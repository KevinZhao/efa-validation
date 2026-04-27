# Tier 1 旗舰 Lever 价值真实性核查

**日期**：2026-04-26
**角色**：Agent V1 (Validator) — 挑战已有 Tier 1 结论
**方法**：代码行号 + PR 状态 + paper 引文 + 归因质疑；数字严格分 **实测 / 推导 / 套用**
**姐妹文件**：`SBO_COMP_SIGNAL_DEEP_DIVE.md`、`UCCL_PAPER_VS_CODE_GAPS.md`、`SBO_SPRINT_PLAN.md`、`EXPECTED_PERFORMANCE_GAINS.md`

---

## 0. TL;DR

| 原 Tier 1 lever | 判决 | 修订收益 |
|---|---|---|
| L1 Sprint A · GPU spin + `comp_signal` | **KEEP（强证据）**，但把 H20 -7.9% 的套用替换成 H200 -3~-6% 的新估算 | decode ITL **-3~-6%**（而不是 -5~-8%）|
| L2 C17 · PER_EXPERT_BATCHING 默认 on | **KEEP，收益口径修正**：2× 仅限 **dispatch** 段，combine 段实测 -0.2%（噪声）| dispatch -20%，但 **combine 段 0%**；对端到端 decode ITL 贡献 < -1% |
| L3 Sprint B · CPU spin + 3 SM 释放 | **DOWNGRADE Tier 2**，归因失败：3 SM 数字是推导；H200 DeepGemm 实测 tile 利用率在 32-72 SM（随 num_experts），边际收益 ≈ 0 | **< -1%**（悲观）；最大价值是 tail 抖动降低，不是带宽 |
| L4 PR #485 · multi-QP in LL | **DROP**：UCCL-EP LL 路径已是多 QP（`num_qps_per_rank = num_experts / num_ranks`）；PR #485 DRAFT 6 个月无动静、无测试、单文件 refactor | 0%（可证伪的归因错误）|
| L5 G-01 · AIMD pacer | **DOWNGRADE Tier 3** + 条件化：commit 92b96373 是 p2p 路径，不是 EP；随后 PR #703 重新加回静态 cap；真正问题是"没有 AIMD"而不是"作者试过 AIMD 失败"。但 single-AZ healthy 场景收益确实 ≈ 0 | 0% on single-AZ；**-5~-10%** on cross-AZ incast（条件收益，不是默认）|
| L6 G-02 · Dynamic NIC LB | **DOWNGRADE Tier 2**：收益依赖 partial-NIC congestion 出现率；p5en 2 NIC/GPU 硬件对称，healthy fabric 下静态 modulo 已经是最优；改动面比 3-5 天大 | 0% healthy；5-10% 在实测观察到 NIC skew 时 |
| L7 L9 · Shared-SRD-QP across peers | **DOWNGRADE Tier 2**：纯防御性，当前 p5en EP=32 可跑证明没触顶；收益是 p6-b200 解锁，**不是性能** | p5en 0% 性能；p6-b200 EP≥64 解锁价值 |

**净效应**：原"Tier 1 合计 -15~-20%"**被推翻为 -4~-8%**（只有 L1 + L2 + 小部分 L3）；超过 -10% 的数字需要 cross-AZ 场景（L5）才成立，而我们生产定位是 single-AZ。

**新发现的 blocker**：
1. DeepGEMM PR #183 **8 个月 OPEN 未 merge**——Sprint A 的 producer 端不在上游 `main`，必须 fork
2. DeepEP PR #390 **closed not merged**——只有 antgroup-opt 分支有；DeepEP main 不吃 SBO
3. **UCCL-EP LL 路径已是多 QP**，PR #485 的归因"加多 QP"是错的
4. 当前 `kInFlightMaxSizeKB = 10 GB`（p2p/rdma/define.h:178-179）等于"没限"——G-01 起点比想象的更低

---

## 1. 逐条核查

### Lever 1: Sprint A · GPU spin + `comp_signal` overlap

#### 原声称
decode ITL -5~-8%，锚 SGLang PR #9660 H20 实测 -7.9% ITL / +6.7% throughput。

#### 挑战点核查

