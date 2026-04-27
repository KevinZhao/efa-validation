# SGLang SBO + `comp_signal` 在 UCCL-EP / EFA 的深度优化点调研

**日期**：2026-04-25
**调研方式**：4 个独立并行 agent（DeepEP 协议 / SGLang 集成 / UCCL-EP EFA 架构 / Producer 多样性）
**目的**：为 UCCL-EP 实现 `comp_signal` 协议的 P0 PR，找出**EFA-CPU-proxy 架构独有的优化点**
**结论定性**：P0 从"API 命名纠错"升级为"EFA 独占 lever 库"，至少有 **3 个 DeepEP NVIDIA 做不了的优化**

---

## 0. 重要更正：Blackwell `src_signals` 不是死代码

之前 `docs/SGLANG_OPT_FEASIBILITY_REVIEW.md` 和 `docs/P0_DESIGN_REVIEW.md` 结论 "`src_signals` 是死代码只在 SGLang Python" 是**错的**。Producer 不在 DeepEP，而在 **FlashInfer CuteDSL** (`flashinfer/gemm/kernels/grouped_gemm_masked_blackwell.py:1790+`)。Blackwell 分支真实可达，当 `--moe-runner-backend flashinfer_cutedsl + --enable-single-batch-overlap + SM100` 时激活。

**这意味着 UCCL-EP 必须同时支持两套协议**（Hopper `comp_signal` + Blackwell `src_signals`），不能只做 Hopper。

---

## 1. 协议规范（来自 4 个 agent 交叉验证）

### 1.1 DeepGemm `comp_signal`（Hopper / p5en）

| 参数 | Shape | Dtype | Owner / zero-init |
|---|---|---|---|
| `comp_signal` | `[num_local_experts * ceil_div(M, block_m)]` | int32 | SGLang 每 forward `torch.zeros`（`single_batch_overlap.py:127`）|
| `packed_recv_count` | `[num_local_experts]` | int32 | UCCL-EP dispatch 已产出（`uccl_ep.cc:1239`）|
| `block_m` | scalar | int | **DeepGemm 运行时返回**（`get_best_config` 选 ∈ {64,128}）|
| `threshold` | scalar | int | = `ceil_div(N_down, best_block_n)`，DeepGemm 返回 |
| `num_sms` | scalar | int | 默认 Hopper 3 / Blackwell 32，env `SGLANG_DEEPEP_LL_COMBINE_SEND_NUM_SMS` |

**Producer side**：DeepGemm PR **#183**（Agent 原说 #14 是错的），SM90 kernel `sm90_fp8_gemm_1d2d_impl` L428-440 在 kEnableOverlap 分支里：
```ptx
atom.add.release.gpu.global.s32 signal[group_idx*ceil(m/BLOCK_M)+m_block_idx], 1
```
发射时机：TMA `store_wait()` + `NamedBarrier` 后。

**Consumer side**：DeepEP antgroup-opt PR **#483** combine kernel 轮询 `ld_acquire_global(signal) >= threshold`。

### 1.2 FlashInfer CuteDSL `src_signals`（Blackwell / p6-b200）

| 参数 | Shape | Dtype | 语义 |
|---|---|---|---|
| `src_signals` | `[num_local_experts]` | uint32 | 每 expert 一个 flag；完成 = 1 |
| `src_signal_expect_value` | scalar | int | 通常是 1（expert-complete）|

**关键差异**：Blackwell 粒度是**整个 expert**，Hopper 粒度是 **block_m × expert**。完全是两个协议，不是方言。

### 1.3 协议对比表

| 属性 | Hopper `comp_signal` | Blackwell `src_signals` |
|---|---|---|
| Shape | `[E * ceil(M/Bm)]` | `[E]` |
| dtype | int32 | uint32 |
| Granularity | per (expert × block_m) | per expert |
| Threshold | `ceil_div(N, block_n)` | 固定 1 |
| PTX | `atom.add.release.gpu.global.s32` | 同 |
| Memory scope | `.gpu`（两者）| 同 |
| Kernel fence | `store_wait()` + NamedBarrier | `cp_async_bulk_wait_group(0)` |

