#!/usr/bin/env bash
# tests/test_skill_templates.sh — Tests for built-in skill templates
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
echo "  Skill templates — creation from built-in"
# ────────────────────────────────────────

# Test: muster skill create discord copies from template
skill_create "discord" > /dev/null 2>&1
_test_file_exists "discord skill.json created" "${SKILLS_DIR}/discord/skill.json"
_test_file_exists "discord run.sh created" "${SKILLS_DIR}/discord/run.sh"
_test "discord run.sh is executable" test -x "${SKILLS_DIR}/discord/run.sh"

# Verify it came from the template (not blank stub)
_hooks=$(cat "${SKILLS_DIR}/discord/skill.json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('hooks',[])))" 2>/dev/null || echo "0")
_test "discord template has fleet hooks" test "$_hooks" -gt 2

_version=$(cat "${SKILLS_DIR}/discord/skill.json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
_test_eq "discord template version is 2.0.0" "2.0.0" "$_version"

# Test: muster skill create slack copies from template
skill_create "slack" > /dev/null 2>&1
_test_file_exists "slack skill.json created" "${SKILLS_DIR}/slack/skill.json"
_test "slack run.sh is executable" test -x "${SKILLS_DIR}/slack/run.sh"

# Verify slack uses Block Kit (not legacy attachments)
_has_blocks=$(grep -c "blocks" "${SKILLS_DIR}/slack/run.sh" 2>/dev/null || echo "0")
_test "slack uses Block Kit" test "$_has_blocks" -gt 0

# Test: muster skill create webhook copies from template
skill_create "webhook" > /dev/null 2>&1
_test_file_exists "webhook skill.json created" "${SKILLS_DIR}/webhook/skill.json"

# ────────────────────────────────────────
echo ""
echo "  Skill templates — blank scaffold fallback"
# ────────────────────────────────────────

# Creating a non-template skill should give blank stub
skill_create "my-custom-skill" > /dev/null 2>&1
_test_file_exists "custom skill.json created" "${SKILLS_DIR}/my-custom-skill/skill.json"

_desc=$(cat "${SKILLS_DIR}/my-custom-skill/skill.json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('description',''))" 2>/dev/null)
_test_eq "blank scaffold has TODO description" "TODO: describe your skill" "$_desc"

# ────────────────────────────────────────
echo ""
echo "  Skill templates — run.sh behavior"
# ────────────────────────────────────────

# Discord: exits 0 when no bot token
_rc=0
"${SKILLS_DIR}/discord/run.sh" > /dev/null 2>&1 || _rc=$?
_test_eq "discord exits 0 without config" "0" "$_rc"

# Slack: exits 0 when no webhook
_rc=0
"${SKILLS_DIR}/slack/run.sh" > /dev/null 2>&1 || _rc=$?
_test_eq "slack exits 0 without config" "0" "$_rc"

# Webhook: exits 0 when no URL
_rc=0
"${SKILLS_DIR}/webhook/run.sh" > /dev/null 2>&1 || _rc=$?
_test_eq "webhook exits 0 without config" "0" "$_rc"

# ────────────────────────────────────────
echo ""
echo "  Skill templates — duplicate prevention"
# ────────────────────────────────────────

_rc=0
skill_create "discord" > /dev/null 2>&1 || _rc=$?
_test "creating duplicate skill fails" test "$_rc" -ne 0

# ────────────────────────────────────────
echo ""
echo "  Skill templates — JSON validity"
# ────────────────────────────────────────

for skill in discord slack webhook my-custom-skill; do
  _valid=0
  python3 -c "import json; json.load(open('${SKILLS_DIR}/${skill}/skill.json'))" 2>/dev/null || _valid=1
  _test_eq "${skill}/skill.json is valid JSON" "0" "$_valid"
done

# ────────────────────────────────────────
echo ""
echo "  Skill templates — syntax check"
# ────────────────────────────────────────

for skill in discord slack webhook; do
  _valid=0
  bash -n "${SKILLS_DIR}/${skill}/run.sh" 2>/dev/null || _valid=1
  _test_eq "${skill}/run.sh passes bash -n" "0" "$_valid"
done

_test_summary
