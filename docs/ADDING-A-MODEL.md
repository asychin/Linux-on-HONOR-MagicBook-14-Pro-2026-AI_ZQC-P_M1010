# Adding a model

This repository was built from one physical laptop. Everything that makes a
fix work on it, PCI subsystem ids, USB and HID ids, EC register offsets, the
panel's VBT, an ACPI table, is different on every other model. So adding a
model is mostly a matter of getting those values, and the code is already
arranged to accept them.

There are three stages, and the first one is the only one that needs the
hardware.

## 1. Send a dump

```sh
sudo bash tools/collect-hwinfo.sh
```

Read-only. It reads sysfs, runs `lspci` and `lsusb`, copies the ACPI tables and
the video BIOS table, and writes one `honor-hwinfo-<model>-<date>.tar.gz` of
about 200 KB.

It never reads `product_serial`, `board_serial`, `chassis_serial` or
`product_uuid`, and it checks the collected text for them anyway before
packing. Look inside if you would rather see for yourself:

```sh
tar xzf honor-hwinfo-*.tar.gz -O ./report.txt | less
```

Attach it to an issue using the **Hardware dump for a new model** template, and
say what is actually broken on your machine under Linux. That last part matters
as much as the dump: a fix nobody needs is not worth carrying.

## 2. Write a profile

Copy [`devices/TEMPLATE.conf`](../devices/TEMPLATE.conf) to
`devices/<model-in-lowercase>.conf` and fill it in from the dump.

The fields are in two groups and the split decides what the installers will
let you do:

**Hardware inventory** is fact, and all of it is in the dump:

| Field | Where in the dump |
|---|---|
| `dmi_*` | the `DMI` section |
| `dmi_board_version` | `board_version` in the same section: `M1010`, `M1020` … |
| `touchscreen_hid`, `touchpad_hid` | `HID devices`, the directory name is `BUS:VID:PID` |
| `audio_ssid` | `audio subsystem id` |
| `fingerprint_usb` | `USB`, the Goodix or Elan reader |
| `panel`, `backlight_max` | `backlight`, plus whether the panel is OLED |
| `ec_fan0`, `ec_fan1` | the tachometer fields in that machine's DSDT |

**Fix parameters**, the `param_` ones, are not in the dump and cannot be. They
are decisions somebody made with the laptop in front of them:
`param_backlight_min` is measured by eye, `param_audio_fixup` names a piece of
kernel code written for that board. Leave them `unknown` until they exist.

Write `unknown` rather than guessing. A missing value produces a clear refusal;
a wrong one gets acted upon. Write `none` when you have looked and the part is
genuinely absent, which is a different statement and the only one that justifies
leaving a fix off the list.

### Two traps in the DMI section

**`dmi_product` is what the firmware says, not what the box said.** HONOR
sometimes wildcards the digits: every 2024 MagicBook Pro 16 reports the literal
string `DRA-XX`, whatever it was sold as. This repository carried four profiles
keyed on `DRA-54`, `DRA-56` and `DRA-72` for a while, and since matching is
exact, not one of them could ever have fired. Copy the string out of the dump.

**`dmi_sku` does not identify a model here.** `C233` is reported by ZQC-P,
XWC-P, an FMB-P, a DRA-XX and a BCC-N. Record it, but detection tries
`dmi_board` and `dmi_board_version` first and falls back to `dmi_sku` last,
where it can only confirm a choice already narrowed.

### Which fixes to list

`fixes=` means "this model needs this". List one when that follows from a value
already in the profile, not from a hunch:

| Recorded fact | Follows |
|---|---|
| `platform=pantherlake` | `cdclk-ptl`, `sof-audio` |
| `touchscreen_hid=2808:5662`, the FocalTech panel | `micmute` |
| `panel=oled` | `oled-backlight` |
| `fingerprint_usb`, **and** a recipe for that id under `patch/fingerprint/sensors/` | `fingerprint` |
| `ec_fan0` / `ec_fan1` | `fan` |
| `battery_charge_presets` | `battery` |
| any of the above builds a module or rebuilds a library | `auto-rebuild` |

A recorded `fingerprint_usb` on its own is **not** enough. `27c6:5f10` and
`10a5:a921` are both real readers on real machines here and neither has a
recipe, so listing `fingerprint` for them would produce a fix that patches the
wrong id into the wrong driver.

Listing a tier B fix on a profile that is not `verified` is still worth doing:
it will refuse, and the refusal names what is missing. That is more useful than
silence.

### When one model has several hardware variants

This is common: the same laptop ships a Goodix fingerprint reader in one market
and a LighTuning one in another, and both report the same DMI product name.

