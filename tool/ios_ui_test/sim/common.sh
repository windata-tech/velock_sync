# Shared settings for the single-simulator helpers. Source, don't run.
#
# Private values (password, sandbox name, simulator) go in local.env next to
# this file. It is gitignored; see local.env.example.
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SIM_DIR/../../.." && pwd)"
# A simulator given on the command line (e.g. a second, restore device) wins
# over local.env; reset stays limited to E2E_RESET_ALLOWED_UDID either way.
_caller_udid="${E2E_SIMULATOR_UDID:-}"
[[ -f "$SIM_DIR/local.env" ]] && { set -a; source "$SIM_DIR/local.env"; set +a; }
[[ -n "$_caller_udid" ]] && E2E_SIMULATOR_UDID="$_caller_udid"

AXE="${AXE:-/opt/homebrew/lib/node_modules/xcodebuildmcp/bundled/axe}"
XCODEBUILDMCP_BIN="${XCODEBUILDMCP_BIN:-/opt/homebrew/bin/xcodebuildmcp}"
OUT_DIR="${E2E_OUT_DIR:-$ROOT_DIR/ui_test_results/sim}"
mkdir -p "$OUT_DIR"

# Explicit UDID, else the only booted simulator. Never guesses between several.
if [[ -z "${E2E_SIMULATOR_UDID:-}" ]]; then
  booted=$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
ids = [d["udid"] for r in json.load(sys.stdin)["devices"].values() for d in r if d["state"] == "Booted"]
print(ids[0] if len(ids) == 1 else "")')
  if [[ -z "$booted" ]]; then
    echo "Set E2E_SIMULATOR_UDID (in local.env): zero or several simulators are booted." >&2
    exit 2
  fi
  E2E_SIMULATOR_UDID="$booted"
fi
export E2E_SIMULATOR_UDID
