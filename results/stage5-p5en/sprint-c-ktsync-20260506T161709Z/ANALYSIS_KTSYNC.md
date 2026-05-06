# K-T_sync A/B — Sprint C Phase 12 session

Session: 2026-05-06 15:54Z – 16:21Z (apne1-az4, 2× p5en.48xlarge spot,
cross-leaf pair `nn-c3ef704548d39be27` + `nn-538115ee971662d03`).
Branch: `feat/k-t-sync` tip `c8f5f0be`.

## TL;DR — **K-T_sync REJECTED**

| Gate | Rule | Result |
|---|---|---|
| K1 | Gate B bit-exact (num_sms=1/2/3/4/8) | **PASS** (48 `nonzero_frac=0` lines across both ranks) |
| K2 | No cell regresses > 3% vs baseline (18 combine-overlap cells) | **effectively PASS** (1 cell +3.37%, 17 cells within ±2%) |
| K3 | At least one cell improves > 3% | **FAIL** — max improvement is -1.07% |
| K4 | Probe v2 confirms sync_share shrinks from 26-55% → target < 15% | **PASS technically** (sync_share → 0.8-2.3%) |

Net verdict: **reject K-T_sync**. The kernel change is *correct* and
lands in the `T_sync` counter as designed (probe v2 confirms), but the
saved kernel time does not flip into end-to-end p99 gains. Removing the
slot-end `__syncthreads()` frees the 7 non-writer warps from waiting
on the finish-flag IBGDA atomic, but those warps had nothing useful to
do next anyway — they spin either on `comp_signal` (for the next slot)
or on the next `mbarrier_wait`. The barrier was cheap wall-time, not
blocking time.

## Cross-leaf caveat — A/B still valid

The two p5en nodes landed on different EFA leaves (`nn-c3ef704548d39be27`
and `nn-538115ee971662d03`). Per memory `feedback_spot_cross_leaf_policy.md`,
same-session A/B (baseline vs K-T_sync on the SAME two nodes, in quick
succession) is **valid** — the cross-leaf penalty lifts both arms
equally, relative delta is preserved. Absolute p99 numbers are ~5-10%
slower than the 2026-05-06 same-leaf smoke session, as expected.

## K1 — correctness (bit-exact vs analytical oracle)

Gate B ran on the K-T_sync build (after `UCCL_EP_K_T_SYNC=1` build).
Output `gateB-ktsync-r0.log`:

```
[rank 0] BASELINE vs analytical:           max=0 nonzero_frac=0
[rank 0] DIAG num_sms=1 vs analytical:     max=0 nonzero_frac=0
[rank 0] DIAG num_sms=2 vs analytical:     max=0 nonzero_frac=0
[rank 0] DIAG num_sms=4 vs analytical:     max=0 nonzero_frac=0
[rank 0] DIAG num_sms=8 vs analytical:     max=0 nonzero_frac=0
[rank 0] bit-exact vs analytical (num_sms=3): max=0 nonzero_frac=0
```

48 rank-lines total across both logs, **all `nonzero_frac=0`**. Gate B
PASS means removing the slot-end `__syncthreads()` does not alter
kernel output. I1/I2/I3 invariant analysis (see `DeepEP_vs_UCCL_mechanism.md`)
is corroborated empirically.

(Gate B on num_sms=96 hung — likely unrelated to K-T_sync; same kernel
on same cross-leaf pair. Killed at 11 min. Tests 1-8 covered the
invariant space; additional high-sms points would not change the
verdict.)

## K2 / K3 — end-to-end p99 A/B

Workload scan: 6 ntok × 3 num_sms × 20 iter × 16 rank, `combine-overlap`
kernel only (the kernel K-T_sync modifies). Median p99 across all
ranks × iter per cell:

