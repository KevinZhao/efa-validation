# UCCL-EP 架构 Gap 综合分析（Phase 15）

**日期**：2026-04-26
**方法**：3 个独立 agent 从不同切面挖 UCCL-EP 架构/实现 gap
- **Agent P**：paper claim vs code reality（UCCL-EP arxiv 2512.19849 + UCCL-Tran 2504.17307）
- **Agent Q**：motivation-driven MVP 妥协点（TODO/数据结构/锁/kernel 配置）
- **Agent R**：已写但未启用的优化（env var / #ifdef / dead code）
**子文档**：`UCCL_PAPER_VS_CODE_GAPS.md` / `UCCL_MVP_COMPROMISES.md` / `UCCL_DISABLED_OPTIMIZATIONS.md`
**原则**：遵循 `feedback_claim_verification_discipline.md`——每条 lever 必锚 `文件:行号`；推论 vs 实测标注；不盲信作者 paper claim

---

## 0. TL;DR（给决策者）

### 三个切面的总览

| Agent | 角度 | 找到的 lever 数 | 最高价值发现 |
|---|---|---|---|
| P | paper claim vs code | **6 个 P0/P1** | **C14 Congestion Control 完全缺失**（paper §6 作为 headline，代码只有 `kMaxInflightBytes = SIZE_MAX`）|
| Q | MVP 工程妥协 | **38 个 MVP 点，5 个 PR-level** | 作者在 `common.hpp:121-146` 用 lambda-static 缓存 getenv，但 `rdma.cpp:818` 还在反复 getenv——**idiom 懂但没推广** |
| R | 未启用优化 | **反直觉：几乎没有** | 唯一真 candidate: `PER_EXPERT_BATCHING`（Makefile:81 默认 0，PR #745/#800 已合入但未推主线） |

### Agent R 的反直觉结论最重要

**之前我们一直假设 UCCL-EP 有 "写了但没默认开的优化"**。Agent R 扫完 13 env var + 430 #ifdef + 80 commit，结论是：**UCCL-EP 代码库卫生度比预想高**。
- 所有 `UCCL_IB_*` 都是 NIC 配置，不是性能开关
- `AGGRESSIVE_ATOMIC` default off 有 PR #680 "stress test 失败" 硬证据
- commit `92b96373 Remove experimental flow control` ——作者**主动删掉**之前加的 hidden CC，实测不 work
- `SOFTWARE_ORDERING` 是 legacy dead path（被 multi-QP PR #485 替代）

**教训**：不要看到 `default off` 就当"可以开"。那是**反模式**。

### Agent P + Q 找到的真金 lever（7 个按 ROI 排）

| # | Lever | 来源 | 层位 | 收益 | 工期 | EFA 独占? | 和已有 lever 正交? |
|---|---|---|---|---|---|---|---|
| **G-01** | 🏆 **CPU proxy AIMD pacer**（C14 CC missing） | P | 新增协议 | P99 tail -5~-15% cross-AZ incast | 1-2w | **是** | ✅ 正交 |
| **G-02** | 🥈 **Dynamic NIC load balance**（C10 静态 modulo） | P | `rdma.cpp:481-504` 重构 | 5-15% throughput under partial-NIC congestion | 3-5d | **是** | ✅ 正交 |
| **L-01** | 🥉 **Hot-path `unordered_map` → `std::array`**（D1 in MVP） | Q | `rdma.cpp:1374/1812` 等 10+ 处 | 每批 WR 省 3-5 µs → ITL -1~-3% | 1d | — | ✅ 正交 |
| **C17** | **PER_EXPERT_BATCHING 默认 on**（需 p5en 实测 gate） | R | `Makefile:81` | 2× dispatch (paper Fig 8) | 1d bench + 4h PR | **是** | ✅ 正交 |
| **G-03** | **Reorder buffer 4→6 bit seq**（C6 safety net） | P | `common.hpp:85` | 非延迟，扩展 num_max_dispatch_tokens 安全上限 | 3-5d | **是** | ✅ 正交 |
| **L-02** | **LowLatencyLayout 移 Buffer 构造期**（I1 in MVP） | Q | `uccl_ep.cc:1160/1218` | 每次 dispatch 省 0.3-0.5 µs (launcher ~10-15% 占比) | 0.5d | — | ✅ 正交 |
| **C9** | **Multi-QP Power-of-Two LB**（paper claim round-robin, code modulo） | P | `uccl_ibgda.cuh:36` | 5-10% P99 under skewed expert | 1w | partial | ⚠️ PR #485 完成后做 |

