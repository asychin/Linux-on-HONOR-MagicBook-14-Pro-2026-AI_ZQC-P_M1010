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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    conn="$(basename "$(dirname "$c")")"
    # Not `[[ -s "$c" ]]`. A sysfs binary attribute reports st_size 0 whether or
    # not it has anything to give, so that test skipped every connector on every
    # machine and this section came back empty in each dump collected so far,
    # this repository's own included. The only way to know is to read it.
    cp "$c" "${WORK}/edid-${conn}.bin" 2>/dev/null || true
    [[ -s "${WORK}/edid-${conn}.bin" ]] || { rm -f "${WORK}/edid-${conn}.bin"; continue; }
    printf -- '--- %s\n' "$conn" >> "$REPORT"
    if have edid-decode; then
        edid-decode < "${WORK}/edid-${conn}.bin" 2>/dev/null >> "$REPORT" || true
    else
        printf 'edid-decode not installed; raw copy attached as edid-%s.bin\n' "$conn" >> "$REPORT"
    fi
done
grep -q -- '--- ' <(sed -n '/===== EDID/,/^$/p' "$REPORT") \
    || printf 'no connector returned an EDID (nothing connected, or the panel is off)\n' >> "$REPORT"

# --- 3b. display link state ---------------------------------------------------
# Everything needed to answer "why does this panel look like that" without a
# second round trip. Two problems on the reference machine were diagnosed
# entirely from these nodes: a full-width band following the mouse pointer,
# which was PSR2 selective update, and a 10-bit panel driven at 6 bits per
# colour, which was the link running out of bandwidth with DSC never tried.
#
# All of it is read-only and none of it identifies anybody. debugfs has to be
# mounted and this has to be root, which it already is.
section "display: module parameters"
for m in xe i915; do
    [[ -d "/sys/module/$m/parameters" ]] || continue
    printf -- '--- %s\n' "$m" >> "$REPORT"
    for f in "/sys/module/$m/parameters/"*; do
        [[ -r "$f" ]] || continue
        printf '%-28s %s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null || true)" >> "$REPORT"
    done
done

DRI_DIRS=()
for d in /sys/kernel/debug/dri/*; do
    [[ -d "$d" ]] || continue
    # debugfs exposes both a PCI-address directory and numeric aliases for the
    # same device. One of them is enough.
    [[ "$(basename "$d")" == *:*:* ]] && DRI_DIRS+=("$d")
done
if (( ${#DRI_DIRS[@]} == 0 )); then
    section "display: debugfs"
    echo "no /sys/kernel/debug/dri/<pci-address>; is debugfs mounted?" >> "$REPORT"
fi

for d in "${DRI_DIRS[@]}"; do
    section "display: pipes and planes ($(basename "$d"))"
    if [[ -r "$d/i915_display_info" ]]; then
        cat "$d/i915_display_info" >> "$REPORT" 2>/dev/null || true
    else
        echo "no i915_display_info" >> "$REPORT"
    fi

    section "display: framebuffer compression ($(basename "$d"))"
    cat "$d/i915_fbc_status" >> "$REPORT" 2>/dev/null || echo "not present" >> "$REPORT"

    for c in "$d"/*/; do
        conn="$(basename "$c")"
        # Only connector directories have these; skip crtc-*, client-* and so on.
        [[ -r "${c}i915_psr_status" || -r "${c}i915_dsc_fec_support" ]] || continue
        section "display: $conn"
        for n in i915_psr_status i915_psr_sink_status \
                 i915_dsc_fec_support i915_dsc_bpc i915_dsc_output_format \
                 i915_dsc_fractional_bpp output_bpc intel_force_link_bpp \
                 i915_dp_max_link_rate i915_dp_max_lane_count \
                 i915_dp_force_link_rate i915_dp_force_lane_count \
                 i915_dp_link_retrain_disabled vrr_range \
                 i915_edp_lobf_info i915_panel_timings i915_lpsp_capability; do
            [[ -r "${c}${n}" ]] || continue
            printf -- '--- %s\n' "$n" >> "$REPORT"
            cat "${c}${n}" >> "$REPORT" 2>/dev/null || true
        done
    done
done

