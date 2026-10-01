#!/usr/bin/env bash
# turntail-hub: everything an admin does on the hub, one command. Run with sudo. Installed by hub/setup.sh.
#
#   turntail-hub status                             services, mounts and listeners, who is live
#   turntail-hub stations add <mount> "<Name>"      create a station mount, prints its password ONCE
#   turntail-hub stations list
#   turntail-hub stations remove <mount>
#   turntail-hub demo on|off                        run or stop the spoken-clock source
#   turntail-hub music on|off                       run or stop the intermission loop source
#   turntail-hub music normalize                    re-normalize /var/lib/turntail/music into music-normalized (run after adding files)
#   turntail-hub logs [hub|demo|music|icecast]      follow a journal (default hub)
#   turntail-hub deploy [repo-dir]                  copy hub/app from the repo into place and restart the app
#   turntail-hub backup > file.tgz                  /etc/turntail as a tarball on stdout
#   turntail-hub mounts                             re-render icecast.xml from the template and stations.json (internal)
set -euo pipefail
STATIONS=/etc/turntail/stations.json
HUB_ENV=/etc/turntail/hub.env
READERS=/etc/turntail/icecast-readers
ICECAST_CONF=/etc/icecast2/icecast.xml
ICECAST_TMPL=/usr/local/share/turntail/icecast.xml.tmpl
APP_DIR=/opt/turntail/hub/app
MUSIC=/var/lib/turntail/music
MUSIC_NORM=/var/lib/turntail/music-normalized
SELF=$(readlink -f "$0")

usage() { sed -n '4,14p' "$SELF" | sed 's/^# \{0,3\}//'; exit 2; }
need_root() { [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }; }
app_port() { grep -s '^APP_PORT=' /etc/turntail/hub.env | cut -d= -f2 || true; }

# Secrets go through the environment, never argv.
render_mounts() {
  [ -f "$STATIONS" ] || echo '[]' > "$STATIONS"
  chown root:root /etc/turntail; chmod 755 /etc/turntail
  grep -q '^ICECAST_READER_PW=' "$HUB_ENV" || echo "ICECAST_READER_PW=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)" >> "$HUB_ENV"
  chown root:root "$HUB_ENV"; chmod 600 "$HUB_ENV"
  install -d -m 755 /var/lib/turntail/icecast-web
  (
    set -a; source "$HUB_ENV"; set +a
    umask 027
    printf 'turntail:%s\n' "$(printf %s "$ICECAST_READER_PW" | md5sum | cut -d' ' -f1)" > "$READERS.tmp"
    chgrp icecast "$READERS.tmp"; mv "$READERS.tmp" "$READERS"
    MOUNTS=$(jq -r --arg f "$READERS" '.[] | "    <mount type=\"normal\">\n        <mount-name>/\(.mount)</mount-name>\n        <username>\(.mount)</username>\n        <password>\(.password)</password>\n        <max-listeners>200</max-listeners>\n        <stream-name>\(.name | @html)</stream-name>\n        <public>0</public>\n        <authentication type=\"htpasswd\">\n            <option name=\"filename\" value=\"\($f)\"/>\n            <option name=\"allow_duplicate_users\" value=\"1\"/>\n        </authentication>\n    </mount>"' "$STATIONS")
    export MOUNTS
    awk '
      function rep(s, k, v,   i) { while ((i = index(s, k)) > 0) s = substr(s, 1, i - 1) v substr(s, i + length(k)); return s }
      /<!-- MOUNTS -->/ { print ENVIRON["MOUNTS"]; next }
      { for (k in ENVIRON) if (k ~ /^(HUB_FQDN|ICECAST_(SOURCE|RELAY|ADMIN)_PW)$/) $0 = rep($0, "__" k "__", ENVIRON[k]); print }
    ' "$ICECAST_TMPL" > "$ICECAST_CONF.tmp"
    chgrp icecast "$ICECAST_CONF.tmp"; mv "$ICECAST_CONF.tmp" "$ICECAST_CONF"
  )
  echo "rendered $(jq length "$STATIONS") mounts into $ICECAST_CONF"
  if systemctl is-active -q icecast2; then systemctl reload icecast2; fi
}

apply_stations() {
  render_mounts >/dev/null
  chown turntail:turntail "$STATIONS"; chmod 640 "$STATIONS"
  systemctl restart turntail-hub
}

