#!/bin/sh
# Sets recommended capture mixer levels for the MS-S1 MAX audio fix and saves them.
# Run as your normal user after the patched codec is active (i.e. after reboot).
set -eu

# find the card whose codec is the ALC245 with the MS-S1 MAX subsystem id
card=""
for c in /proc/asound/card*/codec#*; do
    [ -r "$c" ] || continue
    if grep -q '^Subsystem Id: 0x1f4cb026' "$c"; then
        card=$(printf '%s' "$c" | sed 's|/proc/asound/card\([0-9]*\)/.*|\1|')
        break
    fi
done
[ -n "$card" ] || { echo "ALC245 (0x1f4cb026) not found" >&2; exit 1; }

echo "using sound card $card"
# DMIC array: +10dB keeps loud speech below clipping
amixer -q -c "$card" cset name='Internal Mic Boost Volume' 1,1 || true
# TRRS headset mic: +20dB
amixer -q -c "$card" cset name='Mic Boost Volume' 2,2 || true
amixer -q -c "$card" cset name='Capture Volume' 63,63 || true
amixer -q -c "$card" cset name='Capture Switch' on,on || true

if [ "$(id -u)" = 0 ]; then
    alsactl store && echo "levels set and stored"
else
    echo "levels set. To persist across reboots run: sudo alsactl store"
fi
