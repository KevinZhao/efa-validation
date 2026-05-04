# Sprint A Gate C — Fine-grain num_sms Sweep with P50/P99/P99.9 Tails

**Date**: 2026-05-03 late evening
**Branch**: `feat/sbo-comp-signal-sprint-a` @ `20007c32`
**Hardware**: 2× p5en.48xlarge (Tokyo apne1-az4, fresh nodes)
**Raw**: 2240 BENCH rows (20 iters × 7 modes × 16 ranks × 50 samples/bench)

## TL;DR

**The sweet spot is num_sms=22, not 24. The real value of SM-budgeted mode
is P99 tail reduction (~8-10%), not avg reduction (~2%).**

Previous sweep's "+10%" for num_sms=24 vs baseline was inflated by spot
hardware variance between runs — this run picked a faster pair of nodes,
so baseline improved from 363 µs → 327 µs. Same-session comparisons
inside this sweep are the only ones to trust.

## Results

| mode | SM | n | avg | p50 | **p99** | **p99.9** | max | stdev |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | 96 | 320 | 327.04 | 314.15 | **467.78** | 472.36 | 472.86 | **29.67** |
| overlap-18 | 18 | 320 | 327.73 | 333.17 | **423.72** | 426.08 | 426.34 | 3.66 |
| overlap-20 | 20 | 320 | 323.35 | 328.97 | **424.82** | 428.15 | 428.52 | 2.27 |
| **overlap-22** | **22** | 320 | **319.45** | 322.89 | **432.47** | 434.90 | 435.17 | **2.25** |
| overlap-24 | 24 | 320 | 320.79 | 322.30 | 457.38 | 460.68 | 461.05 | 2.19 |
| overlap-26 | 26 | 320 | 320.88 | 324.31 | 463.49 | 468.69 | 469.26 | 2.29 |
| overlap-28 | 28 | 320 | 321.42 | 321.81 | 470.44 | 473.50 | 473.84 | 2.46 |

## Δ vs baseline (95% bootstrap CI, 5000 resamples)

### avg (mean of 50 per bench() × 20 iters × 16 ranks)
| SM | median | CI | significant? |
|---|---:|---|---|
| 18 | +0.22% | [-0.80%, +1.24%] | no (crosses 0) |
| 20 | **−1.11%** | [-2.09%, -0.11%] | **yes** |
| **22** | **−2.32%** | [-3.32%, -1.34%] | **yes (best avg)** |
| 24 | −1.92% | [-2.92%, -0.95%] | yes |
| 26 | −1.88% | [-2.85%, -0.90%] | yes |
| 28 | −1.73% | [-2.75%, -0.73%] | yes |

### p99 tail (per-call 99th percentile)
| SM | median | CI | significant? |
|---|---:|---|---|
| **18** | **−9.42%** | [-13.0%, -5.5%] | **yes (best p99)** |
| 20 | −9.10% | [-12.7%, -5.2%] | yes |
| 22 | −7.56% | [-11.3%, -3.7%] | yes |
| 24 | −2.27% | [-6.2%, +1.9%] | no |
| 26 | −0.92% | [-4.9%, +3.3%] | no |
| 28 | +0.55% | [-3.5%, +4.9%] | no |

### p99.9 / max — same shape as p99, slightly more pronounced

## Interpretation

### The shape of the curve

- **SM ≤ 22: network bandwidth limited** — each additional SM keeps more
  EFA NICs busy; latency drops monotonically. Tail reduces because all
  slots complete quickly, cutting long-tail outliers.
- **SM ≥ 24: NIC queue contention** — more issuing SMs means more
  concurrent IBGDA puts per NIC. Avg stays flat (bandwidth saturated)
  but tail creeps back up (more chance of NIC-side queue backups).
- **SM = 22 is the knee** between the two regimes on p5en with 16 EFA
  NICs / 2 nodes / 8 GPU.

### Why p99 beats baseline by 8-10% but avg only by 2%

Baseline's 96-SM configuration causes periodic contention on EFA NICs.
Each NIC is shared across ~6 SMs; when multiple SMs hit a NIC
simultaneously, one gets queued. Mean is barely affected (queues
drain), but P99 blows out. With num_sms=18, each NIC is hit by ~1.1 SMs
on average — no queue.

**This is a tail-latency story, not a throughput story.**

### What changed vs previous sweep

The previous ANALYSIS_SWEEP.md reported overlap-24 at −10% avg. That
number compared overlap-24 (new nodes `ip-10-99-10-64`, `...-253`) to a
baseline run on **different nodes** (`ip-10-99-10-170`, `...-172`) from
an earlier session. Spot variance between physical machines = ~11%,
large enough to swallow the real signal.

This sweep put all 7 modes on the SAME pair of nodes so the
cross-config comparison is apples-to-apples. **Real avg speedup is
~2.3% at sweet spot**, not 10%.

### Why p50 gets slightly worse

At p50, baseline's best case (314 µs) is already near the lower bound
achievable — overlap-*'s floor (322-333 µs) includes the fixed cost of
per-slot TMA mbarrier re-init × 96/N iterations per SM. For small N
(fewer iters per SM), this overhead is minimal; for larger N (up to
N=32 slots per SM), it accumulates.

## Recommended default

**`num_sms = 22`** for UCCL-EP on EFA (p5en class).

Rationale:
- Best avg (−2.3%, CI does not cross 0)
- P99 significantly lower (−7.6%, CI does not cross 0)
- Still frees 110 SMs for DeepGemm to co-execute

**Second choice**: num_sms=20 — similar avg (−1.1%), slightly better p99
(−9.1%), for latency-critical workloads.

## Implications for Sprint A PR

1. The PR should document **p99 tail reduction as primary value**, avg
   as secondary.
2. Default must be updated from current `num_sms=3` to `num_sms=22` in
   `ep/src/internode_ll.cu` host `combine()`.
3. PR body should include the full sweep table so maintainers can see
   the knee behavior and understand why 22 > 3 on EFA.
4. Upstream SGLang's default of 3 is **correct for InfiniBand** (few
   NICs, different contention profile). UCCL-EP should override
   internally, not push the change upstream.

## Caveats

1. Spot hardware variance is real (~5-11% across runs on different p5en
   pairs). Any PR claim must note this.
2. Only one config tested: `num_tokens=128 hidden=7168 num_topk=8 num_experts=288`.
   Larger hidden or num_tokens may shift the knee.
3. Instance-class sensitivity: p5 (32 NICs), p6-b200 (8 NICs) will have
   different optima. Include a small auto-detect or env-var override.

## Cost

- 2× p5en spot for ~25 min: ~$20
- Cumulative session cost: ~$150

## Raw

- `sweep2-r0.log` / `sweep2-r1.log` — 2240 BENCH rows, per-mode p50/p99/p99.9
- `analyze_sweep2.py` — bootstrap CI analysis
