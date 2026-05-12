#!/bin/bash
# verify_nvmev.sh - NVMeVirt verification script for x86-64 baseline
# Usage:
#   sudo ./verify_nvmev.sh           # auto-detect phase
#   sudo ./verify_nvmev.sh --phase=1 # setup GRUB (pre-reboot)
#   sudo ./verify_nvmev.sh --phase=2 # build & test (post-reboot)

set -eo pipefail

# ========== Configuration ==========
MEMMAP_START="56G"
MEMMAP_SIZE="4G"
MEMMAP_GRUB="memmap=4G\$56G"
ISOLCPUS="14,15"
CPUS_MODULE="14,15"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOUNT_POINT="/mnt/nvmev-test"
DD_SIZE_MB=256
NVMEV_VENDOR_ID="0x0c51"
# ====================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test results (indexed array for ordered output)
declare -a TEST_NAMES
declare -A TEST_RESULT
ARCH=$(uname -m)

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

record_result() {
    local test_name="$1"
    local result="$2"
    local detail="${3:-}"
    TEST_RESULT["$test_name"]="$result"
    TEST_NAMES+=("$test_name")
    if [ "$result" = "PASS" ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name ${detail:+($detail)}"
    elif [ "$result" = "SKIP" ]; then
        echo -e "  ${YELLOW}SKIP${NC}: $test_name ${detail:+($detail)}"
    else
        echo -e "  ${RED}FAIL${NC}: $test_name ${detail:+($detail)}"
    fi
}

# Cleanup on exit
cleanup() {
    echo ""
    log_info "Cleaning up..."
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null && log_info "Unmounted $MOUNT_POINT" || true
    fi
    if lsmod 2>/dev/null | grep -q "^nvmev "; then
        rmmod nvmev 2>/dev/null && log_info "Unloaded nvmev module" || true
    fi
}
trap cleanup EXIT

# =============================================
# Phase 1: GRUB Setup
# =============================================
phase1_setup() {
    echo "============================================="
    echo " NVMeVirt Verification - Phase 1 (Setup)"
    echo " Architecture: $ARCH"
    echo "============================================="
    echo ""

    # Preflight checks
    log_info "Preflight checks..."

    if [ "$ARCH" != "x86_64" ]; then
        log_warn "Not x86_64 architecture (detected: $ARCH). GRUB memmap is x86-specific."
        log_warn "On ARM, memory reservation may work differently. Continuing anyway."
    fi

    if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
        log_error "Kernel headers not found at /lib/modules/$(uname -r)/build"
        log_error "Install with: sudo apt install linux-headers-$(uname -r)"
        exit 1
    fi
    log_info "  Kernel headers: OK"

    if ! command -v nvme &>/dev/null; then
        log_error "nvme-cli not installed. Install with: sudo apt install nvme-cli"
        exit 1
    fi
    log_info "  nvme-cli: $(nvme --version 2>&1 | head -1)"

    if [ ! -f "$PROJECT_DIR/Kbuild" ]; then
        log_error "Kbuild not found in $PROJECT_DIR. Is this the nvmevirt source tree?"
        exit 1
    fi
    log_info "  Project dir: $PROJECT_DIR"

    # Check Kbuild target
    if grep -q "^CONFIG_NVMEVIRT_NVM := y" "$PROJECT_DIR/Kbuild"; then
        log_info "  Kbuild target: INTEL_OPTANE (NVM) - OK"
    else
        log_warn "Kbuild target is not INTEL_OPTANE (NVM). For simplest testing, edit Kbuild:"
        log_warn "  CONFIG_NVMEVIRT_NVM := y"
    fi

    # Check GRUB
    echo ""
    log_info "Checking GRUB configuration..."

    GRUB_FILE="/etc/default/grub"
    if [ ! -f "$GRUB_FILE" ]; then
        log_error "$GRUB_FILE not found"
        exit 1
    fi

    NEED_UPDATE=false

    if grep -q "memmap=4G.*56G" "$GRUB_FILE"; then
        log_info "  memmap parameter already present in GRUB"
    else
        log_info "  Adding memmap parameter to GRUB..."
        NEED_UPDATE=true
    fi

    if grep -q "isolcpus=14,15" "$GRUB_FILE"; then
        log_info "  isolcpus parameter already present in GRUB"
    else
        log_info "  Adding isolcpus parameter to GRUB..."
        NEED_UPDATE=true
    fi

    if [ "$NEED_UPDATE" = true ]; then
        # Backup GRUB
        BACKUP="$GRUB_FILE.nvmev-backup.$(date +%Y%m%d%H%M%S)"
        cp "$GRUB_FILE" "$BACKUP"
        log_info "  Backed up GRUB to $BACKUP"

        # Add parameters to GRUB_CMDLINE_LINUX
        sed -i '/^GRUB_CMDLINE_LINUX=/ s/"$/ memmap=4G\\\\\$56G isolcpus=14,15"/' "$GRUB_FILE"

        # Verify the edit
        if grep -q "memmap=4G.*56G" "$GRUB_FILE" && grep -q "isolcpus=14,15" "$GRUB_FILE"; then
            log_info "  GRUB_CMDLINE_LINUX updated successfully"
            grep "^GRUB_CMDLINE_LINUX=" "$GRUB_FILE"
        else
            log_error "Failed to update GRUB_CMDLINE_LINUX. Please edit manually:"
            log_error '  GRUB_CMDLINE_LINUX="memmap=4G\\\$56G isolcpus=14,15"'
            exit 1
        fi

        # Update GRUB
        log_info "Running update-grub..."
        update-grub
        log_info "GRUB updated"
    else
        log_info "GRUB already configured. No changes needed."
    fi

    # Verify in grub.cfg
    if grep -q "memmap=4G.*56G" /boot/grub/grub.cfg 2>/dev/null; then
        log_info "  Verified: memmap parameter in /boot/grub/grub.cfg"
    else
        log_warn "Could not verify memmap in /boot/grub/grub.cfg. Check manually."
    fi

    echo ""
    echo "============================================="
    echo " Phase 1 complete. Please reboot now."
    echo " After reboot, run: sudo $0 --phase=2"
    echo " (or just: sudo $0  -- it will auto-detect)"
    echo "============================================="
}

# =============================================
# Find the nvmevirt virtual device by vendor ID
# =============================================
find_nvmev_device() {
    # Method 1: Use nvme list (JSON output) to find device with vendor ID 0x0c51
    if command -v nvme &>/dev/null; then
        local json_output
        json_output=$(nvme list -o json 2>/dev/null || true)
        if [ -n "$json_output" ]; then
            local devpath
            devpath=$(echo "$json_output" | python3 -c "
import sys, json
try:
    devs = json.load(sys.stdin)['Devices']
    for d in devs:
        if d.get('VendorID', '').endswith('0c51'):
            print(d.get('DevicePath', ''))
            break
except: pass
" 2>/dev/null || true)
            if [ -n "$devpath" ] && [ -e "$devpath" ]; then
                echo "$devpath"
                return 0
            fi
        fi
    fi

    # Method 2: Iterate /dev/nvmeX and check identify-controller output
    for dev in /dev/nvme[0-9]; do
        [ -e "$dev" ] || continue
        local vid
        vid=$(nvme id-ctrl "$dev" 2>/dev/null \
            | grep -i "^vid" | head -1 \
            | sed 's/.*:.*\(0x[0-9a-fA-F]*\).*/\1/' || true)
        if [ "$vid" = "$NVMEV_VENDOR_ID" ]; then
            echo "$dev"
            return 0
        fi
    done

    # Method 3: Fallback - pick the highest numbered nvme device
    # (assumes nvme0 is the real SSD, virtual appears as nvme1+)
    local last_dev=""
    for dev in /dev/nvme[0-9]; do
        [ -e "$dev" ] || continue
        last_dev="$dev"
    done
    if [ -n "$last_dev" ]; then
        echo "$last_dev"
        return 0
    fi

    return 1
}

# =============================================
# Phase 2: Build & Test
# =============================================
phase2_test() {
    echo "============================================="
    echo " NVMeVirt Verification - Phase 2 (Test)"
    echo " Architecture: $ARCH"
    echo "============================================="
    echo ""

    local NVME_DEV=""
    local NVME_NS=""
    local CRITICAL_FAIL=false

    # ---- Test 1: Boot parameters ----
    echo "--- Test 1: Boot parameters ---"
    if grep -q "memmap=4G.*56G" /proc/cmdline 2>/dev/null; then
        record_result "GRUB memmap parameter" "PASS"
    else
        record_result "GRUB memmap parameter" "FAIL" "memmap=4G\$56G not found in /proc/cmdline"
        log_error "Run Phase 1 first: sudo $0 --phase=1"
        CRITICAL_FAIL=true
    fi

    if grep -q "isolcpus=14,15" /proc/cmdline 2>/dev/null; then
        record_result "GRUB isolcpus parameter" "PASS"
    else
        record_result "GRUB isolcpus parameter" "FAIL" "isolcpus=14,15 not found in /proc/cmdline"
    fi

    if [ "$CRITICAL_FAIL" = true ]; then
        log_error "Critical boot parameters missing. Cannot continue."
        print_summary
        exit 1
    fi
    echo ""

    # ---- Test 2: Build kernel module ----
    echo "--- Test 2: Module build ---"
    cd "$PROJECT_DIR"
    make clean >/dev/null 2>&1 || true
    local BUILD_LOG="/tmp/nvmev_build.log"
    if make >"$BUILD_LOG" 2>&1; then
        if [ -f "nvmev.ko" ]; then
            record_result "Module build" "PASS"
        else
            record_result "Module build" "FAIL" "make succeeded but nvmev.ko not found"
            CRITICAL_FAIL=true
        fi
    else
        record_result "Module build" "FAIL" "see $BUILD_LOG"
        tail -20 "$BUILD_LOG"
        CRITICAL_FAIL=true
    fi

    if [ "$CRITICAL_FAIL" = true ]; then
        log_error "Module build failed. Cannot continue."
        print_summary
        exit 1
    fi
    echo ""

    # ---- Test 3: Load module ----
    echo "--- Test 3: Module load (insmod) ---"
    if lsmod 2>/dev/null | grep -q "^nvmev "; then
        log_info "nvmev module already loaded, skipping insmod"
        record_result "Module load (insmod)" "PASS" "already loaded"
    else
        if insmod ./nvmev.ko memmap_start="$MEMMAP_START" memmap_size="$MEMMAP_SIZE" cpus="$CPUS_MODULE" 2>&1; then
            sleep 2
            record_result "Module load (insmod)" "PASS"
        else
            record_result "Module load (insmod)" "FAIL"
            log_error "insmod failed. Check dmesg for details."
            log_error "If IOMMU/MSI-X panic, add intremap=off to GRUB_CMDLINE_LINUX and reboot."
            dmesg | tail -20 || true
            CRITICAL_FAIL=true
        fi
    fi

    if [ "$CRITICAL_FAIL" = true ]; then
        print_summary
        exit 1
    fi

    # Check dmesg for success
    if dmesg 2>/dev/null | tail -30 | grep -q "Successfully created Virtual NVMe device"; then
        log_info "dmesg confirms: Virtual NVMe device created"
    else
        log_warn "Could not find success message in dmesg"
    fi
    echo ""

    # ---- Test 4: Discover device ----
    echo "--- Test 4: Device discovery ---"
    NVME_DEV=$(find_nvmev_device || true)

    if [ -n "$NVME_DEV" ] && [ -e "$NVME_DEV" ]; then
        # Find namespace device
        for ns in "${NVME_DEV}n"[0-9]; do
            if [ -e "$ns" ]; then
                NVME_NS="$ns"
                break
            fi
        done
        record_result "Device discovery ($NVME_DEV)" "PASS"
        log_info "  Controller: $NVME_DEV"
        log_info "  Namespace:  $NVME_NS"
    else
        record_result "Device discovery" "FAIL" "No virtual NVMe device found"
        CRITICAL_FAIL=true
    fi

    if [ "$CRITICAL_FAIL" = true ]; then
        log_error "Device not found. Check: ls /dev/nvme* and dmesg"
        print_summary
        exit 1
    fi
    echo ""

    # ---- Test 5: Identify Controller ----
    echo "--- Test 5: NVMe Identify Controller ---"
    local identify_ctrl_out
    identify_ctrl_out=$(nvme id-ctrl "$NVME_DEV" 2>&1 || true)
    # Check output content instead of exit code (glibc ld.so bug can cause exit 127)
    if echo "$identify_ctrl_out" | grep -q "^vid"; then
        local vid sn mn
        vid=$(echo "$identify_ctrl_out" | grep -i "^vid" | head -1 | awk '{print $NF}' || true)
        sn=$(echo "$identify_ctrl_out" | grep -i "^sn" | head -1 | sed 's/^sn[^:]*: *//' || true)
        mn=$(echo "$identify_ctrl_out" | grep -i "^mn" | head -1 | sed 's/^mn[^:]*: *//' || true)
        record_result "NVMe Identify Controller" "PASS" "vid=$vid sn=$sn mn=$mn"
    else
        record_result "NVMe Identify Controller" "FAIL" "no vid field in output"
    fi
    echo ""

    # ---- Test 6: Identify Namespace ----
    echo "--- Test 6: NVMe Identify Namespace ---"
    local identify_ns_out
    identify_ns_out=$(nvme id-ns "$NVME_NS" 2>&1 || true)
    if echo "$identify_ns_out" | grep -q "^nsze"; then
        local nsze
        nsze=$(echo "$identify_ns_out" | grep -i "^nsze" | head -1 | awk '{print $NF}' || true)
        record_result "NVMe Identify Namespace" "PASS" "nsze=$nsze"
    else
        record_result "NVMe Identify Namespace" "FAIL" "no nsze field in output"
    fi
    echo ""

    # ---- Test 7: SMART Log ----
    echo "--- Test 7: NVMe SMART Log ---"
    local smart_out
    smart_out=$(nvme smart-log "$NVME_DEV" 2>&1) && rc=$? || rc=$?
    if [ "$rc" -eq 0 ]; then
        record_result "NVMe SMART Log" "PASS"
    else
        record_result "NVMe SMART Log" "FAIL" "exit code $rc"
        echo "$smart_out" | tail -5
    fi
    echo ""

    # ---- Test 8: Create ext4 filesystem ----
    echo "--- Test 8: ext4 filesystem creation ---"
    if mkfs.ext4 -F "$NVME_NS" >/dev/null 2>&1; then
        record_result "ext4 filesystem creation" "PASS"
    else
        record_result "ext4 filesystem creation" "FAIL"
        CRITICAL_FAIL=true
    fi
    echo ""

    if [ "$CRITICAL_FAIL" = true ]; then
        log_error "Filesystem creation failed. Cannot continue with I/O tests."
        print_summary
        exit 1
    fi

    # ---- Test 9: Mount ----
    echo "--- Test 9: Mount filesystem ---"
    mkdir -p "$MOUNT_POINT"
    if mount "$NVME_NS" "$MOUNT_POINT" 2>&1; then
        record_result "Mount filesystem" "PASS"
    else
        record_result "Mount filesystem" "FAIL"
        CRITICAL_FAIL=true
    fi
    echo ""

    if [ "$CRITICAL_FAIL" = true ]; then
        log_error "Mount failed. Cannot continue with I/O tests."
        print_summary
        exit 1
    fi

    # ---- Test 10: Write/Read data integrity ----
    echo "--- Test 10: Write/Read data integrity ---"
    TEST_CONTENT="NVMeVirt verification test $(date -Iseconds) - PASS"
    echo "$TEST_CONTENT" > "$MOUNT_POINT/verify_test.txt"
    sync
    READ_CONTENT=$(cat "$MOUNT_POINT/verify_test.txt")

    if [ "$TEST_CONTENT" = "$READ_CONTENT" ]; then
        record_result "Write/Read data integrity" "PASS"
    else
        record_result "Write/Read data integrity" "FAIL" "content mismatch"
        log_error "  Expected: $TEST_CONTENT"
        log_error "  Got:      $READ_CONTENT"
    fi
    echo ""

    # ---- Test 11: dd sequential write ----
    echo "--- Test 11: dd sequential write (${DD_SIZE_MB}MiB) ---"
    DD_WRITE_OUT=$(dd if=/dev/zero of="$MOUNT_POINT/dd_test.bin" bs=1M count="$DD_SIZE_MB" oflag=direct 2>&1 || true)
    if echo "$DD_WRITE_OUT" | grep -q "bytes.*copied"; then
        DD_WRITE_SPEED=$(echo "$DD_WRITE_OUT" | grep -oP '[\d.]+ [KMG]?B/s' | tail -1)
        record_result "dd sequential write" "PASS" "$DD_WRITE_SPEED"
    else
        record_result "dd sequential write" "FAIL"
    fi
    echo ""

    # ---- Test 12: dd sequential read ----
    echo "--- Test 12: dd sequential read (${DD_SIZE_MB}MiB) ---"
    DD_READ_OUT=$(dd if="$MOUNT_POINT/dd_test.bin" of=/dev/null bs=1M count="$DD_SIZE_MB" iflag=direct 2>&1 || true)
    if echo "$DD_READ_OUT" | grep -q "bytes.*copied"; then
        DD_READ_SPEED=$(echo "$DD_READ_OUT" | grep -oP '[\d.]+ [KMG]?B/s' | tail -1)
        record_result "dd sequential read" "PASS" "$DD_READ_SPEED"
    else
        record_result "dd sequential read" "FAIL"
    fi
    echo ""

    # ---- Test 13: /proc/nvmev/ interface ----
    echo "--- Test 13: /proc/nvmev/ interface ---"
    PROC_OK=true
    [ -d "/proc/nvmev" ] || PROC_OK=false
    if [ -f "/proc/nvmev/read_times" ] && cat /proc/nvmev/read_times >/dev/null 2>&1; then
        :
    else
        PROC_OK=false
    fi
    if [ -f "/proc/nvmev/write_times" ] && cat /proc/nvmev/write_times >/dev/null 2>&1; then
        :
    else
        PROC_OK=false
    fi
    if [ -f "/proc/nvmev/stat" ] && cat /proc/nvmev/stat >/dev/null 2>&1; then
        :
    else
        PROC_OK=false
    fi

    if [ "$PROC_OK" = true ]; then
        record_result "/proc/nvmev/ interface" "PASS"
        log_info "  read_times:  $(cat /proc/nvmev/read_times 2>/dev/null)"
        log_info "  write_times: $(cat /proc/nvmev/write_times 2>/dev/null)"
    else
        record_result "/proc/nvmev/ interface" "FAIL"
    fi
    echo ""

    # ---- Cleanup: unmount ----
    echo "--- Cleanup ---"
    rm -f "$MOUNT_POINT/verify_test.txt" "$MOUNT_POINT/dd_test.bin"
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT" && log_info "Unmounted $MOUNT_POINT" || log_warn "Failed to unmount"
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    echo ""

    # ---- Test 14: Module unload ----
    echo "--- Test 14: Module unload (rmmod) ---"
    if rmmod nvmev 2>&1; then
        sleep 1
        if ! lsmod 2>/dev/null | grep -q "^nvmev "; then
            record_result "Module unload (rmmod)" "PASS"
        else
            record_result "Module unload (rmmod)" "FAIL" "module still loaded after rmmod"
        fi
    else
        record_result "Module unload (rmmod)" "FAIL"
    fi
    echo ""

    # ---- Print summary ----
    print_summary
}

print_summary() {
    local TOTAL=0 PASS=0 FAIL=0 SKIP=0
    echo ""
    echo "============================================================"
    echo " NVMeVirt Verification Summary ($ARCH)"
    echo "============================================================"

    for key in "${TEST_NAMES[@]}"; do
        local val="${TEST_RESULT[$key]}"
        TOTAL=$((TOTAL + 1))
        case "$val" in
            PASS) PASS=$((PASS + 1)) ;;
            FAIL) FAIL=$((FAIL + 1)) ;;
            SKIP) SKIP=$((SKIP + 1)) ;;
        esac
        printf "  %-35s %s\n" "$key" "$val"
    done

    echo "------------------------------------------------------------"
    if [ "$FAIL" -eq 0 ]; then
        echo -e "  OVERALL: ${GREEN}PASS${NC} ($PASS/$TOTAL passed)"
    else
        echo -e "  OVERALL: ${RED}FAIL${NC} ($PASS/$TOTAL passed, $FAIL failed)"
    fi
    echo "============================================================"
}

# =============================================
# Main
# =============================================
PHASE="auto"

for arg in "$@"; do
    case "$arg" in
        --phase=1) PHASE=1 ;;
        --phase=2) PHASE=2 ;;
        --phase=auto) PHASE=auto ;;
        *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Auto-detect phase
if [ "$PHASE" = "auto" ]; then
    if grep -q "memmap=4G.*56G" /proc/cmdline 2>/dev/null; then
        PHASE=2
        log_info "Auto-detected Phase 2 (boot parameters present)"
    else
        PHASE=1
        log_info "Auto-detected Phase 1 (boot parameters not present)"
    fi
fi

case "$PHASE" in
    1) phase1_setup ;;
    2) phase2_test ;;
esac
