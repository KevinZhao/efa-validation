# Agent X · EFA Protocol Caps & Generation 深挖

**日期**：2026-04-26
**调研方式**：直接读 amzn-drivers master / rdma-core master / libfabric EFA provider 源码 + AWS 官方 EC2 规格 blog/docs
**前置文档**：`docs/SRD_PROTOCOL_DEEP_DIVE.md`（下称 DEEP_DIVE）——本文档对其多处做订正
**准则**：遵守 `feedback_claim_verification_discipline.md`，所有数字 ≥1 个源码/文档锚；纯推论标"推论，待实测"

---

## TL;DR（给决策者）

1. **`max_rdma_size` 不是常量**——它是 Nitro 卡 firmware 通过 admin 命令上报的 runtime 值，不是内核驱动硬编码。但根据 libfabric EFA provider 2026-01 提交的 README 更新，**"newest EFA devices"（EFAv3/v4）上 max_rdma_size = 1 GB**（write & read 均支持）。p5（EFAv2）时代是"只 read，无 write"。DEEP_DIVE 里"8 KB / 2 MB 猜测"可以全部划掉。
2. **p5en NIC 数=16, p6-b200 NIC 数=8, p6-b300 NIC 数=17 (其中 16 个 EFA + 1 个 primary ENA-only)**——都经 AWS 官方 docs 锚定。p5/p5e 是 32 NIC × 100 Gbps，p5en 是 16 NIC × 200 Gbps，p6-b200/b300 是 8 / 16 NIC × 400 Gbps。**单 NIC 带宽从 100→400 Gbps 增 4×，这是 SBO lever 搬到 p6 时最需警惕的**。
3. **每 NIC 最大 QP / 每 PD 最大 AH 的绝对值是 runtime 字段**（`max_qp`/`max_ah` 走 EFA admin queue_attr 命令），开源驱动里没有写死数字；**但 amzn-drivers issue #306 证实 "ENOMEM on repeated `ibv_open_device`" 已触发资源耗尽路径**——这是 Mooncake #1944 shared QP 合并的直接动机。UCCL-EP 当前 3 QP/peer 设计在 EP=32 下 **= 96 QP/peer 无 shared，在节点规模 ≥256 时会撞 cap**（推论，待 1 天 probe 实测）。
4. **DEEP_DIVE 有两处需要订正**：
   - 旧文称 `CQ_WITH_EXT_MEM` = bit 7。**真相**：userspace rdma-core master efadv.h line 25 是 bit 5 `EFADV_DEVICE_ATTR_CAPS_CQ_WITH_EXT_MEM_DMABUF`——且是 **DMABUF-specific**，不是通用"CQ 放 GPU BAR"。L1 lever 范围需收窄。
   - 旧文称 `DATA_POLLING_128` 有 userspace caps bit。**真相**：userspace rdma-core efadv.h **没有**这个 flag；它是 kernel efa-abi.h 内部 bit 4，不通过 `efadv_query_device` 暴露。**L6 lever 需要通过 efa-abi.h 直接查 `EFA_QUERY_DEVICE_CAPS_DATA_POLLING_128` bit，走 uverbs 私有接口——风险↑**。

---

## 1. `max_rdma_size` 真值

### 证据链

**1.1 它是 runtime 上报字段，不是内核常量**

- amzn-drivers `kernel/linux/efa/src/efa_com_cmd.h:126`：
  ```c
  struct efa_com_get_device_attr_result {
      ...
      u32 max_rdma_size;   // line 126
      u32 device_caps;     // line 127
  };
  ```
- amzn-drivers `efa_com_cmd.c:553`（`efa_com_get_device_attr` 函数）：
  ```c
  result->max_rdma_size = resp.u.device_attr.max_rdma_size;
  ```
  值来自 EFA admin command response（Nitro 卡 firmware 填写）。
- amzn-drivers `efa_admin_cmds_defs.h:1031`：
  ```c
  u32 max_rdma_size;   // "Max RDMA transfer size in bytes"
  ```
