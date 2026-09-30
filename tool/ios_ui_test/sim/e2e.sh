#!/usr/bin/env bash
# One-command source-side E2E for Sync + 格间 on one simulator.
#
#   e2e.sh                     full run: build → reset → seed six kinds → verify → backup
#   e2e.sh --from backup       resume the current run at a stage
#   e2e.sh --only verify       run a single stage of the current run
#   e2e.sh --list              print the stages
#   e2e.sh --record ...        also record the simulator screen to <run>/e2e-<time>.mp4
#                              (starts after the build stage, stops on exit, pass or fail)
#
# Stages (in order):
#   build    flutter builds of both apps; skipped when sources are unchanged
#   reset    uninstall + install both apps (only on E2E_RESET_ALLOWED_UDID)
#   init     create the 格间 space and seed password, credit card, note
#   document document fixture; also turns on pairing and saves the recovery card
#   file     import the HostApp proof .txt through the Files picker
#   photo    add the HostApp proof .png to Photos and import it into 相册
#   verify   read 格间's database: all six kinds persisted with encrypted payloads
#   backup   pair Sync, add the local WebDAV connection, back up, check the remote
#
# A full run starts a fresh run directory (logs + WebDAV root) and points
# $OUT_DIR/runs/current at it; --from/--only reuse that directory, since the
# backup profile on the device points at its WebDAV root.
#
# Private values come from local.env (see local.env.example). Uses the local
# anonymous WsgiDAV by default; E2E_NAS=1 backs up to a fresh folder on the
# user's real NAS through tool/local_webdav/nas_relay_proxy.py instead (see
# backup_smoke.sh). The recovery card screenshot goes to <run>/recovery-card.png.
set -euo pipefail
SIM="$(cd "$(dirname "$0")" && pwd)"
source "$SIM/common.sh"
VELOCK_ROOT="${VELOCK_ROOT:-$(cd "$ROOT_DIR/../velock_codex" && pwd)}"
STAGES=(build reset init document file photo verify backup)

from=build only="" record=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) from="$2"; shift 2 ;;
    --only) only="$2"; shift 2 ;;
    --record) record=1; shift ;;
    --list) printf '%s\n' "${STAGES[@]}"; exit 0 ;;
    *) echo "unknown argument: $1 (see --list, --from, --only, --record)" >&2; exit 2 ;;
  esac
done
for s in "$from" ${only:+"$only"}; do
  [[ " ${STAGES[*]} " == *" $s "* ]] || { echo "unknown stage: $s" >&2; exit 2; }
done

runs="$OUT_DIR/runs"
if [[ "$from" == build && -z "$only" ]]; then
  run_dir="$runs/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$run_dir"
  ln -sfn "$run_dir" "$runs/current"
else
  [[ -d "$runs/current" ]] || { echo "No current run; start with a full e2e.sh" >&2; exit 2; }
  run_dir="$(cd "$runs/current" && pwd -P)"
fi
export E2E_LOG_DIR="$run_dir"
export E2E_WEBDAV_ROOT="$run_dir/webdav-root"
export E2E_RECOVERY_CARD_IMAGE="${E2E_RECOVERY_CARD_IMAGE:-$run_dir/recovery-card.png}"
echo "Run: $run_dir  simulator: $E2E_SIMULATOR_UDID"

wants() {
  if [[ -n "$only" ]]; then [[ "$1" == "$only" ]]; return; fi
  local s reached=0
  for s in "${STAGES[@]}"; do
    [[ "$s" == "$from" ]] && reached=1
    [[ "$s" == "$1" ]] && { [[ $reached == 1 ]]; return; }
  done
  return 1
}
stage_start=0 stage=setup
begin() { stage_start=$SECONDS; stage="$1"; echo "── $1"; }
trap 'echo "FAILED at stage: $stage — fix, then: e2e.sh --from ${stage%% *}" >&2' ERR
done_() { echo "   ok ($((SECONDS - stage_start))s)"; }

