# PD 1P1D — Mooncake EFA vs NIXL (LIBFABRIC) — Kimi-K2.5 INT4

**Stamp**: `20260501T002853Z` (run completed 2026-05-01 02:13 UTC)

## Test configuration
- **Hardware**: 2× p5en.48xlarge (H200 × 8, EFA v3 16-rail), same AZ usw2-az4
- **Cluster**: EKS `gpu-cluster-oregon` (1.35, `gpu-p5en-48xlarge-spot` nodegroup)
- **Image**: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake-nixl-uccl:2026.04.30-h200.6`
  - SGLang 0.5.10, Mooncake `634b7097`, NIXL `v1.0.1`, UCX `v1.18.0`, EFA installer `1.47.0`
- **Model**: Kimi-K2.5 compressed-tensors INT4 (~555 GiB, 64 safetensors shards)
- **Topology**: 1 prefill + 1 decode + 1 router, TP=8 symmetric, DP=1
- **Single variable**: `--disaggregation-transfer-backend {mooncake|nixl}` via `KV_BACKEND` env
- **NIXL plugin**: `SGLANG_DISAGGREGATION_NIXL_BACKEND=LIBFABRIC` (avoids UCX-over-EFA TCP fallback hang)
- **Scenarios (S1-S4)**:
  - S1: input 2048, output 512, concurrency 32, 200 prompts
  - S2: input 8192, output 1024, concurrency 64, 200 prompts
  - S3: input 32768, output 1024, concurrency 16, 100 prompts
  - S4: input 4096, output 512, concurrency 128, 200 prompts
  - All scenarios: 3 rounds each; warmup 10-20 prompts per round
- **Benchmark runner**: `sglang.bench_serving --dataset-name random --backend sglang`

## Headline result

| Metric (geo-mean across 4 scenarios) | NIXL/Mooncake ratio | Winner |
|---|---:|:---:|
| TTFT mean | **0.73×** | NIXL faster (−27%) |
| ITL mean | **0.82×** | NIXL faster (−18%) |
| E2E latency mean | **0.80×** | NIXL faster (−20%) |
| Throughput (req/s) | **1.24×** | NIXL higher (+24%) |

**NIXL with LIBFABRIC backend over EFA outperforms Mooncake EFA across all latency/throughput metrics**
on this Kimi-K2.5 INT4 1P1D disaggregated deployment. Largest gaps appear in S2/S4 (mid-size/high-concurrency
scenarios) where KV transfer is a clear bottleneck; S3 (huge 32K input KV) is essentially tied (both
backends saturated by the 32K prefill KV traffic).

## Scenario-by-scenario details below.

---

## S1

| Metric | Mooncake mean (95% CI) | NIXL mean (95% CI) | Δ% (NIXL/MC − 1) | Winner |
|---|---:|---:|---:|:---:|
| TTFT mean (ms) | 1067.21 (717.19–1741.73) | 367.32 (227.13–644.37) | -65.58% | NIXL |
| TTFT P50 (ms) | 1043.61 (567.47–1948.47) | 275.98 (212.01–397.14) | -73.56% | NIXL |
| TTFT P99 (ms) | 1942.11 (1484.36–2606.89) | 927.70 (362.41–2025.62) | -52.23% | NIXL |
| ITL mean (ms) | 14.51 (14.39–14.64) | 14.66 (14.62–14.70) | +1.04% | Mooncake |
| ITL P50 (ms) | 14.50 (13.58–15.11) | 14.90 (14.87–14.92) | +2.70% | Mooncake |
| ITL P99 (ms) | 27.63 (22.34–35.29) | 16.84 (16.44–17.57) | -39.05% | NIXL |
| E2E mean (ms) | 4641.06 (4313.47–5285.38) | 3978.68 (3829.50–4265.82) | -14.27% | NIXL |
| Input tok/s | 6917.63 (6178.58–7299.83) | 7821.61 (7324.55–8094.91) | +13.07% | NIXL |
| Output tok/s | 1571.72 (1403.81–1658.56) | 1777.11 (1664.18–1839.21) | +13.07% | NIXL |
| Total tok/s | — | — | — | — |
| Req/s | 6.36 (5.68–6.71) | 7.19 (6.73–7.44) | +13.07% | NIXL |
| Completed | 200.00 (200.00–200.00) | 200.00 (200.00–200.00) | +0.00% | — |

## S2

| Metric | Mooncake mean (95% CI) | NIXL mean (95% CI) | Δ% (NIXL/MC − 1) | Winner |
|---|---:|---:|---:|:---:|
| TTFT mean (ms) | 2260.81 (2054.26–2444.83) | 2141.19 (1925.66–2394.11) | -5.29% | NIXL |
| TTFT P50 (ms) | 749.10 (717.82–798.92) | 678.19 (595.99–747.83) | -9.47% | NIXL |
| TTFT P99 (ms) | 9387.02 (8436.13–10159.35) | 8822.68 (7853.65–9772.28) | -6.01% | NIXL |
| ITL mean (ms) | 104.90 (102.27–107.75) | 70.43 (69.23–71.83) | -32.86% | NIXL |
| ITL P50 (ms) | 116.41 (116.24–116.64) | 79.24 (79.10–79.43) | -31.93% | NIXL |
| ITL P99 (ms) | 136.70 (136.33–137.17) | 83.73 (83.52–84.03) | -38.75% | NIXL |
| E2E mean (ms) | 54147.70 (53031.28–55350.90) | 36977.82 (36638.75–37457.38) | -31.71% | NIXL |
| Input tok/s | 4478.74 (4381.28–4580.68) | 6460.82 (6384.38–6523.12) | +44.26% | NIXL |
| Output tok/s | 542.89 (531.08–555.25) | 783.15 (773.89–790.71) | +44.26% | NIXL |
| Total tok/s | — | — | — | — |
| Req/s | 1.10 (1.07–1.12) | 1.58 (1.56–1.60) | +44.26% | NIXL |
| Completed | 200.00 (200.00–200.00) | 200.00 (200.00–200.00) | +0.00% | — |

## S3

| Metric | Mooncake mean (95% CI) | NIXL mean (95% CI) | Δ% (NIXL/MC − 1) | Winner |
|---|---:|---:|---:|:---:|
| TTFT mean (ms) | 6822.61 (6799.82–6863.72) | 6857.89 (6803.14–6885.41) | +0.52% | ≈ |
| TTFT P50 (ms) | 6682.29 (6647.33–6734.97) | 6444.10 (6432.63–6467.01) | -3.56% | NIXL |
| TTFT P99 (ms) | 11911.71 (11881.91–11932.71) | 11938.35 (11902.76–11961.21) | +0.22% | ≈ |
| ITL mean (ms) | 10.96 (10.82–11.09) | 10.81 (10.74–10.88) | -1.42% | NIXL |
| ITL P50 (ms) | 11.36 (11.30–11.44) | 11.22 (11.17–11.28) | -1.22% | NIXL |
| ITL P99 (ms) | 14.99 (14.75–15.15) | 14.45 (14.10–14.86) | -3.60% | NIXL |
| E2E mean (ms) | 12560.31 (12529.54–12604.39) | 12514.26 (12500.77–12534.11) | -0.37% | ≈ |
| Input tok/s | 18740.06 (18664.60–18780.20) | 18810.38 (18774.48–18833.37) | +0.38% | ≈ |
| Output tok/s | 610.39 (607.94–611.70) | 612.68 (611.52–613.43) | +0.38% | ≈ |
| Total tok/s | — | — | — | — |
| Req/s | 1.16 (1.16–1.17) | 1.17 (1.17–1.17) | +0.38% | ≈ |
| Completed | 100.00 (100.00–100.00) | 100.00 (100.00–100.00) | +0.00% | — |

## S4

| Metric | Mooncake mean (95% CI) | NIXL mean (95% CI) | Δ% (NIXL/MC − 1) | Winner |
|---|---:|---:|---:|:---:|
| TTFT mean (ms) | 2281.37 (1262.28–3799.38) | 1949.04 (995.68–3638.68) | -14.57% | NIXL |
| TTFT P50 (ms) | 2409.99 (1496.74–3494.00) | 2189.53 (1410.09–3505.43) | -9.15% | NIXL |
| TTFT P99 (ms) | 4910.06 (2234.56–9535.19) | 4067.42 (1518.38–8692.87) | -17.16% | NIXL |
| ITL mean (ms) | 110.48 (107.60–112.89) | 75.00 (73.12–76.27) | -32.12% | NIXL |
| ITL P50 (ms) | 118.14 (117.77–118.47) | 79.50 (79.23–79.75) | -32.71% | NIXL |
| ITL P99 (ms) | 147.63 (141.35–158.91) | 92.56 (86.83–103.79) | -37.30% | NIXL |
| E2E mean (ms) | 29493.12 (29068.76–30303.11) | 20422.18 (19781.51–21649.08) | -30.76% | NIXL |
| Input tok/s | 7178.05 (7013.29–7308.12) | 10226.42 (9768.93–10505.80) | +42.47% | NIXL |
| Output tok/s | 844.42 (825.04–859.72) | 1203.03 (1149.21–1235.90) | +42.47% | NIXL |
| Total tok/s | — | — | — | — |
| Req/s | 3.41 (3.34–3.48) | 4.86 (4.65–5.00) | +42.47% | NIXL |
| Completed | 200.00 (200.00–200.00) | 200.00 (200.00–200.00) | +0.00% | — |

---
## Aggregate across scenarios

| Metric | Geo-mean ratio NIXL/MC | Interpretation |
|---|---:|---|
| TTFT mean (ms) | 0.7274 | NIXL faster |
| TTFT P50 (ms) | 0.6768 | NIXL faster |
| TTFT P99 (ms) | 0.7814 | NIXL faster |
| ITL mean (ms) | 0.8208 | NIXL faster |
| ITL P50 (ms) | 0.8256 | NIXL faster |
| ITL P99 (ms) | 0.6892 | NIXL faster |
| E2E mean (ms) | 0.7972 | NIXL faster |
| Input tok/s | 1.2358 | NIXL higher |
| Output tok/s | 1.2358 | NIXL higher |
| Total tok/s | — | — |
| Req/s | 1.2358 | NIXL higher |
| Completed | 1.0000 | — |

---
## Method
- Same image, same model, same SGLang, same service flags. Only `--disaggregation-transfer-backend` flips mooncake↔nixl.
- Topology: 1P+1D (TP=8 each), DP=1 symmetric, same AZ (usw2-az4).
- For each scenario, 3 rounds per backend, alternating A/B to cancel drift.
- Metrics from `sglang.bench_serving` (random dataset).
- Bootstrap 95% CI on the mean across 3 rounds (2000 resamples).