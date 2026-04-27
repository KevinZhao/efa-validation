# EFA SRD 协议层深挖：UCCL-EP 漏用的真实 lever

> 🔧 **2026-04-26 Part 2 订正** — 本文档是 Part 1。Part 2 (`docs/SRD_PROTOCOL_PART2.md`) 用 3 个独立 agent 攻破了本文留的 8 个 UNKNOWN，对以下条目有**重大订正**：
> - **`CQ_WITH_EXT_MEM` bit 号 7 → 5**，且是 DMABUF-specific（L1 从通用 external memory 降为 DMABUF-only）
> - **`DATA_POLLING_128` userspace efadv.h 未暴露**（L6 实施风险 ↑）
> - **`INLINE_WRITE` 不是 device_cap bit**，是 QP flag + `efadv_get_max_sq_depth` 配合（L2 调用链订正）
> - **`max_rdma_size` ~1 GB，UCCL-EP 不受限 → L7 永久删除**
> - **`flow_label` 彻底死字段**（§3 表 #1 UNKNOWN 撤回）
> - **SL firmware-opaque** → B2 SL 分流永久埋掉
> - **L1 原理可行但降级 Sprint D**（amzn-drivers commit 866f9d3 明确写 "accelerator direct polling"，但工程链 4-6w）
> - **新 L9 shared-SRD-QP 是 AWS 独占 lever**（Mooncake #1944 思路移植）
>
> 结论和 lever 排序以 **Part 2 为准**。本 Part 1 文档保留作历史。

**日期**：2026-04-26
**调研方式**：3 个并行 agent 独立读权威源（SIGCOMM 2020 SRD paper + Linux efa-abi.h + rdma-core efadv.h + UCCL-EP 源码）
**准则**：遵守 `feedback_claim_verification_discipline.md` 四条——所有声称必须锚源头，未找到证据的标 **UNKNOWN**

---

## 0. 三个 agent 的交叉验证结论

| Agent | 角度 | 核心发现 |
|---|---|---|
| Agent 1 (协议规范 + 硬件边界) | SIGCOMM paper + efa-abi.h | **UCCL-EP 完全不调 `efadv_query_device`**，10+ 个 efadv API 没用，硬件能力 caps bit 7 项（CQ_WITH_EXT_MEM、DATA_POLLING_128、RDMA_READ...）全没用 |
| Agent 2 (拥塞 + spray + 尾延迟) | Nitro path 机制 | 协议层**几乎没有 lever**，订正 10 个误区（flow_label/ECN/retry 全是死代码；1/16 collapse 数字在 paper 里找不到） |
| Agent 3 (软件栈边界) | efadv.h + libibverbs | `EFADV_QP_FLAGS_INLINE_WRITE` flag 存在——**可能推翻"max_inline_data=0 是硬约束"的旧结论** |

三个 agent **独立得出同一个高层结论**：
- 应用层可控的 SRD 协议 knob 几乎没有（Nitro 黑盒）
- 真正的 lever 是"**UCCL-EP 没查硬件能力**"——很多 API 没用
- **核心前置动作**：1 天写一个 `efadv_query_device` probe，dump p5en/p6-b200/p6-b300 真实能力，之后所有 lever 才能做

---

## 1. Stage 5 必须先做的 1 天实测

**唯一的"进入其他 lever 的钥匙"**：

```cpp
// 在 rdma.cpp:884 create_srd_qp_ex 里第一行加
struct efadv_device_attr attr = {};
efadv_query_device(context, &attr, sizeof(attr));
fprintf(stderr, "[EFA-CAPS] max_sq_wr=%u max_sq_sge=%u inline=%u "
                "max_rdma_size=%u max_tx_batch=%u caps=0x%x\n",
        attr.max_sq_wr, attr.max_sq_sge, attr.max_inline_buf,
        attr.max_rdma_size, attr.max_tx_batch, attr.device_caps);
```

**dump 存 `results/stage5-p5en/efa_caps/p5en-<date>.txt`**，决定以下 8 个 UNKNOWN：

| UNKNOWN | 决定哪些 lever |
|---|---|
| `max_sq_sge` 真实值 | L1 gather/scatter WR |
| `inline_buf_size` 真实值 | L2 Inline Write for ACK |
| `device_caps & CQ_WITH_EXT_MEM` | L5 CQ 放 GPU BAR |
| `device_caps & DATA_POLLING_128` | L6 batch poll 128 CQE |
| `device_caps & INLINE_WRITE` | **推翻 feedback 条款 4** |
| `max_rdma_size` | L7 单 WR 最大 payload |
| `max_tx_batch` | L8 硬件批处理对齐 |
| SL 物理隔离（实测 bench）| B2 SL 分流 |

