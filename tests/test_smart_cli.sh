#!/usr/bin/env bash
# tests/test_smart_cli.sh — did-you-mean, the dashboard "Next step" logic,
# remembered picker choices, empty/non-TTY menus, narrow terminals.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUSTER_BIN="$MUSTER_ROOT/bin/muster"

source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/mock_helpers.sh"

TEST_TMP=$(mktemp -d)
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"
export MUSTER_NO_VERIFY=true
unset NO_COLOR
_mock_init
trap 'rm -rf "${TEST_TMP:?}"; _mock_cleanup' EXIT

# shellcheck disable=SC2034
GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE="" GRAY=""
MUSTER_QUIET="false"
MUSTER_MINIMAL="false"
source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"
source "$MUSTER_ROOT/lib/core/suggest.sh"
source "$MUSTER_ROOT/lib/core/nextstep.sh"

# ────────────────────────────────────────
echo "  Did you mean"
# ────────────────────────────────────────

_cmds=$(_suggest_commands | tr '\n' ' ')
_test_contains "commands come from the router" " deploy " " ${_cmds} "
_test_contains "explain is a known command" " explain " " ${_cmds} "
# shellcheck disable=SC2086
_test_eq "deplyo → deploy" "deploy" "$(_suggest_closest deplyo $_cmds)"
# shellcheck disable=SC2086
_test_eq "stauts → status" "status" "$(_suggest_closest stauts $_cmds)"
# shellcheck disable=SC2086
_test_eq "rollbak → rollback" "rollback" "$(_suggest_closest rollbak $_cmds)"
# shellcheck disable=SC2086
_test_eq "unique prefix 'doc' → doctor" "doctor" "$(_suggest_closest doc $_cmds)"
# shellcheck disable=SC2086
_test_eq "ambiguous prefix falls back to edit distance" "dev" "$(_suggest_closest de deploy dev)"
_test_eq "single letter → nothing" "" "$(_suggest_closest x deploy dev)"
# shellcheck disable=SC2086
_test_eq "nonsense → nothing" "" "$(_suggest_closest zzzzqq $_cmds)"
_test_eq "flags: --dryrun → --dry-run" "--dry-run" "$(_suggest_closest --dryrun --dry-run --force --json --yes)"
_test_eq "services: wrker → worker" "worker" "$(_suggest_closest wrkr api worker redis)"
_test_eq "distance(kitten, sitting) = 3" "3" "$(_suggest_distance kitten sitting)"

_out=$("$MUSTER_BIN" deplyo </dev/null 2>&1) || true
_test_contains "mistyped command suggests" "Did you mean: deploy?" "$_out"

