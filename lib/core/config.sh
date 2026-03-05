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
  "update_check": "on",
  "update_mode": "release",
  "cloud": {},
  "machine_role": "",
  "minimal": false,
  "deploy_password_hash": "",
  "signing": "off"
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

# ── Config validation ──

_CONFIG_VALIDATED=""

# Validate deploy.json / muster.json structure and values.
# Errors (missing required fields) return 1; warnings print but continue.
# Only runs when jq is available — skips gracefully without it.
_config_validate() {
  # Skip if already validated for this config file
  [[ "$_CONFIG_VALIDATED" == "$CONFIG_FILE" ]] && return 0

  # Require jq for validation
  has_cmd jq || return 0

  local _v_errors=0
  local _v_val

  # ── Required fields ──

  _v_val=$(jq -r '.project // empty' "$CONFIG_FILE" 2>/dev/null)
  if [[ -z "$_v_val" ]]; then
    printf '%b\n' "  ${RED}x${RESET} Config error: missing \"project\" field in $(basename "$CONFIG_FILE")" >&2
    _v_errors=$(( _v_errors + 1 ))
  fi

  _v_val=$(jq -r '.services | type' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$_v_val" != "object" ]]; then
    printf '%b\n' "  ${RED}x${RESET} Config error: \"services\" must be an object in $(basename "$CONFIG_FILE")" >&2
    _v_errors=$(( _v_errors + 1 ))
  fi

  _v_val=$(jq -r '.deploy_order | type' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$_v_val" != "array" ]]; then
    printf '%b\n' "  ${RED}x${RESET} Config error: \"deploy_order\" must be an array in $(basename "$CONFIG_FILE")" >&2
    _v_errors=$(( _v_errors + 1 ))
  fi

  # Bail early if basic structure is broken — service checks would fail
  if (( _v_errors > 0 )); then
    return 1
  fi

  # ── deploy_order <-> services cross-check ──

  local _v_order_item
  while IFS= read -r _v_order_item; do
    [[ -z "$_v_order_item" ]] && continue
    _v_val=$(jq -r --arg s "$_v_order_item" '.services[$s] // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$_v_val" ]]; then
      printf '%b\n' "  ${RED}x${RESET} Config error: service \"${_v_order_item}\" in deploy_order not found in services" >&2
      _v_errors=$(( _v_errors + 1 ))
    fi
  done < <(jq -r '.deploy_order[]' "$CONFIG_FILE" 2>/dev/null)

  local _v_svc_key
  while IFS= read -r _v_svc_key; do
    [[ -z "$_v_svc_key" ]] && continue
    _v_val=$(jq -r --arg s "$_v_svc_key" '.deploy_order | index($s)' "$CONFIG_FILE" 2>/dev/null)
    if [[ "$_v_val" == "null" ]]; then
      printf '%b\n' "  ${YELLOW}!${RESET} Config warning: service \"${_v_svc_key}\" not in deploy_order" >&2
    fi
  done < <(jq -r '.services | keys[]' "$CONFIG_FILE" 2>/dev/null)

  # ── Per-service field validation ──

  local _v_health_type _v_health_port _v_health_timeout
  local _v_cred_mode
  local _v_k8s_deploy _v_k8s_ns
  local _v_remote_enabled _v_remote_host _v_remote_user

  while IFS= read -r _v_svc_key; do
    [[ -z "$_v_svc_key" ]] && continue

    # health.type
    _v_health_type=$(jq -r --arg s "$_v_svc_key" '.services[$s].health.type // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$_v_health_type" ]]; then
      case "$_v_health_type" in
        http|tcp|command) ;;
        *)
          printf '%b\n' "  ${RED}x${RESET} Config error: invalid health type \"${_v_health_type}\" for \"${_v_svc_key}\" (must be http, tcp, or command)" >&2
          _v_errors=$(( _v_errors + 1 ))
          ;;
      esac
    fi

    # health.port
    _v_health_port=$(jq -r --arg s "$_v_svc_key" '.services[$s].health.port // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$_v_health_port" ]]; then
      if ! [[ "$_v_health_port" =~ ^[0-9]+$ ]] || (( _v_health_port <= 0 )); then
        printf '%b\n' "  ${RED}x${RESET} Config error: health port must be a positive integer for \"${_v_svc_key}\" (got \"${_v_health_port}\")" >&2
        _v_errors=$(( _v_errors + 1 ))
      fi
    fi

    # health.timeout
    _v_health_timeout=$(jq -r --arg s "$_v_svc_key" '.services[$s].health.timeout // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$_v_health_timeout" ]]; then
      if ! [[ "$_v_health_timeout" =~ ^[0-9]+$ ]] || (( _v_health_timeout <= 0 )); then
        printf '%b\n' "  ${YELLOW}!${RESET} Config warning: health timeout ${_v_health_timeout} is too low for \"${_v_svc_key}\" (minimum 1)" >&2
      fi
    fi

    # credentials.mode
    _v_cred_mode=$(jq -r --arg s "$_v_svc_key" '.services[$s].credentials.mode // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$_v_cred_mode" ]]; then
      case "$_v_cred_mode" in
        off|save|session|always) ;;
        *)
          printf '%b\n' "  ${RED}x${RESET} Config error: invalid credentials mode \"${_v_cred_mode}\" for \"${_v_svc_key}\" (must be off, save, session, or always)" >&2
          _v_errors=$(( _v_errors + 1 ))
          ;;
      esac
    fi

    # k8s.deployment
    _v_k8s_deploy=$(jq -r --arg s "$_v_svc_key" '.services[$s].k8s.deployment // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$_v_k8s_deploy" ]]; then
      # present but empty string after jq resolves — already caught by // empty
      :
    fi
    # Check if k8s object exists but deployment is empty
    _v_val=$(jq -r --arg s "$_v_svc_key" '.services[$s].k8s | has("deployment")' "$CONFIG_FILE" 2>/dev/null)
    if [[ "$_v_val" == "true" && -z "$_v_k8s_deploy" ]]; then
      printf '%b\n' "  ${RED}x${RESET} Config error: k8s.deployment is empty for \"${_v_svc_key}\"" >&2
      _v_errors=$(( _v_errors + 1 ))
    fi

    # k8s.namespace
    _v_k8s_ns=$(jq -r --arg s "$_v_svc_key" '.services[$s].k8s.namespace // empty' "$CONFIG_FILE" 2>/dev/null)
    _v_val=$(jq -r --arg s "$_v_svc_key" '.services[$s].k8s | has("namespace")' "$CONFIG_FILE" 2>/dev/null)
    if [[ "$_v_val" == "true" && -z "$_v_k8s_ns" ]]; then
      printf '%b\n' "  ${RED}x${RESET} Config error: k8s.namespace is empty for \"${_v_svc_key}\"" >&2
      _v_errors=$(( _v_errors + 1 ))
    fi

    # remote.host + remote.user (required when remote.enabled is true)
    _v_remote_enabled=$(jq -r --arg s "$_v_svc_key" '.services[$s].remote.enabled // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ "$_v_remote_enabled" == "true" ]]; then
      _v_remote_host=$(jq -r --arg s "$_v_svc_key" '.services[$s].remote.host // empty' "$CONFIG_FILE" 2>/dev/null)
      if [[ -z "$_v_remote_host" ]]; then
        printf '%b\n' "  ${RED}x${RESET} Config error: remote.host is required when remote is enabled for \"${_v_svc_key}\"" >&2
        _v_errors=$(( _v_errors + 1 ))
      fi
      _v_remote_user=$(jq -r --arg s "$_v_svc_key" '.services[$s].remote.user // empty' "$CONFIG_FILE" 2>/dev/null)
      if [[ -z "$_v_remote_user" ]]; then
        printf '%b\n' "  ${RED}x${RESET} Config error: remote.user is required when remote is enabled for \"${_v_svc_key}\"" >&2
        _v_errors=$(( _v_errors + 1 ))
      fi
    fi

  done < <(jq -r '.services | keys[]' "$CONFIG_FILE" 2>/dev/null)

  if (( _v_errors > 0 )); then
    return 1
  fi

  # Mark as validated for this config file
  _CONFIG_VALIDATED="$CONFIG_FILE"
  return 0
}

# Load config from muster.json (or deploy.json fallback)
load_config() {
  CONFIG_FILE=$(find_config) || {
    err "No muster.json found. Run 'muster setup' first."
    exit 1
  }
  # Validate config structure on first load
  _config_validate || {
    err "Config validation failed. Fix the errors above and try again."
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

# List service names from deploy.json (validates keys against path traversal)
config_services() {
  local _raw_keys=""
  if has_cmd jq; then
    _raw_keys=$(jq -r '.services | keys[]' "$CONFIG_FILE")
  elif has_cmd python3; then
    _raw_keys=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for k in data.get('services', {}):
    print(k)
" "$CONFIG_FILE")
  else
    err "jq or python3 required to read config"
    return 1
  fi

  # Validate each key — skip dangerous ones
  local _key
  while IFS= read -r _key; do
    [[ -z "$_key" ]] && continue
    # Block path traversal
    case "$_key" in
      *..*|/*) continue ;;
    esac
    printf '%s\n' "$_key"
  done <<< "$_raw_keys"
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
