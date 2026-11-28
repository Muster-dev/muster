#!/usr/bin/env bash
# muster/lib/core/fleet.sh — Fleet config reader, SSH primitives, token storage
# Config CRUD now delegated to fleet_config.sh. This file provides:
# - Token storage (unchanged)
# - _fleet_load_machine() shim (maps _FP_* → _FM_*)
# - SSH execution primitives (unchanged)

source "$MUSTER_ROOT/lib/core/fleet_config.sh"

FLEET_CONFIG_FILE=""

# ── Token storage ──

FLEET_TOKENS_FILE="$HOME/.muster/tokens/fleet.json"

_fleet_token_file() {
  if [[ ! -d "$HOME/.muster" ]]; then
    mkdir -p "$HOME/.muster"
    chmod 700 "$HOME/.muster"
  fi
  if [[ ! -d "$HOME/.muster/tokens" ]]; then
    mkdir -p "$HOME/.muster/tokens"
    chmod 700 "$HOME/.muster/tokens"
  fi
  # Migrate from old path
  if [[ -f "$HOME/.muster/fleet-tokens.json" && ! -f "$FLEET_TOKENS_FILE" ]]; then
    mv "$HOME/.muster/fleet-tokens.json" "$FLEET_TOKENS_FILE"
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
fleet_auto_pair() {
  local machine="$1"
  _fleet_load_machine "$machine"

  # Cloud machines need no muster auth token: the relay authenticates both
  # ends and commands are end-to-end encrypted.
  if [[ "$_FM_TRANSPORT" == "cloud" ]]; then
    return 0
  fi

  if ! fleet_exec "$machine" "command -v muster" &>/dev/null; then
    warn "Remote does not have muster installed"
    _fleet_pair_instructions "$machine"
    return 1
  fi

  local token_count
  token_count=$(fleet_exec "$machine" "{ test -f ~/.muster/tokens/auth.json && jq '.tokens | length' ~/.muster/tokens/auth.json 2>/dev/null; } || { test -f ~/.muster/tokens.json && jq '.tokens | length' ~/.muster/tokens.json 2>/dev/null; } || echo 0" 2>/dev/null)
  token_count=$(printf '%s' "$token_count" | tr -d '[:space:]')

  if [[ -n "$token_count" && "$token_count" != "0" ]]; then
    warn "Remote already has tokens configured — cannot auto-pair"
    _fleet_pair_instructions "$machine"
    return 1
  fi

  local hostname_local
  hostname_local=$(hostname -s 2>/dev/null || echo "fleet")
  local raw_token
  raw_token=$(fleet_exec "$machine" "muster auth create fleet-${hostname_local} --scope deploy" 2>/dev/null)

  if [[ -z "$raw_token" ]]; then
    warn "Failed to create token on remote"
    _fleet_pair_instructions "$machine"
    return 1
  fi

  fleet_token_set "$machine" "$raw_token"

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

_fleet_pair_instructions() {
  local machine="$1"
  echo ""
  printf '%b\n' "  ${DIM}To pair manually:${RESET}"
  printf '%b\n' "  ${DIM}  1. On the remote:${RESET}  ssh $(fleet_desc "$machine") \"muster auth create fleet-\$(hostname) --scope deploy\""
  printf '%b\n' "  ${DIM}  2. Locally:${RESET}        muster fleet pair ${machine} --token <raw-token>"
  echo ""
}

fleet_verify_pair() {
  local machine="$1"
  _fleet_load_machine "$machine"
  [[ "$_FM_TRANSPORT" == "cloud" ]] && return 0
  local token
  token=$(fleet_token_get "$machine")
  [[ -z "$token" ]] && return 1

  local result
  result=$(fleet_exec "$machine" "MUSTER_TOKEN=${token} muster status --json" 2>/dev/null)
  printf '%s' "$result" | jq -e '.services' &>/dev/null
}

# ── Config I/O (shim to fleet_config.sh) ──

# Find and load config — now uses fleet dirs
fleet_load_config() {
  if [[ -n "$FLEET_CONFIG_FILE" ]]; then
    return 0
  fi

  # Check for legacy remotes.json (project dir first, then global)
  local dir=""
  if [[ -n "$CONFIG_FILE" ]]; then
    dir="$(dirname "$CONFIG_FILE")"
  else
    dir="$(pwd)"
  fi

  if [[ -f "${dir}/remotes.json" ]]; then
    FLEET_CONFIG_FILE="${dir}/remotes.json"
    return 0
  fi
  if [[ -f "$HOME/.muster/remotes.json" ]]; then
    FLEET_CONFIG_FILE="$HOME/.muster/remotes.json"
    return 0
  fi

  # Check for fleet dirs
  fleets_ensure_dir
  if fleet_cfg_has_any; then
    FLEET_CONFIG_FILE="__fleet_dirs__"
    return 0
  fi

  return 1
}

fleet_has_config() {
  local dir=""
  if [[ -n "$CONFIG_FILE" ]]; then
    dir="$(dirname "$CONFIG_FILE")"
  else
    dir="$(pwd)"
  fi
  [[ -f "${dir}/remotes.json" ]] || [[ -f "$HOME/.muster/remotes.json" ]] || fleet_cfg_has_any 2>/dev/null
}

# Create empty fleet config
fleet_init() {
  fleets_ensure_dir
  fleet_cfg_create "default" "default"
  fleet_cfg_group_create "default" "default" "default"
  FLEET_CONFIG_FILE="__fleet_dirs__"
  ok "Fleet initialized"
}

# jq query on remotes.json (legacy compat)
fleet_get() {
  local query="$1"
  if [[ "$FLEET_CONFIG_FILE" == "__fleet_dirs__" ]]; then
    return 1
  fi
  jq -r "$query" "$FLEET_CONFIG_FILE" 2>/dev/null
}

# Write value (legacy compat)
fleet_set() {
  local path="$1" value="$2"
  if [[ "$FLEET_CONFIG_FILE" == "__fleet_dirs__" ]]; then
    return 1
  fi
  local tmp="${FLEET_CONFIG_FILE}.tmp"
  jq "${path} = ${value}" "$FLEET_CONFIG_FILE" > "$tmp" && mv "$tmp" "$FLEET_CONFIG_FILE"
}

# ── Machine config (shim: _FP_* → _FM_*) ──

_FM_HOST="" _FM_USER="" _FM_PORT="" _FM_IDENTITY="" _FM_PROJECT_DIR="" _FM_MODE="" _FM_TRANSPORT="" _FM_HOOK_MODE=""

_fleet_load_machine() {
  local name="$1"

  # Try fleet dirs first
  if fleet_cfg_find_project "$name" 2>/dev/null; then
    _FM_HOST="$_FP_HOST"
    _FM_USER="$_FP_USER"
    _FM_PORT="$_FP_PORT"
    _FM_IDENTITY="$_FP_IDENTITY"
    _FM_PROJECT_DIR="$_FP_REMOTE_PATH"
    _FM_TRANSPORT="$_FP_TRANSPORT"
    _FM_HOOK_MODE="$_FP_HOOK_MODE"
    # Use explicit mode when persisted; fall back to hook_mode for legacy project.json
    if [[ -n "$_FP_MODE" ]]; then
      _FM_MODE="$_FP_MODE"
    else
      case "$_FP_HOOK_MODE" in
        manual) _FM_MODE="muster" ;;
        sync)   _FM_MODE="push" ;;
        local)  _FM_MODE="push" ;;
        *)      _FM_MODE="push" ;;
      esac
    fi
    return 0
  fi

  # Fall back to legacy remotes.json
  if [[ -n "$FLEET_CONFIG_FILE" && "$FLEET_CONFIG_FILE" != "__fleet_dirs__" && -f "$FLEET_CONFIG_FILE" ]]; then
    local data
    data=$(jq -r --arg n "$name" \
      '.machines[$n] | "\(.host // "")\n\(.user // "")\n\(.port // 22)\n\(.identity_file // "")\n\(.project_dir // "")\n\(.mode // "push")\n\(.transport // "ssh")\n\(.hook_mode // "manual")"' \
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
        7) _FM_HOOK_MODE="$_line" ;;
      esac
      i=$(( i + 1 ))
    done <<< "$data"

    [[ -z "$_FM_PORT" || "$_FM_PORT" == "null" ]] && _FM_PORT="22"
    [[ "$_FM_IDENTITY" == "null" ]] && _FM_IDENTITY=""
    [[ "$_FM_PROJECT_DIR" == "null" ]] && _FM_PROJECT_DIR=""
    [[ -z "$_FM_MODE" || "$_FM_MODE" == "null" ]] && _FM_MODE="push"
    [[ -z "$_FM_TRANSPORT" || "$_FM_TRANSPORT" == "null" ]] && _FM_TRANSPORT="ssh"
    [[ -z "$_FM_HOOK_MODE" || "$_FM_HOOK_MODE" == "null" ]] && _FM_HOOK_MODE="manual"
    return 0
  fi

  return 1
}

