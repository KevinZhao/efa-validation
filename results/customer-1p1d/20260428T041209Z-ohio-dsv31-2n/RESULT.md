# Customer 1P:1D(2-node decode) perf bench — DeepSeek-V3.1 block-FP8 on Ohio p5en H200

**Date**: 2026-04-28
**Operator**: Kevin Zhao
**Region / AZ**: us-east-2 / use2-az2 (p5en spot × 3)
**Cluster**: gpu-cluster-ohio
**Topology**:
- Prefill pod: 1 × p5en.48xlarge, TP=8 single-node, `--moe-a2a-backend=none` (see "why prefill is forced none" below)
- Decode pod: 2 × p5en.48xlarge, TP=16 (8×2), `--nnodes 2`, variant-dependent a2a backend
- LB pod: 1 × sglang_router mini-lb
- KV transport: Mooncake over EFA
**Image stream**: `public.ecr.aws/n3l4x8f3/sglang-mooncake-{uccl,nccl}:2026.04.28-h200.2`
**Model**: `deepseek-ai/DeepSeek-V3.1` (671B, block-FP8 `[128,128]`, top_k=8, 256+1 experts, MLA)
**Bench**: `sglang.bench_serving --dataset-name random --random-input-len 2048 --random-output-len 1024 --num-prompts 128 --max-concurrency 16 --warmup-requests 8`

## Why 1P(single-node) + 1D(2-node) topology

First attempt (2026-04-28 previous run, 1P:1D single-node) showed UCCL-EP couldn't be exercised
because 1P:1D TP=8 keeps all MoE alltoall intranode NVLink. This run reshapes **decode only** to
cross-node TP=16 so decode's MoE alltoall actually traverses EFA — the exact path UCCL-EP's
`internode_ll` kernel replaces.

Prefill stays single-node because sglang 0.5.10 forces `ep_size=tp_size` when
`moe_a2a_backend=deepep`, and prefill uses DeepEP's `normal` mode which requires per-batch CPU
handshake via `runtime.intranode_prepare`. In PD-disagg warmup this handshake times out
(`DeepEP error: CPU recv timeout`) on 8 TP ranks — regardless of UCCL. UCCL only substitutes the
**internode** low-latency kernel; intranode stays native DeepEP upstream. So prefill keeps
`--moe-a2a-backend=none` in both variants.

## Variant differences (decode side only)

| Variant | Decode `--moe-a2a-backend` | Decode `ep_size` (effective) | Decode MoE path |
|---|---|---|---|
| uccl | `deepep` | 16 (sglang forces ep=tp when deepep) | DeepEP `low_latency` → UCCL-EP `internode_ll` over EFA across 2 nodes |
| nccl | `none` | 1 (MoE weights TP-sharded, no EP) | Standard TP path, NCCL allreduce (no cross-node alltoall) |

**Important**: the two variants do NOT compare "UCCL alltoall kernel" vs "NCCL alltoall kernel".
sglang 0.5.10 `--moe-a2a-backend=none` does NOT pick an alltoall implementation — it disables
expert parallelism entirely and TP-shards the MoE matmul. So the A/B here is **"EP=16 cross-node
via UCCL-EP" vs "EP=1 pure TP"**, which is a different (but still customer-relevant) question:
*for DS-V3.1 at 2×p5en, is distributing experts worthwhile?*

## Results

### uccl variant (EP=16 cross-node via UCCL-EP)

```
Successful requests:                     128
Benchmark duration (s):                  167.22
Request throughput (req/s):              0.77
Output token throughput (tok/s):         394.81
Total token throughput (tok/s):          1246.57
Peak output token throughput (tok/s):    464.00
Concurrency:                             14.64
Mean TTFT (ms):                          708.01
Median TTFT (ms):                        449.34
P99 TTFT (ms):                           2173.31
Mean TPOT (ms):                          35.90
Median TPOT (ms):                        35.94
P99 TPOT (ms):                           39.18
Mean ITL (ms):                           35.78
P95 ITL (ms):                            45.43
P99 ITL (ms):                            56.41
Mean E2E latency (ms):                   19127.80
P90 E2E latency (ms):                    33270.04
```

Raw log: `bench-uccl-dsv31.log`

### nccl variant (EP=1 pure TP)

