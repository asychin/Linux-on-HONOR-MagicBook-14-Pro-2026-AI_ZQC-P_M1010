#!/usr/bin/env bash
# Watch every path a HONOR hotkey can take and report what each key press
# produced. Read-only: it listens, it changes nothing.
#
#   sudo bash patch/hotkeys/capture-keys.sh              # until Ctrl-C
#   sudo DURATION=180 bash patch/hotkeys/capture-keys.sh # for three minutes
#
# Three things can happen when you press an Fn key:
#
#   WMI unmapped     the driver got it and has no name for it. This is the
#                    interesting case: send it in and it gets mapped.
#   WMI mapped       it arrived as a key event. If nothing happens on screen,
#                    the desktop is what is ignoring it.
#   atkbd            it came over the PS/2 keyboard rather than WMI.
#   nothing at all   the EC handled it itself and told nobody. Nothing to map.
#
# Rather than streaming, this takes a journal cursor at the start and reads
# back from it at the end: output redirected to a file would otherwise be block
# buffered and lose the tail.

set -uo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi
command -v evtest >/dev/null || {
    echo "evtest is not installed." >&2
    echo "  Arch/CachyOS: pacman -S evtest      Debian/Ubuntu: apt install evtest" >&2
    exit 1
}

DURATION="${DURATION:-0}"
WORK=$(mktemp -d /tmp/honor-keycap-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

WMI_DEV="" ATK_DEV="" WMI_NAME="" ATK_NAME=""
for d in /sys/class/input/event*; do
    n="$(cat "$d/device/name" 2>/dev/null || true)"
    case "$n" in
        *"WMI hotkeys"*)   WMI_DEV="/dev/input/$(basename "$d")"; WMI_NAME="$n" ;;
        *"AT Translated"*) ATK_DEV="/dev/input/$(basename "$d")"; ATK_NAME="$n" ;;
    esac
done

echo "  WMI hotkeys : ${WMI_DEV:-not found}  ${WMI_NAME}"
echo "  keyboard    : ${ATK_DEV:-not found}  ${ATK_NAME}"
echo

CURSOR="$(journalctl -k -n1 --show-cursor -o cat 2>/dev/null | sed -n 's/^-- cursor: //p')"

for dev in "$WMI_DEV" "$ATK_DEV"; do
    [[ -n "$dev" ]] || continue
    tag=wmi; [[ "$dev" == "$ATK_DEV" ]] && tag=atkbd
    evtest "$dev" > "${WORK}/${tag}.log" 2>/dev/null &
done
EVPIDS=$(jobs -p)

finish() {
    trap - INT TERM
    echo
    kill $EVPIDS 2>/dev/null
    sleep 1

    echo "══════ mapped keys that arrived as events ══════"
    for tag in wmi atkbd; do
        [[ -s "${WORK}/${tag}.log" ]] || continue
        grep -E "value 1$" "${WORK}/${tag}.log" \
          | sed -E "s/.*code ([0-9]+) \(([A-Z_0-9]+)\).*/  ${tag}    \1 \2/" \
          | sort | uniq -c | sed 's/^ */  x/'
    done
    echo

    echo "══════ codes the driver has no name for ══════"
    if [[ -n "$CURSOR" ]]; then
        journalctl -k --after-cursor "$CURSOR" --no-pager 2>/dev/null \
          | grep -iE "Unknown key" \
          | sed -E 's/.*input input[0-9]+: /  WMI unmapped  /; s/.*atkbd serio0: /  atkbd  /' \
          | sort | uniq -c | sed 's/^ */  x/'
    else
        echo "  (could not take a journal cursor; run: journalctl -k | grep -i 'unknown key')"
    fi
    echo
    echo "  Anything under 'no name for' is a code worth sending in."
    rm -rf "$WORK"
    exit 0
}
trap finish INT TERM

if (( DURATION > 0 )); then
    echo "  Press the Fn keys now, one at a time. Collecting for ${DURATION}s."
    echo "  Worth covering: the whole F-row alone and with Fn, YOYO, performance"
    echo "  mode, keyboard backlight, camera shutter, touchpad lock."
    echo
    sleep "$DURATION"
    finish
else
    echo "  Press the Fn keys now, one at a time. Ctrl-C when done."
    echo
    wait
fi
