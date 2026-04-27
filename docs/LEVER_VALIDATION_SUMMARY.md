# Phase 16 · Lever 价值真实性核查综合报告

**日期**：2026-04-26
**方法**：3 个独立 validator agent（V1/V2/V3）挑战已有结论，**不盲信前 phase 推导**
**触发动机**：15 phase 累积声称 decode ITL -10~-15%，但 "µs × layer = %" 推导有放大误差风险
**子文档**：`LEVER_VALIDATION_TIER1.md` / `LEVER_VALIDATION_TIER2.md`
**V3 状态**：超时失败（prompt 过大），本文档用其余信息 + MEMORY 硬规则合成补做

---

## 0. 最重要的结论（一页版）

### 原声称 vs 核查后

| 维度 | Phase 15 声称 | Phase 16 核查后 |
|---|---|---|
| Tier 1 + Tier 2 全做 decode ITL | **-15~-20%** | **-4~-9%**（single-AZ 生产场景） |
| 最高 ROI 单条 Sprint A | -5~-8% | **-3~-6%**（H20→H200 折 0.4-0.7×） |
| 累积 PR 数（值得做） | 14 条 | **3-4 条**（其余或 drop 或降 Tier 3） |
| 本周必做时间 | 3 天 instrumentation | **4 天 Sprint 0**（加 overlap 窗口 + NIC skew 实测）|

### 5 条 lever 被颠覆

| Lever | 颠覆原因 | 处置 |
|---|---|---|
| **PR #485 multi-QP** | **UCCL-EP LL 路径早已多 QP**（`num_qps_per_rank = num_experts/num_ranks`）；PR #485 DRAFT 6 个月没动无数据 | **DROP** |
| **G-01 AIMD pacer** | commit 92b96373 叙事**误读**（是 WIP 清理次日 PR #703 重加），但 single-AZ 硬规则 → 收益 0 | **降 Tier 3 + 条件化** |
| **L11 launcher-cache** | CUDA Graph 默认 on，60-180 µs 已摊销为 0 ITL | **转 TTFT lever** |
| **L9 reduce prefetch** | 基于 num_tokens=128，decode batch=1 实际 num_combined_tokens≈1 | **-1~2% → 0.3-0.7%** |
| **L8 count-send coalescing** | µs × 58 layer / 50 ms 算数错误：0.58% 不是 2-3% | **-2~-3% → -0.5~-1%** |

### 3 条 lever 保留但大幅下调

| Lever | 原 | 修订 | 原因 |
|---|---|---|---|
| Sprint A (L1) | -5~-8% | **-3~-6%** | H20→H200 dense compute 6.7×，overlap 窗口缩 1/6 |
| C17 PER_EXPERT_BATCHING | "2× dispatch" | **dispatch -20%，combine 0%，decode ITL -1~-3%** | PR #745 实测 dispatch both 218.56→174.90 µs；"2×" 是 PPLX baseline 归因错 |
| C14 P-of-2 LB | P99 -5~-10% | **decode 1-2% / prefill 3-7%** | 推导 |

### 3 条 lever 降 Tier（非 0 但次要）

- **Sprint B CPU spin**：-3~-5% → **<-1%**（"3 SM 释放"是从 DeepEP env 套用，UCCL 实际是 36-72 SM）
- **G-02 Dynamic NIC LB**：+5~15% → **healthy 0% / skew 观察下 5-10%**，且工期 7-10d 不是 3-5d
- **L9 Shared-SRD-QP**：p5en EP=32 已证明无触顶（PR #766），**Blackwell 解锁而非性能**

---

## 1. Agent V1 · Tier 1 旗舰核查

### 1.1 Sprint A 的 H20→H200 折扣

