# Sprint A Gate B — V2 Analysis (2026-05-03 evening)

**Supersedes**: initial `ANALYSIS.md` (which concluded kernel bug). Diagnostic
run on top of fix H1 revealed the real problem is in the test methodology,
not the kernel.

## TL;DR

`test_overlap_bit_exact_vs_baseline` cannot be trusted. **Two back-to-back
`low_latency_combine(overlap=False)` calls with identical inputs produce
outputs that differ by `max abs diff ≈ 1.3-1.95` on `1-5%` of elements.**
This matches — within noise — the diff we attributed to my overlap kernel.

The bit-exact test was checking the wrong thing; the legacy combine itself
is not bit-stable across consecutive calls.

## What I actually ran (diagnostic build dbeef3bb, fix H1 in place)

Three tests injected before the real bit-exact check:

### 1. `test_baseline_vs_baseline_control`
Runs `combine(overlap=False)` twice with the same `simulated_gemm_x`,
`topk_idx`, `topk_weights`, `handle`. Compares outputs.

Result (all 16 ranks):
```
[rank 0]  max=1.352 nonzero_frac=0.01224
[rank 1]  max=1.666 nonzero_frac=0.01781
[rank 2]  max=1.557 nonzero_frac=0.05012
[rank 3]  max=1.312 nonzero_frac=0.01225
[rank 4]  max=1.402 nonzero_frac=0.03231
[rank 5]  max=1.460 nonzero_frac=0.04456
[rank 6]  max=1.484 nonzero_frac=0.03676
[rank 7]  max=1.492 nonzero_frac=0.03228
[rank 8]  max=1.422 nonzero_frac=0.03675
[rank 9]  max=1.609 nonzero_frac=0.01893
[rank 10] max=1.449 nonzero_frac=0.05236
[rank 11] max=1.406 nonzero_frac=0.02226
[rank 12] max=1.553 nonzero_frac=0.03231
[rank 13] max=1.957 nonzero_frac=0.01337
[rank 14] max=1.492 nonzero_frac=0.04566
[rank 15] max=1.406 nonzero_frac=0.02561
```

Conclusion: **legacy `low_latency_combine` is not bit-stable across consecutive
calls.** The overlap-kernel diff of 1.4-2.0 is indistinguishable from this
baseline noise.

### 2. `test_overlap_num_sms_full` (attempted)
Tried running overlap=True with `num_sms = num_experts (288)` to exercise
the `kOverlap` kernel body with near-legacy scheduling. **Failed immediately**
with `CUDA error 'too many blocks in cooperative launch'` — `num_experts=288`
exceeds the H200 SM count (132), so `cg::this_grid().sync()` rejects the
launch. This test is invalid as written.

### 3. The original `test_overlap_bit_exact_vs_baseline` (num_sms=3)
Result with fix H1: `max diff 1.36-1.88, nonzero_frac 0.01-0.05` — basically
the same magnitude as the baseline-vs-baseline control. **Indistinguishable
from session noise.**

## Why two consecutive combines differ (hypothesis)

Legacy combine has side-effects that ride through across calls:
1. **`low_latency_buffer_idx` flips** (`buffer_idx ^= 1`) each call. First
   call uses buffer[0], second uses buffer[1]. Stale state in buffer[1]
   from a prior dispatch/combine can leak into reads.
2. **IBGDA `atomic_buffer_ptr` state**: each `nvshmemi_ibgda_amo_nonfetch_add`
   uses `atomic_val` slots. Values from the previous combine may not be
   fully drained when the next SEND begins.
3. **`rdma_recv_flag` / `rdma_recv_flag_internode`**: the peer's flag buffer
   holds residual non-zero from the previous call. The check at line 1191
   (legacy, now line 1199): `"Different node but rdma_recv_flag is not zero!"`
   would normally fire, but it doesn't because of the `clean_meta`
   mechanism. Might still leave subtle race.
4. **`num_tokens_to_send` in IBGDA atomic add**: line 1117 uses
   `num_tokens_to_send` as increment (not `1`). If the peer accumulates
   across calls, the flag value diverges.

In short: legacy combine was designed for **one dispatch + one combine per
iteration of a training step**, not for back-to-back combines with the
same dispatch. The test violated that contract.

## Fix H1 assessment

Fix H1 (`cp.async.bulk.wait_group 0` + `__syncthreads()` between SM-stripe
iterations) is **neither confirmed nor refuted** by this data. It may or may
not matter; we cannot tell until a correctness test with a valid oracle runs.

## Correct test methodology (next)

### Plan: **reference reduce in PyTorch**
Replace bit-exact-vs-legacy with bit-exact-vs-analytical:
1. Dispatch + combine(overlap=True) once → get `out_ov`
2. Compute `expected = Σ_i reg_topk_weights[i] * simulated_gemm_x[reg_topk_idx[i]/num_local_experts, src_idx[token, i], :]`
   on CPU / PyTorch (no kernels involved)
3. Assert `torch.allclose(out_ov, expected, rtol=1e-2)` — allow small
   numerical tolerance for bf16 accumulation order differences

This needs the `src_info` tensor from the dispatch handle, which is already
exposed. The reference is O(num_tokens × num_topk × hidden) = O(128 × 8 ×
7168) = 7.3M FLOPs — trivially fast on CPU or one GPU.

### Alternative: **tolerance-floor check**
If reference reduce is complex to get right, fall back to:
- Run baseline twice → record `max_ref_diff`, `nonzero_frac_ref`
- Run overlap once → record `max_ov_diff`, `nonzero_frac_ov`
- Assert `max_ov_diff ≤ 2 × max_ref_diff AND nonzero_frac_ov ≤ 2 × nonzero_frac_ref`

This is weaker but cheaper to implement. Not recommended for PR-quality
evidence but fine for internal validation.

## Cost

- 2× p5en spot up for ~1 hr total this session: ~$48
- Gate B still not proven green, but **the kernel may actually be correct**

## Next

1. Rewrite `test_overlap_bit_exact_vs_baseline` to compare against PyTorch
   reference reduce
2. Rewrite `test_overlap_num_sms_full` to use `num_sms ∈ {1, 2, 4, 8}` (all
   below SM count)
3. Scale up once, rerun, check overlap matches reference within bf16
   tolerance
4. If it does: Gate B passes → Gate C perf bench
5. If it doesn't: there's a real kernel bug and fix H1 was insufficient

## Raw

- `diag-r0.log` / `diag-r1.log` — full log with control + failed num_sms=full
