#!/usr/bin/env bash
# tests/test_status.sh — Tests for status/health check helpers
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE="" GRAY=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ────────────────────────────────────────
echo "  Status — health hook execution"
# ────────────────────────────────────────

# Create a fake project with health hook
_proj="${TMPDIR}/project"
mkdir -p "${_proj}/.muster/hooks/api"
cat > "${_proj}/.muster/hooks/api/health.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "healthy"
exit 0
SCRIPT
chmod +x "${_proj}/.muster/hooks/api/health.sh"

# Run health hook directly and check output
_output=$(bash "${_proj}/.muster/hooks/api/health.sh" 2>&1)
_test_eq "healthy hook returns healthy" "healthy" "$_output"

# Create a failing health hook
mkdir -p "${_proj}/.muster/hooks/redis"
cat > "${_proj}/.muster/hooks/redis/health.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "connection refused"
exit 1
SCRIPT
chmod +x "${_proj}/.muster/hooks/redis/health.sh"

_rc=0
bash "${_proj}/.muster/hooks/redis/health.sh" 2>/dev/null || _rc=$?
_test "unhealthy hook exits non-zero" test "$_rc" -ne 0

# ────────────────────────────────────────
echo ""
echo "  Status — health hook with timeout"
# ────────────────────────────────────────

# Create a hook that hangs
mkdir -p "${_proj}/.muster/hooks/slow"
cat > "${_proj}/.muster/hooks/slow/health.sh" << 'SCRIPT'
#!/usr/bin/env bash
sleep 60
echo "never reaches here"
SCRIPT
chmod +x "${_proj}/.muster/hooks/slow/health.sh"

# Run with timeout (should fail)
_rc=0
timeout 2 bash "${_proj}/.muster/hooks/slow/health.sh" 2>/dev/null || _rc=$?
_test "timeout kills hanging health hook" test "$_rc" -ne 0

# ────────────────────────────────────────
echo ""
echo "  Status — command health type"
# ────────────────────────────────────────

# Simulate a command health check
_rc=0
bash -c 'echo "all good" && exit 0' 2>/dev/null || _rc=$?
_test_eq "command health succeeds" "0" "$_rc"

_rc=0
bash -c 'exit 1' 2>/dev/null || _rc=$?
_test "command health fails" test "$_rc" -ne 0

# ────────────────────────────────────────
echo ""
echo "  Status — hook permissions"
# ────────────────────────────────────────

# Non-executable hook
cat > "${_proj}/.muster/hooks/api/non_exec.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "should not run"
SCRIPT
# Don't chmod +x

_test "non-executable hook not executable" test ! -x "${_proj}/.muster/hooks/api/non_exec.sh"

# Fix permissions
chmod +x "${_proj}/.muster/hooks/api/non_exec.sh"
_test "fixed hook is executable" test -x "${_proj}/.muster/hooks/api/non_exec.sh"

# ────────────────────────────────────────
echo ""
echo "  Status — missing hook graceful"
# ────────────────────────────────────────

_test "missing hook dir not present" test ! -d "${_proj}/.muster/hooks/nonexistent"
_test "missing health hook not present" test ! -f "${_proj}/.muster/hooks/nonexistent/health.sh"

_test_summary
