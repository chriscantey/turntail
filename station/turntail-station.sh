#!/usr/bin/env bash
# turntail-station: one command for a station. Installed by station/setup.sh, and by the hub for its own two sources.
#
#   turntail-station source turntable|demo|music|off   choose what to push, restarts the service
#   turntail-station status                            source, service, hub reachability
#   turntail-station devices                           capture devices the kernel sees (arecord -l)
#   turntail-station test [seconds]                    record from the interface and report peak and mean level
#   turntail-station gain <dB>                         static gain before the limiter (default 0), restarts the service
#   turntail-station logs                              follow the service journal
#   turntail-station stream [env-file]                 what the service runs: push the chosen source to the hub
#   turntail-station testcard                          raw PCM test card on stdout (stream demo pipes this into ffmpeg)
#   turntail-station musicpcm                          raw PCM of the music folder on stdout, endless (stream music pipes this)
set -euo pipefail
ENV_FILE=${TURNTAIL_ENV:-/etc/turntail/station.env}
SELF=$(readlink -f "$0")

usage() { sed -n '4,12p' "$SELF" | sed 's/^# \{0,3\}//'; exit 2; }
need_root() { [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }; }
load_env() { [ -f "$ENV_FILE" ] || { echo "no $ENV_FILE, run station/setup.sh first"; exit 1; }; set -a; source "$ENV_FILE"; set +a; }
# Resolve the hub through tailscaled, not the owner's tailnet DNS.
hub_addr() { { tailscale ip -4 "${HUB%.}." 2>/dev/null || tailscale ip -4 "${HUB%%.*}" 2>/dev/null; } | head -1 | grep . || echo "${HUB}"; }
set_env() { # key value
  if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}

testcard() {
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  sox -n -r 48000 -c 2 -b 16 "$TMP/bed.wav" synth 15 sine 220 sine 330 remix - gain -20 fade t 0.5 15 0.5 2>/dev/null
  while true; do
    espeak-ng -v en-us -s 150 -w "$TMP/say.wav" "Turntail test card. The time is $(date "+%l:%M and %S seconds" | sed 's/^ //')" 2>/dev/null
    sox "$TMP/say.wav" -r 48000 -c 2 -b 16 "$TMP/say48.wav" gain -n -3 pad 1 2>/dev/null
    sox -m "$TMP/bed.wav" "$TMP/say48.wav" -r 48000 -c 2 -b 16 -t raw - trim 0 15 2>/dev/null || exit 1
  done
}

music_files() { find "$1" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.m4a' -o -iname '*.ogg' \) -print0; }

# After a failed file, one silent sample checks the reader is still there (SIGPIPE if not).
musicpcm() {
  DIR=${MUSIC_DIR:-/var/lib/turntail/music}
  while true; do
    ok=0
    while IFS= read -r -d '' f; do
      if ffmpeg -nostdin -hide_banner -loglevel error -i "$f" -vn -f s16le -ar 48000 -ac 2 - ; then ok=1
      else echo "decode failed, skipping: $f" >&2; printf '\0\0\0\0'; fi
    done < <(music_files "$DIR" | shuf -z)
    [ "$ok" = 1 ] || { echo "nothing decodable in $DIR" >&2; exit 1; }
  done
}

stream() {
  ENV_FILE=${1:-$ENV_FILE}; load_env
  URL="icecast://${MOUNT}:${MOUNT_PW}@$(hub_addr):8000/${MOUNT}"
  # Static gain, then a -2 dBTP ceiling (MP3 decoders overshoot about 1 dB).
  args() { # gain_dB -> the shared ffmpeg output arguments, in ARGS
    ARGS=(-hide_banner -loglevel warning -nostdin
      -af "aresample=async=1,volume=${1}dB,alimiter=limit=0.794:attack=5:release=50:level=false"
      -c:a libmp3lame -b:a "${BITRATE:-256k}" -ar 48000 -ac 2
      -content_type audio/mpeg -ice_name "${MOUNT}" -ice_description "Turntail station ${MOUNT}"
      -f mp3)
  }
  args "${GAIN_DB:-0}"; COMMON=("${ARGS[@]}")
  args "$(( ${GAIN_DB:-0} + 8 ))"; DEMO=("${ARGS[@]}")
  case "${SOURCE:-turntable}" in
    turntable)
      exec ffmpeg -f alsa -thread_queue_size 4096 -i "${ALSA_DEVICE}" "${COMMON[@]}" "$URL"
      ;;
    demo)
      SELF="$SELF" exec bash -o pipefail -c '"$SELF" testcard | ffmpeg -re -f s16le -ar 48000 -ac 2 -thread_queue_size 4096 -i pipe:0 "$@" "$0"' "$URL" "${DEMO[@]}"
      ;;
    music)
      DIR=${MUSIC_DIR:-/var/lib/turntail/music}
      [ -n "$(music_files "$DIR" | head -c1)" ] || { echo "no music files in $DIR, idling"; sleep 60; exit 0; }
      SELF="$SELF" MUSIC_DIR="$DIR" exec bash -o pipefail -c '"$SELF" musicpcm | ffmpeg -re -f s16le -ar 48000 -ac 2 -thread_queue_size 4096 -i pipe:0 "$@" "$0"' "$URL" "${COMMON[@]}"
      ;;
    off)
      echo "source is off, idling"; sleep infinity
      ;;
    *)
      echo "unknown SOURCE=${SOURCE}"; exit 2
      ;;
  esac
}

