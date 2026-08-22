# Fixes for HONOR MagicBook Pro 14 AI (ZQC-P / M1010)

Each subdirectory is one self-contained fix: the patch or source it needs, an
`install.sh`, and a `README.md` explaining what is broken and why the fix looks
the way it does. Every installer is safe to re-run and locates its own files,
so it can be invoked directly from anywhere.

Developed and tested on BIOS 1.10, Core Ultra X9 388H (Panther Lake), CachyOS,
kernel 7.1.5.

Which fixes an installer will run depends on the device profile in
[`devices/`](../devices/) that matches the machine. Thirteen further HONOR
MagicBook profiles are recognised, all of them from somebody else's hardware or
from a hardware probe rather than from a machine anybody here owns; on those,
only the fixes that cannot carry another machine's constants are offered, and
on several of them the honest answer is that nothing here applies at all. See
[`docs/hardware/`](../docs/hardware/) for what is known about each, and
[`docs/ADDING-A-MODEL.md`](../docs/ADDING-A-MODEL.md) for adding one.

## Status

| Area | Status | Fix |
|---|---|---|
| Touchpad, touchscreen, internal keyboard | works | [`acpi-override/`](acpi-override/) — patched SSDT27 plus `i8042.dumbkbd=1`. **Prerequisite for a usable machine** |
| Microphone mutes itself, mic-mute LED flickers | works | [`micmute/`](micmute/) — HID-BPF fixup for the touchscreen's vendor collection |
| Fingerprint reader, Goodix `27c6:6f94` | works | [`fingerprint/`](fingerprint/) — two-line `libfprint` id patch |
| Headset microphone, 3.5 mm jack | works | [`headset-mic/`](headset-mic/) — one-line `SND_PCI_QUIRK` for ALC256 |
| OLED minimum brightness too low, uneven steps | works | [`oled-backlight/`](oled-backlight/) — patched VBT raises the firmware's backlight floor |
| Touchpad left-edge slide does nothing | works | [`touchpad-edge/`](touchpad-edge/) — HID-BPF turns the vendor gesture report into brightness keys |
| Garbled screen at boot on 7.1.6+ | works, opt-in | [`cdclk-ptl/`](cdclk-ptl/) — rebuilds `xe.ko` with the upstream CDCLK fix for Panther Lake. Merged to `drm-intel-next` 2026-08-21, so expect it in 7.3 |
| Battery charge limit ignored | works | [`battery/`](battery/) — the EC arms only for HONOR's preset pairs; everything else is stored and silently dropped |
| Performance and camera keys inert | works | [`hotkey-actions/`](hotkey-actions/) — acts on the keys no desktop binds |
| Fn keys dead, `Unknown key pressed` | works | [`hotkeys/`](hotkeys/) — HONOR codes added to the `huawei-wmi` keymap |
| Fan RPM readout | works | [`fan/`](fan/) — `honor-ec-sensors` module |
| Fan speed control | not available | [`fan/README.md`](fan/README.md) — every OS-side path to a duty cycle was tested, the EC ignores all of them, and the one documented HONOR method (`WTER`) is absent from this firmware. Selecting the EC's fan *curve* does work, is measured, and is not shipped |
| SOF DSP suspend/resume panic | preventive | [`sof-audio/`](sof-audio/) — upstream IPC4 backport; the race never reproduced on this unit. **Merged upstream, released in 7.2** |
| Fixes reverted by package updates | handled | [`auto-rebuild/`](auto-rebuild/) — package-manager hooks that rebuild them automatically |
| Internal keyboard, Caps Lock LED | **merged upstream** | [`keyboard-atkbd/`](keyboard-atkbd/) — the `atkbd` DMI quirk is in Linux 7.2 and queued for 7.1.10. There, drop `i8042.dumbkbd=1` and the LED works |

## Installing

`apply_patch.sh` in the repository root runs all of them in one go and is the
intended entry point for a fresh install. `uninstall_patch.sh` reverts it.
Every step after the ACPI override is independent and only warns on failure.

