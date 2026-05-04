# T0 Baseline (Tokyo, 2026-05-03)

Hardware: 2× p5en.48xlarge spot in ap-northeast-1a (apne1-az4)
UCCL SHA: dd9573dd (post-PR #745, head of main as of 2026-04-25)
Bench: test_low_latency.py --num-tokens=128 --hidden=7168 --num-topk=8 --num-experts=288
EP=16 (2 nodes × 8 GPU), FP8 dispatch/combine

## PEB=0
  Dispatch avg_t (µs): median=232.94 (runs: 193.88 | 232.94 | 281.66)
  Combine avg_t (µs): median=332.82 (runs: 315.02 | 332.82 | 357.56)
  Dispatch BW (GB/s): median=39.49 (runs: 38.74 | 39.49 | 53.71)
  Combine BW (GB/s): median=48.28 (runs: 46.14 | 48.28 | 60.16)

## PEB=1
  Dispatch avg_t (µs): median=194.57 (runs: 267.13 | 194.57 | 191.97)
  Combine avg_t (µs): median=316.27 (runs: 351.45 | 311.63 | 316.27)
  Dispatch BW (GB/s): median=39.14 (runs: 44.46 | 38.65 | 39.14)
  Combine BW (GB/s): median=46.66 (runs: 53.07 | 46.66 | 45.97)

## PR #745 body reference
  Without batching: dispatch 218.56 µs  combine 325.98 µs  disp_bw 35.36 GB/s  comb_bw 45.03 GB/s
  PER_EXPERT_BATCHING=1: dispatch 174.90 µs  combine 326.69 µs  disp_bw 42.88 GB/s  comb_bw 44.94 GB/s

## Our deltas vs PR #745 body
  PEB=0:
    Dispatch avg_t: ours 232.94 vs PR#745 218.56  Δ=+14.38 µs (+6.6%)
    Combine  avg_t: ours 332.82 vs PR#745 325.98  Δ=+6.84 µs (+2.1%)
    Dispatch BW:    ours 39.49 vs PR#745 35.36  Δ=+11.7%
    Combine  BW:    ours 48.28 vs PR#745 45.03  Δ=+7.2%
  PEB=1:
    Dispatch avg_t: ours 194.57 vs PR#745 174.90  Δ=+19.67 µs (+11.2%)
    Combine  avg_t: ours 316.27 vs PR#745 326.69  Δ=-10.42 µs (-3.2%)
    Dispatch BW:    ours 39.14 vs PR#745 42.88  Δ=-8.7%
    Combine  BW:    ours 46.66 vs PR#745 44.94  Δ=+3.8%

## N1 lever measurement (PEB=0 → PEB=1)
  Dispatch avg_t: 232.94 → 194.57  Δ=-38.37 µs (-16.5%)
  Combine  avg_t: 332.82 → 316.27  Δ=-16.55 µs (-5.0%)
  Dispatch BW:    39.49 → 39.14  Δ=-0.9%

PR #745 claimed: dispatch -20% with PEB=1. Our observed: -16.5%
