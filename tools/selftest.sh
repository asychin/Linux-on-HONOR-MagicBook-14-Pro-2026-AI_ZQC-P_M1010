#!/usr/bin/env bash
#
# Checks the repository against itself. No root, no hardware, no network: it
# runs anywhere, including in CI and in a container, and it is the thing to run
# after editing a device profile.
#
# What it checks:
#   1. every devices/*.conf parses, validates, and carries no comments, and the
#      base block of a profile holds nothing that belongs to one board
#   2. every fix named in a profile has a directory under patch/, a trust tier,
#      and a call from apply_patch.sh
#   3. the bootloader command line is edited in place or refused, never flattened
#   4. detection picks the right profile AND the right board section for each
#      model's real DMI values, an unknown board revision never inherits a
#      verified status, and two profiles can never both match one machine
#   5. nothing in the tree looks like a licence key, an MSDM table or a whole
#      registry hive
#   6. no fix is nailed to one machine: no device id is baked into anything that
#      gets installed, a systemd unit only runs a file the installer that ships
#      it actually puts there, and every fix can be installed and removed on its
#      own from any directory
#   7. every shell script passes `bash -n`, and ShellCheck at -S warning where
#      that tool is installed; every python file parses

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
section() { printf '\n%s\n' "$*"; }

source lib/profile.sh

# --- 1. profiles parse, validate, and are data ------------------------------
section "device profiles"
for f in devices/*.conf; do
    [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
    if err="$(profile_load "$f" 2>&1)"; then
        if grep -qE '^[[:space:]]*#' "$f"; then
            fail "$f carries a comment; profiles are data, see docs/hardware/"
        else
            pass "$f"
        fi
    else
        fail "$f: $err"
    fi
done

# TEMPLATE.conf is the field reference. It must NOT validate as a profile (its
# required fields are blank), but every key it mentions must be a real key.
section "devices/TEMPLATE.conf"
PROFILE_QUIET=1 profile_load devices/TEMPLATE.conf >/dev/null 2>&1 \
    && fail "TEMPLATE.conf validates as a real profile; it should not" \
    || pass "does not pretend to be a profile"
missing=""
for k in "${PROFILE_KEYS[@]}"; do
    grep -qE "^${k}=" devices/TEMPLATE.conf || missing+=" $k"
done
[[ -z "$missing" ]] && pass "documents every key" || fail "does not mention:$missing"
# And the other direction, which is how a key that moved out of the schema
# stayed in the template: it kept offering ec_fan0 to anybody filling the file
# in, and the parser had started rejecting it.
stale=""
while read -r k; do
    case " ${PROFILE_KEYS[*]} " in *" $k "*) ;; *) stale+=" $k" ;; esac
done < <(grep -oE '^[a-z0-9_]+=' devices/TEMPLATE.conf | tr -d '=' | sort -u)
[[ -z "$stale" ]] && pass "offers no key the parser would reject" \
                  || fail "offers keys that are not in the schema:$stale"

# --- 1b. the base block of a profile is identity only ------------------------
# The whole point of board sections: a reading, a measurement or a status in the
# base block would apply to every revision HONOR ships under that product name.
# It has to be a parse error, not a convention, so it is checked here.
section "a board's data cannot go in the base block"
_profile_case() { # name body expectation(ok|reject)
    local name="$1" body="$2" expected="$3" tmp rc=0
    tmp="$(mktemp -d)"
    printf '%s\n' "$body" > "$tmp/x.conf"
    PROFILE_QUIET=1 profile_load "$tmp/x.conf" >/dev/null 2>&1 || rc=$?
    rm -rf "$tmp"
    if [[ "$expected" == ok ]]; then
        (( rc == 0 )) && pass "$name" || fail "$name: rejected a profile that is fine"
    else
        (( rc != 0 )) && pass "$name" || fail "$name: accepted, and it must not be"
    fi
}
_MINIMAL='model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
status=probed'
_profile_case "the minimal shape"              "$_MINIMAL" ok
_profile_case "a hardware id in the base block" "model=X
dmi_vendor=HONOR
dmi_product=X
touchscreen_hid=2808:5662

[board M1010]
status=probed" reject
_profile_case "a status in the base block"     "model=X
dmi_vendor=HONOR
dmi_product=X
status=verified

[board M1010]
status=probed" reject
_profile_case "a measurement in the base block" "model=X
dmi_vendor=HONOR
dmi_product=X
backlight_max=704

[board M1010]
status=probed" reject
_profile_case "dmi_product inside a section"   "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
status=probed
dmi_product=Y" reject
_profile_case "no board section at all"        "model=X
dmi_vendor=HONOR
dmi_product=X
" reject
_profile_case "a section with no status"       "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
panel=oled" reject
_profile_case "one revision claimed twice"     "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
status=probed

[board M1020 M1010]
status=verified" reject
_profile_case "the old flat format"            "model=X
dmi_vendor=HONOR
dmi_product=X
status=verified
dmi_board_version=M1010" reject
_profile_case "several revisions in one header" "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1110 M1120]
status=reported" ok
_profile_case "a catch-all section"            "model=X
dmi_vendor=HONOR
dmi_product=X

[board *]
status=probed" ok

# --- hostile input ------------------------------------------------------------
# A profile arrives in a pull request from somebody nobody knows. It is parsed
# and never sourced, so none of the below can execute, but each of them once
# either got through or made the parser hang.
_profile_case "a command substitution in a value" "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
status=probed
origin=\$(touch /tmp/should-not-exist)" reject
_profile_case "backticks in a value"           "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
status=probed
origin=\`touch /tmp/should-not-exist\`" reject
_profile_case "a semicolon in a value"         "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
status=probed; touch /tmp/should-not-exist" reject
_profile_case "a glob in a value"              "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
status=probed
dmi_board=*" reject
_profile_case "the same key twice in a block"  "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
status=probed
panel=oled
panel=lcd" reject
_profile_case "the same fix listed twice"      "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
status=probed
fixes=micmute fingerprint micmute" reject
_profile_case "an unreasonably long value"     "model=X
dmi_vendor=HONOR
dmi_product=X

[board M1010]
status=probed
origin=$(head -c 600 /dev/zero | tr '\0' 'A')" reject
_profile_case "an empty section header"        "model=X
dmi_vendor=HONOR
dmi_product=X

[board ]
status=probed" reject
# 3000 sections used to take over a minute and print nothing while it did: the
# duplicate-revision check is quadratic. It is capped now, and this case is here
# to keep the cap.
_MANY="model=X
dmi_vendor=HONOR
dmi_product=X"
for _i in $(seq 1 200); do _MANY+="

[board M9$(printf '%03d' "$_i")]
status=probed"; done
_profile_case "two hundred board sections"     "$_MANY" reject

# --- 1c. a section describes one board, and claims only what was measured ----
# Two ways to quietly assert more than anybody checked.
#
# A header naming several revisions says "these are the same machine". Nobody
# has done the work that would establish that: on XWC-P the M1110 and M1120
# units have different webcam suppliers, and on DRA-XX the M1030 and M1040
# boards have different CPUs and different fingerprint readers. The parser still
# accepts a merged header, because one day somebody may prove two revisions
# identical; until then no shipped profile may use one.
#
# `[board *]` says "this product's revisions are unknown". That is honest for
# DRB-P, where no probe of a non-HUNTER machine exists at all. It is not honest
# as a layer of inference on top of revisions that ARE known, which is what it
# was being used for.
# The models table in README.md says which board revisions have fixes enabled.
# That is prose about data, so it drifts: it said "none yet" for every board but
# the reference one for exactly as long as it took somebody to enable nine on
# another. Checked rather than remembered.
# A function in lib/ that nobody calls is not neutral. It reads as a supported
# entry point, so it attracts edits: a contributor added a distribution branch
# to distro_kernel_hook_supported() in a pull request, and that function had
# never been called by anything.
section "no dead functions in lib/"
# Some are dispatched by constructed name, e.g. declare -F "_xe_obsolete_${fix}".
mapfile -t dyn < <(grep -rhoE 'declare -F "[a-z_]+' lib/ | sed 's/declare -F "//' | sort -u)
for fn in $(grep -hoE '^[a-z_][a-z0-9_]*\(\)' lib/*.sh | tr -d '()' | sort -u); do
    # The paths grep -r prints start with ./, so the filter has to as well.
    # It did not, the definition line counted as a use, and this whole section
    # passed everything. Found by adding a function nobody calls and watching it
    # come back ok.
    uses=$(grep -rw --include='*.sh' "$fn" . 2>/dev/null | grep -v '^\./\.git' \
           | grep -vc "^\./lib/[a-z-]*\.sh:[[:space:]]*${fn}()")
    (( uses > 0 )) && { pass "$fn"; continue; }
    hit=0
    for prefix in "${dyn[@]}"; do
        [[ -n "$prefix" && "$fn" == "$prefix"* ]] && { hit=1; break; }
    done
    (( hit )) && pass "$fn (dispatched by name)" \
              || fail "lib/ defines $fn and nothing calls it"
done

# Marking a board verified unlocks the tier B fixes, which then read constants
# out of that section. If the section says `unknown` where one of them looks,
# the installer dies somewhere in the middle instead of at the gate. Whether
# somebody really did the verifying is a human question and not checkable here;
# whether the claim is self-consistent is.
# apply_patch.sh's opt-in and opt-out variables are the user interface. One of
# them, WITH_DSC, lived in docs/INSTALL.md and in the fix's own README but never
# reached the options table in README.md, so the only place most people look
# offered WITH_CDCLK and not its twin.
# GNU grep 3.8 warns "stray \\ before X" for an undefined escape in an ERE and
# keeps going, so the pattern still works and the only symptom is noise on the
# user's terminal. apply_patch.sh printed five of them on every run for a
# pattern that escaped its slashes.
section "no undefined escapes in extended regular expressions"
hits="$(grep -rn --include='*.sh' -oE "grep[^|;]*-[a-zA-Z]*E[^|;]*\\\\[/,:<>=!@%&~-]" . 2>/dev/null \
        | grep -v '^\./\.git' || true)"
if [[ -n "$hits" ]]; then
    while read -r h; do fail "undefined ERE escape: $h"; done <<< "$hits"
else
    pass "none"
fi

# '"'"' closes a single-quoted string, inserts a literal quote and opens the
# next one. Inside double quotes it is none of those things: it resolves to two
# quote characters and an unquoted space, which splits one argument into two.
# apply_patch.sh carried one in a `grep -oE` inside an echo, so that grep ran
# with a pattern of stray quotes and a file name that does not exist, matched
# nothing, and printed "OK" followed by a dash and empty space on every run
# since. The error went to /dev/null. Found in a user's log, not here.
section "the single-quote escape is not used inside double quotes"
if python3 - <<'PYEOF'
import glob, sys

ESC = "'" + '"' + "'" + '"' + "'"          # the five characters '"'"'
DQ  = '"'
SQ  = "'"
bad = []
for path in glob.glob("**/*.sh", recursive=True):
    if path.startswith(".git"):
        continue
    for n, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        if ESC not in line:
            continue
        i, in_s, in_d = 0, False, False
        while i < len(line):
            if in_d and line.startswith(ESC, i):
                bad.append("%s:%d: %s" % (path, n, line.strip()[:90]))
                break
            c = line[i]
            if c == "\\" and in_d:
                i += 2
                continue
            if c == SQ and not in_d:
                in_s = not in_s
            elif c == DQ and not in_s:
                in_d = not in_d
            i += 1
