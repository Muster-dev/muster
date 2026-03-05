#!/usr/bin/env bash
# tests/test_fleet_config.sh — Tests for fleet directory-based config
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

FLEETS_BASE_DIR="${TMPDIR}/fleets"
mkdir -p "$FLEETS_BASE_DIR"

source "$MUSTER_ROOT/lib/core/fleet_config.sh"

# Override after sourcing (source sets FLEETS_BASE_DIR from $HOME)
FLEETS_BASE_DIR="${TMPDIR}/fleets"

# ────────────────────────────────────────
echo "  Fleet config — directory structure"
# ────────────────────────────────────────

# Create fleet
fleet_cfg_create "production" 2>/dev/null || true
_test_file_exists "fleet dir created" "${FLEETS_BASE_DIR}/production/fleet.json"

# Create group
fleet_cfg_group_create "production" "web" 2>/dev/null || true
_test "group dir exists" test -d "${FLEETS_BASE_DIR}/production/web"

# Create project/machine
fleet_cfg_project_create "production" "web" "prod-1" '{}' 2>/dev/null || true
_test_file_exists "project.json created" "${FLEETS_BASE_DIR}/production/web/prod-1/project.json"

# ────────────────────────────────────────
echo ""
echo "  Fleet config — read/write"
# ────────────────────────────────────────

# Write machine config
cat > "${FLEETS_BASE_DIR}/production/web/prod-1/project.json" << 'EOF'
{
  "name": "prod-1",
  "machine": {
    "host": "10.0.1.10",
    "user": "deploy",
    "port": 22,
    "transport": "ssh"
  },
  "hook_mode": "manual",
  "remote_path": "/opt/myapp",
  "services": ["api"],
  "deploy_order": ["api"]
}
EOF

# Read back using fleet_cfg_project_load (|| true for jq pipefail on empty arrays)
fleet_cfg_project_load "production" "web" "prod-1" 2>/dev/null || true
_test_eq "read host from project.json" "10.0.1.10" "$_FP_HOST"
_test_eq "read user from project.json" "deploy" "$_FP_USER"
_test_eq "read port from project.json" "22" "$_FP_PORT"
_test_eq "read hook_mode from project.json" "manual" "$_FP_HOOK_MODE"

# ────────────────────────────────────────
echo ""
echo "  Fleet config — listing"
# ────────────────────────────────────────

# Add another machine
fleet_cfg_project_create "production" "web" "prod-2" '{}' 2>/dev/null || true
cat > "${FLEETS_BASE_DIR}/production/web/prod-2/project.json" << 'EOF'
{"name": "prod-2", "machine": {"host": "10.0.1.11", "user": "deploy", "port": 22, "transport": "ssh"}, "hook_mode": "manual", "services": [], "deploy_order": []}
EOF

# List fleets
_fleets=$(fleets_list 2>/dev/null)
_test_contains "list fleets includes production" "production" "$_fleets"

# List groups
_groups=$(fleet_cfg_groups "production" 2>/dev/null)
_test_contains "list groups includes web" "web" "$_groups"

# List projects/machines
_machines=$(fleet_cfg_group_projects "production" "web" 2>/dev/null)
_test_contains "list machines includes prod-1" "prod-1" "$_machines"
_test_contains "list machines includes prod-2" "prod-2" "$_machines"

# ────────────────────────────────────────
echo ""
echo "  Fleet config — deletion"
# ────────────────────────────────────────

fleet_cfg_project_delete "production" "web" "prod-2" 2>/dev/null || true
_test "prod-2 removed" test ! -d "${FLEETS_BASE_DIR}/production/web/prod-2"

_machines=$(fleet_cfg_group_projects "production" "web" 2>/dev/null)
_test_not_contains "prod-2 gone from listing" "prod-2" "$_machines"
_test_contains "prod-1 still exists" "prod-1" "$_machines"

# ────────────────────────────────────────
echo ""
echo "  Fleet config — multiple fleets"
# ────────────────────────────────────────

fleet_cfg_create "staging" 2>/dev/null || true
_test_file_exists "staging fleet created" "${FLEETS_BASE_DIR}/staging/fleet.json"

_fleets=$(fleets_list 2>/dev/null)
_test_contains "list fleets includes staging" "staging" "$_fleets"
_test_contains "list fleets still includes production" "production" "$_fleets"

_test_summary
