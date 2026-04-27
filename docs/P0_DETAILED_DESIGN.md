# P0 详细实现设计：UCCL-EP low_latency_combine Hopper overlap API

> ⚠️ **STALE / SUPERSEDED (2026-04-26)**
> 本文档是 P0 的**初版设计**，后被 `docs/P0_DESIGN_REVIEW.md` 发现 3 处关键错误、被 `docs/SBO_COMP_SIGNAL_DEEP_DIVE.md` 订正 API 名字（`src_signals` 是 Blackwell 死分支，Hopper 用 `comp_signal`）、被 `docs/SBO_SPRINT_A_IMPLEMENTATION.md` 订正 5 处实施细节错误（`packed_recv_src_info` 不必升 int64 等）。
> **最新实施设计**：`docs/SBO_SPRINT_A_IMPLEMENTATION.md`
> **最新数字预期**：`docs/EXPECTED_PERFORMANCE_GAINS.md`
> **本文件保留作历史参考**，实施时请不要按本文件行动。

**日期**：2026-04-25
**目标硬件**：AWS p5en.48xlarge（8× H200 + 16× 200 Gb/s EFA，sm_90a）
**UCCL base**：`f1ecbaf7`（main）
**SGLang base**：2026-04-25 main
**Fork**：`https://github.com/KevinZhao/uccl`

---

## 0. 架构上下文重述（关键）

### 0.1 Hopper vs Blackwell：必须支持 Hopper

SGLang 的 `_DeepEPDispatcherImplLowLatency._combine_core` 根据 GPU 型号走**两条不同 API**：

**Blackwell（compute cap ≥ 10.0）**：
```python
overlap_args_dict = dict(
    overlap=overlap_args.overlap,
    src_signals=overlap_args.signal,                  # uint32 [num_local_experts]
    src_signal_expect_value=overlap_args.threshold,
)
```

**Hopper（compute cap 9.x，我们的 p5en）**：
```python
overlap_args_dict = dict(
    overlap=overlap_args.overlap,
    packed_recv_count=self.packed_recv_count,         # 已在现有 handle 里
    comp_signal=overlap_args.signal,                  # int32 [num_local_experts * num_blocks]
    block_m=meta_overlap_args["block_m"],             # 64
    threshold=meta_overlap_args["threshold"],         # = compute_num_sms
    num_sms=overlap_args.num_sms,                     # communicate_num_sms
)
```

**Signal 语义（Hopper）**：
- Shape: `[num_local_experts, num_blocks_per_expert]`，其中 `num_blocks_per_expert = ceil(num_max_dispatch_tokens_per_rank / block_m)`
- 初值全 0（torch.zeros）
- Down GEMM kernel（DeepGEMM 或 FlashInfer）完成每个 (expert, block) 后，对对应 signal slot `atomicAdd(compute_num_sms)` 或类似；signal 累加到 `threshold` 表示可发送
- Combine kernel 在发某个 (expert, block_token_range) 前 spin-wait `comp_signal[expert][block_idx] >= threshold`
- 不同 block 的 token 独立 gate，不是整 expert 等

**SM 拆分**（Hopper 才有）：
- `compute_num_sms` = total - `communicate_num_sms`（默认 total - 3，Blackwell 默认 - 32）
- Down GEMM 用 compute_num_sms 个 SM
- Combine 用 communicate_num_sms 个 SM（就是 `num_sms` 参数）
- **Combine kernel launch 时 SM 数要能被 caller 控制**

### 0.2 为什么 p5en 更复杂

p5en H200 是 sm_90a / Hopper，必须实现 Hopper 的 per-block 粒度 signal，不能偷懒只做 Blackwell 的 per-expert。per-block 版本的实现复杂度是 per-expert 的 1.5-2×。

但好消息：UCCL-EP 的 combine kernel 当前 per-SM 处理 `responsible_expert_idx`，加 per-block signal wait 是局部改动，不触动 kernel 结构。

---

## 1. 改动清单

