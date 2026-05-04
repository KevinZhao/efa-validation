# Sprint A Gate C — num_sms Sweep (REVISED)

**Date**: 2026-05-03 evening
**Branch**: `feat/sbo-comp-signal-sprint-a` @ `517ffe6b`
**Hardware**: 2× p5en.48xlarge (Tokyo apne1-az4, new nodes `ip-10-99-10-64`, `ip-10-99-10-253`)
**Raw**: 1920 BENCH rows (15 iters × 8 modes × 16 ranks, each bench() = 50 tests)

## Headline

**The SGLang-default `num_sms=3` is wrong for UCCL-EP on EFA.** It's 2.72×
slower than baseline. At `num_sms=24` the overlap kernel **beats baseline
by 10%**, and still frees 108 SMs for DeepGemm to use concurrently.

## Results table (µs, mean of 240 per-iter bench() averages per mode)

| mode | num_sms | avg_mean | avg_med | avg_std | Δ vs baseline | 95% CI |
|---|---:|---:|---:|---:|---:|---:|
| **baseline** | 32 (auto) | 363.34 | 371.71 | 23.30 | — | — |
| overlap-3 | 3 | 988.03 | 988.18 | 3.42 | **+172%** | [+170%, +174%] |
| overlap-6 | 6 | 557.93 | 558.26 | 1.60 | +54% | [+52%, +55%] |
| overlap-8 | 8 | 452.52 | 452.49 | 1.50 | +25% | [+24%, +26%] |
| overlap-12 | 12 | 359.56 | 360.10 | 5.72 | **−1%** | [−1.8%, −0.2%] |
| overlap-16 | 16 | 345.21 | 346.44 | 5.52 | **−5%** | [−5.8%, −4.2%] |
| **overlap-24** | **24** | **326.05** | **326.72** | **2.88** | **−10%** | **[−11.0%, −9.5%]** |
| overlap-32 | 32 | 328.29 | 328.36 | 3.11 | −9.7% | [−10.4%, −8.9%] |

## Interpretation

### num_sms=3 is bandwidth-starved

With only 3 SMs, the kernel can't issue enough in-flight IBGDA puts to
saturate 16 EFA NICs × 400 Gbps = 800 GB/s. Combine work per iteration =
288 `(dst_rank, local_expert)` pairs × ~128 tokens × 14 KB/token = ~540 MB
of outbound data. At full EFA rate this would take 675 µs; we see 988 µs,
suggesting effective bandwidth utilization is ~68% at num_sms=3.

### num_sms=24 is the sweet spot

- combine **10% faster** than baseline (326 vs 363 µs)
- overhead stdev collapses from 23.3 µs to 2.9 µs (**8× more stable**)
- Still frees 108 of 132 SMs for DeepGemm co-execution
- Beyond 24, no further gain (num_sms=32 marginally worse, likely
  coordination overhead from sync_barrier over 1024×32 threads)

### What changed the picture

The original Gate C used `num_sms=3` because that's what SGLang's deepep.py
default suggested (Hopper-tuned on InfiniBand). UCCL-EP runs on AWS EFA
(16 NICs per node instead of ~1-2 on IB) — the optimal SM count is
substantially higher.

## Implications for Sprint A

1. **The kernel design is correct**. SM-stripe scheduling works as
   intended; performance scales with num_sms until network bandwidth is
   saturated (~16-24 SMs on EFA).

2. **The SGLang default must be overridden for UCCL-EP**. Either:
   - (a) UCCL-EP provides its own default via env var (e.g.,
     `UCCL_EP_OVERLAP_NUM_SMS=24`)
   - (b) UCCL-EP's Python wrapper substitutes num_sms=0 → "auto pick best
     for EFA" (24) when the caller didn't specify
   - (c) The Sprint A PR body documents this and lets SGLang handle it

3. **SBO-on-EFA is viable** when properly tuned. At num_sms=24, a full
   SBO iteration's combined (gemm_down || combine) wall time is
   approximately `max(gemm_down, 326 µs)`. Even if gemm_down is much
   shorter, we've still saved 37 µs vs non-overlap baseline.

## Recommended default

```cpp
int num_sms = (num_sms_override > 0) ? num_sms_override : 24;  // was 3
```

In `ep/src/internode_ll.cu` host combine function, change the default for
overlap mode from 3 to 24.

## Caveats

1. This is an **isolated combine bench**. It does not measure combine
   overlapping with real DeepGemm. A Gate D (SGLang e2e with DeepSeek-V3)
   would produce the definitive number.
2. The sweep used `num_tokens=128 hidden=7168 num_topk=8 num_experts=288`.
   Optimal num_sms may differ at other configs (e.g., larger hidden →
   more data → higher SM count helps less because each SM already
   saturates its NIC). Recommended scan each config before production.
3. Hopper/InfiniBand environments may legitimately prefer num_sms=3
   (fewer NICs to feed, Hopper co-issue limits). **Do not change the
   SGLang default upstream** — only change UCCL-EP's internal default.

## Cost

- 2× p5en spot for ~25 min: ~$20

## Raw

- `sweep-r0.log` / `sweep-r1.log` — full torchrun bench output
- `analyze_sweep.py` — sweep analysis script
