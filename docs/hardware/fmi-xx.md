# FMI-XX — MagicBook X14 Plus 2024

| | |
|---|---|
| Product code | `FMI-XX` |
| Product code | `FMI-XX`, board `FMI-XX-PCB`, board version `M1040`, SKU `C233` |
| Platform | **AMD** — Ryzen 7 8845HS with Radeon 780M |
| Profile | [`devices/fmi-xx.conf`](../../devices/fmi-xx.conf) — **probed** |
| Read from | linux-hardware probe [8b414319e5](https://linux-hardware.org/?probe=8b414319e5), the upstream hwmon patch, and a Fedora Discussion report |

The only AMD machine on the [index](README.md). It is listed for one specific
reason, and the reason is worth more than the hardware: **it is the model the
upstream fan driver was written for, and the reference ZQC-P implements the
identical firmware method.**

Other models: [index](README.md).

## Why this machine matters to a MagicBook Pro

[Patch 14751797](https://patchwork.kernel.org/project/linux-hwmon/patch/20260815234041.2262291-1-testname142@gmail.com/),
"hwmon: Add fan monitoring support for HONOR FMI-XX" by Nikita Dubrovskih, was
accepted on `linux-hwmon` on 2026-08-15. It is read-only, calls
`acpi_get_handle(NULL, "\\GFNS")`, sends a three-byte buffer with the fan index
at offset 2, and reads back a status byte and a little-endian 16-bit RPM.

That is byte for byte the contract of `Method (GFNS, 1, Serialized)` in the
ZQC-P DSDT, which returns `FA0L`/`FA0R` for fan 0 and `FA1L`/`FA1R` for fan 1
([`dump/win11/zqc-p/OEM/DSDT.dsl`](../../dump/win11/zqc-p/OEM/DSDT.dsl)). The
submitter's own notes — firmware 1.09, channel 0 at roughly 2500-2800 RPM,
channel 1 readable and sitting at 0 through idle and a short load — describe the
same behaviour measured on the reference machine.

So the fan interface is shared across HONOR EC generations regardless of CPU
vendor, and adding ZQC-P to that driver is one table entry rather than a new
module. The diff is in [`patch/fan/README.md`](../../patch/fan/README.md).

## Hardware

| | | Note |
|---|---|---|
| **CPU** | AMD Ryzen 7 8845HS, 8 cores, Zen | the only non-Intel machine here |
| **iGPU** | `1002:1900` Radeon 780M, subsystem `1ee7:2053` | |
| **Audio** | two devices, both subsystem **`1ee7:2053`**: `1022:15e3` (the analog path) and `1002:1640` (the GPU's HDMI audio) | "HD-Audio Generic" in the input list, so not the ALC256 the Intel machines use |
| **Wi-Fi** | `17cb:1103`, **Qualcomm** | not `iwlwifi`, so the vendor-wide HONOR regulatory entries do not apply here |
| **Bluetooth** | `0489:e0e1` | |
| **Touchpad** | **`347d:7853`**, ACPI `BLTP7853` | the same part as FMB-P, FMB-PM, DRA-XX, DRB-P, FRB-X and GLO-GXXX. Upstream `hid-multitouch` quirk since v6.7 |
| **Camera** | **`3277:0045`** | the same module as FRB-X, and vendor `0x3277` again |
| **Fingerprint** | **`10a5:a921`** (FPC) | the same reader as a DRA-XX board M1040. No recipe here, not in upstream `libfprint` |
| **Chassis SKU** | `FermiI-7211` | |
| **BIOS** | `1.06` (07/12/2024) on the probe; the hwmon patch was validated on `1.09` | |
| **`huawei-wmi`** | binds, and brings up "Huawei WMI hotkeys" | so the WMI hotkey path is the same as on the Intel machines |

So the family's patterns hold on the AMD side more than they break: same
touchpad, same camera vendor, same fingerprint supplier, same WMI hotkey
driver, same fan method. What differs is the silicon underneath and the Wi-Fi.

`platform=amd` is deliberately coarse. Nothing in this repository keys on an AMD
generation, so splitting Phoenix from Hawk Point would be precision this profile
has not earned.

## What it needs

Nothing from here, and that is why `fixes` is empty. The profile exists so that
detection recognises the machine and says so.

Not established: `touchscreen_hid`, `panel`, `backlight_max`, and anything the tier B fixes would need. Whether this EC uses
the same charge presets and the same tachometer offsets as the Intel machines is
a genuinely open question, and one run of
[`tools/collect-hwinfo.sh`](../../tools/collect-hwinfo.sh) would answer it.

One Fedora 43 report exists about slow wake from sleep and an NVMe reset on this
machine, since resolved, and unrelated to anything here.
