#!/usr/bin/env python3
"""Gate C analysis: bootstrap CI for overlap vs baseline combine latency."""

import re
import sys
from collections import defaultdict

import numpy as np

LINE_RE = re.compile(
    r"BENCH rank=(\d+) iter=(\d+) mode=(\w+) num_sms=(\d+) "
    r"avg=([\d.]+) min=([\d.]+) max=([\d.]+)"
)


def parse(paths):
    rows = []  # (rank, iter, mode, num_sms, avg, min, max)
    for path in paths:
        with open(path) as f:
            for line in f:
                m = LINE_RE.search(line)
                if not m:
                    continue
                rank, it, mode, num_sms, avg, mn, mx = m.groups()
                rows.append(
                    (
                        int(rank),
                        int(it),
                        mode,
                        int(num_sms),
                        float(avg),
                        float(mn),
                        float(mx),
                    )
                )
    return rows


def bootstrap_ci(vals, n_resample=5000, alpha=0.05, seed=42):
    rng = np.random.default_rng(seed)
    vals = np.asarray(vals)
    means = np.empty(n_resample)
    for i in range(n_resample):
        sample = rng.choice(vals, size=len(vals), replace=True)
        means[i] = sample.mean()
    lo = np.percentile(means, 100 * alpha / 2)
    hi = np.percentile(means, 100 * (1 - alpha / 2))
    return vals.mean(), lo, hi


def main():
    rows = parse(sys.argv[1:] or ["bench-r0.log", "bench-r1.log"])
    print(f"Parsed {len(rows)} BENCH rows from {len(sys.argv[1:]) or 2} log(s)")

    # Group by (mode, metric)
    by_mode = defaultdict(list)
    for rank, it, mode, num_sms, avg, mn, mx in rows:
        by_mode[(mode, "avg")].append(avg)
        by_mode[(mode, "min")].append(mn)
        by_mode[(mode, "max")].append(mx)

    print()
    print("=== Summary (µs, per-iter bench() averages pooled across 16 ranks × 30 iters) ===\n")
    header = f"{'mode':<10} {'metric':<6} {'n':>4} {'mean':>10} {'median':>10} {'p5':>10} {'p95':>10} {'stdev':>10}"
    print(header)
    print("-" * len(header))
    for mode in ("baseline", "overlap"):
        for metric in ("avg", "min", "max"):
            vals = np.array(by_mode[(mode, metric)])
            if len(vals) == 0:
                continue
            print(
                f"{mode:<10} {metric:<6} {len(vals):>4} "
                f"{vals.mean():>10.2f} {np.median(vals):>10.2f} "
                f"{np.percentile(vals, 5):>10.2f} {np.percentile(vals, 95):>10.2f} "
                f"{vals.std():>10.2f}"
            )

    print()
    print("=== Bootstrap 95% CI for (overlap - baseline) / baseline (mean ratio) ===\n")
    for metric in ("avg", "min", "max"):
        b = np.array(by_mode[("baseline", metric)])
        o = np.array(by_mode[("overlap", metric)])
        rng = np.random.default_rng(42)
        ratios = np.empty(5000)
        for i in range(5000):
            bs = rng.choice(b, size=len(b), replace=True).mean()
            os_ = rng.choice(o, size=len(o), replace=True).mean()
            ratios[i] = (os_ - bs) / bs
        lo = np.percentile(ratios, 2.5)
        med = np.percentile(ratios, 50)
        hi = np.percentile(ratios, 97.5)
        print(
            f"  {metric:<6}: median Δ = {med*100:+.2f}%  "
            f"95% CI = [{lo*100:+.2f}%, {hi*100:+.2f}%]  "
            f"crosses_zero={'YES' if lo < 0 < hi else 'NO'}"
        )


if __name__ == "__main__":
    main()
