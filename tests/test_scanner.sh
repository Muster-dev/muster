#!/usr/bin/env bash
# tests/test_scanner.sh — Tests for project scanner detection
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"
source "$MUSTER_ROOT/lib/core/scanner.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Helper: extract filenames from _SCAN_FILES array ("filename|description" entries)
_scan_file_names() {
  local entry
  for entry in "${_SCAN_FILES[@]}"; do
    echo "${entry%%|*}"
  done
}

# ────────────────────────────────────────
echo "  Scanner — Docker detection"
# ────────────────────────────────────────

PROJ="${TMPDIR}/docker-project"
mkdir -p "$PROJ"
echo "FROM node:18" > "${PROJ}/Dockerfile"
echo '{"scripts":{"start":"node index.js"}}' > "${PROJ}/package.json"

scan_project "$PROJ" 2>/dev/null
_files=$(_scan_file_names)
_test_contains "detects Dockerfile" "Dockerfile" "$_files"

# ────────────────────────────────────────
echo ""
echo "  Scanner — docker-compose detection"
# ────────────────────────────────────────

PROJ="${TMPDIR}/compose-project"
mkdir -p "$PROJ"
cat > "${PROJ}/docker-compose.yml" << 'EOF'
version: '3'
services:
  api:
    build: .
  redis:
    image: redis:7
EOF

scan_project "$PROJ" 2>/dev/null
_files=$(_scan_file_names)
_test_contains "detects docker-compose.yml" "docker-compose.yml" "$_files"

# ────────────────────────────────────────
echo ""
echo "  Scanner — k8s detection"
# ────────────────────────────────────────

PROJ="${TMPDIR}/k8s-project"
mkdir -p "${PROJ}/k8s"
cat > "${PROJ}/k8s/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
EOF

scan_project "$PROJ" 2>/dev/null
_files=$(_scan_file_names)
_test_contains "detects k8s manifests in subdirectory" "k8s/" "$_files"

# ────────────────────────────────────────
echo ""
echo "  Scanner — .musterignore"
# ────────────────────────────────────────

PROJ="${TMPDIR}/ignore-project"
mkdir -p "${PROJ}/archived" "${PROJ}/src"
echo "FROM node:18" > "${PROJ}/Dockerfile"
echo "old" > "${PROJ}/archived/Dockerfile.old"
echo "real" > "${PROJ}/src/app.js"
echo "archived/" > "${PROJ}/.musterignore"

scan_project "$PROJ" 2>/dev/null
_files=$(_scan_file_names)
_test_contains "includes non-ignored files" "Dockerfile" "$_files"

# ────────────────────────────────────────
echo ""
echo "  Scanner — infra service detection"
# ────────────────────────────────────────

# _is_infra_service is in templates.sh
source "$MUSTER_ROOT/lib/core/templates.sh"

_test "_is_infra_service detects redis" _is_infra_service "redis"
_test "_is_infra_service detects postgres" _is_infra_service "postgres"
_test "_is_infra_service detects mongodb" _is_infra_service "mongodb"
_test "_is_infra_service detects rabbitmq" _is_infra_service "rabbitmq"

# App services should not be infra
_is_infra=0
_is_infra_service "api" 2>/dev/null || _is_infra=$?
_test "api is not infra" test "$_is_infra" -ne 0

_test_summary
