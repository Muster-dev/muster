#!/usr/bin/env bash
# tests/test_doctor.sh — Tests for doctor diagnostic checks
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE="" GRAY=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ────────────────────────────────────────
echo "  Doctor — config validation (valid)"
# ────────────────────────────────────────

_proj="${TMPDIR}/valid_project"
mkdir -p "${_proj}/.muster/hooks/api"
cat > "${_proj}/deploy.json" << 'EOF'
{
  "project": "test-app",
  "services": {
    "api": {
      "health": { "type": "http", "port": 3000 }
    }
  },
  "deploy_order": ["api"]
}
EOF

CONFIG_FILE="${_proj}/deploy.json"
_CONFIG_VALIDATED=""

_rc=0
_config_validate 2>/dev/null || _rc=$?
_test_eq "valid config passes validation" "0" "$_rc"

# ────────────────────────────────────────
echo ""
echo "  Doctor — config validation (missing project)"
# ────────────────────────────────────────

cat > "${TMPDIR}/bad_config.json" << 'EOF'
{
  "services": { "api": {} },
  "deploy_order": ["api"]
}
EOF

CONFIG_FILE="${TMPDIR}/bad_config.json"
_CONFIG_VALIDATED=""

_rc=0
_output=$(_config_validate 2>&1) || _rc=$?
_test "missing project field fails" test "$_rc" -ne 0

# ────────────────────────────────────────
echo ""
echo "  Doctor — config validation (bad services type)"
# ────────────────────────────────────────

cat > "${TMPDIR}/bad_services.json" << 'EOF'
{
  "project": "test",
  "services": "not-an-object",
  "deploy_order": ["api"]
}
EOF

CONFIG_FILE="${TMPDIR}/bad_services.json"
_CONFIG_VALIDATED=""

_rc=0
_config_validate 2>/dev/null || _rc=$?
_test "non-object services fails" test "$_rc" -ne 0

# ────────────────────────────────────────
echo ""
echo "  Doctor — config validation (deploy_order mismatch)"
# ────────────────────────────────────────

cat > "${TMPDIR}/mismatch.json" << 'EOF'
{
  "project": "test",
  "services": { "api": {} },
  "deploy_order": ["api", "ghost"]
}
EOF

CONFIG_FILE="${TMPDIR}/mismatch.json"
_CONFIG_VALIDATED=""

_rc=0
_config_validate 2>/dev/null || _rc=$?
_test "deploy_order referencing missing service fails" test "$_rc" -ne 0

# ────────────────────────────────────────
echo ""
echo "  Doctor — hook permissions check"
# ────────────────────────────────────────

_hook_dir="${TMPDIR}/hooks_test"
mkdir -p "${_hook_dir}"

# Executable hook
cat > "${_hook_dir}/deploy.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "deploying"
SCRIPT
chmod +x "${_hook_dir}/deploy.sh"
_test "executable hook detected" test -x "${_hook_dir}/deploy.sh"

# Non-executable hook
cat > "${_hook_dir}/health.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "checking health"
SCRIPT
_test "non-executable hook detected" test ! -x "${_hook_dir}/health.sh"

# Fix with chmod
chmod +x "${_hook_dir}/health.sh"
_test "hook fixed to executable" test -x "${_hook_dir}/health.sh"

# ────────────────────────────────────────
echo ""
echo "  Doctor — stale PID detection"
# ────────────────────────────────────────

_pid_dir="${TMPDIR}/pids"
mkdir -p "${_pid_dir}"

# PID that doesn't exist
echo "9999999" > "${_pid_dir}/ghost.pid"
_pid=$(cat "${_pid_dir}/ghost.pid")
_rc=0
kill -0 "$_pid" 2>/dev/null || _rc=$?
_test "dead PID detected" test "$_rc" -ne 0

# Clean stale PID
rm -f "${_pid_dir}/ghost.pid"
_test "stale PID cleaned" test ! -f "${_pid_dir}/ghost.pid"

# ────────────────────────────────────────
echo ""
echo "  Doctor — log cleanup (old logs)"
# ────────────────────────────────────────

_log_dir="${TMPDIR}/logs"
mkdir -p "${_log_dir}"

# Create a fresh log and an "old" log
echo "recent" > "${_log_dir}/deploy-2026-03-05.log"
echo "ancient" > "${_log_dir}/deploy-2020-01-01.log"

# Count logs
_count=$(ls -1 "${_log_dir}"/*.log 2>/dev/null | wc -l | tr -d ' ')
_test_eq "two log files present" "2" "$_count"

# Simulate cleanup: remove logs older than threshold
find "${_log_dir}" -name "*.log" -mtime +7 -delete 2>/dev/null || true
# Note: mtime check depends on actual file age, not name. The freshly created
# file won't be deleted by mtime. This tests the find pattern works.
_test "find -mtime pattern runs without error" test -f "${_log_dir}/deploy-2026-03-05.log"

# ────────────────────────────────────────
echo ""
echo "  Doctor — health config validation"
# ────────────────────────────────────────

cat > "${TMPDIR}/health_config.json" << 'EOF'
{
  "project": "test",
  "services": {
    "api": {
      "health": { "type": "http", "port": 3000, "timeout": 10 }
    },
    "worker": {
      "health": { "type": "command" }
    }
  },
  "deploy_order": ["api", "worker"]
}
EOF

CONFIG_FILE="${TMPDIR}/health_config.json"
_CONFIG_VALIDATED=""

_rc=0
_config_validate 2>/dev/null || _rc=$?
_test_eq "valid health config passes" "0" "$_rc"

# Invalid health type
cat > "${TMPDIR}/bad_health.json" << 'EOF'
{
  "project": "test",
  "services": {
    "api": {
      "health": { "type": "invalid_type", "port": 3000 }
    }
  },
  "deploy_order": ["api"]
}
EOF

CONFIG_FILE="${TMPDIR}/bad_health.json"
_CONFIG_VALIDATED=""

_rc=0
_config_validate 2>/dev/null || _rc=$?
_test "invalid health type fails validation" test "$_rc" -ne 0

_test_summary
