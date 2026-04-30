# Stage 5 PD 1P1D — Mooncake EFA vs NIXL A/B comparison (Kimi-K2.5 INT4)

## Purpose
Same hardware, same SGLang, same model, same workload. Only KV transfer backend
differs. Measures whether Mooncake EFA and NIXL differ in TTFT / ITL / throughput
for a PD-disaggregated 1P1D deployment of Kimi-K2.5 INT4 (compressed-tensors).

## Image (already built)
- URI: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake-nixl-uccl:2026.04.30-h200.6`
- Digest: `sha256:532e38c882aec01e67000c2491e4ef80096eb6916e2d3ada1c82027206268b2f`
- Pushed: 2026-04-30 16:44 UTC
- Size: 11.21 GB (linux/amd64)
- Mooncake ref: `634b7097` (matches customer-h200.3)
- UCCL ref: `8ac850bd` (matches customer-h200.3)
- NIXL ref: `v1.0.1`, UCX `v1.18.0`
- SGLang: `0.5.10`
- Build-time sanity asserted: both `mooncake` and `nixl` show up in
  `sglang.launch_server --help` under `--disaggregation-transfer-backend`.

## Topology
- 2 × p5en.48xlarge, Spot, same AZ (hard rule)
- Node P: Prefill, TP=8 DP=1 single-node
- Node D: Decode,  TP=8 DP=1 single-node
- Router: sglang-router 0.3.2 with `--pd-disaggregation` on the P node

## Single variable
Only `--disaggregation-transfer-backend {mooncake|nixl}` differs between
variant A (Mooncake) and variant B (NIXL). Image, SGLang args, env vars, model,
workload all identical.

## Why 1P1D (not 2P+2D)
Kimi-K2.5 is INT4 (~555 GiB) — TP=8 single node fits cleanly into 8 × H200 =
1128 GB HBM. Symmetric DP=1 / DP=1 also avoids the 4/29 Gloo TCP SIGABRT that
struck customer's asymmetric DP=2 / DP=8 (see `repro/k2-5-segfault/results/RESULT.md`).

## Deliberate deviations from customer compose
| Item | Customer | Here | Reason |
|---|---|---|---|
| `--dp-size` P/D | 2 / 8 | 1 / 1 | INT4 fits single-node; avoids Gloo SIGABRT |
| `--enable-dp-attention` | on | off | DP=1 makes it a no-op; also bypasses Gloo path |
| `--enable-dp-lm-head` | on D | off | depends on dp-attention |
| `--max-running-requests` P/D | 128 / 256 | 256 / 256 | remove asymmetry noise |
| All other SGLang args | verbatim | verbatim | maximize customer-setup fidelity |
| All MOONCAKE/FI/NVSHMEM env | verbatim | verbatim on A | NIXL path ignores MOONCAKE_* |

## Layout
```
scripts/stage5-pd-1p1d-mc-vs-nixl/
  README.md                        ← this file
  compose/
    prefill-compose.yml            ← single file, entrypoint env picks backend
    decode-compose.yml
    router-compose.yml
  entrypoints/
    prefill_entrypoint.sh          ← reads KV_BACKEND={mooncake|nixl}
    decode_entrypoint.sh           ← reads KV_BACKEND={mooncake|nixl}
    router_start.sh
  bench/
    bench_profile.sh               ← defines S1-S4 matrix
    run_ab_matrix.sh               ← orchestrates alternating A/B/A/B/A/B
    collect_efa_counters.sh
  launch_p5en_spot.sh              ← SPS-aware, same-AZ, spot-only
  pull_weights.sh                  ← s5cmd from s3://...-ohio/.../Kimi-K2.5 → /data/models
```

## Scenarios (S1-S4, 3 rounds each, alternating A/B)
| Scenario | input_len | output_len | concurrency | Purpose |
|---|---|---|---|---|
| S1 short | 2048 | 512 | 32 | low KV, control-plane sensitivity |
| S2 mid   | 8192 | 1024 | 64 | typical customer-profile |
| S3 large | 32768 | 1024 | 16 | KV-bandwidth-dominated |
| S4 high-conc | 4096 | 512 | 128 | queueing / scheduler stress |

Each scenario: 300-prompt warmup + 1000-prompt measurement per round.

## Output path
```
results/stage5-p5en/pd-1p1d-mc-vs-nixl-k25-int4/<UTC-stamp>/
  STEPS.md              ← running log of every action
  RESULT.md             ← final Δ% table + bootstrap 95% CI
  images.json           ← both variant image IDs (same image, different flag)
  raw/
    s1-mc-r1.json  s1-nixl-r1.json  s1-mc-r2.json ...
  logs/
    prefill-mc-r1.log  decode-mc-r1.log ...
  efa_counters/
    before.json  after.json  delta.json (per round)
```
