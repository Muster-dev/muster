#!/usr/bin/env bash
# muster/lib/core/groups.sh — Fleet Groups config reader and CRUD
# Now delegates to fleet_config.sh directory-based API.
# Function signatures preserved for group.sh compat (~40 refs).

source "$MUSTER_ROOT/lib/core/fleet_config.sh"

# Legacy compat — no longer used directly, but some files reference it
GROUPS_CONFIG_FILE="$HOME/.muster/groups.json"

# Current fleet context (set by callers or defaulting to first fleet)
_CURRENT_FLEET=""

# Resolve _CURRENT_FLEET — use first available fleet if not set
_groups_resolve_fleet() {
  if [[ -n "$_CURRENT_FLEET" ]]; then
    return 0
  fi
  fleets_ensure_dir
  local _first
  _first=$(fleets_list | head -1)
  if [[ -n "$_first" ]]; then
    _CURRENT_FLEET="$_first"
    return 0
  fi
  return 1
}

# ── Config file management ──

_groups_ensure_file() {
  fleets_ensure_dir
}

# Read a jq query from groups config (legacy compat — reads from fleet dirs)
groups_get() {
  local query="$1"
  _groups_ensure_file
  # Legacy compat: if old groups.json exists, read from it
  if [[ -f "$GROUPS_CONFIG_FILE" ]]; then
    jq -r "$query" "$GROUPS_CONFIG_FILE" 2>/dev/null
  fi
}

# Write a value (legacy compat — no-op, use fleet_cfg_* instead)
groups_set() {
  local path="$1" value="$2"
  _groups_ensure_file
  if [[ -f "$GROUPS_CONFIG_FILE" ]]; then
    local tmp="${GROUPS_CONFIG_FILE}.tmp"
    jq "${path} = ${value}" "$GROUPS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GROUPS_CONFIG_FILE"
  fi
}

# ── Read helpers ──

# List all group names (these are now fleet names)
groups_list() {
  fleets_ensure_dir
  fleets_list
}

# Check if a group exists
groups_exists() {
  local name="$1"
  fleets_ensure_dir
  local fdir
  fdir="$(fleet_dir "$name")"
  [[ -f "${fdir}/fleet.json" ]]
}

# Get number of projects in a group (fleet)
groups_project_count() {
  local name="$1"
  fleets_ensure_dir
  fleet_cfg_project_count "$name"
}

# Display string for a project entry
groups_project_desc() {
  local name="$1" index="$2"
  _groups_ensure_file
  if ! _groups_resolve_fleet; then
    return 1
  fi

  # Walk projects in deploy order to find by index
  local _fleet="$name"
  local _i=0
  local group project
  for group in $(fleet_cfg_groups "$_fleet"); do
    for project in $(fleet_cfg_group_projects "$_fleet" "$group"); do
      if (( _i == index )); then
        fleet_cfg_project_load "$_fleet" "$group" "$project"
        if [[ "$_FP_TRANSPORT" == "local" ]]; then
          printf '%s' "$_FP_PATH"
        elif [[ "$_FP_TRANSPORT" == "cloud" ]]; then
          printf '%s (cloud)' "$_FP_HOST"
        elif [[ "$_FP_PORT" != "22" ]]; then
          printf '%s@%s:%s' "$_FP_USER" "$_FP_HOST" "$_FP_PORT"
        else
          printf '%s@%s' "$_FP_USER" "$_FP_HOST"
        fi
        return 0
      fi
      _i=$(( _i + 1 ))
    done
  done
  return 1
}

# Get project name
groups_project_name() {
  local name="$1" index="$2"

  local _fleet="$name"
  local _i=0
  local group project
  for group in $(fleet_cfg_groups "$_fleet"); do
    for project in $(fleet_cfg_group_projects "$_fleet" "$group"); do
      if (( _i == index )); then
        fleet_cfg_project_load "$_fleet" "$group" "$project"
        if [[ -n "$_FP_NAME" && "$_FP_NAME" != "null" ]]; then
          echo "$_FP_NAME"
        else
          echo "$project"
        fi
        return 0
      fi
      _i=$(( _i + 1 ))
    done
  done
  return 1
}

