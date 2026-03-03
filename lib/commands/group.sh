#!/usr/bin/env bash
# muster/lib/commands/group.sh — Fleet Groups command handler

source "$MUSTER_ROOT/lib/core/groups.sh"
source "$MUSTER_ROOT/lib/core/credentials.sh"
source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/tui/progress.sh"

# Gather credentials for a service from a config file path
# Args: config_file service_key
# Output: KEY=VALUE lines to stdout (same format as cred_env_for_service)
_group_cred_for_service() {
  local _gcfg="$1" _gsvc="$2"
  local _g_enabled
  _g_enabled=$(jq -r --arg s "$_gsvc" '.services[$s].credentials.enabled // "false"' "$_gcfg" 2>/dev/null)
  [[ "$_g_enabled" != "true" ]] && return 0

  local _g_mode
  _g_mode=$(jq -r --arg s "$_gsvc" '.services[$s].credentials.mode // "off"' "$_gcfg" 2>/dev/null)
  [[ "$_g_mode" == "off" || "$_g_mode" == "null" || -z "$_g_mode" ]] && return 0

  local _g_required
  _g_required=$(jq -r --arg s "$_gsvc" '(.services[$s].credentials.required[]? // empty)' "$_gcfg" 2>/dev/null)
  [[ -z "$_g_required" ]] && return 0

  local _g_name
  _g_name=$(jq -r --arg s "$_gsvc" '.services[$s].name // $s' "$_gcfg" 2>/dev/null)

  while IFS= read -r _g_cred_key; do
    [[ -z "$_g_cred_key" ]] && continue
    local _g_upper
    _g_upper=$(printf '%s' "$_g_cred_key" | tr '[:lower:]' '[:upper:]')
    local _g_env_name="MUSTER_CRED_${_g_upper}"
    local _g_val=""

    case "$_g_mode" in
      save)
        _g_val=$(_cred_keychain_get "$_gsvc" "$_g_cred_key" 2>/dev/null) || true
        if [[ -z "$_g_val" ]]; then
          _g_val=$(_cred_prompt_password "${_g_name} ${_g_cred_key}")
          _cred_keychain_save "$_gsvc" "$_g_cred_key" "$_g_val" 2>/dev/null || true
        fi
        _cred_session_set "${_gsvc}_${_g_cred_key}" "$_g_val"
        ;;
      session)
        _g_val=$(_cred_session_get "${_gsvc}_${_g_cred_key}" 2>/dev/null) || true
        if [[ -z "$_g_val" ]]; then
          _g_val=$(_cred_prompt_password "${_g_name} ${_g_cred_key}")
          _cred_session_set "${_gsvc}_${_g_cred_key}" "$_g_val"
        fi
        ;;
      always)
        _g_val=$(_cred_prompt_password "${_g_name} ${_g_cred_key}")
        ;;
      *) continue ;;
    esac

    printf '%s=%s\n' "$_g_env_name" "$_g_val"
  done <<< "$_g_required"
}

# ── Input validation helpers ──

_group_validate_port() {
  local port="$1"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    err "Port must be 1-65535, got: ${port}"
    return 1
  fi
}