# LRA=20 keeps loudnorm linear (one gain per file). -nostdin because stdin is the file list.
normalize_music() {
  mkdir -p "$MUSIC_NORM"
  find "$MUSIC" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.m4a' -o -iname '*.ogg' \) -print0 | while IFS= read -r -d '' f; do
    out="$MUSIC_NORM/$(basename "${f%.*}").mp3"
    if [ -f "$out" ] && [ "$out" -nt "$f" ]; then continue; fi
    m=$(ffmpeg -nostdin -hide_banner -nostats -i "$f" -af loudnorm=I=-16:TP=-1.5:LRA=20:print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p')
    ii=$(echo "$m" | jq -r .input_i); tp=$(echo "$m" | jq -r .input_tp); lra=$(echo "$m" | jq -r .input_lra); th=$(echo "$m" | jq -r .input_thresh); off=$(echo "$m" | jq -r .target_offset)
    mode=$(ffmpeg -nostdin -hide_banner -nostats -loglevel info -y -i "$f" -af "loudnorm=I=-16:TP=-1.5:LRA=20:measured_I=$ii:measured_TP=$tp:measured_LRA=$lra:measured_thresh=$th:offset=$off:linear=true:print_format=json" -ar 48000 -c:a libmp3lame -b:a 256k "$out" 2>&1 | sed -n '/^{/,/^}/p' | jq -r .normalization_type)
    printf '%-48s in %6s LUFS -> out %s  %s\n' "$(basename "$f")" "$ii" "$(ffmpeg -nostdin -hide_banner -nostats -i "$out" -af ebur128=peak=true -f null - 2>&1 | grep -E '^\s+I:' | tail -1 | awk '{print $2, $3}')" "$mode"
  done
  for o in "$MUSIC_NORM"/*.mp3; do [ -e "$o" ] || continue; b=$(basename "${o%.*}"); ls "$MUSIC"/"$b".* >/dev/null 2>&1 || rm -f "$o"; done
  echo "done: $(ls "$MUSIC_NORM" | wc -l) files in $MUSIC_NORM"
  if systemctl is-active -q turntail-house; then systemctl restart turntail-house; echo "intermission source restarted with the new set"; fi
}

status() {
  printf '%-10s' services; for u in icecast2 turntail-hub turntail-demo turntail-house; do printf '%s=%s  ' "${u#turntail-}" "$(systemctl is-active "$u" 2>/dev/null || true)"; done; echo
  local mounts=""
  if [ -r "$HUB_ENV" ]; then
    mounts=$( (source "$HUB_ENV"; printf 'user = "admin:%s"\n' "$ICECAST_ADMIN_PW") | curl -s --max-time 3 -K - http://127.0.0.1:8000/admin/listmounts || true)
    if [[ "$mounts" == *"<icestats"* ]]; then
      echo "mounts    $(echo "$mounts" | sed 's/<source mount="\//\n/g' | sed -nE 's|^([^"]+)".*<listeners>([0-9]+)</listeners>.*|\1=\2|p' | paste -sd' ')"
    else echo "mounts    icecast not answering"; fi
  else echo "mounts    run with sudo to read Icecast"; fi
  local port; port=$(app_port); port=${port:-8080}
  local st; st=$(curl -s --max-time 3 -H 'Tailscale-User-Login: console@hub' -H 'Tailscale-User-Name: hub console' "http://127.0.0.1:$port/api/state" || true)
  if [ -n "$st" ] && echo "$st" | jq -e . >/dev/null 2>&1; then
    echo "$st" | jq -r '"live      " + (if .live then "\(.live.mount) since \(.live.since/1000 | todate)" + (if .live.until then " until \(.live.until/1000 | todate)" else " (no slot end, nobody waiting)" end) else "nobody, intermission " + (if .house.playing then "playing" elif .house.enabled then "on but no source" else "off" end) end)'
    echo "$st" | jq -r '"queue     " + (if (.queue|length)>0 then (.queue | map(.mount) | join(", ")) else "empty" end)'
    echo "$st" | jq -r '"listeners " + (if (.listeners|length)>0 then (.listeners | map(.name) | join(", ")) else "none" end)'
    echo "$st" | jq -r '"stations  " + (.stations | map("\(.mount)" + (if .source then " (source connected)" else "" end)) | join(", "))'
  else echo "app       not answering on 127.0.0.1:$port"; fi
}

case "${1:-}" in
  status) status;;
  stations)
    need_root; [ -f "$STATIONS" ] || echo '[]' > "$STATIONS"
    case "${2:-}" in
      add)
        mount=${3:?mount}; name=${4:?display name}
        [[ "$mount" =~ ^[a-z0-9-]{1,32}$ ]] || { echo "mount must be [a-z0-9-]{1,32}"; exit 2; }
        jq -e --arg m "$mount" 'map(select(.mount==$m)) | length == 0' "$STATIONS" >/dev/null || { echo "mount $mount exists"; exit 2; }
        pw=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)
        tmp=$(mktemp)
        jq --arg m "$mount" --arg n "$name" --arg p "$pw" '. + [{"mount":$m,"name":$n,"password":$p}]' "$STATIONS" > "$tmp" && mv "$tmp" "$STATIONS"
        apply_stations
        hub=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
        echo "station $mount added. Two more things make it a streamer:"
        echo "  1. a grant in the tailnet policy naming their login with ports 443 and 8000 and {\"role\":\"streamer\",\"mount\":\"$mount\"}"
        echo "  2. send them this line privately, with docs/broadcasting.md:"
        echo "     HUB=$hub MOUNT=$mount MOUNT_PW=$pw"
        ;;
      list) jq -r '.[] | "\(.mount)\t\(.name)"' "$STATIONS";;
      remove)
        mount=${3:?mount}
        tmp=$(mktemp); jq --arg m "$mount" 'map(select(.mount!=$m))' "$STATIONS" > "$tmp" && mv "$tmp" "$STATIONS"
        apply_stations
        echo "station $mount removed. Remove their grant from the tailnet policy too."
        ;;
      *) echo "usage: turntail-hub stations add <mount> \"<Name>\" | list | remove <mount>"; exit 2;;
    esac
    ;;
  demo)
    need_root
    case "${2:-}" in
      on) systemctl enable --now turntail-demo >/dev/null; echo "demo source running";;
      off) systemctl disable --now turntail-demo >/dev/null; echo "demo source stopped";;
      *) echo "usage: turntail-hub demo on|off"; exit 2;;
    esac
    ;;
  music)
    need_root
    case "${2:-}" in
      on) systemctl enable --now turntail-house >/dev/null; echo "intermission source running";;
      off) systemctl disable --now turntail-house >/dev/null; echo "intermission source stopped";;
      normalize) normalize_music;;
      *) echo "usage: turntail-hub music on|off|normalize"; exit 2;;
    esac
    ;;
  logs)
    case "${2:-hub}" in
      hub) journalctl -u turntail-hub -f -o cat;;
      demo) journalctl -u turntail-demo -f -o cat;;
      music) journalctl -u turntail-house -f -o cat;;
      icecast) journalctl -u icecast2 -f -o cat;;
      *) echo "usage: turntail-hub logs hub|demo|music|icecast"; exit 2;;
    esac
    ;;
  deploy)
    need_root
    repo=${2:-$(cd "$(dirname "$SELF")/.." 2>/dev/null && pwd)}
    [ -d "$repo/hub/app" ] || { echo "no hub/app under $repo. Pass the repo directory: turntail-hub deploy <repo dir>"; exit 1; }
    [ "${TURNTAIL_DEPLOYING:-}" = 1 ] || TURNTAIL_DEPLOYING=1 exec bash "$repo/hub/turntail-hub.sh" deploy "$repo"
    rsync -a --delete --exclude data/ "$repo/hub/app/" "$APP_DIR/"
    chown -R turntail:turntail /opt/turntail
    install -m 755 "$repo/hub/turntail-hub.sh" /usr/local/sbin/turntail-hub
    install -m 755 "$repo/station/turntail-station.sh" /usr/local/bin/turntail-station
    install -D -m 644 "$repo/hub/icecast.xml.tmpl" "$ICECAST_TMPL"
    for u in hub demo house; do install -m 644 "$repo/hub/systemd/turntail-$u.service" "/etc/systemd/system/turntail-$u.service"; done
    systemctl daemon-reload
    render_mounts
    systemctl restart turntail-hub
    sleep 2; curl -s -o /dev/null -w "app -> %{http_code}\n" "http://127.0.0.1:$(app_port)/healthz"
    echo "deployed $(cd "$repo" && git log -1 --format='%h %s' 2>/dev/null || echo "$repo"). Source units were reinstalled but not restarted (restart turntail-demo / turntail-house yourself if they changed)."
    ;;
  backup)
    need_root; tar czf - -C / etc/turntail
    ;;
  mounts)
    need_root; render_mounts
    ;;
  *) usage;;
esac
