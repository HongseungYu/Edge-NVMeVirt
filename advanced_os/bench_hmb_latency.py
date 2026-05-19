#!/usr/bin/env python3
"""
bench_hmb_latency.py  –  Sweep HMB cache parameters and plot throughput + hit rates.

Usage (must be root):
  sudo python3 advanced_os/bench_hmb_latency.py
  sudo python3 advanced_os/bench_hmb_latency.py --params sram_size_kb hmb_size_mb
  sudo python3 advanced_os/bench_hmb_latency.py --workload fio --fio-rw randread
  sudo python3 advanced_os/bench_hmb_latency.py --workload both --dd-size 256

Reads /boot/nvmev-arm64.env for memmap/cpu settings (written by verify_nvmev_arm64.sh
--phase=1).  Loads nvmev.ko with each parameter value, measures throughput via dd and/or
fio, captures SRAM/HMB/NAND hit rates from dmesg, then plots the results.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    HAS_PLOT = True
except ImportError:
    HAS_PLOT = False

# ── configuration ─────────────────────────────────────────────────────────────

STATE_FILE  = '/boot/nvmev-arm64.env'
MODULE_PATH = str(Path(__file__).resolve().parent.parent / 'nvmev.ko')
NVMEV_VENDOR_ID = 0x0c51
DD_SIZE_MB  = 512

# fio defaults
FIO_RW      = 'randread'
FIO_BS      = '4k'
FIO_IODEPTH = 32
FIO_RUNTIME = 30   # seconds

# Baseline values (match main.c defaults)
DEFAULTS = dict(
    hmb_size_mb  = 4,
    sram_size_kb = 512,
    lat_sram_ns  = 100,
    lat_hmb_ns   = 3000,
    lat_nand_ns  = 40000,
    repl_policy  = 0,
)

SWEEPS = {
    'lat_sram_ns':  [50, 100, 200, 500, 1000, 2000, 5000],
    'lat_hmb_ns':   [500, 1000, 2000, 5000, 10000, 20000, 50000],
    'lat_nand_ns':  [10000, 20000, 30000, 50000, 100000, 200000],
    'sram_size_kb': [0, 64, 128, 256, 512, 1024],
    'hmb_size_mb':  [0, 1, 2, 3, 4],
}

LABELS = {
    'lat_sram_ns':  'SRAM hit latency (ns)',
    'lat_hmb_ns':   'HMB hit latency (ns)',
    'lat_nand_ns':  'NAND miss latency (ns)',
    'sram_size_kb': 'SRAM cache size (KiB)',
    'hmb_size_mb':  'HMB cache size (MiB)',
}

# ── helpers ───────────────────────────────────────────────────────────────────

def die(msg):
    print(f'[ERROR] {msg}', file=sys.stderr)
    sys.exit(1)


def run(cmd, *, check=True, capture=True):
    return subprocess.run(
        cmd, shell=True, check=check,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


def load_state():
    state = {}
    try:
        for line in Path(STATE_FILE).read_text().splitlines():
            if '=' in line and not line.startswith('#'):
                k, _, v = line.partition('=')
                state[k.strip()] = v.strip()
    except FileNotFoundError:
        die(f'{STATE_FILE} not found – run verify_nvmev_arm64.sh first')
    for key in ('MEMMAP_START_BYTES', 'MEMMAP_SIZE_BYTES', 'CPUS_MODULE'):
        if key not in state:
            die(f'{key} missing from {STATE_FILE}')
    return state


def find_nvme_dev():
    nvme_cls = Path('/sys/class/nvme')
    if not nvme_cls.exists():
        return None
    for ctrl in sorted(nvme_cls.iterdir()):
        vendor_file = ctrl / 'device' / 'vendor'
        try:
            if int(vendor_file.read_text().strip(), 16) == NVMEV_VENDOR_ID:
                return f'/dev/{ctrl.name}'
        except (FileNotFoundError, ValueError):
            pass
    return None


def find_namespace(dev):
    base = Path(dev).name
    for ns in sorted(Path('/dev').glob(f'{base}n[0-9]*')):
        if ns.is_block_device():
            return str(ns)
    return None


def wait_for_dev(timeout=15):
    for _ in range(timeout):
        dev = find_nvme_dev()
        if dev:
            return dev
        time.sleep(1)
    return None


def module_loaded():
    r = run('lsmod', check=False)
    return bool(re.search(r'^nvmev\s', r.stdout, re.MULTILINE))


def unload():
    if module_loaded():
        run('rmmod nvmev', check=False)
        time.sleep(1)


def load(state, overrides):
    params = {**DEFAULTS, **overrides}
    param_str = ' '.join(f'{k}={v}' for k, v in params.items())
    cmd = (
        f'insmod {MODULE_PATH}'
        f' memmap_start={state["MEMMAP_START_BYTES"]}'
        f' memmap_size={state["MEMMAP_SIZE_BYTES"]}'
        f' cpus={state["CPUS_MODULE"]}'
        f' {param_str}'
    )
    r = run(cmd, check=False)
    return r.returncode == 0


def clear_dmesg():
    run('dmesg -C', check=False)


def parse_hmb_stats():
    """Parse HMB cache hit/miss counts from dmesg after rmmod. Returns dict or None."""
    r = run('dmesg 2>/dev/null | grep "HMB cache stats:" | tail -1', check=False)
    line = r.stdout.strip()
    if not line:
        return None

    def extract(pattern):
        m = re.search(pattern, line)
        return int(m.group(1)) if m else 0

    sram        = extract(r'SRAM hits=(\d+)')
    hmb         = extract(r'HMB hits=(\d+)')
    nand        = extract(r'NAND fetches=(\d+)')
    avg_l2p_ns  = extract(r'avg_l2p_lat_ns=(\d+)')
    total = sram + hmb + nand
    if total == 0:
        return {'sram_pct': 0.0, 'hmb_pct': 0.0, 'nand_pct': 0.0,
                'total': 0, 'avg_l2p_ns': 0}
    return {
        'sram_pct':   sram * 100.0 / total,
        'hmb_pct':    hmb  * 100.0 / total,
        'nand_pct':   nand * 100.0 / total,
        'total':      total,
        'avg_l2p_ns': avg_l2p_ns,
    }


def parse_speed_gbps(dd_output):
    m = re.search(r'([\d.]+)\s*([KMGT]?B/s)', dd_output)
    if not m:
        return None
    num  = float(m.group(1))
    unit = m.group(2)
    to_gb = {'B/s': 1e-9, 'KB/s': 1e-6, 'MB/s': 1e-3, 'GB/s': 1.0, 'TB/s': 1e3}
    return num * to_gb.get(unit, 1.0)


def measure_dd(ns_path, size_mb):
    """Return (write_gbps, read_gbps) or (None, None) on failure."""
    wr = run(
        f'dd if=/dev/zero of={ns_path} bs=1M count={size_mb} oflag=direct 2>&1',
        check=False,
    )
    wr_gbps = parse_speed_gbps(wr.stdout + wr.stderr) if wr.returncode == 0 else None

    rd = run(
        f'dd if={ns_path} of=/dev/null bs=1M count={size_mb} iflag=direct 2>&1',
        check=False,
    )
    rd_gbps = parse_speed_gbps(rd.stdout + rd.stderr) if rd.returncode == 0 else None

    return wr_gbps, rd_gbps


def measure_fio(ns_path, rw, bs, iodepth, runtime):
    """
    Run fio on *ns_path* (raw block device) and return a dict:
      read_gbps, write_gbps, read_iops, write_iops, read_lat_us, write_lat_us
    Returns None on failure.
    """
    size_flag = f'--size={DD_SIZE_MB}M' if 'rand' in rw else ''
    cmd = (
        f'fio --filename={ns_path} --direct=1 --rw={rw} --bs={bs}'
        f' --ioengine=libaio --iodepth={iodepth}'
        f' --runtime={runtime} --time_based'
        f' {size_flag}'
        f' --name=bench --output-format=json'
    )
    r = run(cmd, check=False)
    if r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None

    def bw_to_gbps(job, direction):
        # fio reports bw in KiB/s
        return job[direction]['bw'] / (1024 * 1024)  # → GB/s

    def lat_us(job, direction):
        # clat_ns.mean in ns → µs
        try:
            return job[direction]['clat_ns']['mean'] / 1000.0
        except (KeyError, TypeError):
            return None

    jobs = data.get('jobs', [])
    if not jobs:
        return None
    job = jobs[0]

    return {
        'read_gbps':    bw_to_gbps(job, 'read'),
        'write_gbps':   bw_to_gbps(job, 'write'),
        'read_iops':    job['read']['iops'],
        'write_iops':   job['write']['iops'],
        'read_lat_us':  lat_us(job, 'read'),
        'write_lat_us': lat_us(job, 'write'),
    }


# ── sweep ─────────────────────────────────────────────────────────────────────

def sweep_param(param, values, state, args):
    """
    Returns a list of result dicts, one per value:
      val, dd_wr_gbps, dd_rd_gbps,
      fio_read_gbps, fio_write_gbps, fio_read_iops, fio_read_lat_us,
      sram_pct, hmb_pct, nand_pct, total_lookups
    """
    results = []
    use_dd  = args.workload in ('dd', 'both')
    use_fio = args.workload in ('fio', 'both')

    for val in values:
        tag = f'{param}={val}'
        print(f'  {tag}', flush=True)

        clear_dmesg()
        unload()
        if not load(state, {param: val}):
            print(f'    insmod failed – skipping', flush=True)
            results.append({'val': val})
            continue

        time.sleep(2)
        dev = wait_for_dev()
        if not dev:
            print('    device not found – skipping', flush=True)
            unload()
            results.append({'val': val})
            continue

        ns = find_namespace(dev)
        if not ns:
            print(f'    no namespace under {dev} – skipping', flush=True)
            unload()
            results.append({'val': val})
            continue

        rec = {'val': val}

        # ── dd ────────────────────────────────────────────────────────────────
        if use_dd:
            wr, rd = measure_dd(ns, args.dd_size)
            rec['dd_wr_gbps'] = wr
            rec['dd_rd_gbps'] = rd
            wr_s = f'{wr:.2f}' if wr is not None else 'ERR'
            rd_s = f'{rd:.2f}' if rd is not None else 'ERR'
            print(f'    dd  write={wr_s} GB/s  read={rd_s} GB/s', flush=True)

        # ── fio ───────────────────────────────────────────────────────────────
        if use_fio:
            fio = measure_fio(ns, args.fio_rw, args.fio_bs,
                              args.fio_iodepth, args.fio_runtime)
            if fio:
                rec.update({
                    'fio_read_gbps':   fio['read_gbps'],
                    'fio_write_gbps':  fio['write_gbps'],
                    'fio_read_iops':   fio['read_iops'],
                    'fio_write_iops':  fio['write_iops'],
                    'fio_read_lat_us': fio['read_lat_us'],
                })
                rd_s  = f'{fio["read_gbps"]:.2f}'
                wr_s  = f'{fio["write_gbps"]:.2f}'
                iops  = f'{fio["read_iops"]:.0f}'
                lat_s = f'{fio["read_lat_us"]:.0f}' if fio['read_lat_us'] else '?'
                print(f'    fio read={rd_s} GB/s  write={wr_s} GB/s'
                      f'  read_iops={iops}  lat={lat_s} µs', flush=True)
            else:
                print('    fio failed', flush=True)

        # ── unload and capture stats ───────────────────────────────────────────
        unload()
        stats = parse_hmb_stats()
        if stats:
            rec.update({
                'sram_pct':      stats['sram_pct'],
                'hmb_pct':       stats['hmb_pct'],
                'nand_pct':      stats['nand_pct'],
                'total_lookups': stats['total'],
                'avg_l2p_ns':    stats['avg_l2p_ns'],
            })
            print(f'    hit-rate  SRAM={stats["sram_pct"]:.1f}%'
                  f'  HMB={stats["hmb_pct"]:.1f}%'
                  f'  NAND={stats["nand_pct"]:.1f}%'
                  f'  avg_l2p={stats["avg_l2p_ns"]} ns'
                  f'  (total={stats["total"]})', flush=True)
        else:
            print('    hit-rate  (no stats in dmesg)', flush=True)

        results.append(rec)

    return results


# ── plot ──────────────────────────────────────────────────────────────────────

def plot(all_results, args):
    if not HAS_PLOT:
        print('[warn] matplotlib not available – skipping plot (pip install matplotlib)')
        return

    use_dd  = args.workload in ('dd', 'both')
    use_fio = args.workload in ('fio', 'both')

    params = list(all_results.keys())
    n = len(params)
    fig, axes = plt.subplots(2, n, figsize=(5 * n, 8), squeeze=False)

    for col, param in enumerate(params):
        data = all_results[param]
        xs   = [d['val'] for d in data]

        def clean(vals):
            return [v if v is not None else float('nan') for v in vals]

        # ── top subplot: throughput ────────────────────────────────────────────
        ax_tp = axes[0][col]
        plotted = False

        if use_dd:
            wr = clean([d.get('dd_wr_gbps') for d in data])
            rd = clean([d.get('dd_rd_gbps') for d in data])
            ax_tp.plot(xs, wr, 'o-', label='dd Write',  color='tab:blue')
            ax_tp.plot(xs, rd, 's-', label='dd Read',   color='tab:orange')
            plotted = True

        if use_fio:
            frd = clean([d.get('fio_read_gbps')  for d in data])
            fwr = clean([d.get('fio_write_gbps') for d in data])
            ax_tp.plot(xs, frd, '^--', label=f'fio {args.fio_rw} Read',  color='tab:green')
            ax_tp.plot(xs, fwr, 'v--', label=f'fio {args.fio_rw} Write', color='tab:red')
            plotted = True

        default_val = DEFAULTS.get(param)
        if default_val in xs:
            ax_tp.axvline(default_val, color='gray', linestyle=':', linewidth=0.8,
                          label=f'default ({default_val})')

        ax_tp.set_xlabel(LABELS.get(param, param))
        ax_tp.set_ylabel('Throughput (GB/s)')
        ax_tp.set_title(param)
        if plotted:
            ax_tp.legend(fontsize=7)
        ax_tp.grid(True, alpha=0.3)

        if len(xs) >= 2 and max(xs) > 0 and max(xs) / max(min(x for x in xs if x > 0), 1e-9) > 50:
            ax_tp.set_xscale('log')

        # ── bottom subplot: hit rates ──────────────────────────────────────────
        ax_hr = axes[1][col]

        sram_pcts = clean([d.get('sram_pct') for d in data])
        hmb_pcts  = clean([d.get('hmb_pct')  for d in data])
        nand_pcts = clean([d.get('nand_pct') for d in data])

        ax_hr.plot(xs, sram_pcts, 'o-', label='SRAM hit %',  color='tab:green')
        ax_hr.plot(xs, hmb_pcts,  's-', label='HMB hit %',   color='tab:purple')
        ax_hr.plot(xs, nand_pcts, '^-', label='NAND miss %', color='tab:red')
        ax_hr.set_ylim(0, 105)
        ax_hr.set_xlabel(LABELS.get(param, param))
        ax_hr.set_ylabel('L2P lookup %')
        ax_hr.set_title(f'{param} – cache hit rates')
        ax_hr.legend(fontsize=7)
        ax_hr.grid(True, alpha=0.3)

        if len(xs) >= 2 and max(xs) > 0 and max(xs) / max(min(x for x in xs if x > 0), 1e-9) > 50:
            ax_hr.set_xscale('log')

    workload_label = {
        'dd':   'dd sequential',
        'fio':  f'fio {args.fio_rw} bs={args.fio_bs} iodepth={args.fio_iodepth}',
        'both': f'dd + fio {args.fio_rw}',
    }[args.workload]

    fig.suptitle(f'NVMeVirt – HMB cache sweep  [{workload_label}]',
                 fontsize=13, fontweight='bold')
    fig.tight_layout()
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=150, bbox_inches='tight')
    print(f'[done] plot → {args.output}')


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--params', nargs='+', choices=list(SWEEPS),
                    default=list(SWEEPS), metavar='PARAM',
                    help='Parameters to sweep (default: all). Choices: ' + ', '.join(SWEEPS))
    ap.add_argument('--workload', choices=['dd', 'fio', 'both'], default='dd',
                    help='Workload to use for measurement (default: dd)')
    ap.add_argument('--dd-size', type=int, default=DD_SIZE_MB, metavar='MB',
                    help=f'dd transfer size in MiB (default: {DD_SIZE_MB})')
    ap.add_argument('--fio-rw', default=FIO_RW, metavar='MODE',
                    help=f'fio --rw mode (default: {FIO_RW}). '
                         'e.g. randread, randrw, read, write, seqread')
    ap.add_argument('--fio-bs', default=FIO_BS, metavar='SIZE',
                    help=f'fio block size (default: {FIO_BS})')
    ap.add_argument('--fio-iodepth', type=int, default=FIO_IODEPTH, metavar='N',
                    help=f'fio iodepth (default: {FIO_IODEPTH})')
    ap.add_argument('--fio-runtime', type=int, default=FIO_RUNTIME, metavar='S',
                    help=f'fio runtime in seconds (default: {FIO_RUNTIME})')
    ap.add_argument('--output', default=str(Path(__file__).parent / 'hmb_latency_sweep.png'),
                    metavar='PATH', help='Output plot file')
    ap.add_argument('--csv', metavar='PATH', help='Save raw results as CSV')
    args = ap.parse_args()

    if os.geteuid() != 0:
        die('Must run as root:  sudo python3 ' + sys.argv[0])
    if not Path(MODULE_PATH).exists():
        die(f'Module not found: {MODULE_PATH}\nRun `make` in the project root first.')
    if args.workload in ('fio', 'both'):
        if run('which fio', check=False).returncode != 0:
            die('fio not found – install with: apt install fio')

    state = load_state()
    print(f'State:    start={state["MEMMAP_START_BYTES"]}  '
          f'size={state["MEMMAP_SIZE_BYTES"]}  cpus={state["CPUS_MODULE"]}')
    print(f'Module:   {MODULE_PATH}')
    print(f'Workload: {args.workload}', end='')
    if args.workload in ('fio', 'both'):
        print(f'  fio rw={args.fio_rw} bs={args.fio_bs}'
              f' iodepth={args.fio_iodepth} runtime={args.fio_runtime}s', end='')
    if args.workload in ('dd', 'both'):
        print(f'  dd size={args.dd_size} MiB', end='')
    print('\n')

    all_results = {}
    for param in args.params:
        print(f'=== sweeping {param} ===')
        all_results[param] = sweep_param(param, SWEEPS[param], state, args)
        print()

    unload()

    # ── console summary + CSV ─────────────────────────────────────────────────
    use_dd  = args.workload in ('dd', 'both')
    use_fio = args.workload in ('fio', 'both')

    csv_header = ['param', 'value']
    if use_dd:
        csv_header += ['dd_write_gbps', 'dd_read_gbps']
    if use_fio:
        csv_header += ['fio_read_gbps', 'fio_write_gbps', 'fio_read_iops', 'fio_read_lat_us']
    csv_header += ['sram_pct', 'hmb_pct', 'nand_pct', 'total_lookups']

    csv_lines = [','.join(csv_header)]

    print('=== Summary ===')
    for param, data in all_results.items():
        print(f'\n{param}:')

        # build header
        hdr = f'  {"value":>10}'
        if use_dd:
            hdr += f'  {"dd_wr(GB/s)":>12}  {"dd_rd(GB/s)":>12}'
        if use_fio:
            hdr += f'  {"fio_rd(GB/s)":>12}  {"fio_rd_iops":>12}  {"fio_lat(µs)":>12}'
        hdr += f'  {"SRAM%":>7}  {"HMB%":>7}  {"NAND%":>7}  {"l2p_lat(ns)":>12}  {"lookups":>10}'
        print(hdr)

        for d in data:
            row = f'  {d["val"]:>10}'

            dd_wr = d.get('dd_wr_gbps')
            dd_rd = d.get('dd_rd_gbps')
            if use_dd:
                row += f'  {(f"{dd_wr:.3f}" if dd_wr is not None else "ERR"):>12}'
                row += f'  {(f"{dd_rd:.3f}" if dd_rd is not None else "ERR"):>12}'

            frd  = d.get('fio_read_gbps')
            fiops = d.get('fio_read_iops')
            flat  = d.get('fio_read_lat_us')
            if use_fio:
                row += f'  {(f"{frd:.3f}" if frd is not None else "ERR"):>12}'
                row += f'  {(f"{fiops:.0f}" if fiops is not None else "ERR"):>12}'
                row += f'  {(f"{flat:.0f}" if flat is not None else "ERR"):>12}'

            sp  = d.get('sram_pct')
            hp  = d.get('hmb_pct')
            np_ = d.get('nand_pct')
            ll  = d.get('avg_l2p_ns')
            tl  = d.get('total_lookups')
            row += f'  {(f"{sp:.1f}" if sp is not None else "-"):>7}'
            row += f'  {(f"{hp:.1f}" if hp is not None else "-"):>7}'
            row += f'  {(f"{np_:.1f}" if np_ is not None else "-"):>7}'
            row += f'  {(str(ll) if ll is not None else "-"):>12}'
            row += f'  {(str(tl) if tl is not None else "-"):>10}'
            print(row)

            # CSV row
            csv_row = [param, str(d['val'])]
            if use_dd:
                csv_row += [f'{dd_wr:.4f}' if dd_wr is not None else '',
                            f'{dd_rd:.4f}' if dd_rd is not None else '']
            if use_fio:
                csv_row += [f'{frd:.4f}'   if frd   is not None else '',
                            f'{d.get("fio_write_gbps", ""):.4f}' if d.get('fio_write_gbps') is not None else '',
                            f'{fiops:.0f}' if fiops  is not None else '',
                            f'{flat:.1f}'  if flat   is not None else '']
            csv_row += [f'{sp:.2f}'  if sp  is not None else '',
                        f'{hp:.2f}'  if hp  is not None else '',
                        f'{np_:.2f}' if np_ is not None else '',
                        str(tl)      if tl  is not None else '']
            csv_lines.append(','.join(csv_row))

    if args.csv:
        Path(args.csv).write_text('\n'.join(csv_lines) + '\n')
        print(f'\n[done] CSV → {args.csv}')

    plot(all_results, args)


if __name__ == '__main__':
    main()
