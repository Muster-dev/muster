#!/usr/bin/env bash
# tests/test_config.sh — Tests for config loading and utilities
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

# Minimal color stubs (no TTY in tests)
GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"

TMPDIR=$(mktemp -d)
export HOME="${TMPDIR}/home"
mkdir -p "$HOME"
trap 'rm -rf "$TMPDIR"' EXIT

echo "  Config loading"

# Create a test deploy.json
cat > "${TMPDIR}/deploy.json" << 'EOF'
{
  "project": "test-app",
  "version": "1",
  "services": {
    "api": {
      "name": "API Server",
      "skip_deploy": false,
      "health": { "type": "http", "port": 8080, "endpoint": "/health" },
      "k8s": { "deployment": "test-api", "namespace": "production" },
      "deploy_timeout": 300,
      "deploy_mode": "update"
    },
    "redis": {
      "name": "Redis",
      "skip_deploy": false,
      "health": { "type": "tcp", "port": 6379 },
      "k8s": { "deployment": "test-redis", "namespace": "production" }
    },
    "my-svc": {
      "name": "My Service",
      "skip_deploy": false
    }
  },
  "deploy_order": ["redis", "api"]
}
EOF

CONFIG_FILE="${TMPDIR}/deploy.json"

# Test config_get
_proj=$(config_get '.project')
_test_eq "config_get reads project name" "test-app" "$_proj"

_ver=$(config_get '.version')
_test_eq "config_get reads version" "1" "$_ver"

# Test config_get nested
_health_type=$(config_get '.services.api.health.type')
_test_eq "config_get reads nested value" "http" "$_health_type"

# Test config_services
_svcs=$(config_services)
_test_contains "config_services lists api" "api" "$_svcs"
_test_contains "config_services lists redis" "redis" "$_svcs"

# Test _jq_quote for hyphenated keys
_quoted=$(_jq_quote ".services.my-svc.name")
_test_eq "_jq_quote wraps hyphenated segment" '.services["my-svc"].name' "$_quoted"

_plain=$(_jq_quote ".services.api.name")
_test_eq "_jq_quote passes simple segments unchanged" ".services.api.name" "$_plain"

# Test config_get with hyphenated key via config_get, numeric, and boolean
_hyph_name=$(config_get '.services.my-svc.name')
_test_eq "config_get reads hyphenated service key" "My Service" "$_hyph_name"

_multi_hyph=$(_jq_quote ".services.my-cool-svc.health.enabled")
_test_eq "_jq_quote handles multiple hyphens" '.services["my-cool-svc"].health.enabled' "$_multi_hyph"

_port=$(config_get '.services.api.health.port')
_test_eq "config_get reads numeric value" "8080" "$_port"

_skip=$(config_get '.services.api.skip_deploy')
_test_eq "config_get reads boolean value" "false" "$_skip"

_test_contains "config_services lists hyphenated my-svc" "my-svc" "$_svcs"

echo ""
echo "  k8s_env_for_service"

_k8s_api=$(k8s_env_for_service "api")
_test_contains "k8s_env exports deployment" "MUSTER_K8S_DEPLOYMENT=test-api" "$_k8s_api"
_test_contains "k8s_env exports namespace" "MUSTER_K8S_NAMESPACE=production" "$_k8s_api"
_test_contains "k8s_env exports service" "MUSTER_K8S_SERVICE=api" "$_k8s_api"
_test_contains "k8s_env exports deploy_timeout when set" "MUSTER_DEPLOY_TIMEOUT=300" "$_k8s_api"
_test_contains "k8s_env exports deploy_mode when set" "MUSTER_DEPLOY_MODE=update" "$_k8s_api"

_k8s_redis=$(k8s_env_for_service "redis")
_test_not_contains "k8s_env omits deploy_timeout when unset" "MUSTER_DEPLOY_TIMEOUT" "$_k8s_redis"

_k8s_none=$(k8s_env_for_service "my-svc")
_test_eq "k8s_env empty when no k8s config" "" "$_k8s_none"

echo ""
echo "  Missing config"

# Test missing config file
CONFIG_FILE="${TMPDIR}/nonexistent.json"
_missing=$(config_get '.project' 2>/dev/null || echo "FAIL")
_test_eq "config_get returns empty for missing file" "FAIL" "$_missing"

_test_summary
