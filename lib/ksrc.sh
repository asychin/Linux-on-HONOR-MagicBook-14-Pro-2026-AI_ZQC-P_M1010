# shellcheck shell=bash
#
# The upstream kernel tree that matches the running kernel.
#
# Five installers pull source from the stable-tree mirror, either to build a
# module against it or to ask whether a fix is already merged there. Each
# carried its own copy of
#
#     TAG="v${KVER%%-*}"
#
# and every copy was wrong in the same way. Mainline tags the first release of
# a series without its trailing zero: a 7.2.0 kernel is `v7.2`, and `v7.2.0`
# does not exist. On a machine running 7.2.0 all five fetches returned 404 in
# one run, and because each installer reported its own failure in its own words
# it read as five unrelated problems rather than one. That is what took the
# mic-mute fix off a ZQC-P M1050 after it had been working.
#
# So the tag is worked out once, here, and it is not merely worked out: the
# candidate is accepted only when the Makefile at that tag names the release we
# are running. Two of the callers use the tree to decide whether to skip
# themselves, and a tag that silently pointed at a newer tree would make them
# skip a fix the running kernel still needs. Guessing is not good enough for
# that; asking is cheap.

HONOR_KSRC_REPO="${HONOR_KSRC_REPO:-gregkh/linux}"

# Set by ksrc_resolve. Everything else here refuses to run until it is.
KSRC_TAG=""
_KSRC_TAG_FOR=""

# _ksrc_release <kver> -> the mainline release a distro kernel is built from
#
#   7.2.0-1-cachyos          -> 7.2.0
#   6.18.8-arch1-1           -> 6.18.8
#   6.12.30+deb13-amd64      -> 6.12.30
#   7.3.0-rc4-1-cachyos      -> 7.3.0-rc4
#
# The release candidate has to be picked out separately because it lives after
# the first dash, which is exactly what the old one-liner threw away.
_ksrc_release() {
    local kver="$1" base
    base="${kver%%-*}"
    base="${base%%+*}"
    if [[ "$kver" =~ -(rc[0-9]+) ]]; then
        printf '%s-%s' "$base" "${BASH_REMATCH[1]}"
    else
        printf '%s' "$base"
    fi
}

# _ksrc_candidates <kver> -> the tags that could name this kernel, best first
_ksrc_candidates() {
    local kver="$1" rel base
    rel="$(_ksrc_release "$kver")"
    base="${rel%%-*}"
    # v7.3-rc4, never v7.3.0-rc4.
    [[ "$rel" == *-rc* ]] && { printf 'v%s-%s\n' "${base%.0}" "${rel#*-}"; return 0; }
    # The .0 of a series is tagged without it. Offered first so the common case
    # costs one request rather than two.
    [[ "$base" == *.0 ]] && printf 'v%s\n' "${base%.0}"
    printf 'v%s\n' "$base"
}

# _ksrc_curl <url> <dest> -> 0 only on HTTP 200
_ksrc_curl() {
    local url="$1" dest="$2" code
    code=$(curl -sSL --max-time 60 -o "$dest" -w '%{http_code}' "$url" 2>/dev/null) || return 1
    [[ "$code" == "200" ]]
}

# _ksrc_makefile_release <tag> -> the release that tag builds, e.g. 7.2.0
#
# Range-requested because the four fields are in the first few lines and the
# Makefile is 80 KB. A server that ignores the range sends the whole file,
# which parses the same, so nothing depends on the range being honoured.
_ksrc_makefile_release() {
    local tag="$1" mk
    mk="$(curl -sSL --max-time 30 -r 0-511 \
          "https://raw.githubusercontent.com/${HONOR_KSRC_REPO}/${tag}/Makefile" 2>/dev/null)" \
        || return 1
    printf '%s' "$mk" | awk -F'=' '
        /^VERSION[ \t]*=/      { gsub(/[ \t]/, "", $2); v = $2 }
        /^PATCHLEVEL[ \t]*=/   { gsub(/[ \t]/, "", $2); p = $2 }
        /^SUBLEVEL[ \t]*=/     { gsub(/[ \t]/, "", $2); s = $2 }
        /^EXTRAVERSION[ \t]*=/ { gsub(/[ \t]/, "", $2); e = $2 }
        END {
            if (v == "" || p == "" || s == "") exit 1
            printf "%s.%s.%s%s", v, p, s, e
        }'
}

# ksrc_resolve [kver] -> sets KSRC_TAG, or stops with an explanation
#
# Call this once, from the installer's main shell, before any fetch. Not from
# inside $( ), where a failure would end the subshell and leave the caller
# running on an empty tag.
ksrc_resolve() {
    local kver="${1:-${KVER:-$(uname -r)}}"
    [[ -n "$KSRC_TAG" && "$_KSRC_TAG_FOR" == "$kver" ]] && return 0

    command -v curl >/dev/null || _gate_die "missing required tool: curl"

    local want tag got tried=""
    want="$(_ksrc_release "$kver")"
    while read -r tag; do
        tried+="${tried:+, }${tag}"
        got="$(_ksrc_makefile_release "$tag")" || continue
        [[ "$got" == "$want" ]] || continue
        KSRC_TAG="$tag"
        _KSRC_TAG_FOR="$kver"
        return 0
    done < <(_ksrc_candidates "$kver")

    _gate_die "no upstream tag in ${HONOR_KSRC_REPO} builds kernel ${want}.
    Tried: ${tried}.
    Either the mirror is unreachable, or this kernel is not a release of the
    mainline tree, in which case there is nothing to fetch and the fix has to
    be built from your distribution's own sources."
}

_ksrc_ready() {
    [[ -n "$KSRC_TAG" ]] || _gate_die "internal error: ksrc_resolve was not called."
}

# ksrc_fetch <path-in-tree> <dest> -> stops on anything but success
ksrc_fetch() {
    ksrc_fetch_opt "$1" "$2" \
        || _gate_die "could not fetch ${1} at ${KSRC_TAG}.
    The stable-tree mirror is unreachable, rate-limiting this address, or does
    not carry that file at this tag."
}

# ksrc_fetch_opt <path-in-tree> <dest> -> non-zero instead of stopping
#
# A file missing at a given tag is normal for callers that build whatever a
# kernel version actually has, so they need the failure back rather than an
# exit.
ksrc_fetch_opt() {
    local rel="$1" dest="$2"
    _ksrc_ready
    mkdir -p "$(dirname "$dest")"
    _ksrc_curl "https://raw.githubusercontent.com/${HONOR_KSRC_REPO}/${KSRC_TAG}/${rel}" "$dest" \
        && return 0
    rm -f "$dest"
    return 1
}

# ksrc_list_dir <path-in-tree> -> one file name per line, no filtering
#
# Callers take what they want from it. Reading the list from the tree rather
# than hardcoding it is the point: it drifts between kernel versions, and a
# stale list means building against files that no longer exist.
ksrc_list_dir() {
    _ksrc_ready
    # Without this the JSON silently parses to nothing and the caller reports
    # the API as unreachable, which sends whoever reads that log looking in the
    # wrong place entirely.
    command -v python3 >/dev/null || _gate_die "missing required tool: python3"
    curl -sSL --max-time 60 \
        "https://api.github.com/repos/${HONOR_KSRC_REPO}/contents/${1}?ref=${KSRC_TAG}" \
    2>/dev/null | python3 -c '
import json, sys
try:
    entries = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(entries, list):
    sys.exit(0)
for e in entries:
    if e.get("type") == "file" and e.get("name"):
        print(e["name"])
'
}
