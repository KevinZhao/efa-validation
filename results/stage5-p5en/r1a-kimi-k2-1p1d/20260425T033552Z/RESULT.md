# R1a · Kimi-K2-Instruct-0905 1P:1D · Baseline Result

**Run ID**: `r1a-kimi-k2-1p1d`
**Start (UTC)**: 2026-04-25T03:35:52Z (session)
**Bench completion (UTC)**: 2026-04-25T08:44Z
**Region / AZ**: us-east-2 / use2-az1 (Ohio)
**Model**: moonshotai/Kimi-K2-Instruct-0905 (1T MoE, FP8, 959 GB, 62 shards)
**Image**: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake:v5`
  - SGLang 0.5.10 + Mooncake v0.3.10.post2 + Henan EFA PRs (incl. #1944)
  - launcher patches `rdma` → `efa` for Mooncake EfaTransport
**Topology**: 1 prefill (node-A 10.1.11.6) + 1 decode (node-B 10.1.11.89) + 1 router
**KV transport**: Mooncake `EfaTransport` over EFA v3 16×200 Gbps (SRD shared endpoint)
**Weights**: `hostPath: /mnt/nvme/models/Kimi-K2-Instruct-0905` (local NVMe RAID0, 28 TB xfs per node)
  - pre-seeded via `hf download --max-workers 16` with `HF_HUB_ENABLE_HF_TRANSFER=1`
  - prefetch manifest: `manifests/stage5-p5en/_prefetch-hf-to-nvme.yaml`
  - prefetch wall-clock: **15 min for both nodes in parallel** (~1 GB/s per node)

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
Benchmark duration (s):                  70.04
Total input tokens:                      65633
Total input text tokens:                 65633
Total generated tokens:                  33252
Total generated tokens (retokenized):    30192
Request throughput (req/s):              1.83
Input token throughput (tok/s):          937.08
Output token throughput (tok/s):         474.76
Peak output token throughput (tok/s):    1085.00
Peak concurrent requests:                64
Total token throughput (tok/s):          1411.84
Concurrency:                             36.08
----------------End-to-End Latency----------------
Mean E2E Latency (ms):                   19742.55
Median E2E Latency (ms):                 17081.22
P90 E2E Latency (ms):                    38916.30
P99 E2E Latency (ms):                    43060.89
---------------Time to First Token----------------
Mean TTFT (ms):                          7328.81
Median TTFT (ms):                        3344.47
P99 TTFT (ms):                           25651.67
-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          47.70
Median TPOT (ms):                        45.97
P99 TPOT (ms):                           101.07
---------------Inter-Token Latency----------------
Mean ITL (ms):                           47.97
Median ITL (ms):                         35.72
P95 ITL (ms):                            95.74
P99 ITL (ms):                            115.50
Max ITL (ms):                            418.09
==================================================
```

## Key takeaways

1. **PASS** — 128/128 successful requests, clean PD-disaggregation via Mooncake EfaTransport with PR #1944 SRD shared-endpoint active.
2. **Mooncake v5 works for Kimi-K2** when weights are on local NVMe. The 2h15m "stall" observed in the earlier FSx-PVC attempt was **not** a PR #1944 regression; it was cross-AZ FSx Lustre OST contention under the 62-shard × 8-TP concurrent mmap pattern. v2 and v5 share byte-identical worker loop source; failure mode differed only by FSx vs NVMe storage.
3. **TPOT Median 46 ms / P99 101 ms** at 1.83 req/s is in line with Stage 4 1P:2D Kimi-K2 (Stage 4 was 2P:1D at ~same rate with single-digit-ms TPOT boost from the extra decode). Direct comparison requires a matched sweep; R1a is just baseline for R1b/R1c scaling.
4. **TTFT P99 25.6 s is high** — 1P:1D topology means a single prefill is the bottleneck at burst arrival (peak concurrent requests: 64). Expected to drop in R1c (1P:2D) where prefill is freed up sooner.

## Operational notes

- **Cold start total: ~6 min** from `kubectl apply` → readinessProbe OK (weight load from local NVMe was the dominant phase; EFA init + Mooncake bringup < 30 s).
- FSx cross-AZ mount for weights is **not usable** for single-file > 500 GB × concurrent 8+ mmap readers; memory saved as `feedback_fsx_crossaz_hostpath.md`.
- Current Ohio LT `lt-0200be32f4401a715 v1` does not auto-stripe instance-store NVMe. Future Spot-GPU spinups should use `KevinZhao/eks-cluster-deployment` → `GPU_ENABLE_LOCAL_LVM=true` instead of ad-hoc `setup-nvme.sh`. Memory saved as `reference_eks_gpu_node_deploy_repo.md`.

## Artifacts

- `STEPS.md` — full execution timeline
- `ROOT_CAUSE_V5.md` / `ROOT_CAUSE_FINAL.md` — diagnosis chain (initial vs corrected)
- `manifests/stage5-p5en/r1a-kimi-k2-1p1d-v5-hostpath.yaml` — deployed manifest
- `manifests/stage5-p5en/_prefetch-hf-to-nvme.yaml` — HF prefetch Job

## Next

- **R1b**: same hostPath path, 2P:1D topology.
- **R1c**: same, 1P:2D (expected to reduce TTFT P99 meaningfully).
- For R2 (DSv3.1 640 GB), R5 (GLM-5.1) → repeat the HF → `/mnt/nvme` prefetch recipe.
- Teardown at end of session: delete R1a deploys, scale `gpu-p5en-spot-useast2a` desired=0.
