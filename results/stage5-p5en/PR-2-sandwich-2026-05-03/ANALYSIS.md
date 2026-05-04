# PR-2 Stub Non-regression Sandwich — Analysis

**Date**: 2026-05-03 12:07-12:16 UTC
**Sandwich**: baseline-pre × 3 → patched × 3 → baseline-post × 3 (all PEB=0, all upstream `fb4147a2` except stub adds 64-line API-only diff)

## Raw per-run dispatch `avg_t` medians (µs)

| Phase | run1 | run2 | run3 |
|---|---|---|---|
| baseline-pre   | 254.94 | **193.31** | 274.62 |
| patched        | 211.32 | 261.86 | 213.68 |
| baseline-post  | **193.22** | 257.92 | **194.02** |

## Raw per-run combine `avg_t` medians (µs)

| Phase | run1 | run2 | run3 |
|---|---|---|---|
| baseline-pre   | 340.94 | 309.86 | 346.95 |
| patched        | 315.15 | 346.51 | 324.72 |
| baseline-post  | 313.24 | 341.96 | 314.42 |

## Summary (3 metrics × 3 phases)

| Metric | baseline-pre median | patched median | baseline-post median |
|---|---|---|---|
| Dispatch avg_t | 254.94 µs | 213.68 µs | 194.02 µs |
| Combine avg_t  | 340.94 µs | 324.72 µs | 314.42 µs |
| Dispatch BW    | 30.13 GB/s | 35.96 GB/s | 39.58 GB/s |
| Combine BW     | 44.84 GB/s | 47.08 GB/s | 48.60 GB/s |

Min-of-3 (least noise-polluted):

| Metric | baseline-pre min | patched min | baseline-post min | pre→post drift | patched vs pre min |
|---|---|---|---|---|---|
| Dispatch | 193.31 µs | 211.32 µs | 193.22 µs | **-0.04%** | +9.3% |
| Combine  | 309.86 µs | 315.15 µs | 313.24 µs | +1.09% | +1.7% |

## Interpretation

### Combine (passes non-regression)
- pre→post drift 1.09% is within session noise
- patched min-of-3 is +1.7% vs baseline-pre min, within 3-run noise band
- Envelope check: all 3 patched runs in `[309.86, 346.95]` baseline envelope ✓
- **Verdict**: combine non-regression confirmed

### Dispatch (inconclusive)
- pre→post drift 0.04% is remarkably tight — environment was stable
- patched min is +9.3% above both baselines — **beyond 3-run noise**
- But: envelope check `[193.22, 274.62]` contains all 3 patched runs (211.32, 213.68, 261.86) ✓
- The stub patch touches no kernel code — only adds 7 optional kwargs with behavior-preserving defaults. A real +9% dispatch regression is not mechanistically plausible unless:
  1. Build non-determinism shifted SM stripe / ordering (possible but unlikely given -fPIC -O3 and same compiler)
  2. Some container cache effect (e.g., `.so` layout difference affecting cache lines)
  3. Statistical artifact — 3 patched runs all sampled the "high" tail by coincidence

### Why 3 runs is not enough

Per-phase CV:
- pre dispatch CV ≈ 17%
- pt  dispatch CV ≈ 12%
- post dispatch CV ≈ 17%

Each phase has one "low" run (~193 µs) that looks like the hardware's best-case latency, and one or two "high" runs (255-275 µs). The pattern looks bimodal, not Gaussian. 3 samples cannot resolve this.

## Decision for PR body

**Claim non-regression for combine**: yes, with min-of-3 +1.7% evidence.

**Claim non-regression for dispatch**: **cannot defensibly claim**. Options:
1. Honestly report the +9.3% min-of-3 offset as observed but unconfirmed; attribute to 3-run noise; invite maintainer to reproduce.
2. Collect 10+ runs per phase for bootstrap CI before submitting PR.
3. Point to the static code review as the strongest non-regression evidence: diff is 64 lines, touches zero kernel code, adds only optional kwargs with default values preserving existing path.

For a **stub API-compatibility PR**, option (3) is defensible — the onus on non-regression is fundamentally on the code review, not benchmark, because there is no mechanism by which new Python/C++ kwargs with defaults would slow the dispatch path. The bench data supports this (envelope check passes, combine confirms) but doesn't independently prove it.

## Raw files

- 18 bench logs: `raw/bench-{pre,pt,post}-run{1,2,3}-rank{0,1}.log`
- 6 build logs on bastion: `/home/ec2-user/build-{baseline-pre,patched,baseline-post}-r{0,1}.log`
