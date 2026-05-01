# PD 1P1D — Mooncake EFA vs NIXL (LIBFABRIC) — Kimi-K2.5 INT4

Run stamp: `20260501T002853Z`

## TL;DR

NIXL/LIBFABRIC beats Mooncake EFA across S1-S6 on p5en.48xlarge + Kimi-K2.5 INT4 PD-disagg,
geo-mean:

| Metric | NIXL/Mooncake ratio | Reading |
|---|---:|---|
| TTFT mean | 0.80 | NIXL ~20% faster |
| ITL mean  | 0.87 | NIXL ~13% faster |
| E2E mean  | 0.85 | NIXL ~15% faster |
| Throughput| 1.16 | NIXL ~16% higher |

Gap is scenario-dependent:

- **Short ctx + high concurrency** (S2 8K/cc=64, S4 4K/cc=128) → NIXL wins by **30-44%** on ITL/throughput. KV transport efficiency dominates because KV is shipped frequently.
- **Long ctx + low concurrency** (S5 60K/cc=8, S6 120K/cc=4) → gap **collapses to ~2-3%**. Prefill compute is the bottleneck; KV transport barely matters.
- **Very long ctx + moderate cc** (S3 32K/cc=16) → essentially tied.

## Files in this directory

| File | Description |
|---|---|
| `RESULT.md` | **Primary report.** Full per-scenario A/B tables (S1-S6) with bootstrap 95% CI, geo-mean aggregate, method, caveats. Generated from `scripts/stage5-pd-1p1d-mc-vs-nixl/bench/summarize.py`. |
| `STEPS.md` | Full orchestration timeline across all 3 runs (S1-S4 initial, S5/S6 v1 failed, S5/S6 v2 recovered). |
| `raw/*.json` | 36 benchmark JSONs: `s{1..6}-{mooncake,nixl}-r{1,2,3}.json` + 1 smoke. S5 NIXL is missing r1 (failed during router warmup). |
| `logs/*.log` | Per-bench sglang.bench_serving stdout/stderr + orchestrator log. Not in git (gitignore'd), local only. |
| `summarize_mooncake.py` | Legacy mooncake-only summarizer (kept for reference). |

## Reproducing this run

Inputs pinned in the manifest (Oregon variant):

- Infra: EKS `gpu-cluster-oregon`, `gpu-p5en-48xlarge-spot` nodegroup, subnet pinned to usw2-az4
- Image: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake-nixl-uccl:2026.04.30-h200.6`
- Weights: `s3://yanxi-validation-788668107894-oregon/models/moonshotai/Kimi-K2.5/` (regional S3 gateway endpoint)

Commands (from Oregon bastion `i-081b2b010b6af530c`):

```bash
# S1-S4
STAMP=<new> HF_TOKEN=<token> /root/run_ab_eks.sh

# S5/S6 (requires prime_router patch)
STAMP=<same-stamp-to-append> HF_TOKEN=<token> /root/run_s5s6_v2.sh
```

Scripts live at `scripts/stage5-pd-1p1d-mc-vs-nixl/run_ab_eks.sh` and `run_s5s6_v2.sh` in repo root.

## Known caveats

- **S5 NIXL rounds=2** (r1 failed) — first 60K warmup consumed router prime. S6 NIXL has full 3 rounds, and direction of S5 matches S6, so the conclusion is robust.
- **S5/S6 used fresh Oregon Spot nodes** after S1-S4 nodes were reclaimed — same AMI/launch-template, different physical p5en.
- **3 rounds per bench** → bootstrap CIs on the mean are wide (especially S1 TTFT). Direction is consistent across scenarios, but individual point estimates carry real uncertainty.

## Commits relevant to this run

- `a121bf7` — S1-S4 completion (24 benches + initial RESULT.md)
- `ca81e23` — first S5/S6 orchestrator (no prime_router)
- `25d4914` — Ohio pivot attempt (postponed) + Ohio manifest
- `67fcaad` — S5/S6 v2 completion (router-primed), final RESULT.md regenerated
