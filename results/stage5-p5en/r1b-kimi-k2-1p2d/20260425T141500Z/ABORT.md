# R1b · Kimi-K2 1P:2D on 3×p5en Oregon usw2-az3 — ABORTED (Spot reclaim + pool exhaustion)

**Attempt #2 (today), same run ID as 09:15 Ohio attempt**
**Start (UTC)**: 2026-04-25T13:38Z (Oregon retry after R3 PASS)
**Region / AZ target**: us-west-2 / usw2-az3 (SPS=9 @ cap=3 at launch time)

## What happened

1. Scaled `gpu-p5en-48xlarge-spot` NG to desired=3. ASG launched 3 p5en in usw2-az3
   (us-west-2c: 10.0.13.77, 10.0.13.122, 10.0.13.235).
2. Nodes joined EKS. `/data` 28 TB auto-mounted from vg_local — Oregon p5en LT
   also has the new `GPU_ENABLE_LOCAL_LVM=true` userdata (same as p5 LT v4).
3. HF prefetch Job applied. All 3 pods downloading Kimi-K2-Instruct-0905
   (959 GB × 3 parallel).
4. **At ~22 min, 2 of 3 az3 nodes reclaimed** (`i-0fa7e98e4b4dae38c` and
   `i-09ade308b7b3dc644` both shutting-down). One node already had full weights,
   lost on instance-store teardown.
5. ASG tried to replace into az3 → **`MaxSpotInstanceCountExceeded`**. Fell back
   to az2 + az4, which are cross-AZ from remaining az3 node (Mooncake KV
   cross-AZ blocker from today's earlier R3 learning).
6. Terminated non-az3 replacements to force az3 reselection → Spot pool still
   exhausted (`MaxSpotInstanceCountExceeded` repeats).

## Outcome

- 1 of 3 target nodes survived (`i-062587bf5679c0304` in az3, had full 959 GB
  Kimi-K2 weights). Not enough for 1P:2D (requires 3 distinct nodes via
  podAntiAffinity). Teardown and retry tomorrow.

## Confirms existing memories

- `feedback_spot_reclaim_wipes_nvme.md` — Spot reclaim erases `/mnt/nvme`
  (here `/data`) weights; retry mandates re-prefetch, not reuse of orphaned
  data.
- `feedback_same_az_for_pd_disagg.md` — ASG won't honor AZ preference under
  Spot pool pressure; cross-AZ replacements force abort.
- `feedback_no_ondemand_spot_only.md` — despite 2× Spot reclaim + pool
  exhaustion in same day, still don't switch to OD.

## New observation

- Spot pool for p5en in us-west-2 **reported SPS=9 but actual launch hit
  MaxSpotInstanceCountExceeded** when the ASG requested replacements
  within minutes of a reclaim. SPS score appears to lag by 5-15 min
  relative to real-time pool state during churn.

## Next session

- Re-scan SPS tomorrow morning UTC. If Ohio use2-az2 p5en SPS ≥ 6 @ cap=3,
  retry R1b there (Ohio `gpu-p5en-spot-useast2a` is pinned to az1, need to
  either create az2 NG or use Oregon again).
- Consider creating a single-AZ-pinned p5en NG per cluster as a reusable
  pattern (e.g., `gpu-p5en-spot-useast2b`, `gpu-p5en-spot-usw2az3`) so we
  don't fight ASG multi-subnet behavior during Spot churn.