# List all machine names (from fleet dirs or legacy)
fleet_machines() {
  if fleet_cfg_has_any 2>/dev/null; then
    local fleet group
    for fleet in $(fleets_list); do
      for group in $(fleet_cfg_groups "$fleet"); do
        fleet_cfg_group_projects "$fleet" "$group"
      done
    done
  elif [[ -n "$FLEET_CONFIG_FILE" && "$FLEET_CONFIG_FILE" != "__fleet_dirs__" && -f "$FLEET_CONFIG_FILE" ]]; then
    jq -r '.machines | keys[]' "$FLEET_CONFIG_FILE" 2>/dev/null
  fi
}

# List all group names (from fleet dirs or legacy)
fleet_groups() {
  if fleet_cfg_has_any 2>/dev/null; then
    fleets_list
  elif [[ -n "$FLEET_CONFIG_FILE" && "$FLEET_CONFIG_FILE" != "__fleet_dirs__" && -f "$FLEET_CONFIG_FILE" ]]; then
    jq -r '.groups | keys[]' "$FLEET_CONFIG_FILE" 2>/dev/null
  fi
}

# List machines in a group
fleet_group_machines() {
  local group="$1"
  if fleet_cfg_has_any 2>/dev/null; then
    # Group = fleet in new structure; return all projects
    local grp
    for grp in $(fleet_cfg_groups "$group"); do
      fleet_cfg_group_projects "$group" "$grp"
    done
  elif [[ -n "$FLEET_CONFIG_FILE" && "$FLEET_CONFIG_FILE" != "__fleet_dirs__" && -f "$FLEET_CONFIG_FILE" ]]; then
    jq -r --arg g "$group" '.groups[$g][]' "$FLEET_CONFIG_FILE" 2>/dev/null
  fi
}