for b in bad:
    print("        " + b)
sys.exit(1 if bad else 0)
PYEOF
then
    pass "none"
else
    fail "a single-quote escape sits inside double quotes; see the lines above"
fi

# The upstream tag is worked out in one place because when each installer did
# it itself they were all wrong together: a 7.2.0 kernel is v7.2 upstream, and
# asking for v7.2.0 returned 404 five times in one run on a user's machine.
# Nothing may go back to spelling it out, and a fetch before ksrc_resolve would
# use an empty tag.
section "the upstream kernel tag is resolved, never spelled out"
hits="$(grep -rn --include='*.sh' -E 'raw\.githubusercontent\.com/gregkh|api\.github\.com/repos/gregkh|TAG="v\$\{KVER' . 2>/dev/null \
        | grep -v '^\./\.git' | grep -v '^\./lib/ksrc\.sh:' || true)"
if [[ -n "$hits" ]]; then
    while read -r h; do fail "reaches the kernel mirror outside lib/ksrc.sh: $h"; done <<< "$hits"
else
    pass "only lib/ksrc.sh names the mirror"
fi
for f in $(grep -rl --include='*.sh' -E 'ksrc_(fetch|fetch_opt|list_dir)\b' . | grep -v '^\./lib/'); do
    grep -qE '^[[:space:]]*ksrc_resolve\b' "$f" \
        && pass "$(basename "$(dirname "$f")")/$(basename "$f") resolves before it fetches" \
        || fail "$f fetches kernel source without calling ksrc_resolve first"
done

section "every knob apply_patch.sh reads is in the README options table"
for v in $(grep -oE '\$\{(SKIP_[A-Z_]+|WITH_[A-Z_]+|ALLOW_[A-Z_]+|FORCE_[A-Z_]+|CHARGE_PRESET|VBT_MIN)' apply_patch.sh \
           | sed 's/\${//' | sort -u); do
    grep -q "\`${v}=" README.md && pass "$v" \
        || fail "apply_patch.sh reads $v and the README options table never mentions it"
done
# And the other way, because a documented option that nothing reads is worse
# than an undocumented one: the reader sets it, nothing happens, and there is
# no way to tell that from the fix simply not working.
while read -r v; do
    [[ -n "$v" ]] || continue
    grep -rqF --include='*.sh' "$v" . && pass "$v is read somewhere" \
        || fail "README offers $v and no script reads it"
done < <(sed -n 's/^| `\([A-Z_][A-Z_0-9]*\)=.*/\1/p' README.md | sort -u)

# Moving a file is how a link goes stale, and a stale link in a README is found
# by the next person who follows it rather than by the person who moved the
# file. Two of them were left behind by one directory rename. The heading half
# matters as much now: several pages say a thing once and everywhere else links
# to that heading, so renaming it would quietly break five links at a time.
section "relative links point at files, and at headings, that exist"
if python3 - <<'PYEOF'
import glob, os, re, sys

def slug(h):
    h = h.strip().lower()
    h = re.sub(r"[`*_]", "", h)
    h = re.sub(r"[^a-z0-9 -]", "", h)
    return h.replace(" ", "-")

anchors = {}
for f in glob.glob("**/*.md", recursive=True):
    if f.startswith(".git"):
        continue
    anchors[os.path.normpath(f)] = {
        slug(m.group(1))
        for m in re.finditer(r"^#{1,6}\s+(.*)$", open(f, encoding="utf-8").read(), re.M)
    }

bad = []
for f, _ in anchors.items():
    base = os.path.dirname(f)
    for m in re.finditer(r"\]\(([^)\s]+)\)", open(f, encoding="utf-8").read()):
        target = m.group(1)
        if target.startswith(("http", "mailto:")):
            continue
        path, _, frag = target.partition("#")
        # ../../../../issues/N is a GitHub blob-relative link to the tracker,
        # not a path in this tree. The section below checks those instead.
        if "/issues/" in target or "/pull/" in target:
            continue
        if path:
            p = os.path.normpath(os.path.join(base, path))
            if not os.path.exists(p):
                bad.append("%s -> %s (no such file)" % (f, target))
                continue
        else:
            p = f
        if frag and p in anchors and frag not in anchors[p]:
            bad.append("%s -> %s (no such heading in %s)" % (f, target, p))
for b in bad:
    print("        " + b)
sys.exit(1 if bad else 0)
PYEOF
then
    pass "none broken"
else
    fail "a relative link points at something that is not there; see the lines above"
fi

# Links to the issue tracker are written relative, ../../../../issues/N, which
# GitHub resolves from the blob path. That only lands on the repository root
# from a file exactly two directories deep, so the depth is part of the link.
section "relative issue links sit at the depth they assume"
while IFS=: read -r f _ link; do
    depth=$(( $(tr -cd '/' <<< "$f" | wc -c) - 1 ))
    up=$(grep -o '\.\./' <<< "$link" | wc -l)
    (( up == depth + 2 )) && pass "$f -> ${link##*/}" \
        || fail "$f is $depth directories deep but its link goes up $up: $link"
done < <(grep -rn --include='*.md' -oE '\.\./(\.\./)+issues/[0-9]+' . | grep -v '^\./\.git')

# Marking a board verified unlocks the tier B fixes, which then read the numbers
# in that board's directory under each of them. If a directory is missing or
# says `unknown` where the installer looks, the run dies somewhere in the middle
# instead of at the gate. Whether somebody really did the verifying is a human
# question and not checkable here; whether the claim is self-consistent is.
section "a verified board carries what it unlocks"
declare -A NEEDS=(
    [headset-mic]="fixup"
    [oled-backlight]="backlight_min"
    [fan]="ec_fan0 ec_fan1"
    [battery]="presets"
)
for f in devices/*.conf; do
    [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
    PROFILE_QUIET=1 profile_load "$f" >/dev/null 2>&1 || continue
    m="${PROFILE_BASE[model],,}"
    while read -r idx boards st; do
        [[ "$st" == verified ]] || continue
        bad=0
        for b in $boards; do
            [[ "$b" == "*" ]] && continue
            for fix in $(_profile_effective "$idx" fixes ""); do
                [[ -n "${NEEDS[$fix]:-}" ]] || continue
                d="patch/${fix}/${m}/${b}"
                [[ -f "${d}/recipe.conf" ]] || d="patch/${fix}/${m}/any"
                if [[ ! -f "${d}/recipe.conf" ]]; then
                    fail "$(basename "$f") [board $b] is verified and lists '$fix',
        and patch/${fix}/${m}/${b}/ does not exist"
                    bad=1
                    continue
                fi
                # Follow one same_as, the way lib/variant.sh does, so a board
                # that borrows its numbers is judged on the numbers it gets.
                t="$(sed -n 's/^same_as=//p' "${d}/recipe.conf" | head -1)"
                [[ -n "$t" && -f "patch/${fix}/${t}/recipe.conf" ]] && d="patch/${fix}/${t}"
                for key in ${NEEDS[$fix]}; do
                    v="$(sed -n "s/^${key}=//p" "${d}/recipe.conf" | head -1)"
                    [[ -n "$v" && "$v" != unknown ]] && continue
                    fail "$(basename "$f") [board $b] is verified and lists '$fix',
        which reads '$key' from ${d}/recipe.conf, and that is '${v:-absent}'"
                    bad=1
                done
            done
        done
        (( bad )) || pass "$(basename "$f") [board $boards]"
    done < <(profile_sections)
done

# The README says which fixes each board gets, by name, with the ones that
# actually run in bold. A count can be checked by eye; a list of fifteen names
# with a bold subset cannot, so it is generated from the profile here and
# compared. Without this it would be a description of what used to be true.
section "the README fix list matches the profiles"
# One check, not two. This used to be split between a count in a column and a
# "none yet" in the same row, both of which said less than a list of names does
# and both of which had to be kept in step with the profile by hand.
for f in devices/*.conf; do
    [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
    PROFILE_QUIET=1 profile_load "$f" >/dev/null 2>&1 || continue
    m="${PROFILE_BASE[model]}"
    while read -r idx boards _; do
        listed="$(_profile_effective "$idx" fixes "")"
        [[ -n "$listed" ]] || continue
        for b in $boards; do
            [[ "$b" == "*" ]] && continue
            profile_select_board "$b" >/dev/null 2>&1
            want=""
            for fx in $listed; do
                if fix_allowed "$fx"; then want+=" · **${fx}**"; else want+=" · ${fx}"; fi
            done
            want="| \`${m}\` \`${b}\` | ${want# · } |"
            if grep -qF "$want" README.md; then
                pass "${m} ${b}"
            else
                fail "the README fix list for ${m} ${b} is not what the profile says. Write:
        ${want}"
            fi
        done
    done < <(profile_sections)
done
# A board whose profile lists nothing must not be in that table at all, or it
# stops meaning "these are the boards that have any".
for f in devices/*.conf; do
    [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
    PROFILE_QUIET=1 profile_load "$f" >/dev/null 2>&1 || continue
    m="${PROFILE_BASE[model]}"
    while read -r idx boards _; do
        [[ -n "$(_profile_effective "$idx" fixes "")" ]] && continue
        for b in $boards; do
            [[ "$b" == "*" ]] && continue
            if grep -qF "| \`${m}\` \`${b}\` |" README.md; then
                fail "${m} ${b} lists no fixes and the README fix table has a row for it"
            else
                pass "${m} ${b} is absent, as it should be"
            fi
        done
    done < <(profile_sections)
done

section "a section describes one board"
for f in devices/*.conf; do
    [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
    bad=0 named=0 wild=0
    while read -r hdr; do
        n=$(wc -w <<< "$hdr")
        [[ "$hdr" == "*" ]] && wild=1 || named=1
        (( n > 1 )) && { fail "$(basename "$f"): [board $hdr] claims $n revisions are the same machine"; bad=1; }
    done < <(sed -n 's/^\[board \(.*\)\]$/\1/p' "$f")
    if (( wild && named )); then
        fail "$(basename "$f"): has [board *] beside named revisions; the catch-all is
        for a product whose revisions are unknown, not a default for the ones that are"
        bad=1
    fi
    (( bad )) || pass "$(basename "$f")"
done

# --- 2. every fix named in a profile exists ---------------------------------
section "fixes named in profiles"
for f in devices/*.conf; do
    [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
    PROFILE_QUIET=1 profile_load "$f" >/dev/null 2>&1 || continue
    # profile_all_fixes, not PROFILE[fixes]: fixes are named per board section
    # now, and PROFILE after a bare load carries the base block only. Reading
    # PROFILE[fixes] here would loop over nothing and pass silently.
    for fix in $(profile_all_fixes); do
        [[ -d "patch/$fix" ]] && pass "$(basename "$f"): patch/$fix" \
                              || fail "$(basename "$f") lists '$fix', but patch/$fix does not exist"
    done
done

# --- 2b. every patch directory is wired in, or is deliberately reference-only -
section "patch directories"
for d in patch/*/; do
    n="$(basename "$d")"
    [[ -f "$d/README.md" ]] || fail "patch/$n has no README.md"
    if [[ -f "$d/install.sh" ]]; then
        # An installer nothing can reach is dead code. It needs a trust tier so
        # a profile can list it, and apply_patch.sh has to call it.
        [[ -n "${FIX_TIER[$n]:-}" ]] || fail "patch/$n has an install.sh but no FIX_TIER in lib/profile.sh"
        grep -q "patch/$n/install.sh\|PATCH_DIR/$n/install.sh" apply_patch.sh \
            || fail "patch/$n has an install.sh that apply_patch.sh never calls"
        listed=0
        for f in devices/*.conf; do
            [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
            grep -qE "^fixes=.*\b${n}\b" "$f" && { listed=1; break; }
        done
        (( listed )) && pass "patch/$n: tier ${FIX_TIER[$n]}, wired in, listed by a profile" \
                     || fail "patch/$n is installable but no device profile lists it"
    else
        # No installer: reference material, or driven by apply_patch.sh directly.
        pass "patch/$n: reference only, no installer"
    fi
done

# --- 2c. the bootloader command line is edited, never flattened ---------------
# distro_cmdline_add rewrites one shape of file wholesale (/etc/kernel/cmdline,
# where the whole file IS the command line). Every other shape must be edited in
# place or refused. Getting that wrong destroys root= and rootflags= and the
# machine does not boot, so it is tested rather than reasoned about.
section "kernel command line editing"
source lib/distro.sh
_cmdline_case() { # name file-name content expectation
    local name="$1" fname="$2" content="$3" expected="$4"
    local d; d="$(mktemp -d)"; mkdir -p "$(dirname "$d/$fname")"
    printf '%s' "$content" > "$d/$fname"
    local before_lines after_lines rc
    before_lines="$(grep -c '' "$d/$fname" 2>/dev/null || echo 0)"
    distro_cmdline_file() { echo "$d/$fname"; }
    distro_cmdline_add "SELFTEST=1" >/dev/null 2>&1 && rc=0 || rc=1
    after_lines="$(grep -c '' "$d/$fname" 2>/dev/null || echo 0)"
    case "$expected" in
        edited)
            if grep -qF 'SELFTEST=1' "$d/$fname" && [[ "$before_lines" == "$after_lines" ]]; then
                pass "$name: edited in place, $after_lines line(s) kept"
            else
                fail "$name: expected an in-place edit, got rc=$rc and $before_lines -> $after_lines lines"
            fi ;;
        appended)
            grep -qF 'SELFTEST=1' "$d/$fname" && pass "$name: appended" \
                                              || fail "$name: nothing was appended" ;;
        refused)
            if (( rc != 0 )) && ! grep -qF 'SELFTEST=1' "$d/$fname"; then
                pass "$name: refused and left alone"
            else
                fail "$name: should have refused, rc=$rc"
            fi ;;
    esac
    rm -rf "$d"
}
_cmdline_case "limine, default key"   default/limine 'KERNEL_CMDLINE[default]="quiet splash"
ESP_PATH="/boot"
' edited
_cmdline_case "limine, += form"       default/limine 'KERNEL_CMDLINE[default]+="root=UUID=x rw"
ESP_PATH="/boot"
' edited
_cmdline_case "limine, per-kernel key" default/limine '# defaults
KERNEL_CMDLINE[linux-cachyos]="root=UUID=1234 rw"
ESP_PATH="/boot"
' edited
_cmdline_case "grub, quoted"          default/grub 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_TIMEOUT=5
' edited
_cmdline_case "grub, all commented"   default/grub '# GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_TIMEOUT=5
' refused
_cmdline_case "systemd-boot"          kernel/cmdline 'root=UUID=abc rw quiet
' appended
_cmdline_case "a shape we do not know" default/grub 'SOMETHING_ELSE=1
' refused
unset -f distro_cmdline_file
source lib/distro.sh

# A kernel update replaces /usr/lib/modules/<kver>/, so anything this
# repository put in that kernel's updates/ overlay is gone and the stock module
# is back. patch/auto-rebuild/ exists to put it back, and a fix that installs a
# module without being in that path is a fix that silently disappears on the
# next kernel. That is exactly what happened to the xe.ko patches.
section "module fixes survive a kernel update"
_covered() { # $1 = fix name
    grep -q -- "$1" patch/auto-rebuild/deferred.sh && return 0
    # The xe patches are named at run time from the stamp rather than literally.
    if grep -q "^\s*\[$1\]=" lib/xe-build.sh \
       && grep -q 'xe-module.stamp' patch/auto-rebuild/deferred.sh; then
        return 0
    fi
    return 1
}
for d in patch/*/; do
    n="$(basename "$d")"
    [[ -f "$d/install.sh" ]] || continue
    # Does this fix put a module into the per-kernel overlay, directly or
    # through the shared builder?
    # Three ways an installer can land a module in the per-kernel tree: write
    # the overlay path itself, go through distro_module_install, or delegate to
    # the shared xe builder. Matching only one of them is how this check would
    # quietly stop covering things.
    installs_module=0
    grep -qE '/updates|distro_module_install|lib/xe-build\.sh' "$d/install.sh" && installs_module=1
    (( installs_module )) || continue
    # DKMS does its own rebuild on kernel install, so it needs nothing here.
    if grep -q 'dkms' "$d/install.sh"; then
        pass "patch/$n: installs through DKMS, which rebuilds itself"
    elif _covered "$n"; then
        pass "patch/$n: rebuilt after a kernel update"
    else
        fail "patch/$n installs a module overlay that patch/auto-rebuild/ never rebuilds"
    fi
done

# lib/xe-build.sh may carry an "is this fix already upstream" hook per patch.
# The trap is grepping for a string the patch itself adds: then a tree that has
# just been patched looks like a tree that never needed it, the fix silently
# leaves the module, and the build still reports success. That happened once.
section "xe patch obsolescence markers"
if [[ -r lib/xe-build.sh ]]; then
    while read -r fn; do
        fix="${fn#_xe_obsolete_}"; fix="${fix//_/-}"
        marker=$(sed -n "/^${fn}()/,/^}/p" lib/xe-build.sh \
                 | sed -n "s/.*grep -q '\([^']*\)'.*/\1/p" | head -1)
        [[ -n "$marker" ]] || { fail "$fn: cannot find the string it greps for"; continue; }
        patchfile=$(ls "patch/$fix"/*.patch 2>/dev/null | head -1)
        [[ -n "$patchfile" ]] || { fail "$fn: no patch file under patch/$fix"; continue; }
        if grep -E "^\+" "$patchfile" | grep -qF -- "$marker"; then
            fail "$fn greps for '$marker', which patch/$fix adds itself: a patched tree would look obsolete"
        else
            pass "$fn: '$marker' is not introduced by patch/$fix"
        fi
    done < <(grep -oE '^_xe_obsolete_[a-z_]+' lib/xe-build.sh)
else
    fail "lib/xe-build.sh is missing"
fi

# distro_cmdline_remove takes an extended regex, and callers legitimately pass
# an alternation. The delimiter sed is given must therefore not be a character
# that can appear in one: with '|' as the delimiter, '(xe|i915)\.enable_psr=.'
# makes sed exit with "unknown option to `s'" and the parameter stays put, which
# looks exactly like a successful removal from the outside.
_cmdline_rm_case() { # name pattern must-go must-stay
    local name="$1" pattern="$2" gone="$3" stay="$4"
    local d; d="$(mktemp -d)"; mkdir -p "$d/default"
    printf '%s\n' \
        'KERNEL_CMDLINE[default]+="root=UUID=abc rw rootflags=subvol=/@ i8042.dumbkbd=1 xe.enable_psr=1"' \
        'ESP_PATH="/boot"' > "$d/default/limine"
    distro_cmdline_file() { echo "$d/default/limine"; }
    distro_cmdline_remove "$pattern" 2>/dev/null
    if ! grep -qF "$gone" "$d/default/limine" && grep -qF "$stay" "$d/default/limine"; then
        pass "$name: removed, and $stay survived"
    else
        fail "$name: expected '$gone' gone and '$stay' kept, got $(grep -m1 KERNEL_CMDLINE "$d/default/limine")"
    fi
    rm -rf "$d"
}
_cmdline_rm_case "remove a plain parameter"  'i8042\.dumbkbd=1'            'i8042.dumbkbd=1' 'root=UUID=abc'
_cmdline_rm_case "remove via an alternation" '(xe|i915)\.enable_psr=[0-9]+' 'xe.enable_psr=1' 'rootflags=subvol=/@'
unset -f distro_cmdline_file
source lib/distro.sh

# --- 3 and 4. detection ------------------------------------------------------
source lib/detect.sh

FAKE_VENDOR=""; FAKE_PRODUCT=""; FAKE_SKU=""; FAKE_BOARD=""; FAKE_BV=""; FAKE_NVIDIA=1
detect_read_dmi() {
    DETECT_VENDOR="$FAKE_VENDOR";      DETECT_PRODUCT="$FAKE_PRODUCT"
    DETECT_SKU="$FAKE_SKU";            DETECT_BOARD="$FAKE_BOARD"
    DETECT_BOARD_VERSION="$FAKE_BV"
}
detect_has_nvidia() { return "$FAKE_NVIDIA"; }

# name vendor product sku board board_version has_nvidia expected
check_detect() {
    local name="$1" expected="$8" rc got
    FAKE_VENDOR="$2"; FAKE_PRODUCT="$3"; FAKE_SKU="$4"
    FAKE_BOARD="$5";  FAKE_BV="$6";      FAKE_NVIDIA="$7"
    DETECT_PROFILE=""
    detect_profile devices >/dev/null 2>&1 && rc=0 || rc=$?
    got="$DETECT_PROFILE"
    (( rc != 0 )) && got="(rc=$rc)"
    [[ "$got" == "$expected" ]] && pass "$name -> $got" \
                            || fail "$name -> $got, wanted $expected"
}

section "detection, from each model's own recorded DMI"
check_detect "ZQC-P"             HONOR ZQC-P    C233 ZQC-P-PCB  M1010 1 devices/zqc-p.conf
check_detect "MRA-XXX"           HONOR MRA-XXX  C170 MRA-XXX-PCB M1040 1 devices/mra-xxx.conf
check_detect "MRB-XXX"           HONOR MRB-XXX  C233 MRB-XXX-PCB M1090 1 devices/mrb-xxx.conf
check_detect "FRB-X"             HONOR FRB-X    ""   FRB-X-PCB   M1050 1 devices/frb-x.conf
check_detect "GLO-GXXX"          HONOR GLO-GXXX C170 GLO-GXXX-PCB M1010 1 devices/glo-gxxx.conf
check_detect "GLO-GXXX with RTX" HONOR GLO-GXXX C170 GLO-GXXX-PCB M1010 0 devices/glo-gxxx.conf
check_detect "FMI-XX"            HONOR FMI-XX   ""   ""          ""    1 devices/fmi-xx.conf
check_detect "XWC-P M1110"       HONOR XWC-P    C233 XWC-P-PCB  M1110 1 devices/xwc-p.conf
check_detect "XWC-P M1120"       HONOR XWC-P    C233 XWC-P-PCB  M1120 1 devices/xwc-p.conf
check_detect "BCC-N"             HONOR BCC-N    C233 BCC-N-PCB  M1070 1 devices/bcc-n.conf
check_detect "FMB-P M1030"       HONOR FMB-P    C170 FMB-P-PCB  M1030 1 devices/fmb-p.conf
check_detect "FMB-P M1090"       HONOR FMB-P    C233 FMB-P-PCB  M1090 1 devices/fmb-p.conf
check_detect "FMB-PM"            HONOR FMB-PM   ""   FMB-PM-PCB M1030 1 devices/fmb-pm.conf
check_detect "DRB-P HUNTER"      HONOR DRB-P    C170 DRB-P-PCB  M1020 0 devices/drb-p-hunter.conf
check_detect "DRB-P UMA"         HONOR DRB-P    ""   DRB-P-PCB  ""    1 devices/drb-p.conf
check_detect "DRA-XX M1020"      HONOR DRA-XX   C170 DRA-XX-PCB M1020 1 devices/dra-xx.conf
check_detect "DRA-XX M1030 dGPU" HONOR DRA-XX   C233 DRA-XX-PCB M1030 0 devices/dra-xx-hunter.conf
check_detect "DRA-XX M1040 dGPU" HONOR DRA-XX   ""   DRA-XX-PCB M1040 0 devices/dra-xx-hunter.conf

# --- 4b. the board revision decides how far a profile is trusted -------------
# HONOR ships one product code as several machines. Before board sections, any
# ZQC-P matched the one ZQC-P profile and inherited status=verified together
# with every constant measured on board M1010: the backlight floor, the audio
# subsystem id, the EC tachometer offsets, the battery presets. The report on
# issue #1 is a ZQC-P on board M1050 with a different CPU.
#
# So the invariant is not "detection finds a file". It is that a revision
# nobody has measured cannot come out of this verified.
section "the board revision decides the trust"
# name vendor product sku board board_version nvidia expected("profile match status")
check_board() {
    local name="$1" expected="$8" rc got
    FAKE_VENDOR="$2"; FAKE_PRODUCT="$3"; FAKE_SKU="$4"
    FAKE_BOARD="$5";  FAKE_BV="$6";      FAKE_NVIDIA="$7"
    DETECT_PROFILE=""
    detect_profile devices >/dev/null 2>&1 && rc=0 || rc=$?
    if (( rc != 0 )); then
        got="(rc=$rc)"
    else
        got="$(basename "$DETECT_PROFILE") ${PROFILE_BOARD_MATCH} ${PROFILE[status]:-}"
    fi
    [[ "$got" == "$expected" ]] && pass "$name -> $got" \
                            || fail "$name -> $got, wanted $expected"
}
check_board "ZQC-P M1010, the measured board" \
    HONOR ZQC-P C233 ZQC-P-PCB M1010 1 "zqc-p.conf exact verified"
check_board "ZQC-P M1050, reported on issue 1" \
    HONOR ZQC-P ""   ZQC-P-PCB M1050 1 "zqc-p.conf exact verified"
check_board "ZQC-P on a revision nobody has seen" \
    HONOR ZQC-P C233 ZQC-P-PCB M9999 1 "zqc-p.conf none probed"
check_board "ZQC-P whose firmware reports no board" \
    HONOR ZQC-P C233 ZQC-P-PCB ""    1 "zqc-p.conf none probed"
# [board *] is for a product whose revisions are genuinely unknown, not as a
# layer of inference over revisions that are known. DRB-P is the honest case:
# no probe of a machine without the discrete GPU exists at all.
check_board "DRB-P, revision unknown to anyone" \
    HONOR DRB-P ""   DRB-P-PCB ""    1 "drb-p.conf wildcard draft"
check_board "XWC-P M1120, a described revision" \
    HONOR XWC-P C233 XWC-P-PCB M1120 1 "xwc-p.conf exact reported"
check_board "FMB-PM on an undescribed revision, no catch-all" \
    HONOR FMB-PM "" FMB-PM-PCB M9999 1 "fmb-pm.conf none probed"

# And the same thing stated as the rule rather than as cases: for every profile,
# an unrecognised revision must never come back verified.
for f in devices/*.conf; do
    [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
    PROFILE_QUIET=1 profile_load "$f" >/dev/null 2>&1 || continue
    profile_select_board "M0000-not-a-real-revision"
    if [[ "${PROFILE[status]:-}" == verified ]]; then
        fail "$(basename "$f"): an unknown board revision came out verified"
    else
        pass "$(basename "$f"): an unknown revision is '${PROFILE[status]:-}', not verified"
    fi
done

section "detection refuses what it does not know"
# A HONOR that is not in devices/, and a machine that is not a HONOR at all.
check_detect "another HONOR laptop" HONOR NMH-WDX9 "" ""      ""    1 "(rc=1)"
check_detect "same code, other OEM"  LENOVO ZQC-P  "" ""      ""    1 "(rc=1)"
# The four DRA marketing codes are NOT what the firmware reports. If one of
# them ever comes back as a dmi_product, it is a profile that can never match.
for ghost in DRA-54 DRA-56 DRA-72; do
    check_detect "$ghost is not a DMI name" HONOR "$ghost" "" "" "" 1 "(rc=1)"
done

section "one unparseable profile does not blind the rest"
printf 'model=BROKEN\nthis is not a key=value file\n' > devices/__broken.conf
check_detect "ZQC-P beside a broken profile" HONOR ZQC-P C233 ZQC-P-PCB M1010 1 devices/zqc-p.conf
rm -f devices/__broken.conf

# --- 4c. no fix is nailed to one machine -------------------------------------
# Three ways a fix quietly becomes "works on the laptop it was written on":
#
#   a device id typed into a script instead of taken from the profile and
#   confirmed on the bus; a systemd unit pointing at a path the installer no
#   longer creates, which fails at every boot and is invisible until somebody
#   notices the symptom came back; or a per-device program that has nowhere to
#   put a second device.
#
# All three have happened here. They are checked rather than remembered.
section "no device id is baked into anything installed"
# The per-machine directories are exempt by construction: patch/<fix>/<model>/
# <board>/ exists to describe one machine, and its recipe says which part that
# machine has. Everything else has to get the id at run time.
_id_re='[0-9a-fA-F]{4}:[0-9a-fA-F]{4}'
_variant_re='^patch/[a-z0-9-]+/[a-z0-9._-]+/[A-Za-z0-9]+/'
while IFS= read -r f; do
    [[ "$f" =~ $_variant_re ]] && continue
    case "$f" in
        tools/selftest.sh) continue ;;   # this file's own fixtures are ids on purpose
    esac
    # Comments may name the machine a thing was measured on; code may not.
    hits="$(sed 's/#.*//' "$f" | grep -nE "$_id_re" || true)"
    if [[ -n "$hits" ]]; then
        fail "$f has a device id in it, outside a comment: $(head -1 <<< "$hits")"
    else
        pass "$(basename "$(dirname "$f")")/$(basename "$f")"
    fi
done < <(find patch lib tools -type f \( -name '*.sh' -o -name '*.py' -o -name '*.service' \
             -o -name '*.rules' -o -name '*.hwdb' -o -name '*.hook' \) | sort)

section "hwdb rules match a board, not a product name"
for f in patch/*/*.hwdb; do
    [[ -e "$f" ]] || continue
    body="$(sed 's/#.*//' "$f")"
    if grep -q '@HONOR_DMI_MATCH@' <<< "$body"; then
        pass "$(basename "$f"): filled in from the detected machine"
    else
        fail "$(basename "$f"): writes its own DMI match instead of using
        @HONOR_DMI_MATCH@, so it applies to every board of that product"
    fi
done

section "systemd units run a file their installer installs"
# The mic-mute fixup regressed exactly here: a rename moved the helper from
# /usr/local/lib/honor-zqcp to /usr/local/lib/honor and the unit kept the old
# path, so it failed 203/EXEC at every boot and the phantom key came back.
LIBDIR=/usr/local/lib/honor
for u in patch/*/*.service; do
    [[ -e "$u" ]] || continue
    fixdir="$(dirname "$u")"
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        base="$(basename "$path")"
        if [[ ! -f "${fixdir}/${base}" ]]; then
            fail "$(basename "$u") runs $path, which $fixdir does not ship"
        elif [[ "$(dirname "$path")" != "$LIBDIR" ]]; then
            fail "$(basename "$u") runs $path; helpers this repository installs
        live in $LIBDIR, and a stale directory here fails silently at boot"
        else
            pass "$(basename "$u"): $base"
        fi
    done < <(grep -hoE '^(ExecStart|ExecStop|Documentation)=(file:)?/[^ ]*' "$u" \
             | sed -e 's/^[^=]*=//' -e 's|^file:||')
done

# Every installer must work when it is the only thing you run, from any working
# directory: `sudo bash patch/fan/install.sh` is how most people will use this,
# not `apply_patch.sh`. That means resolving its own location from BASH_SOURCE
# rather than assuming the repository is the current directory.
section "installers run standalone, from any directory"
for i in patch/*/install.sh; do
    [[ -e "$i" ]] || continue
    n="$(basename "$(dirname "$i")")"
    src="$(grep -nE '^[[:space:]]*(source|\.)[[:space:]]+.*lib/gate\.sh' "$i" || true)"
    if [[ -z "$src" ]]; then
        fail "patch/$n/install.sh never sources lib/gate.sh, so it does not gate itself"
    elif ! grep -qE '\$\{?(SCRIPT_DIR|SRC_DIR|REPO_DIR|BASH_SOURCE)' <<< "$src"; then
        fail "patch/$n/install.sh sources lib/gate.sh by a bare relative path:
        ${src#*:}
        It then only works when the current directory happens to be the right one."
    else
        pass "patch/$n: gates itself through a path it works out for itself"
    fi
done

# Anything installable has to be removable on its own too, and the removal must
# not be gated on the device profile. The cases where somebody most needs to
# take a fix off are exactly the ones where a gate would refuse: the fix was
# dropped from the profile, a BIOS update changed the DMI strings, the machine
# was recognised as the wrong board, or they are reverting before filing a bug.
section "every fix can be removed on its own"
for d in patch/*/; do
    n="$(basename "$d")"
    if [[ ! -f "$d/uninstall.sh" ]]; then
        fail "patch/$n has no uninstall.sh; it can only be removed by running
        uninstall_patch.sh, which removes everything else too"
        continue
    fi
    if grep -qE '^[^#]*honor_gate' "$d/uninstall.sh"; then
        fail "patch/$n/uninstall.sh calls honor_gate. Removing must work on a
        machine the profile no longer describes, which is when it is needed most"
        continue
    fi
    if ! grep -qE '\$\{?(SCRIPT_DIR|BASH_SOURCE)' "$d/uninstall.sh"; then
        fail "patch/$n/uninstall.sh does not work out its own location, so it
        only runs from one directory"
        continue
    fi
    pass "patch/$n"
done

# uninstall_patch.sh must call them rather than carry its own copy of the paths.
# The copy it used to carry had already fallen behind the installers in two
# places.
# The bug class this repository keeps hitting: a file is installed under one
# path and removed under another, or not removed at all, and nothing notices
# because uninstalling "succeeds" either way. It has bitten three times now —
# a systemd unit left pointing at a renamed directory, /etc/modprobe.d left
# behind, and the SDCP libfprint prefix in /opt that outranks the system library
# and would have stayed there for good.
#
# So: every absolute path an installer writes that belongs to this repository
# has to be named by that fix's uninstaller, or covered by a glob in it.
# "Belongs to this repository" is decided by the path containing "honor", which
# is true of everything these installers create.
section "everything an installer writes, its uninstaller removes"
# A fix may install or remove through a shared library rather than in its own
# script: patch/cdclk-ptl/uninstall.sh drops the xe.ko stamp by calling
# xe_uninstall in lib/xe-build.sh. So both sides are read together with whatever
# lib/*.sh they source, otherwise this check reports a gap that is not there,
# and worse, would miss one that is.
_body_of() {  # <file> -> its text plus the text of the repo libs it sources
    local f="$1" lib
    local stripped; stripped="$(sed 's/#.*//' "$f")"
    printf '%s\n' "$stripped"
    # Only real source lines. Matching every mention of lib/<name>.sh would pull
    # in a library a comment merely refers to, and then report its paths as
    # this fix's.
    while read -r lib; do
        [[ -f "lib/$lib" ]] && sed 's/#.*//' "lib/$lib"
    done < <(grep -E '^[[:space:]]*(source|\.)[[:space:]]' <<< "$stripped" \
             | grep -oE 'lib/[a-z-]+\.sh' | sed 's#lib/##' | sort -u)
}
_paths_of() {  # <file> -> repo-owned absolute paths it names
    _body_of "$1" \
        | grep -oE '/(etc|usr|var|lib|opt)/[A-Za-z0-9._*/${}-]*honor[A-Za-z0-9._*/${}-]*' \
        | sed 's#[/"'"'"']*$##' | sort -u
}
for d in patch/*/; do
    n="$(basename "$d")"
    [[ -f "$d/install.sh" && -f "$d/uninstall.sh" ]] || continue
    ubody="$(_body_of "$d/uninstall.sh")"
    # A glob in the uninstaller can cover several paths, so they are matched as
    # bash patterns rather than as text.
    mapfile -t uglobs < <(grep -oE '/(etc|usr|var|lib|opt)/[A-Za-z0-9._*/${}-]*' <<< "$ubody" | sort -u)
    bad=0
    while read -r path; do
        [[ -z "$path" ]] && continue
        # Three kinds of path are runtime state rather than installed files:
        # mktemp templates, which a trap removes; logs, which are kept on
        # purpose so a failure can still be read afterwards; and lock files,
        # which flock does not need removed and which it would be wrong to
        # delete while another process is holding one.
        [[ "$path" == *XXXXXX* || "$path" == /var/log/* || "$path" == /var/lock/* ]] && continue
        base="${path##*/}"
        [[ -n "$base" && "$ubody" == *"$base"* ]] && continue
        covered=0
        for g in "${uglobs[@]}"; do
            [[ "$g" == *'*'* ]] || continue
            # shellcheck disable=SC2053
            [[ "$path" == $g ]] && { covered=1; break; }
        done
        (( covered )) && continue
        fail "patch/$n installs $path and uninstall.sh never removes it"
        bad=1
    done < <(_paths_of "$d/install.sh")
    (( bad )) || pass "patch/$n"
done

# The other direction, which nothing checked and which cost the Fn keys: an
# uninstaller must not remove a file a *different* fix's installer put there.
# patch/micmute/uninstall.sh deleted the huawei-wmi overlay, left over from an
# early wrong theory about what was muting the microphone. Once patch/hotkeys/
# started installing a huawei-wmi overlay of its own, removing micmute silently
# removed the Fn key mapping with it, and the run said nothing.
section "an uninstaller removes only its own fix's files"
# Read each script on its own, without the libraries it sources. A path that
# comes out of lib/ is shared by construction: the xe.ko stamp really does
# belong to both patches that build xe.ko, and /usr/local/lib/honor is a
# directory several fixes put something in. Only what a fix names itself is its
# own property.
_own_paths_of() {
    local body; body="$(sed 's/#.*//' "$1")"
    { grep -oE '/(etc|usr|var|lib|opt)/[A-Za-z0-9._*/${}-]*honor[A-Za-z0-9._*/${}-]*' <<< "$body"
      # Module overlays are the interesting case and carry no "honor" in the name.
      grep -oE '/usr/lib/modules/[A-Za-z0-9._*/${}-]+/(updates|dkms)/[A-Za-z0-9._-]+\.ko(\.zst)?' <<< "$body"
    } | sed 's#[/"'"'"']*$##' | sort -u
}
declare -A OWNER=()
for d in patch/*/; do
    [[ -f "$d/install.sh" ]] || continue
    while read -r path; do
        [[ -n "$path" ]] && OWNER["$path"]="$(basename "$d")"
    done < <(_own_paths_of "$d/install.sh")
done
# A directory that holds another fix's file is not that fix's file. Uninstallers
# only ever rmdir these, and rmdir on a non-empty directory does nothing.
for path in "${!OWNER[@]}"; do
    for other in "${!OWNER[@]}"; do
        [[ "$other" == "${path}/"* ]] && { unset "OWNER[$path]"; break; }
    done
done
for d in patch/*/; do
    n="$(basename "$d")"
    [[ -f "$d/uninstall.sh" ]] || continue
    bad=0
    while read -r path; do
        [[ -n "$path" ]] || continue
        # Work directories a trap removes, not installed files.
        [[ "$path" == /var/tmp/* || "$path" == *XXXXXX* ]] && continue
        owner="${OWNER[$path]:-}"
        # Unowned paths are legacy names and shared state, which the coverage
        # check above deals with. Only a path another fix demonstrably installs
        # is a problem here.
        [[ -z "$owner" || "$owner" == "$n" ]] && continue
        fail "patch/$n/uninstall.sh removes $path, which patch/$owner/install.sh installs"
        bad=1
    done < <(_own_paths_of "$d/uninstall.sh")
    (( bad )) || pass "$n"
done

# The same rule for kernel modules, checked by module name rather than by path.
# By path it does not work: patch/hotkeys/install.sh never writes
# /usr/lib/modules/.../updates/huawei-wmi.ko.zst, it calls distro_module_install
# and lib/distro.sh builds the path. The name is what both sides do spell out.
section "a fix removes only the kernel modules it installs"
_modules_of() {  # <file> -> the module names it names, without .ko/.ko.zst
    sed 's/#.*//' "$1" \
        | grep -oE '[A-Za-z0-9_-]+\.ko(\.zst)?|distro_module_install[^|;&]*' \
        | sed 's/\.ko\.zst$//; s/\.ko$//; s/.*distro_module_install[[:space:]]*[^[:space:]]*[[:space:]]*//; s/[[:space:]].*//' \
        | grep -vE '^\$|^$|^"' | sort -u
}
declare -A MODOWNER=()
for d in patch/*/; do
    [[ -f "$d/install.sh" ]] || continue
    while read -r m; do
        [[ -n "$m" ]] && MODOWNER["$m"]="$(basename "$d")"
    done < <(_modules_of "$d/install.sh")
done
for d in patch/*/; do
    n="$(basename "$d")"
    [[ -f "$d/uninstall.sh" ]] || continue
    bad=0
    while read -r m; do
        [[ -n "$m" ]] || continue
        owner="${MODOWNER[$m]:-}"
        [[ -z "$owner" || "$owner" == "$n" ]] && continue
        fail "patch/$n/uninstall.sh removes the module '$m', which patch/$owner/install.sh installs"
        bad=1
    done < <(_modules_of "$d/uninstall.sh")
    (( bad )) || pass "$n"
done

section "the full uninstall delegates to the per-fix ones"
missing=""
for d in patch/*/; do
    n="$(basename "$d")"
    [[ -f "$d/uninstall.sh" ]] || continue
    # edp-dsc shares one kernel module with cdclk-ptl, so removing that module
    # once covers both; it is documented in uninstall_patch.sh and not listed.
    [[ "$n" == edp-dsc ]] && continue
    grep -q "$n" uninstall_patch.sh || missing+=" $n"
done
[[ -z "$missing" ]] && pass "every fix is in the removal order" \
                    || fail "uninstall_patch.sh never mentions:$missing"

# A fix that carries anything belonging to one machine keeps it under
# patch/<fix>/<model>/<board>/, the same two words the profile uses. That only
# helps if the two agree, so this checks that they do: every directory names a
# board some profile declares, every board that lists such a fix has a
# directory, and nothing is a second copy of a file that is already here.
section "per-machine parts are laid out like the profiles"

# What the profiles declare, as "model/board" and lowercase, so a directory can
# be looked up in it.
declare -A PROFILE_BOARDS=()
declare -A PROFILE_LISTS=()      # "model/board/fix" -> 1
for f in devices/*.conf; do
    [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
    PROFILE_QUIET=1 profile_load "$f" >/dev/null 2>&1 || continue
    m="${PROFILE_BASE[model],,}"
    while read -r idx boards _; do
        for b in $boards; do
            [[ "$b" == "*" ]] && continue
            PROFILE_BOARDS["${m}/${b}"]=1
            for fx in $(_profile_effective "$idx" fixes ""); do
                PROFILE_LISTS["${m}/${b}/${fx}"]=1
            done
        done
    done < <(profile_sections)
done

# Which fixes keep per-machine parts. Derived from the tree rather than listed
# here: a fix that grows a directory joins the check by growing it.
mapfile -t VARIANT_FIXES < <(
    find patch -mindepth 4 -maxdepth 4 -name recipe.conf 2>/dev/null \
    | sed 's#^patch/##; s#/.*##' | sort -u)
(( ${#VARIANT_FIXES[@]} )) || fail "no fix has a <model>/<board> directory at all"

declare -A VARIANT_SEEN=()
for fx in "${VARIANT_FIXES[@]}"; do
    n=0
    for d in patch/"$fx"/*/*/; do
        [[ -f "${d}recipe.conf" ]] || continue
        n=$((n + 1))
        rel="${d#patch/${fx}/}"; rel="${rel%/}"          # model/board
        model="${rel%%/*}"; board="${rel##*/}"
        VARIANT_SEEN["${rel}/${fx}"]=1

        # The directory has to name a machine that exists. `any` is the
        # directory form of the profile's [board *].
        if [[ "$board" == any ]]; then
            [[ -f "devices/${model}.conf" ]] \
                || fail "${d} is for model '${model}', and devices/${model}.conf does not exist"
        elif [[ -z "${PROFILE_BOARDS[${model}/${board}]:-}" ]]; then
            fail "${d} names ${model} board ${board}, which no profile declares"
        fi

        # Lowercase model, so the lookup from a profile is one transformation
        # and not a search.
        [[ "$model" == "${model,,}" ]] || fail "${d}: the model directory has to be lowercase"

        for key in name status origin; do
            grep -q "^${key}=" "${d}recipe.conf" || fail "${d}recipe.conf has no '${key}'"
        done

        target="$(sed -n 's/^same_as=//p' "${d}recipe.conf" | head -1)"
        if [[ -n "$target" ]]; then
            # One hop only, and it has to land somewhere real. A chain is how
            # two boards end up pointing at each other.
            if [[ ! -f "patch/${fx}/${target}/recipe.conf" ]]; then
                fail "${d}recipe.conf: same_as=${target} does not exist under patch/${fx}/"
            elif grep -q '^same_as=' "patch/${fx}/${target}/recipe.conf"; then
                fail "${d}recipe.conf: same_as=${target} is itself a same_as; one hop only"
            fi
            # Nothing else belongs in a directory that borrows its files.
            extra="$(find "$d" -maxdepth 1 -type f ! -name recipe.conf -printf '%f ' 2>/dev/null)"
            [[ -z "$extra" ]] \
                || fail "${d} points at ${target} and also carries files of its own: ${extra}"
            # A same_as recipe's own device= never reaches an installer, because
            # following the hop reloads the target's recipe over it. Left free
            # it would be documentation that quietly contradicts what runs, so
            # where it is written down it has to agree.
            mine="$(sed -n 's/^device=//p' "${d}recipe.conf" | head -1)"
            theirs="$(sed -n 's/^device=//p' "patch/${fx}/${target}/recipe.conf" | head -1)"
            if [[ -n "$mine" && "$mine" != "$theirs" ]]; then
                fail "${d}recipe.conf says device=${mine} while ${target} says
        device=${theirs:-none}. The hop uses the target one, so this board would
        be checked against the wrong part."
            fi
        else
            # A recipe that names a file it does not carry fails at install
            # time, on the user's machine, after the gate has already said yes.
            for key in program patches patches_old patches_full table hwdb patch; do
                v="$(sed -n "s/^${key}=//p" "${d}recipe.conf")"
                for one in $v; do
                    [[ -f "${d}${one}" ]] || fail "${d}recipe.conf names ${one}, which is not there"
                done
            done
        fi

        # The HID fixes build one object per machine and the uninstaller finds
        # them by a family glob, so the file name has to carry the family.
        case "$fx" in
            micmute)       suffix=micmute ;;
            touchpad-edge) suffix=edge ;;
            *)             suffix="" ;;
        esac
        if [[ -n "$suffix" && -z "$target" ]]; then
            prog="$(sed -n 's/^program=//p' "${d}recipe.conf")"
            [[ "$prog" == honor-*-${suffix}.bpf.c ]] \
                || fail "${d}recipe.conf: program '$prog' has to be named
        honor-<chip>-${suffix}.bpf.c, which is how uninstall_patch.sh finds it"
        fi
        pass "${fx}: ${rel}"
    done
    (( n )) || fail "patch/${fx} has no <model>/<board> directory at all"
