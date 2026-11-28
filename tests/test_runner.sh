#!/usr/bin/env bash
# tests/test_runner.sh — Discover and run all test files
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Isolate every test from the real home directory: tests must never read
# or write ~/.muster (skills, tokens, settings) on the developer's machine.
_TEST_HOME=$(mktemp -d)
trap 'rm -rf "$_TEST_HOME"' EXIT
export HOME="$_TEST_HOME"
export MUSTER_CLOUD_NO_KEYCHAIN=1 MUSTER_NO_BROWSER=1
# Tests deploy failing services on purpose: no ::error annotations on the
# repo's own CI runs (tests/test_ci.sh turns them on where it checks them).
export MUSTER_GITHUB_ANNOTATIONS=off

failures=0
ran=0

for f in "$SCRIPT_DIR"/test_*.sh "$SCRIPT_DIR"/test-*.sh; do
  [[ -f "$f" ]] || continue
  name=$(basename "$f")
  # Skip helpers and this runner
  [[ "$name" == "test_helpers.sh" ]] && continue
  [[ "$name" == "test_runner.sh" ]] && continue

  echo ""
  echo "=== ${name} ==="
  ran=$(( ran + 1 ))
  if ! bash "$f"; then
    failures=$(( failures + 1 ))
  fi
done

echo ""
echo "────────────────────────────────"
if (( failures == 0 )); then
  printf '\033[38;5;114mAll %d test files passed\033[0m\n' "$ran"
else
  printf '\033[38;5;203m%d/%d test files had failures\033[0m\n' "$failures" "$ran"
fi
echo ""

exit $failures
