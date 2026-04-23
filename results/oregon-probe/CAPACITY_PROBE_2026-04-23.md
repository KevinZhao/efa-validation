# Oregon GPU Spot Capacity Probe — 2026-04-23

**Region**: `us-west-2` (Oregon)
**Cluster**: `gpu-cluster-oregon` (EKS 1.35, ACTIVE)
**Bastion**: `i-081b2b010b6af530c` (`EKS-Deploy-Bastion-gpu-cluster-oregon`)
**Deployment repo**: https://github.com/KevinZhao/eks-cluster-deployment @ `fca8aa6`
**Target**: 4× Spot per instance type, 7-minute window, teardown on fail
**Order**: p6-b300 → p6-b200 → p5en (newest first)

## TL;DR

| Instance Type | Target | Got | Result | Limiting factor |
|---|---|---|---|---|
| **p6-b300.48xlarge** | 4 | 0 | **FAIL** | Script bug: EFA interface count 17 > AWS limit 16 (Network Card 0 requested=1, limit=0) |
| **p6-b200.48xlarge** | 4 | 0 | **FAIL** | Spot `UnfulfillableCapacity` across 2a/b/d (not offered in 2c) |
| **p5en.48xlarge** | 4 | **1** | **PARTIAL** | 1 instance in 2c, remaining 3 hit `UnfulfillableCapacity` across 2b/c/d (not offered in 2a) |

**Bottom line**: Oregon cannot satisfy a 4-node GPU test today. Only 1 p5en slot is available in 2c. Move to Ohio (where 1P:2D is already running) or request ODCR/Capacity Block for reliable 4-node capacity.

## Pre-flight facts

| Item | Value |
|---|---|
| Spot P vCPU quota (us-west-2) | 1152 (= 6 × 192-vCPU instances) |
| OD P vCPU quota | 768 |
| VPC | `vpc-081ea929da61b21d7`, 4-AZ private subnets wired into `.env` |
| p6-b300 availability | **2b only** (single AZ) |
| p6-b200 availability | 2a / 2b / 2d |
| p5en availability | 2b / 2c / 2d |
| Spot price snapshot | p6-b300 $16 · p6-b200 $26–47 · p5en $18–20 |

## Config written to bastion `.env`

```
CLUSTER_NAME=gpu-cluster-oregon
AWS_REGION=us-west-2
VPC_ID=vpc-081ea929da61b21d7
PRIVATE_SUBNET_A=subnet-092ec691f3755574e  # 2a
PRIVATE_SUBNET_B=subnet-0343696171ce4cdc9  # 2b
PRIVATE_SUBNET_C=subnet-012b1f25ae467ab6c  # 2c
PRIVATE_SUBNET_D=subnet-0e4dc6ed86312302f  # 2d
K8S_VERSION=1.35
DEPLOY_GPU_SPOT=true
GPU_NODE_DESIRED_CAPACITY=4
GPU_NODE_MIN_SIZE=0
GPU_NODE_MAX_SIZE=4
GPU_NODE_ROOT_VOLUME_SIZE=200
GPU_NODE_DATA_VOLUME_SIZE=100   # initial 0 failed: gp3 requires ≥1 GiB
INSTALL_EFA_DEVICE_PLUGIN=true
EFA_DEVICE_PLUGIN_VERSION=v0.5.17
```

## Timeline (UTC)

| Time | Event |
|---|---|
| 05:14 | Bastion prep: clone `eks-cluster-deployment`, verify kubectl/jq/aws/python3 present |
| 05:19 | `.env` written, kubeconfig to `gpu-cluster-oregon`, `kubectl get nodes` → 2 eks-utils nodes visible |
| **05:22:05** | **p6-b300 attempt #1** (`GPU_NODE_DATA_VOLUME_SIZE=0`) |
| 05:23:06 | ASG created; immediate failures: `InvalidParameterValue: The volume size is invalid for gp3 volumes: 0 GiB` + `p6-b300 not supported in us-west-2a/c/d` |
| 05:33 | Teardown triggered; fixed `.env` → `DATA_VOLUME_SIZE=100` |
| 05:40:18 | **p6-b200 attempt** (fixed config) |
| 05:40:54 | ASG created; 4× Spot requests fired, all in 2a/b/d |
| 05:48:00 | First `UnfulfillableCapacity` |
| 05:52:05 | Multiple `UnfulfillableCapacity` + `InvalidFleetConfiguration us-west-2c` |
| 05:47–06:04 | 7-min window expired with 0/4; teardown |
| 05:48:17 | **p5en attempt** |
| 05:49:16 | ASG created |
| **05:49:24** | ✅ Got 1 p5en Spot in us-west-2c (`i-00866ece38ff70d64`) |
| 05:53 onwards | Repeated `UnfulfillableCapacity` for remaining 3 across 2b/c/d |
| 05:58 | Stuck at 1/4 after 10 min |
| 06:00:11 | **p6-b300 attempt #2** (with valid data volume) |
| 06:01:17 | ASG fired; new error: `EFA interface count 17 exceeds allowed limit for p6-b300.48xlarge` |
| 06:03:26 | Teardown all 3 nodegroups; p5en-1 auto-recycled |

