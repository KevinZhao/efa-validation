# R1a · Kimi-K2 1P:1D — Execution Log

**Run ID**：`r1a-kimi-k2-1p1d`
**Start (UTC)**：2026-04-25T03:35:52Z
**Operator**：Kevin Zhao (via Claude agent)
**Target**：Baseline PD-disaggregation run, Kimi-K2-Instruct-0905 FP8, 1 prefill + 1 decode on 2 × p5en
**Model**：Kimi-K2-Instruct-0905 (1T MoE, FP8 block-quantized, 959 GB)
**Region / AZ**：us-east-2 / us-east-2a (use2-az1, SPS=9 @ cap=2, 16:25 UTC scan)
**Nodegroup**：`gpu-p5en-spot-useast2a`
**Image**：`788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake:v2`
**KV transport**：Mooncake EfaTransport (launcher applies rdma→efa sed patch)

## Related
- R0 PASS: `results/stage5-p5en/r0-smoke/20260424T151359Z/` — image trust established
- STAGE5_PLAN §6 R1a: baseline 1P:1D Kimi-K2

---

## Pre-flight

### SPS cap=2 rescan (16:25 UTC) — Ohio wins

| Region / AZ | Score |
|---|---|
| us-east-2 use2-az1 | **9** |
| us-west-2 usw2-az3 | 4 |
| us-east-2 use2-az2 | 3 |

→ Ohio `gpu-p5en-spot-useast2a` nodegroup.

### Ohio FSx snapshot (verified by busybox probe earlier)

- `fs-0e7e1313a9c964d34` / 4.4 TiB / Lustre 2.15 / us-east-2b (usw2-az2 FSx, GPU lands in us-east-2a → cross-AZ mount)
- `/fsx/Kimi-K2-Instruct-0905/.prefetch-complete` ✅
- 63 safetensors shards / 959.2 GB total
- 3.4 TB used / 1012 GB free

### Node state

- 03:25 UTC: p5en `i-025388ac45366a78d` Running us-east-2a 10.1.11.4 (from R1a prep scale-up at 03:19)
- 03:33 UTC: p5en `i-0a599cca49c3a8875` Running us-east-2a 10.1.11.96
- Both in us-east-2a — `requiredDuringSchedulingIgnoredDuringExecution podAntiAffinity: hostname` will force prefill and decode onto different nodes.

---

## Execution

(filled in as we progress)

### 04:14 UTC — R1a v5 applied

Pods landed correctly (prefill `10.1.11.89`, decode `10.1.11.6`, lb `10.1.11.89`).

Mooncake v5 EFA bringup success:
- `EFA device (libfabric): rdmap137s0, domain: rdmap137s0-rdm, provider: efa (shared endpoint, max_wr=256)` ← **PR #1944 SRD shared-endpoint confirmed active in runtime**
- All 16 EFA NICs initialised per prefill/decode pod
- `Started 16 CQ polling worker threads` × 2 pods
- `Clamped max_mr_size to device limit: 206158430208` (192 GiB MR per device)

### 04:14 → 05:11 UTC — Weight load (56 min and counting)

Shard read: 62/62 in 51 s (FSx Lustre @ ~19 GB/s aggregate across 8 TP ranks).

GPU mem now 125-130 GB / rank (~125 GB Kimi-K2 FP8 weights per GPU × 8 = 1 TB, matches 1T parameter count on FP8).

py-spy confirms scheduler_TP is busy in MoE fused_moe_triton weight loader:
```
Thread 2151 (ThreadPoolExecutor-1_0): _load_w13 (moe/fused_moe_triton/layer.py:454)
  ... via _load_model_weight_or_group_weight_scale → _weight_loader_impl
  ... as_completed: do_load_weights (deepseek_common/deepseek_weight_loader.py:361)
```

SGLang MoE weight loader processes **384 experts × (w13, w2) × 8 TP = ~48 k tensors**
serially through a ThreadPoolExecutor; this is the Kimi-K2 1T MoE cold-start cost,
independent of PR #1944 (which only changes KV transport).

Matches Stage 4 experience: 1P:2D Kimi-K2 cold start was also ~30 min.
Expected R1a 1P:1D cold start: ~45-60 min.

### 05:30 UTC — v5 cold start abandoned (2h 15m, stuck)

Deeper py-spy dump at 05:30 shows:
- Scheduler main thread `as_completed` in `do_load_weights` unchanged (same stack as 05:11)
- **ThreadPoolExecutor-1_0 worker thread has disappeared** (was `_load_w13` at 05:11)
- Scheduler %CPU=1750% (17.5 cores) per TP rank × 8 = 140 cores busy spinning
- Total CPU time 1d 13h 40m accumulated across ranks
- No new stdout/stderr for 2h+

