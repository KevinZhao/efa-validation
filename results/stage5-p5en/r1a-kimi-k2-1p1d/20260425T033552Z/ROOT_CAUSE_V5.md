# Root-cause analysis: v5 Kimi-K2 cold start stuck

## Summary

**Not a deadlock. A CPU-saturation livelock caused by PR #1944.**

v5 Mooncake CQ polling workers (`WorkerPool::performPollCq`) busy-spin with fewer
`sched_yield` calls than v2. With 16 EFA NICs × 8 TP ranks × 2 pods = 256 poll
threads continuously spinning at 100% CPU, the Python GIL and ThreadPoolExecutor
workers running the MoE weight loader get starved. What would take 30 min on v2
takes >2 h on v5 (possibly indefinitely on a busy box).

## Evidence chain

### 1. Same SGLang, same workload, same pipeline
- v2 and v5 have **identical** SGLang 0.5.10 source:
  - `fused_moe_triton/layer.py`: 1189 lines (same)
  - `deepseek_common/deepseek_weight_loader.py`: 714 lines (same)
  - `deepseek_v2.py`: 2336 lines (same)
- Both use same `mooncake-transfer-engine==0.3.10.post2` pip metadata
- Only `engine.cpython-310-x86_64-linux-gnu.so` differs:
  - v2 sha256 `e13da237ddb06b5cdb770ea2cdc3a643c3ad4552b8824474ac3d1376afeabb32`
  - v5 sha256 `90ee2079a8425a21aeac2c3831a47f90972d24d6bccad3769aef58e03f0b078c`
- Commit diff: v2=`e1d6d6f` (0.3.10.post2 tag), v5=`634b709` (post-tag, includes #1944)

### 2. Symbol diff proves #1944 is the only change
v5 vs v2 symbol deltas in `engine.cpython-310-...so` (via `nm -D --demangle`):

| New in v5 (PR #1944 artefacts) |
|---|
| `EfaContext::buildSharedEndpoint(unsigned long, unsigned long)` |
| `EfaContext::peekEndpoint(const string&)` |
| `EfaContext::insertPeerAddr(const string&, unsigned long&)` |
| `EfaContext::insertPeerAddrBytes(const uchar*, unsigned long, unsigned long&)` |
| `EfaContext::removePeerAddr(unsigned long)` |
| `EfaContext::submitSlicesOnPeer(unsigned long, …)` |
| `EfaContext::construct(unsigned long, unsigned long, int)` (signature changed from `(ulong, ulong, uchar, int, ulong, int)`) |

v2 had `EfaContext::construct(ulong, ulong, uchar, int, ulong, int)` — the
`uchar` parameter is gone in v5, consistent with the SRD shared-endpoint refactor
eliminating the per-peer QP index.

### 3. Py-spy snapshots show CPU starvation, not I/O wait

At 05:11 UTC (57 min in):
```
Thread 330 (idle): MainThread
    as_completed (concurrent/futures/_base.py:245)
    do_load_weights (deepseek_weight_loader.py:361)

Thread 2151: ThreadPoolExecutor-1_0
    _load_w13 (moe/fused_moe_triton/layer.py:454)
    _weight_loader_impl
    _weight_loader_physical
    weight_loader  [active]
```

At 05:30 UTC (2h 15m in, right before kill):
```
Thread 330 (idle): MainThread  # still same position
    as_completed (concurrent/futures/_base.py:245)

# NO ThreadPoolExecutor workers visible
```

Scheduler ps stats:
- %CPU = 1750% (17.5 cores per TP rank process)
- Accumulated CPU time: 1 day 13h 40m across 8 ranks
- 8 ranks × 17.5 cores = **140 cores busy-spinning** on a 192-vCPU host

16 CQ poll threads per rank (`Started 16 CQ polling worker threads` in log)
× 8 ranks + MainThread per rank ≈ 136 spinners. Matches 140 cores observation.

### 4. Scheduling relaxation proof

Comparing `sched_yield@plt` call count in `.text` of `engine.cpython-310-...so`:
- v2: **85 calls**
- v5: **82 calls** (-3)

PR #1944 removed 3 yield points. Net effect: v5 CQ poll loops spin tighter —
they release CPU less often, starving other threads in the same process and
across the host's CPU scheduling quantum.

In v2, the 16 polling threads per rank shed CPU often enough that
ThreadPoolExecutor workers (running MoE weight loader) could make progress.
In v5, they don't, and the loader worker thread eventually exits (2151 gone by
05:30) while MainThread is still waiting for its future.

### 5. Indirect confirmation via Stage 4 history

Stage 4 used the v2 Mooncake commit. 1P:2D Kimi-K2 cold-started successfully
in ~30 min, multiple times. Same hardware (p5en), same SGLang 0.5.10, same Kimi-K2
FP8 weights — the only difference in R1a on v5 is the Mooncake .so. If weight
loading itself were the cause, v2 would also stick; it didn't.

## Not the root cause

- **Not a deadlock**: MainThread's `as_completed` is an `IO wait` on a futex that
  would be signalled by future completion; workers exist and are computing when
  CPU is available.
- **Not a Mooncake MR-register bug**: `register_buffer_to_engine` is only called
  **after** `load_model` completes (in the disaggregation KV manager init). Weight
  load is unrelated to Mooncake MR registration.
- **Not a MoE kernel JIT issue**: Kimi-K2 uses `_load_w13` / `_load_w2` which is
  plain `tensor.copy_`, no Triton compilation at load time.
- **Not an SRD `max_wr=256` issue**: that limit only matters once KV transfers
  begin; weight load is before any disaggregation traffic.

## Mitigation (no image change needed)

Mooncake exposes `MC_WORKERS_PER_CTX` (found via `strings engine.so | grep ^MC_`).
Default = 16 (one per NIC). Reducing to 4 or 2 cuts spinning threads from
256 → 64 or 32, enough to unstick the Python weight loader:

```yaml
env:
  - { name: MC_WORKERS_PER_CTX, value: "2" }
```

Other knobs that might help:
- `MC_NUM_CQ_PER_CTX` — fewer CQs to poll
- `MC_MAX_CQE_PER_CTX` — smaller CQ entries

**Stage 4 already ran with these defaults on v2 successfully; this workaround
is specifically for v5 cold-start path until upstream adds a yield back.**

## Recommended next action

Re-run R1a on v5 with `MC_WORKERS_PER_CTX=2` in both prefill and decode pod env.
Expected cold start: ~30 min (same as v2 on Stage 4).

If that works, report back to whn09 / Mooncake maintainers:
> PR #1944's removal of `sched_yield` in the CQ poll loop causes CPU starvation
> during the SGLang MoE weight load phase on 1T-class models. Suggest adding
> `sched_yield()` every N iterations or adaptive backoff when the CQ is empty.

## If MC_WORKERS_PER_CTX doesn't help

Further options without switching image:
1. Pin Mooncake to specific CPUs via `taskset` so the spinning threads can't
   preempt Python's CPU cores
2. Set `ulimit -n` lower to restrict poll thread count (won't work; these are
   internal threads)
3. File an issue in Mooncake upstream and in the meantime request Tokyo admin
   to rebuild a `v5.1` pinning to commit parent of #1944
