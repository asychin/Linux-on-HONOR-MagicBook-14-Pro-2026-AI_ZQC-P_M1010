#!/usr/bin/env bash
# Show what the Intel NPU is doing.
#
#   bash tools/npu-status.sh          # one shot
#   bash tools/npu-status.sh -w       # keep updating, until Ctrl-C
#   bash tools/npu-status.sh -w -n 2  # ... every 2 seconds
#
# Read-only, and no root needed: everything here comes out of the PCI sysfs
# node the `intel_vpu` driver publishes. `sensors` does not show the NPU and
# never will; see docs/NPU.md for why, and for what the numbers mean.
#
# Not tied to any one machine. It matches the NPU by driver, so it works on
# every Core Ultra generation the driver supports.

set -euo pipefail

WATCH=0
INTERVAL=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--watch)    WATCH=1; shift ;;
        -n|--interval) INTERVAL="${2:-1}"; shift 2 ;;
        -h|--help)     sed -n '2,13p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

DEV=""
for d in /sys/bus/pci/drivers/intel_vpu/0000:*; do
    [[ -d "$d" ]] || continue
    DEV="$d"
    break
done

if [[ -z "$DEV" ]]; then
    if lspci -nn 2>/dev/null | grep -qi 'Processing accelerators'; then
        echo "An NPU is on the bus but intel_vpu is not bound to it." >&2
        echo "Check that the module loaded: modprobe intel_vpu" >&2
    else
        echo "No Intel NPU found. This machine may not have one." >&2
    fi
    exit 1
fi

SLOT="$(basename "$DEV")"

# `intel_vpu` publishes these; older kernels publish fewer. Missing files are
# reported as "n/a" rather than failing, because which ones exist tracks the
# kernel version, not the hardware.
read_attr() {
    local f="$DEV/$1"
    [[ -r "$f" ]] && cat "$f" 2>/dev/null || echo "n/a"
}

fw_line() {
    # The firmware name is only ever printed to the kernel log, not to sysfs.
    journalctl -k -b 2>/dev/null | grep -m1 -oE 'intel/vpu/vpu_[0-9a-z_.]+\.bin' || true
}

human_bytes() {
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || { echo "n/a"; return 0; }
    awk -v b="$b" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
    }'
}

NAME="$(lspci -s "${SLOT#0000:}" 2>/dev/null | cut -d: -f3- | sed 's/^ *//')"
[[ -n "$NAME" ]] || NAME="Intel NPU"
FW="$(fw_line)"

static_block() {
    printf 'NPU        %s\n' "$NAME"
    printf 'slot       %s\n' "$SLOT"
    printf 'driver     intel_vpu %s\n' "$(cat /sys/module/intel_vpu/version 2>/dev/null || echo '')"
    printf 'firmware   %s\n' "${FW:-not in the current boot log}"
    printf 'max clock  %s MHz\n' "$(read_attr npu_max_frequency_mhz)"
}

# Utilization is not published as a percentage. npu_busy_time_us is a counter
# of microseconds spent executing jobs, so a percentage only exists between two
# readings: (busy delta) / (wall-clock delta). One reading on its own tells you
# how much work the NPU has done since boot, which is a different question.
PREV_BUSY=""
PREV_NS=""

sample_line() {
    local busy now_ns util="   --" d_busy d_ns
    busy="$(read_attr npu_busy_time_us)"
    now_ns="$(date +%s%N)"

    if [[ "$busy" =~ ^[0-9]+$ && -n "$PREV_BUSY" ]]; then
        d_busy=$(( busy - PREV_BUSY ))
        d_ns=$(( now_ns - PREV_NS ))
        if (( d_ns > 0 )); then
            util="$(awk -v b="$d_busy" -v n="$d_ns" \
                'BEGIN { p = b * 1000.0 / n * 100.0; if (p > 100) p = 100; printf "%5.1f", p }')"
        fi
    fi
    PREV_BUSY="$busy"
    PREV_NS="$now_ns"

    printf 'busy %s%%   clock %5s MHz   power %-7s   mem %-9s   total busy %s\n' \
        "$util" \
        "$(read_attr npu_current_frequency_mhz)" \
        "$(read_attr power_state)" \
        "$(human_bytes "$(read_attr npu_memory_utilization)")" \
        "$(awk -v u="$(read_attr npu_busy_time_us)" \
             'BEGIN { if (u ~ /^[0-9]+$/) printf "%.1f s", u/1000000; else printf "n/a" }')"
}

if (( WATCH == 0 )); then
    static_block
    echo
    # One sample cannot produce a percentage. Take two, a moment apart, so the
    # single-shot output has a real number in it rather than a dash.
    sample_line >/dev/null
    sleep 0.5
    sample_line
    exit 0
fi

static_block
echo
trap 'echo; exit 0' INT
sample_line >/dev/null
while :; do
    sleep "$INTERVAL"
    sample_line
done