**挑战 1.1：H20 → H200 可迁移性**
- H20 FP16 ≈ 148 TFLOPS；H200 FP16 ≈ 989 TFLOPS（**6.7× dense compute**），HBM 带宽 4 TB/s vs 4.8 TB/s。
- SBO 的收益机制 = **Down GEMM 计算时间 ∩ combine 通信时间**。这个 overlap 窗口的大小 = min(compute_time, comm_time)。
- H20 上 Down GEMM 是 decode 的 bottleneck（PR #9660 motivation 原话：H20 is low-compute-power → GEMM 塞不进 ITL），overlap 收益 ≈ 100% overlap 窗口。
- H200 上 Down GEMM 比 H20 快 6-7×，**compute 窗口从 ~N µs 压缩到 ~N/6 µs**；如果 combine 段 ~300 µs（PR #745 实测），overlap 窗口上限 = compute 时间，H200 上能 overlap 的绝对时间 **至多 1/6**。
- **H20 的 -7.9% 不能等比搬到 H200**。物理上 H200 上的 SBO 收益应当是 H20 的 1/4 到 1/2——**预估 H200 decode ITL -2~-4%**（推导，需要 bench 验证）。

**证据**：SGLang PR #9660 自己的话 "The optimization effect of Two-Batch Overlap (TBO) is suboptimal for the Decode phase on low-compute-power cards (i.e., H20)" —— 作者自己承认这是 **low-compute-power 特化优化**。

**挑战 1.2：DeepGemm PR #183 / DeepEP PR #483 merge 状态**
- DeepGEMM PR #183：**OPEN**（创建 2025-09-02，至今 2026-04-26 = 8 个月未 merge）。Sprint A 的 **producer 端（`atom.add.release.gpu`）不在 DeepGEMM main**。
- DeepEP PR #390：**closed NOT merged**（2025-11-21，`merged_at: null`）。DeepEP main 不吃 SBO。
- DeepEP PR #483：merged，但 base 是 `antgroup-opt` 分支，**不是 main**。
- **结论**：Sprint A 要走就得 pin 特定 SHA（Sulfur6/DeepGEMM#sbo.v2.sgl + deepseek-ai/DeepEP@antgroup-opt），上游 breakage 风险极高。

**挑战 1.3：comp_signal 在 Hopper 用，我们实际部署目标是什么代？**
- Stage 5 已经明确主战场 p5en (H200)，Blackwell p6-b300 是未来分叉栈。
- H200 是 Hopper，comp_signal 协议 valid。B200 要走 `src_signals`（粒度不同）。
- Hopper 侧不会白做；但 Blackwell 栈要再写一个 Sprint C（已在 SBO_SPRINT_PLAN.md）。

#### 修订后结论
- **Keep**（协议层面对齐是不可替代的 unlock work，即使收益缩水）
- **修正后收益估算**：decode ITL **-3~-6%**（把 H20 的 -7.9% 折到 H200 的 0.4-0.7 倍；保守 -3%，乐观 -6%）
- **风险等级**：中高
  - 上游依赖两个未 merge PR（#183 OPEN、#390 closed）
  - p5en 无实测数据，全部是推导
  - bs=32 是 PR #9660 baseline，我们 decode bs=1-8 的场景 SBO 可能负收益（DeepEP PR #390 原话 "batch < block_m=64 时 SBO 负收益"）

**前置必做**（加到 Sprint A Day 1-3）：
- p5en bs ∈ {1,4,8,16,32,64,128} × Down-GEMM / combine 时间微测，建 overlap 窗口模型
- 如果 overlap 窗口 < 20 µs（combine 占比 < 10%），Sprint A 降到 Tier 2

---

### Lever 2: C17 · PER_EXPERT_BATCHING 默认 on

#### 原声称
dispatch 2×（paper Fig 8）；当前 Makefile:81 默认 0；PR #745 合入，PR #800 加结果。

#### 挑战点核查

**挑战 2.1：paper Fig 8 的 2.3× baseline 是 PPLX，不是 UCCL-EP with vs without**
- 核查 PR #745 body 的直接数字（p5en 2×8 = 16 GPU，num-tokens=128，hidden=7168，topk=8，experts=288）：

| 段 | 无 batching | PER_EXPERT_BATCHING=1 | Δ |
|---|---|---|---|
| Dispatch both p50 | 218.56 µs | **174.90 µs** | **-20.0%** |
| Dispatch BW | 35.36 GB/s | 42.88 GB/s | +21.3% |
| Dispatch send p50 | 40.90 µs | 44.45 µs | +8.7%（回归）|
| Dispatch recv p50 | 30.69 µs | 30.50 µs | 基本不变 |
| **Combine both p50** | **325.98 µs** | **326.69 µs** | **+0.2%（噪声）** |
| Combine send p50 | 47.68 µs | 47.74 µs | 不变 |
| Combine recv p50 | 46.85 µs | 46.72 µs | 不变 |

