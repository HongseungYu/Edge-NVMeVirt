#!/bin/bash
# run_span_bench.sh — NVMeVirt random-read latency vs LBA span sweep
#
# Usage (must be root):
#   sudo ./advanced_os/run_span_bench.sh LABEL [OPTIONS]
#
# Options:
#   --span  LIST    comma-separated fio sizes  (default: 64M,256M,512M,1G,2G,4G,8G,16G)
#   --qd    N       fio iodepth                (default: 1)
#   --runs  N       fio runs per span          (default: 3)
#   --runtime N     fio runtime seconds        (default: 30)
#   --ramp  N       fio ramp_time seconds      (default: 5)
#   --sleep N       sleep between spans        (default: 5)
#   --hmb   MB      hmb_size_mb param          (default: 4)
#   --sram  KB      sram_size_kb param         (default: 512)
#   --lat-sram NS   lat_sram_ns param          (default: 100)
#   --lat-hmb  NS   lat_hmb_ns param           (default: 3000)
#   --lat-nand NS   lat_nand_ns param          (default: 40000)
#   --repl  N       repl_policy 0=LRU 1=random (default: 0)
#   --no-hmb        disable HMB cache entirely (hmb=0, sram=0)
#
# Examples:
#   sudo ./advanced_os/run_span_bench.sh hmb_on
#   sudo ./advanced_os/run_span_bench.sh hmb_off --no-hmb
#   sudo ./advanced_os/run_span_bench.sh hmb_on_8mb --hmb 8 --span 64M,512M,2G,8G,32G

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_PATH="${SCRIPT_DIR}/../nvmev.ko"
STATE_FILE="/boot/nvmev-arm64.env"

# ── defaults ──────────────────────────────────────────────────────────────────
LABEL=""
SPAN_LIST="16M,32M,64M,128M,192M,256M,512M,1024M,1536M"
QD=1
RUNS=1
RUNTIME=15
RAMP=5
SLEEP=5
HMB_KB=0
SRAM_KB=32
LAT_SRAM=100
LAT_HMB=2000
LAT_NAND=59000
REPL=0

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --span)     SPAN_LIST=$2;  shift 2 ;;
    --qd)       QD=$2;         shift 2 ;;
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
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
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
MEMMAP_SIZE=$(grep '^MEMMAP_SIZE_BYTES='  "$STATE_FILE" | cut -d= -f2)
CPUS=$(grep        '^CPUS_MODULE='         "$STATE_FILE" | cut -d= -f2)

[ -z "$MEMMAP_START" ] && { echo "ERROR: MEMMAP_START_BYTES missing from $STATE_FILE"; exit 1; }
[ -z "$MEMMAP_SIZE"  ] && { echo "ERROR: MEMMAP_SIZE_BYTES missing from $STATE_FILE";  exit 1; }
[ -z "$CPUS"         ] && { echo "ERROR: CPUS_MODULE missing from $STATE_FILE";         exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────
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

# returns NVMeVirt namespace path (vendor 0x0c51) or exits on timeout
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

# ── state file ────────────────────────────────────────────────────────────────
SRAM_COV_MB=$(( SRAM_KB ))              # SRAM_KB KB → SRAM_KB MB logical coverage
HMB_COV_MB=$(( HMB_KB ))               # HMB_KB KB → HMB_KB MB logical coverage

{
  echo "## label";         echo "$LABEL"
  echo "## module";        echo "$MODULE_PATH"
  echo "## date";          echo "$(date -Iseconds)"
  echo "## hmb_size_kb";   echo "$HMB_KB"
  echo "## sram_size_kb";  echo "$SRAM_KB"
  echo "## lat_sram_ns";   echo "$LAT_SRAM"
  echo "## lat_hmb_ns";    echo "$LAT_HMB"
  echo "## lat_nand_ns";   echo "$LAT_NAND"
  echo "## repl_policy";   echo "$REPL"
  echo "## qd";            echo "$QD"
  echo "## runs";          echo "$RUNS"
  echo "## runtime_s";     echo "$RUNTIME"
  echo "## span_list";     echo "$SPAN_LIST"
  echo "## sram_cov_mb";   echo "$SRAM_COV_MB"
  echo "## hmb_cov_mb";    echo "$HMB_COV_MB"
} | tee "$OUTDIR/00_state.txt"

echo ""
echo "SRAM coverage: ${SRAM_COV_MB} MB    HMB coverage: ${HMB_COV_MB} MB"
echo "Results: $OUTDIR"
echo ""

# ── main sweep ────────────────────────────────────────────────────────────────
IFS=',' read -ra SPANS <<< "$SPAN_LIST"
TOTAL=$(( ${#SPANS[@]} * RUNS ))
N=0
START=$(date +%s)

for SPAN in "${SPANS[@]}"; do
  echo "========================================"
  echo "SPAN=$SPAN  ($(date +%H:%M:%S))"
  echo "========================================"

  dmesg -C
  unload_module

  echo "  Loading nvmev.ko ..."
  if ! load_module; then
    echo "  ERROR: insmod failed, skipping $SPAN"
    continue
  fi
  sleep 2

  NS=$(wait_for_ns 15) || { echo "  ERROR: device timeout, skipping $SPAN"; unload_module; continue; }
  echo "  Device: $NS"

  echo "  Preconditioning (write $SPAN) ..."
  fio --filename="$NS" --rw=write --bs=128k --size="$SPAN" \
      --direct=1 --ioengine=libaio --iodepth=16 \
      --name=precond --output-format=normal >/dev/null
  echo "  Precondition done."

  for ((i=1; i<=RUNS; i++)); do
    N=$((N+1))
    OUT="$OUTDIR/bench_qd${QD}_${SPAN}_run${i}.json"
    echo "  [$N/$TOTAL] QD=$QD SPAN=$SPAN run=$i → $(basename "$OUT")"
    fio --filename="$NS" --rw=randread --bs=4k \
        --iodepth="$QD" --size="$SPAN" \
        --direct=1 --ioengine=libaio \
        --runtime="$RUNTIME" --ramp_time="$RAMP" --time_based \
        --randseed=42 --randrepeat=1 \
        --percentile_list=50:95:99:99.9 \
        --name="bench_${SPAN}_run${i}" \
        --output-format=json --output="$OUT"
  done

  echo "  Unloading (capturing HMB stats) ..."
  unload_module
  sleep 1
  dmesg | grep "HMB cache stats:" | tail -1 > "$OUTDIR/hmb_stats_${SPAN}.txt"

  STATS=$(cat "$OUTDIR/hmb_stats_${SPAN}.txt" || echo "(no stats)")
  echo "  $STATS"

  sleep "$SLEEP"
done

# clean up
unload_module 2>/dev/null || true

# fix permissions
chown -R "${SUDO_USER:-$(logname 2>/dev/null || echo root)}:" "$OUTDIR" 2>/dev/null || true

ELAPSED=$(( $(date +%s) - START ))
echo ""
echo "========================================"
echo "Done in ${ELAPSED}s"
echo "Results: $OUTDIR"
echo "Plot:    python3 ${SCRIPT_DIR}/plot_span.py $OUTDIR"
echo "========================================"
