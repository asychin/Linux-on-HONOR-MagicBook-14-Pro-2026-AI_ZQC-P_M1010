#!/usr/bin/env bash
# uninstall.sh — remove the patched ACPI table and the way it was staged.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing the patched SSDT"
u_rm /usr/lib/firmware/acpi/SSDT27_TPD0.aml || echo "    not installed"
rmdir --ignore-fail-on-non-empty /usr/lib/firmware/acpi 2>/dev/null || true

u_log "Removing the mechanism that staged it"
# Two of them, because which one is used depends on the distribution: an
# mkinitcpio install hook on Arch, a CPIO handed to GRUB on Debian and Ubuntu.
u_rm /etc/initcpio/install/acpi_override
distro_acpi_override_remove || true
if [[ -f /etc/mkinitcpio.conf ]]; then
    sed -i 's/ acpi_override//' /etc/mkinitcpio.conf
    echo "    HOOKS=$(grep -E '^HOOKS=' /etc/mkinitcpio.conf)"
fi

u_log "Rebuilding the initramfs"
u_regen

echo
echo "    The touchpad and touchscreen stop working at the next boot: without"
echo "    the corrected table the DSDT load fails and the I2C controllers never"
echo "    come up. The internal keyboard is a separate matter and needs"
echo "    patch/keyboard-atkbd/uninstall.sh if you also want its parameter gone."
u_done
