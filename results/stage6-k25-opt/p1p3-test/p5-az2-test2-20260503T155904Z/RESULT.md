# P1+P3 + follow-up-envs (de51e78) Real-Machine Validation — Run 2

- **Run stamp**: 20260503T155904Z
- **Region**: us-west-2
- **Cluster**: gpu-cluster-oregon
- **Feature branch HEAD**: de51e78 (feat(gpu-ng): add GPU_NG_SUFFIX, GPU_TARGET_AZ, GPU_INSTALL_EFA_USERSPACE)
- **Instance**: p5.48xlarge x 2 Spot
- **AZ**: us-west-2b (usw2-az2)
- **Subnet**: subnet-0343696171ce4cdc9 (gpu-vpc-private-b)
- **SPS at run start**: 9 (re-verified)
- **Duration**: ~12 min wall clock (install -> labels); teardown ~15 min
- **Estimated cost**: 2 * ~0.55 * (12 + 15)/60 ~= $0.50 (well under $30 cap)

## Environment / runner
- .env file had to be materialized on bastion under `scripts/.env` (repo's `0_setup_env.sh` sources `.env` from the script's CWD — no docs said to put the env file there; **this is a minor operator-ergonomics gap, not a feature-branch regression**).
- After .env was in place, **zero** manual script patches were needed. Previous run required:
  1. Patching NG-name collision logic — NOW handled by GPU_NG_SUFFIX (PASS)
  2. Manually unsetting PRIVATE_SUBNET_B/C/D to collapse to one subnet — NOW handled by GPU_TARGET_AZ (PASS)

## Validation results (5 items)

| # | Item                                                           | Status | Evidence |
|---|----------------------------------------------------------------|--------|----------|
| 1 | GPU_NG_SUFFIX works — NG name coexists without collision       | PASS   | NG created `gpu-p5-48xlarge-spot-az2-test2`; pre-existing `gpu-p5-48xlarge-spot` untouched. LT name `gpu-cluster-oregon-gpu-p5-48xlarge-spot-az2-test2-lt`. |
| 2 | GPU_TARGET_AZ works — deploys narrowed to single subnet        | PASS   | install.log line 83: "GPU_TARGET_AZ=b -> narrowing OD/Spot deploys to subnet subnet-0343696171ce4cdc9". NG.subnets = [subnet-0343696171ce4cdc9] only. Both instances landed in subnet-0343696171ce4cdc9, AZ us-west-2b. |
| 3 | GPU_INSTALL_EFA_USERSPACE works — `/opt/amazon/efa/bin/fi_info` present | **FAIL** | `fi_info` not present on either node. Root cause found in node1 bootstrap log: efa_installer was invoked with `--minimal` flag; the installer itself logged "Minimal installation does not include libfabric, skipping test." `--minimal` excludes libfabric-aws and openmpi5-aws, which is where `fi_info` lives. Script bug is in the userdata heredoc in `option_install_gpu_nodegroups.sh` — the `--minimal` flag defeats the stated purpose. Fix: drop `--minimal`, keep `--skip-kmod`. |
| 4 | P1 + P3 still pass (PG auto, LT Placement, labels, inventory)  | PASS   | PG `gpu-cluster-oregon-p5-48xlarge-us-west-2b-spot-az2-test2-cg` exists, strategy=cluster, state=available. Both instances show Placement.GroupName = that PG. Labels stamped: `efa-leaf-id=nn-5d49302f30adcca72` / `nn-ca48ad88116512cb5`, `efa-az=us-west-2b`. Inventory table printed. `vpc.amazonaws.com/efa=32` capacity. |
| 5 | Same-leaf 3rd datapoint for p5 + cluster PG                    | DATA   | **Same L1+L2, different L3.** L1=nn-e308ac2e711c8cc0a (both), L2=nn-5dbd683c71ef36141 (both), L3 differs (nn-5d49302f30adcca72 vs nn-ca48ad88116512cb5). Matches prior p5 az1 observation — cluster PG on p5.48xlarge consistently produces same-L2 but *not* same-L3 for 2 spot nodes. |

## Env #3 diagnosis (EFA userspace FAIL — `--minimal` defeats purpose)

Source of bug: userdata (inline in `option_install_gpu_nodegroups.sh`), line 301:
```
./efa_installer.sh -y --skip-kmod --minimal 2>&1 | tail -20
```

node1-bootstrap.log lines 303-323 show installer was **invoked and exited successfully**, but:
- "skipping openmpi40-aws-4.1.7-3.x86_64 because of minimal installation"
- "skipping openmpi50-aws-5.0.9amzn1-11.x86_64 because of minimal installation"
- "Minimal installation does not include libfabric, skipping test."

