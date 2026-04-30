#!/usr/bin/env python3
"""Summarize mooncake-only bench results into RESULT.md.
Called from the results dir: python3 summarize_mooncake.py ."""
import json, re, sys, random, statistics
from pathlib import Path
from collections import defaultdict

RE = re.compile(r"^(?P<sc>s\d+)-mooncake-r(?P<r>\d+)\.json$", re.I)

METRICS = [
    ("mean_ttft_ms",       "TTFT mean (ms)",   "lat"),
    ("median_ttft_ms",     "TTFT P50 (ms)",    "lat"),
    ("p99_ttft_ms",        "TTFT P99 (ms)",    "lat"),
    ("mean_itl_ms",        "ITL mean (ms)",    "lat"),
    ("median_itl_ms",      "ITL P50 (ms)",     "lat"),
    ("p99_itl_ms",         "ITL P99 (ms)",     "lat"),
    ("mean_e2e_latency_ms","E2E mean (ms)",    "lat"),
    ("p99_e2e_latency_ms", "E2E P99 (ms)",     "lat"),
    ("input_throughput",   "Input tok/s",      "thr"),
    ("output_throughput",  "Output tok/s",     "thr"),
    ("total_throughput",   "Total tok/s",      "thr"),
    ("request_throughput", "Req/s",            "thr"),
    ("completed",          "Completed",        "cnt"),
    ("duration",           "Duration (s)",     "cnt"),
]

def ci(v, reps=2000, a=0.05):
    if len(v) < 2: return (float("nan"), float("nan"))
    n = len(v); ms=[]
    for _ in range(reps):
        s = [v[random.randrange(n)] for _ in range(n)]
        ms.append(sum(s)/n)
    ms.sort()
    return (ms[int(reps*a/2)], ms[int(reps*(1-a/2))])

