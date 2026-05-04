# PREFLIGHT — p6-b300 feat/placement-group-and-topology-gate test (us-west-2b)

**Run stamp**: 20260503T145214Z
**Region**: us-west-2
**Cluster**: gpu-cluster-oregon
**Bastion**: i-081b2b010b6af530c
**Feature branch**: feat/placement-group-and-topology-gate (HEAD: 6277af3725089a819ae7350210416f1b0c814a74)
**Instance**: p6-b300.48xlarge
**AZ**: us-west-2b (usw2-az2)
**Subnet**: subnet-0343696171ce4cdc9 (gpu-vpc-private-b)
**NG name**: gpu-p6-b300-48xlarge-spot-az2-p3
**PG strategy**: cluster (auto-created)
**Topology mode**: GPU_TOPOLOGY_MODE=label (non-strict)

## SPS verification (pre-launch)

- 2026-05-03 ~12:45Z: SPS=9 for p6-b300.48xlarge / us-west-2 / single-AZ / capacity=2 → usw2-az2
- 2026-05-03 14:52Z (this run start): SPS=9 re-verified for target_capacity=2, usw2-az2
- 2026-05-03 15:32Z (post-failure re-check): SPS=9 (unchanged — SPS is optimistic 10-min aggregate, does not reflect live capacity)

## Existing NG collision check

cluster had:
- eks-utils
- gpu-p5-48xlarge-spot (ACTIVE, pre-existing)
- gpu-p5en-spot-usw2c, gpu-p5en-spot-usw2d (ACTIVE)
- **gpu-p6-b300-spot-usw2b** (CREATING at start; hit same InsufficientInstanceCapacity and CREATE_FAILED at 15:21Z before our NG did)
- sibling agent also created: gpu-p5-48xlarge-spot-az1-p3, gpu-g7e-48xlarge-spot-az1-p3 (both DELETING by 15:21Z)

No NG-name collision: our `gpu-p6-b300-48xlarge-spot-az2-p3` vs pre-existing `gpu-p6-b300-spot-usw2b` differ in both instance-type token (`48xlarge`) and AZ suffix.

## Script adaptation (NG_SUFFIX support)

Main script's spot branch (line 1487-1489) hardcoded empty suffix. Patched on bastion:
```
spot_pg_name=$(plan_pg_for_nodegroup "$gpu_type" "spot" "${GPU_NG_SUFFIX:-}" ...)
create_gpu_launch_template "$gpu_type" "spot" "" "${GPU_NG_SUFFIX:-}" ...
create_gpu_nodegroup "$gpu_type" "spot" "$LT_ID" "$LT_VERSION" "${GPU_NG_SUFFIX:-}" ...
```
Recommendation: upstream this tiny change — allow `GPU_NG_SUFFIX` env var in spot branch (already in ODCR/CB branches).

## Env passed to script
```
CLUSTER_NAME=gpu-cluster-oregon
AWS_REGION=us-west-2
VPC_ID=vpc-081ea929da61b21d7
PRIVATE_SUBNET_A=subnet-0343696171ce4cdc9 (duplicated to subnet-B, single-AZ forced)
PRIVATE_SUBNET_B=subnet-0343696171ce4cdc9
PRIVATE_SUBNET_C="" PRIVATE_SUBNET_D=""
PUBLIC_SUBNET_A=subnet-0500247d3c254d410 (required by 0_setup_env.sh validator; not used in NG)
PUBLIC_SUBNET_B=subnet-0500247d3c254d410
GPU_INSTANCE_TYPES=p6-b300.48xlarge
GPU_NODE_DESIRED_CAPACITY=2  GPU_NODE_MIN_SIZE=0  GPU_NODE_MAX_SIZE=2
DEPLOY_GPU_SPOT=true  DEPLOY_GPU_OD=false  DEPLOY_GPU_ODCR=false  DEPLOY_GPU_CB=false
GPU_PG_STRATEGY=cluster
GPU_TOPOLOGY_MODE=label
GPU_TOPOLOGY_GATE_LEVEL=L3
GPU_NG_SUFFIX=-az2-p3
```
