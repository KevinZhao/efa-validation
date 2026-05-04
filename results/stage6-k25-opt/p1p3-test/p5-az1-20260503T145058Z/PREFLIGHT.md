# Preflight — p5-az1 P1+P3 validation

- Date/time: 2026-05-03T14:50:58Z
- Operator: efa-validation agent (Oregon)
- Sibling agent in-flight: p6-b300 in usw2-az2 (do not touch that NG/subnet)

## SPS
```
aws ec2 get-spot-placement-scores --region us-west-2 \
    --instance-types p5.48xlarge --target-capacity 2 --single-availability-zone \
    --query 'SpotPlacementScores[?AvailabilityZoneId==`usw2-az1`]'
```
Result: `[{"Region": "us-west-2", "AvailabilityZoneId": "usw2-az1", "Score": 9}]` — above the memory-mandated threshold of ≥6.

## Targets
- Region: us-west-2
- Cluster: gpu-cluster-oregon
- Bastion: i-081b2b010b6af530c (SSM only)
- Feature branch: feat/placement-group-and-topology-gate @ HEAD 6277af3
  - commits (newest → oldest): `feat(gpu-ng): P3 leaf-labeling mode for cross-leaf NGs` / `docs(gpu-ng): add P2 retry-loop + best-effort plan (deferred)` / `fix(gpu-ng): topology gate strict mode — maxSize=1 (EKS rejects =0)` / `feat(gpu-ng): cluster placement group + topology gate for EFA same-leaf` / `fix(gpu-plugin): set PASS_DEVICE_SPECS=true for NVIDIA device plugin v0.15` / `chore: harden shell scripts and reduce version maintenance burden`
- Instance: p5.48xlarge (1 EFA + 31 efa-only)
- AZ: us-west-2a (usw2-az1)
- Subnet: subnet-092ec691f3755574e (gpu-vpc-private-a)
- Desired: 2 nodes Spot
- NG name: gpu-p5-48xlarge-spot-az1-p3
- PG strategy: cluster (auto-create)
- GPU_TOPOLOGY_MODE: label

## Environment overrides actually used
```bash
cd /root/eks-cluster-deployment-p3
cp /root/eks-cluster-deployment/.env scripts/.env
sed -i 's|GPU_INSTANCE_TYPES=g7e.48xlarge|GPU_INSTANCE_TYPES=p5.48xlarge|' scripts/.env

cd scripts
export GPU_INSTANCE_TYPES=p5.48xlarge
export GPU_NODE_DESIRED_CAPACITY=2
export GPU_NODE_MIN_SIZE=0
export GPU_NODE_MAX_SIZE=2
export DEPLOY_GPU_SPOT=true
export DEPLOY_GPU_OD=false DEPLOY_GPU_ODCR=false DEPLOY_GPU_CB=false
export GPU_PG_STRATEGY=cluster
export GPU_TOPOLOGY_MODE=label
export GPU_TOPOLOGY_GATE_LEVEL=L3
export SPOT_SUFFIX=-az1-p3
export FORCE_SUBNETS=subnet-092ec691f3755574e
bash option_install_gpu_nodegroups.sh 2>&1 | tee /tmp/p5-p3-test.log
```

## Surgical patches to the launcher
Applied on the bastion's checkout only — not pushed to the branch.

1. In `option_install_gpu_nodegroups.sh` Spot block (original lines 1487–1489): replaced 3 hard-coded `""` suffix args with `${SPOT_SUFFIX:-}`. This lets us create a second p5 Spot NG without colliding with the existing production `gpu-p5-48xlarge-spot` NG/LT/PG.
2. Injected after `mapfile -t ALL_SUBNETS ...` (line 1453): a 1-line hook honoring `FORCE_SUBNETS=<csv>`. Needed because `.env` mandates 2+ AZ subnets but `plan_pg_for_nodegroup` requires single-AZ to auto-create a cluster PG.

Both patches are non-functional for the default flow (no SPOT_SUFFIX, no FORCE_SUBNETS → identical behavior to upstream). They could be upstreamed as follow-up if desired.
