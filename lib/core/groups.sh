#!/usr/bin/env bash
# muster/lib/core/groups.sh — Fleet Groups config reader and CRUD

GROUPS_CONFIG_FILE="$HOME/.muster/groups.json"

# ── Config file management ──

_groups_ensure_file() {
  if [[ ! -d "$HOME/.muster" ]]; then
    mkdir -p "$HOME/.muster"
    chmod 700 "$HOME/.muster"
  fi
  if [[ ! -f "$GROUPS_CONFIG_FILE" ]]; then
    printf '{"groups":{}}\n' > "$GROUPS_CONFIG_FILE"
  fi
}

# Read a jq query from groups.json
groups_get() {
  local query="$1"
  _groups_ensure_file
  jq -r "$query" "$GROUPS_CONFIG_FILE" 2>/dev/null
}

# Write a value to groups.json (atomic tmp+mv)
groups_set() {
  local path="$1" value="$2"
  _groups_ensure_file
  local tmp="${GROUPS_CONFIG_FILE}.tmp"
  jq "${path} = ${value}" "$GROUPS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GROUPS_CONFIG_FILE"
}

# ── Read helpers ──

# List all group names (newline-separated)
groups_list() {
  _groups_ensure_file
  jq -r '.groups | keys[]' "$GROUPS_CONFIG_FILE" 2>/dev/null
}

