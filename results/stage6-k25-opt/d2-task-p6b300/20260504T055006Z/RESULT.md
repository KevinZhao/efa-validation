# Stage 6 D2 — p6-b300 Bug Fix Re-Verification (2026-05-04)

## Summary
**Both bug fixes PASS on real p6-b300.48xlarge hardware, single-try.**

| Gate | Result |
|---|---|
| SPS re-verified usw2-az2=9 | PASS |
| NG created first try | PASS (no capacity miss) |
| Bug 1: caller export beats `.env` | PASS (see §1) |
| Bug 2: device plugin bounce function | PASS — scenario (a), healthy on first try, no-op (see §2) |
| EFA 16 NIC | PASS (`vpc.amazonaws.com/efa: 16`) |
| 8× B300 GPU visible | PASS |
| Topology label stamped | PASS (efa-leaf-id=nn-fec6c9c5e769f9d18, efa-az=us-west-2b) |
| libfabric 2.4.0 present | PASS (`/opt/amazon/efa/bin/fi_info: 2.4.0amzn3.0`) |

## Timeline
- 05:50Z SPS re-verify
- 05:51Z first install attempt — aborted (no .env in scripts/)
- 05:53Z install launched (pid 1192394)
- 05:54:10Z NG CREATING
- 05:55:40Z NG ACTIVE (~90s)
- ~06:06Z node Ready, install script finished
- 06:07Z Bug 2 gate verified
- 06:08Z nvidia-smi sanity
- Instance ID: i-05471021f92a6bfe1
- K8s node: ip-10-0-12-70.us-west-2.compute.internal

## §1 — Bug 1 (.env clobber fix)
**Scenario**: caller `export GPU_INSTANCE_TYPES=p6-b300.48xlarge`, then runs script. `.env` in `scripts/` contains `GPU_INSTANCE_TYPES=g7e.48xlarge` (strictly stronger than the original "empty" scenario, because .env's value is non-empty and different).

**Install log evidence**:
```
[2026-05-04 05:53:47] Loading configuration from .env file (caller exports take precedence)...
...
GPU Instance Types: p6-b300.48xlarge
Creating Launch Template: gpu-cluster-oregon-gpu-p6-b300-48xlarge-spot-az2-d2-lt
  Instance Type: p6-b300.48xlarge
Creating nodegroup: gpu-p6-b300-48xlarge-spot-az2-d2
  Instance Type: p6-b300.48xlarge
```

**Stray NG check**: list-nodegroups after creation shows only
`gpu-p6-b300-48xlarge-spot-az2-d2` + pre-existing infra NGs. **No stray `g7e` or `p5` NG created.** PASS.

The snapshot-and-restore logic in `0_setup_env.sh` (commit 2a65ec6) is verified working: caller-exported non-empty values survive `.env` sourcing.

## §2 — Bug 2 (device-plugin time-race fix)
`bounce_nvidia_device_plugin_for_ng()` ran and took the no-op path:

```
Checking nvidia-device-plugin pods on NG=gpu-p6-b300-48xlarge-spot-az2-d2 for stuck-at-init state...
  ip-10-0-12-70.us-west-2.compute.internal: nvidia.com/gpu=8 (healthy, no bounce needed)
  no bounce needed
```

- Post-run `nvidia.com/gpu: 8` (Capacity and Allocatable)
- Device plugin pod `nvidia-device-plugin-daemonset-44z64`: Running, RESTARTS=0, age 11m
- **No manual `kubectl delete pod` required**, unlike D task

This is scenario (a) from spec: race didn't fire this run. The function's detection+no-op path is correct. PASS.

## §3 — EFA / topology sanity
From `kubectl describe node`:
```
efa-az=us-west-2b
efa-leaf-id=nn-fec6c9c5e769f9d18
Capacity:
  nvidia.com/gpu:         8
  vpc.amazonaws.com/efa:  16
Allocatable:
  nvidia.com/gpu:         8
  vpc.amazonaws.com/efa:  16
```

From instance SSM:
```
GPU 0-7: NVIDIA B300 SXM6 AC
/opt/amazon/efa/bin/fi_info: 2.4.0amzn3.0
libfabric api: 2.4
```

## §4 — Teardown
- `aws eks delete-nodegroup` initiated ~06:12Z
- NG fully gone ~06:21Z (~9.5 min)
- Launch template `lt-0a94e166db723d126` deleted
- Instance `i-05471021f92a6bfe1` state=terminated
- Repo `/root/eks-cluster-deployment-d2` removed from bastion
- Final `list-nodegroups` = pre-run state (eks-utils, gpu-p5en-spot-usw2c/d, gpu-p6-b300-spot-usw2b)
- No placement group created (GPU_PG_STRATEGY=none)

## §5 — Cost
~13 min wall clock (05:54 NG create → ~06:08 verification complete) → ~15 min to teardown start → 15–18 min total Spot p6-b300.48xlarge runtime.
p6-b300.48xlarge Spot list price ~$30/h in us-west-2 → well under $20 cap.

## Artifacts
- `PREFLIGHT.md`
- `RESULT.md` (this file)
- `logs/install.log` — full script output with Configuration Summary + bounce section
- `logs/kubectl-describe.txt` — node describe with capacity/allocatable/labels
- `logs/ssm-outputs.txt` — nvidia-smi + fi_info + ibv_devinfo
