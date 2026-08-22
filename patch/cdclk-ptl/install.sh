#!/usr/bin/env bash
# Rebuild xe.ko with the Panther Lake CDCLK sanitization fix.
#
# Since 7.1.6 the shared i915 display code forces a full CDCLK PLL
# disable+enable during driver load on every Panther Lake machine. The panel
# is already lit by the GOP at that point, so the screen shows garbage.
# See README.md in this directory for the trace.
#
# The fix is a 4-line upstream patch. It reached drm-intel-next on 2026-08-21
# and rides the merge window into Linux 7.3, so on any kernel you can install
# today the module has to be rebuilt locally. Only xe.ko is rebuilt: it compiles
# i915-display/intel_cdclk.o straight out of drivers/gpu/drm/i915/display/,
# so the whole kernel does not have to be built.
#
# The result is installed into /usr/lib/modules/$KVER/updates/, which depmod
# searches before kernel/, so the packaged module is never overwritten.
#
# Env knobs:
#   KVER=...     build for another installed kernel (default: running one)
#   JOBS=N       parallel compile jobs (default: nproc)
#   WORKDIR=...  where to unpack the source (default: /var/tmp/honor-cdclk)
#   KEEP_SRC=1   do not delete the source tree afterwards
#   REGEN=0      do not regenerate the initramfs (the caller will)

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/0001-drm-i915-cdclk-avoid-spurious-cdclk-sanitization-on-PTL.patch"
KVER="${KVER:-$(uname -r)}"
JOBS="${JOBS:-$(nproc)}"
WORKDIR="${WORKDIR:-/var/tmp/honor-cdclk}"
KEEP_SRC="${KEEP_SRC:-0}"
REGEN="${REGEN:-1}"
MODDIR="/usr/lib/modules/${KVER}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. is this machine affected at all? -------------------------------------
[[ -f "$PATCH_FILE" ]] || die "patch not found: $PATCH_FILE"
[[ -d "$MODDIR" ]]     || die "no module tree for kernel $KVER"

# Tier A: the patch either applies to the kernel source or it does not, and the
# bug is a property of the display IP rather than of the model.
source "${SCRIPT_DIR}/../../lib/gate.sh"
honor_gate cdclk-ptl

# The bug needs display IP 30, which arrived with Panther Lake. Earlier
# platforms still have the CD2X pipe field the sanitization compares.
if [[ "$(profile_get platform)" != "pantherlake" ]]; then
    die "$(profile_get model) is platform '$(profile_get platform)', and this
    regression only affects display IP version 30 and newer, which arrived with
    Panther Lake. Nothing to fix here."
fi

LSPCI_OUT="$(lspci -nn 2>/dev/null || true)"
if ! grep -qiE '00:02\.0 .*(Panther Lake|Wildcat Lake)' <<< "$LSPCI_OUT"; then
    warn "no Panther Lake / Wildcat Lake iGPU found on 00:02.0, though the"
    warn "profile says this is a Panther Lake machine. Continuing anyway."
fi

# The regression landed in v7.1.6 and is still unfixed in every later release.
# Anything older than that, or any tree that already carries the fix, needs
# nothing. The source check below is the authoritative one; this is just a
# friendly early exit.
KBASE="${KVER%%-*}"
OLDEST_BAD="7.1.6"
if [[ "$KBASE" != "$OLDEST_BAD" &&
      "$(printf '%s\n%s\n' "$KBASE" "$OLDEST_BAD" | sort -V | head -1)" == "$KBASE" ]]; then
    warn "kernel $KBASE predates the regression (it was introduced in $OLDEST_BAD)."
    warn "Nothing to fix here. Set FORCE=1 to build anyway."
    [[ "${FORCE:-0}" == "1" ]] || exit 0
fi

log "kernel  = $KVER"
log "jobs    = $JOBS"

# --- 2. toolchain -------------------------------------------------------------
# The module has to be built with the same compiler family as the kernel,
# otherwise the LTO objects do not match.
distro_kernel_config_path "$KVER" >/dev/null \
    || die "no kernel config available for $KVER.
    Expected /proc/config.gz, /boot/config-$KVER or ${MODDIR}/build/.config."
