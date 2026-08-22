#!/usr/bin/env bash
# Build and install the HID-BPF fixup that removes the phantom KEY_MICMUTE
# device created from the FocalTech FTSC1000 touchscreen's vendor collection.
#
# See README.md in this directory for the root cause.
#
# Reruns are safe. Nothing here has to be repeated after a kernel update:
# the BPF object is CO-RE and libbpf relocates it against the running
# kernel's BTF.

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/honor-ftsc1000-micmute.bpf.c"
OBJ_NAME="honor-ftsc1000-micmute.bpf.o"
INSTALL_DIR="/etc/udev-hid-bpf"
RULES_FILE="/etc/udev/rules.d/99-hid-bpf-honor-ftsc1000-micmute.rules"
KVER="$(uname -r)"
TAG="v${KVER%%-*}"
BASE_URL="https://raw.githubusercontent.com/gregkh/linux/${TAG}/drivers/hid/bpf/progs"
WORK=$(mktemp -d /var/tmp/honor-hidbpf-XXXXXX)

trap 'rm -rf "$WORK"' EXIT

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. prerequisites ---------------------------------------------------------
[[ -f "$SRC" ]] || die "source not found: $SRC"

# Tier A: bound to one HID id, so it never attaches on a machine without that
# touchscreen.
source "${SCRIPT_DIR}/../../lib/gate.sh"
honor_gate micmute

HID_ID="$(gate_param touchscreen_hid)" || die \
    "$(profile_get model) does not record touchscreen_hid.
    Find it in 'ls /sys/bus/hid/devices/' and add it to the profile."
HID_VID="0x${HID_ID%%:*}"
HID_PID="0x${HID_ID##*:}"
# sysfs spells HID device names in upper case: 0018:2808:5662.0001
HID_SYSFS="${HID_ID^^}"
log "touchscreen ${HID_VID}:${HID_PID} (from the $(profile_get model) profile)"

legacy_move /usr/local/lib/honor-zqcp /usr/local/lib/honor

MISSING=()
for t in clang bpftool curl udev-hid-bpf udevadm; do
    command -v "$t" >/dev/null || MISSING+=("$t")
done
if (( ${#MISSING[@]} )); then
    die "missing required tool(s): ${MISSING[*]}
    $(distro_pkg_hint "${MISSING[@]}")
    udev-hid-bpf is not packaged everywhere; if your distribution has no such
    package, build it from https://gitlab.freedesktop.org/libevdev/udev-hid-bpf"
fi

distro_kernel_config_has CONFIG_HID_BPF=y \
    || warn "CONFIG_HID_BPF=y not confirmed in this kernel's config - continuing anyway."

[[ -r /sys/kernel/btf/vmlinux ]] \
    || die "/sys/kernel/btf/vmlinux missing - the kernel needs CONFIG_DEBUG_INFO_BTF=y."

log "kernel  = ${KVER}"
log "headers = ${TAG}"

# --- 2. fetch the kernel's BPF prog headers -----------------------------------
for h in hid_bpf.h hid_bpf_helpers.h hid_report_descriptor_helpers.h; do
    code=$(curl -sSL --max-time 60 -o "${WORK}/${h}" -w '%{http_code}' "${BASE_URL}/${h}")
    [[ "$code" == "200" ]] || die "fetch failed: ${BASE_URL}/${h} (HTTP $code)"
done
bpftool btf dump file /sys/kernel/btf/vmlinux format c > "${WORK}/vmlinux.h"

# --- 3. build -----------------------------------------------------------------
log "building ${OBJ_NAME}"
cp "$SRC" "${WORK}/"
clang -O2 -g -target bpf -mcpu=v3 -D__TARGET_ARCH_x86 \
      -DVID_FOCALTECH="${HID_VID}" -DPID_FTSC1000="${HID_PID}" \
      -I"$WORK" -Wno-missing-declarations \
      -c "${WORK}/$(basename "$SRC")" -o "${WORK}/${OBJ_NAME}" 2>&1 \
    | grep -vE "does not declare anything|^ *[0-9]+ \||^ +\^|In file included from|warnings? generated" \
    || true
[[ -f "${WORK}/${OBJ_NAME}" ]] || die "build produced no object"

udev-hid-bpf inspect "${WORK}/${OBJ_NAME}" >/dev/null \
    || die "udev-hid-bpf does not recognise the built object"

# --- 4. install ---------------------------------------------------------------
log "installing to ${INSTALL_DIR}/${OBJ_NAME}"
udev-hid-bpf install --force "${WORK}/${OBJ_NAME}" >/dev/null
udevadm control --reload

# --- 5. boot-time re-apply service --------------------------------------------
# The udev attach races with the hid-generic -> hid-multitouch handover at
# boot; see the comment at the top of hid-bpf-reapply.sh. This service fixes
# it up once the device has settled, and is a no-op when the race was won.
log "installing the boot-time re-apply service"
install -d -m 0755 /usr/local/lib/honor
install -m 0755 "${SCRIPT_DIR}/hid-bpf-reapply.sh" /usr/local/lib/honor/
install -m 0644 "${SCRIPT_DIR}/honor-hid-bpf-reapply.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable honor-hid-bpf-reapply.service >/dev/null 2>&1 \
    || warn "could not enable honor-hid-bpf-reapply.service"

# --- 6. apply to the live device and verify -----------------------------------
DEV=""
for d in /sys/bus/hid/devices/*"${HID_SYSFS}"*; do [[ -e "$d" ]] && DEV="$d"; done

if [[ -z "$DEV" ]]; then
    warn "No ${HID_ID} HID device present. The fixup is installed and will be"
    warn "applied when the device appears."
    exit 0
fi

# Detach first: re-attaching is what makes the kernel recompute the fixed
# report descriptor. A plain trigger does nothing when the program is already
# loaded but was attached too early to take effect.
log "applying to ${DEV##*/}"
udev-hid-bpf remove "$DEV" >/dev/null 2>&1 || true
sleep 1
udev-hid-bpf add "$DEV" "${INSTALL_DIR}/${OBJ_NAME}" >/dev/null 2>&1 || true
sleep 1

PHANTOM=""
for d in /sys/class/input/input*; do
    [[ "$(cat "$d/name" 2>/dev/null)" == *"${HID_SYSFS}"*UNKNOWN* ]] && PHANTOM="$d"
done
[[ -z "$PHANTOM" ]] || die "phantom device is still present: $(cat "$PHANTOM/name")"

log "phantom KEY_MICMUTE device is gone."

cat <<EOF

════════════════════════════════════════════════════════════════════
  Installed.

  BPF object : ${INSTALL_DIR}/${OBJ_NAME}
  udev rule  : ${RULES_FILE}
  boot fixup : honor-hid-bpf-reapply.service

  Nothing to redo after a kernel update.

  Uninstall:
      sudo systemctl disable --now honor-hid-bpf-reapply.service
      sudo rm ${INSTALL_DIR}/${OBJ_NAME} ${RULES_FILE} \\
              /etc/systemd/system/honor-hid-bpf-reapply.service \\
              /usr/local/lib/honor/hid-bpf-reapply.sh
      sudo systemctl daemon-reload && sudo udevadm control --reload
      reboot

  Verify (must print nothing):
      grep -l UNKNOWN /sys/class/input/input*/name | xargs -r grep -H ${HID_ID%%:*}
════════════════════════════════════════════════════════════════════
EOF
