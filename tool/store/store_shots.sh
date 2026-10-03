#!/usr/bin/env bash
# Raw App Store screenshots on a simulator that already ran e2e.sh. Set
# E2E_SHOT_VELOCK=0 for a simulator that only has Sync installed; the Velock
# backup screens are then skipped.
#
#   E2E_SIMULATOR_UDID=<udid> tool/store/store_shots.sh <lang> <out-dir>
#
# <lang> is the app language storage value (zh, en, zh-Hant, ja, ar, …); folder
# names and the labels the test waits for come from shot_env.py.
#
# Demo servers are local and anonymous; mDNS names make the addresses read like
# a home setup: homenas.local:5005 (the Velock backup, serving the e2e run's
# WebDAV root) and cloud.local:8080 ("Nextcloud", file sync). On a simulator
# with a paired backup the Sync database is patched for the demo: connection
# names/addresses and the backup's display name. Nothing here touches a real
# server.
set -euo pipefail
lang="${1:?app language (zh, en, ja, …)}" out="${2:?output dir}"
source "$(dirname "$0")/../ios_ui_test/sim/common.sh"
U="$E2E_SIMULATOR_UDID"
velock="${E2E_SHOT_VELOCK:-1}"
work="$OUT_DIR/store-demo"; mkdir -p "$work/cloud-root" "$out"; out="$(cd "$out" && pwd -P)"
# Only the Velock screens need the e2e run's backup (iPad runs without it).
backup_root="$(cd "$OUT_DIR/runs/current" 2>/dev/null && pwd -P || true)/webdav-root"
webdav_bin="$ROOT_DIR/ui_test_results/webdav_venv/bin/wsgidav"

pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT
# Parallel runs (one per simulator, see all_shots.sh) share one registration
# made by the caller (E2E_SHOT_NO_DNS=1) and each serve their own port.
cloud_port="${E2E_SHOT_SERVE_PORT:-8080}"
if [[ "${E2E_SHOT_NO_DNS:-0}" != 1 ]]; then
  dns-sd -P "Home NAS" _webdav._tcp local 5005 homenas.local 127.0.0.1 >/dev/null 2>&1 & pids+=($!)
  dns-sd -P "Cloud" _webdav._tcp local 8080 cloud.local 127.0.0.1 >/dev/null 2>&1 & pids+=($!)
fi
serve() {
  # A stale server on the port would answer instead (with another root).
  if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $1 is already in use; stop that server first" >&2; exit 1
  fi
  "$webdav_bin" --port "$1" --host 127.0.0.1 --root "$2" --auth anonymous --no-config --quiet >"$work/webdav-$1.log" 2>&1 &
  local pid=$!; pids+=($pid)
  for _ in {1..40}; do
    kill -0 "$pid" 2>/dev/null || { echo "WebDAV on :$1 did not start (see $work/webdav-$1.log)" >&2; exit 1; }
    curl --noproxy '*' -sf -m 1 -o /dev/null -X OPTIONS "http://127.0.0.1:$1/" && return; sleep 0.25
  done
  echo "WebDAV on :$1 not answering" >&2; exit 1
}
[[ $velock == 1 ]] && serve 5005 "$backup_root"

host_docs=$(python3 - "$U" <<'PY'
import pathlib, plistlib, sys
base = pathlib.Path.home() / 'Library/Developer/CoreSimulator/Devices' / sys.argv[1] / 'data/Containers/Data/Application'
hits = [m.parent for m in base.glob('*/.com.apple.mobile_container_manager.metadata.plist')
        if plistlib.loads(m.read_bytes()).get('MCMMetadataIdentifier') == 'tech.windata.velock.crossapp.uitest.host']
print(hits[0] / 'Documents' if len(hits) == 1 else '')
PY
)
[[ -n "$host_docs" ]] || { echo "fixture host app missing on $U" >&2; exit 1; }
# Fresh every run, so each location's first sync really uploads its files.
rm -rf "$work/cloud-root"; mkdir -p "$work/cloud-root"
eval "$(python3 "$ROOT_DIR/tool/store/shot_env.py" "$lang")"
# The host app keeps folders from earlier languages; only this run's are used.
python3 "$ROOT_DIR/tool/store/make_demo_files.py" "$host_docs" "$work/cloud-root" "$lang"
serve "$cloud_port" "$work/cloud-root"

