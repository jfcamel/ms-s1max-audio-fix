#!/bin/sh
# Removes the MS-S1 MAX audio fix. Reboot afterwards to return to BIOS defaults
# (which are broken on this board — this is only useful for debugging or before
# testing a kernel-side fix).
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

rm -f /lib/firmware/hda-ms-s1max.fw /etc/modprobe.d/hda-ms-s1max.conf
echo "removed. Reboot to apply."
echo "note: /etc/alsa/conf.d/{50,99}-pipewire*.conf symlinks (if the installer created them)"
echo "are generic PipeWire configuration, not specific to this fix, and were left in place."
