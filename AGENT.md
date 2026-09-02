# Handoff: HONOR ZQC-P M1020 Linux bring-up

## Purpose

This file is the persistent handoff for a future agent after the owner replaces Kubuntu with Windows temporarily, updates the BIOS through HONOR PC Manager, wipes Windows, and installs CachyOS KDE.

Read this entire file before changing firmware, ACPI, kernel modules, EC settings, partitions, or authentication. Do not infer that a fix verified on ZQC-P M1010 or M1050 is safe on M1020. Enable fixes one at a time and verify each one before continuing.

The owner speaks Russian and prefers direct, practical help. Safety is the highest priority. Do not raise voltages, power limits, thermal limits, fan duties, or write undocumented EC fields. Do not request, store, echo, or pipe passwords. Root commands must be shown for the owner to run locally if passwordless sudo is unavailable.

## Intended migration

The owner plans this sequence:

1. Wipe Kubuntu.
2. Install Windows natively on the internal SSD.
3. Let HONOR PC Manager offer and install only the BIOS intended for this exact laptop.
4. Record the resulting BIOS version and test HONOR battery protection in Windows.
5. Wipe Windows.
6. Install CachyOS KDE cleanly on the entire internal SSD, preferably Btrfs with Limine.
7. Return to a new agent session and restore only the validated M1020 fixes.

Do not use a manually downloaded BIOS merely because its marketing page resembles this laptop. A package shown as `LinhaiC-5651F-BIOS 2.03(Service)` was seen but never validated against ZQC-P M1020, SKU C170, or the machine's ESRT GUID. The safe update route is an update offered to this physical unit by HONOR PC Manager. The old firmware supports UEFI capsule-on-disk, but no update was available from LVFS when checked.

After any BIOS update, never reuse the old ACPI override before hashing the new live `I2C_DEVT` table. A BIOS update can silently rewrite ACPI tables.

## Hardware identity measured on the physical laptop

Values before the planned BIOS update:

```text
sys_vendor:       HONOR
product_name:     ZQC-P
product_version:  M1020
board_name:       ZQC-P-PCB
board_version:    M1020
product_sku:      C170
BIOS:             HONOR 1.09
BIOS date:        2026-03-19
CPU:              Intel Core Ultra X9 388H, Panther Lake
GPU:              Intel Arc B390 / Xe3, PCI 8086:b080
GPU driver:       xe
NPU:              Intel Panther Lake NPU, PCI 8086:b03e, intel_vpu
Audio controller: Intel 8086:e428
Audio subsystem:  1ee7:209d
Codec:            Realtek ALC256, codec subsystem 0x1ee7209d
Touchscreen:      FocalTech FTSC1000, HID 2808:5662
Touchpad:         Goodix TOPS0102, HID 27c6:0f9a
Fingerprint:      Goodix USB 27c6:6f94
Camera:           Luxvisions 30c9:012c
Battery:          NVT HB7075R5EHW-41T1
SSD:              KIOXIA KBG60ZNV1T02, about 1 TB
Panel:            3120x2080 at 120 Hz OLED
Backlight max:    704
```

Important differences from repository M1010 data:

- M1010 profile SKU is C233; this machine is C170.
- M1010 camera is 3277:00de; this machine is 30c9:012c.
- M1010 battery presets arm the limiter; this M1020 on BIOS 1.09 did not arm `70 90`.
- Therefore matching product name, CPU, DSDT, codec SSID, or marketing name does not justify copying every M1010 fix.

## Original Kubuntu state

Before migration:

```text
OS: Ubuntu/Kubuntu 26.04.1 LTS Resolute
Kernel: 7.0.0-30-generic
Plasma: 6.6.x
Root filesystem: ext4
Secure Boot: disabled
UEFI Setup Mode: enabled
```

Original disk layout before wiping:

```text
/dev/nvme0n1       953.9 GiB
/dev/nvme0n1p1     300 MiB FAT32, mounted /boot/efi
/dev/nvme0n1p2     953.6 GiB ext4, Kubuntu root
```

Only about 18 GiB was used and `/home/sazha` was about 4 GiB. The user explicitly preferred a full wipe and clean Windows then clean CachyOS installation over complicated dual boot partition movement.

