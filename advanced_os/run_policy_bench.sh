#!/usr/bin/env bash
# Cache-policy ablation harness for NVMeVirt (3-tier L2P cache: SRAM→HMB→NAND).
# Runs {cyclic, recency, uniform} × {LRU, RANDOM, MRU, FIFO}.
#
# Since NVMeVirt only exposes hit/miss counters at rmmod, the module is
# reloaded per (policy, pattern) so each run starts with clean counters.
#
# Expected outcomes:
#   cyclic   (sequential wrap-around):  MRU > RANDOM > LRU ≈ FIFO
#   recency  (zipf hot-set):            LRU > FIFO > RANDOM > MRU
#   uniform  (negative control):        all policies roughly equal
#
# Usage (must be root):
#   sudo ./advanced_os/run_policy_bench.sh [-y]
set -euo pipefail

# ----------------------------- config --------------------------------
SPAN_MB=8        # working-set span. Must be > cache coverage.
                 #   coverage ≈ hmb_size_kb entries × 4 KB/entry
                 #   default HMB=1024 entries → ~4 MB → SPAN_MB=8 gives 2×
LOOPS=20         # cyclic: #full passes over SPAN; sets same total I/Os for random
ZIPF_THETA=0.99  # recency skew (higher → sharper hot set, bigger LRU advantage)
SEED=42          # fixed RNG → every policy sees the same LBA stream

POLICIES=(lru random mru fifo)
declare -A POLICY_NUMS=([lru]=0 [random]=1 [mru]=2 [fifo]=3)

# NVMeVirt module parameters
HMB_KB=1024
SRAM_KB=32
LAT_SRAM=100
LAT_HMB=2000
LAT_NAND=59000
# ---------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_PATH="$SCRIPT_DIR/../nvmev.ko"
STATE_FILE="/boot/nvmev-arm64.env"
OUTDIR="$SCRIPT_DIR/results/policy_$(date +%Y%m%d_%H%M)"
CSV="$OUTDIR/summary.csv"

ASSUME_YES=0
[[ "${1:-}" == "-y" ]] && { ASSUME_YES=1; }

mkdir -p "$OUTDIR"

# ── guards ────────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]]       || { echo "ERROR: run as root"; exit 1; }
[[ -f "$MODULE_PATH" ]] || { echo "ERROR: $MODULE_PATH not found — run make first"; exit 1; }
[[ -f "$STATE_FILE"  ]] || { echo "ERROR: $STATE_FILE not found"; exit 1; }
command -v fio >/dev/null || { echo "ERROR: fio not found"; exit 1; }

MEMMAP_START=$(grep '^MEMMAP_START_BYTES=' "$STATE_FILE" | cut -d= -f2)
MEMMAP_SIZE=$(grep  '^MEMMAP_SIZE_BYTES='  "$STATE_FILE" | cut -d= -f2)
CPUS=$(grep         '^CPUS_MODULE='         "$STATE_FILE" | cut -d= -f2)

# ── NVMeVirt hooks ────────────────────────────────────────────────────────────

CURRENT_POL_NUM=0

set_policy() {          # store which policy to use on next reload
  CURRENT_POL_NUM="${POLICY_NUMS[$1]}"
}

reload_module() {       # rmmod + insmod with current policy; resets all counters
  if lsmod | grep -q '^nvmev '; then
    rmmod nvmev 2>/dev/null || true; sleep 1
  fi
  insmod "$MODULE_PATH" \
    memmap_start="$MEMMAP_START" memmap_size="$MEMMAP_SIZE" cpus="$CPUS" \
    hmb_size_kb="$HMB_KB" sram_size_kb="$SRAM_KB" \
    lat_sram_ns="$LAT_SRAM" lat_hmb_ns="$LAT_HMB" lat_nand_ns="$LAT_NAND" \
    repl_policy="$CURRENT_POL_NUM"
  sleep 2
}

unload_module() {
  lsmod | grep -q '^nvmev ' && { rmmod nvmev 2>/dev/null || true; sleep 1; } || true
}

wait_for_ns() {
  for ((t=0; t<${1:-15}; t++)); do
    for vf in /sys/class/nvme/nvme*/device/vendor; do
      [[ -f "$vf" ]] || continue
      if [[ "$(cat "$vf")" == "0x0c51" ]]; then
        ctrl=$(basename "$(dirname "$(dirname "$vf")")")
        ns=$(ls "/dev/${ctrl}n"* 2>/dev/null | sort | head -1)
        [[ -b "$ns" ]] && { echo "$ns"; return 0; }
      fi
    done; sleep 1
  done
  echo "ERROR: NVMeVirt device not found after ${1:-15}s" >&2; return 1
}

reset_counters() {
  : # module reload already resets SRAM/HMB/NAND counters; nothing to do
}

read_hitrate() {
  # hmb_cache_fini prints:
  #   "HMB cache stats: SRAM hits=H  HMB hits=M  NAND fetches=N  avg_l2p_lat_ns=L"
  local line; line=$(dmesg | grep "HMB cache stats:" | tail -1)
  [[ -z "$line" ]] && { echo "NA"; return; }
  local sram hmb nand
  sram=$(echo "$line" | grep -oP 'SRAM hits=\K[0-9]+'   || echo 0)
  hmb=$(echo  "$line" | grep -oP 'HMB hits=\K[0-9]+'    || echo 0)
  nand=$(echo "$line" | grep -oP 'NAND fetches=\K[0-9]+' || echo 0)
  python3 -c "h=${sram}+${hmb}; n=${nand}; t=h+n; print(f'{h/t:.4f}' if t else 'NA')"
}

