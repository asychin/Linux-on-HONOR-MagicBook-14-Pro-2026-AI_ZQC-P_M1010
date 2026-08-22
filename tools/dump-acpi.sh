#!/usr/bin/env bash
# Dump this machine's ACPI tables, ready to drop into dump/acpi/<model>/.
#
#   sudo bash tools/dump-acpi.sh
#
# Read-only. It reads the firmware tables and disassembles them.
#
# This is the first step in producing an ACPI override for a model this
# repository does not cover. What to do with the result: docs/RESEARCH.md
#
# IMPORTANT: acpidump goes through the kernel, which has already applied any
# initrd table override. If one is installed, what you get back is the *patched*
# table, not the firmware's own. Verified here by comparing sizes. To capture
# the original, boot once without the override (remove it from the initrd, or
# pick a boot entry that does not load it) and dump then.

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

for t in acpidump acpixtract iasl; do
    command -v "$t" >/dev/null || {
        echo "missing $t. Install the ACPICA tools:" >&2
        echo "  Arch/CachyOS: pacman -S acpica     Debian/Ubuntu: apt install acpica-tools" >&2
        echo "  Fedora: dnf install acpica-tools" >&2
        exit 1
    }
done

OVERRIDE_PRESENT=no
MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
MODEL_LC="$(printf '%s' "${MODEL,,}" | tr -c 'a-z0-9-' '-')"
BIOS="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo unknown)"
OUT="${1:-acpi-${MODEL_LC}-bios${BIOS}}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

if [[ -e /usr/lib/firmware/acpi ]] && compgen -G "/usr/lib/firmware/acpi/*.aml" >/dev/null; then
    warn "An ACPI override is installed in /usr/lib/firmware/acpi, and acpidump"
    warn "goes through the kernel, which has already applied it. This dump will"
    warn "therefore contain the PATCHED table, not your firmware's own."
    warn ""
    warn "For a factory dump, boot once without the override and run this again."
    warn "Continuing anyway; MACHINE.txt records that the override was present."
    OVERRIDE_PRESENT=yes
fi

mkdir -p "$OUT"
cd "$OUT"

log "machine: $MODEL, BIOS $BIOS"
log "dumping"
acpidump > acpi.dump
acpixtract -a acpi.dump >/dev/null

# MSDM carries the machine's Windows OEM licence key in clear text, and this
# dump is meant to be attached to a public issue. It has nothing to do with any
# fix here. Delete it before anything else touches the directory.
for t in msdm.dat MSDM.dat; do
    [[ -f "$t" ]] && { rm -f "$t"; log "removed $t (it contains the Windows product key)"; }
done
rm -f acpi.dump    # the combined dump contains MSDM too

log "disassembling"
mkdir -p dsl
fail=0
for f in *.dat; do
    [[ -e "$f" ]] || continue
    b="${f%.dat}"
    # -e supplies the DSDT and SSDTs as external references so method calls
    # across tables resolve; without it the listings are full of unresolved
    # names and the interesting code is unreadable.
    if iasl -e dsdt.dat,ssdt*.dat -d "$f" >/dev/null 2>&1 || iasl -d "$f" >/dev/null 2>&1; then
        [[ -f "${b}.dsl" ]] && mv "${b}.dsl" "dsl/${b^^}.dsl"
    else
        fail=$((fail + 1))
    fi
    mv "$f" "${b^^}.aml"
done
(( fail )) && warn "$fail table(s) would not disassemble; the .aml files are still here"

# Which table holds the I2C devices is the one that matters on these machines.
log "tables that declare I2C devices:"
for f in *.aml; do
    oem=$(dd if="$f" bs=1 skip=16 count=8 2>/dev/null | tr -d '\0 ')
    case "$oem" in
        *I2C*|*DEVT*) printf '    %-14s OEM table id %s  %s bytes\n' "$f" "$oem" "$(stat -c%s "$f")" ;;
    esac
done

cat > MACHINE.txt <<EOF
product_name  $MODEL
bios_version  $BIOS
bios_date     $(cat /sys/class/dmi/id/bios_date 2>/dev/null)
board_name    $(cat /sys/class/dmi/id/board_name 2>/dev/null)
product_sku   $(cat /sys/class/dmi/id/product_sku 2>/dev/null)
kernel        $(uname -r)
acpi_override ${OVERRIDE_PRESENT:-no}   # yes = these tables are NOT the factory ones
dumped        $(date -Iseconds)
EOF

[[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER" . 2>/dev/null || true
cd ..
log "written to $OUT/"
echo
echo "  Next: move it to dump/acpi/<model>/ if you are adding it to the repository."
echo "  docs/RESEARCH.md explains what to look for. To contribute it, attach $OUT/"
echo "  to an issue. acpi.dump and MSDM are deleted on the way out: the first is"
echo "  only the raw concatenation of the rest, the second carries your Windows key."
