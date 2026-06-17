#!/usr/bin/env python3
"""
plot_span.py — plot NVMeVirt random-read latency and cache hit rates vs LBA span.

Usage:
    python3 advanced_os/plot_span.py <result_dir> [<result_dir2> ...] [--out FILE]

Each result_dir must contain:
    00_state.txt                     (module parameters saved by run_span_bench.sh)
    bench_qd{N}_{SPAN}_run{N}.json  (fio JSON output)
    hmb_stats_{SPAN}.txt             (HMB cache stats line from dmesg)
"""

import argparse
import json
import re
import statistics
import sys
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# ── file name patterns ────────────────────────────────────────────────────────

_BENCH_RE = re.compile(
    r'^bench_qd(?P<qd>\d+)_(?P<val>\d+)(?P<unit>[MmGg])_run(?P<run>\d+)\.json$'
)
_STATS_RE = re.compile(
    r'^hmb_stats_(?P<val>\d+)(?P<unit>[MmGg])\.txt$'
)


def span_to_gb(val: float, unit: str) -> float:
    return val / 1024 if unit.upper() == 'M' else float(val)


# ── state file parsing ────────────────────────────────────────────────────────

def load_state(directory: Path) -> dict:
    """Parse 00_state.txt key-value pairs written by run_span_bench.sh."""
    state = {}
    f = directory / '00_state.txt'
    if not f.exists():
        return state
    lines = f.read_text(errors='ignore').splitlines()
    i = 0
    while i < len(lines):
        if lines[i].startswith('## '):
            key = lines[i][3:].strip()
            if i + 1 < len(lines):
                state[key] = lines[i + 1].strip()
            i += 2
        else:
            i += 1
    return state


def coverage_boundaries(state: dict):
    """Return (sram_boundary_gb, hmb_boundary_gb) from state, or (None, None)."""
    try:
        sram_kb = int(state.get('sram_size_kb', 0))
        # hmb_size_kb overrides hmb_size_mb when present
        if state.get('hmb_size_kb'):
            hmb_kb = int(state['hmb_size_kb'])
        else:
            hmb_kb = int(state.get('hmb_size_mb', 0)) * 1024
        # each entry = 4 bytes, covers 4KB → coverage = size_bytes * 1024
        sram_gb = sram_kb / 1024        # sram_size_kb KB → sram_size_kb MB = /1024 GB
        hmb_gb  = hmb_kb  / 1024        # hmb_size_kb  KB → hmb_size_kb  MB = /1024 GB
        return sram_gb or None, hmb_gb or None
    except (ValueError, TypeError):
        return None, None


# ── data loading ──────────────────────────────────────────────────────────────

def load_fio(path: Path) -> dict | None:
    """Extract latency and IOPS from a fio JSON output file."""
    try:
        j = json.loads(path.read_text())
        r = j['jobs'][0]['read']
        pct = r['clat_ns'].get('percentile', {})
        return {
            'iops':     r['iops'],
            'mean_us':  r['clat_ns']['mean'] / 1000,
            'p50_us':   pct.get('50.000000', 0) / 1000,
            'p95_us':   pct.get('95.000000', 0) / 1000,
            'p99_us':   pct.get('99.000000', 0) / 1000,
            'p999_us':  pct.get('99.900000', 0) / 1000,
        }
    except (json.JSONDecodeError, KeyError, IndexError, TypeError) as e:
        print(f'WARN: {path.name}: {e}')
        return None


def parse_hmb_stats(path: Path) -> dict | None:
    """Parse HMB cache stats line saved from dmesg."""
    if not path.exists():
        return None
    text = path.read_text(errors='ignore')
    if not text.strip():
        return None

    def ex(pat):
        m = re.search(pat, text)
        return int(m.group(1)) if m else 0

    sram = ex(r'SRAM hits=(\d+)')
    hmb  = ex(r'HMB hits=(\d+)')
    nand = ex(r'NAND fetches=(\d+)')
    avg  = ex(r'avg_l2p_lat_ns=(\d+)')
    total = sram + hmb + nand
    if total == 0:
        return None
    return {
        'sram_pct': sram * 100.0 / total,
        'hmb_pct':  hmb  * 100.0 / total,
        'nand_pct': nand * 100.0 / total,
        'avg_l2p_ns': avg,
    }


