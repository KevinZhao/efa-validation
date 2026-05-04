# Teardown — p5-az1 P1+P3 validation

## Order
1. Delete smoke pod yanxi-validation/p5-efa-smoke — done, wait=false.
2. Delete NG gpu-p5-48xlarge-spot-az1-p3 — started 15:14:40Z, completed ~15:26Z (≈11 min end-to-end, both instances terminated).
3. Delete PG gpu-cluster-oregon-p5-48xlarge-us-west-2a-spot-az1-p3-cg — succeeded once NG deletion completed (instances terminated).
4. Delete LT gpu-cluster-oregon-gpu-p5-48xlarge-spot-az1-p3-lt (lt-09abf019f5a83d8c1) — succeeded.
5. Also cleaned up leftover `gpu-g7e-48xlarge-spot-az1-p3` NG from an earlier misconfigured pass (GPU_INSTANCE_TYPES was overridden by .env). Deleted at creation time; DELETING completed ~15:29Z.
6. Also cleaned up PG `gpu-cluster-oregon-g7e-48xlarge-us-west-2a-spot-az1-p3-cg` (created during that misconfigured pass).

## Final cluster state
Nodegroups now in gpu-cluster-oregon (unchanged from pre-test baseline):
- eks-utils
- gpu-p5-48xlarge-spot (pre-existing; untouched)
- gpu-p5en-spot-usw2c (pre-existing; untouched)
- gpu-p5en-spot-usw2d (pre-existing; untouched)
- gpu-p6-b300-spot-usw2b (sibling agent's NG in usw2-az2; untouched)

## Cost
- 2× p5.48xlarge Spot in us-west-2a running ~26 min (15:01Z → 15:27Z terminated)
- p5.48xlarge Spot Oregon is typically $15-20/hr per instance (per memory guidance $18/hr × 2 for budgeting)
- Actual compute burn: 2 × 0.43 hr × ~$18 = ~$15.50
- Well under the $50 cost cap