**重大订正**：
- PR #745 的"**dispatch 20%**"是真的（p5en 16 GPU 实测）。
- "**2× dispatch**"（声称中的 Fig 8 数字）是 PPLX baseline，不是 UCCL-EP with-vs-without。**归因错误**。
- **Combine 段几乎没改善**（+0.2% 是测量噪声）。声称 "dispatch 2×" 让人以为整个 EP 2×，实际只有 dispatch 段 20%。

**挑战 2.2：PR #800 的实测数字**
- PR #800 的 body 是空模板（"Please include a summary..."），正文没有独立数字；只是把 PR #745 的结果落到 README/docs。
- **PR #745 body = 唯一权威源**，上面数据已摘录。

**挑战 2.3：Pure-win 为什么没默认开？PR #766/#865 的意义**
- PR #766（2026-02-27）修 **3 个 bug**：off13 overflow（8191 字节上限溢出）、receiver barrier stride mismatch（hang）、cudaMalloc(0) crash。**只在 ≥ 32 GPU 才触发**。
- PR #865（2026-04-05）修 AMD 兼容。
- 说明 PER_EXPERT_BATCHING 在 EP ≥ 32 跨多节点的真实场景里 **不是 pure-win**，还有 edge case。
- 作者没默认开的合理解释 = **保守：等更多 AMD / 大 EP 稳定性**。P5en 4 节点 32 GPU 在 PR #766 之后才真正可用（2026-03-02）。

#### 修订后结论
- **KEEP**（dispatch -20% p5en 实测有力）
- **口径修正**：**dispatch 段 -20%**；**combine 段 0%**（实测）。声称"dispatch 2×"是套用 PPLX 比较，应该降级成"dispatch p5en 实测 -20%"。
- decode ITL 端到端影响：dispatch 占 decode ITL 大约 10-15%（`internode_ll.cu:665-722`），20% × 15% = **约 -3% decode ITL**，更可能是 **-1~-3%**。
- **风险等级**：低（可独立 AB 测 env `PER_EXPERT_BATCHING=1`）
- 上游 merge 已完成；下一步是 p5en 4节点 EP=32 实测重复 PR #766 验收范围

---

### Lever 3: Sprint B · CPU spin + 3 SM 释放给 DeepGemm

#### 原声称
ITL 额外 -3~-5%；DeepGemm 多 2-3 SM 线性增。

#### 挑战点核查

**挑战 3.1："3 SM 释放" 来源**
- SGLang env `SGLANG_DEEPEP_LL_COMBINE_SEND_NUM_SMS=3`（SBO_COMP_SIGNAL_DEEP_DIVE.md §1.1 记录，PR #9660 launch script 原话）—— 这是 DeepEP 在 GPU 端做 per-warp IBGDA doorbell 的 SM 数。
- 但 **UCCL-EP 走 CPU-proxy FIFO**，`uccl_ibgda.cuh:36` 选 thread_idx 后 `if (lane_id != 0) return`——31/32 lane 本来就闲。**UCCL-EP 的 combine send SM 数本来就不是 3**。
- `internode_ll.cu:1226` 实测：`num_sms = ceil_div(num_experts, num_warp_groups)`。对于 288 experts / 4 warp-groups = **72 SMs**，for 2 warp-groups = 36 SMs。与 3 无关。
- **"3 SM 释放"是从 DeepEP env 借过来的数字，在 UCCL-EP 上物理意义不一样**。Scheme B 节省的 SM 数是 1（combine 的 signal-wait 占的那个 SM），不是 3。

**挑战 3.2："DeepGemm 2-3 SM 线性增"**
- H200 132 SM。DeepGemm masked GEMM 典型 config（DeepGEMM `m_grouped_fp8_gemm_nt`）tile 数依 num_experts × block_m 确定。
- decode bs=32 DeepSeek-V3 TP=1 EP=16：每 rank ~16 local experts × ceil(32/64) = 16 tiles（block_m=64）——tile 数本来就小于 SM 数，**GEMM 并不 saturate SM**。多 2-3 SM 回来，边际收益 ≈ **0**。
- 只有 bs ≥ 128 且 num_experts × tiles > 132 时 Scheme B 的 SM 回收才有线性收益。Stage 5 decode bs=1-16 实际场景下，SM 回收**收益 ≈ 0**。