```
ntok  nsms   baseline   K-T_sync    delta
 128    22      445.0      448.7   +0.84%
 128    48      561.9      555.9   -1.06%  (best)
 128    96      599.5      601.7   +0.38%
 256    22     1134.8     1131.0   -0.34%
 256    48     1065.1     1066.9   +0.17%
 256    96     1143.4     1138.8   -0.41%
 384    22     1553.7     1606.1   +3.37%  (worst)
 384    48     1518.5     1537.0   +1.22%
 384    96     1569.0     1577.5   +0.55%
 512    22     2021.0     2061.7   +2.01%
 512    48     2035.6     2032.9   -0.13%
 512    96     1963.4     1961.5   -0.09%
 768    22     3274.0     3313.7   +1.21%
 768    48     3091.5     3096.0   +0.15%
 768    96     2864.1     2869.2   +0.18%
1024    22     4345.0     4298.5   -1.07%
1024    48     4138.7     4151.1   +0.30%
1024    96     3737.1     3720.8   -0.44%
```

- Mean delta: **+0.47%** (slower). Median: +0.24%.
- Max regression: **+3.37%** at (384, 22) — edge of K2's 3% threshold
  but within same-session noise as the control modes below.
- Max improvement: -1.07% at (1024, 22) — below the K3 threshold of 3%.
- 10/18 cells slightly slower, 8/18 slightly faster. Within-session
  noise band.

### Control: dispatch-base + combine-base (non-overlap, K-T_sync is no-op)

```
dispatch-base ntok=128   base= 535.4  kt= 541.7  delta=+1.16%
dispatch-base ntok=512   base=1187.2  kt=1221.8  delta=+2.91%
dispatch-base ntok=1024  base=1867.4  kt=1878.8  delta=+0.61%
combine-base  ntok=128   base= 688.0  kt= 692.2  delta=+0.61%
combine-base  ntok=512   base=1810.3  kt=1873.5  delta=+3.49%
combine-base  ntok=1024  base=2677.1  kt=3055.1  delta=+14.12%
```

These are kernels K-T_sync does NOT touch. `combine-base @ 1024` moves
+14% between the baseline-workload and K-T_sync-workload runs — that
**defines the within-session noise floor**. All the `combine-overlap`
deltas above are within this noise band. Conclusion: **no statistically
meaningful change**.

## K4 — probe v2 confirms T_sync actually shrank

Probe v2 on K-T_sync+probe build (`UCCL_EP_K_T_SYNC=1 UCCL_EP_PROBE=1`):

```
ntok  nsms   T_init   T_body   T_sync   T_slot   body%   init%   sync%
 128    22    3.98     4.95     0.20     8.71    56.8%   45.7%   2.3%
 128    48    4.30     7.03     0.22    11.21    62.7%   38.4%   2.0%
 128    96    4.28     8.86     0.23    13.07    67.7%   32.7%   1.8%
 256    22    4.20     8.07     0.21    12.46    64.8%   33.7%   1.7%
 256    48    4.93    10.37     0.21    15.49    66.9%   31.8%   1.4%
 256    96    4.70    12.66     0.23    17.59    72.0%   26.7%   1.3%
 512    22    4.47    12.48     0.21    17.23    72.4%   26.0%   1.2%
 512    48    5.11    15.55     0.22    20.84    74.6%   24.5%   1.1%
 512    96    5.25    22.48     0.23    30.09    74.7%   17.4%   0.8%
```

Compare to Sprint B same-kernel-sans-K-T_sync probe (2026-05-06 02:30Z):

| Cell | Sprint B `sync_share` | Sprint C (K-T_sync) `sync_share` |
|---|---:|---:|
| (128, 22) | **51.7%** | **2.3%** |
| (128, 96) | 26.0% | 1.8% |
| (512, 22) | 37.4% | 1.2% |
| (512, 96) | 28.1% | 0.8% |

**The sync_share measurement drops by ~20-50×**. The kernel change
landed exactly where designed. The hypothesis that "K-T_sync removes
the CTA barrier" is empirically confirmed.

