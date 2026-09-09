#!/usr/bin/env bash
# Continuous thermal-package monitor. Logs package/core/uncore/psys power,
# package temperature and fan RPM. Run in the background, then analyse the CSV.
# Usage: monitor.sh [interval_s] [logfile]
set -u
INT="${1:-2}"
LOG="${2:-/tmp/powerlog.csv}"

PKG=/sys/class/powercap/intel-rapl:0/energy_uj
COR=/sys/class/powercap/intel-rapl:0:0/energy_uj
UNC=/sys/class/powercap/intel-rapl:0:1/energy_uj
PSYS=/sys/class/powercap/intel-rapl:1/energy_uj
MAXPKG=/sys/class/powercap/intel-rapl:0/max_energy_range_uj

CT=""; FAN0=""; FAN1=""
for h in /sys/class/hwmon/hwmon*/; do
    n=$(cat "$h/name" 2>/dev/null)
    case "$n" in
        coretemp) CT="$h" ;;
        honor_ec) FAN0="$h/fan1_input"; FAN1="$h/fan2_input" ;;
    esac
done
TEMP="${CT}temp1_input"
MAXP=$(cat "$MAXPKG" 2>/dev/null || echo 0)

rd() { cat "$1" 2>/dev/null || echo 0; }
# delta in microjoules, wrap-aware
dE() { local a="$1" b="$2"; local d=$((b-a)); (( d < 0 )) && d=$((d + MAXP)); echo "$d"; }

echo "ts,package_W,core_W,uncore_W,psys_W,temp_C,fan0,fan1" > "$LOG"

E0=$(rd "$PKG"); C0=$(rd "$COR"); U0=$(rd "$UNC"); P0=$(rd "$PSYS")
T0=$(date +%s)

while true; do
    sleep "$INT"
    E1=$(rd "$PKG"); C1=$(rd "$COR"); U1=$(rd "$UNC"); P1=$(rd "$PSYS")
    T1=$(date +%s); D=$((T1-T0)); (( D < 1 )) && D=1
    PW=$(awk -v d="$(dE "$E0" "$E1")" -v s="$D" 'BEGIN{printf "%.1f", d/s/1000000}')
    CW=$(awk -v d="$(dE "$C0" "$C1")" -v s="$D" 'BEGIN{printf "%.1f", d/s/1000000}')
    UW=$(awk -v d="$(dE "$U0" "$U1")" -v s="$D" 'BEGIN{printf "%.1f", d/s/1000000}')
    SW=$(awk -v d="$(dE "$P0" "$P1")" -v s="$D" 'BEGIN{printf "%.1f", d/s/1000000}')
    t=$(rd "$TEMP"); t=$((t/1000))
    f0=$(rd "$FAN0"); f1=$(rd "$FAN1")
    line="$(date +%H:%M:%S),$PW,$CW,$UW,$SW,$t,$f0,$f1"
    echo "$line" | tee -a "$LOG"
    E0=$E1; C0=$C1; U0=$U1; P0=$P1; T0=$T1
done
