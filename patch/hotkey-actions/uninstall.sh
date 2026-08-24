#!/usr/bin/env bash
# uninstall.sh — remove the service that acts on the hotkeys the desktop ignores.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing the hotkey action service"
u_unit_off honor-hotkey-actions.service

# Read the camera id BEFORE deleting the file that holds it: the service can
# leave the webcam de-authorised, and this is the only record of which device
# that was.
CAM_ID=""
[[ -f /etc/honor-hotkey-actions.conf ]] && \
    CAM_ID="$(sed -n 's/^CAMERA_USB=//p' /etc/honor-hotkey-actions.conf | tr -d '"' | head -1)"

u_rm /etc/systemd/system/honor-hotkey-actions.service \
     /usr/local/lib/honor/honor-hotkey-actions.py \
     /etc/honor-hotkey-actions.conf \
  || echo "    nothing installed"
u_daemon_reload
rmdir --ignore-fail-on-non-empty /usr/local/lib/honor 2>/dev/null || true

# Leave the camera authorised on the way out. Only the camera: writing 1 to
# every `authorized` under /sys/bus/usb/devices would also re-authorise devices
# somebody had deliberately switched off, and would do it even on a machine
# where this fix was never installed.
if [[ -n "$CAM_ID" ]]; then
    for d in /sys/bus/usb/devices/*/; do
        [[ -r "$d/idVendor" && -r "$d/idProduct" ]] || continue
        [[ "$(cat "$d/idVendor"):$(cat "$d/idProduct")" == "$CAM_ID" ]] || continue
        [[ -w "$d/authorized" ]] && echo 1 > "$d/authorized" 2>/dev/null \
            && echo "    re-authorised the webcam ($CAM_ID)"
    done
else
    echo "    no camera id on record. If your webcam is missing, re-authorise it:"
    echo "        echo 1 | sudo tee /sys/bus/usb/devices/<dev>/authorized"
fi
u_done
