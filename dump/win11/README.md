# What the factory OS knows

One directory per model. These are references, not something anything installs:
when a device works on Windows and not on Linux, the answer is usually in here.

```
dump/win11/<model>/
├── OEM/                            every ACPI table, as .aml and .dsl,
│                                   minus MSDM
├── pnp_full_dump.txt               every PnP device, its hardware ids and driver
└── honor-registry-extract.reg.zst  the vendor subtrees of HKLM, compressed
```

| Model | What it settled |
|---|---|
| [`zqc-p/`](zqc-p/) | the WMI method table behind the fan and battery work, and which devices the vendor driver claims |

**Two things are deliberately not here, and must not be added.**

`MSDM` is the ACPI table that carries the machine's Windows OEM licence key, in
clear text, at offset 56. It has no bearing on any fix and it does not belong in
a public repository. `tools/dump-acpi.sh` and `tools/collect-hwinfo.sh` both
delete it before they hand you an archive, and `tools/selftest.sh` fails if one
reappears in the tree.

**A whole `HKLM` export** is worse: 305 MB, and in the one that used to be
committed here it carried `BackupProductKeyDefault` with the real key, eight
`DigitalProductId` blobs, and 141 references to the machine name. It is gone
from the working tree and **still in git history**; see
[SECURITY.md](../../SECURITY.md).
`honor-registry-extract.reg.zst` replaces it: the same file filtered to the 184
registry blocks whose path mentions HONOR, Huawei, Goodix, FocalTech or the EC,
with every `ProductKey`, `DigitalProductId` and `BackupProductKey` value dropped.
2 MB uncompressed, and it keeps what the dump was for.

`pnp_full_dump.txt` has been through the same treatment, less drastically: the
adapter's Bluetooth MAC, the device-instance suffix that carries it, and the
fingerprint reader's per-unit UID token are replaced with `<redacted>`. Every
hardware id, driver name and ACPI path is untouched, because those are the point
of the file and none of them identifies a person.

To make one yourself, see [docs/WINDOWS-DUMP.md](../../docs/WINDOWS-DUMP.md).
Decompress with `zstd -d`.

## Making one

[docs/WINDOWS-DUMP.md](../../docs/WINDOWS-DUMP.md) is the procedure: it needs a
working Windows install on the same machine and takes about ten minutes.