**挑战 3.3：retransmit sub-ms 定性描述 vs 实测需求**
- p5en CPU busy-spin 稳定性：proxy 已 busy-poll（`proxy.cpp:673-733`），多加一个 signal 预断不会加 CPU 成本。
- SRD retransmit 经验数据：我们 Phase 14 Z 证明了 EFA SRD MTU=8 KB 的 retransmit 在 single-AZ < 100 µs 常态，cross-AZ 观察到 ms 级 tail。
- 真正的风险：**signal memory scope**。DeepGEMM PTX 是 `atom.add.release.gpu.global.s32`（scope=gpu），CPU proxy 读要求 `release.sys`（scope=system）。这是 PTX 的 1 字符改动，但要 DeepGEMM 团队接受。Hopper cache coherent 下可能 de-facto 成立，但 **纸面不保证**。

#### 修订后结论
- **DOWNGRADE Tier 2**
- **修正后收益**：decode ITL < **-1%**（主要 value 是 ITL tail 抖动，不是带宽；Scheme A 的 `__nanosleep(100)` × N 累积 tail 被移走 5-15 µs）
- **风险等级**：中
  - DeepGEMM `release.sys` patch 外部依赖
  - CPU proxy signal polling 成本需在 proxy 实测 < 1 µs
  - 实际只节约 1 SM，不是 3
- 替代路径：Scheme B 做成 **隐藏 env `UCCL_EP_COMBINE_SIGNAL_ON_CPU=1`**，Sprint A 之后 A/B 决定是否默认

---

### Lever 4: PR #485 rebase · multi-QP in LL

#### 原声称
ITL -3~-5%，dispatch send + combine tail。

#### 挑战点核查

**挑战 4.1：PR #485 DRAFT 5-6 个月没动说明什么**
- 创建 2025-10-28，updated_at 2025-11-02（4 天后 review），至今 2026-04-26 = **约 6 个月无动**。
- 单 commit `1e5a7058`，单文件 `ep/src/rdma.cpp`（+321/-250 行），**无 PR body、无 bench、无 test**。
- 作者 MaoZiming 是 UCCL 核心贡献者（PR #453 做过 normal-mode 多 QP），但他在这个 PR 里**没放任何收益数据**。
- **这不是"作者测出收益但没时间 merge"**，更像是 **"实验结果没有显著 / 有 regression / 架构冲突"** 所以搁置。

**挑战 4.2：多 QP 的"多路径收益"假设被 flow_label 不生效推翻**
- Phase 14 Y / SRD_PROTOCOL_PART2.md 已证明 **EFA flow_label 不影响 SRD 多路径 ECMP**（Henan PR 侧实测）。
- 那么多 QP 的收益来源**只剩 SQ 并发 + doorbell concurrency**，不是"多路径"。
- SQ 并发收益 = per-WR 2-5 µs × 并行度。decode batch=1 top-8 每 peer 最多 8 WR，4 QP 分流后每 QP 2 WR。`ibv_wr_rdma_write` 在 EFA 是 doorbell ring + kernel async，**每 QP 的 post 开销 ~200-500 ns**，并发度从 1→4 节省 ~0.6-1.5 µs/peer——decode ITL 中可能 -0.5% 量级。

**挑战 4.3：UCCL-EP LL 路径其实已经多 QP**
- `ep/bench/test_low_latency.py:482`: `num_qps_per_rank = num_experts // num_ranks`
- `ep/bench/test_low_latency_pplx.py:741`：同上
- `ep/src/rdma.cpp:997-1017`：data_qps_by_channel 数组创建 `kChannelPerProxy = 8` 个 QP，但这是 normal mode `if (use_normal_mode)` 分支
- **LL 路径用 `S.qp`（单 QP）**（`rdma.cpp:963, 2227`）
- PR #485 的语义 = 让 LL 路径**不只用 S.qp，而是用 data_qps_by_channel**。**这是一个合理的改动，但归因"多路径收益 -3~-5%" 站不住脚**。

#### 修订后结论
- **DROP**（从 Tier 1 移除）
- 原因：
  1. 作者 6 个月不动是最强的负面信号
  2. 原声称的 -3~-5% 没有任何实测源，完全是推导
  3. 真实物理机制是 SQ 并发，上限 0.5-1.5%
  4. 改动面大（rdma.cpp +321/-250 行），collision risk 高
- 替代路径：**如果 L1 (Sprint A) 实测发现 dispatch send 是 tail，再重新评估多 QP**。否则把人力挪到 G-01 或 G-02。

---

### Lever 5: G-01 · CPU proxy AIMD pacer

