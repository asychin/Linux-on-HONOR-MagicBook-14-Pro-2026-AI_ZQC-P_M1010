# MRA-XXX — MagicBook Art 14 2024

| | |
|---|---|
| Product code | `MRA-XXX`, board `MRA-XXX-PCB`, board version `M1040`, SKU `C170` |
| Platform | Intel Meteor Lake — Core Ultra 7 155H |
| Profile | [`devices/mra-xxx.conf`](../../devices/mra-xxx.conf) — **probed** |
| Read from | linux-hardware probes [35a02e8c69](https://linux-hardware.org/?probe=35a02e8c69) and `5E9D307274A3` in the [linuxhw/DMI](https://github.com/linuxhw/DMI/tree/master/Notebook/HONOR/MRA-XXX) mirror |

A different line from the MagicBook Pro, and it is here for one reason: **it
carries the same FocalTech touchscreen as the reference machine**, so
[`patch/micmute/`](../../patch/micmute/) applies unchanged.

Nobody has run a single fix on one. Everything below is read off probes.

Other models: [index](README.md).

## Hardware

| | | Note |
|---|---|---|
| **CPU** | Core Ultra 7 155H | Meteor Lake, CPUID family 6 model 170 |
| **iGPU** | `8086:7d55`, subsystem `1ee7:2059`, `i915` | |
| **Audio** | `8086:7e28` Meteor Lake-P HD Audio, subsystem **`1ee7:2059`**, `sof-audio-pci-intel-mtl` | no `alc269` quirk upstream for this id |
| **Touchscreen** | **`2808:5662`**, ACPI `FTSC1000`, on `i2c_designware.0` | the same part as ZQC-P, FMB-P and MRB-XXX |
| **Touchpad** | **`35cc:0104`**, ACPI `TOPS0102` | matched upstream in `hid-multitouch` as `MT_CLS_VTL`, commit `7a5ab8071114` |
| **Fingerprint** | `10a5:a900` | no recipe here, and not in upstream `libfprint` |
| **Panel** | EDO `EDO14.55` OLED — the same panel FMB-P's EDID declares as Organic LED | |
| **Battery** | DESAY `AP16L5J`, 59.7 Wh | |
| **BIOS** | `3.01` (09/03/2024); `3.05` (03/07/2025) also seen | |
| **Runs on** | Ubuntu 24.04, kernel 6.8.0-49 | |

## Why `micmute` is listed

The fix binds to one HID id, `2808:5662`, and rewrites that device's report
descriptor so `hid-input` stops turning its vendor collection into a phantom
`KEY_MICMUTE`. It is tier A: on hardware without that touchscreen it matches
nothing and does nothing.

Whether this machine actually shows the symptom is **not** reported. The rule
this repository follows is that a recorded `touchscreen_hid=2808:5662` is enough
to list it, because the fix cannot misfire. If you have one and the microphone
does *not* mute itself, say so and it comes off the list.

## The libinput quirk that names this machine

`libinput` ships exactly one HONOR quirk, and it is for this model:

```
[HONOR MagicBook Art 14]
MatchName=*TOPS0102*
MatchDMIModalias=dmi:*:svnHONOR:pnMRA-XXX:*
MatchUdevType=touchpad
AttrEventCode=-BTN_RIGHT
AttrInputProp=+INPUT_PROP_PRESSUREPAD
```

It describes a clickpad that wrongly announces `BTN_RIGHT`. The `MatchName`
clause alone would also catch ZQC-P and XWC-P, which share the `TOPS0102` ACPI
name with entirely different silicon behind it; only the DMI clause keeps them
apart. See [the ZQC-P page](zqc-p.md#libinput-has-a-quirk-for-this-touchpad-gated-to-another-machine).

## Not established

`camera_usb`, `backlight_max`, `ec_fan0`, `ec_fan1`,
`battery_charge_presets`, every `param_*`, and whether the internal keyboard
needs anything. `MRA-XXX` is not in the upstream `atkbd` quirk table and the
probe shows no `i8042` parameter on the command line.

`panel=oled` is recorded from the panel part number, which FMB-P's EDID
independently declares as Organic LED. `param_backlight_min` still has to be
measured on the panel before [`patch/oled-backlight/`](../../patch/oled-backlight/)
could be offered, so it is not listed.
