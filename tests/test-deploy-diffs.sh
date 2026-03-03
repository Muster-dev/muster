#!/usr/bin/env bash
# Test suite for deploy diffs feature (git helpers + history integration)
# Usage: bash tests/test-deploy-diffs.sh

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

# ── Setup: create a temp git repo to test in ──
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
git commit --allow-empty -m "initial commit" -q

# Create a fake deploy.json + .muster dir so CONFIG_FILE works
mkdir -p .muster/logs
echo '{"project":"test","version":"1","services":{"api":{"name":"API Server"}}}' > deploy.json
CONFIG_FILE="$TMPDIR/deploy.json"
export CONFIG_FILE

# Source muster libs
source "$MUSTER_ROOT/lib/core/colors.sh"
source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/commands/history.sh"

echo ""
echo -e "  \033[1m\033[38;5;220mDeploy Diffs Test Suite\033[0m"
echo ""

# ═══════════════════════════════════════════
echo -e "  \033[1m_git_is_repo\033[0m"
# ═══════════════════════════════════════════

_test "_git_is_repo returns true in a git repo" _git_is_repo

_not_git_repo() { ! (cd /tmp && _git_is_repo); }
_test "returns false outside a git repo" _not_git_repo

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1m_git_current_sha\033[0m"
# ═══════════════════════════════════════════

sha=$(_git_current_sha)
_test "returns a non-empty SHA" test -n "$sha"
_test "SHA is 7+ chars" test "${#sha}" -ge 7

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1m_git_prev_deploy_sha / _git_save_deploy_sha\033[0m"
# ═══════════════════════════════════════════

prev=$(_git_prev_deploy_sha "api")
_test_eq "returns empty when no tracker file exists" "" "$prev"

# Save a SHA
_git_save_deploy_sha "api" "$sha"
_test "creates deploy-commits.json" test -f "$TMPDIR/.muster/deploy-commits.json"

saved=$(_git_prev_deploy_sha "api")
_test_eq "reads back saved SHA" "$sha" "$saved"

# Save a different service
_git_save_deploy_sha "redis" "abc1234"
redis_sha=$(_git_prev_deploy_sha "redis")
_test_eq "stores multiple services independently" "abc1234" "$redis_sha"

# Original service still intact
api_sha=$(_git_prev_deploy_sha "api")
_test_eq "doesn't overwrite other services" "$sha" "$api_sha"

# Nonexistent service returns empty
none=$(_git_prev_deploy_sha "nonexistent")
_test_eq "returns empty for unknown service" "" "$none"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1m_git_deploy_diff\033[0m"
# ═══════════════════════════════════════════

# Empty prev = silently skip (no output)
output=$(_git_deploy_diff "" "$sha")
_test_eq "empty prev produces no output" "" "$output"

# Same SHA = no new commits
output=$(_git_deploy_diff "$sha" "$sha")
_test_contains "same SHA shows 'No new commits'" "No new commits" "$output"

# Unreachable SHA
output=$(_git_deploy_diff "deadbeefcafe" "$sha")
_test_contains "unreachable SHA shows warning" "not reachable" "$output"

# Actual diff with commits
prev_sha=$sha
echo "file1" > file1.txt && git add file1.txt && git commit -q -m "Add file1"
echo "file2" > file2.txt && git add file2.txt && git commit -q -m "Add file2"
echo "file3" > file3.txt && git add file3.txt && git commit -q -m "Add file3"
new_sha=$(_git_current_sha)

output=$(_git_deploy_diff "$prev_sha" "$new_sha")
_test_contains "shows commit count" "3 commit" "$output"
_test_contains "shows commit message" "Add file1" "$output"
_test_contains "shows diffstat with file count" "file" "$output"

# More than 5 commits (truncation)
echo "f4" > f4.txt && git add f4.txt && git commit -q -m "Add f4"
echo "f5" > f5.txt && git add f5.txt && git commit -q -m "Add f5"
echo "f6" > f6.txt && git add f6.txt && git commit -q -m "Add f6"
echo "f7" > f7.txt && git add f7.txt && git commit -q -m "Add f7"
big_sha=$(_git_current_sha)

output=$(_git_deploy_diff "$prev_sha" "$big_sha")
_test_contains "truncates at 5, shows '...and N more'" "...and" "$output"

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1m_history_log_event (5-field format)\033[0m"
# ═══════════════════════════════════════════

_history_log_event "api" "deploy" "ok" "$new_sha"
_history_log_event "api" "deploy" "failed" "$new_sha"
_history_log_event "redis" "rollback" "ok" ""

log_file="$TMPDIR/.muster/logs/deploy-events.log"
_test "event log file exists" test -f "$log_file"

# Check NDJSON format
line1=$(head -1 "$log_file")
_test_contains "log line is NDJSON" '{"ts":' "$line1"

_test_contains "log contains commit SHA" "$new_sha" "$line1"

# Check backward compat: old 4-field entry
echo "2026-01-01 00:00:00|legacy|deploy|ok" >> "$log_file"

line_count=$(wc -l < "$log_file")
_test "log has all 4 entries" test "$line_count" -ge 4

# ═══════════════════════════════════════════
echo ""
echo -e "  \033[1mCONFIG_FILE guard\033[0m"
# ═══════════════════════════════════════════

_prev_no_config() { (unset CONFIG_FILE; result=$(_git_prev_deploy_sha "api" 2>&1); test -z "$result"); }
_test "_git_prev_deploy_sha returns empty when CONFIG_FILE unset" _prev_no_config

_save_no_config() { (unset CONFIG_FILE; _git_save_deploy_sha "api" "test123" 2>&1); }
_test "_git_save_deploy_sha does not crash when CONFIG_FILE unset" _save_no_config

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
