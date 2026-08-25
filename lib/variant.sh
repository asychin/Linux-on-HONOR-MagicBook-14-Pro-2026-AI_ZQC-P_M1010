# shellcheck shell=bash
#
# Where a fix keeps the parts of itself that belong to one machine.
#
#   patch/<fix>/<model>/<board>/recipe.conf
#
# The shape mirrors devices/<model>.conf and its [board <rev>] sections on
# purpose: the profile says this machine is ZQC-P board M1050, and the same two
# words name the directory the installer reads. Preparing a fix for a machine is
# then creating one directory, next to the directories for the machines that
# already have it, instead of finding the place inside an installer where the
# last machine was special-cased and adding a branch beside it.
#
# `any` in place of a board revision is the directory form of the profile's
# `[board *]`: it means every revision of that model, and it is what to write
# when a part is known to be in a model but nobody has said which revision.
#
# Two rules keep the layout from becoming seventeen copies of one file:
#
#   same_as=<model>/<board>
#       This board uses that board's files. The directory still exists, so the
#       machine is still listed where somebody would look for it, but there is
#       one copy of the artefact and it cannot drift out of step with itself.
#       One hop only: a same_as may not point at another same_as.
#
#   device=<vid>:<pid>
#       What this directory was written against. Installers that can see the
#       part on a bus check it and refuse on a mismatch, because a profile is a
#       record of what a board usually ships and the bus is what it shipped.
#
# tools/selftest.sh enforces both, and that every directory here names a board
# some profile actually declares.

VARIANT_DIR=""      # the directory the artefacts are in, after same_as
VARIANT_FOR=""      # the <model>/<board> that was asked for
declare -gA RECIPE=()

_variant_slug() {
    local s="${1,,}"
    printf '%s' "${s//[^a-z0-9._-]/-}"
}

# variant_find <fix-dir> [model] [board] -> 0 and sets VARIANT_DIR / VARIANT_FOR
#
# Defaults to the loaded profile, which is the normal call. The arguments exist
# so the self-test can walk the tree without a machine.
variant_find() {
    local base="$1"
    local model board dir target
    model="$(_variant_slug "${2:-$(profile_get model)}")"
    board="${3:-${PROFILE_BOARD:-}}"
    [[ -n "$model" ]] || return 1

    VARIANT_DIR=""
    VARIANT_FOR=""
    for dir in "${base}/${model}/${board}" "${base}/${model}/any"; do
        [[ -n "$board" || "$dir" == */any ]] || continue
        [[ -f "${dir}/recipe.conf" ]] || continue
        VARIANT_FOR="${model}/$(basename "$dir")"
        recipe_load "$dir" || return 1
        target="$(recipe_get same_as)"
        if [[ -n "$target" ]]; then
            # One hop. A chain is a way for two boards to end up pointing at
            # each other and for nobody to notice until an installer hangs.
            [[ -f "${base}/${target}/recipe.conf" ]] || return 1
            recipe_load "${base}/${target}" || return 1
            [[ -n "$(recipe_get same_as)" ]] && return 1
            VARIANT_DIR="${base}/${target}"
        else
            VARIANT_DIR="$dir"
        fi
        return 0
    done
    return 1
}

# variant_note -> "<model>/<board>", and where the files came from if elsewhere
#
# Worth printing: on a board whose recipe is a same_as, the log otherwise gives
# no clue that the thing being built was written for a different machine, and
# that is exactly what somebody reading a failed install needs to know first.
variant_note() {
    local used
    used="$(basename "$(dirname "$VARIANT_DIR")")/$(basename "$VARIANT_DIR")"
    if [[ "$used" == "$VARIANT_FOR" ]]; then
        printf '%s' "$VARIANT_FOR"
    else
        printf '%s, using the files from %s' "$VARIANT_FOR" "$used"
    fi
}

# variant_known <fix-dir> -> "model/board model/board ...", for an error message
variant_known() {
    local base="$1" m b out=()
    [[ -d "$base" ]] || { printf 'none'; return 0; }
    for m in "$base"/*/; do
        [[ -d "$m" ]] || continue
        for b in "$m"*/; do
            [[ -f "${b}recipe.conf" ]] || continue
            out+=("$(basename "$m")/$(basename "$b")")
        done
    done
    (( ${#out[@]} )) && printf '%s' "${out[*]}" || printf 'none'
}

# recipe_load <dir> -> fills RECIPE from <dir>/recipe.conf
# Strict key=value, parsed and never sourced, for the same reason a profile is:
# these files arrive through pull requests from people we do not know.
recipe_load() {
    local dir="$1" line
    RECIPE=()
    [[ -f "${dir}/recipe.conf" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || continue
        RECIPE["${line%%=*}"]="${line#*=}"
    done < "${dir}/recipe.conf"
    return 0
}

# recipe_get <key> [default]
recipe_get() { printf '%s' "${RECIPE[$1]:-${2:-}}"; }

# recipe_warn_unverified   say so, once, when a recipe has not been run here
recipe_warn_unverified() {
    [[ "${RECIPE[status]:-}" == "verified" ]] && return 0
    printf '\033[1;33m==>\033[0m %s\n' \
        "this recipe is '${RECIPE[status]:-unknown}': it comes from ${RECIPE[origin]:-elsewhere}
    and has not been run on hardware by this repository." >&2
}

# recipe_param <key> [env-var] -> the value, or non-zero if there is none
#
# The numbers a fix needs for one machine live in that machine's directory under
# the fix, not in the profile. A backlight floor, a set of EC offsets, the
# charge pairs an EC arms: none of them describes the machine, they describe
# what this fix has to do on it, and keeping them here is what lets a fix be
# prepared for a board by writing one file instead of editing a shared one.
#
# The profile keeps what the machine *is*: its identity, its trust, and the ids
# of the parts fitted, which an installer can go and confirm on a bus.
#
# An environment variable still wins, so somebody measuring a new floor can say
# VBT_MIN=14 without editing anything first.
recipe_param() {
    local key="$1" envvar="${2:-}" v=""
    [[ -n "$envvar" ]] && v="${!envvar:-}"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    v="${RECIPE[$key]:-}"
    [[ -z "$v" || "$v" == unknown ]] && return 1
    printf '%s' "$v"
}

# variant_check_device <found-id> -> 0, or 1 with the mismatch explained
#
# The recipe says which part it was written against. Where an installer can see
# the part, disagreeing with the profile is worth stopping for: building a
# program for a chip that is not fitted produces something that loads and does
# nothing, which is harder to diagnose than a refusal.
variant_check_device() {
    local found="$1" want
    want="$(recipe_get device)"
    [[ -z "$want" ]] && return 0
    [[ "${found,,}" == "${want,,}" ]] && return 0
    return 1
}