#### 原声称
P99 tail -5~-15% cross-AZ incast。Paper §6 Discussion 撑腰。

#### 挑战点核查

**挑战 5.1：commit 92b96373 的教训到底是什么**
- 提交顺序（git log 还原）：
  ```
  27058a00 Add experimental flow control
  92b96373 Remove experimental flow control      ← 被引用作为"作者测试失败"
  58b113d0 Remove flow control                   ← 同日 2 小时后彻底清干净
  549651d9 Add separate flow control
  d5411b47 New flow control
  030e4c6a Flow control in rdma
  fe2ee97e Move flow-control inside RDMA
  3af0d38d [P2P] flow control and fix high latency issue (#703)   ← PR #703 合并，flow control 被重新加回来
  ```
- 关键事实：**92b96373/58b113d0 是一天内的 WIP 清理**（作者 praveingk 在 IST 时间 13:56 → 15:08 同日），**次日就被 PR #703 re-implementation**。这**不是** "作者实测后删"，而是 "refactor 过程中的 WIP 清掉再重做"。
- PR #703 body：`LOG(INFO) was causing most of the delay. After removing this, performance improvement, and comparable/better to collective RDMA` —— flow control 本身没删，**删的是 hot path 里的 log**。
- **"commit 92b96373 作者实测后删了 → 信号极强" 的原结论是误读**。

**挑战 5.2：当前 flow control 实际是什么**
- `p2p/rdma/rdma_connection.h:401-409`：static `kInFlightMaxSizeKB = 10240000` (10 GB) cap。
- `ep/include/common.hpp:72` (from UCCL_PAPER_VS_CODE_GAPS.md §C14)：`kMaxInflightBytes = SIZE_MAX`（无限制）。
- **当前状态 = 几乎没 CC**。paper §6 原话正是 "future work"——作者自己说没做。
- 所以 G-01 的本质 = **从 0 开始做一个真正的 AIMD**，不是 "重启作者删掉的代码"。

**挑战 5.3：cross-AZ incast 是真问题吗？**
- Stage 5 R3 跨 AZ TransferEncodingError：从 runbook 看是 **Mooncake KV transfer 跨 AZ 首请求超时**，已经记 memory `feedback_same_az_for_pd_disagg.md`——生产规则是 **same-AZ 硬规则**。
- 那么 G-01 的 cross-AZ 收益场景**不在我们的生产定位**。
- Single-AZ healthy fabric 下，static inflight cap 和 AIMD 没差别，G-01 收益 ≈ 0。

**挑战 5.4：SRD 已经有内部 CC，双层 throttling 风险**
- AWS SRD 白皮书承认内部 CC（pacing/retransmit/RTT），但不暴露 API。
- 软件 AIMD 叠加 SRD CC = 可能 under-utilize bandwidth（软件 half rate + SRD 也 half rate = 1/4）。
- 实现 AIMD 前必须先做 **SRD-bypass 验证**（能单独测软件 CC 收益，而不是和 SRD 叠加）。

#### 修订后结论
- **DOWNGRADE Tier 3，条件化**
- 原因：
  1. commit 92b96373 教训是**误读**，作者没失败过 AIMD
  2. 生产定位 single-AZ，default 收益 ≈ 0
  3. cross-AZ 5-15% 是**条件收益**，不是默认场景
  4. 双层 CC 风险真实存在
- **修正后收益估算**：single-AZ 0%；cross-AZ -5~-10%（只在明确 cross-AZ 实验场景做）
- 替代路径：**先做一个 instrumentation PR**（per-peer CQE latency + retransmit counter + inflight bytes metric），2-3 天；data 出来再决定是否投入 AIMD 实现的 1-2 周

---

### Lever 6: G-02 · Dynamic NIC load balance

#### 原声称
throughput +5~15% under partial-NIC congestion。Paper §4 "we omit the details"。

#### 挑战点核查

**挑战 6.1：partial-NIC congestion 多常见**
- Stage 5 截至 2026-04-26 的所有 run 都是 same-AZ p5en，**没有观察到 NIC skew 导致的 throughput drop**。
- p5en 硬件：1 GPU → 2 NIC × 200 Gbps，static modulo (`rdma.cpp:481-504` `thread_idx % 2 + half`) **已经把 2 proxy thread 各绑到一个 NIC**。healthy 场景下两 NIC 负载天然对称。
- partial-NIC congestion 的触发场景：
  - EFA ARM core busy（CPU pinning 不当）— 可控
  - 特定 AZ 物理交换机故障 — 罕见
  - cross-AZ fabric skew — 我们生产不跨 AZ
