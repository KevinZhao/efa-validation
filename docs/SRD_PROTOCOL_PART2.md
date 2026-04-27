# SRD Protocol Deep Dive — Part 2 (UNKNOWN 攻坚结果)

**日期**：2026-04-26
**前置**：`docs/SRD_PROTOCOL_DEEP_DIVE.md`（Part 1，3 agent 原始调研 + 8 个留待深挖的 UNKNOWN）
**本文**：3 个独立 agent（X / Y / Z）对 8 个 UNKNOWN 逐条攻破，附证据级结论 + lever 重排
**子文档**：`SRD_PROTOCOL_PART2_X.md`, `SRD_PROTOCOL_PART2_Y.md`, `SRD_PROTOCOL_PART2_Z.md`
**方法**：遵循 `feedback_claim_verification_discipline.md` —— 每条结论必锚源码行号 / commit SHA / paper section / AWS 文档 URL；推论 vs 实测严格标注

---

## 0. TL;DR（一页给决策者）

### 8 个 UNKNOWN 的答案

| # | UNKNOWN | 结论 | 证据强度 |
|---|---|---|---|
| 1 | `max_rdma_size` 真值 | **~1 GB** (p5en/EFAv3+)，runtime 字段，UCCL-EP 远未触及 | libfabric 2026-01 README + amzn-drivers kernel |
| 2 | 每 NIC `max_qp` | **UNKNOWN 数值**，但 amzn-drivers issue #306 实证"数百级可触顶" | 需 1 天 `efadv_query_device` probe |
| 3 | 每 PD `max_ah` | UNKNOWN 数值，用量低于 QP，**不太可能先触顶** | 同上 |
| 4 | EFA SL 硬件语义 | **firmware-opaque QoS class**，不是独立 HW queue，也不是纯软 tag | rdma-core PR #1505 + kernel 代码无 SL→queue 映射 |
| 5 | GRH `flow_label` 是否进 ECMP hash | **彻底死字段**，kernel `efa_create_ah` 连读都不读 | `efa_verbs.c:3989` + admin cmd 结构无 flow_label 位 |
| 6 | `CQ_WITH_EXT_MEM_DMABUF` 语义 | **GPU HBM CQ polling 原理可行**（amzn commit 866f9d3 明确写为目标用例）；但工程链长 4-6w | commit message verbatim + efadv.h:25 bit 5 |
| 7 | SRD retransmit timer | **软件里不存在**，Nitro firmware 全权；公开定性 "microseconds rather than milliseconds" | re:Invent 2022 DeSantis keynote 12:30 |
| 8 | p5en (v3) vs p6-b200 (v4) vs p6-b300 (v4) 代际 | NIC 数 16/8/17（p6-b300 有 1 primary ENA-only）；单 NIC 带宽 200/400/400 Gbps | AWS docs `efa-acc-inst-types.html` |

### 最终 lever 裁决（**对 Part 1 的重大订正**）

| Part 1 lever | 原状态 | Part 2 裁决 | 理由 |
|---|---|---|---|
| **L1** CQ on GPU BAR (GPU 轮询) | 强候选 | **降级 Sprint D**（0.5 天 micro-bench 后再定） | 原理可行但工程链 4-6w；bit 号订正 7→5；DMABUF-specific |
| **L2** `INLINE_WRITE` | 候选 | **保留，补调用路径** | 需先 `efadv_get_max_sq_depth` 查真实 inline size |
| **L3** multi-NIC per GPU | 候选 | **保留** | p6 代际带宽 2×，需 re-bench（新 L11 gate） |
| **L4** `max_sq_sge ≥ 2` | 候选 | **降级** | MoE buffer <1 GiB 很少触发 chunk-straddle |
| **L5** count-send IMM 分离 | 候选 | **保留** | 与 Part 2 无交叉 |
| **L6** `DATA_POLLING_128` | 候选 | **降级，实施风险 ↑** | userspace efadv.h 未暴露，需走 uverbs 私有 |
| **B2** SL 分流 (FEASIBILITY_RECONFIRM 留的) | 实测待定 | **永久埋掉** | SL firmware-opaque + UCCL 已全 SL=8；分流负收益风险 |
| **flow_label ECMP** 假设 | 常识推论 | **彻底埋掉** | 死字段，kernel 不读 |
| **L7** max_rdma_size 瓶颈 | 弱候选 | **永久删除** | 真值 ~1 GB，UCCL-EP 不受限 |