Optional steps: `SKIP_OLED=1`, `SKIP_EDGE=1`, `SKIP_FAN=1`,
`SKIP_FINGERPRINT=1`. One step is off by default and has to be asked for:
`WITH_CDCLK=1` rebuilds `xe.ko` with the Panther Lake cdclk fix, which
means downloading the distro kernel source and compiling for a few
minutes. The backlight floor defaults to `VBT_MIN=12`, measured on
two units; run [`oled-backlight/measure-floor.sh`](oled-backlight/measure-floor.sh)
if you want to check it against your own panel.

Each installer also stands alone and is safe to re-run:

```sh
sudo bash patch/touchpad-edge/install.sh
```

## Surviving updates

With [`auto-rebuild/`](auto-rebuild/) installed, nothing has to be redone by
hand. `apply_patch.sh` installs it as its last step.

| Fix | What an update does | Handled by |
|---|---|---|
| `acpi-override/` | nothing, it is a firmware file | — |
| `micmute/` | nothing, the BPF object is CO-RE | — |
| `touchpad-edge/` | nothing, the BPF object is CO-RE | — |
| `oled-backlight/` | nothing on a kernel update; a **BIOS** update invalidates the blob | re-run `install.sh` |
| `fan/` | rebuilt automatically | DKMS |
| `headset-mic/` | a kernel update leaves the new kernel without the overlay | `auto-rebuild/` hook |
| `sof-audio/` | same | `auto-rebuild/` hook |
| `fingerprint/` | a libfprint update replaces the patched package | `auto-rebuild/` hook |
| `battery/` | a desktop battery applet can overwrite the armed pair | the installed units re-apply it at boot and resume |
| `hotkeys/` | a kernel update leaves the new kernel without the overlay | `auto-rebuild/` hook |
| `cdclk-ptl/` | a kernel update leaves the new kernel without the overlay | re-run `install.sh`, deliberately not hooked |

Without the hooks, re-run `headset-mic/install.sh` and `sof-audio/install.sh`
after every kernel update, and `fingerprint/install.sh` after every libfprint
update.

On a rolling distribution you will regularly have a kernel installed but not
yet booted, at which point the running kernel's headers no longer exist and
nothing can build. `fan/`, `headset-mic/` and `sof-audio/` accept a `KVER`
override to pre-build for the installed kernel instead:

```sh
sudo KVER=7.1.5-1-cachyos bash patch/fan/install.sh
```

## Upstream

Where each of these stands, checked 2026-08-22. Each fix's own README carries
the detail and the commit ids.

**Already merged — these directories are on their way out:**

| Fix | Where it landed |
|---|---|
| [`keyboard-atkbd/`](keyboard-atkbd/) | Linux **7.2**, commit `410c44b10967`, queued for 7.1.10 |
| [`sof-audio/`](sof-audio/) | Linux **7.2**, from thesofproject PR #5762; 7.1.10 too |
| [`cdclk-ptl/`](cdclk-ptl/) | `drm-intel-next` 2026-08-21, commit `1786d2688781`, `Cc: stable`. Expect **7.3**, then a 7.1.y/7.2.y backport. Note upstream's fix has a different shape from the patch here |

**Never submitted, and small enough to belong upstream:**

- the `libfprint` id addition for Goodix `27c6:6f94` — no merge request, no
  issue, and the same is true of `1c7a:05aa` in `egismoc`
- the `SND_PCI_QUIRK` entry for PCI SSID `1ee7:209d`. Two HONOR entries are
  already in `alc269.c` and one of them uses exactly this fixup
- an `atkbd` entry for `XWC-P`, the one HONOR MagicBook missing from that table

**Submitted by somebody else, coordinate before sending:**

- the `huawei-wmi` keycodes. Ruzal Daminov has a series in flight covering
  `0x288` and more, with mappings identical to
  [`hotkeys/`](hotkeys/). Do not post a competing patch
- `libfprint` MR 611 covers `10a5:9924`; it is open and currently unmergeable

**Staying here:** the SSDT override is firmware-specific and belongs to the
machine. The mic-mute fix works around a real kernel bug in `hid-input.c`,
described in [`micmute/README.md`](micmute/README.md); an HID-BPF program for it
would be the first HONOR entry in `drivers/hid/bpf/progs/`, which currently has
thirty vendor programs and nothing for this one.
