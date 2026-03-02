#!/usr/bin/env bash
# muster/lib/core/fleet.sh — Fleet config reader, SSH primitives, token storage

FLEET_CONFIG_FILE=""

# ── Token storage ──

FLEET_TOKENS_FILE="$HOME/.muster/fleet-tokens.json"

_fleet_token_file() {
  if [[ ! -d "$HOME/.muster" ]]; then
    mkdir -p "$HOME/.muster"
    chmod 700 "$HOME/.muster"
  fi
  if [[ ! -f "$FLEET_TOKENS_FILE" ]]; then
    printf '{"tokens":{}}\n' > "$FLEET_TOKENS_FILE"
  fi
  chmod 600 "$FLEET_TOKENS_FILE"
}

# Compound key: user@host:port
_fleet_token_key() {
  local machine="$1"
  _fleet_load_machine "$machine"
  printf '%s@%s:%s' "$_FM_USER" "$_FM_HOST" "$_FM_PORT"
}

fleet_token_get() {
  local machine="$1"
  _fleet_token_file
  local key
  key=$(_fleet_token_key "$machine")
  local val
  val=$(jq -r --arg k "$key" '.tokens[$k] // ""' "$FLEET_TOKENS_FILE" 2>/dev/null)
  [[ -n "$val" && "$val" != "null" ]] && printf '%s' "$val"
}

fleet_token_set() {
  local machine="$1" token="$2"
  _fleet_token_file
  local key
  key=$(_fleet_token_key "$machine")
  local tmp="${FLEET_TOKENS_FILE}.tmp"
  jq --arg k "$key" --arg v "$token" '.tokens[$k] = $v' \
    "$FLEET_TOKENS_FILE" > "$tmp" && mv "$tmp" "$FLEET_TOKENS_FILE"
  chmod 600 "$FLEET_TOKENS_FILE"
}

fleet_token_delete() {
  local machine="$1"
  _fleet_token_file
  local key
  key=$(_fleet_token_key "$machine")
  local tmp="${FLEET_TOKENS_FILE}.tmp"
  jq --arg k "$key" 'del(.tokens[$k])' \
    "$FLEET_TOKENS_FILE" > "$tmp" && mv "$tmp" "$FLEET_TOKENS_FILE"
  chmod 600 "$FLEET_TOKENS_FILE"
}

# Auto-pair: SSH in, create token on remote, store locally
# Returns 0 on success, 1 on failure (prints instructions)
fleet_auto_pair() {
  local machine="$1"
  _fleet_load_machine "$machine"

  # 1. Check if remote has muster
  if ! fleet_exec "$machine" "command -v muster" &>/dev/null; then
    warn "Remote does not have muster installed"
    _fleet_pair_instructions "$machine"
    return 1
  fi

  # 2. Check if remote already has tokens (can't bootstrap if tokens exist)
  local token_count
  token_count=$(fleet_exec "$machine" "test -f ~/.muster/tokens.json && jq '.tokens | length' ~/.muster/tokens.json 2>/dev/null || echo 0" 2>/dev/null)
  token_count=$(printf '%s' "$token_count" | tr -d '[:space:]')

  if [[ -n "$token_count" && "$token_count" != "0" ]]; then
    warn "Remote already has tokens configured — cannot auto-pair"
    _fleet_pair_instructions "$machine"
    return 1
  fi

  # 3. Create token on remote (bootstrap — first token needs no auth)
  local hostname_local
  hostname_local=$(hostname -s 2>/dev/null || echo "fleet")
  local raw_token
  raw_token=$(fleet_exec "$machine" "muster auth create fleet-${hostname_local} --scope deploy" 2>/dev/null)

  if [[ -z "$raw_token" ]]; then
    warn "Failed to create token on remote"
    _fleet_pair_instructions "$machine"
    return 1
  fi

  # 4. Store token locally
  fleet_token_set "$machine" "$raw_token"

  # 5. Verify token works
  if fleet_verify_pair "$machine"; then
    ok "Paired with $(fleet_desc "$machine")"
    return 0
  else
    warn "Token created but verification failed"
    fleet_token_delete "$machine"
    _fleet_pair_instructions "$machine"
    return 1
  fi
}

