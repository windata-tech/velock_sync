#!/usr/bin/env bash
# Backup smoke test on one simulator with Sync and 格间 already installed.
#
#   backup_smoke.sh [KEY=VALUE ...]
#
# Starts an anonymous local WsgiDAV (never the user's NAS), runs
# testBackupSmoke (pairs and adds the connection if needed, else just backs
# up), then checks the server received a signed commit and no plaintext.
#
#   E2E_WEBDAV_PORT      default 18991
#   E2E_WEBDAV_ROOT      default ui_test_results/sim/webdav-root; keep it
#                        between runs, an existing backup profile points here
#   E2E_PLAINTEXT_MARKERS  comma-separated strings that must not appear in any
#                        uploaded object (e.g. text seeded into 格间)
set -euo pipefail
source "$(dirname "$0")/common.sh"
export E2E_WEBDAV_PORT="${E2E_WEBDAV_PORT:-18991}"
root="${E2E_WEBDAV_ROOT:-$OUT_DIR/webdav-root}"
webdav_bin="${E2E_WEBDAV_BIN:-$ROOT_DIR/ui_test_results/webdav_venv/bin/wsgidav}"
[[ -x "$webdav_bin" ]] || { echo "WsgiDAV not found: $webdav_bin" >&2; exit 3; }
mkdir -p "$root"
if lsof -nP -iTCP:"$E2E_WEBDAV_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $E2E_WEBDAV_PORT is already in use; stop that server or set E2E_WEBDAV_PORT." >&2
  exit 4
fi

commits() { { find "$root/velock-sync/v1" -path '*/devices/*/commits/*' -type f 2>/dev/null || true; } | wc -l | tr -d ' '; }
before=$(commits)

"$webdav_bin" --port "$E2E_WEBDAV_PORT" --host 127.0.0.1 --root "$root" \
  --auth anonymous --no-config --quiet >"${E2E_LOG_DIR:-$OUT_DIR}/webdav.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in {1..40}; do
  curl -sf -m 1 -o /dev/null -X OPTIONS "http://127.0.0.1:$E2E_WEBDAV_PORT/" && break
  sleep 0.25
done

"$(dirname "$0")/run_test.sh" testBackupSmoke "$@"

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
