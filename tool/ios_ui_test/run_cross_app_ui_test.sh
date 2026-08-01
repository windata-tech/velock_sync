#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VELOCK_ROOT="${VELOCK_ROOT:-$ROOT_DIR/../velock_codex}"
XCODEBUILDMCP_BIN="${XCODEBUILDMCP_BIN:-/opt/homebrew/bin/xcodebuildmcp}"
SOURCE_SIMULATOR_ID="${E2E_SOURCE_SIMULATOR_UDID:-26CC5821-DEF4-47D3-978D-A11D7293AD61}"
REPLICA_SIMULATOR_ID="${E2E_REPLICA_SIMULATOR_UDID:-22842F80-E053-41F7-8872-9EB08D9C54F9}"
WEBDAV_PORT="${E2E_WEBDAV_PORT:-18991}"
WEBDAV_BIN="${E2E_WEBDAV_BIN:-$ROOT_DIR/ui_test_results/webdav_venv/bin/wsgidav}"

if [[ ! -x "$XCODEBUILDMCP_BIN" ]]; then
  echo "XcodeBuildMCP CLI not found: $XCODEBUILDMCP_BIN" >&2
  exit 2
fi
if [[ ! -x "$WEBDAV_BIN" ]]; then
  echo "WsgiDAV executable not found: $WEBDAV_BIN" >&2
  exit 3
fi
if [[ "$SOURCE_SIMULATOR_ID" == "$REPLICA_SIMULATOR_ID" ]]; then
  echo "Source and replica must be different simulators." >&2
  exit 4
fi

for simulator_id in "$SOURCE_SIMULATOR_ID" "$REPLICA_SIMULATOR_ID"; do
  if ! "$XCODEBUILDMCP_BIN" simulator list --output json |
      /usr/bin/python3 -c 'import json,sys; needle=sys.argv[1]; data=json.load(sys.stdin); sys.exit(0 if needle in json.dumps(data) else 1)' "$simulator_id"; then
    echo "Simulator not found: $simulator_id" >&2
    exit 5
  fi
done

run_stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RESULTS_DIR="$ROOT_DIR/ui_test_results/cross-app-$run_stamp"
WEBDAV_ROOT="${E2E_WEBDAV_ROOT:-$RESULTS_DIR/webdav-root}"
SYNC_DERIVED_DATA="$RESULTS_DIR/sync-derived-data"
HARNESS_DERIVED_DATA="$RESULTS_DIR/harness-derived-data"
SECURE_DIR="$(mktemp -d /tmp/velock-sync-e2e.XXXXXX)"
RECOVERY_PACKAGE_FILE="$SECURE_DIR/recovery-package"
SERVER_LOG="$RESULTS_DIR/webdav.log"
mkdir -p "$RESULTS_DIR" "$WEBDAV_ROOT"
chmod 700 "$SECURE_DIR"

server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ "$SECURE_DIR" == /tmp/velock-sync-e2e.* && -d "$SECURE_DIR" ]]; then
    find "$SECURE_DIR" -type f -delete
    find "$SECURE_DIR" -depth -type d -delete
  fi
}
trap cleanup EXIT

if curl --silent --fail --output /dev/null --request OPTIONS \
    "http://127.0.0.1:$WEBDAV_PORT/"; then
  echo "WebDAV port is already in use: $WEBDAV_PORT" >&2
  exit 6
fi

if [[ -z "${E2E_RECOVERY_PASSPHRASE:-}" ]]; then
  E2E_RECOVERY_PASSPHRASE="$(openssl rand -base64 32 | tr -d '\n/=+')"
fi
if [[ -z "${VELOCK_RUNTIME_PASSWORD:-}" ]]; then
  VELOCK_RUNTIME_PASSWORD="$(openssl rand -base64 24 | tr -d '\n/=+')"
