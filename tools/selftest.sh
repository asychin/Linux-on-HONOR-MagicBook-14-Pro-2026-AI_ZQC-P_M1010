#!/usr/bin/env bash
#
# Checks the repository against itself. No root, no hardware, no network: it
# runs anywhere, including in CI and in a container, and it is the thing to run
# after editing a device profile.
#
# What it checks:
#   1. every devices/*.conf parses, validates, and carries no comments
#   2. every fix named in a profile has a directory under patch/, a trust tier,
#      and a call from apply_patch.sh
#   3. the bootloader command line is edited in place or refused, never flattened
#   4. detection picks the right profile for each model's real DMI values, and
#      two profiles can never both match one machine
#   5. nothing in the tree looks like a licence key, an MSDM table or a whole
#      registry hive
#   6. every shell script passes `bash -n`, and shellcheck if it is installed

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

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

# --- 2. every fix named in a profile exists ---------------------------------
section "fixes named in profiles"
for f in devices/*.conf; do
    [[ "$(basename "$f")" == TEMPLATE.conf ]] && continue
    PROFILE_QUIET=1 profile_load "$f" >/dev/null 2>&1 || continue
    for fix in ${PROFILE[fixes]:-}; do
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
    local name="$1" fname="$2" content="$3" want="$4"
    local d; d="$(mktemp -d)"; mkdir -p "$(dirname "$d/$fname")"
    printf '%s' "$content" > "$d/$fname"
    local before_lines after_lines rc
    before_lines="$(grep -c '' "$d/$fname" 2>/dev/null || echo 0)"
    distro_cmdline_file() { echo "$d/$fname"; }
    distro_cmdline_add "SELFTEST=1" >/dev/null 2>&1 && rc=0 || rc=1
    after_lines="$(grep -c '' "$d/$fname" 2>/dev/null || echo 0)"
    case "$want" in
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
    local name="$1" want="$8" rc got
    FAKE_VENDOR="$2"; FAKE_PRODUCT="$3"; FAKE_SKU="$4"
    FAKE_BOARD="$5";  FAKE_BV="$6";      FAKE_NVIDIA="$7"
    DETECT_PROFILE=""
    detect_profile devices >/dev/null 2>&1 && rc=0 || rc=$?
    got="$DETECT_PROFILE"
    (( rc != 0 )) && got="(rc=$rc)"
    [[ "$got" == "$want" ]] && pass "$name -> $got" \
                            || fail "$name -> $got, wanted $want"
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
