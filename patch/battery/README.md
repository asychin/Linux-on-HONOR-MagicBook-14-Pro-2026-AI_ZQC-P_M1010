# The battery charge limit that does nothing

| | |
|---|---|
| Symptom | the desktop offers a battery health / charge limit, you set it, the battery still charges to 100% |
| Cause | the EC only enforces the pairs HONOR PC Manager offers. Any other pair is stored and silently ignored |
| Fix | write one of the presets, and keep it written |

```sh
sudo bash patch/battery/install.sh                    # 70-90, the default
sudo CHARGE_PRESET="40 70"  bash patch/battery/install.sh
sudo CHARGE_PRESET="0 100"  bash patch/battery/install.sh   # remove the limit
```

## Why the desktop's own setting does not work

Nothing is missing. The in-tree `huawei-wmi` driver already exposes the limit,
GNOME and KDE already set it, and reading it back returns what you asked for:

```
$ cat /sys/devices/platform/huawei-wmi/charge_control_thresholds
75 80
$ upower -i /org/freedesktop/UPower/devices/battery_BAT0 | grep threshold
    charge-start-threshold:  75%
    charge-end-threshold:    80%
```

And the battery still sits at 100%.

The write reaches the EC. It lands in EC RAM at `0x80` (start) and `0x81`
(stop). But the EC only *arms* the limiter when the pair matches one of its
built-in profiles, and it signals that by putting the profile index in `0x85`,
mirrored in `0x87`. Measured on this machine:

| written | EC `0x80` / `0x81` | EC `0x85` / `0x87` | enforced |
|---|---|---|---|
| `75 80` | 75 / 80 | `0x00` / `0x00` | no |
| `70 90` | 70 / 90 | `0x02` / `0x02` | yes |

That is the whole mystery. `75 80` is a perfectly reasonable pair, the driver
accepts it, sysfs reports it, and the EC ignores it.

The three profiles are the ones HONOR PC Manager offers under battery
protection, and the index in `0x85` is the profile number:

| pair | EC charge mode | PC Manager calls it |
|---|---|---|
| `40 70` | 1 | 70% |
| `70 90` | 2 | 90% |
| `95 100` | 3 | 100% |
| `0 100` | 0 | no limit |

Check it yourself:

```sh
sudo modprobe ec_sys
sudo python3 -c "d=open('/sys/kernel/debug/ec/ec0/io','rb').read(0x100); \
print('start',d[0x80],'stop',d[0x81],'mode',hex(d[0x85]))"
```

`0x85` reading `0x00` after you set a limit means the limit is not in effect,
whatever sysfs says.

## What the installer does

1. Refuses a pair that is not in `presets` in this fix's own directory for that
   machine, `patch/battery/<model>/<board>/recipe.conf`, rather than writing it
   and letting it quietly do nothing.
2. Writes the pair, then **reads EC `0x85` back** and says whether the EC armed
   itself. The point of this fix is that a successful write proves nothing.
3. Installs `/etc/honor-battery.conf` and two small units that re-apply the
   pair at boot and after resume.

Step 3 is there because the desktop is the problem as much as the EC: a battery
applet that writes its own idea of a threshold will overwrite the armed pair
with an unarmed one, and the limit disappears with no visible change in the UI.

## What it does not do

It is a **charging** limit. If the battery is already above the ceiling when
you set it, it stays there and simply will not be topped up again; it does not
discharge to meet the ceiling. On this machine, the battery sat at 100% with
the limit armed and `status` reading `Not charging`, which is correct
behaviour and not a failure.

Reports from the FMB-P say its EC actively drains down to the ceiling. Ours
did not do that in an hour of observation. Same mechanism, different EC
behaviour above the ceiling; worth knowing before concluding the limit is
broken again.

## Adding a model

`presets` in `patch/battery/<model>/<board>/recipe.conf` lists the pairs that
board's EC arms for. Find them by writing a candidate pair and reading EC
`0x85`:

```sh
echo "60 80" | sudo tee /sys/devices/platform/huawei-wmi/charge_control_thresholds
sudo python3 -c "print(hex(open('/sys/kernel/debug/ec/ec0/io','rb').read(0x100)[0x85]))"
```

Nonzero means that pair works on your machine. Please put what you find in an
issue: the preset sets may well differ between models, and this list has been
measured this way on the reference machine and nowhere else. Where another
board carries it, it is inherited, and the board's own page says so.

## Credit

The preset-only behaviour was worked out by **tsukasagenesis** and **yhshzh**
on the FMB-P, in
[colorcube/Linux-on-Honor-Magicbook-14-Pro#10](https://github.com/colorcube/Linux-on-Honor-Magicbook-14-Pro/issues/10),
building on **@n7n8**'s finding that the preset byte pairs are what the EC
reacts to, and **sermart1234**'s 2022 decode of `\SBCM` in
[aymanbagabas/Huawei-WMI#55](https://github.com/aymanbagabas/Huawei-WMI/issues/55).
This directory is that mechanism confirmed independently on the ZQC-P and
wired into this repository's conventions.

---

## Does this hold on other models?

The same preset-only behaviour is reported on `FMB-P` by tsukasagenesis
(colorcube issue #10), who enumerated pairs by writing each one and reading EC
`0x85`: only `40/70`, `70/90` and `95/100` arm, as modes 1, 2 and 3, while
`60/80`, `50/80`, `40/80`, `75/80`, `70/80`, `60/90`, `40/90` and `45/70` are
stored and ignored. That is the same set and the same method as here, on a
different machine, arrived at independently.

**There is one credible contrary report.** yhshzh, also on an `FMB-P`, reports
arbitrary pairs working on their unit. Nothing here resolves it. The conservative
reading, and the one the profiles encode, is that the three presets are what you
can rely on; if arbitrary pairs happen to work on yours, nothing here stops
them.

Corroborating sightings elsewhere in the family:

* an `XWC-P` with three charge cycles reads back `start: 40% end: 70%` — one of
  the three, on a machine whose owner was not configuring UPower
* a `DRB-P` probe shows `upower` reporting `charge-start-threshold: 75%`,
  `charge-end-threshold: 80%`, `charge-threshold-supported: yes`, while the pack
  sits at 99.5% and `inxi` on the same machine in the same probe says
  `start: 0% end: 100%`. That is this exact bug, seen from outside
* a `BCC-N` probe reports `charge-threshold-enabled: yes`, which is a stronger
  claim than the others make. Which pairs its EC honours is unmeasured

No board gets a `presets` line until somebody has run the
write-and-read-EC-`0x85` test on it. It is two commands, in
[docs/TESTING.md](../../docs/TESTING.md#4-the-battery-limit).

> One script in the wild, `laeo/Honor-XWC-Linux-Patch`'s `battery-limit.sh`,
> defaults to writing `75 80` — the pair this page exists to explain. If you
> are using it, that is why nothing changed.
