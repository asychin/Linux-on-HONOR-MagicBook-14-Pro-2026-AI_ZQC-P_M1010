# DRB-P — MagicBook Pro 16 2025, and HUNTER Edition

| | |
|---|---|
| Product code | `DRB-P`, board `DRB-P-PCB` |
| Platform | Intel Arrow Lake H — Core Ultra 9 285H or Ultra 5 225H |
| Profiles | [`devices/drb-p-hunter.conf`](../../devices/drb-p-hunter.conf) — **probed** · [`devices/drb-p.conf`](../../devices/drb-p.conf) — **draft** |
| Read from | one hardware probe, [69db9d1ea1](https://linux-hardware.org/?probe=69db9d1ea1), plus two libfprint issues |

Three configurations are sold under this one product code: the HUNTER Edition
with an RTX 5070 or 5060, and two UMA machines with an Ultra 9 285H or an
Ultra 5 225H. They report the same `product_name`, so detection also looks for
a discrete GPU. Discrete-GPU support is out of scope; these machines are in
scope for their integrated side.

**Every value on this page was measured on the HUNTER variant.** The one Linux
probe in existence is an RTX 5060 machine. The chassis, panel, touchpad, camera
and reader are very likely shared with the UMA models, but "very likely" is not
a reading, so `drb-p.conf` stays almost entirely `unknown`.

Other models: [index](README.md).

## Yes, people run Linux on it

Three, on three distributions:

* Arch, kernel 6.19.6, Hyprland on Wayland, PipeWire, btrfs root — a real
  daily-driver install ([probe 69db9d1ea1](https://linux-hardware.org/?probe=69db9d1ea1), 2026-03-14)
* Ubuntu 25.10 with GNOME ([libfprint #737](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/737))
* Fedora 43 Silverblue, kernel 6.17.7 ([libfprint #776](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/776))

## Hardware, as read off the HUNTER unit

| | | Note |
|---|---|---|
| **CPU** | Core Ultra 9 285H, Arrow Lake H | iGPU `8086:7d51` Arc Pro 130T/140T |
| **Audio** | `8086:7728` "Arrow Lake cAVS", subsystem **`1ee7:207a`** | see the warning below |
| **Touchpad** | **`347d:7853`**, ACPI `BLTP7853`, on `i2c_designware.1`. Works | |
| **Webcam** | **`3277:009f`** "SenseTek FHD Camera", `uvcvideo` | same as DRA-XX |
| **Fingerprint** | **`1c7a:05aa`** LighTuning "Egistec-ETU906Axx", status `failed` | |
| **Panel** | TMA `TL160MDMP01`, 3072x1920 16:10, 165 Hz adaptive-sync, 10 bpc, 16.0" | the same part XWC-P and DRA-XX carry |
| **Battery** | SUNWODA `AP16L5J`, 74.382 Wh | same pack as DRA-XX |
| **Board** | `DRB-P-PCB` version `M1020`, SKU `C170`, chassis SKU `DarwinB-9218` | |
| **BIOS** | `2.07` (04/22/2025), EC firmware 2.7. A `3.04` exists, seen in an August 2026 Windows benchmark submission | |

> **Reading `audio_ssid` on a HUNTER machine.** This laptop has **two** PCI
> devices in class 04: the Intel controller `8086:7728` (class 04-01-00) and the
> discrete GPU's own HDA controller `10de:22eb` (class 04-03-00, subsystem
> `10de:0000`). An `alc269` quirk keys on the Intel one. Anything that takes
> "the first PCI device of class 0401 or 0403" picks the wrong device here.

The panel EDID declares SMPTE ST2084 HDR and a 60–165 Hz adaptive-sync range,
but carries **no** `Display Device Technology` field, so it does not say whether
it is OLED. `panel=lcd` is recorded on the strength of the part number:
`TL160MDMP01` is the 16" IPS LCD HONOR advertises across the Pro 16 line. If
that is ever contradicted, the consequence is only that
[`patch/oled-backlight/`](../../patch/oled-backlight/) is not offered here.

## What works without any of this repository's fixes

The probe is a stock Arch install with no kernel parameters and no ACPI
override, and it boots with a working touchpad.

* **No `AE_AML_INTERNAL`.** DRB-P does not have the table-load failure that
  breaks the touchpad on ZQC-P, XWC-P, FMB-P and FMB-PM. The only ACPI
  complaint in its `dmesg` is the family-wide, harmless
  `AE_NOT_FOUND, \_SB.PC00.I2C3.TPD0`.
* **The touchpad needs nothing.** `347d:7853` has been matched in
  `hid-multitouch` as `MT_CLS_VTL` since v6.7, commit
  [`9ffccb691adb`](https://github.com/torvalds/linux/commit/9ffccb691adb854e7b7f3ee57fbbda12ff70533f),
  which is why `hid-generic` hands it over two tenths of a second into boot.
  There is no libinput quirk to add either.
* **Audio works.** SOF on the Arrow Lake path, ALC256, two DMICs, firmware
  `intel/sof-ipc4/arl/sof-arl.ri`, machine driver `skl_hda_dsp_generic`.
* **`huawei-wmi` binds**, brings up `Huawei WMI hotkeys` as an input device and
  registers the `Huawei Battery Extension` ACPI hook. It also emits the
  family-wide `[Firmware Bug]: WQ00 data block query control method not found`,
  which is cosmetic.
* **No S3**, as everywhere else in this family.

## Open questions

**The keyboard.** `DRB-P` is not in the upstream `atkbd` quirk table, and
whether it needs to be is unresolved. The probe boots with no `i8042`
parameter and the machine is plainly usable, which suggests it does not — but a
probe cannot show whether the internal keyboard produced events, so this needs
one owner to say.

**The battery limit.** `upower` 1.91.1 reports `charge-start-threshold: 75%`,
`charge-end-threshold: 80%`, `charge-threshold-supported: yes` — while the pack
sits at 99.5% with status `Not charging`. `inxi`, run on the same machine in the
same probe, reports `start: 0% end: 100%`. The straightforward reading is the
one this repository has already demonstrated on ZQC-P: the EC stored `75 80`
and did not arm it. No board here gets a `presets` line until somebody runs
the two commands in [TESTING.md](../TESTING.md#4-the-battery-limit).

**A second BIOS line.** `2.07` from the probe, `3.04` from a Windows benchmark
submission dated 2026-08-10 whose motherboard string reads `HONOR DRB-P-PCB
BIOS 3.04`. HONOR's own download pages render client-side and could not be read.

## The fingerprint reader

`1c7a:05aa` is the same EgisTec part as the Chinese-market ZQC-P, and this
repository already carries a recipe for it at
[`patch/fingerprint/zqc-p/M1050/`](../../patch/fingerprint/zqc-p/M1050/),
which is why `fingerprint` is the one fix listed for the HUNTER profile.

Upstream `libfprint` has two reports of exactly this device on exactly this
laptop — [#737](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/737)
(closed 2026-07-02) and [#776](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/776)
(still open) — and the id is still not in `egismoc.c`, whose table ends at
`0x05a1`. The SDCP work it depends on is
[MR 547](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/547),
open since October 2025 and currently unmergeable. So this needs a local patch
on every distribution, indefinitely.

Note the region assumption this breaks. It was recorded here that global units
carry Goodix or FPC readers and Chinese ones the EgisTec part. This machine's
DMI OEM string is `$HUA001RU31030` — a Russian-market unit — and it has the
EgisTec. The reporters in libfprint #737 (Ubuntu) and #776 (Fedora) are not
Chinese either. The rule does not hold; the profile lists what was read.

## Not established, on either profile

`touchscreen_hid`, `backlight_max`, and anything the tier B fixes would need.

A hardware probe cannot fill the last four: `hw-probe` does not collect
`/sys/class/backlight` at all, and the fan tachometer offsets come from the
machine's own DSDT. [`tools/dump-acpi.sh`](../../tools/dump-acpi.sh) and
[`tools/collect-hwinfo.sh`](../../tools/collect-hwinfo.sh) do collect them.

For `drb-p.conf`, the UMA profile, add to that list everything on this page.
One probe from a non-HUNTER machine would settle whether the two share a
chassis, and that is the single most useful thing an owner of one could do.
