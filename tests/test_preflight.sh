#!/usr/bin/env bash
# tests/test_preflight.sh — pre-deploy checks (lib/core/preflight.sh) in TTY
# and non-TTY mode. docker, kubectl, lsof and ssh are fakes on PATH.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUSTER_BIN="$MUSTER_ROOT/bin/muster"

source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/mock_helpers.sh"

TEST_TMP=$(mktemp -d)
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"
export MUSTER_NO_VERIFY=true MUSTER_PREFLIGHT_TTL=0
unset NO_COLOR MUSTER_APPROVE_HOOKS
_mock_init
trap 'rm -rf "${TEST_TMP:?}"; _mock_cleanup' EXIT

# Args: dir service-json hook-body
_mk() {
  local d="$1" svc_json="$2" body="$3"
  mkdir -p "$d/.muster/hooks/web"
  printf '{"project":"shop","services":{"web":%s},"deploy_order":["web"]}\n' "$svc_json" > "$d/muster.json"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$d/.muster/hooks/web/deploy.sh"
  chmod +x "$d/.muster/hooks/web/deploy.sh"
}

_run() {
  local d="$1"; shift
  RC=0
  OUT=$(cd "$d" && "$MUSTER_BIN" "$@" </dev/null 2>&1) || RC=$?
}

# ────────────────────────────────────────
echo "  Preflight — non-TTY"
# ────────────────────────────────────────

P="$TEST_TMP/bare"
_mk "$P" '{"name":"Web","health":{"type":"tcp","port":3000}}' 'echo "web started"'

_run "$P" deploy --yes
_test_eq "clean preflight deploys" "0" "$RC"

# A foreign process holds the service's port
_mock_cmd lsof 'if [[ "$*" == *"TCP:3000"* ]]; then echo 99999; exit 0; fi; exit 1'
_logs_before=$(ls "$P"/.muster/logs/web-deploy-*.log 2>/dev/null | wc -l | tr -d ' ')
_run "$P" deploy --yes
_logs_after=$(ls "$P"/.muster/logs/web-deploy-*.log 2>/dev/null | wc -l | tr -d ' ')
_test_eq "port conflict blocks (exit 1)" "1" "$RC"
_test_contains "port conflict explained in one line" "port 3000 is taken" "$OUT"
_test_contains "blocking message names --no-preflight" "--no-preflight" "$OUT"
_test_eq "hook never ran" "$_logs_before" "$_logs_after"

_run "$P" deploy --yes --no-preflight
_test_eq "--no-preflight skips the checks" "0" "$RC"

_run "$P" --minimal deploy --yes
_test_eq "--minimal still blocks" "1" "$RC"
_test_contains "--minimal prints # error: lines" "# error: web: port 3000 is taken" "$OUT"
_mock_cmd lsof 'exit 1'

# Our own previous instance on the port is fine (dev/bare restart)
sleep 300 &
_own=$!
mkdir -p "$P/.muster/pids"
echo "$_own" > "$P/.muster/pids/web.pid"
_mock_cmd lsof 'if [[ "$*" == *"TCP:3000"* ]]; then echo '"$_own"'; exit 0; fi; exit 1'
_run "$P" deploy --yes
_test_eq "port held by our own PID doesn't block" "0" "$RC"
kill "$_own" 2>/dev/null || true; wait "$_own" 2>/dev/null || true
rm -f "$P/.muster/pids/web.pid"
_mock_cmd lsof 'exit 1'

# Unset env var referenced by the hook: warning only
_mk "$P" '{"name":"Web","health":{"enabled":false}}' 'echo "token=${API_TOKEN}"; IMAGE_TAG="${IMAGE_TAG:-latest}"; LOCAL=1; echo $LOCAL'
_run "$P" deploy --yes
_test_eq "unset env var is a warning, not a block" "0" "$RC"
_test_contains "warns about the unset variable" 'uses $API_TOKEN' "$OUT"
_test_not_contains "vars with defaults aren't flagged" 'IMAGE_TAG' "$OUT"
_test_not_contains "vars assigned in the hook aren't flagged" '$LOCAL' "$OUT"
printf 'API_TOKEN=abc\n' > "$P/.env"
_run "$P" deploy --yes
_test_not_contains ".env satisfies the variable" 'API_TOKEN' "$OUT"
rm -f "$P/.env"

