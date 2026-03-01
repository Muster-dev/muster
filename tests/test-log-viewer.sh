#!/usr/bin/env bash
# Test suite for log viewer feature (colorizing, settings, streambox logic)
# Usage: bash tests/test-log-viewer.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

_test() {
  TOTAL=$(( TOTAL + 1 ))
  local desc="$1"
  shift
  if "$@" 2>/dev/null; then
    PASS=$(( PASS + 1 ))
    printf '  \033[38;5;114m✓\033[0m %s\n' "$desc"
  else
    FAIL=$(( FAIL + 1 ))
    printf '  \033[38;5;203m✗\033[0m %s\n' "$desc"
  fi
}

_test_eq() {
  TOTAL=$(( TOTAL + 1 ))
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$(( PASS + 1 ))
    printf '  \033[38;5;114m✓\033[0m %s\n' "$desc"
  else
    FAIL=$(( FAIL + 1 ))
    printf '  \033[38;5;203m✗\033[0m %s (expected: "%s", got: "%s")\n' "$desc" "$expected" "$actual"
  fi
}

_test_contains() {
  TOTAL=$(( TOTAL + 1 ))
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$(( PASS + 1 ))
    printf '  \033[38;5;114m✓\033[0m %s\n' "$desc"
  else
    FAIL=$(( FAIL + 1 ))
    printf '  \033[38;5;203m✗\033[0m %s (expected to contain: "%s")\n' "$desc" "$needle"
  fi
}

_test_not_contains() {
  TOTAL=$(( TOTAL + 1 ))
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$(( PASS + 1 ))
    printf '  \033[38;5;114m✓\033[0m %s\n' "$desc"
  else
    FAIL=$(( FAIL + 1 ))
    printf '  \033[38;5;203m✗\033[0m %s (should NOT contain: "%s")\n' "$desc" "$needle"
  fi
}

# ── Setup ──
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Backup real global config if it exists
_ORIG_GLOBAL="$HOME/.muster/settings.json"
_BACKUP=""
if [[ -f "$_ORIG_GLOBAL" ]]; then
  _BACKUP="${TMPDIR}/settings-backup.json"
  cp "$_ORIG_GLOBAL" "$_BACKUP"
fi

_restore_settings() {
  if [[ -n "$_BACKUP" ]]; then
    cp "$_BACKUP" "$_ORIG_GLOBAL"
  fi
}
trap '_restore_settings; rm -rf "$TMPDIR"' EXIT

# Source muster libs
source "$MUSTER_ROOT/lib/core/colors.sh"
source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"
source "$MUSTER_ROOT/lib/tui/streambox.sh"