_group_validate_host() {
  local host="$1"
  if [[ -z "$host" ]]; then
    err "Host cannot be empty"
    return 1
  fi
  # Reject shell metacharacters
  case "$host" in
    *[\;\|\&\$\`\(\)\{\}\<\>\!]*)
      err "Invalid characters in host: ${host}"
      return 1
      ;;
  esac
}

_group_validate_user() {
  local user="$1"
  if [[ -z "$user" ]]; then
    err "User cannot be empty"
    return 1
  fi
  case "$user" in
    *[\;\|\&\$\`\(\)\{\}\<\>\!\@\ ]*)
      err "Invalid characters in user: ${user}"
      return 1
      ;;
  esac
}

_group_validate_ssh_key() {
  local key="$1"
  [[ -z "$key" ]] && return 0
  # Expand ~
  local resolved="$key"
  case "$resolved" in
    "~"/*) resolved="${HOME}/${resolved#\~/}" ;;
  esac
  if [[ ! -f "$resolved" ]]; then
    warn "SSH key not found: ${key}"
  fi
}

# ── Main entry ──

cmd_group() {
  # Require jq
  if ! has_cmd jq; then
    err "Fleet Groups requires jq"
    return 1
  fi

  case "${1:-}" in
    list|ls)    shift; _group_cmd_list "$@" ;;
    create)     shift; _group_cmd_create "$@" ;;
    delete|rm)  shift; _group_cmd_delete "$@" ;;
    add)        shift; _group_cmd_add "$@" ;;
    remove)     shift; _group_cmd_remove "$@" ;;
    rename)     shift; _group_cmd_rename_cli "$@" ;;
    edit)       shift; _group_cmd_edit_cli "$@" ;;
    reorder)    shift; _group_cmd_reorder_cli "$@" ;;
    deploy)     shift; _group_cmd_deploy "$@" ;;
    status)     shift; _group_cmd_status "$@" ;;
    --help|-h)  _group_cmd_help ;;
    "")
      if [[ -t 0 ]]; then
        _group_cmd_manager
      else
        _group_cmd_help
      fi
      ;;
    *)
      err "Unknown group command: $1"
      echo "Run 'muster group --help' for usage."
      return 1
      ;;
  esac
}

# ── Help ──

_group_cmd_help() {
  printf '%b\n' "${BOLD}muster group${RESET} — Fleet Groups (cross-project deploy orchestration)"
  echo ""
  echo "Usage: muster group [command]"
  echo ""
  echo "Commands:"
  echo "  (none)              Interactive group manager"
  echo "  list                List all groups"
  echo "  create <name>       Create a new group"
  echo "  delete <name>       Delete a group"
  echo "  add <group> [target] Add a project (path for local, user@host for remote)"
  echo "  remove <group>      Remove a project from a group"
  echo "  rename <group> <name> Rename a group"
  echo "  edit <group> <idx>  Edit a remote project's SSH details"
  echo "  reorder <group>     Reorder projects interactively"
  echo "  deploy <group>      Deploy all projects in a group"
  echo "  status <group>      Show health of all projects in a group"
  echo ""
  echo "Options:"
  echo "  --port, -p    SSH port for remote projects (default: 22)"
  echo "  --key, -k     SSH identity file for remote projects"
  echo "  --path        Project directory on remote machine"
  echo "  --dry-run     Preview deploy plan without executing"
  echo "  --json        Output as JSON"
  echo "  -h, --help    Show this help"
  echo ""
  echo "Examples:"
  echo "  muster group create production"
  echo "  muster group add production /path/to/api"
  echo "  muster group add production deploy@10.0.1.5 --path /opt/frontend"
  echo "  muster group deploy production"
  echo "  muster group status production"
}

# ── List ──

_group_cmd_list() {
  local json_mode=false
  [[ "${1:-}" == "--json" ]] && json_mode=true

  _groups_ensure_file

  if [[ "$json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
    jq '.' "$GROUPS_CONFIG_FILE"
    return 0
  fi

  local group_names=()
  while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    group_names[${#group_names[@]}]="$g"
  done < <(groups_list)

  if (( ${#group_names[@]} == 0 )); then
    echo ""
    info "No groups configured"
    printf '  %bCreate one: muster group create <name>%b\n' "${DIM}" "${RESET}"
    echo ""
    return 0
  fi

  echo ""

  local gi=0
  while (( gi < ${#group_names[@]} )); do
    local gname="${group_names[$gi]}"
    local display_name
    display_name=$(groups_get ".groups.\"${gname}\".name")
    [[ "$display_name" == "null" || -z "$display_name" ]] && display_name="$gname"

    local total
    total=$(groups_project_count "$gname")

    printf '  %b%b%s%b %b(%d project%s)%b\n' \
      "${BOLD}" "${WHITE}" "$display_name" "${RESET}" \
      "${DIM}" "$total" "$([ "$total" != "1" ] && echo "s")" "${RESET}"

    local pi=0
    while (( pi < total )); do
      local _type _desc _pname
      _type=$(jq -r --arg n "$gname" --argjson i "$pi" \
        '.groups[$n].projects[$i].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)
      _desc=$(groups_project_desc "$gname" "$pi")
      _pname=$(groups_project_name "$gname" "$pi")

      local _display_desc="$_desc"
      [[ "$_type" == "local" ]] && _display_desc="${_desc/#$HOME/~}"

      local _icon _color
      if [[ "$_type" == "local" ]]; then
        _icon="●"
        if [[ -d "$_desc" ]]; then
          _color="${GREEN}"
        else
          _color="${RED}"
        fi
      else
        _icon="◆"
        _color="${ACCENT}"
      fi

      printf '    %b%s%b %b%s%b %b%s%b\n' \
        "$_color" "$_icon" "${RESET}" \
        "${WHITE}" "$_pname" "${RESET}" \
        "${DIM}" "$_display_desc" "${RESET}"

      pi=$(( pi + 1 ))
    done

    echo ""
    gi=$(( gi + 1 ))
  done
}

# ── Create ──

_group_cmd_create() {
  local name="${1:-}"
  local display=""

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|-n) display="$2"; shift 2 ;;
      --help|-h) echo "Usage: muster group create <name> [--name \"Display Name\"]"; return 0 ;;
      --*)       err "Unknown flag: $1"; return 1 ;;
      *)         [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done

  if [[ -z "$name" ]]; then
    if [[ -t 0 ]]; then
      echo ""
      printf '  Group name: '
      IFS= read -r name
      [[ -z "$name" ]] && return 0
    else
      err "Usage: muster group create <name>"
      return 1
    fi
  fi

  groups_create "$name" "${display:-$name}"
}

# ── Delete ──

_group_cmd_delete() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    err "Usage: muster group delete <name>"
    return 1
  fi

  if ! groups_exists "$name"; then
    err "Group '${name}' not found"
    return 1
  fi

  # Confirm in interactive mode
  if [[ -t 0 ]]; then
    local total
    total=$(groups_project_count "$name")
    echo ""
    menu_select "Delete group '${name}' (${total} projects)?" "Delete" "Cancel"
    [[ "$MENU_RESULT" != "Delete" ]] && return 0
  fi

  groups_delete "$name"
}

# ── Add ──

_group_cmd_add() {
  local group_name="${1:-}"
  shift 2>/dev/null || true

  if [[ -z "$group_name" ]]; then
    err "Usage: muster group add <group> [path|user@host] [options]"
    return 1
  fi

  if ! groups_exists "$group_name"; then
    err "Group '${group_name}' not found"
    return 1
  fi

  local target="" port="22" key="" remote_path=""

  # Parse remaining args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port|-p) port="$2"; shift 2 ;;
      --key|-k)  key="$2"; shift 2 ;;
      --path)    remote_path="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: muster group add <group> [path|user@host] [--port N] [--key file] [--path dir]"
        return 0
        ;;
      --*) err "Unknown flag: $1"; return 1 ;;
      *)   target="$1"; shift ;;
    esac
  done

  # Interactive mode if no target specified
  if [[ -z "$target" && -t 0 ]]; then
    source "$MUSTER_ROOT/lib/core/registry.sh"
    _registry_ensure_file

    local _project_options=()
    local _project_paths=()

    local _pcount
    _pcount=$(jq '.projects | length' "$MUSTER_PROJECTS_FILE" 2>/dev/null)
    [[ -z "$_pcount" ]] && _pcount=0

    local _pi=0
    while (( _pi < _pcount )); do
      local _pname _ppath
      _pname=$(jq -r ".projects[$_pi].name" "$MUSTER_PROJECTS_FILE")
      _ppath=$(jq -r ".projects[$_pi].path" "$MUSTER_PROJECTS_FILE")
      _project_options[${#_project_options[@]}]="${_pname} (${_ppath/#$HOME/~})"
      _project_paths[${#_project_paths[@]}]="$_ppath"
      _pi=$(( _pi + 1 ))
    done

    _project_options[${#_project_options[@]}]="Add remote project"
    _project_options[${#_project_options[@]}]="Enter path manually"
    _project_options[${#_project_options[@]}]="Back"

    echo ""
    menu_select "Add project to ${group_name}" "${_project_options[@]}"

    case "$MENU_RESULT" in
      "Back"|"__back__") return 0 ;;
      "Enter path manually")
        echo ""
        printf '  Path: '
        IFS= read -r target
        [[ -z "$target" ]] && return 0
        ;;
      "Add remote project")
        echo ""
        printf '  user@host: '
        IFS= read -r target
        [[ -z "$target" ]] && return 0
        printf '  Port [22]: '
        IFS= read -r port
        [[ -z "$port" ]] && port="22"
        printf '  SSH key (optional): '
        IFS= read -r key
        printf '  Project dir on remote: '
        IFS= read -r remote_path
        ;;
      *)
        # Match selected project from registry
        local _mi=0
        while (( _mi < ${#_project_paths[@]} )); do
          if [[ "$MENU_RESULT" == *"${_project_paths[$_mi]/#$HOME/~}"* ]]; then
            target="${_project_paths[$_mi]}"
            break
          fi
          _mi=$(( _mi + 1 ))
        done
        ;;
    esac
  fi

  if [[ -z "$target" ]]; then
    err "No project specified"
    return 1
  fi

  # Detect local vs remote
  if [[ "$target" == *"@"* ]]; then
    # Remote: parse user@host
    local user host
    user="${target%%@*}"
    host="${target#*@}"

    # Validate inputs
    _group_validate_user "$user" || return 1
    _group_validate_host "$host" || return 1
    _group_validate_port "$port" || return 1
    _group_validate_ssh_key "$key"

    echo ""
    groups_add_remote "$group_name" "$host" "$user" "$port" "$key" "$remote_path" || return 1

    # Test connectivity
    local _idx
    _idx=$(( $(groups_project_count "$group_name") - 1 ))

    start_spinner "Testing SSH connectivity..."
    if groups_remote_check "$group_name" "$_idx"; then
      stop_spinner
      ok "SSH connection succeeded"

      # Verify muster is installed
      start_spinner "Checking muster on remote..."
      if groups_remote_exec "$group_name" "$_idx" "command -v muster" &>/dev/null; then
        stop_spinner
        ok "muster found on remote"
      else
        stop_spinner
        warn "muster not installed on remote"
        printf '  %bInstall muster on the remote to enable group deploys%b\n' "${DIM}" "${RESET}"
      fi
    else
      stop_spinner
      warn "SSH connection failed (project still added)"
    fi
    echo ""
  else
    # Local: resolve to absolute path
    local abs_path
    if [[ "$target" == /* ]]; then
      abs_path="$target"
    elif [[ "$target" == "." ]]; then
      abs_path="$(pwd)"
    else
      abs_path="$(cd "$target" 2>/dev/null && pwd)" || {
        err "Directory not found: ${target}"
        return 1
      }
    fi

    echo ""
    groups_add_local "$group_name" "$abs_path" || return 1
    echo ""
  fi
}

# ── Remove ──

_group_cmd_remove() {
  local group_name="${1:-}"
  shift 2>/dev/null || true
  local target="${1:-}"

  if [[ -z "$group_name" ]]; then
    err "Usage: muster group remove <group> [project]"
    return 1
  fi

  if ! groups_exists "$group_name"; then
    err "Group '${group_name}' not found"
    return 1
  fi

  local total
  total=$(groups_project_count "$group_name")

  if (( total == 0 )); then
    warn "Group '${group_name}' has no projects"
    return 0
  fi

  local remove_index=-1

  if [[ -n "$target" ]]; then
    # Try to match by path or user@host or numeric index
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      remove_index="$target"
    else
      local ri=0
      while (( ri < total )); do
        local _desc
        _desc=$(groups_project_desc "$group_name" "$ri")
        if [[ "$_desc" == "$target" || "${_desc/#$HOME/~}" == "$target" ]]; then
          remove_index="$ri"
          break
        fi
        ri=$(( ri + 1 ))
      done
    fi
  elif [[ -t 0 ]]; then
    # Interactive picker
    local _options=()
    local ri=0
    while (( ri < total )); do
      local _pname _desc
      _pname=$(groups_project_name "$group_name" "$ri")
      _desc=$(groups_project_desc "$group_name" "$ri")
      [[ "${_desc:0:1}" == "/" ]] && _desc="${_desc/#$HOME/~}"
      _options[${#_options[@]}]="${_pname} (${_desc})"
      ri=$(( ri + 1 ))
    done
    _options[${#_options[@]}]="Back"

    echo ""
    menu_select "Remove project from ${group_name}" "${_options[@]}"
    [[ "$MENU_RESULT" == "Back" || "$MENU_RESULT" == "__back__" ]] && return 0

    # Find index from selection
    local si=0
    while (( si < total )); do
      local _pname _desc
      _pname=$(groups_project_name "$group_name" "$si")
      _desc=$(groups_project_desc "$group_name" "$si")
      [[ "${_desc:0:1}" == "/" ]] && _desc="${_desc/#$HOME/~}"
      if [[ "$MENU_RESULT" == "${_pname} (${_desc})" ]]; then
        remove_index="$si"
        break
      fi
      si=$(( si + 1 ))
    done
  fi

  if (( remove_index < 0 )); then
    err "Project not found: ${target}"
    return 1
  fi

  echo ""
  groups_remove_project "$group_name" "$remove_index"
  echo ""
}

# ── Rename (CLI) ──

_group_cmd_rename_cli() {
  local group_name="${1:-}"
  local new_name="${2:-}"

  if [[ -z "$group_name" ]]; then
    err "Usage: muster group rename <group> <new-name>"
    return 1
  fi

  if ! groups_exists "$group_name"; then
    err "Group '${group_name}' not found"
    return 1
  fi

  if [[ -z "$new_name" ]]; then
    if [[ -t 0 ]]; then
      _group_rename "$group_name"
      return $?
    fi
    err "Usage: muster group rename <group> <new-name>"
    return 1
  fi

  groups_set ".groups.\"${group_name}\".name" "\"${new_name}\""
  ok "Renamed group '${group_name}' to '${new_name}'"
}

# ── Edit (CLI) ──

_group_cmd_edit_cli() {
  local group_name="${1:-}"
  shift 2>/dev/null || true
  local index="${1:-}"
  shift 2>/dev/null || true

  if [[ -z "$group_name" ]]; then
    err "Usage: muster group edit <group> <index> [--host H] [--user U] [--port P] [--key K] [--path D]"
    return 1
  fi

  if ! groups_exists "$group_name"; then
    err "Group '${group_name}' not found"
    return 1
  fi

  # No index: interactive
  if [[ -z "$index" ]]; then
    if [[ -t 0 ]]; then
      _group_edit_project "$group_name"
      return $?
    fi
    err "Usage: muster group edit <group> <index> [--host H] [--user U] [--port P] [--key K] [--path D]"
    return 1
  fi

  # Validate index
  local total
  total=$(groups_project_count "$group_name")
  if ! [[ "$index" =~ ^[0-9]+$ ]] || (( index >= total )); then
    err "Invalid project index: ${index} (group has ${total} project(s), 0-indexed)"
    return 1
  fi

  local _type
  _type=$(jq -r --arg n "$group_name" --argjson i "$index" \
    '.groups[$n].projects[$i].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)

  if [[ "$_type" != "remote" ]]; then
    err "Only remote projects can be edited via CLI (local projects: remove and re-add)"
    return 1
  fi

  # Parse flags
  local new_host="" new_user="" new_port="" new_key="" new_dir=""
  local has_changes=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)  new_host="$2"; has_changes=true; shift 2 ;;
      --user)  new_user="$2"; has_changes=true; shift 2 ;;
      --port|-p) new_port="$2"; has_changes=true; shift 2 ;;
      --key|-k)  new_key="$2"; has_changes=true; shift 2 ;;
      --path)  new_dir="$2"; has_changes=true; shift 2 ;;
      --help|-h)
        echo "Usage: muster group edit <group> <index> [--host H] [--user U] [--port P] [--key K] [--path D]"
        return 0
        ;;
      *) err "Unknown flag: $1"; return 1 ;;
    esac
  done

  if [[ "$has_changes" == "false" ]]; then
    if [[ -t 0 ]]; then
      _group_edit_remote_fields "$group_name" "$index"
      return $?
    fi
    err "No changes specified. Use --host, --user, --port, --key, or --path."
    return 1
  fi

  # Validate provided fields
  [[ -n "$new_host" ]] && { _group_validate_host "$new_host" || return 1; }
  [[ -n "$new_user" ]] && { _group_validate_user "$new_user" || return 1; }
  [[ -n "$new_port" ]] && { _group_validate_port "$new_port" || return 1; }
  [[ -n "$new_key" ]]  && _group_validate_ssh_key "$new_key"

  # Apply only specified fields
  local tmp="${GROUPS_CONFIG_FILE}.tmp"
  local jq_expr=""
  [[ -n "$new_host" ]] && jq_expr="${jq_expr} | .groups[\$g].projects[\$i].host = \$host"
  [[ -n "$new_user" ]] && jq_expr="${jq_expr} | .groups[\$g].projects[\$i].user = \$user"
  [[ -n "$new_port" ]] && jq_expr="${jq_expr} | .groups[\$g].projects[\$i].port = (\$port | tonumber)"
  [[ -n "$new_key" ]]  && jq_expr="${jq_expr} | .groups[\$g].projects[\$i].identity_file = \$key"
  [[ -n "$new_dir" ]]  && jq_expr="${jq_expr} | .groups[\$g].projects[\$i].project_dir = \$dir"

  # Strip leading " | "
  jq_expr="${jq_expr# | }"

  jq --arg g "$group_name" --argjson i "$index" \
    --arg host "${new_host:-}" --arg user "${new_user:-}" \
    --arg port "${new_port:-0}" --arg key "${new_key:-}" --arg dir "${new_dir:-}" \
    "$jq_expr" "$GROUPS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GROUPS_CONFIG_FILE"

  ok "Updated remote project at index ${index}"
}

# ── Reorder (CLI) ──

_group_cmd_reorder_cli() {
  local group_name="${1:-}"

  if [[ -z "$group_name" ]]; then
    err "Usage: muster group reorder <group>"
    return 1
  fi

  if ! groups_exists "$group_name"; then
    err "Group '${group_name}' not found"
    return 1
  fi

  if [[ -t 0 ]]; then
    _group_reorder "$group_name"
  else
    err "Reorder requires an interactive terminal"
    return 1
  fi
}

# ── Deploy ──

_group_cmd_deploy() {
  local group_name="${1:-}"
  local dry_run=false

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true; shift ;;
      --help|-h)
        echo "Usage: muster group deploy <group> [--dry-run]"
        return 0
        ;;
      --*) err "Unknown flag: $1"; return 1 ;;
      *)
        [[ -z "$group_name" ]] && group_name="$1"
        shift
        ;;
    esac
  done

  # Interactive group picker if no arg
  if [[ -z "$group_name" ]]; then
    local group_names=()
    while IFS= read -r g; do
      [[ -z "$g" ]] && continue
      group_names[${#group_names[@]}]="$g"
    done < <(groups_list)

    if (( ${#group_names[@]} == 0 )); then
      info "No groups configured. Create one: muster group create <name>"
      return 0
    fi

    if (( ${#group_names[@]} == 1 )); then
      group_name="${group_names[0]}"
    else
      echo ""
      group_names[${#group_names[@]}]="Back"
      menu_select "Select group to deploy" "${group_names[@]}"
      [[ "$MENU_RESULT" == "Back" || "$MENU_RESULT" == "__back__" ]] && return 0
      group_name="$MENU_RESULT"
    fi
  fi

  if ! groups_exists "$group_name"; then
    err "Group '${group_name}' not found"
    return 1
  fi

  local total
  total=$(groups_project_count "$group_name")

  if (( total == 0 )); then
    warn "Group '${group_name}' has no projects"
    return 0
  fi

  # Dry run
  if [[ "$dry_run" == "true" ]]; then
    _group_deploy_dry_run "$group_name" "$total"
    return 0
  fi

  local display_name
  display_name=$(groups_get ".groups.\"${group_name}\".name")
  [[ "$display_name" == "null" || -z "$display_name" ]] && display_name="$group_name"

  local succeeded=0 failed=0 skipped=0
  local log_dir="$HOME/.muster/logs"
  mkdir -p "$log_dir"

  # Catch Ctrl+C so we don't falsely report success
  local _group_interrupted=false
  trap '_group_interrupted=true' INT

  echo ""
  printf '  %b%bGroup Deploy%b — %s (%d project%s)\n' \
    "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}" \
    "$display_name" "$total" "$([ "$total" != "1" ] && echo "s")"
  echo ""

  local i=0
  while (( i < total )); do
    local current=$(( i + 1 ))

    local _type _pname
    _type=$(jq -r --arg n "$group_name" --argjson idx "$i" \
      '.groups[$n].projects[$idx].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)
    _pname=$(groups_project_name "$group_name" "$i")

    local log_file="${log_dir}/group-${group_name}-${_pname}-$(date +%Y%m%d-%H%M%S).log"
    local rc=0
    local _svc_total=0

    while true; do
      # Progress bar
      progress_bar "$i" "$total" "${_pname}"
      echo ""

      if [[ "$_type" == "local" ]]; then
        # ── Local project: iterate services individually ──
        local _path
        _path=$(jq -r --arg n "$group_name" --argjson idx "$i" \
          '.groups[$n].projects[$idx].path' "$GROUPS_CONFIG_FILE" 2>/dev/null)

        # Pre-flight checks
        if [[ -z "$_path" || "$_path" == "null" ]]; then
          err "Project has no path configured"
          rc=1
        elif [[ ! -d "$_path" ]]; then
          err "Project directory not found: ${_path}"
          rc=1
        else
          local _cfg=""
          [[ -f "${_path}/deploy.json" ]] && _cfg="${_path}/deploy.json"
          [[ -z "$_cfg" && -f "${_path}/muster.json" ]] && _cfg="${_path}/muster.json"

          if [[ -z "$_cfg" ]]; then
            err "No deploy.json found in ${_path}"
            rc=1
          else
            # Get deploy order
            local _services=()
            local _svc_line
            while IFS= read -r _svc_line; do
              [[ -z "$_svc_line" ]] && continue
              local _skip
              _skip=$(jq -r --arg s "$_svc_line" '.services[$s].skip_deploy // "false"' "$_cfg" 2>/dev/null)
              [[ "$_skip" == "true" ]] && continue
              _services[${#_services[@]}]="$_svc_line"
            done < <(jq -r '(.deploy_order[]? // empty)' "$_cfg" 2>/dev/null)

            if (( ${#_services[@]} == 0 )); then
              while IFS= read -r _svc_line; do
                [[ -z "$_svc_line" ]] && continue
                local _skip
                _skip=$(jq -r --arg s "$_svc_line" '.services[$s].skip_deploy // "false"' "$_cfg" 2>/dev/null)
                [[ "$_skip" == "true" ]] && continue
                _services[${#_services[@]}]="$_svc_line"
              done < <(jq -r '.services | keys[]' "$_cfg" 2>/dev/null)
            fi

            _svc_total=${#_services[@]}

            # Load .env if present
            if [[ -f "${_path}/.env" ]]; then
              while IFS= read -r _envline || [[ -n "$_envline" ]]; do
                _envline=$(printf '%s' "$_envline" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$_envline" || "$_envline" == \#* ]] && continue
                local _ek="${_envline%%=*}" _ev="${_envline#*=}"
                [[ -z "$_ek" ]] && continue
                [[ -z "${!_ek:-}" ]] && export "$_ek=$_ev"
              done < "${_path}/.env"
            fi

            # Pre-authenticate sudo if any hooks use it
            local _any_sudo=false
            for _sudo_svc in "${_services[@]}"; do
              local _sudo_hook="${_path}/.muster/hooks/${_sudo_svc}/deploy.sh"
              if [[ -f "$_sudo_hook" ]] && grep -q 'sudo' "$_sudo_hook" 2>/dev/null; then
                _any_sudo=true
                break
              fi
            done
            if [[ "$_any_sudo" == "true" ]]; then
              # Check if sudo is already cached (no password needed)
              local _sudo_was_cached=false
              sudo -n true 2>/dev/null && _sudo_was_cached=true
              sudo -v || true
              if [[ "$_sudo_was_cached" == "false" ]]; then
                printf '  %b✓%b Authenticated\n' "${GREEN}" "${RESET}"
                printf '    %bSave?%b  1) Session  2) Always ask  3) Never ' "${DIM}" "${RESET}"
                local _sudo_ch=""
                IFS= read -rsn1 -t 3 _sudo_ch 2>/dev/null || true
                printf '\r\033[K'
              fi
            fi

            # Deploy each service with animated preview
            update_term_size
            local _sp_f=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local _svc_idx=0
            rc=0
            for _svc in "${_services[@]}"; do
              _svc_idx=$(( _svc_idx + 1 ))
              local _svc_name
              _svc_name=$(jq -r --arg s "$_svc" '.services[$s].name // $s' "$_cfg" 2>/dev/null)

              # Check for interruption
              if [[ "$_group_interrupted" == "true" ]]; then
                rc=130
                break
              fi

              # Handle credentials (foreground, interactive)
              local _cred_env=""
              _cred_env=$(_group_cred_for_service "$_cfg" "$_svc") || true
              if [[ -n "$_cred_env" ]]; then
                while IFS='=' read -r _ck _cv; do
                  [[ -z "$_ck" ]] && continue
                  export "$_ck=$_cv"
                done <<< "$_cred_env"

                # Credential save prompt (passive, 3s timeout)
                local _g_cur_mode
                _g_cur_mode=$(jq -r --arg s "$_svc" '.services[$s].credentials.mode // ""' "$_cfg" 2>/dev/null)
                if [[ "$_g_cur_mode" == "session" || "$_g_cur_mode" == "always" ]]; then
                  printf '    %bSave?%b  1) Keychain  2) Session  3) Skip ' "${DIM}" "${RESET}"
                  local _save_ch=""
                  IFS= read -rsn1 -t 3 _save_ch 2>/dev/null || true
                  case "$_save_ch" in
                    1)
                      local _tmp_cfg
                      _tmp_cfg=$(jq --arg s "$_svc" '.services[$s].credentials.mode = "save"' "$_cfg") && printf '%s' "$_tmp_cfg" > "$_cfg"
                      printf ' %bsaved%b' "${GREEN}" "${RESET}"
                      ;;
                  esac
                  printf '\r\033[K'
                fi
              fi

              # Export k8s env vars
              local _k8s_dep _k8s_ns
              _k8s_dep=$(jq -r --arg s "$_svc" '.services[$s].k8s.deployment // ""' "$_cfg" 2>/dev/null)
              _k8s_ns=$(jq -r --arg s "$_svc" '.services[$s].k8s.namespace // ""' "$_cfg" 2>/dev/null)
              [[ -n "$_k8s_dep" && "$_k8s_dep" != "null" ]] && export MUSTER_K8S_DEPLOYMENT="$_k8s_dep"
              [[ -n "$_k8s_ns" && "$_k8s_ns" != "null" ]] && export MUSTER_K8S_NAMESPACE="$_k8s_ns"
              export MUSTER_K8S_SERVICE="${_svc//_/-}"
              export MUSTER_SERVICE_NAME="$_svc_name"

              local _timeout
              _timeout=$(jq -r --arg s "$_svc" '.services[$s].deploy_timeout // 120' "$_cfg" 2>/dev/null)
              export MUSTER_DEPLOY_TIMEOUT="$_timeout"

              local _deploy_mode
              _deploy_mode=$(jq -r --arg s "$_svc" '.services[$s].deploy_mode // ""' "$_cfg" 2>/dev/null)
              [[ -n "$_deploy_mode" && "$_deploy_mode" != "null" ]] && export MUSTER_DEPLOY_MODE="$_deploy_mode"

              # Find deploy hook
              local _hook="${_path}/.muster/hooks/${_svc}/deploy.sh"
              if [[ ! -x "$_hook" ]]; then
                warn "No deploy hook for ${_svc_name}, skipping"
                continue
              fi

              local _svc_log="${log_dir}/group-${group_name}-${_pname}-${_svc}-$(date +%Y%m%d-%H%M%S).log"
              : > "$_svc_log"

              # Run hook in background, output to log
              (cd "$_path" && "$_hook") >> "$_svc_log" 2>&1 &
              local _hook_pid=$!

              # Foreground animation: spinner + 3-line log preview
              local _sp_i=0
              local _anim_h=4
              local _pw=$(( TERM_COLS - 8 ))
              (( _pw > 68 )) && _pw=68
              (( _pw < 10 )) && _pw=10

              # Print initial placeholder (4 lines)
              printf '  %b%s%b %bDeploying %s (%d/%d)%b\n' \
                "${ACCENT}" "${_sp_f[0]}" "${RESET}" "${WHITE}" "$_svc_name" "$_svc_idx" "$_svc_total" "${RESET}"
              printf '\033[K\n\033[K\n\033[K\n'

              while kill -0 "$_hook_pid" 2>/dev/null; do
                [[ "$_group_interrupted" == "true" ]] && { kill "$_hook_pid" 2>/dev/null; break; }
                printf '\033[%dA' "$_anim_h"
                printf '  %b%s%b %bDeploying %s (%d/%d)%b\033[K\n' \
                  "${ACCENT}" "${_sp_f[$((_sp_i % 10))]}" "${RESET}" \
                  "${WHITE}" "$_svc_name" "$_svc_idx" "$_svc_total" "${RESET}"
                _sp_i=$(( _sp_i + 1 ))

                local _t0="" _t1="" _t2="" _ti=0
                while IFS= read -r _tl; do
                  _tl=$(printf '%s' "$_tl" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
                  case $_ti in 0) _t0="$_tl" ;; 1) _t1="$_tl" ;; 2) _t2="$_tl" ;; esac
                  _ti=$((_ti + 1))
                done < <(tail -3 "$_svc_log" 2>/dev/null)

                local _tp=""
                for _tp in "$_t0" "$_t1" "$_t2"; do
                  (( ${#_tp} > _pw )) && _tp="${_tp:0:$((_pw - 3))}..."
                  printf '    %b%s%b\033[K\n' "${DIM}" "$_tp" "${RESET}"
                done

                sleep 1
              done

              wait "$_hook_pid" 2>/dev/null
              local _svc_rc=$?

              # Append service log to project log
              cat "$_svc_log" >> "$log_file" 2>/dev/null

              # Clear animation, show result
              printf '\033[%dA' "$_anim_h"
              if (( _svc_rc == 0 )); then
                printf '  %b✓%b %s\033[K\n' "${GREEN}" "${RESET}" "$_svc_name"
              else
                printf '  %b✗%b %s\033[K\n' "${RED}" "${RESET}" "$_svc_name"
              fi
              printf '\033[K\n\033[K\n\033[K'
              printf '\033[2A'

              if (( _svc_rc != 0 )); then
                echo ""
                if [[ -s "$_svc_log" ]]; then
                  tail -5 "$_svc_log" | while IFS= read -r _eline; do
                    _eline=$(printf '%s' "$_eline" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
                    printf '    %b%s%b\n' "${RED}" "$_eline" "${RESET}"
                  done
                fi
                rc="$_svc_rc"
                break
              fi

              # Cleanup credential env vars
              if [[ -n "$_cred_env" ]]; then
                while IFS='=' read -r _ck _cv; do
                  [[ -z "$_ck" ]] && continue
                  unset "$_ck"
                done <<< "$_cred_env"
              fi
            done
          fi
        fi

      else
        # ── Remote project: deploy with animated preview ──
        : > "$log_file"
        _group_deploy_remote "$group_name" "$i" "$log_file" &
        local _remote_pid=$!

        update_term_size
        local _sp_f=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        local _sp_i=0
        local _anim_h=4
        local _pw=$(( TERM_COLS - 8 ))
        (( _pw > 68 )) && _pw=68
        (( _pw < 10 )) && _pw=10

        printf '  %b%s%b %bDeploying %s remotely%b\n' \
          "${ACCENT}" "${_sp_f[0]}" "${RESET}" "${WHITE}" "$_pname" "${RESET}"
        printf '\033[K\n\033[K\n\033[K\n'

        while kill -0 "$_remote_pid" 2>/dev/null; do
          [[ "$_group_interrupted" == "true" ]] && { kill "$_remote_pid" 2>/dev/null; break; }
          printf '\033[%dA' "$_anim_h"
          printf '  %b%s%b %bDeploying %s remotely%b\033[K\n' \
            "${ACCENT}" "${_sp_f[$((_sp_i % 10))]}" "${RESET}" \
            "${WHITE}" "$_pname" "${RESET}"
          _sp_i=$(( _sp_i + 1 ))

          local _t0="" _t1="" _t2="" _ti=0
          while IFS= read -r _tl; do
            _tl=$(printf '%s' "$_tl" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
            case $_ti in 0) _t0="$_tl" ;; 1) _t1="$_tl" ;; 2) _t2="$_tl" ;; esac
            _ti=$((_ti + 1))
          done < <(tail -3 "$log_file" 2>/dev/null)

          local _tp=""
          for _tp in "$_t0" "$_t1" "$_t2"; do
            (( ${#_tp} > _pw )) && _tp="${_tp:0:$((_pw - 3))}..."
            printf '    %b%s%b\033[K\n' "${DIM}" "$_tp" "${RESET}"
          done

          sleep 1
        done

        wait "$_remote_pid" 2>/dev/null
        rc=$?

        printf '\033[%dA' "$_anim_h"
        if (( rc == 0 )); then
          printf '  %b✓%b %s\033[K\n' "${GREEN}" "${RESET}" "$_pname"
        else
          printf '  %b✗%b %s\033[K\n' "${RED}" "${RESET}" "$_pname"
        fi
        printf '\033[K\n\033[K\n\033[K'
        printf '\033[2A'

        if (( rc != 0 )); then
          echo ""
          if [[ -s "$log_file" ]]; then
            tail -5 "$log_file" | while IFS= read -r _eline; do
              _eline=$(printf '%s' "$_eline" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
              printf '    %b%s%b\n' "${RED}" "$_eline" "${RESET}"
            done
          fi
        fi
      fi

      # Handle interruption
      if [[ "$_group_interrupted" == "true" ]]; then
        err "${_pname} deploy interrupted"
        failed=$(( total - succeeded - skipped ))
        echo ""
        _group_deploy_summary "$succeeded" "$skipped" "$failed" "$total"
        trap - INT
        return 130
      fi

      if (( rc == 0 )); then
        echo ""
        progress_bar "$current" "$total" "${_pname}"
        echo ""
        if (( _svc_total > 1 )); then
          printf '  %b✓%b %s deployed (%d services)\n' "${GREEN}" "${RESET}" "$_pname" "$_svc_total"
        else
          printf '  %b✓%b %s deployed\n' "${GREEN}" "${RESET}" "$_pname"
        fi
        succeeded=$(( succeeded + 1 ))
        break
      else
        echo ""
        progress_bar "$i" "$total" "${_pname}" "error"
        echo ""
        echo ""
        menu_select "Deploy failed on ${_pname}" \
          "Retry" "Skip and continue" "Abort"

        case "$MENU_RESULT" in
          "Retry")
            log_file="${log_dir}/group-${group_name}-${_pname}-$(date +%Y%m%d-%H%M%S).log"
            continue
            ;;
          "Skip and continue")
            skipped=$(( skipped + 1 ))
            break
            ;;
          "Abort"|"__back__")
            failed=$(( total - succeeded - skipped ))
            echo ""
            _group_deploy_summary "$succeeded" "$skipped" "$failed" "$total"
            trap - INT
            return 1
            ;;
        esac
      fi
    done

    i=$(( i + 1 ))
  done

  trap - INT
  echo ""
  _group_deploy_summary "$succeeded" "$skipped" "$failed" "$total"
}

_group_deploy_remote() {
  local group_name="$1" index="$2" log_file="$3"
  _groups_load_remote "$group_name" "$index"
  _groups_build_ssh_opts

  # Pre-flight: check SSH connectivity
  # shellcheck disable=SC2086 — $_GROUPS_SSH_OPTS intentionally unquoted for word-splitting
  if ! ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "echo ok" &>/dev/null; then
    printf 'Cannot reach %s@%s — check SSH config and connectivity\n' "$_GP_USER" "$_GP_HOST" > "$log_file"
    return 1
  fi

  local cmd="muster deploy --quiet"
  if [[ -n "$_GP_PROJECT_DIR" ]]; then
    local _escaped_dir
    printf -v _escaped_dir '%q' "$_GP_PROJECT_DIR"
    cmd="cd ${_escaped_dir} && ${cmd}"
  fi

  # shellcheck disable=SC2086 — $_GROUPS_SSH_OPTS intentionally unquoted for word-splitting
  ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "$cmd" >> "$log_file" 2>&1
}

_group_deploy_dry_run() {
  local group_name="$1" total="$2"
  echo ""
  printf '  %b%bDry Run%b — %s (%d project%s)\n' \
    "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}" \
    "$group_name" "$total" "$([ "$total" != "1" ] && echo "s")"
  echo ""

  local i=0
  while (( i < total )); do
    local _type _pname _desc
    _type=$(jq -r --arg n "$group_name" --argjson idx "$i" \
      '.groups[$n].projects[$idx].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)
    _pname=$(groups_project_name "$group_name" "$i")
    _desc=$(groups_project_desc "$group_name" "$i")

    local _icon _color _tag
    if [[ "$_type" == "local" ]]; then
      _tag="local"
      if [[ -d "$_desc" ]]; then
        _icon="●"; _color="${GREEN}"
      else
        _icon="●"; _color="${RED}"; _tag="missing"
      fi
      _desc="${_desc/#$HOME/~}"
    else
      _tag="remote"
      _icon="◆"; _color="${ACCENT}"
    fi

    printf '  %b%d.%b %b%s%b %b%s%b  %b%s%b\n' \
      "${DIM}" "$(( i + 1 ))" "${RESET}" \
      "$_color" "$_icon" "${RESET}" \
      "${WHITE}" "$_pname" "${RESET}" \
      "${DIM}" "$_tag" "${RESET}"

    i=$(( i + 1 ))
  done
  echo ""
}

_group_deploy_summary() {
  local succeeded="$1" skipped="$2" failed="$3" total="$4"

  if (( failed == 0 && skipped == 0 )); then
    ok "Group deploy complete (${succeeded}/${total} succeeded)"
  elif (( failed > 0 )); then
    err "Group deploy: ${succeeded} succeeded, ${skipped} skipped, ${failed} failed (${total} total)"
  else
    warn "Group deploy: ${succeeded} succeeded, ${skipped} skipped (${total} total)"
  fi
  echo ""
}

# ── Status ──

_group_cmd_status() {
  local group_name="${1:-}"
  local json_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)  json_mode=true; shift ;;
      --help|-h)
        echo "Usage: muster group status <group> [--json]"
        return 0
        ;;
      --*) err "Unknown flag: $1"; return 1 ;;
      *)
        [[ -z "$group_name" ]] && group_name="$1"
        shift
        ;;
    esac
  done

  # Interactive group picker if no arg
  if [[ -z "$group_name" ]]; then
    local group_names=()
    while IFS= read -r g; do
      [[ -z "$g" ]] && continue
      group_names[${#group_names[@]}]="$g"
    done < <(groups_list)

    if (( ${#group_names[@]} == 0 )); then
      info "No groups configured"
      return 0
    fi

    if (( ${#group_names[@]} == 1 )); then
      group_name="${group_names[0]}"
    else
      echo ""
      group_names[${#group_names[@]}]="Back"
      menu_select "Select group" "${group_names[@]}"
      [[ "$MENU_RESULT" == "Back" || "$MENU_RESULT" == "__back__" ]] && return 0
      group_name="$MENU_RESULT"
    fi
  fi

  if ! groups_exists "$group_name"; then
    err "Group '${group_name}' not found"
    return 1
  fi

  local total
  total=$(groups_project_count "$group_name")

  if (( total == 0 )); then
    warn "Group '${group_name}' has no projects"
    return 0
  fi

  # JSON mode
  if [[ "$json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
    _group_status_json "$group_name" "$total"
    return 0
  fi

  local display_name
  display_name=$(groups_get ".groups.\"${group_name}\".name")
  [[ "$display_name" == "null" || -z "$display_name" ]] && display_name="$group_name"

  echo ""
  printf '  %b%bGroup Status%b — %s\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}" "$display_name"
  echo ""

  local i=0
  while (( i < total )); do
    local _type _pname
    _type=$(jq -r --arg n "$group_name" --argjson idx "$i" \
      '.groups[$n].projects[$idx].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)
    _pname=$(groups_project_name "$group_name" "$i")

    local _icon _color _tag _result=""

    if [[ "$_type" == "local" ]]; then
      local _path
      _path=$(jq -r --arg n "$group_name" --argjson idx "$i" \
        '.groups[$n].projects[$idx].path' "$GROUPS_CONFIG_FILE" 2>/dev/null)

      if [[ -z "$_path" || "$_path" == "null" || ! -d "$_path" ]]; then
        _icon="●"; _color="${RED}"; _tag="missing"
      else
        local _muster_bin="${MUSTER_ROOT}/bin/muster"
        _result=$(cd "$_path" && "$_muster_bin" status --json 2>/dev/null) || true
      fi
    else
      # Remote: check SSH then muster status
      _groups_load_remote "$group_name" "$i"
      _groups_build_ssh_opts

      # shellcheck disable=SC2086 — $_GROUPS_SSH_OPTS intentionally unquoted for word-splitting
      if ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "echo ok" &>/dev/null; then
        local cmd="muster status --json"
        if [[ -n "$_GP_PROJECT_DIR" ]]; then
          local _escaped_dir
          printf -v _escaped_dir '%q' "$_GP_PROJECT_DIR"
          cmd="cd ${_escaped_dir} && ${cmd}"
        fi
        # shellcheck disable=SC2086 — $_GROUPS_SSH_OPTS intentionally unquoted for word-splitting
        _result=$(ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "$cmd" 2>/dev/null) || true
      else
        _icon="●"; _color="${RED}"; _tag="unreachable"
      fi
    fi

    # Parse service results
    local _svc_keys="" _svc_count=0 _healthy=0
    if [[ -n "$_result" ]] && printf '%s' "$_result" | jq -e '.services' &>/dev/null; then
      # Use deploy_order for local projects, keys[] for remote/fallback
      _svc_keys=""
      if [[ "$_type" == "local" && -n "${_path:-}" ]]; then
        local _svc_cfg=""
        [[ -f "${_path}/deploy.json" ]] && _svc_cfg="${_path}/deploy.json"
        [[ -z "$_svc_cfg" && -f "${_path}/muster.json" ]] && _svc_cfg="${_path}/muster.json"
        [[ -n "$_svc_cfg" ]] && _svc_keys=$(jq -r '(.deploy_order[]? // empty)' "$_svc_cfg" 2>/dev/null)
      fi
      [[ -z "$_svc_keys" ]] && _svc_keys=$(printf '%s' "$_result" | jq -r '.services | keys[]' 2>/dev/null)
      _svc_count=$(printf '%s' "$_result" | jq '[.services | to_entries[]] | length' 2>/dev/null)
      _healthy=$(printf '%s' "$_result" | jq '[.services | to_entries[] | select(.value.status == "healthy")] | length' 2>/dev/null)
      [[ -z "$_svc_count" ]] && _svc_count=0
      [[ -z "$_healthy" ]] && _healthy=0

      if (( _healthy == _svc_count && _svc_count > 0 )); then
        _icon="●"; _color="${GREEN}"; _tag="${_healthy}/${_svc_count} healthy"
      elif (( _healthy > 0 )); then
        _icon="●"; _color="${YELLOW}"; _tag="${_healthy}/${_svc_count} healthy"
      else
        _icon="●"; _color="${RED}"; _tag="0/${_svc_count} healthy"
      fi
    elif [[ -z "$_tag" ]]; then
      # No result and no tag set yet (not missing/unreachable)
      if [[ "$_type" != "local" ]]; then
        _icon="●"; _color="${GREEN}"; _tag="reachable"
      else
        _icon="●"; _color="${YELLOW}"; _tag="no status"
      fi
    fi

    # ── Render project header line ──
    local w=$(( TERM_COLS - 4 ))
    (( w > 50 )) && w=50
    (( w < 10 )) && w=10

    local content_len=$(( 6 + ${#_pname} + ${#_tag} ))
    local dots_len=$(( w - content_len ))
    (( dots_len < 3 )) && dots_len=3
    local dots=""
    local di=0
    while (( di < dots_len )); do
      dots="${dots}·"
      di=$(( di + 1 ))
    done

    printf '  %b%s%b %b%s%b %b%s%b %b%s%b\n' \
      "$_color" "$_icon" "${RESET}" \
      "${WHITE}" "$_pname" "${RESET}" \
      "${DIM}" "$dots" "${RESET}" \
      "$_color" "$_tag" "${RESET}"

    # ── Render per-service lines ──
    if [[ -n "$_svc_keys" ]]; then
      while IFS= read -r _sk; do
        [[ -z "$_sk" ]] && continue
        local _s_status _s_name _s_icon _s_color
        _s_status=$(printf '%s' "$_result" | jq -r --arg k "$_sk" '.services[$k].status // "unknown"' 2>/dev/null)
        _s_name=$(printf '%s' "$_result" | jq -r --arg k "$_sk" '.services[$k].name // $k' 2>/dev/null)

        case "$_s_status" in
          healthy)   _s_icon="●"; _s_color="${GREEN}" ;;
          unhealthy) _s_icon="●"; _s_color="${RED}" ;;
          *)         _s_icon="○"; _s_color="${GRAY}" ;;
        esac

        local _s_content_len=$(( 10 + ${#_s_name} + ${#_s_status} ))
        local _s_dots_len=$(( w - _s_content_len ))
        (( _s_dots_len < 3 )) && _s_dots_len=3
        local _s_dots=""
        local _sdi=0
        while (( _sdi < _s_dots_len )); do
          _s_dots="${_s_dots}·"
          _sdi=$(( _sdi + 1 ))
        done

        printf '      %b%s%b %b%s%b %b%s%b %b%s%b\n' \
          "$_s_color" "$_s_icon" "${RESET}" \
          "${DIM}" "$_s_name" "${RESET}" \
          "${DIM}" "$_s_dots" "${RESET}" \
          "$_s_color" "$_s_status" "${RESET}"
      done <<< "$_svc_keys"
    fi

    i=$(( i + 1 ))
  done
  echo ""
}

_group_status_json() {
  local group_name="$1" total="$2"
  local json_output="[]"
  local i=0
  while (( i < total )); do
    local _type _pname _desc
    _type=$(jq -r --arg n "$group_name" --argjson idx "$i" \
      '.groups[$n].projects[$idx].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)
    _pname=$(groups_project_name "$group_name" "$i")
    _desc=$(groups_project_desc "$group_name" "$i")

    local _status="unknown"
    if [[ "$_type" == "local" ]]; then
      if [[ -d "$_desc" ]]; then
        _status="ok"
      else
        _status="missing"
      fi
    else
      if groups_remote_check "$group_name" "$i" 2>/dev/null; then
        _status="reachable"
      else
        _status="unreachable"
      fi
    fi

    json_output=$(printf '%s' "$json_output" | jq --arg n "$_pname" --arg t "$_type" --arg s "$_status" \
      '. + [{"name":$n,"type":$t,"status":$s}]')
    i=$(( i + 1 ))
  done
  jq -n --arg g "$group_name" --argjson p "$json_output" '{"group":$g,"projects":$p}'
}

# ── Interactive Manager ──

_group_cmd_manager() {
  _groups_ensure_file

  while true; do
    clear
    echo ""
    printf '  %b%bFleet Groups%b\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}"
    echo ""

    local group_names=()
    while IFS= read -r g; do
      [[ -z "$g" ]] && continue
      group_names[${#group_names[@]}]="$g"
    done < <(groups_list)

    if (( ${#group_names[@]} > 0 )); then
      # Show group summary
      local gi=0
      while (( gi < ${#group_names[@]} )); do
        local gname="${group_names[$gi]}"
        local display_name
        display_name=$(groups_get ".groups.\"${gname}\".name")
        [[ "$display_name" == "null" || -z "$display_name" ]] && display_name="$gname"
        local total
        total=$(groups_project_count "$gname")
        printf '  %b●%b %b%s%b %b(%d project%s)%b\n' \
          "${ACCENT}" "${RESET}" \
          "${WHITE}" "$display_name" "${RESET}" \
          "${DIM}" "$total" "$([ "$total" != "1" ] && echo "s")" "${RESET}"
        gi=$(( gi + 1 ))
      done
      echo ""
    else
      printf '  %bNo groups yet. Create one to get started.%b\n' "${DIM}" "${RESET}"
      echo ""
    fi

    local actions=()
    local gi=0
    while (( gi < ${#group_names[@]} )); do
      local _dn
      _dn=$(groups_get ".groups.\"${group_names[$gi]}\".name")
      [[ "$_dn" == "null" || -z "$_dn" ]] && _dn="${group_names[$gi]}"
      actions[${#actions[@]}]="$_dn"
      gi=$(( gi + 1 ))
    done
    actions[${#actions[@]}]="Create group"
    actions[${#actions[@]}]="Back"

    menu_select "Groups" "${actions[@]}"

    case "$MENU_RESULT" in
      "Create group")
        _group_cmd_create
        ;;
      "Back"|"__back__")
        return 0
        ;;
      *)
        # Find matching group name
        local _matched=""
        local mi=0
        while (( mi < ${#group_names[@]} )); do
          local _dn
          _dn=$(groups_get ".groups.\"${group_names[$mi]}\".name")
          [[ "$_dn" == "null" || -z "$_dn" ]] && _dn="${group_names[$mi]}"
          if [[ "$MENU_RESULT" == "$_dn" ]]; then
            _matched="${group_names[$mi]}"
            break
          fi
          mi=$(( mi + 1 ))
        done

        if [[ -n "$_matched" ]]; then
          _group_detail_menu "$_matched"
        fi
        ;;
    esac
  done
}

# ── Rename ──

_group_rename() {
  local group_name="$1"
  local display_name
  display_name=$(groups_get ".groups.\"${group_name}\".name")
  [[ "$display_name" == "null" || -z "$display_name" ]] && display_name="$group_name"

  echo ""
  printf '  Current name: %b%s%b\n' "${WHITE}" "$display_name" "${RESET}"
  printf '  New name: '
  local new_name
  IFS= read -r new_name
  [[ -z "$new_name" ]] && return 0

  groups_set ".groups.\"${group_name}\".name" "\"${new_name}\""
  echo ""
  ok "Renamed to '${new_name}'"
  echo ""
  printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
  IFS= read -rsn1 || true
}

# ── Edit project ──

_group_edit_project() {
  local group_name="$1"
  local total
  total=$(groups_project_count "$group_name")

  if (( total == 0 )); then
    warn "No projects to edit"
    return 0
  fi

  # Build picker
  local options=()
  local pi=0
  while (( pi < total )); do
    local _pname _desc _type
    _pname=$(groups_project_name "$group_name" "$pi")
    _type=$(jq -r --arg n "$group_name" --argjson i "$pi" \
      '.groups[$n].projects[$i].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)
    _desc=$(groups_project_desc "$group_name" "$pi")
    [[ "${_desc:0:1}" == "/" ]] && _desc="${_desc/#$HOME/~}"
    options[${#options[@]}]="${_pname} (${_desc})"
    pi=$(( pi + 1 ))
  done
  options[${#options[@]}]="Back"

  echo ""
  menu_select "Edit which project?" "${options[@]}"
  [[ "$MENU_RESULT" == "Back" || "$MENU_RESULT" == "__back__" ]] && return 0

  # Find selected index
  local sel_idx=-1 si=0
  while (( si < total )); do
    local _pname _desc
    _pname=$(groups_project_name "$group_name" "$si")
    _desc=$(groups_project_desc "$group_name" "$si")
    [[ "${_desc:0:1}" == "/" ]] && _desc="${_desc/#$HOME/~}"
    if [[ "$MENU_RESULT" == "${_pname} (${_desc})" ]]; then
      sel_idx="$si"
      break
    fi
    si=$(( si + 1 ))
  done
  (( sel_idx < 0 )) && return 0

  local _type
  _type=$(jq -r --arg n "$group_name" --argjson i "$sel_idx" \
    '.groups[$n].projects[$i].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)

  if [[ "$_type" == "local" ]]; then
    local _path
    _path=$(jq -r --arg n "$group_name" --argjson i "$sel_idx" \
      '.groups[$n].projects[$i].path' "$GROUPS_CONFIG_FILE" 2>/dev/null)
    echo ""
    printf '  %bLocal project%b\n' "${BOLD}" "${RESET}"
    printf '  Path: %b%s%b\n' "${WHITE}" "$_path" "${RESET}"
    printf '%b\n' "  ${DIM}(Remove and re-add to change path)${RESET}"
    echo ""
    printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
    IFS= read -rsn1 || true
  else
    _group_edit_remote_fields "$group_name" "$sel_idx"
  fi
}

_group_edit_remote_fields() {
  local group_name="$1" idx="$2"

  local cur_host cur_user cur_port cur_key cur_dir
  cur_host=$(jq -r --arg n "$group_name" --argjson i "$idx" \
    '.groups[$n].projects[$i].host // ""' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  cur_user=$(jq -r --arg n "$group_name" --argjson i "$idx" \
    '.groups[$n].projects[$i].user // ""' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  cur_port=$(jq -r --arg n "$group_name" --argjson i "$idx" \
    '.groups[$n].projects[$i].port // 22' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  cur_key=$(jq -r --arg n "$group_name" --argjson i "$idx" \
    '.groups[$n].projects[$i].identity_file // ""' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  cur_dir=$(jq -r --arg n "$group_name" --argjson i "$idx" \
    '.groups[$n].projects[$i].project_dir // ""' "$GROUPS_CONFIG_FILE" 2>/dev/null)
  [[ "$cur_key" == "null" ]] && cur_key=""
  [[ "$cur_dir" == "null" ]] && cur_dir=""

  echo ""
  printf '  %bEdit Remote Project%b\n' "${BOLD}" "${RESET}"
  printf '%b\n' "  ${DIM}Press Enter to keep current value${RESET}"
  echo ""

  printf '  Host [%s]: ' "$cur_host"
  local new_host; IFS= read -r new_host
  [[ -z "$new_host" ]] && new_host="$cur_host"
  _group_validate_host "$new_host" || return 1

  printf '  User [%s]: ' "$cur_user"
  local new_user; IFS= read -r new_user
  [[ -z "$new_user" ]] && new_user="$cur_user"
  _group_validate_user "$new_user" || return 1

  printf '  Port [%s]: ' "$cur_port"
  local new_port; IFS= read -r new_port
  [[ -z "$new_port" ]] && new_port="$cur_port"
  _group_validate_port "$new_port" || return 1

  printf '  SSH key [%s]: ' "${cur_key:-(none)}"
  local new_key; IFS= read -r new_key
  [[ -z "$new_key" ]] && new_key="$cur_key"
  _group_validate_ssh_key "$new_key"

  printf '  Project dir [%s]: ' "${cur_dir:-(none)}"
  local new_dir; IFS= read -r new_dir
  [[ -z "$new_dir" ]] && new_dir="$cur_dir"

  # Save all fields via single jq update
  local tmp="${GROUPS_CONFIG_FILE}.tmp"
  jq --arg g "$group_name" --argjson i "$idx" \
    --arg host "$new_host" --arg user "$new_user" --argjson port "$new_port" \
    --arg key "$new_key" --arg dir "$new_dir" \
    '.groups[$g].projects[$i].host = $host |
     .groups[$g].projects[$i].user = $user |
     .groups[$g].projects[$i].port = $port |
     (if $key != "" then .groups[$g].projects[$i].identity_file = $key
      else del(.groups[$g].projects[$i].identity_file) end) |
     (if $dir != "" then .groups[$g].projects[$i].project_dir = $dir
      else del(.groups[$g].projects[$i].project_dir) end)' \
    "$GROUPS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GROUPS_CONFIG_FILE"

  echo ""
  ok "Remote project updated"
  echo ""
  printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
  IFS= read -rsn1 || true
}

# ── Reorder projects ──

_group_reorder() {
  local group_name="$1"
  local total
  total=$(groups_project_count "$group_name")

  if (( total < 2 )); then
    echo ""
    info "Need at least 2 projects to reorder"
    echo ""
    printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
    IFS= read -rsn1 || true
    return 0
  fi

  local selected=0

  tput civis

  local _ro_w=$(( TERM_COLS - 4 ))
  (( _ro_w > 50 )) && _ro_w=50
  (( _ro_w < 20 )) && _ro_w=20

  _ro_draw_header() {
    echo ""
    printf '  %bReorder Projects%b\n' "${BOLD}" "${RESET}"
    printf '  %b↑/↓ select  ⏎ swap down  q done%b\n' "${DIM}" "${RESET}"
  }

  _ro_draw() {
    local _t
    _t=$(groups_project_count "$group_name")
    local ri=0
    while (( ri < _t )); do
      local _pname
      _pname=$(groups_project_name "$group_name" "$ri")
      local _type
      _type=$(jq -r --arg n "$group_name" --argjson idx "$ri" \
        '.groups[$n].projects[$idx].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)

      local _icon
      [[ "$_type" == "local" ]] && _icon="●" || _icon="◆"

      if (( ri == selected )); then
        local text="  ▸ ${_icon} ${_pname}"
        local text_len=${#text}
        local bar_pad=$(( _ro_w - text_len ))
        (( bar_pad < 0 )) && bar_pad=0
        local pad
        pad=$(printf '%*s' "$bar_pad" "")
        printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
      else
        printf '    %s %s\n' "$_icon" "$_pname"
      fi
      ri=$(( ri + 1 ))
    done

    # Done row
    if (( selected == _t )); then
      local text="  ▸ Done"
      local text_len=${#text}
      local bar_pad=$(( _ro_w - text_len ))
      (( bar_pad < 0 )) && bar_pad=0
      local pad
      pad=$(printf '%*s' "$bar_pad" "")
      printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
    else
      printf '    %bDone%b\n' "${DIM}" "${RESET}"
    fi
  }

  local total_lines=$(( total + 1 ))

  _ro_clear() {
    local ci=0
    while (( ci < total_lines )); do
      tput cuu1
      ci=$(( ci + 1 ))
    done
    tput ed
  }

  _ro_read_key() {
    local key
    IFS= read -rsn1 key || true
    if [[ "$key" == $'\x1b' ]]; then
      local seq1 seq2
      IFS= read -rsn1 -t 1 seq1 || true
      IFS= read -rsn1 -t 1 seq2 || true
      key="${key}${seq1}${seq2}"
    fi
    REPLY="$key"
  }

  _ro_draw_header
  _ro_draw

  while true; do
    _ro_read_key

    case "$REPLY" in
      $'\x1b[A')
        (( selected > 0 )) && selected=$((selected - 1))
        ;;
      $'\x1b[B')
        (( selected < total )) && selected=$((selected + 1))
        ;;
      'q'|'Q')
        _ro_clear
        tput cnorm
        return 0
        ;;
      '')
        if (( selected == total )); then
          # Done
          _ro_clear
          tput cnorm
          return 0
        fi
        # Swap selected with next (if not last project)
        if (( selected < total - 1 )); then
          local tmp="${GROUPS_CONFIG_FILE}.tmp"
          local next=$(( selected + 1 ))
          jq --arg g "$group_name" --argjson a "$selected" --argjson b "$next" '
            .groups[$g].projects as $p |
            .groups[$g].projects[$a] = $p[$b] |
            .groups[$g].projects[$b] = $p[$a]
          ' "$GROUPS_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GROUPS_CONFIG_FILE"
          selected=$next
        fi
        ;;
      *)
        continue
        ;;
    esac

    _ro_clear
    _ro_draw
  done
}

# ── Detail Menu ──

_group_detail_menu() {
  local group_name="$1"

  while true; do
    local display_name
    display_name=$(groups_get ".groups.\"${group_name}\".name")
    [[ "$display_name" == "null" || -z "$display_name" ]] && display_name="$group_name"

    local total
    total=$(groups_project_count "$group_name")

    clear
    echo ""
    printf '  %b%b%s%b %b(%d project%s)%b\n' \
      "${BOLD}" "${WHITE}" "$display_name" "${RESET}" \
      "${DIM}" "$total" "$([ "$total" != "1" ] && echo "s")" "${RESET}"
    echo ""

    # Show projects with services
    if (( total > 0 )); then
      local pi=0
      while (( pi < total )); do
        local _type _pname _desc
        _type=$(jq -r --arg n "$group_name" --argjson idx "$pi" \
          '.groups[$n].projects[$idx].type' "$GROUPS_CONFIG_FILE" 2>/dev/null)
        _pname=$(groups_project_name "$group_name" "$pi")
        _desc=$(groups_project_desc "$group_name" "$pi")

        local _icon _color
        if [[ "$_type" == "local" ]]; then
          _icon="●"; _color="${GREEN}"
          _desc="${_desc/#$HOME/~}"
          local _raw_path
          _raw_path=$(groups_project_desc "$group_name" "$pi")
          [[ ! -d "$_raw_path" ]] && _color="${RED}"
        else
          _icon="◆"; _color="${ACCENT}"
        fi

        printf '    %b%s%b %b%s%b %b%s%b\n' \
          "$_color" "$_icon" "${RESET}" \
          "${WHITE}" "$_pname" "${RESET}" \
          "${DIM}" "$_desc" "${RESET}"

        # Show services with health status under each project
        if [[ "$_type" == "local" && -d "$_raw_path" ]]; then
          local _cfg=""
          if [[ -f "${_raw_path}/deploy.json" ]]; then
            _cfg="${_raw_path}/deploy.json"
          elif [[ -f "${_raw_path}/muster.json" ]]; then
            _cfg="${_raw_path}/muster.json"
          fi
          if [[ -n "$_cfg" ]] && has_cmd jq; then
            local _svc_list
            _svc_list=$(jq -r '(.deploy_order[]? // empty)' "$_cfg" 2>/dev/null)
            [[ -z "$_svc_list" ]] && _svc_list=$(jq -r '.services | keys[]' "$_cfg" 2>/dev/null)
            if [[ -n "$_svc_list" ]]; then
              while IFS= read -r _sk; do
                [[ -z "$_sk" ]] && continue
                local _sn _s_icon _s_color
                _sn=$(jq -r --arg k "$_sk" '.services[$k].name // $k' "$_cfg" 2>/dev/null)

                # Run the health hook directly
                local _s_status="unknown"
                local _h_hook="${_raw_path}/.muster/hooks/${_sk}/health.sh"
                local _h_dir="${_raw_path}/.muster/hooks/${_sk}"
                local _h_enabled
                _h_enabled=$(jq -r --arg k "$_sk" '.services[$k].health.enabled // "true"' "$_cfg" 2>/dev/null)

                if [[ "$_h_enabled" == "false" ]]; then
                  _s_status="disabled"
                elif [[ -x "$_h_hook" ]]; then
                  if (cd "$_raw_path" && "$_h_hook") &>/dev/null; then
                    _s_status="healthy"
                  else
                    _s_status="unhealthy"
                  fi
                elif [[ -f "${_h_dir}/justfile" ]] && has_cmd just; then
                  if (cd "$_raw_path" && just --justfile "${_h_dir}/justfile" health) &>/dev/null; then
                    _s_status="healthy"
                  else
                    _s_status="unhealthy"
                  fi
                fi

                case "$_s_status" in
                  healthy)   _s_icon="●"; _s_color="${GREEN}" ;;
                  unhealthy) _s_icon="●"; _s_color="${RED}" ;;
                  disabled)  _s_icon="○"; _s_color="${DIM}" ;;
                  *)         _s_icon="○"; _s_color="${GRAY}" ;;
                esac

                printf '      %b%s%b %b%s%b\n' \
                  "$_s_color" "$_s_icon" "${RESET}" \
                  "$_s_color" "$_sn" "${RESET}"
              done <<< "$_svc_list"
            fi
          fi
        fi

        pi=$(( pi + 1 ))
      done
      echo ""
    fi

    local actions=()
    actions[${#actions[@]}]="Deploy"
    actions[${#actions[@]}]="Status"
    actions[${#actions[@]}]="Add project"
    actions[${#actions[@]}]="Remove project"
    actions[${#actions[@]}]="Rename group"
    actions[${#actions[@]}]="Edit project"
    actions[${#actions[@]}]="Reorder projects"
    actions[${#actions[@]}]="Delete group"
    actions[${#actions[@]}]="Back"

    menu_select "$display_name" "${actions[@]}"

    case "$MENU_RESULT" in
      "Deploy")
        _group_cmd_deploy "$group_name"
        echo ""
        printf '  %bPress any key to continue...%b' "${DIM}" "${RESET}"
        IFS= read -rsn1 || true
        ;;
      "Status")
        _group_cmd_status "$group_name"
        echo ""
        printf '  %bPress any key to continue...%b' "${DIM}" "${RESET}"
        IFS= read -rsn1 || true
        ;;
      "Add project")
        _group_cmd_add "$group_name"
        ;;
      "Remove project")
        _group_cmd_remove "$group_name"
        ;;
      "Rename group")
        _group_rename "$group_name"
        ;;
      "Edit project")
        _group_edit_project "$group_name"
        ;;
      "Reorder projects")
        _group_reorder "$group_name"
        ;;
      "Delete group")
        groups_delete "$group_name"
        return 0
        ;;
      "Back"|"__back__")
        return 0
        ;;
    esac
  done
}