done

# A board that lists one of these fixes and has no directory for it will get as
# far as the gate saying yes and then fail on the machine.
for key in "${!PROFILE_LISTS[@]}"; do
    fx="${key##*/}"; rel="${key%/*}"; model="${rel%%/*}"
    case " ${VARIANT_FIXES[*]} " in *" $fx "*) ;; *) continue ;; esac
    [[ -n "${VARIANT_SEEN[${rel}/${fx}]:-}" ]] && { pass "${fx}: ${rel} is listed and present"; continue; }
    [[ -f "patch/${fx}/${model}/any/recipe.conf" ]] && { pass "${fx}: ${rel} via ${model}/any"; continue; }
    fail "${rel} lists '${fx}' and patch/${fx}/${rel}/ does not exist"
done

# Two identical files under one fix mean somebody copied where they should have
# written same_as, and a copy is free to drift out of step with its original.
# This is the check that lets the layout have one directory per machine without
# turning into seventeen copies of one file.
dupes="$(find patch -mindepth 4 -type f ! -name recipe.conf -exec md5sum {} + 2>/dev/null \
    | awk '{ fx = $2; sub(/^patch\//, "", fx); sub(/\/.*/, "", fx)
             k = fx SUBSEP $1
             seen[k] = (k in seen) ? seen[k] ", " $2 : $2
             n[k]++ }
           END { for (k in n) if (n[k] > 1) print seen[k] }')"
