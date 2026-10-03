#!/usr/bin/env bash
# Raw + framed App Store screenshots for many app languages on one simulator,
# then the deliver folder (tool/store/screenshots/<App Store locale>/).
#
#   tool/store/all_shots.sh iphone <udid>[,<udid>…] [lang ...]
#
# Several comma-separated simulators run in parallel (UI automation is mostly
# waiting, so one simulator per language group cuts the wall time).
#
# Needs a simulator that already ran e2e.sh (paired Velock backup). Without
# languages it does all 18.
#
# Only reach for this when the app's own screens changed. If it is just the
# framing, recompose.sh re-renders from the raw captures already on disk in a
# couple of minutes without a simulator. `ipad` still works but the app is
# iPhone-only since 1.0.1, so the store has no iPad screenshots to fill.
set -euo pipefail
device="${1:?iphone}" udids="${2:?simulator udid[,udid…]}"; shift 2
here="$(cd "$(dirname "$0")" && pwd)" root="$(cd "$here/../.." && pwd)"
langs=("$@")
[[ ${#langs[@]} -gt 0 ]] || langs=(zh zh-Hant en ar de es fr hi id it ja ko nl pl pt ru tr vi)
[[ $device == ipad ]] && export E2E_SHOT_VELOCK=0
IFS=, read -r -a sims <<<"$udids"

shoot() { # udid lang
  local udid="$1" lang="$2"
  local raw="$root/ui_test_results/store/raw/$device-$lang" framed="$root/ui_test_results/store/framed/$device-$lang"
  # Explicit checks: `shoot … || …` turns off set -e inside the function.
  rm -rf "$raw"
  E2E_SIMULATOR_UDID="$udid" "$here/store_shots.sh" "$lang" "$raw" >/dev/null || return 1
  local expected=8; [[ $device == ipad ]] && expected=6
  [[ $(ls "$raw"/*.png 2>/dev/null | wc -l) -eq $expected ]] || return 1
  rm -rf "$framed"; python3 "$here/compose.py" "$raw" "$framed" "$lang" >/dev/null || return 1
  # Keep the committed captures current so recompose.sh works from a clone.
  if [[ $device == iphone ]]; then
    rm -rf "$here/raw/$lang"; mkdir -p "$here/raw/$lang"
    cp "$raw"/*.png "$here/raw/$lang/"
  fi
  # App Store locales that show this app language.
  local locales locale f
  case $lang in
    zh) locales=(zh-Hans) ;; en) locales=(en-US en-GB en-AU en-CA) ;; ar) locales=(ar-SA) ;;
    de) locales=(de-DE) ;; nl) locales=(nl-NL) ;; es) locales=(es-ES es-MX) ;;
    fr) locales=(fr-FR fr-CA) ;; pt) locales=(pt-BR pt-PT) ;; *) locales=("$lang") ;;
  esac
  for locale in "${locales[@]}"; do
    mkdir -p "$here/screenshots/$locale"
    rm -f "$here/screenshots/$locale/$device-"*.png
    for f in "$framed"/*.png; do cp "$f" "$here/screenshots/$locale/$device-$(basename "$f")"; done
  done
  echo "ok   $device $lang ($(ls "$framed" | wc -l | tr -d ' ') frames)"
}

if [[ ${#sims[@]} == 1 ]]; then
  for lang in "${langs[@]}"; do shoot "${sims[0]}" "$lang" || { echo "FAIL $device $lang"; exit 1; }; done
  exit 0
fi

# Several simulators: one worker each, languages dealt round-robin. Each worker
# has its own port, results dir (DerivedData, logs) and demo cloud root; the
# mDNS names are registered once here.
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
dns-sd -P "Home NAS" _webdav._tcp local 5005 homenas.local 127.0.0.1 >/dev/null 2>&1 & pids+=($!)
dns-sd -P "Cloud" _webdav._tcp local 8080 cloud.local 127.0.0.1 >/dev/null 2>&1 & pids+=($!)
workers=()
for i in "${!sims[@]}"; do
  (
    export E2E_SHOT_NO_DNS=1 E2E_SHOT_SERVE_PORT=$((8080 + i))
    export E2E_OUT_DIR="$root/ui_test_results/sim/shots-$i"
    for ((j = i; j < ${#langs[@]}; j += ${#sims[@]})); do
      shoot "${sims[$i]}" "${langs[$j]}" || echo "FAIL $device ${langs[$j]} (log: $E2E_OUT_DIR/testStoreShots.log)"
    done
  ) & workers+=($!)
done
wait "${workers[@]}"
