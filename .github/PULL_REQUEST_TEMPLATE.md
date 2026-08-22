## What this changes

<!-- One paragraph. What was broken or missing, and what this does about it. -->

## Why this way

<!-- The reasoning matters more than the diff here. What did you measure? What
     did you try that did not work? If the obvious approach was rejected, say
     why, so nobody re-derives it later. -->

## Tested on

| | |
|---|---|
| Model (`product_name`) | |
| BIOS version | |
| Distribution | |
| Kernel | |

<!-- If you could not test something, say so plainly. That is useful
     information, not a defect in the pull request. -->

## Checklist

- [ ] `bash tools/selftest.sh` passes. It needs no root, no hardware and no network.
- [ ] The installer is idempotent: running it twice is a no-op the second time.
- [ ] It refuses to run as a non-root user, or does not need root at all.
- [ ] It gates on the hardware it touches, by DMI or by device id.
- [ ] Anything it overwrites is backed up first, and the backup path is printed.
- [ ] Kernel modules go to `/usr/lib/modules/$KVER/updates/`, never into `kernel/`.
- [ ] There is a way to undo it, and `uninstall_patch.sh` knows about it.
- [ ] The directory `README.md` records the reasoning, not just the recipe.
- [ ] Measured values and inferred values are distinguishable in the text.
- [ ] If this touches a device profile: the profile is data only, and the reasoning went into `docs/hardware/<model>.md` with a source.
- [ ] If this adds or changes a fix: `patch/README.md` says where it stands upstream, and upstream was checked first.