This is a deadlock / livelock after PR #1944 on Kimi-K2 weight load path —
Stage 4 on v2 (pre-#1944) cold-started Kimi-K2 1T MoE in ~30 min reliably.
v5 (#1944) stuck at >2h with loader worker gone but main still waiting.

Hypothesis: PR #1944's SRD shared-endpoint refactor interferes with something
in the 1T MoE FP8 loader path. Not reproducible on Qwen3-Next (R0 worked) because
the MoE weight loader path is DeepseekV2-specific (Kimi-K2 / DSv3.1 / DSv4).

### 05:30 UTC — Plan revision: fall back to v2 for R1a baseline

R1a purpose is baseline data collection, not stack bring-up. v2 is Stage-4
validated. Switch R1a back to v2 image; file v5 cold-start issue for Lane K
dedicated investigation (SRD path is Lane K's scope anyway).

Action:
1. `kubectl delete -f r1a-kimi-k2-1p1d-v5.yaml` (done)
2. Re-apply original `r1a-kimi-k2-1p1d.yaml` (points at v2)
3. STAGE5_PLAN Lane K now has a concrete first task: reproduce v5 cold-start
   regression on Kimi-K2 and bisect.

### 06:30 UTC — Correction: v5 cold-start fine, root cause was cross-AZ FSx

py-spy re-analysis: v2 and v5 share byte-identical worker loop source; the
"stuck 2h15m" was FSx Lustre cross-AZ + concurrent 62-shard mmap, not PR #1944.
Symptoms: host iowait 20%, aggregate 1 GB/s (vs Stage-4 local NVMe 8 GB/s).
New memory saved: `feedback_fsx_crossaz_hostpath.md`.

### 06:45-07:45 UTC — NVMe RAID0 setup + failed FSx rsync

1. Setup `/mnt/nvme` RAID0 on both p5en nodes (8 × 3.5 TB → 28 TB xfs each)
   via ad-hoc `setup-nvme.sh` SSM bash. Not ideal — the Ohio cluster's LT
   `lt-0200be32f4401a715 v1` predates the `KevinZhao/eks-cluster-deployment`
   repo's `GPU_ENABLE_LOCAL_LVM=true` feature (which auto-stripes all
   instance-store NVMe to `/data` via a systemd oneshot). Saved as reference
   memory to use on future Spot-GPU spinups.
2. First prefetch attempt: DaemonSet rsync from FSx PVC. Two concurrent
   rsyncs dropped throughput from 593 MB/s → 27 MB/s (FSx OST contention).
   Also hit a false-positive `.prefetch-complete` bug — the FSx source copy
   already contained that sentinel and rsync `-a` carried it over.
3. Tried serial rsync: still 30 MB/s sustained. Projected 16 h for both
   nodes. Abandoned.

### 07:45-08:05 UTC — HF hub parallel prefetch (WORKS)

New manifest: `manifests/stage5-p5en/_prefetch-hf-to-nvme.yaml`
- Indexed Job, completions=2/parallelism=2, topologySpread hostname
- `hf download --max-workers 16` with `HF_HUB_ENABLE_HF_TRANSFER=1`
- Image: sglang-mooncake:v5 (already has `hf` CLI + hf_transfer)
- sentinel `.nvme-prefetch-done` (distinct from FSx's `.prefetch-complete`)

Result: **both nodes complete in 15 min** (~1 GB/s per node, 2 GB/s aggregate).
- pod-0 (node-A 10.1.11.6): 76 files, `.nvme-prefetch-done` ✅
- pod-1 (node-B 10.1.11.89): 76 files, `.nvme-prefetch-done` ✅

vs cross-AZ FSx rsync projection: 16 h → 15 min (64× speedup).

### 08:05 UTC — R1a hostPath v5 applied

Manifest: `manifests/stage5-p5en/r1a-kimi-k2-1p1d-v5-hostpath.yaml`
- Same as v5 yaml except `volumes.models.hostPath: /mnt/nvme/models`
- Expected: Stage-4-parity cold start (~5-7 min weight load)
- If cold start succeeds → v5 PR #1944 is NOT broken, it was FSx all along.
- If cold start still stalls on Kimi-K2 → that's a real v5 regression.

Pods landed:
- prefill: node-A 10.1.11.170
- decode:  node-B 10.1.11.58
- lb:      node-B 10.1.11.77