read_config() { distro_kernel_config_cat "$KVER"; }

MAKEVARS=()
if distro_kernel_config_has CONFIG_CC_IS_CLANG=y "$KVER"; then
    MAKEVARS=(LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld)
    NEED=(clang ld.lld llvm-strip llvm-objcopy)
else
    NEED=(gcc)
fi
NEED+=(make bc flex bison zstd curl tar depmod)

for t in "${NEED[@]}"; do
    command -v "$t" >/dev/null || die "missing required tool: $t"
done
command -v pahole >/dev/null || warn "pahole not found, the module will be built without BTF"

log "toolchain = ${MAKEVARS[*]:-gcc}"

# --- 3. get the exact source the running kernel was built from ---------------
mkdir -p "$WORKDIR"
cd "$WORKDIR"

SRCDIR=""
if [[ "$KVER" == *cachyos* ]] && command -v pacman >/dev/null; then
    # CachyOS publishes the fully patched tree as a GitHub release, one per
    # package version. That is byte-for-byte what the running kernel came from.
    PKG=$(pacman -Qqo "${MODDIR}/vmlinuz" 2>/dev/null || echo "")
    PKGVER=$(pacman -Q "${PKG:-linux-cachyos}" 2>/dev/null | awk '{print $2}')
    [[ -n "$PKGVER" ]] || die "cannot determine the linux-cachyos package version"
    TAG="cachyos-${PKGVER}"
    SRCDIR="$TAG"
    if [[ ! -d "$SRCDIR" ]]; then
        log "downloading CachyOS source tarball $TAG (about 260 MB)"
        curl -fSL --retry 3 -o "${TAG}.tar.gz" \
            "https://github.com/CachyOS/linux/releases/download/${TAG}/${TAG}.tar.gz" \
            || die "download failed. Check that the release ${TAG} exists."
        log "unpacking"
        tar xzf "${TAG}.tar.gz"
        rm -f "${TAG}.tar.gz"
    else
        log "reusing existing source tree $SRCDIR"
    fi
else
    # Vanilla fallback. Good enough on stock Arch; on a distro that patches
    # drm this will produce a module that does not match the running kernel,
    # so it refuses to go further unless forced.
    MAJOR="${KBASE%%.*}"
    SRCDIR="linux-${KBASE}"
    if [[ ! -d "$SRCDIR" ]]; then
        log "downloading vanilla linux-${KBASE} from kernel.org"
        curl -fSL --retry 3 -o "linux-${KBASE}.tar.xz" \
            "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${KBASE}.tar.xz" \
            || die "download failed"
        tar xf "linux-${KBASE}.tar.xz"
        rm -f "linux-${KBASE}.tar.xz"
    fi
    warn "building against a vanilla tree. If this distro patches drm/, the"
    warn "resulting module may not match the running kernel."
fi

cd "$SRCDIR"

# --- 4. patch -----------------------------------------------------------------
# Upstream took a different shape than the patch carried here: instead of
# guarding the two lines with DISPLAY_VER(display) < 30, commit 1786d2688781
# introduced a has_cd2x_pipe_select() helper, and 1ceb1ef81c32 moved the rest
# of the driver onto it. So a tree that already has the fix will NOT reverse-
# apply our patch — it has to be recognised by the helper's presence.
CDCLK_SRC="drivers/gpu/drm/i915/display/intel_cdclk.c"
if [[ -r "$CDCLK_SRC" ]] && grep -q 'has_cd2x_pipe_select' "$CDCLK_SRC"; then
    log "this kernel carries the upstream fix (has_cd2x_pipe_select). Nothing to do."
    log "patch/cdclk-ptl/ is obsolete on this kernel; uninstall_patch.sh will"
    log "remove any module this repository installed earlier."
    exit 0
fi

if patch -Np1 -R --dry-run --silent < "$PATCH_FILE" >/dev/null 2>&1; then
    log "fix already present in the source tree"
elif patch -Np1 --dry-run --silent < "$PATCH_FILE" >/dev/null 2>&1; then
    log "applying the cdclk fix"
    patch -Np1 < "$PATCH_FILE"
else
    die "the patch does not apply to this tree.
    Either the fix has landed upstream in a shape this installer does not
    recognise, in which case this whole directory is obsolete, or the source
    does not match the running kernel."
