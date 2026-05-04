#!/usr/bin/env python3
"""Bootstrap analysis of PR-2 stub: 10 baseline + 10 patched runs."""
import os, re, statistics as stat, random

RAW = "/home/ec2-user/workspace/efa-validation/results/stage5-p5en/PR-2-sandwich-2026-05-03/big-raw"
RE_DISP = re.compile(r"Dispatch bandwidth:\s*([0-9.]+)\s*GB/s,\s*avg_t=([0-9.]+)")
RE_COMB = re.compile(r"Combine bandwidth:\s*([0-9.]+)\s*GB/s,\s*avg_t=([0-9.]+)")

def run_med(prefix, n):
    run_id = f"{prefix}-n{n}"
    disp, comb = [], []
    for rank in (0, 1):
        p = os.path.join(RAW, f"bench-{run_id}-rank{rank}.log")
        if not os.path.exists(p): continue
        with open(p) as f: text = f.read()
        for bw, us in RE_DISP.findall(text): disp.append(float(us))
        for bw, us in RE_COMB.findall(text): comb.append(float(us))
    return (stat.median(disp) if disp else None, stat.median(comb) if comb else None)

pre_disp, pre_comb = [], []
pt_disp, pt_comb = [], []
for n in range(1, 11):
    d, c = run_med("pre", n)
    if d: pre_disp.append(d); pre_comb.append(c)
    d, c = run_med("pt", n)
    if d: pt_disp.append(d); pt_comb.append(c)

print(f"# 20-run PR-2 stub analysis (Tokyo 2026-05-03 12:30-12:43 UTC)")
print(f"\n## baseline-pre (upstream fb4147a2 + PEB=0), n={len(pre_disp)}")
print(f"  dispatch avg_t: {sorted(pre_disp)}")
print(f"  combine  avg_t: {sorted(pre_comb)}")
print(f"  dispatch: median={stat.median(pre_disp):.2f} min={min(pre_disp):.2f} max={max(pre_disp):.2f} stdev={stat.stdev(pre_disp):.2f}")
print(f"  combine : median={stat.median(pre_comb):.2f} min={min(pre_comb):.2f} max={max(pre_comb):.2f} stdev={stat.stdev(pre_comb):.2f}")

print(f"\n## patched (fb4147a2 + stub + PEB=0), n={len(pt_disp)}")
print(f"  dispatch avg_t: {sorted(pt_disp)}")
print(f"  combine  avg_t: {sorted(pt_comb)}")
print(f"  dispatch: median={stat.median(pt_disp):.2f} min={min(pt_disp):.2f} max={max(pt_disp):.2f} stdev={stat.stdev(pt_disp):.2f}")
print(f"  combine : median={stat.median(pt_comb):.2f} min={min(pt_comb):.2f} max={max(pt_comb):.2f} stdev={stat.stdev(pt_comb):.2f}")

# Bootstrap CI for delta (patched - pre) / pre %
def bootstrap_delta(a, b, N=5000):
    deltas = []
    for _ in range(N):
        a_boot = [random.choice(a) for _ in a]
        b_boot = [random.choice(b) for _ in b]
        deltas.append((stat.mean(b_boot) - stat.mean(a_boot)) / stat.mean(a_boot) * 100)
    deltas.sort()
    return deltas[int(N*0.025)], stat.median(deltas), deltas[int(N*0.975)]

random.seed(42)
print(f"\n## Bootstrap 95% CI for (patched - baseline) / baseline mean")
lo, med, hi = bootstrap_delta(pre_disp, pt_disp)
print(f"  Dispatch: {lo:+.2f}% .. median={med:+.2f}% .. {hi:+.2f}%")
print(f"    Crosses zero? {'YES (no significant regression)' if lo < 0 < hi else 'NO'}")

lo, med, hi = bootstrap_delta(pre_comb, pt_comb)
print(f"  Combine:  {lo:+.2f}% .. median={med:+.2f}% .. {hi:+.2f}%")
print(f"    Crosses zero? {'YES (no significant regression)' if lo < 0 < hi else 'NO'}")

# Also compute simple delta on min-of-10 and median-of-10
print(f"\n## Simple deltas")
print(f"  Dispatch median: pre={stat.median(pre_disp):.2f} pt={stat.median(pt_disp):.2f}  Δ={(stat.median(pt_disp)-stat.median(pre_disp))/stat.median(pre_disp)*100:+.2f}%")
print(f"  Dispatch min:    pre={min(pre_disp):.2f} pt={min(pt_disp):.2f}  Δ={(min(pt_disp)-min(pre_disp))/min(pre_disp)*100:+.2f}%")
print(f"  Combine  median: pre={stat.median(pre_comb):.2f} pt={stat.median(pt_comb):.2f}  Δ={(stat.median(pt_comb)-stat.median(pre_comb))/stat.median(pre_comb)*100:+.2f}%")
print(f"  Combine  min:    pre={min(pre_comb):.2f} pt={min(pt_comb):.2f}  Δ={(min(pt_comb)-min(pre_comb))/min(pre_comb)*100:+.2f}%")
