# Contributing

Thanks for taking the time. This repository collects fixes that make a HONOR
MagicBook usable under Linux: patched ACPI tables, kernel-module quirks,
HID-BPF programs and a few installers that tie them together.

Two things are worth knowing before you start.

**Every installer runs as root and edits things that decide whether the
machine boots**: firmware tables, the initramfs, the kernel command line,
kernel modules. Precision matters more here than speed.

**Almost everything here was derived from one physical machine**, a HONOR
MagicBook Pro 14 2026 (`ZQC-P`, model M1010) on CachyOS. Anything you can
confirm, or contradict, on different hardware or a different distribution is
genuinely useful, and saying "I could not test this" is a perfectly good
contribution note.

## Device profiles, and why the installer may refuse

`apply_patch.sh` identifies the machine before it touches anything. It reads
DMI, picks the matching file in [`devices/`](devices/), and stops if there is
none. That is deliberate: step 2 installs an ACPI table dumped from one
specific unit's firmware, and a foreign SSDT is not a fix that fails quietly.

Each profile carries a `status`:

| `status` | Meaning | What may run |
|---|---|---|
| `verified` | somebody ran these fixes on that machine | everything the profile lists |
| `reported` | built from a hardware dump, never run | tier A only, and only with `ALLOW_UNVERIFIED=1` |
| `draft` | assembled from public information | same as `reported` |

Fixes are sorted into trust tiers in [`lib/profile.sh`](lib/profile.sh):

- **A** derives its inputs from the running machine, or matches on a device id
  and finds nothing on hardware it was not meant for. Safe to offer anywhere.
- **B** carries model specific constants, an audio subsystem id, a measured
  backlight floor, EC register offsets. Needs `status=verified`.
- **C** installs a binary taken from one machine's firmware. Only ever from
  that machine.

So on an unverified model the answer to "why did it skip everything
interesting" is: because nobody has confirmed those constants on your
hardware yet. Sending the dump is how that changes.

Check what you have:

```sh
cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name
ls devices/
```

## Ways to help

### Report a bug

Use the bug report template. What makes a report actionable here:

- `sys_vendor`, `product_name` and BIOS version from `/sys/class/dmi/id/`
- distribution and `uname -r`
- which fix misbehaves, and whether it was installed through
  `apply_patch.sh` or its own `install.sh`
- the installer output, and `journalctl -k -b -0` around the failure

### Add a model

This is the most valuable thing right now. The repository has verified data for
exactly one machine, and the constants that matter, PCI subsystem IDs, USB and
HID ids, EC register offsets, panel VBT, are different on every model.

A profile is strict `key=value`, described field by field in
[`devices/TEMPLATE.conf`](devices/TEMPLATE.conf). It is parsed, never sourced,
because profiles arrive from people we do not know and run as root. Unknown
keys are an error rather than a warning, so a typo cannot silently drop a
value, and anything you have not read off the hardware is written as
`unknown` rather than guessed.

The fields are in two groups, and the split is the whole point:

- **Hardware inventory**, everything that can be read off a running unit or
  found in a dump: device ids, panel type, `max_brightness`, EC offsets. A
  dump alone is enough to fill this in, which is why a `reported` profile can
  be complete here. Several of these accept a space separated list, for models
  sold with different parts in different regions; the installer probes for the
  one actually fitted rather than trusting the first entry.
- **Fix parameters**, prefixed `param_`: values somebody had to measure or
  choose with the laptop in front of them. The backlight floor is a
  measurement made by eye; the audio fixup is a piece of kernel code written
  for one board. Nothing here can be derived from a dump, and that is the
  practical difference between `reported` and `verified`.

Use the "Hardware dump for a new model" template. It lists the commands to run.
Everything it asks for is read-only.

Two warnings about the dump:

- `/sys/class/dmi/id/product_serial` and `board_serial` identify your machine.
  Do not paste them. The template's commands avoid them.
- The ACPI tables and the registry extract are large. Attach them as files
  rather than pasting.

### Confirm or contradict something

If a fix works on your machine, say so with your model, BIOS, distribution and
kernel version. If a documented measurement does not reproduce, that is worth
its own issue. Several entries here were corrected exactly that way.

### Send a patch

Small, self-contained changes are easiest to review. If you are restructuring
something, open an issue first so the approach can be agreed before you spend
the time.

## How the repository is laid out

Each fix is one directory under `patch/`, and it is self-contained:

```
patch/<fix>/
├── README.md      what is broken, why the fix looks like this, what was ruled out
├── install.sh     idempotent, locates its own files, works when run directly
└── <the patch, source or BPF program it needs>
```

`apply_patch.sh` at the repository root runs all of them in order.
`uninstall_patch.sh` reverts them. Neither is a replacement for the individual
installers, which must keep working on their own.

The whole tree:

