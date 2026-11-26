#!/usr/bin/env bash
# tests/test_fleet_rollback.sh — Tests for SSH muster-mode explicit service rollback & --parallel
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
export MUSTER_QUIET="false"
export MUSTER_VERBOSE="false"

# Set up a project with 3 services (1 has skip_deploy: true)
PROJ="${TMPDIR}/proj"
mkdir -p "${PROJ}/.muster/logs"
cat > "${PROJ}/muster.json" << 'EOF'
{
  "project": "rbapp",
  "version": "1",
  "services": {
    "redis": { "name": "Redis", "skip_deploy": false },
    "api":   { "name": "API",   "skip_deploy": false },
    "docs":  { "name": "Docs",  "skip_deploy": true }
  },
  "deploy_order": ["redis", "api", "docs"]
}
EOF

# Fake ssh binary that records every command sent to each host (and optionally sleeps)
LOG_DIR="${TMPDIR}/ssh_calls"
mkdir -p "$LOG_DIR"
FAKE_BIN="${TMPDIR}/fake_bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/ssh" << 'FAKE_SSH'
#!/usr/bin/env bash
# Last two args are user@host and cmd
args=("$@")
n=${#args[@]}
target="${args[$((n - 2))]}"
cmd="${args[$((n - 1))]}"
if [[ -n "${FAKE_SSH_SLEEP:-}" ]]; then
  sleep "$FAKE_SSH_SLEEP"
fi
printf '%s|%s\n' "$target" "$cmd" >> "$FAKE_SSH_LOG"
exit 0
FAKE_SSH
chmod +x "${FAKE_BIN}/ssh"

export PATH="${FAKE_BIN}:$PATH"
export FAKE_SSH_LOG="${LOG_DIR}/calls.log"

source "$MUSTER_ROOT/lib/core/colors.sh"
source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"
source "$MUSTER_ROOT/lib/core/registry.sh"
source "$MUSTER_ROOT/lib/core/fleet.sh"
source "$MUSTER_ROOT/lib/commands/fleet.sh"

# Initialize fleet with 3 SSH muster-mode machines + tokens
fleet_init >/dev/null 2>&1
fleet_add_machine "m1" "host1" "deploy" "22" "" "/opt/rbapp" "muster" "ssh" "manual" >/dev/null 2>&1
fleet_add_machine "m2" "host2" "deploy" "22" "" "/opt/rbapp" "muster" "ssh" "manual" >/dev/null 2>&1
fleet_add_machine "m3" "host3" "deploy" "22" "" "/opt/rbapp" "muster" "ssh" "manual" >/dev/null 2>&1
fleet_token_set "m1" "tok-1"
fleet_token_set "m2" "tok-2"
fleet_token_set "m3" "tok-3"
fleet_load_config

# ────────────────────────────────────────
echo "  SSH muster-mode rollback — explicit services"
# ────────────────────────────────────────

: > "$FAKE_SSH_LOG"
(cd "$PROJ" && _fleet_cmd_rollback m1 >/dev/null 2>&1)
_calls=$(cat "$FAKE_SSH_LOG")

_test_contains "SSH rollback passes redis explicitly" "muster rollback redis" "$_calls"
_test_contains "SSH rollback passes api explicitly" "muster rollback api" "$_calls"
_test_not_contains "SSH rollback skips skip_deploy service" "muster rollback docs" "$_calls"
_test_contains "SSH rollback includes MUSTER_TOKEN" "MUSTER_TOKEN=tok-1" "$_calls"
_test_contains "SSH rollback cd's into project dir" "cd /opt/rbapp &&" "$_calls"

# ────────────────────────────────────────
echo ""
echo "  SSH muster-mode rollback — --service filter"
# ────────────────────────────────────────

: > "$FAKE_SSH_LOG"
(cd "$PROJ" && _fleet_cmd_rollback m1 --service api >/dev/null 2>&1)
_calls=$(cat "$FAKE_SSH_LOG")

_test_contains "--service api rolls back api" "muster rollback api" "$_calls"
_test_not_contains "--service api does not roll back redis" "muster rollback redis" "$_calls"

# ────────────────────────────────────────
echo ""
echo "  Fleet rollback — --parallel executes concurrently"
# ────────────────────────────────────────

# 3 machines, each sleeping 2s in fake ssh:
# Sequential would take >= 6s; parallel should finish in ~2s (< 5s).
: > "$FAKE_SSH_LOG"
_t0=$(date +%s)
(cd "$PROJ" && FAKE_SSH_SLEEP=2 _fleet_cmd_rollback --service api --parallel >/dev/null 2>&1)
_rc=$?
_t1=$(date +%s)
_elapsed=$(( _t1 - _t0 ))
_calls=$(cat "$FAKE_SSH_LOG")

_test_eq "parallel rollback exits 0" "0" "$_rc"
_test_contains "parallel rollback ran on m1" "deploy@host1|" "$_calls"
_test_contains "parallel rollback ran on m2" "deploy@host2|" "$_calls"
_test_contains "parallel rollback ran on m3" "deploy@host3|" "$_calls"
_test "parallel rollback finished faster than sequential (${_elapsed}s < 5s)" test "$_elapsed" -lt 5

_test_summary
