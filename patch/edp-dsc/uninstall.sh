#!/usr/bin/env bash
# uninstall.sh — drop the eDP DSC preference from the local xe.ko.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/xe-build.sh"

u_log "Removing the locally built xe.ko overlay"
xe_uninstall edp-dsc

u_log "Rebuilding the initramfs"
u_regen

echo "    the internal panel goes back to 6 bits per colour with dithering,"
echo "    because the link cannot carry 8 bpc at this mode and the driver drops"
echo "    colour depth before it will compress."
u_done