case "${1:-}" in
  source)
    need_root; load_env
    case "${2:-}" in
      turntable|demo|music|off) set_env SOURCE "$2"; systemctl restart turntail-station; echo "source set to $2";;
      *) echo "usage: turntail-station source turntable|demo|music|off"; exit 2;;
    esac
    ;;
  gain)
    need_root; load_env
    [[ "${2:-}" =~ ^-?[0-9]+$ ]] || { echo "usage: turntail-station gain <dB>   (for example 6, -3, 0)"; exit 2; }
    set_env GAIN_DB "$2"; systemctl restart turntail-station; echo "gain set to $2 dB (before the limiter). The stream restarted, listeners rejoin by themselves in a few seconds."
    ;;
  status)
    need_root; load_env
    echo "source   ${SOURCE:-turntable}   gain ${GAIN_DB:-0} dB   device ${ALSA_DEVICE:-?}   mount ${MOUNT} on ${HUB}"
    echo "service  $(systemctl is-active turntail-station 2>/dev/null || true)   $(systemctl show turntail-station -p ActiveEnterTimestamp --value 2>/dev/null)"
    if timeout 5 bash -c "</dev/tcp/$(hub_addr)/8000" 2>/dev/null; then echo "hub      ${HUB} ($(hub_addr)):8000 reachable"; else echo "hub      ${HUB}:8000 NOT reachable (share accepted on this login, login named in the hub policy, Tailscale up?)"; fi
    journalctl -u turntail-station -n 3 --no-pager -o cat 2>/dev/null | sed 's/^/log      /'
    ;;
  devices)
    arecord -l 2>/dev/null || echo "arecord found no capture devices"
    ;;
  test)
    need_root; load_env
    secs=${2:-5}; [[ "$secs" =~ ^[0-9]+$ ]] || { echo "usage: turntail-station test [seconds]"; exit 2; }
    wav=$(mktemp --suffix=.wav)
    echo "recording ${secs} s from ${ALSA_DEVICE} (the service keeps the device open, so this stops it briefly)"
    was=$(systemctl is-active turntail-station 2>/dev/null || true)
    trap 'rm -f "$wav"; [ "$was" = active ] && systemctl start turntail-station' EXIT INT TERM
    [ "$was" = active ] && systemctl stop turntail-station
    arecord -q -D "${ALSA_DEVICE}" -f S16_LE -r 48000 -c 2 -d "$secs" "$wav" || { echo "capture failed on ${ALSA_DEVICE}. turntail-station devices lists what exists."; exit 1; }
    ffmpeg -nostdin -hide_banner -i "$wav" -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume" | sed 's/.*\] //'
    echo "reading it: this is the input before gain. A record playing peaks above -20 dB. A silent groove or nothing plugged in should sit under -50 dB, hum shows as a higher floor."
    ;;
  logs)
    journalctl -u turntail-station -f -o cat
    ;;
  stream)
    stream "${2:-}"
    ;;
  musicpcm)
    musicpcm
    ;;
  testcard)
    testcard
    ;;
  *) usage;;
esac
