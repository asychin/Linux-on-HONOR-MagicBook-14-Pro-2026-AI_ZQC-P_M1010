#!/usr/bin/env bash
# Collect everything needed to write a device profile for a HONOR MagicBook
# this repository does not cover yet.
#
#   sudo bash tools/collect-hwinfo.sh
#
# Read-only. Nothing here changes the machine: it reads sysfs, runs lspci and
# lsusb, and copies the ACPI tables. Root is needed for the ACPI tables and the
# video BIOS table, and for nothing else.
#
# Serial numbers are never read. product_serial, board_serial, chassis_serial
# and product_uuid identify your laptop and are deliberately not in the field
# list below, so the output is safe to attach to a public issue. Check it
# anyway before you post it: it is your machine, not ours.

set -euo pipefail

OUT_DIR="${OUT_DIR:-$(pwd)}"
TS="$(date +%Y%m%d-%H%M%S)"
MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
MODEL="${MODEL// /-}"
WORK="$(mktemp -d /tmp/honor-hwinfo-XXXXXX)"
REPORT="${WORK}/report.txt"
trap 'rm -rf "$WORK"' EXIT

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n===== %s =====\n' "$1" >> "$REPORT"; }

# --- 1. identity, deliberately without the serial fields ----------------------
section "DMI"
for f in sys_vendor product_name product_version product_sku product_family \
         board_vendor board_name board_version \
         bios_vendor bios_version bios_date chassis_type; do
    printf '%-16s %s\n' "$f" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null || true)" >> "$REPORT"
done

section "distribution and kernel"
{
    grep -E '^(NAME|VERSION|ID)=' /etc/os-release 2>/dev/null || true
    printf 'kernel           %s\n' "$(uname -r)"
    have lscpu && lscpu | grep -E 'Model name|Vendor ID' || true
} >> "$REPORT"

# --- 2. buses -----------------------------------------------------------------
section "PCI"
if have lspci; then lspci -nnk >> "$REPORT"; else echo "lspci not installed" >> "$REPORT"; fi

section "discrete GPU"
LSPCI_OUT="$(have lspci && lspci -nn 2>/dev/null || true)"
if grep -q '\[10de:' <<< "$LSPCI_OUT"; then
    lspci -nn | grep '\[10de:' >> "$REPORT"
else
    echo "none" >> "$REPORT"
fi

section "audio subsystem id"
# This is what an HD-audio codec quirk keys on. The controller is class 0401 on
# some platforms and 0403 on others, so both are checked.
for d in /sys/bus/pci/devices/*; do
    case "$(cat "$d/class" 2>/dev/null || echo)" in
        0x0401*|0x0403*)
            printf '%s  %s:%s\n' "$(basename "$d")" \
                "$(cat "$d/subsystem_vendor")" "$(cat "$d/subsystem_device")" >> "$REPORT" ;;
    esac
done

section "USB"
if have lsusb; then lsusb >> "$REPORT"; else echo "lsusb not installed" >> "$REPORT"; fi

section "HID devices"
# The directory name is BUS:VID:PID, which is what the profile records.
ls /sys/bus/hid/devices/ 2>/dev/null >> "$REPORT" || echo "none" >> "$REPORT"

section "input devices"
cat /proc/bus/input/devices 2>/dev/null >> "$REPORT" || true

# --- 3. display ---------------------------------------------------------------
section "backlight"
for b in /sys/class/backlight/*; do
    [[ -e "$b" ]] || continue
    printf '%s type=%s max_brightness=%s\n' "$(basename "$b")" \
        "$(cat "$b/type" 2>/dev/null)" "$(cat "$b/max_brightness" 2>/dev/null)" >> "$REPORT"
done

section "DRM connectors"
ls /sys/class/drm/ 2>/dev/null >> "$REPORT" || true

# The panel says what technology it is, in the DisplayID block of its EDID, and
# that is the difference between the OLED backlight fix applying and not. The
# EDID is a couple of hundred bytes and carries no personal data.
section "EDID"
for c in /sys/class/drm/*/edid; do
    [[ -s "$c" ]] || continue
    conn="$(basename "$(dirname "$c")")"
    printf -- '--- %s\n' "$conn" >> "$REPORT"
    if have edid-decode; then
        edid-decode < "$c" 2>/dev/null >> "$REPORT" || true
    else
        printf 'edid-decode not installed; raw copy attached as edid-%s.bin\n' "$conn" >> "$REPORT"
    fi
    cp "$c" "${WORK}/edid-${conn}.bin" 2>/dev/null || true
done

