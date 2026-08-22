# shellcheck shell=bash
#
# One line of protection for an installer that can be run on its own.
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/gate.sh"
#   honor_gate fan
#
# apply_patch.sh has already identified the machine by the time it calls a
# fix, and passes the answer down in HONOR_PROFILE so the work is not repeated
# and the banner is not printed twice. Run the installer directly and it does
# the detection itself, which is the point: patch/fan/install.sh on the wrong
# laptop has to refuse whether or not it was reached through apply_patch.sh.
#
# On success PROFILE is loaded, so profile_get and profile_has work in the
# caller.

HONOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_gate_die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

[[ -r "$HONOR_ROOT/lib/profile.sh" && -r "$HONOR_ROOT/lib/detect.sh" ]] \
    || _gate_die "cannot find lib/profile.sh and lib/detect.sh under $HONOR_ROOT.
    Run this from a full checkout of the repository."

# shellcheck source=/dev/null
source "$HONOR_ROOT/lib/profile.sh"
# shellcheck source=/dev/null
source "$HONOR_ROOT/lib/detect.sh"
# Everything that differs between distributions. Sourced here so a gated
# installer never has to work out where the kernel config lives or how this
# distribution compresses its modules.
# shellcheck source=/dev/null
source "$HONOR_ROOT/lib/distro.sh"

honor_gate() {
    local fix="$1" root="$HONOR_ROOT"

    if [[ -n "${HONOR_PROFILE:-}" ]]; then
        profile_load "$HONOR_PROFILE" \
            || _gate_die "HONOR_PROFILE=$HONOR_PROFILE could not be loaded."
        detect_read_dmi
    else
        local rc=0
        detect_profile "$root/devices" || rc=$?
        if (( rc != 0 )); then
            _gate_die "This machine is $(detect_describe)
    and no profile in devices/ describes it.

    This installer carries values measured on one specific laptop. Applied to
    different hardware they do not simply fail, they misconfigure it.

    If this is a HONOR MagicBook, please open an issue with a hardware dump:
    the template lists the commands and all of them are read-only."
        fi
        printf '\033[1;32m==>\033[0m %s\n' "machine: $(detect_describe)"
        printf '\033[1;32m==>\033[0m %s\n' "profile: $(profile_get model) ($(profile_get status))"
    fi

    if ! profile_lists_fix "$fix"; then
        _gate_die "$(profile_get model) does not list '$fix' as a fix it needs.
    If it does need it, say so in devices/$(basename "${DETECT_PROFILE:-${HONOR_PROFILE:-?}}")."
    fi

    if ! fix_allowed "$fix"; then
        _gate_die "'$fix' is a tier ${FIX_TIER[$fix]} fix and the profile for
    $(profile_get model) is marked '$(profile_get status)'.

    Tier B and C fixes carry constants that were measured on one machine: an
    audio subsystem id, a backlight floor, EC register offsets, an ACPI table.
    They stay disabled until somebody runs them on that model and marks the
    profile verified."
    fi
}

# gate_param <key> <fallback-env-var> -> value
# Profile value wins; an explicit environment override wins over that, so
# somebody measuring a new floor can still say VBT_MIN=14 without editing a
# profile first.
gate_param() {
    local key="$1" envvar="${2:-}" v=""
    [[ -n "$envvar" ]] && v="${!envvar:-}"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    profile_has "$key" || return 1
    profile_get "$key"
}

# --- migration off the old zqcp-flavoured names -------------------------------
# Everything installed at runtime used to carry "zqcp" in its name, which was
# wrong the moment a second model appeared. These helpers let each installer
# clean up after the rename, and only for the artefacts it owns: a blanket
# cleanup would happily delete a rule that the installer being run is not going
# to reinstall.

_legacy_say() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

# legacy_move <old> <new>
# Moves a leftover file or directory into its new name. If both exist the new
# one wins and the old is left alone, so nothing is ever silently overwritten.
legacy_move() {
    local old="$1" new="$2"
    [[ -e "$old" ]] || return 0
    if [[ -e "$new" ]]; then
        _legacy_say "both $old and $new exist; leaving the old one in place.
    Remove $old by hand once you have checked you do not need it."
        return 0
    fi
    mkdir -p "$(dirname "$new")"
    mv "$old" "$new"
    _legacy_say "migrated $old -> $new"
}

# legacy_drop <path>...
# Removes leftovers that the caller is about to replace under a new name.
legacy_drop() {
    local p
    for p in "$@"; do
        [[ -e "$p" ]] || continue
        rm -rf "$p"
        _legacy_say "removed the pre-rename $p"
    done
}

# --- fields that legitimately hold several values -----------------------------
# The same model is sold with different parts in different regions: a ZQC-P has
# a Goodix fingerprint reader in one market and a LighTuning one in another, and
# the FMB-P has at least five between them. Splitting those into separate
# profiles does not work, because they report the same DMI product name and are
# indistinguishable before boot.
#
# They are, however, trivially distinguishable *after* boot: a USB or HID id is
# right there in sysfs. So the profile lists what a model is known to ship, and
# the installer picks the one actually fitted. A field with one value behaves
# exactly as before.

# gate_probe_usb <key>
# Prints the id from that profile field which is actually present on this USB
# bus. Returns 1 if the field is unset, 2 if none of the listed devices is here.
gate_probe_usb() {
    local key="$1" id list
    profile_has "$key" || return 1
    list="$(profile_get "$key")"
    for id in $list; do
        lsusb -d "$id" >/dev/null 2>&1 && { printf '%s' "$id"; return 0; }
    done
    return 2
}

# gate_probe_hid <key>
# Same, against the HID bus. sysfs spells these in upper case.
gate_probe_hid() {
    local key="$1" id up d
    profile_has "$key" || return 1
    for id in $(profile_get "$key"); do
        up="${id^^}"
        for d in /sys/bus/hid/devices/*"${up}"*; do
            [[ -e "$d" ]] && { printf '%s' "$id"; return 0; }
        done
    done
    return 2
}

# gate_list_first <key>   the first entry, for callers that just need a default
gate_list_first() {
    local v
    profile_has "$1" || return 1
    v="$(profile_get "$1")"
    printf '%s' "${v%% *}"
}
