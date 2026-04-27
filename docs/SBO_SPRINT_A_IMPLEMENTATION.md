# SBO Sprint A — Implementation-Level Design (UCCL-EP `comp_signal`, GPU spin)

**Date**: 2026-04-26
**Scope**: Sprint A only (GPU-spin Scheme A, Hopper `comp_signal`).
**Audience**: the engineer who writes the PR. Everything below is prescriptive.
**References**:
- Protocol / motivation: `docs/SBO_COMP_SIGNAL_DEEP_DIVE.md`
- Three-Sprint split: `docs/SBO_SPRINT_PLAN.md`
- Baseline numbers: `docs/ALLTOALL_DEEP_DIVE.md` §0 (post-#745: dispatch both 174.9 µs, combine both 326.7 µs)
- Recv-path anatomy: `docs/COMBINE_RECV_DEEP_DIVE.md`
- Discipline: `feedback_claim_verification_discipline.md`

**Note on prior design errors this doc corrects**:
- `SBO_SPRINT_PLAN.md` §A.3 claims "`packed_recv_src_info` int32 → int64 upgrade is needed for SM-stripe" — this is carried over from DeepEP PR #483 and is **conditionally true**. The int64 upgrade is only load-bearing if a single SM mixes tokens from different `(local_expert, src_rank)` pairs. In the design below, SM-stripe keys on `slot_idx = (local_expert, block_in_expert)`, **not** on mixed ranks — each block is still aimed at a single `(local_expert, dst_rank)` pair extracted from `layout_range`. Therefore **the int64 upgrade is NOT required for Sprint A**. Keep `packed_recv_src_info` as int32 and defer the ABI break to a later PR if ever needed. This removes an ABI-break from Sprint A and halves the SGLang-side review cost.
- `SBO_SPRINT_PLAN.md` §A.5 calls `workspace` "`atomic_clean_flag + 1` → `(1 + num_experts) * sizeof(int)`". The correct form is `(1 + 1 + num_local_experts) * sizeof(int)` = `atomic_clean_flag[1] + grid_sync_barrier[1] + finish_counter_per_expert[num_local_experts]`. `grid_sync_barrier` is already allocated today (`internode_ll.cu:1230`), only the per-expert counter is new.
- `SBO_COMP_SIGNAL_DEEP_DIVE.md` §5 "Issue RDMA at line 1069" was flagged as finish-flag race. The real race point is `internode_ll.cu:1037-1078` (the finish-flag write `sync_barrier`), not `:1069` alone.

---

## §1 — `low_latency_combine` new signature

### 1.1 C++ signature (`ep/src/uccl_ep.cc:1286-1297`)

Extend the existing method on `Buffer`:

```cpp
std::tuple<std::optional<EventHandle>, std::optional<std::function<void()>>>
low_latency_combine(
    // --- EXISTING params, unchanged, same positional order ---
    std::uintptr_t x_ptr, int x_dim0, int x_dim1, int x_dim2,
    std::uintptr_t topk_idx_ptr, int topk_rows, int topk_cols,
    std::uintptr_t topk_weights_ptr,
    std::uintptr_t src_info_ptr, int src_info_dim0, int src_info_dim1,
    std::uintptr_t layout_range_ptr, int layout_range_dim0, int layout_range_dim1,
    std::uintptr_t combine_wait_recv_cost_stats_ptr,
    std::uintptr_t compute_stream_ptr,
    int num_max_dispatch_tokens_per_rank, int num_experts,
    bool use_logfmt, bool zero_copy, bool async, bool return_recv_hook,
    std::uintptr_t out_ptr,
    // --- NEW SBO params, all default to "overlap off" ---
    bool overlap                             = false,
    std::uintptr_t packed_recv_count_ptr     = 0,   // int32[num_local_experts]
    std::uintptr_t comp_signal_ptr           = 0,   // int32[num_local_experts * ceil_div(num_max_dispatch_tokens_per_rank*num_ranks, block_m)]
    int block_m                              = 64,
    int threshold                            = 0,
    int num_sms_override                     = 0);  // 0 = auto (existing behavior)
```

Parameter table:

| Param | Type / shape / dtype | Source (SGLang) | Assert (when `overlap=true`) | Default semantics |
|---|---|---|---|---|
| `overlap` | `bool` scalar | `overlap_args.overlap` (`deepep.py:706`) | — | `false` → legacy kernel path, ignore new params |
| `packed_recv_count_ptr` | int32 device ptr, length `num_local_experts` | returned by `low_latency_dispatch` (`uccl_ep.cc:1239`, stored in `self.packed_recv_count`) | `!= 0` | `0` iff `overlap=false` |
| `comp_signal_ptr` | int32 device ptr, length = `num_local_experts * ceil_div(max_rx_tokens, block_m)` where `max_rx_tokens = num_max_dispatch_tokens_per_rank * num_ranks` | SGLang `torch.zeros(..., dtype=torch.int32, device='cuda')` zero-filled each forward (`single_batch_overlap.py:127`) | `!= 0`, aligned 4 B | `0` iff `overlap=false` |
| `block_m` | `int` scalar | DeepGemm runtime `get_best_config()`, passed through `meta_overlap_args["block_m"]` (`deepep.py:715`); spec: `∈ {64, 128}` | `== 64 ∥ == 128` | `64` (placeholder) |
| `threshold` | `int` scalar | DeepGemm runtime: `ceil_div(N_down, best_block_n)` | `>= 1` | `0` (means "signal always satisfied"; used as escape hatch for debug) |
| `num_sms_override` | `int` scalar | `overlap_args.num_sms` (`deepep.py:717`); `0` = keep existing auto-derivation | `>= 0` (0 means "auto") | `0` |

**Existing early assertions remain** (`uccl_ep.cc:1298-1313`). Add after line 1313:

```cpp
if (overlap) {
  EP_HOST_ASSERT(packed_recv_count_ptr != 0);
  EP_HOST_ASSERT(comp_signal_ptr != 0);
  EP_HOST_ASSERT(block_m == 64 || block_m == 128);
  EP_HOST_ASSERT(threshold >= 1);
  EP_HOST_ASSERT(return_recv_hook);                  // deadlock guard (see §7)
  EP_HOST_ASSERT(!async);                            // async+hook already excluded at 1330; keep explicit
}
EP_HOST_ASSERT(num_sms_override >= 0);
```

**Reinterpret the new pointers** (after line 1342):

```cpp
int* packed_recv_count = overlap
    ? reinterpret_cast<int*>(packed_recv_count_ptr) : nullptr;
int* comp_signal = overlap
    ? reinterpret_cast<int*>(comp_signal_ptr) : nullptr;
```

Launcher lambda gets the 5 new args forwarded to `uccl::internode_ll::combine(...)` (see §3.4).

### 1.2 nanobind binding (`ep/src/uccl_ep.cc:2132-2144`)

Replace the existing `.def("low_latency_combine", ...)` with:

```cpp
.def("low_latency_combine", &Buffer::low_latency_combine,
     nb::arg("x_ptr"), nb::arg("x_dim0"), nb::arg("x_dim1"), nb::arg("x_dim2"),
     nb::arg("topk_idx_ptr"), nb::arg("topk_rows"), nb::arg("topk_cols"),
     nb::arg("topk_weights_ptr"),
     nb::arg("src_info_ptr"), nb::arg("src_info_dim0"), nb::arg("src_info_dim1"),
     nb::arg("layout_range_ptr"), nb::arg("layout_range_dim0"), nb::arg("layout_range_dim1"),
     nb::arg("combine_wait_recv_cost_stats_ptr") = 0,
     nb::arg("compute_stream_ptr"),
     nb::arg("num_max_dispatch_tokens_per_rank") = 0,
     nb::arg("num_experts") = 1, nb::arg("use_logfmt") = false,
     nb::arg("zero_copy") = false, nb::arg("is_async") = false,
     nb::arg("return_recv_hook") = false, nb::arg("out_ptr"),
     // --- NEW kwargs ---
     nb::arg("overlap") = false,
     nb::arg("packed_recv_count_ptr") = 0,
     nb::arg("comp_signal_ptr") = 0,
     nb::arg("block_m") = 64,
     nb::arg("threshold") = 0,
     nb::arg("num_sms_override") = 0);
```

All six new kwargs have defaults → existing call sites remain source-compatible.

---

## §2 — `packed_recv_src_info` int32 vs int64 decision

**Decision for Sprint A: keep int32. Do NOT upgrade.**

### 2.1 Why the DeepEP upgrade exists

PR #483 upgrades `packed_recv_src_info` from `int32 → int64` so that the combine-send kernel can decode `(src_idx, src_rank)` from a single 8-byte load. The reason they need this is that their new scheduler (a flat prefix-sum over all experts) may assign one SM to tokens that have **different `src_rank`** values — i.e. a single SM sends to multiple remote ranks.

### 2.2 Why we don't need it here

Our SM-stripe design (§3) keys each slot on `(local_expert, block_in_expert)`, not on a flat per-token prefix. Within one slot (one `block_m` group of tokens belonging to `local_expert`), the `dst_rank` is looked up **once** from `layout_range[local_expert * num_ranks + dst_rank]` — exactly the same way the current kernel (`internode_ll.cu:794-798`) does it. Each SM still visits `(dst_rank, local_expert)` pairs one at a time; it just visits **more** of them (round-robin across slots instead of monopolising one expert).

Therefore the per-token `src_idx` stored in `packed_recv_src_info[local_expert_idx*num_ranks*num_max_dispatch_tokens_per_rank + token_idx]` keeps its semantics and stride. No wire-format change.

### 2.3 Follow-up PR (out of scope for Sprint A)

If in Sprint B or a later optimisation we want to eliminate the outer `(dst_rank, local_expert)` loop entirely (e.g. true per-token prefix), we'll need the int64 upgrade then. That PR would touch:
- `ep/src/uccl_ep.cc:1239` dispatch produce-side
- `ep/include/ep_config.hpp` `LowLatencyLayout` (no field rename needed; `src_info` is read as-is)
- `ep/src/internode_ll.cu:484-485` dispatch-side write site
- `ep/bench/buffer.py:413` (tensor dtype)
- SGLang `self.packed_recv_src_info` consumers (there are no consumers in SGLang — `src_info` is only used inside `low_latency_combine`'s `handle` tuple, so duck-type risk is low, but grep confirms before committing).

Mark it TODO in the PR body so reviewers know it was considered.

---

## §3 — Combine kernel: SM-stripe rewrite

### 3.1 Current behaviour (`internode_ll.cu:735-1080`)

`combine<>` is launched with `num_sms = ceil_div(num_experts, num_warp_groups)`. Each SM owns a contiguous slice of `responsible_expert_idx = sm_id * num_warp_groups + warp_group_id`. Inside one expert-slot (one warp-group), a loop (`line 858-1034`) iterates over all tokens of that `(local_expert, dst_rank)` pair using `sub_warp_id` as the stride.

**Problem with overlap**: a SM may finish sending some blocks of expert E before `down_gemm` has finished producing later blocks. Spinning inside the token loop blocks the whole warp group. Also, if SGLang passes `num_sms=3` (Hopper default for overlap), we'd starve most experts — the current mapping isn't designed for `num_sms ≪ num_experts`.

### 3.2 New behaviour (overlap path only)

When `overlap == true`, run a **second kernel variant** gated by a template bool `kOverlap` so we don't regress the baseline codepath:

```cpp
template <bool kUseLogFMT, int kHidden, int kNumMaxTopk,
          bool kUseAggressiveAtomic, bool kOverlap>
__global__ __launch_bounds__(1024, 1) void combine(
    /* existing params ... */,
    /* NEW: */
    int const* packed_recv_count,   // int32[num_local_experts], nullptr when !kOverlap
    int const* comp_signal,         // int32[num_local_experts * kMaxBlocksPerExpert], nullptr when !kOverlap
    int block_m,                    // 64 or 128, unused when !kOverlap
    int threshold,                  // ≥1, unused when !kOverlap
    int* finish_counter_per_expert  // int32[num_local_experts], in workspace, unused when !kOverlap
);
```

In the SEND phase, `if constexpr (kOverlap)` switches the dispatch logic:

```cuda
// Pseudocode at the top of the SEND phase, replacing line 793 onward
if constexpr (kOverlap) {
  // (a) Compute per-expert slot count in shared memory
  //     per_expert_slots[e] = packed_recv_count[e] > 0
  //                         ? ceil_div(packed_recv_count[e], block_m)
  //                         : 1;              // zero-token experts still take 1 slot
  //     per_expert_dst_rank[e]  — computed below, see §3.5
  //     also compute prefix_sum[e] so total_slots = prefix_sum[num_local_experts]
  __shared__ int s_per_expert_slots[kMaxLocalExperts];     // kMaxLocalExperts = 64 (see §8)
  __shared__ int s_prefix_sum[kMaxLocalExperts + 1];
  __shared__ int s_total_slots;

  if (warp_id == 0) {
    // one warp does the prefix-sum using cooperative_groups::inclusive_scan
    int cnt = (lane_id < num_local_experts)
              ? (packed_recv_count[lane_id] == 0
                 ? 1
                 : (packed_recv_count[lane_id] + block_m - 1) / block_m)
              : 0;
    if (lane_id < num_local_experts) s_per_expert_slots[lane_id] = cnt;
    int inclusive = cg::inclusive_scan(cg::tiled_partition<32>(cg::this_thread_block()), cnt);
    if (lane_id < num_local_experts) s_prefix_sum[lane_id + 1] = inclusive;
    if (lane_id == 0) s_prefix_sum[0] = 0;
    if (lane_id == 0) s_total_slots = inclusive;   // last lane's inclusive value (use shfl)
  }
  __syncthreads();

  // Initialise per-expert finish counter (only SM 0 does this)
  if (sm_id == 0 && warp_id == 0 && lane_id < num_local_experts) {
    finish_counter_per_expert[lane_id] = s_per_expert_slots[lane_id];
  }
  grid.sync();   // all SMs see counters before loop

  // (b) SM-stripe the slot space. Each warp-group handles one slot at a time.
  for (int slot_idx = sm_id;
       slot_idx < s_total_slots;
       slot_idx += num_sms) {

    // Binary-search prefix_sum to recover (local_expert, block_in_expert).
    int local_expert = upper_bound(s_prefix_sum, slot_idx) - 1;   // see §3.5
    int block_in_expert = slot_idx - s_prefix_sum[local_expert];
    int token_offset_in_expert = block_in_expert * block_m;

    // For each (local_expert, dst_rank) pair: outer loop over dst_rank unchanged.
    for (int dst_rank = 0; dst_rank < num_ranks; ++dst_rank) {
      int64_t layout = __ldg(&layout_range[local_expert * num_ranks + dst_rank]);
      int dst_offset, dst_num_tokens;
      unpack2(layout, dst_num_tokens, dst_offset);

      // Slice of this dst_rank's tokens that falls in block_in_expert
      int slice_begin = max(dst_offset, token_offset_in_expert);
      int slice_end   = min(dst_offset + dst_num_tokens,
                            token_offset_in_expert + block_m);
      if (slice_begin >= slice_end) continue;   // this block has no tokens for this rank

      // ===== SPIN on comp_signal =====
      if (lane_id == 0) {
        int max_spin = UCCL_EP_CPU_TIMEOUT_SECS * gpu_clock_hz;
        int spins = 0;
        while (ld_acquire_global<kUseAggressiveAtomic>(
                   comp_signal + local_expert * max_blocks_per_expert + block_in_expert)
               < threshold) {
          #if defined(__NVCC__)
              __nanosleep(kNanoSleepNs);    // §5
          #endif
          if (++spins > max_spin) { __trap(); }  // §5 timeout
        }
      }
      __syncwarp();

      // ===== send tokens [slice_begin, slice_end) for (local_expert, dst_rank) =====
      // Reuse existing TMA + IBGDA path verbatim (internode_ll.cu:858-1034),
      // but with `token_idx` stride = num_warps_per_group (same as before) and
      // range clamped to [slice_begin, slice_end).
      // ...
    }

    // ===== finish-flag race (§6) =====
    // Decrement finish counter for this expert; SM that sees 0 fires finish-flag.
    if (warp_group_id == ... && sub_warp_id == 1 && lane_id == 0) {
      int remaining = atomicSub(&finish_counter_per_expert[local_expert], 1) - 1;
      if (remaining == 0) {
        // exact copy of current finish-flag code at lines 1039-1078, but
        // without the clean_flag dependency (moved; see §6.2)
        // ... IBGDA / IPC finish ...
      }
    }
  }
} else {
  // legacy (pre-overlap) loop: bit-identical to current kernel
  // existing code at lines 793-1080
}
```

### 3.3 Why this layout is correct

- **Per-slot visibility**: signal at `(expert, block_idx)` is set by DeepGemm after the tile `[block_idx*block_m, (block_idx+1)*block_m)` of that expert's output is fully written. Any `dst_rank` slice that falls inside that tile is guaranteed to be valid once signal ≥ threshold.
- **Zero-token experts**: `per_expert_slots = 1` even if `packed_recv_count = 0`, so those experts still run one iteration that sets finish flag (downstream peers don't hang).
- **No hot-path binary search**: the `upper_bound` call inside the loop is over `num_local_experts ≤ 64` entries, fits in one warp's smem register shuffles, ~5 cycles.

### 3.4 Host-side launch (`ep/src/internode_ll.cu:1206-1303`)

Add parameters to the `combine(...)` host function and `COMBINE_LAUNCH_CASE` macro. Concretely:

Signature change at `line 1206-1219`:
```cpp
void combine(..., /* existing args */,
             int const* packed_recv_count,     // NEW, nullable
             int const* comp_signal,           // NEW, nullable
             int block_m, int threshold,       // NEW
             int num_sms_override,             // NEW (0 = auto)
             bool overlap);                    // NEW
```

Launch decision at `line 1221-1226`:
```cpp
int num_warp_groups, num_warps_per_group, num_sms;
if (overlap) {
  // Sprint A: combine kernel runs on N SMs determined by SGLang (default 3 on Hopper).
  num_sms = (num_sms_override > 0) ? num_sms_override : 3;
  // Each SM has one warp group; one slot at a time.
  num_warp_groups = 1;
  num_warps_per_group = kNumMaxWarpGroups;  // 32 on NVIDIA
} else {
  // identical to today: ceil_div(num_experts, num_device_sms) warp groups
  num_warp_groups = ceil_div(num_experts, num_device_sms);
  num_warps_per_group = kNumMaxWarpGroups / num_warp_groups;
  num_sms = ceil_div(num_experts, num_warp_groups);
}
```

Workspace at `line 1229-1231`:
```cpp
auto atomic_clean_flag        = static_cast<int*>(workspace);
auto grid_sync_barrier_ptr    = atomic_clean_flag + 1;
auto finish_counter_per_expert = grid_sync_barrier_ptr + 1;   // NEW
EP_HOST_ASSERT((2 + num_experts / num_ranks) * sizeof(int) <= NUM_WORKSPACE_BYTES);
```

`NUM_WORKSPACE_BYTES` is 32 MB (`ep_configs.cuh:5`) — a few hundred bytes for the counter fits trivially.

`COMBINE_LAUNCH_CASE` (`line 1270-1290`): add template arg `kOverlap` and forward the new args:
```cpp
#define COMBINE_LAUNCH_CASE(hidden)                                            \
  {                                                                            \
    auto combine_func_nooverlap =                                              \
        use_logfmt ? combine<true, hidden, kNumMaxTopk, kAgg, false>           \
                   : combine<false, hidden, kNumMaxTopk, kAgg, false>;         \
    auto combine_func_overlap =                                                \
        use_logfmt ? combine<true, hidden, kNumMaxTopk, kAgg, true>            \
                   : combine<false, hidden, kNumMaxTopk, kAgg, true>;          \
    auto combine_func = overlap ? combine_func_overlap : combine_func_nooverlap;\
    SET_SHARED_MEMORY_FOR_TMA(combine_func);                                   \
    LAUNCH_KERNEL(&cfg, combine_func,                                          \
        /* existing args ... */,                                               \
        packed_recv_count, comp_signal, block_m, threshold,                    \
        finish_counter_per_expert);                                            \
  } break
```
(Full combinatorial expansion = 2 (aggr) × 2 (logfmt) × 2 (overlap) = 8 template instantiations. Build-time increase acceptable.)

### 3.5 `per_expert_dst_rank` reconstruction

In `§3.2` I dropped the per-slot `dst_rank` precompute — the outer `for (dst_rank)` loop handles it at run-time. That's fine because `num_ranks` at EP scale is 16–32; the inner slice-intersection check (`slice_begin >= slice_end`) is a cheap register compare.

---

## §4 — Memory ordering decision

**Decision: keep PTX scope `.gpu` on both producer and consumer for Sprint A. Do NOT patch DeepGemm.**

### 4.1 Producer (DeepGemm, out of our tree)

DeepGemm PR #183 emits `atom.add.release.gpu.global.s32 [signal_ptr], 1` after `tma::store_wait()` + named barrier (`SBO_COMP_SIGNAL_DEEP_DIVE.md` §1.1). Scope = `.gpu`.

### 4.2 Consumer (our combine kernel)

Use `ld_acquire_global<kUseAggressiveAtomic>(signal_ptr)` — this already emits `ld.acquire.gpu.global.s32` (see `ep_utils.cuh:729-738`).

### 4.3 Why `.gpu` and not `.sys`

- Producer and consumer are **same process, same device, same address space**. DeepGemm's GEMM kernel writes; UCCL-EP's combine kernel reads. `release.gpu` + `ld.acquire.gpu` is the correct scope pairing for intra-GPU producer/consumer (see CUDA Programming Guide "Memory Consistency Model", Table 16). Hopper guarantees ordering within `.gpu` scope.
- Upgrading to `.sys` would require changing DeepGemm (one-character PTX patch — `.gpu` → `.sys`). That's Sprint B's job (Scheme B / CPU-proxy spin), where the CPU reads the signal and `.sys` becomes necessary.
- **`SBO_COMP_SIGNAL_DEEP_DIVE.md §6 pitfall #2`**: flagged "`release.gpu` isn't `release.sys`". This doc resolves it explicitly — Sprint A stays `.gpu`, Sprint B's DeepGemm patch is a separate PR.

### 4.4 No `__threadfence()` needed

`ld.acquire.gpu` is itself a fence w.r.t. prior loads/stores in the acquiring thread. No additional `__threadfence()` between the spin loop and the subsequent TMA load. Saves ~10 cycles per slot.

### 4.5 Why `ld_acquire_global`, not `ld.volatile` + `__threadfence`

- `ld.volatile` on Hopper is deprecated for producer-consumer patterns; volatile only prevents register coalescing, not cache invalidation.
- `ld.acquire.gpu` + a following `cuda::memory_order_acquire` compiler barrier is the PTX-correct idiom per SM90 docs.

---

## §5 — Spin details

### 5.1 `__nanosleep` behaviour on SM90a

On Hopper (sm_90a), `__nanosleep(N)` is implemented as `nanosleep.u32 N` — a **true hardware-timed** pause up to ~1024 ns (hardware-capped; values larger than the HW cap are clamped). It relinquishes the SM issue slot to another warp for the duration, so another warp in the same CTA can run (important because we keep 32 warps/SM; see §8). It is **not** a pure cycle counter busy-wait.

(`SBO_COMP_SIGNAL_DEEP_DIVE.md` §3 called `__nanosleep` a "100-cycle busy wait" — that's accurate for older architectures / for AMD RDNA `s_sleep`, but on Hopper it is a proper issue-slot release. The effect on overlap performance is what matters — both cases allow sibling warps to progress.)

### 5.2 Constant

```cpp
constexpr int kNanoSleepNs = 100;   // initial value; sweep {50, 100, 200} in Sprint A Day 8-10
```

Lower values = more polling (burns power + issue slots); higher values = coarser wake-up. 100 is the DeepEP default and the sensible starting point.

### 5.3 Max-spin timeout

Reuse the existing `UCCL_EP_CPU_TIMEOUT_SECS` envvar contract from PR #904:

```cpp
static const int32_t kMaxSpinCycles =
    static_cast<int32_t>(UCCL_EP_CPU_TIMEOUT_SECS) * 1'980'000'000; // H200 clk
```

Read once at kernel launch as a host kernel-argument (pass `max_spin_cycles` alongside `threshold`). Inside spin loop use a cycle counter:
```cuda
uint64_t t_start = clock64();
while (ld_acquire_global(sig) < threshold) {
  __nanosleep(kNanoSleepNs);
  if (clock64() - t_start > max_spin_cycles) {
    __trap();    // triggers CUDA error → host sees cudaErrorLaunchTimeOut
  }
}
```
`__trap()` is preferable to silent deadlock — aligns with the spot-preemption watchdog philosophy (`feedback_spot_reclaim_wipes_nvme.md`).

### 5.4 Short-circuit for zero-token experts

If `packed_recv_count[local_expert] == 0`, the slot-count is 1 and the SM is expected to iterate once, do nothing, and fire finish flag. Critical: **do not spin on `comp_signal` for a zero-token expert** — DeepGemm never writes that signal (it iterates only over experts with tokens). Guard:
```cuda
bool has_tokens = (packed_recv_count[local_expert] > 0);
if (has_tokens) {
  while (ld_acquire_global(sig) < threshold) { ... }
}
// unconditionally fall through to finish-flag decrement
```

### 5.5 Co-operation with `return_recv_hook = true`

SBO mandates `return_recv_hook = true` (SGLang sets it when `--enable-single-batch-overlap`). This keeps the SEND and RECV phases as separate kernel launches — the SEND-phase spin on `comp_signal` can't deadlock the RECV-phase reduce because they are distinct kernels. This is the key correctness invariant and why §7 must assert it.

---

## §6 — Finish flag race

### 6.1 Today's `atomic_clean_flag` (`internode_ll.cu:788-789, 1039-1078`)

- SM 0 zeroes `atomic_clean_flag` and sets it to `num_experts` at line 788.
- Each warp-group (1 per expert in legacy path) eventually runs the block at line 1039 which decrements the flag by 1 and writes an IBGDA atomic to the peer's `rdma_recv_flag`.
- Peer sees flag == 1 → RECV phase proceeds.

### 6.2 Under SM-stripe, what changes

Each `local_expert` is split across `per_expert_slots[e]` slots, distributed across `num_sms` SMs. If each slot writes its own finish-flag, peers will see `num_slots` writes instead of 1 and the counter on their side would be wrong. Solution:

1. New workspace array `finish_counter_per_expert[num_local_experts]` initialised to `per_expert_slots[e]` at kernel entry (one SM writes them, then `grid.sync()`).
2. Each slot, when its send loop finishes, does `int rem = atomicSub(&finish_counter_per_expert[local_expert], 1) - 1`.
3. Only the SM that sees `rem == 0` runs the existing finish-flag code (`line 1039-1078` verbatim: `atomic_clean_flag` check, then IBGDA atomic to peer's `rdma_recv_flag + global_expert_idx`).

### 6.3 Existing `atomic_clean_flag` coexistence

The `atomic_clean_flag` at `line 788-789` is a **cleanup ordering flag between SEND and the next-buffer clean** — it's orthogonal to the finish signal. It still gets initialised by SM 0 warp 0 and decremented once per expert (from inside the `rem == 0` SM). No changes to its semantics. The `overlap` path simply moves the `atomic_add_release_global(-1)` (current line 1077) inside the `if (rem == 0)` block.

### 6.4 Concrete code change at `internode_ll.cu:1037-1078`

Wrap the existing body in a lambda, call it only when `rem == 0`:

```cuda
auto issue_finish_flag = [&]() {
  // Existing body of lines 1037-1078 unchanged, but without the outer condition
  // `sub_warp_id == 1 && lane_id == 0`. We arrive here on the single thread
  // that won the atomicSub race.
  while (ld_acquire_global<kUseAggressiveAtomic>(atomic_clean_flag) == 0) ;
  // ... IPC vs IBGDA finish ... (existing code) ...
  atomic_add_release_global<kUseAggressiveAtomic>(atomic_clean_flag, -1);
};

if constexpr (kOverlap) {
  if (warp_group_id == 0 && sub_warp_id == 1 && lane_id == 0) {
    int rem = atomicSub(&finish_counter_per_expert[local_expert], 1) - 1;
    if (rem == 0) issue_finish_flag();
  }
} else {
  // existing legacy call site
  if (sub_warp_id == 1 && lane_id == 0) issue_finish_flag();
}
```

---

## §7 — Required host-side assertions (in addition to §1.1)

Put these in `low_latency_combine` before the launcher lambda is constructed:

| Assertion | Rationale |
|---|---|
| `overlap → return_recv_hook` | With `async_finish=true` and `overlap=true`, the SEND-phase kernel owns the GPU spin; no RECV-phase call exists to relieve it → deadlock. Only `return_recv_hook=true` gives us the required separate-launch structure |
| `overlap → !async` | Already covered by `async+hook` exclusion at existing line 1330, restate for clarity |
| `!overlap → packed_recv_count_ptr == 0 && comp_signal_ptr == 0` | Guard against stale pointer getting used in legacy path |
| `num_sms_override >= 0` | `< 0` is nonsense; `0` means auto |
| `num_sms_override == 0 || num_sms_override <= num_device_sms` | Sanity; prevents over-subscription |
| `overlap → block_m == 64 || block_m == 128` | DeepGemm's only legal values |
| `overlap → threshold >= 1` | `0` would make spin immediately pass — caller bug |

---

## §8 — Shared-memory budget recalculation

### 8.1 Current budget (`internode_ll.cu:1237`)

`kNumTMABytesPerWarp = 12 * (512 + 16) = 6336 B`.
Per CTA: `6336 * num_warps_launch`.

Legacy path: `num_warps = num_warp_groups * num_warps_per_group` up to `kNumMaxWarpGroups = 32`. Worst case 32 warps × 6336 B = 202 752 B = 198 KB. Fits in the 228 KB opt-in pool (`SET_SHARED_MEMORY_FOR_TMA` sets `cudaFuncAttributeMaxDynamicSharedMemorySize`).

### 8.2 New overhead for overlap path

```
kMaxLocalExperts            = 64     // ≥ max(DSv3=32, Kimi-K2 EP=16 → 24, large EP config)
s_per_expert_slots          = 64 * 4 B = 256 B
s_prefix_sum                = 65 * 4 B = 260 B
s_total_slots               = 4 B
Total new smem              = 520 B
```

### 8.3 New CTA smem ceiling

For overlap path: 32 warps × 6336 + 520 = **202 752 + 520 = 203 272 B ≈ 198.5 KB**.

Still under 228 KB Hopper opt-in, no change needed to `SET_SHARED_MEMORY_FOR_TMA`. Keep `__launch_bounds__(1024, 1)` (one CTA per SM). Occupancy unchanged at 50%.

### 8.4 Large-EP future-proof

If Kimi-K2 with EP=16 picks `num_experts = 384` then `num_local_experts = 24` — still well under 64. If any future model has `num_local_experts > 64`, bump `kMaxLocalExperts` compile-time constant and recheck smem. Stamp a static assert:

```cpp
EP_STATIC_ASSERT(num_local_experts <= kMaxLocalExperts, "bump kMaxLocalExperts");
```

(enforced as a runtime host assert since `num_local_experts` isn't a template param; place at the top of `uccl::internode_ll::combine`).

---

## §9 — Python side changes

### 9.1 `ep/bench/buffer.py:427` (`low_latency_combine` wrapper)

Add six kwargs with same names as SGLang passes, matching DeepEP antgroup-opt PR #483:

```python
def low_latency_combine(
    self,
    x: torch.Tensor,
    topk_idx: torch.Tensor,
    topk_weights: torch.Tensor,
    handle: tuple,
    use_logfmt: bool = False,
    zero_copy: bool = False,
    async_finish: bool = False,
    return_recv_hook: bool = False,
    out: Optional[torch.Tensor] = None,
    combine_wait_recv_cost_stats: Optional[torch.Tensor] = None,
    # NEW — names must match DeepEP PR #483 exactly (SGLang duck-types)
    overlap: bool = False,
    packed_recv_count: Optional[torch.Tensor] = None,   # int32[num_local_experts]
    comp_signal: Optional[torch.Tensor] = None,          # int32[num_local_experts * ceil(max_rx_tokens/block_m)]
    block_m: int = 64,
    threshold: int = 0,
    num_sms: int = 0,                                   # 0 → keep legacy auto
) -> Tuple[torch.Tensor, EventOverlap, Callable]:
    ...
    # Existing body up to self.runtime.low_latency_combine(...)
    # Add these six args at the tail:
    event, hook = self.runtime.low_latency_combine(
        # existing positional/kwargs ...
        overlap=overlap,
        packed_recv_count_ptr=(packed_recv_count.data_ptr() if packed_recv_count is not None else 0),
        comp_signal_ptr=(comp_signal.data_ptr() if comp_signal is not None else 0),
        block_m=int(block_m),
        threshold=int(threshold),
        num_sms_override=int(num_sms),
    )
```

Add Python-side assertions mirroring C++ ones (at function entry, before buffer lookup), using `AssertionError` so stack traces are clear:

```python
if overlap:
    assert return_recv_hook, "overlap=True requires return_recv_hook=True (GPU spin would deadlock async-finish path)"
    assert packed_recv_count is not None and packed_recv_count.dtype == torch.int32
    assert comp_signal is not None and comp_signal.dtype == torch.int32
    assert block_m in (64, 128)
    assert threshold >= 1
    assert packed_recv_count.device == x.device and comp_signal.device == x.device
```

### 9.2 Verify SGLang call site compatibility

SGLang (`deepep.py:710-718`) passes kwargs **by name**:
```python
overlap_args_dict = dict(
    overlap=overlap_args.overlap,
    packed_recv_count=self.packed_recv_count,
    comp_signal=overlap_args.signal,
    block_m=meta_overlap_args["block_m"],
    threshold=meta_overlap_args["threshold"],
    num_sms=overlap_args.num_sms,
)
buffer.low_latency_combine(x=..., topk_idx=..., ..., **overlap_args_dict)
```

Our wrapper accepts those exact six names. Drop-in works.

### 9.3 Backwards-compat test (cheap)

Call `low_latency_combine(x, topk_idx, topk_weights, handle)` with no SBO kwargs → takes default `overlap=False` → runs legacy kernel. Required so existing `test_low_latency_pplx.py` keeps working.

---

## §10 — Testing strategy

### 10.1 Unit tests

Add to `ep/bench/test_low_latency.py` (same directory as existing tests):

1. **`test_combine_overlap_bit_exact_vs_baseline`**: same input, `overlap=False` vs `overlap=True` with `threshold=1` and `comp_signal` pre-filled to all `1`s. Expected: bit-identical output tensors (verify via `torch.equal(out_a, out_b)`; for BF16 use `torch.allclose(rtol=0, atol=0)` — truly identical because reductions are identical per-token).
2. **`test_combine_overlap_zero_token_expert`**: inject a `packed_recv_count` with some entries == 0. Must complete without deadlock within `UCCL_EP_CPU_TIMEOUT_SECS` (set env to 5 s for the test).
3. **`test_combine_overlap_signal_wait`**: pre-set `comp_signal` to all zeros, launch combine in a stream, `cudaStreamSynchronize` expected to hang; a CPU thread waits 100 ms then fills `comp_signal` to threshold → combine completes and output is correct.
4. **`test_combine_overlap_timeout`**: `UCCL_EP_CPU_TIMEOUT_SECS=1`, never fill signal. Expect `cudaErrorLaunchTimeOut` from the host check after `cudaStreamSynchronize`.

### 10.2 Microbenchmark

Extend `ep/bench/test_low_latency.py` (or clone as `test_low_latency_sbo.py`):

```
p5en 2-node 8×2 = 16 GPU
num_experts=288, num_topk=8, hidden=7168, num_tokens=128, num_max_dispatch_tokens_per_rank=128
Sweep:
  overlap ∈ {False, True}
  num_sms ∈ {1, 2, 3, 4, 8}
  kNanoSleepNs ∈ {50, 100, 200}    (rebuild per value)
Measurements:
  combine both p50/p99
  dispatch both p50/p99 (unchanged — sanity)
```

Compare against the ALLTOALL_DEEP_DIVE §0 anchor (combine both p50 = 326.69 µs).

### 10.3 SGLang E2E

Once microbench green:
- Stage 5 lane-E run with `--enable-single-batch-overlap`
- DeepSeek-V3 FP8 DP16+EP16, input 4096, output 1536, concurrency 512 (mirror SGLang PR #9660 config, scaled to our 2-node p5en)
- Record `mean ITL / P99 ITL / output tok/s` baseline (SBO off) and SBO on
- Expectation per `ALLTOALL_DEEP_DIVE.md §1.1`: mean ITL -5% to -10%, P99 ITL -6% to -10%

### 10.4 Regression

- `test_low_latency_pplx.py` all existing configs, must pass (overlap defaults to `False`, zero change)
- `test_internode.py` — unaffected, combine kernel changes only touch low-latency path
- PR #745 `PER_EXPERT_BATCHING` compile mode: rebuild with `-DPER_EXPERT_BATCHING=1`, rerun `test_low_latency_pplx.py`. The overlap path is orthogonal to dispatch-side batching (combine kernel shared), should not regress. Add `PER_EXPERT_BATCHING=1 + overlap=True` as a CI matrix cell.

### 10.5 Numerical stability

Reduce step (`internode_ll.cu:1155-1198`) is **unchanged** by Sprint A — only the send phase is overlapped. No numerical changes expected. Tests in §10.1 #1 above catch accidental drift.

---

## §11 — CUDA Graph compatibility

### 11.1 Tensor-shape constraint

When SGLang captures a CUDA Graph:
- `comp_signal` must be **allocated once** (not `torch.zeros` inside the captured region, because `torch.zeros` allocates). SGLang pre-allocates in `single_batch_overlap.py:127` — already done.
- Zero-fill between graph replays must use in-place `.zero_()` on the persistent tensor, placed **inside** the graph (SGLang does this; verify by reading `single_batch_overlap.py` and grepping for `.zero_()` or `signal.fill_(0)`).
- `packed_recv_count` and other tensors already captured in today's graph flow.

### 11.2 Kernel-parameter constraint

The six new kernel arguments (`overlap`, `block_m`, `threshold`, `num_sms_override` + two pointers) must be **captured as values** when the graph records. This is automatic — `LAUNCH_KERNEL` passes them via register — as long as the Python caller holds a stable reference to the tensors and scalars between capture and replay.

### 11.3 `num_sms_override` stability

`num_sms` must not change between captures. SGLang derives it from `overlap_args.num_sms` (`deepep.py:717`) which comes from `compute_num_sms` in SBO — static per SGLang startup. Safe.

### 11.4 Fallback

If CUDA Graph capture fails (e.g. `cudaStreamCaptureErrorIllegalOperation` during `__trap()` path — shouldn't happen at capture time since no spin occurs, but guard anyway):
- SGLang falls back to eager execution automatically (`cuda_graph_runner.py` has `try/except` around `graph.replay()`).
- On fallback, SBO still works — just without graph capture.
- No UCCL-EP-side changes needed for fallback.

### 11.5 Replay safety of `__trap()`

`__trap()` in a captured kernel during replay → `cudaErrorAssert` → host reset. That's the desired behaviour for spot-preemption / signal-never-arrives. Document in PR body.

---

## §12 — PR body draft

```markdown
## Title
ep(combine): add `comp_signal` overlap support for SGLang Single-Batch Overlap (Sprint A)

## Summary
Enables the Hopper `comp_signal` producer–consumer protocol in `low_latency_combine`, matching
DeepEP PR #483 (`antgroup-opt` branch). SGLang's Single-Batch Overlap (PR #9660, merged 2025-12-03)
can now drive UCCL-EP combine send in parallel with DeepGemm down-gemm tile production.

This is Sprint A of a 3-sprint plan (docs/SBO_SPRINT_PLAN.md); Sprint B (CPU-proxy spin for EFA)
and Sprint C (Blackwell `src_signals`) will land as follow-ups.

## Design
- **New kwargs** on `low_latency_combine`: `overlap`, `packed_recv_count`, `comp_signal`, `block_m`,
  `threshold`, `num_sms`. All default to "overlap off" — existing callers unaffected.
- **SM-stripe scheduler** (new template variant `combine<..., kOverlap=true>`): one SM per (slot_idx % num_sms)
  over a per-expert prefix-sum of `ceil(packed_recv_count[e]/block_m)` slots. Each slot spins on
  `ld.acquire.gpu.global.s32 comp_signal[local_expert * max_blocks + block_in_expert] >= threshold`
  before issuing IBGDA send.
- **Finish-flag race** resolved via new `finish_counter_per_expert` in workspace; only the SM that
  zeroes the counter fires the per-expert finish flag.
- **Memory ordering**: PTX `.gpu` scope on both sides (producer = DeepGemm `atom.add.release.gpu`,
  consumer = our `ld.acquire.gpu`). No DeepGemm patch needed in this PR — `.sys` is deferred to Sprint B.
- **Timeout**: spin bounded by `UCCL_EP_CPU_TIMEOUT_SECS * gpu_clk`, `__trap()` on overflow.
  Inherits PR #904's env convention.
- **No ABI break**: `packed_recv_src_info` stays int32 (unlike DeepEP PR #483 which upgraded to int64);
  our SM-stripe design doesn't mix `(local_expert, dst_rank)` across SMs.

Kernel arg shape sheet and memory-ordering rationale: see `docs/SBO_SPRINT_A_IMPLEMENTATION.md` in
the efa-validation repo.

## Benchmark (AWS p5en, 2-node 16-GPU, Oregon / us-west-2 AZ-TBD)

Hardware: p5en.48xlarge × 2, H200 SXM5 80 GB, EFA v4 32×400 Gbps. Single-AZ placement (per
same-AZ rule, `feedback_same_az_all_tests.md`).

### Microbench — `test_low_latency.py`

Config: `num_experts=288, num_topk=8, hidden=7168, num_tokens=128`, 100 iters p50/p99.

| Config | combine both p50 | combine both p99 | Δ |
|---|---:|---:|---:|
| baseline (pre-this-PR, post-#745) | 326.69 µs | 345 µs | — |
| `overlap=True, num_sms=1` | TBD | TBD | TBD |
| `overlap=True, num_sms=3` (default) | TBD | TBD | TBD |
| `overlap=True, num_sms=8` | TBD | TBD | TBD |

### SGLang E2E — DeepSeek-V3 FP8 decode

Config: DP16 + EP16, input 4096, output 1536, concurrency 512 (mirrors SGLang PR #9660 H20 baseline).

| Metric | SBO off | SBO on (this PR) | Δ |
|---|---:|---:|---:|
| Mean ITL (ms) | TBD | TBD | TBD |
| P99 ITL (ms) | TBD | TBD | TBD |
| Output tok/s | TBD | TBD | TBD |

Expectation (projection from SGLang PR #9660 H20 numbers, discounted for H200 faster GEMM):
mean ITL -5% to -8%, P99 -6% to -10%, tok/s +5% to +7%.

## Testing
- `test_combine_overlap_bit_exact_vs_baseline` (new)
- `test_combine_overlap_zero_token_expert` (new)
- `test_combine_overlap_signal_wait` (new)
- `test_combine_overlap_timeout` (new)
- `test_low_latency_pplx.py` — all existing configs
- `test_internode.py` — sanity
- `PER_EXPERT_BATCHING=1 + overlap=True` CI cell

## References
- DeepGemm PR #183 (producer)
- DeepEP PR #483 (consumer — `antgroup-opt` branch) — our reference implementation
- SGLang PR #9660 (MERGED 2025-12-03) — SBO main PR, H20 baseline
- Companion design docs:
  - `efa-validation/docs/SBO_COMP_SIGNAL_DEEP_DIVE.md`
  - `efa-validation/docs/SBO_SPRINT_PLAN.md`
  - `efa-validation/docs/SBO_SPRINT_A_IMPLEMENTATION.md` (this PR's bible)

## Discipline notes
- Per `feedback_uccl_pr_aws_bench.md`: all µs numbers above are from **our own** Stage 5 p5en run
  logs (not copied from upstream PR bodies). Source: `results/stage5-p5en/sbo-a/<stamp>/`.
- Per `feedback_claim_verification_discipline.md`: any claim in the "Benchmark" table is anchored
  to a concrete bench log file; reviewers can grep `results/stage5-p5en/sbo-a/` for raw output.
```

---

## Delivery-order checklist for the implementer

1. Add new C++ API params + assertions + pybind (§1).
2. Update host-side combine launch + workspace + template expansion (§3.4, §6.4).
3. Implement `kOverlap=true` kernel variant with SM-stripe (§3.2–§3.3).
4. Wire `finish_counter_per_expert` (§6).
5. Update Python wrapper (§9).
6. Write unit tests (§10.1).
7. Microbenchmark sweep + doc Δ table (§10.2).
8. SGLang E2E run (§10.3).
9. Draft PR body from §12, paste real numbers.
10. Push to `KevinZhao/uccl` branch `feat/sbo-comp-signal-sprint-a`, open PR against `KevinZhao/uccl:main`, request MaoZiming review.

File paths used:
- `/home/ec2-user/workspace/uccl/ep/src/uccl_ep.cc:1286-1373` low_latency_combine entry
- `/home/ec2-user/workspace/uccl/ep/src/uccl_ep.cc:2132-2144` nanobind def
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:733-1080` combine SEND kernel
- `/home/ec2-user/workspace/uccl/ep/src/internode_ll.cu:1206-1303` combine host launch
- `/home/ec2-user/workspace/uccl/ep/bench/buffer.py:427` Python wrapper
- `/home/ec2-user/workspace/uccl/ep/include/ep_utils.cuh:729-738` `ld_acquire_global`
- `/home/ec2-user/workspace/uccl/ep/include/ep_configs.cuh:5` `NUM_WORKSPACE_BYTES`
- `/home/ec2-user/workspace/sglang/python/sglang/srt/layers/moe/token_dispatcher/deepep.py:690-735` SGLang call site
- `/home/ec2-user/workspace/sglang/python/sglang/srt/batch_overlap/single_batch_overlap.py` SGLang producer-side orchestration