# simctl only finalises the .mp4 on SIGINT, so the EXIT trap always stops it.
rec_pid="" video=""
start_recording() {
  [[ $record == 1 && -z "$rec_pid" ]] || return 0
  video="$run_dir/e2e-$(date +%H%M%S).mp4"
  xcrun simctl io "$E2E_SIMULATOR_UDID" recordVideo --codec=h264 --force "$video" \
    >"$run_dir/record.log" 2>&1 &
  rec_pid=$!
  local _
  for _ in $(seq 100); do
    grep -q 'Recording started' "$run_dir/record.log" 2>/dev/null && break
    kill -0 "$rec_pid" 2>/dev/null || { echo "recordVideo exited, see $run_dir/record.log" >&2; exit 1; }
    sleep 0.1
  done
  grep -q 'Recording started' "$run_dir/record.log" ||
    { echo "recordVideo did not start, see $run_dir/record.log" >&2; exit 1; }
  echo "   recording → $video"
}
stop_recording() {
  [[ -n "$rec_pid" ]] || return 0
  kill -INT "$rec_pid" 2>/dev/null || true
  wait "$rec_pid" 2>/dev/null || true
  rec_pid=""
  if [[ -s "$video" ]]; then echo "Video: $video"; else echo "Video missing: $video" >&2; fi
}
trap stop_recording EXIT

APPS="$OUT_DIR/apps"
SYNC_APP="$APPS/Sync.app"
VELOCK_APP="$APPS/Velock.app"

# Hash of what goes into the app (lib, ios, assets, pubspec): committed trees
# plus uncommitted and untracked changes. Test scripts and docs don't count.
source_stamp() {
  local repo="$1"; shift
  (cd "$repo" && {
    local paths=() p
    for p in lib ios assets pubspec.yaml pubspec.lock; do [[ -e "$p" ]] && paths+=("$p"); done
    for p in "${paths[@]}"; do git rev-parse "HEAD:$p" 2>/dev/null || echo "$p"; done
    git diff HEAD -- "${paths[@]}" | shasum
    git ls-files -o --exclude-standard -z -- "${paths[@]}" | xargs -0 shasum 2>/dev/null || true
    echo "$@"
  } | shasum | cut -c1-16)
}

# Simulator-only ad-hoc signing with both App Group entitlements; the flutter
# simulator build does not always keep them without a provisioning profile.
sign_for_simulator() {
  local app="$1" ent="$APPS/simulator.entitlements" bin
  cat >"$ent" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.application-groups</key><array>
<string>group.tech.windata.velock</string>
<string>group.tech.windata.velock.sync.exchange</string>
</array></dict></plist>
PLIST
  while IFS= read -r -d '' bin; do
    codesign --force --sign - "$bin" >/dev/null 2>&1
  done < <(find "$app/Frameworks" -type f -perm -111 -print0 2>/dev/null)
  codesign --force --entitlements "$ent" --sign - "$app" >/dev/null 2>&1
  [[ $(codesign -d --entitlements - "$app" 2>&1 | grep -c 'group.tech.windata') == 2 ]] ||
    { echo "App Group entitlements missing after signing: $app" >&2; exit 1; }
}

build_app() { # name repo dest defines...
  local name="$1" repo="$2" dest="$3"; shift 3
  local stamp; stamp=$(source_stamp "$repo" "$@")
  if [[ -d "$dest" && "$(cat "$dest.stamp" 2>/dev/null)" == "$stamp" ]]; then
    echo "   $name unchanged, reusing build"
    return
  fi
  echo "   building $name…"
  if ! (cd "$repo" && flutter build ios --simulator --debug "$@") >"$run_dir/build-$name.log" 2>&1; then
    echo "FAIL build $name, log: $run_dir/build-$name.log" >&2
    tail -20 "$run_dir/build-$name.log" >&2
    exit 1
  fi
  rm -rf "$dest"
  cp -R "$repo/build/ios/iphonesimulator/Runner.app" "$dest"
  sign_for_simulator "$dest"
  echo "$stamp" >"$dest.stamp"
}

container() { # group|data identifier
  python3 - "$E2E_SIMULATOR_UDID" "$1" "$2" <<'PY'
import pathlib, plistlib, sys
base = pathlib.Path.home() / 'Library/Developer/CoreSimulator/Devices' / sys.argv[1] / 'data/Containers'
base = base / ('Shared/AppGroup' if sys.argv[2] == 'group' else 'Data/Application')
hits = [m.parent for m in base.glob('*/.com.apple.mobile_container_manager.metadata.plist')
        if plistlib.loads(m.read_bytes()).get('MCMMetadataIdentifier') == sys.argv[3]]
print(hits[0] if len(hits) == 1 else '')
PY
}

