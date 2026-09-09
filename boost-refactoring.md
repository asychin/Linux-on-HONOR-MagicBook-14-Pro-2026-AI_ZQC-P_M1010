# HONOR Turbo X / NPU boost reverse-engineering notes

Goal: understand how HONOR PC Manager enables the Turbo X high-performance mode on ZQC-P (officially up to 80 W for the Ultra X9-388H model) and implement an equivalent on Linux.

## Summary — read this first

**The mechanism is found, but it is useless on this hardware.** Turbo X is a whole-package power-budget release plus a CPU frequency bias, not a GPU or NPU overclock, and on ZQC-P the cooling system caps sustained CPU power at ~50 W before any of it matters.

- **How it works (reverse-engineered):** Windows DTT calls `\_SB.IETM.IMOK`, which sets the EC `DTTF` flag (`ECF0 0x52` bit 7). A few seconds later the EC firmware raises its own power-budget registers `PP1R`/`PP2R` (`ECF6 0xC2`/`0xC3`) from the 40 W / 50 W default to the 88 W ceiling (`0x58`). On top of that, the DTT software layer sets `PL1 65 W` and `EPP 63` (CPU frequency bias). The `SVRF` "rail" registers (`VCCC`/`VCCG`/`VCCS`/`VCCL`) are already `0xFF` at boot and are a red herring; the MMIO RAPL sysfs is ignored by the hardware; `STUB`/`CRWM` only flips the mode signal.
- **Does it help? No.** Clean A/B with `stress-ng --cpu 16` on the M1020: default budget `29486` bogo-ops/s, boosted `29296`, boosted + TCC-offset 0 `29198` — all noise. Package power sits at ~50 W in every case because the CPU hits the 97 °C thermal throttle first. The Notebookcheck review already showed Performance gives a negligible CPU gain while getting much louder.
- **Fans and throttling:** there is no OS-side fan-speed control on this machine — `SFNS` is gated on the EC `MFGM` flag (never set by any firmware path), the MagicBook Art 14 `WTER` route does not exist, and the only lever is the `IFCI` fan-table selector (`FTSL`), which shifts the engagement threshold, not the maximum RPM. The thermal-throttle point is the writable **TCC offset** (`/sys/class/thermal/cooling_device24/cur_state`, default 3 → throttle at 97 °C; 0 → 100 °C), but lowering it to 0 gained nothing because cooling is the real limit. See `patch/fan/README.md` and `tools/honor-boost/README.md`.
- **Tooling:** `tools/honor-boost/` holds the read-only(+writable PP) `honor-ec-rail` module (ioremap of the EC banks, `/sys/kernel/honor-ec-rail/`), the `acpi_call` build, and load/measure scripts. It exposes `VCCC`-family rails, `ODP0..9`, `DTTF`, `PP1R/PP2R/PP4R/PP1M`, and the fan/temp telemetry.

The detailed chronology and per-experiment evidence follow below; the sections are working notes in the order they were produced.

## What we know

- The NPU on ZQC-P is Intel NPU 5 (`8086:b03e`). It is driven by `intel_vpu` and used through OpenVINO/Level Zero. It has no separate "boost" control; it already pins to `2050 MHz` when loaded. See `docs/NPU.md`.
- HONOR's official Chinese page for the ZQC-P generation (MagicBook Pro 14 2026 with Ultra X9-388H) specifies up to approximately **80 W whole-system performance release**, enabled through Fn+P or PC Manager while connected to AC. The previously cited 115 W burst figure belongs to the older Ultra 9-285H MagicBook Pro 14 and must not be applied to ZQC-P.
- `WMAA` is the HONOR WMI dispatcher in `dump/win11/zqc-p/OEM/SSDT21.dsl`, device `\_SB.WMI1`, `_UID "HWMI"`.
- `MFID 0x07` contains the performance / thermal methods:
  - `SFID 0x0F` → `SVRF` (set rail power limits and `PPL4`)
  - `SFID 0x0D` → `SPPM` (set `SCPM` mode)
  - `SFID 0x08` → `IFCI` (select fan table)
- `SVRF` in `DSDT.dsl` writes to EC: `VCCC`, `VCCG`, `VCCS`, `VCCL`, `PPL4`, `SVFT`. Values `0x01..0x33` = 1..51 W; `0xFF` = unlock. `PPL4` is a peak limit.
- `SPPM` writes `SCPM` (ECF5 `0x32`) — system CPU performance mode `0..3`. On the reference M1010 it had no observable effect on clocks, and current PC Manager binaries contain no direct `SPPM` caller for the ZhuqueC path.
- `IFCI` selects the fan table in `FTSL` (ECF5 `0x30`). Stock is `0xA0`; `0xAB` engages earlier; `0xAC` stops the fans. See `patch/fan/README.md`.

## What "intelligent Turbo X" means

