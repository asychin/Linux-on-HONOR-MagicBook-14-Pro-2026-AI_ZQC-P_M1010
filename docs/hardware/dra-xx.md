# DRA-XX — MagicBook Pro 16 2024, and HUNTER Edition

| | |
|---|---|
| Product code | **`DRA-XX`** — a literal string, not a placeholder. Board `DRA-XX-PCB` |
| Platform | Intel Meteor Lake — Core Ultra 5 125H or Ultra 7 155H |
| Profiles | [`devices/dra-xx.conf`](../../devices/dra-xx.conf) · [`devices/dra-xx-hunter.conf`](../../devices/dra-xx-hunter.conf) — both **probed** |
| Read from | four hardware probes: [988dd23028](https://linux-hardware.org/?probe=988dd23028), [633e9bb800](https://linux-hardware.org/?probe=633e9bb800), [a3e7d421d4](https://linux-hardware.org/?probe=a3e7d421d4) and one more |

Other models: [index](README.md).

## The product name is `DRA-XX`

Every 2024 MagicBook Pro 16 reports `Product Name: DRA-XX` and
`Base Board Product Name: DRA-XX-PCB`, whatever the marketing code on the box
was. `dmesg` prints `DMI: HONOR DRA-XX/DRA-XX-PCB`. HONOR wildcards the digits
in firmware.

Until 2026-08-22 this repository carried four profiles keyed on `DRA-54`,
`DRA-56` and `DRA-72`. Detection compares `dmi_product` exactly, so **none of
them could ever have matched a machine**. They are replaced by two profiles
separated on the one thing that does discriminate: the discrete GPU.

Nothing in DMI carries `54`, `56` or `72`, and no mapping from those codes to
anything the firmware reports was found. What DMI does carry is the board
revision:

| `board_version` | CPU | GPU | `product_sku` | BIOS |
|---|---|---|---|---|
| `M1020` | Core Ultra 5 125H | integrated only | `C170` | 1.14 (12/19/2024) |
| `M1030` | Core Ultra 5 125H | + RTX 4060 Max-Q | `C233` | 1.13 (11/29/2024) |
| `M1040` | Core Ultra 7 155H | + RTX 4060 Max-Q | — | 1.13 (11/29/2024) |

`M1020` is `dra-xx.conf`; `M1030` and `M1040` are `dra-xx-hunter.conf`. The
discrete GPU is `10de:28a0` "AD107M [GeForce RTX 4060 Max-Q]", subsystem
`1ee7:204d`. Discrete-GPU support is out of scope; these machines are in scope
for their integrated side.

## Hardware

Identical across all four probes unless noted.

| | | Note |
|---|---|---|
| **CPU** | Core Ultra 5 125H or Ultra 7 155H | CPUID family 6 model 170, Meteor Lake |
| **Audio** | `8086:7e28` "Meteor Lake-P HD Audio", subsystem **`1ee7:204d`**, ALC256 | the same on the UMA and the RTX machines, so one value covers the family. On an RTX machine, take the Intel device, not the GPU's HDA function |
| **Touchpad** | **`347d:7853`**, ACPI `BLTP7853`. Present and working on all four | |
| **Webcam** | **`3277:009f`** "SenseTek FHD Camera", `uvcvideo` | same as DRB-P |
| **Fingerprint** | **`27c6:5f10`** (Goodix) on boards M1020 and M1030; **`10a5:a921`** (FPC) on M1040. Both status `failed` | |
| **Panel** | TMA `TL160MDMP01`, 3072x1920, 345x215 mm, 16.0" | the same part as DRB-P and XWC-P |
| **Battery** | SUNWODA `AP16L5J`, 74.382 Wh | same pack as DRB-P |

`panel=lcd` is recorded from the part number, not from the EDID: this panel
declares no `Display Device Technology` field. `TL160MDMP01` is the 16" IPS LCD
HONOR advertises across the Pro 16 line.

## What works without any of this repository's fixes

* **No `AE_AML_INTERNAL`.** DRA-XX does not have the table-load failure that
  breaks the touchpad on the 2025 and 2026 machines, and its touchpad works out
  of the box.
* **The touchpad needs no quirk.** `347d:7853` has been in `hid-multitouch` as
  `MT_CLS_VTL` since v6.7, commit
  [`9ffccb691adb`](https://github.com/torvalds/linux/commit/9ffccb691adb854e7b7f3ee57fbbda12ff70533f).
* **Wi-Fi power tables** are already covered by `iwlwifi`'s vendor-wide HONOR
  entries.

That is why both profiles list **no fixes at all**. This is a good outcome, not
a gap: it means a 2024 MagicBook Pro 16 needs nothing from here, and the
profiles exist so that detection recognises the machine and says so rather than
refusing with "unknown model".

## The fingerprint readers have no recipe

Neither `27c6:5f10` nor `10a5:a921` is the id
[`patch/fingerprint/`](../../patch/fingerprint/) handles. `27c6:5f10` is a
Goodix device but **not** the `27c6:6f94` the `goodixmoc` id-table patch adds,
so that patch will not cover it; `10a5:a921` is a different FPC part from the
`10a5:9924` in the FMB-P recipe. Both report `failed` in the probes, meaning no
driver claims them.

Adding either is the same shape of work as the recipes already under
[`patch/fingerprint/sensors/`](../../patch/fingerprint/sensors/) — an id-table
entry and an enrolment-stage count — but it needs somebody with the hardware to
confirm the sensor actually enrols, not just that it opens.

## Not established

`touchscreen_hid`, `backlight_max`, `ec_fan0`, `ec_fan1`,
`battery_charge_presets`, every `param_*`, and whether the internal keyboard
needs anything. `DRA-XX` is not in the upstream `atkbd` quirk table and none of
the four probes shows an `i8042` parameter on the kernel command line.

None of that is obtainable from a hardware probe. One run each of
[`tools/collect-hwinfo.sh`](../../tools/collect-hwinfo.sh) and
[`tools/dump-acpi.sh`](../../tools/dump-acpi.sh) covers all of it.
