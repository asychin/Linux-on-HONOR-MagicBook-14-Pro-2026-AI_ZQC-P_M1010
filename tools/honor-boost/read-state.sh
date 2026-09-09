#!/usr/bin/env bash
# Read boost-relevant EC state through the honor-ec-rail sysfs interface.
set -u
B=/sys/kernel/honor-ec-rail
if [[ ! -d "$B" ]]; then
    echo "honor-ec-rail not loaded; run: sudo insmod honor-ec-rail.ko" >&2
    exit 1
fi
printf '%-12s %-6s\n' "field" "value"
printf '%-12s %-6s\n' "-----------" "-----"
for f in crwm ec_cpu_temp fan0 fan1 svft ftsl fwmd scpm vccc vccg vccs vccl ppl4 vrss vr10 vr12 vr14 vr16; do
    v="$(cat "$B/$f" 2>/dev/null || echo 'n/a')"
    printf '%-12s %-6s\n' "$f" "$v"
done