# ── workload helpers ──────────────────────────────────────────────────────────

perf_mode() {
  nvpmodel -m 0 >/dev/null 2>&1 || true
  jetson_clocks >/dev/null 2>&1 || true
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$f" 2>/dev/null || true
  done
}

precondition() {        # map every LPN in SPAN so L2P lookups are valid
  fio --name=precond --filename="$1" --ioengine=libaio --direct=1 \
      --iodepth=16 --rw=write --bs=128k --size="${SPAN_MB}m" \
      --output-format=normal >/dev/null
}

run_fio() {             # tag dev <fio args…>  →  prints "iops,clat_us"
  local tag="$1" dev="$2"; shift 2
  local out="$OUTDIR/${tag}.json"
  fio --name="$tag" --filename="$dev" --ioengine=libaio --direct=1 \
      --iodepth=1 --bs=4k --offset=0 --group_reporting=1 \
      --output-format=json --output="$out" "$@" >/dev/null
  python3 - "$out" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))["jobs"][0]["read"]
print(f'{r["iops"]:.0f},{r["clat_ns"]["mean"]/1000.0:.1f}')
PY
}

run_pattern() {         # pol  pat  <fio args…>
  local pol="$1" pat="$2"; shift 2
  echo ""
  echo "  ── $pol / $pat ──"

  dmesg -C
  echo "  Reloading (policy=$pol, counters reset) ..."
  if ! reload_module; then
    echo "  ERROR: insmod failed, skipping ${pol}/${pat}"; return
  fi

  local dev
  dev=$(wait_for_ns 15) || { echo "  ERROR: device timeout, skipping"; unload_module; return; }
  echo "  Device: $dev"

  precondition "$dev"
  reset_counters

  local perf; perf=$(run_fio "${pol}_${pat}" "$dev" "$@")

  unload_module
  local hr; hr=$(read_hitrate)

  printf "  %-8s %-8s  hit_rate=%-6s  %s\n" "$pol" "$pat" "$hr" "$perf"
  echo "${pol},${pat},${hr},${perf}" >> "$CSV"
}

# ── main ──────────────────────────────────────────────────────────────────────

IOSIZE_MB=$(( SPAN_MB * LOOPS ))   # same total I/O count as cyclic (SPAN × LOOPS)

{
  echo "## date";         date -Iseconds
  echo "## span_mb";      echo "$SPAN_MB"
  echo "## loops";        echo "$LOOPS"
  echo "## iosize_mb";    echo "$IOSIZE_MB"
  echo "## zipf_theta";   echo "$ZIPF_THETA"
  echo "## seed";         echo "$SEED"
  echo "## hmb_size_kb";  echo "$HMB_KB"
  echo "## sram_size_kb"; echo "$SRAM_KB"
  echo "## lat_sram_ns";  echo "$LAT_SRAM"
  echo "## lat_hmb_ns";   echo "$LAT_HMB"
  echo "## lat_nand_ns";  echo "$LAT_NAND"
} | tee "$OUTDIR/00_state.txt"

echo ""
echo "SPAN=${SPAN_MB}MB  LOOPS=$LOOPS  → ${IOSIZE_MB}MB total I/O per pattern"
echo "Cache: SRAM=${SRAM_KB}KB  HMB=${HMB_KB}KB  (~$((SRAM_KB + HMB_KB))KB coverage)"
echo ""
echo "Expected:  cyclic  → MRU > RANDOM > LRU ≈ FIFO"
echo "           recency → LRU > FIFO > RANDOM > MRU"
echo "           uniform → all roughly equal  (negative control)"
echo ""

if [[ $ASSUME_YES -ne 1 ]]; then
  read -rp "Will WRITE to NVMeVirt device during preconditioning. Proceed? [y/N] " ok
  [[ "$ok" == "y" ]] || { echo "Aborted."; exit 1; }
fi

perf_mode
echo "policy,pattern,hit_rate,read_iops,clat_mean_us" > "$CSV"

for pol in "${POLICIES[@]}"; do
  set_policy "$pol"
  echo ""
  echo "========================================================"
  echo "Policy: $pol  (repl_policy=${CURRENT_POL_NUM})"
  echo "========================================================"

  # cyclic sequential read → MRU wins: keeps oldest entries = about to be re-read
  run_pattern "$pol" cyclic \
    --rw=read --size="${SPAN_MB}m" --loops="$LOOPS"

  # recency-skewed → LRU wins: keeps hot entries that are repeatedly accessed
  # norandommap=1: allow address reuse so zipf hot-set actually repeats
  run_pattern "$pol" recency \
    --rw=randread --size="${SPAN_MB}m" --io_size="${IOSIZE_MB}m" \
    --random_distribution=zipf:"$ZIPF_THETA" --norandommap=1 --randseed="$SEED"

  # uniform → negative control; all policies see same miss rate
  run_pattern "$pol" uniform \
    --rw=randread --size="${SPAN_MB}m" --io_size="${IOSIZE_MB}m" \
    --norandommap=1 --randseed="$SEED"
done

unload_module 2>/dev/null || true
chown -R "${SUDO_USER:-$(logname 2>/dev/null || echo root)}:" "$OUTDIR" 2>/dev/null || true

echo ""
echo "=========================================================="
echo "Results: $OUTDIR"
echo "Plot:    python3 $SCRIPT_DIR/plot_policy.py $OUTDIR"
echo "=========================================================="
echo ""
column -t -s, "$CSV"