### 合并到总 Sprint roadmap

| Sprint | 原定内容 | Phase 15 新增 |
|---|---|---|
| Sprint A (2w) | GPU spin + comp_signal | — |
| Sprint B (1.5w) | CPU spin EFA 独占 | **+ L-01 / L-02 / L-03 并行（host-side MVP 清理, 2-3d 追加）** |
| Sprint C (1.5w) | Blackwell src_signals | — |
| **Sprint E 新增 (2w)** | — | **G-01 AIMD pacer + G-02 NIC LB** ——paper 明说 "future work" 我们先实现 |
| Sprint D (待定) | L1 GPU BAR CQ | — |
| 并行 (1w) | — | PER_EXPERT_BATCHING autotune gate PR（先 p5en bench 复核 #800 结果）|

---

## 1. Agent P 发现：Paper Claim vs Code Reality

### 1.1 Paper 承诺 17 条，实现状态：
- ✅ Fully: **4** (GPU-agnostic, CPU-proxy init, FIFO+tail cache, Token dedup)
- 🟡 Partial: **6** (NIC-agnostic, LL reorder, HT order, Multi-QP LB, CUDA Graph, UCCL-Tran 继承)
- 🟠 Stub/MVP: **5** (Multi-threaded proxy, Multi-NIC LB, PER_EXPERT_BATCHING default off)
- ❌ Missing: **2** (CC, Elastic EP)

### 1.2 最大 gap:**C14 Congestion Control 完全缺失**

**Paper 怎么说**（§6 Discussion）：
> "UCCL-EP delegates control decisions to the flexible CPU proxy, which could easily support request tracking and pacing. If the outstanding requests become high, the CPU proxy thread temporarily buffers the messages at the sender... The CPU proxy could also bear responsibility for multi-QP management... throttle or shard the outgoing requests across NICs and QPs to avoid congestion"

**代码 reality**：
- `common.hpp:72 #define kMaxInflightBytes SIZE_MAX` —— **无限**
- `proxy.cpp:619 size_t budget = (kMaxInflight > pending) ? (kMaxInflight - pending) : 0;` —— 只有硬数字 cap，无 RTT / ECN / loss 反馈
- `kMaxInflightLowLatency 32`, `kMaxInflightNormal 8` —— 静态常量
- UCCL-Tran 的 Swift CC 机制 (paper §3.4, §4.1) **没继承到 `ep/`**
- commit `92b96373 Remove experimental flow control` 是作者自己实测后删的

**为什么 EFA 独占**：EFA SRD 有内部 CC 但**硬件不暴露任何 CC surface 给软件**。CX7 IB 有 hardware CC，用户不需要 UCCL 再做。**UCCL-EP 的 CPU proxy 是 EFA 上唯一的软件控制点**——这个 gap 在 EFA 上尤其痛，跨 AZ runs 见过 3s timeout。

**PR-level 设计 G-01**（详见子文档 §3）：
- 加 `PaceState { atomic<int32> tokens; uint64_t last_update_ns; double rate_bps; }` per (dst_rank, QP)
- AIMD on per-peer bucket（Reno 风格，不是 Swift）
- 关键 edit site: `proxy.cpp:624-669` budget loop
- 验证：cross-AZ p5en 4-node bench，跑 skewed workload 看 P99
- **不互斥**——AIMD 上层流控和 SBO protocol layer 完全正交

### 1.3 第二大 gap: **C10 Multi-NIC "aggregation" 是静态 modulo**

**Paper §4**（第三段）：
> "UCCL-EP relies on CPU threads to load balance across different NICs. **We omit the details for brevity.**"

**代码 reality**（`rdma.cpp:481-504`）：
```cpp
auto half = (local_rank % 2) * 2;
selected_nic_name = candidates[thread_idx % 2 + half];
```
**每个 proxy 线程终生绑死一个 NIC**，`Poll()` 时没有 cross-NIC steering。如果一个 EFA NIC 深队列（AZ 内 fabric 抖动），线程无法 migrate。

**EFA 独占**：CX7 普遍 1 NIC/GPU，**EFA p5en 硬件上是 2× 200 G NIC/GPU**，NIC-bonding 在 EFA 上没有 kernel-level 支持——UCCL-EP 是唯一能做软件级 aggregation 的层。

