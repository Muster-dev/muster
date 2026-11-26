#!/usr/bin/env bash
# tests/test_group_remote.sh — Tests for remote project-dir auto-detection & SSH group status auth
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

TMPDIR=$(mktemp -d)
export HOME="${TMPDIR}/home"
mkdir -p "$HOME"
trap 'rm -rf "$TMPDIR"' EXIT

export NO_COLOR=1
export MUSTER_NO_VERIFY=true
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

source "$MUSTER_ROOT/lib/core/colors.sh"
source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"
source "$MUSTER_ROOT/lib/core/fleet.sh"
source "$MUSTER_ROOT/lib/commands/group.sh"

# ────────────────────────────────────────
echo "  Remote project-dir auto-detection"
# ────────────────────────────────────────

_tab=$'\t'

# 1. Exact unique .project match among multiple remote projects (both muster.json and deploy.json)
_cands="/home/deploy/other${_tab}otherapp${_tab}deploy.json
/home/deploy/target${_tab}myapp${_tab}muster.json
/home/deploy/legacy${_tab}legacyapp${_tab}deploy.json"

_rc=0
_group_select_remote_project_dir "myapp" "$_cands" "deploy@host1" </dev/null || _rc=$?
_test_eq "unique .project match returns 0" "0" "$_rc"
_test_eq "selects matching project dir, not first" "/home/deploy/target" "$_GROUP_DETECTED_DIR"

# 2. Deduplicates directory having both deploy.json and muster.json (prefers muster.json)
_cands_dup="/home/deploy/app${_tab}oldname${_tab}deploy.json
/home/deploy/app${_tab}myapp${_tab}muster.json"
_rc=0
_group_select_remote_project_dir "myapp" "$_cands_dup" "deploy@host1" </dev/null || _rc=$?
_test_eq "muster.json wins over deploy.json in same dir" "0" "$_rc"
_test_eq "deduplicated dir selected" "/home/deploy/app" "$_GROUP_DETECTED_DIR"

# 3. Multiple matches on non-TTY -> fail and list candidates
_cands_multi="/home/deploy/app1${_tab}myapp${_tab}muster.json
/home/deploy/app2${_tab}myapp${_tab}deploy.json"
_rc=0
_group_select_remote_project_dir "myapp" "$_cands_multi" "deploy@host1" </dev/null || _rc=$?
_test_eq "multiple matching dirs fail non-interactively" "1" "$_rc"
_test_contains "error lists first candidate" "/home/deploy/app1" "$_GROUP_DETECT_ERR"
_test_contains "error lists second candidate" "/home/deploy/app2" "$_GROUP_DETECT_ERR"

# 4. Zero matches on non-TTY -> fail and list candidates instead of guessing
_cands_none="/home/deploy/a${_tab}alpha${_tab}muster.json
/home/deploy/b${_tab}beta${_tab}deploy.json"
_rc=0
_group_select_remote_project_dir "myapp" "$_cands_none" "deploy@host1" </dev/null || _rc=$?
_test_eq "no matching project fails non-interactively" "1" "$_rc"
_test_contains "error names missing local project" "myapp" "$_GROUP_DETECT_ERR"
_test_contains "error lists alpha candidate" "/home/deploy/a (alpha)" "$_GROUP_DETECT_ERR"
_test_contains "error lists beta candidate" "/home/deploy/b (beta)" "$_GROUP_DETECT_ERR"

# 5. Empty local project with multiple candidates -> fail on non-TTY instead of guessing
_rc=0
_group_select_remote_project_dir "" "$_cands_none" "deploy@host1" </dev/null || _rc=$?
_test_eq "empty local_project with multiple candidates fails non-TTY" "1" "$_rc"
_test_contains "lists candidates when ambiguous" "/home/deploy/b (beta)" "$_GROUP_DETECT_ERR"

# 6. Empty local project with single candidate -> succeeds
_cands_one="/home/deploy/only${_tab}onlyapp${_tab}muster.json"
_rc=0
_group_select_remote_project_dir "" "$_cands_one" "deploy@host1" </dev/null || _rc=$?
_test_eq "empty local_project with single candidate succeeds" "0" "$_rc"
_test_eq "single candidate selected" "/home/deploy/only" "$_GROUP_DETECTED_DIR"

