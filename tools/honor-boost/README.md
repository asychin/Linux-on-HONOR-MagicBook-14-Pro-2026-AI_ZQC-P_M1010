# HONOR boost — Linux reverse-engineering tooling

Tooling used to find how HONOR Turbo X raises the package power budget on ZQC-P
and to measure whether it matters. This is **not** a shipped fix and is **not**
installed by `apply_patch.sh`; it exists to document and reproduce the
experiments behind `boost-refactoring.md`.

## What was found (short version)

Turbo X is a whole-package power-budget release plus a CPU frequency bias:

- `\_SB.IETM.IMOK` (SSDT18) sets the EC `DTTF` flag (`ECF0 0x52` bit 7).
- A few seconds later the EC firmware raises its own power-budget registers
  `PP1R`/`PP2R` (`ECF6 0xC2`/`0xC3`) from the **40 W / 50 W** default to the
  **88 W** ceiling (`0x58`).
- The DTT software layer then applies `PL1 65 W` + `EPP 63` (CPU frequency).
- The `SVRF` rails (`VCCC`/`VCCG`/`VCCS`/`VCCL`) read `0xFF` at boot and are a
  red herring; MMIO RAPL sysfs is ignored by the hardware.

**Measured result: it does not help.** Clean A/B with `stress-ng --cpu 16`
(default budget vs 88 W vs 88 W + TCC-offset 0) gave `29486` / `29296` /
`29198` bogo-ops/s — noise. Package power sits at ~50 W in every case because
the CPU hits the 97 °C thermal throttle first; the cooling system, not the
firmware, is the limit. There is no OS-side fan-speed control either (see
`patch/fan/README.md`).

## Files

- `honor-ec-rail.c` + `Makefile` — module that ioremaps the EC banks
  `ECF0/ECF3/ECF5/ECF6` and exposes them read-only under
  `/sys/kernel/honor-ec-rail/`: `crwm`, `ec_cpu_temp`, `fan0/1`, `svft`,
  `ftsl`, `fwmd`, `scpm`, the `vccc`-family rails, `odp0..9`, `dttf`,
  `pp1m/pp1r/pp2r/pp4r/ppp1/ppp2`, and VR telemetry. `pp1r`/`pp2r`/`pp4r`
  are additionally **writable** (hex) so the budget can be restored to its
  Smart default after an `IMOK` experiment, since no ACPI method writes them.
- `setup.sh` — builds `honor-ec-rail.ko` and fetches/builds `acpi_call.ko`.
- `read-state.sh` — dump the boost-relevant EC state.
- `measure-power.sh` — average package power (RAPL `energy_uj`) over N seconds.
- `monitor.sh` — continuous CSV logger (package/core/uncore/psys power, temp,
  fan RPM).
- `nspin.c` — non-AVX integer all-core load (reaches the power limit; AVX
  `spin.c` downclocks and draws less).
- `svrf-test.sh` — gated `\SVRF` unlock/restore harness (kept for completeness;
  the rails turned out to be a no-op).

## Setup

```sh
sudo bash tools/honor-boost/setup.sh          # builds honor-ec-rail.ko + acpi_call.ko
sudo insmod tools/honor-boost/honor-ec-rail.ko
sudo insmod tools/honor-boost/acpi_call/acpi_call.ko
sudo bash tools/honor-boost/read-state.sh     # dump current state
```

## Reproducing the key experiments

Raise the budget and watch `PP1R`/`PP2R` move (writes to the EC via the module):

```sh
# enable DTT — the EC raises PP1R/PP2R 40/50 -> 88 W after a few seconds
echo '\_SB.IETM.IMOK 1' > /proc/acpi/call
cat /sys/kernel/honor-ec-rail/pp1r /sys/kernel/honor-ec-rail/pp2r   # 58 58

# restore the Smart default (only via the module write path)
echo 28 > /sys/kernel/honor-ec-rail/pp1r
echo 32 > /sys/kernel/honor-ec-rail/pp2r
```

Measure the (lack of) effect with a proper CPU load:

```sh
gcc -O2 -pthread -o nspin nspin.c
./nspin &                                     # non-AVX all-core load
sudo bash tools/honor-boost/measure-power.sh 10
kill %1
```

## Safety

- Only `\SVRF`, `\IFCI`, `\STUB`, `\IMOK`, `\SODP`, `\GODP`, `\GPPT`, `\GVRF`,
  `\GTUB`, `\GFCI` are ever called through `acpi_call` — no raw `/dev/mem`.
- The `pp1r`/`pp2r`/`pp4r` sysfs writes bypass the EC firmware; use them only
  to *restore* the Smart default (`28`/`32`/`a0`), not to raise the budget.
- `\IFCI 0xAC` disables the fans entirely; do not select it.
- `IMOK` (`DTTF=1`) and a raised `PP1R`/`PP2R` are sticky until reboot; reboot
  to fully reset the EC to its 40 W / 50 W default.