**工作量 1 天，无风险，产出权威数据**——这是整个 EFA 路径的 S0。

---

## 2. 真正可挖的新 lever（不重复 FEASIBILITY_RECONFIRM）

### 🏆 L1 · CQ with External Memory (GPU BAR)

**协议特性**：`EFA_QUERY_DEVICE_CAPS_CQ_WITH_EXT_MEM` (bit 7, `efa-abi.h:134`)。CQE ring 可以放在用户提供的内存（可能是 GPU HBM / DMA-BUF），GPU kernel 直接 poll。

**UCCL 当前**：`rdma.cpp:867` 走 stock `ibv_create_cq_ex`，CQE 在 host DRAM，CPU proxy 轮询。

**收益**：SBO Sprint B "CPU spin" 的**硬件级替代方案**。CQE 放 GPU HBM 后：
- combine kernel 可以 GPU-native poll，不需要 CPU proxy 中转 signal
- 一次 PCIe DMA + doorbell MMIO 省掉

**但有冲突**：这和 SBO Sprint B 的"把 signal 从 GPU 挪到 CPU"**方向相反**——L1 是"把 CQE 从 CPU 挪到 GPU"。两条路只能选一：
- **Sprint B 路线**：用 SPSC queue 在 CPU poll signal，释放 3 个 combine SM 给 DeepGemm
- **L1 路线**：CQE 直接给 GPU poll，combine kernel 自己等

**决策依据**：需要 p5en 实测 "CPU poll latency vs GPU poll latency" 二元 bench。

**DeepEP NVIDIA 能做吗**：NO——mlx5 有 DEVX 可做类似事但 NCCL/DeepEP 没暴露，EFA 这条路径是我们独占。

**UNKNOWN**：`CQ_WITH_EXT_MEM` 具体语义未明（GPU BAR 支持吗？用户 host 内存也算？）——S0 实测后才能定。

**复杂度**：MEDIUM，2-3 周原型。

---

### 🥈 L2 · Inline Write for ACK & atomic imm (EFADV_QP_FLAGS_INLINE_WRITE)

**协议特性**：rdma-core master `efadv.h`:
```c
enum {
    EFADV_QP_FLAGS_UNSOLICITED_WRITE_RECV = 1 << 0,
    EFADV_QP_FLAGS_INLINE_WRITE           = 1 << 1,  // ← 新 flag
};
```

**UCCL 当前**：`rdma.cpp:899` `max_inline_data = 0` 写死。

**重大影响**：**推翻 `feedback_claim_verification_discipline.md` 条款 4 的认知**——"SRD 强制 max_inline_data=0" **只在不开 INLINE_WRITE flag 时成立**。我们之前用这条硬约束驳回过 B2、P4、A2 的 inline 相关声称——**如果这个 flag 真能用，那些驳回要重新审视**。

**UCCL 当前代码**：
- ACK send `SEND_WITH_IMM` payload=0 (`rdma.cpp:2725`)，走 SGE+DMA 而不是 inline
- 小 AMO imm 也走 SGE

**收益**：ACK 每次 send 省一次 DMA read ≈ 0.5-1 µs。decode 每 token 的 ACK 帧累计可观。

**DeepEP NVIDIA 能做吗**：Mellanox 普通 verbs 有 `IBV_SEND_INLINE`，但 EFA 这条必须走 efadv flag。NVIDIA 不需要，但 UCCL 当前也没用上——这是 **AWS-only 贡献**，符合 `feedback_uccl_pr_aws_bench` 定位。

**前置**：S0 确认 `device_caps & INLINE_WRITE` 为真 + `max_inline_buf ≥ 32` 才能做。

**复杂度**：LOW（代码改动 <100 行）。

---

### 🥉 L3 · Runtime caps query (`efadv_query_device`)

**协议特性**：EFA uAPI 要求 runtime 查询 NIC 能力，不能硬编码。

**UCCL 当前**：grep 全仓 0 命中——**完全不查**，所有 caps 按 "conservative floor" 硬编码。

**影响**：`kMaxOutstandingSends=2048`（`common.hpp:79`）、`max_send_sge=1`（`rdma.cpp:897`）、`max_inline_data=0`（`:899`）都可能低于 NIC 真实能力。

**直接收益**：无（只是消除技术债），但**解锁 L1/L2/L4/L7/L8 所有依赖 caps 的 lever**。