- amzn-drivers `efa_verbs.c:~463`：
  ```c
  resp.max_rdma_size = dev_attr->max_rdma_size;
  ```
  驱动**不做任何 clamp / min_t**，透传给 uverbs ioctl response。
- rdma-core `providers/efa/efadv.h:37`：
  ```c
  uint32_t max_rdma_size;   // 暴露给 efadv_query_device 用户
  ```

**结论**：`max_rdma_size` 完全由 Nitro firmware 决定，kernel / userspace 不 clamp。**唯一拿到真值的办法是 `efadv_query_device` runtime dump**。

**1.2 官方文档/代码给出的 p5en/p6 代近似值**

- libfabric `prov/efa/docs/efa_fabric_comparison.md`（akkart-aws/libfabric commit 69e40af, 2026-01-27）：
  > "The newest EFA devices can support RDMA write up to **1 GB**"
  > "efa-direct supports message size up to the device limits (**max_rdma_size ~ 1 GB**)."
- libfabric `man/man7/fi_efa.7`：
  > "For RMA operations, the maximum message size is the maximum RDMA size of the EFA device. The exact values of these sizes can be queried by the `fi_getopt` API with option names `FI_OPT_MAX_MSG_SIZE` and `FI_OPT_MAX_RMA_SIZE`."
- libfabric man（较老）：
  > "DGRAM endpoint only supports FI_MSG capability with a maximum message size of the MTU of the underlying hardware (approximately **8 KiB**)."

**解读**：
- **8 KiB = SEND/RECV MTU**（所有 EFA 代际都这样）。与 max_rdma_size 是两个东西。
- **~1 GB = 最新 EFA (v3/v4) 的 RDMA write/read 单 WR payload 上限**。p5（EFAv2）时期 write 不支持，只 read；p5en 起 write 才支持到 1 GB。

**1.3 "8KB era" 推测的 origin**

DEEP_DIVE 里提到的"8KB era"其实是 **send/recv MTU 限制**，不是 RDMA write。p5 时代确实 RDMA write 不被 efa_verbs 导出（EFA_DEV_CAP_RDMA_WRITE bit 3 未置位，amzn-drivers r2.5.0 才添加），所以要"写"只能走 send/recv，8 KB MTU 下确实要切 chunk。p5en 起 RDMA write 导出后，单 WR 直接到 GB 级。

### 结论

| 代际 | 单 WR RDMA write/read payload | 依据 |
|---|---|---|
| p4 / EFAv1 | RDMA read only，write 走 send/recv MTU 8 KiB | amzn-drivers r1.5.0 only read |
| p5 / EFAv2 | RDMA read ~1 GB，RDMA write **不支持**（driver 不报 bit 3） | amzn-drivers r2.5.0 才加 write |
| p5en / EFAv3 | RDMA write + read ~1 GB (device_caps bit 3 置位) | libfabric 2026-01 README + EFA cap doc |
| p6-b200 / EFAv4 | 推论同 EFAv3（write+read ≥1 GB） | 驱动仍用 0xefa3 或 0xefa4，RELEASENOTES 未宣告新 cap bit |
| p6-b300 / EFAv4? | 同上 | 同上 |

**实测操作**：在 p5en 上跑
```cpp
struct efadv_device_attr a{};
efadv_query_device(ctx, &a, sizeof(a));
printf("max_rdma_size=%u\n", a.max_rdma_size);
```
预期输出 `1073741824` (1 GB) 或相近。

### 对 UCCL-EP 的影响