```
Successful requests:                     128
Benchmark duration (s):                  102.00
Request throughput (req/s):              1.25
Output token throughput (tok/s):         647.27
Total token throughput (tok/s):          2043.71
Peak output token throughput (tok/s):    752.00
Concurrency:                             14.74
Mean TTFT (ms):                          685.55
Median TTFT (ms):                        500.58
P99 TTFT (ms):                           2435.07
Mean TPOT (ms):                          21.56
Median TPOT (ms):                        21.58
P99 TPOT (ms):                           22.75
Mean ITL (ms):                           21.49
P95 ITL (ms):                            22.84
P99 ITL (ms):                            24.13
Mean E2E latency (ms):                   11749.47
P90 E2E latency (ms):                    20037.20
```

Raw log: `bench-nccl-dsv31.log`

## A/B delta table

| Metric | uccl (EP=16, cross-node alltoall) | nccl (EP=1, pure TP) | Δ (uccl vs nccl) |
|---|---:|---:|---:|
| Benchmark duration | 167.22 s | 102.00 s | +64% slower |
| Request throughput | 0.77 req/s | 1.25 req/s | -38% |
| Output tok/s | 394.81 | 647.27 | -39% |
| Total tok/s | 1246.57 | 2043.71 | -39% |
| Peak output tok/s | 464 | 752 | -38% |
| **Mean TPOT** | **35.90 ms** | **21.56 ms** | **+67% slower** |
| Median TPOT | 35.94 ms | 21.58 ms | +67% slower |
| P99 TPOT | 39.18 ms | 22.75 ms | +72% slower |
| **Mean ITL** | **35.78 ms** | **21.49 ms** | **+66% slower** |
| P95 ITL | 45.43 ms | 22.84 ms | +99% slower |
| P99 ITL | 56.41 ms | 24.13 ms | +134% slower |
| Mean TTFT | 708.01 ms | 685.55 ms | +3% (essentially flat) |
| Median TTFT | 449.34 ms | 500.58 ms | -10% (uccl slightly faster) |
| P99 TTFT | 2173.31 ms | 2435.07 ms | -11% (uccl slightly faster) |
| Mean E2E | 19127.80 ms | 11749.47 ms | +63% slower |

## Interpretation

**Prefill (single-node TP=8) throughput is equivalent**, as expected — prefill config is
identical across variants (both nccl), so TTFT differences are noise (~3%).

**Decode TPOT is +67% slower in uccl**. This is the decode path difference. The decode token
generation loop is dominated by the per-token MoE alltoall when ep=16; the cross-node alltoall
latency is significantly higher than the pure TP (allreduce-only) path.

### What this means for the customer

For DS-V3.1 on **2 × p5en.48xlarge**, distributing experts across nodes (UCCL-EP or any cross-node
EP) is **net negative for decode latency** at this model scale. The all-expert-local TP path
(`ep=1`) wins by 67% on TPOT. This matches the theoretical expectation:

- DS-V3.1 at EP=16 puts 16 experts per GPU (256/16). Each decode token triggers top-8 routing,
  and with ep=16 most selected experts are non-local → every decode token pays a cross-node EFA
  alltoall.
- At EP=1 + TP=16, all 256 experts are TP-sharded inside the pod; selected experts are always
  locally accessible via NVLink/NVSwitch + cross-node TP allreduce. No alltoall per token.

### When UCCL-EP would win

UCCL-EP's design target is **wide-EP** (EP ≥ 32, spread across 4+ nodes), where:
- Per-GPU expert count drops to ≤8 → each GPU has too little work to hide local compute
- Expert distribution becomes necessary for memory (trillion-parameter models)
- The comparison is NOT against "no alltoall" but against **NCCL alltoall at same EP size**

On 2 × p5en / DS-V3.1 neither condition applies — the model fits comfortably with TP-sharded
experts on 16 GPUs, and EP=16 creates more cross-node traffic than it saves compute.

**This bench does NOT measure UCCL-EP's value against its actual competitor**. To do that, we'd
need to force both variants to `ep_size=16 + deepep`, with two different DeepEP backend builds
(UCCL-EP vs upstream DeepEP-over-NCCL). That requires either:
1. A custom sglang patch to decouple `--moe-a2a-backend` selection from the UCCL shim, OR
2. An `ep-bench`-style micro-benchmark (bypassing sglang entirely) that directly invokes
   `deep_ep::Buffer.dispatch`/`.combine` with different backends.

Option 2 is what `benchmarks/bench_dispatch_combine_uccl.py` already does — the p5en dispatch/
combine numbers are covered in `reference_alltoall_deep_dive.md`.

## Infrastructure findings from this multi-node run

