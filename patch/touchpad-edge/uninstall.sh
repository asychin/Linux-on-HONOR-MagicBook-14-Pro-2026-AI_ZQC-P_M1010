#!/usr/bin/env bash
# uninstall.sh — remove the touchpad left-edge brightness gesture.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing the edge-gesture HID-BPF program"
# Globbed by family, because the object is named after the touchpad it was
# built for: patch/touchpad-edge/touchpads/<vid>-<pid>-<chip>/.
shopt -s nullglob
u_rm /etc/udev-hid-bpf/honor-*-edge.bpf.o \
     /etc/udev/rules.d/99-hid-bpf-honor-*-edge.rules \
  || echo "    nothing installed"
shopt -u nullglob
udevadm control --reload 2>/dev/null || true

echo "    the program stays attached until the device is re-probed. It is gone"
echo "    for good at the next boot; to drop it now, unplug nothing and run:"
echo "        sudo udev-hid-bpf remove /sys/bus/hid/devices/*<VID>:<PID>*"
echo "    The right edge keeps changing volume: that goes through the EC and"
echo "    was never touched by this fix."
u_done