- **UCCL-EP 当前在 EFA 路径上 dispatch/combine 的单 WR payload 最大 ~数 KB**（MoE token × hidden_size），远未触及 1 GB cap。**所以 max_rdma_size 不是 bottleneck**。
- **真正被误会成"8 KB cap"的是 `max_sq_sge`**：UCCL-EP `rdma.cpp:897` 写死 `max_send_sge=1`，这和 `max_rdma_size` 无关，是 SGE 数限制。DEEP_DIVE L4 里混淆了这两点。
- **对 Mooncake P2P transfer**：大 tensor 一次发到对端，1 GB 单 WR 足够不切；但 UCCL-EP 的 alltoall pattern 单条消息都很小，此 cap 只影响未来要 transfer 整个 KV cache 的场景（L7 lever 实质价值 = 0，建议从 DEEP_DIVE §2 L7 划掉）。
- **`rdma.cpp:487-495` "first half proxies use first NIC" 的注释**：和 max_rdma_size 无关，是 16 NIC × 8 GPU 的 NUMA/拓扑 2-NIC-per-GPU 分配策略，属于 L3 (multi-NIC per GPU) 的范畴。DEEP_DIVE 里"暗示 UCCL 团队对单 NIC 某种 cap 有认知" → **订正**：此注释仅表达"每 GPU 有 2 NIC，静态 round-robin 绑定"，不隐含带宽/QP cap 逻辑。

---

## 2. QP cap per NIC / AH cap per PD

### 证据链

**2.1 字段在哪里上报**

- amzn-drivers `efa_com_cmd.h:103-128` 结构体 `efa_com_get_device_attr_result` 包含：
  - line 115: `u32 max_qp;`
  - line 124: `u32 max_ah;`
  - line 122: `u32 max_mr;`
  - line 123: `u32 max_pd;`
  - line 118: `u32 max_cq;`
- amzn-drivers `efa_com_cmd.c:577-592` 从 admin `queue_attr_1` response 填充：
  ```
  result->max_qp = resp.u.queue_attr_1.max_qp;    // line 577
  result->max_ah = resp.u.queue_attr_1.max_ah;    // line 592
  ```
- amzn-drivers `efa_verbs.c:355-365`（`efa_query_device`）透传到 `ib_device_attr`：
  ```
  props->max_qp = dev_attr->max_qp;    // line 360
  props->max_ah = dev_attr->max_ah;    // line 364
  ```

**同 1.1：驱动不做 clamp**，完全是 Nitro firmware 上报的 runtime 值。

**2.2 「QP cap 真实会触顶」的证据**

- amzn-drivers issue #306（2024-06）：
  > "`ibv_open_device(rdmap79s0) failed: Cannot allocate memory (12)`"
  > "After few loops with `ENOMEM`. It can be reproduced at will by restarting the program. When removing `ibv_create_comp_channel()`, the failure does not seem to reproduce anymore."
  > "ioctl(3, RDMA_VERBS_IOCTL, ...) = -1 ENOSPC (No space left on device)"

  fixed by linux-rdma/rdma-core PR #1536. 这**直接证明** EFA 卡的 resource (CQ / comp_channel / QP) 是有 cap 的，且已经在实践中被用户触及。issue 里 ibv_open_device 循环调用即能触发 ENOMEM，说明 cap 值并不很大（百量级）。
- Mooncake PR #1944（合并多 peer QP 为 shared QP）的动机就是规避这个 cap。

**2.3 UCCL-EP 当前的 QP 数量估算**

- UCCL-EP `rdma.cpp:962-965`：
  ```cpp
  S.qp         = create_srd_qp_ex(S);   // data
  S.ack_qp     = create_srd_qp_ex(S);   // ack
  S.recv_ack_qp= create_srd_qp_ex(S);   // recv_ack
  ```
  = **3 QP per (thread, peer, NIC)**。
- `rdma.cpp:481-503` 每 GPU 绑 1-2 个 NIC，thread 数 = num_proxies / NIC。
- EP=32，假设 8 GPU × 4 thread × 3 QP × 32 peer = **3072 QP per NIC**（推论，上界）。
  - 除以 16 NIC（p5en） ≈ 192 QP/NIC，若 cap 在 ~256 级别就危险。
  - p6-b200 只 8 NIC，分摊后 2-3× 压力 → **p6-b200 更早触顶**。

**2.4 AH cap**

- UCCL-EP `rdma.cpp:1136` 每 peer 创建 **1 个 AH**（`create_ah()` called once in `modify_qp_to_rtr`）。不是 per-ring，也不是 per-SL。
- AH 数 = 节点内 local thread × remote peer ≈ 几百级。
- `max_ah` 的 Nitro 上限 UNKNOWN（需实测），但 UCCL-EP 的 AH 用量远低于 QP 用量，**AH 不太可能先触顶**。

