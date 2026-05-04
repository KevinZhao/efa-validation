# P1+P3 feature-branch validation on p5.48xlarge (us-west-2a)

- Timestamp: 2026-05-03T14:50:58Z
- Branch: feat/placement-group-and-topology-gate @ 6277af3
- Cluster: gpu-cluster-oregon
- Region: us-west-2, AZ: us-west-2a (usw2-az1), SPS=9
- Subnet: subnet-092ec691f3755574e (gpu-vpc-private-a)
- NG: gpu-p5-48xlarge-spot-az1-p3 (SPOT, desired=2)
- LT: lt-09abf019f5a83d8c1 / version 1
- PG: gpu-cluster-oregon-p5-48xlarge-us-west-2a-spot-az1-p3-cg (strategy=cluster)
- Instances: i-0c43ace2f5c49ae59 (10.0.11.246), i-0fde365ec3daa6274 (10.0.11.90)

## Setup notes
- Feature branch hardcoded NG-name suffix `""` for spot path. Required a 4-line surgical patch to let Spot path accept a `SPOT_SUFFIX` env (set `-az1-p3`) so the new NG did not collide with existing `gpu-p5-48xlarge-spot`. See logs/install_gpu_nodegroups.log for diff.
- Also injected a `FORCE_SUBNETS` hook immediately after the `ALL_SUBNETS` build so `plan_pg_for_nodegroup` sees a single-subnet list (the canonical `.env` declares 4 subnets across 4 AZs, which would otherwise make cluster-PG eligibility fail).
- No source code change required in PG/LT/NG/label logic itself — only in the launcher.

## 9 targets + smoke pod

| # | Target | Verdict | Evidence |
|---|---|---|---|
| T1 | PG auto-create | PASS | `aws ec2 describe-placement-groups` returns `gpu-cluster-oregon-p5-48xlarge-us-west-2a-spot-az1-p3-cg` State=available Strategy=cluster. Tags include Cluster, AZ, gpu-instance-type. |
| T2 | LT Placement.GroupName injected | PASS | `describe-launch-template-versions --versions $Latest --query ...Placement` = `{GroupName: gpu-cluster-oregon-p5-48xlarge-us-west-2a-spot-az1-p3-cg, Tenancy: default}` |
| T3 | Node labels `efa-leaf-id` + `efa-az` | PASS | Node ip-10-0-11-246: `efa-leaf-id=nn-ef0ede71e42b8aa87`, `efa-az=us-west-2a`; Node ip-10-0-11-90: `efa-leaf-id=nn-8322a49488884ceb9`, `efa-az=us-west-2a`. |
| T4 | Inventory section `=== Multi-node-eligible leaves ===` | PASS | option_label_nodegroup_topology.sh inventory prints both `=== Leaf inventory (cluster-wide) ===` and `=== Multi-node-eligible leaves (>= 2 nodes same leaf) ===`. For this NG the answer is `(none — all leaves have fewer than 2 nodes)` — see T9. |
| T5 | NVIDIA DS `PASS_DEVICE_SPECS=true` | PASS | kubectl get ds -n kube-system nvidia-device-plugin-daemonset -o yaml shows `env: -name: PASS_DEVICE_SPECS value: "true"`. Image v0.15.0. |
| T6 | EFA plugin ≥8 NICs per p5 node | PASS (exceeds target) | Both nodes have `vpc.amazonaws.com/efa: 32` (allocatable + capacity), matches p5 spec (1 EFA + 31 EFA-only). aws-efa-k8s-device-plugin-daemonset 2/2 Ready. |
| T7 | /data LVM mount | PASS | `df -h /data`: `/dev/mapper/vg_local-lv_scratch  28T  198G  28T  1%  /data`. Striped across 8× 3.5T NVMe. |
| T8 | `/opt/amazon/efa/` present | FAIL | `/opt/amazon/efa/bin/fi_info` does not exist. Host is missing libfabric-aws + openmpi5-aws userspace (manifest in /opt/amazon/efa_installed_packages shows kernel-only install: efa-3.0.0, rdma-core-61, libibverbs, efa-config, efa-nv-peermem, pmix-aws, prrte-aws — NO libfabric/openmpi5 userspace). Kernel side OK (efa kmod loaded, 32 IB devices in /sys/class/infiniband/). Workloads that bring their own libfabric in-container are unaffected (smoke pod confirms 32 uverbs + 32 rdmap exposed into container). Matches historical gap in memory `reference_ohio_eks_p5en_gaps.md`. **Fix**: AMI userdata should run `efa_installer.sh` with defaults (not `--minimal`/`--no-libfabric`). |
| T9 | Describe topology + same-leaf | PASS w/ novel finding | Both instances: `L1=nn-71af5d3f6f6b7a70a (same) L2=nn-8d8b289212361b5a7 (same) L3=nn-ef0ede71e42b8aa87 vs nn-8322a49488884ceb9 (DIFFERENT)`. Cluster PG + single subnet + single AZ is sufficient for same L1/L2 but NOT for same L3 leaf on p5. label-mode correctly surfaces this, strict-L3 gate would have failed (expected given new mode design). |
| D | EFA smoke pod | PASS | Pod `yanxi-validation/p5-efa-smoke` (amazonlinux:2023 image) scheduled on ip-10-0-11-246, Running. `/dev/infiniband/`: 32 uverbs (uverbs0..uverbs31). `/sys/class/infiniband/`: 32 rdmap entries. |

## Novel data point — cluster PG same-leaf on p5
Cluster placement group across 2 p5.48xlarge in us-west-2a / subnet-092ec691f3755574e gave **same L1 + same L2 + DIFFERENT L3 leaves**. Implication: on p5 in Oregon us-west-2a with current Spot capacity, even cluster PG does not guarantee same-leaf pairing. For workloads requiring same-leaf (per memory `feedback_topology_gate_before_bench.md`), operators must still run the gate or the label-mode inventory and retry until they find ≥2 nodes under the same `efa-leaf-id`. This validates the whole motivation for P3 label-mode: the gate is necessary, PG alone is insufficient.

## Validation targets that did NOT need feature-branch code
T5 (PASS_DEVICE_SPECS) lives in commit 4d74f49 (sibling of P1/P3, not in the feature branch proper). It was already applied on the cluster because the branch was rebased onto that commit.

## Artifacts
- Local dir: /home/ec2-user/workspace/efa-validation/results/stage6-k25-opt/p1p3-test/p5-az1-20260503T145058Z/
- S3 mirror: s3://yanxi-validation-788668107894-oregon/results/stage6-k25-opt/p1p3-test/p5-az1-20260503T145058Z/
  - logs/install_gpu_nodegroups.log (662 lines, full stdout of option_install_gpu_nodegroups.sh)
  - logs/inventory.log (output of option_label_nodegroup_topology.sh inventory)
  - logs/nodes.yaml (kubectl get nodes -o yaml for the 2 p5 nodes)

## Teardown
See TEARDOWN.md for commands + results.
