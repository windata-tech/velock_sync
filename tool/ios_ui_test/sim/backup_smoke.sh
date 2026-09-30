#!/usr/bin/env bash
# Backup smoke test on one simulator with Sync and 格间 already installed.
#
#   backup_smoke.sh [KEY=VALUE ...]
#
# Starts an anonymous local WsgiDAV (or, with E2E_NAS=1, a relay to the NAS), runs
# testBackupSmoke (pairs and adds the connection if needed, else just backs
# up), then checks the server received a signed commit and no plaintext.
#
#   E2E_WEBDAV_PORT      default 18991
#   E2E_WEBDAV_ROOT      default ui_test_results/sim/webdav-root; keep it
#                        between runs, an existing backup profile points here
#   E2E_PLAINTEXT_MARKERS  comma-separated strings that must not appear in any
#                        uploaded object (e.g. text seeded into 格间)
#   E2E_NAS=1            use the user's real NAS instead of WsgiDAV: the same
#                        anonymous 127.0.0.1 port is served by
#                        tool/local_webdav/nas_relay_proxy.py, which forwards to
#                        a per-run folder on the NAS (credentials stay in the
#                        gitignored nas_webdav.local.env). The folder name is
#                        kept in <root>/../nas-run so --from backup reuses it;
#                        after the test the folder is mirrored into E2E_WEBDAV_ROOT
#                        and the same remote checks run on the mirror.
set -euo pipefail
source "$(dirname "$0")/common.sh"
export E2E_WEBDAV_PORT="${E2E_WEBDAV_PORT:-18991}"
root="${E2E_WEBDAV_ROOT:-$OUT_DIR/webdav-root}"
webdav_bin="${E2E_WEBDAV_BIN:-$ROOT_DIR/ui_test_results/webdav_venv/bin/wsgidav}"
nas="${E2E_NAS:-0}"
relay="$ROOT_DIR/tool/local_webdav/nas_relay_proxy.py"
if [[ $nas == 1 ]]; then
  nas_env="$ROOT_DIR/tool/local_webdav/nas_webdav.local.env"
  [[ -f "$nas_env" ]] || { echo "NAS mode needs $nas_env" >&2; exit 3; }
  set -a; source "$nas_env"; set +a
  run_file="$(dirname "$root")/nas-run"
  [[ -s "$run_file" ]] || echo "e2e-$(date +%Y%m%d-%H%M%S)" >"$run_file"
  nas_run=$(<"$run_file")
else
  [[ -x "$webdav_bin" ]] || { echo "WsgiDAV not found: $webdav_bin" >&2; exit 3; }
fi
mkdir -p "$root"
if lsof -nP -iTCP:"$E2E_WEBDAV_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $E2E_WEBDAV_PORT is already in use; stop that server or set E2E_WEBDAV_PORT." >&2
  exit 4
fi

commits() { { find "$root/velock-sync/v1" -path '*/devices/*/commits/*' -type f 2>/dev/null || true; } | wc -l | tr -d ' '; }
before=$(commits)

log_dir="${E2E_LOG_DIR:-$OUT_DIR}"
if [[ $nas == 1 ]]; then
  python3 "$relay" serve --port "$E2E_WEBDAV_PORT" --run "$nas_run" \
    --log "$log_dir/nas-relay.log" >"$log_dir/nas-relay.stderr" 2>&1 &
  echo "   NAS run folder: $nas_run (relay log: $log_dir/nas-relay.log)"
else
  "$webdav_bin" --port "$E2E_WEBDAV_PORT" --host 127.0.0.1 --root "$root" \
    --auth anonymous --no-config --quiet >"$log_dir/webdav.log" 2>&1 &
fi
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in {1..40}; do
  curl -sf -m 1 -o /dev/null -X OPTIONS "http://127.0.0.1:$E2E_WEBDAV_PORT/" && break
  sleep 0.25
done

"$(dirname "$0")/run_test.sh" testBackupSmoke "$@"

if [[ $nas == 1 ]]; then
  # Stop the relay first so its summary line is written, then mirror the run
  # folder (sequentially, so the mirror itself never races the relay).
  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
  grep '^SUMMARY' "$log_dir/nas-relay.log" | tail -1 || true
  echo "   relay 401s seen by the app this run: $(grep -c ' 401 ' "$log_dir/nas-relay.log" || true) (retried by the app)"
  rm -rf "$root.mirror"
  python3 "$relay" mirror --run "$nas_run" --dest "$root.mirror"
  rm -rf "$root" && mv "$root.mirror" "$root"
fi

after=$(commits)
if [[ "$after" -lt 1 ]] || ! compgen -G "$root/velock-sync/v1/*/protocol.json" >/dev/null; then
  echo "FAIL remote: no signed commit under $root/velock-sync/v1" >&2
  exit 1
fi
checked=0
IFS=',' read -r -a markers <<<"${E2E_PLAINTEXT_MARKERS:-},"
for marker in "${markers[@]}"; do
  [[ -z "$marker" ]] && continue
  checked=$((checked + 1))
  if grep -rlF -- "$marker" "$root/velock-sync" >/dev/null 2>&1; then
    echo "FAIL remote: plaintext marker found in uploaded objects" >&2
    exit 1
  fi
done
echo "PASS remote: commits $before -> $after, $checked plaintext marker(s) absent"
