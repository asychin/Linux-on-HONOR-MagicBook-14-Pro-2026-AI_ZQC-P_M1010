#!/usr/bin/env bash
# uninstall.sh — remove the HID-BPF fixup that hid the phantom KEY_MICMUTE device.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing the boot-time re-apply service"
u_unit_off honor-hid-bpf-reapply.service
u_rm /etc/systemd/system/honor-hid-bpf-reapply.service \
     /usr/local/lib/honor/hid-bpf-reapply.sh \
     /usr/local/lib/honor-zqcp/hid-bpf-reapply.sh
rmdir --ignore-fail-on-non-empty /usr/local/lib/honor-zqcp 2>/dev/null || true
u_daemon_reload
rmdir --ignore-fail-on-non-empty /usr/local/lib/honor 2>/dev/null || true

u_log "Removing the BPF object"
# What the installer recorded first, then the family glob, because the object
# is named after the touchscreen it was built for and older installs predate
# the record.
if [[ -r /etc/honor-micmute.conf ]]; then
    OBJ="$(sed -n 's/^BPF_OBJECT=//p' /etc/honor-micmute.conf)"
    [[ -n "$OBJ" ]] && u_rm "$OBJ"
fi
shopt -s nullglob
u_rm /etc/honor-micmute.conf \
     /etc/udev-hid-bpf/honor-*-micmute.bpf.o \
     /etc/udev/rules.d/99-hid-bpf-honor-*-micmute.rules \
  || echo "    nothing installed"
shopt -u nullglob
udevadm control --reload 2>/dev/null || true

u_log "Removing any pre-HID-BPF module overlay"
# The first version of this fix shipped a patched hid-multitouch. Anybody who
# installed that and then updated still has it.
#
# It used to remove a huawei-wmi overlay here too, left over from the first,
# wrong theory about what was muting the microphone. That stopped being this
# fix's rubbish the moment patch/hotkeys/ started installing a huawei-wmi
# overlay of its own: removing micmute then quietly took the Fn keys with it,
# and the hotkeys step of the next run had nothing left to remove. An
# uninstaller only removes what its own installer writes. tools/selftest.sh
# checks that now.
OVERLAY="/usr/lib/modules/${KVER}/updates/hid-multitouch.ko.zst"
BACKUP=/root/hid-multitouch.ko.zst.orig
u_rm "$OVERLAY"
[[ -f "$BACKUP" ]] && echo "    in-tree backup at $BACKUP retained"
u_depmod

echo
echo "    The fixed report descriptor survives until the device is re-probed,"
echo "    so the phantom device comes back at the next boot, not now. When it"
echo "    does, the microphone will start muting itself again at ~30 Hz."
u_done
