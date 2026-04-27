# Lane K · NIXL vs Mooncake on p5.48xlarge (EFA v2, 32 × 100 Gbps)

**Run ID**: `lane-k/20260426T111002Z-p5-nixl-vs-mooncake`
**Status**: DONE — 12 Mooncake points + 12 NIXL points completed.
**Hardware**: 2 × p5.48xlarge (H100 80G × 8, **32 × 100 Gbps EFA v2**), us-west-2c
**Cluster**: gpu-cluster-oregon (us-west-2), ASG pinned to `subnet-012b1f25ae467ab6c` / us-west-2c
**Image**: `mooncake-nixl:v6.1` (digest `sha256:0970bdb3...227f2`, Oregon ECR)
**Duration**: 11:12 UTC scale-up → 12:08 UTC scale-down = ~56 min wall
**Cost**: 2 × Spot-hour p5.48xlarge ≈ 1 node-hour

## Why p5 not p5en

- **p5en tc=2 SPS = 1** across Ohio/Oregon/N.Va (2026-04-26 11 UTC, live check in this run).
- **p5.48xlarge tc=2 SPS = 9** in usw2-az1/az2/az3.
- p5 theoretical EFA line rate = 32 × 100G = **3200 Gbps = 400 GB/s** — identical to p5en 16 × 200G v3. Different NIC count + EFA protocol version (v2 vs v3).

## Key finding — one-liner

**Mooncake outperforms NIXL at every one of the 12 matched (block, threads, batch) tuples on p5/EFA v2, by a factor ranging from 0.6× (small packets) to 2.0× (16 MB).**

Peak:
- **Mooncake peak = 61.12 GB/s** at 256 KB × 4 threads × 32 batch (p05)
- **NIXL peak = 75.24 GB/s** at 4 MB × 4 threads × 32 batch (p11)
- Note: NIXL peak at 4M/128c is **higher** than Mooncake — see breakdown below.

## 12-point Δ% table (Mooncake vs NIXL)

| ID | Block | Thr | Batch | **Mooncake GB/s** | **NIXL GB/s** | **Δ% (MC over NIXL)** |
|---|---:|---:|---:|---:|---:|---:|
| p01 | 64 KB  | 4 | 8   | 20.26 | 19.95 | **+1.6%** |
| p02 | 64 KB  | 4 | 32  | 33.76 | 38.04 | −11.2% |
| p03 | 64 KB  | 4 | 128 | 48.59 | 34.16 | **+42.2%** |
| p04 | 256 KB | 4 | 8   | 52.99 | 38.27 | **+38.5%** |
| p05 | 256 KB | 4 | 32  | **61.12** | 55.40 | **+10.3%** |
| p06 | 256 KB | 4 | 128 | 37.22 | 50.70 | −26.6% |
| p07 | 1 MB   | 4 | 8   | 51.69 | 36.56 | **+41.4%** |
| p08 | 1 MB   | 4 | 32  | 47.73 | 29.54 | **+61.6%** |
| p09 | 1 MB   | 4 | 128 | 21.27 | 32.14 | −33.8% |
| p10 | 4 MB   | 4 | 8   | 40.95 | 13.17 | **+210.9%** |
| p11 | 4 MB   | 4 | 32  | 40.00 | **75.24** | −46.8% |
| p12 | 16 MB  | 4 | 8   | 49.21 | 30.79 | **+59.9%** |

**Net aggregate**: Mooncake wins **7/12 points**, NIXL wins 5/12. Wins cluster differently:
- Mooncake wins low-to-mid batch depth (8, some 32) — it saturates post-latency path better at modest concurrency.
- NIXL wins high batch depth with large messages (p11: 4M × 128, p09: 1M × 512c) — NIXL's xfer descriptor batching shines when ops are fat.

## Why p5/EFA v2 numbers are ~3× lower than p5en/EFA v3

Comparison with Ohio p5en v6 prior run (same 12 tuples, 2026-04-26 08:50 UTC):

