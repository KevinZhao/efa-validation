# R2 · Kimi-K2 2P:2D on 4 × p5en (Ohio use2-az2) — PASS but inferior to 1P:3D

**Run ID**: `r2-kimi-k2-2p2d` — tests the hypothesis "1P is the next bottleneck above rate=6"
**Bench completion (UTC)**: 2026-04-26T03:35Z
**Region / AZ**: us-east-2 / use2-az2 (all pods pinned)
**Model**: `moonshotai/Kimi-K2-Instruct-0905`
**Image**: `sglang-mooncake:v5`
**Topology**: **2 prefill + 2 decode + 1 router**; 4 × p5en (same 4 nodes as R1c, reused prefetched weights)
**Method**: re-deployed from R1c teardown, ran rate=4 and rate=6 benches, compared to R1c 1P:3D

## Hypothesis being tested

From R1c rate-sweep conclusion: "at saturation rate=12+, P99 TTFT jumps to 36 s — 1P becomes the next bottleneck, next scaling step is 2P:ND not 1P:4D". R2 tests this by using the **same 4 × p5en budget** but rebalancing as **2P:2D** (instead of 1P:3D).

## Bench results

| Run | Rate | Num prompts | Duration (s) | Total tok/s | Req throughput | Peak concur | Median TTFT | Median TPOT | Median ITL |
|---|---|---|---|---|---|---|---|---|---|
| **R1c 1P:3D** | 4 | 128 | 39.96 | **2474** | 3.20 | 54 | 1665 | 21.2 | 19.9 |
| **R1c 1P:3D** | 6 | 256 | 55.18 | **3532** | 4.64 | 84 | 1808 | 16.6 | 15.7 |
| R1b 1P:2D | 4 | 128 | 54.98 | 1799 | 2.33 | 68 | 8751 | 30.0 | 28.9 |
| **R2 2P:2D** | 4 | 128 | 52.03 | **1900** | 2.46 | 56 | 1041 | 17.0 | 18.5 |
| **R2 2P:2D** | 6 | 256 | 101.62 | **1918** | 2.52 | 155 | 12738 | 39.5 | 35.2 |

**Verdict**: **R2 2P:2D < R1c 1P:3D by -46% throughput, -44% TPOT, worse TTFT tail**. At rate=6 R2 only delivers ~1918 tok/s vs R1c's 3532 tok/s. The hypothesis is **falsified**: for Kimi-K2 on p5en, **decode is still the binding constraint** all the way up, and even at rate=6+ the "prefill bottleneck" we thought we saw in R1c rate=12 was actually decode scheduler queueing, not prefill compute.

## Why 2P:2D underperforms

Inspecting prefill pods during the rate=6 bench showed:

```
prefill-0 token usage: 0.01 – 0.20  (always low)
prefill-1 token usage: 0.01 – 0.20  (always low)
#running-req: 0, #queue-req: 0 almost always
prefill input throughput spikes to 10k-100k tok/s (instantaneous),
sustained occupancy <5%
```

Both prefill pods sit idle most of the time. Meanwhile:
- Decode peak concurrent = 155 (77 req/pod on only 2 decode pods)
- Median TPOT jumps from 17 ms (R1c at rate=6) to 39.5 ms (R2 at rate=6) — **same as R1c at rate=12 saturation level**

Exactly the saturation signature: 2 decode pods cannot drain what 1 prefill can emit, let alone what 2 prefills can emit. **Prefill is ~1/6 of the compute cost of decode for Kimi-K2 at this ISL/OSL ratio** (roughly ISL=1024 in one chunked-prefill pass ≈ 0.45 s prefill compute; OSL=512 × ~20 ms/token = 10 s decode compute, a 22× asymmetry).

## Reinterpretation of R1c rate=12 result

The R1c rate=12 "prefill bottleneck" (P99 TTFT 36 s) was misdiagnosed. The real mechanism:

1. At rate=12, 256 requests flood into 60-70 s window
2. 3 decode pods saturate at ~55 req/pod
3. sglang scheduler only admits new prefill batches when decode KV pool has headroom
4. Prefill sits idle waiting for decode to drain → TTFT grows
5. Metric shows "TTFT-driven", looks prefill-bound, but **prefill compute is 95% idle**

Lesson: **TTFT tail at saturation reflects the binding queue, not the dimension you added hardware to**.

## Conclusion and correction to prior roadmap

For Kimi-K2 (1T MoE FP8, 62 shards) on p5en at ISL=1024 OSL=512:

- **Decode-bound always**. The compute asymmetry means scaling decode count is the only useful lever until you run out of decode-pool-per-pod headroom (which we haven't — H200 141G isn't even half full at rate=6 on R1c).
- **1P:ND is the correct topology family**. 1P:4D, 1P:5D, 1P:6D would all scale further.
- **2P:ND is wasted hardware** until (a) ISL ≫ OSL (prefill-heavy customers), or (b) we find a scheduler config where prefill can be queue-starved independently of decode.
- **Revise the Day 2+ plan**: drop 2P:xD from Kimi-K2 investigation. Instead: 1P:4D or 1P:5D if SPS permits 5-6 × p5en same-AZ.

## Operational notes

- 4 × p5en use2-az2 reused from R1c — no new nodes needed
- Prefetched weights on `/mnt/nvme/models/` still intact (no Spot reclaim)
- Cold start 12 min (same as R1c — dominated by shard load from NVMe)
- `podAntiAffinity` kept 4 server pods on 4 distinct hosts — no co-location
- `sglang_router --pd-disaggregation` with 2 prefill URLs + 2 decode URLs worked cleanly — no LB misconfig

## Artifacts

- Manifest: `manifests/stage5-p5en/r2-kimi-k2-2p2d-v5-hostpath-ohio-az2.yaml`
- Cross-ref R1c: `results/stage5-p5en/r1c-kimi-k2-1p3d/20260426T024500Z-rate-sweep/RATE_SWEEP.md`
- Cross-ref ISL sweep (supporting decode-bound reading): `results/stage5-p5en/r1c-kimi-k2-1p3d/20260426T031000Z-isl-sweep/ISL_SWEEP.md`
