# The faint band that follows the mouse cursor

| | |
|---|---|
| Symptom | a wide, faint, darker band across the whole width of the screen, trailing the pointer as it moves up and down |
| Cause | PSR2 selective update refreshes a range of scanlines, and the hardware can only address that range by line number, so every partial update is full width |
| Fix | limit Panel Self Refresh to PSR1, which has no partial updates |
| Needs | one kernel parameter, no reboot to test, no module, no rebuild |

## What it looks like

Move the pointer slowly up and down over a large flat area, a plain grey or
dark window. A band the full width of the screen follows it, slightly darker
than its surroundings, with soft edges. It sits behind the direction of travel,
so it is under the cursor going up and above it going down. It is easy to miss
on a busy screen and impossible to un-see on a flat one.

It comes and goes between boots, which is the first clue: the panel is not
faulty, some piece of state is.

## Not the backlight

The obvious suspect is [`patch/oled-backlight`](../oled-backlight/), which
replaces the VBT the display driver reads. It is not that. The installed blob
differs from the factory one in exactly two bytes:

```
$ cmp -l /var/lib/honor/vbt-factory.bin /usr/lib/firmware/honor/zqc-p-vbt.bin
offset 3772 (0xebc): 6 -> 12      brightness_min_level[2]
offset 3957 (0xf75): 6 -> 12      the legacy per-entry min_brightness
```

Both are the backlight floor, one number applied to the whole panel at once. No
value in that file is a function of screen position, so it cannot draw a band.

## What it actually is

`i915_psr_status` for the internal panel, before the fix:

```
Sink support: PSR = yes [0x03], Panel Replay = no
PSR mode: PSR2 enabled
Source PSR/PanelReplay ctl: enabled [0x8000e356]
Source PSR/PanelReplay status: DEEP_SLEEP [0x80310030]
PSR2 selective fetch: enabled
```

Panel Self Refresh lets the panel hold the last frame in its own memory so the
display engine can stop sending. PSR2 adds *selective update*: instead of
sending a whole new frame, send only the part that changed. The driver works
out that part from the damage rectangles of each plane, and the mouse pointer
is a plane of its own:

```
[PLANE:145:cursor A]: type=CUR
	hw: [FB:552] AR24 little-endian, 64x64, visible=yes, dst=64x64+1813+1276
```

The catch is what "part of the frame" can mean to the hardware. It is not a
rectangle. From `psr2_granularity_check()`:

```c
	/* PSR2 HW only send full lines so we only need to validate the width */
	if (crtc_hdisplay % sink_w_granularity)
		return false;

	if (crtc_vdisplay % sink_y_granularity)
		return false;
```

and the two registers that carry the region hold scanline numbers and nothing
else:

```c
	val |= ADLP_PSR2_MAN_TRK_CTL_SU_REGION_START_ADDR(crtc_state->psr2_su_area.y1);
	val |= ADLP_PSR2_MAN_TRK_CTL_SU_REGION_END_ADDR(crtc_state->psr2_su_area.y2 - 1);
```

So a selective update is a horizontal slice of the frame, `y1` to `y2`, always
running the entire width. A 64 by 64 cursor moving down the middle of the
screen produces a 3120 pixel wide band, and that band is the thing you can see.

Two more details explain its exact shape. The damaged areas of all planes are
merged into one range, so a cursor that has moved covers both the old position
and the new one:

```c
	if (damage_area->y1 < overlap_damage_area->y1)
		overlap_damage_area->y1 = damage_area->y1;

	if (damage_area->y2 > overlap_damage_area->y2)
		overlap_damage_area->y2 = damage_area->y2;
```

which is why the band is taller than the cursor and lags behind it. And the
range is then rounded outward to the granularity the panel declared:

```c
	if (crtc_state->psr2_su_area.y1 % y_alignment) {
		crtc_state->psr2_su_area.y1 -= crtc_state->psr2_su_area.y1 % y_alignment;
		su_area_changed = true;
	}

	if (crtc_state->psr2_su_area.y2 % y_alignment) {
		crtc_state->psr2_su_area.y2 = ((crtc_state->psr2_su_area.y2 /
						y_alignment) + 1) * y_alignment;
		su_area_changed = true;
	}
```

which is why its edges land on fixed lines rather than following the pointer
smoothly.

None of that is a bug on its own. The bug is that on this panel the band is
*visible*: the lines that were just re-sent do not come out at quite the same
luminance as the lines the panel is still driving out of its own frame buffer.
The panel agrees that something is wrong with what it is being sent. Its own
error latch, read back while the band was on screen:

```
Sink PSR status:       0x2 [active, display from RFB]
Sink PSR error status: 0x1: PSR Link CRC error
```

