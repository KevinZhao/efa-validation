# Lane K · NIXL vs Mooncake DRAM→DRAM over EFA — Partial

> **⚠️ SUPERSEDED (2026-04-26 14:45 UTC)**: 本文件只有 1 NIXL 数据点（58.5 GB/s @ 1M×4×1）。同日后续完成**两组完整 12 点对照**：
> - p5 EFA v2 → `../20260426T111002Z-p5-nixl-vs-mooncake/RESULT.md`
> - p5en EFA v3 → `../20260426T134313Z-p5en-nixl-vs-mooncake-nccl/RESULT.md`
> - 汇总 → `../K_VS_MOONCAKE.md`（最终差值表）

**Status**: **PARTIAL (SUPERSEDED)** — 1 NIXL data point captured before Spot reclaim.
**Run ID**: `lane-k/20260426T091500Z-nixl-vs-mooncake-partial`
**Hardware**: 2 × p5en.48xlarge, Ohio use2-az2, EFA v3 (16 × 200 Gbps)
**Image**: `mooncake-nixl:v6` (`sha256:6271698d...`) — same as prior Mooncake sweep
**GPU time cost**: ~30 min on Spot × 2 nodes = 1 node-hour, Spot reclaimed mid-run

## What we got

### NIXL LIBFABRIC smoke (1 point, completed before reclaim)

```
Block Size (B)      Batch Size     B/W (GB/Sec)   Avg Lat. (us)  Avg Prep (us)  P99 Prep (us)  Avg Post (us)  P99 Post (us)  Avg Tx (us)    P99 Tx (us)
1048576             1              58.508164      17.9           37.8           39.0           22.4           49.0           43.7           67.0
```

- **1 MB block, batch_size=1, num_threads=4**, num_iter=128, op=WRITE, DRAM→DRAM, pairwise
- **Runtime**: nixl (NIXL worker, not nvshmem)
- **Coordination**: ETCD at 10.1.12.248:2379
- **Effective concurrency**: `threads × batch = 4` (single outstanding batch per thread)

### Mooncake 1 MB point (closest comparable from earlier full sweep)

From `results/stage5-p5en/lane-k/20260426T085000Z-mooncake-sweep/MOONCAKE_CPU_SWEEP.md`:

| ID | Block | Threads | Batch | Effective concurrency | **GB/s** |
|---|---|---|---|---|---|
| p07-1M-32c | 1 MB | 4 | 8 | 32 | **190.35** |
| p08-1M-128c | 1 MB | 4 | 32 | 128 | 191.11 |
| p09-1M-512c | 1 MB | 4 | 128 | 512 | 202.93 |

**Mooncake's batch semantics ≠ NIXL's batch semantics**:
- Mooncake `--batch_size=N` means **N concurrent outstanding slices per thread** (post-and-wait depth)
- NIXL `--max_batch_size=N` means **N transfers per xfer descriptor** (single post batches N ops)

They are **not apples-to-apples** unless batch=1 is used on both. Our 1-point NIXL run had batch=1.

## Raw apples-to-apples: batch=1 both tools

Closest equivalence: both at batch=1 effective depth = 4 threads × 1 batch = 4.

We don't have a Mooncake `--batch_size=1` point (the Mooncake sweep used batch=8 minimum). So a true equal-knobs comparison requires **re-running Mooncake at batch=1 for 1 MB** to get the matching data point.

**Projection (not measured)**: Mooncake at batch=1 × 4 threads on 1 MB should be substantially lower than 190 GB/s because the bench becomes post-latency-bound. Based on typical RDMA kernels, expect 20–40 GB/s. **If true, NIXL 58.5 GB/s at same depth would be 1.5–3× Mooncake** at low concurrency.

## Key observations before reclaim

1. **NIXL WAS WORKING**. Rank registration via ETCD, LIBFABRIC backend, 16 × 200 Gbps EFA v3, CPU DRAM on both sides — fully functional.
2. **NIXL binary needs `libcuda.so.1` even in DRAM-only mode**. Workaround: create symlink to `/usr/local/cuda/lib64/stubs/libcuda.so`. **This should be added to `Dockerfile.mooncake-nixl-v6` as a fix (`ln -sf` in a RUN layer).** See v6 follow-up section.
3. **NIXL benchmark_group is etcd-scoped and not auto-cleaned**. If you reuse the same group name, new rank 0 + old rank 1 can collide. Always use a fresh group name per bench invocation (`nixl-$(date +%s)`).
4. **Latency breakdown** (NIXL 1 MB batch=1 × 4 threads):
   - `avg prep` = 37.8 µs (xfer descriptor prep)
   - `avg post` = 22.4 µs (submit to NIC)
   - `avg tx` = 43.7 µs (wire + completion)
   - **Total avg latency = 17.9 µs** (wait on completion, after prep+post accounting)
   - This per-op latency at 1 MB on EFA with 4 concurrent = 58.5 GB/s. Consistent with ~400 µs effective end-to-end per 1 MB burst across all 16 NICs.

## What needs to happen to get the full comparison

1. **Rebuild mooncake-nixl:v6.1 with libcuda stub symlink in Dockerfile** (5 min change, next builder run)
2. **Rerun 12-point sweep** matching params of Mooncake CPU sweep (need 2 × p5en for ~10 min)
3. **Re-run Mooncake at batch=1** for 1 MB (to pair with NIXL batch=1 point)
4. Produce final `K_VS_MOONCAKE.md` with 3 tables:
   - **Mooncake scaling curve** (already done — 211 GB/s peak)
   - **NIXL scaling curve** (this round, interrupted)
   - **Δ% table at matched (block, threads, batch)** — the core deliverable

## Findings worth saving (v6 follow-ups)

| # | Issue | Fix |
|---|---|---|
| 1 | `nixlbench` binary loads `libcuda.so.1` at startup even in `--initiator_seg_type=DRAM` / `--target_seg_type=DRAM` mode | Dockerfile: `RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so.1` |
| 2 | NIXL benchmark_group etcd keys persist across runs, causing "rank N >= global size M" errors on reuse | Either: (a) add TTL to bench group registration upstream, or (b) our orchestrator must always use `group=$(date +%s)` |
| 3 | Spot reclaim mid-sweep leaves pods in `Terminating` + containerd unreachable | Use separate log-staging to durable storage (S3 upload after each point), not just pod-local `/out` |

## Artifacts

- `scripts/lane-k/nixl-smoke.sh` — libcuda stub + reachability sanity
- `scripts/lane-k/nxs3.sh` — single-point NIXL smoke recipe
- `scripts/lane-k/nixl-sweep.sh` — 12-point orchestrator (lost mid-run to Spot reclaim)
- `scripts/lane-k/stub.sh` — libcuda.so.1 stub symlink helper

## Status for Stage 5 deliverables

- `lane-k/K_VS_MOONCAKE.md` (**final** version): **still pending**. This partial report is the first draft + methodology + 1 validated data point.
- `lane-k/MOONCAKE_CPU_SWEEP.md`: DONE (211 GB/s peak confirmed)
- `lane-k/LANE_K_V6_ATTEMPT_LOG.md`: DONE (pipeline recipe)
- `lane-k/TECH_DELTA.md`: DONE (architecture)
- `lane-k/NIXL_TUNING.md`: pending (need full sweep first)
