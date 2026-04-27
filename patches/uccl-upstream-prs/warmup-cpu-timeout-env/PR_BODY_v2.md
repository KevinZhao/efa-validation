# [EP] Allow runtime override of CPU recv timeout via UCCL_EP_CPU_TIMEOUT_SECS

## Description

Allow runtime override of the CPU-side recv timeout via the new
`UCCL_EP_CPU_TIMEOUT_SECS` environment variable.

The timeout is currently a compile-time constant `NUM_CPU_TIMEOUT_SECS`
(100 seconds in non-FAST_DEBUG builds, defined in `ep/include/ep_configs.cuh:14`),
consumed at `ep/src/uccl_ep.cc` (two sites in `Buffer::low_latency_dispatch` and
`Buffer::dispatch`) to bound the `moe_recv_counter` host-side spin loop.

Long training steps (e.g. DeepSeek-V3 / Qwen3-235B Megatron runs with large
grad accumulation, heavy checkpoint I/O, or EP groups that initialize
sequentially under PP ≥ 2) can exceed the 100 s window between successive
dispatches and falsely trigger:

```
DeepEP error: CPU recv timeout
DeepEP error: timeout (dispatch CPU)
```

This was explicitly requested by @AutoJunjie in
https://github.com/uccl-project/uccl/issues/893:

> *"Is there a runtime knob for `NUM_TIMEOUT_CYCLES`, or is re-compiling the
> only path today?"*

The same symptom family also appears in
https://github.com/uccl-project/uccl/issues/878 (Qwen3-235B EP=16 intermittent
crashes on AWS EFA).

Scope note: this PR only touches the CPU-side spin timeout. The GPU-side
`NUM_TIMEOUT_CYCLES` is untouched.

Fixes first half of #893 (runtime knob for CPU timeout).
Related to #878 (similar symptom on EFA).

## Type of Change
- [x] Bug fix

## Design

- New helper `get_cpu_timeout_secs(int fallback_secs)` in `ep/include/common.hpp`,
  placed alongside the four existing env helpers
  (`get_max_inflight_bytes`, `get_max_inflight_low_latency`,
  `get_max_inflight_normal`, `get_aggressive_atomic_enabled`) to match the
  established pattern.
- `fallback_secs` is passed as an argument so `common.hpp` does not need to
  include `ep_configs.cuh`; callers pass the compile-time constant
  `NUM_CPU_TIMEOUT_SECS` explicitly.  The static-local cache remains valid
  because callers always pass the same compile-time value.
- Parses with `strtol` + validation (not `atoi`):
  - env unset / empty        → silent fallback to `NUM_CPU_TIMEOUT_SECS`
  - valid positive int       → use it, capped at `INT_MAX`
  - 0 / negative / garbage   → fallback + one-time `[UCCL] Warning: ...` to stderr
- Parsed once per process via C++11 thread-safe static local (magic static),
  matching the existing env-helper pattern.

## How Has This Been Tested?

- [x] **Format**: `./format.sh` (clang-format-14, black) produces no diff on the
      two changed files.
- [x] **Static check**: `clang-format-14 --dry-run --Werror ep/include/common.hpp
      ep/src/uccl_ep.cc` clean.
- [ ] **Build**: `bash build.sh cu12 ep --install` on an H200 host — I do not
      currently have a p5en node warm; planning to run this together with a
      full smoke pass on Stage 5, and will attach the log as a follow-up
      comment before merge.
- [ ] **Unit tests**: none added.  The env is parsed lazily via a
      static-local cache, so same-process pytest parametrization does not
      work — a proper test needs `subprocess` isolation across cases.
      Happy to add `ep/tests/test_cpu_timeout_env.py` in a follow-up commit
      if desired; otherwise the existing microbench (`test_low_latency.py`)
      will exercise the unset-env path.
- [ ] **Manual stress**: Megatron run with `UCCL_EP_CPU_TIMEOUT_SECS=600` to
      confirm no false timeout during heavy grad-accum steps — planned as
      part of Stage 5 validation; will attach results.

## Checklist
- [x] I have run `format.sh` to follow the style guidelines.
- [ ] I have run `build.sh cu12 ep --install` to verify compilation.  *(see
      "How Has This Been Tested?" above — GPU host pending)*
- [x] I have removed redundant variables and comments.
- [ ] I have updated the documentation.  *(README env-var table update will
      land as a separate commit once the API is settled in review.)*
- [ ] I have added tests.  *(see notes above.)*

## Notes for reviewers

- Env name choice: went with `UCCL_EP_CPU_TIMEOUT_SECS` (EP-specific) to
  mirror the existing `UCCL_EP_*` naming for EP-module knobs
  (e.g. `UCCL_EP_ENABLE_AGGRESSIVE_ATOMIC`).  Happy to rename if you'd
  prefer `UCCL_CPU_TIMEOUT_SECS` (repo-wide) or `DEEPEP_CPU_TIMEOUT_SECS`
  (align with the error string).

- Validation policy: silent fallback for unset/empty vs stderr warning for
  garbage/negative/zero.  The rationale is that unset is the normal path
  for 99% of users, while garbage/negative is almost always a user error
  worth surfacing.  Can be toned down to fully silent or switched to
  `glog` if preferred.

/cc @MaoZiming @YangZhou1997
