# Internal keyboard and the Caps Lock LED

| | |
|---|---|
| Status | **merged upstream.** In Linux **7.2**; queued for **7.1.10** |
| Commit | [`410c44b10967`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=410c44b1096789d0c40fbee706520e981dba7bc1) |
| Author | Donglin Lyu, not this repository |
| Replaces | `i8042.dumbkbd=1` |
| Needs | nothing, on a kernel new enough |

**On Linux 7.2 or 7.1.10 and later there is nothing to do here.** Drop
`i8042.dumbkbd=1` and the Caps Lock LED comes back; see
[removing the parameter](#removing-the-parameter) below.

This directory stays for people on older kernels, and as the record of what the
parameter was working around. It holds a copy of the upstream patch. There is
no installer, because the fix cannot be applied without rebuilding the kernel.

## The problem

The internal keyboard does not work after boot. `apply_patch.sh` works around
it with `i8042.dumbkbd=1` on the kernel command line, which makes the keyboard
usable at the cost of the Caps Lock LED: the parameter disables atkbd's
`SET_LEDS` path, so the keyboard input device comes up without `EV_LED` and no
LED class devices are created for it.

## The fix

`atkbd.c` already carries a `atkbd_deactivate_fixup` quirk for machines whose
firmware breaks when `atkbd_deactivate()` runs at probe:

```c
	if (!atkbd_skip_deactivate)
		atkbd_deactivate(atkbd);
```

The patch adds ZQC-P to the DMI table that sets that flag. The table already
contains `HONOR / FMB-P` and `HONOR / BCC-N`, the sibling models, so this is the
third entry of an established pattern rather than a new mechanism.

With the quirk in place the keyboard works with **no boot parameters at all**,
and the Caps Lock LED comes back.

## Where it landed

Commit `410c44b1096789d0c40fbee706520e981dba7bc1`, "Input: atkbd - skip
deactivate for HONOR ZQC-P", authored 2026-08-02 and applied by Dmitry Torokhov
with the note `[dtor: keep all HONOR entries together]`. It carries
`Cc: stable@vger.kernel.org`, and `Tested-by: Ruslan Shevchenko
<adefka@gmail.com>` — the testing recorded further down this page.

* **Linux 7.2** has it. Verified absent from 7.1, present in 7.2.
* **7.1.y**: `stable-queue.git` holds
  `queue-7.1/input-atkbd-skip-deactivate-for-honor-zqc-p.patch`, added
  2026-08-20 and listed in `queue-7.1/series`, so **7.1.10** is the first 7.1
  release with it. 7.1.9, released 2026-08-19, does **not** have it.

> Patchwork still shows the submission
> ([20260801151115.52709-1-donglin_lyu@outlook.com](https://patchwork.kernel.org/project/linux-input/patch/20260801151115.52709-1-donglin_lyu@outlook.com/))
> as state "new", and the same is true of the BCC-N patch whose commit shipped in
> 7.1. The `linux-input` tracker is not kept in sync with the tree. Check git.

The table now has four HONOR entries: `FMB-P` (6.19, and `FMB-PM` with it,
because `DMI_MATCH` is a `strstr`), `BCC-N` (7.1) and `ZQC-P` (7.2). `XWC-P` is
the one MagicBook still missing from it.

## Verified on this unit

Built into `linux-cachyos 7.1.5` and booted without `i8042.dumbkbd=1`.

| | stock kernel with `dumbkbd` | patched kernel |
|---|---|---|
| keyboard `EV` mask | `0x100013`, no `EV_LED` | `0x120013`, `EV_LED` present |
| `Handlers` | `sysrq kbd event2` | `sysrq kbd leds event2` |
| LED class devices | none | `input2::capslock`, `input2::numlock`, `input2::scrolllock` |
| Caps Lock LED | dark | works |
| key repeats, dropouts | none | none |

Everything else on the machine was unaffected: touchpad, touchscreen, audio,
the mic-mute chain and the fan tachometers all behaved identically.

DMI of the tested unit, identical to the patch author's:

```
sys_vendor     HONOR
product_name   ZQC-P
board_name     ZQC-P-PCB
bios_version   1.09
bios_date      03/19/2026
```

## Why there is no installer

`CONFIG_KEYBOARD_ATKBD=y` in the CachyOS kernels, so `atkbd` is built into the
kernel image and cannot be replaced with a module overlay the way
[`../headset-mic/`](../headset-mic/) and [`../sof-audio/`](../sof-audio/) are.
Applying the patch means rebuilding the kernel package, and repeating that after
every kernel update.

That is not worth it for a dark LED, so `apply_patch.sh` keeps
`i8042.dumbkbd=1`.

## Removing the parameter

On 7.2 or 7.1.10 and later, the quirk is in your kernel and the parameter is
just costing you the LED:

```sh
sudo sed -i 's/ i8042\.dumbkbd=1//' /etc/default/limine
sudo limine-update
reboot
```

Then confirm the quirk is active rather than silently missing:

```sh
grep -c i8042.dumbkbd /proc/cmdline     # 0
ls /sys/class/leds/ | grep capslock     # input2::capslock
```

If the keyboard misbehaves after removing the parameter, your kernel does not
carry the quirk yet. Put it back the same way.

Or check before rebooting, without guessing at version numbers:

```sh
zgrep -c 'HONOR.*ZQC-P' /proc/config.gz 2>/dev/null   # not in the config
strings /boot/vmlinuz-* | grep -c ZQC-P               # 1 if the quirk is there
```

## Rebuilding a kernel with it yourself

Only needed below 7.1.10.

```sh
git clone --depth 1 https://github.com/CachyOS/linux-cachyos
cd linux-cachyos/linux-cachyos
cp .../patch/keyboard-atkbd/0001-Input-atkbd-skip-deactivate-for-HONOR-ZQC-P.patch .
# add the file name to source=() in the PKGBUILD, then
_use_current=yes makepkg -s --skipchecksums --skippgpcheck
```

Two things that cost time when this was done here:

- give the package a distinct `_pkgsuffix` so it installs **alongside** the
  distro kernel instead of replacing it, and give the resulting entry its own
  command line through `KERNEL_CMDLINE[<kernel-id>]` in `/etc/default/limine`
  so only that entry drops `i8042.dumbkbd=1`;
- `_localmodcfg=yes` cuts the build time a lot but drops modules that are not
  loaded right now, and `mkinitcpio` then fails with `module not found:
  'overlay'`. Seed the module list from the working initramfs first:

  ```sh
  lsinitcpio /boot/*/linux-cachyos/initramfs \
    | grep -oP 'modules/[^/]+/kernel/.*?/\K[^/]+(?=\.ko)' | tr '-' '_' \
    | sort -u >> ~/.config/modprobed.db
  ```
