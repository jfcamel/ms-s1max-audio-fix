#!/bin/sh
# Installer for the Minisforum MS-S1 MAX Linux audio fix (Realtek ALC245).
# Installs a HDA patch firmware + modprobe option; kernel-version independent.
set -eu

FW_NAME=hda-ms-s1max.fw
CONF_NAME=hda-ms-s1max.conf
SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FORCE=${1:-}

info()  { printf '\033[1;32m*\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31mE\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root: sudo $0"

# --- hardware verification -------------------------------------------------
product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
codec_ok=no
for c in /proc/asound/card*/codec#*; do
    [ -r "$c" ] || continue
    if grep -q '^Subsystem Id: 0x1f4cb026' "$c" && grep -q 'Realtek ALC245' "$c"; then
        codec_ok=yes
        break
    fi
done

if [ "$product" != "MS-S1 MAX" ] || [ "$codec_ok" != yes ]; then
    warn "hardware mismatch: DMI product='$product', ALC245(0x1f4cb026) found=$codec_ok"
    if [ "$FORCE" = "--force" ]; then
        warn "--force given, installing anyway"
    else
        die "this fix is specific to the Minisforum MS-S1 MAX; use --force to override"
    fi
fi

# --- kernel capability check ----------------------------------------------
if [ -r /proc/config.gz ]; then
    if zgrep -q '^CONFIG_SND_HDA_PATCH_LOADER=y' /proc/config.gz; then
        info "kernel has CONFIG_SND_HDA_PATCH_LOADER=y"
    else
        die "kernel lacks CONFIG_SND_HDA_PATCH_LOADER — the patch cannot load. Rebuild the kernel with it enabled."
    fi
else
    warn "cannot verify CONFIG_SND_HDA_PATCH_LOADER (/proc/config.gz missing); assuming enabled"
fi

# --- install ---------------------------------------------------------------
install -D -m 0644 "$SRC_DIR/firmware/$FW_NAME" "/lib/firmware/$FW_NAME"
info "installed /lib/firmware/$FW_NAME"
install -D -m 0644 "$SRC_DIR/modprobe.d/$CONF_NAME" "/etc/modprobe.d/$CONF_NAME"
info "installed /etc/modprobe.d/$CONF_NAME"

# --- optional: ALSA -> PipeWire bridge (needed at least on Gentoo) ---------
share_d=/usr/share/alsa/alsa.conf.d
etc_d=/etc/alsa/conf.d
if [ -f "$share_d/50-pipewire.conf" ] && [ ! -e "$etc_d/50-pipewire.conf" ] \
   && grep -q "$etc_d" /usr/share/alsa/alsa.conf 2>/dev/null \
   && ! grep -q "$share_d" /usr/share/alsa/alsa.conf 2>/dev/null; then
    mkdir -p "$etc_d"
    ln -sf "$share_d/50-pipewire.conf" "$etc_d/50-pipewire.conf"
    ln -sf "$share_d/99-pipewire-default.conf" "$etc_d/99-pipewire-default.conf"
    info "linked PipeWire ALSA bridge configs into $etc_d (plain arecord/aplay would fail without them)"
fi

echo
info "done. Reboot to apply, then verify with:"
echo "    sudo dmesg | grep -E \"patch firmware|autoconfig\""
info "and optionally apply recommended mixer levels:"
echo "    $SRC_DIR/scripts/set-recommended-mixer.sh"
