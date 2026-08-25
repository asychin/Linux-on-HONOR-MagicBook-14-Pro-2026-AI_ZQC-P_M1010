# How the ACPI override was derived

The touchpad fix is a patched firmware table, not a driver change, so it is
worth writing down how it was produced: the same procedure is what somebody
with a different HONOR laptop needs.

## How the patch is built

`patch/acpi-override/zqc-p/M1010/SSDT27_TPD0.aml` is regenerated from `patch/acpi-override/zqc-p/M1010/SSDT27_TPD0.dsl` with:

```bash
build/build_patch.sh
```

The script

1. Runs `iasl SSDT27_TPD0.dsl` to produce a fresh AML.
2. Patches the OEM-revision field in the AML header from `0x00001000` (the
   OEM value) to `0x00002000` — Linux only swaps an existing SSDT for an
   initrd-provided one when **all** of `signature` / `OEM_ID` /
   `OEM_TABLE_ID` / `OEM_REVISION` match and the override's revision is at
   least the installed one. Bumping the revision by 1 step is the standard
   trick to force the upgrade even when the patched and original tables would
   otherwise tie.
3. Recomputes the ACPI table checksum so the result loads cleanly.

The exact source-level change is in `../patch/acpi-override/ssdt27.patch`:

```asl
             CreateWordField (SBGF, 0x17, INT1)
-            INT1 = GNUM (0x001A088A)
+            Method (_INI, 0, NotSerialized)
+            {
+                INT1 = GNUM (0x001A088A)
+            }
```

That is the *only* semantic change. Everything else (every other device,
every other field, every other method) is identical to the OEM SSDT.

---


## First: check whether your table is one we already have

Before deriving anything, find out whether your machine ships a table this
repository already carries. That is not a silly question, and the answer is
sometimes yes on a machine you would not expect: **ZQC-P (MagicBook Pro 14
2026) and XWC-P (MagicBook Pro 16 2026) ship a byte-identical `I2C_DEVT`
SSDT**, on different BIOS versions.

```sh
# find the table by its OEM table id, not by file number: acpidump numbers
# SSDTs in boot order and that number differs between machines
for f in /sys/firmware/acpi/tables/SSDT*; do
    printf '%s  %s  %s\n' "$(basename "$f")" \
        "$(sudo dd if="$f" bs=1 skip=16 count=8 2>/dev/null)" \
        "$(sudo md5sum "$f" | cut -d' ' -f1)"
done | grep I2C_DEVT
```

`27bb4879b5af49ac2b613a73cf1ffa0b` is the stock table this repository patches;
`0ed8b48df42f797b55714fab5aadaf42` is the patched one, which means the override
is already installed. `apply_patch.sh` runs exactly this check and refuses on
anything else, so if it refuses, the rest of this page is what you need.

Any other md5 means your machine needs its own table. That is still a small job
and the shape of the fix is the same.

## Re-deriving the patch on a similar laptop

If you have a different HONOR (or any other) machine where SSDT-load fails
with `AE_AML_INTERNAL`, the same approach should apply:

```bash
# 1. Capture live ACPI tables
sudo build/extract_oem_acpi.sh   # writes ./oem_acpi/*.dat + *.dsl

# 2. Find the SSDT named in the dmesg error line. dmesg will say
#    "(SSDT:<TABLE_ID>) while loading table". Open <TABLE_ID>.dsl and
#    look for a top-level statement that calls a method (anything that's
#    *not* inside a Method (...) {} block). Common culprits are
#    `<field> = <method>(<arg>)` lines inside Device(...) blocks.

# 3. Wrap that statement in `Method (_INI, 0, NotSerialized) { ... }` so
#    it runs after the table has loaded.

# 4. Recompile and bump the OEM revision (see build/build_patch.sh for the
#    exact one-liner).
```

The Windows-side dump under `dump/win11/` is invaluable here: `pnp_full_dump.txt`
shows the *actual* ACPI path and HID for every device, so you can confirm
which BIOS device you're chasing. For example, in our case Linux saw a
`TXNW3643:01` I²C device which turned out to be a MIPI camera template
*reused as a vendor PNP ID*, not the touchpad. The touchpad's real ACPI path
(`\_SB.PC00.I2C1.TPD0`) was only visible in the Windows PnP dump.

---


---

## Verifying before you reboot

Compiling cleanly is not the same as loading cleanly. `acpiexec` runs the
whole namespace in userspace and will tell you whether your corrected table
resolves, which is a much cheaper way to find out than a boot with no input
devices:

```sh
sudo acpidump -b                       # writes dsdt.dat, ssdt*.dat
acpiexec -b 'quit' dsdt.dat $(ls ssdt*.dat | grep -v <yours>.dat) yours.aml
```

You want **0 added failures** compared with the same command on the untouched
set. phreer's `full-analysis.md` documents this method on XWC-P and it is worth
copying.

Then keep a fallback. Add a second bootloader entry with the override and leave
the original entry alone, so a table that does not work costs you one reboot
rather than a rescue USB.

## Three shapes of the same fix

People have solved this three ways on this hardware. They are not equivalent in
risk, and it is worth knowing all three before picking:

| | What it does | Trade-off |
|---|---|---|
| **`_INI` wrap** (this repository, denis-bb, SamenVas) | moves the offending statement into `Method (_INI)` so it runs after the table loads | smallest diff, keeps the OEM's own resource and GPIO logic |
| **Rename the table id** (phreer variant C) | changes `I2C_DEVT` to `I2CDEVC` so the kernel *adds* the table instead of replacing the BIOS one | sidesteps any question about the replacement path; the original still fails to load and still logs one failure |
| **Static resources** (phreer variant B) | replaces the device's `_CRS`/`_INI`/`_DSM` with hardcoded values measured at runtime | no GPIO calculation at all, but the numbers are machine-specific and a BIOS change invalidates them silently |

There is an unresolved disagreement about whether replacing with the id intact
re-triggers the bug. Two people replace and it works; phreer reports it does
not. See [the XWC-P page](hardware/xwc-p.md#one-thing-is-still-unresolved-replace-or-rename).

## Two traps that have cost people real time

**`acpidump` lies once an override is installed.** It reads through the kernel,
which has already applied the override, so what you get back is your *patched*
table. Somebody attached exactly such a dump to denis-bb issue #8 as evidence of
an undiscovered firmware variant; it turned out to be denis-bb's own patched
table, byte for byte. Boot once without the override before dumping, and
[`tools/dump-acpi.sh`](../tools/dump-acpi.sh) will tell you when it detects the
situation.

**The device you are chasing may not be the one Linux names.** On a HONOR
MagicBook Pro 14 2026 the I²C device Linux showed was `TXNW3643:01`, which is a
MIPI camera template reused as a vendor PNP id, not the touchpad. At least one
person chased it as the touchpad for a while (denis-bb issue #6). The real path,
`\_SB.PC00.I2C1.TPD0`, was only obvious from the Windows PnP dump. If you have
Windows still installed, [WINDOWS-DUMP.md](WINDOWS-DUMP.md) is worth an hour.

## One table per BIOS, unless proven otherwise

A BIOS update rewrites these tables. Sometimes it changes nothing relevant, and
sometimes it changes the size: FMB-P's DSDT is 528,211 bytes on BIOS 1.13 and
522,231 on 1.16, with the same bug in both. Never assume; re-run the md5 check
above after a firmware update, and record which BIOS your table came from
alongside it.
