# BCC-N — MagicBook 14 2026

| | |
|---|---|
| Product code | `BCC-N`, board `BCC-N-PCB`, board version `M1070`, SKU `C233` |
| Platform | Intel **Panther Lake** — Core Ultra X7 358H |
| Profile | [`devices/bcc-n.conf`](../../devices/bcc-n.conf) — **probed** |
| Read from | one hardware probe, [c33ebd2b1c](https://linux-hardware.org/?probe=c33ebd2b1c), and a full `dmidecode` and `dmesg` from a second owner |

The nearest sibling to the reference machine: the only other Panther Lake HONOR
laptop anybody has published a Linux probe of. Same silicon generation, same
iGPU family, same audio driver.

**It does not work out of the box.** This page said it did until 2026-08-22, on
the strength of that one probe. A second owner's `dmesg`
([lcrhf1999](https://github.com/lcrhf1999/HONOR-Magicbook-14-2026-dmesg), issue
[#2](../../../../issues/2) here) shows the same `I2C_DEVT` table-load failure as
every other 2026 machine, and no touchpad at all. Re-reading the probe's own
`dmesg` explains the contradiction: that owner is **already running an
override**. See [below](#it-does-need-the-acpi-fix-after-all).

Other models: [index](README.md).

## What the probe shows

Fedora 44, kernel 7.1.5-200.fc44, Secure Boot **on**, BIOS 1.04 (04/07/2026).
ACPI OEM table id `PTL`.

| | | Note |
|---|---|---|
| **CPU** | Core Ultra X7 358H | the reference machine is an X9 388H |
| **iGPU** | `8086:b080` "Panther Lake [Arc B390]", subsystem `1ee7:210b` | the same device id as ZQC-P |
| **NPU** | `8086:b03e` | |
| **Audio** | `8086:e428`, subsystem **`1ee7:210c`**, `snd_sof_pci_intel_ptl` | |
| **Touchpad** | **`36b6:c001`**, ACPI `CST3340`, on `i2c_designware.1` | a fourth distinct HONOR touchpad part. Binds `hid-multitouch` with no quirk and works |
| **Webcam** | **`3277:010d`**, rendered here as "Shinetech FHD Camera", `uvcvideo` | |
| **Fingerprint** | **`1c7a:05aa`** LighTuning "Egistec-ETU906Axx", status `failed` | |
| **Panel** | BOE `NE140B90-M00`, 2880x1800 16:10, 14.0", 60 Hz base with a 120 Hz DisplayID preferred mode, made week 28 of 2025 | |
| **Battery** | NVT `HB7075R5EHW-41T1`, 92.04 Wh — the same pack as FMB-P | the ACPI device is named **`LBAT`, not `BAT0`** |

The audio subsystem id sits one above the platform id — `210b` for the platform,
`210c` for the audio function — exactly as on FMB-P (`2065`/`2066`). The
reference ZQC-P's `1ee7:209d` does not follow that pattern relative to anything
probed, which is worth remembering before anybody tries to guess an
`audio_ssid`.

> **`LBAT`, not `BAT0`.** Anything hard-coding
> `/sys/class/power_supply/BAT0` breaks on this machine.
> [`patch/battery/honor-battery-threshold.sh`](../../patch/battery/honor-battery-threshold.sh)
> goes through `huawei-wmi`'s platform attribute rather than a battery path, so
> it is unaffected, but third-party scripts often are not.

## What it needs

Less than the other 2026 machines, but not nothing.

* **The keyboard needs nothing.** `BCC-N` has been in the upstream `atkbd`
  quirk table since **7.1** (commit `fb402386af4c`), so no `i8042.dumbkbd=1`
  and the Caps Lock LED works.
* **The touchpad needs an ACPI override**, like the rest of the 2026 line, and
  **a kernel of 7.1 or newer**. `36b6:c001` is `I2C_VENDOR_ID_BLTP` /
  `I2C_PRODUCT_ID_BLTP7853` in `drivers/hid/hid-ids.h`, and
  `i2c-hid-core.c` gives that pair `I2C_HID_QUIRK_NO_IRQ_AFTER_RESET` (commit
  `a991aa5e8936`, first in **v7.1**) because it does not signal reset completion
  and otherwise probes with `-61`. Both machines on record run 7.1 or later, so
  neither has hit it, but an older kernel on this laptop would give you a
  correctly loaded ACPI table and still no touchpad. The probe does log one
  `i2c_hid_acpi i2c-CST3340:00: i2c_hid_get_input: incomplete report (32/262)`,
  which is a single line at boot and not reported as a symptom.

  Do not confuse this part with the `347d:7853` on the 2024 and 2025 machines.
  Both answer to the ACPI/marketing name BLTP7853 and they are different
  silicon with different upstream quirks.
* **Charge thresholds are armed.** `upower` reports
  `charge-threshold-enabled: yes`, which is stronger than the
  `supported: yes` / `enabled` absent that DRB-P shows. Which pairs the EC
  actually honours is still unmeasured.

The profile therefore lists only what follows from the platform:
`cdclk-ptl` and `sof-audio` because it is Panther Lake, `fingerprint` because
`1c7a:05aa` has a recipe under
[`patch/fingerprint/`](../../patch/fingerprint/), and
`auto-rebuild` because both of those build things a package update would
revert.

`sof-audio` is tier B and will refuse on a `probed` profile, naming what is
missing. That is the intended behaviour, not an oversight.

## It does need the ACPI fix after all

Two BCC-N machines, both on BIOS 1.04, and they disagree until you read the
boot lines rather than the outcome.

**lcrhf1999**, Ubuntu, kernel 7.1.0-rc6, no override:

```
ACPI: SSDT 0x000000006FF51000 008B33 (v02 HONOR  I2C_DEVT 00001000 INTL 20200717)
ACPI Error: No pointer back to namespace node in package (20251212/dsargs-301)
ACPI Error: Aborting method \_SB.GINF due to previous error (AE_AML_INTERNAL)
ACPI Error: AE_AML_INTERNAL, (SSDT:I2C_DEVT) while loading table
ACPI Error: 1 table load failures, 32 successful
```

No `i2c_designware`, no `i2c_hid`, no touchpad input device anywhere in the log.
`intel-lpss` enables and nothing binds behind it. This is the family bug, on
this model, verbatim.

**The probe machine**, Fedora 44, kernel 7.1.5:

```
ACPI: Table Upgrade: override [SSDT- HONOR-I2C_DEVT]
ACPI: SSDT ... Physical table override, new table: 0x000000006735D000
ACPI: SSDT 0x000000006735D000 0087D1 (v02 HONOR  I2C_DEVT 00002000 INTL 20260408)
```

OEM revision `0x2000`, compiled 2026-04-08: that owner built their own corrected
table and loads it as an early CPIO. Their command line also carries
`i8042.dumbkbd=1`. So the "works out of the box" reading was an artefact of
measuring a machine that had already been fixed.

Incidentally that probe answers another question: it boots with **Secure Boot on
and the kernel locked down**, and the table upgrade still applied. See
[the note on lockdown](../LIMITATIONS.md).

**This model needs its own table.** BCC-N's stock `I2C_DEVT` is `0x8B33`
(35,635 bytes) against ZQC-P's `0x5C9C` (23,708), so unlike
[XWC-P](xwc-p.md#the-touchpad-failure-and-why-this-repositorys-fix-applies-here)
this is not the same table and the override carried here will be refused on it,
correctly. Rebuilding it is the same one-line change:
[docs/RESEARCH.md](../RESEARCH.md). Nobody has published a BCC-N table yet,
which makes a dump from one of these two owners the single most useful thing
this model needs.

## Confirmed twice

The DMI values on this page come from two independent sources that agree
exactly: linux-hardware probe c33ebd2b1c, and lcrhf1999's `dmidecode`. Product
`BCC-N`, version `M1070`, SKU `C233`, board `BCC-N-PCB` `M1070`, chassis SKU
`BingchuanC-7211`, BIOS `1.04` of 04/07/2026, Core Ultra X7 358H, NVT
`HB7075R5EHW-41T1` pack. lcrhf1999's unit has DMI OEM string 1
`$HUA001CN31000`, a China-market machine.

## What else is on the board

From the probe's `lspci`. Almost every id matches the reference ZQC-P, which is
the clearest evidence that the two share a platform.

| Slot | Device | PCI id | Subsystem |
|---|---|---|---|
| 00:00.0 | Host bridge | `8086:b001` | `1ee7:210b` |
| 00:02.0 | Panther Lake [Arc B390] | `8086:b080` | `1ee7:210b` |
| 00:04.0 | Dynamic Tuning | `8086:b01d` | `1ee7:210b` |
| 00:0a.0 | Platform Monitoring Telemetry | `8086:b07d` | `1ee7:210b` |
| 00:0b.0 | NPU | `8086:b03e` | `1ee7:210b` |
| 00:0d.0 | xHCI (TCSS) | `8086:e431` | `1ee7:210b` |
| 00:13.0 | Thunderbolt | `8086:e462` | `1ee7:210b` |
| 00:14.0 | xHCI | `8086:e47d` | |
| 00:14.3 | Wi-Fi (CNVi) | `8086:e440` | `8086:0094` |
| 00:14.7 | Bluetooth | `8086:e476` | `8086:0000` |
| 00:15.0/.1 | LPSS I²C | `8086:e478`/`e479` | `1ee7:210b` |
| 00:16.0 | CSE / ME | `8086:e470` | `1ee7:210b` |
| 00:1f.0 | eSPI / LPC | `8086:e402` | `1ee7:210b` |
| 00:1f.3 | HD Audio + SOF | `8086:e428` | **`1ee7:210c`** |
| 00:1f.4 | SMBus | `8086:e422` | `1ee7:210b` |
| 00:1f.5 | SPI (BIOS flash) | `8086:e423` | `1ee7:210b` |

Note the Wi-Fi subsystem is `8086:0094`, the same value the reference machine's
Windows dump names as an Intel AX211. The probed unit also has **two** NVMe
drives fitted, a Sandisk `15b7:501e` and a Samsung `144d:a80d`, which is that
owner's configuration rather than a platform fact.

## The Panther Lake cdclk regression applies here

[`patch/cdclk-ptl/`](../../patch/cdclk-ptl/) does apply. lcrhf1999's boot log
reads

```
xe 0000:00:02.0: [drm] Found pantherlake (device ID b080) integrated display
                       version 30.00 stepping B0
```

Display IP **30.00**, the same as the reference machine, which is exactly the
case `bxt_cdclk_ctl()` mishandles from 7.1.6 on. Nobody has said whether the
screen is visibly garbled during boot here, but the code path is the same one.

## Not established

`touchscreen_hid`, `panel` (the EDID carries no `Display Device Technology`
field and the BOE part number was not cross-checked against a specification),
`backlight_max`, and anything the tier B fixes would need.
