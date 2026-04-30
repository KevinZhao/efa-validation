# PD 1P1D Mooncake EFA vs NIXL — Kimi-K2.5 INT4 A/B Result

Stamp: `20260430T174252Z`  (run completed 2026-04-30 18:46 UTC)

## Test configuration
- **Hardware**: 2× p5en.48xlarge (H200 × 8, EFA v3 16-rail), same AZ usw2-az4
- **Cluster**: gpu-cluster-oregon (EKS 1.35, `gpu-p5en-48xlarge-spot` nodegroup)
- **Image**: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake-nixl-uccl:2026.04.30-h200.6` (digest `sha256:532e38c8...`)
- **Model**: Kimi-K2.5 compressed-tensors INT4 (~555 GiB, 64 safetensors shards)
- **Topology**: 1 prefill + 1 decode + 1 router, TP=8 symmetric, DP=1 symmetric
- **Single variable**: `--disaggregation-transfer-backend {mooncake|nixl}` via `KV_BACKEND` env
- **Scenarios** (S1-S4): 2K/512/32c, 8K/1K/64c, 32K/1K/16c, 4K/512/128c — 3 rounds each

## Result summary

- **Mooncake EFA: 12/12 benches + smoke all passed.** Sample data below.
- **NIXL: 0/12 benches passed — see Failure Analysis.**

---
## Mooncake EFA per-scenario (3 rounds, bootstrap 95% CI on mean)

### S1

| Metric | Mean (95% CI) | rounds |
|---|---:|:---:|
| TTFT mean (ms) | 1,557.87  (1,409.73–1,729.42) | 3 |
| TTFT P50 (ms) | 1,704.16  (1,587.28–1,788.33) | 3 |
| TTFT P99 (ms) | 2,051.54  (1,973.69–2,119.98) | 3 |
| ITL mean (ms) | 14.34  (14.26–14.48) | 3 |
| ITL P50 (ms) | 14.65  (14.32–14.91) | 3 |
| ITL P99 (ms) | 23.25  (21.27–26.82) | 3 |
| E2E mean (ms) | 5,090.48  (4,977.45–5,240.75) | 3 |
| E2E P99 (ms) | 9,700.41  (9,137.50–10,664.89) | 3 |
| Input tok/s | 6,357.96  (6,166.19–6,513.92) | 3 |
| Output tok/s | 1,444.56  (1,400.99–1,480.00) | 3 |
| Total tok/s | 7,802.53  (7,567.18–7,993.91) | 3 |
| Req/s | 5.84  (5.67–5.98) | 3 |
| Completed | 200.00 | 3 |
| Duration (s) | 34.26 | 3 |

### S2

| Metric | Mean (95% CI) | rounds |
|---|---:|:---:|
| TTFT mean (ms) | 2,324.86  (2,081.38–2,500.30) | 3 |
| TTFT P50 (ms) | 771.44  (717.81–807.80) | 3 |
| TTFT P99 (ms) | 9,562.23  (7,986.35–10,518.34) | 3 |
| ITL mean (ms) | 103.28  (100.82–106.68) | 3 |
| ITL P50 (ms) | 114.52  (113.78–115.31) | 3 |
| ITL P99 (ms) | 138.49  (137.70–138.97) | 3 |
| E2E mean (ms) | 53,410.46  (52,368.46–54,849.70) | 3 |
| E2E P99 (ms) | 119,674.55  (118,395.21–121,035.02) | 3 |
| Input tok/s | 4,546.91  (4,432.70–4,635.00) | 3 |
| Output tok/s | 551.16  (537.31–561.83) | 3 |
| Total tok/s | 5,098.07  (4,970.02–5,196.84) | 3 |
| Req/s | 1.11  (1.08–1.13) | 3 |
| Completed | 200.00 | 3 |
| Duration (s) | 179.91 | 3 |

### S3

| Metric | Mean (95% CI) | rounds |
|---|---:|:---:|
| TTFT mean (ms) | 6,875.92  (6,788.46–7,038.40) | 3 |
| TTFT P50 (ms) | 6,586.51  (6,551.85–6,604.83) | 3 |
| TTFT P99 (ms) | 12,282.11  (11,969.43–12,633.93) | 3 |
| ITL mean (ms) | 11.03  (10.81–11.15) | 3 |
| ITL P50 (ms) | 11.38  (11.20–11.50) | 3 |
| ITL P99 (ms) | 15.37  (15.14–15.50) | 3 |
| E2E mean (ms) | 12,650.18  (12,618.89–12,694.60) | 3 |
| E2E P99 (ms) | 21,350.40  (21,155.58–21,578.09) | 3 |
| Input tok/s | 18,619.68  (18,567.23–18,647.40) | 3 |
| Output tok/s | 606.47  (604.76–607.38) | 3 |
| Total tok/s | 19,226.15  (19,171.99–19,254.78) | 3 |
| Req/s | 1.16  (1.15–1.16) | 3 |
| Completed | 100.00 | 3 |
| Duration (s) | 86.47 | 3 |

### S4

| Metric | Mean (95% CI) | rounds |
|---|---:|:---:|
| TTFT mean (ms) | 2,238.15  (1,336.76–3,836.40) | 3 |
| TTFT P50 (ms) | 2,275.54  (1,461.47–3,555.62) | 3 |
| TTFT P99 (ms) | 4,696.00  (2,315.10–9,199.77) | 3 |
| ITL mean (ms) | 112.28  (108.72–114.73) | 3 |
| ITL P50 (ms) | 116.95  (116.64–117.14) | 3 |
| ITL P99 (ms) | 149.01  (139.71–155.80) | 3 |
| E2E mean (ms) | 29,892.63  (29,466.97–30,614.36) | 3 |
| E2E P99 (ms) | 57,162.35  (56,600.90–57,718.69) | 3 |
| Input tok/s | 7,113.19  (7,057.71–7,171.57) | 3 |
| Output tok/s | 836.79  (830.27–843.66) | 3 |
| Total tok/s | 7,949.98  (7,887.98–8,015.23) | 3 |
| Req/s | 3.38  (3.36–3.41) | 3 |
| Completed | 200.00 | 3 |
| Duration (s) | 59.11 | 3 |

---
## Failure analysis — NIXL backend

### Symptom
All 12 NIXL benches + smoke failed with router error:

```
Failed to select PD pair error=No prefill workers available.
Please check if prefill servers are configured and healthy.
```
Router retried `detect_connection_mode` 80 times over ~10 minutes; every attempt reported:

```
Step failed: detect_connection_mode -
  HTTP: Health check failed: error sending request for url
    (http://c1p1d-prefill.yanxi-validation.svc:30000/health)
  gRPC: gRPC failed (tried SGLang and vLLM): gRPC health check failed
```

### Root cause (from `logs/nixl-prefill-first-apply.log`)

NIXL library initialized successfully on all 8 TP ranks, but chose **UCX** backend instead
of **LIBFABRIC** (EFA):

```
2026-04-30 18:32:58 NIXL INFO  _api.py:361 Backend UCX was instantiated
[TP0] NIXL KVManager initialized with backend: UCX
```

Shortly after, the detokenizer subprocess stopped responding to heartbeat while UCX was
probing the network transport; sglang's watchdog reported:

```
ERROR: Health check failed. Server couldn't get a response from detokenizer for last 20 seconds.
  tic start time: 18:35:01  last_heartbeat time: 18:33:12
```

### Diagnosis
The built image (`h200.6`) compiled NIXL v1.0.1 with **both** UCX and LIBFABRIC plugins
(Dockerfile `-Denable_plugins=UCX,LIBFABRIC`). At runtime NIXL auto-selected UCX because it
is listed first in the agent's backend probe order. On an EFA-only instance (p5en has no
IB/RoCE NICs), UCX falls back to TCP over the VPC ENI — this path is functional for local
connectivity but hung during pre-batch warmup when NIXL tried to establish the cross-node
KV channel, taking the detokenizer subprocess with it.

### Fix (for a future run)
Force NIXL to use the LIBFABRIC backend via environment variable before the next try:

```
# Option A — force NIXL plugin selection (preferred)
NIXL_PLUGIN_SELECTION=LIBFABRIC

# Option B — disable UCX so only LIBFABRIC is available
UCX_TLS=^tcp  (or) NIXL_DISABLE_UCX=1
```

Add one of these to the prefill/decode env in the manifest and rerun. An alternative
long-term fix is to rebuild the image with `-Denable_plugins=LIBFABRIC` only.

---
## Data & artifacts

- **Raw bench JSON**: `raw/{smoke,s1,s2,s3,s4}-mooncake-r*.json` (13 files)
- **Per-bench logs**: `logs/*.log`
- **STEPS.md**: full orchestration timeline (apply → ready → bench → teardown)
- **NIXL debug log**: `logs/nixl-prefill-first-apply.log` (1339 lines)
- **Manifest**: `manifests/stage5-p5en/pd-1p1d-mc-vs-nixl-k25-int4-usw2.yaml`
- **Orchestrator**: `scripts/stage5-pd-1p1d-mc-vs-nixl/orchestrate_ab.sh`

## Infrastructure released
- EKS nodegroup `gpu-p5en-48xlarge-spot` scaled desired=0 (2× p5en terminating)
- Oregon prefetcher `i-0c7035787c0f3cc6b` terminated (self-shutdown after sentinel)
- Ohio prefetcher `i-046dc8a0a836ea9b5` terminated (self-shutdown)
