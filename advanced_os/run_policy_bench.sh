#!/bin/bash
# run_policy_bench.sh — cyclic sequential read, sweep replacement policies
#
# Loads nvmev.ko once per policy so each starts with a clean cache,
# then runs a cyclic sequential read (fio --rw=read) and records latency.
#
# For a scan region larger than the L2P cache, MRU is expected to win:
#   LRU/FIFO → ~0% hit rate in steady state (keep recently-accessed = useless)
#   MRU      → ~(K-1)/N hit rate  (keeps oldest entries = about to be re-read)
#   RANDOM   → somewhere in between
#
# Usage (must be root):
#   sudo ./advanced_os/run_policy_bench.sh LABEL [OPTIONS]
#
# Options:
#   --span  SIZE   fio size / cyclic scan region  (default: 8M  ≈ 2× HMB coverage)
#   --qd    N      fio iodepth                    (default: 1)
#   --runs  N      fio runs per policy            (default: 3)
#   --runtime N    fio runtime seconds            (default: 30)
#   --ramp  N      fio ramp_time seconds          (default: 5)
#   --sleep N      sleep between policies (s)     (default: 10)
#   --policies LIST comma-sep: 0=LRU,1=RANDOM,2=MRU,3=FIFO (default: 0,1,2,3)
#   --hmb   KB     hmb_size_kb                   (default: 1024)
#   --sram  KB     sram_size_kb                  (default: 32)
#   --lat-sram NS                                (default: 100)
#   --lat-hmb  NS                                (default: 2000)
#   --lat-nand NS                                (default: 59000)
#   -y             skip confirmation prompt
#
# Examples:
#   sudo ./advanced_os/run_policy_bench.sh cyclic_cmp
#   sudo ./advanced_os/run_policy_bench.sh cyclic_cmp --span 16M --runs 3
#   sudo ./advanced_os/run_policy_bench.sh lru_vs_mru --policies 0,2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_PATH="${SCRIPT_DIR}/../nvmev.ko"
STATE_FILE="/boot/nvmev-arm64.env"

# ── defaults ──────────────────────────────────────────────────────────────────
LABEL=""
SPAN="8M"
QD=1
RUNS=3
RUNTIME=30
RAMP=5
SLEEP=10
POLICY_LIST="0,1,2,3"
HMB_KB=1024
SRAM_KB=32
LAT_SRAM=100
LAT_HMB=2000
LAT_NAND=59000
ASSUME_YES=0

POLICY_NAMES=([0]="lru" [1]="random" [2]="mru" [3]="fifo")

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --span)      SPAN=$2;        shift 2 ;;
    --qd)        QD=$2;          shift 2 ;;
    --runs)      RUNS=$2;        shift 2 ;;
    --runtime)   RUNTIME=$2;     shift 2 ;;
    --ramp)      RAMP=$2;        shift 2 ;;
    --sleep)     SLEEP=$2;       shift 2 ;;
    --policies)  POLICY_LIST=$2; shift 2 ;;
    --hmb)       HMB_KB=$2;      shift 2 ;;
    --sram)      SRAM_KB=$2;     shift 2 ;;
    --lat-sram)  LAT_SRAM=$2;    shift 2 ;;
    --lat-hmb)   LAT_HMB=$2;     shift 2 ;;
    --lat-nand)  LAT_NAND=$2;    shift 2 ;;
    -y|--yes)    ASSUME_YES=1;   shift ;;
    -h|--help)   sed -n '2,35p' "$0"; exit 0 ;;
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
command -v fio >/dev/null || { echo "ERROR: fio not found"; exit 1; }
[ -f "$STATE_FILE" ] || { echo "ERROR: $STATE_FILE not found"; exit 1; }

# ── load boot-time memmap parameters ─────────────────────────────────────────
MEMMAP_START=$(grep '^MEMMAP_START_BYTES=' "$STATE_FILE" | cut -d= -f2)
MEMMAP_SIZE=$(grep  '^MEMMAP_SIZE_BYTES='  "$STATE_FILE" | cut -d= -f2)
CPUS=$(grep         '^CPUS_MODULE='         "$STATE_FILE" | cut -d= -f2)