def load_dir(directory: Path):
    """
    Returns:
        spans_gb   : sorted list of span values in GB
        bench_data : {span_gb: [fio_dict, ...]}
        stats_data : {span_gb: hmb_stats_dict}
        state      : dict from 00_state.txt
        qd         : int
    """
    state = load_state(directory)
    bench_data: dict[float, list] = {}
    stats_data: dict[float, dict] = {}
    qd_set: set[int] = set()

    for f in sorted(directory.glob('*.json')):
        m = _BENCH_RE.match(f.name)
        if not m:
            continue
        qd = int(m.group('qd'))
        span_gb = span_to_gb(float(m.group('val')), m.group('unit'))
        qd_set.add(qd)
        rec = load_fio(f)
        if rec is not None:
            bench_data.setdefault(span_gb, []).append(rec)

    for f in sorted(directory.glob('hmb_stats_*.txt')):
        m = _STATS_RE.match(f.name)
        if not m:
            continue
        span_gb = span_to_gb(float(m.group('val')), m.group('unit'))
        s = parse_hmb_stats(f)
        if s is not None:
            stats_data[span_gb] = s

    qd = min(qd_set) if qd_set else int(state.get('qd', 1))
    spans_gb = sorted(bench_data)
    return spans_gb, bench_data, stats_data, state, qd


def agg(runs: list, key: str):
    vals = [r[key] for r in runs if key in r]
    if not vals:
        return float('nan'), 0.0
    if len(vals) == 1:
        return vals[0], 0.0
    return statistics.mean(vals), statistics.stdev(vals)


# ── plotting ──────────────────────────────────────────────────────────────────

COLORS = ['tab:blue', 'tab:orange', 'tab:green', 'tab:red',
          'tab:purple', 'tab:brown', 'tab:pink', 'tab:gray']


def make_label(state: dict, dirname: str) -> str:
    label = state.get('label', dirname)
    hmb = state.get('hmb_size_kb') or (str(int(state.get('hmb_size_mb', 0)) * 1024) if state.get('hmb_size_mb') else '')
    sram = state.get('sram_size_kb', '')
    if hmb and sram:
        return f'{label}  (HMB={hmb}KB SRAM={sram}KB)'
    return label


