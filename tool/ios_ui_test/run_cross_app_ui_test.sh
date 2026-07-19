#!/usr/bin/env bash
set -euo pipefail

DEVICE_ID="${IOS_SIMULATOR_UDID:-26CC5821-DEF4-47D3-978D-A11D7293AD61}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VELOCK_ROOT="${VELOCK_ROOT:-$ROOT_DIR/../velock_codex}"
VELOCK_PASSWORD="${VELOCK_RUNTIME_PASSWORD:-}"

if [[ -z "$VELOCK_PASSWORD" ]]; then
  echo "Set VELOCK_RUNTIME_PASSWORD for the runtime unlock step." >&2
  exit 2
fi

if ! xcrun simctl list devices | grep -Fq "$DEVICE_ID"; then
  echo "Simulator not found: $DEVICE_ID" >&2
  exit 3
fi

mkdir -p "$ROOT_DIR/ui_test_results" "$HOME/Downloads"

echo "Building/installing Velock Sync..."
(cd "$ROOT_DIR" && flutter build ios --simulator --debug)
xcrun simctl install "$DEVICE_ID" "$ROOT_DIR/build/ios/iphonesimulator/Runner.app"

if [[ ! -d "$VELOCK_ROOT/build/ios/iphonesimulator/Runner.app" ]]; then
  echo "Build Velock first: $VELOCK_ROOT/build/ios/iphonesimulator/Runner.app" >&2
  exit 4
fi
xcrun simctl install "$DEVICE_ID" "$VELOCK_ROOT/build/ios/iphonesimulator/Runner.app"

VIDEO_PATH="${UI_TEST_VIDEO_PATH:-$HOME/Downloads/velock-sync-ui-test.mp4}"
rm -f "$VIDEO_PATH"
xcrun simctl io "$DEVICE_ID" recordVideo --codec=h264 --mask=black --force "$VIDEO_PATH" &
RECORD_PID=$!
trap 'kill -INT "$RECORD_PID" 2>/dev/null || true; wait "$RECORD_PID" 2>/dev/null || true' EXIT

echo "Running the black-box test. The runtime password is passed only to the test process."
VELOCK_RUNTIME_PASSWORD="$VELOCK_PASSWORD" \
  xcodebuild test \
    -project "$ROOT_DIR/ui_test_harness/CrossAppUITests.xcodeproj" \
    -scheme CrossAppUITests \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -resultBundlePath "$ROOT_DIR/ui_test_results/CrossAppUITests.xcresult"

kill -INT "$RECORD_PID" 2>/dev/null || true
wait "$RECORD_PID" 2>/dev/null || true
trap - EXIT

test -s "$VIDEO_PATH"
file "$VIDEO_PATH"
echo "Video saved to $VIDEO_PATH"