fi

# --- 5. configure exactly like the running kernel -----------------------------
log "restoring the running kernel's config"
read_config > .config

# vermagic must come out identical or the module will not load. On Arch-like
# trees the release suffix lives in these two files.
if [[ -r "${MODDIR}/build/localversion.10-pkgrel" ]]; then
    cp "${MODDIR}/build/"localversion.* .
else
    # Derive "-1-cachyos" style suffix from the running release string.
    printf '%s\n' "-${KVER#${KBASE}}" | sed 's/^--/-/' > localversion.90-local
fi

# The build has no access to the distro signing key. Signing is off anyway on
# every machine this repo targets (MODULE_SIG_FORCE unset, Secure Boot off),
# so an unsigned module loads fine.
./scripts/config -d MODULE_SIG_ALL
make "${MAKEVARS[@]}" olddefconfig >/dev/null

# Resolve external symbols against the real kernel rather than an empty tree.
[[ -r "${MODDIR}/build/Module.symvers" ]] && cp "${MODDIR}/build/Module.symvers" .

# --- 6. build just the xe module ----------------------------------------------
log "preparing the tree"
make "${MAKEVARS[@]}" -j"$JOBS" modules_prepare

log "building drivers/gpu/drm/xe (a few minutes)"
nice -n 5 make "${MAKEVARS[@]}" -j"$JOBS" M=drivers/gpu/drm/xe

KO="drivers/gpu/drm/xe/xe.ko"
[[ -f "$KO" ]] || die "build produced no xe.ko"

# --- 7. finish the module the way modules_install would -----------------------
# BTF first, then strip: .BTF is not a .debug section and survives the strip.
if command -v pahole >/dev/null && [[ -r /sys/kernel/btf/vmlinux ]]; then
    log "generating module BTF against the running kernel's base BTF"
    LLVM_OBJCOPY=llvm-objcopy pahole -J --btf_base /sys/kernel/btf/vmlinux "$KO" \
        || warn "BTF generation failed, continuing without it"
fi

log "stripping and compressing"
if command -v llvm-strip >/dev/null; then llvm-strip --strip-debug "$KO"
else strip --strip-debug "$KO"; fi
zstd -q -f -19 -T0 "$KO" -o "${WORKDIR}/xe.ko.zst"

NEW_VM=$(modinfo "${WORKDIR}/xe.ko.zst" | awk -F': *' '/^vermagic:/{print $2}')
OLD_VM=$(modinfo -k "$KVER" xe 2>/dev/null | awk -F': *' '/^vermagic:/{print $2}')
[[ "$NEW_VM" == "$OLD_VM" ]] \
    || die "vermagic mismatch, refusing to install
    built:   $NEW_VM
    running: $OLD_VM"
log "vermagic matches: $NEW_VM"

# --- 8. install ---------------------------------------------------------------
install -Dm644 "${WORKDIR}/xe.ko.zst" "${MODDIR}/updates/xe.ko.zst"
depmod "$KVER"
log "installed ${MODDIR}/updates/xe.ko.zst"
echo "    $(modinfo -k "$KVER" xe | grep -E '^filename:')"

# --- 9. initramfs -------------------------------------------------------------
# xe is pulled into the initramfs by the kms hook, so the early-KMS copy has to
# be refreshed too, otherwise the stock module is the one that lights the panel.
if [[ "$REGEN" == "1" ]]; then
    log "regenerating the initramfs"
    distro_initramfs_rebuild || warn "regenerate the initramfs yourself"
else
    log "REGEN=0, skipping the initramfs rebuild"
fi

# --- 10. cleanup --------------------------------------------------------------
if [[ "$KEEP_SRC" != "1" ]]; then
    log "removing the source tree (KEEP_SRC=1 to keep it)"
    cd /
    rm -rf "${WORKDIR:?}/${SRCDIR:?}"
fi

log "done. Reboot, then check:"
echo "    cat /sys/module/xe/srcversion            # should be $(modinfo "${WORKDIR}/xe.ko.zst" | awk -F': *' '/^srcversion:/{print $2}')"
echo "    modinfo xe | head -1                     # should point at updates/"