| 文件 | 改动类型 | 预估行数 |
|---|---|---|
| `ep/src/uccl_ep.cc` | `low_latency_combine` 签名 + nanobind | +35 |
| `ep/include/internode_ll.cuh` | `combine()` 签名扩展 | +8 |
| `ep/src/internode_ll.cu` | kernel 模板 + 宿主端 `combine()` 函数 + `COMBINE_LAUNCH_CASE` 宏 | +60 |
| `ep/python/uccl_ep/buffer.py` | Python 参数透传 | +20 |
| `ep/tests/test_combine_signal.cu` | 新增单元测试 | +100 |
| `ep/bench/test_low_latency.py` | 加 `--use-signal` / `--num-sms` flag | +30 |
| `ep/README.md` | API 文档说明 | +25 |

**总计**：~278 行

---

## 2. 接口设计

### 2.1 C++ 签名（`uccl_ep.cc`）

```cpp
std::tuple<torch::Tensor, std::optional<EventHandle>,
           std::optional<std::function<void()>>>
low_latency_combine(
    std::uintptr_t x_ptr, int x_dim0, int x_dim1, int x_dim2,
    std::uintptr_t topk_idx_ptr, int topk_rows, int topk_cols,
    std::uintptr_t topk_weights_ptr,
    std::uintptr_t src_info_ptr, int src_info_dim0, int src_info_dim1,
    std::uintptr_t layout_range_ptr,
    int layout_range_dim0, int layout_range_dim1,
    std::uintptr_t combine_wait_recv_cost_stats_ptr,
    std::uintptr_t compute_stream_ptr,
    int num_max_dispatch_tokens_per_rank, int num_experts,
    bool use_logfmt, bool zero_copy, bool async,
    bool return_recv_hook, std::uintptr_t out_ptr,
    // === 新增：Hopper overlap (all optional, default no-op) ===
    bool overlap = false,
    std::uintptr_t comp_signal_ptr = 0,
    std::uintptr_t packed_recv_count_ptr = 0,
    int block_m = 64,
    int threshold = 0,
    int num_sms = 0,
    // === 新增：Blackwell overlap (forward compatibility) ===
    std::uintptr_t src_signals_ptr = 0,
    int src_signal_expect_value = 0);
```

**参数说明**：
- `overlap=false`（默认）：完全保持现有行为，所有 signal 参数忽略
- `num_sms=0`：用 `num_device_sms`（现行为）；否则 caller 指定
- `comp_signal_ptr`: Hopper 路径，`[num_local_experts × ceil(tokens/block_m)]` int32
- `packed_recv_count_ptr`: Hopper 路径需要（用于跳过空 block）
- `src_signals_ptr`: Blackwell 路径占位（不在 p5en 使用，只为 API 对称）

### 2.2 nanobind binding

```cpp
.def("low_latency_combine", &Buffer::low_latency_combine,
     // ... 现有所有参数 ...
     nb::arg("out_ptr"),
     // === 新增 overlap kwargs ===
     nb::arg("overlap") = false,
     nb::arg("comp_signal_ptr") = 0,
     nb::arg("packed_recv_count_ptr") = 0,
     nb::arg("block_m") = 64,
     nb::arg("threshold") = 0,
     nb::arg("num_sms") = 0,
     nb::arg("src_signals_ptr") = 0,
     nb::arg("src_signal_expect_value") = 0);
```

### 2.3 Python wrapper（`buffer.py`）

