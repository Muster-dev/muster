#!/usr/bin/env bash
# tests/test_scanner.sh — Tests for project scanner detection
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

TMPDIR=$(mktemp -d)
export HOME="${TMPDIR}/home"
mkdir -p "$HOME"
trap 'rm -rf "$TMPDIR"' EXIT

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"
source "$MUSTER_ROOT/lib/core/scanner.sh"

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

# ────────────────────────────────────────
echo ""
echo "  Scanner — flow-style compose ports & health inference"
# ────────────────────────────────────────

PROJ="${TMPDIR}/flow-compose"
mkdir -p "${PROJ}/api" "${PROJ}/web"
cat > "${PROJ}/docker-compose.yml" << 'EOF'
services:
  api: { build: ./api, ports: ["8080:8080"] }
  web: { build: ./web, ports: ["3000:3000"] }
  redis: { image: "redis:7", ports: ["6379:6379"] }
EOF
printf 'FROM node:20\nEXPOSE 8080\n' > "${PROJ}/api/Dockerfile"
printf 'FROM node:20\nEXPOSE 3000\n' > "${PROJ}/web/Dockerfile"
printf '{"name":"web","dependencies":{"express":"^4.18.0"}}\n' > "${PROJ}/web/package.json"

scan_project "$PROJ" 2>/dev/null
_test_eq "flow compose detects api port 8080" "8080" "$(scan_get_port api)"
_test_eq "flow compose detects web port 3000" "3000" "$(scan_get_port web)"
_test_eq "flow compose detects redis port 6379" "6379" "$(scan_get_port redis)"
_test_eq "flow compose infers tcp health for api" "tcp||8080" "$(scan_infer_health api)"
_test_eq "flow compose infers tcp health for web" "tcp||3000" "$(scan_infer_health web)"
_test_eq "flow compose infers tcp health for redis" "tcp||6379" "$(scan_infer_health redis)"

# ────────────────────────────────────────
echo ""
echo "  Scanner — block compose, healthcheck, Dockerfile EXPOSE, infra defaults"
# ────────────────────────────────────────

PROJ="${TMPDIR}/block-compose"
mkdir -p "${PROJ}/svc_df" "${PROJ}/worker"
cat > "${PROJ}/docker-compose.yml" << 'EOF'
services:
  api:
    build: .
    ports:
      - "8081:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
  svc_df:
    build: ./svc_df
  postgres:
    image: postgres:16
  mysql:
    image: mysql:8
  mongo:
    image: mongo:7
  rabbitmq:
    image: rabbitmq:3
  worker:
    build: ./worker
EOF
printf 'FROM alpine\nEXPOSE 4000/tcp\n' > "${PROJ}/svc_df/Dockerfile"
printf 'FROM alpine\n' > "${PROJ}/worker/Dockerfile"

scan_project "$PROJ" 2>/dev/null
_test_eq "block compose extracts host port 8081" "8081" "$(scan_get_port api)"
_test_eq "compose healthcheck infers http /health" "http|/health|8080" "$(scan_infer_health api)"
_test_eq "Dockerfile EXPOSE infers tcp port 4000" "tcp||4000" "$(scan_infer_health svc_df)"
_test_eq "infra default infers postgres 5432" "tcp||5432" "$(scan_infer_health postgres)"
_test_eq "infra default infers mysql 3306" "tcp||3306" "$(scan_infer_health mysql)"
_test_eq "infra default infers mongo 27017" "tcp||27017" "$(scan_infer_health mongo)"
_test_eq "infra default infers rabbitmq 5672" "tcp||5672" "$(scan_infer_health rabbitmq)"
_test_eq "unknown port leaves health empty" "" "$(scan_infer_health worker)"

# ────────────────────────────────────────
echo ""
echo "  Scanner — k8s manifest containerPort & httpGet probe"
# ────────────────────────────────────────

PROJ="${TMPDIR}/k8s-ports"
mkdir -p "${PROJ}/k8s/api" "${PROJ}/k8s/web"
cat > "${PROJ}/k8s/api/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  template:
    spec:
      containers:
        - name: api
          ports:
            - containerPort: 9000
          readinessProbe:
            httpGet:
              path: /healthz
              port: 9000
EOF
cat > "${PROJ}/k8s/web/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  template:
    spec:
      containers:
        - name: web
          ports:
            - containerPort: 3000
EOF

scan_project "$PROJ" 2>/dev/null
_test_eq "k8s manifest httpGet probe infers http" "http|/healthz|9000" "$(scan_infer_health api)"
_test_eq "k8s manifest containerPort infers tcp" "tcp||3000" "$(scan_infer_health web)"

_test_summary