**核心推理**：
- SBO 收益 = **Down GEMM 计算 ∩ combine 通信** 的 overlap 窗口
- H20 FP16 = 148 TFLOPS；H200 FP16 = 989 TFLOPS (**6.7× dense**)
- H20 上 GEMM 是 bottleneck（PR #9660 明说 "low-compute-power card"）→ overlap 窗口 = 通信时间
- H200 上 GEMM 快 6-7×，compute 窗口压缩到 1/6 → overlap 窗口上限 = compute 时间
- **H20 -7.9% 在 H200 上物理上应当是 1/4 - 1/2 的收益 → -2~-4%**

**证据**：SGLang PR #9660 motivation 原话："The optimization effect of Two-Batch Overlap (TBO) is suboptimal for the Decode phase on low-compute-power cards (i.e., H20)"——作者自己承认 **H20 特化**。

**Blocker**：DeepGEMM PR #183 **OPEN 8 个月** + DeepEP PR #390 **closed not merged**——L1 producer 端不在上游。必须 pin `Sulfur6/DeepGEMM#sbo.v2.sgl + deepseek-ai/DeepEP@antgroup-opt`，上游 breakage 风险高。

**保留原因**：协议层面对齐是不可替代的 unlock work；即使收益缩水，没做的话 comp_signal 代码在 UCCL-EP 上是 dead code。

### 1.2 PR #485 的归因错误

**关键事实（V1 挖到的）**：
- `ep/bench/test_low_latency.py:482`: `num_qps_per_rank = num_experts // num_ranks`
- `ep/bench/test_low_latency_pplx.py:741`：同上
- `ep/src/rdma.cpp:997-1017`：`data_qps_by_channel` 已建 8 QP
- **LL 路径已是多 QP**

PR #485 的真实语义 = 让 LL 路径**不只用 S.qp，而是用 data_qps_by_channel** — 是个合理的 small refactor，但声称的 "多路径 -3~-5%" 归因完全错。

**推论收益**：SQ 并发收益 per-WR 200-500 ns × 并发度 4 = 0.6-1.5 µs/peer。decode ITL 量级 < 0.5%。

**作者 MaoZiming 6 个月不动最强负面信号** = "他自己测了没显著收益或有 regression"。

### 1.3 G-01 的叙事被推翻

**Git log 还原**：
```
27058a00 Add experimental flow control              ← 加
92b96373 Remove experimental flow control           ← 同日 2 小时后清 WIP（被误读为"作者失败"）
58b113d0 Remove flow control                        ← 同日继续清
549651d9 Add separate flow control                  ← 次日重加
...
3af0d38d [P2P] flow control and fix high latency (#703)  ← PR #703 merge，flow control 活着
```

**真相**：92b96373 不是"作者测完删"，是 refactor WIP 清了再重做。PR #703 body 关键一句："**LOG(INFO) was causing most of the delay**"——删的是 log，不是 flow control。

**当前状态**：
- `ep/include/common.hpp:72` `kMaxInflightBytes = SIZE_MAX`（无限）
- `p2p/rdma/rdma_connection.h:401-409` `kInFlightMaxSizeKB = 10 GB`（几乎无限）
- **EP 路径几乎没 CC**，G-01 的本质 = **从 0 开始做**，不是"重启被删代码"

**但**：single-AZ 硬规则下，healthy fabric 没 CC 和有 AIMD 差别 ≈ 0。**降 Tier 3 条件化**。

### 1.4 Sprint B "3 SM 释放" 归因错

- SGLang env `SGLANG_DEEPEP_LL_COMBINE_SEND_NUM_SMS=3` 是 DeepEP IBGDA 路径数字
- UCCL-EP 走 CPU-proxy FIFO，`uccl_ibgda.cuh:36` 的 `lane_id != 0 return` 让 31/32 lane 本来就闲
- 实际 UCCL-EP combine `num_sms = ceil_div(num_experts, num_warp_groups)` = **36-72 SMs**（288 experts / 2-4 wg）
- "3 SM 释放给 DeepGemm"是从 DeepEP 借的数字，UCCL-EP 物理意义完全不同
- H200 bs=1-16 DeepGemm 未 saturate SM，多 2-3 SM 边际 ≈ 0
- **收益 < -1%**，主要 value 是 tail 抖动降低

