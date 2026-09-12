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
# Incremental runs must keep the same remote, just as a real WebDAV account does.
WEBDAV_ROOT="${E2E_WEBDAV_ROOT:-$ROOT_DIR/ui_test_results/persistent-webdav-root}"
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
if [[ "${E2E_RESUME_SOURCE:-0}" == "1" && -z "${VELOCK_RUNTIME_PASSWORD:-}" ]]; then
  # A resumed source keeps the sandbox password chosen when it was created.
  # Refuse to guess: unlocking with a fresh random password would silently
  # strand the run on the password gate and fail the pairing-settings probe.
  echo "VELOCK_RUNTIME_PASSWORD is required when E2E_RESUME_SOURCE=1." >&2
  exit 9
fi
if [[ "${E2E_RESUME_SOURCE:-0}" != "1" && -z "${VELOCK_RUNTIME_PASSWORD:-}" ]]; then
  VELOCK_RUNTIME_PASSWORD="$(openssl rand -base64 24 | tr -d '\n/=+')"
fi
if [[ ${#VELOCK_RUNTIME_PASSWORD} -gt 32 ]]; then
  echo "VELOCK_RUNTIME_PASSWORD must contain at most 32 ASCII characters." >&2
  exit 9
fi
if [[ ${#VELOCK_RUNTIME_PASSWORD} -lt 8 && "${E2E_RESUME_SOURCE:-0}" != "1" ]]; then
  echo "VELOCK_RUNTIME_PASSWORD must contain 8 to 32 ASCII characters." >&2
  exit 9
fi
export E2E_RECOVERY_PASSPHRASE VELOCK_RUNTIME_PASSWORD
export E2E_RECOVERY_PACKAGE_FILE="$RECOVERY_PACKAGE_FILE"
export E2E_WEBDAV_PORT="$WEBDAV_PORT"
export E2E_RECOVERY_CARD_IMAGE="$RESULTS_DIR/source-recovery-card.png"
export VELOCK_E2E_SANDBOX_NAME="${VELOCK_E2E_SANDBOX_NAME:-Velock E2E Replica}"

if [[ "${E2E_ERASE_SOURCE:-0}" == "1" && "${E2E_ALLOW_ERASE:-0}" != "1" ]]; then
  echo "Refusing to erase source simulator without E2E_ALLOW_ERASE=1. Tests are incremental by default." >&2
  exit 11
fi
if [[ "${E2E_ERASE_REPLICA:-0}" == "1" && "${E2E_ALLOW_ERASE:-0}" != "1" ]]; then
  echo "Refusing to erase replica simulator without E2E_ALLOW_ERASE=1. Tests are incremental by default." >&2
  exit 11
fi
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

# Flutter simulator builds can contain prebuilt third-party frameworks whose
# embedded code is unsigned. The simulator refuses to load those dylibs even
# though the app bundle itself installs successfully. Sign every nested binary
# before installation; this is simulator-only and does not affect App Store
# signing or production archives.
sign_simulator_app() {
  local app_path="$1"
  while IFS= read -r -d '' binary; do
    codesign --force --sign - "$binary" >/dev/null 2>&1 || {
      echo "Failed to ad-hoc sign simulator binary: $binary" >&2
      return 1
    }
  done < <(find "$app_path/Frameworks" -type f -perm -111 -print0 2>/dev/null)
  # Use an explicit simulator entitlement set. Xcode may strip the primary
  # group from an ad-hoc simulator signature when no provisioning profile is
  # present; both apps need the shared Velock group for their real data path.
  local entitlements="$RESULTS_DIR/simulator.entitlements"
  cat >"$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.application-groups</key><array>
<string>group.tech.windata.velock</string>
<string>group.tech.windata.velock.sync.exchange</string>
</array></dict></plist>
PLIST
  codesign --force --entitlements "$entitlements" --sign - "$app_path" >/dev/null 2>&1 || return 1
}
sign_simulator_app "$SYNC_APP_PATH"
sign_simulator_app "$VELOCK_APP_PATH"

install_targets=("$SOURCE_SIMULATOR_ID" "$REPLICA_SIMULATOR_ID")
if [[ "${E2E_REPLICA_ONLY:-0}" == "1" || "${E2E_PAIRING_ONLY:-0}" == "1" || "${E2E_RESUME_REPLICA_ONLY:-0}" == "1" ]]; then
  install_targets=("$REPLICA_SIMULATOR_ID")
fi
for simulator_id in "${install_targets[@]}"; do
  for app_path in "$SYNC_APP_PATH" "$VELOCK_APP_PATH"; do
    "$XCODEBUILDMCP_BIN" simulator install --simulator-id "$simulator_id" --app-path "$app_path"
  done
done

# Resolve containers without booting a retained source simulator.
app_data_container() {
  python3 - "$1" "$2" <<'PYCONTAINER'
import pathlib, plistlib, sys
root = pathlib.Path.home() / 'Library/Developer/CoreSimulator/Devices' / sys.argv[1] / 'data/Containers/Data/Application'
matches = []
for metadata in root.glob('*/.com.apple.mobile_container_manager.metadata.plist'):
    with metadata.open('rb') as stream:
        value = plistlib.load(stream)
    if value.get('MCMMetadataIdentifier') == sys.argv[2]:
        matches.append(metadata.parent)
if len(matches) != 1:
    raise SystemExit('Expected one retained app data container')
print(matches[0])
PYCONTAINER
}

# Photos sorts by asset date, not merely import order. Import a byte-identical
# fresh-dated copy so a historical source card is not hidden below newer cards.
import_recovery_card() {
  local card="$1"
  cp "$card" "$SECURE_DIR/original-recovery-card.png"
  touch "$SECURE_DIR/original-recovery-card.png"
  cmp -s "$card" "$SECURE_DIR/original-recovery-card.png"
  xcrun simctl addmedia "$REPLICA_SIMULATOR_ID" "$SECURE_DIR/original-recovery-card.png"
}

verify_recovered_identity() {
  local source_container replica_container
  source_container="$(app_data_container "$SOURCE_SIMULATOR_ID" tech.windata.velock)"
  replica_container="$(app_data_container "$REPLICA_SIMULATOR_ID" tech.windata.velock)"
  python3 "$ROOT_DIR/tool/ios_ui_test/verify_replica_convergence.py" \
    --source-database "$source_container/Documents/venyoreDb" \
    --replica-database "$replica_container/Documents/venyoreDb" --identity-only \
    | tee "$RESULTS_DIR/replica-recovered-identity.json"
}

run_ui_test() {
  local simulator_id="$1"
  local test_name="$2"
  local result_name="$3"
  local sync_started_ms
  sync_started_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
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
        "E2E_RECOVERY_CARD_IMAGE",
        "E2E_ALLOW_EXISTING_RECOVERY",
        "E2E_RECOVER_ADDITIONAL_ACCOUNT",
        "E2E_REQUIRE_RECOVERED_ACCOUNT",
        "E2E_VAULT_ID",
        "E2E_WEBDAV_PORT",
        "VELOCK_RUNTIME_PASSWORD",
        "E2E_SEED_DATA",
        "E2E_SYNC_DB_VERIFIED",
        "E2E_SEED_NOTE",
        "E2E_IMPORT_IMAGE",
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
  # The CLI can return zero even when XCTest reports failures.
  if ! grep -Eq 'Overall Result: Passed|Test Run test succeeded' "$RESULTS_DIR/$result_name.log" ||
      grep -Eq 'Overall Result: Failed|Test Run test failed|Failed: [1-9]' "$RESULTS_DIR/$result_name.log"; then
    echo "XCTest did not pass: $result_name" >&2
    return 1
  fi
  if [[ "$test_name" == "testSyncExistingVelockProfile" ]]; then
    local sync_container
    sync_container="$(xcrun simctl get_app_container "$simulator_id" tech.windata.velock.sync data)"
    python3 - "$sync_container/Library/Application Support/velock-sync/state.db" "$sync_started_ms" <<'PYVERIFY'
import sqlite3, sys
with sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True) as db:
    row = db.execute('select state, error_code, error_category, started_at from sync_runs order by started_at desc limit 1').fetchone()
if not row or row[0] != 'completed' or row[3] < int(sys.argv[2]):
    raise SystemExit(f'No fresh completed sync run: {row}')
print('VERIFIED_FRESH_SYNC_RUN', row)
PYVERIFY
  fi
}

selected_sandbox_id() {
  python3 - "$1" <<'PYSANDBOX'
import pathlib, plistlib, sys
preferences = pathlib.Path(sys.argv[1]) / 'Library/Preferences/tech.windata.velock.plist'
with preferences.open('rb') as stream:
    ident = plistlib.load(stream).get('current_sandbox_id')
if isinstance(ident, bool) or not str(ident).isdigit() or int(ident) <= 0:
    raise SystemExit('Missing valid selected sandbox; refusing cross-space verification')
print(int(ident))
PYSANDBOX
}

verify_replica_business_data() {
  local container db sandbox_id password_count card_count note_count document_count file_count media_count
  container="$(app_data_container "$REPLICA_SIMULATOR_ID" tech.windata.velock)"
  db="$container/Documents/venyoreDb"
  sandbox_id="$(selected_sandbox_id "$container")"
  for _ in {1..20}; do
    [[ -s "$db" ]] && break
    sleep 1
  done
  password_count="$(sqlite3 "$db" "select count(*) from t_password where sandbox_id = $sandbox_id;" 2>/dev/null || echo 0)"
  card_count="$(sqlite3 "$db" "select count(*) from t_card where sandbox_id = $sandbox_id;" 2>/dev/null || echo 0)"
  note_count="$(sqlite3 "$db" "select count(*) from t_note where sandbox_id = $sandbox_id;" 2>/dev/null || echo 0)"
  document_count="$(sqlite3 "$db" "select count(*) from t_document where sandbox_id = $sandbox_id;" 2>/dev/null || echo 0)"
  file_count="$(sqlite3 "$db" "select count(*) from t_file where category_id = 1 and sandbox_id = $sandbox_id;" 2>/dev/null || echo 0)"
  media_count="$(sqlite3 "$db" "select count(*) from t_file where category_id = 2 and sandbox_id = $sandbox_id;" 2>/dev/null || echo 0)"
  echo "REPLICA_DATA_COUNTS password=$password_count card=$card_count note=$note_count document=$document_count file=$file_count media=$media_count"
  local required_kinds="${E2E_REQUIRED_KINDS:-password,card}"
  if [[ "${E2E_REQUIRE_ALL_DATA:-0}" == "1" ]]; then
    required_kinds="password,card,note,document,file,media"
  fi
  local missing_kinds=()
  local kind
  for kind in ${required_kinds//,/ }; do
    case "$kind" in
      password) [[ "$password_count" -lt 1 ]] && missing_kinds+=("password") ;;
      card) [[ "$card_count" -lt 1 ]] && missing_kinds+=("card") ;;
      note) [[ "$note_count" -lt 1 ]] && missing_kinds+=("note") ;;
      document) [[ "$document_count" -lt 1 ]] && missing_kinds+=("document") ;;
      file) [[ "$file_count" -lt 1 ]] && missing_kinds+=("file") ;;
      media) [[ "$media_count" -lt 1 ]] && missing_kinds+=("media") ;;
      *) echo "Unknown required data kind: $kind" >&2; exit 17 ;;
    esac
  done
  if [[ ${#missing_kinds[@]} -gt 0 ]]; then
    echo "Replica is missing required business data: ${missing_kinds[*]}" >&2
    exit 14
  fi
  if [[ "${E2E_REQUIRE_ALL_DATA:-0}" == "1" ]]; then
    python3 "$ROOT_DIR/tool/ios_ui_test/verify_business_persistence.py"       --simulator-id "$REPLICA_SIMULATOR_ID" --database "$db" --sandbox-id "$sandbox_id"       | tee "$RESULTS_DIR/replica-persistence.json"
    source_container="$(app_data_container "$SOURCE_SIMULATOR_ID" tech.windata.velock)"
    python3 "$ROOT_DIR/tool/ios_ui_test/verify_replica_convergence.py"       --source-database "$source_container/Documents/venyoreDb" --replica-database "$db"       | tee "$RESULTS_DIR/replica-convergence.json"
  fi
}

if [[ "${E2E_SYNC_EXISTING_ONLY:-0}" == "1" ]]; then
  run_ui_test "$SOURCE_SIMULATOR_ID" testSyncExistingVelockProfile source-existing-sync
  exit 0
fi

if [[ "${E2E_RESUME_REPLICA_ONLY:-0}" == "1" ]]; then
  export E2E_REQUIRE_ALL_DATA=1
  run_ui_test "$REPLICA_SIMULATOR_ID" testSyncExistingVelockProfile replica-existing-sync
  verify_replica_business_data
  echo "Incremental replica convergence passed (not a fresh account recovery). Results: $RESULTS_DIR"
  exit 0
fi

if [[ "${E2E_SEED_DOCUMENT_ONLY:-0}" == "1" ]]; then
  source_container="$(app_data_container "$SOURCE_SIMULATOR_ID" tech.windata.velock)"
  document_before="$(sqlite3 "$source_container/Documents/venyoreDb" 'select coalesce(max(id), 0) from t_document;')"
  run_ui_test "$SOURCE_SIMULATOR_ID" testSeedVelockDocumentOnly seed-document
  python3 "$ROOT_DIR/tool/ios_ui_test/verify_business_persistence.py"     --simulator-id "$SOURCE_SIMULATOR_ID" --database "$source_container/Documents/venyoreDb"     --sandbox-id "$(selected_sandbox_id "$source_container")" --kinds document --after-id "$document_before" | tee "$RESULTS_DIR/document-persistence.json"
  exit 0
fi

if [[ "${E2E_SEED_NOTE_ONLY:-0}" == "1" ]]; then
  export E2E_SEED_NOTE=1
  run_ui_test "$SOURCE_SIMULATOR_ID" testSeedVelockNoteOnly seed-note
  # UI action success alone is insufficient: require real encrypted persistence.
  source_container="$(app_data_container "$SOURCE_SIMULATOR_ID" tech.windata.velock)"
  source_note_count="$(sqlite3 "$source_container/Documents/venyoreDb" "select count(*) from t_note where sandbox_id = $sandbox_id;")"
  echo "SOURCE_NOTE_COUNT=$source_note_count" | tee "$RESULTS_DIR/source-note-count.txt"
  if [[ "$source_note_count" -lt 1 ]]; then
    echo "Note UI completed but no note was persisted." >&2
    exit 15
  fi
  exit 0
fi

if [[ "${E2E_PAIRING_ONLY:-0}" == "1" ]]; then
  echo "Running the clean Velock registration and real pairing flow..."
  run_ui_test "$REPLICA_SIMULATOR_ID" testCrossAppPairingFlow replica-real-pairing
  echo "Velock registration and real pairing passed. Results: $RESULTS_DIR"
  exit 0
fi

if [[ "${E2E_PROBE_IMPORT_ONLY:-0}" == "1" ]]; then
  # XCUITest handles the real Photos permission prompt. Do not pre-grant
  # permission here and silently ignore failures (or mask denied-state bugs).
  if [[ -n "${E2E_IMPORT_IMAGE:-}" && -s "${E2E_IMPORT_IMAGE}" ]]; then
    xcrun simctl addmedia "$SOURCE_SIMULATOR_ID" "$E2E_IMPORT_IMAGE"
  fi
  source_container="$(app_data_container "$SOURCE_SIMULATOR_ID" tech.windata.velock)"
  media_before="$(sqlite3 "$source_container/Documents/venyoreDb" 'select coalesce(max(id), 0) from t_file;')"
  if [[ "${E2E_MEDIA_ONLY:-0}" == "1" ]]; then
    run_ui_test "$SOURCE_SIMULATOR_ID" testProbeVelockMediaImport probe-media
  else
    run_ui_test "$SOURCE_SIMULATOR_ID" testProbeVelockFileAndImageImport probe-import
  fi
  source_container="$(app_data_container "$SOURCE_SIMULATOR_ID" tech.windata.velock)"
  sandbox_id="$(selected_sandbox_id "$source_container")"
  for _ in {1..30}; do
    source_media_count="$(sqlite3 "$source_container/Documents/venyoreDb" "select count(*) from t_file where category_id = 2 and sandbox_id = $sandbox_id;" 2>/dev/null || echo 0)"
    [[ "$source_media_count" -ge 1 ]] && break
    sleep 1
  done
  source_file_count="$(sqlite3 "$source_container/Documents/venyoreDb" 'select count(*) from t_file;')"
  python3 "$ROOT_DIR/tool/ios_ui_test/verify_media_persistence.py"     --simulator-id "$SOURCE_SIMULATOR_ID" --database "$source_container/Documents/venyoreDb"     --sandbox-id "$(selected_sandbox_id "$source_container")" --after-id "$media_before" | tee "$RESULTS_DIR/media-persistence.json"
  echo "SOURCE_IMPORT_COUNTS file=$source_file_count media=$source_media_count" | tee "$RESULTS_DIR/source-import-counts.txt"
  if [[ "$source_file_count" -lt 1 || "$source_media_count" -lt 1 ]]; then
    echo "Picker actions completed but file/media persistence is missing." >&2
    exit 16
  fi
  exit 0
fi

if [[ "${E2E_REPLICA_ONLY:-0}" == "1" ]]; then
  CARD_IMAGE="${E2E_EXISTING_RECOVERY_CARD:-}"
  if [[ -z "$CARD_IMAGE" || ! -s "$CARD_IMAGE" ]]; then
    echo "E2E_REPLICA_ONLY requires E2E_EXISTING_RECOVERY_CARD." >&2
    exit 10
  fi
  import_recovery_card "$CARD_IMAGE"
  run_ui_test "$REPLICA_SIMULATOR_ID" testRecoverVelockAccountFromCardPhoto replica-recover-account
  verify_recovered_identity
  export E2E_REQUIRE_RECOVERED_ACCOUNT=1
  run_ui_test "$REPLICA_SIMULATOR_ID" testCrossAppPairingFlow replica-repair-and-sync
  verify_replica_business_data
  echo "Replica recovery and re-pair flow passed. Results: $RESULTS_DIR"
  exit 0
fi

# Release acceptance verifies every data class the source actually seeded.
# Default to the six-class gate, but allow callers that seed a subset (for
# example E2E_SEED_DATA without file/media imports) to name the kinds.
export E2E_REQUIRE_ALL_DATA="${E2E_REQUIRE_ALL_DATA:-1}"
if [[ -n "${E2E_REQUIRED_KINDS:-}" ]]; then
  export E2E_REQUIRE_ALL_DATA=0
fi
echo "Running the new source-to-replacement recovery flow..."
# The source test creates the real account, enables Sync, pairs, and
# uploads to the live WebDAV server started above. It also saves the
# Sync-enabled recovery-card QR into RESULTS_DIR.
if [[ "${E2E_RESUME_SOURCE:-0}" == "1" ]]; then
  run_ui_test "$SOURCE_SIMULATOR_ID" testExportSyncRecoveryCard source-current-recovery-card
  run_ui_test "$SOURCE_SIMULATOR_ID" testSyncExistingVelockProfile source-existing-sync
else
  run_ui_test "$SOURCE_SIMULATOR_ID" testCrossAppPairingFlow source-new-flow
fi
source_container="$(app_data_container "$SOURCE_SIMULATOR_ID" tech.windata.velock)"
python3 "$ROOT_DIR/tool/ios_ui_test/verify_remote_coverage.py"     --database "$source_container/Documents/venyoreDb" --remote "$WEBDAV_ROOT"     | tee "$RESULTS_DIR/source-remote-coverage.json"
source_operation_count="$(find "$WEBDAV_ROOT" -type f -name operations.enc | wc -l | tr -d ' ')"
if [[ "$source_operation_count" -lt 1 ]]; then
  echo "Source flow did not upload any encrypted business batch." >&2
  exit 12
fi
CARD_IMAGE="$RESULTS_DIR/source-recovery-card.png"
if [[ ! -s "$CARD_IMAGE" && -n "${E2E_EXISTING_RECOVERY_CARD:-}" && -s "$E2E_EXISTING_RECOVERY_CARD" ]]; then
  cp "$E2E_EXISTING_RECOVERY_CARD" "$CARD_IMAGE"
fi
if [[ ! -s "$CARD_IMAGE" ]]; then
  echo "Sync-enabled source recovery card was not produced: $CARD_IMAGE" >&2
  exit 10
fi
# XcodeBuildMCP has no media-import operation; simctl is used only for this
# simulator Photos fixture handoff, never for app interaction.
import_recovery_card "$CARD_IMAGE"
run_ui_test "$REPLICA_SIMULATOR_ID" testRecoverVelockAccountFromCardPhoto replica-recover-account
verify_recovered_identity
export E2E_REQUIRE_RECOVERED_ACCOUNT=1
run_ui_test "$REPLICA_SIMULATOR_ID" testCrossAppPairingFlow replica-repair-and-sync
verify_replica_business_data
echo "New account-recovery and re-pair flow passed. Results: $RESULTS_DIR"
exit 0
