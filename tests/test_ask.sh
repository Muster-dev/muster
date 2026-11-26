#!/usr/bin/env bash
# tests/test_ask.sh — muster ask against a mock assistant server
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  echo "  (skipped: needs python3, jq and openssl)"
  exit 0
fi

TMP=$(mktemp -d)
SRV_PID=""
cleanup() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Never touch the real home directory or keychain
export HOME="$TMP/home"
mkdir -p "$HOME"
export MUSTER_CLOUD_NO_KEYCHAIN=1 MUSTER_NO_VERIFY=true MUSTER_NO_BROWSER=1 NO_COLOR=1
unset MUSTER_TOKEN MUSTER_ASK_FAILURE_SERVICE MUSTER_ASK_FAILURE_EXIT MUSTER_ASK_FAILURE_LOG

M="$MUSTER_ROOT/bin/muster"
LOG="$TMP/requests.ndjson"
MARK="$TMP/rolled-back"

start_server() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null || true
  : > "$LOG"
  rm -f "$MARK"
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

# ── Project with a failed deploy that leaks secrets in its log ──
mkdir -p "$TMP/p"
cd "$TMP/p"
git init -q .
"$M" setup --services api,web --stack bare --health api=none --health web=none --name shop --force >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho "connecting with DB_PASSWORD=hunter2hunter2 to postgres://app:pgS3cret@db/app"\necho "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"\nexit 1\n' > .muster/hooks/api/deploy.sh
printf '#!/usr/bin/env bash\necho rolled > "%s"\necho "api rolled back"\n' "$MARK" > .muster/hooks/api/rollback.sh
printf '#!/usr/bin/env bash\necho "live: retrying with DB_PASSWORD=hunter2hunter2"\n' > .muster/hooks/api/logs.sh
rm -f .muster/hooks/web/logs.sh
chmod +x .muster/hooks/api/*.sh
printf 'APP_SIGNING_VALUE=zebra-banana-42\nPORT=3000\n' > .env
printf '#!/usr/bin/env bash\necho "starting with zebra-banana-42"\nexit 1\n' > .muster/hooks/web/deploy.sh
"$M" hooks approve --yes >/dev/null 2>&1
"$M" deploy api </dev/null >"$TMP/deploy.out" 2>&1 || true

echo "  Failed non-interactive deploy hint"
_test_contains "deploy prints 'Get help: muster ask'" "Get help: muster ask" "$(cat "$TMP/deploy.out")"

echo "  Preconditions"
start_server normal
out=$("$M" ask --yes "why?" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "not logged in exits 1" "1" "$rc"
_test_contains "suggests muster cloud login" "muster cloud login" "$out"

mkdir -p "$HOME/.muster/tokens"
printf '{"tokens":{"default":"mst_cli_testtoken123"}}\n' > "$HOME/.muster/tokens/cloud.json"
chmod 600 "$HOME/.muster/tokens/cloud.json"

out=$("$M" ask "why?" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "no consent (non-TTY) exits 1" "1" "$rc"
_test_contains "explains --yes" "--yes" "$out"
_test_eq "nothing sent without consent" "0" "$(wc -l < "$LOG" | tr -d ' ')"

"$M" settings --global assistant off >/dev/null 2>&1
out=$("$M" ask --yes "why?" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "kill switch exits 1" "1" "$rc"
_test_contains "kill switch message" "turned off" "$out"
_test_eq "nothing sent when disabled" "0" "$(wc -l < "$LOG" | tr -d ' ')"
"$M" settings --global assistant on >/dev/null 2>&1

echo "  Read tools auto-run, actions declined without a terminal"
out=$("$M" ask --yes "why did api fail?" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "exits 0" "0" "$rc"
_test_file_exists "consent stored" "$TMP/p/.muster/assistant.json"
_test_eq "consent recorded" "true" "$(jq -r .consent .muster/assistant.json)"
_test_contains "consent file gitignored" ".muster/assistant.json" "$(cat .gitignore)"
_test_contains "streams text" "Let me check the current status first." "$out"
_test_not_contains "bold markers rendered" "**" "$out"
_test_contains "dim read line" "Reading api logs" "$out"
_test_contains "action summary shown" "Roll back api to the previous version" "$out"
_test_contains "declined without terminal" "Declined (no terminal" "$out"
_test "rollback hook did not run" bash -c "[[ ! -f '$MARK' ]]"
_test_contains "markdown bullet" "- Rolled back api" "$out"
session=$(jq -c 'select(.path == "/api/assist/sessions") | .body' "$LOG")
_test_eq "session project" "shop" "$(printf '%s' "$session" | jq -r .project)"
_test_eq "context includes the failed service" "api" "$(printf '%s' "$session" | jq -r .context.failure.service)"
_test_eq "context services" "api,web" "$(printf '%s' "$session" | jq -r '.context.services | join(",")')"
_test_eq "bearer token sent" "Bearer mst_cli_testtoken123" "$(jq -r 'select(.path == "/api/assist/sessions") | .auth' "$LOG")"
r1=$(jq -c 'select(.body.tool_results) | .body.tool_results' "$LOG" | sed -n 1p)
_test_eq "both read results in one turn" "tu_status,tu_logs" "$(printf '%s' "$r1" | jq -r 'map(.tool_use_id) | join(",")')"
_test_contains "status result is muster status --json" '"services"' "$(printf '%s' "$r1" | jq -r '.[0].content')"
_test_contains "logs result has the service's log output" "DB_PASSWORD=" "$(printf '%s' "$r1" | jq -r '.[1].content')"
r2=$(jq -c 'select(.body.tool_results) | .body.tool_results' "$LOG" | sed -n 2p)
_test_eq "declined action is_error" "true" "$(printf '%s' "$r2" | jq -r '.[0].is_error')"
_test_eq "declined action content" "The user declined this action." "$(printf '%s' "$r2" | jq -r '.[0].content')"

echo "  Redaction of everything sent"
all=$(jq -c . "$LOG")
_test_not_contains "no DB password" "hunter2hunter2" "$all"
_test_not_contains "no URL password" "pgS3cret" "$all"
_test_not_contains "no GitHub token" "ghp_abcdefghij" "$all"
_test_not_contains "no CLI token in bodies" "mst_cli_testtoken123" "$(jq -c .body "$LOG")"
_test_contains "masked marker present" "‹redacted›" "$all"

echo "  --allow-actions"
start_server normal
out=$("$M" ask --allow-actions "why did api fail?" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "exits 0" "0" "$rc"
_test_file_exists "rollback hook ran" "$MARK"
r2=$(jq -c 'select(.body.tool_results) | .body.tool_results' "$LOG" | sed -n 2p)
_test_eq "action result not an error" "false" "$(printf '%s' "$r2" | jq -r '.[0].is_error')"
_test_contains "action output sent back" "rolled back" "$(printf '%s' "$r2" | jq -r '.[0].content')"

echo "  --read-only"
start_server normal
"$M" ask --read-only --allow-actions "why?" </dev/null >/dev/null 2>&1 || true
_test "read-only never runs actions" bash -c "[[ ! -f '$MARK' ]]"

echo "  --json with stdin approvals"
start_server normal
out=$(printf '{"approve":"tu_rb"}\n{"message":"and now?"}\n' | "$M" ask --json "why did api fail?" 2>/dev/null) && rc=0 || rc=$?
_test_eq "exits 0" "0" "$rc"
_test "every stdout line is JSON" bash -c 'printf "%s\n" "$1" | jq -e -s "length > 0" >/dev/null' _ "$out"
types=$(printf '%s\n' "$out" | jq -r .type | tr '\n' ' ')
_test_contains "session event" "session" "$types"
_test_contains "server text events passed through" "text" "$types"
_test_contains "tool_request passed through" "tool_request" "$types"
_test_contains "tool_running event" "tool_running" "$types"
_test_contains "approval_needed event" "approval_needed" "$types"
_test_contains "tool_result event" "tool_result" "$types"
_test_contains "done event" "done" "$types"
_test_eq "approval_needed names the rollback" "tu_rb" "$(printf '%s\n' "$out" | jq -r 'select(.type == "approval_needed") | .tool_use_id')"
_test_file_exists "approved via stdin → rollback ran" "$MARK"
_test_contains "follow-up message from stdin" "Follow-up answer." "$(printf '%s\n' "$out" | jq -r 'select(.type == "text") | .delta' | tr -d '\n')"

start_server normal
printf '{"decline":"tu_rb"}\n' | "$M" ask --json "why?" >/dev/null 2>&1 || true
_test "declined via stdin → rollback did not run" bash -c "[[ ! -f '$MARK' ]]"
_test_eq "decline sent as is_error" "true" "$(jq -r 'select(.body.tool_results) | .body.tool_results[] | select(.tool_use_id == "tu_rb") | .is_error' "$LOG")"

echo "  Input validation"
start_server badtools
out=$("$M" ask --allow-actions "x" </dev/null 2>&1) && rc=0 || rc=$?
res=$(jq -c 'select(.body.tool_results) | .body.tool_results' "$LOG" | sed -n 1p)
_test_contains "unknown tool rejected" "Unknown tool: rm_rf" "$(printf '%s' "$res" | jq -r '.[] | select(.tool_use_id == "tu_a") | .content')"
_test_contains "unknown service rejected" "Unknown service: nope" "$(printf '%s' "$res" | jq -r '.[] | select(.tool_use_id == "tu_b") | .content')"
_test_contains "shell metacharacters rejected" "metacharacters" "$(printf '%s' "$res" | jq -r '.[] | select(.tool_use_id == "tu_c") | .content')"
_test_eq "all rejections are errors" "true,true,true" "$(printf '%s' "$res" | jq -r '[.[] | select(.tool_use_id != "tu_d") | .is_error] | map(tostring) | join(",")')"
_test_contains "server 'read' label on an action is ignored (approval asked)" "Approved by --allow-actions" "$out"

start_server badtools
"$M" ask "x" </dev/null >/dev/null 2>&1 || true
_test "mislabelled action declined without a terminal" bash -c "[[ ! -f '$MARK' ]]"

echo "  Every read tool"
start_server allreads
jq '.services.api.credentials = {"mode": "save", "keys": ["DB_PASSWORD"]} | .services.api.env = {"API_TOKEN": "abc123xyz789"}' muster.json > muster.json.tmp && mv muster.json.tmp muster.json
"$M" hooks approve --yes >/dev/null 2>&1
out=$("$M" ask "x" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "exits 0" "0" "$rc"
res=$(jq -c 'select(.body.tool_results) | .body.tool_results' "$LOG" | sed -n 1p)
_r() { printf '%s' "$res" | jq -r --arg id "$1" '.[] | select(.tool_use_id == $id) | .content'; }
_test_eq "all ten results sent" "10" "$(printf '%s' "$res" | jq length)"
_test_contains "history for a service (limited)" '"service":"api"' "$(_r r1)"
_test "history JSON array" bash -c 'printf "%s" "$1" | jq -e "type == \"array\"" >/dev/null' _ "$(_r r2)"
_test_contains "doctor JSON" "{" "$(_r r3)"
_test_eq "diagnose names the service" "api" "$(_r r4 | jq -r .service)"
_test_contains "diagnose includes the log tail" "connecting with DB_PASSWORD" "$(_r r4)"
_test_not_contains "diagnose log tail redacted" "hunter2hunter2" "$(_r r4)"
_test_contains "hooks status reported" "hook" "$(_r r5 | tr 'A-Z' 'a-z')"
_test_eq "read_config strips credentials" "null" "$(_r r6 | jq -c .services.api.credentials)"
_test_eq "read_config masks env values" "‹redacted›" "$(_r r6 | jq -r .services.api.env.API_TOKEN)"
_test_contains "read_hook returns the hook" "#!/usr/bin/env bash" "$(_r r7)"
_test_not_contains "read_hook is redacted" "hunter2hunter2" "$(_r r7)"
_test_contains "dry-run deploy runs as a read tool" "DRY-RUN" "$(_r r9)"
_test_not_contains "dry-run needs no approval" "Declined" "$out"
_test_contains "logs for a never-deployed service explain why" "web" "$(_r r10)"
_test_eq "missing logs reported as an error" "true" "$(printf '%s' "$res" | jq -r '.[] | select(.tool_use_id == "r10") | .is_error')"

echo "  propose_hook_edit"
start_server hookedit
out=$("$M" ask "fix the hook" </dev/null 2>&1) && rc=0 || rc=$?
_test_contains "shows the diff" "+set -e" "$out"
_test_not_contains "declined edit not applied" "set -e" "$(cat .muster/hooks/api/deploy.sh)"
start_server hookedit
out=$("$M" ask --allow-actions "fix the hook" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "exits 0" "0" "$rc"
_test_contains "approved edit applied" "set -e" "$(cat .muster/hooks/api/deploy.sh)"
_test "hook stays executable" test -x .muster/hooks/api/deploy.sh
_test_contains "hook approved with the same approval" "Approved on this machine" "$out"
_test_contains "hooks verify passes" "All hooks verified" "$("$M" hooks verify 2>&1)"

echo "  Errors"
start_server 402
out=$("$M" ask "x" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "402 exits 1" "1" "$rc"
_test_contains "402 prints the upgrade URL" "https://cloud.example.test/billing" "$out"
out=$("$M" ask --json "x" </dev/null 2>/dev/null) && rc=0 || rc=$?
_test_eq "402 --json error code" "payment_required" "$(printf '%s\n' "$out" | jq -r 'select(.type == "error") | .error')"
_test_eq "402 --json upgrade_url" "https://cloud.example.test/billing" "$(printf '%s\n' "$out" | jq -r 'select(.type == "error") | .upgrade_url')"

start_server 401
out=$("$M" ask "x" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "401 exits 1" "1" "$rc"
_test_contains "401 suggests muster cloud login" "muster cloud login" "$out"

start_server dropped
out=$("$M" ask "x" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "dropped stream exits 1" "1" "$rc"
_test_contains "dropped stream message" "connection dropped" "$out"

kill "$SRV_PID" 2>/dev/null || true
SRV_PID=""
out=$(MUSTER_ASSIST_URL="http://127.0.0.1:1" "$M" ask "x" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "unreachable server exits 1" "1" "$rc"
_test_contains "network error message" "Can't reach the Muster Assistant" "$out"

_test_summary
