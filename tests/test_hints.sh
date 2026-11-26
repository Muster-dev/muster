#!/usr/bin/env bash
# tests/test_hints.sh — offline rules engine (lib/core/hints.sh) and
# `muster explain` (human + --json). docker/lsof are mocked.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUSTER_BIN="$MUSTER_ROOT/bin/muster"
FIX="$SCRIPT_DIR/fixtures/hints"

source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/mock_helpers.sh"

TEST_TMP=$(mktemp -d)
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"
export MUSTER_NO_VERIFY=true
unset NO_COLOR
_mock_init
trap 'rm -rf "${TEST_TMP:?}"; _mock_cleanup' EXIT

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE="" GRAY=""
MUSTER_QUIET="false"
MUSTER_MINIMAL="false"
source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"
source "$MUSTER_ROOT/lib/core/hints.sh"

# ────────────────────────────────────────
echo "  Rules engine — fixtures map to the expected rule"
# ────────────────────────────────────────

for f in "$FIX"/*.log; do
  name=$(basename "$f" .log)
  expected="${name%%__*}"
  [[ "$expected" == "normal" ]] && continue
  got="none"
  if hints_match_file "$f" 1 api; then got="$HINT_ID"; fi
  _test_eq "${name}" "$expected" "$got"
done

# ────────────────────────────────────────
echo ""
echo "  Rules engine — no false positives on normal logs"
# ────────────────────────────────────────

for f in "$FIX"/normal__*.log; do
  got="none"
  if hints_match_file "$f" 0 api; then got="$HINT_ID"; fi
  _test_eq "$(basename "$f" .log) matches nothing" "none" "$got"
done

# ────────────────────────────────────────
echo ""
echo "  Rules engine — exit codes"
# ────────────────────────────────────────

hints_match_text "still waiting for rollout" 124 api || true
_test_eq "exit 124 → deploy_timeout" "deploy_timeout" "$HINT_ID"
hints_match_text "nothing useful" 127 api || true
_test_eq "exit 127 with no clue → command_not_found" "command_not_found" "$HINT_ID"
hints_match_text "nothing useful" 137 api || true
_test_eq "exit 137 with no clue → oom_killed" "oom_killed" "$HINT_ID"
_rc=0; hints_match_text "nothing useful" 1 api || _rc=$?
_test_eq "exit 1 with no clue → no match" "1" "$_rc"
hints_match_text "Bind for 0.0.0.0:8080 failed: port is already allocated" 124 api || true
_test_eq "timeout beats log text" "deploy_timeout" "$HINT_ID"
_test_contains "other matches kept" "port_in_use" "${_HINT_ALL_IDS[*]}"

# ────────────────────────────────────────
echo ""
echo "  Rules engine — enrichment and fix commands"
# ────────────────────────────────────────

_mock_cmd docker 'if [[ "$1" == "ps" && "$*" == *"publish=8080"* ]]; then echo old-api; fi; exit 0'
hints_match_file "$FIX/port_in_use__docker.log" 1 api
_test_contains "port owner (container) named" "container 'old-api'" "$HINT_TITLE"
_test_eq "port fix stops the container" "docker stop old-api" "$HINT_FIX_CMD"

_mock_cmd docker 'exit 0'
_mock_cmd lsof 'if [[ "$*" == *"TCP:3000"* ]]; then echo 4242; exit 0; fi; exit 1'
hints_match_file "$FIX/port_in_use__node.log" 1 web
_test_contains "port owner (process) has PID" "PID 4242" "$HINT_TITLE"
_test_eq "port fix kills the PID" "kill 4242" "$HINT_FIX_CMD"
_mock_cmd lsof 'exit 1'

hints_match_file "$FIX/ssh_host_key__changed.log" 255 api
_test_eq "host key mismatch never offers an auto-fix" "" "$HINT_FIX_CMD"
_test_contains "host key explains the risk" "intercepting" "$HINT_TITLE"
_test_contains "host key names the host" "prod.example.com" "$HINT_TRY"

hints_match_file "$FIX/env_missing__compose.log" 1 api
_test_contains "missing env var named" "DATABASE_URL" "$HINT_TITLE"
hints_match_file "$FIX/env_missing__unbound.log" 1 api
_test_contains "unbound var named" "API_KEY" "$HINT_TITLE"

hints_match_file "$FIX/command_not_found__helm.log" 127 api
_test_contains "missing tool named" "'helm'" "$HINT_TITLE"

hints_match_file "$FIX/hook_not_executable__perm.log" 126 worker
_test_eq "non-executable hook → chmod fix" "chmod +x /proj/.muster/hooks/worker/deploy.sh" "$HINT_FIX_CMD"

# deploy_order fix when the DB deploys after the app
PROJ="$TEST_TMP/proj"
mkdir -p "$PROJ/.muster/hooks/api" "$PROJ/.muster/hooks/postgres" "$PROJ/.muster/logs" "$PROJ/.muster/pids"
cat > "$PROJ/muster.json" <<'JSON'
{"project":"demo","services":{
  "api":{"name":"API","health":{"type":"http","port":3000,"endpoint":"/health"}},
  "postgres":{"name":"Postgres","health":{"type":"tcp","port":5432}}},
 "deploy_order":["api","postgres"]}
JSON
CONFIG_FILE="$PROJ/muster.json"
hints_match_file "$FIX/conn_refused_dep__pg.log" 1 api
_test_contains "dependency ordering explained" "postgres deploys after api" "$HINT_TITLE"
_test_eq "fix reorders deploy_order" "_hints_fix_order_before postgres api" "$HINT_FIX_CMD"
(cd "$PROJ" && hints_run_fix --yes >/dev/null)
_test_eq "fix applied to muster.json" "postgres,api" "$(jq -r '.deploy_order | join(",")' "$PROJ/muster.json")"

hints_match_text "x" 124 api || true
_test_eq "timeout fix doubles deploy_timeout" "_hints_fix_timeout api 240" "$HINT_FIX_CMD"
(cd "$PROJ" && hints_run_fix --yes >/dev/null)
_test_eq "deploy_timeout written" "240" "$(jq -r '.services.api.deploy_timeout' "$PROJ/muster.json")"

# Health: wrong port (the service's PID listens elsewhere)
sleep 300 &
_fake_pid=$!
echo "$_fake_pid" > "$PROJ/.muster/pids/api.pid"
_mock_cmd lsof 'if [[ "$*" == *"-p '"$_fake_pid"'"* ]]; then printf "COMMAND PID USER FD TYPE DEVICE SIZE NODE NAME\nnode '"$_fake_pid"' me 20u IPv6 0x0 0t0 TCP *:3001 (LISTEN)\n"; exit 0; fi; exit 1'
hints_health api || true
_test_eq "health on wrong port → health_wrong_port" "health_wrong_port" "$HINT_ID"
_test_contains "suggests the listening port" "port 3001" "$HINT_TITLE"
_test_eq "health port fix" "_hints_fix_health_port api 3001" "$HINT_FIX_CMD"
kill "$_fake_pid" 2>/dev/null || true
wait "$_fake_pid" 2>/dev/null || true
rm -f "$PROJ/.muster/pids/api.pid"
_mock_cmd lsof 'exit 1'
hints_health api || true
_test_eq "health with nothing listening → health_refused" "health_refused" "$HINT_ID"
CONFIG_FILE=""

# Every rule documented
_missing_docs=""
while IFS='|' read -r _id _t _try; do
  grep -q "^### \`${_id}\`" "$MUSTER_ROOT/docs/troubleshooting.md" 2>/dev/null || _missing_docs="${_missing_docs} ${_id}"
done < <(hints_list_rules)
_test_eq "every rule has a section in docs/troubleshooting.md" "" "${_missing_docs# }"

# ────────────────────────────────────────
echo ""
echo "  muster explain — human and --json"
# ────────────────────────────────────────

cp "$FIX/port_in_use__docker.log" "$PROJ/.muster/logs/api-deploy-20260101-120000.log"
printf '%s|api|deploy|1|%s|port_in_use\n' "$(date +%s)" "$PROJ/.muster/logs/api-deploy-20260101-120000.log" > "$PROJ/.muster/logs/.last_failure"

_out=$(cd "$PROJ" && "$MUSTER_BIN" explain </dev/null 2>&1) || true
_test_contains "explain shows Likely cause" "Likely cause:" "$_out"
_test_contains "explain shows Try" "Try:" "$_out"
_test_contains "explain names the service" "api" "$_out"

_json=$(cd "$PROJ" && "$MUSTER_BIN" explain --json </dev/null 2>/dev/null)
_test_eq "explain --json is valid JSON" "ok" "$(jq -e . <<< "$_json" >/dev/null 2>&1 && echo ok)"
_test_eq "--json service" "api" "$(jq -r .service <<< "$_json")"
_test_eq "--json matched" "true" "$(jq -r .matched <<< "$_json")"
_test_eq "--json hint id" "port_in_use" "$(jq -r .hint.id <<< "$_json")"
_test_eq "--json exit_code" "1" "$(jq -r .exit_code <<< "$_json")"
_test_eq "--json has docs link" "true" "$(jq '.hint.docs | test("troubleshooting#port-in-use")' <<< "$_json")"
_test_eq "--json hints is an array" "true" "$(jq '.hints | type == "array" and length >= 1' <<< "$_json")"

_json=$("$MUSTER_BIN" explain --log "$FIX/registry_rate_limit__hub.log" --json </dev/null 2>/dev/null)
_test_eq "explain --log works outside a project" "registry_rate_limit" "$(jq -r .hint.id <<< "$_json")"

_json=$("$MUSTER_BIN" explain --log "$FIX/normal__k8s.log" --json </dev/null 2>/dev/null)
_test_eq "--json unmatched log" "false" "$(jq -r .matched <<< "$_json")"
_test_eq "--json unmatched hint is null" "null" "$(jq -r .hint <<< "$_json")"

_out=$(cd "$PROJ" && "$MUSTER_BIN" explain apii </dev/null 2>&1) || true
_test_contains "explain suggests a close service name" "Did you mean: api?" "$_out"

rm -f "${PROJ:?}/.muster/logs/"*.log "${PROJ:?}/.muster/logs/.last_failure"
_out=$(cd "$PROJ" && "$MUSTER_BIN" explain </dev/null 2>&1)
_test_contains "explain with nothing to explain is friendly" "Nothing to explain yet" "$_out"

_out=$(cd "$PROJ" && "$MUSTER_BIN" explain --log "$FIX/disk_full__build.log" --fix </dev/null 2>&1) || true
_test_not_contains "fix never runs without a TTY or --yes" "Fix applied" "$_out"

_test_summary