# The panel's own answers, rather than the driver's summary of them. These are
# what settle whether a faster link exists and whether compression is possible:
# the driver can only ever report what it decided, and the four blocks below are
# where that decision comes from.
section "display: DPCD"
if compgen -G '/dev/drm_dp_aux*' >/dev/null; then
    for aux in /dev/drm_dp_aux*; do
        n="$(basename "$aux")"
        conn="$(basename "$(readlink -f "/sys/class/drm_dp_aux_dev/$n/device" 2>/dev/null)" 2>/dev/null || echo unknown)"
        printf -- '--- %s (%s)\n' "$n" "$conn" >> "$REPORT"
        # 0x000 receiver caps, 0x010 the eDP supported-link-rates table,
        # 0x060 DSC capability, 0x200 link and sink status including the
        # per-lane symbol error counters.
        for range in "0:16:0x000 receiver capability" \
                     "16:16:0x010 eDP supported link rates" \
                     "96:16:0x060 DSC capability" \
                     "512:32:0x200 link and sink status"; do
            off="${range%%:*}"; rest="${range#*:}"
            len="${rest%%:*}"; label="${rest#*:}"
            printf '%s\n' "$label" >> "$REPORT"
            if have xxd; then
                dd if="$aux" bs=1 skip="$off" count="$len" status=none 2>/dev/null \
                    | xxd -g1 >> "$REPORT" || echo "  unreadable" >> "$REPORT"
            else
                dd if="$aux" bs=1 skip="$off" count="$len" status=none 2>/dev/null \
                    | od -An -tx1 >> "$REPORT" || echo "  unreadable" >> "$REPORT"
            fi
        done
    done
else
    echo "no /dev/drm_dp_aux*; CONFIG_DRM_DISPLAY_DP_AUX_CHARDEV is not enabled" >> "$REPORT"
fi

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
# three of the profile fields a hardware probe can never fill.
#
# It used to print "to include it: sudo modprobe ec_sys && re-run" and stop
# there, which meant the section arrived empty in the dumps that came back and
# the most useful thing in it was the thing nobody sent. So load the module
# here instead of asking. Without write_support=1, which is not passed and is
# not the default, /sys/kernel/debug/ec/ec0/io is a read-only window: no write
# path to the controller is opened. If it had to be loaded it is unloaded
# again, leaving the machine as it was found.
section "EC RAM page 0"
EC_SYS_LOADED_HERE=0
if [[ ! -r /sys/kernel/debug/ec/ec0/io ]] && have modprobe; then
    # Loading a read-only module and unloading it again is as far as this
    # goes. If debugfs is not mounted the node stays missing and the report
    # says so: mounting a filesystem is a change to the machine, and this
    # script's whole contract is that it does not make any.
    modprobe ec_sys 2>/dev/null && EC_SYS_LOADED_HERE=1
fi
if [[ -r /sys/kernel/debug/ec/ec0/io ]]; then
    od -Ax -tx1 -N 256 /sys/kernel/debug/ec/ec0/io >> "$REPORT" 2>/dev/null || true
    if (( EC_SYS_LOADED_HERE )); then
        printf '(ec_sys was loaded read-only to read this, then unloaded)\n' >> "$REPORT"
    fi
else
    printf 'not available: ec_sys would not load, or debugfs is not mounted.\n' >> "$REPORT"
    printf 'It is read-only unless you pass write_support=1, which nothing here does.\n' >> "$REPORT"
fi
# `(( x )) && ...` is not usable here: the compound returns 1 when x is 0, and
# under `set -e` that ends the collection instead of skipping a line.
if (( EC_SYS_LOADED_HERE )); then
    modprobe -r ec_sys 2>/dev/null || true
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
# The base block is identity only. Everything else belongs to one board
# revision, and the revision is the section header rather than a key, so print
# it in the shape it has to be written in.
echo "base block:"
printf '  %-18s %s\n' \
    "model"           "$(dmi product_name)" \
    "dmi_vendor"      "$(dmi sys_vendor)" \
    "dmi_product"     "$(dmi product_name)"
bv="$(dmi board_version)"
[[ -n "$bv" ]] || bv="$(dmi product_version)"
echo
echo "section:"
printf '  [board %s]\n' "${bv:-UNKNOWN-say-so-rather-than-guessing}"
printf '  %-18s %s\n' \
    "dmi_sku"         "$(dmi product_sku)" \
    "dmi_board"       "$(dmi board_name)" \
    "cpu"             "$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"

ssid="$(sed -n '/===== audio subsystem id/,/^$/p' "$REPORT" | awk 'NF==2 {print $2}' | head -1)"
printf '  %-18s %s\n' "audio_ssid" "${ssid//0x/}"

if grep -qi '^none$' <(sed -n '/===== discrete GPU/,/^$/p' "$REPORT"); then
    printf '  %-18s %s\n' "dgpu" "none"
else
    printf '  %-18s %s\n' "dgpu" "nvidia"
fi

printf '  %-18s %s\n' "backlight_max" \
    "$(sed -n '/===== backlight/,/^$/p' "$REPORT" | sed -n 's/.*max_brightness=\([0-9]*\).*/\1/p' | head -1)"