### 1.4 `packed_recv_src_info` 的 ABI-breaking 改动（容易漏）

DeepEP PR #483 把 `packed_recv_src_info` 从 **int32 升级到 int64**，`pack2(src_idx, src_rank)` 低 32bit = src_idx，高 32bit = src_rank。理由是 combine kernel 改成"SM 跨 signal-slot stripe"后，每个 SM 可能处理混合 expert，需要 per-token 取 dst_rank。

**影响**：UCCL-EP dispatch 必须同步改，任何下游消费者（SGLang routing / eplb counters）都要审查。

---

## 2. EFA Combine 时间线（p5en 16×EP 实测基线）

来自 `results/stage2-p5en-2026-04-23/SUMMARY.md` + agent 代码分析：

| 段 | µs | 可 overlap? | 代码位置 |
|---|---:|---|---|
| A. kernel launch + TMA setup | 5-10 | no | `internode_ll.cu:1296` |
| B. per-token FP8/BF16 + LogFMT | 10-30 | **yes** | `internode_ll.cu:858-1009` |
| C. `__threadfence_system` + FIFO push | 0.3-1/cmd | no | `internode_ll.cu:1023` |
| D. CPU proxy poll FIFO head | 0.2-2 | — | `proxy.cpp:677` |
| E. `ibv_wr_rdma_write` | 2-5/WR | no | `proxy.cpp:743, 859` |
| F. EFA SRD wire | 8-15 | — | 物理下限 |
| G. Remote CQE poll + atomic post | 2-4 | — | `proxy.cpp:476` |
| H. Remote GPU spin on recv_flag | 5-50（variable）| — | `internode_ll.cu:1096` |
| I. `cg::this_grid().sync()` | 3-8 | no | `internode_ll.cu:1148` |
| J. Reduce top-k → combined_x | 30-80 | **yes** | `internode_ll.cu:1155` |

**Combine 总时长实测**：297-322 µs（send/recv ≈ 35/45 µs）
**Critical path**：C+D+E（3-8 µs/msg × fan-out）+ F（8-15 µs wire）+ H（5-50 µs）+ J（30-80 µs）

**Combine kernel 占用率**：`__launch_bounds__(1024,1)`，32 warps × 6336 B smem = 202 KB 顶满 228 KB opt-in；**occupancy 50%（1 CTA/SM）**——意味着同一个 CTA 里 GPU spin 会阻塞 sync_barrier 中的 group-mate。**这强化了 Scheme B 的价值**。

---

## 3. `comp_signal` 在 EFA 的 3 种实现方案

| 方案 | Spin 位置 | 优点 | 缺点 | UCCL-EP 独占？ |
|---|---|---|---|---|
| **A. GPU spin（DeepEP 照搬）** | combine sender warp | Drop-in API 兼容 | `__nanosleep(100)` sm_90a 是**硬件定时 pause**（Agent C 2026-04-26 订正：不是 "100-cycle busy-wait"，是真硬件 pause 释放 issue slot）；占用 SM + 阻塞同 CTA group-mate（occupancy 已 50%）| ❌ |
| **B. CPU proxy spin** | proxy 线程（已 busy-poll）| **零 GPU 成本**；proxy 已 idle-poll；pinned page `__sync_load` ~80 ns | sender 延迟 +1 µs（signal lag）；需 `TransferCmd` 扩展 | **✅ EFA 独占** |
| **C. kernel predicate + CPU re-queue** | proxy | 最大 GPU overlap；SM 立刻释放 | 复杂；与 `atomic_clean_flag` 顺序强相关 | **✅ EFA 独占** |

**建议落地顺序**：
- **主 PR 先落 Scheme A**（保证和 DeepEP API 一致，SGLang drop-in）
- **追加隐藏 env `UCCL_EP_COMBINE_SIGNAL_ON_CPU=1` 切到 Scheme B**（EFA 独占 escape hatch）
- **Scheme C 做 backup**，等 Scheme B benchmark 看是否需要

