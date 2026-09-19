#!/usr/bin/env bash
# Archive and verify App Store releases for Velock Sync (and, when available,
# the Velock companion) and verify code signing of the exported apps.
#
# Usage:
#   tool/release/verify_app_store_release.sh [output-dir]
#
# Environment:
#   VELOCK_SYNC_ROOT   Repository root of velock_sync (default: derived from
#                      the location of this script)
#   VELOCK_CODEX_ROOT  Repository root of velock_codex (default: the sibling
#                      directory ../velock_codex; skipped when not present)
#   VELOCK_TEAM_ID     Apple Team ID used for App Store Connect export
#                      (required; e.g. from Xcode > Signing & Capabilities)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SYNC="${VELOCK_SYNC_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
ROOT_CODEX="${VELOCK_CODEX_ROOT:-$(cd "$ROOT_SYNC/.." && pwd)/velock_codex}"
OUT="${1:-/tmp/velock-appstore-release}"

: "${VELOCK_TEAM_ID:?set VELOCK_TEAM_ID to the Apple Team ID for App Store Connect export}"

if [[ ! -d "$ROOT_SYNC/ios/Runner.xcworkspace" ]]; then
  echo "velock_sync Xcode workspace not found under $ROOT_SYNC/ios" >&2
  exit 2
fi

rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string><key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>${VELOCK_TEAM_ID}</string><key>uploadSymbols</key><true/><key>compileBitcode</key><false/>
</dict></plist>
PLIST

specs=("sync:$ROOT_SYNC:velock-sync")
if [[ -d "$ROOT_CODEX/ios/Runner.xcworkspace" ]]; then
  specs+=("codex:$ROOT_CODEX:velock-codex")
else
  echo "SKIP codex: $ROOT_CODEX not found (set VELOCK_CODEX_ROOT to include it)"
fi

for spec in "${specs[@]}"; do
  IFS=: read -r name root outname <<<"$spec"
  xcodebuild -workspace "$root/ios/Runner.xcworkspace" -scheme Runner -configuration Release \
    -archivePath "$OUT/$outname.xcarchive" -allowProvisioningUpdates archive
  xcodebuild -exportArchive -archivePath "$OUT/$outname.xcarchive" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/$name-export"
  app="$OUT/$name-export/Payload/Runner.app"
  codesign --verify --deep --strict "$app"
  echo "PASS $name: $OUT/$name-export"
done
