#!/usr/bin/env bash
# uninstall.sh — remove the SOF IPC4 copier-payload overlay.
#
# Runs on its own: sudo bash $0
# See lib/uninstall.sh for why this is not gated on the device profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/uninstall.sh"

u_log "Removing the snd-sof overlay for ${KVER}"
# Only the overlay in updates/. The packaged module underneath was never
# touched, which is the whole point of installing into updates/.
u_rm "/usr/lib/modules/${KVER}/updates/snd-sof.ko.zst" \
     "/usr/lib/modules/${KVER}/updates/snd-sof.ko" \
  || echo "    no overlay installed for ${KVER}"

# Kept, not deleted: it is the original module, and a later reinstall reuses it.
[[ -f /root/snd-sof.ko.zst.orig ]] \
    && echo "    in-tree backup at /root/snd-sof.ko.zst.orig retained"

u_depmod
echo "    the DSP falls back to the packaged module. The suspend/resume race"
echo "    this backported a fix for never reproduced here, so this is a"
echo "    preventive measure going away, not a working thing breaking."
u_done
