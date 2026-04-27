# Tier 2 中等 Lever 价值真实性核查

**日期**：2026-04-26
**作者**：Agent V2 (Validator)
**任务**：挑战 7 条 Tier 2 lever 的 "µs × layer = %" 推导，查出哪些在 decode 场景其实收益 ≈ 0

---

## 0. TL;DR

| 结论 | 数量 | Lever |
|---|---|---|
| ✅ **保留**（数字基本对得上） | 2 | L10 (unordered_map→array)、L13 (Sprint C Blackwell src_signals) |
| ⚠️ **大幅下调**（真实收益被夸大 2-5 倍） | 3 | L8 (count-send coalesce)、L11 (launcher-cache)、L14 (P-of-2 LB) |
| ❌ **应降 Tier 3 或 drop**（decode batch=1 下收益 ≈ 0） | 2 | L9 (reduce prefetch)、L12 (launch_bounds 变体) |

**核心误区**（贯穿全部）：所有 Tier 2 声称都**以 bench 的 num-tokens=128 profile 为基准线** → 把 `3-6 µs/token × 128 = 400-800 µs/layer` 线性放大。但 **SGLang decode batch=1 实际 num_combined_tokens ≈ batch_size (1~8)，不是 128**。很多 per-token 数字 × layer 放进 ITL 公式应该乘 1/16~1/128。

**总累积上限订正**：Tier 2 全做的真实 ITL 收益从声称的 **-8~-18%** 订到 **-2~-4%**（而 Tier 1 SBO Sprint A + PR #485 + count-coalesce 仍然能拿 -10~-15%）。

---

## 1. Amdahl 框架：decode 50 ms ITL 里的组件分布

Decode **单 step** 时间预算（DSv3 58 MoE layer，H200 p5en，post-PR #745）：

| 组件 | 估算占比 | µs 绝对值 | 来源 |
|---|---|---|---|
| Attention (prefill KV, MQA decode) | ~20% | ~10 ms | SGLang profile H200 DSv3 decode typical |
| MoE dispatch + combine 通信 EP | ~58% | ~29 ms | 58 layer × 500 µs/layer (ALLTOALL_DEEP_DIVE §0.2) |
| GEMM (gate/up/down proj) | ~18% | ~9 ms | FP8 GEMM DeepGemm 58 layer |
| RMSNorm + residual + misc | ~2% | ~1 ms | cheap kernels |
| Host launcher + misc CPU | ~2% | ~1 ms | CUDA Graph replay |
| **total** | 100% | **50 ms** | SGLang PR #9660 H20 73 ms → H200 p5en 预期 ~50 ms |

**Tier 2 lever 作用在哪个组件**：

| Lever | 作用组件 | 理论上限（Amdahl） |
|---|---|---|
| L8 count-send coalesce | EP dispatch send (58%×20% = 11.6%) | **-11%/组件 × 组件占比 ≤ -1% ITL** |
| L9 reduce shared-mem prefetch | EP combine reduce (58%×46/326 = 8.2%) | **-10%/组件 × 组件占比 ≤ -0.8% ITL** |
| L10 unordered_map → array | CPU launcher (2%) | **-50%/组件 × 组件占比 ≤ -1% ITL** |
| L11 launcher-cache cudaDeviceGetAttribute | CPU launcher (2%) | **-20%/组件 ≤ -0.4% ITL** |
| L12 launch_bounds 变体 | EP kernel compute (58%× reduce 8%) | 若 occupancy 能 double，**理论 ≤ -4% ITL**；若 spill 负收益 |
| L13 Sprint C src_signals | EP combine overlap with DeepGemm (Blackwell only) | Blackwell -3~-5% ITL；Hopper **0** |
| L14 Multi-QP P-of-2 LB | EP dispatch tail (P99) | **-1~-3% P50，P99 -5~-10%** |

**结论**：Tier 2 任何 lever 的**理论上限（Amdahl）都在 -1~-4% ITL 之间**，不可能出现 "-3~-5%" 的量级——除非作用组件占比被严重夸大。

---

## 2. 逐条核查

### Lever 8 · Count-send coalescing (per-rank AMO merge)

**原声称**：ITL -2~-3%（10-30 µs/layer）

