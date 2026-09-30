#!/usr/bin/env bash
# Compact accessibility dump of the simulator screen:
#   type | label | identifier | center
# Optional argument filters lines (grep -i -E), e.g. ui.sh 'backup|webdav'.
set -euo pipefail
source "$(dirname "$0")/common.sh"
"$AXE" describe-ui --udid "$E2E_SIMULATOR_UDID" | python3 -c '
import json, sys
def walk(n):
    f = n.get("frame") or {}
    label, uid = n.get("AXLabel") or "", n.get("AXUniqueId") or ""
    if label or uid:
        cx = round(f.get("x", 0) + f.get("width", 0) / 2)
        cy = round(f.get("y", 0) + f.get("height", 0) / 2)
        kind = n.get("type", "?")
        print(f"{kind} | {label[:60]!r} | {uid} | {cx},{cy}")
    for c in n.get("children") or []:
        walk(c)
data = json.load(sys.stdin)
for root in data if isinstance(data, list) else [data]:
    walk(root)
' | { if [[ $# -gt 0 ]]; then grep -i -E "$1" || true; else cat; fi; }
