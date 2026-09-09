#!/usr/bin/env bash
# Report average package (RAPL) power over a number of seconds.
# Usage: measure-power.sh [seconds] [domain]   (default 5 s, package)
set -u
SECS="${1:-5}"
DOM="${2:-0}"                 # 0 = package, 1 = pp0 (IA cores), 2 = pp1 (GT/iGPU)

BASE="/sys/class/powercap/intel-rapl:${DOM}/energy_uj"
if [[ ! -r "$BASE" ]]; then
    echo "RAPL domain $DOM not available" >&2
    exit 1
fi

E0=$(cat "$BASE")
sleep "$SECS"
E1=$(cat "$BASE")

# energy_uj wraps at max_energy_range_uj; assume no wrap over SECS.
DELTA=$(( E1 - E0 ))
if (( DELTA < 0 )); then
    MAX=$(cat "/sys/class/powercap/intel-rapl:${DOM}/max_energy_range_uj" 2>/dev/null || echo 0)
    DELTA=$(( DELTA + MAX ))
fi

AVG=$(awk -v d="$DELTA" -v s="$SECS" 'BEGIN { printf "%.1f", d / s / 1000000 }')
echo "avg package power over ${SECS}s: ${AVG} W"
