#!/usr/bin/env bash
# tests/test_dev.sh — Tests for dev stack PID management and cleanup
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
# Re-set trap AFTER sourcing utils.sh (which sets its own EXIT trap)
trap 'rm -rf "$TMPDIR"' EXIT

# Helper: count files matching a pattern (safe with pipefail)
_count_files() {
  local dir="$1" pattern="$2"
  local _c=0 _f
  for _f in "${dir}"/${pattern}; do
    [[ -f "$_f" ]] && _c=$((_c + 1))
  done
  echo "$_c"
}

# ────────────────────────────────────────
echo "  Dev — PID file creation"
# ────────────────────────────────────────

_pid_dir="${TMPDIR}/pids"
mkdir -p "$_pid_dir"

# Simulate writing a PID file (as dev stack does)
echo "$$" > "${_pid_dir}/api.pid"
_test_file_exists "PID file created" "${_pid_dir}/api.pid"

_stored_pid=$(cat "${_pid_dir}/api.pid")
_test_eq "PID file contains current PID" "$$" "$_stored_pid"

# ────────────────────────────────────────
echo ""
echo "  Dev — PID file read and validate"
# ────────────────────────────────────────

# Our own PID should be alive
_rc=0
kill -0 "$_stored_pid" 2>/dev/null || _rc=$?
_test_eq "stored PID is alive" "0" "$_rc"

# Dead PID
echo "9999999" > "${_pid_dir}/ghost.pid"
_ghost_pid=$(cat "${_pid_dir}/ghost.pid")
_rc=0
kill -0 "$_ghost_pid" 2>/dev/null || _rc=$?
_test "dead PID detected" test "$_rc" -ne 0

# ────────────────────────────────────────
echo ""
echo "  Dev — PID cleanup logic"
# ────────────────────────────────────────

# Simulate the cleanup pattern used in dev.sh:
# For each .pid file, check if process alive, kill if so, remove file
for _pf in "${_pid_dir}"/*.pid; do
  [[ -f "$_pf" ]] || continue
  _p=$(cat "$_pf")
  if kill -0 "$_p" 2>/dev/null; then
    # Process alive — in real code, would kill it
    :
  else
    # Process dead — stale PID, remove
    rm -f "$_pf"
  fi
done

# ghost.pid (dead PID) should be removed, api.pid (our PID) should remain
_test "stale PID file cleaned" test ! -f "${_pid_dir}/ghost.pid"
_test_file_exists "live PID file kept" "${_pid_dir}/api.pid"

# ────────────────────────────────────────
echo ""
echo "  Dev — multiple PID files"
# ────────────────────────────────────────

# Create several PID files
echo "1111" > "${_pid_dir}/svc1.pid"
echo "2222" > "${_pid_dir}/svc2.pid"
echo "3333" > "${_pid_dir}/svc3.pid"

_count=$(_count_files "$_pid_dir" "*.pid")
_test_eq "multiple PID files created" "4" "$_count"  # 3 new + api.pid

# Clean all PID files (simulating full cleanup)
rm -f "${_pid_dir}"/*.pid

_count=$(_count_files "$_pid_dir" "*.pid")
_test_eq "all PID files cleaned" "0" "$_count"

# ────────────────────────────────────────
echo ""
echo "  Dev — hooks directory structure"
# ────────────────────────────────────────

_proj="${TMPDIR}/devproject"
mkdir -p "${_proj}/.muster/hooks/api"
mkdir -p "${_proj}/.muster/hooks/redis"

# Deploy hook
cat > "${_proj}/.muster/hooks/api/deploy.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "starting api on port 3000"
SCRIPT
chmod +x "${_proj}/.muster/hooks/api/deploy.sh"

# Cleanup hook
cat > "${_proj}/.muster/hooks/api/cleanup.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "stopping api"
SCRIPT
chmod +x "${_proj}/.muster/hooks/api/cleanup.sh"

_test "deploy hook exists and executable" test -x "${_proj}/.muster/hooks/api/deploy.sh"
_test "cleanup hook exists and executable" test -x "${_proj}/.muster/hooks/api/cleanup.sh"

# Verify hook output
_output=$(bash "${_proj}/.muster/hooks/api/deploy.sh" 2>&1)
_test_contains "deploy hook runs" "starting api" "$_output"

_test_summary