- **典型 p5en single-AZ healthy fabric 下 G-02 收益 ≈ 0**。

**挑战 6.2：改动面 vs 3-5 天**
- UCCL_PAPER_VS_CODE_GAPS.md §C10 声称 3-5 天。核查改动面：
  - `ProxyCtx` 必须变成 **多 NicCtx**（每个 NIC 一个 pd / context / QP 池）
  - MR 注册要在每个 NIC 的 pd 下重做（dmabuf 多键）
  - QP 创建数 × 2（per-thread 2 NIC × 8 channel = 16 QP/thread）
  - post loop 加 min-load picker（outstanding-WR counter per QP）
- **实际工作量 7-10 天**（含单测和 p5en correctness 验证）。3-5 天低估。

**挑战 6.3：static modulo 已经是最优的场景**
- healthy 情况下 `thread_idx % 2 + half` 把 thread 0/1 发到 NIC 0/1，thread 2/3 发到 NIC 2/3……每 NIC 负载均等。
- dynamic LB 的收益**必须依赖 NIC queue depth 出现 skew**。
- 如果 skew 不存在，dynamic LB 只会增加 picker 决策成本（~50-100 ns/post）——**小负收益**。

#### 修订后结论
- **DOWNGRADE Tier 2**
- **修正后收益**：healthy p5en 0%，观察到 NIC skew 时 5-10%
- **风险等级**：中（改动面大于预估 2×）
- 前置必做：先做 **per-NIC outstanding-WR instrumentation**（2 天），数据证实 skew 存在再做实现
- 替代路径：如果 Sprint 5 实测 p5en 两 NIC 负载差 < 10%，G-02 直接 DROP

---

### Lever 7: L9 · Shared-SRD-QP across peers

#### 原声称
QP 数 / peers 倍减，消 p6-b200 QP cap 触顶风险。

#### 挑战点核查

**挑战 7.1：UCCL 当前 p5en EP=32 能跑吗**
- PR #766 body（2026-03-02）：`Tested on 4× p5.48xlarge (32× H100 80GB, 32× EFA 100Gb/s): All correctness tests pass... EP32 benchmark (4 nodes, 32 GPUs, 288 experts): 4.16 GB/s D+C bandwidth`
- **答案：能跑**。说明 p5en EP=32 **没触顶 QP cap**。
- L9 对 **p5en 是预防性，不是性能**。
- SRD_PROTOCOL_PART2.md §L9 的动机是 **p6-b200 EP≥64 时触 ~384 QP/NIC cap**——那是 Blackwell 分叉栈的事。

**挑战 7.2：Mooncake #1944 scope vs UCCL-EP scope**
- Mooncake #1944 只改 Transfer Engine（P2P KV 传输），scope 是**点对点**。
- UCCL-EP shared-QP 要同时改 dispatch（多对多）和 combine（多对多），scope 是 **all-to-all**，对 QP 锁竞争敏感度高一个数量级。
- **2 周是激进估算**。考虑 correctness testing（dispatch + combine + PER_EXPERT_BATCHING × EP ∈ {16, 32, 64} × topk ∈ {4, 8}），**更可能 3-4 周**。

**挑战 7.3：shared QP 引入新的 contention**
- shared QP post_send 需要 spinlock（或者 per-QP 独占生产者线程）。
- UCCL-EP 现在 `kNumProxyThs = 4` threads × `kChannelPerProxy = 8` channels = **32 producer × 1 QP** 的锁竞争 — decode 每 ITL 的 post 数 32 × 8 = 256 ops → 锁开销数百纳秒累加**可能吃掉 shared 的收益**。
- 解决方案：per-thread 独占一个 shared-QP 片段（thread 0 用 QP0，thread 1 用 QP1），但这就退化回类似现在的"每 thread 有自己的 QP"——**没 shared**。

#### 修订后结论
- **DOWNGRADE Tier 2**
- **修正后收益**：p5en 0% 性能（EP=32 可跑证明无触顶）；p6-b200 EP≥64 时**解锁**（不是 speed-up，是 enable）
- **风险等级**：中高（锁竞争、3-4 周工作量）
- 依赖：Blackwell 栈 ready 后才做
- 替代路径：p6-b200 上**先测 EP=64 / EP=128 的 QP 创建数**，如果 single-NIC < 300 QP 就 drop L9；如果 > 350 再激活 L9