# Required (${VAR:?}) unset variable blocks
_mk "$P" '{"name":"Web","health":{"enabled":false}}' ': "${DB_URL:?DB_URL is required}"'
_run "$P" deploy --yes
_test_eq "required env var blocks" "1" "$RC"
_test_contains "required var named" 'requires $DB_URL' "$OUT"

# Non-executable hook
_mk "$P" '{"name":"Web","health":{"enabled":false}}' 'echo hi'
chmod -x "$P/.muster/hooks/web/deploy.sh"
_run "$P" deploy --yes
_test_eq "non-executable hook blocks" "1" "$RC"
_test_contains "suggests chmod" "chmod +x .muster/hooks/web/deploy.sh" "$OUT"
chmod +x "$P/.muster/hooks/web/deploy.sh"

# Docker daemon down
D="$TEST_TMP/docker"
_mk "$D" '{"name":"Web","health":{"enabled":false}}' 'docker build -t web . && docker run -d web'
_mock_cmd docker 'if [[ "$1" == "info" ]]; then echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1; fi; exit 0'
_run "$D" deploy --yes
_test_eq "docker daemon down blocks" "1" "$RC"
_test_contains "explains docker isn't running" "Docker is installed but not running" "$OUT"

_mock_cmd docker 'if [[ "$1" == "info" ]]; then echo "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2; exit 1; fi; exit 0'
_run "$D" deploy --yes
_test_contains "docker socket permission explained" "permission to use Docker" "$OUT"
_mock_cmd docker 'exit 0'

# Docker missing entirely
_saved_path="$PATH"
_mock_missing docker
_run "$D" deploy --yes
_test_eq "missing docker blocks" "1" "$RC"
_test_contains "explains docker isn't installed" "Docker isn't installed" "$OUT"
export PATH="$_saved_path"
_mock_cmd docker 'exit 0'

# Kubernetes: namespace missing, prod-looking context
K="$TEST_TMP/k8s"
_mk "$K" '{"name":"Web","health":{"enabled":false},"k8s":{"deployment":"web","namespace":"shop"}}' 'kubectl rollout restart deployment/web -n shop'
_mock_cmd kubectl 'case "$1 $2" in
  "config current-context") echo "dev-cluster" ;;
  "get namespace") echo "Error from server (NotFound): namespaces \"shop\" not found" >&2; exit 1 ;;
esac; exit 0'
_run "$K" deploy --yes
_test_eq "missing namespace blocks" "1" "$RC"
_test_contains "offers to create the namespace" "kubectl create namespace shop" "$OUT"

_mock_cmd kubectl 'case "$1 $2" in "config current-context") echo "prod-eu-1" ;; esac; exit 0'
_run "$K" deploy --yes
_test_eq "prod-looking context only warns" "0" "$RC"
_test_contains "warns about a prod context" "looks like production" "$OUT"

_mock_cmd kubectl 'case "$1 $2" in "config current-context") echo "" ;; esac; exit 0'
_run "$K" deploy --yes
_test_contains "no kube context explained" "no current context" "$OUT"
_mock_cmd kubectl 'case "$1 $2" in "config current-context") echo "dev-cluster" ;; esac; exit 0'

# Remote SSH unreachable
R="$TEST_TMP/remote"
_mk "$R" '{"name":"Web","health":{"enabled":false},"remote":{"enabled":true,"host":"10.9.9.9","user":"deploy","port":22}}' 'echo remote'
_mock_cmd ssh 'echo "ssh: connect to host 10.9.9.9 port 22: Operation timed out" >&2; exit 255'
_run "$R" deploy --yes
_test_eq "unreachable SSH host blocks" "1" "$RC"
_test_contains "ssh failure explained" "SSH to deploy@10.9.9.9 failed" "$OUT"
_mock_cmd ssh 'echo "Host key verification failed." >&2; exit 255'
_run "$R" deploy --yes
_test_contains "host key problem explained" "host key" "$OUT"
_mock_cmd ssh 'exit 0'

