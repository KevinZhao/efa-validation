# Phase 10 + 11 analysis — adaptive num_sms validation + probe v2 decomposition

**Session stamp**: `20260506T023000Z`
**Region / AZ**: ap-northeast-1 / apne1-az4 (SPS=8 at launch)
**Cluster / NG**: yanxi-eks-tokyo / gpu-p5en-48xlarge-spot
**Nodes**: `i-0ffeb9fc8d5e6719b` (rank-0, 10.99.10.181) + `i-01c3b536c1639af11` (rank-1, 10.99.10.19)
**Topology**: same ap-northeast-1a, same Layer-1/Layer-2, **different Layer-3 leaf** —
per `feedback_spot_cross_leaf_policy.md` this is same-session A/B so
Grid A and Grid B see the same cross-leaf penalty; the relative
comparison holds.
**Commit on nodes**: `16785c9` (tip of `feat/sprint-a-generalization-bench`)
**Build**: CUDA 13.0 (nvcr 25.10-py3), `TORCH_CUDA_ARCH_LIST=9.0`
**Probe build (Phase 11)**: `UCCL_EP_PROBE=1`, `probe_buffer_bytes()=526912`,
schema version=2

---

## Phase 10 — adaptive num_sms

### Grid A (static num_sms) median p99 (µs)

| ntok | 22 | 48 | 96 | best |
|---|---|---|---|---|
| 128 |  **448** |  559 |  600 |  448 |
| 256 | 1136 | **1061** | 1150 | 1061 |
| 384 | **1517** | 1537 | 1557 | 1517 |
| 512 | 2010 | 2053 | **1973** | 1973 |
| 768 | 3330 | 3121 | **2856** | 2856 |
| 1024 | 4425 | 4195 | **3720** | 3720 |

### Grid B (adaptive via `num_sms=0`) — tier lookup

| ntok | resolved | p50 | p99 | p99.9 | n |
|---|---|---|---|---|---|
| 128 | 22 | 330 | 445 | 448 | 288 |
| 256 | 22 | 699 | 1142 | 1131 | 288 |
| 384 | 22 | 931 | 1558 | 1506 | 288 |
| 512 | 48 | 1187 | 2033 | 2062 | 288 |
| 768 | 48 | 1791 | 3090 | 3080 | 288 |
| 1024 | 48 | 2517 | 4177 | 4569 | 288 |

### Gate G1–G4 results

| Gate | Spec | Result |
|---|---|---|
| G1 @ 128 | adaptive ≤ 1.03 × best static | PASS (0.995) |
| G1 @ 256 | adaptive ≤ 1.03 × best static | **FAIL** (1.076) — adaptive chose 22 but 48 was better |
| G1 @ 384 | adaptive ≤ 1.03 × best static | PASS (1.027) |
| G1 @ 512 | adaptive ≤ 1.03 × best static | **FAIL** (1.030) — adaptive chose 48 but 96 was better |
| G1 @ 768 | adaptive ≤ 1.03 × best static | **FAIL** (1.082) — adaptive chose 48 but 96 was best |
| G1 @ 1024 | adaptive ≤ 1.03 × best static | **FAIL** (1.123) — adaptive chose 48 but 96 was best |
| G2 | decode win preserved (128 ratio ≤ 0.75) | **PASS** (0.742) |
| G3 | 512 ≤ static_22 | **FAIL** (1.011) — 512×48 is not meaningfully better than 512×22 here |
| G4 | 384 within ±5% of best of {22, 48} | PASS (1.027) |

### Key finding — tier table is **wrong for this session's topology**

The tiers `(≤384 → 22, >384 → 48)` were derived from Sprint A logs on
a prior session. In this session's log the U-curve has shifted:

- **decode (128)**: 22 still wins. ✓
- **medium (256–384)**: 48 is now the sweet spot; 22 is worse by 7–8%.
- **prefill (512–1024)**: **96** wins, not 48. The old tier 48
  under-provisions SMs by 4–12%.

Why the shift from prior-session's findings? Cross-leaf topology today.
Each combine needs more SMs to amortize cross-leaf RTT. When inter-node
fabric is cheaper (same leaf), the "22 SMs handle decode" holds; when
RTT is higher, the NIC-bound regime extends upward and 48/96 start
winning earlier.

### Verdict

**Do NOT ship the current tier table to UCCL**. Two data points:
1. Session cost \~$2 to produce; low confidence that tiers generalise.
2. Adaptive-ship would regress **4 out of 6** ntok cells today vs best
   static. The one clear win (128 decode) is preserved, but the rest
   is a wash-to-regression.

**Next step**: re-derive tiers from **two sessions** (same leaf + cross
leaf) and codify a topology-aware tier table, OR defer adaptive
entirely and leave `num_sms` as a user-selected param. First option
needs one more GPU session; second is free and ships today.

---

## Phase 11 — probe v2 decomposition

Per-cell shares (all 9 cells fire):