---

## 2. 交叉影响分析

### 2.1 重叠收益（不能线性相加）

| Lever 对 | 重叠情况 |
|---|---|
| L1 + L3 | **强重叠**。Sprint A 做 Scheme A；Sprint B 在 A 上做 Scheme B。**收益不能叠加**（L3 的 -3~-5% 建立在 L1 已完成的 signal 协议上）。订正：L1 + L3 合计 -4~-7%（保守） |
| L4 + L6 | **部分重叠**。两者都触 NIC post 路径：L4 改 QP 分流，L6 改 NIC picker。一起做会相互影响 benchmark 可 attribution |
| L5 + L6 | **部分重叠**。G-01 的 per-NIC token bucket 需要 G-02 的 NIC picker 粒度才能发挥——**G-01 依赖 G-02** |
| L2 + L1 | **正交**。PER_EXPERT_BATCHING 影响 dispatch；comp_signal 影响 combine。可以叠加 |
| L2 + L4 | **部分重叠**。都在改 WR 发送路径。L4 的多 QP 在 PER_EXPERT_BATCHING 下 reorder buffer 容量需要审查 |

### 2.2 互相依赖

- **L3 依赖 L1**：没 L1 的 signal 协议，L3 无处可挪 spin
- **L5 依赖 L6 (弱)**：AIMD 要 per-NIC 粒度才精准
- **L7 依赖 Blackwell 栈**：不看 b200，没必要

### 2.3 Cannibalize（此消彼长）

- **L4 和 L1 的 combine send**：L1 要 SM stripe combine send；L4 要多 QP 分流 combine send。两个机制同时改一个文件（`internode_ll.cu` combine kernel），merge conflict 必然
- **L6 和 L5**：如果 G-01 先做且 per-peer 限速，G-02 的 NIC picker 空间被压缩

---

## 3. 给 roadmap 的修订建议

### 3.1 Sprint 顺序调整

**原计划**（SBO_SPRINT_PLAN.md）：Sprint A → B → C。
**建议修订**：

1. **Sprint 0（本周，3 天）—— Instrumentation & Baseline**
   - 新建 `ep/bench/microbench_combine_timeline.py`：分段测 kernel-launch / TMA setup / send / remote recv / reduce 各段 µs
   - 测 p5en 两 NIC 负载 skew（证实 / 证伪 G-02 前提）
   - 测 per-peer CQE latency 分布（为 G-01 提供 baseline）
   - 测 Down-GEMM 时间 × bs sweep（为 L1 提供 overlap 窗口 model）
   - 测 PER_EXPERT_BATCHING 在 EP=32 稳定性（重现 PR #766 edge case）

2. **Sprint A 修订版（2 周）—— comp_signal Scheme A**
   - 保留原计划
   - **Day 1-3 增加 Sprint 0 bench** 作为入口 gate
   - **Gate 条件**：如果 overlap 窗口 < 20 µs（即 combine 占 ITL < 10%），Sprint A 降 Tier 2 并暂停
   - 收益目标调整为 p5en **-3~-6%**（不是 -5~-8%）

3. **Sprint B 修订版（1 周）—— Scheme B 作为隐藏 env**
   - 降工作量到 1 周（不是 1.5 周）
   - 不走主 PR，做成 `UCCL_EP_COMBINE_SIGNAL_ON_CPU=1` env 隐藏开关
   - 收益目标 < -1%（悲观）

4. **Sprint C —— Blackwell `src_signals`**（看 p6-b200 SPS）

### 3.2 Tier 降级 / 移除

| Lever | 原 Tier | 新 Tier | 理由 |
|---|---|---|---|
| L1 Sprint A | 1 | **1** (keep) | 最强，但预期收益对折 |
| L2 C17 | 1 | **1** (keep) | 有 p5en 实测；口径缩到 dispatch -20% |
| L3 Sprint B | 1 | **2** | 归因失败；收益 < -1% |
| L4 PR #485 | 1 | **DROP** | 作者 6 月不动 + 机制失误 |
| L5 G-01 | 1 | **3** (条件收益) | single-AZ 0%；仅 cross-AZ 场景启用 |
| L6 G-02 | 1 | **2** | 依赖实测发现 NIC skew |
| L7 L9 | 1 | **2** (p6 only) | p5en 0%；p6 enable |

**新 Tier 1**：只有 L1 + L2。合计 decode ITL -4~-9%（不是 -15~-20%）。

### 3.3 本周 instrumentation 优先级