# Print manual pair instructions
_fleet_pair_instructions() {
  local machine="$1"
  echo ""
  echo -e "  ${DIM}To pair manually:${RESET}"
  echo -e "  ${DIM}  1. On the remote:${RESET}  ssh $(fleet_desc "$machine") \"muster auth create fleet-\$(hostname) --scope deploy\""
  echo -e "  ${DIM}  2. Locally:${RESET}        muster fleet pair ${machine} --token <raw-token>"
  echo ""
}

# Verify stored token works against remote
fleet_verify_pair() {
  local machine="$1"
  local token
  token=$(fleet_token_get "$machine")
  [[ -z "$token" ]] && return 1

  local result
  result=$(fleet_exec "$machine" "MUSTER_TOKEN=${token} muster status --json" 2>/dev/null)
  # If we got valid JSON back (not an error), the token works
  printf '%s' "$result" | jq -e '.services' &>/dev/null
}

# ── Config I/O ──

# Find and load remotes.json from project directory
fleet_load_config() {
  if [[ -n "$FLEET_CONFIG_FILE" ]]; then
    return 0
  fi

  # Use project dir from deploy.json if available
  local dir=""
  if [[ -n "$CONFIG_FILE" ]]; then
    dir="$(dirname "$CONFIG_FILE")"
  else
    dir="$(pwd)"
  fi

  local path="${dir}/remotes.json"
  if [[ -f "$path" ]]; then
    FLEET_CONFIG_FILE="$path"
    return 0
  fi

  return 1
}

# Check if fleet config exists (without erroring)
fleet_has_config() {
  local dir=""
  if [[ -n "$CONFIG_FILE" ]]; then
    dir="$(dirname "$CONFIG_FILE")"
  else
    dir="$(pwd)"
  fi
  [[ -f "${dir}/remotes.json" ]]
}

# Create empty remotes.json
fleet_init() {
  local dir=""
  if [[ -n "$CONFIG_FILE" ]]; then
    dir="$(dirname "$CONFIG_FILE")"
  else
    dir="$(pwd)"
  fi

  local path="${dir}/remotes.json"
  if [[ -f "$path" ]]; then
    err "remotes.json already exists"
    return 1
  fi

  printf '{\n  "machines": {},\n  "groups": {},\n  "deploy_order": []\n}\n' > "$path"
  FLEET_CONFIG_FILE="$path"
  ok "Created remotes.json"
}

# jq query on remotes.json
fleet_get() {
  local query="$1"
  jq -r "$query" "$FLEET_CONFIG_FILE"
}

# Write value to remotes.json
fleet_set() {
  local path="$1" value="$2"
  local tmp="${FLEET_CONFIG_FILE}.tmp"
  jq "${path} = ${value}" "$FLEET_CONFIG_FILE" > "$tmp" && mv "$tmp" "$FLEET_CONFIG_FILE"
}

# ── Machine config (batch read) ──

# Vars set by _fleet_load_machine:
_FM_HOST="" _FM_USER="" _FM_PORT="" _FM_IDENTITY="" _FM_PROJECT_DIR="" _FM_MODE="" _FM_TRANSPORT=""

# Load all config for a machine in one jq call
_fleet_load_machine() {
  local name="$1"
  local data
  data=$(jq -r --arg n "$name" \
    '.machines[$n] | "\(.host // "")\n\(.user // "")\n\(.port // 22)\n\(.identity_file // "")\n\(.project_dir // "")\n\(.mode // "push")\n\(.transport // "ssh")"' \
    "$FLEET_CONFIG_FILE" 2>/dev/null)

  local i=0
  while IFS= read -r _line; do
    case $i in
      0) _FM_HOST="$_line" ;;
      1) _FM_USER="$_line" ;;
      2) _FM_PORT="$_line" ;;
      3) _FM_IDENTITY="$_line" ;;
      4) _FM_PROJECT_DIR="$_line" ;;
      5) _FM_MODE="$_line" ;;
      6) _FM_TRANSPORT="$_line" ;;
    esac
    i=$(( i + 1 ))
  done <<< "$data"

  # Defaults
  [[ -z "$_FM_PORT" || "$_FM_PORT" == "null" ]] && _FM_PORT="22"
  [[ "$_FM_IDENTITY" == "null" ]] && _FM_IDENTITY=""
  [[ "$_FM_PROJECT_DIR" == "null" ]] && _FM_PROJECT_DIR=""
  [[ -z "$_FM_MODE" || "$_FM_MODE" == "null" ]] && _FM_MODE="push"
  [[ -z "$_FM_TRANSPORT" || "$_FM_TRANSPORT" == "null" ]] && _FM_TRANSPORT="ssh"
}

