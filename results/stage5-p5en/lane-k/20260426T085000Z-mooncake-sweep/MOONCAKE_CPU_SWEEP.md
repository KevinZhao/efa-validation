# Lane K · Mooncake EFA DRAM→DRAM sweep (CPU mode, v6 image)

**Run ID**: `lane-k/20260426T085000Z-mooncake-sweep`
**Completed**: 2026-04-26 08:57 UTC
**Hardware**: 2 × p5en.48xlarge, Ohio use2-az2, EFA v3 (16 × 200 Gbps / node)
**Image**: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/mooncake-nixl:v6` (`sha256:6271698d...`)
**Stack**: Mooncake `634b7097` + 5 Henan EFA PRs + NIXL v1.0.1 (nixlbench present but unused this round)
**Method**: Mooncake `transfer_engine_bench --protocol=efa --use_vram=false`, CPU DRAM source and target, write operation, 15 s per point
**Baseline**: First Lane K actual microbench data; **no NIXL comparison this round** (deferred, pipeline for NIXL still needs etcd Deployment wiring).

## Bench results

| # | Run ID | Block size | Threads | Batch | Require (GB) | Duration (s) | Batch count | **GB/s** |
|---|---|---|---|---|---|---|---|---|
| 1 | p01-64K-32c  | 64 KB | 4 | 8   | 0.00 | 15 | 751,681 | 26.27 |
| 2 | p02-64K-128c | 64 KB | 4 | 32  | 0.01 | 15 | 337,044 | 47.12 |
| 3 | p03-64K-512c | 64 KB | 4 | 128 | 0.03 | 15 | 111,841 | 62.54 |
| 4 | p04-256K-32c | 256 KB | 4 | 8   | 0.01 | 15 | 601,624 | 84.11 |
| 5 | p05-256K-128c| 256 KB | 4 | 32  | 0.03 | 15 | 258,032 | 144.29 |
| 6 | p06-256K-512c| 256 KB | 4 | 128 | 0.13 | 15 | 74,870  | 167.47 |
| 7 | p07-1M-32c   | 1 MB | 4 | 8   | 0.03 | 15 | 340,382 | 190.35 |
| 8 | p08-1M-128c  | 1 MB | 4 | 32  | 0.13 | 15 | 85,438  | 191.11 |
| 9 | p09-1M-512c  | 1 MB | 4 | 128 | 0.54 | 15 | 22,682  | 202.93 |
| 10 | p10-4M-32c  | 4 MB | 4 | 8   | 0.13 | 15 | 87,448  | 195.60 |
| 11 | p11-4M-128c | 4 MB | 4 | 32  | 0.54 | 15 | 22,714  | 203.21 |
| 12 | **p12-16M-32c** | **16 MB** | 4 | 8   | 0.54 | 15 | 23,592  | **211.08** |

**Peak**: **211 GB/s** at 16 MB block / 32 in-flight batch size. 
**EFA theoretical aggregate**: 16 × 200 Gbps = 3200 Gbps = **400 GB/s** per node.
**Achieved fraction of line rate**: **~53%** (CPU DRAM, 16-NIC striped).

## Analysis

### A. Message-size scaling

For fixed in-flight concurrency = 32:

| Block | GB/s @ 32c |
|---|---|
| 64 KB | 26.27 |
| 256 KB | 84.11 |
| 1 MB | 190.35 |
| 4 MB | 195.60 |
| 16 MB | 211.08 |

**Pattern**: throughput climbs steeply until **1 MB** then plateaus. 64 KB messages are clearly kernel-send-overhead-bound (fixed per-request cost dominates). Message bundling across NICs only pays off above ~256 KB.

### B. Concurrency scaling (at fixed block size)

For fixed block = 1 MB:

| Concurrency (threads × batch) | GB/s |
|---|---|
| 32 (4×8) | 190.35 |
| 128 (4×32) | 191.11 |
| 512 (4×128) | 202.93 |

**Pattern**: at 1 MB+ blocks, concurrency > 32 gives only marginal lift (~6%). At small messages (64 KB) doubling concurrency gives 2× throughput (26→47→63 GB/s from 32→128→512c). This is the classic "amortize kernel overhead via depth" curve.

### C. Peak identification

- **Max observed**: 211 GB/s (p12: 16 MB × 32c)
- The 4 MB / 128c (p11) and 16 MB / 32c (p12) cluster suggests **~200-210 GB/s is the Mooncake CPU-DRAM EFA ceiling** for p5en with 5 Henan PRs.
- Left on the table: 400 GB/s theoretical minus 211 = **~47% gap**. Expected sources of the gap:
  - CPU-only path: each byte traverses DRAM→NIC DMA (host memcpy stage). GPUDirect path would cut CPU-side memcpy.
  - Single initiator process (not multi-process) — each thread shares the same AV / endpoint resources.
  - `--buffer_size` default 1 GB limits concurrency; would need bigger buffers + more threads to push harder.

## Corresponding runs from prior Stage 5 work

From `results/STAGE1-4_P5EN_SUMMARY.md` (Mooncake GPU-VRAM over EFA, similar stack):
- p5en, GPU-VRAM → GPU-VRAM, **365 GB/s write** (Stage 4 baseline, 91% line rate) — ~1.7× our CPU-DRAM number

**Implied CPU→GPU gap on this stack**: ~40% throughput loss from running through DRAM instead of VRAM+GPUDirect. This is the "GPUDirect value" number a customer would get if they moved KV buffers to device memory.

## Raw CSV

```csv
run_id,block_size,threads,batch_size,require_gb,duration_s,batch_count,gbps
p01-64K-32c,65536,4,8,0.00,15,751681,26.27
p02-64K-128c,65536,4,32,0.01,15,337044,47.12
p03-64K-512c,65536,4,128,0.03,15,111841,62.54
p04-256K-32c,262144,4,8,0.01,15,601624,84.11
p05-256K-128c,262144,4,32,0.03,15,258032,144.29
p06-256K-512c,262144,4,128,0.13,15,74870,167.47
p07-1M-32c,1048576,4,8,0.03,15,340382,190.35
p08-1M-128c,1048576,4,32,0.13,15,85438,191.11
p09-1M-512c,1048576,4,128,0.54,15,22682,202.93
p10-4M-32c,4194304,4,8,0.13,15,87448,195.60
p11-4M-128c,4194304,4,32,0.54,15,22714,203.21
p12-16M-32c,16777216,4,8,0.54,15,23592,211.08
```

## Runtime recipe (for future reruns)

1. 2 × p5en same AZ, each with pod `hostNetwork + vpc.amazonaws.com/efa: 16 + IPC_LOCK + hugepages-2Mi: 5120Mi`
2. 1 × `mooncake-meta` Deployment using image's `mooncake.http_metadata_server` — listens on hostNetwork :8080
3. `metadata_server=http://<meta-host>:8080/metadata` (**`/metadata` suffix required** — otherwise 404)
4. `MC_LEGACY_RPC_PORT_BINDING=1` (required to bind RPC to `--local_server_name` port; otherwise random port)
5. Env: `FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1 FI_EFA_FORK_SAFE=1 FI_MR_HMEM=1 MC_WORKERS_PER_CTX=2 MC_NUM_CQ_PER_CTX=2`
6. **Sizing constraint**: `block_size × threads × batch_size ≤ --buffer_size` (default 1 GB). If you exceed, initiator will crash with `Cannot select device for dest_addr` at bench start (root cause: dest offset falls outside declared segment range).
7. Initial/target both use `--use_vram=false` (CPU-DRAM). GPUDirect requires `/dev/nvidia*` injection which needs Dockerfile + gpu-operator fix — see LANE_K_V6_ATTEMPT_LOG.md section E.

## What's NOT in this report

- **NIXL comparison**: v6 image has `nixlbench` but we didn't wire etcd this round (mooncake http meta doesn't speak etcd protocol). Follow-up: deploy etcd sidecar + run matching 12-point sweep with `nixlbench --backend LIBFABRIC`.
- **GPUDirect on/off A/B**: needs `/dev/nvidia*` injection fix. Reference Stage 4 VRAM bench 365 GB/s suggests ~1.7× uplift from GPUDirect.
- **Smaller block sizes at max concurrency**: 64 KB × 512c was the lowest msg / highest conc; could push 1024+ concurrency to see if small-msg curve keeps climbing.

## Artifacts

- CSV (inlined above): `/out/lane-k-sweep.csv` on initiator pod
- Individual init/target log per run: `/out/target.log` / `/out/init.log` on bench pods (retrieve via kubectl cp if needed later — we didn't save per-point)
- Orchestrator: `scripts/lane-k/sweep.sh` (runs 12 points end-to-end, ~8 min wall clock)