| # | 任务 | 工作量 | unlock |
|---|---|---|---|
| 1 | combine timeline microbench | 1 d | L1 overlap 窗口验证 |
| 2 | 两 NIC 负载 skew 实测 | 0.5 d | L6 前提验证 |
| 3 | per-peer CQE latency 分布 | 1 d | L5 baseline |
| 4 | Down-GEMM 时间 × bs sweep | 0.5 d | L1 兑现率 |
| 5 | EP=32 PER_EXPERT_BATCHING 4 节点稳定性 | 1 d | L2 生产验收 |

**总工作量 4 天**；**完成前不开 Sprint A / Sprint B**。

### 3.4 汇报口径修正

之前对外宣称"合计 decode ITL -15~-20%"应改口：
- **证据支撑的保守上限 -4~-9%**（L1 -3~-6% + L2 -1~-3%）
- **条件收益（cross-AZ / NIC skew）额外 +5~10%** 但非默认场景
- **实测前任何数字都是推导**，禁止承诺

---

## 附：证据表

### PR / Commit 状态实测

| ID | 状态 | 日期 | 影响 |
|---|---|---|---|
| uccl-project/uccl#485 | **OPEN DRAFT**，最后更新 2025-11-02 | 5.8 months stale | L4 DROP 信号 |
| uccl-project/uccl#745 | merged 2026-02-26 | — | L2 核心证据（p5en 实测）|
| uccl-project/uccl#766 | merged 2026-03-02 | 3 bug fix | L2 生产门槛 |
| uccl-project/uccl#800 | merged 2026-03-08 | 空 PR body | L2 无独立数据 |
| uccl-project/uccl#865 | merged 2026-04-06 | AMD fix | L2 跨平台门 |
| uccl-project/uccl#703 | merged 2026-02-03 | 重新加回 p2p flow control | **推翻** L5 "作者失败" 叙事 |
| deepseek-ai/DeepGEMM#183 | **OPEN** 2025-09-02 | 8 months | L1 blocker（producer 端不在上游）|
| deepseek-ai/DeepEP#390 | **closed NOT merged** 2025-11-21 | — | L1 blocker（DeepEP main 不吃 SBO）|
| deepseek-ai/DeepEP#483 | merged 2025-11-21 到 `antgroup-opt` 分支 | — | L1 必须 fork pin |
| sgl-project/sglang#9660 | merged 2025-12-03 | 5 nodes H20 bs=32 | L1 数字套用源（H20 不是 H200）|

### Git 历史溯源（L5）

92b96373（Feb 2, 2026 13:56 IST）"Remove experimental flow control" → 58b113d0（同日 15:08 IST）"Remove flow control" → 549651d9 "Add separate flow control" → d5411b47 → 030e4c6a → fe2ee97e → **3af0d38d PR #703（Feb 3）"flow control and fix high latency issue" 重新加回**。

结论：92b96373 是同日 refactor WIP，次日 PR #703 就恢复了；**不是作者测试失败删除**。

### 代码行号证据

| Lever | 关键行号 |
|---|---|
| L2 Makefile 默认 off | `ep/Makefile:81` `PER_EXPERT_BATCHING ?= 0` |
| L2 PER_EXPERT_BATCHING 分支 | `ep/src/internode_ll.cu:672-682`、`448-450` |
| L3 combine num_sms 来源 | `ep/src/internode_ll.cu:665, 1226` `ceil_div(num_experts, num_warp_groups)` |
| L4 LL 路径单 QP | `ep/src/rdma.cpp:963, 2227` `S.qp` |
| L4 normal 路径多 QP | `ep/src/rdma.cpp:994-1017` `data_qps_by_channel` |
| L4 num_qps_per_rank 语义 | `ep/bench/test_low_latency.py:482` |
| L5 当前 inflight cap | `p2p/rdma/define.h:178-179` `kInFlightMaxSizeKB = 10240000`（10 GB）|
| L5 EP 侧无 CC | `ep/include/common.hpp:72` `kMaxInflightBytes = SIZE_MAX` |
| L6 NIC static modulo | `ep/src/rdma.cpp:481-504` `thread_idx % 2 + half` |
| L7 LL 协议路径已 num_qps_per_rank = experts/ranks | `ep/bench/test_low_latency_pplx.py:741` |

---

**签名**：Agent V1
**文档版本**：1.0
**下一步**：与原 SBO_SPRINT_PLAN.md / FINAL_EXECUTION_CHECKLIST.md 对账，把 Tier 降级反映到 roadmap。