and the driver had already given up on the area calculation once during boot:

```
xe 0000:00:02.0: [drm] Selective fetch area calculation failed in pipe A
```

which is `drm_info_once` from the fall back to a full update when `y1` is still
-1, sitting under a comment that says the calculation is known to be wrong in
cases nobody has enumerated:

```c
	/*
	 * TODO: For now we are just using full update in case
	 * selective fetch area calculation fails. To optimize this we
	 * should identify cases where this happens and fix the area
	 * calculation for those.
	 */
	if (crtc_state->psr2_su_area.y1 == -1) {
		drm_info_once(display->drm,
			      "Selective fetch area calculation failed in pipe %c\n",
```

## Measured on the reference unit

`/sys/kernel/debug/dri/0000:00:02.0/i915_edp_psr_debug` switches PSR mode at
run time with no reboot and no config change, so the three states can be
compared back to back in one sitting. `1` is `I915_PSR_DEBUG_DISABLE`, `3` is
`I915_PSR_DEBUG_FORCE_PSR1`, `0` is the driver's own choice.

| | psr_debug | resulting mode | band | sink error latch |
|---|---|---|---|---|
| A | 1 | PSR disabled | **no** | n/a |
| B | 3 | PSR1 enabled | **no** | `0x0` |
| C | 0 | PSR2 enabled, selective fetch | **yes** | `0x1 PSR Link CRC error` |

C was run last, on purpose: the band came back. Without that the first two
stages would only show that it had gone away, which is not the same thing.

Stage B is the one worth having. PSR still works, the panel still holds the
frame while the screen is idle, and there is no partial update for the band to
be made of. Watched for the flicker on PSR entry and exit that PSR1 is known
for on some panels, and there is none on this one.

## The fix

```
xe.enable_psr=1        # 0 = off, 1 = up to PSR1, 2 = up to PSR2
```

This is not merely similar to stage B, it is the same code path. The parameter
is checked at the top of `intel_psr2_config_valid()`:

```c
	if (!connector->dp.psr_caps.su_support || display->params.enable_psr == 1)
		return false;
```

and the debugfs force is checked in `sel_update_global_enabled()`:

```c
	switch (intel_dp->psr.debug & I915_PSR_DEBUG_MODE_MASK) {
	case I915_PSR_DEBUG_DISABLE:
	case I915_PSR_DEBUG_FORCE_PSR1:
		return false;
	}
```

Both are consulted by `intel_sel_update_config_valid()`, and a `false` from
either jumps to the same label:

```c
unsupported:
	crtc_state->enable_psr2_sel_fetch = false;
	return false;
```

So what was tested at run time is what the parameter produces at boot, with no
inference in between.

```sh
sudo bash patch/psr-band/install.sh
```

The installer reads the driver actually bound to the display and writes
`xe.enable_psr=1` or `i915.enable_psr=1` accordingly, refuses to guess if
neither is there, and stops without touching the command line if the machine is
not in PSR2 to begin with. It also applies the change to the running session,
so the band goes away before the reboot rather than after it.

`PSR_LEVEL=0` turns PSR off entirely. That is stage A, and it is only worth
reaching for if PSR1 itself misbehaves on your panel.

## Verifying after reboot

```sh
# 1. the parameter reached the driver
cat /sys/module/xe/parameters/enable_psr          # expect 1

# 2. the display engine agrees
sudo grep -E '^PSR mode|selective fetch' /sys/kernel/debug/dri/*/eDP-1/i915_psr_status
    expect: PSR mode: PSR1 enabled
    and no "PSR2 selective fetch" line at all

# 3. the panel has stopped complaining
sudo cat /sys/kernel/debug/dri/*/eDP-1/i915_psr_sink_status
    expect: Sink PSR error status: 0x0
```

## What this costs

PSR1 still stops the display engine while the screen is static, which is where
almost all of the saving is. What is given up is PSR2's extra saving on small
updates, a blinking text cursor being the standard example.

**This has not been measured here.** Putting a number on it means holding the
machine at a controlled idle for long enough on each setting to read
`/sys/class/power_supply/BAT*/power_now` without the desktop's own activity
swamping the difference, and that has not been done. Intel's own figure for the
selective update saving over PSR1 is small compared to the PSR1 saving over no
PSR at all, but do not take a number from this file that is not in it.

## Approaches that were ruled out

**`xe.enable_psr2_sel_fetch=0`.** Reaches almost the same place: with selective
fetch refused and no hardware tracking on this display generation,
`intel_sel_update_config_valid()` takes the `unsupported` label and PSR drops
to PSR1. It is one more parameter for the same result through a longer route,
and it is not the one that was measured, so it is not the one that is shipped.