```
HONOR_ZQC-P_M1010/
├── README.md                       # this file
├── apply_patch.sh                  # one-shot installer (idempotent)
├── uninstall_patch.sh              # revert installer
├── CONTRIBUTING.md                 # conventions for installers, how to add a model
├── docs/
│   └── ADDING-A-MODEL.md           # dump -> profile -> verified, step by step
├── tools/
│   ├── collect-hwinfo.sh           # read-only hardware dump for a new profile
│   ├── dump-acpi.sh                # read-only ACPI table dump
│   └── selftest.sh                 # run this after touching a profile or a lib
├── devices/                        # one profile per supported machine
│   ├── zqc-p.conf                  #   the reference unit, status=verified
│   ├── xwc-p.conf ... fmi-xx.conf  #   thirteen more, recognised but unverified
│   └── TEMPLATE.conf               #   field by field reference for a new one
├── lib/
│   ├── profile.sh                  # profile parser, validator and trust tiers
│   ├── detect.sh                   # DMI plus PCI -> which profile applies
│   ├── gate.sh                     # the check every installer runs, and migration helpers
│   └── distro.sh                   # what differs between distributions
├── patch/                          # one self-contained directory per fix
│   ├── README.md                   # index + status table
│   ├── acpi-override/              # patched SSDT27 — touchpad, touchscreen, keyboard
│   │   ├── SSDT27_TPD0.aml         #   ready-to-install ACPI override (binary)
│   │   ├── SSDT27_TPD0.dsl         #   human-readable source
│   │   └── acpi_override.install   #   mkinitcpio install hook (early CPIO)
│   ├── keyboard-atkbd/             # upstream quirk, reference only, needs a kernel rebuild
│   │   ├── 0001-Input-atkbd-skip-deactivate-for-HONOR-ZQC-P.patch
│   │   └── README.md
│   ├── auto-rebuild/               # package-manager hooks: keep fixes applied across updates
│   │   ├── rebuild.sh              #   dispatcher, installed to /usr/local/lib/honor/
│   │   ├── 95-honor-kernel-modules.hook
│   │   ├── 96-honor-libfprint.hook
│   │   └── install.sh
│   ├── oled-backlight/             # firmware backlight floor is too low for this panel
│   │   ├── vbt-min.py              #   inspect / patch brightness_min_level in a VBT
│   │   ├── measure-floor.sh        #   find the lowest duty the panel renders evenly
│   │   ├── install.sh              #   extract, patch, initramfs + cmdline
│   │   └── uninstall.sh
│   ├── battery/                    # the charge limit the EC quietly ignores
│   │   ├── honor-battery-threshold.sh
│   │   ├── honor-battery-threshold.service
│   │   └── install.sh
│   ├── hotkey-actions/            # acts on the keys no desktop binds
│   ├── hotkeys/                    # Fn keys the huawei-wmi keymap does not know
│   │   ├── huawei-wmi-honor-keymap.patch
│   │   ├── 61-honor-keyboard.hwdb
│   │   └── install.sh
│   ├── cdclk-ptl/                  # boot-time screen corruption on kernels 7.1.6+
│   │   ├── 0001-drm-i915-cdclk-avoid-spurious-cdclk-sanitization-on-PTL.patch
│   │   └── install.sh              #   rebuild xe.ko from the distro kernel source
│   ├── touchpad-edge/              # left-edge slide gesture -> brightness keys
│   │   ├── honor-tops0102-edge.bpf.c   # HID-BPF device-event hook
│   │   └── install.sh              #   build + install via udev-hid-bpf
│   ├── micmute/                    # phantom KEY_MICMUTE from the touchscreen
│   │   ├── honor-ftsc1000-micmute.bpf.c     # HID-BPF descriptor fixup
│   │   └── install.sh              #   build + install via udev-hid-bpf
│   ├── headset-mic/                # ALC256 quirk for PCI SSID 1ee7:209d
│   │   ├── alc269-honor-zqc-p-m1010.patch
│   │   └── install.sh              #   build+install snd-hda-codec-alc269.ko
│   ├── sof-audio/                  # preventive IPC4 backport (PR #5762)
│   │   ├── 0001-ASoC-SOF-ipc4-topology-Refresh-copier-IPC-payload-before-widget-setup.patch
│   │   └── install.sh              #   build+install snd-sof.ko (updates/ overlay)
│   ├── fingerprint/                # Goodix 27c6:6f94 in libfprint
│   │   ├── libfprint-goodixmoc-honor-zqc-p-6f94.patch
│   │   ├── PKGBUILD                #   pacman-owned rebuild, avoids file conflicts
│   │   ├── sensors/               #   one recipe per reader, see its README
│   │   └── install.sh
│   └── fan/                        # honor-ec-sensors — EC fan tachometers (read-only)
│       ├── honor-ec-sensors.c
│       ├── Makefile / dkms.conf
│       └── install.sh
├── build/
│   ├── build_patch.sh              # iasl + checksum recompute + revision bump
│   └── extract_oem_acpi.sh         # dump live ACPI tables for new investigations
├── dump/                          # everything read off a real machine
│   ├── acpi/<model>/              #   firmware tables, .aml and .dsl
│   └── win11/<model>/             #   ACPI (no MSDM), PnP list, scoped registry
└── tools/
    ├── collect-hwinfo.sh          # read-only dump for a new device profile
    └── dump-acpi.sh               # this machine's ACPI tables, for dump/acpi/
```

