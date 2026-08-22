#!/usr/bin/env bash
# Re-apply the battery charge limit. Installed to /usr/local/lib/honor/ and run
# by honor-battery-threshold.service at boot and after resume.
#
# The value comes from /etc/honor-battery.conf, which the installer writes.
set -euo pipefail

CONF=/etc/honor-battery.conf
NODE=/sys/devices/platform/huawei-wmi/charge_control_thresholds

[[ -r "$CONF" ]] || exit 0
# shellcheck source=/dev/null
. "$CONF"
[[ -n "${CHARGE_PRESET:-}" ]] || exit 0
[[ -w "$NODE" ]] || { echo "no $NODE, is huawei-wmi loaded?" >&2; exit 1; }

echo "$CHARGE_PRESET" > "$NODE"

# The EC only arms itself for the presets its firmware knows. Report what it
# actually did rather than assuming the write took effect.
if [[ -r /sys/kernel/debug/ec/ec0/io ]]; then
    mode=$(dd if=/sys/kernel/debug/ec/ec0/io bs=1 skip=133 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
    if [[ "${mode:-0}" == "0" ]]; then
        echo "warning: wrote '$CHARGE_PRESET' but the EC did not arm (charge mode 0)." >&2
        echo "         Only the presets in /etc/honor-battery.conf are enforced." >&2
    fi
fi
