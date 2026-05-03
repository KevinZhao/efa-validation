# bench_serving OAI-compat stats fix — E2E validation

**Environment**
- p5.48xlarge spot, us-west-2b, image `public.ecr.aws/n3l4x8f3/sglang-mooncake-uccl:2026.04.28-h200.6`
- sglang 0.5.10 (container baseline), Qwen3-Next-80B-A3B-Instruct, TP=8 single node
- All tests: `--num-prompts 5 --max-concurrency 1`, same server process between runs, only
  `bench_serving.py` swapped in via `docker cp` (patched vs upstream).

## PRs under validation

- **#24255** — `IndexError` fix + `output_len` scope correction for `sglang-oai` SSE parse
- **#24266** — default `stream_options.include_usage=true` on both `sglang-oai` and
  `sglang-oai-chat` (depends on #24255)

"combined" below means the container's `bench_serving.py` was replaced by the fork with
both PR diffs applied; "upstream" is the original sglang 0.5.10 shipped in the image
(md5 `1c5b1ee2d40b9ca6696730b1145ade3a`).

## T1 — sglang-oai + early-stop (the original bug)

Workload: `max_tokens=512`, `--extra-request-body '{"stop":["."]}'` → real decode ~24 tokens.

| Variant | Mean TPOT (ms) | Note |
|---|---|---|
| upstream | **0.24** | physically impossible — implies ~505 output tokens/req |
| combined | **5.17** | matches real decode rate |

See `/tmp/earlystop-full.log` (captured pre-compaction, numbers verified against container).

## T2 — sglang-oai-chat + early-stop (new evidence, same bug)

Same workload as T1 but `--backend sglang-oai-chat`.

| Variant | Mean TPOT (ms) | Total throughput (tok/s) |
|---|---|---|
| upstream | 0.38 | 1683.43 |
| combined | 5.06 | 158.22 |

Chat endpoint has the same `output_len` fallback symptom as completions under early-stop.
The ~10× throughput inflation is the signature.

## T3 — sglang-oai + natural EOS (no regression)

Workload: `--random-output 64 --disable-ignore-eos` (model stops at EOS before hitting 64).

| Variant | Mean TPOT (ms) | Total throughput (tok/s) |
|---|---|---|
| upstream | 5.05 | 184.48 |
| combined | 5.13 | 182.29 |

When generation runs close to `max_tokens`, the upstream fallback happens to be ~right,
so both paths produce matching numbers. Confirms no regression on the common case.

## T4 — sglang-oai + --disable-stream (gate works)

Workload: `--disable-stream --disable-ignore-eos`, non-streaming.

| Variant | Mean TPOT (ms) |
|---|---|
| upstream | -0.00 (non-streaming has no per-token timings) |
| combined | -0.00 |

The `if not args.disable_stream` guard in #24266 correctly skips the `stream_options`
injection on non-streaming requests. Behavior identical to upstream.

## Raw log

Full captured output: [`t234-matrix.log`](./t234-matrix.log)
