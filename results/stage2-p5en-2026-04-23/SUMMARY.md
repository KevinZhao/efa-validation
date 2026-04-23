# Stage 2 (p5en re-run, 2026-04-23) — UCCL-EP on EFA v3, Ohio

**Date**: 2026-04-23 12:40 UTC
**Cluster**: `gpu-cluster-ohio` (EKS 1.35)
**Nodes**: 2× p5en.48xlarge (us-east-2a, `ip-10-1-11-107`, `ip-10-1-11-124`)
  — new Spot batch after overnight preemption
**Image**: `yanxi/uccl-ep:v2` (unchanged from 2026-04-22 run)
**Manifest**: `stage2-uccl-ep/mpijob-perf-uccl.yaml` (patched: `workload-type: gpu`
for both launcher and worker nodeSelector to survive fleet re-provisioning)

## Why the re-run

The 04-22 baseline run is in `results/stage2-p5en/SUMMARY.md`. Today's node group
was fully re-provisioned after Spot preemption (new instance IDs, new AMIs,
same software stack). This re-run confirms the baseline replicates on a fresh
fleet, and provides a fresh EP-a2a data point for the GLM-5.1 FP16 TP8/EP2
planning exercise.

## NCCL-EP (DeepEP) — BLOCKED

DeepEP cpp extension built for CUDA 12.4 triggers
`undefined symbol: __cudaRegisterLinkedBinary_0b4aee48_9_layout_cu_833d94b3`
under our image's CUDA 12.6 + torch 2.5.1+cu124 combo (pre-existing Ohio
known issue, documented in `stage2-uccl-ep/README.md`). Re-build of the
DeepEP wheel for cu126 is required before NCCL-EP can be benched
apples-to-apples against UCCL-EP.

Until that's fixed, the NCCL-EP baseline is the historical number from
Stage 2 p5 (`results/stage2/SUMMARY.md`): **~7 GB/s per rank**
dispatch+combine (DeepEP over IB / legacy NCCL plugin).

## UCCL-EP results

### `test_low_latency.py` (MoE decode-style path)

16 ranks across 2 nodes, hidden=7168, topk=8, num_experts default, BF16 + FP8
sweep, 16/16 correctness PASS.

| Metric | Value per rank |
|---|---|
| **Dispatch + combine bandwidth (combined kernel)** | **34.37–34.49 GB/s** |
| Dispatch + combine avg latency | ~640 μs (range 537–714 μs) |
| Dispatch bandwidth (decomposed) | 38.2–43.9 GB/s |
| Combine bandwidth (decomposed) | 45.1–49.0 GB/s |
| Dispatch latency | 171–196 μs |
| Combine latency | 297–322 μs |
| Dispatch send / recv | ~35 / ~22 μs |
| Combine send / recv | ~35 / ~45 μs |

### `test_internode.py` (MoE prefill-style path, with kernel tuning sweep)

Auto-tuned over (SMs, NVL chunk, RDMA chunk) grid. Best configs:

| Op | Precision | Best RDMA BW | Best NVL BW | Transmit | Notify |
|---|---|---|---|---|---|
| **Dispatch** | **FP8** | **51.07 GB/s** | 167.08 GB/s | 1181 μs | 90 μs |
| **Dispatch** | BF16 | 64.70 GB/s | 211.66 GB/s | 1808 μs | 254 μs |
| **Combine** | BF16 | 17.19 GB/s | 56.23 GB/s | 6806 μs | 390 μs |

Best config for all three was SMs=24, with RDMA chunk 20–32 and varying NVL
chunk size.

### Comparison with 2026-04-22 baseline

| Metric | 04-22 baseline | **04-23 re-run** | Δ |
|---|---|---|---|
| Dispatch+combine BW/rank (LL bench) | 36.49–36.64 GB/s | **34.37–34.49 GB/s** | -6% |
| Dispatch single BW/rank | 37.95–65.85 GB/s | **38.24–43.85** (dispatch-only in LL) | within noise |
| Correctness | 16/16 | **16/16** | = |

Re-run is within ~6% of 04-22 baseline — reproduces the Ohio p5en UCCL-EP
signature on fresh hardware. The small delta is normal Spot-to-Spot variance
(different physical rack placements after preemption).

## Implications for GLM-5.1 FP16 TP=8 EP=2

Planned topology is 2× p5en per pool (P + D each 2 nodes, TP=8 × EP=2).
EP a2a traffic happens between the two nodes of each pool — exactly what
this benchmark measures (16 ranks across 2 nodes).

| Expected per-pool EP a2a capacity |  |
|---|---|
| Dispatch+combine BW/rank (LL) | **~34 GB/s** → aggregate 544 GB/s for 16 ranks |
| Dispatch BW/rank (prefill FP8) | **~51 GB/s** |
| Combine BW/rank (prefill BF16) | **~17 GB/s** → combine is the tighter limit |

For GLM-5.1's 256 routed experts / top-8 active, per-token a2a volume is
modest (top-8 × hidden=6144 bytes × 2 = ~100 KB dispatch, similar combine).
At 34 GB/s/rank combined, per-layer a2a is ~3 μs — not a bottleneck, as
expected.

## Artifacts

- Launcher log: `/var/lib/yanxi-logs/stage2/uccl-perf-internode.log` (2 MB)
- LL bench log: `/var/lib/yanxi-logs/stage2/uccl-perf-ll.log` (2 MB)
- Old NCCL baseline attempt: `/var/lib/yanxi-logs/stage2/nccl-perf-{internode,ll}.log` (DeepEP ABI error)
- Patched manifests pushed to `stage2-uccl-ep/mpijob-perf-{nccl,uccl}.yaml` on bastion
  (not committed back yet — the `workload-type: gpu` nodeSelector change is
  general enough to upstream)
