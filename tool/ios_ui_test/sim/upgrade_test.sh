#!/usr/bin/env bash
# Upgrade check for Velock: install the OLD release, fill it with the six kinds
# of data through the real UI, then install the NEW build over it (data kept,
# like an App Store update) and prove everything still unlocks and opens.
#
#   upgrade_test.sh <old Runner.app> [new Velock.app]
#
# The old app is a simulator build of the previous release, e.g. from a
# worktree:  git -C ../velock_codex worktree add --detach ../velock_206 25e14d9
#            (cd ../velock_206 && flutter build ios --simulator --debug --dart-define=VELOCK_E2E_FIXTURES=true)
# The new app defaults to e2e.sh's build ($OUT_DIR/apps/Velock.app).
# Resets the simulator, so it only runs on E2E_RESET_ALLOWED_UDID.
set -uo pipefail
SIM="$(cd "$(dirname "$0")" && pwd)"
source "$SIM/common.sh"
U="$E2E_SIMULATOR_UDID"
[[ "${E2E_RESET_ALLOWED_UDID:-}" == "$U" ]] || { echo "Refusing to reset $U (E2E_RESET_ALLOWED_UDID)" >&2; exit 1; }
APPS="$OUT_DIR/apps"; OLD_SRC="${1:?old Runner.app}"; NEW="${2:-$APPS/Velock.app}"
run_dir="$OUT_DIR/upgrade-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$run_dir"
OLD="$APPS/Velock-old.app"; rm -rf "$OLD"; cp -R "$OLD_SRC" "$OLD"

ent="$APPS/simulator.entitlements"
sign() {
  local app="$1" bin
  while IFS= read -r -d '' bin; do codesign --force --sign - "$bin" >/dev/null 2>&1; done \
    < <(find "$app/Frameworks" -type f -perm -111 -print0 2>/dev/null)
  codesign --force --entitlements "$ent" --sign - "$app" >/dev/null 2>&1
}
[[ -f "$ent" ]] || { echo "Missing $ent: run e2e.sh --only build once" >&2; exit 1; }
sign "$OLD"
echo "old: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$OLD/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$OLD/Info.plist"))"
echo "new: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$NEW/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$NEW/Info.plist"))"

failures=()
step() { # name command...
  local name="$1"; shift
  echo "── $name"
  if "$@" >"$run_dir/$name.log" 2>&1; then echo "   ok"; else echo "   FAIL (see $run_dir/$name.log)"; tail -5 "$run_dir/$name.log" | sed 's/^/   /'; failures+=("$name"); fi
}
probe() { # phase  — unlock and open file, photo and credential contents
  local p="$1"
  for kind in File Photo Credential; do
    mkdir -p "$run_dir/$p-content"
    step "$p-open-$kind" "$SIM/run_test.sh" "testTutorial${kind}ContentProbe" E2E_TUTORIAL_DIR="$run_dir/$p-content"
  done
  step "$p-verify" "$SIM/e2e.sh" --only verify
  cp "$OUT_DIR/runs/current/source-evidence.json" "$run_dir/$p-evidence.json" 2>/dev/null
}

echo "── reset"
for id in tech.windata.velock.sync tech.windata.velock; do
  xcrun simctl terminate "$U" "$id" >/dev/null 2>&1; xcrun simctl uninstall "$U" "$id" >/dev/null 2>&1
done
xcrun simctl install "$U" "$APPS/Sync.app"
xcrun simctl install "$U" "$OLD"
xcrun simctl privacy "$U" grant photos tech.windata.velock

# Seed with the OLD app, exactly as a user of that release would have.
step old-init "$SIM/e2e.sh" --only init
step old-document "$SIM/e2e.sh" --only document
step old-file "$SIM/e2e.sh" --only file
step old-photo "$SIM/e2e.sh" --only photo
probe old

data=$(xcrun simctl get_app_container "$U" tech.windata.velock data)
(cd "$data" && find . -type f -not -path './tmp/*' -not -path './Library/Caches/*' -print0 | xargs -0 shasum) | sort -k2 >"$run_dir/old-files.sha"

echo "── upgrade: install the new build over the old one"
xcrun simctl terminate "$U" tech.windata.velock >/dev/null 2>&1
xcrun simctl install "$U" "$NEW"
probe new
data=$(xcrun simctl get_app_container "$U" tech.windata.velock data)
(cd "$data" && find . -type f -not -path './tmp/*' -not -path './Library/Caches/*' -print0 | xargs -0 shasum) | sort -k2 >"$run_dir/new-files.sha"

echo "── files from the old version that are gone after the upgrade:"
comm -23 <(awk '{print $2}' "$run_dir/old-files.sha") <(awk '{print $2}' "$run_dir/new-files.sha") | tee "$run_dir/removed.txt" | sed 's/^/   /' | head -40
echo "── evidence before / after:"
python3 - "$run_dir" <<'PY'
import json, sys, os
d = sys.argv[1]
for p in ('old', 'new'):
    f = os.path.join(d, p + '-evidence.json')
    e = json.load(open(f)) if os.path.exists(f) else {}
    print('  ', p, ', '.join(f'{k}={len(v)}' for k, v in e.items()) or 'n/a')
PY
if ((${#failures[@]})); then echo "FAILED: ${failures[*]}  (logs: $run_dir)"; exit 1; fi
echo "UPGRADE CHECK PASSED  (logs: $run_dir)"