**复杂度**：1 天。

---

### L4 · `max_sq_sge ≥ 2` 合并 DMA-BUF chunk-straddle

**协议特性**：`efadv.max_sq_sge` 可能 ≥ 2（p5en 上 UNKNOWN 实际值）。

**UCCL 当前**：`rdma.cpp:897` 写 1。`rdma.cpp:1562-1586` 跨 1 GiB DMA-BUF chunk 时被迫发 2 个 sub-WR + signal 链。

**收益**：消除跨 chunk 的 2-WR 模式，未来还能 gather small count + payload fuse WR。

**前置**：S0 确认 `max_sq_sge ≥ 2`。

**复杂度**：MEDIUM。

---

### L5 · Count-send 改 `RDMA_WRITE`（无 IMM）

**协议特性**：SRD 支持 plain `RDMA_WRITE`（`EFA_QUERY_DEVICE_CAPS_RDMA_WRITE` bit 5）。

**UCCL 当前**：count-send 用 `RDMA_WRITE_WITH_IMM`（`rdma.cpp:3033`），imm 位编码 seq + payload。

**这是 ALLTOALL_DEEP_DIVE §4.1 方案 A 的协议层实现**：
- 用 plain `RDMA_WRITE` 把 16 个 expert 的 count 一起写到对端 cacheline
- 再发 1 个 summary IMM 做信号
- 从 16 AMO-chain-WRITE_WITH_IMM → 1 WRITE + 1 IMM

**收益**：≤5 µs/layer（同 ALLTOALL_DEEP_DIVE）。

**前置**：必须等 PR #485 merge（multi-QP 会改 AMO post 分布）。

**复杂度**：MEDIUM，3-5 天。

---

### L6 · `DATA_POLLING_128` 批量 CQE poll

**协议特性**：`EFA_QUERY_DEVICE_CAPS_DATA_POLLING_128` (bit 4)，CQE ring 可以一次 poll 128 entry。

**UCCL 当前**：`rdma.cpp:2130-2152 poll_cq_once` 逐个 poll。

**收益**：proxy CPU 负载 -N%（具体数字 UNKNOWN），和 A2 `selective signaling` 驳回后的唯一 CPU 节省路径。

**前置**：S0 确认 caps bit 4。

**复杂度**：LOW。

---

## 3. 10 个需要订正的误区清单（Agent 2 原文）

| # | 旧说法 | 真相 |
|---|---|---|
| 1 | `flow_label` 影响 Nitro spray | SRD 不读 `flow_label`，hash 用 Nitro 内部 path-id（**但 Agent 1 从 SIGCOMM paper ll.122-124 发现 sender 可以通过修改 encap 控制 path，所以其实 flow_label 可能有效——UNKNOWN，待 L2 bench 定论**） |
| 2 | `traffic_class`/ECN 能调 CC | SRD CC 不用 ECN，`traffic_class=0` 是死代码 |
| 3 | `retry_cnt=7 rnr_retry=7` 控制 EFA 重传 | RTS modify 整段对 EFA 提前 return（`rdma.cpp:1282`） |
| 4 | 多 QP 增加 path 多样性 | Nitro path 独立于 QP 数；多 QP 真实价值是 **SQ 并发** |
| 5 | `kReorderingBufferSize=16` 会溢出 | Stage 5 实测零溢出 |
| 6 | "1/16 collapse" = SRD 带宽 1/16 | **Agent 1 在 SIGCOMM paper 里找不到这个数字**，origin unclear，UNKNOWN |
| 7 | combine 47 µs 差 20 µs 不明 | `ibv_post_send` per WR 2-5 µs × top-8 fan-out = 16-20 µs 正好吃掉 |
| 8 | 降 EFA MTU 可优化 | MTU 是 NIC attribute，不是 QP 可改 |
| 9 | 应用层可控 SRD CC | SRD CC 在 Nitro 内部 |
| 10 | SRD 可做 tail hedging on same QP | reorder buffer 依赖 seq 单调不容忍 dup |

---

## 4. 关键冲突：L1 和 SBO Sprint B 互斥

**必须做出的决策**：

| 路线 | 机制 | 优势 |
|---|---|---|
| **SBO Sprint B** | signal 从 GPU 挪到 CPU proxy（用 SPSC queue）| 释放 3 SM 给 DeepGemm |
| **L1 CQ_WITH_EXT_MEM** | CQE 从 CPU 挪到 GPU HBM（GPU 直接 poll）| 省一跳 PCIe |

