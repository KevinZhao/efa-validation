# Spot Placement Score — US Regions, 4× GPU instances

**Date (UTC)**: 2026-04-23
**Account**: 788668107894
**Target capacity**: 4 instances, Spot
**API**: `ec2:GetSpotPlacementScores`
**Source data**: `*.json` in this directory
**Script**: `scripts/spot-placement-score.sh`

> Scale: **1 (lowest) → 10 (highest)**. Score 1 does NOT mean "unavailable" — it means AWS's model refuses to give a confident signal. Any score ≥ 2 is more informative. SPS is a hint, not a reservation.

## Instance availability (regions where offered to this account)

| Instance | us-east-1 | us-east-2 | us-west-1 | us-west-2 |
|---|---|---|---|---|
| `p5.48xlarge` | ✅ | ✅ | ✅ | ✅ |
| `p5e.48xlarge` | — | ✅ | — | ✅ |
| `p5en.48xlarge` | ✅ | ✅ | ✅ | ✅ |
| `p6-b200.48xlarge` | ✅ | ✅ | — | ✅ |
| `p6-b300.48xlarge` | — | — | — | ✅ |

## Region-level SPS (capacity=4)

| Instance | us-east-1 | us-east-2 | us-west-1 | us-west-2 | Best |
|---|---|---|---|---|---|
| `p5.48xlarge` | **3** | 1 | 1 | 1 | **us-east-1 = 3** |
| `p5e.48xlarge` | — | 1 | — | 1 | tied |
| `p5en.48xlarge` | 1 | 1 | 1 | 1 | tied |
| `p6-b200.48xlarge` | 1 | 1 | — | 1 | tied |
| `p6-b300.48xlarge` | — | — | — | 1 | us-west-2 only option |

## AZ-level SPS (single-AZ, capacity=4)

### p5.48xlarge (only line item with >1 scores)

| Region | AZ ID | AZ name | Score |
|---|---|---|---|
| us-east-1 | use1-az3 | us-east-1e | **3** |
| us-east-1 | use1-az5 | us-east-1f | 1 |
| us-east-2 | use2-az1 | us-east-2a | 1 |
| us-east-2 | use2-az2 | us-east-2b | 1 |
| us-east-2 | use2-az3 | us-east-2c | 1 |
| us-west-1 | usw1-az3 | us-west-1c | 1 |
| us-west-2 | usw2-az1 | us-west-2a | 1 |
| us-west-2 | usw2-az2 | us-west-2b | 1 |
| us-west-2 | usw2-az3 | us-west-2c | 1 |
| us-west-2 | usw2-az4 | us-west-2d | 1 |

### p5e.48xlarge — 4 AZs, all score 1

| Region | AZ ID | AZ name |
|---|---|---|
| us-east-2 | use2-az1 | us-east-2a |
| us-east-2 | use2-az2 | us-east-2b |
| us-east-2 | use2-az3 | us-east-2c |
| us-west-2 | usw2-az3 | us-west-2c |

### p5en.48xlarge — 9 AZs, all score 1

us-east-1b/d, us-east-2a/b/c, us-west-1c, us-west-2b/c/d

### p6-b200.48xlarge — 7 AZs, all score 1

us-east-1d, us-east-2a/b/c, us-west-2a/b/d

### p6-b300.48xlarge — 1 AZ, score 1

**us-west-2b (usw2-az2) only**. No other US AZ returned any score.

## Interpretation

1. **Only `p5.48xlarge` got a non-trivial score.** `us-east-1e` scored **3/10**, the rest are all **1/10**. For Hopper (H100) 4× Spot, N. Virginia is the best bet.
2. Everything else (p5e, p5en, p6-b200, p6-b300) returns the floor score of 1 everywhere it returns at all. Use the AZ shortlist, not the number, to pick where to launch.
3. `p6-b300` has exactly one viable US AZ (**us-west-2b**); if the job requires B300, Oregon is the only door.

## Top AZ picks per instance (4× Spot)

- `p5.48xlarge` → **us-east-1e** (score 3); fallbacks: us-east-1f, us-east-2a/b/c.
- `p5e.48xlarge` → us-east-2 (a/b/c) for 3-AZ spread; Oregon has only us-west-2c.
- `p5en.48xlarge` → us-east-2 (a/b/c), us-west-2 (b/c/d).
- `p6-b200.48xlarge` → us-east-2 (a/b/c) all three in one region; else us-west-2a/b/d or us-east-1d.
- `p6-b300.48xlarge` → **us-west-2b only**.

## Files

- `p5.48xlarge-{region,az}.json`
- `p5e.48xlarge-{region,az}.json`
- `p5en.48xlarge-{region,az}.json`
- `p6-b200.48xlarge-{region,az}.json`
- `p6-b300.48xlarge-{region,az}.json`
