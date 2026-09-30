#!/usr/bin/env bash
# tap.sh <identifier> [settle-seconds]   tap by accessibility identifier
# tap.sh <x> <y> [settle-seconds]        tap a point
# Prints the screen afterwards (ui.sh) so one call shows the result.
set -euo pipefail
source "$(dirname "$0")/common.sh"
if [[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9]+$ ]]; then
  "$AXE" tap -x "$1" -y "$2" --tap-style physical --udid "$E2E_SIMULATOR_UDID"
  settle="${3:-1}"
else
  "$AXE" tap --id "$1" --tap-style physical --wait-timeout 10 --udid "$E2E_SIMULATOR_UDID"
  settle="${2:-1}"
fi
sleep "$settle"
"$(dirname "$0")/ui.sh"
