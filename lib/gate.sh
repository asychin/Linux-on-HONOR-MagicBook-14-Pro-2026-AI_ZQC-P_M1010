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
# Finding the upstream tree that matches the running kernel. Sourced here for
# the same reason: five installers need it, and when each worked it out for
# itself they were all wrong together.
# shellcheck source=/dev/null
source "$HONOR_ROOT/lib/ksrc.sh"
# Where a fix keeps the parts of itself that belong to one machine, laid out the
# same way a profile is: patch/<fix>/<model>/<board>/.
# shellcheck source=/dev/null
source "$HONOR_ROOT/lib/variant.sh"

# honor_lock <name>
#
# One run of a thing at a time. File descriptor 9 by convention, released by the
# kernel when the process exits, so a script that dies does not leave it held.
#
# This exists because patch/fingerprint/install.sh was found running twice at
# once: its own `pacman -S` named libfprint as a transaction target, which fired
# the auto-rebuild hook, which deferred a second copy of the same script, and
# the two raced in one build directory. The same shape is reachable for every
# fix the deferred rebuild re-runs after a kernel update, so the lock is taken
# for all of them rather than for the one where it was noticed.
honor_lock() {
    # Two statements, not one `local a=.. b=..${a}..`: bash expands every word of
    # the command before it assigns any of them, so the second would read an
    # unset variable and die under set -u.
    local name="$1"
    local lock="/var/lock/honor-${name}.lock"
    # Some containers and minimal images have no /var/lock. Tested first rather
    # than relying on `exec 9>"$lock" 2>/dev/null`: exec applies its
    # redirections left to right, so fd 9 is opened, and its failure printed,
    # before 2>/dev/null is in effect. The message reached the user.
    [[ -d /var/lock ]] || return 0
    exec 9>"$lock" || return 0
    if ! flock -n 9; then
        printf '\033[1;32m==>\033[0m %s\n' \
            "another run of '${name}' is already in progress; leaving it to that one."
        exit 0
    fi
}

honor_gate() {
    local fix="$1" root="$HONOR_ROOT"

    if [[ -n "${HONOR_PROFILE:-}" ]]; then
        profile_load "$HONOR_PROFILE" \
            || _gate_die "HONOR_PROFILE=$HONOR_PROFILE could not be loaded."
        # The file names the product; the board revision decides which section
        # of it describes the machine actually running this, and how far it is
        # trusted. apply_patch.sh passes the file down, not the answer, so the
        # board has to be chosen here too.
        detect_read_dmi
        profile_select_board "$DETECT_BOARD_VERSION"
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
        printf '\033[1;32m==>\033[0m %s\n' \
            "profile: $(profile_get model) board ${PROFILE_BOARD:-?} ($(profile_get status))"
    fi

    local note
    note="$(detect_board_note)"
    if [[ -n "$note" ]]; then
        printf '\033[1;33m==>\033[0m %s\n' "$note" >&2
    fi

    if ! profile_lists_fix "$fix"; then
        _gate_die "$(profile_get model) board ${PROFILE_BOARD:-?} does not list '$fix' as a fix it needs.
    If it does need it, say so under the matching [board ...] section in
    devices/$(basename "${DETECT_PROFILE:-${HONOR_PROFILE:-?}}")."
    fi

    if ! fix_allowed "$fix"; then
        _gate_die "'$fix' is a tier ${FIX_TIER[$fix]} fix and board ${PROFILE_BOARD:-?} of
    $(profile_get model) is marked '$(profile_get status)'.

    Tier B and C fixes carry constants that were measured on one machine: an
    audio subsystem id, a backlight floor, EC register offsets, an ACPI table.
    HONOR ships one product code as several boards, so measured on a
    $(profile_get model) is not the same statement as measured on this one. They
    stay disabled until somebody runs them on board ${PROFILE_BOARD:-?} and marks
    that section verified."
    fi

    # Past every refusal, so what follows may build and install. Serialise from
    # here rather than at the top: a refusal should never wait behind another
    # run, and two refusals at once are harmless.
    honor_lock "$fix"
}

# gate_wait_until <seconds> <command...> -> 0 as soon as the command succeeds
#
# `udev-hid-bpf add` returns before the kernel has finished re-probing the
# device, so checking once after a fixed sleep is a coin toss. It normally
# settles in about 200 ms, and it was seen losing that toss on a machine where
# the attach had in fact worked: the installer then died red, saying the program
# was not attached to a device it was attached to. Waiting for the state instead
# of for a duration is both faster in the usual case and correct in the unusual
# one.
gate_wait_until() {
    local deadline=$(( SECONDS + $1 ))
    shift
    while :; do
        "$@" && return 0
        (( SECONDS >= deadline )) && return 1
        sleep 0.2
    done
}

# gate_param <key> <fallback-env-var> -> value
# Profile value wins; an explicit environment override wins over that, so
# somebody can override an inventory value from the environment without editing
# a profile first. The numbers a fix needs are not here: those come out of that
# fix's own directory for the machine, through recipe_param in lib/variant.sh.
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

# gate_hid_devpath <vid:pid>
# The /sys/bus/hid/devices entry for that id, or nothing. sysfs spells the id in
# upper case and prefixes it with the bus number, so this is a glob rather than
# a path; having it in one place is what stops installers writing the id of the
# machine they were developed on into the glob.
gate_hid_devpath() {
    local up="${1^^}" d out=""
    for d in /sys/bus/hid/devices/*"${up}"*; do
        [[ -e "$d" ]] && out="$d"
    done
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

# gate_hwdb_dmi_match
# The DMI part of a udev hwdb match glob for exactly the machine this is running
# on, board revision included.
#
# The hwdb files in this repository carry a @HONOR_DMI_MATCH@ placeholder rather
# than a written-out product name. A rule keyed on the product alone applies to
# every revision HONOR ships under it, which for a battery preset or a keyboard
# scancode means one board's measurement quietly reaching a board nobody
# measured. `rvr` is board_version in the DMI modalias; hwdb globs are fnmatch
# without FNM_PATHNAME, so `*` spans the colons between fields.
gate_hwdb_dmi_match() {
    local g="svn${DETECT_VENDOR}*pn${DETECT_PRODUCT}*"
    [[ -n "$DETECT_BOARD_VERSION" ]] && g+="rvr${DETECT_BOARD_VERSION}*"
    printf '%s' "$g"
}

# gate_hwdb_render <template> <destination> [extra sed expressions...]
# Copies a hwdb template with the placeholder filled in.
gate_hwdb_render() {
    local src="$1" dst="$2"
    shift 2
    local -a expr=(-e "s|@HONOR_DMI_MATCH@|$(gate_hwdb_dmi_match)|g")
    local e
    for e in "$@"; do expr+=(-e "$e"); done
    install -d -m 0755 "$(dirname "$dst")"
    sed "${expr[@]}" "$src" > "$dst"
    chmod 0644 "$dst"
}