if [[ -n "$dupes" ]]; then
    while read -r line; do
        [[ -n "$line" ]] && fail "the same file twice under one fix; use same_as: ${line}"
    done <<< "$dupes"
else
    pass "no file is carried twice"
fi

# --- 5. nothing in the tree that should not be published ---------------------
# This exists because it happened: the first commit carried dump/win11/.../MSDM
# and a full HKLM registry export, both of which contain the machine's Windows
# OEM licence key in clear text.
section "material that must never be committed"
mapfile -t tracked < <(find . -path ./.git -prune -o -type f -print)
bad=0
for f in "${tracked[@]}"; do
    case "$f" in
        *MSDM*|*msdm*)
            fail "$f is an ACPI MSDM table; it contains a Windows product key"; bad=1 ;;
    esac
done
# Key-shaped strings, in any file, compressed or not.
for f in "${tracked[@]}"; do
    case "$f" in
        *.zst) hit=$(zstd -dc "$f" 2>/dev/null | grep -acoE '[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}' || true) ;;
        *.gz)  hit=$(gzip -dc "$f" 2>/dev/null | grep -acoE '[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}' || true) ;;
        *)     hit=$(grep -acoE '[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}' "$f" 2>/dev/null || true) ;;
    esac
    if [[ -n "$hit" && "$hit" != 0 ]]; then
        fail "$f contains $hit product-key-shaped string(s)"; bad=1
    fi
