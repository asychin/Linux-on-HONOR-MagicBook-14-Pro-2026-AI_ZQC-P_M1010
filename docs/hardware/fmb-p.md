# FMB-P — MagicBook Pro 14 2025

| | |
|---|---|
| Product code | `FMB-P`, board `FMB-P-PCB`, board versions `M1010` `M1020` `M1030` `M1070` `M1090` |
| Platform | Intel Arrow Lake H — Core Ultra 5 225H or Ultra 9 285H |
| Profile | [`devices/fmb-p.conf`](../../devices/fmb-p.conf) — **reported** |
| Read from | 10 hardware probes and four independent projects |

After the reference machine, this is the best-supported model in the family and
by far the best-documented. Ten hardware probes exist, spanning Fedora 43 and
44, NixOS 26.05, Arch, Manjaro and Evernight Vista, on kernels 6.12 to 7.1.1,
and people run it daily. One report on kernel 7.0 calls it "effectively 100%
functional".

Nothing below was measured here. Every row says where it came from.

Other models: [index](README.md).

## Sources

| Who | What |
|---|---|
| [colorcube/Linux-on-Honor-Magicbook-14-Pro](https://github.com/colorcube/Linux-on-Honor-Magicbook-14-Pro) | the main project for this machine. Issues #3 to #24 and PR #21, largely by **tsukasagenesis** and **nikube** |
| [drphilth/honor-magicbook-pro-14-ubuntu](https://github.com/drphilth/honor-magicbook-pro-14-ubuntu) | Debian packaging, and [`docs/dsdt-root-cause.md`](https://github.com/drphilth/honor-magicbook-pro-14-ubuntu/blob/main/docs/dsdt-root-cause.md), the clearest write-up of the ACPI defect anywhere |
| [denis-bb/honor-fmb-p-dsdt](https://github.com/denis-bb/honor-fmb-p-dsdt) | patched DSDTs for BIOS 1.13, global and Chinese |
| [astenir/honor-fmb-p-bios-1.16-dsdt](https://github.com/astenir/honor-fmb-p-bios-1.16-dsdt) | the same for BIOS 1.16 |
| linux-hardware.org | probes [4fd456fede](https://linux-hardware.org/?probe=4fd456fede), [cb4b31864c](https://linux-hardware.org/?probe=cb4b31864c), [aaa5a6aa00](https://linux-hardware.org/?probe=aaa5a6aa00), [1657e7ed5c](https://linux-hardware.org/?probe=1657e7ed5c) and six more |

## Hardware

Every id below is identical on all ten probes unless the row says otherwise.

| | | Source |
|---|---|---|
| **Audio** | `8086:7728` "Arrow Lake cAVS", subsystem **`1ee7:2066`**, ALC256 codec, `snd_sof_pci_intel_mtl` | 10 probes |
| **Touchpad** | **`347d:7853`**, ACPI `BLTP7853`, on `i2c_designware.1` | 3 probes with input logs |
| **Webcam** | **`3277:00b9`** "SenseTek FHD Camera", `uvcvideo` | 10 probes |
| **Fingerprint** | **`10a5:9924`** (FPC, 7 probes) or **`1c7a:05aa`** (LighTuning EgisTec ETU906Axx, 3 probes). Both report `failed` — no in-kernel driver | probes, and colorcube #6 |
| **Panel** | **OLED**, asserted by the panel itself: the EDID DisplayID block reads `Display Device Technology: Organic LED`. EDO `EDO14.55`, 3120x2080 at 120 Hz, 12 bpc, 700 cd/m² full-field | [probe 4fd456fede EDID](https://linux-hardware.org/?probe=4fd456fede&log=edid) |
| **Battery** | NVT `HB7075R5EHW-41T1`, 92.0 Wh | probes |
| **BIOS** | `1.13` (05/08/2025) on all ten, across five board revisions. `1.16` (02/27/2026) exists and is reported by colorcube | probes, colorcube #15/#18 |

The fingerprint split is *within* board revision M1030, so it is a batch or
region split, not a board split. That is why `fingerprint_usb` lists both and
the installer probes the USB bus.

`10a5:9201`, `10a5:9800` and `10a5:a920` were listed here as "reported without
corroboration" until 2026-08-22. Reading colorcube #6 to the end, that was too
generous: those were posted as links to a Lenovo ThinkPad driver and to an
unrelated project, not as readings from this machine. None appears in any
probe. They are dropped.

### The board revisions

Five, all on BIOS 1.13, all reporting `product_name FMB-P`:

| `board_version` | `product_sku` | Chassis SKU |
|---|---|---|
| `M1010` | — | — |
| `M1020` | `C100` | `FermatB-9211T` |
| `M1030` | `C170` | `FermatB-5211T` |
| `M1070` | — | — |
| `M1090` | `C233` | `FermatB-9211T` |

`C233` is also what the reference ZQC-P reports. See
[the index](README.md#what-the-firmware-calls-these-machines) for why `dmi_sku`
is the last tiebreaker and never the deciding one.

## The ACPI table failure

FMB-P has it, and the trigger is **not** a touchpad SSDT — it is the DSDT
itself. Probe [cb4b31864c](https://linux-hardware.org/?probe=cb4b31864c&log=dmesg)
(Fedora 44, kernel 6.19.14, BIOS 1.13, unpatched) logs:

```
ACPI Error: Aborting method \_SB.GINF due to previous error (AE_AML_INTERNAL)
ACPI Error: Aborting method \_SB.GNUM due to previous error (AE_AML_INTERNAL)
ACPI Error: AE_AML_INTERNAL, [DSDT] table load failed
```

drphilth traced it: `Device (NFC0)` with `_HID "NTAG0001"` on
`\_SB.PC00.I2C1` runs `CreateWordField (SBGF, 0x17, INT1); INT1 = GNUM
(0x0014080A)` in the device body, i.e. at load time. FMB-PM's DSDT carries the
identical statement with the identical literal argument.

**An override has to be built per BIOS version.** BIOS 1.13 ships a
528,211-byte DSDT; BIOS 1.16 ships 522,231 bytes. Both have the same NFC0 bug,
and applying one machine's table to the other is how people brick a boot.

### Three patched DSDTs are in circulation

Four projects publish a corrected FMB-P DSDT and they are not interchangeable.
Checked 2026-08-22:

| Project | bytes | OEM rev | md5 (global / chinese) |
|---|---|---|---|
| [denis-bb](https://github.com/denis-bb/honor-fmb-p-dsdt) | 522,743 | 0xb / 0xa | `70c1a162…` / `78301569…` |
| [EvernightFedora](https://github.com/EvernightFedora/evernight-honor-acpi) | 522,743 | 0xb / 0xa | byte-identical to denis-bb, and credits them |
| [drphilth](https://github.com/drphilth/honor-magicbook-pro-14-ubuntu) | 522,901 | 0x3 | `8ea9a809…` / `e0e055ba…` |
| [NOREIED](https://github.com/NOREIED/linux-honor-fmb-p-dsdt) | 522,936 | 0x2 | `89880de9…` / `bb732b65…` |

They differ because they fix different amounts: denis-bb moves the NFC0 call,
drphilth additionally injects the missing touchscreen power resource, NOREIED
adds touchscreen support of its own. Bigger is not better, and mixing a table
from one with instructions from another is how people end up debugging a
machine that half works.

There is also a **global** and a **chinese** variant of each. Which one a given
unit needs is not predictable from where it was bought: denis-bb issue #7 is a
China-market machine on BIOS 1.1.6 that needs the *global* table.

### The touchscreen needs more than that

Separate defect, and it is why "the DSDT fix" is not the whole story on units
that have a touchscreen. The active touchscreen is `\_SB.PC00.I2C2.TPL1` and
returns `_STA = 0x0F`, but it has no `_PS0`/`_PS3` or `_PR0`/`_PR3`: the
firmware defined the `PTPL` power resource only for the *inactive* `TPL1`
instances on I2C4 and I2C5. The panel is therefore never powered and NACKs at
address `0x38` with `-ENXIO`. drphilth's `inject-touchscreen-power.py` adds the
missing power resource.

### One reported "third regional variant" that is not one

denis-bb issue #8: an FMB-P bought in Russia, BIOS 1.13, on which **both**
published tables leave `Could not resolve symbol [\_SB.PC00.I2C3.TPD0]` and no
touchpad. The owner reasonably suspected a third regional firmware and attached
a full `acpidump` from their machine.

That dump is byte-identical to denis-bb's patched **chinese** table
(`7830156903fc1f43fc42d3463ec41153`, OEM revision 0xa, 522,743 bytes). They
dumped while the override was loaded, so `acpidump` handed back the patched
table rather than their firmware's own — the trap
[`dump/README.md`](../../dump/README.md#a-warning-about-acpidump) describes. The
third-variant hypothesis is therefore untested, not disproved, and settling it
needs one boot without the override.

Their `AE_NOT_FOUND` on `\_SB.PC00.I2C3.TPD0` is a separate thing and is
harmless on its own: it is a dangling reference to a device slot the SKU does
not populate, and every machine in this family prints it.

## Phantom keys: two sources, not one

This matters because [`patch/micmute/`](../../patch/micmute/) addresses only the
first of them.

1. **The touchscreen.** `FTSC1000:00 2808:5662 UNKNOWN` emits `KEY_MICMUTE` at
   roughly 30 per second, flickering the mic overlay and breaking Fn+F7 —
   exactly the reference machine's symptom, and exactly what `patch/micmute/`
   fixes (colorcube #5).
2. **The touchpad.** The Goodix `27c6:01e0` fitted to *some* FMB-P units
   exposes vendor collections `FF00:0001` and `FF01:0001`, driverless under
   Windows, which `hid-input` maps anyway into a phantom `UNKNOWN` input device
   (colorcube #3, and kernel bugzilla 220741).

The second is the mirror image of the problem
[`patch/touchpad-edge/`](../../patch/touchpad-edge/) solves on ZQC-P: there the
vendor collection carries a gesture worth translating, here it carries noise
worth suppressing. Same vendor, same collection numbers, opposite conclusion —
which is why `touchpad-edge` is not listed for this model.

Note that the ten probes show `347d:7853` and no touchscreen at all. Both the
FocalTech touchscreen and the Goodix touchpad are reported by real owners, so
this model evidently ships in more than one configuration. `micmute` is tier A
and binds to one HID id: on a unit without that touchscreen it finds nothing
and does nothing, which is why it stays listed.

## Fans

tsukasagenesis found the tachometers by diffing EC RAM at idle against load
and reports fan1 2291 RPM / fan2 1989 RPM — within a few percent of the
reference machine's idle figures. Same offsets, `0x2c` and `0x2e`, 16-bit
little-endian. nikube notes the fans read 0 at idle because they genuinely are
off, matching the observation here that they do not engage until roughly 72 °C.

## The battery presets, and an unresolved disagreement

The profile records `40-70 70-90 95-100`, and two credible hardware-backed
accounts conflict about whether that is the whole story:

* **tsukasagenesis** (global unit, BIOS 1.16) enumerated pairs by writing each
  one and reading EC `0x85`, and reports that only `40/70`, `70/90` and
  `95/100` arm — modes 1, 2 and 3 — while `60/80`, `50/80`, `40/80`, `75/80`,
  `70/80`, `60/90`, `40/90` and `45/70` are stored and ignored. This matches
  what was measured here on ZQC-P.
* **yhshzh** reports arbitrary pairs working on their unit.

Not resolved. The conservative reading, and the one the profile encodes, is
that the three presets are the ones you can rely on.

## Firmware limits that are not Linux bugs

Recorded because they are otherwise reported as regressions (colorcube #8, #18,
PR #21):

* **No S3.** `\_S3` exists in the DSDT but is gated behind `Name (SS3, Zero)`,
  which firmware never sets. Forcing `SS3 = One` registers S3 and then
  hard-freezes the machine on entry. Arrow Lake H is S0ix-only and Windows has
  no S3 here either. Hibernate works.
* **No IR camera.** Not fitted.
* **The power button ignores short presses**, by design.

## Two things drphilth built that nothing here has

[drphilth/honor-magicbook-pro-14-ubuntu](https://github.com/drphilth/honor-magicbook-pro-14-ubuntu)
packages this machine for Ubuntu, and two of its pieces are worth naming
because they close gaps this repository still has.

**`honor-fmbp-kbdlight`**, a GPL `leds-class` driver for the keyboard backlight.
It writes EC RAM field `KBBL` at offset `0x41` directly, because the firmware's
WMI keyboard-light methods are no-ops on that model, and it maps

```
0x04 = off   0x02 = low   0x03 = high   0x01 = latch the level (no timeout)
```

That mapping is **exactly** what the reference machine's DSDT does in `\SKBM`
and `\GKBM`, read independently out of
[`dump/win11/zqc-p/OEM/DSDT.dsl`](../../dump/win11/zqc-p/OEM/DSDT.dsl). Two
models, same interface, one of them with a working driver already written. See
[the ZQC-P page](zqc-p.md#the-keyboard-backlight-is-reachable).

**`honor-fmbp-hwmon`**, the fan tachometer module this repository's
[`patch/fan/`](../../patch/fan/) was ported from.

One thing in that repository looks like it does not work.
`61-honor-fmbp-keyboard.hwdb` maps `KEYBOARD_KEY_e078=unknown`. udev applies
hwdb keyboard entries through the legacy `EVIOCSKEYCODE`, where the scancode is
an index into atkbd's 512-entry keymap, and atkbd in translated set 2 folds the
`e0` prefix into the high bit — so the index is `0xf8`, and `0xe078` is 57464,
out of range and rejected. Verified here on ZQC-P through the same ioctl:
`e078` rejected, `f8` accepted, and the property still shows up in
`udevadm info` either way, which is what makes it look like it works. Not
tested on an FMB-P, so this is a thing to check rather than a claim. Their rule
also matches every `svnHONOR*` machine rather than one model.

## Upstream

* The `atkbd` quirk is in since **6.19**, commit
  [`2aaf33c6e1e8`](https://github.com/torvalds/linux/commit/2aaf33c6e1e82561d7dce2345298a985a2483266),
  written against `DMI: HONOR FMB-P/FMB-P-PCB, BIOS 1.13 05/08/2025`. The Caps
  Lock LED works from that kernel on without `i8042.dumbkbd=1`.
* The touchpad `347d:7853` has needed nothing since **6.7**: commit
  [`9ffccb691adb`](https://github.com/torvalds/linux/commit/9ffccb691adb854e7b7f3ee57fbbda12ff70533f)
  matches it in `hid-multitouch` as `MT_CLS_VTL`, added for a different HONOR
  laptop. There is no libinput work to do either.
* The audio subsystem id `1ee7:2066` has **no** quirk in `alc269.c`. Nobody has
  reported the headset microphone broken on this machine, so `headset-mic` is
  not listed — but if somebody does, the id is now on record.

## Not established

`backlight_max` — no probe collects `/sys/class/backlight`, and no project
records it. The backlight floor — has to be measured on the panel with
[`patch/oled-backlight/measure-floor.sh`](../../patch/oled-backlight/measure-floor.sh);
the reference machine's `12` is a Panther Lake figure and must not be copied
here.