# Get ordered group list for deploy
fleet_deploy_order() {
  if fleet_cfg_has_any 2>/dev/null; then
    fleets_list
  elif [[ -n "$FLEET_CONFIG_FILE" && "$FLEET_CONFIG_FILE" != "__fleet_dirs__" && -f "$FLEET_CONFIG_FILE" ]]; then
    jq -r '.deploy_order[]' "$FLEET_CONFIG_FILE" 2>/dev/null
  fi
}

# ── CRUD (delegated) ──

fleet_add_machine() {
  local name="$1" host="$2" user="$3" port="${4:-22}" identity="${5:-}" project_dir="${6:-}" mode="${7:-push}" transport="${8:-ssh}" hook_mode="${9:-manual}"

  case "$mode" in
    muster|push) ;;
    *) err "Invalid mode: ${mode} (must be muster or push)"; return 1 ;;
  esac
  case "$transport" in
    ssh|cloud) ;;
    *) err "Invalid transport: ${transport} (must be ssh or cloud)"; return 1 ;;
  esac

  fleets_ensure_dir

  # Ensure default fleet exists
  if ! fleet_cfg_has_any; then
    fleet_cfg_create "default" "default"
    fleet_cfg_group_create "default" "default" "default"
  fi

  local _fleet
  _fleet=$(fleets_list | head -1)

  local _json
  _json=$(jq -n \
    --arg n "$name" \
    --arg host "$host" \
    --arg user "$user" \
    --argjson port "$port" \
    --arg identity "$identity" \
    --arg project_dir "$project_dir" \
    --arg mode "$mode" \
    --arg transport "$transport" \
    --arg hook_mode "$hook_mode" \
    '{name: $n, machine: ({host: $host, user: $user, port: $port, transport: $transport} +
      (if $identity != "" then {identity_file: $identity} else {} end)),
      mode: $mode, hook_mode: $hook_mode} +
      (if $project_dir != "" then {remote_path: $project_dir} else {} end)')

  fleet_cfg_project_create "$_fleet" "default" "$name" "$_json"
  ok "Added machine '${name}' (${user}@${host}:${port})"
}

