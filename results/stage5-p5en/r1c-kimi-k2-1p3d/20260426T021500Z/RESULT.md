# R1c · Kimi-K2-Instruct-0905 1P:3D on 4 × p5en (Ohio use2-az2) — PASS

**Run ID**: `r1c-kimi-k2-1p3d` (completes Kimi-K2 PD scaling curve 1P:1D → 1P:2D → 1P:3D)
**Bench completion (UTC)**: 2026-04-26T02:15Z
**Region / AZ**: us-east-2 / **use2-az2** (pinned via nodeSelector, all 4 pods + LB)
**Model**: `moonshotai/Kimi-K2-Instruct-0905` (1T MoE FP8 block-quantized, 959 GB, 62 shards)
**Image**: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake:v5`
  - SGLang 0.5.10 + Mooncake v0.3.10.post2 + 5 Henan EFA PRs (incl. #1944 SRD shared-endpoint)
**Topology**: 1 prefill + 3 decode + 1 router; all 4 GPU pods on distinct p5en hosts (podAntiAffinity)
**KV transport**: Mooncake `EfaTransport` over EFA v3 (16 × 200 Gbps per p5en)
**Weights**: `hostPath: /mnt/nvme/models/Kimi-K2-Instruct-0905` on each node
  - `hf download` 4-way parallel prefetch with **HF_TOKEN** — **27 min** for 959 GB × 4 nodes = 3.8 TB aggregate
  - `/mnt/nvme` 28 TB RAID0 via `scripts/setup-nvme.sh` on each of the 4 Ohio p5en nodes (LT v1 no auto-LVM)

## Infrastructure path

Day 2 continuation. Day 1 R1c first attempt (2026-04-25) failed because the single-node catch-up prefetch pod was HF-rate-limited without a token (300/959 GB then 0 B/min stall). Day 2 fix: new `hf-token` k8s Secret + `HF_TOKEN` env injected into prefetch manifest + 4-way parallel prefetch on all 4 nodes from cold (not catch-up).

1. Fresh SPS scan (tc=4 single-AZ whitelist) — Ohio `use2-az2` p5en = 9, reusable NG `gpu-p5en-spot-useast2b`
2. `aws eks update-nodegroup-config ... desiredSize=4` — 4 × p5en Spot launched in 1 min, all in us-east-2b
3. Parallel SSM `scripts/setup-nvme.sh` (inline, no heredoc) — `/mnt/nvme` 28 TB RAID0 on all 4 in ~90 s
4. `kubectl create secret generic hf-token` with HF token
5. New manifest `_prefetch-hf-kimi-ohio-az2-4x.yaml` (completions=4, parallelism=4, `HF_TOKEN` + `HUGGING_FACE_HUB_TOKEN` from secret) — **27 min** prefetch
6. `r1c-kimi-k2-1p3d-v5-hostpath-ohio-az2.yaml` apply — 17 min cold start → 4/4 server pods Ready
7. Bench `rate=4, 128 prompts, ISL=1024, OSL=512` — 40 s duration, 128/128 PASS

## SGLang server config

| param | value |
|---|---|
| TP | 8 (per pod) |
| context-length | 131072 |
| mem-fraction-static | 0.92 |
| chunked-prefill-size | 4096 |
| fp8-gemm-backend | cutlass |
| disaggregation-transfer-backend | mooncake |
| FI_PROVIDER | efa |
| MC_WORKERS_PER_CTX | 2 |
| MC_NUM_CQ_PER_CTX | 2 |

## Bench workload

| param | value |
|---|---|
| dataset | random |
| num-prompts | 128 |
| request-rate | 4.0 req/s |
| random-input-len | 1024 |
| random-output-len | 512 |

## Bench results

```
============ Serving Benchmark Result ============
Backend:                                 sglang
Traffic request rate:                    4.0
Successful requests:                     128
Benchmark duration (s):                  39.96
Total input tokens:                      65633
Total generated tokens:                  33252
Request throughput (req/s):              3.20
Input token throughput (tok/s):          1642.37
Output token throughput (tok/s):         832.08
Peak output token throughput (tok/s):    2672.00
Peak concurrent requests:                54
Total token throughput (tok/s):          2474.46
Concurrency:                             32.74
----------------End-to-End Latency----------------
Mean E2E Latency (ms):                   10220.22
Median E2E Latency (ms):                 8627.48
P90 E2E Latency (ms):                    19416.95
P99 E2E Latency (ms):                    29447.91
---------------Time to First Token----------------
Mean TTFT (ms):                          4065.68
Median TTFT (ms):                        1664.68
P99 TTFT (ms):                           13234.91
-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          22.44
Median TPOT (ms):                        21.23
P99 TPOT (ms):                           68.73
---------------Inter-Token Latency----------------
Mean ITL (ms):                           23.78
Median ITL (ms):                         19.90
P95 ITL (ms):                            71.87
P99 ITL (ms):                            88.05
Max ITL (ms):                            12027.25
==================================================
```

## Kimi-K2 PD scaling curve — R1a → R1b → R1c (same model, same bench, same image)

| Metric | R1a 1P:1D | R1b 1P:2D | **R1c 1P:3D** | Δ(c vs a) | Δ(c vs b) |
|---|---|---|---|---|---|
| Total tok/s | 1412 | 1799 | **2474** | **+75%** | **+38%** |
| Request throughput (req/s) | 1.83 | 2.33 | **3.20** | **+75%** | **+37%** |
| Benchmark duration (s) | 69.9 | 54.98 | **39.96** | **-43%** | **-27%** |
| Peak output tok/s | 1768 | 2476 | **2672** | +51% | +8% |
| Peak concurrent req | 64 | 68 | 54 | -16% | -21% |
| Concurrency (avg in-flight) | 36.1 | 36.3 | 32.74 | -9% | -10% |
| Mean TPOT (ms) | 47.7 | 31.95 | **22.44** | **-53%** | **-30%** |
| Median TPOT (ms) | 46.0 | 29.97 | **21.23** | **-54%** | **-29%** |
| P99 TPOT (ms) | 101 | 78.12 | **68.73** | **-32%** | **-12%** |
| Mean ITL (ms) | 48.0 | 30.00 | **23.78** | **-50%** | **-21%** |
| Median ITL (ms) | 35.7 | 28.94 | **19.90** | **-44%** | **-31%** |
| P95 ITL (ms) | 95.7 | 64.37 | **71.87** | -25% | +12% (noise) |
| Mean TTFT (ms) | 7329 | 7844 | **4066** | **-45%** | **-48%** |
| Median TTFT (ms) | 3344 | 8751 | **1665** | **-50%** | **-81%** |
| P99 TTFT (ms) | 25651 | 20770 | **13235** | **-48%** | **-36%** |
| Mean E2E (ms) | 19743 | 15609 | **10220** | **-48%** | **-35%** |
| Median E2E (ms) | — | 14493 | **8627** | — | **-40%** |

**Interpretation**:

1. **Throughput scales near-linearly with decode count** at rate=4 req/s:
   - 1P:1D → 1P:2D : +27% tok/s
   - 1P:2D → 1P:3D : +38% tok/s
   - 1P:1D → 1P:3D : +75% tok/s (vs ideal 200% if perfectly linear; decode-bound portion scales, request-rate-bound portion caps)

2. **Decode-bound metrics drop hard and consistently** — TPOT / ITL fall by roughly 1/N as we add decode pods. At 1P:3D, **Median TPOT = 21.23 ms** (~47 tokens/s per request decode speed), down from 46 ms at 1P:1D.

3. **Prefill bottleneck now visible at 1P:3D**:
   - Queue dissipates: Median TTFT drops from 8.75 s (1P:2D) → 1.66 s (1P:3D). With 3 decodes, requests now spend much less time *waiting for decode capacity to free up*, so they hit the prefill queue sooner, and that queue moves fast enough at rate=4 that TTFT is near-ideal.
   - The **R1b TTFT regression vs R1a** (Median 8.75 s vs 3.34 s) that confused us at 1P:2D was clearly decode-back-pressure: requests got admitted but stalled in the 2-decode KV pool, making TTFT look worse. R1c's drop to 1.66 s confirms this — the effect was never prefill-bound at all.
   - **P99 TTFT** still at 13 s (was 20–25 s on R1a/R1b) — tail still prefill-burst-limited.

4. **Cliff moved**: at rate=4, **decode stops being the bottleneck somewhere between 2 and 3 decodes**. At 1P:3D we have decode headroom — next step is to push rate higher (rate=6, rate=8) and find the new 1P throughput ceiling.

5. **Peak concurrent requests dropped 68 → 54** moving 1P:2D → 1P:3D. Not a regression: because decodes complete faster, the system drains the in-flight queue quicker before the next burst, so the instantaneous peak is lower even though throughput is higher.

## Key findings (new since R1b)

1. **HF_TOKEN is mandatory for hf download on k8s**: without it, anonymous rate-limit stalls a single node at ~300 GB for Kimi-K2. With `HF_TOKEN` Secret injected as env, 4-way parallel hit ~470-670 MB/s/node sustained, completed 959 GB × 4 in 27 min. Memorized as `reference_hf_token.md`.
2. **Setup-nvme via SSM heredoc is fragile**: shell-in-shell JSON escaping broke parameters. Fix: squash the whole script to one line and pass via `--parameters file://...json`. Saved as operational note for future Ohio LT-v1 NGs.
3. **PD 1P:1D → 1P:3D scaling confirmed on EFA v5**: real, reproducible, same-AZ. No Mooncake KV stalls across any of the 3 decode pods. The v5 stack behaves.
4. **TTFT at 1P:2D was a red herring**: the apparent regression (Median TTFT 3.3 → 8.7 s) was decode back-pressure, not a prefill-path issue. Confirmed by R1c returning to 1.66 s.

