#!/usr/bin/env bash
# tests/test_deploy_cancel.sh — cancelling a deploy must stop the hook and
# everything it started, release locks, record "cancelled" and exit 130.
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
MARK="muster_cancel_test_$$"
trap 'pkill -f "^${MARK} " 2>/dev/null || true; rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MUSTER_NO_VERIFY=true NO_COLOR=1 MUSTER_APPROVE_HOOKS=1
mkdir -p "$HOME" "$TMP/p"
cd "$TMP/p"
M="$MUSTER_ROOT/bin/muster"
"$M" setup --services slow,quick --stack bare --health slow=none --health quick=none --name cancel --force >/dev/null 2>&1
mkdir -p .muster/hooks/slow .muster/hooks/quick
# The hook starts a long-running child (like docker build would)
printf '#!/usr/bin/env bash\necho started\nbash -c "exec -a %s sleep 300"\n' "$MARK" > .muster/hooks/slow/deploy.sh
printf '#!/usr/bin/env bash\necho fine\n' > .muster/hooks/quick/deploy.sh
chmod +x .muster/hooks/*/deploy.sh

for mode in plain json; do
  echo "  SIGTERM to the deploy's process group ($mode)"
  args=(deploy slow)
  if [[ "$mode" == "json" ]]; then
    tok=$(jq -r '.tokens | length' "$HOME/.muster/tokens/auth.json" 2>/dev/null || echo 0)
    if [[ "$tok" == "0" || ! -f "$HOME/.muster/tokens/auth.json" ]]; then
      export MUSTER_TOKEN
      MUSTER_TOKEN=$("$M" auth create t --scope admin 2>/dev/null | awk '/Token:/{print $2; exit}')
    fi
    args=(deploy --json slow)
  fi
  set -m
  "$M" "${args[@]}" > "$TMP/out.$mode" 2>&1 &
  pid=$!
  set +m
  # Anchor on argv[0]: an unanchored pattern also matches any shell whose
  # command line merely contains the marker (e.g. the checker itself, on Linux)
  for _ in $(seq 1 100); do pgrep -f "^${MARK} " >/dev/null && break; sleep 0.1; done
  _test "hook child started" bash -c "pgrep -f '^${MARK} ' >/dev/null"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid"
  rc=0; wait "$pid" || rc=$?
  sleep 1
  _test_eq "exits 130" "130" "$rc"
  if pgrep -f "^${MARK} " >/dev/null; then orphan=yes; else orphan=no; fi
  _test_eq "no orphaned hook process" "no" "$orphan"
  _test "deploy lock released" test ! -f .muster/deploy.lock
  if [[ "$mode" == "json" ]]; then
    _test_contains "emits a cancelled event" '"event":"cancelled"' "$(cat "$TMP/out.$mode")"
  else
    _test_contains "says it was cancelled" "Deploy cancelled" "$(cat "$TMP/out.$mode")"
  fi
  _test_contains "history records cancelled" "cancelled" "$(tail -1 .muster/logs/deploy-events.log)"
done

echo "  Next deploy works straight away"
"$M" deploy quick >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "next deploy exits 0" "0" "$rc"

echo ""
printf '  %d/%d tests passed\n' "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]]