### 结论

| 资源 | UCCL-EP 当前用量估算 | 实际 cap | 风险 |
|---|---|---|---|
| `max_qp` per NIC | EP=32 下约 192 QP/NIC (p5en) / 384 QP/NIC (p6-b200) | **UNKNOWN**，需 1 天 probe；有 issue #306 证据表明是"数百级可触顶" | **HIGH**——p6-b200 迁移 + EP ≥64 + 多 layer 场景 |
| `max_ah` per PD | 几百级 | UNKNOWN | LOW |
| `max_mr` per PD | ~16 (每 NIC 一条 1 GiB chunk) | UNKNOWN | LOW |
| `max_cq` per device | thread 数 = 几十 | UNKNOWN | LOW |

### 对 UCCL-EP 的影响

- **P4 lever（"ctrl / data QP 分离"）在 QP cap 角度负相关**：分离让 QP 数从 2 变 3 倍。DEEP_DIVE 里若有"分离后 CPU 负载降低"的 P4 声称，需要加一条"前提：QP cap 还没触顶"。
- **Mooncake #1944 shared-QP 策略**应该移植到 UCCL-EP：让多个 peer 复用同一个 SRD QP（SRD 是 datagram，AH 才决定目的端，QP 本身不绑 peer）——这是一条**尚未被 UCCL 识别的独立 lever（新 L9）**，见 §4。
- **实测操作**：加 probe 输出 `a.max_sq_wr`、`ib_device_attr.max_qp`、`max_ah`、`max_mr` 四个字段，覆盖 p5en / p6-b200。

---

## 3. p5en / p6-b200 / p6-b300 代际差异表

### 证据来源

| 字段 | p5en (EFAv3) | p6-b200 (EFAv4) | p6-b300 (EFAv4) | 证据 URL |
|---|---|---|---|---|
| NVIDIA GPU | 8× H200 | 8× B200 | 8× B300 (Blackwell Ultra) | AWS blog p6-b200 GA 2025-05; p6-b300 GA 2025-11 |
| Network cards | **16** | **8** | **17** (1 primary ENA-only + 16 EFA) | AWS docs `efa-acc-inst-types.html`; parallelcluster issue #7143 |
| Total EFA BW | 3200 Gbps | 3200 Gbps | **6400 Gbps** | AWS blog p6-b200; p6-b300 blog |
| EFA BW per NIC | 200 Gbps | **400 Gbps** | **400 Gbps** | 总带宽/NIC 数 |
| EFA BW per GPU | 400 Gbps | 400 Gbps | **800 Gbps** | 总带宽/8 GPU |
| NVLink gen | 4th (900 GB/s) | 5th (1800 GB/s) | 5th (1800 GB/s) | aws-samples efa-cheatsheet; p6-b200/b300 blog |
| Nitro version | v5 | v6 | v6 | AWS docs `efa.html` 表格 |
| EFA generation name | **EFAv3** | **EFAv4** | **EFAv4** | AWS blog p5en (2024-12); p6-b200 GA (2025-05); p6-b300 GA (2025-11) |
| PCI device ID | 0xefa3（推论） | 0xefa3（推论，驱动未升） | 0xefa3（推论） | amzn-drivers master `efa_main.c` 只到 0xefa3；RELEASENOTES 无 0xefa4 |
| RDMA read support | Yes | Yes | Yes | AWS efa.html Nitro v4+ 表 |
| RDMA write support | Yes | Yes | Yes | 同上 |
| max_rdma_size (预期) | ~1 GB | ~1 GB | ~1 GB | libfabric 2026-01 README "newest" |
| max_inline_data | 0（default） / ≤32（INLINE_WRITE flag） | 同 p5en（推论） | 同 p5en（推论） | rdma-core efadv.h line 87 `EFADV_QP_FLAGS_INLINE_WRITE`；`inline_buf_size_ex` 字段已存在 |
| CQ_WITH_EXT_MEM_DMABUF | bit 5 支持（查 kernel ≥ r2.17.0） | 同 p5en | 同 p5en | amzn-drivers RELEASENOTES r2.17.0 + efadv.h:25 |
| UNSOLICITED_WRITE_RECV | bit 4 支持（kernel ≥ r2.10.0） | 同 p5en | 同 p5en | RELEASENOTES r2.10.0 |
| DATA_POLLING_128 | 支持（kernel ≥ r2.4.0） | 同 | 同 | RELEASENOTES r2.4.0 + efa-abi.h:120 |
| atomic support | **NO** (SRD 不支持 atomic；仅 RDMA read/write/send/recv) | NO（推论，amzn-drivers master 仍无） | NO（同） | SRD.txt "Currently only Send operation is supported, but nothing precludes RDMA operations support in future" |
| EFA service levels (SL) | 16 (LL SL 用 sl=8 或 类似) | 同 p5en | 同 p5en | rdma-core PR #1505 "Add QP service level in EFA DV" |