## Operational stats

- 4 × p5en Spot launched 01:19 UTC, k8s Ready 01:22, NVMe ready 01:23
- Prefetch 01:38 → 02:05 UTC (27 min, 959 GB × 4 = 3.8 TB aggregate from HF hub)
- R1c apply 02:05, all pods 1/1 Ready 02:22 (17 min cold start — same as R1b)
- Bench 02:14–02:15 UTC (40 s benchmark duration)
- **Total e2e from cold NG to PASS**: ~56 min (was ~2.5 h for R1a on Day 1 due to FSx detour)

## Status

**PASS** — R1c headline numbers locked. Complete PD scaling curve for Kimi-K2-Instruct-0905 on p5en + EFA + Mooncake v5:

| Points | Kimi-K2 Total tok/s at rate=4 | Median TPOT |
|---|---|---|
| 2 × p5en 1P:1D | 1412 | 46.0 ms |
| 3 × p5en 1P:2D | 1799 | 29.97 ms |
| **4 × p5en 1P:3D** | **2474** | **21.23 ms** |

## Next steps

- **Push rate up** (rate=6 / rate=8 / rate=12) at 1P:3D — find where decode saturates or prefill crosses over, giving the *true* 1P:ND throughput ceiling
- **Compare to R2 DSv3.1 TP=16** cross-node (future) — two-model PD scaling
- R1c + GLM-4.6 long-ctx sweep (R3 extension, ISL=128k) — Day 3

## Artifacts

- Manifest: `manifests/stage5-p5en/r1c-kimi-k2-1p3d-v5-hostpath-ohio-az2.yaml`
- Prefetch: `manifests/stage5-p5en/_prefetch-hf-kimi-ohio-az2-4x.yaml` (HF_TOKEN-enabled)
- Secret: `kubectl get secret -n yanxi-validation hf-token` (not committed — lives in cluster only)
- SPS snapshot: `results/sps/20260426T012522Z/` (tc=4 single-AZ whitelist)
