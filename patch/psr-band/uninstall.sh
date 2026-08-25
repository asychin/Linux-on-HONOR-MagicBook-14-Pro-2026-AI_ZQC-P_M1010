#!/usr/bin/env bash
# uninstall.sh — give PSR2 selective update back to the driver.
#
# Dropping the kernel parameter is the whole of it. The running session is put
# back as well, so the band returns immediately rather than at the next boot,
# which is what you want when you are checking that this was the cause.
#
# Env knobs:
#   LIVE=0   leave the running session alone
#   REGEN=0  do not update the bootloader config (the caller will)

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE="${LIVE:-1}"
REGEN="${REGEN:-1}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/distro.sh"

log "[1/3] Remove the kernel parameter"
f="$(distro_cmdline_file 2>/dev/null || true)"
if [[ -n "$f" ]]; then
    distro_cmdline_remove '(xe|i915)\.enable_psr=[0-9]+'
    distro_cmdline_show | sed 's/^/    /'
else
    echo "    no kernel command line file found; drop (xe|i915).enable_psr="
    echo "    from your bootloader's command line by hand"
fi

log "[2/3] Put the running session back"
if (( LIVE )); then
    restored=0
    for d in /sys/kernel/debug/dri/*/i915_edp_psr_debug; do
        [[ -w "$d" ]] || continue
        echo 0 > "$d" 2>/dev/null && restored=1
        break
    done
    if (( restored )); then
        sleep 1
        for s in /sys/kernel/debug/dri/*/eDP-1/i915_psr_status; do
            [[ -r "$s" ]] && { grep -E '^PSR mode' "$s" | sed 's/^/      /'; break; }
        done
    else
        echo "    debugfs not writable, skipped"
    fi
else
    echo "    skipped by LIVE=0"
fi

if (( REGEN )); then
    log "[3/3] Update the bootloader config"
    distro_bootloader_update || warn "update your bootloader config by hand"
else
    log "[3/3] Bootloader config left to the caller (REGEN=0)"
fi
