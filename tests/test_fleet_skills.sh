#!/usr/bin/env bash
# tests/test_fleet_skills.sh — Tests for fleet skill hooks system
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

# Minimal stubs
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

# Source the skills manager
source "$MUSTER_ROOT/lib/skills/manager.sh"

# Override after sourcing (source sets these from $HOME)
SKILLS_DIR="${TMPDIR}/skills"
GLOBAL_SKILLS_DIR="${TMPDIR}/skills"
FLEETS_BASE_DIR="${TMPDIR}/fleets"

# ────────────────────────────────────────
echo "  Fleet skill hooks — skill resolution"
# ────────────────────────────────────────

# Create a test skill
mkdir -p "${SKILLS_DIR}/test-notifier"
cat > "${SKILLS_DIR}/test-notifier/skill.json" << 'EOF'
{
  "name": "test-notifier",
  "version": "1.0.0",
  "description": "Test skill",
  "hooks": ["post-deploy", "fleet-deploy-end", "fleet-machine-deploy-end"]
}
EOF

cat > "${SKILLS_DIR}/test-notifier/run.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "HOOK=${MUSTER_HOOK}"
echo "STATUS=${MUSTER_DEPLOY_STATUS}"
echo "SERVICE=${MUSTER_SERVICE}"
echo "FLEET=${MUSTER_FLEET_NAME}"
echo "MACHINE=${MUSTER_FLEET_MACHINE}"
echo "HOST=${MUSTER_FLEET_HOST}"
echo "STRATEGY=${MUSTER_FLEET_STRATEGY}"
echo "MODE=${MUSTER_FLEET_MODE}"
SCRIPT
chmod +x "${SKILLS_DIR}/test-notifier/run.sh"

# Enable the skill (uses .enabled, not enabled)
touch "${SKILLS_DIR}/test-notifier/.enabled"

# Test: run_skill_hooks with fleet env vars
export MUSTER_FLEET_NAME="production"
export MUSTER_FLEET_MACHINE="web-1"
export MUSTER_FLEET_HOST="deploy@10.0.1.10"
export MUSTER_FLEET_STRATEGY="sequential"
export MUSTER_FLEET_MODE="muster"
export MUSTER_DEPLOY_STATUS="ok"

_output=$(run_skill_hooks "fleet-deploy-end" "" 2>/dev/null)
_test_contains "fleet-deploy-end hook fires" "HOOK=fleet-deploy-end" "$_output"
_test_contains "fleet name propagates" "FLEET=production" "$_output"
_test_contains "deploy status propagates" "STATUS=ok" "$_output"
_test_contains "strategy propagates" "STRATEGY=sequential" "$_output"

# Test: per-machine hook
_output=$(run_skill_hooks "fleet-machine-deploy-end" "" 2>/dev/null)
_test_contains "fleet-machine-deploy-end hook fires" "HOOK=fleet-machine-deploy-end" "$_output"
_test_contains "machine name propagates" "MACHINE=web-1" "$_output"
_test_contains "host propagates" "HOST=deploy@10.0.1.10" "$_output"
_test_contains "mode propagates" "MODE=muster" "$_output"

# Clean up fleet env
unset MUSTER_FLEET_NAME MUSTER_FLEET_MACHINE MUSTER_FLEET_HOST \
      MUSTER_FLEET_STRATEGY MUSTER_FLEET_MODE MUSTER_DEPLOY_STATUS

# ────────────────────────────────────────
echo ""
echo "  Fleet skill hooks — fleet scoping"
# ────────────────────────────────────────

# Create a fleet with skills.json that only enables test-notifier
mkdir -p "${FLEETS_BASE_DIR}/staging"
cat > "${FLEETS_BASE_DIR}/staging/skills.json" << 'EOF'
{
  "enabled": ["test-notifier"],
  "config": {}
}
EOF

# Create a second skill that is NOT in the staging fleet's enabled list
mkdir -p "${SKILLS_DIR}/other-skill"
cat > "${SKILLS_DIR}/other-skill/skill.json" << 'EOF'
{
  "name": "other-skill",
  "version": "1.0.0",
  "description": "Should not fire for staging fleet",
  "hooks": ["fleet-deploy-end"]
}
EOF
cat > "${SKILLS_DIR}/other-skill/run.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "OTHER_FIRED=yes"
SCRIPT
chmod +x "${SKILLS_DIR}/other-skill/run.sh"
touch "${SKILLS_DIR}/other-skill/.enabled"

# Test: fleet-scoped skills only fire enabled ones
export MUSTER_FLEET_NAME="staging"
export MUSTER_DEPLOY_STATUS="ok"

