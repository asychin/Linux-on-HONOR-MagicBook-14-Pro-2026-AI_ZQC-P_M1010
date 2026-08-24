# Fingerprint reader — Goodix `27c6:6f94`

Working: enroll and verify both succeed.

## The device

The power-button reader is a Goodix **match-on-chip** sensor on USB:

```
27c6:6f94  "Goodix USB2.0 MISC"
vendor-specific class, 2 bulk endpoints, firmware 01010106
device id UID579A0DC6_XXXX_MOC_B0
```

It is a **pure USB device and has nothing to do with the ACPI override** this
repo ships. The DSDT does contain a fingerprint node, but on the wrong bus:
`\_SB.PC00.SPI1.FPNT` is a generic SPI sensor slot for other SKUs, whose `_HID`
resolves through an EC-provided selector byte `FPTT` (FPC1011 / FPC1020 /
VFSI6101 / VFSI7500 / EGIS0300 / FPC1021). On this unit `FPTT == 0`, so `_HID`
resolves to `"DUMY0000"` and `_STA` returns 0 — the node is absent by design.

A USB device enumerates entirely from its own descriptors, so nothing was ever
missing in firmware. The only place to fix it is the USB driver.

## The fix

The sensor speaks the ordinary `goodixmoc` protocol that `libfprint` has
supported for years. It was simply not in the driver's id table: upstream
already carries `0x6984`, `0x6A94`, `0x6594` and the rest of the family, but
not `0x6F94`. Two additions cover it — the id itself, and the
`max_enroll_stage = 12` case the whole family shares:

```c
     case 0x6984:
+    case 0x6F94:
       self->max_enroll_stage = 12;
...
   { .vid = 0x27c6,  .pid = 0x6984,  },
+  { .vid = 0x27c6,  .pid = 0x6F94,  },
```

No protocol reverse-engineering, no TOD blob, no vendor driver. (Contrast the
sibling FMB-P, whose FPC `10a5:9924` needed real driver logic for an opaque
identity token — this device needs none of that.)

```sh
sudo bash patch/fingerprint/install.sh

# then as your normal user:
fprintd-enroll -f right-index-finger     # 12 touches on the power button
fprintd-verify
```

To use it for login and sudo:

- **Arch/CachyOS** — add `auth sufficient pam_fprintd.so` above the `pam_unix`
  line in `/etc/pam.d/system-local-login` and `/etc/pam.d/sudo`
- **Debian/Ubuntu** — `sudo pam-auth-update --enable fprintd`
- **Fedora** — `sudo authselect enable-feature with-fingerprint`

## Packaging matters here

On Arch/CachyOS the installer does **not** drop files into `/usr`. It derives a
package from Arch's own PKGBUILD with the patch applied in `prepare()`, bumps
`pkgrel` past the repo's so the result is unambiguously newer, and installs it
with `pacman -U`. `PKGBUILD` in this directory is the tested recipe.

This is not cosmetic. A bare `ninja install` leaves unowned files in `/usr`, and
the next `pacman -S fprintd` then fails outright:

```
error: failed to commit transaction (conflicting files)
libfprint: /usr/lib/libfprint-2.so exists in filesystem
```

because `fprintd` pulls `libfprint` in as a dependency. Letting pacman own the
files avoids that and makes the patch visible in `pacman -Qi libfprint`.

A future distro update to a **newer** `libfprint` version will still replace
it — re-run the installer then.

## Build note

`libfprint`'s `tests/meson.build` has an upstream bug in the
`introspection=false` branch that trips newer meson with

```
Foreach expects exactly 2 variables for iterating over objects of type dict
```

so the build forces `-Dintrospection=true`.

## Upstream

`0x6F94` was absent from `libfprint` master as of 2026-07-30 (checked at commit
`c4654fd`). This is a trivially reviewable id addition and should be sent
upstream; once it lands, drop the local patch and this directory.

## Verified state

