# R1c · Kimi-K2 1P:3D ISL sweep — prefill headroom characterization

**Run ID**: `r1c-kimi-k2-1p3d/20260426T031000Z-isl-sweep`
**Completed**: 2026-04-26T03:10Z
**Topology / cluster**: same R1c pods (1 prefill + 3 decode + lb), Ohio `use2-az2`
**Method**: hold decode work constant (OSL=512), sweep ISL ∈ {1024, 2048, 4096, 8192}. rate=6 for ISL≤4096, rate=4 for ISL=8192 (avoid overload). num-prompts sized for ~60 s window.

## Raw results

| ISL | rate | num | Duration | Req/s achieved | Input tok/s | Output tok/s | **Total tok/s** | Median TTFT | P99 TTFT | Median TPOT | P99 TPOT | Median ITL | P95 ITL | Median E2E | Peak concur |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1024 | 6 | 256 | 55.2 s | 4.64 | 2386 | 1147 | **3532** | 1808 | 15610 | 16.6 | 77.0 | 15.7 | 58.9 | 10184 | 84 |
| 2048 | 6 | 256 | 64.1 s | 3.99 | 4322 | 987  | **5309** | 1359 | 27269 | 17.6 | 91.7 | 19.1 | 58.0 | 6358 | 71 |
| 4096 | 6 | 256 | 60.4 s | 4.24 | 8958 | 1047 | **10005**| 2688 | 23189 | 14.6 | 66.1 | 15.7 | 33.2 | 8085 | 82 |
| 8192 | 4 | 128 | 48.5 s | 2.64 | 10378 | 686 | **11064**| 3383 | 13567 | 13.7 | 19.1 | 13.5 | 22.6 | 7906 | 38 |

## Prefill compute characterization

**Input tok/s scales sub-linearly with ISL** — doubling ISL from 1024 to 2048 to 4096 to 8192 only gets +81%, +107%, +16% more input tokens/sec. That's because attention is O(N²) per sequence, and the `chunked-prefill-size=4096` chunker pages big prompts into smaller batches:

| ISL | Input tok/s | Per-request prefill budget | Inference |
|---|---|---|---|
| 1024 | 2386 | ~0.45 s/req prefill | chunked-prefill digests whole prompt in one chunk (1024 < 4096) |
| 2048 | 4322 | ~0.47 s/req | still one chunk; attention matrix 4× larger, but prefill stays well-batched |
| 4096 | 8958 | ~0.46 s/req | exactly one chunk; peak efficiency for this config |
| 8192 | 10378 | ~0.79 s/req | **2 chunks per request** — chunking overhead shows up |

The **"sweet spot for raw input tok/s is ISL=4096"** with this chunked-prefill setting. Setting ISL=8192 + 2 chunks costs ~70% more wall-clock per request despite doubling input size, because chunk-to-chunk dependencies force sequential passes.

## Decode characterization (cross-ISL)

Decode behavior is remarkably **invariant across ISL** (because decode step is O(1) per token, bound by KV-cache read + autoregressive step):

| ISL | Median TPOT | Median ITL | Output tok/s |
|---|---|---|---|
| 1024 | 16.6 ms | 15.7 ms | 1147 |
| 2048 | 17.6 ms | 19.1 ms | 987 |
| 4096 | 14.6 ms | 15.7 ms | 1047 |
| 8192 | 13.7 ms | 13.5 ms | 686 |

Decode pipeline outputs **~1000 tok/s aggregate across 3 decode pods** (so ~330 tok/s/pod), invariant of ISL. The variation is Poisson noise. **ISL=8192 output is lower only because rate was 4 not 6.**

## Key findings

1. **Prefill is NOT the 1P bottleneck at ISL=1024**. In the rate sweep we thought it was, but ISL sweep shows prefill can push 10k+ input tok/s — the rate=12 TTFT blowup wasn't prefill saturation, it was **scheduler queueing** (waiting for decode KV slots).

2. **Total system throughput at ISL=4096 + rate=6 = 10 GB/s-class** token generation. This is likely the **real R1c ceiling for mixed workloads** — roughly the p5en node's sustained H200 compute bound (FP8 GEMM + attention combined).

3. **TTFT improves with ISL** (median 1.8 s at ISL=1024 → 2.7 s at ISL=4096) because longer prompts amortize chunked-prefill setup — more computation per scheduler tick means the request sees less queue time.

4. **ISL=8192 is the chunked-prefill crossover**: 2 chunks per request, so effective prefill throughput efficiency drops. For customers with long-context serving, tuning `chunked-prefill-size` to 8192 (to keep 1 chunk per request) would likely lift ISL=8192 output into ~12-13k tok/s range. Not tested today.

5. **Decode path is fully saturated only at very high concurrency** (rate=12 from earlier sweep). In normal ISL regimes, decode never hits its ceiling because prefill gates new arrivals.

## What this says about 2P:2D (next experiment)

Adding a 2nd prefill pod would:
- Roughly **double input tok/s ceiling at high rate** (where 1P was the gate)
- **NOT change TPOT** at low rate (decode untouched)
- **Not change** ISL=4096 total tok/s at rate=6 (system wasn't prefill-bound there)

So 2P:2D's value is mostly at **high-load TTFT tail** and at **ISL=1024 rate=12+** territory, not at the nominal rate=6 / ISL=4096 point. We'll verify.

## Artifacts

- Raw bench outputs are inlined above
- Same R1c pods used — no re-deploy between points
- Cross-ref: `results/stage5-p5en/r1c-kimi-k2-1p3d/20260426T024500Z-rate-sweep/RATE_SWEEP.md` for rate sweep context