# ── CRUD ──

# Create a new group (fleet)
groups_create() {
  local name="$1"
  local display="${2:-$1}"
  fleets_ensure_dir
  fleet_cfg_create "$name" "$display"
  fleet_cfg_group_create "$name" "default" "default"
}

# Delete a group (fleet)
groups_delete() {
  local name="$1"
  fleets_ensure_dir
  fleet_cfg_delete "$name"
}

# Add a local project to a group
groups_add_local() {
  local name="$1" path="$2"
  fleets_ensure_dir

  if ! groups_exists "$name"; then
    err "Group '${name}' not found"
    return 1
  fi

  # Validate path has a config file
  if [[ ! -f "${path}/muster.json" && ! -f "${path}/deploy.json" ]]; then
    err "No muster.json or deploy.json found in: ${path}"
    return 1
  fi

  local _pname
  _pname=$(basename "$path")

  local _json
  _json=$(jq -n --arg n "$_pname" --arg p "$path" \
    '{name: $n, machine: {transport: "local"}, path: $p, hook_mode: "local"}')

  fleet_cfg_project_create "$name" "default" "$_pname" "$_json"
  ok "Added local project: ${path}"
}

# Add a remote project to a group
groups_add_remote() {
  local name="$1" host="$2" user="$3" port="${4:-22}" identity="${5:-}" project_dir="${6:-}"
  local cloud="${7:-false}" auth_method="${8:-}" auth_mode="${9:-}" hook_mode="${10:-manual}"
  fleets_ensure_dir

  if ! groups_exists "$name"; then
    err "Group '${name}' not found"
    return 1
  fi

  [[ -z "$auth_method" && "$cloud" == "true" ]] && auth_method=""
  [[ -z "$auth_method" && -n "$identity" ]] && auth_method="key"
  [[ -z "$auth_method" ]] && auth_method="key"

  local _transport="ssh"
  [[ "$cloud" == "true" ]] && _transport="cloud"

  # Use host as dir name (sanitize dots/colons)
  local _pdir_name
  _pdir_name=$(printf '%s' "$host" | tr '.:' '-')

  local _json
  _json=$(jq -n \
    --arg n "$_pdir_name" \
    --arg host "$host" \
    --arg user "$user" \
    --argjson port "$port" \
    --arg transport "$_transport" \
    --arg identity "$identity" \
    --arg project_dir "$project_dir" \
    --arg hook_mode "$hook_mode" \
    --arg auth_method "$auth_method" \
    --arg auth_mode "$auth_mode" \
    '{name: $n, machine: ({host: $host, user: $user, port: $port, transport: $transport} +
      (if $identity != "" then {identity_file: $identity} else {} end)),
      hook_mode: $hook_mode} +
      (if $project_dir != "" then {remote_path: $project_dir} else {} end) +
      (if $auth_method == "password" then {auth: ({method: "password"} + (if $auth_mode != "" then {mode: $auth_mode} else {} end))} else {} end)')

  fleet_cfg_project_create "$name" "default" "$_pdir_name" "$_json"

  if [[ "$cloud" == "true" ]]; then
    ok "Added cloud project: ${host}"
  else
    ok "Added remote project: ${user}@${host}:${port}"
  fi
}

# Remove a project from a group by index
groups_remove_project() {
  local name="$1" index="$2"
  fleets_ensure_dir

  local _fleet="$name"
  local _i=0
  local group project
  for group in $(fleet_cfg_groups "$_fleet"); do
    for project in $(fleet_cfg_group_projects "$_fleet" "$group"); do
      if (( _i == index )); then
        fleet_cfg_project_delete "$_fleet" "$group" "$project"
        ok "Removed project from group '${name}'"
        return 0
      fi
      _i=$(( _i + 1 ))
    done
  done
  err "Invalid project index: ${index}"
  return 1
}

# ── Remote helpers for group projects (SSH, cloud, password auth) ──

