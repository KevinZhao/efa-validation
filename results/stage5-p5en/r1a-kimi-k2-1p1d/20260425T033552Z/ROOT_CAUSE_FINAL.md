# R1a cold-start root cause (corrected analysis)

## TL;DR

**Not Mooncake PR #1944.** The bottleneck is **FSx Lustre cross-AZ mmap
I/O** during SGLang's multi-process safetensors weight load.

Stage 4 Kimi-K2 cold-started in ~5 min because weights were on **local NVMe
RAID0**. R1a loads from **FSx (us-east-2b) across AZ to GPU in us-east-2a**,
and 8 TP ranks simultaneously mmap-read 62 shards × 125 GB/rank. FSx bandwidth
is fine in isolation (428 MB/s seq, 577 MB/s warm, 752 MB/s random 1MB),
but the mmap pattern × 8 concurrent processes × cross-AZ RTT produces a
much slower aggregate.

## Evidence

### host top (prefill node at 18 min into R1a v5 run)
```
load average: 211.30, 208.48, 175.60      ← load avg 211 on 192 cores
%Cpu(s): 41.2 us, 34.9 sy, 3.4 id, 20.5 wa ← 20.5% iowait (Lustre blocking)
PID     USER    %CPU    TIME
163126  root    1630%   369 min   sglang::schedul_TP0
163127  root    1630%   368 min   sglang::schedul_TP1
... (8 TP ranks all at ~1625%)
```

- **20.5% iowait** is the smoking gun. CPU is not 100% Mooncake spin —
  it's waiting on FSx reads.
- 8 TP ranks × ~1625% = ~130 cores busy
- Per-rank `%CPU=1625%` breakdown is roughly:
  - 16 CQ poll threads (Mooncake) — spin yield, each ~100%
  - N `_load_w13`/`_load_w2` worker threads that actually run when Python can
  - Lustre client threads doing RDMA-over-TCP read

### FSx raw bandwidth (healthy)
From `dd`/Python on the same FSx mount inside the prefill pod:
- Sequential cold read 500 MB: **428 MB/s**
- Sequential warm read 500 MB: 577 MB/s
- 200 × 1 MB random seek: **752 MB/s**

These numbers are fine for single-threaded. FSx isn't the issue in isolation.

### Pattern mismatch: safetensors mmap + 8 concurrent TP ranks

SGLang's model loader (`deepseek_common/deepseek_weight_loader.py`):
1. All 8 TP ranks open all 62 shards via HF `safetensors` (which uses mmap)
2. Each rank's `_load_w13`/`_load_w2` reads slices belonging to its TP partition
3. Page fault → Lustre client fetches 1 MB chunks on demand
4. 8 × 62 = 496 concurrent file handles, each page-faulting

Lustre cross-AZ with RDMA-over-TCP and ~2-3 ms RTT penalty makes each page
fault ~10× slower than local NVMe. FSx bandwidth is 1.3 GB/s per TiB baseline
(which we have; ~3 GB/s burst), but with 8 concurrent demand-pagers and
shared lock contention (OST locking per stripe), effective throughput
collapses.

### Network evidence
```
enp71s0:  Rx 1.09 TB, Tx 75 GB  (prefill pod's single ENI)
```
1.1 TB received over ~18 min = **1 GB/s average** — matches the low end of
expected FSx aggregate. Stage 4 saw **~8 GB/s** from NVMe (125 GB / 15 s).

### Why the previous diagnosis was wrong

v2 vs v5 Mooncake `.so` diff:
- PR #1944 adds shared-endpoint symbols but behaviour is `load_model`-unrelated
- Worker loop in `efa_transport.cpp` is **byte-identical** v2 vs v5 (same
  `std::this_thread::yield()` on empty poll)
- CPU 140-core spinning happens on BOTH v2 and v5 in disaggregation mode
  (16 NICs × poll thread per NIC)

The symptom is the same on both — the actual difference: v2 on local NVMe
finishes fast enough that the CPU spinning is not a long-term problem;
v5 on cross-AZ FSx takes hours to finish weight load so spinning becomes
visible as "CPU starvation".

Root cause is the I/O path, not the Mooncake version.

## Recommended fixes

### A. Move FSx to the same AZ as the GPU NG (best long-term)
- Current: FSx in us-east-2b, GPU NG in us-east-2a → cross-AZ
- Option 1: Create a new FSx in us-east-2a; repoint PVC
- Option 2: Move GPU NG subnet to us-east-2b (change NG subnet list)
  - Caveat: us-east-2b may not have Kimi-K2 SPS capacity
- Cost: one-time re-prefetch (~2 h for 3.4 TB) if rebuilding FSx

### B. Pre-hydrate Lustre client cache before R1a (quick workaround)
- Before apply R1a pod, run a "cat > /dev/null" pass over all Kimi-K2
  shards from the target p5en node, sequentially
- This warms the Linux page cache on the GPU node — subsequent SGLang load
  hits page cache instead of triggering Lustre fetches
- Cost: +5 min before each run; per-node (not shared across pods)

### C. Tune Lustre client stripe readahead
- `lctl set_param llite.*.max_read_ahead_mb=4096`
- Default is 64 MB per OST; at 8 TP × 62 shards with 4 MB chunks this is
  too small
- Applied per-mount, affects all pods on the node

### D. Fall back to hostPath NVMe for R1 series (matches Stage 4)
- Use the prefetch Spot instance pattern from Stage 4 to put Kimi-K2 on
  each p5en's local 30 TB NVMe RAID0 before the pod starts
- This is what Stage 4 did. Gives ~5 min cold start.
- Cost: per-node prefetch (~2 min for 959 GB over HF API or FSx→local copy)

### Recommendation

For R1 series (Kimi-K2 / DSv3.1): **option D (hostPath NVMe)**. FSx's value
proposition was "share model once, all nodes use it" but the load path
doesn't amortise cost across pods — it re-reads per TP process per pod.
NVMe RAID0 on p5en is 30 TB free and the prefetch Spot instance already
exists.

For Lane K / bench runs: FSx is fine (single short reads), keep PVC.

## Action plan

1. Abandon current R1a v5 run (it will eventually finish but at high cost)
2. Copy Kimi-K2 from FSx to local NVMe on both p5en nodes (~5 min/node)
3. Modify R1a manifest to use hostPath `/mnt/nvme/models/Kimi-K2-*` instead of PVC
4. Re-apply R1a — expect ~5-7 min cold start (Stage 4 parity)

Image stays v5 (PR #1944 is fine; we keep SRD shared-endpoint benefits).
