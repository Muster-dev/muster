#!/usr/bin/env bash
# tests/test_auth_concurrency.sh — concurrent --json calls must never wipe the token store
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MUSTER_NO_VERIFY=true NO_COLOR=1
mkdir -p "$HOME" "$TMP/proj"
M="$MUSTER_ROOT/bin/muster"

cd "$TMP/proj"
"$M" setup --services api --stack bare --health api=none --name conc --force >/dev/null 2>&1

# First token can be created without auth
token=$("$M" auth create tui --scope admin 2>/dev/null | awk '/Token:/ {print $2; exit}')
_test "created a token" test -n "$token"
"$M" auth create other --scope read >/dev/null 2>&1 || true
before=$(jq '.tokens | length' "$HOME/.muster/tokens/auth.json")

echo "  6 concurrent --json calls x 5 rounds"
for _round in 1 2 3 4 5; do
  for _ in 1 2 3 4 5 6; do
    MUSTER_TOKEN="$token" "$M" history --json >/dev/null 2>&1 &
  done
  wait
done

after=$(jq '.tokens | length' "$HOME/.muster/tokens/auth.json" 2>/dev/null || echo "invalid")
_test_eq "token store still valid with all tokens" "$before" "$after"
_test_eq "no temp files left behind" "0" "$(find "$HOME/.muster/tokens" -name 'auth.json.*' | wc -l | tr -d ' ')"
_test "lock released" test ! -d "$HOME/.muster/tokens/auth.json.lock"
MUSTER_TOKEN="$token" "$M" history --json >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "token still works afterwards" "0" "$rc"

echo ""
printf '  %d/%d tests passed\n' "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]]
