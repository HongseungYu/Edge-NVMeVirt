#!/bin/bash
# run_locality_bench.sh — NVMeVirt locality (Zipf) sweep
#
# Holds the LBA span fixed and sweeps Zipf skew (theta).
# Reloads nvmev.ko per theta so each theta starts with a clean LRU cache
# and per-theta SRAM/HMB/NAND hit rates can be read from dmesg.
#
# Output files (loc_qd{QD}_t{THETA}_run{N}.json) match real_ssd/run_locality.sh
# so real_ssd/plot_locality.py can plot NVMeVirt results directly.
#
# Usage (must be root):
#   sudo ./advanced_os/run_locality_bench.sh LABEL [OPTIONS]
#
# Options:
#   --span  SIZE   fixed fio size              (default: 2G)
#   --qd    N      fio iodepth                 (default: 1)
#   --theta LIST   comma-separated thetas      (default: 0,0.2,0.4,0.6,0.8,0.99)
#   --runs  N      fio runs per theta          (default: 5)
#   --runtime N    fio runtime seconds         (default: 30)
#   --ramp  N      fio ramp_time seconds       (default: 5)
#   --sleep N      sleep between thetas        (default: 10)
#   --hmb   KB     hmb_size_kb param           (default: 1024)
#   --sram  KB     sram_size_kb param          (default: 32)
#   --lat-sram NS  lat_sram_ns param           (default: 100)
#   --lat-hmb  NS  lat_hmb_ns param            (default: 2000)
#   --lat-nand NS  lat_nand_ns param           (default: 59000)
#   --repl  N      repl_policy 0=LRU 1=random  (default: 0)
#   --no-hmb       disable HMB cache (hmb=0, sram=0)
#   -y             skip confirmation prompt
#
# Examples:
#   sudo ./advanced_os/run_locality_bench.sh hmb_on_loc
#   sudo ./advanced_os/run_locality_bench.sh hmb_off_loc --no-hmb
#   sudo ./advanced_os/run_locality_bench.sh hmb_on_loc --theta 0,0.4,0.8,0.99,1.2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_PATH="${SCRIPT_DIR}/../nvmev.ko"
STATE_FILE="/boot/nvmev-arm64.env"

# ── defaults ──────────────────────────────────────────────────────────────────
LABEL=""
SPAN=1536M
QD=1
THETA_LIST="0,0.2,0.4,0.6,0.8,0.99"
RUNS=1
RUNTIME=30
RAMP=5
SLEEP=10
HMB_KB=1024
SRAM_KB=32
LAT_SRAM=100
LAT_HMB=2000
LAT_NAND=59000
REPL=0
ASSUME_YES=0

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --span)     SPAN=$2;       shift 2 ;;
    --qd)       QD=$2;         shift 2 ;;
    --theta)    THETA_LIST=$2; shift 2 ;;
    --runs)     RUNS=$2;       shift 2 ;;
    --runtime)  RUNTIME=$2;    shift 2 ;;
    --ramp)     RAMP=$2;       shift 2 ;;
    --sleep)    SLEEP=$2;      shift 2 ;;
    --hmb)      HMB_KB=$2;     shift 2 ;;
    --sram)     SRAM_KB=$2;    shift 2 ;;
    --lat-sram) LAT_SRAM=$2;   shift 2 ;;
    --lat-hmb)  LAT_HMB=$2;    shift 2 ;;
    --lat-nand) LAT_NAND=$2;   shift 2 ;;
    --repl)     REPL=$2;       shift 2 ;;
    --no-hmb)   HMB_KB=0; SRAM_KB=0; shift ;;
    -y|--yes)   ASSUME_YES=1;  shift ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *)
      if [ -z "$LABEL" ]; then LABEL=$1
      else echo "Unknown argument: $1"; exit 1
      fi
      shift ;;
  esac
done

