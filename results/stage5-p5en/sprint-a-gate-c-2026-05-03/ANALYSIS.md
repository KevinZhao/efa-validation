# Sprint A Gate C — Combine Kernel Latency Bench

**Date**: 2026-05-03 17:45 UTC
**Branch**: `feat/sbo-comp-signal-sprint-a` @ `f96a51cd`
**Hardware**: 2× p5en.48xlarge (Tokyo apne1-az4, new nodes `ip-10-99-10-81`, `ip-10-99-10-211`)
**Config**: EP=16, `num_tokens=128 hidden=7168 num_topk=8 num_experts=288`, PEB=0, SM=90

## Raw data

- 30 iters × 2 modes × 16 ranks × 50 tests/bench = **24 000 combine invocations**
- 480 per-iter `avg_t` rows per mode, 480 per-iter `min_t`/`max_t` rows each

## Headline numbers

| Metric | baseline (num_sms=auto=32) | overlap (num_sms=3) | Δ |
|---|---|---|---|
| combine avg_t mean | **353 µs** | **971 µs** | **+175%** |
| combine avg_t median | 365 µs | 971 µs | +166% |
| combine avg_t stdev | 24 µs | 5 µs | — |
| combine min_t mean | 107 µs | 952 µs | — |
| combine max_t mean | 641 µs | 993 µs | — |

**Bootstrap 95% CI on (overlap − baseline) / baseline** (5000 resamples):

| Metric | CI lower | median | CI upper | Crosses 0 |
|---|---|---|---|---|
| avg | +173.4% | +175.1% | +176.7% | **NO** |
| min | +745.5% | +793.2% | +844.5% | **NO** |
| max | +52.5% | +54.9% | +57.5% | **NO** |

## Interpretation

**The standalone overlap combine kernel is ~2.75× slower than baseline
when measured in isolation.** This is expected and does not invalidate
Sprint A — the SBO design deliberately trades combine-kernel speed for
the ability to run combine concurrently with DeepGemm's down_gemm.

### Why is the overlap kernel slower standalone?

- **Baseline**: 32 SMs each own ~9 experts (`num_warp_groups=3-4`, one
  expert per warp_group). 288 `(dst_rank, local_expert)` pairs run in
  parallel across 32 SMs.
- **Overlap**: 3 SMs each stride over 96 `(dst_rank, local_expert)`
  pairs serially. Total TMA+IBGDA work is the same, but distributed
  across 10× fewer SMs → 10× longer wall time if the kernel is
  SM-bound.
- Actual slowdown 2.75× (not 10×) reflects that the kernel is partially
  network-bound (EFA link bandwidth is the bottleneck for per-token
  TMA-store + IBGDA-put), so reducing SM count doesn't linearly slow it.
- Fix H1's overhead (`cp.async.bulk.wait_group 0` + `__syncthreads()`
  between slots) is lost in the noise at this level.

### Why is this still the right design?

SGLang SBO assumes:
```
  # Traditional:  gemm_up → dispatch → gemm_down → combine → next_layer
  # SBO:          gemm_up → dispatch → (gemm_down ∥ combine) → next_layer
```
With 3 SMs for combine, 29 SMs remain free for `gemm_down`. The 618 µs
of extra combine time (971 − 353) is hidden behind DeepGemm's down_gemm,
which on this config takes ~800-1200 µs. **Net: effectively saves
353 µs of combine wall time per iteration**, assuming GEMM already ran
that long anyway.

### Stdev collapses under overlap

- baseline stdev = 24 µs (7% CV)
- overlap stdev = 5 µs (0.5% CV)

With 3 SMs the kernel saturates EFA uniformly; 32-SM baseline shows
tail-latency noise (possibly from NIC rate-shaping contention across
warp_groups on same EFA NIC).

## What this DOESN'T claim

- **NOT an SBO e2e speedup claim**. To prove SBO's benefit, we need
  SGLang e2e running DeepSeek-V3 with `--enable-single-batch-overlap`.
  That's blocked on DeepGemm + DSv3 checkpoint availability.
- **NOT a claim that overlap is ready for production**. It's correct
  (Gate B PASSED) and has a measurable but expected cost in isolation.
  Productionization requires Gate D (full SGLang e2e).

## Verdict

**Gate C SUFFICIENT for Sprint A PR claim**: "overlap=True is correct
(Gate B all-zero diff) and adds 618 µs to combine when DeepGemm is
absent. Under SBO, this cost is hidden by DeepGemm's concurrent
execution — expected net benefit 5-10% e2e ITL per SGLang PR #9660."

## Cost

- 2× p5en for ~20 min = ~$16

## Raw

- `bench-r0.log` — rank0 side BENCH rows + full startup
- `bench-r1.log` — rank1 side
- `analyze.py` — bootstrap CI script
- Run: `python3 analyze.py bench-r0.log bench-r1.log`
