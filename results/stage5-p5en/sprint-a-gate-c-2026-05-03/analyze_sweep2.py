#!/usr/bin/env python3
"""Fine-grain num_sms sweep analysis with p50/p99/p999."""

import re
import sys
from collections import defaultdict

import numpy as np

LINE_RE = re.compile(
    r"BENCH rank=(\d+) iter=(\d+) mode=([\w-]+) num_sms=(\d+) "
    r"avg=([\d.]+) p50=([\d.]+) p99=([\d.]+) p999=([\d.]+) "
    r"min=([\d.]+) max=([\d.]+)"
)


def parse(paths):
    rows = []
    for path in paths:
        with open(path) as f:
            for line in f:
                m = LINE_RE.search(line)
                if not m:
                    continue
                rank, it, mode, nsms, avg, p50, p99, p999, mn, mx = m.groups()
                rows.append(
                    (
                        int(rank), int(it), mode, int(nsms),
                        float(avg), float(p50), float(p99), float(p999),
                        float(mn), float(mx),
                    )
                )
    return rows


def main():
    rows = parse(sys.argv[1:] or ["sweep2-r0.log", "sweep2-r1.log"])
    print(f"Parsed {len(rows)} BENCH rows\n")

    by_mode = defaultdict(lambda: defaultdict(list))
    for r, it, mode, nsms, avg, p50, p99, p999, mn, mx in rows:
        by_mode[mode]["avg"].append(avg)
        by_mode[mode]["p50"].append(p50)
        by_mode[mode]["p99"].append(p99)
        by_mode[mode]["p999"].append(p999)
        by_mode[mode]["min"].append(mn)
        by_mode[mode]["max"].append(mx)
        by_mode[mode]["nsms_val"] = nsms

    ordered = sorted(
        by_mode.keys(),
        key=lambda m: (0 if m == "baseline" else 1, by_mode[m]["nsms_val"]),
    )

    header = (
        f"{'mode':<14} {'SM':>4} {'n':>5} "
        f"{'avg':>8} {'p50':>8} {'p99':>8} {'p99.9':>8} {'max':>8} {'stdev':>8}"
    )
    print(header)
    print("-" * len(header))
    for mode in ordered:
        d = by_mode[mode]
        print(
            f"{mode:<14} {d['nsms_val']:>4} {len(d['avg']):>5} "
            f"{np.mean(d['avg']):>8.2f} {np.mean(d['p50']):>8.2f} "
            f"{np.mean(d['p99']):>8.2f} {np.mean(d['p999']):>8.2f} "
            f"{np.mean(d['max']):>8.2f} {np.std(d['avg']):>8.2f}"
        )

    print()
    print("=== Δ vs baseline — 95% bootstrap CI ===\n")
    for metric in ("avg", "p50", "p99", "p999", "max"):
        print(f"--- {metric} ---")
        b = np.array(by_mode["baseline"][metric])
        rng = np.random.default_rng(42)
        for mode in ordered:
            if mode == "baseline":
                continue
            d = by_mode[mode]
            o = np.array(d[metric])
            ratios = np.empty(5000)
            for i in range(5000):
                bs = rng.choice(b, size=len(b), replace=True).mean()
                os_ = rng.choice(o, size=len(o), replace=True).mean()
                ratios[i] = (os_ - bs) / bs
            lo = np.percentile(ratios, 2.5)
            med = np.percentile(ratios, 50)
            hi = np.percentile(ratios, 97.5)
            xz = "YES" if lo < 0 < hi else "NO"
            print(
                f"  {mode:<14} SM={d['nsms_val']:>3}  "
                f"median={med*100:+.2f}%  CI=[{lo*100:+.2f}%, {hi*100:+.2f}%]  xzero={xz}"
            )
        print()


if __name__ == "__main__":
    main()