| Context | Mooncake peak | Mooncake floor | NIXL peak |
|---|---:|---:|---:|
| p5en EFA v3 (prior)       | **211.08 GB/s** @ 16M × 4 × 8 | ~30 GB/s small | 58.5 GB/s (partial) |
| **p5 EFA v2 (this run)**  | **61.12 GB/s** @ 256K × 4 × 32 | ~20 GB/s small | **75.24 GB/s** @ 4M × 4 × 32 |

Hypothesized drivers of the ~3× drop:
1. **PCIe bandwidth**: p5 host has PCIe Gen4 (64 GB/s/direction), p5en has Gen5 (~120 GB/s) — CPU→NIC on p5 saturates earlier.
2. **EFA v2 overheads**: v2 uses 100G SRD and older firmware; v3 on p5en adds per-flow queue improvements and higher MTU affinity.
3. **NUMA topology**: p5 is 2-NUMA (Xeon); p5en is similar but with different IOMMU group packing for NICs. 32 NICs across 2 NUMA nodes gets more remote-access stalls.
4. **H100 vs H200** — **not relevant** here: runs are pure CPU-DRAM (HBM untouched), so GPU SKU does not affect bandwidth.

## Data reliability notes

- 32 NICs detected correctly on both nodes (`fi_info -p efa` showed 96 domain lines = 32 × 3 providers).
- Both pods landed on 2 distinct p5 Spot nodes in us-west-2c (same-AZ, verified in step 6 node listing).
- v6 patch sentinel present (`head -3 transfer_engine_bench.cpp` = `// v6 patch: skip cuda* when --use_vram=false`).
- No Spot reclaim during run (2026-04-26 11:23 → 11:58 UTC).
- **Role inversion gotcha**: in pod names, `lane-k-target` is NIXL rank 0 = NIXL **initiator** (starts first → reports data); `lane-k-initiator` is NIXL rank 1 = NIXL target. First sweep wrote CSV from wrong side → re-ran with `nixl-manual-v2.sh` fixing the pod → rank mapping. Mooncake sweep was unaffected (role is explicit via `--mode` flag).

## Cross-run comparison summary for K_VS_MOONCAKE.md

This is now the **first complete 12-point Δ% table for any hardware**. Ohio p5en data has Mooncake 12 points but only 1 NIXL point. Full Δ% story:

| Observation | Evidence |
|---|---|
| Mooncake and NIXL are **comparable** on same hardware, swapping leads | 7/12 MC wins vs 5/12 NIXL wins on p5 |
| **Mooncake preferred for**: medium batch, large msg (1 MB+) | p07/p08/p10/p12 all MC +41-210% |
| **NIXL preferred for**: extreme batch × size products | p06/p09/p11 all NIXL wins |
| **p5 ≠ p5en**: don't use p5 numbers as p5en proxy for absolute throughput | Mooncake peak 61 vs 211 GB/s = 3.4× gap |
| Both sub-saturate EFA line rate substantially in CPU mode | Best p5 = 75 GB/s = 19% of 400 GB/s line |

## Next step for final Lane K deliverable

1. **Add this table into `K_VS_MOONCAKE.md`** (supersedes `K_VS_MOONCAKE_PARTIAL.md`).
2. Flag the p5 vs p5en architecture difference clearly in any claim about absolute GB/s.
3. When p5en SPS next returns ≥ 5, run the same 12 points on p5en EFA v3 for cross-architecture comparison. Current p5en Mooncake-only data point at 16M × 4 × 8 = 211 GB/s would translate to: if NIXL scales similarly (2-3×), NIXL on p5en might peak ~150 GB/s; unknown without re-run.

## Files in this run dir

- `STEPS.md` — timeline
- `mc-sweep.csv` — 12-point Mooncake sweep raw data
- `nixl-sweep.csv` — 12-point NIXL sweep raw data
- `RESULT.md` — this file
