# Sprint A Gate A — Analysis

## Verdict

**PASS** — branch `feat/sbo-comp-signal-sprint-a` at commit `1304e828` compiles
cleanly on a p5en.48xlarge H200 container with `nvcc 12.6 SM=90` and
`PER_EXPERT_BATCHING=0`. The kernel link step produced
`ep.cpython-310-x86_64-linux-gnu.so` with all 8 `combine<>` template
instantiations (`{use_logfmt, aggressive_atomic, kOverlap}` × 2 × 2 × 2 = 8).

## Diff summary

Sprint A adds (on top of PR #919 stub):

| File | +/- |
|---|---|
| `ep/src/uccl_ep.cc` | `if (overlap)` stub body replaced with Hopper-path assertions + pointer reinterpret + forward to `internode_ll::combine(...)` with 6 new args |
| `ep/include/internode_ll.cuh` | `combine(...)` declaration extended with 6 new trailing args (all defaulted) |
| `ep/src/internode_ll.cu` | (a) host `combine(...)` grows `send_overlap` branch that sets `num_sms=3, num_warp_groups=1, num_warps_per_group=32`; (b) workspace layout gets `finish_counter_per_expert[num_local_experts]`; (c) kernel template gains `kOverlap` bool; (d) SEND phase is wrapped in a `for (send_slot_idx = slot_start; send_slot_idx < num_experts; send_slot_idx += slot_stride)` so overlap mode strides with `num_sms`, legacy mode still runs 1 iter; (e) when `kOverlap`, one-lane spin on `ld.acquire.gpu.global.s32 comp_signal[local_expert*max_blocks + last_block] >= threshold` before touching TMA/mbarrier; (f) `COMBINE_LAUNCH_CASE` macro extended to pick among 8 template variants |
| `ep/bench/buffer.py` | `NotImplementedError` guard swapped for full kwarg validation (dtype/device/block_m/threshold/return_recv_hook), and the 7 DeepEP-compatible args are forwarded to `self.runtime.low_latency_combine` |

Total: +216 / -56 lines (215 net), same 4 files.

## Compile-time checks exercised

- `goto` label bypass across local variables: **caught and fixed** on first attempt (see `ENV.md §Gotchas`).
- 8-way template expansion: builds without errors or `__launch_bounds__` warnings.
- No new static_assert failures.
- Kernel signature + host declaration stayed in sync.

## What this does NOT prove

- Correctness of the overlap kernel path: unit tests (bit-exact vs overlap=False, zero-token experts, signal wait/timeout) are still pending → Gate B
- Performance improvement: the whole point of Sprint A. Needs a 2-node p5en bench with DeepGemm (or a mock producer) → Gate C
- Interaction with `PER_EXPERT_BATCHING=1`: not tested in this pass; N1 matrix cell owed in the Sprint A PR body
- Kernel-level determinism at SM=100 (Blackwell): out of scope; Sprint C

## Cost

- Single p5en spot instance up for ~23 min: 14:04 → 14:27 UTC
- Spot price ~$24/hr in Tokyo → **~$9.20**, well within the "build-only" budget

## Next

1. Draft Gate B unit tests (bit-exact / zero-token / signal-wait / timeout) — see `docs/SBO_SPRINT_A_IMPLEMENTATION.md` §10.1
2. Design a mock `comp_signal` producer kernel for CI (so unit tests don't need DeepGemm)
3. Open a Sprint A PR on top of `uccl-project/uccl#919` — blocked on #919 merge; do NOT open yet

## Raw files

- `build.log` — full make output
- `ENV.md` — hardware + software + timeline + gotchas
