#!/bin/bash
# verify_nvmev_arm64.sh - NVMeVirt verification script for ARM64
# Usage:
#   sudo ./verify_nvmev_arm64.sh --phase=1
#   sudo ./verify_nvmev_arm64.sh --phase=2
#   sudo ./verify_nvmev_arm64.sh --restore-boot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTLINUX_CONF="${EXTLINUX_CONF:-/boot/extlinux/extlinux.conf}"
STATE_FILE="${STATE_FILE:-/boot/nvmev-arm64.env}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nvmev-test}"
NVMEV_VENDOR_ID="${NVMEV_VENDOR_ID:-0x0c51}"
DEFAULT_MEMMAP_SIZE="${MEMMAP_SIZE:-1G}"
DD_SIZE_MB="${DD_SIZE_MB:-256}"
NVMEV_ARM64_IOMMU_PASSTHROUGH="${NVMEV_ARM64_IOMMU_PASSTHROUGH:-${IOMMU_PASSTHROUGH:-0}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

declare -a TEST_NAMES
declare -A TEST_RESULT

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

record_result() {
    local name="$1" result="$2" detail="${3:-}"
    TEST_NAMES+=("$name")
    TEST_RESULT["$name"]="$result"
    case "$result" in
        PASS) echo -e "  ${GREEN}PASS${NC}: $name ${detail:+($detail)}" ;;
        SKIP) echo -e "  ${YELLOW}SKIP${NC}: $name ${detail:+($detail)}" ;;
        *) echo -e "  ${RED}FAIL${NC}: $name ${detail:+($detail)}" ;;
    esac
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Missing required command: $cmd"
        exit 1
    fi
}