## ACPI discovery and validated override

### Stock failure

Without an override, Linux logged:

```text
ACPI Error: No pointer back to namespace node in package
ACPI Error: AE_AML_INTERNAL, While resolving operands for [Index]
ACPI Error: Aborting method \_SB.GINF
ACPI Error: Aborting method \_SB.GNUM
ACPI Error: AE_AML_INTERNAL, (SSDT:I2C_DEVT) while loading table
ACPI Error: 1 table load failures
```

The failed `I2C_DEVT` SSDT prevented the touchpad and touchscreen from appearing.

### Exact stock table proof on BIOS 1.09

The live table was:

```text
path: /sys/firmware/acpi/tables/SSDT27
OEM table id: I2C_DEVT
size: 23708 bytes
MD5: 27bb4879b5af49ac2b613a73cf1ffa0b
```

This exactly matched the stock table carried by the repository. The patched table MD5 documented by the project is `0ed8b48df42f797b55714fab5aadaf42`.

The installed override then produced:

```text
ACPI: Table Upgrade: override [SSDT- HONOR-I2C_DEVT]
ACPI: SSDT ... (v02 HONOR I2C_DEVT 00002000 INTL 20251212)
```

After override:

```text
/sys/bus/acpi/devices/TOPS0102:00
/sys/bus/acpi/devices/FTSC1000:00
```

Both internal keyboard and touch devices worked. The kernel command line included `i8042.dumbkbd=1`.

### DSDT equivalence proof

The live M1020 BIOS 1.09 DSDT was dumped separately, avoiding a full ACPI dump containing MSDM data:

```text
size: 243659 bytes
SHA-256: a73e83433f2500702d7da50947a49267fccd5d1de0cab86cd87c4232da7bc075
```

It was byte-identical to the repository's M1010 Windows DSDT at `dump/win11/zqc-p/OEM/DSDT.aml`.

This equality justified reusing only facts derived directly from that DSDT, such as the fan tachometer offsets. It did not prove that EC firmware behavior, USB peripherals, codec module ABI, or panel observations were identical.

### Mandatory ACPI procedure after BIOS update

On the new CachyOS installation, before installing any override:

```bash
for f in /sys/firmware/acpi/tables/SSDT*; do
    id=$(sudo dd if="$f" bs=1 skip=16 count=8 2>/dev/null | tr -d '\0 ')
    if [ "$id" = I2C_DEVT ]; then
        sudo stat -c 'file=%n size=%s' "$f"
        sudo md5sum "$f"
    fi
done
```

Interpretation:

- `27bb4879b5af49ac2b613a73cf1ffa0b`: the old stock table is unchanged; the existing patched AML may be offered through the installer's normal hash gate.
- `0ed8b48df42f797b55714fab5aadaf42`: old override is already active, which should not normally be true after a clean disk wipe.
- Any other hash: stop. Dump and re-derive the one-line `_INI` fix from the new firmware. Never use `FORCE_ACPI=1` merely to get a booting machine quickly.
- If the new BIOS no longer logs `AE_AML_INTERNAL` and exposes TOPS0102/FTSC1000 without override, do not install an override at all.

Keep an external USB keyboard and mouse available for the first CachyOS boot because the live ISO will not carry this local ACPI override.

## Fixes verified on M1020

### 1. ACPI override and keyboard workaround

Repository addition:

```text
patch/acpi-override/zqc-p/M1020/recipe.conf
```

It aliases the M1010 table, but installation remains protected by the live table MD5 comparison.

On Linux 7.0 the internal keyboard required:

```text
i8042.dumbkbd=1
```

That parameter disables keyboard LED commands, so Caps Lock works logically but its LED remains dark. The upstream ZQC-P `atkbd_deactivate_fixup` is in Linux 7.2 and stable 7.1.10. On a sufficiently new CachyOS kernel, first confirm the quirk is present, then remove `i8042.dumbkbd=1`; the Caps Lock LED should return. Do not remove the parameter on an older kernel because the keyboard may stop working.

### 2. FocalTech phantom microphone-mute fix

The FTSC1000 exposed an extra input device named:

