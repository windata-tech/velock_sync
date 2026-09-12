#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
XCODEBUILDMCP_BIN="${XCODEBUILDMCP_BIN:-/opt/homebrew/bin/xcodebuildmcp}"
WEBDAV_PORT="${E2E_WEBDAV_PORT:-18992}"
WEBDAV_BIN="${E2E_WEBDAV_BIN:-$ROOT_DIR/ui_test_results/webdav_venv/bin/wsgidav}"

if [[ ! -x "$XCODEBUILDMCP_BIN" ]]; then
  echo "XcodeBuildMCP CLI not found: $XCODEBUILDMCP_BIN" >&2
  exit 2
fi
if [[ ! -x "$WEBDAV_BIN" ]]; then
  echo "WsgiDAV executable not found: $WEBDAV_BIN" >&2
  exit 3
fi

SOURCE_SIMULATOR_ID="${E2E_SIMULATOR_UDID:-}"
if [[ -z "$SOURCE_SIMULATOR_ID" ]]; then
  SOURCE_SIMULATOR_ID="$(xcrun simctl list devices booted -j | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime in data.get("devices", {}).values():
    for device in runtime:
        if device.get("state") == "Booted":
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
')" || {
    echo "No booted iOS Simulator found. Boot one or set E2E_SIMULATOR_UDID." >&2
    exit 4
  }
fi
REPLICA_SIMULATOR_ID="${E2E_REPLICA_SIMULATOR_UDID:-22842F80-E053-41F7-8872-9EB08D9C54F9}"
if [[ "$SOURCE_SIMULATOR_ID" == "$REPLICA_SIMULATOR_ID" ]]; then
  echo "Source and replica must be different simulators." >&2
  exit 4
fi
if ! xcrun simctl list devices | grep -q "$REPLICA_SIMULATOR_ID"; then
  echo "Replica Simulator not found: $REPLICA_SIMULATOR_ID" >&2
  exit 4
fi

xcrun simctl boot "$REPLICA_SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$REPLICA_SIMULATOR_ID" -b

run_stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RESULTS_DIR="$ROOT_DIR/ui_test_results/selected-folder-$run_stamp"
WEBDAV_ROOT="$RESULTS_DIR/webdav-root"
SYNC_DERIVED_DATA="$RESULTS_DIR/sync-derived-data"
HARNESS_DERIVED_DATA="$RESULTS_DIR/harness-derived-data"
SERVER_LOG="$RESULTS_DIR/webdav.log"
DEBUG_TREE_DIR="$RESULTS_DIR/debug-trees"
SECURE_DIR="$(mktemp -d /tmp/velock-selected-folder-e2e.XXXXXX)"
RECOVERY_PACKAGE_FILE="$SECURE_DIR/recovery-package"
E2E_RECOVERY_PASSPHRASE="${E2E_RECOVERY_PASSPHRASE:-$(openssl rand -base64 32 | tr -d '\n/=+')}"
export E2E_DEBUG_TREE_DIR="$DEBUG_TREE_DIR"
export E2E_RECOVERY_PACKAGE_FILE="$RECOVERY_PACKAGE_FILE"
export E2E_RECOVERY_PASSPHRASE
mkdir -p "$DEBUG_TREE_DIR" "$RESULTS_DIR" "$WEBDAV_ROOT"
chmod 700 "$SECURE_DIR"

server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ "$SECURE_DIR" == /tmp/velock-selected-folder-e2e.* && -d "$SECURE_DIR" ]]; then
    find "$SECURE_DIR" -type f -delete
    find "$SECURE_DIR" -depth -type d -delete
  fi
}
trap cleanup EXIT

if curl --silent --fail --output /dev/null --request OPTIONS \
    "http://127.0.0.1:$WEBDAV_PORT/"; then
  echo "WebDAV port is already in use: $WEBDAV_PORT" >&2
  exit 5
fi

"$WEBDAV_BIN" \
  --port "$WEBDAV_PORT" \
  --host 0.0.0.0 \
  --root "$WEBDAV_ROOT" \
  --auth anonymous \
  --no-config \
  --quiet >"$SERVER_LOG" 2>&1 &
