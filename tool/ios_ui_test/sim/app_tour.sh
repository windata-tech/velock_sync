#!/usr/bin/env bash
# Whole-app tour of Sync after the backup stage (e2e.sh stage "app").
#
#   app_tour.sh [KEY=VALUE ...]
#
# Serves E2E_WEBDAV_ROOT with the anonymous local WsgiDAV (the same server the
# backup profile points at) plus a second WsgiDAV for file sync on
# E2E_PLAIN_PORT (the backup owns the first server's root, and a plain mirror
# may never overlap a backup folder), prepares a plain local folder inside the fixture
# host's Documents (visible in the Files picker), runs testSyncAppTour, then
# checks the real files on both sides:
#   - the first sync uploaded the local tree and downloaded the server-only file
#   - the second sync moved one new file each way
#   - a local deletion reached the server
#   - removing the sync location left both sides' files in place
#   - the plain mirror is plaintext by design; the Velock backup still is not
set -euo pipefail
source "$(dirname "$0")/common.sh"
export E2E_WEBDAV_PORT="${E2E_WEBDAV_PORT:-18991}"
root="${E2E_WEBDAV_ROOT:-$OUT_DIR/webdav-root}"
export E2E_WEBDAV_ROOT="$root"
export E2E_PLAIN_REMOTE_NAME="${E2E_PLAIN_REMOTE_NAME:-plain-e2e}"
export E2E_PLAIN_PORT="${E2E_PLAIN_PORT:-18992}"
plain_root="${E2E_PLAIN_WEBDAV_ROOT:-$(dirname "$root")/plain-webdav-root}"
export E2E_PLAIN_WEBDAV_ROOT="$plain_root"
webdav_bin="${E2E_WEBDAV_BIN:-$ROOT_DIR/ui_test_results/webdav_venv/bin/wsgidav}"
log_dir="${E2E_LOG_DIR:-$OUT_DIR}"

host=$(python3 - "$E2E_SIMULATOR_UDID" <<'PY'
import pathlib, plistlib, sys
base = pathlib.Path.home() / 'Library/Developer/CoreSimulator/Devices' / sys.argv[1] / 'data/Containers/Data/Application'
hits = [m.parent for m in base.glob('*/.com.apple.mobile_container_manager.metadata.plist')
        if plistlib.loads(m.read_bytes()).get('MCMMetadataIdentifier') == 'tech.windata.velock.crossapp.uitest.host']
print(hits[0] if len(hits) == 1 else '')
PY
)
[[ -n "$host" ]] || { echo "Fixture host app is not installed; run the file stage first" >&2; exit 1; }
png="$host/Documents/VelockSync-E2E-Source/velock-sync-e2e-proof.png"
[[ -f "$png" ]] || { echo "HostApp proof image missing; run the file stage first" >&2; exit 1; }

local_dir="$host/Documents/PlainSync-E2E"
remote_dir="$plain_root/$E2E_PLAIN_REMOTE_NAME"
# E2E_TOUR_FROM=C|D resumes after the file sync part and keeps its files.
if [[ "${E2E_TOUR_FROM:-A}" < C ]]; then
  rm -rf "$local_dir" "$plain_root" "$root/tour-backup-candidate"
  mkdir -p "$plain_root" "$local_dir/docs" "$local_dir/photos"
  printf 'hello from the phone\n' >"$local_dir/hello.txt"
  printf '# Plain sync\nThe folder structure is kept as is.\n' >"$local_dir/docs/readme.md"
  cp "$png" "$local_dir/photos/proof.png"
else
  rm -rf "$plain_root/tour-folder"
fi
export E2E_PLAIN_LOCAL_DIR="$local_dir"

servers=()
trap 'kill "${servers[@]}" 2>/dev/null || true' EXIT
serve() { # port root log
  if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $1 is already in use; stop that server first." >&2
    exit 4
  fi
  "$webdav_bin" --port "$1" --host 127.0.0.1 --root "$2" \
    --auth anonymous --no-config --quiet >"$3" 2>&1 &
  servers+=($!)
  for _ in {1..40}; do
    curl -sf -m 1 -o /dev/null -X OPTIONS "http://127.0.0.1:$1/" && return
    sleep 0.25
  done
}
serve "$E2E_WEBDAV_PORT" "$root" "$log_dir/webdav-tour.log"
serve "$E2E_PLAIN_PORT" "$plain_root" "$log_dir/webdav-plain.log"

commits() { { find "$root/velock-sync/v1" -path '*/devices/*/commits/*' -type f 2>/dev/null || true; } | wc -l | tr -d ' '; }
before=$(commits)
"$(dirname "$0")/run_test.sh" testSyncAppTour "$@"

fail() { echo "FAIL tour files: $*" >&2; exit 1; }
for f in docs/readme.md photos/proof.png from-remote.txt docs/remote-later.txt; do
  [[ -f "$remote_dir/$f" && -f "$local_dir/$f" ]] || fail "$f is missing on one side"
done
[[ "$(cat "$local_dir/hello.txt")" == "edited on the server" ]] || fail "conflict: hello.txt is not the server's version"
copies=("$local_dir"/hello\ \(*)
[[ ${#copies[@]} == 1 && "$(cat "${copies[0]}")" == "edited on the phone" ]] || fail "conflict: the phone's copy was not kept"
[[ ! -e "$remote_dir/local-later.txt" && ! -e "$local_dir/local-later.txt" ]] || fail "the deleted file survived"
diff -r "$local_dir" "$remote_dir" >"$log_dir/tour-diff.txt" || fail "phone and server differ, see $log_dir/tour-diff.txt"
[[ -d "$plain_root/tour-folder" && -d "$root/tour-backup-candidate" ]] || fail "folders created in the app are missing"
after=$(commits)
grep -rlF -- "hello from the phone" "$root/velock-sync" >/dev/null 2>&1 && fail "plain file content leaked into the Velock backup"
echo "PASS tour files: $(find "$local_dir" -type f | wc -l | tr -d " ") files identical on both sides (incl. kept conflict copy), deletion propagated, location removal kept data; backup commits $before -> $after"
