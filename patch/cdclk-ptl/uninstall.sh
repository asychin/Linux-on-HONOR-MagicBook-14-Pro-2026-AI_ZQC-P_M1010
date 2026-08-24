#!/usr/bin/env bash
# uninstall.sh — drop the Panther Lake CDCLK fix from the local xe.ko.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/xe-build.sh"

u_log "Removing the locally built xe.ko overlay"
xe_uninstall cdclk-ptl

# xe is pulled into the initramfs by the kms hook, so the early-KMS copy has to
# be refreshed as well, otherwise the removed module keeps lighting the panel.
u_log "Rebuilding the initramfs"
u_regen

echo "    on a kernel from 7.1.6 that has not picked up the upstream fix, the"
echo "    screen is garbled again during boot until the compositor starts."
u_done
