# FMB-PM — MagicBook Pro 14 2025 Geek Edition

| | |
|---|---|
| Product code | `FMB-PM`, board `FMB-PM-PCB`, board version `M1030` |
| Platform | Intel **Meteor Lake** — Core Ultra 5 125H |
| Profile | [`devices/fmb-pm.conf`](../../devices/fmb-pm.conf) — **reported** |
| Read from | one machine, [sledeil](https://github.com/sledeil/honor-fmb-pm-linux-touchpad-fix) |

`FMB-PM` is 荣耀 MagicBook Pro 14 2025 极客版, the Geek Edition — a China-market
configuration of the same product as [FMB-P](fmb-p.md), which is why HONOR ships
one BIOS installer for both and why the two DSDTs share a defect down to the
literal argument.

Exactly one person has published anything about running Linux on it. There is
no hardware probe of an FMB-PM anywhere, so most of the profile is `unknown` and
honestly so.

Other models: [index](README.md).

## The platform is Meteor Lake, not Arrow Lake

An earlier draft of this profile inferred Arrow Lake from the marketing year
2025 and was wrong. Two firmware-level confirmations, not just the CPU
marketing name:

* the FMB-PM DSDT's OEM Table ID is literally `MTL`, where every FMB-P DSDT
  (denis-bb global, denis-bb Chinese, astenir BIOS 1.16) carries `ARL`;
* the CPU is a Core Ultra 5 125H, CPUID family 6 model 170.

This is why `platform` is a recorded fact in the profile rather than something
derived from `year`.

## What is known

| | | Source |
|---|---|---|
| **Touchpad** | `347d:7853`, ACPI `BLTP7853` | sledeil, read off the machine |
| **Panel** | OLED, 14.6" 3120x2080, 60/120 Hz, on both published Geek Edition SKUs. The same panel FMB-P's EDID identifies as `EDO14.55` and declares as Organic LED | published specification, corroborated by the FMB-P EDID |
| **BIOS** | `2.07`, dated 2026-04-27 | sledeil |
| **Runs on** | Fedora 44, kernel 7.1.4-202.fc44 | sledeil |
| **Battery** | 92 Wh, 4-cell — the same pack FMB-P probes report | published specification |

sledeil reports the touchpad as the only user-visible breakage, and does not
report problems with audio, Wi-Fi, camera, suspend or battery. That is one
person's experience of one machine, not a support matrix.

### The touchpad is selected by firmware at runtime

Worth knowing before anybody keys a fix on `touchpad_hid` here. The DSDT's
`\_SB.PC00.I2C1.TPD0` switches its own `_HID` on an EC-provided variable `TPDT`:

```
If ((TPDT == One))    { _HID = "GXT7863"; HID2 = One; BADR = 0x5D }
If ((TPDT == 0x02))   { _HID = "BLTP7853"; HID2 = One; BADR = 0x2C }
```

`_STA` returns `0x0F` either way. So this model ships with at least two
different touchpads and the firmware picks at boot. `347d:7853` is confirmed on
sledeil's unit; a second variant reporting a Goodix id is likely and should be
probed for rather than assumed. The profile records the one value that was
actually read.

### `BLTP7853` names two different parts

A trap, and one this repository nearly fell into. `drivers/hid/hid-ids.h`
defines `I2C_VENDOR_ID_BLTP 0x36b6` and `I2C_PRODUCT_ID_BLTP7853 0xc001`, and
`i2c-hid-core.c` gives that pair `I2C_HID_QUIRK_NO_IRQ_AFTER_RESET` (commit
`a991aa5e8936`, first in v7.1) for a pad that fails to signal reset completion
and probes with `-61`.

That is **`36b6:c001`, not `347d:7853`.** Two different silicon parts behind one
ACPI name string. Never key anything on the ACPI `_HID`.

The part this machine actually reports, `347d:7853`, has had an upstream
`hid-multitouch` quirk since **v6.7** — commit
[`9ffccb691adb`](https://github.com/torvalds/linux/commit/9ffccb691adb854e7b7f3ee57fbbda12ff70533f),
`MT_CLS_VTL`, whose comment calls it a "HONOR GLO-GXXX panel". `MT_CLS_VTL`
carries `MT_QUIRK_FORCE_GET_FEATURE`, which is what stops the pad coming up in
mouse mode. Nothing to do here.

## The ACPI table failure

Present, and identical to FMB-P down to the literal GPIO argument. Both DSDTs
contain, on `\_SB.PC00.I2C1`:

```
Device (NFC0) { Name (_HID, "NTAG0001") ...
    CreateWordField (SBGF, 0x17, INT1)
    INT1 = GNUM (0x0014080A) }
```

at device-body scope, so it runs at table load. The consequence sledeil reports
verbatim: `intel-lpss 0000:00:15.0` and `.1` log `can't derive routing for PCI
INT A/B`, then `probe with driver intel-lpss failed`, and the touchpad does not
exist at all.

sledeil's fix is a hand-built DSDT override prepended to the dracut initramfs as
an uncompressed early CPIO. There is no distro packaging for FMB-PM.

`acpi-override` is not listed in the profile: that fix ships one machine's
firmware image, and an FMB-PM needs its own.

## The keyboard needs nothing

`FMB-PM` inherits the upstream `atkbd` quirk for free. `dmi_matches()` in
`drivers/firmware/dmi_scan.c` uses `strstr()` unless `.exact_match` is set, the
HONOR entries do not set it, and `FMB-P` is a prefix of `FMB-PM`. So commit
[`2aaf33c6e1e8`](https://github.com/torvalds/linux/commit/2aaf33c6e1e82561d7dce2345298a985a2483266)
covers this machine from **6.19** on, without anybody having asked for it.

## Disagreements left open

* **BIOS version.** sledeil read `2.07` off the machine and astenir
  independently warns about "BIOS 2.xx" as an FMB-PM thing. A commenter on
  colorcube #22 says HONOR's June 2026 download, named `FermatB-5611-BIOS
  20260509`, is "the same 1.16 version". Both cannot be right and nothing here
  settles it.
* **CPU.** Published specifications and sledeil's machine agree on Core Ultra 5
  125H. A single AliExpress listing pairs the string `FMB-PM` with a Core Ultra
  5 225H, which would make it Arrow Lake. Treated as a listing error.

## Not established

`touchscreen_hid`, `audio_ssid`, `fingerprint_usb`, `camera_usb`,
`backlight_max`, and anything the tier B fixes would need.

Some of these have a plausible answer that is deliberately **not** written into
the profile:

| Field | The plausible answer, and why it is not recorded |
|---|---|
| `touchscreen_hid` | both published Geek Edition configurations give 1.37 kg, which Chinese reviews call the non-touch weight, and neither spec sheet lists touch. Probably no touchscreen, but "probably absent" is not `none` |
| `fingerprint_usb` | a reader is fitted. China-market machines across this family carry the LighTuning `1c7a:05aa`. Inference, not a reading |
| `camera_usb` | vendor `0x3277` is this family's camera supplier without exception. The product half is genuinely unknown, and the installer acts on the whole id |
| `ec_fan0` / `ec_fan1` in `patch/fan/fmb-pm/<board>/` | ZQC-P and FMB-P both use `0x2c` and `0x2e`. A different EC generation is exactly the case where guessing an offset writes to the wrong register |
| `presets` in `patch/battery/fmb-pm/<board>/` | `40-70 70-90 95-100` on both neighbours. Needs the write-and-read-EC-`0x85` test from [TESTING.md](../TESTING.md#4-the-battery-limit) |
| `backlight_max` | must **not** be copied from ZQC-P's `704`, which is a Panther Lake figure from a different BIOS-programmed PWM period. One line of sysfs settles it |

The machine's DSDT is already on sledeil's disk, so the two offsets are
minutes of work for somebody who has it.
