#!/usr/bin/env python3
"""Analyze PR-2 stub sandwich: baseline-pre × 3 / patched × 3 / baseline-post × 3."""
import os, re, statistics as stat

RAW = "/home/ec2-user/workspace/efa-validation/results/stage5-p5en/PR-2-sandwich-2026-05-03/raw"
RE_DISP = re.compile(r"Dispatch bandwidth:\s*([0-9.]+)\s*GB/s,\s*avg_t=([0-9.]+)")
RE_COMB = re.compile(r"Combine bandwidth:\s*([0-9.]+)\s*GB/s,\s*avg_t=([0-9.]+)")

def collect_run(run_id):
    disp_us, comb_us, disp_bw, comb_bw = [], [], [], []
    for rank in (0, 1):
        p = os.path.join(RAW, f"bench-{run_id}-rank{rank}.log")
        if not os.path.exists(p):
            continue
        with open(p) as f:
            text = f.read()
        for bw, us in RE_DISP.findall(text):
            disp_bw.append(float(bw)); disp_us.append(float(us))
        for bw, us in RE_COMB.findall(text):
            comb_bw.append(float(bw)); comb_us.append(float(us))
    return {
        "disp_us_med": stat.median(disp_us) if disp_us else None,
        "comb_us_med": stat.median(comb_us) if comb_us else None,
        "disp_bw_med": stat.median(disp_bw) if disp_bw else None,
        "comb_bw_med": stat.median(comb_bw) if comb_bw else None,
        "samples": len(disp_us),
    }

def group(tag, run_ids):
    vals = [collect_run(r) for r in run_ids]
    print(f"\n## {tag}")
    print(f"  Per-run dispatch avg_t medians: " + " | ".join(f"{v['disp_us_med']:.2f}" if v['disp_us_med'] else "?" for v in vals))
    print(f"  Per-run combine  avg_t medians: " + " | ".join(f"{v['comb_us_med']:.2f}" if v['comb_us_med'] else "?" for v in vals))
    all_disp = [v['disp_us_med'] for v in vals if v['disp_us_med']]
    all_comb = [v['comb_us_med'] for v in vals if v['comb_us_med']]
    group_disp = stat.median(all_disp) if all_disp else None
    group_comb = stat.median(all_comb) if all_comb else None
    print(f"  Group median dispatch avg_t: {group_disp:.2f} us")
    print(f"  Group median combine  avg_t: {group_comb:.2f} us")
    return group_disp, group_comb

print("# PR-2 stub non-regression sandwich (Tokyo, 2026-05-03 12:08-12:16 UTC)")
print("Baseline SHA: fb4147a2 (upstream main)  Patched: fb4147a2 + stub patch  PEB=0")

pre_d, pre_c = group("baseline-pre (main, PEB=0)",  ["pre-run1",  "pre-run2",  "pre-run3"])
pt_d,  pt_c  = group("patched  (main+stub, PEB=0)", ["pt-run1",   "pt-run2",   "pt-run3"])
po_d,  po_c  = group("baseline-post (main, PEB=0)", ["post-run1", "post-run2", "post-run3"])

print("\n## Environment stability (pre vs post, must be < 1% for clean sandwich)")
print(f"  Dispatch: pre={pre_d:.2f} post={po_d:.2f}  Δ = {(po_d-pre_d)/pre_d*100:+.2f}%")
print(f"  Combine:  pre={pre_c:.2f} post={po_c:.2f}  Δ = {(po_c-pre_c)/pre_c*100:+.2f}%")

print("\n## Non-regression check (patched vs baseline-pre)")
print(f"  Dispatch: patched={pt_d:.2f} vs pre={pre_d:.2f}  Δ = {(pt_d-pre_d)/pre_d*100:+.2f}%")
print(f"  Combine:  patched={pt_c:.2f} vs pre={pre_c:.2f}  Δ = {(pt_c-pre_c)/pre_c*100:+.2f}%")

print("\n## Non-regression check (patched vs baseline-post)")
print(f"  Dispatch: patched={pt_d:.2f} vs post={po_d:.2f}  Δ = {(pt_d-po_d)/po_d*100:+.2f}%")
print(f"  Combine:  patched={pt_c:.2f} vs post={po_c:.2f}  Δ = {(pt_c-po_c)/po_c*100:+.2f}%")