---

## 2. Agent V2 · Tier 2 核查

### 2.1 四条贯穿全文的数字误区

V2 找到的系统性错误（Phase 3-15 多个 agent 都犯过）：

1. **Bench num-tokens=128 直接套 decode batch=1** —— 差 16-128 倍
2. **µs × layer / 50 ms 算错** —— 3-5 µs × 58 layer = 290 µs = **0.58% 不是 2-3%**
3. **忽略 CUDA Graph 摊销** —— SGLang 默认 on，所有 host API 开销 → 0
4. **"CPU 省时间 = ITL 改善"** —— CPU proxy 异步，不在 critical path

### 2.2 Tier 2 具体修订

| Lever | 原声称 | 修订 | 根因 |
|---|---|---|---|
| L8 count-send coalescing | -2~-3% | **-0.5~-1%** | 算数错：10-30 µs × 58 = 0.58-1.7% 上限 |
| L9 reduce prefetch | -1~-2% | **0.3-0.7%** | bench 用 num_tokens=128，decode 实际 ≈ 1 |
| L10 unordered_map→array | -1~-3% | **prefill -1~-2% / decode 0%** | CPU proxy 异步，不在 critical path |
| L11 launcher-cache | 0.3-1% | **0% ITL / TTFT** lever | CUDA Graph 已摊销 |
| L12 launch_bounds(2) | -2~-5% | **HOLD** 需 PTXAS reg dump | `TODO: too many regs` 暗示 spill 风险 |
| L13 Sprint C Blackwell | -3~-5% | KEEP (p6-b300 blocked) | — |
| L14 P-of-2 LB | P99 -5~-10% | **decode 1-2% / prefill 3-7%** | 推导 |

### 2.3 累积收益订正

- 原 Tier 2 合计声称 **-8~-14%**
- 修订后 **-2~-4%**（全做）

### 2.4 本周实测建议（V2 提出）

2.5 天解锁 6/7 lever 真实 ROI：
1. CUDA Graph vs eager launcher overhead profile（0.5d）→ 验证 L10/L11
2. `clock64()` per-phase 埋点测 reduce 实际 µs（1.5d）→ 验证 L9
3. `nvcc -Xptxas -v` dump reg usage（0.5d）→ 决定 L12 可行性

---

## 3. V3 补做（小 scope）· MEMORY 硬规则对场景的颠覆性影响

V3 超时，但其核心质疑——**场景适配性**——可以用 MEMORY 新增规则直接验证：

### 3.1 致命场景矛盾

**MEMORY 第 14 行**：`所有测试机器必须同 AZ（硬规则，无例外）`
**MEMORY 第 10 行**：`硬规则：所有模型权重一律从 S3 加载`
**MEMORY 第 15 行**：`PD-disagg 必须同 AZ（跨 AZ Mooncake KV 会挂）`

对 lever 的影响：

| Lever | 依赖场景 | 我们实际场景 | 收益 |
|---|---|---|---|
| **G-01 AIMD pacer** | **cross-AZ incast** 才有 P99 benefit | **single-AZ 硬规则** | **0%**（不适用场景）|
| G-02 Dynamic NIC LB | partial-NIC congestion | healthy single-AZ 无 skew | healthy 0% |
| Sprint A SBO | bs ≥ 32 overlap 才显著 | decode bs 1-16 | 部分适用 |
| Sprint B CPU spin | SM utilization 已饱和 | H200 bs=1-16 未饱和 | < -1% |
| L9 shared-QP | QP cap 触顶 | p5en EP=32 已证明不触 | p5en 0% |

### 3.2 生产定位重新定义

我们的**实际场景**：
- single-AZ p5en
- decode batch 1-16（Kimi-K2 / GLM-4.6 主力）
- H200 算力，不是 H20 瓶颈
- S3 权重加载，不是网络瓶颈