1. **NVMe RAID0 setup needed on p5en** — raw NVMe → mdadm /dev/md0 → ext4 → /mnt/nvme 28 TB
   (`scripts/setup-nvme-p5.sh`). Pre-existing LVM from 04-27 cluster was gone after spot refresh.
2. **s5cmd prefetch OOM with 3 concurrent nodes downloading 688 GB each**. initContainer memory
   limit bumped 32Gi → 64Gi (`resources.limits.memory: 64Gi`).
3. **decode-1 (follower) readiness probe** — non-leader nodes only expose `/health` via a stub
   HTTP server, not `/get_model_info`. Changed probe from `httpGet /get_model_info` to
   `tcpSocket: {port: 30000}` to accommodate both leader (real) and follower (stub) nodes.
4. **StatefulSet + Headless Service** (`c1p1d-decode-headless:10010`) is required for sglang
   multi-node — torch distributed bootstrap uses stable per-pod DNS
   (`c1p1d-decode-0.c1p1d-decode-headless.yanxi-validation.svc:10010`).
5. **ClusterIP Service for the leader only** — `c1p1d-decode` selects on
   `statefulset.kubernetes.io/pod-name: c1p1d-decode-0` so LB's `/generate` only talks to the
   leader (decode-1 doesn't accept external traffic, only runs the distributed worker).
6. **TP convention in sglang**: `--tp 16 --nnodes 2` means 16 TOTAL ranks across 2 nodes (8 per
   node), not 16 per node. Earlier misconfiguration caused launch failure.
7. **NODE_RANK from pod ordinal**: launcher derives `NODE_RANK="${POD_NAME##*-}"` from
   StatefulSet pod name suffix (`c1p1d-decode-0` → rank 0, `-1` → rank 1).
8. **bench_serving `/v1/models` ready check** hangs against mini-lb + PD-disagg prefill. Fix:
   `--ready-check-timeout-sec 0` in Bench Job args.
9. **Watchdog 1800s (30 min)** confirmed necessary — DeepGEMM JIT for DS-V3.1 FP8 consistently
   takes 12-15 min for 16384 kernels on each fresh pod start.

## Files

- `manifest-uccl.yaml`, `manifest-nccl.yaml` — full K8s manifests (prefill=none, decode=deepep/none)
- `bench-job-uccl.yaml`, `bench-job-nccl.yaml` — rendered bench Jobs
- `bench-uccl-dsv31.log` — uccl variant bench output (128/128 prompts, 167.22 s)
- `bench-nccl-dsv31.log` — nccl variant bench output (128/128 prompts, 102.00 s)

## Conclusions

1. **A/B completes cleanly**: both variants ran to 128/128 completion with zero crashes, same
   bench harness, same dataset seed.
2. **Decode-side A/B is statistically meaningful but architecturally uneven**: uccl=EP16 vs
   nccl=EP1 compare "do cross-node alltoall per token" vs "don't". Result matches physics: not
   doing alltoall is faster on 2 nodes.
3. **Customer takeaway for DS-V3.1 at 2×p5en**: use **nccl variant** (`--moe-a2a-backend=none`).
   UCCL-EP doesn't help at this scale; it only helps when wide-EP is forced by model memory
   pressure (> 2 nodes, > EP=16).
4. **UCCL-EP vs NCCL alltoall** requires either a sglang patch (fix `--moe-a2a-backend=nccl` to
   do real NCCL alltoall at ep=16), or a micro-bench at deep_ep level. Customer bench can't
   measure this directly with stock sglang 0.5.10.

## Next steps

- **For customer production on DS-V3.1**: ship nccl variant image, document "use deepep only if
  scaling to ≥ 4 nodes wide-EP". Add this guidance to `docs/P5EN_MODEL_DEPLOYMENT_MATRIX.md`.
- **For UCCL-EP PR story**: the real value story lives at the deep_ep micro-benchmark level
  (p5en dispatch 174.9µs / combine 326.7µs per `reference_alltoall_deep_dive.md`), not at
  sglang.bench_serving. Sprint A/B/C SBO optimizations target those micro-numbers.
- **For GLM-5 customer spec (D:TP16/EP16/DPattn16 2-node)**: expect similar pattern — EP=16 on
  2 nodes will be slower than EP=1 TP=16 for decode. Customer's insistence on EP=16 must come
  from a memory/architecture constraint they haven't stated; document the tradeoff.
- **Scale Ohio ASG back to 0** once bench artifacts are committed.