---

## 4. **按 ROI 排序的可挖优化点**（核心产出）

### 🏆 OPT-1: CPU-proxy signal wait（Scheme B）—— 最大 lever

**Lever**：把 `comp_signal` 轮询从 GPU 挪到 CPU proxy `run_sender` 里（`proxy.cpp:743` 批处理循环内）。DeepEP NVIDIA GPU-initiated IBGDA 没有 CPU agent 在 hot path 上可用——**EFA-CPU-proxy 独占**。

**为什么能赢**：
- DeepEP GPU spin 独占一个 SM，同 CTA group-mate 被 sync_barrier 阻塞（combine occupancy 已 50%）
- UCCL-EP 把 spin 挪到 CPU 后，combine 的 3 个 SM 全部释放给 DeepGemm：144 → **141 compute SM**
- DeepGemm 在 H200 上 tile 利用率约 132 SMs，多 9 SM 相当于 +1.5-2% tile 吞吐
- 更重要：**ITL tail 不再被 GPU spin 拖尾**，Scheme A 下 `__nanosleep(100)` × N 次可能累积 5-15 µs 抖动

**工作量**：~200 LOC
- 新增 `CmdType::COMBINE_SIGNAL_WAIT`（占 TransferCmd 一个变种）
- `comp_signal` 通过 `cudaHostAlloc(cudaHostAllocMapped)` 分配（模板：`uccl_proxy.cpp:59-87` 的 `atomic_buffer_ptr_`）
- proxy 在 `post_gpu_commands_mixed` 前检查 signal ≥ threshold，不满足就挂起该 batch

**证据**：
- proxy 已经 busy-poll FIFO（`proxy.cpp:673-733`），多一个 `__sync_load` 几乎零开销
- `cudaHostRegister` + volatile load over PCIe Gen5 ~200 ns（但 Hopper cache coherent，可能更快）

**风险**：
- 需要 DeepGemm 的 atomic 从 `release.gpu` 改成 `release.sys`（一字符 PTX 改动；否则 CPU 可能读到 stale value）。或者 Hopper 能观察 coherent memory 的 gpu-scope release，实测确认。

### 🥈 OPT-2: `num_sms = 1`（vs DeepEP 默认 3）

**Lever**：默认 `SGLANG_DEEPEP_LL_COMBINE_SEND_NUM_SMS=3`（Hopper）/ 32（Blackwell）。DeepEP 选 3 因为 GPU 端 per-warp IBGDA doorbell ringing。**UCCL-EP 走 CPU-proxy FIFO，只需 1 warp push `TransferCmd` 就够**（`uccl_ibgda.cuh:35` 已经 `if (lane_id != 0) return`，31/32 lane 本来就闲）。

**为什么能赢**：`compute_num_sms = 144 - 1 = 143`，DeepGemm 多 2 SM（~1.5% tile）。和 OPT-1 叠加后 combine 总共只占 1 SM。

**工作量**：0 天（env 切换）

**风险**：ring 竞争需要 benchmark；small batch 下可能 sender throughput 不够。

### 🥉 OPT-3: Per-expert FIFO reorder in proxy

**Lever**：proxy 批处理时跨所有 ring 排序（`proxy.cpp:673-733`），按 `comp_signal` ready 优先级重排——已 ready 的 expert 先发。DeepEP GPU-initiated per-warp send 没法跨 expert-warp 做全局重排。

**为什么能赢**：decode 下不同 expert 的 down_gemm 完成时刻差异大（token 分布不均匀），先发已 ready 的能显著缩 ITL tail。

**工作量**：~80 LOC（sort `wrs_to_post` by signal-ready predicate）

**风险**：必须遵守 `atomic_clean_flag` flush 顺序（`internode_ll.cu:1069`）。

### 4. Piggy-back signal on finish WR

**Lever**：`TransferCmd.atomic_offset` 有 16 bit 空闲位（`ring_buffer.cuh:88`），夹带 "expert X block_m Y ready"，复用 `internode_ll.cu:1069` 的 finish atomic WR，不加新 WR。DeepEP 没 CPU proxy 做 field multiplexing。

