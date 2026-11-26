#!/usr/bin/env bash
# tests/test_cloud.sh — muster cloud login/logout/status against a mock relay
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  (skipped: needs python3 and jq)"
  exit 0
fi

TMP=$(mktemp -d)
RELAY_PID=""
cleanup() {
  [[ -n "$RELAY_PID" ]] && kill "$RELAY_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Never touch the real home directory or keychain
export HOME="$TMP/home"
mkdir -p "$HOME"
export MUSTER_CLOUD_NO_KEYCHAIN=1 MUSTER_NO_VERIFY=true MUSTER_NO_BROWSER=1 NO_COLOR=1

M="$MUSTER_ROOT/bin/muster"

start_relay() {
  local mode="$1"
  [[ -n "$RELAY_PID" ]] && kill "$RELAY_PID" 2>/dev/null || true
  PORT=$((20000 + RANDOM % 20000))
  MODE="$mode" python3 "$SCRIPT_DIR/fixtures/mock_relay.py" "$PORT" &
  RELAY_PID=$!
  disown "$RELAY_PID" 2>/dev/null || true

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:${PORT}/healthz" && return 0
    sleep 0.2
  done
  return 1
}

echo "  Login (approved)"
start_relay approve
out=$("$M" cloud login --relay "http://127.0.0.1:${PORT}" 2>&1) && rc=0 || rc=$?
_test_eq "login exits 0" "0" "$rc"
_test_contains "shows the user code" "WXYZ-2345" "$out"
_test_contains "confirms login" "Logged in to Fleet Cloud" "$out"
_test_eq "org saved" "org_user_abc" "$(jq -r '.cloud.org_id' "$HOME/.muster/settings.json")"
_test_eq "token not in settings.json" "0" "$(grep -c mst_cli_ "$HOME/.muster/settings.json" || true)"
_test_eq "token stored 0600" "600" "$(stat -c '%a' "$HOME/.muster/tokens/cloud.json" 2>/dev/null || stat -f '%Lp' "$HOME/.muster/tokens/cloud.json")"
_test_contains "token stored" "mst_cli_secretvalue" "$(cat "$HOME/.muster/tokens/cloud.json")"

out=$("$M" cloud status 2>&1) && rc=0 || rc=$?
_test_eq "status exits 0 when logged in" "0" "$rc"
_test_contains "status shows org" "org_user_abc" "$out"
_test_contains "status shows reachable relay" "reachable" "$out"

echo "  Logout"
"$M" cloud logout >/dev/null 2>&1
_test_eq "token removed" "0" "$(grep -c mst_cli_ "$HOME/.muster/tokens/cloud.json" || true)"
"$M" cloud status >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "status exits 1 when logged out" "1" "$rc"

echo "  Login (denied / expired / unreachable)"
start_relay deny
out=$("$M" cloud login --relay "http://127.0.0.1:${PORT}" 2>&1) && rc=0 || rc=$?
_test_eq "denied login exits 1" "1" "$rc"
_test_contains "denied message" "denied" "$out"

start_relay expire
out=$("$M" cloud login --relay "http://127.0.0.1:${PORT}" 2>&1) && rc=0 || rc=$?
_test_eq "expired login exits 1" "1" "$rc"
_test_contains "expired message" "expired" "$out"

kill "$RELAY_PID" 2>/dev/null || true
RELAY_PID=""
out=$("$M" cloud login --relay "http://127.0.0.1:1" 2>&1) && rc=0 || rc=$?
_test_eq "unreachable relay exits 1" "1" "$rc"
_test_contains "unreachable message" "Can't reach the relay" "$out"

echo ""
printf '  %d/%d tests passed\n' "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]]
