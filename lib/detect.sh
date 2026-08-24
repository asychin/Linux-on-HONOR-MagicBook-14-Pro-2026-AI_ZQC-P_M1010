# shellcheck shell=bash
#
# The DETECT_* variables are this file's interface. Every installer sources it
# and reads them, which shellcheck cannot see from here.
# shellcheck disable=SC2034
#
# Work out which device profile describes the machine we are running on, and
# which board revision inside it. Source this after lib/profile.sh.
#
# product_name alone is not an identifier. HONOR sells a whole line under one
# string: DRB-P covers both the UMA machine and the HUNTER one with a discrete
# RTX, and DRA-XX covers every 2024 MagicBook Pro 16 regardless of CPU or GPU.
# So candidates are first selected on vendor plus product, then narrowed by
# whether a discrete GPU is present, then by board, board revision and SKU.
#
# That order is deliberate. dmi_sku is last because it is not model-unique on
# these machines: SKU C233 is reported by ZQC-P, XWC-P, an FMB-P (board M1090),
# a DRA-XX (board M1030) and BCC-N. It can only ever confirm, never decide.
#
# Matching is exact, never a substring: FMB-P is a prefix of FMB-PM, and the
# kernel's own DMI_MATCH being a substring test is exactly why the upstream
# atkbd quirk for FMB-P also catches FMB-PM.
#
# --- two steps, not one -------------------------------------------------------
#
# Picking the file is only half the job. board_version is not just a tiebreaker
# between files; it is the thing that decides which machine this is. ZQC-P is
# board M1010 with a Core Ultra X9 388H here and board M1050 with a Core Ultra 5
# 338H in issue #1, and there is one ZQC-P file. So after a file is chosen,
# profile_select_board picks the section inside it, and a revision nobody has
# described gets the product-level facts with the trust taken away rather than
# the constants measured on somebody else's board.

DETECT_VENDOR=""
DETECT_PRODUCT=""
DETECT_SKU=""
DETECT_BOARD=""
DETECT_BOARD_VERSION=""
DETECT_PROFILE=""