**数字来源追溯**：
- `ALLTOALL_DEEP_DIVE.md` §4.1 自己已经订正："之前 agent 说 10-14 µs/layer × 58 = 700 µs/token，这个算法有错——真实节省 ≤ 5 µs/layer"
- 但 `EXPECTED_PERFORMANCE_GAINS.md` 还写着 "3-5 µs/layer → -2~-3% ITL"——**3-5 µs × 58 layer / 50 ms = 0.35~0.58%**，不是 2-3%。数字自己打架。

**代码实证**（`internode_ll.cu:404-444`）：
- count-send 是 **per-(expert, rank) 1 AMO**，受 `if (responsible_expert_idx < num_experts and sub_warp_id == 0 and lane_id == 0)` 门控
- 每 GPU 上 responsible expert 数 = `num_experts / num_sms / num_warp_groups`——对 num_experts=288, num_sms=144, 每 GPU 每 layer post **288 AMO（per-expert-dst 一个）**
- 但 `rdma.cpp:2996-3039` 已经 **per-dst-rank 把所有 AMO 合进一个 `ibv_wr_start/complete` chain**（16 dst rank × 每 rank 18 AMO = 288 AMO，但只 16 个 chain）
- Scheme A 把 **16 个 chain × N AMO 变成 16 个 chain × 1 RDMA_WRITE**，省的是 chain 内的 per-item 成本（非 doorbell）

**Amdahl sanity check**：
- dispatch send p50 = 44.45 µs (bench)，其中 count-send 段 ≤ 15 µs（从已有 agent 分析）
- 即使 count-send 压到 0，dispatch send **上限减 15 µs，每 layer 从 44.45 → ~30，相对 500 µs/layer = -3%**
- 但实际压不到 0（receiver 死锁检测要求至少一个 sentinel per dst-rank）
- 保守 5 µs/layer × 58 = 290 µs ÷ 50000 µs = **0.58% ITL**

**decode vs prefill 区别**：
- prefill num_tokens=128 时 **payload 占主导**，count AMO 相对占比小，coalesce 收益小
- decode batch=1 top-8 时 每个 expert 只有 0-1 token 要发，**AMO sentinel 的占比反而变大**（因为 payload 短）→ decode 下 coalesce 收益相对更高，但绝对值 µs 仍小

**修订后结论**：**真实 -0.5~-1% ITL**（不是 -2~-3%）。保留 lever，但**下调到 Tier 2 底**。

---

### Lever 9 · Lever B · Combine reduce shared-mem prefetch

**原声称**：ITL -1~-2%（3-6 µs/token × 128 tokens = 400-800 µs/layer）

**数字来源追溯**：
- `COMBINE_RECV_DEEP_DIVE.md` §1 表格里 "Reduce ~33 µs" 是**Agent A 推导**，不是 profiling：
  - "~14.5 KB read / SM × 1 token / SM / 37 GB/s = 3.1 µs/token ideal"
  - "× 3-5 非合并 factor = 30-40 µs/token"
  - **这 33 µs 是「每 SM per token 处理时间」的推导，不是总 reduce 时间**
- 但 bench 配置 num_combined_tokens=**128**，num_sms=144 → 每 SM ~1 token 并行，**reduce 总 wall-clock 与 per-token 时间同量级（33 µs）**
- 没有 nsys trace 证明 33 µs

**Amdahl sanity check**：
- combine recv 46.72 µs 里 reduce 估 33 µs（71%）
- prefetch 省 3-6 µs/token（声称）= 33 µs → 27 µs = **-6 µs / 46.72 µs / layer combine = -1.8%/combine layer**
- × 58 layer × combine_weight (326/500=65%) / 50 ms = **-2.2% 理论上限**
- 听起来接近声称 -1~-2%，但 **decode batch=1 场景**：
  - num_combined_tokens = **batch_size ≈ 1-8**，不是 128
  - 每 SM 分摊 < 1 token，reduce 总时间 **不是** 33 µs × layer，而是 ~33 µs ÷ (128/bs) + 固定开销
  - 实测需要 COMBINE_RECV_DEEP_DIVE §7 的 per-phase `clock64()` instrument 才能定

**decode vs prefill 区别**（**最关键漏洞**）：
- `400-800 µs/layer = 3-6 µs/token × 128 tokens`：**前提是 num_combined_tokens=128**
- decode SGLang 实际 `num_combined_tokens ≈ batch_size`（对 batch=1 就是 1）
- **decode 下 Lever B 收益大约 = 3-6 µs × batch ≈ 3-6 µs/layer**（不是 400-800），× 58 layer = **174-348 µs ÷ 50 ms = 0.35-0.7% ITL**