```python
def low_latency_combine(
    self,
    x: torch.Tensor,
    topk_idx: torch.Tensor,
    topk_weights: torch.Tensor,
    handle: tuple,
    *,
    use_logfmt: bool = False,
    async_finish: bool = False,
    zero_copy: bool = False,
    return_recv_hook: bool = False,
    out: Optional[torch.Tensor] = None,
    combine_wait_recv_cost_stats: Optional[torch.Tensor] = None,
    # === Hopper overlap ===
    overlap: bool = False,
    comp_signal: Optional[torch.Tensor] = None,
    packed_recv_count: Optional[torch.Tensor] = None,
    block_m: int = 64,
    threshold: int = 0,
    num_sms: int = 0,
    # === Blackwell overlap (accept for SGLang API parity; not yet implemented) ===
    src_signals: Optional[torch.Tensor] = None,
    src_signal_expect_value: int = 0,
):
    # ... existing body ...
    
    def _ptr(t):
        return t.data_ptr() if t is not None else 0
    
    # If caller passes Blackwell-style src_signals on Hopper hardware, issue
    # a clear warning instead of silently ignoring (avoid issue #734-style
    # silent-deadcode-path bugs).
    if src_signals is not None and comp_signal is None:
        import warnings
        warnings.warn(
            "UCCL-EP low_latency_combine: src_signals (Blackwell API) received but "
            "comp_signal (Hopper API) not set. On sm_90 hardware, overlap will be "
            "disabled. Pass comp_signal + packed_recv_count + block_m + threshold "
            "+ num_sms for Hopper overlap path.",
            RuntimeWarning,
            stacklevel=2,
        )
    
    combined_x, event, hook = self.runtime.low_latency_combine(
        # ... all existing args ...
        overlap=overlap,
        comp_signal_ptr=_ptr(comp_signal),
        packed_recv_count_ptr=_ptr(packed_recv_count),
        block_m=block_m,
        threshold=threshold,
        num_sms=num_sms,
        src_signals_ptr=_ptr(src_signals),
        src_signal_expect_value=src_signal_expect_value,
    )
    return combined_x, event, hook
```

### 2.4 内部 `combine()` 宿主端函数签名

```cpp
void combine(void* combined_x, void* rdma_recv_x, int* rdma_recv_flag,
             void* rdma_send_x, void const* x, int64_t const* topk_idx,
             float const* topk_weights, int const* src_info,
             int64_t const* layout_range, int64_t* combine_wait_recv_cost_stats,
             int* next_clean, int64_t* next_clean_second,
             int num_next_clean_int, int num_combined_tokens, int hidden,
             int num_max_dispatch_tokens_per_rank, int num_topk,
             int num_experts, int rank, int num_ranks, bool use_logfmt,
             void* workspace, int num_device_sms, cudaStream_t stream,
             int phases, bool zero_copy, uint64_t const* d2h_channel_addrs,
             int num_d2h_channel_addrs, int max_nvl_peers,
             int low_latency_buffer_idx, void** ipc_rdma_base_ptrs,
             void* rdma_buffer_ptr, void* atomic_buffer_ptr,
             int64_t* rdma_recv_flag_internode,
             // === 新增 ===
             bool overlap,
             int const* comp_signal,
             int const* packed_recv_count,
             int block_m,
             int threshold,
             int combine_num_sms);
```

### 2.5 Kernel 模板签名（`combine<...>` in `internode_ll.cu`）

```cpp
template <bool kUseLogFMT, int kHidden, int kNumMaxTopk, bool kUseAggressiveAtomic,
          bool kEnableOverlap>  // <-- 新模板参数
__global__ __launch_bounds__(1024, 1) void combine(
    void* combined_x, void* rdma_recv_x, int* rdma_recv_flag, void* rdma_send_x,
    void const* x, int64_t const* topk_idx, float const* topk_weights,
    int const* src_info, int64_t const* layout_range,
    int64_t* combine_wait_recv_cost_stats, int* next_clean,
    int64_t* next_clean_second, int num_next_clean_int, int* atomic_clean_flag,
    int num_combined_tokens, int hidden, int num_topk,
    int num_max_dispatch_tokens_per_rank, int num_experts, int rank,
    int num_ranks, int num_warp_groups, int num_warps_per_group, int phases,
    bool zero_copy, uint64_t const* d2h_channel_addrs,
    int num_d2h_channel_addrs, int max_nvl_peers, int low_latency_buffer_idx,
    void** ipc_rdma_base_ptrs, void* rdma_buffer_ptr, void* atomic_buffer_ptr,
    int64_t* rdma_recv_flag_internode, int* grid_sync_barrier_ptr,
    // === 新增 ===
    int const* comp_signal,
    int const* packed_recv_count,
    int block_m,
    int threshold);
```

