# Smoke test — reproducing 2026-05-06T02:30Z session on fresh hardware

**Purpose**: confirm the 2026-05-06 phase-10 Grid A numbers
(`~448µs @ (128,22)`, roughly 90× below Sprint A/B's `40ms`) are a
stable property of the kernel + EP=16 p5en setup, not a session-local
artefact. If they reproduce, `feat/sm-stripe-overlap` can carry a
real performance claim. If they diverge, the 2026-05-06 read was
noise and we need to halt any PR motion.

## Setup

| field | 2026-05-06T02:30Z (reference) | 2026-05-06T09:30Z (smoke) |
|---|---|---|
| region / AZ | apne1-az4 | apne1-az4 |
| NG | yanxi-eks-tokyo / gpu-p5en-48xlarge-spot | same |
| instances | i-0ffeb9fc8d5e6719b + i-01c3b536c1639af11 | **i-00a7319d96ca73df1 + i-0fb930d3f56086be0** (different hardware) |
| node IPs | 10.99.10.181 / 10.99.10.19 | **10.99.10.198 / 10.99.10.27** |
| Layer-3 leaves | nn-b117…5f85 / nn-c3ef…be27 | **nn-36828d…b9b4e / nn-1ebfda…5c7b7** |
| image | nvcr.io/nvidia/pytorch:25.10-py3 | same |
| commit | `16785c9` (`feat/sprint-a-generalization-bench`) | `f30bdb6` (`feat/sm-stripe-overlap`, clean base) |
| build | `TORCH_CUDA_ARCH_LIST=9.0`, no probe | same |
| bench | `--workload-tokens=128,256,384,512,768,1024 --workload-sms=22,48,96` | **subset**: `--workload-tokens=128,256,384 --workload-sms=22,48,96` |
| `--num-iters` | 20 | 20 |

Same `num_rdma_bytes=20GiB`, same topk / experts / hidden, same
world_size=16. The only differences are the physical hardware pair,
the git commit hash (clean branch = same kernel, dropped K-1b /
adaptive residues), and the ntok subset.

## Per-cell results (median p99 µs across 16 ranks × 18 iters)

| ntok | nsms | smoke p99 | ref p99 | ratio (smoke/ref) | smoke min | ref min |
|---:|---:|---:|---:|---:|---:|---:|
| 128 | 22 | **446.9** | 447.5 | **0.998** | 211.5 | 211.2 |
| 128 | 48 | 559.4 | 558.8 | 1.001 | 142.0 | 138.3 |
| 128 | 96 | 603.5 | 600.3 | 1.005 | 127.6 | 124.1 |
| 256 | 22 | 1145.0 | 1135.9 | 1.008 | 287.3 | 285.8 |
| 256 | 48 | 1068.4 | 1061.0 | 1.007 | 262.3 | 283.4 |
| 256 | 96 | 1147.9 | 1149.7 | 0.998 | 198.5 | 200.1 |
| 384 | 22 | 1515.3 | 1516.7 | 0.999 | 529.6 | 517.4 |
| 384 | 48 | 1525.6 | 1537.3 | 0.992 | 380.9 | 380.7 |
| 384 | 96 | 1552.9 | 1557.4 | 0.997 | 348.3 | 339.2 |

All 9 cells are within **±1 %** of the 2026-05-06 reference. The
(128, 22) — our headline decode case — reproduced to within 0.1 µs
(447 vs 448).

## Gate verdict

| gate | rule | result |
|---|---|---|
| reproduction | (128,22) p99 ∈ [400, 500] µs | **PASS** (447 µs) |
| decode win | p99(128,22) ≤ 0.75 × p99(128,96) | **PASS** (ratio 0.740, **26 % reduction**) |

## What this settles

1. The 2026-05-06T02:30Z Grid A numbers are a **reproducible property
   of the SM-stripe kernel** on p5en EP=16, not session noise. Tested
   across two independent leaf pairs and two independent physical
   hardware samples taken from the same spot pool ~7 hours apart.
2. The **Sprint A / Sprint B p99 ≈ 40 ms** measurements must have
   been contaminated by a different source (bench hygiene issue,
   host noise on those specific spot instances, …). They are not
   a property of the kernel. Any claim derived from those numbers
   (K-1b target, tier values, `num_sms=3` prior assumption) remains
   obsoleted; this smoke run adds no new support for them.
3. The 26 % decode p99 reduction at `num_tokens=128, num_sms=22` vs
   `num_sms=96` is a **shipable performance property** of the
   SM-stripe kernel. It survives:
     - different physical hardware samples,
     - different Layer-3 leaves (both cross-leaf),
     - clean-base git commit (no K-1b / adaptive residues).

## What this does NOT settle

- **Same-leaf behaviour**: both sessions so far have been cross-leaf
  (two different leaf pairs). We still do not have a same-leaf
  p99 number to compare. Plausible effect: same leaf may further
  reduce p99 but not by the orders of magnitude Sprint A reported.
  A third session landing on a same-leaf pair is needed to bound
  the cross-leaf penalty (and may not happen without burning more
  spot rolls).
- **ntok ≥ 512 behaviour**: smoke ran only `{128, 256, 384}`. The
  2026-05-06 reference showed (512, 96) / (768, 96) / (1024, 96) as
  the prefill sweet spots; the smoke run does not re-validate these.
  Next session targeting prefill should cover these cells.
- **Probe v2 shares are not re-run**. The 2026-05-06 probe
  decomposition (body 82-94 %, init 3-11 %, sync 26-55 %) still
  stands as single-session data. If K-T_sync work is about to
  begin, it would be cheap to add a probe re-run in the next
  session for extra confidence.

## Decision

- The SM-stripe kernel on `feat/sm-stripe-overlap` has a
  reproducible 26 % decode p99 reduction at (128, 22).
  **Unblock the upstream PR path** — a minimal PR containing only the
  SM-stripe kernel + tests (no bench research tooling, no probe v2)
  is defensible against this smoke data.
- The adaptive tier table verdict stands: **do not** land it.
  The tier values were derived from Sprint A's noisy measurements.
- K-T_sync remains the right next kernel target based on probe v2
  shares; smoke does not contradict that.

## Cost and teardown

- p5en uptime: 09:14 → 09:30Z ≈ 16 min (node warm + image pull +
  build + 9 × 20-iter bench)
- estimated spot spend: ≈ \$5
- teardown: ASG scaled to 0 at 09:30Z; both instances in
  `shutting-down` within 10 s