[ -z "$LABEL" ] && { echo "ERROR: label required. See --help"; exit 1; }
[ "$EUID" -ne 0 ] && { echo "ERROR: run as root (sudo)"; exit 1; }
[ -f "$MODULE_PATH" ] || { echo "ERROR: module not found: $MODULE_PATH (run make first)"; exit 1; }
command -v fio >/dev/null || { echo "ERROR: fio not found (apt install fio)"; exit 1; }

# ── load boot-time memmap parameters ─────────────────────────────────────────
[ -f "$STATE_FILE" ] || { echo "ERROR: $STATE_FILE not found — run verify_nvmev_arm64.sh first"; exit 1; }

MEMMAP_START=$(grep '^MEMMAP_START_BYTES=' "$STATE_FILE" | cut -d= -f2)
MEMMAP_SIZE=$(grep  '^MEMMAP_SIZE_BYTES='  "$STATE_FILE" | cut -d= -f2)
CPUS=$(grep         '^CPUS_MODULE='         "$STATE_FILE" | cut -d= -f2)

[ -z "$MEMMAP_START" ] && { echo "ERROR: MEMMAP_START_BYTES missing from $STATE_FILE"; exit 1; }
[ -z "$MEMMAP_SIZE"  ] && { echo "ERROR: MEMMAP_SIZE_BYTES missing from $STATE_FILE";  exit 1; }
[ -z "$CPUS"         ] && { echo "ERROR: CPUS_MODULE missing from $STATE_FILE";         exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────
norm_theta() {
  case "$1" in
    1|1.0|1.00) echo "0.99" ;;
    *)          echo "$1" ;;
  esac
}

unload_module() {
  if lsmod | grep -q '^nvmev '; then
    rmmod nvmev 2>/dev/null || true
    sleep 1
  fi
}

load_module() {
  insmod "$MODULE_PATH" \
    memmap_start="$MEMMAP_START" \
    memmap_size="$MEMMAP_SIZE" \
    cpus="$CPUS" \
    hmb_size_kb="$HMB_KB" \
    sram_size_kb="$SRAM_KB" \
    lat_sram_ns="$LAT_SRAM" \
    lat_hmb_ns="$LAT_HMB" \
    lat_nand_ns="$LAT_NAND" \
    repl_policy="$REPL"
}

wait_for_ns() {
  local timeout=${1:-15}
  for ((t=0; t<timeout; t++)); do
    for vf in /sys/class/nvme/nvme*/device/vendor; do
      [ -f "$vf" ] || continue
      if [ "$(cat "$vf")" = "0x0c51" ]; then
        ctrl=$(basename "$(dirname "$(dirname "$vf")")")
        ns=$(ls "/dev/${ctrl}n"* 2>/dev/null | sort | head -1)
        [ -b "$ns" ] && { echo "$ns"; return 0; }
      fi
    done
    sleep 1
  done
  echo "ERROR: NVMeVirt namespace not found after ${timeout}s" >&2
  return 1
}

# ── output directory ──────────────────────────────────────────────────────────
OUTDIR="${SCRIPT_DIR}/results/${LABEL}_$(date +%Y%m%d_%H%M)"
mkdir -p "$OUTDIR"

# ── lock performance mode ─────────────────────────────────────────────────────
nvpmodel -m 0 >/dev/null 2>&1 || true
jetson_clocks >/dev/null 2>&1 || true
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$f" 2>/dev/null || true
done

# ── state snapshot ────────────────────────────────────────────────────────────
{
  echo "## label";        echo "$LABEL"
  echo "## module";       echo "$MODULE_PATH"
  echo "## date";         echo "$(date -Iseconds)"
  echo "## experiment";   echo "locality (zipf) sweep, fixed span"
  echo "## hmb_size_kb";  echo "$HMB_KB"
  echo "## sram_size_kb"; echo "$SRAM_KB"
  echo "## lat_sram_ns";  echo "$LAT_SRAM"
  echo "## lat_hmb_ns";   echo "$LAT_HMB"
  echo "## lat_nand_ns";  echo "$LAT_NAND"
  echo "## repl_policy";  echo "$REPL"
  echo "## span";         echo "$SPAN  (fixed)"
  echo "## qd";           echo "$QD"
  echo "## theta_list";   echo "$THETA_LIST  (0 = uniform baseline)"
  echo "## runs";         echo "$RUNS"
  echo "## runtime_s";    echo "$RUNTIME"
  echo "## ramp_s";       echo "$RAMP"
  echo "## sleep_s";      echo "$SLEEP"
} | tee "$OUTDIR/00_state.txt"