server_pid=$!
sleep 0.5
if ! kill -0 "$server_pid" 2>/dev/null; then
  echo "WsgiDAV did not start. See $SERVER_LOG" >&2
  exit 6
fi
for _ in {1..40}; do
  if curl --silent --output /dev/null --request OPTIONS \
      "http://127.0.0.1:$WEBDAV_PORT/"; then
    break
  fi
  sleep 0.25
done

SYNC_APP_PATH="${E2E_SYNC_APP_PATH:-}"
if [[ -z "$SYNC_APP_PATH" ]]; then
  "$XCODEBUILDMCP_BIN" simulator build \
    --workspace-path "$ROOT_DIR/ios/Runner.xcworkspace" \
    --scheme Runner \
    --simulator-id "$SOURCE_SIMULATOR_ID" \
    --configuration Debug \
    --derived-data-path "$SYNC_DERIVED_DATA"
  SYNC_APP_PATH="$SYNC_DERIVED_DATA/Build/Products/Debug-iphonesimulator/Runner.app"
fi
if [[ ! -d "$SYNC_APP_PATH" ]]; then
  echo "Sync simulator app is unavailable: $SYNC_APP_PATH" >&2
  exit 7
fi

for simulator_id in "$SOURCE_SIMULATOR_ID" "$REPLICA_SIMULATOR_ID"; do
  if [[ "${E2E_KEEP_APP_DATA:-0}" != "1" ]]; then
    xcrun simctl uninstall "$simulator_id" tech.windata.velock.sync 2>/dev/null || true
  fi
  "$XCODEBUILDMCP_BIN" simulator install \
    --simulator-id "$simulator_id" \
    --app-path "$SYNC_APP_PATH"
done

run_ui_test() {
  local simulator_id="$1"
  local test_name="$2"
  local result_name="$3"
  local payload
  payload="$(/usr/bin/python3 - "$test_name" <<'PY'
import json
import os
import sys

keys = (
    "E2E_RECOVERY_PASSPHRASE",
    "E2E_RECOVERY_PACKAGE_FILE",
    "E2E_VAULT_ID",
    "E2E_DEBUG_TREE_DIR",
)
environment = {key: os.environ[key] for key in keys if os.environ.get(key)}
environment["E2E_WEBDAV_PORT"] = os.environ["E2E_WEBDAV_PORT"]
print(json.dumps({
    "extraArgs": [
        f"-only-testing:CrossAppUITests/CrossAppUITests/{sys.argv[1]}",
    ],
    "testRunnerEnv": environment,
}))
PY
)"
  "$XCODEBUILDMCP_BIN" simulator test \
    --project-path "$ROOT_DIR/ui_test_harness/CrossAppUITests.xcodeproj" \
    --scheme CrossAppUITests \
    --simulator-id "$simulator_id" \
    --derived-data-path "$HARNESS_DERIVED_DATA" \
    --json "$payload" | tee "$RESULTS_DIR/$result_name.log"
}

export E2E_WEBDAV_PORT="$WEBDAV_PORT"
run_ui_test "$SOURCE_SIMULATOR_ID" testSelectedFolderSourceSync source-sync
run_ui_test "$SOURCE_SIMULATOR_ID" testExportSelectedFolderRecoveryPackage source-export

vault_root_count="$(find "$WEBDAV_ROOT/velock-sync/v1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
vault_root="$(find "$WEBDAV_ROOT/velock-sync/v1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
if [[ "$vault_root_count" != "1" || -z "$vault_root" ]]; then
  echo "Expected exactly one Generic Vault under $WEBDAV_ROOT." >&2
  exit 8
fi
if ! find "$vault_root" -type f -name operations.enc -print -quit | grep -q .; then
  echo "The simulator flow completed without an encrypted operations batch." >&2
  exit 9
fi
if [[ ! -s "$RECOVERY_PACKAGE_FILE" ]]; then
  echo "The source flow did not export a recovery package." >&2
  exit 10
fi
E2E_VAULT_ID="$(basename "$vault_root")"
export E2E_VAULT_ID

run_ui_test "$REPLICA_SIMULATOR_ID" testRecoverSelectedFolderReplica replica-recover

echo "Selected Folder two-simulator sync and recovery passed. Results: $RESULTS_DIR"