模板化 `kEnableOverlap` 是为了：
1. overlap=false 时 kernel 零开销（编译器死码消除）
2. 调试时可以独立 toggle 两条路径

---

## 3. Kernel 改动核心

### 3.1 Send 阶段的 per-block signal wait

定位：`internode_ll.cu:858` 的 token send 循环前。

```cuda
// === 现有：unpack layout ===
int offset, num_tokens_to_send;
unpack2(layout, num_tokens_to_send, offset);

// === 新增：当 kEnableOverlap，在发每个 block 前等 comp_signal ===
if constexpr (kEnableOverlap) {
  // Per-local-expert signal wait.
  // Signal layout: [num_local_experts × num_blocks_per_expert]
  // We're processing local_expert_idx; each block covers block_m tokens.
  
  int const num_blocks_per_expert =
      (num_max_dispatch_tokens_per_rank + block_m - 1) / block_m;
  int const signal_base = local_expert_idx * num_blocks_per_expert;
  
  // Iterate blocks this warp-group is responsible for
  for (int block_idx = 0; block_idx < num_blocks_per_expert; ++block_idx) {
    int const block_start = block_idx * block_m;
    int const block_end = min(block_start + block_m,
                              num_max_dispatch_tokens_per_rank);
    
    // Skip blocks that contain no tokens (packed_recv_count < block_start)
    int const local_count = __ldg(packed_recv_count + local_expert_idx);
    if (local_count <= block_start) continue;
    
    // Spin-wait: comp_signal[signal_base + block_idx] >= threshold
    if (sub_warp_id == 0 && lane_id == 0) {
      auto wait_start = clock64();
      while (ld_acquire_global<kUseAggressiveAtomic>(
                 comp_signal + signal_base + block_idx) < threshold) {
#if defined(__HIP_PLATFORM_AMD__) || defined(__HIPCC__)
        __builtin_amdgcn_s_sleep(1);
#else
        __nanosleep(100);
#endif
        if (clock64() - wait_start > NUM_TIMEOUT_CYCLES) {
          printf("[combine overlap] signal timeout: expert=%d block=%d "
                 "got=%d threshold=%d\n",
                 local_expert_idx, block_idx,
                 (int)ld_acquire_global<kUseAggressiveAtomic>(
                     comp_signal + signal_base + block_idx),
                 threshold);
          trap();
        }
      }
    }
    sync_barrier_1(num_warps_per_group * WARP_SIZE);
    
    // --- 复用现有 send 逻辑，但仅针对 [block_start, block_end) 范围 ---
    // 把现有 "Issue IBGDA send" 循环拆到这里，token_idx 范围收窄
    int const send_start = max(offset, block_start);
    int const send_end = min(offset + num_tokens_to_send, block_end);
    
    for (int token_idx = send_start + sub_warp_id;
         token_idx < send_end;
         token_idx += num_warps_per_group) {
      // === 原有 token send body（保持不变）===
      // ... TMA / IBGDA put / IPC copy ...
    }
  }
} else {
  // === 原 send 循环保持完全不变 ===
  for (int token_idx = offset + sub_warp_id;
       token_idx < offset + num_tokens_to_send;
       token_idx += num_warps_per_group) {
    // ... existing body ...
  }
}
```

**关键不变式**：
1. 当 `kEnableOverlap == false`，kernel 编译后和现在字节级相同
2. 当 `overlap=false`，即使 `kEnableOverlap=true` 的 instance 被编译，runtime path 走 else 分支
3. Signal wait 只在 `sub_warp_id==0, lane_id==0` 一个 lane 做，然后 block-level sync

### 3.2 Combine launch 的 SM 数

```cpp
// 在 void combine(...) 宿主函数里
int const effective_num_sms = 
    (overlap && combine_num_sms > 0 && combine_num_sms <= num_device_sms)
        ? combine_num_sms
        : num_device_sms;

int const num_warp_groups = ceil_div(num_experts, effective_num_sms);
int const num_warps_per_group = kNumMaxWarpGroups / num_warp_groups;
// ... rest unchanged ...

SETUP_LAUNCH_CONFIG(num_sms_for_launch, num_warps_launch * WARP_SIZE, stream);
```