echo ""
if [ "$ASSUME_YES" -ne 1 ]; then
  read -rp "Proceed? (y/N) " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; rm -rf "$OUTDIR"; exit 1; }
fi

# ── main sweep ────────────────────────────────────────────────────────────────
IFS=',' read -ra THETAS <<< "$THETA_LIST"
TOTAL=$(( ${#THETAS[@]} * RUNS ))
N=0
START=$(date +%s)

for TH_RAW in "${THETAS[@]}"; do
  TH=$(norm_theta "$TH_RAW")
  [ "$TH" != "$TH_RAW" ] && echo "NOTE: theta=$TH_RAW -> using $TH (fio limit)"

  if [ "$TH" = "0" ] || [ "$TH" = "0.0" ]; then
    DIST="random"; THLABEL="0"
  else
    DIST="zipf:${TH}"; THLABEL="$TH"
  fi

  echo ""
  echo "========================================"
  echo "theta=$THLABEL  dist=$DIST  ($(date +%H:%M:%S))"
  echo "========================================"

  dmesg -C
  unload_module

  echo "  Loading nvmev.ko (hmb_size_kb=$HMB_KB sram_size_kb=$SRAM_KB) ..."
  if ! load_module; then
    echo "  ERROR: insmod failed, skipping theta=$THLABEL"
    continue
  fi
  sleep 2

  NS=$(wait_for_ns 15) || { echo "  ERROR: device timeout, skipping theta=$THLABEL"; unload_module; continue; }
  echo "  Device: $NS"

  echo "  Preconditioning (write $SPAN) ..."
  fio --filename="$NS" --rw=write --bs=128k --size="$SPAN" \
      --direct=1 --ioengine=libaio --iodepth=16 \
      --name=precond --output-format=normal >/dev/null
  echo "  Precondition done."

  for ((i=1; i<=RUNS; i++)); do
    N=$((N+1))
    OUT="$OUTDIR/loc_qd${QD}_t${THLABEL}_run${i}.json"
    echo "  [$N/$TOTAL] theta=$THLABEL run=$i -> $(basename "$OUT")"
    fio --filename="$NS" --rw=randread --bs=4k \
        --iodepth="$QD" --size="$SPAN" \
        --direct=1 --ioengine=libaio \
        --random_distribution="$DIST" \
        --randseed=42 --randrepeat=1 \
        --runtime="$RUNTIME" --ramp_time="$RAMP" --time_based \
        --percentile_list=50:95:99:99.9 \
        --name="loc_qd${QD}_t${THLABEL}_run${i}" \
        --output-format=json --output="$OUT"
  done

  echo "  Unloading (capturing HMB stats) ..."
  unload_module
  sleep 1
  dmesg | grep "HMB cache stats:" | tail -1 > "$OUTDIR/hmb_stats_t${THLABEL}.txt"
  STATS=$(cat "$OUTDIR/hmb_stats_t${THLABEL}.txt" 2>/dev/null || echo "(no stats)")
  echo "  $STATS"

  [ "$TH_RAW" != "${THETAS[-1]}" ] && sleep "$SLEEP"
done

# clean up
unload_module 2>/dev/null || true

chown -R "${SUDO_USER:-$(logname 2>/dev/null || echo root)}:" "$OUTDIR" 2>/dev/null || true

ELAPSED=$(( $(date +%s) - START ))
echo ""
echo "========================================"
echo "Done in ${ELAPSED}s"
echo "Results: $OUTDIR"
echo "Plot:    python3 /home/nxc/AdvancedOS26/real_ssd/plot_locality.py $OUTDIR"
echo "========================================"