is_truthy() {
    case "${1:-0}" in
        1|y|Y|yes|YES|true|TRUE|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

cmdline_has_global_iommu_passthrough() {
    grep -Eq '(^| )(iommu\.passthrough=1|iommu=pt)( |$)' /proc/cmdline
}

normalized_vendor_id() {
    printf '0x%04x' "$((NVMEV_VENDOR_ID))"
}

vendor_id_regex() {
    local hex
    hex="${NVMEV_VENDOR_ID#0x}"
    hex="${hex#0X}"
    hex="$(printf '%s' "$hex" | tr 'A-F' 'a-f' | sed 's/^0*//')"
    [ -n "$hex" ] || hex=0
    printf '0x0*%s' "$hex"
}

parse_bytes() {
    python3 - "$1" <<'PY'
import re, sys
s = sys.argv[1].strip()
m = re.fullmatch(r'(0x[0-9a-fA-F]+|\d+)([KMGTP]?)', s)
if not m:
    raise SystemExit(f"invalid size/address: {s}")
v = int(m.group(1), 0)
scale = {'': 1, 'K': 1 << 10, 'M': 1 << 20, 'G': 1 << 30, 'T': 1 << 40, 'P': 1 << 50}
print(v * scale[m.group(2)])
PY
}

choose_cpus() {
    if [ -n "${CPUS_MODULE:-}" ]; then
        echo "$CPUS_MODULE"
        return
    fi

    python3 - <<'PY'
import pathlib
s = pathlib.Path('/sys/devices/system/cpu/online').read_text().strip()
cpus = []
for part in s.split(','):
    if '-' in part:
        a, b = map(int, part.split('-', 1))
        cpus.extend(range(a, b + 1))
    elif part:
        cpus.append(int(part))
if len(cpus) < 2:
    raise SystemExit('need at least two online CPUs')
print(','.join(map(str, cpus[-2:])))
PY
}

choose_mem_start() {
    local size_bytes="$1"

    if [ -n "${MEMMAP_START:-}" ]; then
        parse_bytes "$MEMMAP_START"
        return
    fi

    python3 - "$size_bytes" <<'PY'
import pathlib, re, struct, sys
size = int(sys.argv[1])
align = 1 << 20
ram = []
children = []
current_ram = None
for line in open('/proc/iomem'):
    m = re.match(r'(\s*)([0-9a-fA-F]+)-([0-9a-fA-F]+) : (.*)$', line.rstrip())
    if not m:
        continue
    indent, name = len(m.group(1)), m.group(4)
    start, end = int(m.group(2), 16), int(m.group(3), 16) + 1
    if name == 'System RAM':
        current_ram = (start, end, indent)
        ram.append((start, end))
        continue
    if current_ram and indent > current_ram[2]:
        ram_start, ram_end, _ = current_ram
        if start < ram_end and end > ram_start:
            children.append((max(start, ram_start), min(end, ram_end)))

free = []
for start, end in ram:
    spans = [(start, end)]
    for cstart, cend in children:
        new_spans = []
        for s, e in spans:
            if cend <= s or cstart >= e:
                new_spans.append((s, e))
            else:
                if s < cstart:
                    new_spans.append((s, cstart))
                if cend < e:
                    new_spans.append((cend, e))
        spans = new_spans
    free.extend(spans)

def prop_cells(path):
    data = path.read_bytes()
    return [x[0] for x in struct.iter_unpack('>I', data)]

def cells_to_int(cells):
    v = 0
    for c in cells:
        v = (v << 32) | c
    return v

def live_dt_memory_ranges():
    base = pathlib.Path('/sys/firmware/devicetree/base')
    try:
        ac = cells_to_int(prop_cells(base / '#address-cells'))
    except FileNotFoundError:
        ac = 2
    try:
        sc = cells_to_int(prop_cells(base / '#size-cells'))
    except FileNotFoundError:
        sc = 1

    ranges = []
    for node in base.glob('memory*'):
        reg = node / 'reg'
        if not reg.exists():
            continue
        cells = prop_cells(reg)
        step = ac + sc
        for i in range(0, len(cells), step):
            addr = cells_to_int(cells[i:i + ac])
            rsize = cells_to_int(cells[i + ac:i + step])
            if rsize:
                ranges.append((addr, addr + rsize))
    return ranges

dtmem = live_dt_memory_ranges()
if dtmem:
    restricted = []
    for s, e in free:
        for ds, de in dtmem:
            isect = (max(s, ds), min(e, de))
            if isect[0] < isect[1]:
                restricted.append(isect)
    free = restricted

best = None
for start, end in free:
    if end <= start or end - start < size:
        continue
    cand = (end - size) & ~(align - 1)
    if cand < start:
        cand = ((start + align - 1) // align) * align
    if cand < start or cand + size > end:
        continue
    if best is None or cand > best:
        best = cand
if best is None or best == 0:
    raise SystemExit('could not auto-select an unused System RAM subrange; set MEMMAP_START and MEMMAP_SIZE')
print(best)
PY
}

active_fdt() {
    local conf="${1:-$EXTLINUX_CONF}"
    python3 - "$conf" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
default = None
current = None
entries = {}
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        continue
    parts = stripped.split(None, 1)
    key = parts[0].upper()
    val = parts[1].strip() if len(parts) > 1 else ''
    if key == 'DEFAULT':
        default = val
    elif key == 'LABEL':
        current = val
        entries.setdefault(current, {})
    elif current and key == 'FDT':
        entries[current]['fdt'] = val

labels = [label for label, entry in entries.items() if 'fdt' in entry]
if default and default in entries and 'fdt' in entries[default]:
    print(entries[default]['fdt'])
elif labels:
    print(entries[labels[0]]['fdt'])
else:
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        parts = stripped.split(None, 1)
        if parts[0].upper() == 'FDT' and len(parts) > 1:
            print(parts[1].strip())
            break
PY
}

make_overlay() {
    local out_dts="$1" start="$2" size="$3" addr_cells="$4" size_cells="$5"
    python3 - "$out_dts" "$start" "$size" "$addr_cells" "$size_cells" <<'PY'
import sys
out, start, size, ac, sc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
def cells(v, n):
    return ' '.join(f'0x{(v >> (32 * i)) & 0xffffffff:08x}' for i in range(n - 1, -1, -1))
def unit_addr(v, n):
    return ','.join(f'{(v >> (32 * i)) & 0xffffffff:x}' for i in range(n - 1, -1, -1))
with open(out, 'w') as f:
    f.write('/dts-v1/;\n/plugin/;\n\n')
    f.write('/ {\n')
    f.write('\tfragment@0 {\n')
    f.write('\t\ttarget-path = "/reserved-memory";\n')
    f.write('\t\t__overlay__ {\n')
    f.write(f'\t\t\t#address-cells = <{ac}>;\n')
    f.write(f'\t\t\t#size-cells = <{sc}>;\n')
    f.write('\t\t\tranges;\n\n')
    f.write(f'\t\t\tnvmevirt@{unit_addr(start, ac)} {{\n')
    f.write('\t\t\t\tcompatible = "nvmevirt,reserved-memory";\n')
    f.write('\t\t\t\tstatus = "okay";\n')
    f.write('\t\t\t\tno-map;\n')
    f.write(f'\t\t\t\treg = <{cells(start, ac)} {cells(size, sc)}>;\n')
    f.write('\t\t\t};\n')
    f.write('\t\t};\n')
    f.write('\t};\n')
    f.write('};\n')
PY
}

patch_extlinux() {
    local patched_dtb="$1" cpus="$2" backup="$3" iommu_passthrough="$4"
    [ -f "$backup" ] || cp "$EXTLINUX_CONF" "$backup"
    python3 - "$EXTLINUX_CONF" "$patched_dtb" "$cpus" "$iommu_passthrough" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
dtb = sys.argv[2]
cpus = sys.argv[3]
iommu_passthrough = sys.argv[4] == '1'
lines = path.read_text().splitlines()
default = None
labels = []
for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        continue
    parts = stripped.split(None, 1)
    key = parts[0].upper()
    val = parts[1].strip() if len(parts) > 1 else ''
    if key == 'DEFAULT':
        default = val
    elif key == 'LABEL':
        labels.append(val)
target_label = default if default in labels else (labels[0] if labels else None)
current_label = None
fdt_done = False
append_done = False
out = []
for line in lines:
    stripped = line.lstrip()
    indent = line[:len(line) - len(stripped)]
    parts = stripped.split(None, 1)
    key = parts[0].upper() if parts else ''
    if not stripped.startswith('#') and key == 'LABEL':
        current_label = parts[1].strip() if len(parts) > 1 else ''
    in_target = target_label is None or current_label == target_label
    if not stripped.startswith('#') and key == 'FDT' and in_target and not fdt_done:
        out.append(f'{indent}FDT {dtb}')
        fdt_done = True
        continue
    if not stripped.startswith('#') and key == 'APPEND' and in_target and not append_done:
        rest = stripped[len('APPEND'):].strip()
        toks = [
            t for t in rest.split()
            if not t.startswith('isolcpus=')
            and not t.startswith('iommu.passthrough=')
            and t != 'iommu=pt'
        ]
        toks.append(f'isolcpus={cpus}')
        if iommu_passthrough:
            toks.append('iommu.passthrough=1')
        out.append(f'{indent}APPEND {" ".join(toks)}')
        append_done = True
        continue
    out.append(line)
if not fdt_done:
    raise SystemExit('no active FDT line found in extlinux.conf')
if not append_done:
    raise SystemExit('no active APPEND line found in extlinux.conf')
path.write_text('\n'.join(out) + '\n')
PY
}

write_state() {
    local start="$1" size="$2" cpus="$3" patched_dtb="$4" patched_dtb_boot="$5" backup="$6" iommu_passthrough="$7"
    {
        echo "MEMMAP_START_BYTES=$start"
        echo "MEMMAP_SIZE_BYTES=$size"
        echo "CPUS_MODULE=$cpus"
        echo "PATCHED_DTB=$patched_dtb"
        echo "PATCHED_DTB_BOOT=$patched_dtb_boot"
        echo "BACKUP_EXTLINUX=$backup"
        echo "IOMMU_PASSTHROUGH=$iommu_passthrough"
    } > "$STATE_FILE"
}

phase1_setup() {
    require_root
    [ "$(uname -m)" = "aarch64" ] || { log_error "This script is for aarch64 only"; exit 1; }
    [ -d "/lib/modules/$(uname -r)/build" ] || { log_error "Kernel headers missing"; exit 1; }
    require_cmd python3
    require_cmd dtc
    require_cmd fdtoverlay
    require_cmd fdtget
    require_cmd nvme
    [ -f "$EXTLINUX_CONF" ] || { log_error "Missing $EXTLINUX_CONF"; exit 1; }

    local cpus size_bytes start_bytes fdt_boot fdt_linux patched_linux patched_boot backup old_backup source_extlinux iommu_passthrough
    local tmpd overlay_dts overlay_dtb ac sc
    cpus="$(choose_cpus)"
    size_bytes="$(parse_bytes "$DEFAULT_MEMMAP_SIZE")"
    start_bytes="$(choose_mem_start "$size_bytes")"
    if is_truthy "$NVMEV_ARM64_IOMMU_PASSTHROUGH"; then
        iommu_passthrough=1
    else
        iommu_passthrough=0
    fi

    backup="${EXTLINUX_CONF}.nvmev-arm64-backup.$(date +%Y%m%d%H%M%S)"
    source_extlinux="$EXTLINUX_CONF"
    if [ -f "$STATE_FILE" ]; then
        old_backup="$(awk -F= '$1 == "BACKUP_EXTLINUX" { print $2; exit }' "$STATE_FILE")"
        if [ -n "$old_backup" ] && [ -f "$old_backup" ]; then
            backup="$old_backup"
            source_extlinux="$old_backup"
        fi
    fi

    fdt_boot="$(active_fdt "$source_extlinux")"
    [ -n "$fdt_boot" ] || { log_error "Could not find active FDT in $source_extlinux"; exit 1; }
    if [[ "$fdt_boot" = /* ]]; then
        fdt_linux="$fdt_boot"
        if [ ! -f "$fdt_linux" ] && [ -f "/boot/${fdt_boot#/}" ]; then
            fdt_linux="/boot/${fdt_boot#/}"
        fi
    else
        fdt_linux="/boot/${fdt_boot#/}"
    fi
    [ -f "$fdt_linux" ] || { log_error "Active FDT not found: $fdt_linux"; exit 1; }

    if [ -n "${PATCHED_DTB:-}" ]; then
        patched_linux="$PATCHED_DTB"
        patched_boot="${PATCHED_DTB_BOOT:-$PATCHED_DTB}"
    else
        patched_linux="${fdt_linux%.dtb}-nvmev.dtb"
        if [[ "$fdt_boot" = *.dtb ]]; then
            patched_boot="${fdt_boot%.dtb}-nvmev.dtb"
        else
            patched_boot="$patched_linux"
        fi
    fi

    ac="$(fdtget -t d "$fdt_linux" /reserved-memory '#address-cells' 2>/dev/null || fdtget -t d "$fdt_linux" / '#address-cells' 2>/dev/null || echo 2)"
    sc="$(fdtget -t d "$fdt_linux" /reserved-memory '#size-cells' 2>/dev/null || fdtget -t d "$fdt_linux" / '#size-cells' 2>/dev/null || echo 2)"

    tmpd="$(mktemp -d)"
    overlay_dts="$tmpd/nvmevirt-reserved-memory.dts"
    overlay_dtb="$tmpd/nvmevirt-reserved-memory.dtbo"
    make_overlay "$overlay_dts" "$start_bytes" "$size_bytes" "$ac" "$sc"
    dtc -@ -I dts -O dtb -o "$overlay_dtb" "$overlay_dts"
    fdtoverlay -i "$fdt_linux" -o "$patched_linux" "$overlay_dtb"
    rm -rf "$tmpd"

    patch_extlinux "$patched_boot" "$cpus" "$backup" "$iommu_passthrough"
    write_state "$start_bytes" "$size_bytes" "$cpus" "$patched_linux" "$patched_boot" "$backup" "$iommu_passthrough"

    log_info "Patched DTB: $patched_linux"
    log_info "extlinux FDT path: $patched_boot"
    log_info "extlinux backup: $backup"
    log_info "memmap_start=$start_bytes memmap_size=$size_bytes cpus=$cpus"
    if [ "$iommu_passthrough" = 1 ]; then
        log_info "Added boot params: isolcpus=$cpus iommu.passthrough=1"
    else
        log_info "Added boot params: isolcpus=$cpus"
        log_info "Global IOMMU passthrough left disabled"
    fi
    echo "Reboot, then run: sudo $0 --phase=2"
}

restore_boot() {
    require_root
    [ -f "$STATE_FILE" ] || { log_error "Missing state file: $STATE_FILE"; exit 1; }
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    [ -n "${BACKUP_EXTLINUX:-}" ] && [ -f "$BACKUP_EXTLINUX" ] || {
        log_error "No extlinux backup recorded in $STATE_FILE"
        exit 1
    }
    cp "$BACKUP_EXTLINUX" "$EXTLINUX_CONF"
    log_info "Restored $EXTLINUX_CONF from $BACKUP_EXTLINUX"
}

cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    if lsmod 2>/dev/null | grep -q "^nvmev "; then
        rmmod nvmev 2>/dev/null || true
    fi
}

find_nvmev_device() {
    local dev ctrl vendor vendor_re
    vendor_re="$(vendor_id_regex)"
    for dev in /dev/nvme[0-9]*; do
        [ -e "$dev" ] || continue
        [[ "$dev" =~ ^/dev/nvme[0-9]+$ ]] || continue
        ctrl="$(basename "$dev")"
        vendor="$(cat "/sys/class/nvme/$ctrl/device/vendor" 2>/dev/null || true)"
        if [ "$vendor" = "$NVMEV_VENDOR_ID" ]; then
            echo "$dev"
            return 0
        fi
    done

    for dev in /dev/nvme[0-9]*; do
        [ -e "$dev" ] || continue
        [[ "$dev" =~ ^/dev/nvme[0-9]+$ ]] || continue
        if timeout 3s nvme id-ctrl "$dev" 2>/dev/null | grep -Eqi "^vid.*$vendor_re"; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

wait_for_nvmev_device() {
    local i dev
    for i in $(seq 1 15); do
        dev="$(find_nvmev_device || true)"
        if [ -n "$dev" ]; then
            echo "$dev"
            return 0
        fi
        sleep 1
    done
    return 1
}

find_nvmev_pci_device() {
    local dev vendor wanted
    wanted="$(normalized_vendor_id)"
    for dev in /sys/bus/pci/devices/*; do
        [ -r "$dev/vendor" ] || continue
        vendor="$(tr 'A-F' 'a-f' < "$dev/vendor")"
        if [ "$vendor" = "$wanted" ]; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

check_nvmev_iommu_group() {
    local pci_dev="$1" group group_type group_id

    if [ ! -L "$pci_dev/iommu_group" ]; then
        record_result "NVMeVirt SMMU assignment" PASS "no iommu_group; direct DMA expected"
        return 0
    fi

    group="$(readlink -f "$pci_dev/iommu_group")"
    group_id="$(basename "$group")"
    group_type="$(cat "$group/type" 2>/dev/null || echo unknown)"

    if [ "${IOMMU_PASSTHROUGH:-0}" = 1 ]; then
        record_result "NVMeVirt SMMU assignment" PASS "group $group_id type=$group_type; global passthrough requested"
        return 0
    fi

    case "$group_type" in
        identity|unmanaged)
            record_result "NVMeVirt SMMU assignment" PASS "group $group_id type=$group_type"
            return 0
            ;;
        *)
            record_result "NVMeVirt SMMU assignment" FAIL "group $group_id type=$group_type; PRP may be IOVA"
            return 1
            ;;
    esac
}

dt_reserved_memory_covers() {
    local start="$1" size="$2"
    python3 - "$start" "$size" <<'PY'
import pathlib, struct, sys
start, size = int(sys.argv[1]), int(sys.argv[2])
end = start + size
base = pathlib.Path('/sys/firmware/devicetree/base/reserved-memory')
def prop_cells(path):
    data = path.read_bytes()
    return [x[0] for x in struct.iter_unpack('>I', data)]
def cells_to_int(cells):
    v = 0
    for c in cells:
        v = (v << 32) | c
    return v
try:
    ac = cells_to_int(prop_cells(base / '#address-cells'))
    sc = cells_to_int(prop_cells(base / '#size-cells'))
except FileNotFoundError:
    raise SystemExit(1)
for node in base.glob('nvmevirt@*'):
    reg = node / 'reg'
    if not reg.exists() or not (node / 'no-map').exists():
        continue
    cells = prop_cells(reg)
    step = ac + sc
    for i in range(0, len(cells), step):
        addr = cells_to_int(cells[i:i + ac])
        rsize = cells_to_int(cells[i + ac:i + step])
        if addr <= start and end <= addr + rsize:
            raise SystemExit(0)
raise SystemExit(1)
PY
}

dt_memory_covers() {
    local start="$1" size="$2"
    python3 - "$start" "$size" <<'PY'
import pathlib, struct, sys
start, size = int(sys.argv[1]), int(sys.argv[2])
end = start + size
base = pathlib.Path('/sys/firmware/devicetree/base')
def prop_cells(path):
    data = path.read_bytes()
    return [x[0] for x in struct.iter_unpack('>I', data)]
def cells_to_int(cells):
    v = 0
    for c in cells:
        v = (v << 32) | c
    return v
try:
    ac = cells_to_int(prop_cells(base / '#address-cells'))
except FileNotFoundError:
    ac = 2
try:
    sc = cells_to_int(prop_cells(base / '#size-cells'))
except FileNotFoundError:
    sc = 1
for node in base.glob('memory*'):
    reg = node / 'reg'
    if not reg.exists():
        continue
    cells = prop_cells(reg)
    step = ac + sc
    for i in range(0, len(cells), step):
        addr = cells_to_int(cells[i:i + ac])
        rsize = cells_to_int(cells[i + ac:i + step])
        if addr <= start and end <= addr + rsize:
            raise SystemExit(0)
raise SystemExit(1)
PY
}

iomem_system_ram_intersects() {
    local start="$1" size="$2"
    python3 - "$start" "$size" <<'PY'
import re, sys
start, size = int(sys.argv[1]), int(sys.argv[2])
end = start + size
for line in open('/proc/iomem'):
    m = re.match(r'\s*([0-9a-fA-F]+)-([0-9a-fA-F]+) : System RAM$', line)
    if not m:
        continue
    rstart, rend = int(m.group(1), 16), int(m.group(2), 16) + 1
    if start < rend and end > rstart:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

show_hmb_stats() {
    local line sram_hits hmb_hits nand_fetches avg_l2p_lat total

    # hmb_cache_fini() logs this line to dmesg on rmmod
    line="$(dmesg 2>/dev/null | grep "HMB cache stats:" | tail -1)"
    if [ -z "$line" ]; then
        log_warn "HMB cache stats not found in dmesg (HMB cache may be disabled or not exercised)"
        return
    fi

    sram_hits="$(echo "$line"    | sed -n 's/.*SRAM hits=\([0-9]*\).*/\1/p')"
    hmb_hits="$(echo "$line"     | sed -n 's/.*HMB hits=\([0-9]*\).*/\1/p')"
    nand_fetches="$(echo "$line" | sed -n 's/.*NAND fetches=\([0-9]*\).*/\1/p')"
    avg_l2p_lat="$(echo "$line"  | sed -n 's/.*avg_l2p_lat_ns=\([0-9]*\).*/\1/p')"

    sram_hits="${sram_hits:-0}"
    hmb_hits="${hmb_hits:-0}"
    nand_fetches="${nand_fetches:-0}"
    avg_l2p_lat="${avg_l2p_lat:-0}"
    total=$(( sram_hits + hmb_hits + nand_fetches ))

    echo ""
    echo "============================================================"
    echo " HMB Cache Statistics"
    echo "============================================================"
    if [ "$total" -eq 0 ]; then
        echo "  No L2P lookups recorded (HMB cache not exercised)"
    else
        printf "  %-22s %10d  (%d%%)\n" "SRAM hits:"    "$sram_hits"    $(( sram_hits    * 100 / total ))
        printf "  %-22s %10d  (%d%%)\n" "HMB hits:"     "$hmb_hits"     $(( hmb_hits     * 100 / total ))
        printf "  %-22s %10d  (%d%%)\n" "NAND fetches:" "$nand_fetches" $(( nand_fetches * 100 / total ))
        echo "  --------------------------------------------------"
        printf "  %-22s %10d\n"  "Total L2P lookups:" "$total"
        printf "  %-22s %9d%%\n" "Cache hit rate:"    $(( (sram_hits + hmb_hits) * 100 / total ))
        printf "  %-22s %9d%%\n" "NAND miss rate:"    $(( nand_fetches * 100 / total ))
        printf "  %-22s %9d ns\n" "Avg L2P lat/IO:"   "$avg_l2p_lat"
    fi
    echo "============================================================"
}

print_summary() {
    local total=0 pass=0 fail=0 key val
    echo ""
    echo "============================================================"
    echo " NVMeVirt ARM64 Verification Summary"
    echo "============================================================"
    for key in "${TEST_NAMES[@]}"; do
        val="${TEST_RESULT[$key]}"
        total=$((total + 1))
        [ "$val" = PASS ] && pass=$((pass + 1))
        [ "$val" = FAIL ] && fail=$((fail + 1))
        printf "  %-35s %s\n" "$key" "$val"
    done
    echo "------------------------------------------------------------"
    if [ "$fail" -eq 0 ]; then
        echo -e "  OVERALL: ${GREEN}PASS${NC} ($pass/$total passed)"
    else
        echo -e "  OVERALL: ${RED}FAIL${NC} ($pass/$total passed, $fail failed)"
    fi
}

phase2_test() {
    require_root
    trap cleanup EXIT
    [ "$(uname -m)" = "aarch64" ] || { log_error "This script is for aarch64 only"; exit 1; }
    [ -f "$STATE_FILE" ] || { log_error "Missing $STATE_FILE; run --phase=1 first"; exit 1; }
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    require_cmd nvme
    require_cmd mkfs.ext4
    [ -d "/lib/modules/$(uname -r)/build" ] || { log_error "Kernel headers missing"; exit 1; }

    local critical=false build_log pci_dev nvme_dev nvme_ns out rc speed vendor_re
    vendor_re="$(vendor_id_regex)"
    IOMMU_PASSTHROUGH="${IOMMU_PASSTHROUGH:-0}"

    if [ "$IOMMU_PASSTHROUGH" = 1 ]; then
        if cmdline_has_global_iommu_passthrough; then
            record_result "iommu passthrough boot param" PASS
        else
            record_result "iommu passthrough boot param" FAIL "state requested passthrough but boot param is missing"
            critical=true
        fi
    else
        if cmdline_has_global_iommu_passthrough; then
            record_result "iommu passthrough disabled" FAIL "unexpected global passthrough in /proc/cmdline"
            critical=true
        else
            record_result "iommu passthrough disabled" PASS
        fi
    fi

    if dt_reserved_memory_covers "$MEMMAP_START_BYTES" "$MEMMAP_SIZE_BYTES"; then
        record_result "DTB reserved-memory carveout" PASS
    else
        record_result "DTB reserved-memory carveout" FAIL
        critical=true
    fi

    if dt_memory_covers "$MEMMAP_START_BYTES" "$MEMMAP_SIZE_BYTES"; then
        record_result "memmap inside DT memory" PASS
    else
        record_result "memmap inside DT memory" FAIL
        critical=true
    fi

    if iomem_system_ram_intersects "$MEMMAP_START_BYTES" "$MEMMAP_SIZE_BYTES"; then
        record_result "memmap removed from System RAM" FAIL "rerun --phase=1 and reboot"
        critical=true
    else
        record_result "memmap removed from System RAM" PASS
    fi

    [ "$critical" = false ] || { print_summary; exit 1; }

    cd "$PROJECT_DIR"
    make clean >/dev/null 2>&1 || true
    build_log="/tmp/nvmev_arm64_build.log"
    if make >"$build_log" 2>&1 && [ -f nvmev.ko ]; then
        record_result "Module build" PASS
    else
        record_result "Module build" FAIL "see $build_log"
        tail -30 "$build_log" || true
        print_summary
        exit 1
    fi

    if insmod ./nvmev.ko memmap_start="$MEMMAP_START_BYTES" memmap_size="$MEMMAP_SIZE_BYTES" cpus="$CPUS_MODULE"; then
        sleep 2
        record_result "Module load" PASS
    else
        record_result "Module load" FAIL
        dmesg | tail -30 || true
        print_summary
        exit 1
    fi

    pci_dev="$(find_nvmev_pci_device || true)"
    if [ -n "$pci_dev" ]; then
        record_result "PCI device discovery" PASS "$(basename "$pci_dev")"
    else
        record_result "PCI device discovery" FAIL "vendor $NVMEV_VENDOR_ID not found under /sys/bus/pci/devices"
        print_summary
        exit 1
    fi

    check_nvmev_iommu_group "$pci_dev" || { print_summary; exit 1; }

    nvme_dev="$(wait_for_nvmev_device || true)"
    if [ -n "$nvme_dev" ]; then
        record_result "Device discovery" PASS "$nvme_dev"
    else
        record_result "Device discovery" FAIL
        print_summary
        exit 1
    fi

    nvme_ns=""
    for ns in "${nvme_dev}n"[0-9]*; do
        [ -b "$ns" ] || continue
        nvme_ns="$ns"
        break
    done
    if [ -n "$nvme_ns" ]; then
        record_result "Namespace discovery" PASS "$nvme_ns"
    else
        record_result "Namespace discovery" FAIL
        print_summary
        exit 1
    fi

    out="$(nvme id-ctrl "$nvme_dev" 2>&1 || true)"
    if echo "$out" | grep -Eqi "^vid.*$vendor_re"; then
        record_result "NVMe Identify Controller" PASS
    else
        record_result "NVMe Identify Controller" FAIL
    fi

    out="$(nvme id-ns "$nvme_ns" 2>&1 || true)"
    if echo "$out" | grep -q "^nsze"; then
        record_result "NVMe Identify Namespace" PASS
    else
        record_result "NVMe Identify Namespace" FAIL
    fi

    if nvme smart-log "$nvme_dev" >/dev/null 2>&1; then
        record_result "NVMe SMART Log" PASS
    else
        record_result "NVMe SMART Log" FAIL
    fi

    if mkfs.ext4 -F "$nvme_ns" >/dev/null 2>&1; then
        record_result "ext4 filesystem creation" PASS
    else
        record_result "ext4 filesystem creation" FAIL
        print_summary
        exit 1
    fi

    mkdir -p "$MOUNT_POINT"
    if mount "$nvme_ns" "$MOUNT_POINT"; then
        record_result "Mount filesystem" PASS
    else
        record_result "Mount filesystem" FAIL
        print_summary
        exit 1
    fi

    local expected readback
    expected="NVMeVirt ARM64 verification $(date -Iseconds)"
    echo "$expected" > "$MOUNT_POINT/verify_test.txt"
    sync
    readback="$(cat "$MOUNT_POINT/verify_test.txt")"
    if [ "$expected" = "$readback" ]; then
        record_result "Write/Read data integrity" PASS
    else
        record_result "Write/Read data integrity" FAIL
    fi

    out="$(dd if=/dev/zero of="$MOUNT_POINT/dd_test.bin" bs=1M count="$DD_SIZE_MB" oflag=direct 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ] && echo "$out" | grep -q "bytes.*copied"; then
        speed="$(echo "$out" | grep -oE '[0-9.]+ [KMG]?B/s' | tail -1)"
        record_result "dd sequential write" PASS "$speed"
    else
        record_result "dd sequential write" FAIL
    fi

    out="$(dd if="$MOUNT_POINT/dd_test.bin" of=/dev/null bs=1M count="$DD_SIZE_MB" iflag=direct 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ] && echo "$out" | grep -q "bytes.*copied"; then
        speed="$(echo "$out" | grep -oE '[0-9.]+ [KMG]?B/s' | tail -1)"
        record_result "dd sequential read" PASS "$speed"
    else
        record_result "dd sequential read" FAIL
    fi

    if [ -d /proc/nvmev ] && cat /proc/nvmev/read_times >/dev/null 2>&1 &&
       cat /proc/nvmev/write_times >/dev/null 2>&1 && cat /proc/nvmev/stat >/dev/null 2>&1; then
        record_result "/proc/nvmev interface" PASS
    else
        record_result "/proc/nvmev interface" FAIL
    fi

    rm -f "$MOUNT_POINT/verify_test.txt" "$MOUNT_POINT/dd_test.bin"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT" 2>/dev/null || true

    if rmmod nvmev && ! lsmod | grep -q "^nvmev "; then
        record_result "Module unload" PASS
    else
        record_result "Module unload" FAIL
    fi

    show_hmb_stats
    print_summary
}

PHASE="auto"
RESTORE=false
for arg in "$@"; do
    case "$arg" in
        --phase=1) PHASE=1 ;;
        --phase=2) PHASE=2 ;;
        --phase=auto) PHASE=auto ;;
        --restore-boot) RESTORE=true ;;
        *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
done

if [ "$RESTORE" = true ]; then
    restore_boot
    exit 0
fi

if [ "$PHASE" = auto ]; then
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        if dt_reserved_memory_covers "$MEMMAP_START_BYTES" "$MEMMAP_SIZE_BYTES" &&
           dt_memory_covers "$MEMMAP_START_BYTES" "$MEMMAP_SIZE_BYTES" &&
           ! iomem_system_ram_intersects "$MEMMAP_START_BYTES" "$MEMMAP_SIZE_BYTES"; then
            PHASE=2
        else
            PHASE=1
        fi
    else
        PHASE=1
    fi
fi

case "$PHASE" in
    1) phase1_setup ;;
    2) phase2_test ;;
esac