# Vars set by _groups_load_remote:
_GP_HOST="" _GP_USER="" _GP_PORT="" _GP_IDENTITY="" _GP_PROJECT_DIR=""
_GP_CLOUD="" _GP_AUTH_METHOD="" _GP_AUTH_MODE="" _GP_PASSWORD=""

# Load remote config from a group project entry
_groups_load_remote() {
  local name="$1" index="$2"

  local _fleet="$name"
  local _i=0
  local group project
  for group in $(fleet_cfg_groups "$_fleet"); do
    for project in $(fleet_cfg_group_projects "$_fleet" "$group"); do
      if (( _i == index )); then
        fleet_cfg_project_load "$_fleet" "$group" "$project"
        # Map _FP_* → _GP_*
        _GP_HOST="$_FP_HOST"
        _GP_USER="$_FP_USER"
        _GP_PORT="$_FP_PORT"
        _GP_IDENTITY="$_FP_IDENTITY"
        _GP_PROJECT_DIR="$_FP_REMOTE_PATH"
        _GP_CLOUD="false"
        [[ "$_FP_TRANSPORT" == "cloud" ]] && _GP_CLOUD="true"

        # Auth from project.json
        local cfg
        cfg="$(fleet_cfg_project_dir "$_fleet" "$group" "$project")/project.json"
        _GP_AUTH_METHOD=$(jq -r '.auth.method // "key"' "$cfg" 2>/dev/null)
        _GP_AUTH_MODE=$(jq -r '.auth.mode // ""' "$cfg" 2>/dev/null)

        [[ -z "$_GP_PORT" || "$_GP_PORT" == "null" ]] && _GP_PORT="22"
        [[ "$_GP_IDENTITY" == "null" ]] && _GP_IDENTITY=""
        [[ "$_GP_PROJECT_DIR" == "null" ]] && _GP_PROJECT_DIR=""
        _GP_PROJECT_DIR="${_GP_PROJECT_DIR#:}"
        [[ -z "$_GP_AUTH_METHOD" || "$_GP_AUTH_METHOD" == "null" ]] && _GP_AUTH_METHOD="key"
        [[ "$_GP_AUTH_MODE" == "null" ]] && _GP_AUTH_MODE=""
        _GP_PASSWORD=""
        return 0
      fi
      _i=$(( _i + 1 ))
    done
  done
  return 1
}

# Load cloud config from global settings into FLEET_CLOUD_* vars
_groups_cloud_config() {
  FLEET_CLOUD_RELAY=$(global_config_get "cloud.relay" 2>/dev/null)
  FLEET_CLOUD_ORG=$(global_config_get "cloud.org_id" 2>/dev/null)
  FLEET_CLOUD_TOKEN=$(global_config_get "cloud.token" 2>/dev/null)

  [[ "$FLEET_CLOUD_RELAY" == "null" ]] && FLEET_CLOUD_RELAY=""
  [[ "$FLEET_CLOUD_ORG" == "null" ]] && FLEET_CLOUD_ORG=""
  [[ "$FLEET_CLOUD_TOKEN" == "null" ]] && FLEET_CLOUD_TOKEN=""

  if [[ -z "$FLEET_CLOUD_TOKEN" ]]; then
    local _token_ref
    _token_ref=$(global_config_get "cloud.token_ref" 2>/dev/null)
    if [[ -n "$_token_ref" && "$_token_ref" != "null" ]]; then
      source "$MUSTER_ROOT/lib/core/cloud.sh"
      FLEET_CLOUD_TOKEN=$(_fleet_cloud_token_get "$_token_ref")
    fi
  fi
}

