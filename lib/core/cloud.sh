#!/usr/bin/env bash
# muster/lib/core/cloud.sh — Cloud transport helpers (shells out to muster-tunnel)

if ! declare -f _cred_keychain_get >/dev/null 2>&1; then
  source "$MUSTER_ROOT/lib/core/credentials.sh"
fi

# ── Binary detection ──

_fleet_cloud_available() {
  command -v muster-tunnel &>/dev/null || {
    [[ -x "$HOME/.muster/bin/muster-tunnel" ]] && return 0
    return 1
  }
}

_fleet_cloud_bin() {
  if command -v muster-tunnel &>/dev/null; then
    printf 'muster-tunnel'
  else
    printf '%s/.muster/bin/muster-tunnel' "$HOME"
  fi
}

# ── Cloud config (from remotes.json .cloud section) ──

FLEET_CLOUD_RELAY=""
FLEET_CLOUD_ORG=""
FLEET_CLOUD_TOKEN=""

_fleet_cloud_config() {
  # Skip if already configured (allows callers to pre-populate from other sources)
  [[ -n "${FLEET_CLOUD_RELAY:-}" && -n "${FLEET_CLOUD_TOKEN:-}" ]] && return 0

  FLEET_CLOUD_RELAY=$(fleet_get '.cloud.relay // ""')
  FLEET_CLOUD_ORG=$(fleet_get '.cloud.org_id // ""')
  local token_ref
  token_ref=$(fleet_get '.cloud.token_ref // ""')
  if [[ -n "$token_ref" ]]; then
    FLEET_CLOUD_TOKEN=$(_fleet_cloud_token_get "$token_ref")
  fi

  # Fall back to the account from `muster cloud login`
  if [[ -z "$FLEET_CLOUD_RELAY" || -z "$FLEET_CLOUD_TOKEN" ]]; then
    local g_relay g_org g_ref
    g_relay=$(global_config_get "cloud.relay" 2>/dev/null)
    g_org=$(global_config_get "cloud.org_id" 2>/dev/null)
    g_ref=$(global_config_get "cloud.token_ref" 2>/dev/null)
    [[ -z "$FLEET_CLOUD_RELAY" && -n "$g_relay" && "$g_relay" != "null" ]] && FLEET_CLOUD_RELAY="$g_relay"
    [[ -z "$FLEET_CLOUD_ORG" && -n "$g_org" && "$g_org" != "null" ]] && FLEET_CLOUD_ORG="$g_org"
    if [[ -z "$FLEET_CLOUD_TOKEN" && -n "$g_ref" && "$g_ref" != "null" ]]; then
      FLEET_CLOUD_TOKEN=$(_fleet_cloud_token_get "$g_ref")
    fi
  fi
}

# ── Cloud token storage (~/.muster/cloud-tokens.json) ──

FLEET_CLOUD_TOKENS_FILE="$HOME/.muster/tokens/cloud.json"

_fleet_cloud_token_file() {
  if [[ ! -d "$HOME/.muster" ]]; then
    mkdir -p "$HOME/.muster"
    chmod 700 "$HOME/.muster"
  fi
  if [[ ! -d "$HOME/.muster/tokens" ]]; then
    mkdir -p "$HOME/.muster/tokens"
    chmod 700 "$HOME/.muster/tokens"
  fi
  # Migrate from old path
  if [[ -f "$HOME/.muster/cloud-tokens.json" && ! -f "$FLEET_CLOUD_TOKENS_FILE" ]]; then
    mv "$HOME/.muster/cloud-tokens.json" "$FLEET_CLOUD_TOKENS_FILE"
  fi
  if [[ ! -f "$FLEET_CLOUD_TOKENS_FILE" ]]; then
    printf '{"tokens":{}}\n' > "$FLEET_CLOUD_TOKENS_FILE"
  fi
  chmod 600 "$FLEET_CLOUD_TOKENS_FILE"
}

# Tokens live in the system keychain when one is available (macOS Keychain,
# secret-tool); the 0600 JSON file is the fallback for headless machines.
_fleet_cloud_keychain_ok() {
  [[ -z "${MUSTER_CLOUD_NO_KEYCHAIN:-}" ]] || return 1
  command -v security &>/dev/null || command -v secret-tool &>/dev/null
}

_fleet_cloud_token_get() {
  local name="$1"
  if _fleet_cloud_keychain_ok; then
    local kc
    kc=$(_cred_keychain_get "cloud" "token_${name}" 2>/dev/null) || kc=""
    if [[ -n "$kc" ]]; then
      printf '%s' "$kc"
      return 0
    fi
  fi
  _fleet_cloud_token_file
  local val
  val=$(jq -r --arg n "$name" '.tokens[$n] // ""' "$FLEET_CLOUD_TOKENS_FILE" 2>/dev/null)
  [[ -n "$val" && "$val" != "null" ]] && printf '%s' "$val"
}