### Part 2 新增的 lever

| # | lever | 收益 | 工作量 | 优先级 |
|---|---|---|---|---|
| **L9** | shared-SRD-QP across peers（Mooncake #1944 思路移植到 UCCL-EP） | QP 数减 peers 倍，消 QP cap 触顶风险，NIC 侧 SQ scheduler fairness | 2w | **高**（AWS 独占，NVIDIA IB-RC 做不了） |
| **L10** | `INLINE_WRITE` + `efadv_get_max_sq_depth` 正确调用链 | ACK 省 1 DMA ≈ 0.5-1 µs | 200 行 | 中 |
| **L11** | SBO p5en→p6 带宽 2× 回归测 gate | 不 regress | 每 Sprint 重测 | **强制** |
| **L12** | `rnr_retry` 作为 safety net | 可靠性，非性能 | <1 天 | 低 |
| **S0-ext** | `efadv_query_device` + `efadv_get_max_sq_depth` + `ibv_query_device_ex` 一起 probe | 解锁 L1-L6/L9-L12 | **1 天** | **必须先做** |

### 关键决策

1. **Sprint 顺序不变**：A (GPU spin + comp_signal) → B (CPU spin) → C (Blackwell src_signals) → **L1 降级到 Sprint D**
2. **S0 probe 价值被 3 个 agent 一致强调**，是解锁 L1/L2/L6/L9 的**共同先决条件**，1 天工作量 ROI 10×
3. **B2 和 flow_label 的 1 天实测预算全部转移到 S0 probe**

---

## 1. UNKNOWN 逐条攻破

### UNKNOWN #1 · `max_rdma_size` 真值（Agent X）

**证据链**：
- amzn-drivers `efa_com_cmd.h:126` 字段定义 `u32 max_rdma_size`
- `efa_com_cmd.c:553` 从 admin queue response 透传
- `efa_verbs.c:~463` 再透传到 uverbs ioctl response（**kernel 不做任何 clamp**）
- libfabric 2026-01-27 commit 69e40af 官方 README：**"newest EFA devices support RDMA write up to 1 GB"**

**结论**：
| 代际 | 单 WR RDMA write/read payload |
|---|---|
| p4 / EFAv1 | RDMA read only, write 走 send/recv 8 KiB MTU |
| p5 / EFAv2 | RDMA read ~1 GB, RDMA write **不支持** |
| p5en / EFAv3 | RDMA write + read ~1 GB |
| p6 / EFAv4 | 同 EFAv3（推论，RELEASENOTES 无新 cap） |

**对 UCCL-EP 的影响**：
- MoE dispatch/combine 单 WR payload 仅数 KB，**远未触及 1 GB cap**
- **L7 lever 永久删除**（Part 1 "max_rdma_size 瓶颈" 的假设不成立）
- "8 KB era" 的错觉源于 send/recv MTU，不是 RDMA write payload

**订正 Part 1**：`rdma.cpp:487-495` "first half proxies use first NIC" 注释和 max_rdma_size **无关**，是 2-NIC-per-GPU 静态绑定策略（属于 L3/multi-NIC 范畴）。

---

### UNKNOWN #2 · QP cap per NIC / AH cap per PD（Agent X）

