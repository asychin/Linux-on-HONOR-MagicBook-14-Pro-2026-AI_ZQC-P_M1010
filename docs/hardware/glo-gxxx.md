# GLO-GXXX — MagicBook 14 2023

| | |
|---|---|
| Product code | **`GLO-GXXX`**, a wildcarded string. Board `GLO-GXXX-PCB`, version `M1010`, SKU `C170` |
| Platform | Intel Raptor Lake — 13th Gen Core i5-13500H |
| Profile | [`devices/glo-gxxx.conf`](../../devices/glo-gxxx.conf) — **probed** |
| Read from | two different machines in the `linuxhw` mirrors: DMI from [`79EA85B67EC3`](https://github.com/linuxhw/DMI/tree/master/Notebook/HONOR/GLO-GXXX), PCI from [`2F2B243F6D7B`](https://github.com/linuxhw/LsPCI/tree/master/Notebook/HONOR/GLO-GXXX) |

The oldest machine this repository recognises, and the second clear case of
HONOR wildcarding a product name: the retail model is sold as **`GLO-G561`**
while DMI reports `GLO-GXXX`, exactly as the 2024 MagicBook Pro 16 line reports
`DRA-XX`. If you are writing a profile from a spec sheet, that is the trap.

It is here for two reasons. It is the machine the upstream touchpad quirk was
written for, and nothing in this repository applies to it.

Other models: [index](README.md).

## Hardware

| | | Note |
|---|---|---|
| **CPU** | 13th Gen Core i5-13500H, 12 cores | CPUID family 6 model 186, Raptor Lake |
| **iGPU** | `8086:a7a0`, subsystem `1ee7:203a`, `i915` | an RTX 3050 variant is also sold; the probed unit is iGPU-only |
| **Audio** | `8086:51ca`, subsystem **`1ee7:203a`**, `snd_hda_intel` | no `alc269` quirk upstream |
| **Touchpad** | **`347d:7853`**, ACPI `BLTP7853` | see below |
| **Panel** | not established | the profile records `panel=unknown` |
| **BIOS** | `1.11` (09/15/2023) | from the DMI machine `79EA85B67EC3` |
| **Runs on** | Pop OS 22.04, kernel 6.6.10 | from the PCI machine `2F2B243F6D7B`, which is a different unit |

The board version, SKU and BIOS in the profile come from one machine and the PCI
ids from another, because no single published dump has both. Five GLO-GXXX
machines are in the database and they are not all the same board revision, so
treat the two halves as independent readings rather than one machine's
inventory.

## The touchpad quirk everything else in this family inherits

Commit [`9ffccb691adb`](https://github.com/torvalds/linux/commit/9ffccb691adb854e7b7f3ee57fbbda12ff70533f)
"HID: multitouch: Add quirk for HONOR GLO-GXXX touchpad" (Aoba K, 2023-11-21,
first in **v6.7**) matches `347d:7853` as `MT_CLS_VTL`, whose
`MT_QUIRK_FORCE_GET_FEATURE` is what stops the pad coming up in mouse mode.

It was written for this laptop, and because the match is on bus and id rather
than DMI, it covers **FMB-P, FMB-PM, DRA-XX, DRB-P and FRB-X** as well. Half
the machines on the [index](README.md) get a working touchpad from a patch
somebody sent for a 2023 model.

The kernel comment calls `347d:7853` a "panel"; it is a touchpad. Harmless, but
it costs people a minute when they grep for it.

`dgpu` is left `unknown` in the profile rather than `none`: an RTX 3050 option
exists, the probed unit does not have one, and since the fix list is empty
either way there is nothing for the discrete GPU to change.

## Not established

Everything else: `touchscreen_hid`, `fingerprint_usb`, `camera_usb`,
`backlight_max`, and anything the tier B fixes would need. One probe, no owner report, and a 2023 machine that is largely
supported by mainline already.