### 关键订正 vs DEEP_DIVE

| 项 | DEEP_DIVE 的说法 | 真相 |
|---|---|---|
| `CQ_WITH_EXT_MEM` at bit 7 | bit 7 | **bit 5**（rdma-core `efadv.h:25`），而且**是 DMABUF-specific**（仅支持 DMABUF fd 共享的 CQ 外部内存） |
| `DATA_POLLING_128` 通过 efadv API 可查 | efadv 有 flag | 错——userspace efadv.h **没有** `EFADV_DEVICE_ATTR_CAPS_DATA_POLLING_128`，只有 kernel efa-abi.h `EFA_QUERY_DEVICE_CAPS_DATA_POLLING_128 = 1 << 4`。要查得走 uverbs query device ex 的 `device_cap_flags_ex`（间接） |
| `device_caps` bit 7 项全没用 | 只列出 5 个 cap | 对的，userspace 只 expose 5 项（RDMA_READ/WRITE/RNR_RETRY/CQ_WITH_SGID/UNSOLICITED_WRITE_RECV/CQ_WITH_EXT_MEM_DMABUF = 6 项 bit 0-5）。kernel 侧有 CQ_NOTIFICATIONS (bit 2)、DATA_POLLING_128 (bit 4)、CQ_WITH_EXT_MEM (bit 7) 但**不全通过 efadv.h 暴露** |
| `max_inline_data` via INLINE_WRITE flag | flag 存在可解锁 | **部分对**。rdma-core efadv.h:87 确实有 `EFADV_QP_FLAGS_INLINE_WRITE` + efadv.h:51 `EFADV_SQ_DEPTH_ATTR_INLINE_WRITE`，实际 inline size 要走 `efadv_get_max_sq_depth()` 拿 `max_inline_data` 字段（不是 query_device），是另一个 API |

---

## 4. 基于以上资料的新 lever

### 🥇 新 L9 · Shared SRD QP across peers（Mooncake #1944 思路移植）

**原理**：SRD 是 datagram，每个 WR 自带 AH 指目的端，QP 本身不绑 peer。UCCL-EP 当前为每个 (thread, peer) pair 创建 3 QP（data/ack/recv_ack），完全没必要——可以让整个 thread 只持 3 QP，用 AH 区分 peer。

**收益**：
- QP 数从 `(threads × peers × 3)` 降到 `(threads × 3)`——规模大（EP ≥64）时降 peers 倍。
- 消除 QP cap 触顶风险（§2.3）。
- NIC 侧 SQ scheduler 在多 peer 场景下的 fairness（Mooncake 报告的次级收益）。

**前置**：
- S0（1 天 probe）确认 `max_qp` 值。
- rdma-core `efadv_create_qp_ex` + AH per-WR 的路径在 UCCL `rdma.cpp:2037` 已是这个模式，代码改动主要在 **QP 生命周期管理**（谁建、谁销毁、引用计数）。

**复杂度**：MEDIUM，2 周。

**DeepEP NVIDIA 能做吗**：IB RC 绑 peer，做不了；UCCL-EP EFA 独占。

