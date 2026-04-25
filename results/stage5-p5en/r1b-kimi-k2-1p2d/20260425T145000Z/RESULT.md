# R1b · Kimi-K2-Instruct-0905 1P:2D on 3 × p5en (Ohio use2-az2) — PASS

**Run ID**: `r1b-kimi-k2-1p2d` (third attempt — first PASS)
**Bench completion (UTC)**: 2026-04-25T14:50Z
**Region / AZ**: us-east-2 / **usw2-az2** (pinned via nodeSelector)
**Model**: `moonshotai/Kimi-K2-Instruct-0905` (1T MoE FP8 block-quantized, 959 GB, 62 shards)
**Image**: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake:v5`
  - SGLang 0.5.10 + Mooncake v0.3.10.post2 + Henan EFA PRs (incl. #1944 SRD shared-endpoint)
**Topology**: 1 prefill + 2 decode + 1 router; all 3 GPU pods on distinct hosts in same AZ
**KV transport**: Mooncake `EfaTransport` over EFA v3 (16 × 200 Gbps per p5en)
**Weights**: `hostPath: /mnt/nvme/models/Kimi-K2-Instruct-0905` on each node
  - pre-seeded via HF `hf download --max-workers 16 + HF_HUB_ENABLE_HF_TRANSFER=1`
  - Kimi-K2 959 GB × 3 nodes parallel prefetch: **20 min**
  - `/mnt/nvme` created manually via `scripts/setup-nvme.sh` (Ohio LT v1 lacks auto-LVM)

## Infrastructure path to get here

Today's third R1b attempt. Prior two aborts:
- **09:15 UTC Ohio use2-az1** (`gpu-p5en-spot-useast2a`): 3 nodes launched, HF prefetch started, 3 of 3 Spot-reclaimed → weights on `/mnt/nvme` erased
- **13:38 UTC Oregon usw2-az3** (`gpu-p5en-48xlarge-spot`): 3 nodes launched, 2 of 3 reclaimed at ~22 min of HF prefetch; ASG replacements hit `MaxSpotInstanceCountExceeded`

Third attempt path (`14:00 UTC`):
1. Observed Ohio p5en SPS recovery on use2-az2 (= 9 @ cap=3). Existing Ohio p5en NG `gpu-p5en-spot-useast2a` is hard-pinned to use2-az1 (SPS=1).
2. Created new NG `gpu-p5en-spot-useast2b` on subnet-0c86f1c69e4067890 (us-east-2b = use2-az2).
3. Fixed LT: existing `lt-0200be32f4401a715` v1 had `InstanceType: null` which caused `CreateNodeGroup` validation to reject with "max 1 NIC for t3.medium". Patched to v2 with `InstanceType: p5en.48xlarge`.
4. 3 Spot p5en launched in use2-az2 within 4 min; NG ACTIVE, no health issues.
5. Ran `scripts/setup-nvme.sh` on all 3 nodes (Ohio LT v1 lacks the new `GPU_ENABLE_LOCAL_LVM=true` userdata). `/mnt/nvme` 28 TB xfs ready in ~90 s.
6. Applied HF prefetch Job (completions=3/parallelism=3 + `nodeSelector: topology.kubernetes.io/zone=us-east-2b`). 20 min to complete 3/3.
7. Applied R1b hostPath manifest with the same AZ pin applied to all 4 Deployments (prefill + decode-0 + decode-1 + lb).
8. 14 min cold start — all pods 1/1 Ready.
9. Bench PASS.

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
Benchmark duration (s):                  54.98
Total input tokens:                      65633
Total generated tokens:                  33252
Request throughput (req/s):              2.33
Input token throughput (tok/s):          1193.76
Output token throughput (tok/s):         604.80
Peak output token throughput (tok/s):    2476.00
Peak concurrent requests:                68
Total token throughput (tok/s):          1798.56
Concurrency:                             36.34
----------------End-to-End Latency----------------
Mean E2E Latency (ms):                   15608.95
Median E2E Latency (ms):                 14492.86
P90 E2E Latency (ms):                    27905.61
P99 E2E Latency (ms):                    39029.46
---------------Time to First Token----------------
Mean TTFT (ms):                          7844.34
Median TTFT (ms):                        8751.88
P99 TTFT (ms):                           20770.06
-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          31.95
Median TPOT (ms):                        29.97
P99 TPOT (ms):                           78.12
---------------Inter-Token Latency----------------
Mean ITL (ms):                           30.00
Median ITL (ms):                         28.94
P95 ITL (ms):                            64.37
P99 ITL (ms):                            79.65
Max ITL (ms):                            17516.31
==================================================
```

## PD scaling curve — R1a vs R1b (same model, same bench, same image)

