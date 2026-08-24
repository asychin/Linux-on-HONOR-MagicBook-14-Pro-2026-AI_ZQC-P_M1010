#!/usr/bin/env bash
# uninstall.sh — remove the EC fan tachometer module.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing honor-ec-sensors"
# Order matters: unload first, then let DKMS deregister, then remove the files.
# Once dkms has removed the module, modprobe can no longer resolve the name and
# a still-resident copy would stay until a reboot. rmmod works on the loaded
# module regardless of what is left on disk.
modprobe -r honor-ec-sensors 2>/dev/null || rmmod honor_ec_sensors 2>/dev/null || true
if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q '^honor-ec-sensors'; then
    dkms remove -m honor-ec-sensors -v 1.0 --all >/dev/null 2>&1 \
        && echo "    removed DKMS module honor-ec-sensors" \
        || u_fail "dkms remove honor-ec-sensors/1.0 failed; remove it by hand"
fi
# Both names. This module was honor-zqcp-hwmon before the rename, and a machine
# that installed that and never re-ran the installer still has it.
modprobe -r honor-zqcp-hwmon 2>/dev/null || rmmod honor_zqcp_hwmon 2>/dev/null || true
if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q '^honor-zqcp-hwmon'; then
    dkms remove -m honor-zqcp-hwmon -v 1.0 --all >/dev/null 2>&1 \
        && echo "    removed the pre-rename DKMS module honor-zqcp-hwmon"
fi
shopt -s nullglob
u_rm /usr/src/honor-ec-sensors-1.0 \
     /usr/src/honor-zqcp-hwmon-1.0 \
     /etc/modules-load.d/honor-zqcp-hwmon.conf \
     /usr/lib/modules/*/updates/honor-zqcp-hwmon.ko* \
     /etc/modules-load.d/honor-ec-sensors.conf \
     /etc/modprobe.d/honor-ec-sensors.conf \
     /usr/lib/modules/*/updates/honor-ec-sensors.ko* \
     /usr/lib/modules/*/updates/dkms/honor-ec-sensors.ko* \
     /lib/modules/*/updates/honor-ec-sensors.ko* \
  || echo "    nothing installed"
shopt -u nullglob
u_depmod

echo "    fan RPM disappears from sensors, btop and desktop widgets. Nothing"
echo "    about the fans themselves changes: this was always read-only, and"
echo "    the EC owns the curve."
u_done