```
$ pacman -Q libfprint fprintd
libfprint 1.94.100-1.2
fprintd 1.94.5-2.1

$ fprintd-list $USER
found 1 devices
Device at /net/reactivated/Fprint/Device/0
... Goodix MOC Fingerprint Sensor
```

## It used to build itself twice

This script runs `pacman -S --needed` for its build dependencies. The patched
`libfprint` it produced last time is in that dependency closure, so pacman lists
`libfprint` as a target of the transaction, so
[`../auto-rebuild/`](../auto-rebuild/)'s `96-honor-libfprint.hook` fires, so
`rebuild.sh` defers **a second copy of this script**. Two `makepkg` runs then
raced in one build directory, and the one that lost printed

```
==> makepkg failed — run it by hand in ~/.cache/honor-libfprint-build to see why
```

on a machine whose `libfprint` had in fact just been patched correctly by the
other one. The failure was in the report, not in the result, which is the worst
shape a bug can take.

It now takes `/var/lock/honor-fingerprint.lock` before doing anything. Whichever
run gets there first does the work; the other says so and exits. The end state
is the same and it is reached once.

## More than one sensor

HONOR ships different fingerprint readers in different markets under the same
model name, so `sensors/` holds one directory per reader and the installer uses
whichever is actually on the USB bus.

```
sensors/
├── 27c6-6f94-goodixmoc/       Goodix, global ZQC-P — verified here
├── 10a5-9924-fpcmoc/          FPC, global FMB-P
└── 1c7a-05aa-egismoc-sdcp/    EgisTec ET171, Chinese units of both
```

`recipe_find` and `recipe_load` in [`../../lib/gate.sh`](../../lib/gate.sh) do
the lookup, and they are shared with the other fixes that are a family rather
than a single fix: [`../micmute/touchscreens/`](../micmute/) and
[`../touchpad-edge/touchpads/`](../touchpad-edge/) are laid out and read the same
way.

Each carries a `recipe.conf` saying which driver, which patches, which
libfprint versions the patches were checked against, where the work came from,
and whether anyone has run it on hardware. Nothing has to be fetched from
another repository at install time.

| Reader | Source | State |
|---|---|---|
| `27c6:6f94` Goodix | the distribution's own libfprint, plus one patch | verified on this machine |
| `10a5:9924` FPC | same | patches carried in, **not** run on that sensor here |
| `1c7a:05aa` EgisTec | upstream's SDCP branch at a pinned commit, plus three patches | built and checked here, **not** run on that sensor |

### The EgisTec one is different

That sensor speaks SDCP, Microsoft's Windows Hello protocol, and SDCP support
is not in any libfprint release yet: it is
[merge request 547](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/547).
So adding an id to the packaged libfprint would achieve nothing. The recipe
builds upstream's `feature/sdcp-v2` at a pinned commit into `/opt`, and puts it
ahead of the system library through `ld.so.conf.d`. The distribution's package
stays installed and untouched:

```sh
sudo rm -rf /opt/honor-libfprint-sdcp /etc/ld.so.conf.d/00-honor-libfprint-sdcp.conf
sudo ldconfig
```

