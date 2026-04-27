# Spot Placement Score — US Regions, 4× GPU instances

**Date (UTC)**: 2026-04-23 (re-scan 13:46 UTC)
**Account**: 788668107894
**US commercial regions in scope** (account opt-in): us-east-1, us-east-2, us-west-1, us-west-2
**GovCloud** (us-gov-east-1 / us-gov-west-1): not enabled on this account (separate partition)
**Target capacity**: 4 instances, Spot
**API**: `ec2:GetSpotPlacementScores`
**Script**: `scripts/spot-placement-score.sh`

> Scale: **1 (lowest) → 10 (highest)**. Scores fluctuate minute-to-minute; a high score is a *time-of-day* signal, not a contract.

## Change vs prior scan (11:32 UTC, 2 hours earlier)

| Instance | Prior best | **Now best** |
|---|---|---|
| `p5.48xlarge` | us-east-1 / use1-az3 = 3 | **us-west-2 / usw2-az2 = 9** ⬆ |
| `p5e.48xlarge` | 1 everywhere | 1 everywhere |
| `p5en.48xlarge` | 1 everywhere | **us-west-2 / usw2-az3 = 9** ⬆ |
| `p6-b200.48xlarge` | 1 everywhere | 1 everywhere |
| `p6-b300.48xlarge` | us-west-2b = 1 | **us-west-2 / usw2-az2 = 3** ⬆ |

Oregon's Hopper/Blackwell inventory loosened substantially over the last 2 hours.

## Region-level SPS (capacity=4)

| Instance | us-east-1 | us-east-2 | us-west-1 | us-west-2 |
|---|---|---|---|---|
| `p5.48xlarge` | 1 | 1 | 1 | **9** |
| `p5e.48xlarge` | — | 1 | — | 1 |
| `p5en.48xlarge` | 1 | 1 | 1 | **9** |
| `p6-b200.48xlarge` | 1 | 1 | — | 1 |
| `p6-b300.48xlarge` | — | — | — | **3** |

## AZ-level SPS (single-AZ, capacity=4)

### p5.48xlarge

| Region | AZ ID | AZ name | Score |
|---|---|---|---|
| us-west-2 | usw2-az2 | us-west-2b | **9** |
| us-west-2 | usw2-az3 | us-west-2c | 1 |
| us-west-2 | usw2-az4 | us-west-2d | 1 |
| us-east-1 | use1-az1 | us-east-1a | 1 |
| us-east-1 | use1-az2 | us-east-1b | 1 |
| us-east-1 | use1-az3 | us-east-1e | 1 |
| us-east-1 | use1-az4 | us-east-1c | 1 |
| us-east-1 | use1-az5 | us-east-1f | 1 |
| us-east-2 | use2-az1 | us-east-2a | 1 |
| us-east-2 | use2-az3 | us-east-2c | 1 |

### p5e.48xlarge

| Region | AZ ID | AZ name | Score |
|---|---|---|---|
| us-east-2 | use2-az1 | us-east-2a | 1 |
| us-east-2 | use2-az2 | us-east-2b | 1 |
| us-east-2 | use2-az3 | us-east-2c | 1 |
| us-west-2 | usw2-az3 | us-west-2c | 1 |

### p5en.48xlarge

| Region | AZ ID | AZ name | Score |
|---|---|---|---|
| us-west-2 | usw2-az3 | us-west-2c | **9** |
| us-west-2 | usw2-az2 | us-west-2b | 1 |
| us-west-2 | usw2-az4 | us-west-2d | 1 |
| us-east-1 | use1-az2 | us-east-1b | 1 |
| us-east-1 | use1-az6 | us-east-1d | 1 |
| us-east-2 | use2-az1 | us-east-2a | 1 |
| us-east-2 | use2-az2 | us-east-2b | 1 |
| us-east-2 | use2-az3 | us-east-2c | 1 |
| us-west-1 | usw1-az3 | us-west-1c | 1 |

### p6-b200.48xlarge

| Region | AZ ID | AZ name | Score |
|---|---|---|---|
| us-east-1 | use1-az6 | us-east-1d | 1 |
| us-east-2 | use2-az1 | us-east-2a | 1 |
| us-east-2 | use2-az2 | us-east-2b | 1 |
| us-east-2 | use2-az3 | us-east-2c | 1 |
| us-west-2 | usw2-az1 | us-west-2a | 1 |
| us-west-2 | usw2-az2 | us-west-2b | 1 |
| us-west-2 | usw2-az4 | us-west-2d | 1 |

### p6-b300.48xlarge

| Region | AZ ID | AZ name | Score |
|---|---|---|---|
| us-west-2 | usw2-az2 | us-west-2b | **3** |

**Only AZ in all US where this instance has any Spot signal.**

## Top AZ picks per instance (4× Spot, NOW)

- `p5.48xlarge` → **us-west-2b (usw2-az2) = 9** ⭐
- `p5e.48xlarge` → no winner; us-east-2 or us-west-2c
- `p5en.48xlarge` → **us-west-2c (usw2-az3) = 9** ⭐
- `p6-b200.48xlarge` → no winner; us-east-2 all-AZ spread or us-west-2
- `p6-b300.48xlarge` → **us-west-2b only**, score 3

## Caveats

1. Scores from this account; SPS is scoped per-account.
2. Oregon looks strong *now*. If launch is more than ~1 hour away, re-scan before firing.
3. No signal from GovCloud (would need separate credentials in the `aws-us-gov` partition).
4. Actual launch requires EC2/Spot Fleet `capacity-optimized` — SPS doesn't reserve.