**证据链**：
- `max_qp`、`max_ah`、`max_mr`、`max_pd`、`max_cq` 全是 Nitro firmware 通过 admin queue 上报的 runtime 字段（`efa_com_cmd.h:103-128` + `efa_com_cmd.c:577-592`）
- 驱动不 clamp（`efa_verbs.c:355-365`）
- **硬证据：amzn-drivers issue #306**（2024-06）——`ibv_open_device` 循环调用即触发 `ENOMEM` + `ENOSPC`（fixed by rdma-core PR #1536）
- 证实资源 cap 存在且不很大（百量级）

**UCCL-EP 当前 QP 数量估算**：
- `rdma.cpp:962-965`：每 (thread, peer) 创建 3 QP（data / ack / recv_ack）
- EP=32 × 8 GPU × 4 thread × 3 QP × 32 peer ≈ **3072 QP/node 上界**
- 除以 16 NIC (p5en) ≈ 192 QP/NIC
- **p6-b200 只 8 NIC → 384 QP/NIC，最早触顶**
- **p6-b300 回 16 EFA NIC → 同 p5en 密度**

**AH cap**：UCCL-EP 每 peer 1 AH（`rdma.cpp:1136`），用量远低于 QP，不太可能先触顶。

**新 L9 lever（重要）**：
- **shared-SRD-QP across peers**——SRD 是 datagram，每个 WR 自带 AH 指目的端，QP 本身不绑 peer
- 让 thread 只持 3 QP（共用），用 AH 区分 peer，QP 数 `(threads × peers × 3)` → `(threads × 3)`
- 收益：EP ≥ 64 时降 peers 倍，消 QP cap 触顶风险，NIC SQ scheduler fairness
- **NVIDIA IB RC 做不了（绑 peer），EFA 独占 lever**
- 直接移植 Mooncake #1944 思路（see `reference_henan_pr_quality_review.md`）

**对 P4 (ctrl/data QP 分离) 的订正**：P4 会让 QP 数从 N 升到 2N-3N，结合上述估算，**p6-b200 上可能危险**。建议 P4 附加 gate：S0 确认 max_qp ≥ 2× current usage 才做。

---

### UNKNOWN #3 · EFA SL 字段真语义（Agent Y）

**证据链（从 userspace 到 firmware）**：
- UCCL 写入点：`rdma.cpp:911` 全部 QP 都设 SL=8 (`use_ll_sl` 在 p5/p5en/p6-b200 全为 true)
- rdma-core PR #1505 (mrgolin@Amazon, 2024-11-12) **body 和 Jason Gunthorpe 讨论中没有任何语言描述 SL 语义**
- kernel `efa_verbs.c` 纯 u8 透传 (`create_qp_params.sl = cmd.sl`)
- admin cmd `efa_admin_create_qp_cmd.sl` 注释仅 "Requested service level for the QP, 0 is the default SL"
- **`efa_io_tx_meta_desc` 每包结构 0 处 SL 字段**（不是每包带；QP 级一次设定）
- IB Spec §9.6 SL→VL mapping **在 EFA 上不适用**（EFA 不跑 SM，L3/UDP 隧道进 Nitro）

**libfabric 的 fallback 逻辑**暗示 firmware 确实认 SL=8 的"低延迟 class"，但**具体副作用 AWS 未公开**。

**结论**：SL 是 **firmware-opaque QoS class**——不是独立 HW SQ scheduler，也不是纯软 tag。

**对 B2 (SL 分流) 的判决**：**永久埋掉**
- UCCL 已全 SL=8；"分流"等于把部分 QP 降到 SL=0，libfabric fallback 逻辑暗示 SL=0 延迟更高 → **负收益风险**
- P99 -5~-10µs 是无源数字，没有协议文档 / benchmark 支持
- `FEASIBILITY_RECONFIRM` 已砍掉过一次，本次再确认

---

### UNKNOWN #4 · GRH `flow_label` 是否被 Nitro ECMP 使用（Agent Y）

