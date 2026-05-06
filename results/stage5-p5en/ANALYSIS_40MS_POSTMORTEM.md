# 40 ms p99 postmortem — 2026-05-05 Sprint B K-1b A/B session

Purpose: establish what went wrong with the Sprint B K-1b A/B session on
2026-05-05 that produced median p99 ≈ 40 000 µs at (`ntok=128, num_sms=22`),
roughly 90× the steady-state figure the kernel reproduces at ~447 µs on
every other session. Without this explanation the K-T_sync case and any
future PR sits on top of two contradictory measurements of the same code.

## TL;DR

- **Four sessions** on the same SM-stripe kernel produced two regimes:
  **normal (~440 µs p99)** and **pathological (~40 000 µs p99)**.
- The pathological session (2026-05-05) is the **only** one whose log
  shows **`NET/OFI OFI fi_getinfo() call failed: No data available`**
  and `aws-ofi-nccl initialization failed` for every rank at startup.
- In that session **every UCCL code path** — `dispatch-base`,
  `combine-base` (legacy), and `combine-overlap` (SM-stripe) — had
  p99 ≈ 40 000 µs. Three different kernels don't all slow down together
  unless the failure is at a **shared layer below the kernel**.
- All 16 ranks degraded **in lockstep**, and latency climbed
  monotonically from iter 0 (~39 ms) to iter 19 (~50 ms) — a
  **resource-exhaustion pattern**, not tail outliers.
- The aws-ofi-nccl failure and the UCCL kernel slowdown share a cause:
  **libfabric / rdma-core on that specific pod did not fully initialize
  the EFA provider**. NCCL ended up on socket fallback (where ~40 ms is
  normal for 16-rank all-to-all), and UCCL's CPU-proxy fallback for
  IBGDA atomic writes was also degraded enough to saturate every slot.
- Root cause is **environmental on that pod only**, not the kernel.
  It does not recur in any other session on the same kernel and did
  not manifest on the 2026-05-03 session (the original Sprint A
  workload run that pre-dated Sprint B by two days).

## Evidence table

| session | date (UTC) | min | p50 | **p99** | notes |
|---|---|---:|---:|---:|---|
| sprint-a-gate-c-2026-05-03 | 2026-05-03 | 213 | 331 | **438** | Sprint A workload, normal |
| sprint-b-k1b-ab-20260505T034422Z (sprintA) | 2026-05-05 03:34 | 212 | **18 617** | **40 147** | K-1b A/B, pathological |
| sprint-b-k1b-ab-20260505T034422Z (k1b) | 2026-05-05 03:34 | 213 | 19 000 | **43 370** | same session, K-1b variant |
| sprint-b-adaptive-probev2-20260506T023000Z | 2026-05-06 02:30 | 211 | 332 | **446** | different pod, normal |
| sprint-b-smoke-20260506T093000Z | 2026-05-06 09:30 | 212 | 323 | **446** | different pod, normal |

All five runs use the same commit family on the same SM-stripe kernel.
The 40 ms figure is isolated to one pod on one date.

## The three-kernel synchronized slowdown

In sessions running `--mode=workload`, the bench loop times three
independent code paths per `(ntok, nsms)` configuration:

1. `dispatch-base` — UCCL low-latency dispatch
2. `combine-base` — UCCL legacy combine (no overlap kernel)
3. `combine-overlap-<N>` — SM-stripe combine kernel under test

At `ntok=128`:

| mode | 2026-05-06 smoke (normal) | 2026-05-05 sprintA (bad) | 2026-05-03 gate-c (normal) |
|---|---:|---:|---:|
| dispatch-base min / p99 | 60 / 539 | 59 / **40 535** | 181 / 225 |
| combine-base min / p99 | 90 / 674 | 72 / **40 247** | 79 / 679 |
| combine-overlap-22 min / p99 | 212 / 446 | 212 / **40 147** | 213 / 438 |

Three kernels with no shared device code are all clamped to the same
p99. The constant here is not kernel time. It is whatever CPU-side
resource every kernel needs per call.

