# Stage 6 Task D — p6-b300 Blackwell Hardware Validation — PREFLIGHT

- **Stamp**: 20260504T043453Z
- **Operator**: Stage 6 agent (continuation from 2026-05-03 InsufficientInstanceCapacity retries)
- **Bastion**: i-081b2b010b6af530c (SSM Online @ 04:33 UTC)
- **Branch**: `feat/placement-group-and-topology-gate` @ `82351b6d09e22ad92c0d1a1d6160869efbead681`

## 1. Spot Placement Score

```
aws ec2 get-spot-placement-scores --region-names us-west-2 \
  --instance-types p6-b300.48xlarge --single-availability-zone \
  --target-capacity 1
```

Result: `usw2-az2 score=9` (GO; same as yesterday but worth retry per diurnal pattern).

## 2. Pre-existing NG state (untouched)

`gpu-p6-b300-spot-usw2b` — `CREATE_FAILED` with `AsgInstanceLaunchFailures / InsufficientInstanceCapacity`, desired=0. Yesterday state, LEFT ALONE.

## 3. NG create parameters (target)

| env var | value |
|---|---|
| CLUSTER_NAME | gpu-cluster-oregon |
| GPU_INSTANCE_TYPES | p6-b300.48xlarge |
| GPU_NODE_DESIRED_CAPACITY / MIN / MAX | 1 / 0 / 1 |
| DEPLOY_GPU_SPOT | true |
| DEPLOY_GPU_OD / ODCR / CB | false |
| GPU_NG_SUFFIX | -az2-d |
| GPU_TARGET_AZ | b |
| GPU_INSTALL_EFA_USERSPACE | true |
| GPU_PG_STRATEGY | none |
| GPU_TOPOLOGY_MODE | label |

Target NG name: `gpu-p6-b300-48xlarge-spot-az2-d`
Target subnet: `subnet-0343696171ce4cdc9` (us-west-2b / usw2-az2)

## 4. Operational incidents during launch

### 4a. `.env` override of `GPU_INSTANCE_TYPES`

The oregon `.env` shipped `GPU_INSTANCE_TYPES=` (empty). `scripts/0_setup_env.sh` does `set -a; source .env` which CLOBBERS the parent-exported `GPU_INSTANCE_TYPES=p6-b300.48xlarge` with empty string, causing the script to use the **default** `p5.48xlarge`.

Effect: first launch created wrong NG `gpu-p5-48xlarge-spot-az2-d` (p5 Spot in usw2-az2). Also triggered SSM nohup retry (the memory rule `feedback_ssm_nohup_retry.md`) which invoked the script a 2nd time, creating a SECOND stray NG `gpu-p5en-48xlarge-spot` with desired=2 (the default from somewhere).

**Remediation applied**:
- Edited `/root/eks-cluster-deployment-d-task/.env` to set `GPU_INSTANCE_TYPES=p6-b300.48xlarge`.
- Deleted both stray NGs via `eks delete-nodegroup` immediately (both entered DELETING within 30s of creation so no instances launched).
- Re-ran with `flock -n 9 ... 9>/tmp/p6b300-d.lock` to guard against SSM retry double-invocation.

### 4b. Confirmation of correct target NG

`gpu-p6-b300-48xlarge-spot-az2-d` — CREATING, desired=1, p6-b300.48xlarge, SPOT, subnet-0343696171ce4cdc9, LT `lt-0554fb3ccb30105dc` v1.

## 5. Operator follow-ups

- **Bug in eks-cluster-deployment PR #2**: empty `GPU_INSTANCE_TYPES=` in shipped `.env` silently clobbers exported value. Should change `0_setup_env.sh` to only source explicitly-set (non-empty) values or change `.env` to not write empty variables.
- **SSM nohup retry** reproduced cleanly; `flock` guard works. Document for future Stage-6 ops.
