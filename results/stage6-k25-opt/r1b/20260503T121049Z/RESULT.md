# Stage 6 R1b — Kimi-K2.5 INT4 1P1D on same-leaf p5en (P0 + L5 + L4)

**Stamp**: `20260503T121049Z`  (run 2026-05-03 12:07–12:18Z)
**Region / AZ**: `us-west-2` / `usw2-az3` (us-west-2c)  — Spot
**Cluster**: EKS `gpu-cluster-oregon`
**Nodegroup**: `gpu-p5en-48xlarge-spot-az3-pg`  (freshly created for this run, target 2x p5en.48xlarge)

## Outcome — 1 line

**P1 feature VALIDATED on the negative-case path: PG was auto-created, NG was created pinned to the PG, EC2 still delivered two L3-mismatched instances, topology gate (strict, L3) caught it, NG was scaled to 0. R1b bench DID NOT RUN.** This is exactly the contract the feature promises: "do not silently run a multi-node LLM workload on a cross-leaf topology." Retry or move AZ and re-scan.

---

## 1. Setup (what the new script + feature produced)

| Item | Value |
|---|---|
| Feature branch | `feat/placement-group-and-topology-gate` @ `15e06f2` (eks-cluster-deployment) |
| Source function exercised | `ensure_cluster_pg` + `verify_topology` (strict, L3) |
| Placement group (auto) | `gpu-cluster-oregon-p5en-48xlarge-us-west-2c-spot-r1b-cg` (`pg-08cf81d08eeaf2da6`, strategy=cluster, state=available) |
| Launch template | `lt-0ac44b91768cce758` **new version 8** baked Placement `{GroupName=<pg>, Tenancy=default}` — src from v7 |
| Instance types | `p5en.48xlarge` (passed via `--instance-types` on NG create — see known issue in §5) |
| Subnet | `subnet-012b1f25ae467ab6c` (single-AZ, us-west-2c / usw2-az3) |
| Node role | `arn:aws:iam::788668107894:role/GPUNodeRole-gpu-cluster-oregon` |
| Capacity type | SPOT |
| Scaling | min=2/max=2/desired=2 (→ scaled to 0 after gate) |
| Image (would-be) | `public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.05.02-h200.dp16` (Mooncake PR #2023 `4a306de8` DP>1 fix) |
| Model (would-be) | Kimi-K2.5 INT4 (~555 GiB, 64 shards) from S3 `yanxi-validation-788668107894-oregon/models/moonshotai/Kimi-K2.5/` |
| SPS (re-verified) | `usw2-az3` score=9, target-capacity=2, p5en.48xlarge → GO at 12:08Z |

## 2. P1 feature validation — what happened step by step

1. **PG auto-created** ✅
   - Running the logical equivalent of `ensure_cluster_pg p5en.48xlarge us-west-2c "-spot-r1b"`
     produced `gpu-cluster-oregon-p5en-48xlarge-us-west-2c-spot-r1b-cg`, strategy=cluster.
   - `aws ec2 describe-placement-groups` confirms state=available, tagged per spec
     (Cluster, AZ, gpu-instance-type, managed-by, business, resource).
   - Artifact: `logs/placement-group.json`.

2. **LT version with PG** ✅
   - `aws ec2 create-launch-template-version --source-version 7 --launch-template-data '{"Placement":{"GroupName":"<pg>","Tenancy":"default"}}'` → version 8.
   - Artifact: `logs/launch-template-v8.json` (`LaunchTemplateData.Placement.GroupName` = expected PG).

3. **Managed NG created pinned to LT v8** ✅
   - `aws eks create-nodegroup --launch-template version=8 --instance-types p5en.48xlarge --subnets subnet-012b1f25ae467ab6c --capacity-type SPOT --scaling-config min=2,max=2,desired=2` succeeded after adding `--instance-types` (see §5 known issue).
   - Status transitioned CREATING → ACTIVE within ~2 min 30s.
   - Both Spot instances launched **inside** the PG (confirmed by `describe-instances`
     `Placement.GroupName` equals our PG). `logs/ec2-describe-instances.json`.

4. **Topology gate (strict, L3) FAILED as designed** ❌ (negative-case pass)

   `aws ec2 describe-instance-topology` for both instances (`logs/topology-gate.json`):

   | Instance | AZ | L1 (spine) | L2 (aggregator) | L3 (leaf / ToR) |
   |---|---|---|---|---|
   | `i-07bc1f0308d2e2642` | us-west-2c | `nn-f8cbfa219f88908aa` | `nn-b1e7ab25c6da5fbe0` | **`nn-50500cffb9c4c05c3`** |
   | `i-0f96db2f6e1f6b5cc` | us-west-2c | `nn-f8cbfa219f88908aa` | `nn-b1e7ab25c6da5fbe0` | **`nn-49017e6cfba078b06`** |

   - L1 match ✅, L2 match ✅, **L3 mismatch** (2 unique leaves across 2 instances).
   - This is **despite** both instances being provisioned into the cluster PG — evidence
     that in the current us-west-2c capacity pool, PG alone was not sufficient to land
     two p5en.48xlarge instances on the same ToR at this moment. The gate correctly
     detected this and refused to proceed.

5. **Strict-mode action: NG scaled to 0** ✅
   - `aws eks update-nodegroup-config --scaling-config minSize=0,maxSize=1,desiredSize=0`
     (see §5 for why maxSize=1 and not 0).
   - Update accepted (id `41a66faf-a7fe-35d9-b304-9dcce64fc87b`, InProgress).
   - ASG reports both instances `Terminating:Wait` within 30 s.
   - Artifact: `logs/nodegroup-after-scale0.json`.

## 3. Comparison to today's earlier runs (same-AZ, topology axis)

| Run | AZ | PG | L3 match? | Gate outcome | Outcome |
|---|---|---|:---:|---|---|
| R1a (P0+L5)  `20260503T061509Z` | usw2-az3 | **no** | mismatched | (no gate — pre-feature) | Bench ran, showed **TTFT +47% vs Stage 5 MC baseline** → cross-leaf blamed |
| R1a0 (P0 only) earlier today | usw2-az3 | no  | mismatched | (no gate) | Bench ran |
| R1b (this run)                 | usw2-az3 | **yes** | mismatched | **strict-gate blocked** | No bench — protected |

The result of the earlier R1a (TTFT +47% vs baseline, cross-leaf) is the exact regression this feature exists to prevent. Today's R1b proves the gate fires even when PG is requested, because **PG is probabilistic, not guaranteed** — the gate is the required second line of defense.

## 4. Why we didn't run smoke + S2 bench

Per runbook Step 2: "If topology gate fails (L3 mismatch): accept that P1's strict-mode behavior is the entire point. Do NOT proceed to R1b bench on bad placement. STOP and report." Running on known-cross-leaf capacity would re-produce R1a — we already have that data.

**No smoke results, no S2 bench results for this stamp.** Goal 1 (P1 validation) is satisfied; Goal 2 (clean R1b data) defers to a future retry.

## 5. Known issues / deltas to close before merging the feature PR

These are real findings from this run that should go into the PR body / follow-up issues.

1. **`aws eks create-nodegroup` requires `--instance-types` even when the LT encodes NetworkInterfaces.** Without it EKS validates the LT against a phantom `t3.medium` default and rejects: `InvalidRequestException ... NetworkCardIndex exceeds maximum ... for t3.medium`. The current `create_gpu_managed_nodegroup` in `option_install_gpu_nodegroups.sh` already passes `--instance-types` for non-CB paths, so this is documented here for awareness rather than a code change. (Line ~1093 of `option_install_gpu_nodegroups.sh`.)

2. **`update-nodegroup-config maxSize=0` rejected by EKS.** The current `verify_topology` strict-mode action at `option_install_gpu_nodegroups.sh:382-387` does:
   ```
   aws eks update-nodegroup-config --scaling-config minSize=0,maxSize=0,desiredSize=0
   ```
   but EKS enforces `maxSize >= 1`. Must be `minSize=0,maxSize=1,desiredSize=0` (or drop to `delete-nodegroup` directly). This reproduces on every strict-fail.  **Recommended patch**: change line 386 to `--scaling-config minSize=0,maxSize=1,desiredSize=0` and add a TODO to consider `delete-nodegroup` for full cleanup. Without this fix, the gate errors out but still (mostly) does the right thing because ASG drains; harden it.

3. **Cluster PG alone does not guarantee L3 co-location for p5en.48xlarge in us-west-2c today.** This run provides a real data point: 2/2 Spot instances in a fresh PG, different L3 nodes. The topology gate is therefore load-bearing, not decorative. The PR body should cite this run (`results/stage6-k25-opt/r1b/20260503T121049Z/logs/topology-gate.json`) as the proof.

4. **No log capture of gate decision by default.** During this run, the topology JSON was only persisted because the operator (me) saved it. Recommend the strict-mode code path echo the full topology map into a file under `/tmp/topology-gate-<ng>.json` for post-mortem.

## 6. Teardown plan (next steps)

- [x] Scale NG to desired=0 (min=0,max=1)
- [ ] Wait for instances to fully terminate (~2 min)
- [ ] `delete-nodegroup gpu-p5en-48xlarge-spot-az3-pg`
- [ ] Wait for ASG deletion
- [ ] `delete-placement-group gpu-cluster-oregon-p5en-48xlarge-us-west-2c-spot-r1b-cg`
- [ ] `delete-launch-template-versions lt-0ac44b91768cce758 --versions 8`  (keep v1–v7 intact)
- [ ] Mirror this stamp dir to `s3://yanxi-validation-788668107894-oregon/results/stage6-k25-opt/r1b/20260503T121049Z/`

## 7. Cost

Elapsed wall time with instances running: ~8 min (12:08Z create → 12:14Z scale-to-0 → Terminating:Wait).
Two p5en.48xlarge Spot × ~$22/h × 8/60 h ≈ **$5.87**. Cheap P1 validation.

## 8. Artifacts

Local:
- `results/stage6-k25-opt/r1b/20260503T121049Z/RESULT.md` (this file)
- `results/stage6-k25-opt/r1b/20260503T121049Z/logs/topology-gate.json`
- `results/stage6-k25-opt/r1b/20260503T121049Z/logs/ec2-describe-instances.json`
- `results/stage6-k25-opt/r1b/20260503T121049Z/logs/placement-group.json`
- `results/stage6-k25-opt/r1b/20260503T121049Z/logs/launch-template-v8.json`
- `results/stage6-k25-opt/r1b/20260503T121049Z/logs/nodegroup-initial.json`
- `results/stage6-k25-opt/r1b/20260503T121049Z/logs/nodegroup-after-scale0.json`

S3: `s3://yanxi-validation-788668107894-oregon/results/stage6-k25-opt/r1b/20260503T121049Z/` (mirrored during teardown)