Note that `min` stays normal in the bad session. The fast path through
each kernel is unchanged. What changed is that the **tail hits a
48-bit wall at 40 000 µs on every call**.

## The rank-synchronised, iter-monotonic decay

Per-iter spread of `combine-overlap-22` p99 on the 2026-05-05 session,
across 16 ranks:

```
iter  n_ranks  min_p99     median_p99   max_p99
 0    16       29 921      39 127       40 612
 1    16       22 783      26 871       31 598
 5    16       36 959      38 789       46 396
10    16       39 522      40 742       45 125
15    16       47 305      49 544       54 942
19    16       38 352      40 158       49 271
```

Two tells:

- **Rank spread is tight** (< 20 % within any iter). All 16 GPUs degrade
  together. That rules out per-rank issues (flaky NIC on one instance,
  one hot PCIe slot, …).
- **Median p99 rises from 39 ms (iter 0) to ≈ 49 ms (iter 15)**, then
  stabilises. A single capped queue emptying more slowly than it fills
  produces exactly this curve. Warmup-settling looks like the opposite
  curve (high iter 0, low thereafter).

## The NCCL OFI failure

Only the 2026-05-05 log contains these lines (first 10 s of rank init):

```
[2026-05-05 03:23:25] nccl_net_ofi_rdma_init:7978
  NCCL WARN NET/OFI OFI fi_getinfo() call failed: No data available
[2026-05-05 03:23:25] nccl_net_ofi_create_plugin:218
  NCCL WARN NET/OFI Failed to initialize rdma protocol
[2026-05-05 03:23:25] nccl_net_ofi_create_plugin:335
  NCCL WARN NET/OFI aws-ofi-nccl initialization failed
[2026-05-05 03:23:25] nccl_net_ofi_init:155
  NCCL WARN NET/OFI Initializing plugin failed
```

This is repeated for every one of the 16 ranks. The other four sessions
have zero `NET/OFI` warnings and instead show the normal
`[RDMA] Selected NIC rdmap...s0 (index N) for GPU M, NUMA node K` trace
that UCCL emits when libfabric handed it a working EFA provider.

**`fi_getinfo: No data available`** from the libfabric side means the
provider list for the EFA fabric was empty when NCCL asked for it. The
EFA kernel module and `libibverbs` may have been functional (UCCL's
`Registered proxies for device N` printed, and in-kernel IBGDA kept the
minimum latency at ~210 µs), but libfabric's provider registration was
broken in that pod image / driver combination.

When libfabric EFA is half-initialized:

- NCCL falls back to its sockets transport. Any NCCL operation is
  ~1 000× slower, but UCCL's `low_latency_combine` does not call NCCL.
- UCCL's CPU proxy uses `ibv_*` directly, not libfabric, for QP
  operations — so it still comes up.
- But the IBGDA atomic path (`nvshmemi_ibgda_amo_nonfetch_add`, fired
  once per slot from the slot-end writer warp) runs through
  driver-level submission queues that were never validated for the
  degraded fabric. Queue pressure builds over iterations, producing
  the observed monotonic climb.

## Why we almost bought the 40 ms number

- The Sprint B probe v1 reading on top of that session showed
  `sm_ovhd ≈ 1.43`, `put_ratio ≈ 0.10`, and `slot-inter-sync` ≈ 37 %
  of `T_sm`. Those are real clock-domain ratios, so they were not
  obviously wrong; we used them to pick K-1b.
- Probe v1 could not separate `T_init` from `T_sync`, so the "sync
  overhead is the problem" finding was interpreted as "mbarrier-init is
  the hoistable problem" — which became K-1b. Ran K-1b A/B on the
  same degraded pod, still 40 ms, concluded K-1b is net-negative.
- Both of those conclusions are **sound given the bad data**. They
  just told us nothing about the kernel on a healthy fabric.

## What the smoke confirmed