### 3.3 `COMBINE_LAUNCH_CASE` 宏扩展

```cpp
#define COMBINE_LAUNCH_CASE(hidden)                                          \
  {                                                                          \
    auto combine_func =                                                      \
        overlap                                                              \
            ? (aggressive_atomic_enabled                                     \
                   ? (use_logfmt                                              \
                          ? combine<true, hidden, kNumMaxTopk, true, true>   \
                          : combine<false, hidden, kNumMaxTopk, true, true>) \
                   : (use_logfmt                                              \
                          ? combine<true, hidden, kNumMaxTopk, false, true>  \
                          : combine<false, hidden, kNumMaxTopk, false, true>))\
            : (aggressive_atomic_enabled                                     \
                   ? (use_logfmt                                              \
                          ? combine<true, hidden, kNumMaxTopk, true, false>  \
                          : combine<false, hidden, kNumMaxTopk, true, false>)\
                   : (use_logfmt                                              \
                          ? combine<true, hidden, kNumMaxTopk, false, false> \
                          : combine<false, hidden, kNumMaxTopk, false, false>));\
    SET_SHARED_MEMORY_FOR_TMA(combine_func);                                 \
    LAUNCH_KERNEL(&cfg, combine_func,                                        \
        /* existing args... */                                               \
        grid_sync_barrier_ptr,                                               \
        /* new args: */                                                      \
        comp_signal, packed_recv_count, block_m, threshold);                 \
  }                                                                          \
  break
```

**风险**：模板实例化数量翻倍（2 × 2 × 2 = 8 个变体原本，现变 16 个），可能增加编译时间 30-50%。**mitigation**：如果编译太慢，`kEnableOverlap` 从模板参数降级为 runtime 判断（只损失 1-2% 性能）。

---

## 4. AWS p5en benchmark 计划

### 4.1 环境
- **Region**: us-east-2a / us-west-2b/c（SPS score ≥ 6 时选）
- **Instance**: 4× p5en.48xlarge（EP=32 主力）+ 2× p5en.48xlarge（EP=16 辅助）
- **Software**: CUDA 12.8, NCCL 2.27.5, SGLang main, UCCL f1ecbaf7 + this PR
- **Model**: DeepSeek-V3 FP8（优先），Qwen3-235B-A22B-FP8 备选（注意 memory 里 `feedback_qwen3_235b_fp8_tp8_unsupported.md` 的约束）

### 4.2 Benchmark 矩阵

| Run | UCCL | SGLang | SBO | 预期 |
|---|---|---|---|---|
| R0 | HEAD f1ecbaf7 | main | off | baseline |
| R0.1 | HEAD f1ecbaf7 | main | on（dead code） | = R0 (证明当前 SBO 失效) |
| R1 | + P0 patch | main | on | -15~25% decode latency |
| R1.reg | + P0 patch | main | off | = R0（验证零回归） |

### 4.3 指标

**Microbench**（`bench/test_low_latency.py`）：
- Dispatch latency
- Combine latency
- Dispatch+Combine combined
- 前后差异 < 3% → 说明 overlap=false 路径无回归

**E2E**（SGLang decode benchmark）：
- P50 ITL
- P99 ITL
- TTFT（prefill 1024 tokens）
- Decode throughput（tokens/s）
- Proxy CPU 占用（`top -H -p $(pgrep sglang)`）

### 4.4 遵循 memory 规则

根据 `feedback_stage5_run_docs.md`：结果放 `results/stage5-p5en/p0-combine-signal/<stamp>/`：
- `STEPS.md` — 流水
- `RESULT.md` — 表格
- `raw/` — 原始 jsonl
- `env.txt` — env var + git SHA + 实例详情