done
# Registry exports must be scoped, never a whole hive.
for f in "${tracked[@]}"; do
    case "$f" in
        *HKEY_LOCAL_MACHINE*|*HKLM*)
            fail "$f looks like a whole registry hive; export only the vendor subtrees" ; bad=1 ;;
    esac
done
(( bad )) || pass "no licence keys, MSDM tables or whole registry hives"

# --- 6. shell syntax ---------------------------------------------------------
section "shell scripts"
mapfile -t scripts < <(find . -path ./.git -prune -o \( -name '*.sh' -o -name '*.bash' \) -print | sort)
for s in "${scripts[@]}"; do
    bash -n "$s" 2>/dev/null && pass "$s" || fail "$s does not parse"
done
mapfile -t pyfiles < <(find . -path ./.git -prune -o -name '*.py' -print | sort)
for s in "${pyfiles[@]}"; do
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$s" 2>/dev/null \
        && pass "$s" || fail "$s does not parse"
done
if command -v shellcheck >/dev/null; then
    if out="$(shellcheck -S warning "${scripts[@]}" 2>&1)"; then
        pass "shellcheck clean at -S warning"
    else
        fail "shellcheck:"
        printf '%s\n' "$out" | sed 's/^/        /'
    fi
else
    printf '  skip  shellcheck not installed\n'
fi

section "$([[ $fails -eq 0 ]] && echo "all checks passed" || echo "$fails check(s) failed")"
exit $(( fails > 0 ))