[ -z "$MEMMAP_START" ] && { echo "ERROR: MEMMAP_START_BYTES missing"; exit 1; }
[ -z "$MEMMAP_SIZE"  ] && { echo "ERROR: MEMMAP_SIZE_BYTES missing";  exit 1; }
[ -z "$CPUS"         ] && { echo "ERROR: CPUS_MODULE missing";         exit 1; }

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
    repl_policy="$1"
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
  echo "## date";         echo "$(date -Iseconds)"
  echo "## experiment";   echo "policy comparison (cyclic sequential read)"
  echo "## workload";     echo "cyclic"
  echo "## span";         echo "$SPAN"
  echo "## qd";           echo "$QD"
  echo "## policies";     echo "$POLICY_LIST  (0=LRU 1=RANDOM 2=MRU 3=FIFO)"
  echo "## runs";         echo "$RUNS"
  echo "## runtime_s";    echo "$RUNTIME"
  echo "## ramp_s";       echo "$RAMP"
  echo "## hmb_size_kb";  echo "$HMB_KB"
  echo "## sram_size_kb"; echo "$SRAM_KB"
  echo "## lat_sram_ns";  echo "$LAT_SRAM"
  echo "## lat_hmb_ns";   echo "$LAT_HMB"
  echo "## lat_nand_ns";  echo "$LAT_NAND"
} | tee "$OUTDIR/00_state.txt"

echo ""
echo "Workload : cyclic sequential read (fio --rw=read, wraps at $SPAN)"
echo "L2P cache: SRAM ${SRAM_KB}KB + HMB ${HMB_KB}KB  →  coverage ~$((SRAM_KB + HMB_KB))KB"
echo "Expected : MRU > RANDOM > LRU ≈ FIFO  (scan > cache size)"
echo ""

if [ "$ASSUME_YES" -ne 1 ]; then
  read -rp "Proceed? (y/N) " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; rm -rf "$OUTDIR"; exit 1; }
fi

# ── main sweep ────────────────────────────────────────────────────────────────
IFS=',' read -ra POLICIES <<< "$POLICY_LIST"
TOTAL=$(( ${#POLICIES[@]} * RUNS ))
N=0
START=$(date +%s)

for POL in "${POLICIES[@]}"; do
  PNAME="${POLICY_NAMES[$POL]:-pol${POL}}"

  echo ""
  echo "========================================"
  echo "Policy $POL ($PNAME)  span=$SPAN  ($(date +%H:%M:%S))"
  echo "========================================"

  dmesg -C
  unload_module

  echo "  Loading nvmev.ko (repl_policy=$POL=$PNAME) ..."
  if ! load_module "$POL"; then
    echo "  ERROR: insmod failed, skipping policy=$POL"
    continue
  fi
  sleep 2

  NS=$(wait_for_ns 15) || { echo "  ERROR: device timeout, skipping"; unload_module; continue; }
  echo "  Device: $NS"

  echo "  Preconditioning (sequential write $SPAN) ..."
  fio --filename="$NS" --rw=write --bs=128k --size="$SPAN" \
      --direct=1 --ioengine=libaio --iodepth=16 \
      --name=precond --output-format=normal >/dev/null
  echo "  Precondition done."

  for ((i=1; i<=RUNS; i++)); do
    N=$((N+1))
    OUT="$OUTDIR/pol_qd${QD}_${PNAME}_run${i}.json"
    echo "  [$N/$TOTAL] policy=$PNAME run=$i -> $(basename "$OUT")"
    fio --filename="$NS" --rw=read --bs=4k \
        --iodepth="$QD" --size="$SPAN" \
        --direct=1 --ioengine=libaio \
        --runtime="$RUNTIME" --ramp_time="$RAMP" --time_based \
        --percentile_list=50:95:99:99.9 \
        --name="pol_${PNAME}_run${i}" \
        --output-format=json --output="$OUT"
  done

  echo "  Unloading (capturing HMB stats) ..."
  unload_module
  sleep 1
  dmesg | grep "HMB cache stats:" | tail -1 > "$OUTDIR/hmb_stats_${PNAME}.txt"
  STATS=$(cat "$OUTDIR/hmb_stats_${PNAME}.txt" 2>/dev/null || echo "(no stats)")
  echo "  $STATS"

  [ "$POL" != "${POLICIES[-1]}" ] && sleep "$SLEEP"
done

unload_module 2>/dev/null || true
chown -R "${SUDO_USER:-$(logname 2>/dev/null || echo root)}:" "$OUTDIR" 2>/dev/null || true

ELAPSED=$(( $(date +%s) - START ))
echo ""
echo "========================================"
echo "Done in ${ELAPSED}s"
echo "Results: $OUTDIR"
echo "Plot:    python3 ${SCRIPT_DIR}/plot_policy.py $OUTDIR"
echo "========================================"
