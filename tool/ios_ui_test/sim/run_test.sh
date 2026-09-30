#!/usr/bin/env bash
# run_test.sh <testName> [KEY=VALUE ...]
# Runs one CrossAppUITests method on the simulator. VELOCK_RUNTIME_PASSWORD,
# VELOCK_E2E_SANDBOX_NAME and E2E_* variables from the environment/local.env
# are passed to the test runner; extra KEY=VALUE pairs override them.
# The full log stays in ui_test_results/sim/<test>.log; only a summary prints.
set -euo pipefail
source "$(dirname "$0")/common.sh"
test_name="${1:?usage: run_test.sh <testName> [KEY=VALUE ...]}"; shift
log_dir="${E2E_LOG_DIR:-$OUT_DIR}"; mkdir -p "$log_dir"
log="$log_dir/$test_name.log"
payload=$(python3 - "$test_name" "$@" <<'PY'
import json, os, sys
env = {k: v for k, v in os.environ.items()
       if k.startswith('E2E_') or k in ('VELOCK_RUNTIME_PASSWORD', 'VELOCK_E2E_SANDBOX_NAME')}
env.pop('E2E_SIMULATOR_UDID', None)
for private in ('E2E_OUT_DIR', 'E2E_LOG_DIR', 'E2E_RESET_ALLOWED_UDID'):
    env.pop(private, None)
for kv in sys.argv[2:]:
    k, v = kv.split('=', 1)
    env[k] = v
print(json.dumps({
    'extraArgs': ['-only-testing:CrossAppUITests/CrossAppUITests/' + sys.argv[1],
                  '-collect-test-diagnostics', 'never',
                  '-test-timeouts-enabled', 'YES',
                  '-maximum-test-execution-time-allowance', '1500'],
    'testRunnerEnv': env}))
PY
)
started=$SECONDS
set +e
"$XCODEBUILDMCP_BIN" simulator test \
  --project-path "$ROOT_DIR/ui_test_harness/CrossAppUITests.xcodeproj" \
  --scheme CrossAppUITests --configuration Debug --prefer-xcodebuild true \
  --simulator-id "$E2E_SIMULATOR_UDID" \
  --derived-data-path "$OUT_DIR/DerivedData" \
  --json "$payload" >"$log" 2>&1
set -e
# The CLI can exit 0 on a failed test, so decide from its summary line.
if ! grep -qE "^✅ [0-9]+ tests? passed, 0 failed" "$log"; then
  echo "FAIL $test_name ($((SECONDS - started))s) log: $log"
  grep -E "^❌|✗|failed - |error:" "$log" | grep -v SMOKE_TREE | head -12
  # Filtered element tree printed by failWithTree().
  sed -n '/SMOKE_TREE_BEGIN/,/SMOKE_TREE_END/p' "$log" | head -60
  exit 1
fi
echo "PASS $test_name ($((SECONDS - started))s)"
