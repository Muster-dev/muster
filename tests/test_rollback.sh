#!/usr/bin/env bash
# tests/test_rollback.sh — Tests for rollback/history functions
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
echo "  History — event logging"
# ────────────────────────────────────────

# Set up fake project dir for CONFIG_FILE
_proj="${TMPDIR}/myproject"
mkdir -p "${_proj}/.muster/logs"
CONFIG_FILE="${_proj}/deploy.json"
touch "$CONFIG_FILE"

# Source history.sh (it only defines functions, no side effects)
source "$MUSTER_ROOT/lib/commands/history.sh"

# Log a deploy event
_history_log_event "api" "deploy" "ok" "abc123"
_test_file_exists "deploy-events.log created" "${_proj}/.muster/logs/deploy-events.log"

_log_content=$(cat "${_proj}/.muster/logs/deploy-events.log")
_test_contains "event has service" '"service":"api"' "$_log_content"
_test_contains "event has action" '"action":"deploy"' "$_log_content"
_test_contains "event has status" '"status":"ok"' "$_log_content"
_test_contains "event has commit" '"commit":"abc123"' "$_log_content"
_test_contains "event has timestamp" '"ts":' "$_log_content"

# ────────────────────────────────────────
echo ""
echo "  History — rollback event"
# ────────────────────────────────────────

_history_log_event "redis" "rollback" "failed" ""
_log_content=$(cat "${_proj}/.muster/logs/deploy-events.log")
_test_contains "rollback event recorded" '"action":"rollback"' "$_log_content"
_test_contains "failure status recorded" '"status":"failed"' "$_log_content"

# Check multiple events appended (should have 2 lines)
_line_count=$(wc -l < "${_proj}/.muster/logs/deploy-events.log" | tr -d ' ')
_test_eq "two events in log" "2" "$_line_count"

# ────────────────────────────────────────
echo ""
echo "  History — fleet source included"
# ────────────────────────────────────────

MUSTER_DEPLOY_SOURCE="fleet:production"
_history_log_event "api" "deploy" "ok" "def456"
unset MUSTER_DEPLOY_SOURCE

_last_line=$(tail -1 "${_proj}/.muster/logs/deploy-events.log")
_test_contains "fleet source in event" '"source":"fleet:production"' "$_last_line"

_test_summary