```text
FTSC1000:00 2808:5662 UNKNOWN
```

It generated phantom `KEY_MICMUTE`. The HID-BPF descriptor fix was installed and verified. The UNKNOWN input disappeared while the touchscreen remained functional.

Repository addition:

```text
patch/micmute/zqc-p/M1020/recipe.conf
```

Installer compatibility fixes made during this bring-up:

- Linux 7.0 does not contain `hid_report_descriptor_helpers.h`; installers now fetch it only when the kernel's `hid_bpf_helpers.h` includes it.
- Debian/Ubuntu BPF builds need the multiarch include directory such as `/usr/include/x86_64-linux-gnu` for `asm/errno.h`.
- Installers now detect missing `libbpf-dev` headers before compilation.

The boot reapply service was enabled and verified:

```text
honor-hid-bpf-reapply.service
```

### 3. Goodix left-edge touchpad brightness gesture

The exact device `27c6:0f9a` was confirmed. HID-BPF program `honor_tops0102_edge_event` was compiled, loaded, and functionally tested. Sliding along the left edge changed brightness. The right edge continued to control volume.

Repository addition:

```text
patch/touchpad-edge/zqc-p/M1020/recipe.conf
```

Ubuntu's `udev-hid-bpf 2.1` lacks the newer `list-loaded` command. The installer now falls back to `bpftool prog show` and no longer hides `udev-hid-bpf add` failures.

### 4. Fan RPM monitoring

The byte-identical DSDT defined:

```text
Offset 0x2c: FA0L, FA0R
Offset 0x2e: FA1L, FA1R
```

The read-only `honor-ec-sensors` DKMS module was installed and verified. Typical observed values were about 2300 RPM and 2000 RPM. Module parameters were mode 0444. The source uses `ec_read()` and does not use `ec_write()` or control fan duty.

Repository addition:

```text
patch/fan/zqc-p/M1020/recipe.conf
```

This module only displays RPM. It does not improve or alter cooling. EC/BIOS remains responsible for the fan curve.

### 5. HONOR hotkey mapping

A physical capture on M1020 recorded:

```text
WMI 0x0288: camera access toggle
WMI 0x02a3: touchpad off
atkbd f8: companion PS/2 scancode emitted with HONOR hotkeys
```

Already mapped events included:

```text
KEY_CONFIG
KEY_PRINT
KEY_MICMUTE
KEY_NOTIFICATION_CENTER
KEY_MUTE
KEY_VOLUMEDOWN
KEY_VOLUMEUP
```

The patched `huawei-wmi` overlay and board-specific hwdb rule were installed. After installation, no new unknown-key entries appeared.

Repository addition:

```text
patch/hotkeys/zqc-p/M1020/recipe.conf
```

The physical F8 camera key is not the same thing as the meaningless atkbd scancode index `f8`. The meaningful event is WMI `0x288`, mapped to `KEY_CAMERA_ACCESS_TOGGLE`; the companion atkbd `f8` is ignored to prevent noise/duplicate behavior.

### 6. Camera action and native Plasma OSD

The M1020 camera is USB `30c9:012c`, not the M1010 camera. During this session the hotkey action service was installed explicitly with `POWER_PROFILE_KEY=0` because the performance key had not been captured or requested:

```bash
sudo POWER_PROFILE_KEY=0 bash patch/hotkey-actions/install.sh
```

The resulting runtime configuration was:

```text
POWER_PROFILE_KEY=0
CAMERA_KEY=1
CAMERA_USB=30c9:012c
```

The installer's default remains `POWER_PROFILE_KEY=1`. A future plain `apply_patch.sh` run will therefore enable power-profile cycling unless the variable is passed again. Preserve `POWER_PROFILE_KEY=0` until the M1020 performance key is captured and its behavior is explicitly approved.

Pressing F8 writes only this camera's USB `authorized` attribute. Verification showed:

```text
authorized=0 -> /dev/video* disappears
press again -> camera reauthorizes and /dev/video* returns
```

The service now sends native Plasma OSD through:

```text
org.kde.plasmashell
/org/kde/osdService
org.kde.osdService.showText
camera-off / Camera Disabled
camera-on / Camera Enabled
```