---

### 🥈 新 L10 · `EFADV_QP_FLAGS_INLINE_WRITE` + `efadv_get_max_sq_depth`

**订正**：DEEP_DIVE L2 把这条放在"inline ACK"场景——但具体调用路径在 rdma-core 是：

```c
efadv_sq_depth_attr d = {};
d.flags = EFADV_SQ_DEPTH_ATTR_INLINE_WRITE;
efadv_get_max_sq_depth(ctx, &d, sizeof(d));
// now d.max_inline_data tells real inline buffer size
```

**然后**在 QP init：
```c
efadv_qp_init_attr.flags |= EFADV_QP_FLAGS_INLINE_WRITE;
qp_attr_ex.cap.max_inline_data = d.max_inline_data;
```

**收益**：和 DEEP_DIVE L2 同（ACK 省 1 DMA ≈ 0.5-1 µs）。但**订正**：DEEP_DIVE 里只提 flag，没提要用 `efadv_get_max_sq_depth` 先问具体大小——两步都得做。

**复杂度**：LOW，~200 行。

---

### 🥉 新 L11 · p6 代际带宽增 4× 的 SBO Sprint B 回归测

**不是新 lever 是新 gate**：SBO Sprint B 如果在 p5en 上 bench 过了，p6-b200 上 **单 NIC 带宽 200 Gbps → 400 Gbps**，CPU proxy spin 释放 3 SM 的假设（proxy 有足够吞吐 keep up）需要在 p6 上重新测。不做这步迁移可能 regress。

**具体**：
- p5en 单 NIC SRD ack 吞吐 ~X req/s
- p6-b200 单 NIC SRD ack 吞吐 ~2X（推论，带宽 2×）
- 如 CPU proxy 的 signal poll 在 p5en 刚好打满，p6-b200 就 bottleneck
- → Sprint B 可能需要提升 SPSC queue capacity 或 double proxy thread

**动作**：每个 Sprint 完成后**必须**在 p5en + p6-b200 两代都 re-bench。

---

### L12 · `CQ_WITH_EXT_MEM_DMABUF` 走 DMABUF fd 挂 GPU HBM

**订正 DEEP_DIVE L1**：bit 5 + DMABUF-specific 意味着——你**必须**用 cuMemCreate + cuMemExportToShareableHandle 拿到 dmabuf fd，然后传给 `efadv_create_cq` with `EFADV_CQ_INIT_FLAGS_EXT_MEM_DMABUF`（efadv.h:128）。**不支持任意 host memory**。

**这降低了 L1 的实用性**：
- GPU kernel poll CQE 还需要 GPU 能访问那块 DMABUF 内存（HBM mapped via GPUDirect RDMA）
- Userspace doorbell / CQ ring 格式对 GPU 是 "undocumented"（不是像 mlx5 DEVX 那样 stable interface）
- 可能 fallback 成"把 CQE DMA 到 HBM 让 CPU 还是 poll"—— 省不了 PCIe 来回

**结论**：L1 从"原型候选"**降级为"调研候选"**，仍需实测 + AWS 团队确认 GPU-direct poll 是否 supported。Sprint B（CPU spin）在二元决策里胜算↑。

---

## 5. 对已有 lever 的修正

### L1 `CQ_WITH_EXT_MEM` 修正
- **bit 号**：7 → **5**
- **范围**：通用 external memory → **DMABUF-only**
- **实用性**：降级（见 §4 L12）。

### L2 INLINE_WRITE 修正
- **调用路径**：补 `efadv_get_max_sq_depth` 前置查询（§4 L10）
- **`max_inline_data` 字段**：不在 `efadv_device_attr` 主 struct，要走 `efadv_sq_depth_attr.max_inline_data`

### L4 `max_sq_sge ≥ 2` 的场景重估
- DEEP_DIVE 里拿"跨 DMA-BUF chunk"当主场景。但 UCCL-EP 当前 `rdma.cpp:1562-1586` 的 chunk-straddle 只在 register 超过 1 GiB 的 MR 时才发生，MoE dispatch/combine buffer 远 <1 GiB，**实际触发很少**。此 lever 的价值更多在"未来 KV cache transfer"，不在 decode ITL。