**在这个场景下**，真正还能拿到收益的 lever：

| Lever | 修订收益 | 原因 |
|---|---|---|
| **Sprint A (L1)** | **-3~-6%** | 协议 unlock + decode bs ≥ 8 可见 |
| **C17 PER_EXPERT_BATCHING** | **-1~-3%** | dispatch 段实测 -20% × 占比 |
| 其余 | **累积 ≤ -2%** | 大多 < 1% 或条件场景 |

**single-AZ healthy p5en 场景累积上限 = -4~-9%**（保守），不是 -15~-20%。

---

## 4. 新 Tier 划分（Phase 16 修订）

### Tier 1 · 真正值得做（只剩 2 条）

| Lever | 工期 | 收益 | 置信度 |
|---|---|---|---|
| **L1 Sprint A** GPU spin + comp_signal | 2w | -3~-6% decode ITL | 🟡 中（H20 实测锚 + 折扣） |
| **L2 C17** PER_EXPERT_BATCHING autotune | 1d bench + 4h PR | -1~-3% decode ITL | 🟢 高（PR #745 实测 dispatch -20%）|

### Tier 2 · 条件性 / 次要

| Lever | 触发条件 |
|---|---|
| **L3 Sprint B** CPU spin | Sprint A 完成后；目标是 tail 抖动非 ITL |
| **L6 G-02** NIC LB | **Sprint 0 实测两 NIC skew > 10% 才做** |
| **L9 shared-SRD-QP** | Blackwell p6-b200 EP=64+ ready 后 |
| **L13 Sprint C** Blackwell | B300 栈 ready 后 |

### Tier 3 · 条件化 / 部分重写

| Lever | 触发条件 |
|---|---|
| **L5 G-01 AIMD pacer** | **明确 cross-AZ 实验场景**（我们生产不遇到）|
| **L14 C9 P-of-2 LB** | decode P99 skew 证据出现 |
| **L12 L-04 launch_bounds** | PTXAS reg dump 证明不 spill |

### DROP / 永久埋

| Lever | 原因 |
|---|---|
| **L4 PR #485** | UCCL-EP LL 路径已多 QP，归因错误 |
| **L11 launcher-cache (ITL)** | CUDA Graph 摊销 |
| **L8 count-send 2-3%** | 算数错，真实 0.5-1% 降 Tier 3 |
| **L9 reduce prefetch 1-2%** | decode batch=1 基数错 |

---

## 5. 修订后的 Sprint Roadmap

### Sprint 0（本周 4 天，必做）—— Instrumentation & Gate

**这 4 天是整个 roadmap 可信度的基础**。没有这些数据，后续 Sprint 全是推导。

| 任务 | 时间 | 决策 unlock |
|---|---|---|
| `microbench_combine_timeline.py` 分段测各 µs | 1d | Sprint A overlap 窗口模型 |
| p5en 两 NIC 负载 skew 实测 | 1d | G-02 是否做 |
| per-peer CQE latency 分布 | 0.5d | G-01 基线 |
| Down-GEMM 时间 × bs sweep (1/4/8/16/32/64/128) | 1d | Sprint A 在 bs ≥ ? 才有收益 |
| `nvcc -Xptxas -v` reg dump | 0.5d | L12 launch_bounds 可行性 |

### Sprint A 修订版（2 周）

Gate 条件（Sprint 0 数据通过）：
- **overlap 窗口（min(compute, comm)） ≥ 20 µs** → 进
- **overlap 窗口 < 20 µs** → 降 Tier 2

Sprint A 内容不变（comp_signal 协议对齐 + SM-stripe 重写），但**必须附 p5en bs sweep 数据**。

### C17 并行（1 天）

独立于 Sprint A。做 p5en 4 节点 EP=32 的 `PER_EXPERT_BATCHING=1` AB 实验，确认 PR #766 edge case 在我们的 Kimi-K2 / GLM-4.6 稳态。