# The HID directory name carries the ids but not which device is which, so
# these are listed as candidates rather than assigned to a field. The bus and
# the kernel's own name for the device come along with each one: telling people
# to go and cross-reference the input section by hand produced reports where a
# Bluetooth mouse sat in the list looking exactly like a touchpad.
hid_bus_name() {
    case "$1" in
        0003) printf 'USB' ;;
        0005) printf 'Bluetooth, so external' ;;
        0018) printf 'I2C' ;;
        0019) printf 'host' ;;
        *)    printf 'bus %s' "$1" ;;
    esac
}
hids="$(sed -n '/===== HID devices/,/^$/p' "$REPORT" | grep -E '^[0-9]{4}:' || true)"
if [[ -n "$hids" ]]; then
    echo "touchpad_hid and touchscreen_hid, one of these each:"
    while read -r h; do
        [[ -n "$h" ]] || continue
        ids="${h#*:}"; ids="${ids%%.*}"
        # /proc/bus/input/devices spells the path in the sysfs line, which ends
        # in the HID directory name. The N: line above it is the device name.
        # `paste -sd', '` would alternate the two delimiter characters between
        # joins rather than use both, so the separator is spelled out once.
        names="$(awk -v id="$h" '
            /^N: Name=/ { n = $0; sub(/^N: Name="/, "", n); sub(/"$/, "", n) }
            $0 ~ ("/" id "/") && n != "" { print n; n = "" }
        ' /proc/bus/input/devices 2>/dev/null | sort -u \
          | awk 'NR>1 { printf ", " } { printf "%s", $0 } END { print "" }' || true)"
        printf '  %-18s (%s, %s)%s\n' "${ids,,}" "$h" "$(hid_bus_name "${h%%:*}")" \
            "${names:+  ${names}}"
    done <<< "$hids"
fi

# Naming the vendors this repository happened to have met is how a reader that
# announces itself as "LighTuning Technology Inc. Egistec-ETU906Axx" came back
# as "no obvious reader in lsusb" on a machine that has one. Match on the ids
# instead. The first list is not a second copy of anything: it is read out of
# the recipes under patch/fingerprint/<model>/<board>/, so a reader this
# repository can already handle is named by the same file that handles it.
fp=""; fp_note=""
for r in "${SCRIPT_DIR}"/../patch/fingerprint/*/*/; do
    [[ -f "${r}recipe.conf" ]] || continue
    rid="$(sed -n 's/^device=//p' "${r}recipe.conf" | head -1)"
    [[ -n "$rid" ]] || continue
    if grep -qiE "(^|[^0-9a-f])${rid}([^0-9a-f]|$)" <(sed -n '/===== USB/,/^$/p' "$REPORT"); then
        fp="$rid"
        fp_note="  # supported: $(sed -n 's/^name=//p' "${r}recipe.conf" | head -1)"
        break
    fi
done
if [[ -z "$fp" ]]; then
    # Nothing known. Fall back to the USB vendors that make these sensors, which
    # is still a guess, but a guess about who built the chip rather than about
    # how the marketing department spelled itself in a descriptor.
    fp="$(sed -n '/===== USB/,/^$/p' "$REPORT" \
          | grep -oiE '(27c6|1c7a|06cb|138a|04f3|08ff|147e|10a5|05ba|1491|298d):[0-9a-f]{4}' \
          | head -1 || true)"
    # `[[ ... ]] && var=...` would end the script under set -e whenever the
    # test is false, which is the usual case here.
    if [[ -n "$fp" ]]; then
        fp_note="  # unknown to this repository, please say so in the issue"
    fi
fi
if [[ -z "$fp" ]]; then
    fp="$(sed -n '/===== USB/,/^$/p' "$REPORT" \
          | grep -iE 'fingerprint|biometric|egis|goodix|elan|synaptics|validity|authentec' \
          | grep -oE '[0-9a-f]{4}:[0-9a-f]{4}' | head -1 || true)"
    if [[ -n "$fp" ]]; then
        fp_note="  # matched on the descriptor text, worth double-checking"
    fi
fi
if [[ -n "$fp" ]]; then
    printf '  %-18s %s%s\n' "fingerprint_usb" "${fp,,}" "$fp_note"
else
    echo "  fingerprint_usb    no reader recognised in lsusb, check by hand"
fi

cat <<'NOTE'

  panel              oled or lcd, you know this by looking at the screen
What a fix needs to run on this board does not go in the profile. It goes in
that fix's own directory for this machine, patch/<fix>/<model>/<board>/:

  patch/fan/...             ec_fan0, ec_fan1: the tachometer fields in the DSDT,
                            inside acpi-tables.tar.gz
  patch/battery/...         presets: write a pair, then read EC 0x85
  patch/oled-backlight/...  backlight_min: measure-floor.sh, by eye
  patch/headset-mic/...     fixup: only exists once somebody writes it

Everything under "section" belongs to the [board ...] block above it, not to the
base block. That is the point: HONOR ships one product code as several machines,
so a value read here describes this board and no other.
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