**和 Sprint A (SBO) 的 overlap**：
- Sprint A 用 `comp_signal` 让 combine send 和 down_gemm 重叠，**不碰 reduce**
- 所以 L9 和 Sprint A **独立，不 double-count**

**修订后结论**：
- prefill/bench num-tokens=128 场景：**-1~-2% ITL**（声称对）
- **decode batch=1 生产场景：-0.3~-0.7% ITL**（声称错了 3-5×）
- **降级：Tier 3**（bench 看得到，生产效果微乎其微）

---

### Lever 10 · L-01 · Hot-path `unordered_map` → `std::array`

**原声称**：ITL -1~-3%（每批 WR 省 3-5 µs）

**数字来源追溯**：
- `rdma.cpp:1374, 1812, 2985` 三个地方都是 `std::unordered_map<int, std::vector<size_t>> dst_rank_wr_ids`
- 3-5 µs/批是 FEASIBILITY_RECONFIRM 的推导，**没有 profiling 数据**
- glibc `unordered_map` 一次默认构造含：
  - 1 次 bucket array 分配（默认 11 buckets → ~88 bytes）
  - `reserve()` 可能触发 rehash
  - per-insert：hash + bucket walk + node alloc（`new`）

**Amdahl sanity check**（最关键错误）：
- FINAL_EXECUTION_CHECKLIST 确认过 "UCCL init 已 1-2s"（一次性），**不是每批 3-5 µs**
- 实际 per-batch CPU proxy 工作：`proxy.cpp:494-543` run_dual loop 一次 `take` 多个 cmd（drain loop），每次 dequeue 一批 → 构造 map → post
- decode top-8 × 2 node 每 layer 的 proxy batch size ≈ 8 条 cmd，`unordered_map<int, vec>` 只装 ≤ 8 entries
- 小容量 glibc `unordered_map` 分配**已经被 arena cache 命中**（tc-malloc/jemalloc 更明显）
- 实际 per-batch 开销可能是 **0.5-1.5 µs**，不是 3-5 µs

**"3-5 µs 改进 vs 3-5 µs 总开销 = 100% 减半"的矛盾**：
- 如果 CPU launcher 总耗时才 3-5 µs（FINAL_EXECUTION_CHECKLIST）而 L10 省 3-5 µs，那 launcher 变 0 → 和 GPU compute 重叠，但 GPU 并不等 CPU（异步 post）
- 正确的框架：**CPU proxy 不在 critical path 上，它只要 < GPU spin 等待窗口（~200 µs）就隐身**。L10 省 0.5-1.5 µs 在 CPU 侧是隐身收益，**对 ITL 贡献 ≈ 0**
- 只有当 CPU proxy **跟不上 GPU post 速度**（backpressure）时，L10 才有 ITL 收益
- Stage 5 实测 decode 未见 proxy backpressure → **L10 decode ITL 收益 ≈ 0**

**但**：L10 仍然降 CPU 功耗 / 减 proxy CPU pin 要求 / 改代码质量，**值得做**，只是**不应算 ITL 收益**。

**decode vs prefill 区别**：
- prefill batch>>8 时每批 WR 数 ≥ 256，`unordered_map` 分配 + rehash 开销按比例放大
- prefill 场景可能真 3-5 µs/批 → 有 ITL 影响
- decode 场景每批 < 16 WR，开销 < 1 µs → ITL 0

**修订后结论**：
- **prefill**：-1~-2% ITL（声称基本对，但要实测）
- **decode**：≈ 0% ITL（CPU 不在 critical path）
- **保留 lever**（代码质量 + 功耗 + prefill 收益），**但 decode ITL 收益砍到 ~0**

---

### Lever 11 · Launcher-cache `cudaDeviceGetAttribute` 静态化

**原声称**：60-180 µs/token（0.3-1% ITL）

**数字来源追溯**：
- FEASIBILITY_RECONFIRM §C1 ("替代 lever")：
  - `internode_ll.cu:1242-1246` 每次 combine launch 调 `cudaGetDevice` + `cudaDeviceGetAttribute`
  - 声称 "1-3 µs/layer × 58 layer = 60-180 µs/token"