fleet_remove_machine() {
  local name="$1"
  fleets_ensure_dir

  # Find and remove
  if fleet_cfg_find_project "$name"; then
    # Remove token first
    _fleet_token_file
    local _token_key="${_FP_USER}@${_FP_HOST}:${_FP_PORT}"
    local tmp="${FLEET_TOKENS_FILE}.tmp"
    jq --arg k "$_token_key" 'del(.tokens[$k])' \
      "$FLEET_TOKENS_FILE" > "$tmp" && mv "$tmp" "$FLEET_TOKENS_FILE"
    chmod 600 "$FLEET_TOKENS_FILE"

    fleet_cfg_project_delete "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT"
    ok "Removed machine '${name}'"
  else
    err "Machine '${name}' not found"
    return 1
  fi
}

fleet_set_group() {
  local group_name="$1"
  shift
  # In new structure, groups are fleets. This is legacy compat.
  fleets_ensure_dir
  if [[ -n "$FLEET_CONFIG_FILE" && "$FLEET_CONFIG_FILE" != "__fleet_dirs__" && -f "$FLEET_CONFIG_FILE" ]]; then
    local machines_json="[]"
    while [[ $# -gt 0 ]]; do
      machines_json=$(printf '%s' "$machines_json" | jq --arg m "$1" '. + [$m]')
      shift
    done
    local tmp="${FLEET_CONFIG_FILE}.tmp"
    jq --arg g "$group_name" --argjson m "$machines_json" \
      '.groups[$g] = $m' "$FLEET_CONFIG_FILE" > "$tmp" && mv "$tmp" "$FLEET_CONFIG_FILE"
    ok "Group '${group_name}' updated"
  fi
}

fleet_remove_group() {
  local group_name="$1"
  fleets_ensure_dir
  if [[ -n "$FLEET_CONFIG_FILE" && "$FLEET_CONFIG_FILE" != "__fleet_dirs__" && -f "$FLEET_CONFIG_FILE" ]]; then
    local tmp="${FLEET_CONFIG_FILE}.tmp"
    jq --arg g "$group_name" '
      del(.groups[$g]) |
      .deploy_order = [.deploy_order[] | select(. != $g)]
    ' "$FLEET_CONFIG_FILE" > "$tmp" && mv "$tmp" "$FLEET_CONFIG_FILE"
    ok "Removed group '${group_name}'"
  fi
}

# ── SSH execution ──

_fleet_build_opts() {
  _FLEET_SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=${MUSTER_SSH_HOSTKEY_CHECK:-accept-new} -o BatchMode=yes"

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

fleet_exec() {
  local machine="$1" cmd="$2"
  _fleet_load_machine "$machine"
  case "$_FM_TRANSPORT" in
    ssh)
      _fleet_build_opts
      # shellcheck disable=SC2086
      ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" "$cmd"
      ;;
    cloud)
      # Only plain `muster …` argv can run on a cloud agent; anything that
      # needs a shell is refused here (see _cloud_exec_plain).
      source "$MUSTER_ROOT/lib/core/cloud.sh"
      _cloud_exec_plain "$(_fleet_cloud_agent "$machine")" "$cmd" "$_FM_PROJECT_DIR"
      ;;
    *)
      err "Unknown transport: ${_FM_TRANSPORT} (machine: ${machine})"
      return 1
      ;;
  esac
}

