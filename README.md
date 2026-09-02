# Minisforum MS-S1 MAX — Linux audio fix (Realtek ALC245)

Fixes broken onboard audio on the **Minisforum MS-S1 MAX** (AMD Strix Halo / Ryzen AI Max) under Linux:
front headphone jack output, TRRS headset microphone, and the front-panel **dual DMIC array** all work after applying this patch.

No kernel rebuild required — the fix is a HDA "patch firmware" file loaded by `snd-hda-intel`,
so it survives kernel upgrades.

## Supported hardware

| | |
|---|---|
| Machine | Minisforum MS-S1 MAX (board vendor "Shenzhen Meigao Electronic Equipment", DMI product `MS-S1 MAX`) |
| HDA controller | AMD Family 17h/19h/1ah HD Audio (`1022:15e3`) |
| Codec | Realtek ALC245, subsystem id `0x1f4cb026` |

The installer verifies both the DMI product name and the codec subsystem id and refuses to
install on other machines (override with `--force` at your own risk).

## What is broken on stock Linux

1. **The BIOS pin defaults do not match the actual board wiring.**
   The BIOS tells the codec that the headphone jack is on pin 0x21 and the mic jack on 0x19 —
   both are unwired on this board. The real jacks are wired to 0x17 (headphone out) and
   0x18 (jack-detect sense). As a result jack detection never fires, no analog output device
   appears, and the default capture source records floating-pin garbage.

2. **The Linux kernel cannot drive the ALC245 headset-mic circuitry.**
   Enabling a TRRS headset mic on Realtek codecs requires codec-specific COEF register
   sequences (`alc_headset_mode_*` in `sound/hda/codecs/realtek/realtek.c`). ALC245
   (`0x10ec0245`) is missing from those switch statements — its siblings ALC215/225/285/289/295/299
   are all handled. Verified still missing in torvalds/master as of 2026-09. Without the CTIA-mode
   COEF setup the headset mic is completely silent.

3. *(Gentoo-specific, not part of the firmware patch)* the PipeWire ALSA bridge configs live in
   `/usr/share/alsa/alsa.conf.d/` which `alsa.conf` does not read; plain `arecord`/`aplay`
   then fail with "No such file or directory". The installer offers to symlink them into
   `/etc/alsa/conf.d/`.

## What the patch does

`firmware/hda-ms-s1max.fw` is applied by the kernel's HDA patch loader at codec probe
(and re-applied on S3 resume):

* `[pincfg]` — corrects the pin configuration:

  | Pin | Stock BIOS value | Patched | Meaning |
  |---|---|---|---|
  | 0x12 | `0x90a60120` | unchanged | internal stereo DMIC array (BIOS was right about this one) |
  | 0x17 | disabled | `0x0221401f` | **real** front headphone output |
  | 0x19 | mic jack w/ jack-detect | `0x02a19130` | headset mic, no-presence (its sense line is unwired) |
  | 0x18, 0x1a, 0x21 | various | disabled | unwired / sense-only pins that confuse the driver |

* `[verb]` — writes the ALC225-family **CTIA headset mode** COEF sequence that the kernel
  never applies for ALC245: `coef 0x45=0xd689`, `0x4a=0xa1f0`, `0x67=0x3000`,
  `0x63=0x8000` (bits 15:14 = 2 is the critical one — value 1 leaves the mic dead),
  plus coefex `0x57:05 = 0x3680`. The codec's own impedance auto-detection was used to
  confirm the jack is CTIA-wired.

Result:

* Front jack: headphone output **and** TRRS headset mic (jack presence detection works for the
  headphone side; the mic port is always selectable because its sense line is not wired).
* Front-panel dual DMIC (stereo, high sensitivity) as the default capture source — wired
  directly to the codec, no AMD ACP / SOF involved (the ACP PCI function is BIOS-disabled
  on this board).

## Install

```sh
git clone https://github.com/jfcamel/ms-s1max-audio-fix
cd ms-s1max-audio-fix
sudo ./install.sh
# reboot, then (optionally) apply recommended mixer levels:
./scripts/set-recommended-mixer.sh
```

Requirements: `CONFIG_SND_HDA_PATCH_LOADER=y` (checked by the installer; enabled in most
distro kernels).

Uninstall with `sudo ./uninstall.sh` and reboot — this returns you to the broken BIOS defaults.

## Verify

```sh
sudo dmesg | grep -E 'patch firmware|autoconfig'
# expect: "Applying patch firmware 'hda-ms-s1max.fw'"
#         "autoconfig for ALC245: line_outs=1 (0x17/...) type:hp"
#         "inputs: Internal Mic=0x12 / Mic=0x19"

arecord -f S16_LE -r 48000 -c 2 -d 5 /tmp/t.wav && aplay /tmp/t.wav
```

Capture ports exposed via PipeWire/PulseAudio:
`Internal Microphone` (DMIC array, default) and `Microphone` (headset jack).

## Known limitations

* No plug/unplug auto-detection for the headset **mic** port (the board does not wire that
  sense line to the pin carrying mic audio) — select the port manually when you want the
  headset mic instead of the DMICs.
* Capture has a large DC offset / infrasonic drift component (99.6 % of noise energy is
  below 50 Hz). Inaudible and harmless for speech tools; high-pass it if it bothers you.
* A BIOS update that changes the pin tables may change the picture — re-verify after BIOS
  updates.

## Upstreaming

The proper fix belongs in the kernel:

1. add `case 0x10ec0245:` to the ALC225-family groups in `alc_headset_mode_unplugged` /
   `alc_headset_mode_ctia` / `alc_headset_mode_omtp` / `alc_headset_mode_mic_in` /
   `alc_determine_headset_type` (`sound/hda/codecs/realtek/realtek.c`);
2. add `SND_PCI_QUIRK(0x1f4c, 0xb026, "Minisforum MS-S1 MAX", ...)` with the pin fixups
   above chained to the headset-mode fixup.

Until that lands, this firmware patch is the workaround (and it stays harmless afterwards —
it just re-applies the same values).

## How this was diagnosed

Full write-up (in Japanese) with the complete evidence chain — pin-sense probing with
`hda-verb`, live codec reconfiguration via `/sys/class/sound/hwC1D0/`, and an acoustic
loopback method (play a 440 Hz tone through the HDMI monitor speakers, detect it in the
capture path via DFT) that separates real microphones from floating-pin noise:
[docs/ms-s1max-audio-fix.ja.md](docs/ms-s1max-audio-fix.ja.md)

## License

MIT
