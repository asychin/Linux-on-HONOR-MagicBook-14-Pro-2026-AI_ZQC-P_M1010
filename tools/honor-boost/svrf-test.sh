#!/usr/bin/env bash
# Gate, apply, and roll back the SVRF rail unlock on ZQC-P.
#
#   svrf-test.sh status   - print current rail state (honor-ec-rail)
#   svrf-test.sh unlock   - capture baseline, apply rail unlock (0xFF), verify
#   svrf-test.sh restore  - restore the captured baseline, verify
#
# The unlock is left in place after `unlock` so you can run a load and measure
# package power between `unlock` and `restore`.  A trap restores the baseline
# if the script is interrupted while it still holds the rails unlocked.
#
# Requires: acpi_call (for \SVRF) and honor-ec-rail (to read the rails back).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

B=/sys/kernel/honor-ec-rail
STATE=/tmp/honor-boost-baseline
PROC=/proc/acpi/call

rd() { cat "$B/$1" 2>/dev/null; }

die() { echo "ERROR: $*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "run as root (sudo)"; }

require_modules() {
    [[ -d "$B" ]] || die "honor-ec-rail not loaded (sudo insmod honor-ec-rail.ko)"
    [[ -e "$PROC" ]] || die "acpi_call not loaded (sudo insmod acpi_call/acpi_call.ko)"
}

# ac-gate: refuse without AC or with battery charge <= 20% (see boost-refactoring.md)
require_ac() {
    local online cap
    online="$(cat /sys/class/power_supply/ADP1/online 2>/dev/null || echo 0)"
    cap="$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo 0)"
    [[ "$online" == "1" ]] || die "not on AC; Performance requires AC"
    (( cap > 20 )) || die "battery charge ${cap}% <= 20%; refusing"
}

# Build a 10-byte SVRF buffer: offsets 0x04..0x09 = ppl4,vccc,vccg,vccs,vccl,svft
svrf_buffer() {
    local ppl4="$1" vccc="$2" vccg="$3" vccs="$4" vccl="$5" svft="$6"
    printf 'b00000000%02x%02x%02x%02x%02x%02x' \
        0x$ppl4 0x$vccc 0x$vccg 0x$vccs 0x$vccl 0x$svft
}

svrf_call() {
    echo "\\SVRF $1" > "$PROC"
    cat "$PROC"
}

status() {
    require_modules
    printf '%-12s %-6s\n' "field" "value"
    printf '%-12s %-6s\n' "-----------" "-----"
    for f in crwm ec_cpu_temp fan0 fan1 svft ftsl scpm vccc vccg vccs vccl ppl4 vrss vr10 vr12 vr14 vr16; do
        printf '%-12s %-6s\n' "$f" "$(rd "$f")"
    done
}

do_unlock() {
    require_root; require_modules; require_ac
    [[ -f "$STATE" ]] && die "baseline already captured at $STATE; run 'restore' first"

    local vccc vccg vccs vccl ppl4 svft
    vccc=$(rd vccc); vccg=$(rd vccg); vccs=$(rd vccs); vccl=$(rd vccl)
    ppl4=$(rd ppl4); svft=$(rd svft)

    for v in "$vccc" "$vccg" "$vccs" "$vccl"; do
        [[ -n "$v" ]] || die "could not read rails; is honor-ec-rail loaded?"
    done

    echo "baseline: vccc=$vccc vccg=$vccg vccs=$vccs vccl=$vccl ppl4=$ppl4 svft=$svft"
    printf '%s %s %s %s %s %s\n' "$vccc" "$vccg" "$vccs" "$vccl" "$ppl4" "$svft" > "$STATE"

    # insurance: restore baseline if this script is killed while holding unlock
    trap 'echo; echo "interrupted, restoring baseline"; do_restore_impl; exit 130' INT TERM

    echo "applying SVRF unlock (all rails 0xFF, PPL4=0, SVFT=0)..."
    svrf_call "$(svrf_buffer 00 ff ff ff ff 00)"

    echo "new state:"
    printf '%-12s %-6s\n' "field" "value"
    printf '%-12s %-6s\n' "-----------" "-----"
    for f in vccc vccg vccs vccl ppl4 svft; do
        printf '%-12s %-6s\n' "$f" "$(rd "$f")"
    done
    echo
    echo "Run your load now, then: sudo $0 restore"
}

do_restore_impl() {
    [[ -f "$STATE" ]] || { echo "no baseline at $STATE"; return 1; }
    read -r vccc vccg vccs vccl ppl4 svft < "$STATE"
    echo "restoring: vccc=$vccc vccg=$vccg vccs=$vccs vccl=$vccl ppl4=$ppl4 svft=$svft"
    svrf_call "$(svrf_buffer "$ppl4" "$vccc" "$vccg" "$vccs" "$vccl" "$svft")"
    rm -f "$STATE"
}

do_restore() {
    require_root; require_modules
    do_restore_impl
    echo "verifying restore:"
    for f in vccc vccg vccs vccl ppl4 svft; do
        printf '%-12s %-6s\n' "$f" "$(rd "$f")"
    done
}

case "${1:-}" in
    status)  status ;;
    unlock)  do_unlock ;;
    restore) do_restore ;;
    *) echo "usage: $0 {status|unlock|restore}"; exit 2 ;;
esac