# Check if a group exists (returns 0/1)
groups_exists() {
  local name="$1"
  _groups_ensure_file
  local val
  val=$(jq -r --arg n "$name" '.groups[$n] // empty' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  [[ -n "$val" ]]
}

# Get number of projects in a group
groups_project_count() {
  local name="$1"
  _groups_ensure_file
  local count
  count=$(jq -r --arg n "$name" '.groups[$n].projects | length' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  [[ -z "$count" || "$count" == "null" ]] && count=0
  echo "$count"
}

# Display string for a project entry (path for local, user@host for remote)
groups_project_desc() {
  local name="$1" index="$2"
  _groups_ensure_file
  local _type
  _type=$(jq -r --arg n "$name" --argjson i "$index" \
    '.groups[$n].projects[$i].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)

  if [[ "$_type" == "local" ]]; then
    jq -r --arg n "$name" --argjson i "$index" \
      '.groups[$n].projects[$i].path' "$GROUPS_CONFIG_FILE" 2>/dev/null
  else
    local _user _host _port
    _user=$(jq -r --arg n "$name" --argjson i "$index" \
      '.groups[$n].projects[$i].user' "$GROUPS_CONFIG_FILE" 2>/dev/null)
    _host=$(jq -r --arg n "$name" --argjson i "$index" \
      '.groups[$n].projects[$i].host' "$GROUPS_CONFIG_FILE" 2>/dev/null)
    _port=$(jq -r --arg n "$name" --argjson i "$index" \
      '.groups[$n].projects[$i].port // 22' "$GROUPS_CONFIG_FILE" 2>/dev/null)
    if [[ "$_port" != "22" ]]; then
      printf '%s@%s:%s' "$_user" "$_host" "$_port"
    else
      printf '%s@%s' "$_user" "$_host"
    fi
  fi
}

# Get project name (from config on disk for local, from desc for remote)
groups_project_name() {
  local name="$1" index="$2"
  local _type
  _type=$(jq -r --arg n "$name" --argjson i "$index" \
    '.groups[$n].projects[$i].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)

  if [[ "$_type" == "local" ]]; then
    local _path
    _path=$(jq -r --arg n "$name" --argjson i "$index" \
      '.groups[$n].projects[$i].path' "$GROUPS_CONFIG_FILE" 2>/dev/null)
    # Read project name from muster.json or deploy.json
    local _config=""
    [[ -f "${_path}/muster.json" ]] && _config="${_path}/muster.json"
    [[ -z "$_config" && -f "${_path}/deploy.json" ]] && _config="${_path}/deploy.json"
    if [[ -n "$_config" ]] && has_cmd jq; then
      local _pname
      _pname=$(jq -r '.project // ""' "$_config" 2>/dev/null)
      if [[ -n "$_pname" && "$_pname" != "null" ]]; then
        echo "$_pname"
        return
      fi
    fi
    # Fallback to directory name
    basename "$_path"
  else
    groups_project_desc "$name" "$index"
  fi
}

# ── CRUD ──

# Create a new group
groups_create() {
  local name="$1"
  local display="${2:-$1}"
  _groups_ensure_file

  # Validate name
  case "$name" in
    *[^a-zA-Z0-9_-]*)
      err "Group name must be alphanumeric, hyphens, or underscores"
      return 1
      ;;
  esac

  if groups_exists "$name"; then
    err "Group '${name}' already exists"
    return 1
  fi

  local group_json
  group_json=$(jq -n --arg n "$display" '{"name": $n, "projects": [], "deploy_order": []}')

  local tmp="${GROUPS_CONFIG_FILE}.tmp"
  jq --arg g "$name" --argjson v "$group_json" \
    '.groups[$g] = $v' "$GROUPS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GROUPS_CONFIG_FILE"

  ok "Created group '${name}'"
}

# Delete a group
groups_delete() {
  local name="$1"
  _groups_ensure_file

  if ! groups_exists "$name"; then
    err "Group '${name}' not found"
    return 1
  fi

  local tmp="${GROUPS_CONFIG_FILE}.tmp"
  jq --arg g "$name" 'del(.groups[$g])' \
    "$GROUPS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GROUPS_CONFIG_FILE"

  ok "Deleted group '${name}'"
}

# Add a local project to a group
groups_add_local() {
  local name="$1" path="$2"
  _groups_ensure_file

  if ! groups_exists "$name"; then
    err "Group '${name}' not found"
    return 1
  fi

  # Validate path has a config file
  if [[ ! -f "${path}/muster.json" && ! -f "${path}/deploy.json" ]]; then
    err "No muster.json or deploy.json found in: ${path}"
    return 1
  fi

  # Check for duplicates
  local existing
  existing=$(jq -r --arg g "$name" --arg p "$path" \
    '[.groups[$g].projects[] | select(.type == "local" and .path == $p)] | length' \
    "$GROUPS_CONFIG_FILE" 2>/dev/null)
  if [[ "$existing" != "0" ]]; then
    err "Project already in group: ${path}"
    return 1
  fi

  local project_json
  project_json=$(jq -n --arg p "$path" '{"path": $p, "type": "local"}')

  local tmp="${GROUPS_CONFIG_FILE}.tmp"
  jq --arg g "$name" --argjson p "$project_json" \
    '.groups[$g].projects += [$p]' "$GROUPS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GROUPS_CONFIG_FILE"

  ok "Added local project: ${path}"
}

# Add a remote project to a group
groups_add_remote() {
  local name="$1" host="$2" user="$3" port="${4:-22}" identity="${5:-}" project_dir="${6:-}"
  _groups_ensure_file

  if ! groups_exists "$name"; then
    err "Group '${name}' not found"
    return 1
  fi

  # Check for duplicates by host+user+port
  local existing
  existing=$(jq -r --arg g "$name" --arg h "$host" --arg u "$user" --argjson p "$port" \
    '[.groups[$g].projects[] | select(.type == "remote" and .host == $h and .user == $u and .port == $p)] | length' \
    "$GROUPS_CONFIG_FILE" 2>/dev/null)
  if [[ "$existing" != "0" ]]; then
    err "Remote already in group: ${user}@${host}:${port}"
    return 1
  fi

  local project_json
  project_json=$(jq -n \
    --arg host "$host" \
    --arg user "$user" \
    --argjson port "$port" \
    --arg identity "$identity" \
    --arg project_dir "$project_dir" \
    '{host: $host, user: $user, port: $port, type: "remote"} +
     (if $identity != "" then {identity_file: $identity} else {} end) +
     (if $project_dir != "" then {project_dir: $project_dir} else {} end)')

  local tmp="${GROUPS_CONFIG_FILE}.tmp"
  jq --arg g "$name" --argjson p "$project_json" \
    '.groups[$g].projects += [$p]' "$GROUPS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GROUPS_CONFIG_FILE"

  ok "Added remote project: ${user}@${host}:${port}"
}

# Remove a project from a group by index
groups_remove_project() {
  local name="$1" index="$2"
  _groups_ensure_file

  if ! groups_exists "$name"; then
    err "Group '${name}' not found"
    return 1
  fi

  local total
  total=$(groups_project_count "$name")
  if (( index < 0 || index >= total )); then
    err "Invalid project index: ${index}"
    return 1
  fi

  local tmp="${GROUPS_CONFIG_FILE}.tmp"
  jq --arg g "$name" --argjson i "$index" \
    '.groups[$g].projects = [.groups[$g].projects | to_entries[] | select(.key != $i) | .value]' \
    "$GROUPS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GROUPS_CONFIG_FILE"

  ok "Removed project from group '${name}'"
}

# ── SSH helpers for remote group projects ──

# Vars set by _groups_load_remote:
_GP_HOST="" _GP_USER="" _GP_PORT="" _GP_IDENTITY="" _GP_PROJECT_DIR=""

# Load SSH config from a remote project entry
_groups_load_remote() {
  local name="$1" index="$2"
  _GP_HOST=$(jq -r --arg n "$name" --argjson i "$index" \
    '.groups[$n].projects[$i].host // ""' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  _GP_USER=$(jq -r --arg n "$name" --argjson i "$index" \
    '.groups[$n].projects[$i].user // ""' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  _GP_PORT=$(jq -r --arg n "$name" --argjson i "$index" \
    '.groups[$n].projects[$i].port // 22' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  _GP_IDENTITY=$(jq -r --arg n "$name" --argjson i "$index" \
    '.groups[$n].projects[$i].identity_file // ""' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  _GP_PROJECT_DIR=$(jq -r --arg n "$name" --argjson i "$index" \
    '.groups[$n].projects[$i].project_dir // ""' "$GROUPS_CONFIG_FILE" 2>/dev/null)

  [[ -z "$_GP_PORT" || "$_GP_PORT" == "null" ]] && _GP_PORT="22"
  [[ "$_GP_IDENTITY" == "null" ]] && _GP_IDENTITY=""
  [[ "$_GP_PROJECT_DIR" == "null" ]] && _GP_PROJECT_DIR=""
}

# Build SSH options string from _GP_* vars
_groups_build_ssh_opts() {
  _GROUPS_SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

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

# Execute a command on a remote group project
groups_remote_exec() {
  local name="$1" index="$2" cmd="$3"
  _groups_load_remote "$name" "$index"
  _groups_build_ssh_opts
  ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "$cmd"
}

# Check SSH connectivity for a remote group project
groups_remote_check() {
  local name="$1" index="$2"
  _groups_load_remote "$name" "$index"
  _groups_build_ssh_opts
  ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "echo ok" &>/dev/null
}
