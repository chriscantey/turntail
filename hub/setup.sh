#!/usr/bin/env bash
# Turntail hub setup. Idempotent. Run as root on a fresh Debian 13 machine.
#
#   HUB_FQDN=turntail.<tailnet>.ts.net TS_AUTHKEY=tskey-auth-... bash hub/setup.sh
set -euo pipefail

: "${HUB_FQDN:?set HUB_FQDN to the hub MagicDNS name}"
: "${TS_AUTHKEY:?set TS_AUTHKEY to a tagged (tag:hub) auth key}"
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)

log() { printf '\n== %s\n' "$*"; }

log "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q icecast2 curl ca-certificates gnupg sudo jq unzip rsync ffmpeg sox libsox-fmt-mp3 espeak-ng

log "tailscale"
if ! command -v tailscale >/dev/null; then
  t=$(mktemp); curl -fsSL https://tailscale.com/install.sh -o "$t"; sh "$t"; rm -f "$t"
fi
tailscale up --auth-key="$TS_AUTHKEY" --ssh --hostname="${HUB_FQDN%%.*}" --advertise-tags=tag:hub
tailscale set --auto-update=true
tailscale status --json | jq -r '.Self.DNSName'

log "secrets"
mkdir -p /etc/turntail
if [ ! -f /etc/turntail/hub.env ]; then
  gen() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }
  install -m 600 /dev/null /etc/turntail/hub.env
  cat > /etc/turntail/hub.env <<ENV
HUB_FQDN=$HUB_FQDN
ICECAST_SOURCE_PW=$(gen)
ICECAST_RELAY_PW=$(gen)
ICECAST_ADMIN_PW=$(gen)
APP_PORT=8080
ICECAST_URL=http://127.0.0.1:8000
SLOT_MINUTES=60
ENV
fi
# shellcheck disable=SC1091
source /etc/turntail/hub.env
[ -f /etc/turntail/stations.json ] || echo '[]' > /etc/turntail/stations.json

log "commands"
install -m 755 "$REPO_DIR/hub/turntail-hub.sh" /usr/local/sbin/turntail-hub
install -m 755 "$REPO_DIR/station/turntail-station.sh" /usr/local/bin/turntail-station

log "icecast on 127.0.0.1:8000"
install -D -m 644 "$REPO_DIR/hub/icecast.xml.tmpl" /usr/local/share/turntail/icecast.xml.tmpl
turntail-hub mounts
sed -i 's/^ENABLE=.*/ENABLE=true/' /etc/default/icecast2 2>/dev/null || true
systemctl enable icecast2 >/dev/null
systemctl restart icecast2
sleep 1
ss -ltnp | grep -q '127.0.0.1:8000' || { echo "icecast is not listening on 127.0.0.1:8000"; exit 1; }
if ss -ltn | grep ":8000" | grep -E -q "(0\.0\.0\.0|\[::\]):8000"; then echo "icecast is listening on a public address, refusing"; exit 1; fi

log "app user and bun"
id turntail >/dev/null 2>&1 || useradd -r -m -d /home/turntail -s /usr/sbin/nologin turntail
mkdir -p /opt/turntail/hub
rsync -a --delete --exclude data/ "$REPO_DIR/hub/app/" /opt/turntail/hub/app/
mkdir -p /opt/turntail/hub/app/data
chown -R turntail:turntail /opt/turntail
if [ ! -x /home/turntail/.bun/bin/bun ]; then
  t=$(mktemp); curl -fsSL https://bun.sh/install -o "$t"; chown turntail "$t"
  su -s /bin/bash turntail -c "bash $t"; rm -f "$t"
fi
/home/turntail/.bun/bin/bun --version

log "app service"
install -m 644 "$REPO_DIR/hub/systemd/turntail-hub.service" /etc/systemd/system/turntail-hub.service
systemctl daemon-reload
systemctl enable turntail-hub >/dev/null
systemctl restart turntail-hub
sleep 2
curl -s -o /dev/null -w "app on 127.0.0.1:$APP_PORT -> %{http_code}\n" "http://127.0.0.1:$APP_PORT/healthz"

log "hub sources: demo (spoken clock) and house (intermission loop), stations that run on the hub itself"
mkdir -p /var/lib/turntail/music /var/lib/turntail/music-normalized
hub_source() { # mount "Display name" bitrate source gain_dB
  jq -e --arg m "$1" 'map(select(.mount==$m)) | length > 0' /etc/turntail/stations.json >/dev/null || turntail-hub stations add "$1" "$2" >/dev/null
  local pw; pw=$(jq -r --arg m "$1" '.[] | select(.mount==$m) | .password' /etc/turntail/stations.json)
  if [ ! -f "/etc/turntail/$1.env" ]; then
    install -m 600 /dev/null "/etc/turntail/$1.env"
    printf 'HUB=127.0.0.1\nMOUNT=%s\nMOUNT_PW=%s\nALSA_DEVICE=none\nBITRATE=%s\nSOURCE=%s\nGAIN_DB=%s\nMUSIC_DIR=/var/lib/turntail/music-normalized\n' "$1" "$pw" "$3" "$4" "$5" > "/etc/turntail/$1.env"
  fi
}
hub_source demo "Spoken clock" 128k demo 0
hub_source house "Intermission" 256k music 0
install -m 644 "$REPO_DIR/hub/systemd/turntail-demo.service" /etc/systemd/system/turntail-demo.service
install -m 644 "$REPO_DIR/hub/systemd/turntail-house.service" /etc/systemd/system/turntail-house.service
systemctl daemon-reload
systemctl enable --now turntail-demo turntail-house >/dev/null
echo "drop MP3s in /var/lib/turntail/music and run: turntail-hub music normalize"

log "tailscale serve: 443 -> app with role capability forwarded, tcp 8000 -> icecast (stations only, by policy)"
tailscale serve --bg --accept-app-caps=turntail.internal/cap/role "http://127.0.0.1:$APP_PORT"
tailscale serve --bg --tcp=8000 tcp://127.0.0.1:8000
tailscale serve status

log "done: https://$HUB_FQDN/"