# The saved "Nextcloud" connection must point at this run's port (parallel
# simulators each serve their own).
xcrun simctl terminate "$U" tech.windata.velock.sync >/dev/null 2>&1 || true
sync_db="$(xcrun simctl get_app_container "$U" tech.windata.velock.sync data)/Library/Application Support/velock-sync/state.db"
[[ -f "$sync_db" ]] && python3 - "$sync_db" "$cloud_port" <<'PY'
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for cid, raw in c.execute("select id, payload_json from connections").fetchall():
    p = json.loads(raw); proto = p.get('protocol', {})
    if p.get('name') == 'Nextcloud' and proto.get('address') == 'http://cloud.local':
        proto['port'] = sys.argv[2]
        p['target'] = f"{proto['address']}:{proto['port']}"
        c.execute("update connections set payload_json=? where id=?", (json.dumps(p, ensure_ascii=False), cid))
c.commit()
PY

if [[ $velock == 1 ]]; then
  xcrun simctl terminate "$U" tech.windata.velock.sync >/dev/null 2>&1 || true
  db="$(xcrun simctl get_app_container "$U" tech.windata.velock.sync data)/Library/Application Support/velock-sync/state.db"
  python3 - "$db" "$home_nas" "$my_velock" <<'PY'
import json, sqlite3, sys
db, home_nas, my_velock = sys.argv[1:4]
c = sqlite3.connect(db)
for cid, raw in c.execute("select id, payload_json from connections").fetchall():
    p = json.loads(raw); proto = p.get('protocol', {})
    if proto.get('port') in ('18991', '5005'):
        p['name'] = home_nas
        proto['address'], proto['port'] = 'http://homenas.local', '5005'
    elif proto.get('port') in ('18992', '8080'):
        p['name'] = 'Nextcloud'
        proto['address'], proto['port'] = 'http://cloud.local', '8080'
    else:
        continue
    p['target'] = f"{proto['address']}:{proto['port']}"
    p['target_description'] = f"address={proto['address']}"
    c.execute("update connections set payload_json=? where id=?", (json.dumps(p, ensure_ascii=False), cid))
for pid, raw in c.execute("select profile_id, payload_json from sync_profiles where state != 'removed'").fetchall():
    p = json.loads(raw)
    if p.get('kind') == 'velock-managed':
        p['displayName'] = my_velock
        c.execute("update sync_profiles set payload_json=? where profile_id=?", (json.dumps(p, ensure_ascii=False), pid))
c.commit()
PY
fi

xcrun simctl status_bar "$U" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
"$ROOT_DIR/tool/ios_ui_test/sim/run_test.sh" testStoreShots E2E_SHOT_DIR="$out" E2E_SHOT_LANG="$lang" \
  E2E_SHOT_VELOCK="$velock" E2E_SHOT_LOCATIONS="$locs" E2E_SHOT_WIZARD="$wizard" E2E_SHOT_BROWSE="$browse" \
  E2E_SHOT_RTL="$rtl" E2E_SHOT_L_DONE="$L_DONE" E2E_SHOT_L_BACKUP_DONE="$L_BACKUP_DONE" E2E_SHOT_L_LIST="$L_LIST" \
  E2E_SHOT_L_TWO="$L_TWO" E2E_SHOT_L_UP="$L_UP" E2E_SHOT_L_DOWN="$L_DOWN" \
  E2E_SHOT_CLOUD_NAME=Nextcloud E2E_SHOT_CLOUD_HOST=cloud.local E2E_SHOT_CLOUD_PORT="$cloud_port"
ls "$out"