### L5 count-send `RDMA_WRITE` + IMM 分离 保持不变（LOW risk）

### L6 `DATA_POLLING_128` 订正
- **userspace efadv.h 没有**这个 cap flag（只有 kernel efa-abi.h:120）。要查只能走 `ibv_query_device_ex` 拿 `device_cap_flags_ex` 或 自己解析 uverbs ioctl response。
- **实现风险↑**，因为 userspace 没 stable API 暴露这个 bit，得做一层 reverse mapping
- 建议推迟到 S0 之后确认 uverbs query device ex 是否能拿到

### B1 multi-NIC lever 保持
- p5en 16 NIC × 200 Gbps → p6-b200 8 NIC × 400 Gbps → p6-b300 16 NIC × 400 Gbps（p6-b300 回到 16 NIC）。
- **重要**：p6-b300 NIC 数 = 17 包括 1 个 primary ENA-only（`parallelcluster issue #7143`），**UCCL-EP 不能把它当 EFA NIC 算进来**，否则 multi-NIC 绑定逻辑会错。当前 `rdma.cpp:487-503` 只 handle num_efas ∈ {32, 16, 8}——**p6-b300 是 16 EFA NIC，应该落到现有 16-NIC 分支**，但实测才能确认 `ibv_get_device_list` 返回是否过滤了 ENA-only 那个。

### P4 ctrl/data QP 分离 修正
- DEEP_DIVE 里没明确谈 QP cap 代价。**补充**：分离让 QP 从 N 升到 2N-3N，结合 §2.3 估算，p6-b200 (8 NIC) 上 EP=32 就可能危险。
- **建议附加 gate**：只有 S0 确认 max_qp ≥ 2× current usage 才做。

---

## 6. 更新的 S0 probe 代码（比 DEEP_DIVE §1 更全）

```cpp
// 在 rdma.cpp:884 create_srd_qp_ex 第一行 (ctx 已开)
struct efadv_device_attr attr = {};
efadv_query_device(ctx, &attr, sizeof(attr));

struct efadv_sq_depth_attr sqd = {};
sqd.flags = EFADV_SQ_DEPTH_ATTR_INLINE_WRITE;
efadv_get_max_sq_depth(ctx, &sqd, sizeof(sqd));

struct ibv_device_attr_ex ibattr = {};
ibv_query_device_ex(ctx, NULL, &ibattr);  // get max_qp, max_ah, etc.

fprintf(stderr,
  "[EFA-CAPS] dev=%s\n"
  "  max_sq_wr=%u max_rq_wr=%u max_sq_sge=%u max_rq_sge=%u\n"
  "  inline_buf=%u inline_buf_ex=%u max_rdma_size=%u caps=0x%x\n"
  "  sq_depth_inline_data=%u max_rdma_sge=%u\n"
  "  ibv.max_qp=%u max_qp_wr=%u max_cq=%u max_cqe=%u max_mr=%u max_pd=%u max_ah=%u\n",
  ibv_get_device_name(ctx->device),
  attr.max_sq_wr, attr.max_rq_wr, attr.max_sq_sge, attr.max_rq_sge,
  attr.inline_buf_size, attr.inline_buf_size_ex, attr.max_rdma_size, attr.device_caps,
  sqd.max_inline_data, sqd.max_rdma_sge,
  ibattr.orig_attr.max_qp, ibattr.orig_attr.max_qp_wr, ibattr.orig_attr.max_cq,
  ibattr.orig_attr.max_cqe, ibattr.orig_attr.max_mr, ibattr.orig_attr.max_pd,
  ibattr.orig_attr.max_ah);
```

在 p5en + p6-b200（有 capacity 时）各跑一次，dump 存 `results/stage5-p5en/efa_caps/<instance-type>-<date>.txt`，push 上游 UCCL repo 作 issue。

---

## 7. 最终要订正到 DEEP_DIVE 的条目