If the difference is **visible on the running machine**, and a USB, HID or PCI
id always is, do not split the profile. List the possibilities:

```
fingerprint_usb=27c6:6f94 1c7a:05aa
```

The installer probes the bus and uses the one actually fitted, so a single
profile covers both units. A field with one value behaves exactly as before.
`touchscreen_hid`, `touchpad_hid` and `audio_ssid` work the same way.

Where the variants need **different code**, not just a different id, the
installer maps the detected device to the right patch and refuses cleanly when
it has none for what it found. That is better than applying the wrong one: the
Chinese sensor above needs libfprint's SDCP support, so adding its id to the
Goodix table would achieve nothing.

Split into separate profiles only when the difference is **not** visible at
runtime, for example an EC layout or a measured backlight floor. Then you need
a discriminator DMI can see, and they are tried in this order: `dgpu` (which
separates the HUNTER variants from the UMA ones), then `dmi_board`, then
`dmi_board_version`, then `dmi_sku`.

`dmi_board_version` is usually the one that works. Five FMB-P board revisions
share one product name; three DRA-XX configurations differ only by it.

Check it parses:

```sh
bash -c 'source lib/profile.sh; profile_load devices/<model>.conf && echo ok'
```

Unknown keys are an error, not a warning, so a typo cannot silently drop a
value.

## 3. Verify it, then say so

A new profile is `draft`, `probed` or `reported`:

| | What somebody did |
|---|---|
| `draft` | nothing. Model and platform from published specifications |
| `probed` | uploaded a hardware probe, or sent a dump. The ids are genuine readings, no fix was tried |
| `reported` | ran something on that machine and wrote it down, in another project |

All three behave identically as far as the installers are concerned: only the
fixes that cannot carry another machine's constants are allowed, meaning those
that read their inputs off the running machine, or match on a device id and
simply find nothing on hardware they were not meant for.

```sh
sudo ALLOW_UNVERIFIED=1 ./apply_patch.sh
```

Everything else stays disabled until somebody runs it on that model and it
works. When that happens, set `status=verified` and record what it was verified
against:

```
status=verified
verified_kernel=6.11.0-generic
verified_bios=1.04
verified_distro=Ubuntu 24.04
```

Please do not set `verified` on the strength of a spec sheet or a DSDT that
looks similar to ours. The whole point of the field is that somebody took the
risk on real hardware.

## What the fixes need beyond a profile

Three of them need more than values, because the model-specific part is code
or a binary rather than a number:

| Fix | What a new model needs |
|---|---|
| `acpi-override` | the same table, or its own. The installer compares the md5 of your live `I2C_DEVT` against the stock one in `dump/acpi/` and refuses unless they match, so a model that happens to ship the identical table is covered for free — ZQC-P and XWC-P do — and one that does not gets a clean refusal. If yours differs, rebuild it from your own tables with `build/build_patch.sh` and [RESEARCH.md](RESEARCH.md) |
| `headset-mic` | possibly a new `alc269.c` fixup. The installer refuses if `param_audio_fixup` names one it does not know how to emit |
| `fan` | its EC offsets added to the DMI table in `patch/fan/honor-ec-sensors.c` as their own `honor_ec_layout`. The installer refuses if the model is not in that table, and the module would refuse to load anyway |

`fingerprint` is in between: the id comes from the profile, but the libfprint
patch adds one specific id, so a different reader needs its own patch file. The
installer compares the two and refuses on a mismatch.

## Which fixes even apply

Some of it follows from the platform rather than the model:

| | 2026, Panther Lake | 2025, Arrow Lake | 2024, Meteor Lake |
|---|---|---|---|
| `cdclk-ptl` | yes, display IP 30 | no | no |
| `sof-audio` | relevant | probably not | probably not |
| everything else | depends on the parts fitted | same | same |

And some of it does not apply because upstream already handles it. Check before
writing a fix:

* the internal-keyboard `atkbd` quirk is upstream for `FMB-P` and `FMB-PM`
  (6.19), `BCC-N` (7.1) and `ZQC-P` (7.2, 7.1.10)
* the touchpads `347d:7853` (commit `9ffccb691adb`, in since v6.7) and
  `35cc:0104` (commit `7a5ab8071114`) already have `hid-multitouch` quirks
* `iwlwifi`'s regulatory allow-lists match `HONOR` vendor-wide, so Wi-Fi power
  tables need no per-model work
* the 2024 machines have no ACPI table failure at all

Models with a discrete NVIDIA GPU are supported only on their integrated-GPU
side. The proprietary driver, PRIME and graphics switching are out of scope
here; the `dgpu` field exists to tell two variants of the same `product_name`
apart, not to promise support.
