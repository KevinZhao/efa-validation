#!/usr/bin/env python3
"""Post-process sglang bench_serving A/B raw JSONs into RESULT.md.
Reads: <RESULTS>/raw/*.json
Writes: <RESULTS>/RESULT.md with Δ% + bootstrap 95% CI.
"""
import json, re, sys, random
from pathlib import Path
from statistics import mean
from collections import defaultdict

RE = re.compile(r"^(?P<sc>s\d+)-(?P<be>mooncake|nixl)-r(?P<r>\d+)\.json$", re.I)

METRICS = [
    ("mean_ttft_ms",   "TTFT mean (ms)",   "latency"),
    ("median_ttft_ms", "TTFT P50 (ms)",    "latency"),
    ("p99_ttft_ms",    "TTFT P99 (ms)",    "latency"),
    ("mean_itl_ms",    "ITL mean (ms)",    "latency"),
    ("median_itl_ms",  "ITL P50 (ms)",     "latency"),
    ("p99_itl_ms",     "ITL P99 (ms)",     "latency"),
    ("mean_e2e_latency_ms", "E2E mean (ms)", "latency"),
    ("input_throughput",   "Input tok/s",   "throughput"),
    ("output_throughput",  "Output tok/s",  "throughput"),
    ("total_token_throughput", "Total tok/s", "throughput"),
    ("request_throughput", "Req/s",        "throughput"),
    ("completed",          "Completed",    "count"),
]

def boot_ci(v, reps=2000, a=0.05):
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
    if not raw.is_dir():
        sys.exit(f"no raw dir under {root}")

    data = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for f in sorted(raw.glob("*.json")):
        m = RE.match(f.name)
        if not m:
            if f.name.startswith("smoke"): continue
            print(f"skip {f.name}")
            continue
        sc = m["sc"].upper(); be = m["be"]
        try:
            d = json.loads(f.read_text())
        except Exception as e:
            print(f"skip {f} parse err: {e}")
            continue
        for k,_,_ in METRICS:
            v = d.get(k)
            if isinstance(v,(int,float)):
                data[sc][be][k].append(float(v))

    scenarios = sorted(data.keys())

    lines = [
        f"# Stage 5 PD 1P1D — Mooncake EFA vs NIXL  A/B Result",
        f"",
        f"Stamp: `{root.name}`",
        f"Model: Kimi-K2.5 (compressed-tensors INT4, ~555 GiB)  ",
        f"Hardware: 2× p5en.48xlarge (H200 x 8, EFA v3 16-rail) in usw2-az4",
        f"Image: `sglang-mooncake-nixl-uccl:2026.04.30-h200.6` (same image, backend toggled via `--disaggregation-transfer-backend`)  ",
        f"Scenarios: S1=2K/512/32c, S2=8K/1K/64c, S3=32K/1K/16c, S4=4K/512/128c — 3 rounds each alternating A/B",
        f"",
        f"---",
    ]

    # per-scenario table
    for sc in scenarios:
        mc = data[sc].get("mooncake", {})
        nx = data[sc].get("nixl", {})
        lines += [f"## {sc}", "", "| Metric | Mooncake mean (95% CI) | NIXL mean (95% CI) | Δ% (NIXL/MC − 1) | Winner |", "|---|---:|---:|---:|:---:|"]
        for key,label,kind in METRICS:
            mv = mc.get(key,[]); nv = nx.get(key,[])
            if not mv or not nv:
                lines.append(f"| {label} | — | — | — | — |"); continue
            mm, nm = mean(mv), mean(nv)
            mlo,mhi = boot_ci(mv); nlo,nhi = boot_ci(nv)
            dp = (nm/mm - 1.0)*100 if mm>0 else float("nan")
            if kind == "latency":
                winner = "NIXL" if dp < -1 else ("Mooncake" if dp > 1 else "≈")
            elif kind == "throughput":
                winner = "NIXL" if dp > 1 else ("Mooncake" if dp < -1 else "≈")
            else:
                winner = "—"
            lines.append(f"| {label} | {mm:.2f} ({mlo:.2f}–{mhi:.2f}) | {nm:.2f} ({nlo:.2f}–{nhi:.2f}) | {dp:+.2f}% | {winner} |")
        lines.append("")

    # aggregate
    lines += ["---", "## Aggregate across scenarios", "", "| Metric | Geo-mean ratio NIXL/MC | Interpretation |", "|---|---:|---|"]
    for key,label,kind in METRICS:
        ratios=[]
        for sc in scenarios:
            mv = data[sc]["mooncake"].get(key,[])
            nv = data[sc]["nixl"].get(key,[])
            if mv and nv and mean(mv) > 0:
                ratios.append(mean(nv)/mean(mv))
        if not ratios:
            lines.append(f"| {label} | — | — |"); continue
        p=1.0
        for r in ratios: p*=r
        geo = p**(1.0/len(ratios))
        if kind == "latency":
            intr = "NIXL faster" if geo<0.99 else ("Mooncake faster" if geo>1.01 else "≈")
        elif kind == "throughput":
            intr = "NIXL higher" if geo>1.01 else ("Mooncake higher" if geo<0.99 else "≈")
        else:
            intr = "—"
        lines.append(f"| {label} | {geo:.4f} | {intr} |")

    lines.append("")
    lines += [
        "---",
        "## Method",
        "- Same image, same model, same SGLang, same service flags. Only `--disaggregation-transfer-backend` flips mooncake↔nixl.",
        "- Topology: 1P+1D (TP=8 each), DP=1 symmetric, same AZ (usw2-az4).",
        "- For each scenario, 3 rounds per backend, alternating A/B to cancel drift.",
        "- Metrics from `sglang.bench_serving` (random dataset).",
        "- Bootstrap 95% CI on the mean across 3 rounds (2000 resamples).",
    ]

    out = root/"RESULT.md"
    out.write_text("\n".join(lines))
    print(f"wrote {out}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv)>1 else ".")
