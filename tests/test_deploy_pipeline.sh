#!/usr/bin/env bash
# tests/test_deploy_pipeline.sh — Tests for deploy pipeline functions
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE="" GRAY=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"
MUSTER_MINIMAL="true"

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ────────────────────────────────────────
echo "  Deploy verify — empty log"
# ────────────────────────────────────────

# Source deploy.sh functions we need — only _deploy_verify
# We can't source the whole file (it sources TUI libs), so extract just what we need
eval "$(sed -n '/^_deploy_verify()/,/^}/p' "$MUSTER_ROOT/lib/commands/deploy.sh")"

_log_file="${TMPDIR}/empty.log"
touch "$_log_file"
_start_time=$(date +%s)
sleep 1

_output=$(_deploy_verify "$_log_file" "api" "$_start_time" 2>&1)
_test_contains "detects empty log" "no output" "$_output"

# ────────────────────────────────────────
echo ""
echo "  Deploy verify — success markers"
# ────────────────────────────────────────

_log_file="${TMPDIR}/success.log"
echo "Service deployed successfully" > "$_log_file"
_start_time=$(( $(date +%s) - 5 ))

_output=$(_deploy_verify "$_log_file" "api" "$_start_time" 2>&1)
_test_not_contains "no warning for success markers" "no success markers" "$_output"

# ────────────────────────────────────────
echo ""
echo "  Deploy verify — missing success markers"
# ────────────────────────────────────────

_log_file="${TMPDIR}/no_markers.log"
echo "some random output that has no keywords" > "$_log_file"
_start_time=$(( $(date +%s) - 5 ))

_output=$(_deploy_verify "$_log_file" "api" "$_start_time" 2>&1)
_test_contains "warns on missing success markers" "no success markers" "$_output"

# ────────────────────────────────────────
echo ""
echo "  Deploy verify — JSON mode"
# ────────────────────────────────────────

_log_file="${TMPDIR}/empty_json.log"
touch "$_log_file"
_start_time=$(( $(date +%s) - 5 ))

_output=$(_deploy_verify "$_log_file" "api" "$_start_time" "json" 2>&1)
_test_contains "JSON mode emits verify_warning" "verify_warning" "$_output"
_test_contains "JSON mode includes service name" '"service":"api"' "$_output"

# ────────────────────────────────────────
echo ""
echo "  Deploy lock — file path"
# ────────────────────────────────────────

_lock_path=$(_deploy_lock_file "$TMPDIR/project")
_test_eq "lock file path" "$TMPDIR/project/.muster/deploy.lock" "$_lock_path"

# ────────────────────────────────────────
echo ""
echo "  Deploy lock — create and release"
# ────────────────────────────────────────

_proj="${TMPDIR}/project"
mkdir -p "${_proj}/.muster"

# Acquire lock (non-interactive, no existing lock)
_deploy_lock_acquire "$_proj" "api" "redis" 2>/dev/null
_lock_file=$(_deploy_lock_file "$_proj")
_test_file_exists "lock file created" "$_lock_file"

# Verify lock content is JSON with expected fields
_lock_content=$(cat "$_lock_file")
_test_contains "lock has user field" '"user":' "$_lock_content"
_test_contains "lock has pid field" '"pid":' "$_lock_content"
_test_contains "lock has started field" '"started":' "$_lock_content"
_test_contains "lock has services array" '"services":' "$_lock_content"

# Release lock
_deploy_lock_release "$_proj"
_test "lock file removed" test ! -f "$_lock_file"

# ────────────────────────────────────────
echo ""
echo "  Deploy lock — read"
# ────────────────────────────────────────

_lock_file="${TMPDIR}/test_lock.json"
cat > "$_lock_file" << 'EOF'
{"user":"testuser","pid":99999,"started":"2026-01-01 12:00:00","terminal":"/dev/ttys001","services":["api","redis"]}
EOF

_deploy_lock_read "$_lock_file"
_test_eq "read lock user" "testuser" "$_LOCK_USER"
_test_eq "read lock pid" "99999" "$_LOCK_PID"
_test_contains "read lock started" "2026-01-01" "$_LOCK_STARTED"
_test_contains "read lock services" "api" "$_LOCK_SERVICES"

# ────────────────────────────────────────
echo ""
echo "  Deploy lock — stale lock removal"
# ────────────────────────────────────────

_proj2="${TMPDIR}/project2"
mkdir -p "${_proj2}/.muster"
_lock_file=$(_deploy_lock_file "$_proj2")

# Create a lock with a dead PID
cat > "$_lock_file" << 'EOF'
{"user":"ghost","pid":1,"started":"2020-01-01 00:00:00","terminal":"unknown","services":[]}
EOF

# pid 1 is init — alive, but let's use a definitely-dead PID
# Use a very high PID that won't exist
cat > "$_lock_file" << 'EOF'
{"user":"ghost","pid":9999999,"started":"2020-01-01 00:00:00","terminal":"unknown","services":[]}
EOF

# Acquire should remove the stale lock and succeed
_deploy_lock_acquire "$_proj2" 2>/dev/null
_test_file_exists "new lock created after stale removal" "$_lock_file"
_lock_content=$(cat "$_lock_file")
_test_not_contains "stale lock replaced" '"user":"ghost"' "$_lock_content"

_deploy_lock_release "$_proj2"

# ────────────────────────────────────────
echo ""
echo "  Env file — load and unload"
# ────────────────────────────────────────

_env_file="${TMPDIR}/test.env"
cat > "$_env_file" << 'EOF'
# Database config
DB_HOST=localhost
DB_PORT=5432
DB_NAME="myapp_test"
SECRET_KEY='s3cr3t'

# Blank line above
EMPTY_VAL=
EOF

# Clear any existing values
unset DB_HOST DB_PORT DB_NAME SECRET_KEY EMPTY_VAL 2>/dev/null || true

_load_env_file "$_env_file"
_test_eq "loads DB_HOST" "localhost" "${DB_HOST:-}"
_test_eq "loads DB_PORT" "5432" "${DB_PORT:-}"
_test_eq "strips double quotes" "myapp_test" "${DB_NAME:-}"
_test_eq "strips single quotes" "s3cr3t" "${SECRET_KEY:-}"
_test_eq "handles empty value" "" "${EMPTY_VAL:-}"
_test "tracks loaded vars" test "${#_MUSTER_ENV_VARS[@]}" -ge 4

# No-override test: create separate env file
_env_file2="${TMPDIR}/override.env"
echo "DB_HOST=overwritten" > "$_env_file2"
_load_env_file "$_env_file2"
_test_eq "does not override existing vars" "localhost" "$DB_HOST"

# Unload (second _load_env_file replaced _MUSTER_ENV_VARS, so reload first)
_unload_env_file
unset DB_HOST DB_PORT DB_NAME SECRET_KEY EMPTY_VAL 2>/dev/null || true
_load_env_file "$_env_file"
_unload_env_file
_test_eq "DB_HOST unset after unload" "" "${DB_HOST:-}"
_test_eq "DB_PORT unset after unload" "" "${DB_PORT:-}"
_test "env vars array cleared" test "${#_MUSTER_ENV_VARS[@]}" -eq 0

# ────────────────────────────────────────
echo ""
echo "  Env file — missing file is no-op"
# ────────────────────────────────────────

_rc=0
_load_env_file "${TMPDIR}/nonexistent.env" || _rc=$?
_test_eq "missing env file returns 0" "0" "$_rc"

_test_summary