This is not `notify-send`. It displays the same Plasma OSD style used by hardware keys. The system service discovers the active seat0 user and invokes `qdbus6` on that user's D-Bus session.

`ProtectHome=yes` hid `/run/user/<uid>/bus`, so it was changed to `ProtectHome=read-only`. The installer was also fixed to restart an already-running service instead of relying on `systemctl enable --now`, which does not restart active services. Both Camera Enabled and Camera Disabled OSDs were reported working.

Repository addition:

```text
patch/hotkey-actions/zqc-p/M1020/recipe.conf
```

## Fingerprint work verified on Kubuntu but not yet integrated into this profile

The Goodix USB reader is:

```text
27c6:6f94
```

Stock Ubuntu package:

```text
libfprint-2-2 1:1.95.1+tod1-0ubuntu2
fprintd 1.94.5-4
```

Stock behavior was `No devices available`.

The exact signed Ubuntu source package was downloaded from the official Ubuntu archive:

```text
libfprint_1.95.1+tod1.orig.tar.bz2
SHA-256 b04c55ce1b1f0bcf97ca6e9e3dfbcad931ac2e8f87c29548c93d1aa69d9f6c60

libfprint_1.95.1+tod1-0ubuntu2.debian.tar.xz
SHA-256 3abf87b13fe2ca2d24d8a34f8087efa0e0da877890bdc62986e78f1566565688
```

Two semantic additions were made to `libfprint/drivers/goodixmoc/goodix.c`:

```c
case 0x6F94:
  self->max_enroll_stage = 12;
```

and:

```c
{ .vid = 0x27c6, .pid = 0x6F94, },
```

The generated udev autosuspend hwdb was regenerated with:

```bash
ninja -C obj-x86_64-linux-gnu sync-udev-hwdb
```

Build version:

```text
1:1.95.1+tod1-0ubuntu2.1honor1
```

Verification:

```text
27c6:6f94 | Goodix MOC Fingerprint Sensor
```

212 functional tests passed. The sole remaining AppStream validation failure was unrelated: `appstreamcli` reported the upstream libfprint issue tracker URL temporarily unreachable. The binary package was then built with `DEB_BUILD_OPTIONS=nocheck` only after the functional suite and generated hwdb test passed.

The local package was installed. `fprintd` found one Goodix MOC device. `right-index-finger` enrollment completed, `fprintd-verify` returned `verify-match`, and `sudo` authentication succeeded through the fingerprint.

PAM was enabled through Ubuntu's standard profile:

```bash
sudo pam-auth-update --enable fprintd
```

The password remained available as fallback.

For CachyOS, do not copy the Ubuntu `.deb`. Use the repository's Arch packaging as a base, adapt the two-line Goodix patch to the exact installed libfprint source, build with makepkg in an unprivileged build user, inspect the package, then install through pacman. Verify with `fprintd-list`, enroll, verify, and only then enable PAM. Add an M1020 fingerprint recipe to this repository only after the CachyOS build and physical sensor are verified.

## Battery limiter: explicitly not validated

The standard node existed:

```text
/sys/devices/platform/huawei-wmi/charge_control_thresholds
```

Initial value was `0 100`.

A controlled test wrote `70 90` through the documented huawei-wmi interface. EC RAM then showed:

```text
start = 70
stop = 90
mode = 0
```

Mode zero means the EC stored the percentages but did not arm a limit. The setting was restored to `0 100`. No persistent battery service was installed. Do not add `battery` to the M1020 profile unless a new BIOS or Windows PC Manager produces a nonzero mode and the behavior is physically verified.

On the M1010 reference, known modes are:

```text
40 70  -> mode 1
70 90  -> mode 2
95 100 -> mode 3
```

Do not assume these work on M1020. Do not call undocumented ACPI methods, write raw EC charge fields, alter voltage/current, or use calibration-discharge methods as a substitute.

After the Windows BIOS update, test HONOR PC Manager's official battery protection. Record start, stop, and EC mode if possible. A setting that merely reads back from sysfs is not proof of enforcement.

## Headset microphone: failed patch and kernel Oops

This section is critical.

