#!/usr/bin/env python3
"""num_sms sweep analysis."""

import re
import sys
from collections import defaultdict

import numpy as np

LINE_RE = re.compile(
    r"BENCH rank=(\d+) iter=(\d+) mode=([\w-]+) num_sms=(\d+) "
    r"avg=([\d.]+) min=([\d.]+) max=([\d.]+)"
)


def parse(paths):
    rows = []
    for path in paths:
        with open(path) as f:
            for line in f:
                m = LINE_RE.search(line)
                if not m:
                    continue
                rank, it, mode, nsms, avg, mn, mx = m.groups()
                rows.append(
                    (int(rank), int(it), mode, int(nsms), float(avg), float(mn), float(mx))
                )
    return rows


def main():
    rows = parse(sys.argv[1:] or ["sweep-r0.log", "sweep-r1.log"])
    print(f"Parsed {len(rows)} BENCH rows\n")

    # Group by mode
    by_mode = defaultdict(lambda: {"avg": [], "min": [], "max": [], "nsms": None})
    for rank, it, mode, nsms, avg, mn, mx in rows:
        by_mode[mode]["avg"].append(avg)
        by_mode[mode]["min"].append(mn)
        by_mode[mode]["max"].append(mx)
        by_mode[mode]["nsms"] = nsms

    # Order modes: baseline first, then overlap by num_sms ascending
    ordered = sorted(by_mode.keys(), key=lambda m: (0 if m == "baseline" else 1, by_mode[m]["nsms"]))

    print(f"{'mode':<14} {'num_sms':>8} {'n':>5} {'avg_mean':>10} {'avg_med':>10} {'avg_std':>10} {'min_mean':>10} {'max_mean':>10}")
    print("-" * 90)
    baseline_avg = None
    for mode in ordered:
        d = by_mode[mode]
        vals_avg = np.array(d["avg"])
        vals_min = np.array(d["min"])
        vals_max = np.array(d["max"])
        print(
            f"{mode:<14} {d['nsms']:>8} {len(vals_avg):>5} "
            f"{vals_avg.mean():>10.2f} {np.median(vals_avg):>10.2f} {vals_avg.std():>10.2f} "
            f"{vals_min.mean():>10.2f} {vals_max.mean():>10.2f}"
        )
        if mode == "baseline":
            baseline_avg = vals_avg.mean()

    if baseline_avg is None:
        return

    print("\n=== Δ vs baseline (avg_t mean) with bootstrap 95% CI ===\n")
    b = np.array(by_mode["baseline"]["avg"])
    rng = np.random.default_rng(42)
    print(f"{'mode':<14} {'num_sms':>8} {'Δ median':>12} {'CI lower':>12} {'CI upper':>12} {'xzero':>6}")
    print("-" * 70)
    for mode in ordered:
        if mode == "baseline":
            continue
        d = by_mode[mode]
        o = np.array(d["avg"])
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
            f"{mode:<14} {d['nsms']:>8} "
            f"{med*100:>+11.2f}% {lo*100:>+11.2f}% {hi*100:>+11.2f}% {xz:>6}"
        )


if __name__ == "__main__":
    main()
