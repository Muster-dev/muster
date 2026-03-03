#!/usr/bin/env bash
# muster/lib/core/config.sh — Read and write deploy.json + global settings

CONFIG_FILE=""

# ── Global settings (~/.muster/settings.json) ──

GLOBAL_CONFIG_DIR="$HOME/.muster"
GLOBAL_CONFIG_FILE="$HOME/.muster/settings.json"

_GLOBAL_DEFAULTS='{
  "color_mode": "auto",
  "log_color_mode": "auto",
  "log_retention_days": 7,
  "default_stack": "bare",
  "default_health_timeout": 10,
  "scanner_exclude": [],
  "update_check": "on"
}'

# Ensure global config exists with defaults
_ensure_global_config() {
  if [[ ! -d "$GLOBAL_CONFIG_DIR" ]]; then
    mkdir -p "$GLOBAL_CONFIG_DIR"
  fi
  if [[ ! -f "$GLOBAL_CONFIG_FILE" ]]; then
    printf '%s\n' "$_GLOBAL_DEFAULTS" > "$GLOBAL_CONFIG_FILE"
  fi
}

# Read a value from global settings
# Usage: global_config_get "color_mode"
global_config_get() {
  local key="$1"
  _ensure_global_config
  if has_cmd jq; then
    jq -r "$(_jq_quote ".$key")" "$GLOBAL_CONFIG_FILE"
  elif has_cmd python3; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
val = data.get(sys.argv[2], '')
if isinstance(val, list):
    print(json.dumps(val))
elif isinstance(val, str):
    print(val)
else:
    print(val)
" "$GLOBAL_CONFIG_FILE" "$key"
  else
    err "jq or python3 required to read global config"
    return 1
  fi
}

# Set a value in global settings (requires jq)
# Usage: global_config_set "color_mode" '"never"'   (string values need inner quotes)
#        global_config_set "log_retention_days" '14'  (numbers are bare)
global_config_set() {
  local key="$1" value="$2"
  _ensure_global_config
  if has_cmd jq; then
    local tmp="${GLOBAL_CONFIG_FILE}.tmp"
    jq "$(_jq_quote ".$key") = $value" "$GLOBAL_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GLOBAL_CONFIG_FILE"
  else
    err "jq required to modify global config"
    return 1
  fi
}

# Get all global settings as JSON
global_config_dump() {
  _ensure_global_config
  if has_cmd jq; then
    jq '.' "$GLOBAL_CONFIG_FILE"
  elif has_cmd python3; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    print(json.dumps(json.load(f), indent=2))
" "$GLOBAL_CONFIG_FILE"
  else
    cat "$GLOBAL_CONFIG_FILE"
  fi
}

# Load config from muster.json (or deploy.json fallback)
load_config() {
  CONFIG_FILE=$(find_config) || {
    err "No muster.json found. Run 'muster setup' first."
    exit 1
  }
  # Auto-register project in the global registry
  _registry_touch "$(dirname "$CONFIG_FILE")"
}

# Quote path segments containing hyphens for jq
# .services.my-svc.name → .services["my-svc"].name
_jq_quote() {
  printf '%s' "$1" | sed -E 's/\.([a-zA-Z0-9_]*-[a-zA-Z0-9_-]*)/["\1"]/g'
}

# Read a value from deploy.json using jq or python fallback
config_get() {
  local query="$1"
  if has_cmd jq; then
    jq -r "$(_jq_quote "$query")" "$CONFIG_FILE"
  elif has_cmd python3; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
keys = sys.argv[2].strip('.').split('.')
for k in keys:
    if k: data = data.get(k, '')
print(data if isinstance(data, str) else json.dumps(data))
" "$CONFIG_FILE" "$query"
  else
    err "jq or python3 required to read config"
    exit 1
  fi
}

# List service names from deploy.json
config_services() {
  if has_cmd jq; then
    jq -r '.services | keys[]' "$CONFIG_FILE"
  elif has_cmd python3; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for k in data.get('services', {}):
    print(k)
" "$CONFIG_FILE"
  else
    err "jq or python3 required to read config"
    return 1
  fi
}

# Write deploy.json from stdin
config_write() {
  local target="$1"
  cat > "$target"
}

# Set a value in deploy.json (requires jq)
config_set() {
  local path value="$2"
  path=$(_jq_quote "$1")
  if has_cmd jq; then
    local tmp="${CONFIG_FILE}.tmp"
    jq "$path = $value" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  else
    err "jq required to modify config"
    return 1
  fi
}

# Return k8s env vars for a service (from deploy.json .services.<svc>.k8s)
# Outputs MUSTER_K8S_DEPLOYMENT=name, MUSTER_K8S_NAMESPACE=ns, MUSTER_K8S_SERVICE=svc
# Usage: k8s_env_for_service "api"
k8s_env_for_service() {
  local svc="$1"
  local deployment namespace
  deployment=$(config_get ".services.${svc}.k8s.deployment")
  namespace=$(config_get ".services.${svc}.k8s.namespace")
  [[ "$deployment" == "null" || -z "$deployment" ]] && return
  [[ "$namespace" == "null" || -z "$namespace" ]] && namespace="default"
  echo "MUSTER_K8S_DEPLOYMENT=${deployment}"
  echo "MUSTER_K8S_NAMESPACE=${namespace}"
  # K8s names use hyphens, not underscores
  local _k8s_svc="${svc//_/-}"
  echo "MUSTER_K8S_SERVICE=${_k8s_svc}"
  local deploy_timeout
  deploy_timeout=$(config_get ".services.${svc}.deploy_timeout")
  if [[ -n "$deploy_timeout" && "$deploy_timeout" != "null" ]]; then
    echo "MUSTER_DEPLOY_TIMEOUT=${deploy_timeout}"
  fi
  local deploy_mode
  deploy_mode=$(config_get ".services.${svc}.deploy_mode")
  if [[ -n "$deploy_mode" && "$deploy_mode" != "null" ]]; then
    echo "MUSTER_DEPLOY_MODE=${deploy_mode}"
  fi
}