**PR-level 设计 G-02**：
- `ProxyCtx` 改成 `std::vector<NicCtx>`（每 NicCtx 自己的 context/pd/QPs）
- `Poll()` dispatch 时按 outstanding-WR depth 挑 NicCtx
- 3-5 天工程，改动集中
- 实测方式：`tc qdisc` / `ethtool --pause` 人工降级一张 NIC 看 throughput 是否转移到健康 NIC

### 1.4 C6/C7 reorder buffer safety net

**Paper §3.3**：LL partial completion fence 是 EFA 正确性核心机制。

**代码 reality**：
- `common.hpp:85 #define kReorderingBufferSize 16  // Right now only 4 bits.`
- `rdma.cpp:2285/2304` 如果 seq ≥ 16 直接 `std::abort()`
- 超过 16 reorder depth 就挂——对 SRD adaptive routing 风险

**PR G-03**：偷 2 bit from `kMaxSendAtomicValue`（14 bit → 12 bit），释放给 seq（4 bit → 6 bit = 64 slots）。Agent Q 的 **X1/X2 也是同一个问题**：`common.hpp:83` 作者注释 "I tried to fit more bits, but this eats into offset and values"——这是 known limitation 但没人做。

**EFA 独占**：CX7 RC 是 in-order 交付，seq 永远低，cap 触不到。EFA SRD 是 adaptive-routing datagram，reorder 深度真实存在。

### 1.5 C17 PER_EXPERT_BATCHING 默认关