# Load SSH password using the credential system
_groups_load_ssh_password() {
  local cred_key="ssh_${_GP_USER}@${_GP_HOST}:${_GP_PORT}"

  case "$_GP_AUTH_MODE" in
    save)
      _GP_PASSWORD=$(_cred_keychain_get "groups" "$cred_key" 2>/dev/null) || true
      if [[ -z "$_GP_PASSWORD" ]]; then
        _GP_PASSWORD=$(_cred_session_get "$cred_key" 2>/dev/null) || true
      fi
      if [[ -z "$_GP_PASSWORD" ]]; then
        _GP_PASSWORD=$(_cred_prompt_password "SSH password for ${_GP_USER}@${_GP_HOST}")
        _cred_keychain_save "groups" "$cred_key" "$_GP_PASSWORD" 2>/dev/null || true
      fi
      _cred_session_set "$cred_key" "$_GP_PASSWORD"
      ;;
    session)
      _GP_PASSWORD=$(_cred_session_get "$cred_key" 2>/dev/null) || true
      if [[ -z "$_GP_PASSWORD" ]]; then
        _GP_PASSWORD=$(_cred_prompt_password "SSH password for ${_GP_USER}@${_GP_HOST}")
        _cred_session_set "$cred_key" "$_GP_PASSWORD"
      fi
      ;;
    always)
      _GP_PASSWORD=$(_cred_prompt_password "SSH password for ${_GP_USER}@${_GP_HOST}")
      ;;
    *)
      _GP_PASSWORD=""
      ;;
  esac
}

# Build SSH options string from _GP_* vars
_groups_build_ssh_opts() {
  _GROUPS_SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

  if [[ "$_GP_AUTH_METHOD" != "password" ]]; then
    _GROUPS_SSH_OPTS="${_GROUPS_SSH_OPTS} -o BatchMode=yes"
  fi

  if [[ -n "$_GP_IDENTITY" ]]; then
    local id_path="$_GP_IDENTITY"
    case "$id_path" in
      "~"/*) id_path="${HOME}/${id_path#\~/}" ;;
    esac
    _GROUPS_SSH_OPTS="${_GROUPS_SSH_OPTS} -i ${id_path}"
  fi

  if [[ "$_GP_PORT" != "22" ]]; then
    _GROUPS_SSH_OPTS="${_GROUPS_SSH_OPTS} -p ${_GP_PORT}"
  fi
}

# Wrap a command with PATH setup for non-interactive SSH
_groups_wrap_cmd() {
  printf 'export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"; %s' "$1"
}

# Execute a command on a remote group project (SSH or cloud)
groups_remote_exec() {
  local name="$1" index="$2" cmd
  _groups_load_remote "$name" "$index"
  [[ "$_GP_AUTH_METHOD" == "password" ]] && _groups_load_ssh_password

  if [[ "$_GP_CLOUD" == "true" ]]; then
    # Cloud agents run plain `muster …` argv only (no shell, no PATH tweaks);
    # anything else is refused locally. Prefer _cloud_muster at call sites.
    source "$MUSTER_ROOT/lib/core/cloud.sh"
    _groups_cloud_config
    _cloud_exec_plain "$_GP_HOST" "$3" "$_GP_PROJECT_DIR"
  else
    cmd=$(_groups_wrap_cmd "$3")
    _groups_build_ssh_opts
    if [[ "$_GP_AUTH_METHOD" == "password" ]]; then
      export SSHPASS="$_GP_PASSWORD"
      # shellcheck disable=SC2086
      sshpass -e ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "$cmd"
      local _rc=$?
      unset SSHPASS
      return $_rc
    else
      # shellcheck disable=SC2086
      ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "$cmd"
    fi
  fi
}

# Check connectivity for a remote group project (SSH or cloud)
groups_remote_check() {
  local name="$1" index="$2"
  _groups_load_remote "$name" "$index"
  [[ "$_GP_AUTH_METHOD" == "password" ]] && _groups_load_ssh_password

  if [[ "$_GP_CLOUD" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/cloud.sh"
    _groups_cloud_config
    _fleet_cloud_check "$_GP_HOST"
  else
    _groups_build_ssh_opts
    if [[ "$_GP_AUTH_METHOD" == "password" ]]; then
      export SSHPASS="$_GP_PASSWORD"
      # shellcheck disable=SC2086
      sshpass -e ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "echo ok" &>/dev/null
      local _rc=$?
      unset SSHPASS
      return $_rc
    else
      # shellcheck disable=SC2086
      ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "echo ok" &>/dev/null
    fi
  fi
}