**工作量**：中（需要设计编码格式）

### 5. Batch-coalesce WRs for same dst_rank+expert

**Lever**：EFA SRD max_inline=0，per-WR 固定 2-5 µs。SBO 产生的 block_m 子发送在 1-3 µs proxy 窗口内合并成一个 scatter-SGE `ibv_wr_rdma_write`。需要 `max_send_sge` 从 1 调高（`rdma.cpp:897`）。

**工作量**：中

**风险**：EFA MTU / segmentation 交互需要 p5en bench 验证。

### 6. 零日优化 lever（SGLang 端 env sweep）

| # | Lever | 工作量 |
|---|---|---|
| 6a | `SGLANG_DEEPEP_LL_COMBINE_SEND_NUM_SMS ∈ {1,2,3,4,6,8}` sweep | 0.5 d |
| 6b | `--cuda-graph-bs` 覆盖 UCCL-EP 实际 warmup 区间 | 0 d |
| 6c | `SboFlags.enable_dispatch_shared_one_stream_overlap` 自动开 | 0 d |
| 6d | 给 UCCL-EP wire `combine_wait_recv_cost_stats` tensor 做 per-rank EFA tail 诊断 | 1 d |

---

## 5. UCCL-EP `low_latency_combine` 改动清单

| 文件 | 行 | 改动 | 类型 |
|---|---|---|---|
| `ep/src/uccl_ep.cc` | 1287-1297 | 加 6 kwargs: `overlap, packed_recv_count_ptr, comp_signal_ptr, block_m, threshold, num_sms` | API |
| `ep/src/uccl_ep.cc` | 1239-1241 | `packed_recv_src_info` int32 → int64（ABI break）| **breaking** |
| `ep/src/uccl_ep.cc` | 1800, 2132 | pybind 新 kwargs | binding |
| `ep/src/internode_ll.cu` | 735-749 | combine signature 加参数 + `atomic_finish_counter_per_expert` | kernel sig |
| `ep/src/internode_ll.cu` | 792-858 | 重写 send loop 为 SM-striped `for vaild_signal_idx` | **major** |
| `ep/src/internode_ll.cu` | 857 前 | 插 `while(ld_acquire_global(signal) != threshold)` spin | hot path |
| `ep/src/internode_ll.cu` | 1028-1077 | finish flag 包 lambda，overlap 模式只在最后一个 block 发送 | fix race |
| `ep/src/layout.cu` | src_info stride | 字节数翻倍 | layout |
| UCCL workspace | `atomic_clean_flag + 1` → `(1 + num_experts) * sizeof(int)` | workspace | 分配 |

---

## 6. 致命陷阱 / Must-assert

1. **`comp_signal` length 以 block_m-slot 计，每 expert 至少 1 slot**（即使 0 token 的 expert 也保留 1 slot）。如果 UCCL-EP 用 `ceil_div(packed_recv_count[e], 64)` 不加 `?1:` fallback，prefix-sum 会 underflow。
2. **`atom.add.release.gpu`** scope 是 `.gpu` 不是 `.sys`。Scheme B 要求 DeepGemm 改 `release.sys`（一字符 PTX）。Hopper cache coherent 上可能自然成立但 PTX 不保证。
3. **`packed_recv_src_info` int64 是 ABI break**，下游 SGLang routing/eplb 要审查。fork 必须 bump version flag。
4. **Finish flag race**：`num_sms > 1` 时，最后一个 block 的 SM 发 finish flag 给所有 rank。如果 kernel mid-loop dead，finish 永不发，对端 combine-recv 死等。Spot preemption 场景必须加 CPU proxy 侧 watchdog timeout。
5. **`overlap && return_recv_hook=False`** 会死锁。必须 assert `overlap → return_recv_hook`。
6. **`num_sms=0` 除零**。assert `num_sms >= 1`。
7. **batch < block_m=64 时 SBO 负收益**（DeepEP PR #390 原话）。decode per-rank bs=1-8 需要 A/B。
8. **`compute_num_sms` 吃掉 GEMM**：Blackwell 默认 32，砍掉 24% SM，small batch 下 GEMM 本不是瓶颈此时负收益。Hopper 默认 3 合理。
9. **Qwen3-235B-FP8 TP=8 不能走 DeepGemm masked GEMM**（moe_intermediate_size=1536 不是 block_n=128 倍数，已记 memory）——SBO 对 Qwen3-235B-FP8 直接不可用，只适用 DeepSeek-V3 / Kimi-K2（K2 需确认 DeepGemm 路径）。