PROJ="$TEST_TMP/proj"
mkdir -p "$PROJ/.muster/hooks/api" "$PROJ/.muster/hooks/worker"
cat > "$PROJ/muster.json" <<'JSON'
{"project":"demo","services":{"api":{"name":"API","health":{"enabled":false}},"worker":{"name":"Worker","health":{"enabled":false}}},"deploy_order":["api","worker"]}
JSON
printf '#!/usr/bin/env bash\necho ok\n' > "$PROJ/.muster/hooks/api/deploy.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$PROJ/.muster/hooks/worker/deploy.sh"
chmod +x "$PROJ"/.muster/hooks/*/deploy.sh

_out=$(cd "$PROJ" && "$MUSTER_BIN" deploy wroker </dev/null 2>&1) || true
_test_contains "mistyped service suggests" "Did you mean: worker?" "$_out"
_out=$(cd "$PROJ" && "$MUSTER_BIN" deploy --dryrun </dev/null 2>&1) || true
_test_contains "mistyped flag suggests" "Did you mean: --dry-run?" "$_out"

# ────────────────────────────────────────
echo ""
echo "  Next step"
# ────────────────────────────────────────

CONFIG_FILE="$PROJ/muster.json"
mkdir -p "$PROJ/.muster/logs"
EV="$PROJ/.muster/logs/deploy-events.log"

_next_step "$PROJ"
_test_eq "never deployed → first_deploy" "first_deploy" "$NEXT_STEP_KIND"
_test_eq "never deployed → Enter deploys" "Deploy" "$NEXT_STEP_ACTION"
_test_contains "never deployed text" "No deploys yet" "$NEXT_STEP_TEXT"

printf '{"ts":"%s","service":"api","action":"deploy","status":"ok","commit":""}\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$EV"
_next_step "$PROJ"
_test_eq "deployed and healthy → ok" "ok" "$NEXT_STEP_KIND"
_test_eq "ok has no text" "" "$NEXT_STEP_TEXT"

MUSTER_UPDATE_AVAILABLE=true _MUSTER_LATEST_TAG="v9.9.9"
_next_step "$PROJ"
_test_eq "update available → update" "update" "$NEXT_STEP_KIND"
_test_contains "update text names the version" "v9.9.9" "$NEXT_STEP_TEXT"
MUSTER_UPDATE_AVAILABLE=false

# A failure newer than the last good deploy
printf '%s|api|deploy|1|%s|port_in_use\n' "$(( $(date +%s) + 5 ))" "/nope.log" > "$PROJ/.muster/logs/.last_failure"
_next_step "$PROJ"
_test_eq "recent failure → failure" "failure" "$NEXT_STEP_KIND"
_test_eq "failure → Enter explains" "Explain last failure" "$NEXT_STEP_ACTION"
_test_contains "failure text names the service" "api failed" "$NEXT_STEP_TEXT"

# ...fixed by a later successful deploy
printf '%s|api|deploy|1|%s|port_in_use\n' "$(( $(date +%s) - 120 ))" "/nope.log" > "$PROJ/.muster/logs/.last_failure"
_next_step "$PROJ"
_test_eq "failure fixed by a later deploy → not failure" "ok" "$NEXT_STEP_KIND"

# ...an old failure (over a day) is not nagged about
printf '%s|worker|deploy|1|%s|\n' "$(( $(date +%s) - 90000 ))" "/nope.log" > "$PROJ/.muster/logs/.last_failure"
_next_step "$PROJ"
_test_eq "day-old failure is ignored" "ok" "$NEXT_STEP_KIND"
rm -f "$PROJ/.muster/logs/.last_failure"

# Stale lock
printf '{"user":"sam","pid":999999,"started":"2026-01-01 00:00:00"}\n' > "$PROJ/.muster/deploy.lock"
_next_step "$PROJ"
_test_eq "stale lock → lock" "lock" "$NEXT_STEP_KIND"
_test_eq "stale lock → doctor --fix" "Doctor --fix" "$NEXT_STEP_ACTION"
rm -f "$PROJ/.muster/deploy.lock"

# Hooks needing approval (hook security loaded, nothing approved yet)
(
  source "$MUSTER_ROOT/lib/core/colors.sh"
  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  _next_step "$PROJ"
  printf '%s|%s|%s\n' "$NEXT_STEP_KIND" "$NEXT_STEP_ACTION" "$NEXT_STEP_TEXT"
) > "$TEST_TMP/ns.out" 2>/dev/null || true
_test_contains "unapproved hooks → approval" "approval|Approve hooks|" "$(cat "$TEST_TMP/ns.out")"
_test_contains "approval text counts hooks" "2 hooks need approval" "$(cat "$TEST_TMP/ns.out")"

# ────────────────────────────────────────
echo ""
echo "  Menus — remember, empty state, non-TTY"
# ────────────────────────────────────────

_out=$(bash -c 'MUSTER_ROOT="'"$MUSTER_ROOT"'"; source "$MUSTER_ROOT/lib/core/colors.sh"; source "$MUSTER_ROOT/lib/core/utils.sh"; source "$MUSTER_ROOT/lib/tui/menu.sh"; menu_select "Deploy which services?" a b' </dev/null 2>&1) || true
_test_contains "non-TTY menu names the prompt" '"Deploy which services?" needs an interactive terminal' "$_out"
_test_contains "non-TTY menu points at flags" "flags" "$_out"

if command -v python3 >/dev/null 2>&1; then
  cat > "$TEST_TMP/menu.sh" <<EOF
MUSTER_ROOT="$MUSTER_ROOT"
MUSTER_MINIMAL=true
source "\$MUSTER_ROOT/lib/core/colors.sh"
source "\$MUSTER_ROOT/lib/core/utils.sh"
source "\$MUSTER_ROOT/lib/tui/menu.sh"
CONFIG_FILE="$PROJ/muster.json"
MENU_REMEMBER=pick; menu_select "Pick one" alpha beta gamma; echo "R1=\$MENU_RESULT"
MENU_REMEMBER=pick; menu_select "Pick again" alpha beta gamma; echo "R2=\$MENU_RESULT"
menu_select "Nothing here"; echo "R3=\$MENU_RESULT"
EOF
  _out=$(python3 "$SCRIPT_DIR/pty_drive.py" "$TEST_TMP" 15 "Choose [1-3]:=>2\n" "Pick again=>" "Choose [1-3]:=>\n" -- bash "$TEST_TMP/menu.sh" 2>&1) || true
  _test_contains "first pick" "R1=beta" "$_out"
  _test_contains "Enter reuses the remembered pick" "R2=beta" "$_out"
  _test_contains "empty menu shows an empty state" "Nothing to choose from here yet" "$_out"
  _test_contains "empty menu returns back" "R3=__back__" "$_out"
  _test_file_exists "picks stored per project under .muster/" "$PROJ/.muster/.menu_state"
fi

# ────────────────────────────────────────
echo ""
echo "  Narrow terminals"
# ────────────────────────────────────────

_bar=$(bash -c 'MUSTER_ROOT="'"$MUSTER_ROOT"'"; source "$MUSTER_ROOT/lib/core/colors.sh"; source "$MUSTER_ROOT/lib/core/utils.sh"; BOLD=""; source "$MUSTER_ROOT/lib/tui/dashboard.sh"; TERM_COLS=40; _dashboard_bar "muster" "v0.6.2  macos arm64 and a long tail  "' 2>/dev/null)
_test "header fits in 40 columns" test "${#_bar}" -le 40

# ────────────────────────────────────────
echo ""
echo "  Doctor — Needs attention / Fine, rule fixes"
# ────────────────────────────────────────

D="$TEST_TMP/doc"
mkdir -p "$D/.muster/hooks/web" "$D/.muster/logs"
printf '{"project":"doc","services":{"web":{"name":"Web","health":{"type":"tcp","port":3000}}},"deploy_order":["web"]}\n' > "$D/muster.json"
printf '#!/usr/bin/env bash\necho "$API_TOKEN"\n' > "$D/.muster/hooks/web/deploy.sh"
printf '{"user":"sam","pid":999999,"started":"2026-01-01 00:00:00"}\n' > "$D/.muster/deploy.lock"
_mock_cmd lsof 'if [[ "$*" == *"TCP:3000"* ]]; then echo 99999; exit 0; fi; exit 1'

_out=$(cd "$D" && "$MUSTER_BIN" doctor </dev/null 2>&1) || true
_test_contains "doctor groups problems under Needs attention" "Needs attention" "$_out"
_test_contains "doctor summarizes passing checks under Fine" "Fine — " "$_out"
_test_contains "doctor reports the stale lock" "Stale deploy lock from sam" "$_out"
_test_contains "doctor reports the port conflict" "port 3000 is taken" "$_out"
_test_contains "doctor reports the unset env var" 'uses $API_TOKEN' "$_out"
_test_contains "doctor reports the non-executable hook" "not executable (--fix)" "$_out"

_out=$(cd "$D" && "$MUSTER_BIN" doctor --fix </dev/null 2>&1) || true
_test "doctor --fix removes the stale lock" test ! -f "$D/.muster/deploy.lock"
_test "doctor --fix makes hooks executable" test -x "$D/.muster/hooks/web/deploy.sh"
_test_contains "risky fixes are printed, not run, without a TTY" "run: kill 99999" "$_out"
_mock_cmd lsof 'exit 1'

_test_summary