if wants build; then
  begin build
  mkdir -p "$APPS"
  build_app sync "$ROOT_DIR" "$SYNC_APP"
  build_app velock "$VELOCK_ROOT" "$VELOCK_APP" --dart-define=VELOCK_E2E_FIXTURES=true
  done_
fi

if wants reset; then
  begin reset
  if [[ -z "${E2E_RESET_ALLOWED_UDID:-}" || "$E2E_RESET_ALLOWED_UDID" != "$E2E_SIMULATOR_UDID" ]]; then
    echo "Refusing to reset $E2E_SIMULATOR_UDID: set E2E_RESET_ALLOWED_UDID to it in local.env" >&2
    exit 1
  fi
  for app in "$SYNC_APP" "$VELOCK_APP"; do
    [[ -d "$app" ]] || { echo "No build at $app; run the build stage" >&2; exit 1; }
  done
  for id in tech.windata.velock.sync tech.windata.velock; do
    xcrun simctl terminate "$E2E_SIMULATOR_UDID" "$id" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$E2E_SIMULATOR_UDID" "$id"
  done
  for group in group.tech.windata.velock group.tech.windata.velock.sync.exchange; do
    [[ -z "$(container group "$group")" ]] ||
      { echo "App Group $group survived uninstall; old data would leak into this run" >&2; exit 1; }
  done
  xcrun simctl install "$E2E_SIMULATOR_UDID" "$SYNC_APP"
  xcrun simctl install "$E2E_SIMULATOR_UDID" "$VELOCK_APP"
  # iOS 27 shows the Photos prompt outside any AX tree; grant it up front.
  xcrun simctl privacy "$E2E_SIMULATOR_UDID" grant photos tech.windata.velock
  done_
fi

run() { "$SIM/run_test.sh" "$@"; }
start_recording

if wants init; then
  begin "init (space + password, credit card, note)"
  run testSeedVelockBusinessData E2E_SEED_DATA=1 E2E_SEED_NOTE=1 E2E_SEED_CREDIT_CARD=1
  done_
fi

if wants document; then
  begin "document (+ pairing on, recovery card)"
  run testSeedVelockDocumentOnly
  done_
fi

if wants file; then
  begin "file (proof .txt via Files)"
  mkdir -p "$run_dir/file"
  run testTutorialImportText E2E_TUTORIAL_DIR="$run_dir/file"
  done_
fi

if wants photo; then
  begin "photo (proof .png via Photos)"
  host=$(container data tech.windata.velock.crossapp.uitest.host)
  png="$host/Documents/VelockSync-E2E-Source/velock-sync-e2e-proof.png"
  [[ -n "$host" && -f "$png" ]] || { echo "HostApp proof image missing; run the file stage first" >&2; exit 1; }
  xcrun simctl addmedia "$E2E_SIMULATOR_UDID" "$png"
  run testProbeVelockMediaImport E2E_PHOTOS_PREGRANTED=1
  done_
fi

if wants verify; then
  begin "verify (six kinds in 格间's database)"
  python3 - "$E2E_SIMULATOR_UDID" "$ROOT_DIR/tool/ios_ui_test/tutorial" >"$run_dir/source-evidence.json" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2])
from tutorial_coverage import verify_source, REQUIRED_KINDS
evidence = verify_source({'devices': {'source': sys.argv[1]}, 'prepared': True, 'keep_source': True,
                          'required_kinds': list(REQUIRED_KINDS)})
print(json.dumps(evidence, indent=2))
PY
  python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); print("   " + ", ".join(f"{k}={len(v)}" for k, v in e.items()))' "$run_dir/source-evidence.json"
  done_
fi

if wants backup; then
  begin "backup (pair + WebDAV + remote checks)"
  E2E_PLAINTEXT_MARKERS="E2E Password,e2e-secret,E2E Credit Card,4111111111111111,E2E note content,E2E document recovery content,VELOCK SYNC REAL DATA E2E" \
    "$SIM/backup_smoke.sh"
  done_
fi
echo "ALL STAGES PASSED  (logs: $run_dir)"