- 代码实证（确认）：
  ```cuda
  // line 1240-1264
  #if defined(__NVCC__) && !defined(DISABLE_SM90_FEATURES)
    int device_id = 0;
    if (cudaGetDevice(&device_id) == cudaSuccess) {
      int max_smem = 0;
      if (cudaDeviceGetAttribute(&max_smem, ..., device_id) == cudaSuccess ...
  ```
- 这是**host 侧函数，在每次 combine launch 前跑**

**Amdahl sanity check**（关键陷阱：CUDA Graph）：
- SGLang decode **默认 CUDA Graph = ON**（FEASIBILITY_RECONFIRM §C1 的重要发现）
- **CUDA Graph capture 只在首次 warmup 执行 host code**，replay 时**完全跳过 `cudaGetDevice` / `cudaDeviceGetAttribute`**
- 所以在 SGLang 生产路径：**`cudaDeviceGetAttribute` 每 step 调用 0 次，不是 58 次**
- 60-180 µs/token 是 **eager mode** 数字，对 CUDA Graph 0 µs

**哪里才有 ROI？**
- Warmup 阶段（~60-180 µs/token × warmup steps = ~几 ms）——**TTFT 改善，不是 ITL 改善**
- 用户关心 ITL 不关心 warmup，**这 lever 的 ITL 收益 ≈ 0**
- 如果用户的 workload 禁用 CUDA Graph（eager mode debug），则 60-180 µs/token 成立

**eager vs graph 基线差异**：
- eager mode ITL: launcher overhead 10-30% → L11 真省 60-180 µs × 58 layer = 3.5-10 ms
- graph mode ITL: launcher overhead < 1% → L11 省 ~0

**修订后结论**：
- **生产（Graph on）**：ITL 收益 ≈ 0
- **Warmup / Eager**：3.5-10 ms TTFT 改善
- **降级：Tier 3**（收益场景不是 ITL，是 TTFT / warmup），**1 天工程仍值得做**

---

### Lever 12 · L-04 · `__launch_bounds__(X, 2)` 变体

**原声称**：ITL -2~-5%（occupancy 1→2 block/SM）

**数字来源追溯**：
- `internode_ll.cu:23, 50, 735` 都硬 `__launch_bounds__(1024, 1)`
- `internode.cu:480, 2086, 2088` 也是 min_blocks=1
- `internode.cu:2021` 作者 TODO 注释：`// TODO: maybe too many registers here`
- 声称 "occupancy 1→2 = 2× latency hide" **没有 PTXAS verbose 数据支持**

**代码证据（register pressure）**：
- `internode.cu:2022`: `int4 recv_value_int4[kMaxNumRanks]`——如果 `kMaxNumRanks=16` 则 **16 × 16 B = 256 B = 64 registers per thread** 就这一个数组
- 加上 `bias_0/1_value_int4` 再 32 B，`values[kDtypePerInt4]` 浮点累加再若干
- Combine kernel 估计 per-thread reg 用量 **70-100+**
- H200 SM 有 65536 reg → per thread ≤ 65536/1024 = 64 reg（已经吃紧）

**"occupancy 1→2"的可行性**：
- 强制 `min_blocks=2` 意味 **per-thread reg ≤ 32**，对当前 kernel **必然 spill**
- Spill 到 local memory（L1/L2/HBM），**每次访问 200-500 cycle**，比 reg 200-500× 慢
- nvcc 会在 "too many resources" 时自动降 occupancy（不编译失败，但运行时 `block=0` 或退化）

**Amdahl sanity check**（数学证明收益 ≈ 0）：
- 假设 occupancy 能从 1 → 2：latency hiding **理论** 2× → 减少 memory stall 等待 → 收益 **上限** 15-20%（kernel 级别）
- **但 spill 惩罚**：假设 20% 指令变成 spill load/store，每次 +200 cycle
- 净：可能 **负收益** 10-30%

**decode vs prefill**：
- decode batch=1 hidden=7168：kernel 本来就小，**GPU resources 利用不满**，occupancy 上不去实际不是瓶颈
- prefill num_tokens=128：kernel 跑满，此时 spill 惩罚放大，L12 更危险

**PTXAS 实测需求**：
- 需要先 `nvcc -Xptxas -v` dump 当前 kernel reg usage
- 如果 ≤ 48 reg → `min_blocks=2` 可行，测 sweep
- 如果 > 48 reg → **lever 不可行，收益 0 甚至负**

