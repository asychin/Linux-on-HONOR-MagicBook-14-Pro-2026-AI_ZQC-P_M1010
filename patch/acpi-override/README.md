# Patched SSDT27 — touchpad, touchscreen, internal keyboard

**This is the prerequisite fix.** Without it the machine is barely usable under
Linux: the touchpad does not enumerate, and the internal keyboard misbehaves.
Everything else in `patch/` is independent of it.

Applied by `apply_patch.sh` in the repository root — you normally do not invoke
anything here directly.

## What is wrong in the firmware

The touchpad is a Goodix **TOPS0102** on `\_SB.PC00.I2C1.TPD0` (I²C HID, address
`0x5D`), described in `SSDT27` (`OEM Table ID "I2C_DEVT"`).

Inside the device's resource scope the firmware executes

```asl
CreateWordField (SBGF, 0x17, INT1)
INT1 = GNUM (0x001A088A)          // <-- at table-load time, in device scope
```

The `GNUM()` call — which resolves a GPIO pin number into the interrupt
descriptor of the resource buffer — is placed at **table-load time** rather than
inside an initialisation method. Windows' AML interpreter tolerates this;
Linux's ACPICA evaluates the scope differently and the interrupt number never
gets patched into the descriptor, so the touchpad is never wired to a working
IRQ and `i2c_hid` finds nothing.

## What the patch changes

Two edits, both in `SSDT27_TPD0.dsl`:

1. **Move the `GNUM()` call into a proper `_INI` method**, so it runs as device
   initialisation instead of at table load:

   ```asl
   Method (_INI, 0, NotSerialized)
   {
       INT1 = GNUM (0x001A088A)
   }
   ```

2. Normalise a package of raw byte constants to named ASL constants
   (`0x01`/`0x00` → `One`/`Zero`). Cosmetic; a by-product of the
   disassemble/recompile round trip, semantically identical.

The table header's OEM Revision is bumped `0x1000` → `0x2000` so the override is
distinguishable from the stock table at a glance.

## How it is applied

`apply_patch.sh` installs the compiled table and an initramfs hook:

```
patch/acpi-override/zqc-p/M1010/SSDT27_TPD0.aml     -> /usr/lib/firmware/acpi/SSDT27_TPD0.aml
patch/acpi-override/acpi_override.install -> /etc/initcpio/install/acpi_override
```

It then adds `acpi_override` to `HOOKS=` in `/etc/mkinitcpio.conf` (right after
`autodetect`) and regenerates the initramfs, so the kernel loads the override
table early, before the ACPI namespace is built. On distributions without
`mkinitcpio` the same table goes into an early uncompressed CPIO by the
equivalent mechanism; [`lib/distro.sh`](../../lib/distro.sh) picks the route and
[docs/INSTALL.md](../../docs/INSTALL.md#other-distributions-and-bootloaders) describes them.

It also appends **`i8042.dumbkbd=1`** to the kernel command line, which the
internal keyboard needs on kernels below 7.2 (or 7.1.10). That has one known
side effect: it disables atkbd's `SET_LEDS` path, so the **Caps Lock LED stays
dark**. On a newer kernel the upstream `atkbd` quirk does the same job with the
parameter removed and the LED intact; see
[`../keyboard-atkbd/`](../keyboard-atkbd/).

> **Kernel lockdown silently defeats this.** Under lockdown the kernel refuses
> initrd ACPI table overrides and logs only `ACPI: kernel is locked down,
> ignoring table override`. The machine then boots with no touchpad and no
> obvious reason. `apply_patch.sh` warns about it at this step. Turn Secure Boot
> off, or sign the kernel yourself.

`uninstall_patch.sh` reverts all of it.

## Rebuilding the table

`SSDT27_TPD0.aml` is generated from the `.dsl`:

```sh
bash build/build_patch.sh
```

`../../dump/acpi/zqc-p/` holds the untouched `SSDT27_orig.dsl` / `.aml`, and
`ssdt27.patch` beside this file is the diff between it and the table installed here,
the diff between stock and patched sources — useful when a BIOS update changes
the table and the edits have to be re-derived.

`build/extract_oem_acpi.sh` dumps the machine's own ACPI tables, which is where
you start after any firmware update.

## Which machines this table belongs to

Two, and it is the *table* that decides, not the model.

**`ZQC-P` and `XWC-P` ship a byte-identical `I2C_DEVT` SSDT.** phreer published
the full disassembly of the stock table from a MagicBook Pro 16 2026 on BIOS
1.09; against this repository's `dump/acpi/zqc-p/SSDT27_orig.dsl`, taken from a
MagicBook Pro 14 2026 on BIOS 1.10, it matches on length (23708), checksum
(`0xE5`), OEM revision (`0x1000`), compiler stamp, and every one of 3862 lines
of ASL. Different screen size, different BIOS version, same table. That is why
two people arrived at the same one-line fix independently, and why this fix is
listed for both models.

**The installer decides at run time.** Before writing anything it finds the live
table by its OEM table id — not by file name, since `acpidump` numbers SSDTs by
boot order and that number is not stable — and compares the md5:

| live table | what happens |
|---|---|
| `0ed8b48d…`, the patched one | already installed, re-running changes nothing |
| `27bb4879…`, the stock one | install, whatever the model or BIOS says |
| anything else | refuse, printing both md5s. `FORCE_ACPI=1` overrides |

A model whose table differs needs its own, and gets a clean refusal rather than
a machine that will not boot. BCC-N is that case: its `I2C_DEVT` is 35,635 bytes
against these 23,708.

## Which BIOS this table came from

**BIOS 1.10**, and the check is reproducible on the machine:

| | md5 |
|---|---|
| `dump/win11/zqc-p/OEM/DSDT.aml` and the live `/sys/firmware/acpi/tables/DSDT` | `736ba1ee…` — identical, so the Windows-side dump is this firmware |
| `dump/win11/zqc-p/OEM/SSDT27.aml` and `dump/acpi/zqc-p/SSDT27_orig.aml` | `27bb4879…` — identical, so the stock table on record is this firmware's |
| `SSDT27_TPD0.aml` here and the live `/sys/firmware/acpi/tables/SSDT27` | `0ed8b48d…` — identical, so what is installed is what is in this directory |

The stock table is unchanged between BIOS 1.09 and 1.10; earlier revisions of
this file said 1.09 for that reason, and SamenVas's independent dump on 1.09 is
the same 23708 bytes. `devices/zqc-p.conf` records `verified_bios=1.10` for
provenance only: **the installer does not gate on it.** It compares the md5 of
your live table, which is the thing that actually decides, and which a BIOS
update would change if it rewrote the table.

To check yours, with the override **not** installed:

```sh
sudo bash tools/dump-acpi.sh
md5sum dump/acpi/zqc-p/SSDT27_orig.aml   # 27bb4879b5af49ac2b613a73cf1ffa0b
```

`tools/dump-acpi.sh` detects an installed override and says so, because
`acpidump` goes through the kernel and would otherwise hand you the patched
table back.

## If a BIOS update breaks this

Re-dump the tables, disassemble `SSDT27`, and re-apply the `_INI` change by
hand — match on the method and object names, not on line numbers, since those
drift between firmware revisions. Then replace `dump/acpi/zqc-p/SSDT27_orig.aml`
with your new stock table, so the installer's md5 comparison recognises it, and
update `verified_bios` in `devices/zqc-p.conf` to record where it came from.
