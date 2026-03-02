#!/usr/bin/env bash
# muster/lib/core/cloud.sh — Cloud transport helpers (shells out to muster-tunnel)

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
  FLEET_CLOUD_RELAY=$(fleet_get '.cloud.relay // ""')
  FLEET_CLOUD_ORG=$(fleet_get '.cloud.org_id // ""')
  local token_ref
  token_ref=$(fleet_get '.cloud.token_ref // ""')
  if [[ -n "$token_ref" ]]; then
    FLEET_CLOUD_TOKEN=$(_fleet_cloud_token_get "$token_ref")
  fi
}

# ── Cloud token storage (~/.muster/cloud-tokens.json) ──

FLEET_CLOUD_TOKENS_FILE="$HOME/.muster/cloud-tokens.json"

_fleet_cloud_token_file() {
  if [[ ! -d "$HOME/.muster" ]]; then
    mkdir -p "$HOME/.muster"
    chmod 700 "$HOME/.muster"
  fi
  if [[ ! -f "$FLEET_CLOUD_TOKENS_FILE" ]]; then
    printf '{"tokens":{}}\n' > "$FLEET_CLOUD_TOKENS_FILE"
  fi
  chmod 600 "$FLEET_CLOUD_TOKENS_FILE"
}

_fleet_cloud_token_get() {
  local name="$1"
  _fleet_cloud_token_file
  local val
  val=$(jq -r --arg n "$name" '.tokens[$n] // ""' "$FLEET_CLOUD_TOKENS_FILE" 2>/dev/null)
  [[ -n "$val" && "$val" != "null" ]] && printf '%s' "$val"
}

_fleet_cloud_token_set() {
  local name="$1" token="$2"
  _fleet_cloud_token_file
  local tmp="${FLEET_CLOUD_TOKENS_FILE}.tmp"
  jq --arg n "$name" --arg v "$token" '.tokens[$n] = $v' \
    "$FLEET_CLOUD_TOKENS_FILE" > "$tmp" && mv "$tmp" "$FLEET_CLOUD_TOKENS_FILE"
  chmod 600 "$FLEET_CLOUD_TOKENS_FILE"
}

_fleet_cloud_token_delete() {
  local name="$1"
  _fleet_cloud_token_file
  local tmp="${FLEET_CLOUD_TOKENS_FILE}.tmp"
  jq --arg n "$name" 'del(.tokens[$n])' \
    "$FLEET_CLOUD_TOKENS_FILE" > "$tmp" && mv "$tmp" "$FLEET_CLOUD_TOKENS_FILE"
  chmod 600 "$FLEET_CLOUD_TOKENS_FILE"
}

# ── Transport functions ──

_fleet_cloud_exec() {
  local machine="$1" cmd="$2"
  _fleet_cloud_config

  if ! _fleet_cloud_available; then
    err "muster-tunnel not installed. Install: curl -sSL https://getmuster.dev/cloud | bash"
    return 1
  fi

  local bin
  bin=$(_fleet_cloud_bin)
  "$bin" exec \
    --relay "$FLEET_CLOUD_RELAY" \
    --token "$FLEET_CLOUD_TOKEN" \
    --org "$FLEET_CLOUD_ORG" \
    --agent "$machine" \
    --cmd "$cmd"
}

_fleet_cloud_push() {
  local machine="$1" hook_file="$2" env_lines="${3:-}"
  _fleet_cloud_config

  if ! _fleet_cloud_available; then
    err "muster-tunnel not installed. Install: curl -sSL https://getmuster.dev/cloud | bash"
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

    "$bin" push \
      --relay "$FLEET_CLOUD_RELAY" \
      --token "$FLEET_CLOUD_TOKEN" \
      --org "$FLEET_CLOUD_ORG" \
      --agent "$machine" \
      --hook "$hook_file" \
      --env "$env_csv"
  else
    "$bin" push \
      --relay "$FLEET_CLOUD_RELAY" \
      --token "$FLEET_CLOUD_TOKEN" \
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
  "$bin" ping \
    --relay "$FLEET_CLOUD_RELAY" \
    --token "$FLEET_CLOUD_TOKEN" \
    --org "$FLEET_CLOUD_ORG" \
    --agent "$machine" 2>/dev/null
}