_dmi() {
    local v=""
    [[ -r "/sys/class/dmi/id/$1" ]] && v="$(cat "/sys/class/dmi/id/$1" 2>/dev/null || true)"
    # trim; some firmwares pad these with spaces
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

detect_read_dmi() {
    DETECT_VENDOR="$(_dmi sys_vendor)"
    DETECT_PRODUCT="$(_dmi product_name)"
    DETECT_SKU="$(_dmi product_sku)"
    DETECT_BOARD="$(_dmi board_name)"
    # DMI type 2 Version. Every HONOR probe read so far has type 1 and type 2
    # Version agreeing, so product_version serves when the board field is blank.
    DETECT_BOARD_VERSION="$(_dmi board_version)"
    [[ -n "$DETECT_BOARD_VERSION" ]] || DETECT_BOARD_VERSION="$(_dmi product_version)"
}

# 0 if a discrete NVIDIA GPU is present. dGPU support is out of scope; this
# only tells two variants of the same product_name apart.
detect_has_nvidia() {
    command -v lspci >/dev/null || return 1
    # Not piped into grep -q: that exits at the first match, lspci can die of
    # SIGPIPE, and under `set -o pipefail` the whole thing then reports failure
    # on exactly the machines that do have a discrete GPU. Which profile gets
    # picked depends on this answer, so it has to be the right one.
    local out
    out="$(lspci -nn 2>/dev/null)" || return 1
    grep -q '\[10de:' <<< "$out"
}

detect_describe() {
    printf '%s / %s' "${DETECT_VENDOR:-?}" "${DETECT_PRODUCT:-?}"
    [[ -n "$DETECT_SKU"   ]] && printf ' / SKU %s' "$DETECT_SKU"
    [[ -n "$DETECT_BOARD" ]] && printf ' / board %s' "$DETECT_BOARD"
    [[ -n "$DETECT_BOARD_VERSION" ]] && printf ' %s' "$DETECT_BOARD_VERSION"
    printf '\n'
}

# detect_profile <devices-dir>
#   0  exactly one profile matched, path in DETECT_PROFILE, loaded, and a board
#      section selected. PROFILE_BOARD_MATCH says how well that section fits.
#   1  nothing matched
#   2  several matched and could not be told apart
detect_profile() {
    local dir="$1" f nvidia=1
    local -a candidates=() narrowed=()

    detect_read_dmi
    detect_has_nvidia && nvidia=0

    [[ -d "$dir" ]] || { printf 'detect: no such directory: %s\n' "$dir" >&2; return 1; }

    # A profile that does not parse is skipped, loudly, rather than aborting the
    # scan. Profiles arrive through issues from people we do not know, and one
    # bad file must not stop this machine being recognised.
    for f in "$dir"/*.conf; do
        [[ -e "$f" ]] || continue
        [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
        if ! profile_load "$f"; then
            printf 'detect: skipping %s, it does not parse\n' "$f" >&2
            continue
        fi
        # Base block only: vendor and product identify the product, and a
        # section cannot change them.
        [[ "${PROFILE_BASE[dmi_vendor]}"  == "$DETECT_VENDOR"  ]] || continue
        [[ "${PROFILE_BASE[dmi_product]}" == "$DETECT_PRODUCT" ]] || continue
        candidates+=("$f")
    done

    (( ${#candidates[@]} )) || { PROFILE=(); return 1; }

    # narrow by discrete GPU. A file stays in the running if any revision it
    # describes could be this machine.
    if (( ${#candidates[@]} > 1 )); then
        narrowed=()
        for f in "${candidates[@]}"; do
            profile_load "$f" || continue
            if (( nvidia == 0 )); then
                profile_offers dgpu nvidia || profile_offers dgpu unknown || continue
            else
                profile_offers dgpu none || profile_offers dgpu unknown || continue
            fi
            narrowed+=("$f")
        done
        (( ${#narrowed[@]} )) && candidates=("${narrowed[@]}")
    fi

    # then by board, board revision and SKU, in that order, and only where both
    # sides know the value. SKU is last because it collides across models.
    local key val
    for key in dmi_board dmi_board_version dmi_sku; do
        (( ${#candidates[@]} > 1 )) || break
        case "$key" in
            dmi_board)         val="$DETECT_BOARD" ;;
            dmi_board_version) val="$DETECT_BOARD_VERSION" ;;
            dmi_sku)           val="$DETECT_SKU" ;;
        esac
        [[ -n "$val" ]] || continue
        narrowed=()
        for f in "${candidates[@]}"; do
            profile_load "$f" || continue
            # A file may describe several revisions, and a field may list
            # several values: one board carries five known revisions and reports
            # whichever it is. A file that does not know the value is dropped,
            # unless that would drop every candidate, which the test below
            # catches.
            if profile_offers "$key" "$val"; then narrowed+=("$f"); fi
        done
        (( ${#narrowed[@]} )) && candidates=("${narrowed[@]}")
    done

    if (( ${#candidates[@]} > 1 )); then
        printf 'detect: %s matches more than one profile:\n' "$(detect_describe)" >&2
        printf '    %s\n' "${candidates[@]}" >&2
        PROFILE=()
        return 2
    fi

    DETECT_PROFILE="${candidates[0]}"
    profile_load "$DETECT_PROFILE" || return 1
    profile_select_board "$DETECT_BOARD_VERSION"
}

# detect_board_note -> a line about how well the chosen section fits, or nothing
# when it fits exactly. Printed by the gate so that running on an undescribed
# revision is visible rather than silent.
detect_board_note() {
    case "$PROFILE_BOARD_MATCH" in
        exact) return 0 ;;
        wildcard)
            printf 'board %s is not described on its own; using this profile'\''s catch-all section.\n' \
                "${PROFILE_BOARD:-(unreported)}" ;;
        none)
            printf 'board %s is not described in %s.\n' \
                "${PROFILE_BOARD:-(unreported)}" "$(basename "${PROFILE_FILE}")"
            printf '    Running as '\''probed'\'': only the fixes that work out their own inputs\n'
            printf '    from this machine. Everything carrying a measured constant stays off,\n'
            printf '    because it was measured on a different board. A dump from yours is what\n'
            printf '    changes that: see the tracking issue in docs/SUPPORT.md.\n' ;;
    esac
}