fi
if [[ ${#VELOCK_RUNTIME_PASSWORD} -lt 8 || ${#VELOCK_RUNTIME_PASSWORD} -gt 32 ]]; then
  echo "VELOCK_RUNTIME_PASSWORD must contain 8 to 32 ASCII characters." >&2
  exit 9
fi
export E2E_RECOVERY_PASSPHRASE VELOCK_RUNTIME_PASSWORD
export E2E_RECOVERY_PACKAGE_FILE="$RECOVERY_PACKAGE_FILE"
export E2E_WEBDAV_PORT="$WEBDAV_PORT"
export VELOCK_E2E_SANDBOX_NAME="${VELOCK_E2E_SANDBOX_NAME:-Velock E2E Replica}"

if [[ "${E2E_ERASE_SOURCE:-0}" == "1" ]]; then
  "$XCODEBUILDMCP_BIN" simulator-management erase \
    --simulator-id "$SOURCE_SIMULATOR_ID" \
    --shutdown-first
  "$XCODEBUILDMCP_BIN" simulator-management boot \
    --simulator-id "$SOURCE_SIMULATOR_ID"
fi
if [[ "${E2E_ERASE_REPLICA:-0}" == "1" ]]; then
  "$XCODEBUILDMCP_BIN" simulator-management erase \
    --simulator-id "$REPLICA_SIMULATOR_ID" \
    --shutdown-first
  "$XCODEBUILDMCP_BIN" simulator-management boot \
    --simulator-id "$REPLICA_SIMULATOR_ID"
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
if ! kill -0 "$server_pid" 2>/dev/null; then
  echo "WsgiDAV did not start. See $SERVER_LOG" >&2
  exit 6
fi

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
VELOCK_APP_PATH="${E2E_VELOCK_APP_PATH:-$VELOCK_ROOT/build/ios/iphonesimulator/Runner.app}"

for app_path in "$SYNC_APP_PATH" "$VELOCK_APP_PATH"; do
  if [[ ! -d "$app_path" ]]; then
    echo "Simulator app is unavailable: $app_path" >&2
    exit 7
  fi
done

for simulator_id in "$SOURCE_SIMULATOR_ID" "$REPLICA_SIMULATOR_ID"; do
  "$XCODEBUILDMCP_BIN" simulator install \
    --simulator-id "$simulator_id" \
    --app-path "$SYNC_APP_PATH"
done
"$XCODEBUILDMCP_BIN" simulator install \
  --simulator-id "$REPLICA_SIMULATOR_ID" \
  --app-path "$VELOCK_APP_PATH"

run_ui_test() {
  local simulator_id="$1"
  local test_name="$2"
  local result_name="$3"
  local payload
  payload="$(/usr/bin/python3 - "$test_name" <<'PY'
import json
import os
import sys

test_name = sys.argv[1]
environment = {
    key: os.environ[key]
    for key in (
        "E2E_RECOVERY_PASSPHRASE",
        "E2E_RECOVERY_PACKAGE_FILE",
        "E2E_VAULT_ID",
        "E2E_WEBDAV_PORT",
        "VELOCK_RUNTIME_PASSWORD",
        "VELOCK_E2E_SANDBOX_NAME",
    )
    if os.environ.get(key)
}
print(json.dumps({
    "extraArgs": [
        f"-only-testing:CrossAppUITests/CrossAppUITests/{test_name}",
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

if [[ "${E2E_PAIRING_ONLY:-0}" == "1" ]]; then
  echo "Running the clean Velock registration and real pairing flow..."
  run_ui_test "$REPLICA_SIMULATOR_ID" testCrossAppPairingFlow replica-real-pairing
  echo "Velock registration and real pairing passed. Results: $RESULTS_DIR"
  exit 0
fi

echo "Running source upload and secure recovery-package flow..."
run_ui_test "$SOURCE_SIMULATOR_ID" testCreateWebDAVConnection source-01-webdav
run_ui_test "$SOURCE_SIMULATOR_ID" testProbeSelectedFolderPicker source-02-folder
run_ui_test "$SOURCE_SIMULATOR_ID" testProbeExistingSelectedFolderProfile source-03-upload
run_ui_test "$SOURCE_SIMULATOR_ID" testExportRecoveryPackageSecurely source-04-recovery-export

vault_roots=("$WEBDAV_ROOT"/velock-sync/v1/*)
if [[ ${#vault_roots[@]} -ne 1 || ! -d "${vault_roots[0]}" ]]; then
  echo "Expected exactly one uploaded vault under the WebDAV root." >&2
  exit 8
fi
E2E_VAULT_ID="${vault_roots[0]##*/}"
export E2E_VAULT_ID

echo "Running fresh-replica recovery, download integrity and real pairing flow..."
run_ui_test "$REPLICA_SIMULATOR_ID" testRecoverReplicaAndDownload replica-01-recover-download
run_ui_test "$REPLICA_SIMULATOR_ID" testCrossAppPairingFlow replica-02-real-pairing

echo "All cross-app UI tests passed. Results: $RESULTS_DIR"
