#!/usr/bin/env python3
"""Drop the single per-group outlier (max/min) and recompute."""
import os, re, statistics as stat

RAW = "/home/ec2-user/workspace/efa-validation/results/stage5-p5en/PR-2-sandwich-2026-05-03/raw"
RE_DISP = re.compile(r"Dispatch bandwidth:\s*([0-9.]+)\s*GB/s,\s*avg_t=([0-9.]+)")
RE_COMB = re.compile(r"Combine bandwidth:\s*([0-9.]+)\s*GB/s,\s*avg_t=([0-9.]+)")

def run_med(run_id):
    disp, comb = [], []
    for rank in (0, 1):
        p = os.path.join(RAW, f"bench-{run_id}-rank{rank}.log")
        if not os.path.exists(p): continue
        with open(p) as f: text = f.read()
        for bw, us in RE_DISP.findall(text): disp.append(float(us))
        for bw, us in RE_COMB.findall(text): comb.append(float(us))
    return stat.median(disp) if disp else None, stat.median(comb) if comb else None

def group(tag, runs):
    vals = [run_med(r) for r in runs]
    disp_vals = sorted(v[0] for v in vals if v[0])
    comb_vals = sorted(v[1] for v in vals if v[1])
    print(f"\n## {tag}")
    print(f"  dispatch sorted: {' / '.join(f'{d:.2f}' for d in disp_vals)}")
    print(f"  combine  sorted: {' / '.join(f'{c:.2f}' for c in comb_vals)}")
    print(f"  dispatch min   : {disp_vals[0]:.2f}  mid: {disp_vals[1]:.2f}  max: {disp_vals[2]:.2f}")
    print(f"  combine  min   : {comb_vals[0]:.2f}  mid: {comb_vals[1]:.2f}  max: {comb_vals[2]:.2f}")
    return disp_vals, comb_vals

pre_d, pre_c = group("baseline-pre",  ["pre-run1", "pre-run2", "pre-run3"])
pt_d, pt_c   = group("patched",       ["pt-run1",  "pt-run2",  "pt-run3"])
po_d, po_c   = group("baseline-post", ["post-run1","post-run2","post-run3"])

print("\n## Min-of-3 (best-case) comparison — most stable signal")
print(f"  Dispatch: pre={pre_d[0]:.2f}  pt={pt_d[0]:.2f}  post={po_d[0]:.2f}")
print(f"    pt vs pre: {(pt_d[0]-pre_d[0])/pre_d[0]*100:+.2f}%")
print(f"    pt vs post: {(pt_d[0]-po_d[0])/po_d[0]*100:+.2f}%")
print(f"    pre vs post (env drift): {(po_d[0]-pre_d[0])/pre_d[0]*100:+.2f}%")
print(f"  Combine:  pre={pre_c[0]:.2f}  pt={pt_c[0]:.2f}  post={po_c[0]:.2f}")
print(f"    pt vs pre: {(pt_c[0]-pre_c[0])/pre_c[0]*100:+.2f}%")
print(f"    pt vs post: {(pt_c[0]-po_c[0])/po_c[0]*100:+.2f}%")
print(f"    pre vs post (env drift): {(po_c[0]-pre_c[0])/pre_c[0]*100:+.2f}%")

print("\n## All 9 runs combined — is patched within pre+post envelope?")
pre_all = pre_d + po_d  # treat pre and post as same distribution (they are!)
pre_min, pre_max = min(pre_all), max(pre_all)
print(f"  Baseline envelope (dispatch): [{pre_min:.2f}, {pre_max:.2f}] us")
print(f"  Patched runs (dispatch):  {' / '.join(f'{d:.2f}' for d in pt_d)}")
inside = all(pre_min <= d <= pre_max for d in pt_d)
print(f"  All patched runs within baseline envelope: {inside}")

pre_all_c = pre_c + po_c
pre_min_c, pre_max_c = min(pre_all_c), max(pre_all_c)
print(f"  Baseline envelope (combine): [{pre_min_c:.2f}, {pre_max_c:.2f}] us")
print(f"  Patched runs (combine):  {' / '.join(f'{c:.2f}' for c in pt_c)}")
inside_c = all(pre_min_c <= c <= pre_max_c for c in pt_c)
print(f"  All patched runs within baseline envelope: {inside_c}")
