# Sprint A Gate B — Unit Test Results

**Date**: 2026-05-03 14:30 → 15:27 UTC
**Branch**: `feat/sbo-comp-signal-sprint-a` @ `05f42ab0`

## Verdict

**Gate B reveals a correctness bug.** `test_overlap_bit_exact_vs_baseline` fails across all 16 ranks with `max abs diff ∈ [1.45, 1.96]` when comparing `low_latency_combine(overlap=True, comp_signal pre-filled to threshold)` against `low_latency_combine(overlap=False)` on the same input tensors.

Non-zero diff means the overlap path is producing partially-correct output — data is making it across, but some (dst_rank, local_expert) pairs are being missed, or TMA/mbarrier state is being corrupted between the outer-loop iterations my SM-stripe scheduler introduced.

## Setup

- 2× p5en.48xlarge in apne1-az4 (Tokyo, SPS=9 at acquisition)
- EP=16, EFA fabric, p5en images from ECR `yanxi/uccl-ep:latest`
- `UCCL_IB_HCA=rdmap` (EFA device prefix match)
- `num_tokens=128 hidden=7168 num_topk=8 num_experts=288`

## What passed

- Build Gate A ran clean across both nodes (identical result to yesterday's 1-node build)
- Test 1 (bit-exact) reaches combine kernel — no launch failures, no CUDA OOM, no fabric timeout
- UCCL proxy binds to all 16 EFA NICs per node correctly (`[RDMA] Selected NIC rdmapXXX` for each GPU/NUMA pairing)

## What failed: bit-exact

Every rank reports a non-zero max abs diff:
```
[rank 0] FAIL: max abs diff = 1.515625
[rank 1] FAIL: max abs diff = 1.5390625
[rank 2] FAIL: max abs diff = 1.52734375
[rank 3] FAIL: max abs diff = 1.486083984375
[rank 4] FAIL: max abs diff = 1.47265625
[rank 5] FAIL: max abs diff = 1.65625
[rank 6] FAIL: max abs diff = 1.44921875
[rank 7] FAIL: max abs diff = 1.96484375
```

The diff is consistent (bf16 output values of magnitude ~1-2), which rules out uninitialized memory; that would give either `nan`/`inf` or values of 10^38 scale.

## Suspect root cause (unverified — needs kernel debug)

Overlap-mode kernel wraps the legacy SEND phase in a `for (send_slot_idx = sm_id; send_slot_idx < num_experts; send_slot_idx += num_sms)` loop. Inside each iteration, the legacy body:

1. Unpacks `layout` for `(dst_rank, local_expert)` from the current slot
2. Initializes TMA `mbarrier[3]` and phase counters in smem (lines 840-852)
3. Runs per-token TMA load → LogFMT → IBGDA put
4. Hits `sync_barrier<true>(warp_group_id + 1, num_warps_per_group * WARP_SIZE)` (line 1041)
5. Writes finish flag

The legacy kernel runs this path exactly once per CTA. My loop runs it N times. Between iterations, the TMA mbarrier state, `tma_phase[stage_idx]`, and `tma_store_wait` fence are stale. Specifically:
- `mbarrier_init` is guarded by `if (lane_id < kNumStages)` — runs every iteration, but `fence_view_async_shared()` + `fence_barrier_init()` may not be enough to invalidate the previous iteration's pending TMA loads
- `sync_barrier<true>(1, 1024)` is a named barrier (`bar.sync 1, 1024`). Re-use across iterations is supposed to be legal, but only if all 1024 threads participate each time. In my stripe, threads that do not participate in this (local_expert, dst_rank) pair's per-token work (e.g. threads in a different warp) still reach the barrier — but via the TMA smem code path they may deadlock or early-exit.
- The `if (sub_warp_id == 1 and lane_id == 0)` finish-flag write is fine for per-slot flag, but `atomic_add_release_global(atomic_clean_flag, -1)` decrements a flag that was initialized to `num_experts` at kernel start, and I decrement it `num_experts / num_sms` times per SM × num_sms SMs = num_experts times total. That part should be balanced.

## Suspect fix list (ordered by likelihood)

1. **mbarrier re-initialization between iterations**: move `mbarrier_init` into the outer for-loop body, AFTER a `__syncthreads()` fence. Currently it's at line 840, inside `if (responsible_expert_idx < num_experts)` but before the for-loop body was wrapped. Needs explicit `asm volatile("bar.sync 0;")` between iterations to drain stale TMA stores.

2. **Re-scope smem buffer allocation per slot**: TMA buffers live in shared memory at `smem_buffer + warp_id * kNumStages * (kNumTMABufferBytes + 16)` — each warp has its own stripe, which is correct, but the offsets assume the buffer is used once. Re-use is fine in principle; the issue is synchronization.

3. **`tma_store_wait()` before starting next slot**: ensure all TMA stores from the previous slot have committed before we overwrite the smem buffer.

4. **Finish-flag race**: in legacy, `sync_barrier` synchronizes across the whole CTA (1024 threads), and only `sub_warp_id==1, lane_id==0` proceeds to write the flag. In my stripe, once the flag is written, the other threads fall through to `__syncwarp()` and then back to the outer for-loop. They may start the next slot before the flag is committed.

## What WAS verified

- **Overall end-to-end flow works**: dispatch → combine (overlap=True) executes without CUDA errors, without deadlock, without fabric timeout. This validates:
  - The Python→nanobind→C++→kernel parameter forwarding chain
  - `packed_recv_count` / `comp_signal` pointer reinterpret + pass-through
  - `UCCL_IB_HCA=rdmap` selects EFA NICs correctly
  - EFA resource (`vpc.amazonaws.com/efa: 16`) grants proper device access inside pod
  - `num_sms=3` kernel launch is accepted
  - Finish-flag write is reaching peers (otherwise test would hang on `rdma_recv_flag[expert_idx]==1` spin in RECV phase, not fail with a data diff)

In short: **wiring is correct, kernel semantics need a fix between outer-loop iterations.**

## What was NOT reached

- `test_overlap_signal_wait` — not run (test 1 failed first and raises)
- `test_overlap_zero_token_expert` — not run
- `test_overlap_bad_kwargs` — not run

## Cost

- 2× p5en spot, 2 nodes up for ~60 min: ~$48 total (but only ~15 min were productive; 45 min burned on infra debugging — EFA permissions, ephemeral-storage eviction, kubectl exec timeouts)

## Next

1. Debug the kernel: introduce `__syncthreads()` + `tma_store_wait()` boundary between outer-loop iterations
2. After kernel fix, re-run Gate B to verify bit-exact
3. Only after Gate B green → Gate C perf bench

## Raw

- `test-r0.log` / `test-r1.log` — full torchrun output with FAIL stacks
- Build log stayed on node (not archived; already verified yesterday via Gate A)