The Apple wired CTIA headset had working playback but no microphone or remote buttons. Hardware identity matched M1010:

```text
Codec: Realtek ALC256
Codec subsystem: 0x1ee7209d
PCI subsystem: 1ee7:209d
```

An M1020 alias to the M1010 headset fix was temporarily created, then removed after it caused a kernel Oops. Do not recreate or enable it without a new safe implementation.

The first build also exposed an installer bug: it hardcoded clang, while Ubuntu's kernel was built with GCC and supplied GCC-only flags. The installer now chooses GCC or clang from the target kernel config. This generic compiler-selection improvement remains in the repository.

After a successful rebuild, the overlay was installed at:

```text
/usr/lib/modules/7.0.0-30-generic/updates/snd-hda-codec-alc269.ko.zst
```

On reboot, the kernel crashed during audio probe:

```text
BUG: unable to handle page fault for address 0000000000010000
RIP: try_assign_dacs+0x7b/0x6e0 [snd_hda_codec_generic]
snd_hda_gen_parse_auto_config
alc_parse_auto_config
alc269_probe [snd_hda_codec_alc269]
```

The machine hung during two boots and only reached the desktop on a later attempt after the kernel Oops. Audio degraded to PipeWire `auto_null`.

The overlay was removed with `patch/headset-mic/uninstall.sh`. `modinfo -F filename snd_hda_codec_alc269` then resolved to the stock path under:

```text
/lib/modules/7.0.0-30-generic/kernel/sound/hda/codecs/realtek/
```

The M1020 headset recipe and `headset-mic` profile entry were removed before this commit.

Most likely explanation: the installer fetched vanilla upstream `v7.0` codec source but loaded the resulting module alongside Ubuntu's backported HDA modules. Internal, non-modversioned structures were not semantically compatible. This does not prove that the analog pin fixup itself is wrong for M1020, but it proves that this module overlay strategy is unsafe on that Ubuntu kernel.

On CachyOS:

1. Do not install the old headset fix immediately.
2. Verify normal boot/audio first.
3. Compare the exact CachyOS kernel source package to the running modules.
4. Prefer rebuilding the complete matching kernel package or applying an upstream-quality quirk to the exact distro kernel source, not mixing a single upstream source file with distro-backported companion modules.
5. Keep the stock/LTS kernel installed and make the experiment in a separate boot entry.
6. Never mark M1020 headset support verified until several clean boots, suspend/resume, speakers, headphones, DMIC, headset mic, and jack replug all pass.

Remote-button support is separate from analog microphone routing and was never demonstrated.

## Display and GPU status

The Arc B390 works with `xe`. The driver loaded DMC, GuC, HuC, and GSC firmware. The panel ran at 3120x2080 120 Hz.

Observed messages included:

```text
Selective fetch area calculation failed in pipe A
Allocated fbdev into stolen failed: -22
PXP requires PTL GSC build 1396 or newer
```

No visible PSR band or low-brightness OLED blotches were reported by the owner. Therefore the following were deliberately not enabled on M1020:

```text
psr-band
oled-backlight
cdclk-ptl
edp-dsc
```

`cdclk-ptl` specifically targets corruption on kernel 7.1.6 and later; Kubuntu was running 7.0. `edp-dsc` and OLED changes alter the display driver/VBT and require measurement, not assumption.

KDE GPU graphs were missing because KSystemStats 6.6 did not support Intel's `xe` driver. KDE bug 512866 adds xe support in Plasma/KSystemStats 6.8. Do not replace `xe` with `i915`, lower `perf_event_paranoid`, or give System Monitor root. On an older desktop, `nvtop` can read DRM fdinfo. On Plasma 6.8, use native xe support.

The GPU exported xe PMU events:

```text
engine-active-ticks
engine-total-ticks
gt-actual-frequency
gt-requested-frequency
gt-c6-residency
```

Process DRM fdinfo contained `drm-driver: xe`, engine cycles, and GTT/system memory accounting.

## Plasma microphone OSD and LEDs

The physical F7 key already emitted `KEY_MICMUTE`. The mic LED was attached to `[audio-micmute]` and correctly followed the actual default-source mute state:

```text
Mute: yes -> LED brightness 1
Mute: no  -> LED brightness 0
```

