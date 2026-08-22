# Security policy

## What this repository is, in security terms

This is not a networked service. It is a collection of scripts that a person
runs, deliberately, as root, on their own laptop. What they do is nonetheless
privileged:

- install an ACPI table override that the firmware parser consumes at boot
- rebuild the initramfs and edit the kernel command line
- place kernel modules into `/usr/lib/modules/$KVER/updates/`
- build code fetched over the network from `raw.githubusercontent.com` and
  from distribution package sources
- install udev rules, package-manager hooks and systemd units

So the interesting failure mode here is not data theft. It is a machine that
will not boot, or a kernel module that misconfigures hardware.

## Supported versions

Only the tip of `main`. This repository tracks a moving target, current kernels
and current firmware, and older commits are not maintained.

## Reporting

**For anything that could damage hardware or prevent a machine from booting**,
please report privately first, so a fix can go out before the recipe does. Use
GitHub's private vulnerability reporting on this repository, or contact the
maintainer at [@rs0x29a](https://github.com/rs0x29a).

Examples of what belongs here:

- an installer that can write a table or a value to the wrong machine
- a path where an unrecoverable state is reached without a backup being taken
- an EC or firmware access that could be destructive if a register is wrong

**For ordinary bugs**, including an installer that fails, a fix that does not
work, or a regression after a kernel update, open a normal issue. Those are not
security reports and public discussion helps everyone.

## What to include

- your model (`/sys/class/dmi/id/product_name`) and BIOS version
- distribution and `uname -r`
- which script, and how far it got
- what state the machine was left in, and whether it recovered

Please do not include serial numbers, `MSDM`, or a full registry export.

## What we ask of contributors

The conventions in [`CONTRIBUTING.md`](CONTRIBUTING.md) exist mostly for this
reason. Two of them matter more than the rest:

- **Gate on the hardware you touch.** Model-specific values must never reach a
  machine that was not verified. Most of this repository was derived from a
  single unit.
- **Never write into `kernel/`.** Modules belong in the `updates/` overlay, so
  the distribution's own file survives and removal is one `rm`.

## How that is enforced

`apply_patch.sh` identifies the machine from DMI before it touches anything,
and refuses if no profile in `devices/` matches. Profiles carry a `status`, and
a fix carrying model specific constants only runs against a profile somebody
has actually verified. The tiers live in `lib/profile.sh`.

Profiles are parsed, never sourced. They arrive through issues, from people we
do not know, and are consumed by a script running as root, so unknown keys are
rejected and values are restricted to a boring character set.

It also refuses to publish what should not be published. `MSDM` carries a
Windows OEM licence key in clear text and a full `HKLM` registry export carries
that plus the machine name and Wi-Fi profiles.

> **Both were committed to this repository in its first commit, `f140954`, and
> are still readable from git history.** Deleting them from the tip does not
> remove the blobs: anyone can fetch them from any clone, fork or cached object.
> The key on that machine should be treated as disclosed. Removing them for good
> needs history to be rewritten and force-pushed, and every fork re-created;
> until that is done and this paragraph says so, assume the exposure is live.
[`tools/dump-acpi.sh`](tools/dump-acpi.sh) and
[`tools/collect-hwinfo.sh`](tools/collect-hwinfo.sh) now delete `MSDM` before
handing you an archive, and `tools/selftest.sh` fails on a key-shaped string, an
`MSDM` file or a whole-hive export anywhere in the tree.

`tools/selftest.sh` checks the whole arrangement without root, hardware or
network: that every profile parses, that no fix is named that does not exist,
that detection picks the right profile for each model's real DMI values, and
that no two profiles can both match one machine. Run it after touching a
profile or anything in `lib/`.

This is a floor, not a guarantee. A wrong value inside a *verified* profile
will still be acted upon, which is why verification means somebody ran the
fixes on that machine rather than somebody read a spec sheet.