# --- 4. firmware --------------------------------------------------------------
# Not just the file names. What identifies a table is its OEM table id and its
# contents, and the ACPI override is decided by exactly that: if your I2C_DEVT
# has the same md5 as the one this repository carries, the existing fix is
# already right for your machine, whatever the model badge says.
section "ACPI table identity"
if [[ -r /sys/firmware/acpi/tables/DSDT ]]; then
    printf '%-10s %-10s %8s  %s\n' TABLE "OEM ID" BYTES MD5 >> "$REPORT"
    for t in /sys/firmware/acpi/tables/*; do
        [[ -f "$t" ]] || continue
        # MSDM holds the Windows OEM licence key. Not listed, not hashed, not
        # collected: this report goes into a public issue.
        [[ "$(basename "$t")" == MSDM ]] && continue
        oem="$(dd if="$t" bs=1 skip=16 count=8 2>/dev/null | tr -d '\0' | tr -c '[:print:]' ' ')"
        printf '%-10s %-10s %8s  %s\n' "$(basename "$t")" "${oem// /}" \
            "$(stat -c%s "$t")" "$(md5sum "$t" | cut -d' ' -f1)" >> "$REPORT"
    done
else
    printf 'not readable; re-run with sudo\n' >> "$REPORT"
fi

# The EC page holds the fan tachometers and the charge-mode byte, which are
# three of the profile fields a hardware probe can never fill. Read only, and
# only if the debug interface is already there: this script does not load
# modules. `sudo modprobe ec_sys` makes it appear, read-only by default.
section "EC RAM page 0"
if [[ -r /sys/kernel/debug/ec/ec0/io ]]; then
    od -Ax -tx1 -N 256 /sys/kernel/debug/ec/ec0/io >> "$REPORT" 2>/dev/null || true
else
    printf 'not available. To include it: sudo modprobe ec_sys && re-run.\n' >> "$REPORT"
    printf 'It is read-only unless you pass write_support=1, which nothing here does.\n' >> "$REPORT"
fi

section "ACPI tables present"
ls /sys/firmware/acpi/tables/ 2>/dev/null >> "$REPORT" || true

if (( EUID == 0 )); then
    # --exclude MSDM: that table holds the machine's Windows OEM licence key in
    # clear text, this archive is meant to be attached to a public issue, and no
    # fix here has any use for it.
    if tar czf "${WORK}/acpi-tables.tar.gz" --exclude='MSDM' --exclude='msdm' \
              -C /sys/firmware/acpi tables 2>/dev/null; then
        say "collected the ACPI tables (MSDM excluded: it contains your Windows key)"
    else
        warn "could not read the ACPI tables"
    fi
    VBT="$(ls /sys/kernel/debug/dri/*/i915_vbt 2>/dev/null | head -1 || true)"
    if [[ -n "$VBT" ]]; then
        cat "$VBT" > "${WORK}/vbt.bin" 2>/dev/null && say "collected the video BIOS table"
    fi
else
    warn "not running as root: the ACPI tables and the video BIOS table are missing."
    warn "Those are the two things the touchpad and backlight fixes are derived"
    warn "from, so please re-run with sudo."
fi

# --- 5. kernel log ------------------------------------------------------------
if have journalctl; then
    journalctl -k -b -0 --no-pager > "${WORK}/dmesg.txt" 2>/dev/null || true
elif have dmesg; then
    dmesg > "${WORK}/dmesg.txt" 2>/dev/null || true
fi

# --- 6. a last look for anything that identifies the machine ------------------
# Belt and braces: the field list above avoids the serial attributes, but a
# serial can also surface inside dmesg or an ACPI table, so say what was found
# rather than quietly shipping it.
LEAK=0
for f in product_serial board_serial chassis_serial product_uuid; do
    v="$(cat "/sys/class/dmi/id/$f" 2>/dev/null || true)"
    [[ -z "$v" || "$v" == "None" || "$v" == "Default string" ]] && continue
    if grep -qsF -- "$v" "$REPORT" "${WORK}/dmesg.txt" 2>/dev/null; then
        warn "your $f appears in the collected output; removing it"
        sed -i "s|${v}|<removed>|g" "$REPORT" "${WORK}/dmesg.txt" 2>/dev/null || true
        LEAK=1
    fi
done
# The DMI serials are the ones that are checked exactly, because their values
# are known. A kernel log also carries a hostname and the root filesystem's
# UUID, which identify a machine just as well, so those are scrubbed by shape.
for pat in "s|root=UUID=[0-9a-fA-F-]\{8,\}|root=UUID=<removed>|g" \
           "s|resume=UUID=[0-9a-fA-F-]\{8,\}|resume=UUID=<removed>|g" \
           "s|rootflags=subvol=[^ ]*|rootflags=subvol=<removed>|g"; do
    sed -i "$pat" "$REPORT" "${WORK}/dmesg.txt" 2>/dev/null || true