Plasma initially showed OSD when muting but not when unmuting. This was identified as KDE bugs 500828/521973: `PreferredDevice` could miss the default source signal before construction. The upstream fix initializes preferred devices in the constructor and is marked fixed in Plasma 6.8.0.

A temporary `notify-send` monitor was created, rejected because it was not a native Plasma OSD, and completely removed. Do not recreate:

```text
~/.local/bin/mic-unmute-notify
~/.config/systemd/user/mic-unmute-notify.service
```

After the default source changed and returned, native F7 OSD began working in both directions for the session. The owner chose to wait for Plasma 6.8 rather than carry a local plasma-pa rebuild.

Caps Lock LED is separate. It is disabled by `i8042.dumbkbd=1` on old kernels. Use the upstream atkbd quirk in Linux 7.2/7.1.10+, not an LED daemon.

## CachyOS recommendation and initial setup

CachyOS is a reasonable final OS for this owner because Panther Lake and Arc B390 benefit from fresh kernel, Mesa, firmware, and Vulkan. The owner also plans gaming. CachyOS offers native packages, Proton-CachyOS, Gamescope, MangoHud, and performance tooling. It is still a rolling release and may regress.

Recommended clean installation:

- CachyOS KDE.
- Btrfs.
- Limine with snapshots if the installer supports the desired layout.
- Secure Boot disabled during installation.
- Install both `linux-cachyos` and `linux-cachyos-lts`.
- Keep a bootable USB and external keyboard/mouse.
- Use full `pacman -Syu`; never perform partial upgrades.
- Create a snapshot before major kernel, Mesa, Plasma, or firmware changes.
- Prefer the stable CachyOS kernel first; use RC kernels only in a separate boot entry.

Likely initial dependencies for this repository on CachyOS include the appropriate kernel headers, base-devel, git, curl, cpio, acpica, clang/LLVM for HID-BPF, bpftool from the Arch/Cachy package providing it, libbpf, udev-hid-bpf, DKMS, and Python. Confirm current package names instead of blindly copying Ubuntu names.

Gaming notes:

- Install the official CachyOS gaming meta packages through CachyOS Hello or pacman.
- Keep Valve Proton stable/Experimental available alongside Proton-CachyOS.
- Do not expect every optimization to produce a large FPS gain.
- Arc B390 at native 3120x2080 is demanding; use XeSS/FSR or a lower render resolution where appropriate.
- Kernel-level anti-cheat compatibility is game-specific and is not fixed by choosing CachyOS.

## First-session checklist on CachyOS

Before applying patches, collect:

```bash
uname -a
cat /etc/os-release
for f in sys_vendor product_name product_version product_sku board_name board_version bios_vendor bios_version bios_date; do
    printf '%s: ' "$f"
    cat "/sys/class/dmi/id/$f" 2>/dev/null || true
done
cat /proc/cmdline
lspci -nnk
lsusb
cat /proc/bus/input/devices
journalctl -b -k --no-pager | grep -iE 'ACPI|I2C_DEVT|AE_AML_INTERNAL|i8042|TOPS|FTSC|HID|snd|sof|hda|xe|drm'
```

Then hash `I2C_DEVT` using the mandatory procedure above.

Apply and verify in this order, rebooting only when required and stopping on errors:

1. ACPI override only if the new live table exactly matches a recorded stock table or a new patch has been derived from the new firmware.
2. Confirm internal keyboard, touchpad, touchscreen, and a fallback boot entry.
3. Check whether the new kernel already carries the ZQC-P atkbd quirk; remove `i8042.dumbkbd=1` only when proven.
4. HID-BPF micmute fix; verify UNKNOWN input disappears.
5. HID-BPF touchpad edge fix; physically test brightness and volume edges.
6. Fan RPM DKMS using offsets only after confirming the new DSDT still places FA0/FA1 at 0x2c/0x2e.
7. Hotkey mapping; run `capture-keys.sh` again because firmware may change emitted codes.
8. Camera action with actual USB ID; BIOS update could change camera enumeration or model.
9. Fingerprint package built against exact CachyOS libfprint source.
10. Test suspend/resume, audio, camera, Wi-Fi, Bluetooth, NPU, fingerprint, and input across several boots.
11. Only then consider auto-rebuild hooks.