---

## 7. MoE Backend × Hardware 兼容矩阵

| Hardware | Backend | SBO? | 信号 API | UCCL-EP 必须支持 |
|---|---|---|---|---|
| **H200 (p5en)** + FP8 | `deep_gemm` | ✅ | `comp_signal` (5 kwargs) | **✅ P0 目标** |
| H200 + FP8 | `flashinfer_cutedsl` | ❌ (SM100-only kernel) | — | — |
| H200 + BF16 | `triton/cutlass` | ❌ gate 不过 | — | — |
| **B200 (p6-b200)** + NVFP4/FP8 | `flashinfer_cutedsl` | ✅ | `src_signals` (2 kwargs) | **✅ P1 目标** |
| B200 + any | `deep_gemm` | ❌ (`and not is_blackwell()` gate) | — | — |

---

## 8. SBO 实测基准（不可忽略）

**SGLang PR #9660 MERGED 2025-12-03**，5 节点 H20 DP16+EP16 decode DeepSeek-V3/R1，input 4096 / output 1536，concurrency 512：

| 指标 | origin | SBO on | Δ |
|---|---|---|---|
| Output tok/s | 6667 | 7111 | **+6.7%** |
| Mean ITL (ms) | 73.11 | 67.35 | **-7.9%** |
| P99 ITL (ms) | 155.32 | 141.96 | **-8.6%** |
| Median E2E | 113847 | 105364 | -7.5% |

**SBO 就是为 decode 设计的**（PR #9660 作者原话），不是 prefill/训练路径。H20 基线我们可以迁移到 p5en 预期（H200 compute 更强，比例可能略小，但方向成立）。

---

## 9. 建议执行顺序

### Sprint A（P0 主 PR，2 周）

1. **Day 1-3**：基线 benchmark 建立
   - p5en 8×2 搭 SGLang + UCCL-EP HEAD + DeepSeek-V3 FP8
   - 跑 decode ITL，确认 SBO off 下 P50/P99 baseline
   - 确认 `moe_runner_backend=deep_gemm` auto-resolve
2. **Day 4-7**：Scheme A 实现（GPU spin，匹配 DeepEP API）
   - `ep/src/uccl_ep.cc` signature 扩展 + pybind
   - `ep/src/internode_ll.cu` combine 加 signal spin + SM stripe
   - `packed_recv_src_info` int64 升级
3. **Day 8-10**：env sweep + 正确性验证
   - SGLang `--enable-single-batch-overlap` 跑通
   - compare bit-exact baseline
   - `SGLANG_DEEPEP_LL_COMBINE_SEND_NUM_SMS` sweep
4. **Day 11-14**：PR body 准备 + AWS benchmark 附录（遵守 memory `feedback_uccl_pr_aws_bench.md`）

**期望产出**：p5en decode ITL 改善 5-10%（保守，打 H20 数字的折扣）

### Sprint B（Scheme B EFA 独占优化，1.5 周）

5. **Day 15-19**：Scheme B 实现
   - `TransferCmd` 扩展 `CmdType::COMBINE_SIGNAL_WAIT`
   - `comp_signal` pinned mapping
   - proxy 侧 signal-ready predicate
   - 环境变量 `UCCL_EP_COMBINE_SIGNAL_ON_CPU=1`
6. **Day 20-23**：DeepGemm `release.sys` patch + benchmark
   - 验证 GPU spin vs CPU spin delta
   - 量化 3 个 SM 回归给 DeepGemm 的收益