Every subdirectory of `patch/` also carries its own `README.md` with the
measurements behind the fix and the approaches that were ruled out.

---

## Conventions for installers

These are not style preferences, they are what keeps the scripts safe to run
twice on a machine somebody depends on.

- `#!/usr/bin/env bash` and `set -euo pipefail`.
- Refuse to run unless `EUID` is 0, with the exact command to retry.
- **Idempotent.** Running twice must be a no-op the second time, and must not
  stack duplicate entries in `mkinitcpio.conf`, the kernel command line or
  udev rules.
- **Gate on the hardware you are about to touch.** Source `lib/gate.sh` and
  call `honor_gate <fix-name>` early. It identifies the machine, refuses on an
  unknown one, and enforces the trust tier. It also honours `HONOR_PROFILE`,
  which `apply_patch.sh` exports, so the detection is not repeated.
- **Take model-specific values from the profile, not from the script.** Use
  `gate_param <key> [ENV_OVERRIDE]`. A constant baked into an installer is a
  constant that will eventually reach the wrong laptop. Where a value is baked
  into something else, a patch file or a driver's DMI table, cross-check it
  against the profile and refuse on a mismatch rather than proceeding.
- **Back up before overwriting**, and print where the backup went.
- **Kernel modules go to `/usr/lib/modules/$KVER/updates/`.** `depmod` searches
  that before `kernel/`, so the packaged module is never overwritten and
  removal is one `rm`. Never write into `kernel/`.
- **Compare `vermagic`** against the running kernel before installing a module
  you built.
- Accept a `KVER` override where it makes sense. On a rolling distribution
  there is regularly a kernel installed but not yet booted.
- Explain the risky step in a comment. Future readers, including the person
  who wrote it, need to know why the odd-looking line is there.

A fix that needs an uninstall path beyond deleting a file should ship
`uninstall.sh` next to `install.sh`, and `uninstall_patch.sh` should call it.

## Distributions

Everything that differs between distributions lives in
[`lib/distro.sh`](lib/distro.sh), and gated installers get it for free through
`lib/gate.sh`. Use it rather than calling `mkinitcpio` or editing
`/etc/default/limine` directly:

| Instead of | Use |
|---|---|
| `zcat /proc/config.gz` | `distro_kernel_config_cat`, `distro_kernel_config_has` |
| `mkinitcpio -P`, `limine-update` | `distro_initramfs_rebuild` |
| editing `/etc/default/limine` | `distro_cmdline_add`, `distro_cmdline_remove` |
| `pacman -S` | `distro_pkg_install`, `distro_kernel_headers_pkg` |
| assuming `.ko.zst` | `distro_module_suffix`, `distro_module_install` |

Where a fact can be observed rather than inferred from the distribution's
name, observe it. The module compression is read off the distribution's own
modules, so a distribution nobody here has ever run still gets it right.

**Honest status:** the Arch and CachyOS paths are exercised on real hardware.
The Debian, Ubuntu and Fedora branches are written from their documented
behaviour and are **not yet tested on those systems**. If you run one of them,
saying whether it worked is a genuinely useful contribution.

Fetching kernel sources by tag from `raw.githubusercontent.com`, and using
DKMS for out-of-tree modules, already work everywhere and need no
abstraction.

## Documentation

Every fix directory has a `README.md`, and it is expected to record the
reasoning, not just the recipe: what the symptom was, what the measurement
showed, and which approaches were tried and rejected. Several fixes here look
strange until you read why the obvious version does not work.

State plainly what was verified and what was inferred. A number that came from
a datasheet and a number that came from a measurement should not read the same.

## Commits

One logical change per commit. Subject as `area: what changed`, lowercase
after the colon, in the imperative:

```
oled-backlight: raise the panel minimum through a patched VBT
```

The body is where the value is. Say what was observed, what the cause turned
out to be, and why this is the fix rather than the other one. Include the
evidence: register values, log lines, upstream commit hashes.

## Upstream first

If a fix belongs in the kernel, `libfprint` or another project, say so in the
directory's README and link the submission. The intent is for this repository
to shrink as things land, and it has: the `atkbd` quirk and the SOF copier fix
both reached Linux 7.2, and the Panther Lake cdclk fix is queued for 7.3.
[`patch/README.md`](patch/README.md#upstream) tracks where each one stands,
including the ones nobody has sent yet and the one somebody else is already
sending.

Before writing a fix, check whether upstream has done it. Several things this
family needs are already in the kernel and easy to miss — per-model `atkbd`
quirks, `hid-multitouch` entries for two of the touchpads, vendor-wide
`iwlwifi` regulatory entries. [`docs/hardware/README.md`](docs/hardware/README.md#what-the-kernel-knows-about-honor)
lists everything the kernel knows about HONOR.

## Licence

By contributing you agree that your work is published under the MIT licence in
[`LICENSE`](LICENSE).
