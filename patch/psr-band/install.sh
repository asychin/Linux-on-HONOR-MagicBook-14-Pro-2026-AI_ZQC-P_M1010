#!/usr/bin/env bash
# install.sh — stop PSR2 selective update from painting a faint full width band
# under the mouse cursor, by limiting Panel Self Refresh to PSR1.
#
# PSR2 selective update refreshes a range of scanlines rather than the whole
# frame, and the hardware can only address that range by line number:
#
#	/* PSR2 HW only send full lines so we only need to validate the width */
#	if (crtc_hdisplay % sink_w_granularity)
#		return false;
#	                        -- psr2_granularity_check(), intel_psr.c
#
# So every partial update is a band the full width of the screen. Move the
# pointer and the cursor plane's damage rectangle drags that band up and down
# with it. On this OLED the band is rendered visibly differently from the part
# of the frame the panel is still driving out of its own buffer, and the result
# is a wide, faint, moving shadow. See README.md for the whole trace.
#
# PSR1 has no selective update at all: it either holds the frame or refreshes
# all of it, so the band cannot exist. Most of the idle power saving is in PSR1
# already; what is given up is the extra saving PSR2 gets on small updates.
#
# Env knobs:
#   PSR_LEVEL=1  limit to PSR1 (default). 0 turns PSR off entirely, which is
#                only worth doing if PSR1 itself misbehaves on your panel.
#   LIVE=0       do not also apply the change to the running session
#   REGEN=0      do not update the bootloader config (the caller will)

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSR_LEVEL="${PSR_LEVEL:-1}"
LIVE="${LIVE:-1}"
REGEN="${REGEN:-1}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$PSR_LEVEL" == 0 || "$PSR_LEVEL" == 1 ]] \
    || die "PSR_LEVEL must be 0 (PSR off) or 1 (PSR1 only). 2 is the default
    the driver already uses, and it is what puts the band on the screen."

# Tier A: nothing here comes out of the profile. The parameter is read off the
# driver actually bound to the display, and whether there is anything to fix is
# decided by asking the running machine what PSR mode it is in.
source "${SCRIPT_DIR}/../../lib/gate.sh"
honor_gate psr-band

# --- 1. which driver owns the display ----------------------------------------
DRV=""
for d in /sys/class/drm/card*/device/driver; do
    [[ -e "$d" ]] || continue
    case "$(basename "$(readlink -f "$d")")" in
        xe)   DRV=xe;   break ;;
        i915) DRV=i915; break ;;
    esac
done
[[ -n "$DRV" ]] || die "neither xe nor i915 is bound to a display device, so
    there is no PSR here to limit."

PARAM="${DRV}.enable_psr=${PSR_LEVEL}"

# --- 2. is this machine actually showing the problem? ------------------------
# Distinguish three answers, because they need three different reactions:
# PSR2 is on (fix it), PSR2 is off (nothing to do), cannot tell (say so and
# install anyway, the parameter is harmless).
PSR_STATUS=""
for f in /sys/kernel/debug/dri/*/eDP-1/i915_psr_status; do
    [[ -r "$f" ]] && { PSR_STATUS="$(cat "$f")"; break; }
done

if [[ -z "$PSR_STATUS" ]]; then
    warn "cannot read i915_psr_status under /sys/kernel/debug/dri.
    Either debugfs is not mounted, this is not being run on the machine being
    fixed, or the panel is not eDP-1. Installing the parameter anyway: it can
    only lower the PSR level, never raise it."
elif grep -q '^PSR mode: PSR2 enabled' <<<"$PSR_STATUS"; then
    log "eDP is in PSR2 with selective fetch, which is the configuration that"
    echo "    produces the band:"
    grep -E '^(PSR mode|PSR2 selective fetch)' <<<"$PSR_STATUS" | sed 's/^/      /'
elif grep -q '^PSR mode: PSR1 enabled' <<<"$PSR_STATUS"; then
    log "eDP is already in PSR1, so the band is already gone from this session."
    echo "    Installing the parameter makes that survive a reboot."
else
    log "eDP is not in PSR2:"
    grep -E '^PSR mode' <<<"$PSR_STATUS" | sed 's/^/      /'
    echo "    Nothing here needs fixing. Not touching the command line."
    exit 0
fi

# The sink keeps its own error latch. A CRC error there is the panel saying it
# received a frame it could not verify, which is worth showing before and after.
for f in /sys/kernel/debug/dri/*/eDP-1/i915_psr_sink_status; do
    [[ -r "$f" ]] || continue
    if grep -q 'error status: 0x[1-9a-f]' "$f"; then
        log "the panel is also latching PSR errors right now:"
        sed 's/^/      /' "$f"
    fi
    break