**期望产出**：在 Scheme A 基础上再 +3-5% decode ITL（EFA 独占增量）

### Sprint C（P1 Blackwell `src_signals`，1.5 周）

7. **Day 24-30**：p6-b200 上 `src_signals` 协议
   - 第二个 kernel variant
   - FlashInfer CuteDSL 集成测试
   - Blackwell SPS 找 AZ

### 同期进行的零日优化

- OPT-6a (SEND_NUM_SMS sweep) 可以在 Sprint A Day 8-10 里做
- OPT-6b/6c 直接记录在 bench 配置里

---

## 10. 和已有工作叠加

- **PR #903**（`__threadfence + __nanosleep + rdma_recv 128→512`）：减少 hop C 约 0.5 µs/cmd，和 SBO 正交 → 先合 #903，再加 SBO
- **PR #904**（UCCL_EP_CPU_TIMEOUT_SECS）：已提交，和 SBO 无关
- **`PER_EXPERT_BATCHING` 编译选项**：建议 `comp_signal` 也做成 `#ifdef UCCL_EP_COMBINE_COMP_SIGNAL`，和现有 batching flag 组合

---

## 11. 待用户决策的 3 个问题

1. **Sprint A 先上 Scheme A 还是 Scheme B？**
   - 倾向 A：兼容性保底 + 能 merge
   - B 作为后续 PR 或隐藏 env（上游可能暂不接受 EFA 专属优化）
2. **Blackwell `src_signals` 是否同期做？**
   - 倾向 P1 delay：Hopper 是当前 Stage 5 目标，Blackwell p6-b200 SPS 还不稳
3. **DeepGemm `release.sys` patch 要我们提还是等上游？**
   - 如果 Scheme B 决定做，最好我们顺手提个 DeepGemm PR，收获额外 sender 点（和 MaoZiming/DeepGemm 团队建立联系）

---

## 12. 关键文件索引

**上游 PR**：
- DeepGemm PR **#183**（Hopper producer，OPEN）
- DeepEP PR **#390**（SBO motivation/design，OPEN）
- DeepEP PR **#483**（`comp_signal` consumer，antgroup-opt 分支已合）
- SGLang PR **#9660**（SBO 主 PR，MERGED 2025-12-03）
- SGLang PR **#17289**（Blackwell 分支）
- SGLang PR **#21877**（fused down+combine，与 SBO 互斥）

**本地代码**：
- `/home/ec2-user/workspace/sglang/python/sglang/srt/batch_overlap/single_batch_overlap.py:28-144`
- `/home/ec2-user/workspace/sglang/python/sglang/srt/layers/moe/token_dispatcher/deepep.py:704-732`
- `/home/ec2-user/workspace/sglang/python/sglang/srt/layers/moe/moe_runner/deep_gemm.py:332-357`
- `/home/ec2-user/workspace/sglang/python/sglang/srt/layers/moe/flashinfer_cutedsl_moe.py:157-182`
- `/home/ec2-user/workspace/sglang/python/sglang/srt/layers/moe/utils.py:68-114`
- `/home/ec2-user/workspace/sglang/python/sglang/srt/environ.py:407-408`
- `/home/ec2-user/workspace/uccl/ep/src/uccl_ep.cc:1287-1373`
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:735-1304`
- `/home/ec2-user/workspace/uccl/ep/src/proxy.cpp:464-543, 655-749`
- `/home/ec2-user/workspace/uccl/ep/src/uccl_proxy.cpp:59-87`
- `/home/ec2-user/workspace/uccl/ep/src/rdma.cpp:884-952`
- `/home/ec2-user/workspace/uccl/ep/include/uccl_ibgda.cuh:27-256`
- `/home/ec2-user/workspace/uccl/ep/include/ring_buffer.cuh:57-90`

**Baseline 数据**：
- `/home/ec2-user/workspace/efa-validation/results/stage2-p5en-2026-04-23/SUMMARY.md`（combine 297-322 µs）
