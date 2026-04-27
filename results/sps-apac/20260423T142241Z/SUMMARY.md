# Spot Placement Score — APAC Regions, 4× GPU instances

**Date (UTC)**: 2026-04-23 14:22 UTC
**Account**: 788668107894
**Target capacity**: 4 instances, Spot
**API**: `ec2:GetSpotPlacementScores`
**Script**: `scripts/spot-placement-score-apac.sh`

## Opt-in status (APAC, account-level)

| Region | Name | Opt-in | Notes |
|---|---|---|---|
| ap-south-1 | Mumbai | ✅ opt-in-not-required | Scanned |
| ap-south-2 | Hyderabad | ❌ not-opted-in | Skipped |
| ap-east-1 | Hong Kong | ✅ opted-in | Scanned (no GPU offered) |
| ap-east-2 | Taipei | ❌ not-opted-in | Skipped |
| ap-northeast-1 | Tokyo | ✅ | Scanned |
| ap-northeast-2 | Seoul | ✅ | Scanned |
| ap-northeast-3 | Osaka | ✅ | Scanned (no GPU offered) |
| ap-southeast-1 | Singapore | ✅ | Scanned (no GPU offered) |
| ap-southeast-2 | Sydney | ✅ | Scanned |
| ap-southeast-3/4/5/6/7 | Jakarta / Melbourne / Malaysia / Thailand / NZ | ❌ | Skipped |

SPS cannot see regions that are not opted-in; to include them, enable the region and rerun.

## Instance availability in opted-in APAC

| Instance | ap-south-1 | ap-northeast-1 | ap-northeast-2 | ap-southeast-2 | Other APAC |
|---|---|---|---|---|---|
| `p5.48xlarge` | ✅ | ✅ | ✅ | ✅ | — |
| `p5e.48xlarge` | — | — | — | ✅ | — |
| `p5en.48xlarge` | ✅ | ✅ | ✅ | — | — |
| `p6-b200.48xlarge` | — | — | — | — | — |
| `p6-b300.48xlarge` | — | — | — | — | — |

(ap-east-1 / ap-northeast-3 / ap-southeast-1 have no p5/p5e/p5en/p6 offer at all.)

## Region-level SPS (capacity=4)

| Instance | ap-south-1 | ap-northeast-1 | ap-northeast-2 | ap-southeast-2 |
|---|---|---|---|---|
| `p5.48xlarge` | 1 | 1 | — ⚠ | 1 |
| `p5e.48xlarge` | — | — | — | 1 |
| `p5en.48xlarge` | 1 | **5** ⭐ | 1 | — |

⚠ `p5.48xlarge` on ap-northeast-2 (Seoul) was listed as offered but returned no region-level score (dropped below threshold).

## AZ-level SPS (single-AZ)

### p5.48xlarge — all 1

| Region | AZ ID | AZ name | Score |
|---|---|---|---|
| ap-south-1 | aps1-az1 | ap-south-1a | 1 |
| ap-south-1 | aps1-az2 | ap-south-1c | 1 |
| ap-south-1 | aps1-az3 | ap-south-1b | 1 |
| ap-northeast-1 | apne1-az1 | ap-northeast-1c | 1 |
| ap-northeast-1 | apne1-az4 | ap-northeast-1a | 1 |
| ap-southeast-2 | apse2-az1 | ap-southeast-2b | 1 |
| ap-southeast-2 | apse2-az2 | ap-southeast-2c | 1 |
| ap-southeast-2 | apse2-az3 | ap-southeast-2a | 1 |

### p5e.48xlarge — 1 AZ, score 1

| Region | AZ ID | AZ name | Score |
|---|---|---|---|
| ap-southeast-2 | apse2-az3 | ap-southeast-2a | 1 |

### p5en.48xlarge — top signal in region

| Region | AZ ID | AZ name | Score |
|---|---|---|---|
| ap-northeast-1 | apne1-az4 | **ap-northeast-1a** | **5** ⭐ |
| ap-south-1 | aps1-az1 | ap-south-1a | 1 |
| ap-south-1 | aps1-az3 | ap-south-1b | 1 |
| ap-northeast-2 | apne2-az1 | ap-northeast-2a | 1 |

### p6-b200.48xlarge / p6-b300.48xlarge

**Not offered in any opted-in APAC region as of 2026-04-23.** Blackwell remains US-only in this account.

## Top picks (APAC, 4× Spot)

| Instance | Best APAC AZ | Score |
|---|---|---|
| `p5.48xlarge` | tied — try ap-south-1 or ap-northeast-1 Fleet across 3 AZs | 1 |
| `p5e.48xlarge` | **ap-southeast-2a** (only choice) | 1 |
| `p5en.48xlarge` | **Tokyo / ap-northeast-1a (apne1-az4)** | **5** |
| `p6-b200.48xlarge` | — (not offered) | — |
| `p6-b300.48xlarge` | — (not offered) | — |

## Cross-region comparison (latest scans)

| Instance | Best US | Best APAC |
|---|---|---|
| `p5.48xlarge` | us-west-2b = 9 | 1 |
| `p5e.48xlarge` | 1 (tie across us-east-2, us-west-2c) | 1 (ap-southeast-2a only) |
| `p5en.48xlarge` | us-west-2c = 9 | Tokyo ap-northeast-1a = 5 |
| `p6-b200.48xlarge` | 1 (us-east-2 / us-west-2) | not offered |
| `p6-b300.48xlarge` | us-west-2b = 3 | not offered |

## Files

- `p5.48xlarge-{region,az}.json`
- `p5e.48xlarge-{region,az}.json`
- `p5en.48xlarge-{region,az}.json`
- `p6-b200.48xlarge-{region,az}.skip`, `p6-b300.48xlarge-{region,az}.skip` (not offered in opted-in APAC)
