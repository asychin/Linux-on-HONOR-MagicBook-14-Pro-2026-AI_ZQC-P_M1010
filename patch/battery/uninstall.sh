#!/usr/bin/env bash
# uninstall.sh — remove the battery charge limit and the units that keep it armed.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing the charge-limit service"
u_unit_off honor-battery-threshold.service
systemctl disable honor-battery-threshold-resume.service >/dev/null 2>&1 || true
u_rm /etc/systemd/system/honor-battery-threshold.service \
     /etc/systemd/system/honor-battery-threshold-resume.service \
     /usr/local/lib/honor/honor-battery-threshold.sh \
     /etc/honor-battery.conf \
     /etc/udev/hwdb.d/61-honor-battery-charge-limit.hwdb \
  || echo "    nothing installed"
u_daemon_reload
command -v systemd-hwdb >/dev/null && systemd-hwdb update 2>/dev/null || true
rmdir --ignore-fail-on-non-empty /usr/local/lib/honor 2>/dev/null || true

u_log "Handing the limit back to the EC"
# Removing the files does not disarm the EC: it keeps the pair it was given
# across reboots. 0 100 is the preset that means "no limit".
if [[ -w /sys/devices/platform/huawei-wmi/charge_control_thresholds ]]; then
    echo "0 100" > /sys/devices/platform/huawei-wmi/charge_control_thresholds \
        && echo "    charge limit removed (0 100)"
else
    u_warn "huawei-wmi exposes no charge_control_thresholds here; if the EC is
    still limiting the charge, clear it from HONOR PC Manager under Windows."
fi
u_done