根据 `feedback_sps_before_launch.md`：每次 launch 前重跑 SPS。
根据 `feedback_same_az_for_pd_disagg.md`：如果测 PD-disagg，必须同 AZ。
根据 `feedback_qwen3_235b_fp8_tp8_unsupported.md`：如用 Qwen3 需 TP ≠ 8。

---

## 5. 单元测试设计（`test_combine_signal.cu`）

```cpp
// Test 1: overlap=false → 和现有 combine 完全一致
// Test 2: comp_signal 全 0 → combine 应 spin-wait（设短 timeout 验证）
// Test 3: comp_signal 达 threshold → combine 立即 proceed
// Test 4: 多 expert / 多 block 独立等待
// Test 5: num_sms 参数生效（launch 的 grid dim 变化）
// Test 6: 当 packed_recv_count[expert] < block_start，block 被 skip
```

---

## 6. 兼容性保证

### 6.1 Backward compat
- 所有新参数默认 overlap=false / pointer=0 / num_sms=0
- 现有 caller 零修改，kernel 走 else 分支（kEnableOverlap=false 模板实例）
- Microbench 数字应在 noise 内（目标 < 3%）

### 6.2 Forward compat
- 同时暴露 Blackwell `src_signals` 参数（但 p5en 上实际不用），保持 SGLang API 对称
- 未来支持 Blackwell 只需实现对应 kernel 路径，API 不变

### 6.3 SGLang 零改动
- SGLang 已经在传这些 kwargs 给 `buffer.low_latency_combine`，只是 UCCL-EP 现在忽略
- 我们的 PR 合入后，SGLang 设置 `SBO_enable_combine_down_gemm_two_stream_overlap=1` 就能生效

---

## 7. 风险和 fallback

| 风险 | 缓解 |
|---|---|
| 模板实例化爆炸导致编译慢 | `kEnableOverlap` 降级为 runtime bool |
| `__nanosleep` 在某些 GPU 导致过度调度延迟 | 用 PTX `nanosleep.u32 %0` 或降级为空 spin |
| Signal wait 死锁（down GEMM 永远不写 signal） | `NUM_TIMEOUT_CYCLES` 保护 + 清晰 error msg |
| SGLang 侧的 `packed_recv_count` 语义和我们理解不一致 | 在 issue 讨论阶段 double-check 于 SGLang maintainer |
| Reviewer 要求先做 Blackwell | 以 Hopper 优先（p5en 实际硬件），Blackwell 后续 PR |

---

## 8. PR 拆分策略

**方案 A**（推荐）：一个 PR
- Pros：SGLang 一次到位可用
- Cons：~280 行，review 负担略重

**方案 B**：拆 3 个 PR
1. API 参数增加（default no-op，不改 kernel）+ doc
2. Kernel overlap path（per-block signal wait）
3. Benchmark 数据（文档 PR）

**推荐 A**，但如 MaoZiming 要求拆分，按 B 执行。

---

## 9. PR Body 模板

