# Sprint A Gate C — Workload Scaling + Dispatch Baseline

**Date**: 2026-05-04 00:45 UTC
**Branch**: `feat/sbo-comp-signal-sprint-a` @ `bf8aa898`
**Hardware**: 2× p5en.48xlarge (Tokyo apne1-az4, nodes `ip-10-99-10-60`, `...-108`)
**Raw**: 2880 BENCH rows (20 iters × 3 num_tokens × 3 modes × 16 ranks × 50 samples/bench)

## TL;DR — num_sms=22 does NOT generalize beyond num_tokens=128

The earlier sweep conclusion ("num_sms=22 is the sweet spot") was
**workload-local**. At num_tokens=256 and 512, the same `num_sms=22`
kernel is 14-17% slower than baseline (combine-base at 96 SMs). The
correct conclusion is that **num_sms must scale with num_tokens**.

## Data

### Absolute latency (mean of 320 per-iter bench() averages)

| mode | ntok | avg | p50 | p99 | p99.9 | max |
|---|---:|---:|---:|---:|---:|---:|
| dispatch-base | 128 | 223 | 216 | 303 | 307 | 308 |
| combine-base | 128 | 351 | 335 | 612 | 621 | 623 |
| combine-overlap-22 | 128 | **323** | 327 | **431** | 434 | 435 |
| | | | | | | |
| dispatch-base | 256 | 419 | 393 | 766 | 776 | 778 |
| combine-base | 256 | **594** | 573 | **885** | 897 | 899 |
| combine-overlap-22 | 256 | 693 | 658 | 1106 | 1115 | 1116 |
| | | | | | | |
| dispatch-base | 512 | 656 | 621 | 993 | 1066 | 1074 |
| combine-base | 512 | **1104** | 1058 | **1664** | 1686 | 1688 |
| combine-overlap-22 | 512 | 1259 | 1207 | 1951 | 1967 | 1969 |

### Δ overlap-22 vs combine-base (bootstrap 95% CI)

| ntok | avg | p99 | p99.9 | verdict |
|---|---:|---:|---:|---|
| **128** | **−8.1%** [−8.8%, −7.4%] | **−29.6%** [−31.3%, −27.7%] | −30.1% | **overlap WINS** (big tail cut) |
| 256 | **+16.7%** [+15.4%, +17.9%] | +25.0% [+20.4%, +30.0%] | +24.2% | overlap LOSES |
| 512 | +14.0% [+13.1%, +15.0%] | +17.3% [+14.4%, +20.3%] | +16.7% | overlap LOSES |

## Interpretation

### Why overlap-22 wins at ntok=128

At 128 tokens / 16 ranks, each `(dst_rank, local_expert)` pair has
**~7 tokens** (128 × 16 topk / (16 ranks × 18 local_experts) ≈ 7).
Each slot's TMA+IBGDA work is small. 22 SMs can keep 16 EFA NICs
saturated — baseline's 96 SMs just add contention.

The **29.6% p99 reduction** is huge: baseline's 96-SM configuration
causes periodic NIC queue backups that show up in p99 spikes. With 22
SMs, each NIC is hit by ~1.4 SMs on average → no queue.

### Why overlap-22 loses at ntok=256 / 512

At 256 tokens, each slot has **~14 tokens** of work. At 512, **~28 tokens**.
The kernel is now **compute-and-memory-bound per slot**, not NIC-bandwidth
bound. With 22 SMs each doing 96/22 ≈ 4.4 iterations of SEND body, total
wall time = 4.4 × (per-slot time).

Baseline's 96-SM configuration runs 96/96 = 1 iteration → 4-5× less
serialization. Bandwidth saturation becomes moot when compute dominates.

### Scaling law (empirical)

Combine-base avg scales:
- ntok=128 → 351 µs
- ntok=256 → 594 µs (1.69×)
- ntok=512 → 1104 µs (3.15× vs 128)

Roughly linear-plus-constant: `avg ≈ 180 + 1.8 * ntok` µs.
Combine-overlap-22 scales worse:
- ntok=128 → 323 µs
- ntok=256 → 693 µs (2.15×)
- ntok=512 → 1259 µs (3.90×)

Rough: `avg ≈ 100 + 2.3 * ntok` — steeper slope proves the kernel is
linear in per-slot work, not in bandwidth.

## Dispatch baseline (L3 prep)

Dispatch has no overlap variant yet, but now we have its baseline:
- ntok=128: 223 µs avg / 303 µs p99
- ntok=256: 419 µs avg / 766 µs p99
- ntok=512: 656 µs avg / 993 µs p99

Dispatch p99 tail is also ~1.4× p50 (similar to combine-base 1.8×)
suggesting similar NIC-contention pattern. **If Sprint B implements
dispatch SM-stripe, similar p99 reduction likely.**

## Revised Sprint A conclusion

**The default must not be a hard-coded `num_sms=22`.** Instead:

### Option 1: workload-adaptive auto-tune
```cpp
int pick_overlap_num_sms(int num_max_rx_tokens) {
  // Empirical: ~1 SM per 90 rx tokens saturates 16 EFA NICs without over-serializing
  int n = (num_max_rx_tokens + 89) / 90;
  return std::clamp(n, 16, 96);
}
```
- ntok=128 (max_rx=2048): n = 23 ≈ 22 ✓
- ntok=256 (max_rx=4096): n = 46 → beats baseline on 128, likely on 256
- ntok=512 (max_rx=8192): n = 91 → near baseline, minimal gain

### Option 2: pass-through SGLang's num_sms
SGLang SBO's DeepGemm sizing chooses `num_sms` per-call based on token
count. If we respect `overlap_args.num_sms` without override, the caller
can tune. Downside: SGLang default is 3 which is wrong for EFA.

### Option 3 (recommended): env var override
```cpp
static int const kAutoNumSms = [](){
  if (const char* v = getenv("UCCL_EP_OVERLAP_NUM_SMS"))
    return std::atoi(v);
  return 22;  // tuned for decode (ntok≤128); prefill users must override
}();
int num_sms = (num_sms_override > 0) ? num_sms_override : kAutoNumSms;
```
PR body documents the trade-off and recommends:
- Decode (ntok ≤ 128): default 22
- Prefill (ntok ≥ 256): `export UCCL_EP_OVERLAP_NUM_SMS=96` or use auto-tune

## What this does for Sprint A PR narrative

**Before this sweep**: "SM-budgeted scheduler gives 2-10% speedup"
**After**:
- Decode workloads: **29.6% p99 reduction at ntok=128**
- Prefill workloads: no speedup (or regression) — tune via env var

The p99 decode story is still compelling **for agentic / low-latency
inference workloads**. Need to be explicit about workload scope in PR.

## Cost

- 2× p5en spot for ~25 min: ~$20
- Cumulative session: ~$170

## Raw

- `workload-r0.log` / `workload-r1.log` — 2880 BENCH rows, per-mode p50/p99/p99.9
- `analyze_workload.py` — bootstrap CI analysis