echo ""
echo -e "  \033[1m\033[38;5;220mLog Viewer Test Suite\033[0m"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1m_colorize_log_line — auto mode\033[0m"
# ═══════════════════════════════════════════

_LOG_COLOR_MODE="auto"

# Error lines → red
output=$(_colorize_log_line "Something went error here")
_test_contains "error line contains RED escape" $'\033[38;5;203m' "$output"

output=$(_colorize_log_line "FATAL: process crashed")
_test_contains "FATAL line contains RED escape" $'\033[38;5;203m' "$output"

output=$(_colorize_log_line "Error: connection refused")
_test_contains "Error (capitalized) contains RED" $'\033[38;5;203m' "$output"

# Warning lines → yellow
output=$(_colorize_log_line "Warning: disk space low")
_test_contains "Warning line contains YELLOW escape" $'\033[38;5;221m' "$output"

output=$(_colorize_log_line "DEPRECATION WARNING: old API")
_test_contains "WARNING line contains YELLOW escape" $'\033[38;5;221m' "$output"

# Success lines → green
output=$(_colorize_log_line "Successfully built abc123")
_test_contains "Successfully line contains GREEN" $'\033[38;5;114m' "$output"

output=$(_colorize_log_line "Service is healthy")
_test_contains "healthy line contains GREEN" $'\033[38;5;114m' "$output"

output=$(_colorize_log_line "Build complete")
_test_contains "Complete line contains GREEN" $'\033[38;5;114m' "$output"

# Step/arrow lines → accent
output=$(_colorize_log_line "Step 1/5 : FROM node:18")
_test_contains "Step line contains ACCENT" $'\033[38;5;178m' "$output"

output=$(_colorize_log_line " ---> abc123def456")
_test_contains "---> line contains ACCENT" $'\033[38;5;178m' "$output"

# Default lines → dim
output=$(_colorize_log_line "just a normal log line")
_test_contains "normal line contains DIM" $'\033[2m' "$output"

# All lines contain RESET
output=$(_colorize_log_line "any text")
_test_contains "output ends with RESET" $'\033[0m' "$output"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1m_colorize_log_line — none mode\033[0m"
# ═══════════════════════════════════════════

_LOG_COLOR_MODE="none"

output=$(_colorize_log_line "Error: should be plain")
_test_eq "none mode: error line has no escapes" "Error: should be plain" "$output"

output=$(_colorize_log_line "Step 1/5 : FROM node")
_test_not_contains "none mode: step line has no ANSI" $'\033[' "$output"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1m_colorize_log_line — raw mode\033[0m"
# ═══════════════════════════════════════════

_LOG_COLOR_MODE="raw"

output=$(_colorize_log_line "Error: pass through raw")
_test_eq "raw mode: passes text through unchanged" "Error: pass through raw" "$output"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1mlog_color_mode in global defaults\033[0m"
# ═══════════════════════════════════════════

_test_contains "log_color_mode present in _GLOBAL_DEFAULTS" "log_color_mode" "$_GLOBAL_DEFAULTS"
_test_contains "default value is auto" '"log_color_mode": "auto"' "$_GLOBAL_DEFAULTS"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1mglobal_config_get/set for log_color_mode\033[0m"
# ═══════════════════════════════════════════

# Read current value (should be auto or whatever user has)
val=$(global_config_get "log_color_mode" 2>/dev/null)
_test "global_config_get reads log_color_mode" test -n "$val"

# Set to raw, read back
global_config_set "log_color_mode" '"raw"'
val=$(global_config_get "log_color_mode")
_test_eq "set log_color_mode to raw" "raw" "$val"

# Set to none, read back
global_config_set "log_color_mode" '"none"'
val=$(global_config_get "log_color_mode")
_test_eq "set log_color_mode to none" "none" "$val"

# Set back to auto
global_config_set "log_color_mode" '"auto"'
val=$(global_config_get "log_color_mode")
_test_eq "set log_color_mode back to auto" "auto" "$val"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1msettings CLI validation\033[0m"
# ═══════════════════════════════════════════

# Source settings (needs menu.sh + remote.sh stubs or the real thing)
# We'll test the CLI function directly by sourcing
source "$MUSTER_ROOT/lib/core/platform.sh" 2>/dev/null || true
source "$MUSTER_ROOT/lib/tui/menu.sh" 2>/dev/null || true
source "$MUSTER_ROOT/lib/core/remote.sh" 2>/dev/null || true
source "$MUSTER_ROOT/lib/commands/settings.sh"

# Valid values
_valid_auto() { _settings_global_cli "log_color_mode" "auto" >/dev/null 2>&1; }
_test "CLI accepts log_color_mode=auto" _valid_auto

_valid_raw() { _settings_global_cli "log_color_mode" "raw" >/dev/null 2>&1; }
_test "CLI accepts log_color_mode=raw" _valid_raw

_valid_none() { _settings_global_cli "log_color_mode" "none" >/dev/null 2>&1; }
_test "CLI accepts log_color_mode=none" _valid_none

# Invalid value
_invalid_mode() { ! _settings_global_cli "log_color_mode" "invalid" >/dev/null 2>&1; }
_test "CLI rejects log_color_mode=invalid" _invalid_mode

# Reset to auto
global_config_set "log_color_mode" '"auto"'

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1mstreambox functions exist\033[0m"
# ═══════════════════════════════════════════

_fn_exists_stream_in_box() { declare -f stream_in_box >/dev/null; }
_fn_exists_log_viewer() { declare -f _log_viewer >/dev/null; }
_fn_exists_colorize() { declare -f _colorize_log_line >/dev/null; }
_test "stream_in_box is a function" _fn_exists_stream_in_box
_test "_log_viewer is a function" _fn_exists_log_viewer
_test "_colorize_log_line is a function" _fn_exists_colorize

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1mlog file reading + ANSI stripping\033[0m"
# ═══════════════════════════════════════════

# Create a mock log file with ANSI codes
cat > "${TMPDIR}/test.log" <<'LOGEOF'
Step 1/5 : FROM node:18-alpine
 ---> abc123def
Step 2/5 : WORKDIR /app
npm WARN deprecated old-package@1.0.0
Error: Module not found
Successfully built 9f44b69329e5
just a plain line
LOGEOF

# Verify file has expected line count
line_count=$(wc -l < "${TMPDIR}/test.log" | tr -d ' ')
_test_eq "test log has 7 lines" "7" "$line_count"

# Test that colorize handles each line type
_LOG_COLOR_MODE="auto"
out=$(_colorize_log_line "Step 1/5 : FROM node:18-alpine")
_test_contains "Step line colored as accent" $'\033[38;5;178m' "$out"

out=$(_colorize_log_line "npm WARN deprecated old-package@1.0.0")
_test_contains "WARN line colored as yellow" $'\033[38;5;221m' "$out"

out=$(_colorize_log_line "Error: Module not found")
_test_contains "Error line colored as red" $'\033[38;5;203m' "$out"

out=$(_colorize_log_line "Successfully built 9f44b69329e5")
_test_contains "Successfully line colored as green" $'\033[38;5;114m' "$out"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1mCtrl+O detection in streambox (code check)\033[0m"
# ═══════════════════════════════════════════

# Verify the streambox code contains read -rsn1 -t 1 (not sleep 0.3)
sb_code=$(declare -f stream_in_box)
sb_source=$(cat "$MUSTER_ROOT/lib/tui/streambox.sh")
_test_contains "stream_in_box uses read -rsn1 -t 1" "read -rsn1 -t 1" "$sb_code"
_test_not_contains "stream_in_box has no sleep 0.3" "sleep 0.3" "$sb_code"
_test_contains "streambox source checks for Ctrl+O (\\x0f)" '\x0f' "$sb_source"
_test_contains "stream_in_box calls _log_viewer" "_log_viewer" "$sb_code"

# Verify the log viewer uses clear + cursor hide/show
lv_code=$(declare -f _log_viewer)
_test_contains "_log_viewer clears screen" "tput clear" "$lv_code"
_test_contains "_log_viewer hides cursor (civis)" "civis" "$lv_code"
_test_contains "_log_viewer restores cursor (cnorm)" "cnorm" "$lv_code"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1mafter-deploy hint in deploy.sh (code check)\033[0m"
# ═══════════════════════════════════════════

deploy_code=$(cat "$MUSTER_ROOT/lib/commands/deploy.sh")
_test_contains "deploy.sh has Ctrl+O hint text" "Ctrl+O view full log" "$deploy_code"
_test_contains "deploy.sh reads key after deploy" "read -rsn1" "$deploy_code"
_test_contains "deploy.sh calls _log_viewer on Ctrl+O" "_log_viewer" "$deploy_code"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1mvisual output check (color samples)\033[0m"
# ═══════════════════════════════════════════

echo ""
echo -e "  Sample colorized output (auto mode):"
_LOG_COLOR_MODE="auto"
printf '    '
_colorize_log_line "Step 1/5 : FROM node:18-alpine"
echo ""
printf '    '
_colorize_log_line " ---> abc123def"
echo ""
printf '    '
_colorize_log_line "npm WARN deprecated old-package"
echo ""
printf '    '
_colorize_log_line "Error: Module not found"
echo ""
printf '    '
_colorize_log_line "Successfully built 9f44b69329e5"
echo ""
printf '    '
_colorize_log_line "just a regular log line"
echo ""

# ═══════════════════════════════════════════
echo ""
echo "  ─────────────────────────────────"
if (( FAIL == 0 )); then
  printf '  \033[38;5;114m%d/%d tests passed\033[0m\n' "$PASS" "$TOTAL"
else
  printf '  \033[38;5;203m%d/%d tests failed\033[0m\n' "$FAIL" "$TOTAL"
fi
echo ""

exit $FAIL