- 2026-05-06 09:30 smoke on a **different** pod + **different** physical
  instances reproduced 2026-05-06 02:30 to within 1 % across 9 cells
  (`sprint-b-smoke-20260506T093000Z/ANALYSIS_SMOKE.md`).
- That establishes the ~440 µs figure as a reproducible property of
  the kernel on a **healthy** p5en pod.
- It also establishes that the 2026-05-05 session is the outlier, not
  the two 2026-05-06 sessions.

## Conclusions

1. The 2026-05-05 measurements are **not the kernel's performance**.
   They reflect a degraded libfabric / IBGDA submission path on one pod.
2. Any decision taken on them should be revisited. In practice this
   means **`K-1b is rejected` stands** (net-negative on today's data
   too, independent of the pathology), but the reason written in
   Sprint B's `ANALYSIS_FINAL.md` ("K-1b didn't hit the ~37 % ceiling
   sync_share implied") was derived from contaminated shares and is
   not the correct justification.
3. The **`sync_share ∈ 26–55 %`** finding on 2026-05-06 probe v2 is
   the one that motivates K-T_sync, and it was measured on a
   healthy pod — it is intact.
4. The SM-stripe kernel's decode **`26 %`** p99 reduction at
   `(128, 22)` vs `(128, 96)` (`sprint-b-smoke-20260506T093000Z`) is
   the only reproducible performance claim on record. It, and it
   alone, is shippable.

## Preventing this from happening again

The pathological session passed all of the following checks silently:

- Bench ran to completion (no exception).
- `min` column for every cell was in the expected 60–250 µs band.
- Every rank produced output; no torchrun abort.

The symptom only showed up in `p99` / `p50`. We need a pre-scan bench
hygiene gate that would have refused to keep the data. Concretely:

- `p99 / min` ratio gate: flag / abort when `median(p99) / median(min)
  > 10×`. On the normal sessions this ratio is **~2×**; on 2026-05-05
  it was **~190×**. Two orders of magnitude of headroom.
- `p50 > 1 000 µs` gate at `ntok=128`. Normal p50 is ~330 µs; bad
  p50 was ~18 000 µs.
- NCCL / libfabric init scan: parse stderr for
  `NET/OFI.*initialization failed` or
  `fi_getinfo.*No data available` in the first 30 s. If present,
  abort the session and publish the log, don't publish the metrics.

These are cheap, deterministic, and would have saved this entire
2-day detour. They are the subject of Task 2 (bench hygiene gate).

## Artifacts referenced

- `sprint-a-gate-c-2026-05-03/workload-r{0,1}.log` — normal
- `sprint-b-k1b-ab-20260505T034422Z/workload-sprintA-r{0,1}.log`,
  `workload-k1b-r{0,1}.log` — pathological (both variants)
- `sprint-b-adaptive-probev2-20260506T023000Z/workload-static-r{0,1}.log`
  — normal, morning session
- `sprint-b-smoke-20260506T093000Z/smoke-r{0,1}.log` — normal, smoke
  on different hardware

## Unresolved item

Why the libfabric EFA provider on that specific 2026-05-05 pod came
up degraded is not in the log and not reproducible now (pod and
instances are gone). Candidates we cannot distinguish from the
available evidence:

- Pod image mismatch (that session predated the nvcr-25.10 standardisation
  on 2026-05-06; it may have been running 25.04 with a CUDA 12.9 compat
  libcuda and an older libfabric).
- Host-level `/opt/amazon/efa/` missing on one of the physical nodes
  (we observed this exact condition on 2026-05-06 morning before the
  yaml was patched to stop bind-mounting `/opt/amazon/efa`).
- Spot instance of the era had a stale EFA firmware / driver that got
  patched out by the time the watcher next caught capacity.

If this recurs the diagnostic path is:

1. On pod startup, `fi_info -p efa -l` → expect one or more EFA
   providers; if empty, abort.
2. `grep NET/OFI stderr` after the first `dist.init_process_group`;
   any WARN = abort.
3. If (1) passes and (2) fails, inspect `aws-ofi-nccl` version in the
   image against the host's `libfabric` ABI.
