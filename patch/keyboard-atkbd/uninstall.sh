#!/usr/bin/env bash
# uninstall.sh — remove the i8042.dumbkbd=1 keyboard parameter.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing i8042.dumbkbd=1 from the kernel command line"
if f="$(distro_cmdline_file 2>/dev/null)" && [[ -n "$f" ]]; then
    distro_cmdline_remove 'i8042\.dumbkbd=1'
    echo "    $(grep -hE 'CMDLINE|^[^#]' "$f" | head -1)"
else
    u_warn "no kernel command line file found; remove i8042.dumbkbd=1 from your
    bootloader's command line by hand"
fi

u_log "Updating the bootloader config"
u_regen

echo
echo "    Read this before rebooting. On a kernel WITHOUT the upstream atkbd"
echo "    quirk for this machine, the parameter is what makes the internal"
echo "    keyboard work, and taking it away can leave you at a login screen"
echo "    with no keyboard. The quirk shipped in 7.2 and 7.1.10; check with:"
echo
echo "        uname -r"
echo
echo "    What you get back is the Caps Lock LED, which the parameter disables"
echo "    as collateral. Have a USB keyboard to hand either way."
u_done