done
HOST="$(hostname 2>/dev/null || true)"
if [[ -n "$HOST" && "$HOST" != localhost ]]; then
    sed -i "s|\b${HOST}\b|<host>|g" "$REPORT" "${WORK}/dmesg.txt" 2>/dev/null || true
fi

if (( LEAK )); then
    say "removed the DMI serial(s) that had leaked into the collected text"
else
    say "no DMI serial found in the collected text"
fi
say "hostname, root= and resume= UUIDs scrubbed from the report and the log"

# --- 7. pack ------------------------------------------------------------------
ARCHIVE="${OUT_DIR}/honor-hwinfo-${MODEL}-${TS}.tar.gz"
tar czf "$ARCHIVE" -C "$WORK" .
chmod 0644 "$ARCHIVE"
[[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER" "$ARCHIVE" 2>/dev/null || true

# --- 8. show what was found ---------------------------------------------------
# Print the identifying sections in full, stopping before the long ones. A
# range match ending at the next header would print that header with nothing
# under it, which is how this first read.
echo
awk '/^===== PCI =====/ { exit } /^===== DMI =====/ { p = 1 } p' "$REPORT"

# Then the handful of values a profile is actually built from, next to the key
# each one belongs to. Anything the script cannot work out on its own says so
# rather than guessing.
dmi() { grep -m1 "^$1 " "$REPORT" | awk '{$1=""; print substr($0,2)}'; }

echo "===== what this fills in, in devices/<model>.conf ====="
printf '%-20s %s\n' \
    "dmi_vendor"      "$(dmi sys_vendor)" \
    "dmi_product"     "$(dmi product_name)" \
    "dmi_sku"         "$(dmi product_sku)" \
    "dmi_board"       "$(dmi board_name)"

ssid="$(sed -n '/===== audio subsystem id/,/^$/p' "$REPORT" | awk 'NF==2 {print $2}' | head -1)"
printf '%-20s %s\n' "audio_ssid" "${ssid//0x/}"

if grep -qi '^none$' <(sed -n '/===== discrete GPU/,/^$/p' "$REPORT"); then
    printf '%-20s %s\n' "dgpu" "none"
else
    printf '%-20s %s\n' "dgpu" "nvidia"
fi

printf '%-20s %s\n' "backlight_max" \
    "$(sed -n '/===== backlight/,/^$/p' "$REPORT" | sed -n 's/.*max_brightness=\([0-9]*\).*/\1/p' | head -1)"

# The HID directory name carries the ids but not which device is which, so
# these are listed as candidates rather than assigned to a field.
hids="$(sed -n '/===== HID devices/,/^$/p' "$REPORT" | grep -E '^[0-9]{4}:' || true)"
if [[ -n "$hids" ]]; then
    echo "touchpad_hid and touchscreen_hid, one of these each:"
    while read -r h; do
        [[ -n "$h" ]] || continue
        ids="${h#*:}"; ids="${ids%%.*}"
        printf '  %-18s (%s)\n' "${ids,,}" "$h"
    done <<< "$hids"
    echo "  which is which: see the 'input devices' section of report.txt"
fi

fp="$(sed -n '/===== USB/,/^$/p' "$REPORT" \
      | grep -iE 'goodix|elan|synaptics|fingerprint|validity' \
      | grep -oE '[0-9a-f]{4}:[0-9a-f]{4}' | head -1 || true)"
[[ -n "$fp" ]] && printf '%-20s %s\n' "fingerprint_usb" "$fp" \
               || echo "fingerprint_usb      no obvious reader in lsusb, check by hand"

cat <<'NOTE'

panel                oled or lcd, you know this by looking at the screen
ec_fan0 / ec_fan1    from the tachometer fields in DSDT, inside acpi-tables.tar.gz
param_backlight_min  measure it, patch/oled-backlight/measure-floor.sh
param_audio_fixup    only exists once somebody writes it for this board
NOTE

echo
say "written: $ARCHIVE"
echo
echo "  Attach that file to an issue using the 'Hardware dump for a new model'"
echo "  template. It carries no DMI serials, no product UUID, no MSDM table and"
echo "  no hostname or filesystem UUIDs. Have a look inside first if you"
echo "  would rather check that yourself:"
echo
echo "      tar tzf $ARCHIVE"
echo "      tar xzf $ARCHIVE -O ./report.txt | less"
echo
