# MRB-XXX — MagicBook Art 14 2025

| | |
|---|---|
| Product code | `MRB-XXX`, board `MRB-XXX-PCB`, board version `M1090`, SKU `C233` |
| Platform | Intel Arrow Lake H — Core Ultra 7 255H |
| Profile | [`devices/mrb-xxx.conf`](../../devices/mrb-xxx.conf) — **probed** |
| Read from | one linux-hardware probe, [69946861f1](https://linux-hardware.org/?probe=69946861f1) |

The 2025 successor to [MRA-XXX](mra-xxx.md), and here for the same reason: the
same FocalTech touchscreen, so [`patch/micmute/`](../../patch/micmute/) applies.

Other models: [index](README.md).

## Hardware

| | | Note |
|---|---|---|
| **CPU** | Core Ultra 7 255H | Arrow Lake H |
| **Audio** | `8086:7728`, subsystem **`1ee7:2081`** | **already upstream**: `SND_PCI_QUIRK(0x1ee7, 0x2081, "HONOR MRB-XXX M1020", ALC256_FIXUP_HONOR_MRB_XXX_M1020_AUDIO)`, commit `d9448dca4235`, in v7.1 |
| **Touchscreen** | **`2808:5662`**, ACPI `FTSC1000`, on `i2c_designware.0` | |
| **Touchpad** | **`35cc:0104`**, ACPI `TOPS0102` | upstream `hid-multitouch` quirk, commit `7a5ab8071114`. It also exposes a native Consumer Control node, which is the tidy version of what [`patch/touchpad-edge/`](../../patch/touchpad-edge/) has to reach with HID-BPF on the ZQC-P part |
| **Chassis SKU** | `MooreB-7261T` | |
| **BIOS** | `2.04` (05/30/2025) | |

Note the upstream audio quirk is labelled `M1020` while the probed board is
`M1090`. It keys on the PCI subsystem id, not the board revision, so it covers
both; the label is just the machine the submitter had. This is also the second
of only two HONOR entries in the kernel's `alc269.c`, and the pin table it
installs is the template to copy if a HONOR machine ever needs more than
`ALC2XX_FIXUP_HEADSET_MIC`.

## Not established

`fingerprint_usb`, `camera_usb`, `panel`, `backlight_max`, `ec_fan0`,
`ec_fan1`, `battery_charge_presets`, every `param_*`, and whether the keyboard
needs anything. One probe, no owner report.