# List all machine names
fleet_machines() {
  jq -r '.machines | keys[]' "$FLEET_CONFIG_FILE" 2>/dev/null
}

# List all group names
fleet_groups() {
  jq -r '.groups | keys[]' "$FLEET_CONFIG_FILE" 2>/dev/null
}

# List machines in a group
fleet_group_machines() {
  local group="$1"
  jq -r --arg g "$group" '.groups[$g][]' "$FLEET_CONFIG_FILE" 2>/dev/null
}

# Get ordered group list for deploy
fleet_deploy_order() {
  jq -r '.deploy_order[]' "$FLEET_CONFIG_FILE" 2>/dev/null
}

# ── CRUD ──

fleet_add_machine() {
  local name="$1" host="$2" user="$3" port="${4:-22}" identity="${5:-}" project_dir="${6:-}" mode="${7:-push}" transport="${8:-ssh}"

  # Validate mode
  case "$mode" in
    muster|push) ;;
    *)
      err "Invalid mode: ${mode} (must be muster or push)"
      return 1
      ;;
  esac

  # Validate transport
  case "$transport" in
    ssh|cloud) ;;
    *)
      err "Invalid transport: ${transport} (must be ssh or cloud)"
      return 1
      ;;
  esac

  # Check if machine already exists
  local existing
  existing=$(jq -r --arg n "$name" '.machines[$n] // empty' "$FLEET_CONFIG_FILE" 2>/dev/null)
  if [[ -n "$existing" ]]; then
    err "Machine '${name}' already exists. Remove it first with: muster fleet remove ${name}"
    return 1
  fi

  # Build machine JSON
  local machine_json
  machine_json=$(jq -n \
    --arg host "$host" \
    --arg user "$user" \
    --argjson port "$port" \
    --arg identity "$identity" \
    --arg project_dir "$project_dir" \
    --arg mode "$mode" \
    --arg transport "$transport" \
    '{host: $host, user: $user, port: $port, mode: $mode} +
     (if $transport != "ssh" then {transport: $transport} else {} end) +
     (if $identity != "" then {identity_file: $identity} else {} end) +
     (if $project_dir != "" then {project_dir: $project_dir} else {} end)')

  local tmp="${FLEET_CONFIG_FILE}.tmp"
  jq --arg n "$name" --argjson m "$machine_json" \
    '.machines[$n] = $m' "$FLEET_CONFIG_FILE" > "$tmp" && mv "$tmp" "$FLEET_CONFIG_FILE"

  ok "Added machine '${name}' (${user}@${host}:${port}, mode: ${mode})"
}

fleet_remove_machine() {
  local name="$1"

  # Check exists
  local existing
  existing=$(jq -r --arg n "$name" '.machines[$n] // empty' "$FLEET_CONFIG_FILE" 2>/dev/null)
  if [[ -z "$existing" ]]; then
    err "Machine '${name}' not found"
    return 1
  fi

  # Get token key before removing config (needs machine config to build key)
  local _token_key=""
  _fleet_load_machine "$name"
  _token_key="${_FM_USER}@${_FM_HOST}:${_FM_PORT}"

  # Remove from machines and all groups
  local tmp="${FLEET_CONFIG_FILE}.tmp"
  jq --arg n "$name" '
    del(.machines[$n]) |
    .groups = (.groups | to_entries | map(.value = (.value | map(select(. != $n)))) | from_entries) |
    .deploy_order = [.deploy_order[] | select(. != $n)]
  ' "$FLEET_CONFIG_FILE" > "$tmp" && mv "$tmp" "$FLEET_CONFIG_FILE"

  # Remove stored token
  if [[ -n "$_token_key" ]]; then
    _fleet_token_file
    tmp="${FLEET_TOKENS_FILE}.tmp"
    jq --arg k "$_token_key" 'del(.tokens[$k])' \
      "$FLEET_TOKENS_FILE" > "$tmp" && mv "$tmp" "$FLEET_TOKENS_FILE"
    chmod 600 "$FLEET_TOKENS_FILE"
  fi

  ok "Removed machine '${name}'"
}