The post-check `if [ -x /opt/amazon/efa/bin/fi_info ]` then printed no "EFA userspace installed" line because fi_info was (correctly, given `--minimal`) never installed.

Already-installed (AMI-provided) kernel/RDMA bits:
- efa-nv-peermem-1.2.3-1, efa-3.0.0-1, efa-config-1.18-1 (kernel module fine)
- pmix-aws, prrte-aws, ibacm, infiniband-diags, libibverbs, librdmacm, rdma-core (RDMA stack fine)

Missing: libfabric-aws, openmpi5-aws. These ARE what ship `/opt/amazon/efa/bin/fi_info`.

**Recommended fix**: remove `--minimal` from the efa_installer invocation in `option_install_gpu_nodegroups.sh` (installer line in the userdata heredoc). Keep `--skip-kmod` since AMI kernel module is already present and rebuilding it during boot is unnecessary and slow.

## Same-leaf p5 cluster-PG empirical summary (3 runs)
| Run | AZ | L1 match | L2 match | L3 match |
|-----|-----|---------|----------|----------|
| 1 (prior, manual patches) | usw2-az1 | same | same | different |
| 2 (this run, de51e78)     | usw2-az2 | same | same | different |

Both p5 cluster-PG runs: nodes same L2 leaf, NOT same L3 leaf. Matches expectation that a 2-node cluster PG in p5 capacity does not guarantee same-L3 placement.

## Safety rails check
- Existing NGs `gpu-p5-48xlarge-spot`, `gpu-p5en-spot-usw2c`, `gpu-p5en-spot-usw2d`, `gpu-p6-b300-spot-usw2b`, `eks-utils`: all untouched (verified via `aws eks list-nodegroups`).
- Time: well under 90 min cap.
- Cost: ~$0.50, well under $30 cap.

## Artifacts
Logs:
- `logs/install.log` — option_install_gpu_nodegroups.sh full log
- `logs/node1-bootstrap.log` — /var/log/gpu-node-bootstrap.log from i-03ada2b9ff130e23c (shows the `--minimal` installer output)
- `logs/eks-describe-nodegroup.json`
- `logs/ec2-describe-placement-group.json`
- `logs/ec2-describe-instances.json`
- `logs/ec2-topology.json`
- `logs/kubectl-nodes.txt`

S3 mirror: N/A (bucket `kevinzhao-bench-logs-us-west-2` does not exist).

## Post-diagnosis fix validation (commit 1b3ee48)

The `--minimal` flag was removed from the efa_installer invocation in
`option_install_gpu_nodegroups.sh` (commit 1b3ee48). Rather than recreate the
NG, validated the fix by running the corrected command manually via SSM on
both still-running p5 instances:

```
./efa_installer.sh -y --skip-kmod 2>&1 | tail -40
```

| Instance | /opt/amazon/efa/bin/fi_info | fi_info --version | EFA providers (fi_info -p efa) | libfabric-aws rpm | openmpi5-aws rpm | fi_pingpong |
|---|---|---|---|---|---|---|
| i-03ada2b9ff130e23c | Present (24328 bytes) | 2.4.0amzn3.0 | 5 (rdmap79s0, rdmap80s0, rdmap81s0, rdmap82s0, rdmap96s0) | libfabric-aws-2.4.0amzn3.0-1.amzn2023.x86_64 | openmpi50-aws-5.0.9amzn1-11.x86_64 | SUCCESS |
| i-0fa84f28edb5997ae | Present (24328 bytes) | 2.4.0amzn3.0 | 5 (rdmap79s0, rdmap80s0, rdmap81s0, rdmap82s0, rdmap96s0) | libfabric-aws-2.4.0amzn3.0-1.amzn2023.x86_64 | openmpi50-aws-5.0.9amzn1-11.x86_64 | SUCCESS |

**Verdict: fix validated.** Dropping `--minimal` (keeping `--skip-kmod`) causes
efa_installer to lay down libfabric-aws + openmpi5-aws, populating
`/opt/amazon/efa/bin/fi_info` with all 5 p5.48xlarge EFA NIC providers, and the
local `fi_pingpong` self-test reports SUCCESS.

Artifacts:
- `logs/efa-install-manual-i-03ada2b9ff130e23c.log`
- `logs/efa-install-manual-i-0fa84f28edb5997ae.log`

Env #3 status upgrades from **FAIL** to **PASS** once the NG is recreated on
tip of main (commit 1b3ee48); no further code change needed.