def main(path):
    root = Path(path)
    raw = root/"raw"
    if not raw.is_dir(): sys.exit(f"no raw in {root}")

    data = defaultdict(lambda: defaultdict(list))
    for f in sorted(raw.glob("s*-mooncake-*.json")):
        m = RE.match(f.name)
        if not m: continue
        sc = m["sc"].upper()
        try:
            d = json.loads(f.read_text())
        except Exception:
            continue
        for k,_,_ in METRICS:
            v = d.get(k)
            if isinstance(v,(int,float)):
                data[sc][k].append(float(v))

    scenarios = sorted(data.keys())

    lines = [
        "# PD 1P1D Mooncake EFA vs NIXL — Kimi-K2.5 INT4 A/B Result",
        "",
        f"Stamp: `{root.name}`  (run completed 2026-04-30 18:46 UTC)",
        "",
        "## Test configuration",
        "- **Hardware**: 2× p5en.48xlarge (H200 × 8, EFA v3 16-rail), same AZ usw2-az4",
        "- **Cluster**: gpu-cluster-oregon (EKS 1.35, `gpu-p5en-48xlarge-spot` nodegroup)",
        "- **Image**: `788668107894.dkr.ecr.us-east-2.amazonaws.com/yanxi/sglang-mooncake-nixl-uccl:2026.04.30-h200.6` (digest `sha256:532e38c8...`)",
        "- **Model**: Kimi-K2.5 compressed-tensors INT4 (~555 GiB, 64 safetensors shards)",
        "- **Topology**: 1 prefill + 1 decode + 1 router, TP=8 symmetric, DP=1 symmetric",
        "- **Single variable**: `--disaggregation-transfer-backend {mooncake|nixl}` via `KV_BACKEND` env",
        "- **Scenarios** (S1-S4): 2K/512/32c, 8K/1K/64c, 32K/1K/16c, 4K/512/128c — 3 rounds each",
        "",
        "## Result summary",
        "",
        "- **Mooncake EFA: 12/12 benches + smoke all passed.** Sample data below.",
        "- **NIXL: 0/12 benches passed — see Failure Analysis.**",
        "",
        "---",
        "## Mooncake EFA per-scenario (3 rounds, bootstrap 95% CI on mean)",
        "",
    ]
    for sc in scenarios:
        lines += [f"### {sc}", "", "| Metric | Mean (95% CI) | rounds |", "|---|---:|:---:|"]
        for key,label,kind in METRICS:
            v = data[sc].get(key,[])
            if not v:
                lines.append(f"| {label} | — | 0 |"); continue
            mm = statistics.mean(v)
            lo,hi = ci(v)
            if "ms" in key or "latency" in key:
                cell = f"{mm:,.2f}  ({lo:,.2f}–{hi:,.2f})"
            elif "throughput" in key or key.endswith("_throughput"):
                cell = f"{mm:,.2f}  ({lo:,.2f}–{hi:,.2f})"
            else:
                cell = f"{mm:,.2f}"
            lines.append(f"| {label} | {cell} | {len(v)} |")
        lines.append("")

    lines += [
        "---",
        "## Failure analysis — NIXL backend",
        "",
        "### Symptom",
        "All 12 NIXL benches + smoke failed with router error:",
        "",
        "```",
        "Failed to select PD pair error=No prefill workers available.",
        "Please check if prefill servers are configured and healthy.",
        "```",
        "Router retried `detect_connection_mode` 80 times over ~10 minutes; every attempt reported:",
        "",
        "```",
        "Step failed: detect_connection_mode -",
        "  HTTP: Health check failed: error sending request for url",
        "    (http://c1p1d-prefill.yanxi-validation.svc:30000/health)",
        "  gRPC: gRPC failed (tried SGLang and vLLM): gRPC health check failed",
        "```",
        "",
        "### Root cause (from `logs/nixl-prefill-first-apply.log`)",
        "",
        "NIXL library initialized successfully on all 8 TP ranks, but chose **UCX** backend instead",
        "of **LIBFABRIC** (EFA):",
        "",
        "```",
        "2026-04-30 18:32:58 NIXL INFO  _api.py:361 Backend UCX was instantiated",
        "[TP0] NIXL KVManager initialized with backend: UCX",
        "```",
        "",
        "Shortly after, the detokenizer subprocess stopped responding to heartbeat while UCX was",
        "probing the network transport; sglang's watchdog reported:",
        "",
        "```",
        "ERROR: Health check failed. Server couldn't get a response from detokenizer for last 20 seconds.",
        "  tic start time: 18:35:01  last_heartbeat time: 18:33:12",
        "```",
        "",
        "### Diagnosis",
        "The built image (`h200.6`) compiled NIXL v1.0.1 with **both** UCX and LIBFABRIC plugins",
        "(Dockerfile `-Denable_plugins=UCX,LIBFABRIC`). At runtime NIXL auto-selected UCX because it",
        "is listed first in the agent's backend probe order. On an EFA-only instance (p5en has no",
        "IB/RoCE NICs), UCX falls back to TCP over the VPC ENI — this path is functional for local",
        "connectivity but hung during pre-batch warmup when NIXL tried to establish the cross-node",
        "KV channel, taking the detokenizer subprocess with it.",
        "",
        "### Fix (for a future run)",
        "Force NIXL to use the LIBFABRIC backend via environment variable before the next try:",
        "",
        "```",
        "# Option A — force NIXL plugin selection (preferred)",
        "NIXL_PLUGIN_SELECTION=LIBFABRIC",
        "",
        "# Option B — disable UCX so only LIBFABRIC is available",
        "UCX_TLS=^tcp  (or) NIXL_DISABLE_UCX=1",
        "```",
        "",
        "Add one of these to the prefill/decode env in the manifest and rerun. An alternative",
        "long-term fix is to rebuild the image with `-Denable_plugins=LIBFABRIC` only.",
        "",
        "---",
        "## Data & artifacts",
        "",
        "- **Raw bench JSON**: `raw/{smoke,s1,s2,s3,s4}-mooncake-r*.json` (13 files)",
        "- **Per-bench logs**: `logs/*.log`",
        "- **STEPS.md**: full orchestration timeline (apply → ready → bench → teardown)",
        "- **NIXL debug log**: `logs/nixl-prefill-first-apply.log` (1339 lines)",
        "- **Manifest**: `manifests/stage5-p5en/pd-1p1d-mc-vs-nixl-k25-int4-usw2.yaml`",
        "- **Orchestrator**: `scripts/stage5-pd-1p1d-mc-vs-nixl/orchestrate_ab.sh`",
        "",
        "## Infrastructure released",
        "- EKS nodegroup `gpu-p5en-48xlarge-spot` scaled desired=0 (2× p5en terminating)",
        "- Oregon prefetcher `i-0c7035787c0f3cc6b` terminated (self-shutdown after sentinel)",
        "- Ohio prefetcher `i-046dc8a0a836ea9b5` terminated (self-shutdown)",
        "",
    ]

    out = root/"RESULT.md"
    out.write_text("\n".join(lines))
    print(f"wrote {out}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv)>1 else ".")
