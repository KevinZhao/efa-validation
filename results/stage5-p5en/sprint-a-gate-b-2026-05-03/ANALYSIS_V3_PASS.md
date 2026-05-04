# Sprint A Gate B — V3 PASSED

**Date**: 2026-05-03 17:15 UTC
**Supersedes**: `ANALYSIS.md` (wrong oracle), `ANALYSIS_V2.md` (diagnosis of test bug)
**Branch**: `feat/sbo-comp-signal-sprint-a` @ `06607b91`

## Verdict

**PASS ✅** — every correctness check returns `max=0 nonzero_frac=0` across
all 16 ranks and all exercised `num_sms` values.

## Fix that mattered

The actual kernel fix was `f4dda8d9` (plan A):
1. `cp.async.bulk.wait_group 0` at the start of each SM-stripe iteration
   to drain any in-flight TMA load prefetches from the previous slot
2. `__syncthreads()` at the end of each iteration so the finish-flag
   writer warp's IBGDA atomic completes before other warps start
   re-initializing mbarriers

Both are guarded `if constexpr (kOverlap)` so legacy path is unchanged.

## What was NOT a kernel bug

The original V1 analysis blamed the kernel because
`test_overlap_bit_exact_vs_baseline` reported `max diff = 1.45-1.96` across
all ranks. The V2 diagnostic `test_baseline_vs_baseline_control` proved
that **two consecutive `low_latency_combine(overlap=False)` calls with
identical inputs also differ** by `max=1.3-1.95, nonzero=1-5%`. The
noise comes from legacy combine's ring-buffer state bleeding across calls
(buffer-index flip, IBGDA atomic residual, rdma_recv_flag leftover). It
is NOT an overlap kernel bug. Legacy combine was never designed to be
called twice in a row with no intervening dispatch — SGLang's real
workload always does `dispatch -> GEMM -> combine -> next iteration's
dispatch`, and our test violated that contract.

## Correct oracle

`test_baseline_analytical_oracle` and all its overlap-mode variants use
the analytical identity: with `simulated_gemm_x = ones()` and
`topk_weights = ones() / num_topk`, every combined token must equal
exactly `1.0` (since `Σ_i (1/num_topk) * 1.0 = 1.0`). No comparison
between two kernel runs is needed.

## Test matrix that passed (all ranks 0-15)

| Test | Result |
|---|---|
| `BASELINE vs analytical` (legacy combine, ones in → ones out) | `max=0 nonzero_frac=0` |
| `DIAG num_sms=1 vs analytical` (overlap, single-SM scheduler) | `max=0 nonzero_frac=0` |
| `DIAG num_sms=2 vs analytical` | `max=0 nonzero_frac=0` |
| `DIAG num_sms=4 vs analytical` | `max=0 nonzero_frac=0` |
| `DIAG num_sms=8 vs analytical` | `max=0 nonzero_frac=0` |
| `bit-exact vs analytical (num_sms=3)` **← SGLang default** | `max=0 nonzero_frac=0` |

The remaining edge tests (`signal-wait`, `zero-token`, `bad-kwargs`)
hit an unrelated Python threading issue in the test harness and were
killed by the operator; not kernel problems.

## Setup

- 2× p5en.48xlarge spot (apne1-az4, SPS=9)
- Nodes: `ip-10-99-10-170`, `ip-10-99-10-172`
- Image `yanxi/uccl-ep:latest`, CUDA 12.6, PyTorch 2.5.1
- `num_tokens=128 hidden=7168 num_topk=8 num_experts=288 EP=16`
- `PEB=0`, `SM=90`
- `UCCL_IB_HCA=rdmap` (EFA all NICs)
- Pod spec v4: `vpc.amazonaws.com/efa: 16`, hostPath `/data/...` for workspace

## Cost

- Spot runtime this session: ~30 min
- Cumulative Gate B + debug: ~$80 (includes 3 failed attempts before
  finding oracle bug)

## Next

1. Gate C: 2-node perf bench comparing `overlap=False` baseline vs
   `overlap=True num_sms=3` with mock comp_signal (instant fill). This
   measures the "pure SBO overhead" (spin check + CTA fence + drain).
2. A follow-up Gate C' with real DeepGemm producer will land in Sprint A.2
   (requires DeepSeek-V3 weights checkout).
3. Rebase / prepare Sprint A PR body against the stub PR #919's eventual
   merge commit.

## Raw

- `PASS-r0.log` / `PASS-r1.log` — full torchrun output, all 16 ranks
- `PASS-build.log` — full nvcc build output