**两条路不能同时生效**——CQE 位置决定 poll 在哪一侧。

**决策依据**：S0 后在 p5en 跑二元 bench：CPU poll 延迟 vs GPU poll 延迟。哪条短走哪条。

---

## 5. 修订后的整体 roadmap（合并 SBO + FEASIBILITY + SRD 本轮）

### Sprint 0 · 实测 caps（1 天）
- 改 `create_srd_qp_ex` 加 `efadv_query_device` dump
- p5en / p6-b200 / p6-b300 各跑一次
- 结果 push 到 UCCL 上游作为 issue（"AWS EFA caps dump for UCCL dev use"）—— AWS-bench 权威贡献

### Sprint 1 · 已定的稳态 decode 优化（不变）
1. SBO Sprint A (2w)
2. PR #485 rebase + p5en bench (3-5 d)
3. count-send coalescing via L5 (3-5 d, 必须 #485 后)

### Sprint 2 · 新 EFA 特性 lever
4. L2 Inline Write for ACK QP (LOW, 1 周)
5. L3 `efadv_query_device` 基础设施 (1 天, 已在 S0)
6. L6 DATA_POLLING_128 (LOW, 3-5 d)

### Sprint 3 · 二元决策分叉
**基于 S0 + "CPU poll vs GPU poll" bench 结果二选一**：
- 分支 A: SBO Sprint B (CPU spin, 1.5 w)
- 分支 B: L1 CQ_WITH_EXT_MEM (GPU poll, 2-3 w)

### 不做
- L2 flow_label experiment（UNKNOWN 太多，1 周 bench 完成不值得）
- L4 max_sq_sge（DMA-BUF chunk-straddle 场景小）
- Multi-AH hedging（收益不确定）
- 所有 SRD 协议 knob（Nitro 黑盒）

---

## 6. 对 feedback 规则的新补充

### 建议修订 `feedback_claim_verification_discipline.md` 条款 4

**原条款 4**：
> EFA 硬件约束必须从 `uccl/ep/src/rdma.cpp:884-964` SRD QP 创建代码读，不能假设"应该能配"。已知硬限：`sq_sig_all=1` 强制 signaled、`max_inline_data=0` 写死...

**修订为**：
> EFA 硬件约束必须从 `efadv_query_device` 运行时查询 + `rdma.cpp:884-964` SRD QP 创建代码交叉验证。**代码硬编码 ≠ 驱动硬约束**：
> - `sq_sig_all=1` 是驱动级硬约束（SRD QP 必须）
> - `max_inline_data=0` **不是硬约束**——`EFADV_QP_FLAGS_INLINE_WRITE` flag 可解锁
> - `max_send_sge=1` **不是硬约束**——runtime caps 可查
> - `max_rdma_size` 必须 runtime 查，不能假设
> 任何声称依赖"硬限"的 lever 必须先跑 `efadv_query_device` 验证。

---

## 7. 关键引用

**权威源**（按证据强度）：
- `/usr/include/rdma/efa-abi.h`（Linux kernel uAPI，最权威）
- `rdma-core master providers/efa/efadv.h`（userspace API）
- Shalev et al., "A Cloud-Optimized Transport Protocol..." IEEE Micro 2020
- amzn-drivers EFA RELEASENOTES

**UCCL-EP 关键行**：
- `rdma.cpp:884-953` SRD QP 创建
- `rdma.cpp:897-899` 硬编码 sge=1 / inline=0
- `rdma.cpp:903` sq_sig_all=1 (driver forced)
- `rdma.cpp:914` UNSOLICITED_WRITE_RECV (已用)
- `rdma.cpp:1132` flow_label=0
- `rdma.cpp:1282` EFA 路径提前 return
- `rdma.cpp:2130-2152` poll_cq_once
- 0 grep `efadv_query_device` 命中

**基线实测**（post-PR #745）：
- dispatch both p50 174.9 µs, combine both 326.7 µs on p5en 2-node 16-GPU
- Stage 5 grep "duplicate seq" 零命中（reorder window 充足）

---

## 8. 一句话结论

**SRD 协议层对 UCCL 基本是黑盒，真实 lever 全在"UCCL 没查 EFA 硬件能力"这件事上**。S0（1 天 `efadv_query_device` dump）是进入其他 lever 的钥匙，不做 S0 谈不了 L1/L2/L4/L5/L6。SBO Sprint A + PR #485 + count-coalescing 仍是主线，SRD 新 lever 都是锦上添花（Sprint 2/3 级别）。