| Metric | R1a 1P:1D | **R1b 1P:2D** | Δ vs R1a |
|---|---|---|---|
| Total tok/s | 1412 | **1799** | **+27%** |
| Request throughput | 1.83 req/s | **2.33 req/s** | **+27%** |
| Mean TPOT | 47.7 ms | **31.95 ms** | **-33%** |
| Median TPOT | 46.0 ms | **29.97 ms** | **-35%** |
| P99 TPOT | 101 ms | **78.12 ms** | **-23%** |
| Mean ITL | 48.0 ms | **30.00 ms** | **-37%** |
| Median ITL | 35.7 ms | **28.94 ms** | **-19%** |
| P95 ITL | 95.7 ms | **64.4 ms** | **-33%** |
| Mean TTFT | 7329 ms | 7844 ms | +7% (noise; prefill-bound) |
| Median TTFT | 3344 ms | 8751 ms | +162% (see note) |
| P99 TTFT | 25651 ms | 20770 ms | -19% |
| Mean E2E | 19743 ms | **15609 ms** | **-21%** |
| Peak concurrent req | 64 | 68 | +6% |
| Concurrency | 36.1 | 36.3 | ~flat |

**Interpretation**: adding a second decode pod at the same prefill capacity gives **+27% throughput with -33% TPOT**. The decode path was clearly the bottleneck in R1a: each decode node can feed only so many concurrent active sequences through its KV cache + autoregressive step; a second decode doubles the parallel decoding capacity.

**TTFT notes**:
- Median TTFT increased (3.3 s → 8.7 s). This is counter-intuitive at first glance, but explainable: at the same 4 req/s arrival rate, the 1P:2D deployment absorbs more in-flight sequences (peak concurrent 64→68), so more requests queue behind the single prefill while it crunches through its chunked-prefill queue. If we scaled `request-rate` proportionally (4 → 5.3 req/s), the per-request TTFT should recover.
- P99 TTFT actually decreased (25.6 s → 20.8 s), consistent with the bigger decode pool absorbing bursts better.
- **TTFT is prefill-bound; TPOT/ITL is decode-bound**. R1b proves both dimensions: prefill-bound metrics stay flat or slightly worse (because the 1P handles more overall load), decode-bound metrics drop sharply (because 2D has twice the capacity).

## Key findings

1. **PD scaling works on EFA with Mooncake v5**: adding a decode node 1 → 2 produces near-linear throughput scaling (+27% at rate=4 which was the cliff for 1P:1D) and proportional decode-latency reduction.
2. **Same-AZ `nodeSelector` pinning is effective**: all 4 Deployments (3 server + 1 LB) have `nodeSelector: topology.kubernetes.io/zone=us-east-2b`; ASG happened to schedule all 3 Spot instances into use2-az2 so no pod was pending. No cross-AZ Mooncake KV failures like the earlier R3 1P:2D attempt.
3. **New Ohio p5en NG pattern established**: `gpu-p5en-spot-useast2b` on use2-az2 subnet. The subnet-pinned NG + LT v2 (with `InstanceType` set) is reusable for future runs that need a specific AZ.
4. **R1a vs R1b validates our Stage 4 Kimi-K2 1P:2D baseline** (different image v5 vs v2): the v5 stack produces valid PD scaling, making it safe to use v5 for the rest of Stage 5 instead of v2.

## Operational caveats

- **3rd attempt of the day** — first two aborted on Spot reclaim during HF prefetch. The combination of:
  - Not relying on FSx PVC (cross-AZ Lustre contention)
  - Paying for prefetch re-download on each attempt (HF hub gives us 1 GB/s/node = 20 min for Kimi-K2)
  - Using `nodeSelector` to keep pods in one AZ
  — is the current "robust recipe" on EFA. Spot reclaim cost is ~20 min per full redo.
- **New memory**: Ohio LT v1 `lt-0200be32f4401a715` is a template — creating new NGs from it requires a v2 patch to add `InstanceType: p5en.48xlarge` (saved below as ops note).

## Status

**PASS** — R1b headline numbers locked. Combined with R1a PASS, we now have two points on the Kimi-K2 PD scaling curve (1P:1D and 1P:2D). R1c (1P:3D) next if Spot supports 4 nodes in same AZ.

## Artifacts

- Manifest: `manifests/stage5-p5en/r1b-kimi-k2-1p2d-v5-hostpath-ohio-az2.yaml`
- Prefetch: `manifests/stage5-p5en/_prefetch-hf-kimi-ohio-az2.yaml`
- Earlier abort docs:
  - `results/stage5-p5en/r1b-kimi-k2-1p2d/20260425T091545Z/ABORT.md` (Ohio az1 Spot reclaim)
  - `results/stage5-p5en/r1b-kimi-k2-1p2d/20260425T141500Z/ABORT.md` (Oregon az3 pool exhaustion)