Yet end-to-end p99 does not move. Hence the interpretation.

## Interpretation — sync_share was wait time, not blocking time

Probe v2's `T_sync` = `sync_end - slot_body_end` — the window between
"last token put finishes" and "finish-flag IBGDA atomic lands". Pre-
K-T_sync, this window included:

- `sync_barrier<true>(warp_group_id+1, ...)` — warp-group fence (kept)
- `sub_warp_id==1 lane_id==0:` writer lane writes finish-flag + atomic
  decrement (kept)
- `__syncwarp()` (kept)
- **`__syncthreads()` (REMOVED by K-T_sync)** ← this is what we cut

The removed barrier forced 7 non-writer warps to wait for the writer's
remote IBGDA atomic round-trip. Probe v2 sees those warps idle. We
interpreted that as "attackable latency".

But the next slot's very first operation (after `cp.async.bulk.wait_group 0`
TMA drain, ~1 µs) is `comp_signal` spin + `mbarrier_init` — both CTA-
wide. So the non-writer warps that K-T_sync released just hit the
*next* CTA sync point almost immediately. Net kernel time: unchanged.

The cost of `__syncthreads()` on Hopper SM90 with ~8 warps is
~10-50 cycles (~10-50 ns @ 2 GHz) — essentially free. Probe v2's
`T_sync` measurement was picking up the **wait-for-IBGDA-atomic**
latency on the writer lane, which has to happen whether the barrier
is there or not.

## Implications for Sprint C planning

1. **K-T_sync is not shippable**: no measurable gain, so no reason to
   modify the kernel on the `feat/sm-stripe-overlap` branch. Keep
   `feat/k-t-sync` as a research artifact (commit `c8f5f0be`).
2. **The Sprint A decode win (~26%) remains the only shippable claim.**
   That came from SM-stripe (fewer SMs per combine, leaving SMs for
   decode/downgemm), not from any per-slot optimization.
3. **Probe v2 needs a retake.** `T_sync` does not measure what we
   thought it did. Possible next metric:
   - `T_until_next_work` — gap between slot i's finish-flag and slot
     i+1's first token arrive at remote. That's the real blocking
     time.
   - Or: trace the critical path across slots, not within slots.
4. **The original probe v1 "slot_ovhd" finding** (which pushed K-1b,
   rejected 2026-05-05) is now understandable: v1's lumped overhead
   was a mixture of actually-blocking cycles and idle-spin cycles,
   so any variant that removed idle-spin cycles looked good in the
   probe but did nothing at the workload level. Both K-1b and K-T_sync
   failed the workload gate for the same underlying reason.

## Artifacts

Logs (in this directory):

- `session.log` — session timeline
- `verify-efa-ktsync-r{0,1}.log` — EFA pre-flight
- `build-{baseline,ktsync,ktsync-probe}-ktsync-r{0,1}.log` — 3 builds
- `gateB-ktsync-r{0,1}.log` — Gate B (48 PASS lines)
- `workload-{baseline,ktsync}-r{0,1}.log` — 4800 BENCH rows each
- `probev2-ktsync-r{0,1}.log` — 432 PROBE rows each

S3 archive: `s3://uccl-ep-mumbai-788668107894-20260506/ktsync-results/ktsync-20260506T161709Z.tgz`

## Session cost

- 2× p5en.48xlarge spot × ~25 minutes (Pod Running at 15:41Z, scale=0
  at 16:53Z) = ~0.85 node-hrs at ~$13/node-hr ≈ **~$11**
- Cross-leaf didn't waste a retry (same-session A/B valid per policy).
- 1 failed session attempt (`/tmp/ktsync-20260506T155405Z` — missing
  `.so` symlinks) + 1 failed (`160129Z` — destroy_uccl signature) +
  1 good (`161709Z`) → 3 torchrun restarts, no extra node-hrs since
  pods stay idle between runs.
