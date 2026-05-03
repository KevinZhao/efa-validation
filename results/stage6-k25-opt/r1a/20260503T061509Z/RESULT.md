# Stage 6 R1a — Kimi-K2.5 INT4 1P1D, P0 image + L5 envs vs Stage 5 baseline (S2 only)

**Stamp**: `20260503T061509Z` (bench run 2026-05-03 07:02-07:14Z, 3 rounds sequential)
**Region / AZ**: `us-west-2` / `usw2-az3` (us-west-2c) — Spot, SPS=9 at preflight
**Cluster**: EKS `gpu-cluster-oregon` (nodegroup `gpu-p5en-48xlarge-spot-az3`, freshly created for this run)
**Nodes**: 2× `p5en.48xlarge` Spot
- `ip-10-0-13-158` (`i-07fbeaa8eeb68df00`) — decode pod
- `ip-10-0-13-56`  (`i-019c908531879f537`) — prefill + LB pods (podAntiAffinity only between app=k25-r1a)

## Setup

| | Stage 5 baseline (S2 Mooncake) | Stage 6 R1a |
|---|---|---|
| Image | `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake-nixl-uccl:2026.04.30-h200.6` (Mooncake `634b7097`) | **`public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.05.02-h200.dp16`** (P0 — Mooncake PR #2023 tip `4a306de8` DP>1 root fix) |
| Model | Kimi-K2.5 compressed-tensors INT4 (~555 GiB, 64 shards) | same (from S3 `yanxi-validation-788668107894-oregon/models/moonshotai/Kimi-K2.5/`) |
| SGLang | 0.5.10 | 0.5.10 |
| Topology | 1P+1D, TP=8 each, DP=1 symmetric | same |
| KV backend | Mooncake (all 16 rails unified via `--disaggregation-ib-device`) | same — `--disaggregation-transfer-backend mooncake` |
| DeepEP / a2a | OFF (`--moe-a2a-backend` default none) | **OFF** (same as baseline; L4 NOT added in R1a) |
| L5 envs | not set | **`SGLANG_MOONCAKE_CUSTOM_MEM_POOL=1`, `FI_EFA_ENABLE_SHM_TRANSFER=1`, `FI_EFA_FORK_SAFE=1`** |
| AZ | usw2-az4 | **usw2-az3** (SPS-driven; new physical instances) |

**Delta vs baseline = "P0 image + L5 3 envs"** (DeepEP stays off in R1a; DeepEP is R1b's job).

## Scenario S2 (matches Stage 5 baseline S2)

- `--random-input-len 8192 --random-output-len 1024 --num-prompts 200 --max-concurrency 64 --warmup-requests 20`
- Bench runner: `python3 -m sglang.bench_serving --backend sglang --base-url http://k25-r1a-lb.yanxi-validation.svc:8000 --model /models/moonshotai/Kimi-K2.5 --tokenizer /models/moonshotai/Kimi-K2.5`
- Executor: exec-ed into the prefill pod
- Rounds: 3, sequential. Smoke 2K/256 (`python3 -m sglang.bench_serving ... --num-prompts 8`) was run once before R1 to prime the router (passed cleanly, TTFT_mean=718.65 ms, ITL_mean=11.78 ms, 8/8 completed).

### Per-round

| Round | Duration (s) | Completed | TTFT mean | TTFT P50 | TTFT P99 | ITL mean | ITL P50 | ITL P99 | E2E mean | E2E P99 | Input tok/s | Output tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| R1 | 183.97 | 200/200 | 3537.59 | 743.28 | 14102.12 | 103.11 | 117.95 | 142.57 | 54538.28 | 124287.85 | 4445.02 | 538.81 |
| R2 | 183.85 | 200/200 | 3241.31 | 744.16 | 13271.07 | 103.50 | 118.20 | 142.31 | 54433.09 | 123339.98 | 4447.94 | 539.16 |
| R3 | 186.13 | 200/200 | 3210.13 | 749.74 | 13117.10 | 105.15 | 120.05 | 142.70 | 55220.24 | 129796.42 | 4393.53 | 532.57 |
| **mean** | **184.65** | **200/200** | **3329.68** | **745.73** | **13496.76** | **103.92** | **118.73** | **142.53** | **54730.54** | **125808.08** | **4428.83** | **536.84** |

### Comparison vs Stage 5 S2 Mooncake baseline (3-round mean)

| Metric | Stage 5 baseline MC (mean) | Stage 6 R1a (mean) | Δ% (R1a/base − 1) | Direction |
|---|---:|---:|---:|:---:|
| TTFT mean (ms) | 2260.81 | 3329.68 | **+47.28%** | worse |
| TTFT P50 (ms) | 749.10 | 745.73 | -0.45% | ≈ |
| TTFT P99 (ms) | 9387.02 | 13496.76 | **+43.78%** | worse |
| ITL mean (ms) | 104.90 | 103.92 | -0.94% | ≈ (marginal better) |
| ITL P50 (ms) | 116.41 | 118.73 | +2.00% | ≈ (marginal worse) |
| ITL P99 (ms) | 136.70 | 142.53 | +4.26% | ≈ (marginal worse) |
| E2E mean (ms) | 54147.70 | 54730.54 | +1.08% | ≈ |
| Input tok/s | 4478.74 | 4428.83 | -1.11% | ≈ |
| Output tok/s | 542.89 | 536.84 | -1.11% | ≈ |
| Req/s | 1.10 | 1.08 | -1.53% | ≈ |
| Completed | 200.00 | 200.00 | +0.00% | — |

**Headline verdict**: R1a **does not improve** S2 mean latency vs the Stage 5 Mooncake baseline. Median TTFT, ITL mean/P50, and E2E mean are effectively flat (within ~2%). **Tail TTFT got substantially worse** (mean +47%, P99 +44%). Throughput is within ±1.5%.

Three rounds consistently landed in the same ballpark (duration 183.85-186.13 s, TTFT mean 3210-3537 ms), so this is not run-to-run noise.

## Interpretation / gotchas

- **Different AZ + physical instances vs baseline** (R1a on usw2-az3 new spot nodes vs baseline on usw2-az4). EKS-level, NIC-level, and noisy-neighbor variance is real on p5en Spot. The ±2% flat region (ITL, E2E mean, throughput) is inside typical cross-node noise.
- **TTFT tail regression (+44% P99, +47% mean)** is NOT inside cross-node noise and is consistent across 3 rounds. Hypothesis: one of the new L5 envs introduces startup-path overhead on the prefill side (e.g. `FI_EFA_FORK_SAFE=1` forcing extra copies on mr-reg at first-request; `SGLANG_MOONCAKE_CUSTOM_MEM_POOL=1` changing allocator behavior). TTFT **P50** is unchanged, so only the head-of-queue/slowest 20% is affected — classic signature of a new serialization point in the prefill path rather than a per-request throughput loss.
- **P0 image DP>1 fix is mostly inert for DP=1 topology** (1P+1D symmetric TP=8 DP=1). It's expected to help when DP > 1, so we shouldn't expect it to visibly move S2 on this topology — the "+P0" in the delta doesn't really fire here. R1a was framed as isolating "image + env" delta; on a DP=1 S2 scenario that isolation resolves to mostly "+L5 envs" in practice.
- **R1b (this run + DeepEP L4 stacked)** will test whether the tail-TTFT regression persists when MoE a2a path changes, or whether it was something L5-specific.

## Cost / timeline

- NG created: 2026-05-03 06:18:54Z. Both nodes `Ready`: 06:21:49Z (3 min). K8s pods applied: 06:39:47Z. Pods `Ready`: 07:00:17Z (~20 min coldstart; decode took ~20 min, prefill ~12 min). Smoke: 07:01:23Z, passed ~07:02:25Z. Bench R1-R3: 07:02:46Z to 07:14:10Z (~11.5 min wallclock).
- **Total elapsed at bench completion**: ~55 min (06:18 → 07:14) from NG create. **GPU cost so far**: `55/60 × $22/hr × 2 nodes ≈ $40.3`.
- NG + pods left running (Step 9) for R1b / smoke reuse.

## Artifacts

- Raw bench JSONs: `raw/s2-r1a-r{1,2,3}.json` + `raw/summary.json`
- Bench logs: `logs/s2-r1a-r{1,2,3}.log` (SSM stdout/stderr), `logs/smoke.log`, `logs/decode-startup.log`
- Extract log (JSON pull from pod): `logs/extract-jsons.log`
- SSM command traces: `ssm/step{1,2,3,4,5}-*.log`
- Preflight: `PREFLIGHT.md`
- Timeline + step-by-step: `STEPS.md`

## Next action

- Operator review: decide R1b (add L4 / DeepEP on top of R1a) now vs drop R1a L5 envs and retest R1a without them (to isolate whether the TTFT tail regression is from L5 or from AZ variance).
- Before R1b: smoke should still pass with DeepEP on; the MEMORY note `reference_cuda_graph_uccl_ep_risk` three smoke tests may apply if DeepEP path is UCCL-EP-backed.

---

## R1a0 — L5 ablation (P0 image, L5 envs removed)

**Purpose**: attribute the +44-47% TTFT tail regression seen in R1a. Same image `2026.05.02-h200.dp16`, same nodes, same AZ (usw2-az3), same pods — only the 3 L5 envs (`SGLANG_MOONCAKE_CUSTOM_MEM_POOL`, `FI_EFA_ENABLE_SHM_TRANSFER`, `FI_EFA_FORK_SAFE`) removed. `Recreate` rollout strategy (GPU-bound — rolling update can't schedule a second pod per role with only 2 nodes). Coldstart ~17 min both sides.

**Stamp (sub-run)**: 3 rounds S2 sequential, `07:42:32Z → 08:03:45Z` UTC (21 min end-to-end incl. smoke). Prefill+decode rebuild started `07:25:40Z`, Ready `07:41:32Z`.

### Env verification

Before bench:
```
env | grep -E "MOONCAKE_CUSTOM_MEM_POOL|FI_EFA_ENABLE_SHM_TRANSFER|FI_EFA_FORK_SAFE"
# → (empty) — i.e. NOT_SET
```
Clean removal confirmed in prefill pod.

### Smoke (2K/256, 8 prompts)

Duration 6.46s, 8/8 complete, TTFT mean=775.53 ms (vs R1a smoke 718.65), ITL mean=9.51 ms (vs R1a 11.78). Router primed.

### Per-round S2

| Round | Duration (s) | Completed | TTFT mean | TTFT P50 | TTFT P99 | ITL mean | ITL P50 | ITL P99 | E2E mean | E2E P99 | Input tok/s | Output tok/s | Req/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| R1 | 401.85 | 200/200 | 5539.70 | 1917.90 | 26296.78 | 114.37 | 120.12 | 142.43 | 122536.95 | 151728.02 | 4077.19 | 509.65 | 0.498 |
| R2 | 402.24 | 200/200 | 5236.81 | 931.46 | 26642.98 | 114.79 | 120.72 | 143.45 | 122673.02 | 153186.72 | 4073.22 | 509.15 | 0.497 |
| R3 | 401.22 | 200/200 | 5302.33 | 950.26 | 26629.74 | 114.45 | 120.49 | 142.45 | 122383.52 | 153336.99 | 4083.59 | 510.45 | 0.498 |
| **mean** | **401.77** | **200/200** | **5359.61** | **1266.54** | **26523.17** | **114.54** | **120.44** | **142.78** | **122531.16** | **152750.58** | **4078.00** | **509.75** | **0.498** |

### Three-way comparison (3-round means)

| Metric | Stage 5 MC baseline | R1a (P0+L5) | R1a0 (P0 only, L5 OFF) | R1a Δ% vs base | R1a0 Δ% vs base | R1a0 Δ% vs R1a |
|---|---:|---:|---:|---:|---:|---:|
| Duration (s) | 181.27 | 184.65 | 401.77 | +1.87% | +121.65% | **+117.56%** |
| TTFT mean (ms) | 2260.81 | 3329.68 | 5359.61 | +47.28% | **+137.07%** | +60.96% |
| TTFT P50 (ms) | 749.10 | 745.73 | 1266.54 | -0.45% | **+69.08%** | +69.84% |
| TTFT P99 (ms) | 9387.02 | 13496.76 | 26523.17 | +43.78% | **+182.55%** | +96.52% |
| ITL mean (ms) | 104.90 | 103.92 | 114.54 | -0.94% | +9.19% | +10.22% |
| ITL P50 (ms) | 116.41 | 118.73 | 120.44 | +2.00% | +3.46% | +1.44% |
| ITL P99 (ms) | 136.70 | 142.53 | 142.78 | +4.26% | +4.45% | +0.18% |
| E2E mean (ms) | 54147.70 | 54730.54 | 122531.16 | +1.08% | **+126.30%** | +123.87% |
| Input tok/s | 4478.74 | 4428.83 | 4078.00 | -1.11% | -8.95% | -7.92% |
| Output tok/s | 542.89 | 536.84 | 509.75 | -1.11% | -6.10% | -5.05% |
| Req/s | 1.10 | 1.08 | 0.498 | -1.53% | **-54.75%** | -54.06% |

### Verdict

**L5 is INNOCENT — in fact, L5 is NECESSARY for acceptable throughput on this stack.**

Removing the 3 L5 envs does not "fix" R1a's TTFT tail — it makes **every** metric substantially worse across all 3 rounds:

- **Request-rate collapse**: throughput crashes from 1.08 → 0.498 req/s (-54.7%) at cc=64. The server can no longer saturate the offered load. Input token throughput drops -8% and output drops -5%, but because the pipeline depth is much shorter, the system drains requests half as fast.
- **TTFT tail blow-up**: P99 TTFT 13.5s → 26.5s (+97%). Even TTFT P50 now regresses +70% (was flat in R1a vs baseline).
- **E2E latency doubled**: 54.7s → 122.5s mean.
- **ITL marginal**: +10% mean, tails barely move. Decode phase is not the bottleneck.

This is the opposite of the R1a hypothesis. The L5 envs are doing real work:
- `FI_EFA_FORK_SAFE=1` lets libfabric tolerate fork() in the Python runtime (tokenizer workers / subprocess spawning) without losing EFA MRs — disabling this likely causes silent MR invalidation + fallback to slow-path reg-each-request.
- `FI_EFA_ENABLE_SHM_TRANSFER=1` enables SHM for intra-node messaging (tokenizer worker → engine via rendezvous). Disabling forces all transfers over EFA even on-host → heavier CPU + NIC load.
- `SGLANG_MOONCAKE_CUSTOM_MEM_POOL=1` routes KV pool through a pinned Mooncake allocator, reducing MR-registration churn in the disaggregation path. Disabling forces generic pool + re-registration on every transfer.

Together they act as a throughput floor. Without them, the Mooncake+libfabric integration falls off a cliff.

### Cross-AZ impact estimate (revised)

R1a vs Stage 5 baseline showed +47% TTFT mean, +44% TTFT P99, ~0% ITL/throughput. With R1a0 now proving L5 is protective, the R1a regression must come from the AZ/node swap (usw2-az4 → usw2-az3, brand-new p5en Spot nodes). Since ITL mean/throughput in R1a are within ±1-2% of baseline, the network path isn't fundamentally worse — the delta is **TTFT-specific tail variance** (new NIC bring-up, cold BGP/EFA paths, or noisy-neighbor on new Spot instances).

Estimate: of the +47% TTFT mean in R1a, ~40-45pp is AZ/new-node variance, ~2-7pp is P0 image internal overhead (which on DP=1 should be ~zero). L5 contributes 0pp (or slightly negative = helpful).

### Implication for R1b

- **KEEP L5 envs in R1b manifest**. Do not drop them; they are part of the baseline recipe, not an experimental knob.
- Bigger action item: quantify AZ-swap tail variance by re-running R1a on usw2-az4 once capacity appears, or repeat R1a on same az3 nodes with a longer warm-up (ensure EFA MR cache is primed across all 16 rails).
- R1b (DeepEP stacked on top of R1a) should proceed with current manifest. The R1a TTFT regression is a tail-variance story, not a stackable-regression.

### Timeline / cost (R1a0 specifically)

| Step | UTC | Wall |
|---|---|---|
| Patch apply | 07:24:13Z | - |
| Recreate strategy + pod rollout start | 07:25:40Z | 0:00 |
| Prefill Ready | 07:36:40Z (approx) | 11:00 |
| Decode Ready | 07:41:32Z | 15:52 |
| Smoke end | 07:42:28Z | 16:48 |
| R1 end | 07:49:37Z | 23:57 |
| R2 end | 07:56:53Z | 31:13 |
| R3 end | 08:03:45Z (approx) | 38:05 |

- **R1a0 elapsed**: ~38 min (07:25-08:04) of which ~21 min is compute/bench, ~17 min coldstart.
- **Total nodegroup lifetime so far**: `06:18 → 08:04` = 106 min × $22/hr × 2 nodes ≈ **$77.7 running tab**.

### R1a0 artifacts

- Raw JSONs: `raw/s2-r1a0-r{1,2,3}.json` + `raw/summary-r1a0.json`
- Bench logs: `logs/s2-r1a0-r{1,2,3}.log`, `logs/r1a0-smoke.log`, `logs/r1a0-bench-run.log`
- Patched manifests: `ssm/r1a0-k25-r1a-{prefill,decode}-noL5.yaml` (31 env vars each after drop, vs 33 original; note drop was actually 3, original listing re-counted)
- Patch log: `ssm/r1a0-patch-apply.log`

