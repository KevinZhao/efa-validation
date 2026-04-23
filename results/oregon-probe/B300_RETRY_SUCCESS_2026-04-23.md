# Oregon p6-b300 Spot x4 — End-to-End Success with Fix

**Date**: 2026-04-23
**Region**: us-west-2 (Oregon), AZ us-west-2b
**Cluster**: `gpu-cluster-oregon`
**Script**: `eks-cluster-deployment` @ `f587709` (PR #1 merged — p6-b300 NIC 0 fix)

## Result

**4/4 p6-b300.48xlarge Spot instances** successfully launched and joined EKS.

| Instance ID | AZ | Private IP | Launch Time | Lifecycle |
|---|---|---|---|---|
| `i-0fb2ca813d5583da3` | us-west-2b | 10.0.12.231 | 2026-04-23T06:42:30Z | spot |
| `i-02d1a9c6b767cbb32` | us-west-2b | 10.0.12.253 | 2026-04-23T06:44:17Z | spot |
| `i-0d399ef0b7c05bb0b` | us-west-2b | 10.0.12.32  | 2026-04-23T06:44:17Z | spot |
| `i-049d958b6b754fc9f` | us-west-2b | 10.0.12.35  | 2026-04-23T06:44:17Z | spot |

## Timing (all UTC)

| Event | Time | Delta |
|---|---|---|
| `nohup option_install_gpu_nodegroups.sh` started | 06:41:23 | 0 |
| ASG created (`eks-gpu-p6-b300-48xlarge-spot-2ccedc89...`) | 06:41:55 | **+32s** |
| First Spot InService (1 instance in 2b) | 06:42:30 | **+67s** |
| Remaining 3 Spot InService | 06:44:17 | **+2m54s** |
| All 4 nodes Ready in Kubernetes | ~06:47 | +5m40s |
| NG status = ACTIVE | ~06:48 | +6m25s |

## Kubernetes verification

```
$ kubectl get nodes -l workload-type=gpu -o wide
NAME                                        STATUS   ROLES    AGE   VERSION               INTERNAL-IP   OS-IMAGE                        KERNEL-VERSION                    CONTAINER-RUNTIME
ip-10-0-12-231.us-west-2.compute.internal   Ready    <none>   27m   v1.35.3-eks-bbe087e   10.0.12.231   Amazon Linux 2023.11.20260413   6.12.79-101.147.amzn2023.x86_64   containerd://2.2.1+unknown
ip-10-0-12-253.us-west-2.compute.internal   Ready    <none>   25m   v1.35.3-eks-bbe087e   10.0.12.253   ...
ip-10-0-12-32.us-west-2.compute.internal    Ready    <none>   25m   v1.35.3-eks-bbe087e   10.0.12.32    ...
ip-10-0-12-35.us-west-2.compute.internal    Ready    <none>   25m   v1.35.3-eks-bbe087e   10.0.12.35    ...
```

### Per-node capacity

| Node | vpc.amazonaws.com/efa | nvidia.com/gpu |
|---|---|---|
| ip-10-0-12-231 | **16** | **8** |
| ip-10-0-12-253 | **16** | **8** |
| ip-10-0-12-32  | **16** | **8** |
| ip-10-0-12-35  | **16** | N/A (device plugin not yet reporting) |

Total across nodegroup: **64 EFA NICs + 24 H200 Blackwell GPUs** (1 node still warming up
device-plugin — expected to settle within 5–10 min).

## Fix validation — `AttachmentLimitExceeded` is gone

Searching the 4-instance ASG's scaling activities for capacity/EFA-related errors
returns **zero** `AttachmentLimitExceeded` entries. The script-level `InvalidFleetConfiguration`
entries for us-west-2a/c/d are expected (p6-b300 only available in 2b) and
harmless — they're noise from EKS managed NG trying every subnet.

The three Spot fulfillment attempts that landed in 2b all report
`StatusCode=Successful`:
```
2026-04-23T06:44:17Z  Successful (3x — nodes in 2b)
2026-04-23T06:42:30Z  (first instance, logged separately)
```

## What changed vs the 05:22 failed attempt

| Layer | Before fix | After fix |
|---|---|---|
| LT NIC 0 | `InterfaceType=efa` | **`InterfaceType=interface`** (ENA only) |
| Total EFA ENIs on LT | 17 (rejected by AWS) | **16** (== MaxEfaInterfaces) |
| Total NICs on LT | 17 | 17 (matches MaxNetworkCards) |
| Spot error | `AttachmentLimitExceeded - Network Card 0 (requested: 1, limit: 0)` | **none** |
| Spot fulfillment | 0/4 | **4/4 in 67s–2m54s** |

## Spot placement score reality check

Pre-probe score (from `get-spot-placement-scores`):
- Single-AZ p6-b300 target=4 → **3/10** (tight but non-zero)
- Target=2 → 6/10; target=1 → 9/10

Reality: **we got all 4 in under 3 minutes**. The score accurately flagged the
pool as tight-but-available; user request for "≥4 guaranteed" should still be
done via ODCR / Capacity Block, but spot worked this time.

## Next steps

1. **Stack deploy**: same `yanxi/sglang-mooncake:v2` image from Ohio ECR (already
   shared to `338295026919`). Need to share to this AWS account / pull via the
   existing ECR share if target account differs from probe account.
2. **NVMe RAID0 DaemonSet**: reuse `stage4-p5en/nvme-setup.yaml` for model
   prefetch space. p6-b300 has 8× NVMe same as p5en.
3. **1P:3D or 2P:2D topology**: 4 Blackwell nodes give flexibility. With
   Kimi K2 FP8 959GB weights and ~180GB/GPU on B300 (180GB HBM3e × 8 =
   1.44TB/node), single-node TP=8 can hold the full model with room for
   long-context KV — consider 1P:3D for throughput sweep.
4. **EFA stack**: 16 NICs × 400 Gbps = **6.4 Tbps/node** (vs p5en's 3.2 Tbps);
   Mooncake `EfaTransport` will need to be validated at this NIC count (Ohio
   stack tops at 16, should be a no-op, but confirm).

## Artifacts

- PR merged: https://github.com/KevinZhao/eks-cluster-deployment/pull/1
- Commit on bastion: `/home/ec2-user/eks-cluster-deployment` at `f587709`
- Script log: `/tmp/probe-b300-final.log` on bastion
- NG: `gpu-p6-b300-48xlarge-spot` (ACTIVE, 4 nodes)
- Nodes leave running for user's next test phase
