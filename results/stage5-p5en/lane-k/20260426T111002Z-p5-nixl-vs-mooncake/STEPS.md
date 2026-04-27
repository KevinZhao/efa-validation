# Lane K NIXL vs Mooncake — Oregon p5.48xlarge 12-point sweep

**Run ID**: `lane-k/20260426T111002Z-p5-nixl-vs-mooncake`
**Reason**: p5en tc=2 SPS=1 across Ohio/Oregon/N.Va on 2026-04-26 11 UTC;
p5.48xlarge tc=2 SPS=9 in usw2-az1/az2/az3. EFA v2 (32×100G) → same 3200
Gbps line rate as p5en EFA v3 (16×200G); different NIC count/topology.
**Hardware**: 2 × p5.48xlarge (H100 80G × 8, 32 × 100 Gbps EFA v2)
**Cluster**: gpu-cluster-oregon (us-west-2)
**Bastion**: i-081b2b010b6af530c (10.0.11.203)
**Image**: mooncake-nixl:v6.1 (`sha256:0970bdb3...227f2`, Oregon ECR)

## Timeline

| Time (UTC) | Action | Result |
|---|---|---|
| 11:12 | `aws eks update-nodegroup-config gpu-p5-48xlarge-spot desired=2` | 2 nodes launched in **us-west-2a + us-west-2b** — cross AZ, violates hard rule |
| 11:15 | Scale to 0 → pin ASG VPCZoneIdentifier to `subnet-012b1f25ae467ab6c` (us-west-2c) → re-scale to 2 | 2 new nodes in us-west-2c at 11:23 |
| 11:27 | Apply `etcd-for-nixlbench.yaml` + `mooncake-http-metadata-oregon-p5.yaml` + `lane-k-bench-pods-oregon-p5.yaml` on Oregon cluster via SSM→bastion (manifests staged to S3) | etcd, mooncake-meta, bench pods all landed on the 2 p5 nodes |
| 11:30 | Image pull (v6.1, 8.67 GB) | target Ready at 11:29, initiator Ready at 11:31 |
| 11:32 | Preflight: `fi_info -p efa` = 96 domain lines (32 NIC × 3 providers); `nixlbench --help` loads OK; mooncake bench sentinel present; `/dev/nvidia0..` visible | ALL GREEN |
| 11:35 | Smoke: 16M × 4 × 8 → **46.25 GB/s**, 1-GB chunks registered on 32 NICs in ~1.3 s | OK |
| 11:36 | Launch Mooncake 12-point sweep (`bash sweep-mooncake-cpu.sh`) | |
| 11:46 | Mooncake sweep DONE — 12 points captured, peak 61.12 GB/s at 256K × 4 × 32 | |
| 11:47 | Launch NIXL v1 sweep (wrong parse regex + 28s dwell → all rows empty, 0/12 captured) | FAILED — parse bug |
| 11:54 | Debug: read full nxt.log from `lane-k-target`; realized target pod is NIXL rank 0 = "initiator" in NIXL semantics (reports data); rewrote v2 script with per-point log files, 45-80s dwells, correct pod → rank mapping | |
| 11:55 | Launch NIXL v2 sweep (`bash nixl-manual-v2.sh`) | |
| 12:06 | NIXL v2 sweep DONE — 12 points captured, peak 75.24 GB/s at 4M × 4 × 32 | |
| 12:08 | `kubectl delete` all workload; `aws autoscaling set-desired-capacity=0` on ASG (EKS NG update failed due to stale node health, worked around via ASG direct) | Scale-in initiated |

## Preflight results (11:32 UTC)

- `fi_info -p efa` domain count = 96 → 32 × 3 providers = **32 EFA NICs visible** ✓
- `/opt/nixl/bin/nixlbench --help` loads (libcuda stub from v6.1 works) ✓
- `head -3 transfer_engine_bench.cpp` → `// v6 patch: skip cuda* when --use_vram=false` ✓
- `ls /dev/nvidia*` → nvidia0, nvidia1, nvidia-modeset, nvidia-uvm, nvidia-uvm-tools ✓
- `curl http://10.0.13.65:8080/metadata?key=x` → 200-range OK (reachable via host-network IP)
- `curl http://10.0.13.225:2379/version` → etcd reachable

## Observed topology

- **Target** pod on node `ip-10-0-13-65` (us-west-2c), NIC `rdmap183s0`/`rdmap184s0`/..., "Started 32 CQ polling worker threads"
- **Initiator** pod on node `ip-10-0-13-103` (us-west-2c), both in same AZ (hostname-level anti-affinity enforced)
- mooncake-meta and etcd colocated on 10.0.13.65 (Service selector)

## Files

- `manifests/lane-k/oregon-p5/lane-k-bench-pods-oregon-p5.yaml` — target + initiator, zone placeholder
- `manifests/lane-k/oregon-p5/mooncake-http-metadata-oregon-p5.yaml` — Mooncake http meta, zone placeholder
- `manifests/lane-k/etcd-for-nixlbench.yaml` — shared (no zone pin)
- `scripts/lane-k/sweep-mooncake-cpu.sh` — Mooncake orchestrator (12 points)
- `scripts/lane-k/nixl-sweep.sh` — NIXL orchestrator (12 points)

## Diff vs Ohio p5en sweep (2026-04-26 08:50 UTC)

| Attribute | Ohio p5en (prior) | Oregon p5 (this run) |
|---|---|---|
| GPU | H200 141G × 8 | H100 80G × 8 |
| EFA | 16 × 200 Gbps v3 | 32 × 100 Gbps v2 |
| Theoretical line rate | 3200 Gbps = 400 GB/s | 3200 Gbps = 400 GB/s |
| Image | v6 | v6.1 (libcuda stub baked) |
| MC_LEGACY_RPC_PORT_BINDING | 1 | 1 (pre-set in env) |
| Mooncake peak (CPU-DRAM, prior) | 211 GB/s (53% line) | **61.12 GB/s** @ 256K × 4 × 32 (~15% of line) |
| NIXL LIBFABRIC (prior) | 58.5 GB/s (1M batch=1) | **75.24 GB/s** @ 4M × 4 × 32 |
| NIXL complete 12-point sweep | PARTIAL (1 point, Spot reclaim) | **DONE (12 points)** |
