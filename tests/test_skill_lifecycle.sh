#!/usr/bin/env bash
# tests/test_skill_lifecycle.sh — Tests for skill enable/disable/configure/remove
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SKILLS_DIR="${TMPDIR}/skills"
GLOBAL_SKILLS_DIR="${TMPDIR}/skills"
FLEETS_BASE_DIR="${TMPDIR}/fleets"
mkdir -p "$SKILLS_DIR" "$FLEETS_BASE_DIR"

source "$MUSTER_ROOT/lib/skills/manager.sh"

# Override after sourcing (source sets these from $HOME)
SKILLS_DIR="${TMPDIR}/skills"
GLOBAL_SKILLS_DIR="${TMPDIR}/skills"
FLEETS_BASE_DIR="${TMPDIR}/fleets"

# ────────────────────────────────────────
echo "  Skill lifecycle — create + remove"
# ────────────────────────────────────────

skill_create "lifecycle-test" > /dev/null 2>&1
_test "skill created" test -d "${SKILLS_DIR}/lifecycle-test"
_test_file_exists "skill.json exists" "${SKILLS_DIR}/lifecycle-test/skill.json"
_test_file_exists "run.sh exists" "${SKILLS_DIR}/lifecycle-test/run.sh"

skill_remove "lifecycle-test" > /dev/null 2>&1
_test "skill removed" test ! -d "${SKILLS_DIR}/lifecycle-test"

# ────────────────────────────────────────
echo ""
echo "  Skill lifecycle — enable/disable"
# ────────────────────────────────────────

skill_create "toggle-test" > /dev/null 2>&1

# Initially not enabled
_test "skill starts as not enabled" test ! -f "${SKILLS_DIR}/toggle-test/.enabled"

# Enable
skill_enable "toggle-test" > /dev/null 2>&1
_test_file_exists "enabled file created" "${SKILLS_DIR}/toggle-test/.enabled"

# Disable
skill_disable "toggle-test" > /dev/null 2>&1
_test "enabled file removed on disable" test ! -f "${SKILLS_DIR}/toggle-test/.enabled"

# ────────────────────────────────────────
echo ""
echo "  Skill lifecycle — hook matching"
# ────────────────────────────────────────

# Create skill with specific hooks
mkdir -p "${SKILLS_DIR}/hook-test"
cat > "${SKILLS_DIR}/hook-test/skill.json" << 'EOF'
{"name":"hook-test","version":"1.0.0","hooks":["post-deploy"]}
EOF
cat > "${SKILLS_DIR}/hook-test/run.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "HOOK_FIRED=${MUSTER_HOOK}"
SCRIPT
chmod +x "${SKILLS_DIR}/hook-test/run.sh"
touch "${SKILLS_DIR}/hook-test/.enabled"

# Should fire on post-deploy
_output=$(run_skill_hooks "post-deploy" "api" 2>/dev/null)
_test_contains "fires on matching hook" "HOOK_FIRED=post-deploy" "$_output"

# Should NOT fire on post-rollback
_output=$(run_skill_hooks "post-rollback" "api" 2>/dev/null)
_test_not_contains "skips non-matching hook" "HOOK_FIRED" "$_output"

# ────────────────────────────────────────
echo ""
echo "  Skill lifecycle — disabled skill does not fire"
# ────────────────────────────────────────

skill_disable "hook-test" > /dev/null 2>&1
_output=$(run_skill_hooks "post-deploy" "api" 2>/dev/null)
_test_not_contains "disabled skill does not fire" "HOOK_FIRED" "$_output"

# Re-enable for cleanup
skill_enable "hook-test" > /dev/null 2>&1

# ────────────────────────────────────────
echo ""
echo "  Skill lifecycle — error handling"
# ────────────────────────────────────────

# Remove nonexistent skill (uses exit 1, so run in subshell)
_rc=0
( skill_remove "nonexistent-skill" ) > /dev/null 2>&1 || _rc=$?
_test "removing nonexistent skill returns error" test "$_rc" -ne 0

# Enable nonexistent skill
_rc=0
skill_enable "nonexistent-skill" > /dev/null 2>&1 || _rc=$?
_test "enabling nonexistent skill returns error" test "$_rc" -ne 0

# Create with empty name should fail (uses exit 1, so run in subshell)
_rc=0
( skill_create "" ) > /dev/null 2>&1 || _rc=$?
_test "empty skill name rejected" test "$_rc" -ne 0

# ────────────────────────────────────────
echo ""
echo "  Skill lifecycle — non-fatal execution"
# ────────────────────────────────────────

# Skill that exits non-zero should not crash the hook runner
mkdir -p "${SKILLS_DIR}/failing-skill"
cat > "${SKILLS_DIR}/failing-skill/skill.json" << 'EOF'
{"name":"failing-skill","version":"1.0.0","hooks":["post-deploy"]}
EOF
cat > "${SKILLS_DIR}/failing-skill/run.sh" << 'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
chmod +x "${SKILLS_DIR}/failing-skill/run.sh"
touch "${SKILLS_DIR}/failing-skill/.enabled"

# Run should not crash — hook-test should still fire after failing-skill
_rc=0
_output=$(run_skill_hooks "post-deploy" "api" 2>/dev/null) || _rc=$?
_test_contains "healthy skill still fires after failing skill" "HOOK_FIRED=post-deploy" "$_output"

_test_summary