### 延后 / 条件

- Sprint B → Sprint A 后做，目标 tail 抖动非带宽
- G-02 → Sprint 0 NIC skew 数据证实才做
- G-01 → 只在明确 cross-AZ 实验场景做
- L9 → Blackwell 栈 ready 后做

---

## 6. 对外口径订正

**原声称**（Phase 15）：decode ITL -10~-15% 全做，Sprint A 单独 -5~-8%
**修订后口径**：
- **保守上限 -4~-9%**（Sprint A + C17 + Tier 2 少数）
- **Sprint A 单独 -3~-6%**（p5en H200 scenario，未实测）
- **best case single-AZ healthy p5en -9%**（所有 Tier 1/2 落地 + 实测数据符合理论上限）
- **条件收益**（cross-AZ / NIC skew 场景）额外 -5~-15%，但**不在我们生产定位**

**给 UCCL 上游 PR body 写的数据必须是 p5en 实测**，不是我们推导的 ITL 数字（feedback `uccl_pr_aws_bench` 已定）。

---

## 7. 方法论 meta-教训

### 7.1 本次 Phase 16 暴露的 Phase 1-15 错误类型

| 错误类型 | 发生在 Phase | 修正 |
|---|---|---|
| Baseline 套错（H20 → H200） | 3, 11, 15 | 算力比例折扣 |
| "µs × layer = %" 算数错 | 4, 8, 15 | Amdahl 诚实 |
| CUDA Graph 被忽略 | FEASIBILITY_RECONFIRM, 15 | launcher overhead → 0 ITL |
| "commit X 说明作者失败" 误读 | FEASIBILITY_RECONFIRM, 15 | git log 全段还原，非单 commit |
| 归因错（多 QP "多路径"） | 13, 14, 15 | 先确认物理机制 |
| bench param 套 decode（num_tokens=128 → batch=1） | 9, 13 | 区分场景 |

### 7.2 已立规则 + 新加规则

已立：`feedback_claim_verification_discipline.md` 4 条规则——本次验证**规则本身正确，但执行不够彻底**。

Phase 16 要加的第 5 条：
> **Baseline 套用必须先写等比/非等比的物理证明**。H20 → H200 不能等比，H200 → B200 也不能。套用另一个硬件 / workload 的数字必须跟一段 physics discussion。

Phase 16 要加的第 6 条：
> **git commit 教训判定必须还原全段历史**。看到 "Remove X" commit 不等于"作者失败"。必须 grep "Re-add X"、"Fix X"、后续 PR 是否重加同一 feature。

这两条立 memory feedback。

---

## 8. 给决策者的一句话

**经过 Phase 16 核查，我们真正值得做的只有 2 条主 lever：Sprint A（-3~-6%）+ C17 默认 on（-1~-3%）= decode ITL -4~-9% 上限**。其余 12 条或是算数错、或是场景不适配、或是作者早就做过被误读。**本周 4 天 Sprint 0 instrumentation 是一切后续决策的前提**——没这些数据，Sprint A 可能 gate 不通过。

对外不要再说 "-15~-20%"——那是**累加了不该累加的数字**。诚实口径是 **single-AZ p5en -4~-9%**。

---

## 9. 引用

- 子文档：`LEVER_VALIDATION_TIER1.md`（V1 详细）、`LEVER_VALIDATION_TIER2.md`（V2 详细）
- 历史 baseline：`ALLTOALL_DEEP_DIVE.md`（p5en 174.9/326.7 µs）
- PR 数据：uccl-project/uccl #745 body, #800, #766, #485
- paper：arxiv 2512.19849 (UCCL-EP), 2504.17307 (UCCL-Tran), SGLang PR #9660 body
- 关键推翻文档：`UCCL_PAPER_VS_CODE_GAPS.md`（C14 CC missing）、`FEASIBILITY_RECONFIRM.md`（上轮推翻 80% 声称）