## Root-cause per instance type

### p6-b300 — FAIL (script bug)
```
AttachmentLimitExceeded - EFA interface count 17 exceeds allowed limit for
p6-b300.48xlarge. Network Card 0 (requested: 1, limit: 0). Launching EC2
instance failed.
```
In `option_install_gpu_nodegroups.sh`:
```bash
p6-b300.48xlarge) echo 16 ;;    # NetworkCardIndex 1-16
```
Script requests 1 primary EFA + 16 EFA-only = 17 NICs, but AWS reports
**Network Card 0 limit = 0** for p6-b300 (primary card doesn't accept an EFA
interface). Correct layout is 16 NICs total on indexes 1–16 with **no** EFA on
index 0, or 15 EFA-only on indexes 1–15. **Needs upstream fix.**

Container capacity itself (2b) was never truly tested because of this bug.

### p6-b200 — FAIL (no Spot capacity today)
```
UnfulfillableCapacity - Unable to fulfill capacity due to your request
configuration. Please adjust your request and try again.
```
7 minutes of retries across 2a/2b/2d yielded 0 instances. Not supported in 2c.
Oregon Spot pool for Blackwell is dry at probe time. (Spot price history shows
active bids at $26–47/hr — healthy market, just no idle supply now.)

### p5en — PARTIAL (1/4)
ASG fired within 8 s of creation, **1 Spot won in 2c**. Subsequent requests for
the remaining 3 all `UnfulfillableCapacity` across 2b/c/d (2a not supported).

Fastest response of the probe: **<10 s** from ASG create to first Spot
`InService`. This is a usable signal — the p5en fabric/plumbing works; only
the pool depth is thin.

## Observations on `option_install_gpu_nodegroups.sh`

| Finding | Impact | Fix |
|---|---|---|
| `GPU_NODE_DATA_VOLUME_SIZE=0` silently generates invalid gp3 LT | Wastes 4–5 min on ASG retries before visible error | Default to `100` or reject `0` in env validation |
| p6-b300 EFA-only count = 16 triggers AWS `AttachmentLimitExceeded` | Blocks p6-b300 entirely | Correct to 15 (or omit primary EFA NIC) |
| Passes **all 4 AZ subnets** to Spot nodegroup regardless of instance-type AZ support | Wastes scaling-activity slots on `InvalidFleetConfiguration` for unsupported AZs | Lookup `ec2 describe-instance-type-offerings` per type, pass only matching subnets |
| `aws eks wait nodegroup-active` blocks shell for 15–30 min even when Spot fails | Harness must background the script and poll ASG instead | Add `--no-wait` flag or drop the wait |

## Next-step options

### Option 1 — Stay in Oregon, accept 1 × p5en
Can smoke-test single-node workflows (model load, single-TP-8 inference), but
cannot demonstrate PD disaggregation (needs ≥2 nodes). Not suitable for the
2P:2D target the user asked for.

### Option 2 — Back to Ohio
Ohio already has 3 p5en running the 1P:2D stack (`DISAGG_1P2D_SWEEP.md`,
`KIMI_K2_RESULTS.md`). No replanning needed.

### Option 3 — ODCR / Capacity Block for Oregon
- ODCR 4× p5en in 2b + 2c: guaranteed capacity at on-demand price ($82/hr ×
  4 = $328/hr).
- Capacity Block: book a 1–14 day window for 4× p6-b200 or p5en.
Either removes Spot pool dependency. Requires 12–48 h lead time.

### Option 4 — Smaller 2P:2D = 4 nodes with AZ-diverse bid
Re-run with `PRIVATE_SUBNET_A/B/C` = only the supported AZs, and
`GPU_INSTANCE_TYPES=p5en.48xlarge,p6-b200.48xlarge` (mixed) so the Spot Fleet
can attempt either. Requires minor script change (script currently creates a
separate nodegroup per type rather than one mixed-type NG).

## Artifacts

- `.env` on bastion: `/home/ec2-user/eks-cluster-deployment/.env`
- Script launch logs on bastion: `/tmp/probe-b300.log`, `/tmp/probe-b200.log`,
  `/tmp/probe-p5en.log`, `/tmp/probe-b300-retry.log`
- All 3 nodegroups torn down as of 06:03:26 UTC
- Single orphan p5en Spot instance (`i-00866ece38ff70d64`) auto-recycled with
  its ASG deletion
- Oregon EKS cluster left in original state (2 eks-utils nodes only)