The three patches are Philip Walsh's, from
[`drphilth/honor-fmbp-libfprint-sdcp`](https://github.com/drphilth/honor-fmbp-libfprint-sdcp),
carried here verbatim with authorship intact.

### Patches go stale, and the installer says so

A patch written against one libfprint does not necessarily fit the next one.
`recipe.conf` records the versions each was checked against, and the installer
refuses rather than applying it with fuzz into a file that has moved on:

```
this patch was checked against libfprint 1.94.9 1.94.10, and you have 1.94.100.
Refusing rather than applying it with fuzz into a file that has moved on.
```

`FP_FORCE_VERSION=1` overrides that if you want to try anyway.

The FPC patch needed exactly this treatment. `fpcmoc` was restructured in
1.94.100: the response fields moved out of a struct into byte-reader locals,
and the identity check that appeared once now appears twice. Carrying it
forward is `0001-fpcmoc-add-10a5-9924-for-libfprint-1.94.100.patch`, which
applies cleanly to 1.94.100, compiles without warnings, and produces a library
that lists `10a5:9924`. Only the verify path is loosened; the second site is
the enrolment duplicate check, and loosening it there would make every
enrolment look like a duplicate.

That rebase has **not** been run on the sensor, which nobody here has. It also
inherits a real limitation worth knowing: the sensor answers with an opaque
per-enrolment token, so with several fingers enrolled `IDENTIFY` reports the
first template rather than the one presented. The device did match a genuine
enrolled finger; the token just does not say which. `VERIFY` is unaffected.

Variants, where a recipe offers them:

```sh
sudo FP_PATCH_VARIANT=old  bash patch/fingerprint/install.sh   # for 1.94.9/1.94.10
sudo FP_PATCH_VARIANT=full bash patch/fingerprint/install.sh   # the larger FPC effort
```

---

## Upstream status

Checked 2026-08-22 against `libfprint` master, HEAD
`c4654fdc85c25afdd9115bec2f95a44145ae3b94` (2026-07-28, "elanmoc: Add new PID
0xCB6") — the same commit this file was last checked at, so nothing has moved
since.

| Id | Driver | Upstream state |
|---|---|---|
| `27c6:6f94` | `goodixmoc` | **never submitted.** No merge request, no issue. The id table ends at `0x6984` |
| `1c7a:05aa` | `egismoc` | **not merged.** The id table ends at `0x05a1`. [Issue #776](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/776) has been open since 2026-03-11 with no answer; [#737](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/737) was closed without the id landing |
| `10a5:9924` | `fpcmoc` | **submitted by a third party and stuck.** [MR 611](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/611) by Zeno-sole, open since 2026-06-29, `merge_status: cannot_be_merged` — it conflicts with master |
| SDCP itself | — | **not merged and not in any release.** [MR 547](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/547) has been open since 2025-10-20, is the third attempt after MRs 536 and 544, and is also `cannot_be_merged` |

So every one of these needs a local patch on every distribution, indefinitely.
That is the reason this directory exists rather than a line in an issue.

**The SDCP pin has not gone stale.** `recipe.conf` pins
`git_commit=2d7c5277de08c6b29b3fac7447f17a516fbc4d1c`; resolving the upstream
branch `feature/sdcp-v2` today returns exactly that commit, "sdcp: tweak
virtual-sdcp driver and test to work with gnome-desktop-testing-runner",
2026-04-07. The branch has not moved in four months.

### On older distribution libfprint

The `goodixmoc` patch anchors on the `0x6984` line, which does not exist in
`libfprint` 1.94.7 and older. On Ubuntu 24.04 (`libfprint 1.94.7+tod1`) it will
not apply. Wusanggg's working substitute, from
[issue #10](../../../../issues/10), is to edit `goodix.c` by hand:

* add `case 0x6F94:` to the group that sets `max_enroll_stage = 12`
* add `{ .vid = 0x27c6, .pid = 0x6F94 }` to the id table

Same two changes, applied where the file's structure differs. The installer
refuses rather than mangling the file, which is the correct behaviour; this is
the manual route when it does.

### One contradictory report about `27c6:6f94`

[andreas-fe/goodix-27c6-6f94-linux-driver](https://github.com/andreas-fe/goodix-27c6-6f94-linux-driver)
reverse-engineers the same USB id on a MagicBook Art 14 and concludes it is a
Goodix GF3268 SDCP sensor speaking TLS 1.2 PSK with AES-128-CBC and
HMAC-SHA256, where verify, identify, list and delete work through a
purpose-written driver but **enrolment does not**.

That is not what happens here: through the `goodixmoc` id-table addition,
enrolment works, and it was checked. Different code paths reach the same
silicon. Worth knowing before anybody reads that repository and concludes the
sensor cannot enrol.