# Deploy failure: "Likely cause / Try" printed and the failure recorded
_mk "$P" '{"name":"Web","health":{"enabled":false}}' 'echo "Error: listen EADDRINUSE: address already in use :::3000"; exit 1'
_run "$P" deploy --yes
_test_eq "failing hook exits 1" "1" "$RC"
_test_contains "failure shows Likely cause" "Likely cause: Port 3000 is already in use" "$OUT"
_test_contains "failure shows Try" "Try:" "$OUT"
_test_file_exists "failure recorded for muster explain --last" "$P/.muster/logs/.last_failure"
_test_contains "recorded rule id" "port_in_use" "$(cat "$P/.muster/logs/.last_failure")"

_mk "$P" '{"name":"Web","health":{"enabled":false},"deploy_timeout":1}' 'sleep 5'
_run "$P" deploy --yes
_test_contains "timeout explains deploy_timeout" "1s deploy_timeout" "$OUT"

# Cache: a clean result is reused within the TTL
_mk "$P" '{"name":"Web","health":{"enabled":false}}' 'echo hi'
(cd "$P" && MUSTER_PREFLIGHT_TTL=60 "$MUSTER_BIN" deploy --yes </dev/null >/dev/null 2>&1) || true
_test_file_exists "clean preflight is cached briefly" "$P/.muster/.preflight_ok"

# ────────────────────────────────────────
echo ""
echo "  Preflight — TTY (Fix it / Continue anyway / Abort)"
# ────────────────────────────────────────

if command -v python3 >/dev/null 2>&1; then
  _mk "$P" '{"name":"Web","health":{"type":"tcp","port":3000}}' 'echo "web started"'
  _mock_cmd lsof 'if [[ "$*" == *"TCP:3000"* ]]; then echo 99999; exit 0; fi; exit 1'

  _rc=0
  _out=$(python3 "$SCRIPT_DIR/pty_drive.py" "$P" 20 "Choose [1-3]:=>3\n" "kill=>any key to continue" -- "$MUSTER_BIN" --minimal deploy --yes 2>&1) || _rc=$?
  _test_contains "TTY offers Fix it" "Fix it: Stop" "$_out"
  _test_contains "TTY offers Continue anyway" "Continue anyway" "$_out"
  _test_contains "Abort stops before any hook" "Deploy aborted before any hook ran" "$_out"

  _out=$(python3 "$SCRIPT_DIR/pty_drive.py" "$P" 20 "Choose [1-3]:=>2\n" "kill=>any key to continue" -- "$MUSTER_BIN" --minimal deploy --yes 2>&1) || true
  _test_contains "Continue anyway runs the deploy" "deployed" "$_out"

  # Fix it: the fix (kill PID) runs, then preflight re-checks
  sleep 300 &
  _victim=$!
  _mock_cmd lsof 'if [[ "$*" == *"TCP:3000"* ]] && kill -0 '"$_victim"' 2>/dev/null; then echo '"$_victim"'; exit 0; fi; exit 1'
  _out=$(python3 "$SCRIPT_DIR/pty_drive.py" "$P" 20 "Choose [1-3]:=>1\n" "kill=>any key to continue" -- "$MUSTER_BIN" --minimal deploy --yes 2>&1) || true
  _test_contains "Fix it runs the fix" "Fix applied" "$_out"
  _test_contains "re-check passes after the fix" "Preflight checks pass" "$_out"
  _alive=yes; kill -0 "$_victim" 2>/dev/null || _alive=no
  _test_eq "port owner was stopped" "no" "$_alive"
  wait "$_victim" 2>/dev/null || true
  _mock_cmd lsof 'exit 1'
else
  echo "  (python3 not available — skipping TTY tests)"
fi

_test_summary
