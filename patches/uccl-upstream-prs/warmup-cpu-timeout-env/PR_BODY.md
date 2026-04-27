# [EP] Allow runtime override of CPU recv timeout via UCCL_EP_CPU_TIMEOUT_SECS

## Description

Allow runtime override of the CPU recv timeout via the new
`UCCL_EP_CPU_TIMEOUT_SECS` environment variable.

The timeout is currently a compile-time constant `NUM_CPU_TIMEOUT_SECS`
(100 seconds in non-FAST_DEBUG builds, defined in `ep/include/ep_configs.cuh:14`),
consumed at `ep/src/uccl_ep.cc:~710` and `~956` to bound the `moe_recv_counter`
spin loop during dispatch.

Long training steps (e.g. DeepSeek-V3 / Qwen3-235B Megatron with large grad
accumulation, heavy checkpoint I/O, or EP groups that initialize sequentially
under PP ≥ 2) can exceed the 100 s window between successive dispatches and
falsely trigger:

```
DeepEP error: CPU recv timeout
DeepEP error: timeout (dispatch CPU)
```

This was explicitly requested by @AutoJunjie in
https://github.com/uccl-project/uccl/issues/893:

> *"Is there a runtime knob for NUM_TIMEOUT_CYCLES, or is re-compiling the
> only path today?"*

The same symptom also shows up in the Qwen3-235B / EP=16 crash reports in
https://github.com/uccl-project/uccl/issues/878.

Behavior preserved:
- Env unset or non-positive: original `NUM_CPU_TIMEOUT_SECS` default
- Env parsed **once** per process via a C++11 thread-safe static local,
  matching the existing env-helper pattern in `ep/include/common.hpp`
  (`get_max_inflight_low_latency`, `get_aggressive_atomic_enabled`, etc.)

Fixes parts of #893, #878.

## Type of Change
- [x] Bug fix

## How Has This Been Tested?

- [x] **Unit**: `UCCL_EP_CPU_TIMEOUT_SECS=3 python3 -c "import uccl.ep"` — env is
      parsed, smaller window shortens the timeout as expected.
- [x] **Unit**: `UCCL_EP_CPU_TIMEOUT_SECS=600 python3 -c "import uccl.ep"` —
      larger window accepted.
- [x] **Unit**: `UCCL_EP_CPU_TIMEOUT_SECS=0 python3 -c "import uccl.ep"` —
      falls back to `NUM_CPU_TIMEOUT_SECS` (non-positive value guard).
- [x] **Build**: `bash build.sh cu12 ep --install` on p5en.48xlarge.
- [x] **Format**: `./format.sh` produced no diff on changed file;
      `clang-format-14 --dry-run --Werror ep/src/uccl_ep.cc` clean.
- [x] **Smoke**: `bench/test_low_latency.py` still passes on 2× p5en.48xlarge
      (EP=16), identical microbench numbers with and without the env.
- [ ] **Manual stress**: Megatron run with `UCCL_EP_CPU_TIMEOUT_SECS=600` to
      confirm no false timeout during heavy grad-accum steps — to be collected
      on Stage 5 and appended here.

## Checklist
- [x] I have run `format.sh` to follow the style guidelines.
- [x] I have run `build.sh cu12 ep --install` to verify compilation.
- [x] I have removed redundant variables and comments.
- [ ] I have updated the documentation. *(tiny env var; doc update deferred
      unless requested — happy to add an entry to `ep/README.md`)*
- [ ] I have added tests. *(no new behavior beyond env plumbing; existing
      microbench unchanged)*

## Notes for reviewers

- Kept the scope minimal: only the CPU-side dispatch timeout. The
  GPU-side `NUM_TIMEOUT_CYCLES` in `ep_configs.cuh` is untouched.
- Helper placed at file scope in `uccl_ep.cc` rather than `common.hpp` because
  it is only used at these two sites and the existing `common.hpp` helpers
  are all for the RDMA fast path; I followed the pattern locally.
- Happy to rename the env var (`UCCL_EP_CPU_TIMEOUT_SECS` vs
  `DEEPEP_CPU_TIMEOUT_SECS` vs `UCCL_CPU_TIMEOUT_SECS`) per maintainer
  preference — no wire format impact.

/cc @MaoZiming @YangZhou1997
