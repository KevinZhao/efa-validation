# R1b · Kimi-K2 1P:2D — ABORTED

**Planned**: 1 prefill + 2 decode on 3 × p5en, same bench config as R1a.
**Outcome**: Aborted mid-bench (≈ request 75/128) when all 3 p5en Spot instances were reclaimed by AWS within ~2 minutes.

## Timeline

- 09:20Z: 3rd p5en (`i-0999442128e41a790`, 10.1.11.88) ready in use2-az1
- 09:03Z → 09:18Z: HF prefetch to its `/mnt/nvme` (959 GB, 15 min)
- 09:19Z: R1b applied; prefill/decode-0/decode-1/LB scheduled
- 09:29Z: all 4 pods 1/1 Ready (cold start ~10 min)
- 09:29Z: bench start (rate=4, 128 prompts, random 1024/512)
- ~09:31Z: bench mid-flight (≈ 75/128 progress shown) → `ConnectionRefusedError ('172.20.184.203', 8000)` on every subsequent request
- 09:33Z: investigation: `sglang-r1b-lb` pod in Terminating, kubelet Killing
- 09:33Z: `kubectl get node -o wide` shows **all 3 p5en NotReady,SchedulingDisabled**
- 09:33Z: `aws ec2 describe-instances`: two p5en already Terminated (`i-025388ac45366a78d`, `i-0a599cca49c3a8875`), third `shutting-down`
- 09:33Z: SPS use2-az1 **dropped 9 → 1** minutes ago; use2-az2 still 9
- 09:35Z: NG health still ACTIVE, trying to replace into az1 (SPS=1) — expected to churn

## Root cause

AWS Spot capacity reclaim hit all 3 p5en in use2-az1 near-simultaneously. This is a standard capacity-shortage signal, not a fault. Typical cause: a burst of On-Demand / Capacity Block requests in the same AZ forced AWS to reclaim Spot.

## Data loss

- `/mnt/nvme/models/Kimi-K2-Instruct-0905` on all 3 nodes gone (instance-store is ephemeral).
- `.hf-cache` metadata that could have accelerated re-download also gone.
- R1b bench produced no valid summary (bench_serving.py aborted; no `============ Serving Benchmark Result ============` emitted).

## Lessons saved to memory

- `feedback_spot_reclaim_wipes_nvme.md` — Spot reclaim erases `/mnt/nvme`; multi-node Spot reclaim tends to happen concurrently in one AZ.
- Proposal to harden: S3 mirror of prefetched models, or use On-Demand/ODCR for 3+ node PD sweeps.

## Next decision

Options (in order of preference):

1. **Wait for NG auto-replace into use2-az2** (SPS=9). But current NG only allows use2-az1. Need to widen subnet list or create new NG for az2 — ~30 min extra.
2. **Switch to us-west-2 usw2-az3** (SPS=7). Have pre-built NG already (see RUNBOOK / Stage 5 plan Oregon NGs). Re-mirror image + FSx PVC to Oregon for Kimi-K2 was already done; could redeploy R1b there.
3. **Fall back to On-Demand p5en x 3** (no Spot risk). ~$380/h × expected 4 h = $1.5k to finish R1b + R1c.
4. **Abandon R1b today, retry in next window** after SPS recovery.

Chosen: TBD by operator.
