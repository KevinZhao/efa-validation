# D2 Task Preflight — 2026-05-04 05:50Z

## SPS re-verify
```
aws ec2 get-spot-placement-scores --region-names us-west-2 \
  --instance-types p6-b300.48xlarge --single-availability-zone \
  --target-capacity 1 --query 'SpotPlacementScores[?Score>=`6`]'
```
Result: `[{"Region":"us-west-2","AvailabilityZoneId":"usw2-az2","Score":9}]` → GO

## Existing nodegroups (before run)
- eks-utils
- gpu-p5en-spot-usw2c
- gpu-p5en-spot-usw2d
- gpu-p6-b300-spot-usw2b

No `gpu-*-az2-d` leftover from D task. Safe.

## Branch
HEAD=`2a65ec6` on `feat/placement-group-and-topology-gate` (fix .env clobber + device plugin time-race).

## .env setup for Bug 1 scenario
`/root/eks-cluster-deployment-d2/scripts/.env` contains:
```
GPU_INSTANCE_TYPES=g7e.48xlarge
```
Caller exports `GPU_INSTANCE_TYPES=p6-b300.48xlarge` before `bash option_install_gpu_nodegroups.sh`.
Fix must ensure caller value wins.

## Target
- NG name: gpu-p6-b300-48xlarge-spot-az2-d2
- AZ: us-west-2b, subnet-0343696171ce4cdc9
- Target=1 Spot, cap $20 / 60 min
