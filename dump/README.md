# Dumps

Raw material, one directory per kind and then one per model. Nothing here is
installed by anything; it is what the fixes were derived from, and what somebody
working on a model nobody owns has to read.

```
dump/
├── acpi/<model>/    the machine's own firmware tables
└── win11/<model>/   what the factory OS knows about the same machine
```

| | |
|---|---|
| [`acpi/`](acpi/) | ACPI tables as the firmware provides them, `.aml` and disassembled `.dsl`. Produced by [`tools/dump-acpi.sh`](../tools/dump-acpi.sh) |
| [`win11/`](win11/) | ACPI tables, the full PnP device list and the registry hive from Windows. Produced by hand, see [docs/WINDOWS-DUMP.md](../docs/WINDOWS-DUMP.md) |

## Why both

They answer different questions.

The **ACPI dump** is what Linux has to work with, and on the 2025 and 2026
machines it is also the thing that is broken: one module-level call inside an
unrelated `Device (NFC0)` aborts at load time, the kernel rolls the whole table
back, and every I²C device it declared stops existing. It is the `I2C_DEVT`
SSDT on `ZQC-P` and `XWC-P`, and the DSDT itself on `FMB-P` and `FMB-PM`. The
`DRA-XX` (2024) and `DRB-P` (2025) do not have the fault at all. The corrected table in
[`patch/acpi-override/`](../patch/acpi-override/) is that dump with one line
moved, and [`ssdt27.patch`](../patch/acpi-override/zqc-p/M1010/ssdt27.patch) is the diff
between them.

The **Windows dump** is what the same firmware tells an interpreter that
tolerates the bug, plus everything the vendor's own driver knows: the WMI
dispatch table behind the fan and battery work, the EC field names, and which
driver claims which device. When something works on the factory OS and not
here, the answer is usually in there rather than in the kernel.

## What is here

| Model | ACPI | Windows |
|---|---|---|
| `ZQC-P` | [`acpi/zqc-p/`](acpi/zqc-p/) — `I2C_DEVT` at BIOS 1.10 | [`win11/zqc-p/`](win11/zqc-p/) |

One model, out of the twelve product codes [`devices/`](../devices/)
recognises. That is the gap: everything known about the other eleven comes from
other people's
repositories and from hardware probes, neither of which carries firmware
tables. If you have any HONOR MagicBook, this is the contribution that cannot
be substituted.

The two dumps here corroborate each other: `win11/zqc-p/OEM/DSDT.aml` is
byte-identical to the live `/sys/firmware/acpi/tables/DSDT` on BIOS 1.10, and
`win11/zqc-p/OEM/SSDT27.aml` is byte-identical to `acpi/zqc-p/SSDT27_orig.aml`.

## Adding yours

```sh
sudo bash tools/dump-acpi.sh          # then move the result into dump/acpi/<model>/
```

Read-only, about a minute. [docs/RESEARCH.md](../docs/RESEARCH.md) explains
what to look for in the result and how to produce a corrected table.

The Windows side is a manual procedure and needs the factory OS still
installed: [docs/WINDOWS-DUMP.md](../docs/WINDOWS-DUMP.md). It also needs a
few minutes of scrutiny before publishing, because a registry export carries
the machine name, Wi-Fi profiles and product keys.

Send the ACPI dump even if you send nothing else. It is the one thing that
cannot be reconstructed from anywhere but the machine, and it is what an
`AE_AML_INTERNAL` at boot is fixed with.

## A warning about `acpidump`

`acpidump` goes through the kernel, which has already applied any initrd table
override. If one is installed, what you get back is the **patched** table, not
your firmware's own. On this machine, with the override in place,
`/sys/firmware/acpi/tables/SSDT27` is byte-identical to
`patch/acpi-override/zqc-p/M1010/SSDT27_TPD0.aml` (`0ed8b48d…`, 22940 bytes, OEM revision
`0x2000`) rather than to `acpi/zqc-p/SSDT27_orig.aml` (`27bb4879…`, 23708 bytes,
OEM revision `0x1000`). This is not a hypothetical. denis-bb issue #8 reports an FMB-P on which both
published tables fail, attaches "a full acpidump from my unit" as evidence of an
undiscovered regional firmware variant, and that dump is byte-identical to
denis-bb's own patched Chinese table (`7830156903fc1f43fc42d3463ec41153`). The
machine was dumped with the override loaded. A real question went unanswered for
want of one boot without it.

`tools/dump-acpi.sh` detects this, says so, and
records `acpi_override=yes` in the `MACHINE.txt` it writes, so a contributed
dump cannot be mistaken for a factory one. For a genuine factory dump, boot
once without the override.