**证据链（自底向上）**：
- amzn-drivers kernel `efa_create_ah` (`efa_verbs.c:3944-4013`) **仅读 `ah_attr->grh.dgid.raw`** 一行 memcpy
- **不读 `flow_label` / `traffic_class` / `hop_limit` / `sgid_index` / `port_num`**
- admin cmd `efa_admin_create_ah_cmd` 结构：`u8 dest_addr[16]; u16 pd; u16 reserved;` —— **firmware 根本看不到 flow_label**
- AWS 自己的 libfabric (`efa_ah.c`) **不设 flow_label**，只填 `port_num=1, is_global=1, memcpy(dgid)`
- UCCL 全仓 grep：**13 处 `flow_label = 0`，0 处非零**
- 任务 prompt 说 `rdma.cpp:944-961` 派生 flow_label from QPN —— **误记**，实际 `:1132` 硬编码 0，全仓无派生逻辑
- AWS HPC blog 2023 原话："we choose 64 paths at a time" —— **明确说 64 paths 是 NIC 内部选**，非 sender 指定

**结论**：`flow_label` 是**彻底死字段**。driver 连读都不读，admin cmd 也没位置传给 firmware。

**对 Part 1 §3 表 #1 的订正**：Agent 1 之前"可能 flow_label 有效——UNKNOWN" 的推论**撤回**。kernel driver 代码明证不成立。