_output=$(run_fleet_skill_hooks "fleet-deploy-end" "" "staging" 2>/dev/null)
_test_contains "enabled skill fires for fleet" "HOOK=fleet-deploy-end" "$_output"
_test_not_contains "disabled skill blocked by fleet scoping" "OTHER_FIRED=yes" "$_output"

unset MUSTER_FLEET_NAME MUSTER_DEPLOY_STATUS

# Test: without skills.json, all enabled skills fire (fallback)
_output=$(run_fleet_skill_hooks "fleet-deploy-end" "" "nonexistent-fleet" 2>/dev/null)
_test_contains "all skills fire when no skills.json" "HOOK=fleet-deploy-end" "$_output"
_test_contains "other skill fires without fleet scoping" "OTHER_FIRED=yes" "$_output"

# ────────────────────────────────────────
echo ""
echo "  Fleet skill hooks — config overlay"
# ────────────────────────────────────────

# Create fleet with config overrides
mkdir -p "${FLEETS_BASE_DIR}/production"
cat > "${FLEETS_BASE_DIR}/production/skills.json" << 'EOF'
{
  "enabled": ["test-notifier"],
  "config": {
    "test-notifier": {
      "CUSTOM_WEBHOOK": "https://prod.example.com/hook",
      "CUSTOM_CHANNEL": "prod-deploys"
    }
  }
}
EOF

# Update test skill to echo custom config
cat > "${SKILLS_DIR}/test-notifier/run.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "HOOK=${MUSTER_HOOK}"
echo "WEBHOOK=${CUSTOM_WEBHOOK:-unset}"
echo "CHANNEL=${CUSTOM_CHANNEL:-unset}"
SCRIPT
chmod +x "${SKILLS_DIR}/test-notifier/run.sh"

export MUSTER_FLEET_NAME="production"
export MUSTER_DEPLOY_STATUS="ok"

_output=$(run_fleet_skill_hooks "fleet-deploy-end" "" "production" 2>/dev/null)
_test_contains "fleet config overlay injects CUSTOM_WEBHOOK" "WEBHOOK=https://prod.example.com/hook" "$_output"
_test_contains "fleet config overlay injects CUSTOM_CHANNEL" "CHANNEL=prod-deploys" "$_output"

unset MUSTER_FLEET_NAME MUSTER_DEPLOY_STATUS

# Test: config overlay cleaned up after execution
_test_eq "CUSTOM_WEBHOOK unset after skill runs" "" "${CUSTOM_WEBHOOK:-}"
_test_eq "CUSTOM_CHANNEL unset after skill runs" "" "${CUSTOM_CHANNEL:-}"

# ────────────────────────────────────────
echo ""
echo "  Fleet skill hooks — hook name matching"
# ────────────────────────────────────────

# Skill only declares fleet-deploy-end, should NOT fire on fleet-deploy-start
cat > "${SKILLS_DIR}/test-notifier/skill.json" << 'EOF'
{
  "name": "test-notifier",
  "version": "1.0.0",
  "hooks": ["fleet-deploy-end"]
}
EOF

cat > "${SKILLS_DIR}/test-notifier/run.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "FIRED=yes"
SCRIPT
chmod +x "${SKILLS_DIR}/test-notifier/run.sh"

_output=$(run_skill_hooks "fleet-deploy-end" "" 2>/dev/null)
_test_contains "skill fires on declared hook" "FIRED=yes" "$_output"

_output=$(run_skill_hooks "fleet-deploy-start" "" 2>/dev/null)
_test_not_contains "skill does NOT fire on undeclared hook" "FIRED=yes" "$_output"

_output=$(run_skill_hooks "post-deploy" "" 2>/dev/null)
_test_not_contains "skill does NOT fire on post-deploy if not declared" "FIRED=yes" "$_output"

# ────────────────────────────────────────
echo ""
echo "  Fleet skill hooks — env var isolation"
# ────────────────────────────────────────

# Verify fleet env vars from one call don't leak to next
export MUSTER_FLEET_NAME="fleet-a"
export MUSTER_FLEET_MACHINE="machine-a"
run_fleet_skill_hooks "fleet-deploy-end" "" "production" > /dev/null 2>&1

# After run_fleet_skill_hooks, the _FLEET_SKILLS_JSON should be cleared
_test_eq "_FLEET_SKILLS_JSON cleared after run" "" "${_FLEET_SKILLS_JSON:-}"

unset MUSTER_FLEET_NAME MUSTER_FLEET_MACHINE

_test_summary