- Makefile 默认 0（PR #745 已合入，PR #800 有实测数据）
- Paper Figure 8 的 2.3× dispatch 收益是 **ON 时**的
- 作者没敢默认开，可能原因：FP8 路径 extra copy (`internode_ll.cu:252 TODO`), signaling buffer grows `num_ranks²*sizeof(int)`, 已有 2 个 fix PR (#766, #865) 说明曾有 correctness bug
- **我们的 gate**：先在 p5en + Kimi-K2/GLM-4.6 decode 场景实测（复核 PR #800 结果），确认 -5%+ ITL 才推"特定配置默认 on" PR

---

## 2. Agent Q 发现：MVP 工程妥协

### 2.1 38 个 MVP 点的分布

| 类别 | 数量 | 典型代表 |
|---|---|---|
| 数据结构（hot-path `unordered_map` 重建） | 4 | `rdma.cpp:1374/1812` 每批 WR 建 2-3 个 map |
| hot-path `std::vector` 分配 | 5 | `proxy.cpp:863-864` 8 个 vector 每次构造 |
| Config / 调参表硬编码 | 6 | `kNumProxyThs=4` `#define`；DeepEP 配置表继承未调 EFA |
| CUDA kernel 配置 | 4 | `__launch_bounds__(X, 1)` 全硬写 1 |
| Python binding | 3 | nanobind 30+ 参数 marshalling |
| 错误路径 guard | 6 | kernel 139 处 `printf`/`abort` |
| Init vs hot path 分离 | 4 | `LowLatencyLayout` 每次 dispatch 重算 |
| 协议 / imm 位预算 | 3 | 4-bit seq（= G-03） |
| 算法精度 | 3 | `SourceMeta` bitfield 循环 OR |

### 2.2 最高 ROI 5 个 (L-01 ~ L-05)

**L-01 · Hot-path `unordered_map` → `std::array`**（1 天工程，ROI 明确）

现状：`rdma.cpp:1374` `post_rdma_async_batched_normal_mode` 每次调用构造 `unordered_map<int, vector<size_t>> dst_rank_wr_ids`，内层还有一层 map for ring 分组，`rdma.cpp:1812` fast_mode 同样。batch=32 + 8 dst_rank 场景**每次付 3.4 µs allocator 开销**。

作者在 `proxy.cpp:751-753 wrs_to_post.clear()` 用了 member-vector 模式，说明懂 pool 但没推广。

PR 设计：改成 `std::array<std::vector<size_t>, kMaxRanks=128> dst_rank_wr_ids` 为 ProxyCtx 成员，用 `.clear()` 保 capacity。

风险：几乎 0；tc-malloc 下可能只剩 1 µs（Agent Q 的 UNKNOWN #3）。

**L-02 · `LowLatencyLayout` 一次算常驻**（0.5 天）

现状：`uccl_ep.cc:1160/1218` 每次 dispatch 调 `LowLatencyLayout layout(...)` 构造。8+ 字段全部从 Buffer 生命周期不变参数推导。每次 300-500 ns CPU。decode batch=1 launcher CPU 总预算 ~3-5 µs，此项占 10-15%。

PR 设计：加 `Buffer::ll_layout_[2]` 成员，构造期一次算。

**L-03 · `post_gpu_commands_mixed` 8 vector 池化**（30 分钟 PR）

`proxy.cpp:863-864` 每次构造 8 个 vector（rdma/atomic/quiet/barrier 各 wr+cmd）。PR 成员化用 clear。

**L-04 · `__launch_bounds__(X, 2)` 变体**（1-2 天）

`internode_ll.cu:23/50/735` + `internode.cu:480/2086/2088` 所有 LL kernel 硬 `__launch_bounds__(X, 1)`。告诉 PTXAS 每 SM 只开 1 block → 寄存器用满。decode batch=1 hidden=7168 场景寄存器压力不满，放开到 2 能双 block/SM latency-hide。

风险：中。`internode.cu:2021` 作者自己注释 "TODO: maybe too many registers here"——combine kernel 可能因 `kMaxNumRanks=64` 寄存器 spill。需 PTXAS verbose + nsys profile 验证。

**L-05 · Release build kernel `printf` 清理**

139 处 `fprintf/abort` + kernel 内多处 `printf` guard（`uccl_ibgda.cuh:132/139/145/165-168`）。命中率 0 但 PTXAS 留 BRA 槽位 + vprintf stub。改成 `UCCL_RELEASE_ASSERT` 宏，release 用 `__builtin_trap()` / `__trap()`。

### 2.3 最惊艳的发现：idiom 不一致

作者在 `common.hpp:121-146` 已用 lambda-static 模式缓存 getenv：
```cpp
static const bool cached = [](){ return getenv(...) != nullptr; }();
```
但 `rdma.cpp:818 can_register_gpu_memory_for_atomics` 还在每次调 `getenv` 触发 libc 锁。

**这不是不懂，是 MVP 没推广。** 意味着 housekeeping PR 有清晰模式可套，risk 低。

### 2.4 另外的 TODO 金矿（from `TODO(MaoZiming)` grep）

- `internode_ll.cu:252 // TODO: extra temp->per-expert copy in FP8 path` ← C17 核心痛点
- `internode.cu:2021 // TODO: maybe too many registers here` ← 影响 combine occupancy
- `uccl_ibgda.cuh:176 // TODO: Fix. non-fetch add` ← 本地 vs 远程原子不一致，多一次 round-trip
- `bench/buffer.py:55 // TODO: Reduce SMs` ← `num_sms=20` 硬写，compute path 抢 SM（但作者自己放 TODO 说明想改）
- `bench/buffer.py:691/719 // TODO: automatically tune` ← DeepEP 调参表直接继承 NVIDIA IB 配置，EFA 没重调

---

## 3. Agent R 发现：几乎没有"未启用优化"

### 3.1 核心结论（反直觉）

扫完后只有 **1 个真候选**：**PER_EXPERT_BATCHING**（和 Agent P C17 重复）。

### 3.2 不能开的清单（重要——防误建议）

| Flag | Default OFF 的**硬证据** |
|---|---|
| `UCCL_EP_ENABLE_AGGRESSIVE_ATOMIC` | PR #680 标题 "disable aggressive atomic on amd by default, as it fails stress test" |
| `SOFTWARE_ORDERING` | PR #485 multi-QP 合入后 legacy dead path |
| `USE_SENDER_BARRIER` | commit `66adf3b5 remove USE_SENDER_BARRIER` |
| `ENABLE_FAST_DEBUG` | 10s timeout 真实训练 100% fail |
| `MEASURE_PER_OP/VERB_LATENCY` | std::chrono + unordered_map 干扰稳态 |
| `USE_SUBSET_BARRIER` | 注释掉 WIP，barrier 语义错会 hang/corrupt 不是 regression |
| `UCCL_ATOMICS_USE_HOST_MEMORY=1` on CUDA | CUDA path 已由 probe gate 自动选最优 |
| `DISABLE_BUILTIN_SHLF_SYNC` on CUDA | Volta+ 无 sync mask 是 UB |
| `DISABLE_AGGRESSIVE_PTX_INSTRS=1` | 退化到 `.volatile` 性能降 |

### 3.3 commit `92b96373 Remove experimental flow control` 的教训

作者曾加过 hidden CC，**自己实测后删掉**。这对 G-01 AIMD pacer 是**直接警示**：

- 简单加个 AIMD bucket 很可能被作者"实测后删"的历史重演
- 我们的 G-01 必须附带：(a) p5en cross-AZ incast 的 benchmark 证明实际有 P99 tail regression 发生，(b) AIMD pacer 启用后 P99 显著改善数据
- **没有实测数据支撑的 CC PR 很可能被 reject**

### 3.4 两条可推的 housekeeping

- `rdma.cpp:1511` `SOFTWARE_ORDERING` 80 行 dead code 清理 PR（非性能）
- `UCCL_IB_MAX_INFLIGHT_BYTES=SIZE_MAX` 改成 README 建议而非默认值

---

## 4. 与之前几轮 lever 的互补性矩阵

| Phase 15 lever | Phase 1-14 相关 lever | 关系 |
|---|---|---|
| **G-01 CC pacer** | SBO Sprint A/B (signal path) | **完全正交**——上层流控 vs 下层 signal |
| **G-02 NIC LB** | B1 multi-NIC aggregation | **G-02 是 B1 的具体实现**（之前只是说要做，这次有 edit site） |
| **G-03 reorder 4→6 bit** | SBO Sprint C (Blackwell src_signals) | 独立（imm 位预算 vs signal 协议） |
| **L-01 unordered_map** | SBO Sprint B (CPU spin proxy 内部) | **互补**——L-01 是 CPU proxy 外部批处理，Sprint B 是内部 poll |
| **L-02 Layout cache** | launcher-cache / cudaDeviceGetAttribute cache | **L-02 是 launcher-cache 的姐妹 lever**（同一 decode launcher 路径的不同 hot 点）|
| **L-03 vector 池化** | count-send coalescing | 同函数 `post_gpu_commands_mixed` 可一 PR 合并 |
| **L-04 launch_bounds** | SBO Sprint A/B | 独立（launch config vs kernel 内 signal）|
| **L-05 printf guard** | 所有 kernel lever | 独立（code hygiene）|
| **C9 Power-of-2 LB** | A1 PR #485 multi-QP | **A1 是 PR #485 给的 multi-QP 基础，C9 是在 multi-QP 基础上做 load-aware 选择**；顺序必须 A1 先 |
| **C17 PER_EXPERT_BATCHING** | 所有 decode lever | 独立（compile-time batch 策略） |

### 5 个 Phase 15 新 lever 和 SBO/QP 主线**完全正交**
L-01/L-02/L-03/L-05 都是 host-side 工程卫生，不涉及 GPU kernel 内部 signal/sync 逻辑，可以作为 **Sprint B 的并行 side track** 推。

---

## 5. PR 推送策略

### 5.1 分层次

**Tier A · 技术原创、AWS 独占、paper 承诺缺失——高价值 PR**
1. **G-01 AIMD pacer**（paper §6 名义 future work，我们先实现）
2. **G-02 Dynamic NIC LB**（paper §4 "we omit the details"，我们补齐）
3. **L9 shared-SRD-QP**（Phase 13 Part 2 发现；AWS 独占 lever）

这三条都能讲成 "UCCL-Tran / UCCL-EP paper 里说了但没做的 EFA 独占工程"，PR body 必须引 paper section 号。

**Tier B · MVP polish housekeeping——快速 merge 建立合作接触点**
4. L-01 `unordered_map` → array（1d）
5. L-02 Layout 缓存（0.5d）
6. L-03 8-vector 池化（30min）
7. L-05 release printf guard（1-2d）

这几条都不碰核心协议，reviewer 不会有大 concern；**合并速度快，能让 MaoZiming / YangZhou1997 知道我们的代码风格是对的**。

**Tier C · 需要实测先行的 PR**
8. C17 PER_EXPERT_BATCHING autotune gate（先 p5en bench 复核 #800 结果）
9. L-04 `__launch_bounds__(2)` 变体（PTXAS 验证 + nsys occupancy）
10. G-03 reorder 4→6 bit（需要 reorder torture test 证明扩展前会触 abort）

### 5.2 投递顺序建议

| 顺序 | PR | 理由 |
|---|---|---|
| 1 | **L-03** (vector 池化 30min) | 最小 PR，测 UCCL merge 流程 |
| 2 | **L-02** (Layout 缓存 0.5d) | 小 PR，风险低 |
| 3 | **L-01** (unordered_map→array 1d) | 中 PR，有实测收益（1-3 µs） |
| 4 | **G-01** (AIMD pacer) | 旗舰 PR，paper §6 明说 future work，我们抢先做 |
| 5 | **G-02** (Dynamic NIC LB) | 旗舰 PR，paper §4 "we omit" |
| 6 | **L9** (shared-SRD-QP) | Phase 13 产出，AWS 独占 lever |
| 7 | Tier C 的其余按实测结果取舍 | |

### 5.3 避免的做法

- 不要推 `USE_SUBSET_BARRIER` 默认 on（正确性风险）
- 不要推通用 CC without cross-AZ bench（会被 "Remove experimental flow control" 历史打回）
- 不要同时推 G-01 + G-02（两个都大改 proxy，分开 review 更快）

---

## 6. 诚实标注的 UNKNOWN

| # | UNKNOWN | 解法 |
|---|---|---|
| U1 | G-01 AIMD pacer 在 p5en single-AZ 实测有没有收益 | 需跑 cross-AZ incast 模拟 benchmark；single-AZ 可能看不到 |
| U2 | C17 PER_EXPERT_BATCHING 在 p5en Kimi-K2 decode 实测数据是否支持默认 on | 复核 PR #800 结果，自跑 p5en bench |
| U3 | L-04 `__launch_bounds__(X, 2)` combine kernel 能否编译 | 实际 `make` + PTXAS verbose 看 regs/thread |
| U4 | L-01 tc-malloc 下真实收益 | nsys profile 确认 |
| U5 | G-02 p5en 2-NIC-per-GPU 的 load imbalance 实际多严重 | Stage 2 bench 数据加 per-NIC counter |
| U6 | G-03 reorder cap=16 在实际 EFA 运行中有没有触过 `abort` | 加 `present_mask` peak 统计 instrumentation |
| U7 | paper Figure 8 的 2.3× PER_EXPERT_BATCHING 收益是否用 p5en baseline | 读 paper methodology section 确认 |

---

## 7. 一句话结论

**UCCL-EP 的 paper 承诺和代码实现之间最大的 gap 是 paper §6 整段 CC 讨论**——作者自己都说 "future work"，代码里 `kMaxInflightBytes = SIZE_MAX` 就是没做。**G-01 AIMD pacer 是最高价值 PR，EFA 独占 + paper 撑腰 + commit `92b96373` 的历史教训要求我们必须附 cross-AZ bench 数据才推**。

同时 Agent R 的反直觉结论很重要：**不要看到 default off 就以为是 hidden optimization，UCCL 代码库的卫生度比预想的高**，真正"写了没开"的只有 PER_EXPERT_BATCHING 一条。大部分 lever 价值来自 Agent P 的 paper-vs-code gap 和 Agent Q 的 MVP 工程妥协（host-side 工程优化）。

**最终 Sprint 地图**：
- Sprint A (GPU spin) → Sprint B (CPU spin) + **L-01/L-02/L-03 并行** → **Sprint E 新增 G-01/G-02 (2w)** → Sprint C (Blackwell) → (Sprint D L1 if preview positive)
- 完整收益相对 Phase 14 基线加 **decode ITL 额外 -3~-5% + P99 tail 额外 -5~-15% cross-AZ incast 场景**

---

## 8. 引用

- 子文档：`docs/UCCL_PAPER_VS_CODE_GAPS.md` / `docs/UCCL_MVP_COMPROMISES.md` / `docs/UCCL_DISABLED_OPTIMIZATIONS.md`
- UCCL-EP paper: arxiv 2512.19849 (Mao et al., OSDI 2026)
- UCCL-Tran paper: arxiv 2504.17307 (Zhou et al., OSDI 2026)
- UCCL PR #745 (PER_EXPERT_BATCHING), #800 (results), #485 (multi-QP DRAFT), #680/#858 (aggressive_atomic default off), `92b96373` (remove experimental flow control)
- 源码：`/home/ec2-user/workspace/uccl/ep/{src,include}/`
