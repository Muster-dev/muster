#!/usr/bin/env bash
# tests/test_ask_remote.sh — muster ask --server <name> (remote mode)
#
# A mock assistant server (tests/fixtures/mock_assist.py, MODE=remote) asks
# for every tool; stub muster-tunnel / ssh binaries play the fleet servers
# and record what would run there. Nothing touches a real machine.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  (skipped: needs python3 and jq)"
  exit 0
fi

TMP=$(mktemp -d)
SRV_PID=""
cleanup() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.muster/tokens" "$TMP/bin" "$TMP/elsewhere"
export MUSTER_CLOUD_NO_KEYCHAIN=1 MUSTER_NO_VERIFY=true MUSTER_NO_BROWSER=1 NO_COLOR=1
unset MUSTER_TOKEN MUSTER_ASK_FAILURE_SERVICE MUSTER_ASK_FAILURE_EXIT MUSTER_ASK_FAILURE_LOG

M="$MUSTER_ROOT/bin/muster"
LOG="$TMP/requests.ndjson"
export CALLS="$TMP/calls.log"

start_server() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null || true
  : > "$LOG"
  : > "$CALLS"
  PORT=$((20000 + RANDOM % 20000))
  MODE="$1" LOG="$LOG" python3 "$SCRIPT_DIR/fixtures/mock_assist.py" "$PORT" &
  SRV_PID=$!
  disown "$SRV_PID" 2>/dev/null || true
  export MUSTER_ASSIST_URL="http://127.0.0.1:${PORT}"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    curl -s -o /dev/null "${MUSTER_ASSIST_URL}/healthz" && return 0
    sleep 0.2
  done
  return 1
}

# ── Stub servers ──
cat > "$TMP/bin/muster-tunnel" <<'STUB'
#!/usr/bin/env bash
sub="$1"; shift
cmd="" agent=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cmd) cmd="$2"; shift 2 ;;
    --agent) agent="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'tunnel %s %s %s\n' "$sub" "$agent" "$cmd" >> "$CALLS"
[[ "$sub" == "ping" ]] && exit 0
case "$cmd" in
  "muster status --json --no-verify")
    [[ -n "${STATUS_FAIL:-}" ]] && { echo "Error: agent edge-agent not connected"; exit 1; }
    printf '{"project":"shop","muster_version":"0.7.3","services":{"web":{"status":"healthy"},"pond":{"status":"unhealthy","detail":"DB_PASSWORD=hunter2hunter2"}}}\n' ;;
  "muster logs web --tail 20 --no-verify")
    printf 'web log line\nusing ghp_abcdefghijklmnopqrstuvwxyz0123456789\n' ;;
  "muster logs web --tail 80 --no-verify")
    printf 'diag log line\n' ;;
  "muster history --json web --no-verify")
    printf '[{"ts":"2026-11-27T10:00:00Z","service":"web","action":"deploy","status":"failed"},{"ts":"2026-11-27T11:00:00Z","service":"web","action":"deploy","status":"ok"}]\n' ;;
  "muster hooks status --json --no-verify")
    printf '{"services":{"web":{"state":"approved"}}}\n' ;;
  "muster deploy web --dry-run --no-verify") printf 'DRY-RUN: would deploy web\n' ;;
  "muster deploy web --no-verify") printf 'deployed web\n' ;;
  "muster rollback web --no-verify") printf 'rolled back web\n' ;;
  "muster restart web --no-verify") printf 'restarted web\n' ;;
  *) printf 'unexpected\n'; exit 2 ;;
esac
STUB
cat > "$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
host="" cmd=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|-i|-p) shift 2 ;;
    *@*) host="$1"; shift; cmd="$*"; break ;;
    *) shift ;;
  esac
done
printf 'ssh %s %s\n' "$host" "$cmd" >> "$CALLS"
case "$cmd" in
  "echo ok") echo ok ;;
  *"muster status --json"*) printf '{"project":"box-app","services":{"api":{"status":"healthy"}}}\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/muster-tunnel" "$TMP/bin/ssh"
export PATH="$TMP/bin:$PATH"

# Global fleet (no project anywhere near the working directory)
cat > "$HOME/.muster/remotes.json" <<'EOF'
{"cloud":{"relay":"ws://127.0.0.1:1","org_id":"org_t","token_ref":"default"},
 "machines":{
  "edge":{"host":"edge-agent","user":"u","mode":"muster","transport":"cloud","project_dir":"/opt/app"},
  "box":{"host":"10.0.0.9","user":"deploy","mode":"muster","project_dir":"/srv/app"},
  "pusher":{"host":"10.0.0.8","user":"deploy","mode":"push","project_dir":"/srv/p"}},
 "groups":{"all":["edge","box","pusher"]},"deploy_order":["all"]}
EOF
printf '{"tokens":{"deploy@10.0.0.9:22":"boxtok"}}\n' > "$HOME/.muster/tokens/fleet.json"
printf '{"tokens":{"default":"mst_cli_testtoken123"}}\n' > "$HOME/.muster/tokens/cloud.json"
chmod 600 "$HOME/.muster/tokens/"*.json
cd "$TMP/elsewhere"
SF="$HOME/.muster/assistant/servers.json"

