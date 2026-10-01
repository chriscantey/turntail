#!/usr/bin/env bash
# Turntail station setup. Idempotent. Run as root on a Debian or Raspberry Pi OS box next to a turntable.
#
#   HUB=turntail.<tailnet>.ts.net MOUNT=alice MOUNT_PW=... bash station/setup.sh
set -euo pipefail
: "${HUB:?hub MagicDNS name}"; : "${MOUNT:?mount name}"; : "${MOUNT_PW:?mount password}"
# First USB capture card by ALSA card id (stable across reboots). Override with ALSA_DEVICE=hw:CARD=<id>,DEV=0.
detect_capture() { arecord -l 2>/dev/null | sed -n 's/^card [0-9]*: \([A-Za-z0-9_]*\) \[.*USB.*/\1/p' | head -1; }
ALSA_DEVICE=${ALSA_DEVICE:-}
HERE=$(cd "$(dirname "$0")" && pwd)
log() { printf '\n== %s\n' "$*"; }

log "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ffmpeg alsa-utils curl ca-certificates jq espeak-ng sox libsox-fmt-mp3 >/dev/null

log "tailscale"
if ! command -v tailscale >/dev/null; then
  t=$(mktemp); curl -fsSL https://tailscale.com/install.sh -o "$t"; sh "$t"; rm -f "$t"
fi
if ! tailscale status >/dev/null 2>&1; then
  echo "Log this device in to YOUR tailnet (the one you accepted the share with):"
  tailscale up --reset --hostname="${MOUNT}-station"
fi
tailscale set --auto-update=true --accept-dns=false
tailscale status --peers=false
HUB_ADDR=$( (tailscale ip -4 "${HUB%.}." 2>/dev/null || tailscale ip -4 "${HUB%%.*}" 2>/dev/null) | head -1 || true); HUB_ADDR=${HUB_ADDR:-$HUB}
echo "checking the hub's source port over the share ($HUB is $HUB_ADDR here)"
timeout 8 bash -c "</dev/tcp/$HUB_ADDR/8000" && echo "hub port 8000 reachable" || { echo "cannot reach $HUB:8000. Check that this Pi is logged in to the Tailscale account that accepted the hub's share, and that the hub owner has added that login. Then run setup again."; exit 1; }

log "config"
mkdir -p /etc/turntail /var/lib/turntail/music
if [ -f /etc/turntail/station.env ]; then
  sed -i "s|^HUB=.*|HUB=$HUB|; s|^MOUNT=.*|MOUNT=$MOUNT|; s|^MOUNT_PW=.*|MOUNT_PW=$MOUNT_PW|" /etc/turntail/station.env
else
  install -m 600 /dev/null /etc/turntail/station.env
  cat > /etc/turntail/station.env <<ENV
HUB=$HUB
MOUNT=$MOUNT
MOUNT_PW=$MOUNT_PW
ALSA_DEVICE=$ALSA_DEVICE
BITRATE=256k
SOURCE=turntable
GAIN_DB=0
ENV
fi
chmod 600 /etc/turntail/station.env

log "capture device"
if [ -z "$ALSA_DEVICE" ]; then
  id=$(detect_capture)
  if [ -n "$id" ]; then ALSA_DEVICE="hw:CARD=$id,DEV=0"; echo "using $ALSA_DEVICE ($(arecord -l | grep -m1 "^card [0-9]*: $id " | sed 's/^card [0-9]*: //'))"
  else ALSA_DEVICE="hw:CARD=CODEC,DEV=0"; echo "WARNING: no USB audio capture device found. Plug the interface in and run setup again."; fi
  sed -i "s|^ALSA_DEVICE=.*|ALSA_DEVICE=$ALSA_DEVICE|" /etc/turntail/station.env
fi

log "turntail-station command"
install -m 755 "$HERE/turntail-station.sh" /usr/local/bin/turntail-station

log "usb audio never autosuspends, journal capped for the SD card"
cat > /etc/udev/rules.d/90-turntail-usb-audio.rules <<'RULE'
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="01", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="08bb", TEST=="power/control", ATTR{power/control}="on"
RULE
udevadm control --reload 2>/dev/null || true
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=64M\n' > /etc/systemd/journald.conf.d/turntail.conf
systemctl restart systemd-journald 2>/dev/null || true

log "service"
install -m 644 "$HERE/systemd/turntail-station.service" /etc/systemd/system/turntail-station.service
systemctl daemon-reload
systemctl enable turntail-station >/dev/null
systemctl restart turntail-station
sleep 3
systemctl --no-pager --lines=5 status turntail-station | tail -6
log "done. Next: sudo turntail-station test 10 with a record playing, then Go live on the page."
