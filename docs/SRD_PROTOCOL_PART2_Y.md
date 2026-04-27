# Agent Y · EFA SL + flow_label 真相

**日期**：2026-04-26
**调研方式**：纯协议 / 源码证据（amzn-drivers 内核 + rdma-core efa provider + libfabric efa provider + AWS 公开文档），不实测
**准则**：遵守 `feedback_claim_verification_discipline.md` 四条 —— 所有声称锚源码行号或 URL；源码缺证据的标 **UNKNOWN**
**背景文档**：`docs/SRD_PROTOCOL_DEEP_DIVE.md` §0-§2、§5

---

## 0. TL;DR

| 问题 | 证据级结论 |
|---|---|
| **SL 是硬件队列还是软 tag？** | **firmware-opaque**。内核和 userspace 都把 `sl` 当 `u8` 透传给 Nitro firmware，没有任何文档/commit/代码/注释说它映射到独立硬件 SQ、调度器、VL、优先级。"SL=8 = 低延迟" 是 AWS libfabric 和 UCCL 的约定（`efa.h` 宏 + `FI_TC_LOW_LATENCY` 翻译），但**硬件行为未公开**。 |
| **GRH flow_label 被 Nitro ECMP 用吗？** | **直接否定**。内核驱动 `efa_create_ah` 只读 `ah_attr->grh.dgid.raw`（一行 memcpy），**不读 flow_label / traffic_class / hop_limit / sgid_index**。userspace `ibv_cmd_create_ah` 即便 marshalled 也被 kernel 丢弃。Nitro 内部 spray 路径选择与 `flow_label` 无证据链。 |
| **UCCL 当前对 flow_label 的使用** | 任务 prompt 说 `rdma.cpp:944-961` 派生 flow_label from QPN ——**这是误记**。实际 `rdma.cpp:1132` 硬编码 `flow_label=0`，全仓 grep 无任何非零赋值（13 处都是 `=0` 或注释掉）。"UCCL 团队相信这会走多路径" 的假设在当前 tree 里不成立。 |
| **B2 (SL 分流) 该做吗** | **埋掉 —— 现有证据不足以justify 实测预算**。理由见 §3。 |
| **A1 (multi-QP PR #485) 和 flow_label 有重复收益吗** | **没重复**。flow_label 路径压根不生效，A1 的收益来自 SQ 并发，不是路径多样性。 |

---

## 1. EFA SL 字段：队列 vs tag

### 1.1 证据链（从 userspace 到 firmware）

**UCCL 写入点**：
- `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp:911`
  ```cpp
  if (use_ll_sl) efa_attr.sl = EFA_QP_LOW_LATENCY_SERVICE_LEVEL;
  ```
- `/home/ec2-user/workspace/uccl/ep/include/common.hpp:30`
  ```cpp
  #define EFA_QP_LOW_LATENCY_SERVICE_LEVEL 8
  ```
- `use_ll_sl` 在 `rdma.cpp:486/495/502` 基于 NIC 数量（p5=32 / p5en=16 / p6-b200=8）被设为 `true`；实际 EP 路径上 **全部 QP 都 SL=8**（三类 QP：data `S.qp`、`ack_qp`、`recv_ack_qp`，都走同一 `create_srd_qp_ex`）。

**rdma-core efa provider 写入点**：
- commit `cd3855442142c802dd93ad552b15e7b77f95d5d0`（2024-10-29, mrgolin@Amazon）"providers/efa: Add QP service level in EFA DV"
  - `verbs.c:~2358`：
    ```c
    req.sl = efa_attr->sl;
    ```
- `efadv.h` 结构（master）：
  ```c
  struct efadv_qp_init_attr {
      uint64_t comp_mask;
      uint32_t driver_qp_type;
      uint16_t flags;
      uint8_t  sl;
      uint8_t  reserved;
  };
  ```
  **sl 字段无任何注释**，man 页只写 "*sl*: Service Level - 0 value implies default level."
  man 页来源：rdma-core master `providers/efa/man/efadv_create_qp_ex.3.md`

**PR 描述 + reviewer 讨论**：rdma-core PR #1505（merged 2024-11-12）
- PR body 原文："Add SL parameter to EFA create QP direct verb and pass it to the kernel. Update Pyverbs and documentation accordingly."
- Jason Gunthorpe 的唯一实质评论是问"`efa_attr->sl` 默认为 0 是否安全"，mrgolin 回"现有 validation 会 catch reserved 非 0"。
- **没有任何语言描述 SL 的硬件语义**（queue / scheduler / QoS / VL / priority / traffic class），作者也没说。

**内核 driver（amzn-drivers `kernel/linux/efa/src/efa_verbs.c`, r2.13.0, 2024-10-30, commit e2cb1ae）**：
- commit message 原文："Using modify QP with AH attributes and IB_QP_AV flag set doesn't make much sense for connectionless QP types like SRD. Add SL parameter to EFA create QP user ABI and pass it to the device."
- 代码路径：
  ```c
  create_qp_params.sl = cmd.sl;            // userspace 直传
  err = efa_com_create_qp(&dev->edev, &create_qp_params, &create_qp_resp);
  ```
- `efa_com_cmd.c`：
  ```c
  create_qp_cmd.sl = params->sl;           // 再透传到 admin command
  err = efa_com_cmd_exec(aq, (struct efa_admin_aq_entry *)&create_qp_cmd, ...);
  ```
- Admin 结构 `efa_admin_create_qp_cmd`（`efa_admin_cmds_defs.h`）：
  ```c
  u16 uar;
  u8  sl;   /* Requested service level for the QP, 0 is the default SL */
  u8  reserved;
  u32 reserved2;
  ```
  **仅 "Requested service level for the QP, 0 is the default SL" 一句注释**，没有说映射到哪个硬件资源。

**uAPI 结构 `efa_ibv_create_qp`（`/usr/include/rdma/efa-abi.h:92-100`）**：
```c
struct efa_ibv_create_qp {
    __u32 comp_mask;
    __u32 rq_ring_size;
    __u32 sq_ring_size;
    __u32 driver_qp_type;
    __u16 flags;
    __u8  sl;
    __u8  reserved_98[5];
};
```

**kernel driver 里没有 SL-to-queue / SL-to-scheduler 的映射代码**。任务 prompt 里假设的 `efa_io_tx_meta_desc` 带 SL 字段的猜想 —— **amzn-drivers `efa_io_defs.h` 的 `efa_io_tx_meta_desc` 结构没有 SL 字段**（字段是：`req_id`, `ctrl1`, `ctrl2`, `dest_qp_num`, `length`, `immediate_data`, `ah`, `reserved`, `qkey`, `reserved2[12]`）。也就是说 SL **不会每包带**，是 QP 级别一次设定。

**IB Spec 参考**：IB Architecture Release 1.7 Vol.1 §9.6 (SL→VL mapping) 要求 subnet manager 在 switch 层维护 SL→VL map。**EFA 根本不跑 SM、不走 IB switch、是 L3/UDP 隧道进 Nitro**（SRD paper §III）——搬 VL 概念的前提不成立。

### 1.2 推论（明确标注"推论"）

**推论 A（高置信度）**：SL 在当前 r2.13.0 kernel + rdma-core master 组合里是 **firmware-opaque passthrough**，driver 和 userspace 都不理解语义，语义完全由 Nitro firmware 决定。

**推论 B（中等置信度）**：AWS libfabric 约定 **SL=0 = 默认、SL=8 = 低延迟**（`/prov/efa/src/efa.h` `#define EFA_QP_DEFAULT_SERVICE_LEVEL 0` / `#define EFA_QP_LOW_LATENCY_SERVICE_LEVEL 8`），触发条件是 `FI_TC_LOW_LATENCY` traffic class。这个"低延迟档位"在 firmware 侧**确实会改行为**，否则 libfabric 不会专门写 fallback 分支（libfabric 在 low-latency QP 创建失败时 fall back 到 SL=0 重试）。但改什么（独立 scheduler / 独立 batching / 不同 CC tuning / 不同 retry / 不同 spray 宽度）—— **UNKNOWN，AWS 没公开**。

**推论 C（低置信度）**：SL=8 vs SL=0 **不太可能是独立物理硬件 SQ**。证据链：
- 每 QP 有自己的 SQ ring（`efa_ibv_create_qp_resp.sq_db_mmap_key`），SQ 是 QP 属性不是 SL 属性
- admin 命令 `sl` 是 u8 `flags`-adjacent 字段，更像"行为 flag"而非"绑定到 HW queue 的索引"
- 如果 SL 选独立 HW SQ，UCCL 现在把 3 个 QP 全设 SL=8 会让它们在硬件上挤到同一个"低延迟"scheduler，这和"SL 分流"的假设冲突
- 但这只是推理，**不能排除 firmware 在 NIC 里维护"低延迟 priority class"**，让 SL=8 的 packet 在内部调度时抢跑（类似 DCTCP 的 PFC class）

### 1.3 结论

**SL=0 vs SL=8 不是"独立硬件调度器"**——证据不支持。**也不是纯软 tag**——libfabric 的 fallback 逻辑暗示 firmware 确实认 SL=8 做了某种低延迟优化。最准确的说法是 **"firmware 内部 QoS class，语义闭源、AWS 保留解释权"**。

**对 "signal QP SL=X, data QP SL=Y 分流"的影响**：
- 两个 QP 都走 Nitro，即便 SL 不同，也是**同一 Nitro VF / 同一物理端口 / 同一 spray pool 的子集**
- 没有任何 driver / hw doc 说 SL 不同 → 不同 SQ doorbell → 避免锁竞争
- P99 -5~-10µs 收益没有协议层证据支持，只是"试一下看看"——这是我们之前就已打回的"声称链"

---

## 2. GRH flow_label 是否被 Nitro ECMP 消耗

### 2.1 证据链（自底向上）

**内核 driver `efa_create_ah`（amzn-drivers `efa_verbs.c:3944-4013`, r2.13.0）关键段**：
```c
memcpy(params.dest_addr, ah_attr->grh.dgid.raw,
       sizeof(params.dest_addr));
params.pdn = to_epd(ibah->pd)->pdn;
err = efa_com_create_ah(&dev->edev, &params, &result);
```
**仅两行触 `ah_attr`**：
- `ah_attr->grh.dgid.raw` copy 到 `params.dest_addr[16]`
- `ah_attr->grh.dgid.raw` copy 到 `ah->id`（本地缓存，用于 lookup）

**没有**任何行读 `ah_attr->grh.flow_label` / `traffic_class` / `hop_limit` / `sgid_index` / `port_num`。

**admin command `efa_admin_create_ah_cmd`（`efa_admin_cmds_defs.h`）verbatim**：
```c
/*
 * Create Address Handle command parameters. Must not be called more than
 * once for the same destination
 */
struct efa_admin_create_ah_cmd {
    struct efa_admin_aq_common_desc aq_common_desc;
    u8  dest_addr[16];   /* Destination address in network byte order */
    u16 pd;
    u16 reserved;
};
```
**AH 传到 firmware 的数据只有 `dest_addr[16]` + `pd` + `reserved`**。flow_label 在 firmware 看到的 AH 描述里不存在。

**libfabric efa provider（AWS 官方软件）的做法**：
- `/prov/efa/src/efa_ah.c` 里 `ibv_ah_attr = { 0 }` 后只设 `port_num=1`、`is_global=1`、`memcpy(dgid...)`
- **不设 flow_label，不设 traffic_class** —— AWS 自己的 libfabric 都不用这两个字段
- 如果 flow_label 真进 ECMP hash，libfabric 会用它做 path diversity，但它没用

**UCCL 现状 grep**：
```
/home/ec2-user/workspace/uccl/**/flow_label = 0       13 处
/home/ec2-user/workspace/uccl/**/flow_label = <非 0>   0 处
```
任务 prompt 声称 `rdma.cpp:944-961` 派生 flow_label from QPN 是**误记**。`rdma.cpp:944-961` 实际是 QP → RTS 状态 + per-thread QP 创建 dispatch 代码，flow_label 在 `rdma.cpp:1132` 硬编码为 0。

**AWS 公开语料**：
- AWS SRD paper (IEEE Micro 2020 摘要)："sends the packets over as many network paths as possible, while avoiding overloaded paths" —— 没提 sender-controllable hash field
- AWS HPC blog "In the search for performance, there's more than one way to build a network"（2023）："SRD can push all the packets making up a block of data all at once, over all the possible pathways in our fabric (in practice, for memory reasons, we choose 64 paths at a time from the hundreds or even thousands available)" —— **明确说 64 paths 是 NIC 内部选，不是 sender 指定**
- AWS EC2 / EFA 官方 doc：0 处提 flow_label / ECMP / packet spraying 的 sender 控制方式
- rdma-core mailing list / GitHub issue 搜索"EFA flow_label" / "efa ah_attr" 0 个 AWS engineer 回帖说它有效

### 2.2 Nitro ECMP 入参

**没有公开文档**。可用证据反推：
- sender 写的 `ibv_ah_attr` 中只有 `dgid` 到达 firmware（§2.1 证据）
- Nitro 拿到的 per-packet 信息 = `efa_io_tx_meta_desc` 字段（§1.1 列过）：`req_id, ctrl1, ctrl2, dest_qp_num, length, immediate_data, ah, reserved, qkey, reserved2[12]`
- 里面**没有 flow_label**，**没有 sender-supplied hash seed**
- Nitro spray 用什么做 hash —— SRD paper 和 AWS doc 都没披露，**推测**（但无源码证据）是：内部 path-id 轮转 + per-packet 随机，和 sender 完全无关

### 2.3 结论

**flow_label 是彻底的死字段**：
- kernel driver `efa_create_ah` 连读都不读
- admin command 里没位置放
- Nitro firmware 不可能从 sender 拿到这个值
- AWS 自己的 libfabric 也不用
- UCCL 把它设 0 是**正确的**（设什么都没区别）

**hash 字段是否也包括 src/dst QP number**：**UNKNOWN**。`efa_io_tx_meta_desc.dest_qp_num` 倒是每包带到 firmware，理论上 Nitro **可以**把它塞 hash，但无公开证据。这意味着 "多 QP → 多路径" 的假设也无源码证据，只是"常识猜测"。SRD_PROTOCOL_DEEP_DIVE §3 表项 #4 写的"多 QP 真实价值是 SQ 并发" 恰好与此一致——**不要依赖 "多 QP 天然多路径" 的假设**。

---

## 3. 对已有 lever 的判定

### 3.1 B2（SL 分流：signal QP vs data QP 不同 SL）

**判定：埋掉**。

**理由**：
1. **证据不支持"独立硬件队列"假设**（§1.3）——SL 是 firmware-opaque QoS class，不是独立 SQ scheduler
2. **当前 UCCL 已经全 SL=8**（`rdma.cpp:911` + `use_ll_sl` 三处触发点 = p5/p5en/p6-b200 全覆盖）。要做"分流"，等于把 data QP 降到 SL=0 —— libfabric 的 fallback 逻辑暗示 SL=0 < SL=8 在延迟上，这是**负收益风险**
3. **P99 -5~-10µs 是凭空数字**。没有任何协议文档 / benchmark / paper 支持这个量级。`FEASIBILITY_RECONFIRM` 已经把这个"声称链"砍掉过一次，本次复核**再次确认**砍掉
4. **实测代价 vs 不确定性**：即便做 2 天 bench，可能性是 (a) 没差异 (b) 负收益 (c) 微正收益 (d) 噪声内。只有 (d) 下才可能"看着有收益但不可靠"

**唯一值得做的 SL 相关探查**（5 分钟零风险）：加 printf 确认 runtime 上 `use_ll_sl=true`（应该是）+ `efa_attr.sl=8` 真的生效。不是优化，是 sanity check。

### 3.2 A1（multi-QP，PR #485）vs flow_label 分流

**判定：不重复**。

**理由**：
1. flow_label 分流**不生效**（§2.3），所以谈不上"重复收益"——flow_label 根本没收益
2. PR #485 的收益来源是 **SQ 并发 + doorbell concurrency**（同 `SRD_PROTOCOL_DEEP_DIVE §3 #4` 结论）——每个 QP 有独立 `sq_db_offset`（`efa_ibv_create_qp_resp`），多 QP 真能让多个 CPU 线程同时 `ibv_post_send` 不挤 doorbell 锁
3. "多 QP → 多路径"的副作用 —— 无证据（§2.2），但就算 Nitro 真把 `dest_qp_num` 放 hash，PR #485 也会自然带上这个副作用，不需要额外 flow_label 补刀

**副产物观察**：如果未来 PR #485 merge 后 bench 发现 p50/p99 降的幅度远超"SQ 并发"能解释的量级，那就是 Nitro 真的用了 QP number 做 hash ——到时再决定要不要做 flow_label UNKNOWN 实验。现在不做。

---

## 4. 如果真要实测，怎么 1 天拿结果

前置定性结论说 **不值得做**。如果 owner 仍要做，这里给 1-day 最短路径（只为对齐流程；我的建议是用这 1 天去做 S0 `efadv_query_device` dump，价值高 10 倍）。

### 4.1 SL 隔离实测（0.5 天）

**目的**：确认 SL=8 vs SL=0 vs 混合时延差异。

**实验矩阵**：
| case | data QP sl | ack QP sl | recv_ack QP sl |
|------|-----------|-----------|----------------|
| C0 | 8 | 8 | 8 |（baseline，当前）
| C1 | 8 | 0 | 0 |（signal 降 SL，data 保持）
| C2 | 0 | 0 | 0 |（全默认）
| C3 | 0 | 8 | 8 |（signal 升 SL，data 降）

**改法**：`rdma.cpp:911` 改成读 env `UCCL_DATA_SL` / `UCCL_ACK_SL`，3 个 QP 分开设。
**测什么**：跑现有 EP alltoall bench（`ep/bench/alltoall/benchmark.cpp`），统计 dispatch/combine P50、P99、P99.9（各 10 k iter）。
**判据**：C1 vs C0 如果 P99 差 < 2 µs 且**稳定**（3 轮一致），说明 SL 分流没用；差 > 5 µs 且方向正确（C1 低于 C0），才值得做主线集成。
**时间**：3-5 min per case × 4 case × 3 repeat = ~1 h bench + 2 h setup + 3 h 分析。

### 4.2 flow_label 实测（0.5 天）

**目的**：确认 flow_label **真的**没影响（我的判断是死字段，但如果 owner 要 paper trail）。

**改法**：`rdma.cpp:1132` 加 env `UCCL_FLOW_LABEL`，三个 case：`0`、`hash(local_qpn ^ remote_qpn) & 0xFFFFF`、`random_per_AH`。
**测什么**：同 4.1。
**预期**：三者**完全相同**（driver 根本不读 §2.1）。
**时间**：1 h。
**如果竟然有差异** —— 说明我对 driver 代码的阅读有问题，回头去 git blame `efa_create_ah` 过去 2 年修改，尤其是 efa_p2p.c / efa_com_cmd.c 里 AH 相关 path。

### 4.3 我的强烈建议：换 S0

**不要拿这 1 天测 SL/flow_label**。拿去做 `SRD_PROTOCOL_DEEP_DIVE §1` 已经定的 S0：`efadv_query_device` dump p5en / p6-b200 / p6-b300 caps，解锁 L1/L2/L3/L4/L6 共 6 条 lever。ROI 差距至少 10×。

---

## 5. 证据完整性声明

**已查**：
- amzn-drivers master `kernel/linux/efa/src/efa_verbs.c` / `efa_com_cmd.c` / `efa_admin_cmds_defs.h` / `efa_io_defs.h` / `efa-abi.h` / `SRD.txt` / `RELEASENOTES.md`
- rdma-core master `providers/efa/verbs.c` / `efadv.h` / `man/efadv_create_qp_ex.3.md`
- rdma-core PR #1505 (mrgolin@Amazon, 2024-11-12)
- amzn-drivers commit e2cb1ae (kernel r2.13.0, 2024-10-30)
- libfabric main `prov/efa/src/efa_ah.c` / `efa_base_ep.c` / `efa.h`
- AWS HPC blog + IEEE Micro SRD 摘要（full PDF 被 Amazon Science 站挡了 403，用摘要代替）
- UCCL tree 全仓 grep `flow_label` / `service_level` / `efa_attr.sl`

**未拿到**（UNKNOWN 明确标出）：
- Nitro firmware 内部 SL 映射表（AWS 不公开）
- Nitro ECMP hash 算法具体输入（AWS 不公开）
- SL=8 触发哪些 firmware 行为（libfabric 暗示存在，但无描述）
- `dest_qp_num` 是否进 hash（推测有可能，无证据）

**不盲信之前 agent 的点**：
- `SRD_PROTOCOL_DEEP_DIVE §3 #1` 写 "SRD 不读 `flow_label`（但 Agent 1 从 SIGCOMM paper ll.122-124 发现 sender 可以通过修改 encap 控制 path，所以其实 flow_label 可能有效——UNKNOWN）" —— 本次调研**不支持这个 UNKNOWN**。有 kernel driver 代码证据（`efa_verbs.c:3989` 只读 dgid），`flow_label` 根本到不了 firmware，sender 无法通过 `ibv_ah_attr` 控制。Agent 1 的推论应该撤回（或他看的是不同代码路径，在当前 r2.13.0 driver 里该推论不成立）。
- 任务 prompt 的"`rdma.cpp:944-961` 填 GRH flow_label，从 QP 编号派生" —— **错**。实际代码在 `:1132` 硬编码 0，全仓无派生逻辑。建议 MEMORY 订正。

**不编的点**：
- SL 硬件队列具体实现、Nitro 内部 spray 算法、SL=8 具体 firmware 副作用 —— 标为 UNKNOWN，不给猜测数字

---

## 6. 一句话结论

**SL 是 firmware-opaque（保留 SL=8 现状即可，不做分流实验）；flow_label 是死字段（driver 连读都不读，0 或非 0 无差异）**。B2 lever 应从 roadmap 埋掉，那 1 天预算应投到 S0 `efadv_query_device` dump。
