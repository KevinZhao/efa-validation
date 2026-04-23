# EKS GPU Nodegroup Inventory — 2026-04-23

Pre-built nodegroups across Ohio + Oregon, all `desiredSize=0` to avoid costs
until needed. Structure is "one multi-AZ NG per instance type per region",
except for single-AZ instance types (p6-b300) which are locked to their only
available AZ.

## Oregon (us-west-2)  — cluster `gpu-cluster-oregon`

| NG name | Instance type | AZs | Status | Scaling | Notes |
|---|---|---|---|---|---|
| `gpu-p5-48xlarge-spot` | p5.48xlarge | 4 (a/b/c/d) | ACTIVE | 0/0/4 | H100, widest Spot pool (score=9 @ T=2) |
| `gpu-p5en-48xlarge-spot` | p5en.48xlarge | 4 (a/b/c/d; 2a not offered, auto-filtered) | ACTIVE | 0/0/4 | H200, score=9 @ T=2 |
| `gpu-p6-b200-48xlarge-spot` | p6-b200.48xlarge | 4 (a/b/c/d; 2c not offered) | CREATING | 0/0/4 | B200, Spot tight (score=1 @ T=2) |
| `gpu-p6-b300-48xlarge-spot` | p6-b300.48xlarge | 4 (a/b/c/d; only 2b offered) | ACTIVE | 0/0/4 | B300, single-AZ reality, score=6 @ T=2 |

Subnets in `.env` on bastion:
- A: `subnet-092ec691f3755574e` (us-west-2a)
- B: `subnet-0343696171ce4cdc9` (us-west-2b)
- C: `subnet-012b1f25ae467ab6c` (us-west-2c)
- D: `subnet-0e4dc6ed86312302f` (us-west-2d)

## Ohio (us-east-2)  — cluster `gpu-cluster-ohio`

| NG name | Instance type | AZs | Status | Scaling | Notes |
|---|---|---|---|---|---|
| `gpu-p5-48xlarge-spot` | p5.48xlarge | 1 (2b) | ACTIVE | 0/0/4 | Pre-existing, single-AZ, score=2 @ T=2 |
| `gpu-p5en-spot-useast2a` | p5en.48xlarge | 1 (2a) | ACTIVE | 0/0/4 | Pre-existing daily-driver, single-AZ |
| `gpu-p6-b200-48xlarge-spot` | p6-b200.48xlarge | 3 (a/b/c) | CREATING | 0/0/4 | New, multi-AZ; score=1 @ T=2 |

Subnets in `.env` on bastion:
- A: `subnet-06b9c08e3273826ca` (us-east-2a)
- B: `subnet-0c86f1c69e4067890` (us-east-2b)
- C: `subnet-03eb558ae0bb03b24` (us-east-2c)

Note: `gpu-p5-48xlarge-spot` and `gpu-p5en-spot-useast2a` are older
single-AZ NGs retained as-is. They can be deleted and recreated as multi-AZ
later if Spot hit rate becomes a problem.

## How to scale up for a test

```bash
# Example: 2 p6-b300 nodes in Oregon for Stage 0
aws eks update-nodegroup-config \
  --cluster-name gpu-cluster-oregon \
  --nodegroup-name gpu-p6-b300-48xlarge-spot \
  --region us-west-2 \
  --scaling-config minSize=0,maxSize=4,desiredSize=2
```

## How to scale down

```bash
aws eks update-nodegroup-config ... --scaling-config desiredSize=0
```

## Cost

| Resource | Monthly cost |
|---|---|
| NG metadata (all 7 nodegroups) | $0 |
| ASG (desired=0) | $0 |
| Launch templates | $0 |
| IAM roles + SGs | $0 |
| **Total static cost** | **$0** |

Plus EKS control plane `$0.10/hr × 2 clusters × 720h = $144/month` (unchanged
regardless of NG count — billed by cluster, not by NG).

## Risk: AMI drift

LTs lock a specific GPU AMI at creation time. If a NG sits unused for 2–3
months, the pinned AMI can fall behind on EKS / NVIDIA driver updates and
break pod bootstrap when finally scaled up. Mitigation:

```bash
aws eks update-nodegroup-version \
  --cluster-name <cluster> \
  --nodegroup-name <ng> \
  --region <region>
```
This re-bakes the NG with the latest EKS optimized GPU AMI in ~30s. Run
monthly or right before scaling up.

## Known issues (at creation time)

- `gpu-p6-b200-48xlarge-spot` in both regions was in `CREATING` state for
  15+ minutes at inventory time. EKS control plane is slow on p6-b200 NG
  creation but will eventually settle to ACTIVE without errors.
- `eks-cluster-deployment` PR #1 fix (p6-b300 NIC 0 = interface not efa)
  is applied on both bastions via merged master.

## Validation

All NGs created via `scripts/option_install_gpu_nodegroups.sh` from
`KevinZhao/eks-cluster-deployment@master`, so the same LT / userdata /
IAM / EFA configuration is consistent across regions. Spot capacity
tested as of 2026-04-23:

- Oregon p5 target=2: score 9
- Oregon p5en target=2: score 9
- Oregon p6-b200 target=2: score 1
- Oregon p6-b300 target=2: score 6
- Ohio p5 target=2: score 2
- Ohio p5en target=2: score 2
- Ohio p6-b200 target=2: score 1