def plot(dirs: list[Path], out_file: str):
    datasets = []
    for d in dirs:
        spans, bench, stats, state, qd = load_dir(d)
        if not spans:
            print(f'WARN: no benchmark data in {d}')
            continue
        datasets.append((d.name, spans, bench, stats, state, qd))
        print(f'  {d} → {len(spans)} spans, QD={qd}, '
              f'HMB={state.get("hmb_size_mb","?")}MB SRAM={state.get("sram_size_kb","?")}KB')

    if not datasets:
        print('ERROR: no valid datasets loaded.')
        sys.exit(1)

    fig, (ax_lat, ax_hr) = plt.subplots(2, 1, figsize=(10, 9), sharex=False)

    for idx, (dirname, spans, bench, stats, state, qd) in enumerate(datasets):
        color = COLORS[idx % len(COLORS)]
        label = make_label(state, dirname)

        # fio mean and p99 latency
        if bench:
            mean_vals = [agg(bench[s], 'mean_us')[0] for s in spans]
            p99_vals  = [agg(bench[s], 'p99_us')[0]  for s in spans]
            ax_lat.plot(spans, mean_vals, 'o-', color=color, lw=2, ms=7,
                        label=f'{label} mean')
            ax_lat.plot(spans, p99_vals, 's--', color=color, lw=1.5, ms=5,
                        alpha=0.75, label=f'{label} p99')

        # hit rates (only if stats available)
        if stats:
            stat_spans = sorted(stats)
            ax_hr.plot(stat_spans, [stats[s]['sram_pct'] for s in stat_spans],
                       'o-', color=color, lw=2, ms=6, label=f'{label} SRAM%')
            ax_hr.plot(stat_spans, [stats[s]['hmb_pct']  for s in stat_spans],
                       's--', color=color, lw=1.5, ms=5, alpha=0.8, label=f'{label} HMB%')
            ax_hr.plot(stat_spans, [stats[s]['nand_pct'] for s in stat_spans],
                       '^:', color=color, lw=1, ms=4, alpha=0.6, label=f'{label} NAND%')

        # draw cache boundaries once (from first dataset with valid state)
        if idx == 0:
            sram_gb, hmb_gb = coverage_boundaries(state)
            if sram_gb:
                for ax in (ax_lat, ax_hr):
                    ax.axvline(sram_gb, color='gray', linestyle=':', lw=1.2,
                               label=f'SRAM full ({sram_gb*1024:.0f}MB)')
            if hmb_gb:
                for ax in (ax_lat, ax_hr):
                    ax.axvline(hmb_gb, color='dimgray', linestyle='--', lw=1.2,
                               label=f'HMB full ({hmb_gb:.0f}GB)')

    # latency panel
    ax_lat.set_xscale('log')
    ax_lat.set_xlabel('LBA span (GB)')
    ax_lat.set_ylabel('fio read latency (µs)')
    ax_lat.set_title('NVMeVirt — fio read latency vs span  (mean & p99)')
    ax_lat.grid(alpha=0.3)
    ax_lat.legend(fontsize=8)

    # hit-rate panel
    ax_hr.set_xscale('log')
    ax_hr.set_xlabel('LBA span (GB)')
    ax_hr.set_ylabel('L2P cache hit rate (%)')
    ax_hr.set_title('Cache tier hit rates vs span')
    ax_hr.set_ylim(-5, 105)
    ax_hr.grid(alpha=0.3)
    ax_hr.legend(fontsize=8)

    fig.tight_layout()
    fig.savefig(out_file, dpi=150, bbox_inches='tight')
    print(f'\nSaved: {out_file}')


def print_summary(dirs: list[Path]):
    for d in dirs:
        spans, bench, stats, state, qd = load_dir(d)
        if not spans:
            continue
        print(f'\n=== {d.name}  (QD={qd}) ===')
        header = f'{"span(GB)":>10}  {"mean(µs)":>10}  {"p99(µs)":>10}  {"SRAM%":>7}  {"HMB%":>7}  {"NAND%":>7}  {"avg_l2p(ns)":>12}'
        print(header)
        print('-' * len(header))
        for s in spans:
            mean, _ = agg(bench[s], 'mean_us')
            p99,  _ = agg(bench[s], 'p99_us')
            st = stats.get(s)
            row = f'{s:>10.3f}  {mean:>10.1f}  {p99:>10.1f}'
            if st:
                row += f'  {st["sram_pct"]:>7.1f}  {st["hmb_pct"]:>7.1f}  {st["nand_pct"]:>7.1f}  {st["avg_l2p_ns"]:>12}'
            else:
                row += f'  {"—":>7}  {"—":>7}  {"—":>7}  {"—":>12}'
            print(row)


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dirs', nargs='+', metavar='result_dir')
    ap.add_argument('--out', default='span_latency.png', metavar='FILE',
                    help='Output PNG file (default: span_latency.png)')
    args = ap.parse_args()

    dirs = [Path(d) for d in args.dirs]
    for d in dirs:
        if not d.is_dir():
            print(f'ERROR: {d} is not a directory')
            sys.exit(1)

    print_summary(dirs)
    plot(dirs, args.out)


if __name__ == '__main__':
    main()
