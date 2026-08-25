# FRB-X — MagicBook X14 Plus 2025

| | |
|---|---|
| Product code | `FRB-X`, board `FRB-X-PCB`, board version `M1050` |
| Platform | Intel Raptor Lake — Core 5 220H |
| Profile | [`devices/frb-x.conf`](../../devices/frb-x.conf) — **probed** |
| Read from | one linux-hardware probe, [e706235ea5](https://linux-hardware.org/?probe=e706235ea5) |

The X series, not the Pro line. It is here because **nothing in this repository
applies to it**, and knowing that is worth a page: an owner running
`apply_patch.sh` gets "recognised, nothing to install" instead of "unknown
model, refusing".

Other models: [index](README.md).

## Hardware

| | | Note |
|---|---|---|
| **CPU** | Intel Core 5 220H | Raptor Lake refresh |
| **Audio** | `8086:51ca` Raptor Lake-P/U/H cAVS, subsystem **`1ee7:2074`** | no `alc269` quirk upstream |
| **Touchpad** | **`347d:7853`**, ACPI `BLTP7853` | upstream `hid-multitouch` `MT_CLS_VTL` since v6.7, commit `9ffccb691adb`. Nothing to do |
| **Camera** | **`3277:0045`** "ShineOptics HD Camera" | the same vendor as every machine in this family |
| **Fingerprint** | `27c6:5f91` (Goodix) | no recipe here, not in upstream `libfprint` |
| **Panel** | CSW `CSW143B`, 2880x1800, 14.0", 120 Hz | |
| **Battery** | DESAY `AP16L5J`, 59.4 Wh | |
| **BIOS** | `1.02` (02/14/2025) | |

## Why the fix list is empty

* **No ACPI table failure.** This is not a 2025/2026 Pro machine; there is no
  `I2C_DEVT` or NFC0 load-time call to work around.
* **The touchpad needs nothing**, as above.
* **Wi-Fi** is covered by `iwlwifi`'s vendor-wide HONOR entries.
* **The fingerprint reader has no recipe** anywhere, so listing `fingerprint`
  would patch the wrong id into the wrong driver.
* **`micmute` does not apply**: no FocalTech touchscreen was probed.

That is the honest state, not a gap waiting to be filled. If something on your
X14 Plus is broken under Linux, it is not one of the things this repository
already knows about, and an issue would be genuinely new information.

## Not established

Everything except the row above: `touchscreen_hid`, `backlight_max`,
`dmi_sku`, and anything the tier B fixes would need, and whether the
keyboard needs an `i8042` parameter. `FRB-X` is not in the upstream `atkbd`
quirk table.
