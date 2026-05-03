# Stage 6 R1a Preflight — Kimi-K2.5 1P1D on 2 x p5en Spot

Stamp: 2026-05-03 06:15Z (UTC)
Target: 2 x p5en.48xlarge Spot in usw2-az3 on EKS cluster `gpu-cluster-oregon` (us-west-2).
Bastion: `i-081b2b010b6af530c` via SSM.

## 1. Bastion health

OK. Reachable via SSM. date=2026-05-03 06:10:51 UTC, kernel 6.1.166-197.305.amzn2023 aarch64.
Tools present: `eksctl`, `aws` (v2), `kubectl`. `s5cmd` NOT on bastion (installed on GPU nodes at boot via userdata; acceptable).
`eks-cluster-deployment` repo present at `~/eks-cluster-deployment/` with scripts/, manifests/, examples/, `.env` filled in for gpu-cluster-oregon.

## 2. Current K8s state

- Context: `arn:aws:eks:us-west-2:788668107894:cluster/gpu-cluster-oregon` (explicit `KUBECONFIG=/root/.kube/config` required; no default export in SSM shell).
- Nodes (2, both Graviton m7g system nodes, 23d old):
  - `ip-10-0-11-159` — Ready
  - `ip-10-0-14-146` — Ready
- `yanxi-validation` namespace: **No resources found** (clean slate).
- `/root/stage5/` contains `pd-1p1d-mc-vs-nixl-k25-int4-usw2.yaml`; `/root/results/` has `pd-1p1d-mc-vs-nixl-k25-int4/`.

## 3. Fresh SPS (2026-05-03 06:10Z)

p5en.48xlarge, target-capacity=2, single-AZ:

| AZ ID | AZ name | Score |
|---|---|---|
| **usw2-az3** | **us-west-2c** | **9** |
| usw2-az4 | us-west-2d | 7 |
| usw2-az2 | us-west-2b | 1 |
| usw2-az1 | us-west-2a | (<1, not returned) |

usw2-az3 improved from 8 (05:25Z) to **9** now. Clear go.

## 4. Existing p5en nodegroup — assessment

Existing: `gpu-p5en-48xlarge-spot`
- **Status: DEGRADED** (reason below)
- desired=0, min=0, max=4, capacityType=SPOT
- Subnets configured: **all 4 AZs** (subnet-092...az1, subnet-034...az2, subnet-012...az3, subnet-0e4...az4)
- Launch template `lt-0ac44b91768cce758` v3: AMI `ami-0a84de20b5de8b750`, 16 NICs (1 EFA + 15 EFA-only — correct for p5en), root + LVM data volume.
- Taint: `nvidia.com/gpu=true:NO_SCHEDULE` — OK.
- Labels: `gpu-instance-type=p5en.48xlarge, purchase-option=spot, workload-type=gpu` — OK.

**DEGRADED reason** (from EKS health API):
> AutoScalingGroupInvalidConfiguration: ASG `eks-gpu-p5en-48xlarge-spot-52cedd76-...` has subnets `[subnet-0e4dc6ed86312302f]` which is not expected by Amazon EKS. Expected subnets: `[subnet-092..., subnet-0343..., subnet-012..., subnet-0e4d...]`.

ASG drift: someone narrowed the ASG to az4 only but the NG still lists all 4 subnets. This blocks `update-nodegroup-config` cleanly, and scaling it up cannot guarantee az3 placement (EKS SPOT allocates wherever capacity + strategy win; in this case only az4 is in the ASG, **guaranteeing az4 not az3**).

**Verdict: DO NOT reuse the existing NG.** It is pinned to the wrong AZ via ASG drift and violates the "all tests same AZ" hard rule (which says usw2-az3 per today's SPS). Cleanest path: create a new AZ-pinned NG using the same LT.

Other NGs present (informational): `eks-utils` (system), `gpu-p5-48xlarge-spot`, `gpu-p6-b300-48xlarge-spot`. No running GPU instances right now (0 GPU nodes).

## 5. Recommended next command

Create a new Spot NG pinned to az3 only, reusing proven LT `lt-0ac44b91768cce758` v3, IAM role `GPUNodeRole-gpu-cluster-oregon` (already in EKS access entries):

```
# Run from the Oregon bastion (i-081b2b010b6af530c), as root, KUBECONFIG=/root/.kube/config
aws eks create-nodegroup \
  --cluster-name gpu-cluster-oregon \
  --region us-west-2 \
  --nodegroup-name gpu-p5en-48xlarge-spot-az3 \
  --subnets subnet-012b1f25ae467ab6c \
  --node-role arn:aws:iam::788668107894:role/GPUNodeRole-gpu-cluster-oregon \
  --launch-template id=lt-0ac44b91768cce758,version=3 \
  --instance-types p5en.48xlarge \
  --capacity-type SPOT \
  --scaling-config minSize=0,maxSize=2,desiredSize=2 \
  --labels workload-type=gpu,gpu-instance-type=p5en.48xlarge,purchase-option=spot,stage=stage6-r1a \
  --taints key=nvidia.com/gpu,value=true,effect=NO_SCHEDULE \
  --tags k8s.io/cluster-autoscaler/enabled=true,k8s.io/cluster-autoscaler/gpu-cluster-oregon=owned,gpu-instance-type=p5en.48xlarge,business=middleware,resource=eks,stage=stage6-r1a
```

Then wait and verify same-AZ placement:
```
aws eks wait nodegroup-active --cluster-name gpu-cluster-oregon --region us-west-2 --nodegroup-name gpu-p5en-48xlarge-spot-az3
KUBECONFIG=/root/.kube/config kubectl get nodes -l gpu-instance-type=p5en.48xlarge -o wide \
  -L topology.kubernetes.io/zone
# expect both nodes in us-west-2c (usw2-az3)
```

Resolved constants (verified on bastion):
- VPC: `vpc-081ea929da61b21d7`
- usw2-az3 private subnet: `subnet-012b1f25ae467ab6c` (us-west-2c)
- GPU AMI: `ami-0a84de20b5de8b750` (baked into LT v3)
- IAM role: `arn:aws:iam::788668107894:role/GPUNodeRole-gpu-cluster-oregon`
- LT: `lt-0ac44b91768cce758` v3 (includes LVM userdata, EFA 16-NIC config, root+data volumes)

## 6. S3 weight cache

**PRESENT.** `s3://yanxi-validation-788668107894-oregon/models/moonshotai/Kimi-K2.5/`: 85 objects, 595,204,646,314 bytes (~595 GB). Weights + modeling_kimi_k25.py + tokenizer artifacts all staged (mtime 2026-04-30 16:39). s5cmd pull to `/mnt/nvme` on each new p5en node remains as usual.

## 7. Housekeeping before GO

Operator should also (out of this preflight's scope):
- Decide disposition of existing DEGRADED `gpu-p5en-48xlarge-spot` NG (either `aws eks delete-nodegroup` it or leave at desired=0 — it's 0 nodes so no cost, only cosmetic).
- Confirm no other team has claimed usw2-az3 p5en spot pool in the next ~30 min (SPS is minute-level).

## GO / NO-GO

**GO** — usw2-az3 SPS=9, S3 weights cached, bastion + LT + IAM ready; only blocker was existing NG's ASG drift, bypassed by creating a new az3-pinned NG with the command in section 5.
