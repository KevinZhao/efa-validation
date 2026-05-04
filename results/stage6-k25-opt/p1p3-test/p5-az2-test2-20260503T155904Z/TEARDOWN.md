# Teardown — p5-az2-test2 run 20260503T155904Z

## Timeline (UTC)
- 16:04:24 — both p5 Spot instances reached `running`
- 16:17:19 — `aws eks delete-nodegroup` issued (status DELETING)
- 16:31:56 — NG gone (ResourceNotFoundException), 20 poll attempts @ ~45 s = 14 min 37 s
- 16:32:20 — both instances confirmed `terminated`
- 16:32:22 — `aws ec2 delete-placement-group` exit 0
- 16:32:24 — `aws ec2 delete-launch-template` exit 0
- 16:32:40 — bastion `/root/eks-cluster-deployment-p3-v2` removed via SSM

Total wall clock from NG-create (~15:59:04) to full teardown (16:32:40): ~34 min.

## Final state verification

| Resource | Check | Result |
|---|---|---|
| NG `gpu-p5-48xlarge-spot-az2-test2` | `describe-nodegroup` | ResourceNotFoundException (OK) |
| PG `gpu-cluster-oregon-p5-48xlarge-us-west-2b-spot-az2-test2-cg` | `describe-placement-groups` | InvalidPlacementGroup.Unknown (OK) |
| LT `lt-0b4f1649f26a4e12f` | `describe-launch-templates` | InvalidLaunchTemplateId.NotFound (OK) |
| Instance `i-03ada2b9ff130e23c` | `describe-instances` | terminated |
| Instance `i-0fa84f28edb5997ae` | `describe-instances` | terminated |
| Bastion workdir `/root/eks-cluster-deployment-p3-v2` | SSM `ls /root` | absent |

## Other NGs untouched (safety rail PASS)
`aws eks list-nodegroups --cluster-name gpu-cluster-oregon` after teardown:
- eks-utils
- gpu-p5-48xlarge-spot
- gpu-p5en-spot-usw2c
- gpu-p5en-spot-usw2d
- gpu-p6-b300-spot-usw2b

## Cost summary
- p5.48xlarge Spot (us-west-2b) launch → terminated: 16:04:24 → ~16:32:20 = 27 min 56 s each
- 2 instances × (27.93 / 60) h × $18/h (p5.48xlarge Spot reference) = **$16.76**
- Sanity-cap target was $30 — under cap.

## Stranded resources: none
No EBS volumes, no ENIs, no orphan LTs, no orphan PGs.

## Notes
- Bastion `/root/eks-cluster-deployment-p3` and `/root/eks-cluster-deployment-p3-p6` left in place — they belong to earlier independent p3/p6 runs, not this run.
- The feature-branch `install_gpu_nodegroups.sh` fix (commit 1b3ee48, drop `--minimal`) was validated out-of-band via SSM on the live nodes before teardown; NG recreate not required. See `RESULT.md` "Post-diagnosis fix validation" section.
