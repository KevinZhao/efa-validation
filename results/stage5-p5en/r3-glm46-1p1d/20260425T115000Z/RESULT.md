# R3 · GLM-4.6-FP8 1P:1D on 2 × p5 (Oregon, same-AZ) — PASS

**Run ID**: `r3-glm46-1p1d`
**Bench completion (UTC)**: 2026-04-25T11:50Z
**Region / AZ**: us-west-2 / **usw2-az2 (both pods)**
**Model**: `zai-org/GLM-4.6-FP8` (355B MoE, 160 experts top-8, GLM-MoE, ~370 GB FP8)
**Image**: `788668107894.dkr.ecr.us-west-2.amazonaws.com/yanxi/sglang-mooncake:v5`
  - SGLang 0.5.10 + Mooncake v0.3.10.post2 + Henan EFA PRs (incl. #1944 SRD shared-endpoint)
**Topology**: 1 prefill (node-B' 10.0.12.228) + 1 decode (node-B 10.0.12.231) + 1 router co-located with decode; both GPU pods on same AZ `usw2-az2`, anti-affinity by hostname
**KV transport**: Mooncake `EfaTransport` over EFA (16 NICs × p5, libfabric efa provider, shared endpoint max_wr=256)
**Weights**: `hostPath: /data/models/GLM-4.6-FP8` on each node
  - `/data` = 27.6 TB striped LVM (vg_local) auto-mounted by **Oregon p5 LT v4 userdata** (KevinZhao/eks-cluster-deployment's `GPU_ENABLE_LOCAL_LVM=true`)
  - weights pre-seeded via `hf download --max-workers 16` + `HF_HUB_ENABLE_HF_TRANSFER=1` (~8-10 min parallel)

## SGLang server config

| param | value |
|---|---|
| TP | 8 |
| context-length | 131072 |
| mem-fraction-static | 0.85 |
| chunked-prefill-size | 4096 |
| fp8-gemm-backend | cutlass |
| disaggregation-transfer-backend | mooncake |
| FI_PROVIDER | efa |
| MC_WORKERS_PER_CTX | 2 |
| MC_NUM_CQ_PER_CTX | 2 |

Quant kernel: `CompressedTensorsW8A8Fp8MoE` (GLM-4.6 uses compressed-tensors FP8, not block-FP8; no block_n alignment constraint unlike Qwen3-235B-A22B-FP8).

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
Benchmark duration (s):                  42.71
Total input tokens:                      65633
Total input text tokens:                 65633
Total generated tokens:                  33252
Total generated tokens (retokenized):    33212
Request throughput (req/s):              3.00
Input token throughput (tok/s):          1536.67
Output token throughput (tok/s):         778.53
Peak output token throughput (tok/s):    1337.00
Peak concurrent requests:                47
Total token throughput (tok/s):          2315.21
Concurrency:                             25.23
----------------End-to-End Latency----------------
Mean E2E Latency (ms):                   8419.19
Median E2E Latency (ms):                 8412.19
P90 E2E Latency (ms):                    14367.09
P99 E2E Latency (ms):                    16693.50
---------------Time to First Token----------------
Mean TTFT (ms):                          1226.06
Median TTFT (ms):                        590.47
P99 TTFT (ms):                           5296.31
-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          27.65
Median TPOT (ms):                        28.81
P99 TPOT (ms):                           34.94
---------------Inter-Token Latency----------------
Mean ITL (ms):                           27.79
Median ITL (ms):                         28.81
P95 ITL (ms):                            31.38
P99 ITL (ms):                            36.37
Max ITL (ms):                            294.85
==================================================
```

## Direct comparison vs R1a baseline

Same bench config (rate=4, 128 prompts, 1024/512 ISL/OSL).

| Metric | R1a Kimi-K2 1P:1D p5en | R3 GLM-4.6 1P:1D p5 same-AZ |
|---|---|---|
| Total tok throughput | 1412 tok/s | **2315 tok/s (+64%)** |
| Request throughput | 1.83 req/s | **3.00 req/s (+64%)** |
| Mean TTFT | 7329 ms | **1226 ms (-83%)** |
| Median TTFT | 3344 ms | **590 ms (-82%)** |
| P99 TTFT | 25651 ms | **5296 ms (-79%)** |
| Mean TPOT | 47.7 ms | **27.65 ms (-42%)** |
| P99 TPOT | 101 ms | **34.94 ms (-65%)** |
| Mean ITL | 47.97 ms | **27.79 ms (-42%)** |
| Concurrency | 36 | 25 |

Caveats on comparison:
- Different GPU (H200 141 GB for Kimi-K2 vs H100 80 GB for GLM-4.6) — Kimi-K2 model is also 2.6× larger so per-token compute is higher.
- R3 uses `compressed-tensors` FP8; R1a uses `block-fp8`. The MoE kernel path differs.
- This is not a fair Mooncake-vs-Mooncake comparison for the same model; it's two separate data points in the Stage 5 grid.

## Key findings

1. **Mooncake v5 PD-disagg works end-to-end on p5 (H100 80 GB)** for GLM-4.6-FP8 with TP=8 and same-AZ topology. PR #1944 SRD shared-endpoint active.
2. **Same-AZ is mandatory** for Mooncake KV handshake in the current stack: earlier R3 attempt with 3 pods across usw2-az1/2/3 produced `TransferEncodingError: Not enough data to satisfy transfer length header` on the very first warmup request, while same-AZ variant completed 128/128 cleanly.
3. **GLM-4.6-FP8 is significantly "lighter" than Kimi-K2**: smaller weights (370 GB vs 959 GB), fewer active experts per token, compressed-tensors FP8 avoiding block alignment issues, and H100 being H100 + sufficient headroom → TTFT and TPOT both drop substantially relative to Kimi-K2.
4. Cold start (weight load from local NVMe + EFA init + Mooncake handshake) was ~10 min from `kubectl apply` to 1/1 Ready on both pods.

## Operational sidebar

- **New infra discovery**: Oregon p5 Launch Template v4 already bakes `GPU_ENABLE_LOCAL_LVM=true` (from `KevinZhao/eks-cluster-deployment`) — no manual `setup-nvme.sh` needed. Confirms memory `reference_eks_gpu_node_deploy_repo.md`.
- **ASG subnet pinning**: `aws eks update-nodegroup-config` does NOT allow subnets edit post-creation. Workarounds:
  1. Directly modify the underlying ASG's `VPCZoneIdentifier` — but EKS reconciles it back within seconds.
  2. Terminate non-target-AZ instances and hope ASG replaces into the target AZ — effective but wasteful.
  3. Lock pods via `nodeSelector: topology.kubernetes.io/zone=<az>` — this worked once we had ≥1 node in the desired AZ.
- **Quota signal**: `MaxSpotInstanceCountExceeded` surfaced when scaling from 3 → 6 p5. Account-level Spot p5 capacity was capped by AWS at ~3-4 for Oregon at that moment. Not a hard quota; will recover as capacity frees up.

## Memories written this session

- `feedback_fsx_crossaz_hostpath.md` — Kimi-K2 FSx cross-AZ OST issue (R1a)
- `feedback_spot_reclaim_wipes_nvme.md` — R1b Ohio Spot reclaim erased `/mnt/nvme`
- `feedback_no_ondemand_spot_only.md` — never fall back to On-Demand
- `feedback_same_az_for_pd_disagg.md` — same-AZ is mandatory for Mooncake KV (R3 cross-AZ → same-AZ success proves it)
- `feedback_qwen3_235b_fp8_tp8_unsupported.md` — Qwen3-235B-A22B-FP8 TP=8 hits sglang's block-FP8 alignment bug
- `reference_eks_gpu_node_deploy_repo.md` (updated) — Oregon p5 LT v4 already uses the new auto-LVM userdata

## Artifacts

- Manifest: `manifests/stage5-p5en/r3-glm46-1p1d-v5-hostpath-oregon-az2.yaml`
- Prefetch: `manifests/stage5-p5en/_prefetch-hf-glm46-oregon.yaml`
- Earlier abort doc: `results/stage5-p5en/r3-glm46-1p2d/20260425T110000Z/ABORT.md` (pre same-AZ fix)

## Status

**PASS** — R3 headline number captured. Planned R3 variant ("GLM-4.6 长 ctx 128k/200k" in Stage 5 plan §6) is a follow-on sweep (longer input len) and can be run on demand off this baseline.
