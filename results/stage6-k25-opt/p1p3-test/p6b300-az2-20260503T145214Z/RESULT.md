# RESULT — p6-b300 feat/placement-group-and-topology-gate test (us-west-2b)

**Date**: 2026-05-03
**Outcome**: PARTIAL — infrastructure-side validation PASS, runtime validation BLOCKED by capacity

## Executive summary

Spot capacity for p6-b300.48xlarge in usw2-az2 was unavailable at run time (despite SPS=9). The EKS managed node group exhausted its internal ASG retry budget after 33 min of `InsufficientInstanceCapacity` errors and went `CREATE_FAILED`. No live nodes ever joined the cluster.

Because no instance ever launched, the 3 p6-b300-runtime-specific validation targets (GPU count, EFA plugin enumeration, actual NIC topology on instance) could not be evaluated. However, all **infrastructure / launch-spec** targets passed on the first attempt.

## Validation targets

| # | Target | Result | Evidence |
|---|---|---|---|
| 1 | Feature branch cloned, HEAD=6277af3 (P3) | PASS | `git rev-parse HEAD` → `6277af3725089a819ae7350210416f1b0c814a74` |
| 2 | Script accepts single-AZ subnet list | PASS | `ALL_SUBNETS=[subnet-0343696171ce4cdc9]` after dedup |
| 3 | P1 PG auto-creation (cluster strategy) | PASS | PG `gpu-cluster-oregon-p6-b300-48xlarge-us-west-2b-spot-az2-p3-cg` State=available Strategy=cluster GroupId=pg-0e7b36371a27be595 |
| 4 | LT has `Placement.GroupName` set (P1 fix) | PASS | `lt-0ec9355a7c76a9d9a` v1 → `Placement.GroupName=gpu-cluster-oregon-p6-b300-48xlarge-us-west-2b-spot-az2-p3-cg` |
| 5 | LT has 17 NetworkInterfaces for p6-b300 | PASS | 1 ENA + 16 EFA-only = 17 entries |
| 6 | **NIC 0 = InterfaceType=interface** (ENA-only, p6-b300 special) | **PASS** | `NetworkCardIndex:0, InterfaceType:interface` in LT |
| 7 | **NICs 1-16 = InterfaceType=efa-only** | **PASS** | 16 entries `NetworkCardIndex:1..16, InterfaceType:efa-only` |
| 8 | NG create API succeeds | PASS | `CreateNodegroup` returned NG ARN `...gpu-p6-b300-48xlarge-spot-az2-p3/06cef72c-...` |
| 9 | NG reaches ACTIVE within budget | **FAIL — InsufficientInstanceCapacity** | `AsgInstanceLaunchFailures` after 33 min |
| 10 | **Device plugin reports 8 Blackwell B300** | BLOCKED (no nodes) | n/a |
| 11 | **`vpc.amazonaws.com/efa: 16` on node** | BLOCKED (no nodes) | n/a |
| 12 | **ec2:DescribeInstances confirms NIC 0 on live instance is interface** | BLOCKED (no instance) | n/a (LT-level evidence in #6) |
| 13 | **P3 leaf-labeling actually labels nodes** | BLOCKED (no nodes) | n/a |
| 14 | **Same-leaf verification on p6-b300 cluster PG** | BLOCKED (no instances) | n/a |
| 15 | EFA smoke pod (fi_info -p efa) | BLOCKED (no nodes) | n/a |

## Key positive findings

1. **P1 PG injection works for p6-b300** — `Placement.GroupName` correctly populated in LT; PG pre-created before LT via `plan_pg_for_nodegroup → ensure_cluster_pg`. (This was the script's main historical bug — fixed and verified on first Blackwell dry run.)

2. **NIC 0 = ENA correctly handled** — the special-case code at lines 912-923 of `option_install_gpu_nodegroups.sh` is in the NetworkInterfaces-generator Python block. The produced LT has:
   ```
   [{DeviceIndex:0, NetworkCardIndex:0, InterfaceType:interface},       # ENA only, correct
    {DeviceIndex:1, NetworkCardIndex:1..16, InterfaceType:efa-only}]    # 16 EFAs, correct
   ```
   This matches the p6-b300 NIC topology exactly: NIC 0 cannot carry EFA (per script doc "Network Card 0 does NOT support EFA; yields AttachmentLimitExceeded").

3. **Single-AZ PG eligibility** — `plan_pg_for_nodegroup` correctly short-circuits to PG creation only when all subnets resolve to a single AZ (dedup worked: A=B=`subnet-0343696171ce4cdc9`).

4. **Suffix propagation end-to-end** — with 3-line patch to spot branch, `GPU_NG_SUFFIX=-az2-p3` flows into PG name, LT name, and NG name consistently:
   - PG: `gpu-cluster-oregon-p6-b300-48xlarge-us-west-2b-spot-az2-p3-cg`
   - LT: `gpu-cluster-oregon-gpu-p6-b300-48xlarge-spot-az2-p3-lt`
   - NG: `gpu-p6-b300-48xlarge-spot-az2-p3`

## Runtime blocker

- **EC2 InsufficientInstanceCapacity** for p6-b300.48xlarge spot in us-west-2b
- ASG retried 6 times from 15:11:03Z to 15:26:54Z (all failed), EKS gave up at 15:31:30Z
- Pre-existing `gpu-p6-b300-spot-usw2b` NG (created 14:48Z, unrelated to this test) hit same error and failed at 15:21Z → **the whole AZ is out of p6-b300 spot** right now, not specific to our NG
- **SPS=9 continued to report post-failure** — this is a well-known SPS-vs-reality gap. The `feedback_sps_before_launch.md` rule says "pick score≥6" but even SPS=10 can fail when capacity is acutely scarce
- **Not a script bug** — every artifact shows the script did its job correctly

## Was NIC 0 InterfaceType correctly set to 'interface'?

**YES** — verified at LT level. See `logs/lt-verify.json`:
```
NetworkInterfaces[0] = {DeviceIndex:0, NetworkCardIndex:0, InterfaceType:"interface"}
NetworkInterfaces[1..16] = {DeviceIndex:1, NetworkCardIndex:1..16, InterfaceType:"efa-only"}
```
The Python generator at lines 912-923 correctly branches on `instance_type == "p6-b300.48xlarge"` and emits ENA for the primary, matching the hardware constraint.

## Same-leaf on p6-b300 cluster PG — unknown

Cannot evaluate — no instances ever launched, so `ec2:DescribeInstanceTopology` has nothing to query. Deferred to next capacity window.

## Any Blackwell-specific gap in the script or device plugins?

**No gaps detected in the script** — all p6-b300 special-cases (NIC 0 = interface, MaxEFA=16, NetworkCardIndex 0-16) are already handled. The runtime validation remains a gap because we couldn't actually boot an instance.

**Device plugin gap (not exercised)**: nvidia-device-plugin v0.15 with `PASS_DEVICE_SPECS=true` (from commit `4d74f49`) should enumerate B300s, but this wasn't verifiable without a live node. Recommend retry in next 24h when p6-b300 spot capacity returns.

## Teardown

- `aws eks delete-nodegroup` initiated at 15:32Z → status DELETING
- PG and LT will be left to manual cleanup once NG DELETED (PG has instance-ref while LT v1 is attached to NG)
- Follow-up: after NG fully deleted, run
  ```
  aws ec2 delete-placement-group --group-name gpu-cluster-oregon-p6-b300-48xlarge-us-west-2b-spot-az2-p3-cg --region us-west-2
  aws ec2 delete-launch-template --launch-template-id lt-0ec9355a7c76a9d9a --region us-west-2
  ```

## Cost

- $0 (no instances launched)

## Artifacts

- `PREFLIGHT.md` — env, SPS, collision check, script patch
- `RESULT.md` — this file
- `logs/p6b300-p3-ng-create.log` — full script output (268 lines)
- `logs/lt-verify.json` — LT v1 full spec (with NIC + PG evidence)
- `logs/pg-verify.json` — PG state + tags
- `logs/asg-activities.json` — 6 ASG launch-failure events
- `logs/ng-final-state.json` — NG CREATE_FAILED + health issue
- `logs/sps-p6b300-post-failure.json` — SPS still=9 after failure

## Next steps (operator)

1. **Retry in a few hours** when p6-b300 spot capacity recovers (monitor via `get-spot-placement-scores` + ASG dry-run)
2. Alternative: try `us-west-2d` (requires subnet-D, tagged for private) if SPS stays high there
3. Consider upstream PR: add `GPU_NG_SUFFIX` env-var support to spot branch (lines 1487-1489) to match existing ODCR/CB branches

## Teardown confirmation (15:34Z)

- NG `gpu-p6-b300-48xlarge-spot-az2-p3`: DELETED (ResourceNotFoundException by 15:33:30Z)
- PG `gpu-cluster-oregon-p6-b300-48xlarge-us-west-2b-spot-az2-p3-cg`: deleted, describe returns []
- LT `lt-0ec9355a7c76a9d9a`: deleted, describe-launch-templates returns NotFound
- Pre-existing NGs undisturbed: gpu-p5-48xlarge-spot, gpu-p5en-spot-usw2c/d, gpu-p6-b300-spot-usw2b (CREATE_FAILED, not ours)
- Sibling p5 NGs already DELETING by 15:21Z (separate agent)
- Total cost: $0 (no instances launched)