- Official ZQC-P source: [HONOR MagicBook Pro 14 2026](https://www.honor.com/cn/laptops/honor-magicbook-pro-14-2026/). Its footnote specifies approximately 80 W for the X9-388H configuration, not 115 W. Reports of 88 W refer to the Pro 14/16 series maximum and do not override the model-specific Pro 14 footnote.
- HONOR markets Turbo X as an AI-assisted, system-wide performance/efficiency engine that recognizes workloads and coordinates hardware, the OS, and applications. Intel publicly describes the underlying collaboration as using Intel DTT, HGS, and IPF.
- Local implementation confirms that this is not conventional CPU multiplier overclocking. `HSPPPlugin.dll` monitors the foreground process, scene ID, AC/battery state, CPU load, GPU 3D/video load, system load level, and other state. It chooses named strategies such as `BALANCE_AC_DEFAULT_3` and `PERFORMANCE_AC`, then applies a bundle of PL1/PL2, EPP, Intel DTT ITM/EPO policy IDs, `commandPL4`, fan-table, GPU-frequency, power-plan, and related controls.
- There is a real optional AI path: the binary contains `SceneStrategy::OnRecvAiMsg`, `ModelControl`, `HSPPToAI_MachineConfig.dat`, `isAiControl`, `aiRcvProcName`, and messages saying some power scenes are AI-only. This proves an AI-policy interface exists, but does **not** prove that the NPU performs the reasoning or that AI was active during our capture.
- The AI path was located in signed HONOR Java components: `AwarenessDecision`/`PcAwareness.jar` collect CPU/GPU load, GT/package-limit events, PL1/EPP, foreground process, scene, frame rate, battery, brightness, camera, keyboard/mouse activity, and stuck events. `BrainDecision`/`Brain.jar` contains `PcPowerOptModel` and `OptIntelHandler`.
- `PcPowerOptModel` is a lightweight personalized statistical model, not an NPU neural network: it reads historical samples from SQLite, groups them by scene and strategy, saves a serialized `Map`, and `infer()` reads that map. Its `eval()` literally returns `0`. `OptIntelHandler` applies rule/fence logic with 15- and 30-second periods. Generic FTRL and CART implementations also exist in `Brain.jar`, but no evidence links them to the Turbo mode path.
- No OpenVINO, ONNX, DirectML, Level Zero, `intel_vpu`, NPU inference libraries, or NPU model files were found in the HONOR PC Manager/BasicService installation. The power "AI" executes in Java/CPU processes; no NPU participation is evidenced.
- `PerformancePredictionModel.xml` is also threshold configuration rather than a learned model: it contains polling intervals and CPU/GPU/memory thresholds for UI warnings/optimization prompts.
- Other real HSPP controls found in native code include scene-specific PL1/PL2 and EPP, DTT EPO/ITM IDs, Windows PPM parameters, iGPU min/max frequency, dGPU overclock, PPAB, dynamic P-state, battery boost, power-plan/overlay selection, CPU affinity/background control, and smart-fan selection. In the captured ZhuqueC default strategies, iGPU frequency overrides and dGPU overclock were zero/disabled.
- In the captured Performance transition, `isAiControl=0`; the deterministic scene engine selected `PERFORMANCE_AC`. During a later passive game run in Smart mode, scene IDs `15` and `9` were recognized, but the selected policy remained `BALANCE_AC_DEFAULT_3` and repeated evaluations were skipped as unchanged.
- Therefore "intelligent overclock" is best understood as dynamic OEM power/thermal/workload policy selection, not a separate NPU boost and not necessarily frequency overclocking beyond Intel specifications.
- Power figures are easy to conflate for this model: it ships with a 100 W USB-C adapter and supports up to 80 W reverse charging; HONOR advertises 88 W for the wider Pro 14/16 series, while the model-specific Pro 14 X9-388H footnote says 80 W. The older 285H model advertised a 115 W burst. No independent X9-388H/ZQC-P measurement above 100 W was found.
- The available independent Notebookcheck review uses the lower Ultra 5-338H SKU, not X9. On Windows it measured a 65 W short CPU-package burst and about 50 W sustained. Its Performance mode gave only a small CPU multi-core gain over Smart while increasing noise from 42.9 to 53.6 dB(A); this cannot be assumed to quantify the X9/B390 gaming difference.

## Linux parity status

- The current repository fixes hardware compatibility; they do not reproduce HONOR Turbo X. The fan module is read-only, and the performance hotkey only cycles standard `power-profiles-daemon` profiles.
- On the measured M1010 Linux system, selecting `platform_profile=performance` still left the EC-enforced package limit at approximately 50 W. The advertised RAPL constraints did not override `VCCC`; sustained all-core clocks settled around 3.3 GHz.
- Therefore Linux does not automatically receive the complete Windows Performance-mode behavior from the current fixes. Windows additionally performs the `STUB`/`CRWM` switch, unlocks EC rail limits with `SVRF`, selects DTT ITM/EPO policies, and coordinates fan and other controls.
- Reverse-engineering remains useful, but the realistic target is parity with the model's roughly 80 W whole-system mode, not a presumed 115 W package mode. The likely benefit is workload-dependent: limited for some CPU-only work, potentially more important in combined CPU+iGPU gaming where both share package and cooling headroom.
- Do not apply the rail-unlock payload alone as a final solution. Windows couples it with DTT and cooling policy; a Linux implementation needs equivalent thermal monitoring, a reversible Smart/Performance transition, and measurement with `turbostat`/RAPL/fan RPM under matched workloads.

## Linux rail/power-cap measurements (2026-09-09, M1020)

A read-only `ioremap` module (`tools/honor-boost/honor-ec-rail.c`) now exposes the extended EC banks under `/sys/kernel/honor-ec-rail/`, so the rails are directly observable for the first time. It was validated against the firmware getters: `GTUB`→`CRWM`, `GFCI`→`FTSL`, `GVRF`→`PPL4`/`VRSS`/`GFF0` all agree (GVRF returned `PPL4=0`, `VRSS=0x0F`, `GFF0=0xC7DD`, matching the Windows capture).

- At a cold Linux boot the rails already read `VCCC=VCCG=VCCS=VCCL=0xFF`, `PPL4=0`, `SVFT=0`, `FTSL=0xA0`, `CRWM=0`. The `SVRF` "rail unlock" is therefore a no-op on this unit — the rails are not what caps the package. This contradicts the fan README's claim that the ~50 W cap is enforced through `VCCC`.
- The real default budget is MMIO RAPL: `intel-rapl-mmio:0` shows `PL1=40 W`, `PL2=50 W`, while the MSR `intel-rapl:0` advertises 88 W. The effective cap is the MMIO value.
- Under a 16-thread all-core FMA load (4 P-cores @5.1 GHz, 8 E @4.0, 4 LP @3.7), package power settled at ~35 W, all cores 100% busy at ~3.4 GHz.
- Individually raising the MMIO RAPL to `PL1=65/PL2=80 W` and separately setting `STUB`/`CRWM=1` produced **no** change in package power. No single register (rail, MMIO RAPL, or `CRWM`) lifts the cap.
- The loaded kernel stack (`processor_thermal_mbox`, `processor_thermal_rfim`, `processor_thermal_power_floor`, `intel_pmc_core`) points to Intel DPTF/DTT as the coordinating mechanism. Windows Performance's PL1 65-70 W is applied through DTT policies, not through `SVRF` or a bare RAPL write; a Linux equivalent therefore needs the DPTF/DTT path, not the rail registers.
- `tools/honor-boost/` holds the module, `acpi_call` build, and the gated `svrf-test.sh` harness. The test found no lever to pull via `SVRF`, so the safety-gate question shifts from "roll back the rails" to "how to drive the DPTF mailbox safely and reversibly".

## The real lever found: EC power-budget registers `PP1R`/`PP2R`, raised by `IMOK` (2026-09-09)

Follow-up Linux test with a non-AVX all-core load (`nspin.c`, integer xorshift) that actually reaches the limit, plus a module extension exposing `ODP0..9`, `DTTF`, and the `PP*` registers:

- The MMIO RAPL sysfs is a **red herring**: writing `PL1` up to 65 W and down to 25 W changed nothing (package stayed ~40 W). The write sticks in sysfs but the hardware ignores it. This disproves the earlier "MMIO RAPL is the lever" conclusion.
- The actual power budget lives in `PP1R` (`ECF6 0xC2`) and `PP2R` (`0xC3`). On a cold Linux boot they read `0x28`/`0x32` = **40 W / 50 W**; `PP1M` (`0xC1`) = `0x58` = 88 W is the ceiling. These match the MMIO 40/50 W numbers, which is why the MMIO registers appeared to be the limit.
- **No ACPI method writes `PP1R`/`PP2R`.** `GPPT` only reads them; `SODP` only writes `ODP0..9`. They are written by the EC firmware itself in response to DTT being enabled.
- The trigger is `\_SB.IETM.IMOK` (SSDT18:410), which sets the `DTTF` flag (`ECF0 0x52` bit 7). A few seconds after `IMOK`, the EC raises `PP1R`/`PP2R` from 40/50 W to **88 W** (`0x58`), and the raise is sticky (persists after `DTTF` resets to 0, until reboot). Package power under the same load rose from ~40 W to ~43-46 W.
- `SODP` writes to `ODP1`/`ODP2` are immediately reverted by the EC (those two reflect the current mode, not a policy the OS sets); `ODP8` (EPO) sticks. Setting `DTTF=1` + `ODP8=1` alone did not move `PP1R`/`PP2R` — the `IMOK`→`DTTF`→EC-firmware path is what does.
- Conclusion: the ~40 W cap is the EC's default power budget (`PP1R`/`PP2R`), and `IMOK` is the safe, reversible (per reboot) ACPI lever that lifts it to the 88 W ceiling. The remaining gap to Windows' ~60 W sustained is the DTT software layer (`PL1=65 W`, `EPP=63`, higher frequency) on top of the now-raised EC ceiling, not the EC budget itself.

### Final measurement: the EC budget is a small lever, `7z` is load-limited (2026-09-09)

A follow-up run maxed out every Linux-side lever and then restored the EC budget, to separate the `IMOK` effect from load/thermal behaviour:

- EPP already `performance` (=0) on all 16 policies (more aggressive than Windows' 63), turbo enabled, `max_perf_pct=100`.
- Forcing `intel_pstate/min_perf_pct=100` raised P-core frequency under `7z b` from ~3.3 to ~4.3-4.5 GHz, but package power stayed at ~50 W.
- **After restoring `PP1R`/`PP2R` to the Smart default 40/50 W, `7z b` still drew ~49 W** and reached 98 °C (thermal throttling). So `7z`'s ~50 W is its own load/thermal ceiling (at the `PP2R`=50 W PL2 edge), not the EC budget. The `IMOK`-raised budget shows up on the sustained integer load instead: `nspin` 40 → 46 W.

Interpretation: the EC budget (`PP1R`/`PP2R`, raised by `IMOK`) is a real but **modest** lever — a few watts on sustained integer work, nothing on the bursty/thermal-limited `7z` load. The remaining gap to Windows' ~60 W is the Intel DTT/HGS current/frequency layer (kernel-level), not a HONOR register and not the EC budget.

Net, measured (same `nspin` load isolates the EC-budget effect; `7z` is ~50 W regardless of budget):

| State | `PP1R`/`PP2R` | load | package W |
|---|---|---|---|
| Linux default | 40/50 W | `nspin` | 40 |
| after `IMOK` (EC=88 W) | 88 W | `nspin` | 46 |
| Linux default / `IMOK` | 40/50 W / 88 W | `7z b` | ~50 both |
| Windows Performance | 88 W | `7z b 1` | ~60 (peak ~70) |

### Definitive A/B: the boost gives zero throughput (2026-09-09)

`stress-ng --cpu 16 --timeout 30 --metrics-brief` across three configurations
(same load, same thermal start):

| config | bogo ops/s | package W |
|---|---|---|
| default budget (40/50 W) | 29486 | 47.5 |
| `IMOK` (88 W) | 29296 | 46.8 |
| `IMOK` + TCC offset 0 (throttle at 100 °C) | 29198 | 47.3 |

The spread is < 1 % (noise). Raising the EC budget, lowering the thermal-throttle
offset, or both changes nothing: the CPU hits the 97 °C thermal throttle before
any power budget, so the cooling system (~50 W sustained) is the hard limit.

### Real-game check (Linux, 2026-09-09)

A ~7.7-minute GPU-bound game logged with `tools/honor-boost/monitor.sh`: package
power averaged 29.8 W (peak 50.6 W), `uncore`/iGPU ~10-20 W while CPU cores only
~14 W, `psys` (whole platform) peaked at **72.6 W**, and temperature peaked at
97 °C. Raising the EC budget to 88 W mid-game did not raise the peak (`psys`
71.8 W after) — the machine is GPU-bound and thermally limited, so the extra CPU
budget is unused. This matches the Windows Division 2 result (iGPU power changed
~0.2 % under Turbo X).

### Fan and throttle levers (verified)

- Fan speed cannot be set from the OS: `SFNS` is gated on the EC `MFGM` flag
  (never set by any firmware path), the Art 14 `WTER` route is absent, and DPTF
  `TFN1`/ACPI `Fan` objects do nothing (see `patch/fan/README.md`).
- The only fan lever is the `IFCI` table selector (`FTSL`); the "aggressive"
  `0xAB` table lowers the engagement threshold but **not** the maximum RPM
  (verified: ~2460 RPM at 85 °C EC-temp, same as stock).
- The throttle point is the writable TCC offset (`/sys/class/thermal/
  cooling_device24/cur_state`, default 3 → throttle at 97 °C; 0 → 100 °C).
  Setting it to 0 gained nothing (still ~50 W, ~29200 bogo-ops/s), confirming
  cooling is the binding constraint, not the throttle offset or the budget.

## DTT / EPO / ITM decoded: the ODVP EC-register path (2026-09-08)

The "Intel DTT/EPO/ITM policy" that Windows applies is not an opaque DPTF blob. It reduces to ten named EC registers `ODP0..ODP9` written through WMI, which the Intel DTT driver then reads and turns into power/thermal policy. This closes the gap left by the Linux rail measurements above, which looked at the `VCCC`-family rails (ECF6 `0x20+`) and missed the DTT registers at `0x10..0x19`.

### Windows call chain

- `SchedulExecuterIntel::SchedulIntelPlatform` (`HSPPPlugin.dll`, decomp `HSPP-intel-executor-decomp.txt`) ends with `Execute DTT(EPO) Policy ID` and `Execute DTT(ITM) Policy ID`.
- `OS2SOCUtil::SetIntelPolicyIDByODVP8` sends a 64-byte `OemWMIfun` input `03 0F 08 <id>` → **EPO policy to `ODP8`** (`CONCAT13(param,0x80f03)`).
- `OS2SOCUtil::SetIntelODVP9` sends `03 0F 09 <id>` → **DTT policy to `ODP9`** (`CONCAT13(param,0x90f03)`).
- `PowerPolicyPlugin.dll` registers the names `ODVP0`..`ODVP8`; `WMI::SetOdvp5`/`GetOdvp5`/`SetOdvpXToDefault`/`SetOdvp0ToDefault` (`Util.dll`) and `BiosWmi::GetODVP(0..8)` confirm the per-slot API. A separate `ODP5` write is logged as `Intel Driveturbo SetODVP5`.

### WMI dispatch

- `SODP` = `MFID 0x03 / SFID 0x0F` (`SSDT21.dsl:472-495`): writes `CAID` (input byte 3) to `ODP[ODVW]` (input byte 2 selects 0..9), then calls `\_SB.IETM.ODVP()` and `Notify(IETM, 0x88)`.
- `GODP` = `MFID 0x03 / SFID 0x0E`: returns `CAID` for the requested `ODVX` in output byte 1.

### EC register map (LXEC, `DSDT.dsl:24883`)

| Register | Offset | Meaning |
|---|---:|---|
| `ODP0`..`ODP9` | `0x10`..`0x19` | DTT policy slots; `ODP8` = EPO, `ODP9` = DTT, `ODP5` = Driveturbo |
| `ODCN` | `0x1F` | DTT count/state |
| `VCCC/VCCG/VCCS/VCCL` | `0x20`..`0x23` | rail unlock (`SVRF`) — already `0xFF` on Linux, not the DTT lever |
| `PPL4` | `0x24` | peak limit (`SVRF`) |
| `VRSS`/`VR10..16` | `0x25`..`0x2D` | VR telemetry |

`DTTF` enable flag is `ECF0 @ 0xFE0B0000` offset `0x52` bit 7, set by `\_SB.IETM.IMOK`. The Intel DTT software components (`SWC\VID8086_DTT_0001`, `DTTCFG`, `DTTTECH`, `PPM_1008`, installed via `oem38.inf`/`oem40.inf`) consume `ODP0..9` through the `\_SB.IETM` DPTF interface (`ODVP()`, `DTTE`, `DTTF`, `_DSM`, `_OSC`).

### Consequence for the Linux prototype

The Linux `honor-ec-rail.c` module already maps `ECF6` but only exposes offsets `0x1F+` (`VCCC`..`VR16`); it never exposed `ODP0..ODP9`, which is why the rail tests above saw no lever to pull. The next step is to extend the module (read-only first) to expose `ODP0..ODP9`, and on Windows to add a `GODP` getter to `tools/windows/honor-wmi-read` and capture `ODP0..9` in Smart vs Performance to learn which slots and values actually change.

### Observed ODP values (Smart vs Performance, 2026-09-08)

Captured live with the `godp` getter (MFID `0x03`/SFID `0x0E`) in Smart (DC and AC) and Performance (AC):

| ODP | Smart (AC/DC) | Performance (AC) |
|---|---:|---:|
| ODP0 | 0x00 | 0x00 |
| ODP1 | 0x01 | 0x00 |
| ODP2 | 0x00 | 0x01 |
| ODP3..ODP7 | 0x00 | 0x00 |
| ODP8 (EPO) | 0x01 | 0x01 |
| ODP9 (DTT) | 0x00 | 0x00 |

`ODP8`/`ODP9` are constant across modes (EPO=1, DTT=0 — the "common setup" the executor applies in every strategy). The mode signal is carried by `ODP1`/`ODP2`: Smart sets `ODP1=1, ODP2=0`, Performance sets `ODP1=0, ODP2=1`. This is power-source independent (Smart reads identically on DC and AC). Together with `CRWM` (0/1), the reversible Performance transition is `ODP1=0, ODP2=1, CRWM=1`; the rollback is `ODP1=1, ODP2=0, CRWM=0`.

Still open: whether the EC firmware consumes `ODP1`/`ODP2` directly or only the Intel DTT driver does. On Linux there is no DTT driver reading these, so the effect of writing them on Linux (with the `honor-ec-rail.c` module) is unproven until a Linux test measures package power after setting `ODP1=0/ODP2=1`.

### EC power-limit registers are mode-independent (GPPT)

`GPPT` (`MFID 0x03 / SFID 0x0B`) reads the EC's own power-limit registers from `ECF6` (`PP1M/PP1R/PP2R` @ `0xC1..0xC3`, `PP4R` @ `0xC4`, `PPP1/PPP2` @ `0xC6/0xC8`). Captured in both modes:

| Register | Smart | Performance |
|---|---:|---:|
| PL1M / PL1R / PL2R | 0x58 (88) | 0x58 (88) |
| PL4R | 0xEF (239) | 0xEF (239) |
| P1RT / P2RT | 140 / 170 | 140 / 170 |

They are identical in Smart and Performance: the EC does not change its own PL registers per mode; they sit at the 88 W firmware ceiling (matching the MSR `intel-rapl` 88 W, not the MMIO `intel-rapl-mmio` 40/50 W default). The mode-defining PL1 (50 → 65 W) is therefore applied by the Intel DTT driver via MMIO RAPL and Windows PPM, not by these EC registers and not by the rails.

`HSPPPlugin.dll` only ever writes three ODVP slots via `SODP`: `ODP5` (`SetARMThermalTableByWMI`), `ODP8` (EPO), `ODP9` (DTT). There is no HSPP caller for `ODP1`/`ODP2`, so the mode flip observed there is written by the Intel DTT driver or the EC firmware, not by PC Manager.

## Windows tooling

1. **ACPICA** (`acpidump.exe`, `iasl.exe`) — dump and disassemble DSDT/SSDT. `docs/WINDOWS-DUMP.md` has the exact commands.
2. **RWEverything** — live EC register reads, especially `ECF5` and `ECF6`.
3. **HWiNFO64** — package power, RAPL, PL1/PL2, VRM, temperature.
4. **WMI Explorer** / `wbemtest.exe` — enumerate and call `\_SB.WMI1.WMAA`.
5. **Process Monitor** — file / registry traffic from `PCManager.exe`.
6. **ETW** — `logman start wmi -p Microsoft-Windows-WMI-Activity 0x2 -ets` to capture live `WMAA` calls.
7. **Ghidra** / **x64dbg** / **IDA Free** — reverse the PC Manager binaries.
8. **WinDbg Preview** (optional) — kernel-level tracing of the EC / ACPI driver.

## Working branch

`feat/honor-boost`

## Next steps

- [ ] Install the Windows tools above.
- [ ] Dump current EC state at idle and under load with RWEverything.
- [ ] Switch HONOR PC Manager performance modes and record the `WMAA` payload (ETW and/or WMI call capture).
- [ ] Compare EC values for `VCCC`, `PPL4`, `SCPM`, `FTSL` across modes.
- [ ] Reproduce the `SVRF` payload on Linux via `acpi_call` or a small kernel module.
- [ ] Validate package power in Linux with `turbostat`, `s-tui`, or RAPL `powercap`.

## M1020 dump progress

- Dump directory: `C:\Users\sazha\Desktop\m1020-dump`
- `acpidump` successfully wrote all ACPI tables except `DSDT`; the M1020 DSDT is byte-identical to the M1010 DSDT (see `docs/hardware/zqc-p.md`), so the M1010 `DSDT.aml` is used as the external symbol table.
- Disassembled with `iasl -e dsdt.aml -d <ssdt>.aml`:
  - `ssdt21.dsl` (HONOR `WmiTable` with `WMAA` dispatcher)
  - `ssdt18.dsl` (Intel DPTF table)
- `MSDM` was excluded; `.dat` raw files removed.
- Registry exports: `acpi.reg`, `enum-acpi.reg`, `services.reg`.
- PnP dump: `pnp_full_dump.txt`.

## M1020 vs M1010 ACPI comparison

SHA-256 check of every M1020 `.aml` against the M1010 dump in `dump/win11/zqc-p/OEM`:

- Identical (`MATCH`): 39 tables, including `DSDT`, `SSDT21` (`WmiTable` / `WMAA`), `SSDT18` (DPTF), all CPU/PCI/thermal SSDTs, and `SSDT27` (`I2C_DEVT`).
- Different (`DIFF`): only `fpdt.aml` and `uefi.aml` — both contain boot/runtime timestamps and are expected to differ.
- Missing in M1010: none.

Conclusion: the M1020 unit being analyzed is firmware-identical to the M1010 reference for all ACPI methods relevant to the boost / WMI / EC investigation. The M1010 `WMAA` dispatch table and `SVRF` / `SPPM` / `IFCI` methods are valid here.

## Live Windows session status (2026-09-08)

- Windows Test Mode (`bcdedit /set testsigning on`) was enabled and the system was rebooted.
- RWEverything still cannot load `RwDrv.sys`: it is on the Microsoft Vulnerable Driver Blocklist. Test signing alone does not unblock it; `Memory Integrity` / `VulnerableDriverBlocklistEnable` must also be disabled to use RWEverything.
- WMI ETW trace was started after reboot:
  ```bat
  logman start honor-wmi-2 -p "Microsoft-Windows-WMI-Activity" 0x2 -o "C:\Users\sazha\Desktop\m1020-dump\wmi-trace.etl" -ets
  ```
- Discovered a usable WMI interface that maps directly to `WMAA`:
  - Namespace `root\WMI`, class `OemWMIMethod`, GUID `{ABBC0F5B-8EA1-11D1-A000-C90629100000}`.
  - Instances: `ACPI\PNP0C14\HWMI_0`, `ACPI\PNP0C14\HWMI_1`.
  - Methods: `OemWMIfun` (WmiMethodId 1, maps to `Arg1=1`), `OemWMIfunEx` (WmiMethodId 2, maps to `Arg1=2`).
  - Parameters: `u8Input` (UInt8Array, in), `u32Resrved` (UInt32, out), `u8Output` (UInt8Array, out).
- Tried `GVER` (`MFID=0x01, SFID=0x01`) via `Invoke-CimMethod` / `Invoke-WmiMethod` with `u8Input` lengths 2, 256, 260, 512, 1024 bytes. All calls returned `u8Output.Length = 0` and no `u32Resrved` value. `OemWMIfunEx` on `HWMI_0` returned `InvalidArgument`.
- Interpretation: `OemWMIfun` is present and callable, but the output buffer mapping is not yet decoded. Either the provider expects a different buffer layout, or the `WMRP` package returned by `WMAA` is not surfaced through `u8Output`.
- The first ETW command above is incorrect for method tracing: `0x2` was used as a keyword and produced only an 8 KiB trace header. The correct provider configuration is keyword `0x8000000000000000` (`Microsoft-Windows-WMI-Activity/Trace`) at level `0x4`:
  ```bat
  logman start honor-wmi-trace -p "Microsoft-Windows-WMI-Activity" 0x8000000000000000 0x4 -o "C:\Users\sazha\Desktop\m1020-dump\wmi-mode-trace.etl" -ets
  ```
- A successful Smart → Performance → Smart capture was saved as `C:\Users\sazha\Desktop\m1020-dump\wmi-mode-trace.etl` and converted with `tracerpt -lr` to `wmi-mode-trace.xml`.
- The caller is `C:\Program Files\HONOR\PCManager\HnPerformanceCenter.exe` (PID 8572 during this capture), not `PCManagerMainService.exe`. ETW recorded `IWbemServices::ExecMethod` calls to `ROOT\WMI:OemWMIMethod.InstanceName='ACPI\PNP0C14\HWMI_0'::OemWMIfun`, but the provider does not include `u8Input` in the events.
- Static analysis identified the relevant implementation in `plugins\PerfCommonPlugin.dll` and `plugins\HSPPPlugin.dll`; `HnPerfPowerNexus.exe` primarily handles GPU modes.
- `TurboMode::SetTurboMode(int)` in `PerfCommonPlugin.dll` sends a 64-byte `OemWMIfun` input through `WMI::GetOutPutUIntEx`:
  - Smart: `04 0F 00` followed by zero padding.
  - Performance: `04 0F 01` followed by zero padding.
  - This dispatches to `STUB`; byte 2 sets EC `CRWM` to `0` or `1`.
- `HnPerformanceCenter.log` confirms the GUI mapping on the M1020/ZhuqueC: selecting Performance logged `SetTurboMode ... status:1`; returning to Smart logged `status:0`. Both calls succeeded.
- Changing `CRWM` generates WMI event `673`. `HSPPPlugin.dll` handles it through `OS2SOCUtil::EnterHighPerMode`, selects the PERFORMANCE_AC strategy, then applies Intel DTT/ITM/EPO policy.
- During the captured Performance transition the strategy log contained `commandPL4: 00 00 00 FF FF FF FF 00`. `OS2SOCUtil::SetIntelPowerLimit4` parses that string and prepends `07 0F`, producing this 64-byte WMI input:
  ```text
  07 0F 00 00 00 FF FF FF FF 00 00 ...
  ```
- `SVRF` interprets this as `PPL4=0`, `VCCC=0xFF`, `VCCG=0xFF`, `VCCS=0xFF`, `VCCL=0xFF`, `SVFT=0`: all four rail limits are unlocked. This confirms that PC Manager calls `MFID 0x07 / SFID 0x0F` from HSPP. Later logs show the same `commandPL4` in both Smart and Performance strategies, so rail unlock is common setup rather than the mode-defining difference.
- `OS2SOCUtil::SetSmartFan` sends `07 08 <table>` padded to 64 bytes. On ZhuqueC the strategy reports table `160` (`0xA0`) in both Smart and Performance, hence the effective payload is `07 08 A0 00 ...` in both modes. The louder Performance fan behavior is therefore driven by `CRWM`, higher heat/power targets, and DTT behavior rather than a different `FTSL` table.
- No `07 0D`/`SPPM` caller was found among all direct WMI call sites decompiled from `HSPPPlugin.dll`, `PerfCommonPlugin.dll`, or `PowerPolicyPlugin.dll`. HSPP's many `PPM` references are Windows Processor Power Management (`powercfg`/PPM settings), not the ACPI `SPPM` method. Treat `SPPM` as an available firmware method that appears unused on ZhuqueC unless a dynamic capture proves otherwise.
- WMI event mapping is now explicit: `0x2A1` (decimal 673) and `0x2A8` call `OS2SOCUtil::EnterHighPerMode`; `0x2A0` (decimal 672) calls `ExitHighPerMode`. The GUI first sends `04 0F 01/00` to `STUB`, which sets `CRWM` and generates these notifications.
- For the default scene, live logs show DTT ITM policy `0` and EPO policy `1` in both Smart and Performance. The measured mode-defining policy changes are dynamic PL1 `50 → 65 W` and EPP `127 → 63`; PL2 remains `80 W`. Other scenes can select different EPO IDs (for example, EPO `3` was observed for a fullscreen Firefox scene).
- Ghidra project and decompilation artifacts are in `C:\Users\sazha\Desktop\m1020-dump\ghidra-project` and `C:\Users\sazha\Desktop\m1020-dump\*-decomp.txt`. Microsoft OpenJDK 21 was installed for Ghidra 12.
- A later The Division 2 A/B run exposed the effective policy values in `HnPerformanceCenter.log`:
  - Performance: PL1 normally `65 W` (one sample `70 W`), PL2 `80 W`, EPP `63`, reported package power `58.2-64.3 W`.
  - Smart/Balance: PL1 dynamically `50-55 W`, PL2 `80 W`, EPP `127`, reported package power `57.3-59.4 W` in the sampled moments.
  - Thus Turbo mode raises the sustained package target by roughly 10-15 W and makes scheduling more performance-biased, but does not raise the 80 W short limit in this workload. This matches the user's observation that fan behavior changed much more than iGPU power or frequency.
  - HSPP reported `GPUPower=0.0` for these samples, so its log cannot validate the separate HWiNFO iGPU reading of approximately 19-19.5 W.
- Controlled The Division 2 built-in benchmark result:
  - Smart: approximately 27 FPS, game-reported GPU 73%, CPU 14%, score 2439.
  - Performance: approximately 27 FPS, game-reported GPU 66%, CPU 10%, score 2439.
  - HWiNFO/PresentMon simultaneously showed approximately 99.6-99.9% total GPU use, a fixed 2500 MHz GPU clock, approximately 19.3 W iGPU power, and GPU Busy nearly equal to total frame time. The game's own GPU/CPU percentages are therefore not trustworthy on this Panther Lake/B390 platform; FPS and score are the useful outputs.
  - On comparable continuous GPU-bound CSV regions, Performance raised package power by about 21.5%, IA-core power by about 60%, and package temperature by about 6.7 °C, while iGPU power changed by only about 0.2% and FPS changed by less than 1%. For this workload Turbo X produced no measurable performance gain.
- A read-only Windows getter helper now lives in `tools/windows/honor-wmi-read`. It uses the signed PC Manager `Util.dll` `BiosWmi` singleton and hard-codes only `GTUB`, `GFCI`, and `GVRF`; it refuses non-`ZQC-P` systems and requires an administrator token. Normal-user calls fail with `0x80041003` (`WBEM_E_ACCESS_DENIED`).
- This helper was needed because PowerShell/.NET WMI invocation loses the void method's out parameters, while `HnWMISDK::ParseOutputResult` incorrectly uses `SafeArrayGetElemsize()` as the total length and copies only one byte. `Util.dll::GetOutPutUIntEx` copies the requested full output buffer and works.
- First successful read in Performance mode:
  - `GTUB`: `STAT=0`, `CRWM=1`.
  - `GFCI`: `STAT=0`, `FTSL=0xA0`.
  - `GVRF`: `STAT=0`, `VRMS=0x0F`, `PPL4=0`; `VR10/12/14/16` and `GFP0/2/3` were zero, `GFF0=0xC7DD`. The telemetry words still need interpretation and repeated sampling.
- A synchronized idle transition established the ordering and delay:
  - Smart → Performance: setter start `16:41:06.466`, setter success `16:41:06.472`, event `673` and `EnterHighPerMode` at `16:41:06.517`, `PERFORMANCE_AC` selected by `16:41:06.659`, getter first observed `CRWM=1` at `16:41:07.16`, and PL1/EPP/DTT application completed around `16:41:11.75` (about 5.3 seconds after the setter).
  - Performance → Smart: setter start `16:41:46.865`, success `16:41:46.875`, event `672` and `ExitHighPerMode` at `16:41:46.914`, `BALANCE_AC` selected by `16:41:47.137`, and PL1/EPP/DTT application completed around `16:41:52.19` (again about 5.3 seconds later).
  - `FTSL=0xA0`, `PPL4=0`, `VRMS=0x0F`, and the returned GVRF telemetry words did not change. A final Smart getter read confirmed `CRWM=0` with the same GFCI/GVRF state.
- The correctly configured ETW capture `m1020-dump\wmi-transition.etl` recorded the corresponding `OemWMIfun` traffic, but still does not expose payload bytes; the getter timeline and PC Manager log provide the state correlation.
- Static battery gating is `BatteryLifePercent > 0x13`, so 20% is accepted and 19% is rejected; no hysteresis is visible in this check.
- A synchronized Performance → AC off → AC on capture established the power-loss fail-safe:
  - AC removal: event `672`/`ExitHighPerMode` at `17:14:45.764` with no preceding `SetTurboMode(0)` log; getter observed `CRWM=0` by `17:14:46.17`. PC Manager did not log DC detection until `17:14:50.098`. Therefore EC/firmware or an earlier firmware notification clears Turbo within about one second, roughly four seconds before the userspace AC handler.
  - On DC, `FTSL` stayed `0xA0`, `PPL4` stayed `0`, and `VRMS` changed `0x0F → 0x00` by `17:14:51.21`. HSPP selected a forced `BALANCE_DC` policy with requested PL1 `45`, PL2 `65`, EPP `216`, and EPO `4`; the executor log still showed a stale AC policy during the short transition, so exact applied DC limits require HWiNFO confirmation in a longer disconnected run.
  - AC reconnect: PC Manager detected AC at `17:15:43.584`; getter observed `VRMS=0x0F` by `17:15:44.16`. PC Manager automatically replayed `SetTurboMode(1)` at `17:15:46.594`, event `673` followed at `17:15:46.652`, and getter observed `CRWM=1` by `17:15:47.14`. Performance PL1/EPP/DTT was applied by `17:15:52.09`.
  - Thus reconnect automatically restores the previously selected Performance mode. A Linux implementation should deliberately be more conservative: exit immediately on AC loss and require manual re-entry after reconnect.
- A bounded CPU-only A/B used three `7z b 1 -mmt=16` runs per mode with 30-second idle gaps and synchronized HWiNFO logging:
  - Performance scores: `106687`, `105490`, `106564` MIPS; mean `106247`.
  - Smart scores: `106190`, `105932`, `105428` MIPS; mean `105850`.
  - Performance advantage was only `0.38%`, below the approximately `1.1%` run-to-run spread.
  - Performance used dynamic PL1 about `70 W`; Smart used `55 W`; PL2 was `80 W` in both. Under actual load both averaged about `60 W` package power and peaked around `70-71 W`.
  - Every high-load sample in both modes asserted core thermal throttling and IA Max Turbo Limit. Package thermal throttling appeared in 24/27 Performance samples and 20/26 Smart samples. No package, IA PL1/PL2, or electrical limit reason asserted. All runs reached `99-100 °C`.
  - Therefore this cooling system reaches its thermal ceiling before either mode reaches its configured PL1. A longer CPU torture test is neither useful nor justified; Turbo provides no meaningful CPU throughput gain under this workload and increases time spent package-throttled.
  - HWiNFO exposed no fan RPM sensors, so fan response was not captured in these CSVs. Add the read-only `GFNS` getter to the helper before any further thermal test rather than repeating this workload blind.
- The read-only helper now also supports `GFNS` as `fan0`/`fan1`. The first post-test Smart sample returned `2884/2451 RPM`.
- A synchronized Performance suspend/resume test on AC established resume behavior:
  - Windows requested sleep at `17:41:12`; HSPP logged suspend at `17:41:13`, and resume at `17:41:50` after about 38 seconds in Modern Standby.
  - Before sleep: `CRWM=1`, `FTSL=0xA0`, `PPL4=0`, `VRMS=0x0F`, fans approximately `2884/2452 RPM`.
  - The first getter sample after resume observed `CRWM=0` at `17:41:49.95`; `FTSL`, `PPL4`, and `VRMS` were unchanged. PC Manager replayed `SetTurboMode(1)` twice at `17:41:55.045/059`, event `673` followed at `17:41:55.130`, and getter observed `CRWM=1` by `17:41:55.12`.
  - Fans rose to approximately `3759/3560 RPM` after resume. The EC therefore resumes in the safer Smart state and Windows restores remembered Performance about five seconds later. Linux should keep Smart after resume and require explicit re-entry rather than copying the automatic restore.
- A second synchronized test suspended in Performance on AC, disconnected AC while asleep, and resumed on battery:
  - HSPP logged suspend at `17:45:53`, detected DC at `17:46:38.809`, and logged resume at `17:46:38.949`. Getter first resumed at `17:46:38.96` with `CRWM=0`; it remained zero and no `SetTurboMode(1)` replay occurred.
  - `FTSL` stayed `0xA0`, `PPL4` stayed `0`, and `VRMS` changed `0x0F → 0x00` by `17:46:43.20`. Fans were approximately `3766/3558 RPM` before sleep and `3631/3284 RPM` after resume.
  - Windows selected `PERFORMANCE_DC` because Performance was remembered, but with hardware Turbo off: ITM `0`, EPO `3`, PL1 `55`, PL2 `80`, EPP `0`. Thus AC loss during sleep is handled before normal resume work and does not re-enable `CRWM`; the remembered UI profile can still choose a more aggressive DC software policy.
  - A Linux implementation should explicitly enter its conservative battery profile on resume without AC regardless of the previously selected profile.
- An early SYSTEM getter task captured a warm reboot while Performance was remembered and AC remained connected:
  - Windows booted at `17:58:13`; capture began at `17:58:23.74`; the first getter at `17:58:24.66` observed `CRWM=0`, `FTSL=0xA0`, `PPL4=0`, `VRMS=0x0F`, and fans `2363/2059 RPM`.
  - HnPerformanceCenter started plugin initialization at `17:58:28.508`, explicitly replayed `SetTurboMode(1)` at `17:58:31.739`, and getter observed `CRWM=1` by `17:58:32.14`. The final Performance PL1/PL2 policy (`70/80`) was reported at `17:58:40.110`.
  - Therefore reboot resets `CRWM` to safe Smart before PC Manager runs. `FTSL`, `PPL4`, and `VRMS` matched their pre-reboot values, but those values are also normal firmware defaults/common setup, so this alone cannot prove whether they persisted or were reinitialized.
- A separate full-shutdown/cold-boot test was intentionally skipped: AC loss, suspend, and reboot already independently prove that `CRWM` fails safe, while `GVRF` cannot expose `VCCC/VCCG/VCCS/VCCL`. Since `FTSL=A0` and `PPL4=0` are both the observed runtime values and plausible defaults, another boot cannot distinguish persistence from reinitialization. It would not close the remaining `SVRF` safety question.
- The temporary SYSTEM startup-capture task was deleted after the reboot test. The conservative implementation decision is to exclude `SVRF` from the first Linux prototype rather than infer rail rollback from unobservable state.
- Next step: use the helper to fill any remaining observable transition state below. Build a reversible Linux prototype around the confirmed `STUB`, common `SVRF` unlock, stock `IFCI A0`, and standard Linux performance/EPP controls only after its safety gates are satisfied; do not add `SPPM` without new evidence.

## Required evidence from the next Windows session

There can be no absolute safety guarantee without HONOR documentation for the EC and DTT policy. The remaining Windows work should therefore concentrate on rollback, power-loss, suspend and persistence behavior rather than on finding a larger peak-power number. A short Linux `STUB=1` / `STUB=0` idle test is already supported by enough evidence; Linux `SVRF` rail unlock is not.

### Capture one synchronized transition timeline

For every scenario below, preserve `HnPerformanceCenter.log`, the related HSPP/BasicService logs, a correctly configured WMI ETW trace, and an HWiNFO CSV. Record wall-clock start and transition times so the files can be aligned. The goal is to establish the exact ordering of `STUB`, `SVRF`, PL1/PL2, EPP, DTT ITM/EPO, and fan-policy operations in both the forward and rollback paths.

Capture these scenarios without a heavy workload unless the scenario explicitly calls for one:

1. Cold boot into Smart, including PC Manager service startup.
2. Smart → Performance.
3. Performance → Smart.
4. Performance → AC adapter disconnected, then reconnected.
5. Performance → suspend → resume.
6. Performance → reboot.
7. Performance → full shutdown, adapter disconnected, wait, then cold boot.

For AC removal, determine how quickly Windows changes strategy, `CRWM`, PL1/PL2, EPP and DTT policy. This is the reference for a Linux fail-safe path. For suspend, reboot and full shutdown, determine whether PC Manager replays `STUB`, `SVRF`, DTT, PL1/PL2, EPP and `IFCI A0`, or whether the relevant EC state survives.

PC Manager explicitly states that Performance is available only while AC is connected and battery charge is above 20%. Treat both as required policy gates rather than UI-only advice. The Linux implementation must refuse entry when either condition is false and leave Performance if AC disappears or charge reaches the lower threshold. The remaining question is where Windows enforces this: synchronously in the GUI/service, through a DTT policy, in EC firmware, or through more than one layer.

#### AC and battery-gate capture

With charge safely above 20%, select Performance at idle, start synchronized getter/log capture, disconnect AC, wait for the mode transition, then reconnect it. Record whether Windows merely makes Performance available again or automatically re-enters it. Capture the first observed changes in `CRWM`, strategy, PL1/PL2, EPP, ITM/EPO, `PPL4`, and `FTSL`, including their order and delay.

Do not deliberately discharge the battery under load to test the 20% boundary. Prefer existing logs, static analysis of the PC Manager threshold check, or an idle observation if the battery reaches that level during normal use. Establish whether the cutoff is `<20%` or `<=20%`, whether hysteresis exists, and whether reconnecting AC automatically restores the previous mode.

#### Why suspend/resume still needs a capture

Sleeping in Performance is not expected to damage the machine: CPU/GPU load and package power collapse during sleep. The risk is a brief state mismatch around resume, not power consumption while asleep. Several implementations are possible:

1. The EC sees AC removal during sleep and clears `CRWM` or restores its own limits before the OS wakes.
2. Windows or DTT receives the power-source change during resume and applies the battery policy before normal workloads resume.
3. PC Manager handles a resume/power event and sends `STUB=0` plus the Smart PL1/EPP/DTT bundle.
4. EC rail unlock survives while OS-side PL1/EPP/DTT state resets, leaving a short interval with incomplete policy until PC Manager starts its approximately five-second apply sequence.

The first three provide automatic rollback and are likely; the fourth is the failure window the Linux design must exclude. A Linux prototype does not necessarily need to block suspend if testing proves that firmware handles it. Otherwise it should run a pre-sleep hook that exits Performance and a post-resume hook that first verifies AC, battery charge, `CRWM`, temperature, fan telemetry and power limits before allowing Performance again.

Test this at idle in two separate runs:

1. Enter Performance on AC, suspend, resume with AC still connected, and sample `GTUB/GFCI/GVRF` immediately after resume and again after PC Manager settles.
2. Enter Performance on AC, suspend, disconnect AC while asleep, resume on battery, and sample the same state immediately. Confirm that Windows returns to Smart without a manual UI action and identify whether `CRWM` was already zero before the PC Manager policy log completed.

No workload is needed. Preserve Windows event timestamps for sleep, wake and power-source change alongside the getter and HSPP logs. Also note whether the Performance selection is remembered and automatically restored after AC is reconnected; Linux should not copy that behavior until it is explicitly chosen.

### Record EC/WMI state before and after transitions

The ideal state matrix is:

1. Cold boot before PC Manager has applied its policy.
2. Smart idle.
3. Smart under a short controlled load.
4. Performance idle.
5. Performance under the same load.
6. Immediately after returning to Smart.
7. After reboot.
8. After full shutdown with the adapter removed.

Prioritize these fields:

- `GTUB` / `CRWM`.
- `GFCI` / `FTSL`.
- `GVRF` / `PPL4` and the available VR telemetry.
- `SCPM`, only as an observation; do not call `SPPM`.
- `VCCC`, `VCCG`, `VCCS`, `VCCL` and `SVFT` if a safe read-only route becomes available.

`GTUB`, `GFCI` and `GVRF` are firmware getters and are preferable to direct EC access. `GVRF` exposes `PPL4` and VR telemetry but does not directly return the current `VCCC`/`VCCG`/`VCCS`/`VCCL` bytes. Do not disable Microsoft Vulnerable Driver Blocklist or Memory Integrity merely to load `RwDrv.sys`; using a known-vulnerable driver creates a separate security risk and still does not provide a safety guarantee. Use official WMI getters, debugger instrumentation, or a safe signed read-only mechanism instead. Do not write raw EC registers.

### Run a repeatable CPU-limited A/B measurement

The Division 2 result is a valid GPU-bound negative result but cannot measure the benefit of the additional CPU budget. Use a short repeatable CPU-only workload, with Smart and Performance starting from comparable idle temperatures. Run each mode at least three times and report the distribution rather than one result. Cool the machine between runs. Do not use an unbounded torture test.

Log at least:

- CPU package and IA-core power.
- GT/iGPU power and GPU busy, as a cross-check.
- Effective PL1 and PL2.
- Package and hottest-core temperature.
- Effective clocks.
- Thermal-, current- and power-limit throttling flags.
- Both fan RPM values.
- Battery charge/discharge rate and adapter input power if exposed.
- The selected strategy, EPP, and DTT ITM/EPO policy IDs.

Stop the run if cooling behaves unexpectedly, either fan reports zero while package temperature is high, the adapter disconnects, or the package approaches 95 °C. The objective is to identify stable PL1 and cooling response, not to force the silicon to its thermal limit.

For each state, fill this table from synchronized logs:

| State | CRWM | Strategy | ITM | EPO | PL1 | PL2 | EPP | FTSL | `commandPL4` |
|---|---:|---|---:|---:|---:|---:|---:|---:|---|
| Smart idle | 0 | `BALANCE_AC` | 0 | 1 | 55 | 80 | 127 | `0xA0` | `00 00 00 FF FF FF FF 00` |
| Performance idle | 1 | `PERFORMANCE_AC` | 0 | 1 | 68 in this run (normally 65-70) | 80 | 63 | `0xA0` | `00 00 00 FF FF FF FF 00` |
| Smart CPU load | 0 | `BALANCE_AC` | 0 | 1 | 55 | 80 | 127 | `0xA0` | `00 00 00 FF FF FF FF 00` |
| Performance CPU load | 1 | `PERFORMANCE_AC` | 0 | 1 | ~70 | 80 | 63 | `0xA0` | `00 00 00 FF FF FF FF 00` |
| Performance, AC removed | 0 within ~1 s | `BALANCE_DC` (forced) | not confirmed | 4 requested | 45 requested | 65 requested | 216 requested | `0xA0` | `00 00 00 FF FF FF FF 00` |
| After resume on AC | 0 initially, 1 after ~5 s | `PERFORMANCE_AC` restored | 0 | 1 | 65 | 80 | 63 | `0xA0` | unchanged |
| After resume on battery | 0 | `PERFORMANCE_DC` (remembered profile, Turbo off) | 0 | 3 | 55 | 80 | 0 | `0xA0` | unchanged |
| After reboot on AC | 0 initially, 1 after ~8 s capture / ~19 s boot | `PERFORMANCE_AC` restored | 0 | 1 | 70 after settle | 80 | 63/0 during startup transition | `0xA0` | unchanged |
| After full power-off | not run; low additional value | | | | | | | | rail state not observable through available getters |

Also determine whether EPP `127 → 63` is one package-wide setting or differs across P-core, E-core and LP E-core classes, and which Windows PPM settings accompany it.

### Safety gates for the Linux prototype

Evidence is now sufficient for a first **STUB-only** Linux prototype:

- Read-only `GTUB`, `GFCI`, `GVRF`, and both `GFNS` fan channels work.
- Windows proves that `CRWM` fails safe to zero on AC loss, suspend/resume, and reboot; explicit Smart also rolls back immediately.
- The prototype must refuse Performance without AC or below 20%, return to Smart on AC loss, exit before suspend, remain Smart after resume/reconnect until manual re-entry, and never call `SVRF` or `SPPM`.

Evidence/status for any future Linux `SVRF ... FF FF FF FF` test:

1. [x] Exact Performance → Smart rollback ordering.
2. [x] Exact behavior when AC is removed in Performance.
3. [x] Suspend/resume on AC and with AC removed while asleep.
4. [x] Reboot behavior for `CRWM`, `FTSL`, `PPL4`, and `VRMS`.
5. [x] Repeatable short CPU-only HWiNFO A/B measurement.
6. [ ] A safe read-only route for current `VCCC/VCCG/VCCS/VCCL/SVFT`, or vendor documentation proving their reset semantics. Cold boot without this visibility cannot answer the question.
7. [ ] A Linux rollback sequence that restores PL1, EPP, platform profile and `STUB=0` before the test process exits.
8. [ ] A watchdog that refuses entry without AC and battery charge above 20%, then stops load and rolls back on AC removal, charge reaching the lower threshold, lost telemetry, daemon failure, abnormal fan RPM, excessive temperature or unexpected package power.
9. [x] Suspend policy chosen: exit Performance before sleep and require explicit re-entry after resume/reconnect.

`SVRF` remains out of scope until items 6-8 are satisfied. The completed Windows tests do not justify inferring unobservable rail state.

Do not use `SPPM`, non-stock `IFCI` values, raw `/dev/mem` EC writes, voltage/current changes, disabled thermal protections, or an experimental boot-time daemon. The AML range condition in `IFCI` uses `FANT >= 0xA0 || FANT < 0xAD`, which is effectively always true, so firmware does not reliably reject a bad fan-table value. Windows uses stock `IFCI A0` in both captured modes; no other table is needed for parity.

## Windows GUI coordinate scaling

- Windows display configuration was restored to the user's normal setting: `3120x2080`, effective DPI `192`, scale `200%` (`2.0`). Do not ask to leave it at 100%.
- `windows-mcp` captures the physical `3120x2080` desktop as a `1620x1080` image and reports `Screenshot Coordinate Scale: 1.925926`. Multiply coordinates from the tool's actual `1620x1080` image by `1.925926` before calling `Click`.
- The image rendered in the Devin chat can be scaled again (observed as `1560x1040`). Never calculate click coordinates directly from the chat-rendered dimensions; first convert them to the tool image: multiply chat coordinates by `1620/1560 = 1.0384615` and `1080/1040 = 1.0384615`, then by `1.925926`. Combined for that rendering, chat-image coordinates map to physical screen coordinates by exactly `2.0`.
- PC Manager can move, so never reuse stored absolute coordinates. Take a fresh screenshot, locate each radio circle in the tool's actual image, apply the conversion above, and click the circle itself rather than its text.

## Key references

- `WMAA` dispatcher: `dump/win11/zqc-p/OEM/SSDT21.dsl` lines 852-905
- `SVRF` EC writes: `dump/win11/zqc-p/OEM/DSDT.dsl` lines 4217-4287
- EC register map: `patch/fan/README.md` lines 216-235
