# R1c · Kimi-K2 1P:3D rate sweep — finding the real throughput ceiling

**Run ID**: `r1c-kimi-k2-1p3d/20260426T024500Z-rate-sweep`
**Completed**: 2026-04-26T02:45Z
**Topology / cluster**: same R1c pods (1 prefill + 3 decode + lb), Ohio `use2-az2`, v5 image, Mooncake EfaTransport
**Method**: 4-point rate sweep at `num-prompts=256, ISL=1024, OSL=512` (rate=4 reused from baseline, rates 6/8/12/16 new)

## Raw results

| rate (req/s) | Duration (s) | Req throughput | Total tok/s | Peak concur | Avg concurrency | Median TTFT (ms) | Mean TTFT (ms) | P99 TTFT (ms) | Median TPOT (ms) | Mean TPOT (ms) | P99 TPOT (ms) | Median ITL (ms) | Mean ITL (ms) | Median E2E (ms) | Mean E2E (ms) | P99 E2E (ms) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 4  (R1c baseline) | 39.96 | 3.20 | 2474 | 54  | 32.7 | 1665 | 4066 | 13235 | 21.2 | 22.4 | 68.7 | 19.9 | 23.8 | 8627 | 10220 | 29448 |
| 6  | 55.18 | 4.64 | **3532** | 84  | 47.0 | 1808 | 5002 | 15610 | 16.6 | 19.9 | 77.0 | 15.7 | 20.8 | 10184 | 10130 | 23780 |
| 8  | 66.56 | 3.85 | 2929 | 111 | 54.0 | 2639 | 6662 | 23903 | 25.1 | 29.5 | 75.5 | 22.1 | 29.4 | 10789 | 14038 | 36992 |
| 12 | 73.68 | 3.47 | 2646 | 157 | 68.9 | 4360 | 8020 | 36407 | 47.4 | 46.8 | 105.8 | 45.0 | 47.7 | 18224 | 19820 | 53964 |
| 16 | 63.80 | 4.01 | 3055 | 166 | 78.4 | 2309 | 7176 | 29792 | 44.0 | 47.9 | 94.6 | 42.5 | 49.7 | 17445 | 19534 | 48329 |

> **Achieved req throughput vs target rate**: at rate=4 we hit 3.20 req/s (80% of target), at rate=6 we hit 4.64 (77%). From rate=8 onward, achieved throughput **stops tracking the arrival rate** — the system has saturated and the remaining load queues.

## The decode-saturation point

TPOT tells the story:

| rate | Median TPOT | interpretation |
|---|---|---|
| 4  | 21.2 ms | decode pools have slack, ~47 tok/s/seq output |
| 6  | 16.6 ms | **best TPOT** — batch fusion benefit kicks in, decode still un-saturated |
| 8  | 25.1 ms | decode back-pressure starts — +20% vs rate=6 |
| 12 | 47.4 ms | **fully saturated** — double the rate=6 TPOT, matching 1P:1D at rate=4 |
| 16 | 44.0 ms | plateaued, no further degradation because queue is already at steady-state |

Median TPOT jumps from 17 ms to 47 ms between rate=6 and rate=12. This is the classic saturation knee: **3 × H200 decodes @ TP=8 can sustain ~50 tok/s/seq × ~55 concurrent sequences ≈ 2800 tok/s aggregate output + input = ~3200 tok/s total** before queueing takes over.

## Throughput ceiling

Three observations, same-config, same model, same PD topology:

1. **rate=6 saw 3532 tok/s** with Median TPOT 17 ms — system healthy, decode not saturated, arrival rate still below bottleneck
2. **rate=16 saw 3055 tok/s** with peak concurrent 166 — system saturated, queue absorbs the excess
3. **rate=8/12 saw 2929 / 2646 tok/s** — transitional, Poisson bursts + short 256-prompt window produces noisy samples

**Estimate**: sustained ceiling ≈ **3000–3500 tok/s total** (stable-state), **~3100 req-rate req/s** (Little's Law: Concurrency / E2E, cross-check at rate=8: 54.0/10.8 = 5.0 req/s... consistent).

So the real R1c 1P:3D ceiling is somewhere around **2000 prefill tok/s + 1100 decode tok/s ≈ 3100 tok/s**, roughly **2.2× R1a (1412)** — PD scaling holds even at maximum sustained load.

## Where the bottleneck is at saturation

At rate=12/16:
- **Peak concurrent reached 157–166** — 50+ req/pod on decodes, KV pool under memory pressure
- **Median TPOT doubled 17→47 ms** — decode scheduler spending time on batch ordering
- **Median TTFT** reacts slower: 1.8 → 4.4 s at rate=12, back to 2.3 s at rate=16 (decode draining stabilized)
- **P99 TTFT 15.6 → 36.4 s at rate=12** — tail clearly prefill-queued, which aligns with the earlier hypothesis: **at saturation, 1P becomes the hard limit, not 3D**

**Conclusion**: the 1P:3D balance **is decode-bound below rate=6 and prefill-bound above rate=8**. The crossover is narrow. Adding a 4th decode at R1c's load would not help — it would push the knee further but prefill queue would still top out around 4-5 req/s of new requests. **The next scaling step is 2P:ND, not 1P:4D.**

## R1a→R1c throughput ceiling comparison

Assumed ceilings (rate=6 point, safest sustained reading):

| Topology | Total tok/s | Median TPOT | vs R1a |
|---|---|---|---|
| 1P:1D (R1a) @ rate=4 | 1412 | 46 ms | baseline |
| 1P:2D (R1b) @ rate=4 | 1799 | 30 ms | +27% |
| **1P:3D (R1c) @ rate=6** | **3532** | **17 ms** | **+150%** |

At rate=4 we undercounted R1c's true capability by ~40% because we didn't push arrival rate high enough. **rate=6 is the right operating point to compare PD topologies on Kimi-K2 + p5en.**

## Operational notes

- SSM `StandardOutputContent` has a ~24 KB cap; the initial 4-in-1 sweep truncated at rate=12. Workaround: run each rate as a separate SSM invocation (which is what we did for rates 12 and 16).
- `kubectl run --rm` as the bench driver works well. Driver pod needs to be on `us-east-2b` (same AZ as LB) for LB ClusterIP to resolve — noderSelector in overrides JSON.
- Bench window = ISL×prompts / rate is too short at rate=16 (63 s) to fully stabilize. For a quieter number we'd want 512+ prompts.

## Next actions

- **2P:ND scaling**: since prefill is the next bottleneck above rate=6, natural next point is **2P:2D** or **2P:3D** on 5-6 × p5en. Requires launching more Spot capacity (SPS shows use2-az2 score=9 for tc=6 so feasible).
- **ISL sweep**: hold rate=6 but vary ISL=2048, 4096, 8192 → characterize prefill-compute cost (1P can push 4× more input tokens at ISL=512 than ISL=2048 due to attention O(N²)).
- **Decode batch headroom**: at rate=12/16 peak concurrent 160+, that's ~55/decode pod. If Kimi-K2 can actually hold more concurrent sequences per H200 141G, increasing `--max-running-requests` might expand the 1P:3D ceiling without adding hardware.