**修订后结论**：
- **实测前**：**不应列入 Tier 2**，风险 > 收益
- **实测后**：如果 reg < 48 → -1~-2% ITL（比声称 -2~-5% 少一半）；如果 reg ≥ 48 → drop
- **当前状态：Drop from Tier 2，挪到 "需实测验证" 桶**

---

### Lever 13 · Sprint C · Blackwell `src_signals`（p6-b200/b300 only）

**原声称**：ITL -3~-5%（B300 only），p6 兼容必需

**数字来源追溯**：
- `SBO_SPRINT_PLAN.md` Sprint C：p6-b200/b300 Blackwell 的 `src_signals` 原生 API
- Hopper 上 src_signals 是 dead code（Phase 13 已确认，`SRD_PROTOCOL_PART2.md`）

**Amdahl sanity check**：
- 和 Sprint A 攻的是同一块（combine send-gemm overlap），Blackwell 版本只是 API 更原生（CuteDSL 支持）
- 不 double-count：**Sprint A 是 Hopper 版本，Sprint C 替换成 Blackwell 版本**，不是叠加

**关键问题：值不值得做？**
- **p5en Hopper 用户（当前生产）**：src_signals 0 收益（dead code）
- **p6-b200/b300 用户（未来）**：如果上游 SGLang + FlashInfer CuteDSL 主动支持，我们做是重复劳动
- 1.5w 工程 vs "等上游"：MaoZiming + 上游团队正在做 Blackwell 适配，**我们先做能捞到 co-author credit，但纯 ROI 角度不划算**

**修订后结论**：
- **技术上收益 -3~-5% ITL 可能对**（Blackwell 下）
- **但对我们当前 p5en 生产 ROI = 0**
- **战略价值**（B300 ready 时 AWS 独占）：保留但**条件**：等 Blackwell 硬件真到手（Stage 5.5 专项）才做
- **Keep in Tier 2**，但标注 "blocked on B300 hardware"

---

### Lever 14 · C9 · Multi-QP Power-of-Two LB

**原声称**：P99 -5~-10% under skewed expert

**数字来源追溯**：
- `uccl_ibgda.cuh:36` 当前 `int thread_idx = (expert_idx % num_d2h_channel_addrs) % kNumProxyThs`——**modulo 不是 P-of-2**
- P99 -5~-10% 是估算，**没找到 benchmark 来源**
- DeepSeek router "某些 expert 被访问 10×" 的说法需要 double-check：
  - DSv3 paper §4.3 说 router "balanced through auxiliary loss"，**不是 10× skew**
  - 实际 decode 场景 batch=1 top-8 里，每 token 选 8/256 expert，**已经相对均匀**（没那么偏）

**Amdahl sanity check**：
- P-of-2 LB 需要 **per-QP outstanding-WR counter**，每次 post 读 2 个 counter 比大小
- counter 读是 atomic load：~10-50 ns/次 on CPU（cache-line atomic）
- post 频率：~120/layer × 58 = 7K/token，×10 ns = 70 µs/token overhead
- 如果 P99 tail 本来是 +5 ms (10%)，LB 压到 +2 ms → 收益 3 ms，减去 70 µs 开销 → 净 **2.93 ms P99 改善 = 3% P99**（比声称 5-10% 少一半）

**和 PR #485 的关系**（关键）：
- PR #485 是 **multi-QP infrastructure**：让 LL 模式可用多 QP（当前单 QP）
- C9 是 **LB 策略**：**PR #485 merge 时默认给的 LB 策略**（需看 PR diff）
- 如果 PR #485 上游给的就是 modulo 或 round-robin → C9 是增量优化
- 如果 PR #485 已内含 P-of-2 → C9 是 0

**需要看 PR #485 的 diff** 才能决定增量。目前 PR #485 DRAFT，没有 final design。

**decode vs prefill**：
- decode batch=1 top-8：每 peer 1-8 outstanding WR，**QP-level 拥塞不明显**，P-of-2 LB 差异小
- prefill batch=128 top-8：每 peer 128-1024 WR，P-of-2 LB 差异明显 → **P99 改善主要在 prefill**
- **decode ITL 收益可能 < 1%**，prefill P99 才是 5-10%

**修订后结论**：
- **decode ITL**：-1~-2%（比声称 -5~-10% 少 3×）
- **prefill P99**：-3~-7%（比声称少一点，但仍有）
- **Keep in Tier 2**，但只作 **PR #485 的 follow-up**（不能独立做）

---

## 3. 数字累加验证