| 位置 | 原文 | 订正 |
|---|---|---|
| §1 表 | `device_caps & CQ_WITH_EXT_MEM` | → `CQ_WITH_EXT_MEM_DMABUF` (bit 5) |
| §1 表 | `device_caps & DATA_POLLING_128` | → 走 efa-abi.h bit 4，**userspace efadv.h 未暴露** |
| §1 表 | `device_caps & INLINE_WRITE` | → 不是 device_cap bit，是 `efadv_get_max_sq_depth` 配合 `EFADV_QP_FLAGS_INLINE_WRITE` QP flag |
| §2 L1 | CQ_WITH_EXT_MEM bit 7 | bit 5，DMABUF-only |
| §2 L1 | "GPU kernel 直接 poll CQE" | 需确认 GPU-direct poll 是否 supported，降级为调研项 |
| §2 L2 | 直接设 `max_inline_data` | 需先 `efadv_get_max_sq_depth` 查真实大小 |
| §2 L6 | 通过 `efadv_query_device` 查 DATA_POLLING_128 | userspace 没这个 flag，要走 uverbs 私有 |
| §2 L7 | max_rdma_size 影响单 WR payload | 真值 ~1 GB，UCCL-EP 不受限，**删 L7** |
| §7 引用 | UCCL 漏调 `efadv_query_device` | + 漏调 `efadv_get_max_sq_depth` / `ibv_query_device_ex` |

---

## 8. 风险与未解答（诚实标注）

| UNKNOWN | 实测方式 | 为啥不能 web 查 |
|---|---|---|
| `max_qp` 真实值 (p5en/p6-b200/b300) | S0 probe | firmware 上报值，未见 AWS 官方公布 |
| `max_ah` 真实值 | S0 probe | 同上 |
| `inline_buf_size_ex` 真实值 | S0 probe | 同上 |
| p6-b300 PCI device ID | 实际 boot + `lspci -nn \| grep 1d0f` | amzn-drivers master RELEASENOTES 最新未显示 0xefa4，可能仍复用 0xefa3 |
| p6 atomic 支持 | 实测 `ibv_post_send` with `IBV_WR_ATOMIC_*` on SRD | SRD.txt 文字"currently only Send operation supported"，但该文档老；驱动 src 仍未见 atomic 路径 |
| p6-b300 16 vs 17 NIC 在 verbs 视角 | `ibv_get_device_list()` count | AWS docs 说 17 网卡 1 个 ENA-only，EFA verbs 视角应该只看见 16 个 |
| GPU-direct CQ polling on EFA | AWS 团队 confirm 或实测 | rdma-core / amzn-drivers 未文档化 |

---

## 9. 一句话结论

**Q1 答**：`max_rdma_size ≈ 1 GB` on p5en+ (EFAv3/v4)，runtime 字段，UCCL-EP 用量远低于此——**不是瓶颈，L7 lever 删除**。

**Q2 答**：`max_qp` 和 `max_ah` per NIC 是 runtime firmware 字段，开源不公布数值；amzn-drivers issue #306 证实已被实际触顶过；UCCL-EP 当前 3 QP/peer 设计在 EP ≥32 + 多 thread 时 **估算已接近危险区**，**Mooncake #1944 shared-QP 移植作为新 L9 是最高 ROI 的 QP-cap 防御性 lever**——且正好 AWS 独占（NVIDIA IB RC 绑 peer，做不了）。

**Q3 答**：p5en=EFAv3 16NIC/200Gbps，p6-b200=EFAv4 8NIC/400Gbps，p6-b300=EFAv4 16NIC/400Gbps（+1 primary ENA-only 共 17 网卡）；三代都支持 RDMA write+read；**SBO 优化在 p5en bench 过的结果不能直接搬 p6**——单 NIC 带宽 2×，CPU proxy spin / signal poll 吞吐假设需重测。

**真正的 S0 动作（1 天）**：改 `rdma.cpp:884` 加 §6 的 probe，跑 p5en + p6-b200 两代，push UCCL 上游——这是进一步 lever 的先决条件，无风险。