echo "  Help"
_test_contains "help documents --server" "--server <name>" "$("$M" ask --help)"

echo "  Server validation (nothing sent)"
start_server remote
out=$("$M" ask --server 'bad;name' --yes "hi" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "invalid name exits 1" "1" "$rc"
_test_contains "invalid name message" "Invalid server name" "$out"
out=$("$M" ask --server ghost --yes "hi" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "unknown server exits 1" "1" "$rc"
_test_contains "unknown server message" "No server named 'ghost'" "$out"
out=$("$M" ask --server pusher --yes "hi" </dev/null 2>&1) && rc=0 || rc=$?
_test_contains "push-mode server refused" "push-mode" "$out"
out=$("$M" ask --json --server ghost --yes "hi" </dev/null 2>/dev/null) && rc=0 || rc=$?
_test_eq "unknown server JSON error" "unknown_server" "$(printf '%s' "$out" | jq -r .error)"
out=$("$M" ask --server "" "hi" </dev/null 2>&1) && rc=0 || rc=$?
_test_contains "--server needs a value" "needs a server name" "$out"
_test_eq "nothing sent to the assistant" "0" "$(wc -l < "$LOG" | tr -d ' ')"

echo "  Consent (per server)"
out=$("$M" ask --server edge "hi" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "no consent (non-TTY) exits 1" "1" "$rc"
_test_contains "explains --yes" "--yes" "$out"
_test "no consent file written" bash -c "[[ ! -f '$SF' ]]"
_test_eq "nothing sent without consent" "0" "$(wc -l < "$LOG" | tr -d ' ')"

"$M" settings --global assistant off >/dev/null 2>&1
out=$("$M" ask --server edge --yes "hi" </dev/null 2>&1) && rc=0 || rc=$?
_test_contains "kill switch respected" "turned off" "$out"
"$M" settings --global assistant on >/dev/null 2>&1

echo "  Server unreachable: no session started"
out=$(STATUS_FAIL=1 "$M" ask --server edge --yes "hi" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "exits 1" "1" "$rc"
_test_contains "names the server" "Couldn't get status from edge" "$out"
_test_eq "no assistant session used" "0" "$(wc -l < "$LOG" | tr -d ' ')"

echo "  Read tools run on the server (outside any project)"
start_server remote
out=$("$M" ask --server edge --yes "is everything healthy?" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "exits 0" "0" "$rc"
_test_file_exists "consent file" "$SF"
_test_eq "consent recorded for the server" "true" "$(jq -r .servers.edge.consent "$SF")"
_test_eq "consent file is 0600" "600" "$(stat -f '%Lp' "$SF" 2>/dev/null || stat -c '%a' "$SF")"
_test_contains "header names the server" "Server edge (cloud)" "$out"
session=$(jq -c 'select(.path == "/api/assist/sessions") | .body' "$LOG")
_test_eq "project from the server" "shop" "$(printf '%s' "$session" | jq -r .project)"
_test_eq "surface cli" "cli" "$(printf '%s' "$session" | jq -r .context.surface)"
_test_eq "context names the server" "edge|cloud|muster" "$(printf '%s' "$session" | jq -r '.context.remote | "\(.server)|\(.transport)|\(.mode)"')"
_test_eq "remote muster version" "0.7.3" "$(printf '%s' "$session" | jq -r .context.remote.muster_version)"
_test_eq "services from the server" "pond,web" "$(printf '%s' "$session" | jq -r '.context.services | join(",")')"
_test_contains "note says tools run there" "Every tool runs on that server" "$(printf '%s' "$session" | jq -r .context.note)"
res=$(jq -c 'select(.body.tool_results) | .body.tool_results' "$LOG" | sed -n 1p)
_r() { printf '%s' "$res" | jq -r --arg id "$1" '.[] | select(.tool_use_id == $id) | .content'; }
_e() { printf '%s' "$res" | jq -r --arg id "$1" '.[] | select(.tool_use_id == $id) | .is_error'; }
_test_eq "all ten results sent" "10" "$(printf '%s' "$res" | jq length)"
_test_eq "status → remote status --json" "unhealthy" "$(_r s1 | jq -r .services.pond.status)"
_test_not_contains "status redacted" "hunter2hunter2" "$(_r s1)"
_test_contains "logs → fleet logs --tail" "web log line" "$(_r s2)"
_test_not_contains "logs redacted" "ghp_abcdefghij" "$(_r s2)"
_test_eq "history → remote history --json, limited" "1|ok" "$(_r s3 | jq -r '"\(length)|\(.[0].status)"')"
_test_eq "hooks status → remote hooks status --json" "approved" "$(_r s4 | jq -r .services.web.state)"
_test_eq "diagnose combines status + history + logs" "edge|healthy|failed|diag log line" \
  "$(_r s5 | jq -r '"\(.server)|\(.status.status)|\(.last_failure.status)|\(.log_tail[0])"')"
for id in s6 s7 s8; do
  _test_contains "$id unavailable remotely" "not available for remote servers yet" "$(_r "$id")"
  _test_eq "$id is an error" "true" "$(_e "$id")"
done
_test_contains "unknown service rejected" "Unknown service: nope (services on edge" "$(_r s9)"
_test_contains "dry-run deploy runs on the server" "DRY-RUN" "$(_r s10)"
_test "remote status ran via the tunnel" grep -q "tunnel exec edge-agent muster status --json --no-verify" "$CALLS"
_test "logs ran via the tunnel" grep -q "tunnel exec edge-agent muster logs web --tail 20 --no-verify" "$CALLS"
_test_not_contains "read_config never reached the server" "muster.json" "$(cat "$CALLS")"

echo "  Actions need approval"
r2=$(jq -c 'select(.body.tool_results) | .body.tool_results' "$LOG" | sed -n 2p)
_test_eq "actions declined without a terminal" "true,true,true" \
  "$(printf '%s' "$r2" | jq -r '[.[] | select(.tool_use_id != "a4") | .is_error | tostring] | join(",")')"
_test_eq "declined content" "The user declined this action." "$(printf '%s' "$r2" | jq -r '.[] | select(.tool_use_id == "a1") | .content')"
_test_not_contains "no restart ran" "restart web" "$(cat "$CALLS")"
_test_not_contains "no rollback ran" "rollback web" "$(cat "$CALLS")"
_test_not_contains "no deploy ran" "muster deploy web --no-verify" "$(cat "$CALLS")"
_test_contains "hook edit refused (not asked)" "not available for remote servers yet" \
  "$(printf '%s' "$r2" | jq -r '.[] | select(.tool_use_id == "a4") | .content')"

start_server remote
out=$("$M" ask --server edge --allow-actions "fix it" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "--allow-actions exits 0" "0" "$rc"
_test "restart → fleet restart on the server" grep -q "tunnel exec edge-agent muster restart web --no-verify" "$CALLS"
_test "rollback ran on the server" grep -q "tunnel exec edge-agent muster rollback web --no-verify" "$CALLS"
_test "deploy ran on the server" grep -q "tunnel exec edge-agent muster deploy web --no-verify" "$CALLS"
r2=$(jq -c 'select(.body.tool_results) | .body.tool_results' "$LOG" | sed -n 2p)
_test_contains "restart output sent back" "restarted" "$(printf '%s' "$r2" | jq -r '.[] | select(.tool_use_id == "a1") | .content')"
_test_eq "approved actions not errors" "false,false,false" \
  "$(printf '%s' "$r2" | jq -r '[.[] | select(.tool_use_id != "a4") | .is_error | tostring] | join(",")')"

echo "  --json"
start_server remote
out=$(printf '{"approve":"a1"}\n' | "$M" ask --json --server edge "x" 2>/dev/null) && rc=0 || rc=$?
_test "every stdout line is JSON" bash -c 'printf "%s\n" "$1" | jq -e -s "length > 0" >/dev/null' _ "$out"
_test_eq "session event names the server" "edge|cloud" "$(printf '%s\n' "$out" | jq -r 'select(.type == "session") | "\(.server)|\(.transport)"')"
_test_eq "approval_needed names the server" "edge" "$(printf '%s\n' "$out" | jq -r 'select(.type == "approval_needed" and .tool_use_id == "a1") | .server')"
_test "approved via stdin → restart ran" grep -q "muster restart web" "$CALLS"
_test_not_contains "unapproved rollback did not run" "rollback web" "$(cat "$CALLS")"
_test_eq "no approval asked for the hook edit" "" "$(printf '%s\n' "$out" | jq -r 'select(.type == "approval_needed" and .tool_use_id == "a4") | .tool_use_id')"

echo "  SSH muster-mode server"
start_server normal
out=$("$M" ask --server box --yes --read-only "hi" </dev/null 2>&1) && rc=0 || rc=$?
_test "status over SSH with the paired token" grep -q "ssh deploy@10.0.0.9 cd /srv/app && MUSTER_TOKEN=boxtok muster status --json" "$CALLS"
_test_eq "context transport ssh" "box|ssh" "$(jq -r 'select(.path == "/api/assist/sessions") | .body.context.remote | "\(.server)|\(.transport)"' "$LOG")"
_test_eq "consent stored per server" "true|true" "$(jq -r '"\(.servers.edge.consent)|\(.servers.box.consent)"' "$SF")"

echo "  fleet history"
out=$(MUSTER_TOKEN="" "$M" fleet history edge web 2>&1) && rc=0 || rc=$?
_test_contains "fleet history (human) runs remote history" "tunnel exec edge-agent muster history web" "$(cat "$CALLS")"
# The assistant's local API token (deploy scope) passes the read gate
T=$(cat "$HOME/.muster/assistant/local-token")
out=$(MUSTER_TOKEN="$T" "$M" fleet history edge web --json 2>/dev/null) && rc=0 || rc=$?
_test_eq "fleet history --json array" "2" "$(printf '%s' "$out" | jq length)"
out=$(MUSTER_TOKEN="$T" "$M" fleet history pusher --json 2>&1 >/dev/null) && rc=0 || rc=$?
_test_contains "fleet history refuses push mode" "push_mode" "$out"

_test_summary