done

# --- 3. kernel command line ---------------------------------------------------
log "[1/3] Put ${PARAM} on the kernel command line"

# Any other enable_psr= setting has to go first, or the two end up on the same
# line and which one wins is down to parsing order.
if grep -qE '(xe|i915)\.enable_psr=' "$(distro_cmdline_file)" 2>/dev/null \
   && ! grep -qF -- "$PARAM" "$(distro_cmdline_file)" 2>/dev/null; then
    warn "replacing an existing enable_psr= setting"
    distro_cmdline_remove '(xe|i915)\.enable_psr=[0-9]+'
fi

if distro_cmdline_add "$PARAM"; then
    echo "    $(grep -hE 'CMDLINE|^GRUB_CMDLINE' "$(distro_cmdline_file)" | head -1)"
else
    die "could not edit the kernel command line. Add ${PARAM} to it yourself."
fi

# --- 4. make it true for this session as well ---------------------------------
# Without this the band stays until the next boot. I915_PSR_DEBUG_FORCE_PSR1 is
# 3, and it reaches the same decision the parameter does: sel_update_global_
# enabled() returns false for it, params.enable_psr == 1 makes intel_psr2_
# config_valid() return false, and both land on the same `unsupported` label
# that clears crtc_state->enable_psr2_sel_fetch.
if (( LIVE )) && [[ "$PSR_LEVEL" == 1 ]]; then
    log "[2/3] Apply it to the running session too"
    applied=0
    for f in /sys/kernel/debug/dri/*/i915_edp_psr_debug; do
        [[ -w "$f" ]] || continue
        if echo 3 > "$f" 2>/dev/null; then applied=1; fi
        break
    done
    if (( applied )); then
        sleep 1
        for f in /sys/kernel/debug/dri/*/eDP-1/i915_psr_status; do
            [[ -r "$f" ]] && { grep -E '^PSR mode' "$f" | sed 's/^/      /'; break; }
        done
        echo "    The screen may have blinked once; that is the modeset."
    else
        echo "    debugfs not writable, skipped. The parameter takes effect at"
        echo "    the next boot regardless."
    fi
elif (( LIVE )); then
    log "[2/3] Not applying live"
    echo "    PSR_LEVEL=0 has no runtime equivalent that reverts cleanly, so"
    echo "    this one waits for the reboot."
else
    log "[2/3] Skipped by LIVE=0"
fi

# --- 5. bootloader ------------------------------------------------------------
if (( REGEN )); then
    log "[3/3] Update the bootloader config"
    distro_bootloader_update || warn "update your bootloader config by hand"
else
    log "[3/3] Bootloader config left to the caller (REGEN=0)"
fi

cat <<EOF

Done. After the next reboot, confirm with:

    cat /sys/module/${DRV}/parameters/enable_psr        # expect ${PSR_LEVEL}
    sudo grep '^PSR mode' /sys/kernel/debug/dri/*/eDP-1/i915_psr_status
                                                       # expect PSR1 enabled

To go back: sudo bash ${SCRIPT_DIR}/uninstall.sh
EOF
