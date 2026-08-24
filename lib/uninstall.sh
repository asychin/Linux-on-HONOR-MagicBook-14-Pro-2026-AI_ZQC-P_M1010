# shellcheck shell=bash
#
# Shared preamble for the per-fix uninstallers. Source this, do not execute it.
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/uninstall.sh"
#
# --- why an uninstaller does NOT call honor_gate -------------------------------
#
# Installing is a decision about hardware, so it is gated: the profile has to
# describe this machine and list the fix. Removing is not. The cases where
# somebody most needs to take a fix off are exactly the cases where the gate
# would refuse:
#
#   * the fix was installed and then dropped from the profile, so
#     profile_lists_fix now says no;
#   * a BIOS update changed the DMI strings and detection no longer matches;
#   * the machine was recognised as the wrong board and the fix misbehaved;
#   * somebody is reverting before reporting a bug.
#
# So these run on any machine, remove what is there, and treat what is not there
# as already done. The worst case is that a machine which never had the fix has
# a few files that do not exist deleted.
#
# --- why they are not `set -e` -------------------------------------------------
#
# This is the recovery path. A machine reaching for it may already be in an odd
# state: a kernel whose module tree is gone, a bootloader config edited by hand.
# One failing step must not stop the rest. Every step reports for itself and the
# exit status reflects the total.

set -uo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

HONOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$HONOR_ROOT/lib/distro.sh"

# The kernel whose module tree is being cleaned. Overridable for the same reason
# the installers accept it: a new kernel may be installed but not yet booted.
KVER="${KVER:-$(uname -r)}"

# Counted, not fatal. uninstall_patch.sh adds up what its children report.
UNINSTALL_FAILURES="${UNINSTALL_FAILURES:-0}"

u_log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
u_warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
u_fail() {
    printf '    [warn] %s\n' "$*" >&2
    UNINSTALL_FAILURES=$((UNINSTALL_FAILURES + 1))
}

# u_rm <path>...
# Removes what exists and says so; silent about what does not. `rm -fv` prints
# nothing for a missing file anyway, but globs that match nothing would reach rm
# as a literal pattern, so they are filtered here instead.
u_rm() {
    local p removed=0
    for p in "$@"; do
        [[ -e "$p" || -L "$p" ]] || continue
        rm -rf -- "$p" && { printf '    removed %s\n' "$p"; removed=1; }
    done
    return $(( ! removed ))
}

# u_unit_off <unit>...   disable and stop, quietly, whether or not it exists
u_unit_off() {
    local u
    for u in "$@"; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
    done
}

u_daemon_reload() { systemctl daemon-reload 2>/dev/null || true; }

# u_depmod   after removing a module overlay
#
# Silent when that kernel has no module tree at all. That is not a failure of
# ours: it is a kernel that was removed, or a container, and warning about it on
# every one of the fixes that touches a module was pure noise.
u_depmod() {
    local moddir="/usr/lib/modules/${KVER}"
    [[ -d "$moddir" ]] || moddir="/lib/modules/${KVER}"
    [[ -d "$moddir" ]] || { printf '    no module tree for %s, nothing to reindex\n' "$KVER"; return 0; }
    rmdir --ignore-fail-on-non-empty "${moddir}/updates" 2>/dev/null || true
    depmod -a "$KVER" 2>/dev/null || u_fail "depmod -a $KVER failed"
}

# u_done   the exit status a per-fix uninstaller ends on, so that a problem it
# reported reaches uninstall_patch.sh instead of being swallowed by `exit 0`.
u_done() {
    (( UNINSTALL_FAILURES == 0 )) && exit 0
    printf '    %d problem(s) above were not fixed.\n' "$UNINSTALL_FAILURES" >&2
    exit 1
}

# u_regen   rebuild the initramfs and bootloader config, unless the caller says
# it will do it once for all of them. uninstall_patch.sh passes REGEN=0.
u_regen() {
    if [[ "${REGEN:-1}" != "1" ]]; then
        printf '    initramfs and bootloader left to the caller (REGEN=0)\n'
        return 0
    fi
    distro_initramfs_rebuild || u_fail "rebuild the initramfs yourself before rebooting"
    distro_bootloader_update || u_fail "regenerate your bootloader config yourself"
}
