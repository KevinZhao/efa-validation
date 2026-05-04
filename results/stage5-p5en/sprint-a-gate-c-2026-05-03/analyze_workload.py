#!/usr/bin/env python3
"""Workload scaling analysis — num_tokens × {dispatch-base, combine-base, combine-overlap-22}."""

import re
import sys
from collections import defaultdict

import numpy as np

LINE_RE = re.compile(
    r"BENCH rank=(\d+) iter=(\d+) mode=([\w-]+) num_tokens=(\d+) "
    r"num_sms=(\d+) avg=([\d.]+) p50=([\d.]+) p99=([\d.]+) "
    r"p999=([\d.]+) min=([\d.]+) max=([\d.]+)"
)


def parse(paths):
    rows = []
    for p in paths:
        with open(p) as f:
            for line in f:
                m = LINE_RE.search(line)
                if not m:
                    continue
                rank, it, mode, ntok, nsms, avg, p50, p99, p999, mn, mx = m.groups()
                rows.append(
                    (int(rank), int(it), mode, int(ntok), int(nsms),
                     float(avg), float(p50), float(p99), float(p999),
                     float(mn), float(mx))
                )
    return rows


def bootstrap_ratio(b, o, n=5000, seed=42):
    rng = np.random.default_rng(seed)
    b, o = np.asarray(b), np.asarray(o)
    r = np.empty(n)
    for i in range(n):
        bs = rng.choice(b, size=len(b), replace=True).mean()
        os_ = rng.choice(o, size=len(o), replace=True).mean()
        r[i] = (os_ - bs) / bs
    return (np.percentile(r, 2.5), np.percentile(r, 50), np.percentile(r, 97.5))


def main():
    rows = parse(sys.argv[1:] or ["workload-r0.log", "workload-r1.log"])
    print(f"Parsed {len(rows)} BENCH rows\n")

    # group by (mode, ntok)
    grp = defaultdict(lambda: defaultdict(list))
    for rank, it, mode, ntok, nsms, avg, p50, p99, p999, mn, mx in rows:
        key = (mode, ntok)
        grp[key]["avg"].append(avg)
        grp[key]["p50"].append(p50)
        grp[key]["p99"].append(p99)
        grp[key]["p999"].append(p999)
        grp[key]["max"].append(mx)

    tokens = sorted({k[1] for k in grp.keys()})
    print("=== Summary (µs) ===\n")
    hdr = f"{'mode':<22} {'ntok':>5} {'n':>4} {'avg':>8} {'p50':>8} {'p99':>8} {'p99.9':>8} {'max':>8}"
    print(hdr); print("-"*len(hdr))
    for ntok in tokens:
        for mode in ("dispatch-base", "combine-base", "combine-overlap-22"):
            key = (mode, ntok)
            if key not in grp:
                continue
            d = grp[key]
            print(
                f"{mode:<22} {ntok:>5} {len(d['avg']):>4} "
                f"{np.mean(d['avg']):>8.2f} {np.mean(d['p50']):>8.2f} "
                f"{np.mean(d['p99']):>8.2f} {np.mean(d['p999']):>8.2f} "
                f"{np.mean(d['max']):>8.2f}"
            )
        print()

    print("=== Combine overlap-22 Δ vs combine-base (same ntok, same session) ===\n")
    print(f"{'ntok':>5} {'metric':<8} {'Δ median':>10} {'CI lower':>10} {'CI upper':>10} {'xzero':>6}")
    print("-"*60)
    for ntok in tokens:
        base_key = ("combine-base", ntok)
        ov_key = ("combine-overlap-22", ntok)
        if base_key not in grp or ov_key not in grp:
            continue
        for metric in ("avg", "p50", "p99", "p999", "max"):
            b = grp[base_key][metric]
            o = grp[ov_key][metric]
            lo, med, hi = bootstrap_ratio(b, o)
            xz = "YES" if lo < 0 < hi else "NO"
            print(
                f"{ntok:>5} {metric:<8} {med*100:>+9.2f}% {lo*100:>+9.2f}% {hi*100:>+9.2f}% {xz:>6}"
            )
        print()


if __name__ == "__main__":
    main()