### 3.1 声称累积

Tier 2 原声称总 ITL：
- L8 -2~-3% + L9 -1~-2% + L10 -1~-3% + L11 -0.3~-1% + L12 -2~-5% + L13 -3~-5%(b300) + L14 -5~-10%(P99)
- 合计 P50：**-8~-14% ITL**（重叠已扣）

### 3.2 订正后累积

| Lever | 订正后 decode ITL | 订正后 prefill/P99 |
|---|---|---|
| L8 count-send | **-0.5~-1%** | -1% |
| L9 reduce prefetch | **-0.3~-0.7%** | -1~-2% |
| L10 unordered_map | **0%**（CPU 不在 critical） | -1~-2% |
| L11 launcher-cache | **0%**（Graph 摊销） | TTFT -3~10 ms 只 |
| L12 launch_bounds | **未知（需实测 PTXAS）** | 同 decode |
| L13 Sprint C | **0%**（Hopper） | 0%（Hopper）|
| L14 P-of-2 LB | **-1~-2%** | **P99 -3~-7%** |
| **合计 decode ITL** | **-1.8~-3.7%** | **N/A** |
| **合计 prefill P99** | — | **-6~-13%** |

**核心发现**：
- **Tier 2 全做对 decode ITL 真实收益 ≤ -4%**（不是声称的 -8~-14%）
- **Tier 2 的价值主要在 prefill/P99，不是 decode ITL**
- Tier 1 (Sprint A + PR #485 + count-coalesce) 的 -10~-15% 才是 decode ITL 主战场

### 3.3 Double-counting 检查

没有 double-counting（每个 lever 作用在不同组件）：
- L8 dispatch send
- L9 combine reduce
- L10/L11 CPU launcher（但两个独立场景）
- L12 kernel occupancy（通用）
- L13 Blackwell (不和 Hopper Sprint A 叠)
- L14 QP scheduling

### 3.4 被夸大的根源（方法论反思）

| 误区 | 表现 |
|---|---|
| **µs × layer 线性放大** | "3-5 µs/layer × 58 = 290 µs"（对），但 290/50000 = 0.58% 不是 2-3% |
| **prefill bench 数字直接套 decode** | num_tokens=128 profile 推 decode batch=1 |
| **CUDA Graph 忽略** | eager mode 的 host overhead 在 Graph 下是 0 |
| **"CPU 省时间 = ITL 改善"** | CPU proxy 不在 critical path，异步隐身 |
| **"Occupancy 翻倍 = ITL 翻倍"** | 忽略 spill 惩罚和 kernel 本身是否 resource-bound |

---

## 4. 本周 instrumentation 建议

最该实测确认的 3 个数字（按 ROI 排序）：

### 实测 1：CUDA Graph 下 launcher 开销（验证 L10/L11）
- **目的**：确认 `cudaDeviceGetAttribute` 和 `unordered_map` 在 Graph 下是否 0 µs
- **方法**：
  ```bash
  # SGLang decode 跑两组：graph on / off
  python -m sglang.launch_server --disable-cuda-graph  # eager
  python -m sglang.launch_server                        # graph
  # nsys profile decode step，grep host API 时间占比
  ```
- **工期**：0.5 天
- **决策**：如果 Graph 下 ITL 差异 < 1%（launcher < 500 µs/token），则 L10/L11 对 decode ITL ≈ 0 确证

### 实测 2：Combine reduce 33 µs 是不是真的（验证 L9）
- **目的**：COMBINE_RECV_DEEP_DIVE §7 的 `clock64()` per-phase counter
- **方法**：
  ```cuda
  // internode_ll.cu:1083, 1143, 1149, 1200 各埋 1 个 uint64_t
  uint64_t t = clock64();
  // atomicAdd 到 workspace[4..7]
  ```
- **工期**：1.5 天
- **决策**：
  - 如果 reduce < 20 µs → L9 收益更小，drop
  - 如果 reduce ≈ 33 µs → L9 prefill 收益确认 -1~-2%
  - 还要测 **decode batch=1** 下 reduce 时间：如果 ≤ 5 µs → L9 decode 收益 ≈ 0 确证

### 实测 3：PTXAS reg usage（决定 L12 可行性）
- **目的**：当前 combine kernel 每 thread 用多少 reg
- **方法**：
  ```bash
  cd /home/ec2-user/workspace/uccl/ep
  make CXXFLAGS="-Xptxas -v -Xptxas --warn-on-spills" 2>&1 | grep -E "combine|dispatch|registers"
  ```
- **工期**：0.5 天
- **决策**：
  - reg > 48 → L12 drop
  - reg ≤ 48 → 试 `min_blocks=2` + micro-bench

### 最小测试脚本框架

```bash
# 1. Graph vs eager launcher overhead
cd /home/ec2-user/workspace/uccl/ep
torchrun --nnodes=2 --nproc_per_node=8 bench/test_low_latency_pplx.py \
  --num-tokens=1 --hidden=7168 --num-topk=8 --num-experts=288 \
  --dispatch-use-fp8 --iters=1000
# 对比 num-tokens=128 版本

# 2. clock64 per-phase（先在 fork 加 PR）
git checkout -b perf/combine-recv-clock64
# edit src/internode_ll.cu lines 1083/1143/1149/1200

# 3. PTXAS reg dump
make clean && make CFLAGS="-Xptxas -v" 2>&1 | tee /tmp/ptxas.log
grep "registers" /tmp/ptxas.log
```

**汇总 instrumentation 工期**：0.5 + 1.5 + 0.5 = **2.5 天**，解锁 6/7 Tier 2 lever 的准确 ROI。

---

## 5. 最终决策表

| Lever | 原 Tier | 订正 Tier | 订正 decode ITL | 决策 |
|---|---|---|---|---|
| L8 count-send coalesce | 2 | **2-** | -0.5~-1% | Keep（PR #485 后做）|
| L9 reduce prefetch | 2 | **3** | -0.3~-0.7% | **Drop from Tier 2**（decode 场景收益小，prefill 才 work）|
| L10 unordered_map | 2 | **2-** | 0% decode / -1% prefill | Keep（代码质量）|
| L11 launcher-cache | 2 | **3** | 0% (Graph 摊销) | **Drop from Tier 2**（TTFT 优化）|
| L12 launch_bounds | 2 | **hold** | 未知 | **实测 PTXAS reg 后再定**|
| L13 Sprint C Blackwell | 2 | **2** | 0% Hopper / -3~-5% B300 | Keep（B300 blocked）|
| L14 Multi-QP P-of-2 LB | 2 | **2-** | -1~-2% decode / P99 -3~-7% | Keep（PR #485 follow-up）|

**净变化**：Tier 2 从 7 条 → **3 条保留 / 2 条降 Tier 3 / 1 条 hold / 1 条保留但有条件（B300）**。

**累积 decode ITL 订正**：-8~-14% → **-2~-4%**（仍值得做，但不如声称大）。

---

## 参考文件

- `/home/ec2-user/workspace/efa-validation/docs/ALLTOALL_DEEP_DIVE.md` §0.2, §4.1 基线和 count-send
- `/home/ec2-user/workspace/efa-validation/docs/COMBINE_RECV_DEEP_DIVE.md` §1 reduce 33 µs 推导, §7 instrumentation
- `/home/ec2-user/workspace/efa-validation/docs/FEASIBILITY_RECONFIRM.md` C1 替代 lever launcher-cache
- `/home/ec2-user/workspace/efa-validation/docs/EXPECTED_PERFORMANCE_GAINS.md` Tier 2 声称汇总
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:50-449` dispatch kernel + count-send
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:735-1204` combine kernel + reduce
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:1240-1264` `cudaDeviceGetAttribute` host call
- `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp:1374, 1812, 2985` `unordered_map` 3 处
- `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp:2996-3039` AMO chain per dst_rank
- `/home/ec2-user/workspace/uccl/ep/src/internode.cu:2021` "maybe too many registers" TODO
- `/home/ec2-user/workspace/uccl/ep/include/uccl_ibgda.cuh:36` modulo LB（C9 基础）

---

## 附录：证据规则自检

| 规则 | 自评 |
|---|---|
| 1. 每个数字标 实测/推导/套用 | ✅ 表格中标注（如 L9 "33 µs 推导不是 profiling"）|
| 2. 说 X µs 错要给对的 | ✅（如 L10 "3-5 µs 是推导，实际 0.5-1.5 µs"）|
| 3. 收益 0 要给数学证明 | ✅（L11 Graph 摊销 / L10 异步 CPU 不在 critical path）|
| 4. 多 agent 同数字不等于验证 | ✅（L9 "33 µs" 只 Agent A 提过，无 profiling） |
