# Making a Windows dump

When a device works on the factory OS and not on Linux, the answer is almost
always in what Windows knows about it: which driver claims it, which hardware
ids it advertises, and what the firmware tells it that it does not tell us.

Three artefacts are worth having, and together they take about ten minutes.
They go in [`dump/win11/<model>/`](../dump/win11/).

You need the machine's own Windows install. A live USB will not do: half the
value is in the OEM driver's registry state.

---

## 1. The ACPI tables, as Windows sees them

The point of dumping these under Windows rather than Linux is that Linux may
already be applying an override, and on a machine where the tables fail to load
Linux never sees the interesting ones at all.

Get the ACPICA tools for Windows from
<https://www.intel.com/content/www/us/en/developer/topic-technology/open/acpica/download.html>
(`iasl-win-*.zip`), unpack somewhere, then in an **administrator** command
prompt:

```bat
acpidump.exe -b
```

That writes one `.dat` per table into the current directory. Disassemble them
together, so cross-table method calls resolve:

```bat
iasl.exe -e dsdt.dat,ssdt*.dat -d *.dat
```

Keep both the `.aml` and the `.dsl` for every table **except `MSDM`**. Delete
that one now:

```bat
del msdm.dat msdm.aml msdm.dsl
```

`MSDM` carries your Windows OEM licence key in clear text, starting 56 bytes in.
It has nothing to do with any fix here, and it was committed to this repository
by mistake once already. `tools/selftest.sh` fails if one turns up in the tree.

Rename the remaining `.dat` files to `.aml` so the directory reads the same as
the Linux side.

> The `-e` matters. Without it every call into another table disassembles as an
> unresolved name and the code that matters is unreadable.

---

## 2. Every device, with its ids and driver

In an **administrator** PowerShell:

```powershell
Get-PnpDevice | ForEach-Object {
    "=" * 50
    "Device        : $($_.FriendlyName)"
    "Class         : $($_.Class)"
    "Manufacturer  : $($_.Manufacturer)"
    "InstanceId    : $($_.InstanceId)"
    "-" * 50
    "PROPERTIES:"
    Get-PnpDeviceProperty -InstanceId $_.InstanceId | ForEach-Object {
        ""
        "[$($_.KeyName)]"
        "Type : $($_.Type)"
        "Data :"
        $_.Data
    }
} | Out-File -Encoding utf8 pnp_full_dump.txt
```

This is the file that answers "what is this device actually called, and which
driver has it". The `SUBSYS_` field in an `InstanceId` is where PCI subsystem
ids come from, which is what an HD-audio codec quirk keys on.

---

## 3. The registry, scoped

This is where the vendor's own service keeps what it knows: WMI method names,
EC register meanings, fan tables, and the device ids its driver binds to.
Searching it for a WMI GUID or a method name found in the DSDT is usually
faster than reading the AML.

**Do not export the whole hive.** `reg export HKLM` produces about 300 MB and
carries your Windows licence key, your machine name and your Wi-Fi profiles
along with it. Export the subtrees you actually need:

```bat
reg export "HKLM\HARDWARE\ACPI" acpi.reg
reg export "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI" enum-acpi.reg
reg export "HKLM\SYSTEM\CurrentControlSet\Services" services.reg
```

If you already have a full export and want to salvage it, filter it on Linux
instead of re-exporting. This is how
`dump/win11/zqc-p/honor-registry-extract.reg.zst` was produced: keep only the
blocks whose path names the vendor, drop every licensing value.

```python
import io
keys = ('HONOR','Huawei','HUAWEI','Goodix','FTSC','TOPS0102','WMAA','LXEC')
drop = ('ProductKey','DigitalProductId','BackupProductKey','ProductId',
        'SusClientId','MachineGuid','HwProfileGuid')

def flush(out, buf, keep):
    if keep and buf:
        out.writelines(buf)

buf, keep, value = [], False, []
with io.open('HKEY_LOCAL_MACHINE.reg', encoding='utf-16', errors='replace') as f, \
     io.open('scoped.reg', 'w', encoding='utf-8') as out:
    for line in f:
        if line.startswith('['):
            flush(out, buf, keep)
            buf, keep, value = [line], any(k in line for k in keys), []
            continue
        # A registry value can span many lines: every line but the last ends
        # with a backslash. Accumulate the whole value, then decide, or a
        # multi-line hex: blob loses its first line and keeps its payload.
        value.append(line)
        if line.rstrip().endswith('\\'):
            continue
        if not any(d in value[0] for d in drop):
            buf.extend(value)
        value = []
    if value and not any(d in value[0] for d in drop):
        buf.extend(value)
    flush(out, buf, keep)
```

Then check the result before you commit it:

```sh
grep -acoE '[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}' scoped.reg
grep -ac 'ProductKey\|DigitalProductId\|ComputerName\|ProfileName' scoped.reg
```

Both must print `0`.

On the reference machine that turns 413,075 registry blocks into 184, and
305 MB into 2 MB. Then `zstd -19 scoped.reg`, and check the result before
committing it.

---

## Before you publish one

A registry export contains machine-specific and sometimes personal data. This
section existed before the first commit of this repository and was not applied
to it, with the consequences set out in [SECURITY.md](../SECURITY.md). So:
actually run the checks below, and run `tools/selftest.sh`, which fails on
key-shaped strings and on any whole-hive export in the tree, before the first
commit and not after. Deleting a blob from the tip does not remove it from
history.

At minimum, check for and remove:

- `HKLM\SYSTEM\...\ComputerName`, and any hostname you would rather not share
- Wi-Fi profiles under `HKLM\SOFTWARE\Microsoft\WlanSvc`
- product keys and licence blobs under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion`
- user names appearing in installed-application paths

The ACPI tables and the PnP dump are firmware and hardware inventory and carry
nothing personal, though the PnP dump does contain the machine's serial in some
`InstanceId` values, so it is worth a look before posting.

If that sounds like more scrutiny than you want to give it, the ACPI tables
alone are still genuinely useful. Send those.

---

## What this repository has

| Model | Dump | Notes |
|---|---|---|
| `ZQC-P` | [`dump/win11/zqc-p/`](../dump/win11/zqc-p/) | the source for the WMI method table in the fan and battery work |

The WMI dispatch table that made the fan work readable, and the EC offsets
behind `honor-ec-sensors`, both came out of the DSDT in that directory rather
than from guesswork. It is worth the ten minutes.
