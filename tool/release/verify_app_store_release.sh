#!/usr/bin/env bash
set -euo pipefail
ROOT_SYNC="/Users/parcool/AndroidStudioProjects/velock_sync"
ROOT_CODEX="/Users/parcool/AndroidStudioProjects/velock_codex"
OUT="${1:-/tmp/velock-appstore-release}"
rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string><key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>45G9263U49</string><key>uploadSymbols</key><true/><key>compileBitcode</key><false/>
</dict></plist>
PLIST
for spec in "sync:$ROOT_SYNC:velock-sync" "codex:$ROOT_CODEX:velock-codex"; do
 IFS=: read -r name root outname <<<"$spec"
 xcodebuild -workspace "$root/ios/Runner.xcworkspace" -scheme Runner -configuration Release \
   -archivePath "$OUT/$outname.xcarchive" -allowProvisioningUpdates archive
 xcodebuild -exportArchive -archivePath "$OUT/$outname.xcarchive" \
   -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/$outname-export"
 app="$OUT/$outname-export/Payload/Runner.app"
 codesign --verify --deep --strict "$app"
 echo "PASS $name: $OUT/$outname-export"
done