Do not enable M1010-only display, battery, audio, or SOF patches merely because they appear in the longer M1010 profile.

## Repository changes in this branch

Expected intentional changes:

```text
README.md
devices/zqc-p.conf
docs/hardware/README.md
docs/hardware/zqc-p.md
patch/acpi-override/zqc-p/M1020/recipe.conf
patch/fan/zqc-p/M1020/recipe.conf
patch/hotkey-actions/zqc-p/M1020/recipe.conf
patch/hotkeys/zqc-p/M1020/recipe.conf
patch/micmute/zqc-p/M1020/recipe.conf
patch/touchpad-edge/zqc-p/M1020/recipe.conf
patch/micmute/install.sh
patch/touchpad-edge/install.sh
patch/hotkey-actions/honor-hotkey-actions.py
patch/hotkey-actions/honor-hotkey-actions.service
patch/hotkey-actions/install.sh
patch/headset-mic/install.sh
AGENT.md
```

The M1020 profile intentionally lists only:

```text
acpi-override micmute touchpad-edge fan hotkeys hotkey-actions
```

It records hardware IDs for future fingerprint/audio work, but does not list fingerprint until the CachyOS package is integrated and does not list headset-mic after the kernel Oops.

The generic headset installer compiler-selection fix remains useful, but it must not be interpreted as making the headset patch safe for M1020.

## Verification commands for this repository

Run before committing or after restoring the repository:

```bash
bash tools/selftest.sh
bash -n apply_patch.sh uninstall_patch.sh
python3 -m py_compile patch/hotkey-actions/honor-hotkey-actions.py
git diff --check
git status --short
```

The full self-test passed after the M1020 additions. `shellcheck` was not installed during the session, so the self-test reported that check as skipped.

## Security and operational rules for the next agent

- Never accept or embed a password in commands, logs, scripts, environment variables, or chat.
- Never commit ACPI MSDM tables, Windows product keys, firmware blobs from unknown sources, biometric templates, VPN secrets, or full logs containing credentials.
- Never flash BIOS, delete partitions, wipe filesystems, or remove the last working kernel without explicit confirmation for that exact action.
- Never use `FORCE_ACPI=1` after a BIOS change without proving table compatibility.
- Never write raw EC fields to experiment with fan duty, battery voltage/current, or undocumented modes.
- Keep a stock or LTS kernel and a fallback boot entry before testing kernel modules.
- A matching PCI/USB ID is necessary but not always sufficient. The headset crash proved that distro kernel source compatibility matters.
- Validate fixes one at a time and inspect the previous boot journal after any hang.
- Preserve password authentication when enabling fingerprint PAM.
- Do not hide build/test failures. Investigate them and document any consciously accepted unrelated test failure.

## Known good outcomes before migration

Verified physically or from system state:

- Internal keyboard works.
- Touchpad works.
- Touchscreen works.
- Left-edge brightness gesture works.
- Right-edge volume gesture works.
- Phantom touchscreen mic-mute input is gone.
- F7 mic mute and LED state work.
- Camera F8 physically deauthorizes/reauthorizes the camera.
- Native Plasma camera OSD works after the updated service is restarted.
- Fan RPM readings are plausible.
- Wi-Fi and Bluetooth work.
- USB camera works.
- Built-in speakers and DMIC worked before the failed headset overlay.
- Intel NPU binds to intel_vpu.
- Arc B390 binds to xe.
- Goodix fingerprint enroll, verify, and sudo authentication work on the patched Ubuntu libfprint.

Not verified or known broken:

- Battery charge limit: not armed on BIOS 1.09.
- Apple headset microphone: not working with stock configuration.
- Apple headset remote buttons: not working and separate from mic routing.
- M1020 headset codec overlay: caused kernel Oops and must remain disabled.
- Native KDE xe GPU graphs: unavailable before Plasma 6.8.
- Caps Lock LED: unavailable while old kernel requires `i8042.dumbkbd=1`.
- Display-specific M1010 patches: deliberately not tested because no corresponding visible defect was reported.