_fleet_cloud_token_set() {
  local name="$1" token="$2"
  if _fleet_cloud_keychain_ok && _cred_keychain_save "cloud" "token_${name}" "$token"; then
    # Don't leave a plaintext copy behind
    _fleet_cloud_token_delete_file "$name"
    return 0
  fi
  _fleet_cloud_token_file
  local tmp="${FLEET_CLOUD_TOKENS_FILE}.tmp"
  jq --arg n "$name" --arg v "$token" '.tokens[$n] = $v' \
    "$FLEET_CLOUD_TOKENS_FILE" > "$tmp" && mv "$tmp" "$FLEET_CLOUD_TOKENS_FILE"
  chmod 600 "$FLEET_CLOUD_TOKENS_FILE"
}

_fleet_cloud_token_delete() {
  local name="$1"
  if _fleet_cloud_keychain_ok; then
    if command -v security &>/dev/null; then
      security delete-generic-password -a "muster-cloud" -s "muster-token_${name}" >/dev/null 2>&1 || true
    elif command -v secret-tool &>/dev/null; then
      secret-tool clear service "muster-cloud" key "token_${name}" >/dev/null 2>&1 || true
    fi
  fi
  _fleet_cloud_token_delete_file "$name"
}

_fleet_cloud_token_delete_file() {
  local name="$1"
  [[ -f "$FLEET_CLOUD_TOKENS_FILE" ]] || return 0
  local tmp="${FLEET_CLOUD_TOKENS_FILE}.tmp"
  jq --arg n "$name" 'del(.tokens[$n])' \
    "$FLEET_CLOUD_TOKENS_FILE" > "$tmp" && mv "$tmp" "$FLEET_CLOUD_TOKENS_FILE"
  chmod 600 "$FLEET_CLOUD_TOKENS_FILE"
}

# ── Transport functions ──

_fleet_cloud_exec() {
  local machine="$1" cmd="$2" cwd="${3:-}"
  _fleet_cloud_config

  if ! _fleet_cloud_available; then
    err "muster-tunnel not installed. Install: curl -fsSL https://getmuster.dev/fleet-cloud/install.sh | bash -s -- --tunnel"
    return 1
  fi

  local bin
  bin=$(_fleet_cloud_bin)
  if [[ -n "$cwd" ]]; then
    MUSTER_CLOUD_TOKEN="$FLEET_CLOUD_TOKEN" "$bin" exec \
      --relay "$FLEET_CLOUD_RELAY" \
      --org "$FLEET_CLOUD_ORG" \
      --agent "$machine" \
      --cmd "$cmd" \
      --cwd "$cwd"
  else
    MUSTER_CLOUD_TOKEN="$FLEET_CLOUD_TOKEN" "$bin" exec \
      --relay "$FLEET_CLOUD_RELAY" \
      --org "$FLEET_CLOUD_ORG" \
      --agent "$machine" \
      --cmd "$cmd"
  fi
}

_fleet_cloud_push() {
  local machine="$1" hook_file="$2" env_lines="${3:-}"
  _fleet_cloud_config

  if ! _fleet_cloud_available; then
    err "muster-tunnel not installed. Install: curl -fsSL https://getmuster.dev/fleet-cloud/install.sh | bash -s -- --tunnel"
    return 1
  fi

  local bin
  bin=$(_fleet_cloud_bin)

  if [[ -n "$env_lines" ]]; then
    local env_csv=""
    while IFS= read -r _env_line; do
      [[ -z "$_env_line" ]] && continue
      if [[ -n "$env_csv" ]]; then
        env_csv="${env_csv},${_env_line}"
      else
        env_csv="$_env_line"
      fi
    done <<< "$env_lines"

    MUSTER_CLOUD_TOKEN="$FLEET_CLOUD_TOKEN" "$bin" push \
      --relay "$FLEET_CLOUD_RELAY" \
      --org "$FLEET_CLOUD_ORG" \
      --agent "$machine" \
      --hook "$hook_file" \
      --env "$env_csv"
  else
    MUSTER_CLOUD_TOKEN="$FLEET_CLOUD_TOKEN" "$bin" push \
      --relay "$FLEET_CLOUD_RELAY" \
      --org "$FLEET_CLOUD_ORG" \
      --agent "$machine" \
      --hook "$hook_file"
  fi
}

_fleet_cloud_check() {
  local machine="$1"
  _fleet_cloud_config

  if ! _fleet_cloud_available; then
    return 1
  fi

  local bin
  bin=$(_fleet_cloud_bin)
  MUSTER_CLOUD_TOKEN="$FLEET_CLOUD_TOKEN" "$bin" ping \
    --relay "$FLEET_CLOUD_RELAY" \
    --org "$FLEET_CLOUD_ORG" \
    --agent "$machine" 2>/dev/null
}
