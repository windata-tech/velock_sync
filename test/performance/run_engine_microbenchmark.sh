#!/usr/bin/env bash
# Two fresh test processes; artifacts stay outside the Flutter source tree.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACTS_DIR="${1:-${ROOT_DIR}_test_results/engine-microbenchmark}"
mkdir -p "$ARTIFACTS_DIR"
ARTIFACTS_DIR="$(cd "$ARTIFACTS_DIR" && pwd -P)"
case "$ARTIFACTS_DIR/" in
  "$ROOT_DIR/"*) echo "Artifacts must be outside the source tree" >&2; exit 2 ;;
esac
cd "$ROOT_DIR"
{
  printf 'scope=pure engine microbenchmark; no network/UI/App Group/adapter crypto\n'
  printf 'started_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'git_head=%s\n' "$(git rev-parse HEAD)"
  printf 'command=flutter test --no-pub test/performance/sync_engine_microbenchmark_test.dart --reporter expanded\n'
  dart --version 2>&1
  git status --short -- test/performance lib/sync_core/engine
} > "$ARTIFACTS_DIR/environment.txt"
for run in 1 2; do
  output="$ARTIFACTS_DIR/run-$run"
  mkdir -p "$output"
  if ENGINE_MICROBENCHMARK_OUTPUT_DIR="$output" /usr/bin/time -p \
    flutter test --no-pub test/performance/sync_engine_microbenchmark_test.dart \
      --reporter expanded > "$output/suite.log" 2>&1; then
    printf '0\n' > "$output/exit-code.txt"
    tail -5 "$output/suite.log"
  else
    status=$?
    printf '%s\n' "$status" > "$output/exit-code.txt"
    cat "$output/suite.log"
    exit "$status"
  fi
done
printf 'Engine-only evidence: %s\n' "$ARTIFACTS_DIR"