**`xe.enable_psr=0`.** Works, stage A above, and gives up the panel self
refresh entirely for a problem that only exists in the selective update part of
it. Available as `PSR_LEVEL=0` for anyone whose panel needs it.

**A DPCD quirk.** `dpcd_quirk_list[]` in `drm_dp_helper.c` is where "this
specific panel's DisplayPort implementation is broken" belongs, and it carries
`DP_DPCD_QUIRK_NO_PSR` already. That is the right shape for an upstream fix,
but the existing quirk is all-or-nothing: it would take PSR away rather than
step it down to PSR1, which is more than this panel needs. Proposing a narrower
quirk means first pinning down whether the fault is the panel's or the area
calculation's, and that is not settled here.

**Waiting for a driver fix.** The comment quoted above says the area
calculation is known to be incomplete, and selective fetch has been disabled
wholesale on earlier platforms before, for flickering reproduced by moving the
cursor. Something may well land. Until it does, this is a parameter, not a
patch, and it costs nothing to drop later.

## What was ruled out as a cause

**Framebuffer compression.** Off, and off *because* of selective update, so it
cannot be the source:

```
FBC disabled: Selective update enabled
```

**Variable refresh rate.** Not in use on the internal panel: `vrr_range` reads
`Min: 0  Max: 0`, and the mode is a fixed 120 Hz.

**Panel Replay.** The sink does not support it, so the driver is not using it:
`Panel Replay = no, Panel Replay Selective Update = no`.

**The backlight.** Two bytes, both the floor, shown above.

## An unrelated thing found while looking

The panel is being driven at **6 bits per colour with dithering**:

```
adjusted_mode="3120x2080": 120 900864 3120 3332 3336 3400 2080 2202 2203 2208
pipe src=3120x2080+0+0, dither=yes, bpp=18
port_clock=540000, lane_count=4
```

`bpp=18` is 6 bits per component. The link is at HBR2 on 4 lanes, which carries
17.28 Gbit/s of payload; this mode needs 16.22 Gbit/s at 6 bpc and 21.62 at 8,
so 8 bpc does not fit and the driver dropped to 6 and turned on dithering. The
panel advertises Display Stream Compression, which is exactly the way out, and
it is not being used:

```
DSC_Enabled: no
DSC_Sink_Support: yes
DSC_Output_Format_Sink_Support: RGB: yes
DSC_Sink_Max_Slice_Count: 4
```

This is a separate defect with its own consequences, and it is tracked
separately rather than being folded in here. It is mentioned because dithering
noise on flat areas is part of why the band was visible enough to notice: the
band is a PSR2 artefact either way, but a panel running at its full bit depth
hides it better.

## Files

| file | |
|---|---|
| [`install.sh`](install.sh) | detect the driver, check the machine is in PSR2, set the parameter, apply it live |
| [`uninstall.sh`](uninstall.sh) | drop the parameter and hand selective update back |

## Sources

* `drivers/gpu/drm/i915/display/intel_psr.c`, Linux v7.1.8, the release this
  was measured on. All quotes above are from that file:
  `psr2_granularity_check()`, `intel_psr2_sel_fetch_pipe_alignment()`,
  `clip_area_update()`, `intel_psr2_sel_fetch_update()`,
  `intel_psr2_config_valid()`, `sel_update_global_enabled()`,
  `intel_sel_update_config_valid()`, `psr2_program_man_trk_ctl()`.
* [drm/i915/psr: Disable PSR2 selective fetch for all TGL steps](https://lkml.kernel.org/lkml/89b5f3210a3f3e9c629967890090b21a94749f0a.camel@intel.com/T/)
  — the precedent: selective fetch turned off across a whole platform for
  flickering, reproduced by moving the cursor.
* [Fixes for selective fetch area calculation](https://yhbt.net/lore/all/c4876757329baa66a7846bb9832743aac9149286.camel@intel.com/T/)
  — the area calculation has been corrected more than once.
* [drm/i915: Implement PSR2 selective fetch](https://lists.freedesktop.org/archives/intel-gfx/2020-June/242071.html)
  — the original series, for how the software tracking is meant to work.
* [asus-expertbook-linux](https://github.com/burakgon/asus-expertbook-linux) —
  another Panther Lake laptop, a different PSR failure on the same driver
  (`Timed out waiting PSR idle state`, panel lockups), worked around with
  `xe.enable_psr=0 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0`. Useful
  as confirmation that this driver and this display generation have more than
  one PSR problem, and as a reminder that the blunt version of this fix is what
  people reach for first.
