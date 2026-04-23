#!/usr/bin/env python3
"""
Parse nvidia-smi CSVs from the 3 p5en nodes during the Kimi K2 stress bench
and summarise GPU utilization, VRAM, power, and clock behaviour per role.

Role mapping (from pod listing at bench time):
  node1 = ip-10-1-11-93  → sglang-prefill
  node2 = ip-10-1-11-108 → sglang-decode-0
  node3 = ip-10-1-11-197 → sglang-decode-1
"""
from __future__ import annotations
import csv
from datetime import datetime
from pathlib import Path
from statistics import mean, median, stdev

HERE = Path(__file__).parent
CSV_DIR = HERE.parent / "results" / "stage4-p5en" / "gpu-stats"

ROLES = [
    ("prefill", "node1-prefill.csv"),
    ("decode-0", "node2-decode0.csv"),
    ("decode-1", "node3-decode1.csv"),
]

# Bench phases (from bench log; all 4 phases + 15s gap between).
# rate=2 started ~t0, rate=4 ~t0+71s+15s, rate=8 ~+55s+15s, rate=16 ~+44s+15s.
# We don't have a perfect timestamp mapping to nvidia-smi, so we report
# overall stats + 10-second rolling windows. A separate pass slices by
# approximate windows.

def parse_csv(path: Path):
    rows = []
    with open(path) as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            if len(row) != 11:
                continue
            ts_str = row[0].strip()
            try:
                ts = datetime.strptime(ts_str, "%Y/%m/%d %H:%M:%S.%f")
            except ValueError:
                continue
            try:
                rows.append(dict(
                    ts=ts,
                    gpu=int(row[1]),
                    util=float(row[2]),
                    util_mem=float(row[3]),
                    mem_used=float(row[4]),
                    mem_total=float(row[5]),
                    power=float(row[6]),
                    sm_clk=float(row[7]),
                    mem_clk=float(row[8]),
                    temp=float(row[9]),
                    pstate=row[10].strip(),
                ))
            except (ValueError, IndexError):
                continue
    return rows


def summarise(rows, label: str):
    print(f"\n===== {label} (n={len(rows)} sample-rows over 8 GPUs) =====")
    # Aggregate per-timestamp across 8 GPUs.
    by_ts = {}
    for r in rows:
        by_ts.setdefault(r["ts"], []).append(r)
    samples = sorted(by_ts.values(), key=lambda lst: lst[0]["ts"])
    print(f"  window: {samples[0][0]['ts']}  →  {samples[-1][0]['ts']}  ({len(samples)} ticks, 8 GPUs each)")

    # Collect per-gpu stats
    per_gpu_util = {i: [] for i in range(8)}
    per_gpu_mem = {i: [] for i in range(8)}
    per_gpu_power = {i: [] for i in range(8)}
    per_gpu_sm_clk = {i: [] for i in range(8)}
    per_gpu_mem_clk = {i: [] for i in range(8)}
    for r in rows:
        g = r["gpu"]
        per_gpu_util[g].append(r["util"])
        per_gpu_mem[g].append(r["mem_used"])
        per_gpu_power[g].append(r["power"])
        per_gpu_sm_clk[g].append(r["sm_clk"])
        per_gpu_mem_clk[g].append(r["mem_clk"])

    # Active-phase filter: util>5% (skip idle between rates)
    active = [r for r in rows if r["util"] > 5]
    idle = [r for r in rows if r["util"] <= 5]
    act_ratio = len(active) / len(rows) * 100

    print(f"  overall active ratio (util>5%): {act_ratio:.1f}%   "
          f"(active={len(active)}, idle={len(idle)})")

    # Overall (all GPUs, all ticks)
    total_mem = rows[0]["mem_total"]
    print(f"  VRAM per GPU total: {total_mem/1024:.1f} GB")

    for g in range(8):
        u = per_gpu_util[g]
        m = per_gpu_mem[g]
        p = per_gpu_power[g]
        smclk = per_gpu_sm_clk[g]
        memclk = per_gpu_mem_clk[g]
        u_active = [x for x in u if x > 5]
        print(f"  GPU{g}: "
              f"util mean={mean(u):5.1f}%  active_mean={mean(u_active) if u_active else 0:5.1f}%  p95={sorted(u)[int(len(u)*0.95)]:5.1f}%  |  "
              f"VRAM {mean(m)/1024:5.1f}GB (min={min(m)/1024:4.1f} max={max(m)/1024:4.1f}) |  "
              f"power {mean(p):5.1f}W (max={max(p):5.1f}) |  "
              f"SM_clk {mean(smclk):.0f} MHz  mem_clk {mean(memclk):.0f} MHz")

    # Cross-GPU aggregate during "busy" ticks (any GPU >5%).
    busy_ticks = [s for s in samples if any(r["util"] > 5 for r in s)]
    if busy_ticks:
        avg_node_util = mean([mean(r["util"] for r in s) for s in busy_ticks])
        p95_node_util = sorted([max(r["util"] for r in s) for s in busy_ticks])[int(len(busy_ticks)*0.95)]
        avg_node_power = mean([sum(r["power"] for r in s) for s in busy_ticks])
        max_node_power = max([sum(r["power"] for r in s) for s in busy_ticks])
        print(f"\n  ▶ When busy ({len(busy_ticks)} ticks): "
              f"avg-GPU-util={avg_node_util:.1f}%  max-GPU-p95={p95_node_util:.1f}%  "
              f"node-power avg={avg_node_power:.0f}W  peak={max_node_power:.0f}W (cap ~2800W × 8 = 22400W)")


def main():
    for label, fname in ROLES:
        p = CSV_DIR / fname
        if not p.exists():
            print(f"[!] missing {p}")
            continue
        rows = parse_csv(p)
        summarise(rows, label)


if __name__ == "__main__":
    main()