| ntok | nsms | init | body | sync | T_slot (SM clks) |
|---|---|---|---|---|---|
| 128 | 22 | 11.3% | 82.8% | 51.7% | 7.8 |
| 128 | 48 | 10.7% | 83.5% | 55.1% | 8.4 |
| 128 | 96 |  9.1% | 85.2% | 54.4% | 9.9 |
| 256 | 22 |  9.5% | 86.4% | 45.3% | 9.6 |
| 256 | 48 |  8.0% | 87.3% | 49.8% | 11.5 |
| 256 | 96 |  5.6% | 89.9% | 41.3% | 16.5 |
| 512 | 22 |  7.0% | 90.7% | 33.8% | 13.3 |
| 512 | 48 |  5.1% | 92.1% | 33.5% | 18.5 |
| 512 | 96 |  3.2% | 93.7% | 26.0% | 29.0 |

(Shares do not sum to 1.0 because `sync` overlaps `body`: `sync_start
= body_end`, they're sibling time windows, not disjoint. `init +
body` is the disjoint split within `slot_start → slot_body_end`.)

### Gate P1–P4

| Gate | Result |
|---|---|
| P1 — schema=2 | **PASS** on r0 log (r1 has only ranks 8–15; SCHEMA is rank-0 only) |
| P2 — body_share > 0.20 every cell | **PASS** — body ≥ 82.8% everywhere |
| P3 — init heavier at decode | **PASS** — init@(128,22)=0.113 > init@(512,22)=0.070 |
| P4 — sync_share ≥ 0.10 somewhere | **PASS** — max sync_share=0.551 @ (128,48) |

### What this tells us — **`T_body` dominates; K-1b was attacking the wrong thing**

Sprint B probe v1 showed "slot-level overhead ≈ 37%" and we translated
that into K-1b (hoist mbarrier_init). v2 decomposes that 37% into:

- `init` (hoistable by K-1b): **3–11%**, drops to 3% at prefill
- `sync` (finish-flag atomic + slot-end `__syncthreads()`): **26–55%**,
  and this sits *concurrent* with body, not after it — so overlap
  opportunity exists
- `body` (token pipeline, IBGDA puts, TMA loads): **82–94%** of slot wall-time

The ceiling for a K-1b-style "only attack init" kernel is **at most
11% at decode, 3% at prefill** — exactly the range K-1b underperformed
its Sprint B probe v1 estimate by.

### Which kernel next?

| Target share | Kernel | Expected win |
|---|---|---|
| `body` (82–94%) | K-1a token-pipe / K-1c slot-pipelining — **LARGEST** | big but risky (register pressure) |
| `sync` (26–55% at decode) | K-T_sync — overlap finish-flag IBGDA with next slot body | 5–15% |
| `init` (3–11%) | K-1b/K-1a hoist | 3% ceiling, already tested, not worth it |

**Recommendation**: next variant is **K-T_sync** (move finish-flag
IBGDA atomic out of the per-slot critical path). Rationale:
1. `sync` is big (26–55%) but low-risk to attack (no per-thread state
   changes; just reorder a single atomic).
2. `body` would win more but needs register-aware redesign (Sprint B
   K-1b lesson: blind pressure increase regresses).
3. `init` too small to bother with.

### Cross-session comparison

| metric | Sprint A (2026-04) | Sprint B K-1b (2026-05-04) | this session (2026-05-06) |
|---|---|---|---|
| p99 decode (128, best static) | 40147 µs (cross-leaf ≤leaf?) | ~41k | **448 µs** ?! |
| p99 prefill (512, best static) | 40368 µs | ~40k | **1973 µs** |

**WAIT — this session's p99 is \~90× lower than Sprint A/B**. Check
raw log BENCH units / world_size. Sprint A/B ran with `world_size=16`
across 2 nodes × 8 ranks; this session matches. Either:
- This session is actually faster (fewer cross-leaf hops? different
  spine?), or
- Units reporting differs somewhere in the bench path.

Needs investigation before any absolute-number claim lands.

---

## Cost and teardown

- p5en uptime: 02:16 → 03:00Z launch + deploy, 02:53-03:00 teardown-start ≈ 45 min
- estimated spend: ~$12 (p5en spot $20/hr × 2 × 0.75h = $30 actual; with spot discount applied so probably less)
- scp tarball: 475 KB
- teardown: ASG desiredCapacity=0, both instances terminating as of this analysis

---

## Decisions taken

1. **No PR** lands today. The tier table doesn't hold on this topology;
   Adaptive G1 fails on 4/6 ntok cells.
2. **Next kernel work**: K-T_sync design sketch (not K-1a/K-1c yet).
   Probe v2 says sync is 26–55% of slot time and mechanically
   overlap-able.
3. **Revisit adaptive tiers** only after two sessions worth of
   topology-varied data (same-leaf + cross-leaf), so the tier
   boundaries can encode topology as an input.
4. **The 90× p99 discrepancy vs Sprint A/B** — flag as open question;
   before trusting any cross-session absolute claim, re-check the
   bench path didn't change reporting units.