# ────────────────────────────────────────
echo ""
echo "  SSH group status & picker — MUSTER_TOKEN + minimal fallback"
# ────────────────────────────────────────

# Set up fake ssh to inspect commands and simulate auth gate
FAKE_BIN="${TMPDIR}/fake_bin"
mkdir -p "$FAKE_BIN"
SSH_LOG="${TMPDIR}/ssh.log"
cat > "${FAKE_BIN}/ssh" << 'FAKE_SSH'
#!/usr/bin/env bash
args=("$@")
cmd="${args[$((${#args[@]} - 1))]}"
printf '%s\n' "$cmd" >> "$FAKE_SSH_LOG"
if [[ "$cmd" == *"status --json"* ]]; then
  if [[ "$cmd" == *"MUSTER_TOKEN=valid-tok"* ]]; then
    printf '{"project":"demo","services":{"api":{"name":"API","status":"healthy"},"redis":{"name":"Redis","status":"healthy"}}}\n'
    exit 0
  else
    printf '{"error":"auth_required","message":"MUSTER_TOKEN not set"}\n' >&2
    exit 1
  fi
elif [[ "$cmd" == *"muster --minimal"* ]]; then
  printf 'muster: demo\n  API: healthy\n  Worker: unhealthy\nmuster: 2 services (1 healthy, 1 unhealthy, 0 disabled)\n'
  exit 0
elif [[ "$cmd" == *"muster.json"* ]]; then
  printf 'api\nworker\n'
  exit 0
elif [[ "$cmd" == *"echo ok"* ]]; then
  echo ok
  exit 0
fi
exit 0
FAKE_SSH
chmod +x "${FAKE_BIN}/ssh"

export PATH="${FAKE_BIN}:$PATH"
export FAKE_SSH_LOG="$SSH_LOG"

groups_create "ops" "Ops" >/dev/null 2>&1
groups_add_remote "ops" "10.0.5.10" "deploy" "22" "" "/opt/demo" "false" "key" "" "manual" >/dev/null 2>&1

# Store a fleet token matching deploy@10.0.5.10:22
mkdir -p "$HOME/.muster/tokens"
jq -n '{tokens: {"deploy@10.0.5.10:22": "valid-tok"}}' > "$HOME/.muster/tokens/fleet.json"
chmod 600 "$HOME/.muster/tokens/fleet.json"

: > "$SSH_LOG"
_groups_load_remote "ops" 0 || true
_json=$(_group_ssh_status_json "ops" 0)
_test_contains "paired SSH status passes MUSTER_TOKEN" "MUSTER_TOKEN=valid-tok" "$(cat "$SSH_LOG")"
_test_eq "paired SSH status parses 2 services" "2" "$(printf '%s' "$_json" | jq '.services | length')"
_test_eq "paired SSH status reports api healthy" "healthy" "$(printf '%s' "$_json" | jq -r '.services.api.status')"

: > "$SSH_LOG"
_keys=$(_group_ssh_picker_services "ops" 0)
_test_contains "paired SSH picker passes MUSTER_TOKEN" "MUSTER_TOKEN=valid-tok" "$(cat "$SSH_LOG")"
_test_contains "paired SSH picker returns api key" "api" "$_keys"
_test_contains "paired SSH picker returns redis key" "redis" "$_keys"

# Remove fleet token -> unpaired fallback must still work cleanly
rm -f "$HOME/.muster/tokens/fleet.json"

: > "$SSH_LOG"
_groups_load_remote "ops" 0 || true
_json2=$(_group_ssh_status_json "ops" 0)
_test_contains "unpaired SSH status falls back to muster --minimal" "muster --minimal" "$(cat "$SSH_LOG")"
_test_eq "unpaired SSH status parses API healthy" "healthy" "$(printf '%s' "$_json2" | jq -r '.services.API.status')"
_test_eq "unpaired SSH status parses Worker unhealthy" "unhealthy" "$(printf '%s' "$_json2" | jq -r '.services.Worker.status')"

: > "$SSH_LOG"
_keys2=$(_group_ssh_picker_services "ops" 0)
_test_contains "unpaired SSH picker returns api" "api" "$_keys2"
_test_contains "unpaired SSH picker returns worker" "worker" "$_keys2"

_test_summary