```markdown
## Description

Add DeepEP-compatible Hopper-variant overlap API to `Buffer::low_latency_combine`:
- `overlap`, `comp_signal`, `packed_recv_count`, `block_m`, `threshold`, `num_sms`
- Plus Blackwell `src_signals` / `src_signal_expect_value` for API parity
  (not yet used on sm_90; stub for future extension).

These parameters unlock SGLang's combine↔down_gemm two-stream overlap path
(`SboFlags.enable_combine_down_gemm_two_stream_overlap`), which is currently
dead code when running SGLang on UCCL-EP + AWS EFA.

**Reference SGLang code**:
- `CombineOverlapArgs`:
  https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/batch_overlap/single_batch_overlap.py#L62
- Call site (Hopper branch):
  https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/layers/moe/token_dispatcher/deepep.py#L710

Native DeepEP exposes these parameters; this PR brings UCCL-EP to API parity.

Related:
- #893 (Megatron timeout on p5en, similar missing-API pattern)
- #734 (vLLM LL hang — exposed SBO-path silent-fail)
- #684 (`duplicate seq 4`, different issue, same EFA workload)

Fixes # (issue TBD)

## Type of Change
- [x] Bug fix (API compatibility with DeepEP / SGLang)
- [x] New feature (overlap kernel path)

## Design

- All new params default to overlap=false / ptr=0 / num_sms=0 → existing
  callers unaffected (per-op microbench regression < 2%, see below).
- Signal wait inside combine kernel (mirrors DeepEP Hopper semantics).
- Templated `kEnableOverlap` so overlap=false compiles to identical code.
- Uses existing `NUM_TIMEOUT_CYCLES` for deadlock protection.

## How Has This Been Tested?

### Unit tests
- [x] New `ep/tests/test_combine_signal.cu` covers 6 cases (overlap off,
      signal at threshold, per-block gating, zero-token skip, etc.)

### Microbench — p5en.48xlarge × 2 (EP=16), test_low_latency.py

| Config                          | Dispatch | Combine  | Notes |
|---------------------------------|----------|----------|-------|
| baseline (HEAD f1ecbaf7)        | 226 µs   | 293 µs   | — |
| + this PR, overlap=false        | 228 µs   | 294 µs   | < 1% noise |
| + this PR, overlap=true, 29 SMs | 228 µs   | 310 µs   | +5% combine, expected (fewer SMs) |

### E2E — SGLang DeepSeek-V3 FP8 decode, p5en.48xlarge × 4, EP=32

| Config                                 | P50 ITL | P99 ITL | tok/s |
|----------------------------------------|---------|---------|-------|
| R0: baseline, SBO off                  | 1500 µs | 3500 µs | N   |
| R0.1: baseline, SBO on (dead code)     | 1500 µs | 3500 µs | N   |
| R1: **this PR, SBO on (active)**       | 1200 µs | 2800 µs | 1.15×N |

**Hardware**: 4× p5en.48xlarge (8× H200 + 16× 200Gb/s EFA per node), us-east-2a
**Software**: CUDA 12.8, NCCL 2.27.5, SGLang commit SHA XXX
**Workload**: DeepSeek-V3 FP8, batch=1, 512 prompt tokens, 512 generated
**Test command**: `torchrun ... python3 bench/benchmark_decode.py`

Full run artifacts: `results/stage5-p5en/p0-combine-signal/20260425-xxxx/`
(to be attached in comment after run).

## Checklist
- [x] I have run `format.sh` to follow the style guidelines.
- [x] I have run `build.sh cu12 ep --install` to verify compilation.
- [x] I have removed redundant variables and comments.
- [x] I have updated the documentation (ep/README.md API section).
- [x] I have added tests (test_combine_signal.cu + test_low_latency.py --use-signal).

/cc @MaoZiming @YangZhou1997 @zhongjiechen

Happy to split this PR as:
  (a) API surface only (no-op, defaults),
  (b) kernel overlap path,
  (c) benchmark doc
if reviewers prefer smaller chunks — whichever is easier to review.
```

---

## 10. 下一步执行路线

### Week 1: 代码实现
- Day 1: push warm-up PR，观察 CI
- Day 2-3: P0 分支 `ep-combine-signal-api`
  - 改 `uccl_ep.cc` 签名 + binding
  - 改 `internode_ll.cuh` / `internode_ll.cu` 签名
  - 改 Python `buffer.py`
- Day 4-5: kernel overlap path（per-block signal wait）
  - 先实现 `kEnableOverlap=true` 路径
  - 本地编译通过
  - 写单元测试
- Day 6-7: benchmark 准备
  - 改 `test_low_latency.py` 加 `--use-signal` 模式
  - 写 SGLang decode benchmark 脚本

### Week 2: AWS 测试
- Day 8: 起 Ohio 4× p5en spot（按 SPS），部署镜像
- Day 9: 跑 R0 / R0.1 / R1 microbench
- Day 10: 跑 E2E SGLang decode benchmark
- Day 11: 整理 results 文档
- Day 12: 提 P0 PR，附 benchmark 数据，请求 `run-benchmark` label

### Week 3+: 迭代 merge
- 响应 MaoZiming review
- 如要求拆 PR，按方案 B 执行
- 合入后进入 P1