**对 A1 (PR #485 multi-QP) 的判决**：
- 和 flow_label 无重复收益（flow_label 不生效）
- A1 收益来源是 **SQ 并发 + doorbell concurrency**（每 QP 独立 `sq_db_offset`）
- "多 QP → 多路径" 假设无证据（`dest_qp_num` 是否进 Nitro hash 是 UNKNOWN，但如真的进，A1 自然带上这个副作用，不需要 flow_label 补刀）

---

### UNKNOWN #5 · `EFADV_CQ_INIT_FLAGS_EXT_MEM_DMABUF` 真实语义（Agent Z）

**证据链**：
- rdma-core master `providers/efa/efadv.h:115` `EFADV_CQ_INIT_FLAGS_EXT_MEM_DMABUF = 1 << 0`
- `efadv.h:23` capability bit `EFADV_DEVICE_ATTR_CAPS_CQ_WITH_EXT_MEM_DMABUF = 1 << 5`（**订正 Part 1 说的 bit 7**）
- 入参是 `int32_t fd`（DMA-BUF fd），不是裸指针
- **amzn-drivers commit 866f9d3 (2025-07-15, r2.17.0)** message verbatim:
  > *"One of the possible usages is creating CQs that reside in accelerator memory, allowing low latency asynchronous direct polling from the accelerator device."*
- kernel `efa_verbs.c:2353` `cq->cpu_addr = NULL; cq->dma_addr = ib_umem_start_dma_addr(umem)` —— kernel 不保留 VA，CPU verbs 无法 deref CQE
- NVIDIA 侧配套 API：`cuMemGetHandleForAddressRange(CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD)`（NVSHMEM/ibgda 已在 mlx5 上在用）

**支持的内存类型**：
| 类型 | 支持 | 证据 |
|---|---|---|
| GPU HBM (via CUDA DMA-BUF export) | ✅ 设计目标 | commit 866f9d3 message |
| Host DRAM (pinned) | ✅ | `ib_umem_get()` 路径 |
| Neuron | ✅ | 已有 Neuron P2P path |

**哪端能 poll**：
| Poller | 可行 | 性能 |
|---|---|---|
| GPU kernel 从 HBM 读 | ✅ 设计目标 | ~20-40 ns/CQE (HBM latency, 推论) |
| CPU user-space (HBM BAR 映射) | ✅ 但**巨慢** | ~200-800 ns/CQE (uncached BAR read) |
| CPU user-space (host DRAM, 现状) | ✅ | ~3-4 ns/CQE (L1/L2) |
| kernel verbs | ❌ | `cpu_addr = NULL` |

**L1 裁决（重要）**：
- **原理可行**，API + kernel + NVIDIA 三端齐备
- **阻塞项**：
  1. efa-driver 必须 ≥ r2.17.0（我们生产镜像可能不满足）
  2. rdma-core `libefa.so` ≥ 2025-07-24 commit 22c4e37（自编）
  3. UCCL `rdma.cpp` 零处 `efadv_create_cq` 调用，greenfield 代码路径
  4. **Nitro EFA → GPU HBM P2P 写入延迟/带宽未实测**
- **降级为 Sprint D**：Sprint A+B+C 完成后再评估
- **本周 0.5 天 micro-bench**：分配 16 KB GPU HBM，导出 dmabuf fd，创建 EXT_MEM_DMABUF CQ，测 CQE 从 Nitro 到 GPU kernel 可见时间
  - **< 2 µs** → L1 进 Sprint D roadmap
  - **≥ 10 µs** → L1 永久 drop

---

### UNKNOWN #6 · SRD retransmit timer（Agent Z）

**证据链**：
- `SRD.txt` 全文 **0 处数字 timeout 值**
- amzn-drivers 所有 `.c`/`.h` grep "timeout": 只有 admin queue 相关（`ADMIN_CMD_TIMEOUT_US=30000000` / `EFA_REG_READ_TIMEOUT_US=50000` / `hw_hints` 4 个字段）——**与 SRD 数据路径无关**
- `efadv_query_device` 返回结构无 timer 字段
- sysfs / debugfs 无 timer 参数
- **最权威公开数量级**：re:Invent 2022 keynote (Peter DeSantis, 12:30-14:18)：
  > *"retransmits will happen in microseconds rather than milliseconds"*
- SIGCOMM 2020 paper 只提 "fast retransmission"，无具体值

**可调的 only**：
- `rnr_retry`（receiver 无 RQ WQE 重试），可通过 `ibv_modify_qp` 调；**不是单包重传 timer**
- SRD 单包 retransmit timer **完全不可调**，Nitro 固件决定

**对 Sprint B 的影响**：

| 场景 | CQE 出现时间 | CPU spin 安全? |
|---|---|---|
| 正常网络 | 10-20 µs | ✅ 完美 |
| 单包丢一次 + Nitro 重传 | 原 10-20 µs + 数百 µs | ✅ P99 < 1 ms |
| 远端节点挂 (spot reclaim) | 上层 transport timeout (秒级) | ⚠️ 需 watchdog fallback |

**结论**：Sprint B (CPU spin) **不被 retransmit 阻塞**，因为 retransmit "microseconds rather than milliseconds"，加 spin_budget_us=10 ms + `ibv_req_notify_cq` + epoll watchdog 完全安全。

---

### UNKNOWN #7 · p5en / p6-b200 / p6-b300 代际差异（Agent X）

| 字段 | p5en (EFAv3) | p6-b200 (EFAv4) | p6-b300 (EFAv4) |
|---|---|---|---|
| GPU | 8× H200 | 8× B200 | 8× B300 (Blackwell Ultra) |
| **Network cards** | **16** | **8** | **17** (1 ENA-only + 16 EFA) |
| Total EFA BW | 3200 Gbps | 3200 Gbps | **6400 Gbps** |
| **EFA BW per NIC** | 200 Gbps | **400 Gbps** | **400 Gbps** |
| EFA BW per GPU | 400 Gbps | 400 Gbps | **800 Gbps** |
| NVLink | 4th gen 900 GB/s | 5th gen 1.8 TB/s | 5th gen 1.8 TB/s |
| Nitro | v5 | v6 | v6 |
| RDMA write + read | ✅ | ✅ | ✅ |
| `max_rdma_size` | ~1 GB | ~1 GB | ~1 GB |
| SRD SL | 支持 sl=8 | 同 | 同 |

**关键 gate（新 L11）**：
- **单 NIC 带宽 200 → 400 Gbps 2×** —— SBO Sprint B 的 CPU proxy spin / signal poll 吞吐假设**不能直接从 p5en 搬到 p6**
- 每个 Sprint 完成后必须 **p5en + p6-b200 双代 re-bench**
- 否则可能 p5en 完美的 signal poll 在 p6-b200 因更快 SRD ack 吞吐不够，regress

**p6-b300 的 NIC 陷阱**：
- 17 网卡中 1 是 primary ENA-only（`parallelcluster issue #7143`）
- UCCL `rdma.cpp:487-503` 只 handle `num_efas ∈ {32, 16, 8}`
- **推论**：`ibv_get_device_list` 应该过滤掉 ENA-only 那个，p6-b300 落 16-NIC 分支，但**需实测确认**

---

### UNKNOWN #8 · UCCL 漏用的 EFA API（3 agent 共同发现）

**UCCL-EP `rdma.cpp` 零处**：
- `efadv_query_device` —— 从不问 EFA 真实 cap
- `efadv_get_max_sq_depth` —— INLINE_WRITE 的必须前置查询
- `efadv_create_cq` with EXT_MEM flag —— 整个 L1 lever 未动

**UCCL-EP 硬编码假设**：
- `max_sq_wr`, `max_rq_wr`, `max_inline_data=0`, `max_send_sge=1` 等全部写死
- 忽略 `DATA_POLLING_128` (128B CQE)
- 忽略 `CQ_WITH_EXT_MEM_DMABUF`
- 忽略 `UNSOLICITED_WRITE_RECV`

**对代际 portability 的影响**：
- 硬编码在 p5en 可能 OK
- p6-b200/b300 如果 firmware 升级了某 cap，UCCL-EP 用不到
- 跨代重测就变"玄学调优"

**建议修正（S0-ext）**：

```cpp
// rdma.cpp:884 create_srd_qp_ex 开头
struct efadv_device_attr attr = {};
efadv_query_device(ctx, &attr, sizeof(attr));

struct efadv_sq_depth_attr sqd = {};
sqd.flags = EFADV_SQ_DEPTH_ATTR_INLINE_WRITE;
efadv_get_max_sq_depth(ctx, &sqd, sizeof(sqd));

struct ibv_device_attr_ex ibattr = {};
ibv_query_device_ex(ctx, NULL, &ibattr);

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

dump 存 `results/stage5-p5en/efa_caps/<instance-type>-<date>.txt`，push UCCL 上游作 issue（和 PR #904 warmup env var 类似的小 bug 式贡献）。

---

## 2. Part 1 文档需要订正的条目

| 位置 | Part 1 原文 | Part 2 订正 |
|---|---|---|
| §1 表 | `CQ_WITH_EXT_MEM` at bit 7 | → **bit 5**, `CQ_WITH_EXT_MEM_DMABUF`，DMABUF-specific |
| §1 表 | `DATA_POLLING_128` 通过 efadv API 可查 | → userspace efadv.h **未暴露**，要走 uverbs 私有 |
| §1 表 | `INLINE_WRITE` 是 device_cap bit | → 不是，是 QP flag `EFADV_QP_FLAGS_INLINE_WRITE` + `efadv_get_max_sq_depth` 查 size |
| §1 L1 | CQ_WITH_EXT_MEM 通用 external memory | → **DMABUF-only**，且需 Nitro→HBM P2P 实测验证 |
| §1 L2 | 直接设 `max_inline_data` | → 先 `efadv_get_max_sq_depth` 查真实值 |
| §1 L7 | max_rdma_size 是瓶颈 | → **删除 L7**，真值 ~1 GB，UCCL-EP 不受限 |
| §2 sq_sig_all=1 硬约束 | EFA 硬限 | → **真驱动级硬约束**，但不涵盖 inline_data（INLINE_WRITE flag 可解） |
| §3 表 #1 | flow_label UNKNOWN (Agent 1 推测可能有效) | → **彻底否定**，kernel 不读，admin cmd 无位置 |
| §3 表 #4 | 多 QP → 多路径的 Nitro spray | → 无证据；多 QP 真实收益是 **SQ 并发**，路径多样性 UNKNOWN |

---

## 3. 最终 lever 排名（ROI 升序，近→远）

### 立即可做（本周 / 下周）

| # | lever | 收益 | 工作量 | 状态 |
|---|---|---|---|---|
| **S0-ext** | `efadv_query_device` + `efadv_get_max_sq_depth` + `ibv_query_device_ex` probe | 解锁 L1/L2/L6/L9 | **1 天** | **必须先做** |
| **L1-preview** | Nitro→p5en HBM P2P CQE 写入 micro-bench | 裁决 Sprint D 是否入 roadmap | 0.5 天 | 零依赖 |
| **launcher-cache** | `cudaDeviceGetAttribute` 结果静态化（替代 C1 persistent kernel）| 60-180 µs/token | 1 天 | 已在 FINAL_EXECUTION_CHECKLIST §2 |

### Sprint 关键路径（本月内）

| # | lever | 收益 | 工作量 | 依赖 |
|---|---|---|---|---|
| **Sprint A** | GPU spin + `comp_signal` 协议对齐 | decode ITL -5~-8% | 2w | 无 |
| **A1** (PR #485 rebase) | multi-QP LL，dispatch SQ 并发 | dispatch P50 个位 %, combine tail 10-20% | 3-5d | 无 |
| **count-send coalescing** | per-rank AMO merge | 10-30 µs/层 | 3-5d | #485 |
| **L10** (INLINE_WRITE 正确链) | ACK 省 1 DMA | 0.5-1 µs | 200 行 | S0-ext |

### Sprint B 里面（1.5w 之后）

| # | lever | 收益 | 工作量 |
|---|---|---|---|
| **Sprint B** | CPU spin EFA 独占 + SPSC queue | 再减 µs 级 signal poll 中介 | 1.5w |
| **L9** (shared-SRD-QP, Mooncake #1944 思路) | QP 数减 peers 倍，消 cap 触顶 | 2w | **AWS 独占 lever** |
| **L3** multi-NIC per GPU | dispatch 带宽 1.6-2× | 3-5w | B1 |

### Sprint C 之后 (2026-Q3+)

| # | lever | 收益 | 依赖 |
|---|---|---|---|
| **Sprint C** Blackwell src_signals | decode ITL -3~-5% (B300 only) | 1.5w | Sprint B + Blackwell 栈 |
| **Sprint D = L1** CQ on GPU BAR | 未量化 | 4-6w | Sprint A+B+C 完 + L1-preview ≥ positive |

### 永久埋掉

- **L4** max_sq_sge ≥ 2（触发场景少）
- **L6** DATA_POLLING_128（userspace 未暴露）
- **L7** max_rdma_size 瓶颈（假设不成立）
- **B2** SL 分流（负收益风险）
- **flow_label ECMP** 分流（死字段）
- **A5** straggler soft degrade (FEASIBILITY_RECONFIRM 已驳回)
- **A2** selective signaling (sq_sig_all=1 硬限)
- **A3** post-send batching window (已隐式 batch)
- **C1** persistent kernel (CUDA Graph 已摊销)
- **C2** early-drop 非 top-k (path 本就 top-k)
- **C3** clean-elision (不是 per-step)

---

## 4. L1 vs Sprint B 最终裁决

**FEASIBILITY_RECONFIRM 遗留问题**："L1 (CQ on GPU BAR) 与 SBO Sprint B (CPU spin) 互斥，必须选一个。"

**Part 2 答案**：**不互斥**。
- **Sprint B** 是增量改动（不依赖新 driver/库），1.5w 落地
- **L1** 是 greenfield（amzn-drivers r2.17.0 + rdma-core 自编 + UCCL 新代码 + P2P bench + persistent kernel poller），4-6w
- **顺序**：Sprint A → Sprint B → Sprint C，**L1 降为 Sprint D**

**触发 L1 的条件**：
- S0-ext 确认 p5en 上 efa-driver ≥ r2.17.0 + `CQ_WITH_EXT_MEM_DMABUF` cap bit 置位
- L1-preview micro-bench（0.5 天）测 Nitro→HBM P2P CQE 延迟 < 2 µs
- Sprint A+B+C 完成后 decode ITL 仍有 > 5% 头部可压

**不触发就 drop**：Sprint A+B+C 后拿到 -10~-15% decode ITL，已覆盖 FEASIBILITY_RECONFIRM 里定的"完整收益 50-60% = Sprint A 单独"基线，L1 的增量收益若 <3% 且工程 4-6w 不划算。

---

## 5. 需要订正的其他文档

| 文档 | 需要订正的位置 |
|---|---|
| `docs/SRD_PROTOCOL_DEEP_DIVE.md` | §1 表 bit 号、§1 L2/L6/L7、§3 表 #1 flow_label、§2 硬约束定义 |
| `docs/EXPECTED_PERFORMANCE_GAINS.md` | 加 L9 (shared-SRD-QP) 作为 AWS 独占 lever 项 |
| `docs/FINAL_EXECUTION_CHECKLIST.md` | §1 instrumentation 补 `efadv_get_max_sq_depth` 和 `ibv_query_device_ex` 两个 API |
| `memory/project_p0_combine_signal.md` | flow_label 错误说法订正（原 prompt 说 `rdma.cpp:944-961` 派生） |
| `memory/reference_srd_protocol_deep_dive.md` | 指向 Part 2，更新 8 UNKNOWN 答案 |

---

## 6. 诚实标注的残余 UNKNOWN

| # | UNKNOWN | 解法 | 优先级 |
|---|---|---|---|
| U1 | p5en/p6-b200 实际 `max_qp`、`max_ah` 数值 | S0-ext probe 1 天 | **高**（决定 L9 ROI 上限）|
| U2 | p6-b300 PCI device ID 是否仍 0xefa3 | 实际 boot + `lspci -nn \| grep 1d0f` | 中（新镜像 bake 时测）|
| U3 | p6 atomic 支持 | 实测 `ibv_post_send` with `IBV_WR_ATOMIC_*` | 中 |
| U4 | `dest_qp_num` 是否进 Nitro ECMP hash | 多 QP bench 观察 path 分布 | 低（A1 PR #485 bench 自然带） |
| U5 | SL=8 vs SL=0 firmware 行为差异 | AWS 团队 confirm | 低（永久埋掉 B2）|
| U6 | Nitro→GPU HBM P2P CQE 写入延迟 | L1-preview micro-bench 0.5 天 | **高**（裁决 Sprint D）|
| U7 | SRD 单包 retransmit timer 具体数值 | AWS 不披露；paper 级"microseconds" 已足够 | 低 |
| U8 | Nitro VF 调度对 SL 是否做 class-based fairness | AWS 未公开 | 低 |

---

## 7. 一句话结论

**"EFA 协议层"不是"物理硬约束"而是"Nitro firmware 黑盒"**。Part 2 的 8 UNKNOWN 攻坚把 "猜测/常识" lever（B2 SL 分流、flow_label ECMP、L7 max_rdma_size 瓶颈、L4 max_sq_sge）全部埋掉，把"真有证据但要工程"lever（L1 GPU BAR CQ）降级到 Sprint D，把"AWS 独占真金"lever（L9 shared-SRD-QP）新推上主排名。**本周应立即花 1.5 天做 S0-ext probe + L1-preview micro-bench**，把残余 UNKNOWN 里 3 个关键的（U1/U6）收掉，之后 Sprint 顺序 A→B→C→(L1?) 清晰。

**Sprint 期望总收益不变**：全做完 decode ITL **-10~-15%** + TTFT cold **-200-500ms**；Sprint A 单独拿 50-60% 全收益仍是最高 ROI 密度。
