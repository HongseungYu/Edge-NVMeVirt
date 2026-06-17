#!/usr/bin/env python3
"""
plot_policy.py — visualize run_policy_bench.sh results.

Reads summary.csv (or a result directory containing it) and draws grouped
bar charts: hit rate / mean latency / IOPS  ×  {cyclic, recency, uniform}.

Usage:
    python3 advanced_os/plot_policy.py <result_dir>  [--out FILE.png]
    python3 advanced_os/plot_policy.py summary.csv   [--out FILE.png]
"""
import sys
import csv
import re
import argparse
from pathlib import Path
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

POLICY_ORDER  = ["lru", "random", "mru", "fifo"]
POLICY_LABELS = {"lru": "LRU", "random": "RANDOM", "mru": "MRU", "fifo": "FIFO"}
PATTERN_ORDER = ["cyclic", "recency", "uniform"]
COLORS = {
    "lru":    "tab:blue",
    "random": "tab:orange",
    "mru":    "tab:green",
    "fifo":   "tab:red",
}


def load_csv(path):
    data = defaultdict(dict)  # data[pattern][policy] = {hit_rate, iops, lat}
    with open(path) as f:
        for row in csv.DictReader(f):
            pol = row["policy"]
            pat = row["pattern"]
            hr  = row["hit_rate"]
            data[pat][pol] = {
                "hit_rate": float(hr) if hr != "NA" else None,
                "iops":     float(row["read_iops"]),
                "lat":      float(row["clat_mean_us"]),
            }
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", help="result dir or summary.csv")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    p = Path(args.path)
    csv_path = (p / "summary.csv") if p.is_dir() else p
    if not csv_path.exists():
        sys.exit(f"ERROR: {csv_path} not found")

    data = load_csv(csv_path)

    patterns = [pt for pt in PATTERN_ORDER if pt in data]
    seen = {pol for pat in patterns for pol in data[pat]}
    policies = [pol for pol in POLICY_ORDER if pol in seen]

    n_pat = len(patterns)
    n_pol = len(policies)
    x = np.arange(n_pat)
    width = 0.75 / n_pol

    fig, axes = plt.subplots(1, 3, figsize=(14, 5))

    metrics = [
        ("hit_rate", "Cache hit rate (%)",  lambda v: (v * 100) if v is not None else 0),
        ("lat",      "Mean latency (µs)",   lambda v: v),
        ("iops",     "IOPS (4K read)",       lambda v: v),
    ]

    for ax, (key, ylabel, xfm) in zip(axes, metrics):
        for i, pol in enumerate(policies):
            vals = [xfm(data[pat].get(pol, {}).get(key)) for pat in patterns]
            offset = (i - n_pol / 2 + 0.5) * width
            ax.bar(x + offset, vals, width=width * 0.9,
                   label=POLICY_LABELS.get(pol, pol.upper()),
                   color=COLORS.get(pol, "tab:gray"))
        ax.set_xticks(x)
        ax.set_xticklabels([pt.capitalize() for pt in patterns])
        ax.set_ylabel(ylabel)
        ax.legend(fontsize=8)
        ax.grid(axis="y", alpha=0.3)
        if key == "hit_rate":
            ax.set_ylim(0, 110)

    # Read state for title
    state_f = (p / "00_state.txt") if p.is_dir() else (p.parent / "00_state.txt")
    title = p.name
    if state_f.exists():
        txt = state_f.read_text(errors="ignore")
        span = re.search(r"## span_mb\n(\S+)", txt)
        hmb  = re.search(r"## hmb_size_kb\n(\S+)", txt)
        if span and hmb:
            title = f"Policy comparison  span={span.group(1)}MB  HMB={hmb.group(1)}KB"

    fig.suptitle(title, fontsize=12)
    plt.tight_layout()

    out = args.out or f"{p.name}_policy.png"
    plt.savefig(out, dpi=150)
    print(f"Saved: {out}")

    # Print summary table
    print(f"\n{'policy':>8} | {'pattern':>8} | {'hit%':>6} | {'IOPS':>7} | {'lat_us':>8}")
    print("-" * 50)
    for pat in patterns:
        for pol in policies:
            d = data[pat].get(pol, {})
            hr = d.get("hit_rate")
            hr_str = f"{hr*100:5.1f}%" if hr is not None else "   NA "
            print(f"{POLICY_LABELS.get(pol,pol):>8} | {pat:>8} | "
                  f"{hr_str} | {d.get('iops',0):>7.0f} | {d.get('lat',0):>8.1f}")


if __name__ == "__main__":
    main()