fleet_set_group() {
  local group_name="$1"
  shift
  local machines_json="[]"
  while [[ $# -gt 0 ]]; do
    machines_json=$(printf '%s' "$machines_json" | jq --arg m "$1" '. + [$m]')
    shift
  done

  local tmp="${FLEET_CONFIG_FILE}.tmp"
  jq --arg g "$group_name" --argjson m "$machines_json" \
    '.groups[$g] = $m' "$FLEET_CONFIG_FILE" > "$tmp" && mv "$tmp" "$FLEET_CONFIG_FILE"

  ok "Group '${group_name}' updated"
}

fleet_remove_group() {
  local group_name="$1"

  local existing
  existing=$(jq -r --arg g "$group_name" '.groups[$g] // empty' "$FLEET_CONFIG_FILE" 2>/dev/null)
  if [[ -z "$existing" ]]; then
    err "Group '${group_name}' not found"
    return 1
  fi

  local tmp="${FLEET_CONFIG_FILE}.tmp"
  jq --arg g "$group_name" '
    del(.groups[$g]) |
    .deploy_order = [.deploy_order[] | select(. != $g)]
  ' "$FLEET_CONFIG_FILE" > "$tmp" && mv "$tmp" "$FLEET_CONFIG_FILE"

  ok "Removed group '${group_name}'"
}

# ── SSH execution ──

# Build SSH options from _FM_* vars
_fleet_build_opts() {
  _FLEET_SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

  if [[ -n "$_FM_IDENTITY" ]]; then
    local id_path="$_FM_IDENTITY"
    case "$id_path" in
      "~"/*) id_path="${HOME}/${id_path#\~/}" ;;
    esac
    _FLEET_SSH_OPTS="${_FLEET_SSH_OPTS} -i ${id_path}"
  fi

  if [[ "$_FM_PORT" != "22" ]]; then
    _FLEET_SSH_OPTS="${_FLEET_SSH_OPTS} -p ${_FM_PORT}"
  fi
}

# Execute command on machine
fleet_exec() {
  local machine="$1" cmd="$2"
  _fleet_load_machine "$machine"
  case "$_FM_TRANSPORT" in
    ssh)
      _fleet_build_opts
      ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" "$cmd"
      ;;
    cloud)
      source "$MUSTER_ROOT/lib/core/cloud.sh"
      _fleet_cloud_exec "$machine" "$cmd"
      ;;
    *)
      err "Unknown transport: ${_FM_TRANSPORT} (machine: ${machine})"
      return 1
      ;;
  esac
}

# Pipe hook script to machine
fleet_push_hook() {
  local machine="$1" hook_file="$2" env_lines="${3:-}"
  _fleet_load_machine "$machine"
  case "$_FM_TRANSPORT" in
    ssh)
      _fleet_build_opts
      {
        # Export env vars
        if [[ -n "$env_lines" ]]; then
          while IFS= read -r _env_line; do
            [[ -z "$_env_line" ]] && continue
            printf 'export %s\n' "$_env_line"
          done <<< "$env_lines"
        fi

        # cd to project directory if set
        if [[ -n "$_FM_PROJECT_DIR" ]]; then
          printf 'cd %s || exit 1\n' "$_FM_PROJECT_DIR"
        fi

        # Pipe the hook script
        cat "$hook_file"
      } | ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" "bash -s"
      ;;
    cloud)
      source "$MUSTER_ROOT/lib/core/cloud.sh"
      _fleet_cloud_push "$machine" "$hook_file" "$env_lines"
      ;;
    *)
      err "Unknown transport: ${_FM_TRANSPORT} (machine: ${machine})"
      return 1
      ;;
  esac
}

# Connectivity test
fleet_check() {
  local machine="$1"
  _fleet_load_machine "$machine"
  case "$_FM_TRANSPORT" in
    ssh)
      _fleet_build_opts
      ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" "echo ok" &>/dev/null
      ;;
    cloud)
      source "$MUSTER_ROOT/lib/core/cloud.sh"
      _fleet_cloud_check "$machine"
      ;;
    *)
      return 1
      ;;
  esac
}

# Display string: user@host:port
fleet_desc() {
  local machine="$1"
  _fleet_load_machine "$machine"
  printf '%s@%s:%s' "$_FM_USER" "$_FM_HOST" "$_FM_PORT"
}
