# Spot Placement Score — US Regions, 4× GPU instances

**Date (UTC)**: 2026-04-23
**Account**: 788668107894
**Target capacity**: 4 instances, Spot, single-AZ scope for AZ results
**API**: `ec2:GetSpotPlacementScores`
**Source data**: `*.json` in this directory
**Script**: `scripts/spot-placement-score.sh`

> Scoring scale: **1 (lowest) → 10 (highest)**. A score of `1` does NOT mean "will succeed"; it means AWS's internal model returns the lowest confidence bucket. Per AWS docs, SPS is a hint, not a guarantee — validate with an actual Spot request.

## Instance availability (regions where offered to this account)

| Instance | us-east-1 (N. Virginia) | us-east-2 (Ohio) | us-west-1 (N. California) | us-west-2 (Oregon) |
|---|---|---|---|---|
| `p5en.48xlarge` | offered | offered | offered | offered |
| `p6-b200.48xlarge` | offered | offered | — | offered |
| `p6-b300.48xlarge` | — | — | — | offered |

(Queried via `ec2:DescribeInstanceTypeOfferings` on 2026-04-23.)

## Region-level SPS (capacity=4)

| Instance | Region scores |
|---|---|
| `p5en.48xlarge` | us-east-1 = **1**, us-east-2 = **1**, us-west-1 = **1**, us-west-2 = **1** |
| `p6-b200.48xlarge` | us-east-1 = **1**, us-east-2 = **1**, us-west-2 = **1** |
| `p6-b300.48xlarge` | us-west-2 = **1** |

## AZ-level SPS (capacity=4, single-AZ)

Only AZs that the API returned a score for appear below. **AZs that did not appear** were scored below the minimum threshold (effectively "not recommended").

### p5en.48xlarge — 9 AZs returned, all score **1**

| Region | AZ ID | AZ name |
|---|---|---|
| us-east-1 | use1-az2 | us-east-1b |
| us-east-1 | use1-az6 | us-east-1d |
| us-east-2 | use2-az1 | us-east-2a |
| us-east-2 | use2-az2 | us-east-2b |
| us-east-2 | use2-az3 | us-east-2c |
| us-west-1 | usw1-az3 | us-west-1c |
| us-west-2 | usw2-az2 | us-west-2b |
| us-west-2 | usw2-az3 | us-west-2c |
| us-west-2 | usw2-az4 | us-west-2d |

**AZs NOT returned** (likely 0-capacity hint): us-east-1a / 1c / 1e / 1f, us-west-1a, us-west-2a.

### p6-b200.48xlarge — 7 AZs returned, all score **1**

| Region | AZ ID | AZ name |
|---|---|---|
| us-east-1 | use1-az6 | us-east-1d |
| us-east-2 | use2-az1 | us-east-2a |
| us-east-2 | use2-az2 | us-east-2b |
| us-east-2 | use2-az3 | us-east-2c |
| us-west-2 | usw2-az1 | us-west-2a |
| us-west-2 | usw2-az2 | us-west-2b |
| us-west-2 | usw2-az4 | us-west-2d |

**AZs NOT returned**: us-east-1 (all except 1d), us-west-2c.

### p6-b300.48xlarge — 1 AZ returned, score **1**

| Region | AZ ID | AZ name |
|---|---|---|
| us-west-2 | usw2-az2 | us-west-2b |

**Only AZ with any Spot capacity signal.** All other Oregon AZs returned no score.

## Interpretation

1. **All returned scores are 1/10.** This is consistent with how AWS reports large-GPU Spot: the model refuses to promise, even where capacity does exist. Treat this as *"possibly available"* — the AZ shortlist is still the useful output.
2. **Shortlist to try first for 4× Spot**:
   - `p5en.48xlarge` → widest footprint; try us-east-2b / us-east-2a / us-west-2d first (same-account bastions already there), fall back to us-west-1c, us-east-1d/b.
   - `p6-b200.48xlarge` → us-east-2 (all three AZs), us-west-2a/b/d, us-east-1d.
   - `p6-b300.48xlarge` → **us-west-2b only**. No other US AZ returned a score.
3. **Next step to actually prove it**: a dry-run `RunInstances --instance-market-options Spot` (or a small Spot Fleet / EC2 Fleet with `lowest-price` strategy across the shortlisted AZs) — SPS does not reserve capacity.

## Files

- `p5en.48xlarge-region.json`, `p5en.48xlarge-az.json`
- `p6-b200.48xlarge-region.json`, `p6-b200.48xlarge-az.json`
- `p6-b300.48xlarge-region.json`, `p6-b300.48xlarge-az.json`