fleet_push_hook() {
  local machine="$1" hook_file="$2" env_lines="${3:-}"
  _fleet_load_machine "$machine"

  local _hook_sig=""
  local _signing
  _signing=$(global_config_get "signing" 2>/dev/null || echo "off")
  if [[ "$_signing" == "on" && -f "$hook_file" ]]; then
    source "$MUSTER_ROOT/lib/core/payload_sign.sh"
    _payload_ensure_keypair 2>/dev/null
    _hook_sig=$(payload_sign "$hook_file" 2>/dev/null || true)
  fi

  case "$_FM_TRANSPORT" in
    ssh)
      _fleet_build_opts
      # shellcheck disable=SC2086
      {
        if [[ -n "$env_lines" ]]; then
          while IFS= read -r _env_line; do
            [[ -z "$_env_line" ]] && continue
            printf 'export %s\n' "$_env_line"
          done <<< "$env_lines"
        fi
        if [[ -n "$_hook_sig" ]]; then
          printf 'export MUSTER_HOOK_SIG=%s\n' "$_hook_sig"
        fi
        if [[ -n "$_FM_PROJECT_DIR" ]]; then
          printf 'cd %s || exit 1\n' "$_FM_PROJECT_DIR"
        fi
        cat "$hook_file"
      } | ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" "bash -s"
      ;;
    cloud)
      local _cloud_env="$env_lines"
      if [[ -n "$_hook_sig" ]]; then
        if [[ -n "$_cloud_env" ]]; then
          _cloud_env="${_cloud_env}
MUSTER_HOOK_SIG=${_hook_sig}"
        else
          _cloud_env="MUSTER_HOOK_SIG=${_hook_sig}"
        fi
      fi
      source "$MUSTER_ROOT/lib/core/cloud.sh"
      local _cloud_cwd="$_FM_PROJECT_DIR" _cloud_agent
      _cloud_agent=$(_fleet_cloud_agent "$machine")
      # Push only works for agents joined with --mode push
      _cloud_run_explained "$machine" \
        _fleet_cloud_push "$_cloud_agent" "$hook_file" "$_cloud_env" "$_cloud_cwd"
      ;;
    *)
      err "Unknown transport: ${_FM_TRANSPORT} (machine: ${machine})"
      return 1
      ;;
  esac
}

fleet_check() {
  local machine="$1"
  _fleet_load_machine "$machine"
  case "$_FM_TRANSPORT" in
    ssh)
      _fleet_build_opts
      # shellcheck disable=SC2086
      ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" "echo ok" &>/dev/null
      ;;
    cloud)
      source "$MUSTER_ROOT/lib/core/cloud.sh"
      _fleet_cloud_check "$(_fleet_cloud_agent "$machine")"
      ;;
    *)
      return 1
      ;;
  esac
}

fleet_desc() {
  local machine="$1"
  _fleet_load_machine "$machine"
  if [[ "$_FM_TRANSPORT" == "cloud" ]]; then
    printf 'cloud:%s' "$_FM_HOST"
    return 0
  fi
  printf '%s@%s:%s' "$_FM_USER" "$_FM_HOST" "$_FM_PORT"
}

# Refuse an SSH-only feature for a cloud-transport machine.
# Args: machine feature_description
fleet_require_ssh() {
  local machine="$1" what="$2"
  _fleet_load_machine "$machine"
  if [[ "$_FM_TRANSPORT" == "cloud" ]]; then
    err "${what} needs SSH; ${machine} uses the cloud transport"
    printf '%b\n' "  ${DIM}Cloud agents only run allowlisted muster commands (deploy, status, rollback, logs).${RESET}"
    return 1
  fi
  return 0
}

_fleet_check_nonroot() {
  local machine="$1"
  _fleet_load_machine "$machine"
  # SSH-only: the cloud agent runs as whatever user started muster-agent
  [[ "$_FM_TRANSPORT" == "cloud" ]] && return 0
  local remote_uid
  remote_uid=$(fleet_exec "$machine" "id -u" 2>/dev/null)
  remote_uid=$(printf '%s' "$remote_uid" | tr -d '[:space:]')

  if [[ "$remote_uid" == "0" ]]; then
    echo ""
    warn "SSH user is root on $(fleet_desc "$machine")"
    printf '%b\n' "  ${DIM}Root access increases blast radius on failed deploys.${RESET}"
    printf '%b\n' "  ${DIM}Consider: muster fleet setup-user ${machine}${RESET}"
    echo ""
  elif [[ -n "$remote_uid" ]]; then
    ok "Remote user is non-root (uid ${remote_uid})"
  fi
}

# "1 server" / "3 servers". Args: count noun
_fleet_plural() {
  if [[ "$1" == "1" ]]; then
    printf '%s %s' "$1" "$2"
  else
    printf '%s %ss' "$1" "$2"
  fi
}
