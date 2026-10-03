#!/usr/bin/env bash
# Re-frame the App Store screenshots from the raw simulator captures that are
# already on disk — no simulator, no UI automation, ~2 minutes for all 18
# languages. This is the path to use whenever only the framing changes (style,
# device chrome, caption layout).
#
#   tool/store/recompose.sh [style] [lang ...]
#
# style defaults to the shipping one (see STYLES in compose.py). Without
# languages it does all 18.
#
# The raw captures are committed under tool/store/raw/<lang>/ so this works
# from a fresh clone; all_shots.sh refreshes them when the app's screens change
# (it also leaves a copy in the gitignored ui_test_results/store/raw/, which is
# used as a fallback here).
#
# Writes ui_test_results/store/framed/<device>-<lang>/ and copies into the
# deliver folder tool/store/screenshots/<App Store locale>/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)" root="$(cd "$here/../.." && pwd)"
style="${1:-deep}"; shift || true
langs=("$@")
[[ ${#langs[@]} -gt 0 ]] || langs=(zh zh-Hant en ar de es fr hi id it ja ko nl pl pt ru tr vi)

# One app language can appear under several App Store locales.
locales_for() {
  case "$1" in
    zh) echo zh-Hans ;; en) echo "en-US en-GB en-AU en-CA" ;; ar) echo ar-SA ;;
    de) echo de-DE ;; nl) echo nl-NL ;; es) echo "es-ES es-MX" ;;
    fr) echo "fr-FR fr-CA" ;; pt) echo "pt-BR pt-PT" ;; *) echo "$1" ;;
  esac
}

# iPhone only: the app is iPhone-only since 1.0.1 (TARGETED_DEVICE_FAMILY = 1),
# so the store has no iPad display type to fill.
total=0 missing=0
for lang in "${langs[@]}"; do
  raw="$here/raw/$lang"
  [[ -d $raw ]] || raw="$root/ui_test_results/store/raw/iphone-$lang"
  if [[ ! -d $raw ]]; then
    echo "MISSING tool/store/raw/$lang — run all_shots.sh for '$lang' first"
    missing=$((missing + 1)); continue
  fi
  framed="$root/ui_test_results/store/framed/iphone-$lang"
  rm -rf "$framed"
  n=$(python3 "$here/compose.py" "$raw" "$framed" "$lang" "$style" | awk '{print $1}')
  [[ $n -eq 8 ]] || { echo "FAIL $lang: $n frames, expected 8"; exit 1; }
  total=$((total + n))
  for locale in $(locales_for "$lang"); do
    mkdir -p "$here/screenshots/$locale"
    rm -f "$here/screenshots/$locale/iphone-"*.png
    for f in "$framed"/*.png; do cp "$f" "$here/screenshots/$locale/iphone-$(basename "$f")"; done
  done
  echo "ok   $lang"
done
echo "$total frames in style '$style'; $missing language(s) had no raw captures"
[[ $missing -eq 0 ]]
