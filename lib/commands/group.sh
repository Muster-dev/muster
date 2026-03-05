#!/usr/bin/env bash
# muster/lib/commands/group.sh — Fleet Groups command handler

source "$MUSTER_ROOT/lib/core/groups.sh"
source "$MUSTER_ROOT/lib/core/credentials.sh"
source "$MUSTER_ROOT/lib/core/trust.sh"
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

# ── Fleet-dir project loader ──
# Load project at flat index within a fleet (group_name)
# Sets _FP_* vars via fleet_cfg_project_load
# After calling: _FP_TRANSPORT == "local" for local, "ssh"/"cloud" for remote
#                _FP_PATH for local project path
#                _FP_HOST, _FP_USER, _FP_PORT for remote
#                _FP_FLEET, _FP_GROUP, _FP_PROJECT for save operations
_group_load_project_at() {
  local name="$1" index="$2"
  local _i=0
  local group project
  for group in $(fleet_cfg_groups "$name"); do
    for project in $(fleet_cfg_group_projects "$name" "$group"); do
      if (( _i == index )); then
        fleet_cfg_project_load "$name" "$group" "$project"
        return 0
      fi
      _i=$(( _i + 1 ))
    done
  done
  return 1
}

# Check if project at index is local (returns 0) or remote (returns 1)
_group_project_is_local() {
  local name="$1" index="$2"
  _group_load_project_at "$name" "$index" || return 1
  [[ "$_FP_TRANSPORT" == "local" ]]
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
  printf '%b\n' "${BOLD}muster group${RESET} — Orchestrate multiple projects as one deploy"
  echo ""
  echo "  Combine local and remote projects into a group, then deploy them"
  echo "  together in order. Each project can use SSH or cloud transport."
  echo ""
  echo "Usage: muster group [command]"
  echo "       muster deploy fleet <group>   (shortcut)"
  echo ""
  echo "Commands:"
  echo "  (none)              Interactive group manager"
  echo "  list                List all groups"
  echo "  create <name>       Create a new group"
  echo "  delete <name>       Delete a group"
  echo "  add <group> [target] Add a project to a group"
  echo "  remove <group>      Remove a project from a group"
  echo "  rename <group> <name> Rename a group"
  echo "  edit <group> <idx>  Edit a remote project's connection settings"
  echo "  reorder <group>     Reorder projects interactively"
  echo "  deploy <group>      Deploy all projects in a group"
  echo "  status <group>      Show health of all projects in a group"
  echo ""
  echo "Project types:"
  echo "  Local               muster group add prod /path/to/project"
  echo "  Remote (SSH key)    muster group add prod deploy@10.0.1.5 --path /opt/app"
  echo "  Remote (SSH pass)   muster group add prod deploy@10.0.1.5 --auth password"
  echo "  Remote (cloud)      muster group add prod agent-name --cloud --path /opt/app"
  echo ""
  echo "Add options:"
  echo "  --port, -p N        SSH port (default: 22)"
  echo "  --key, -k FILE      SSH identity file"
  echo "  --path DIR          Project directory on remote"
  echo "  --cloud             Route through cloud tunnel (instead of SSH)"
  echo "  --auth METHOD       Auth: key (default), password, agent"
  echo "  --auth-mode MODE    Password handling: save, session, always"
  echo ""
  echo "Deploy options:"
  echo "  --dry-run           Preview deploy plan without executing"
  echo "  --json              Output as JSON"
  echo ""
  echo "Edit options:"
  echo "  --host, --user, --port, --key, --path   Change connection details"
  echo "  --cloud / --no-cloud                    Toggle cloud transport"
  echo "  --auth, --auth-mode                     Change auth settings"
  echo ""
  echo "Other: -h, --help    Show this help"
}

# ── List ──

_group_cmd_list() {
  local json_mode=false
  [[ "${1:-}" == "--json" ]] && json_mode=true

  _groups_ensure_file

  if [[ "$json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
    # Build JSON from fleet dirs
    local _json="{}"
    local _g
    for _g in $(groups_list); do
      local _total _display
      _total=$(groups_project_count "$_g")
      fleet_cfg_load "$_g" 2>/dev/null
      _display="${_FL_NAME:-$_g}"
      _json=$(printf '%s' "$_json" | jq --arg g "$_g" --arg d "$_display" --argjson t "$_total" \
        '. + {($g): {name: $d, project_count: $t}}')
    done
    printf '%s\n' "$_json" | jq '.'
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
    local display_name="$gname"
    fleet_cfg_load "$gname" 2>/dev/null && [[ -n "$_FL_NAME" && "$_FL_NAME" != "null" ]] && display_name="$_FL_NAME"

    local total
    total=$(groups_project_count "$gname")

    printf '  %b%b%s%b %b(%d project%s)%b\n' \
      "${BOLD}" "${WHITE}" "$display_name" "${RESET}" \
      "${DIM}" "$total" "$([ "$total" != "1" ] && echo "s")" "${RESET}"

    local pi=0
    while (( pi < total )); do
      local _desc _pname
      _desc=$(groups_project_desc "$gname" "$pi")
      _pname=$(groups_project_name "$gname" "$pi")

      local _is_local=false
      if _group_project_is_local "$gname" "$pi"; then
        _is_local=true
      fi

      local _display_desc="$_desc"
      [[ "$_is_local" == "true" ]] && _display_desc="${_desc/#$HOME/~}"

      local _icon _color
      if [[ "$_is_local" == "true" ]]; then
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
  local _add_cloud="false" _add_auth="" _add_auth_mode="" _add_hook_mode="manual"

  # Parse remaining args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port|-p)     port="$2"; shift 2 ;;
      --key|-k)      key="$2"; shift 2 ;;
      --path)        remote_path="$2"; shift 2 ;;
      --cloud)       _add_cloud="true"; shift ;;
      --auth)        _add_auth="$2"; shift 2 ;;
      --auth-mode)   _add_auth_mode="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: muster group add <group> [path|user@host] [options]"
        echo ""
        echo "Options:"
        echo "  --port, -p N       SSH port (default: 22)"
        echo "  --key, -k FILE     SSH identity file"
        echo "  --path DIR         Project directory on remote"
        echo "  --cloud            Use cloud tunnel transport"
        echo "  --auth METHOD      Auth method: key, password, agent"
        echo "  --auth-mode MODE   Password mode: save, session, always"
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
        printf '  Transport (ssh/cloud) [ssh]: '
        local _transport_input; IFS= read -r _transport_input
        case "$_transport_input" in
          cloud) _add_cloud="true" ;;
          *) _add_cloud="false" ;;
        esac
        if [[ "$_add_cloud" == "true" ]]; then
          printf '  Cloud agent name: '
          IFS= read -r target
          [[ -z "$target" ]] && return 0
        else
          printf '  user@host: '
          IFS= read -r target
          [[ -z "$target" ]] && return 0
          printf '  Port [22]: '
          IFS= read -r port
          [[ -z "$port" ]] && port="22"
          printf '  Auth method (key/password/agent) [key]: '
          local _auth_input; IFS= read -r _auth_input
          case "$_auth_input" in
            password) _add_auth="password"
              printf '  Password mode (save/session/always) [session]: '
              local _mode_input; IFS= read -r _mode_input
              case "$_mode_input" in
                save|always) _add_auth_mode="$_mode_input" ;;
                *) _add_auth_mode="session" ;;
              esac
              ;;
            agent) _add_auth="agent" ;;
            *)
              _add_auth="key"
              printf '  SSH key (optional): '
              IFS= read -r key
              ;;
          esac
        fi
        printf '  Project dir on remote: '
        IFS= read -r remote_path
        # Strip leading colon (common mistake from user@host:/path muscle memory)
        remote_path="${remote_path#:}"
        printf '  Hook mode (manual/sync) [manual]: '
        local _hm_input; IFS= read -r _hm_input
        case "$_hm_input" in
          sync)
            _add_hook_mode="sync"
            printf '  %b  Sync mode: this machine pushes hooks before each deploy.%b\n' "${DIM}" "${RESET}"
            printf '  %b  No muster install needed on the target — just SSH access.%b\n' "${DIM}" "${RESET}"
            ;;
          *) _add_hook_mode="manual" ;;
        esac
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
  if [[ "$_add_cloud" == "true" && "$target" != *"@"* ]]; then
    # Cloud target: bare hostname (no user@host)
    local host="$target"
    local user="deploy"
    _group_validate_host "$host" || return 1

    echo ""
    groups_add_remote "$group_name" "$host" "$user" "$port" "$key" "$remote_path" "$_add_cloud" "$_add_auth" "$_add_auth_mode" "$_add_hook_mode" || return 1

    # Test cloud connectivity
    local _idx
    _idx=$(( $(groups_project_count "$group_name") - 1 ))

    source "$MUSTER_ROOT/lib/core/cloud.sh"
    _groups_cloud_config
    start_spinner "Testing cloud connectivity..."
    if _fleet_cloud_check "$host" 2>/dev/null; then
      stop_spinner
      ok "Cloud agent reachable"
    else
      stop_spinner
      warn "Cloud agent unreachable (project still added)"
    fi
    echo ""
  elif [[ "$target" == *"@"* ]]; then
    # Remote: parse user@host
    local user host
    user="${target%%@*}"
    host="${target#*@}"

    # Validate inputs
    _group_validate_user "$user" || return 1
    _group_validate_host "$host" || return 1
    _group_validate_port "$port" || return 1
    _group_validate_ssh_key "$key"

    # Check sshpass for password auth — offer to install if missing
    if [[ "$_add_auth" == "password" ]]; then
      _ensure_sshpass || return 1
    fi

    echo ""
    groups_add_remote "$group_name" "$host" "$user" "$port" "$key" "$remote_path" "$_add_cloud" "$_add_auth" "$_add_auth_mode" "$_add_hook_mode" || return 1

    # Prompt for password now if mode is save/session (don't wait until deploy)
    if [[ "$_add_auth" == "password" && "$_add_auth_mode" != "always" ]]; then
      source "$MUSTER_ROOT/lib/core/credentials.sh"
      local _cred_key="ssh_${user}@${host}:${port}"
      local _pw
      _pw=$(_cred_prompt_password "SSH password for ${user}@${host}")
      if [[ -n "$_pw" ]]; then
        if [[ "$_add_auth_mode" == "save" ]]; then
          _cred_keychain_save "groups" "$_cred_key" "$_pw" 2>/dev/null && ok "Password saved to keychain" || warn "Could not save to keychain"
        fi
        _cred_session_set "$_cred_key" "$_pw"
      fi
    fi

    # Test connectivity
    local _idx
    _idx=$(( $(groups_project_count "$group_name") - 1 ))

    start_spinner "Testing SSH connectivity..."
    if groups_remote_check "$group_name" "$_idx"; then
      stop_spinner
      ok "SSH connection succeeded"

      # Verify muster is installed
      local _muster_on_remote=false
      start_spinner "Checking muster on remote..."
      if groups_remote_exec "$group_name" "$_idx" "command -v muster" &>/dev/null; then
        stop_spinner
        ok "muster found on remote"
        _muster_on_remote=true
      else
        stop_spinner
        warn "muster not installed on remote"
        printf '  %bInstall muster on the remote to enable group deploys%b\n' "${DIM}" "${RESET}"
      fi

      # Send fleet trust join request
      if [[ "$_muster_on_remote" == "true" ]]; then
        local _my_fp _my_label
        _my_fp=$(trust_fingerprint)
        _my_label=$(trust_label)

        start_spinner "Sending trust request..."
        local _req_result
        _req_result=$(groups_remote_exec "$group_name" "$_idx" \
          "muster trust request --fingerprint '${_my_fp}' --label '${_my_label}'" 2>/dev/null) || true
        stop_spinner

        case "$_req_result" in
          already_trusted)
            ok "Already trusted on remote"
            ;;
          already_pending)
            info "Trust request already pending on remote"
            ;;
          pending)
            ok "Trust request sent"
            # Poll for acceptance
            info "Waiting for remote to accept... (Ctrl+C to skip)"
            local _poll_start _poll_elapsed _trust_accepted=false
            _poll_start=$(date +%s)
            trap 'true' INT
            while true; do
              _poll_elapsed=$(( $(date +%s) - _poll_start ))
              (( _poll_elapsed > 120 )) && break

              local _verify_result
              _verify_result=$(groups_remote_exec "$group_name" "$_idx" \
                "muster trust verify --fingerprint '${_my_fp}'" 2>/dev/null) || true

              if [[ "$_verify_result" == "trusted" ]]; then
                _trust_accepted=true
                break
              fi

              printf '\r  %bi%b Waiting for acceptance (%ds)... ' "${ACCENT}" "${RESET}" "$_poll_elapsed"
              sleep 3
            done
            trap - INT
            printf '\r\033[K'

            if [[ "$_trust_accepted" == "true" ]]; then
              ok "Trust accepted — deploys are authorized"
            else
              info "Trust request pending. Remote must run:"
              printf '  %bmuster trust accept %s%b\n' "${DIM}" "${_my_fp:0:20}..." "${RESET}"
              printf '  %bOr accept via the dashboard on the remote machine%b\n' "${DIM}" "${RESET}"
            fi
            ;;
          *)
            warn "Could not send trust request (muster trust may not be available on remote)"
            ;;
        esac
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

  local _edit_usage="Usage: muster group edit <group> <index> [--host H] [--user U] [--port P] [--key K] [--path D] [--cloud] [--no-cloud] [--auth M] [--auth-mode M]"

  if [[ -z "$group_name" ]]; then
    err "$_edit_usage"
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
    err "$_edit_usage"
    return 1
  fi

  # Validate index
  local total
  total=$(groups_project_count "$group_name")
  if ! [[ "$index" =~ ^[0-9]+$ ]] || (( index >= total )); then
    err "Invalid project index: ${index} (group has ${total} project(s), 0-indexed)"
    return 1
  fi

  if _group_project_is_local "$group_name" "$index"; then
    err "Only remote projects can be edited via CLI (local projects: remove and re-add)"
    return 1
  fi

  # Parse flags
  local new_host="" new_user="" new_port="" new_key="" new_dir=""
  local new_cloud="" new_auth="" new_auth_mode=""
  local has_changes=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)      new_host="$2"; has_changes=true; shift 2 ;;
      --user)      new_user="$2"; has_changes=true; shift 2 ;;
      --port|-p)   new_port="$2"; has_changes=true; shift 2 ;;
      --key|-k)    new_key="$2"; has_changes=true; shift 2 ;;
      --path)      new_dir="$2"; has_changes=true; shift 2 ;;
      --cloud)     new_cloud="true"; has_changes=true; shift ;;
      --no-cloud)  new_cloud="false"; has_changes=true; shift ;;
      --auth)      new_auth="$2"; has_changes=true; shift 2 ;;
      --auth-mode) new_auth_mode="$2"; has_changes=true; shift 2 ;;
      --help|-h)
        echo "$_edit_usage"
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
    err "No changes specified. Use --host, --user, --port, --key, --path, --cloud, --auth, --auth-mode."
    return 1
  fi

  # Validate provided fields
  [[ -n "$new_host" ]] && { _group_validate_host "$new_host" || return 1; }
  [[ -n "$new_user" ]] && { _group_validate_user "$new_user" || return 1; }
  [[ -n "$new_port" ]] && { _group_validate_port "$new_port" || return 1; }
  [[ -n "$new_key" ]]  && _group_validate_ssh_key "$new_key"
  if [[ -n "$new_auth" ]]; then
    case "$new_auth" in
      key|password|agent) ;;
      *) err "Invalid auth method: ${new_auth} (must be key, password, or agent)"; return 1 ;;
    esac
  fi
  if [[ -n "$new_auth_mode" ]]; then
    case "$new_auth_mode" in
      save|session|always) ;;
      *) err "Invalid auth mode: ${new_auth_mode} (must be save, session, or always)"; return 1 ;;
    esac
  fi

  # Apply to fleet dir project.json
  _group_load_project_at "$group_name" "$index" || { err "Project not found"; return 1; }

  local _pcfg
  _pcfg="$(fleet_cfg_project_dir "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT")/project.json"

  local jq_expr=""
  [[ -n "$new_host" ]] && jq_expr="${jq_expr} | .machine.host = \$host"
  [[ -n "$new_user" ]] && jq_expr="${jq_expr} | .machine.user = \$user"
  [[ -n "$new_port" ]] && jq_expr="${jq_expr} | .machine.port = (\$port | tonumber)"
  [[ -n "$new_key" ]]  && jq_expr="${jq_expr} | .machine.identity_file = \$key"
  [[ -n "$new_dir" ]]  && jq_expr="${jq_expr} | .remote_path = \$dir"
  [[ "$new_cloud" == "true" ]]  && jq_expr="${jq_expr} | .machine.transport = \"cloud\""
  [[ "$new_cloud" == "false" ]] && jq_expr="${jq_expr} | .machine.transport = \"ssh\""
  [[ -n "$new_auth" ]] && jq_expr="${jq_expr} | .auth.method = \$auth"
  [[ -n "$new_auth_mode" ]] && jq_expr="${jq_expr} | .auth.mode = \$authmode"

  # Strip leading " | "
  jq_expr="${jq_expr# | }"

  local tmp="${_pcfg}.tmp"
  jq --arg host "${new_host:-}" --arg user "${new_user:-}" \
    --arg port "${new_port:-0}" --arg key "${new_key:-}" --arg dir "${new_dir:-}" \
    --arg auth "${new_auth:-}" --arg authmode "${new_auth_mode:-}" \
    "$jq_expr" "$_pcfg" > "$tmp" && mv "$tmp" "$_pcfg"

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

  local display_name="$group_name"
  fleet_cfg_load "$group_name" 2>/dev/null && [[ -n "$_FL_NAME" && "$_FL_NAME" != "null" ]] && display_name="$_FL_NAME"

  local succeeded=0 failed=0 skipped=0
  local log_dir="$HOME/.muster/logs"
  mkdir -p "$log_dir"

  # Acquire group deploy lock
  local _group_lock="$HOME/.muster/.group_deploying"
  if [[ -f "$_group_lock" ]]; then
    local _lock_group
    _lock_group=$(cat "$_group_lock" 2>/dev/null)
    err "Group deploy already in progress: ${_lock_group:-unknown}"
    return 1
  fi
  printf '%s' "$group_name" > "$_group_lock"

  # Catch Ctrl+C so we don't falsely report success
  local _group_interrupted=false
  trap '_group_interrupted=true; rm -f "'"$_group_lock"'"' INT

  echo ""
  printf '  %b%bGroup Deploy%b — %s (%d project%s)\n' \
    "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}" \
    "$display_name" "$total" "$([ "$total" != "1" ] && echo "s")"
  echo ""

  # Pre-calculate total deploy steps (services across all projects)
  local _total_steps=0
  local _steps_done=0
  local _pi=0
  while (( _pi < total )); do
    if _group_project_is_local "$group_name" "$_pi"; then
      local _pp="$_FP_PATH"
      local _pc=""
      [[ -f "${_pp}/deploy.json" ]] && _pc="${_pp}/deploy.json"
      [[ -z "$_pc" && -f "${_pp}/muster.json" ]] && _pc="${_pp}/muster.json"
      if [[ -n "$_pc" ]]; then
        local _ns
        _ns=$(jq '[.services | to_entries[] | select((.value.skip_deploy // false) | tostring != "true")] | length' "$_pc" 2>/dev/null)
        [[ -z "$_ns" || "$_ns" == "null" ]] && _ns=0
        (( _ns > 0 )) && _total_steps=$(( _total_steps + _ns )) || _total_steps=$(( _total_steps + 1 ))
      else
        _total_steps=$(( _total_steps + 1 ))
      fi
    else
      _total_steps=$(( _total_steps + 1 ))
    fi
    _pi=$(( _pi + 1 ))
  done

  # Pre-authenticate sudo if any project hooks use it (before bar for clean TUI)
  local _any_sudo_global=false
  _pi=0
  while (( _pi < total )); do
    if _group_project_is_local "$group_name" "$_pi"; then
      local _pp="$_FP_PATH"
      if [[ -d "${_pp:-}" && -d "${_pp}/.muster/hooks" ]]; then
        if grep -rq 'sudo' "${_pp}/.muster/hooks" 2>/dev/null; then
          _any_sudo_global=true; break
        fi
      fi
    fi
    _pi=$(( _pi + 1 ))
  done
  if [[ "$_any_sudo_global" == "true" ]]; then
    local _sudo_was_cached=false
    sudo -n true 2>/dev/null && _sudo_was_cached=true
    sudo -v || true
    if [[ "$_sudo_was_cached" == "false" ]]; then
      printf '  %b✓%b Authenticated\n' "${GREEN}" "${RESET}"
      printf '    %bSave?%b  0) Close  1) Session  2) Always ask  3) Never ' "${DIM}" "${RESET}"
      local _sudo_ch=""
      IFS= read -rsn1 _sudo_ch 2>/dev/null || true
      case "$_sudo_ch" in
        1) printf '\r\033[K    %b✓%b Session\n' "${GREEN}" "${RESET}" ;;
        2) printf '\r\033[K    %b✓%b Always ask\n' "${GREEN}" "${RESET}" ;;
        3) printf '\r\033[K    %b✓%b Never\n' "${GREEN}" "${RESET}" ;;
        *) printf '\r\033[K' ;;
      esac
    fi
  fi

  # Pre-authenticate SSH passwords for remote projects (before bar for clean TUI)
  # First check if sshpass is needed
  local _needs_sshpass=false
  _pi=0
  while (( _pi < total )); do
    if ! _group_project_is_local "$group_name" "$_pi"; then
      _groups_load_remote "$group_name" "$_pi"
      if [[ "$_GP_CLOUD" != "true" && "$_GP_AUTH_METHOD" == "password" ]]; then
        _needs_sshpass=true; break
      fi
    fi
    _pi=$(( _pi + 1 ))
  done
  if [[ "$_needs_sshpass" == "true" ]]; then
    _ensure_sshpass || return 1
  fi

  local _prompted_hosts=()
  _pi=0
  while (( _pi < total )); do
    if ! _group_project_is_local "$group_name" "$_pi"; then
      _groups_load_remote "$group_name" "$_pi"
      if [[ "$_GP_CLOUD" != "true" && "$_GP_AUTH_METHOD" == "password" ]]; then
        local _host_key="${_GP_USER}@${_GP_HOST}:${_GP_PORT}"
        local _already=false _hi=0
        while (( _hi < ${#_prompted_hosts[@]} )); do
          [[ "${_prompted_hosts[$_hi]}" == "$_host_key" ]] && { _already=true; break; }
          _hi=$(( _hi + 1 ))
        done
        if [[ "$_already" == "false" ]]; then
          _groups_load_ssh_password
          _prompted_hosts[${#_prompted_hosts[@]}]="$_host_key"
          if [[ "$_GP_AUTH_MODE" == "save" ]]; then
            # "save" mode auto-saves to keychain in _groups_load_ssh_password
            printf '  %b✓%b SSH %s %b(keychain)%b\n' "${GREEN}" "${RESET}" "$_host_key" "${DIM}" "${RESET}"
          else
            printf '  %b✓%b SSH %s\n' "${GREEN}" "${RESET}" "$_host_key"
            printf '    %bSave?%b  0) Close  1) Keychain  2) Session  3) Skip ' "${DIM}" "${RESET}"
            local _ssh_ch=""
            IFS= read -rsn1 _ssh_ch 2>/dev/null || true
            case "$_ssh_ch" in
              1) printf '\r\033[K    %b✓%b Keychain\n' "${GREEN}" "${RESET}"
                 local _cred_key="ssh_${_GP_USER}@${_GP_HOST}:${_GP_PORT}"
                 _cred_keychain_save "groups" "$_cred_key" "$_GP_PASSWORD" 2>/dev/null || true ;;
              2) printf '\r\033[K    %b✓%b Session\n' "${GREEN}" "${RESET}" ;;
              3) printf '\r\033[K    %b✓%b Skip\n' "${GREEN}" "${RESET}" ;;
              *) printf '\r\033[K' ;;
            esac
          fi
        fi
      fi
    fi
    _pi=$(( _pi + 1 ))
  done

  # Verify cloud config for cloud projects (before bar)
  local _has_cloud=false
  _pi=0
  while (( _pi < total )); do
    if ! _group_project_is_local "$group_name" "$_pi"; then
      if [[ "$_FP_TRANSPORT" == "cloud" ]]; then
        _has_cloud=true; break
      fi
    fi
    _pi=$(( _pi + 1 ))
  done
  if [[ "$_has_cloud" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/cloud.sh"
    if ! _fleet_cloud_available; then
      err "Cloud projects require muster-tunnel. Install: curl -sSL https://getmuster.dev/cloud | bash"
      return 1
    fi
    _groups_cloud_config
    if [[ -z "$FLEET_CLOUD_TOKEN" ]]; then
      err "Cloud token not configured. Run: muster settings --global cloud.token <token>"
      return 1
    fi
    printf '  %b✓%b Cloud transport ready\n' "${GREEN}" "${RESET}"
  fi

  # Progress bar — printed once, updated via full-section redraw
  local _first_pname _first_pdesc
  _first_pname=$(groups_project_name "$group_name" "0")
  _first_pdesc=$(groups_project_desc "$group_name" "0")
  [[ "${_first_pdesc:0:1}" == "/" ]] && _first_pdesc="${_first_pdesc/#$HOME/~}"
  progress_bar 0 "$_total_steps" "${_first_pname}  ${_first_pdesc}"
  echo ""
  local _result_lines=()
  local _section_h=1
  local _bar_state=""

  local i=0
  while (( i < total )); do
    # shellcheck disable=SC2034
    local current=$(( i + 1 ))

    local _is_local_proj=false _pname _pdesc
    _group_load_project_at "$group_name" "$i"
    [[ "$_FP_TRANSPORT" == "local" ]] && _is_local_proj=true
    _pname=$(groups_project_name "$group_name" "$i")
    _pdesc=$(groups_project_desc "$group_name" "$i")
    [[ "${_pdesc:0:1}" == "/" ]] && _pdesc="${_pdesc/#$HOME/~}"

    local log_file
    log_file="${log_dir}/group-${group_name}-${_pname}-$(date +%Y%m%d-%H%M%S).log"
    local rc=0
    local _svc_total=0
    local _svc_idx=0
    local _steps_before="$_steps_done"
    local _results_before=${#_result_lines[@]}

    while true; do

      if [[ "$_is_local_proj" == "true" ]]; then
        # ── Local project: iterate services individually ──
        local _path="$_FP_PATH"

        # Pre-flight checks
        if [[ -z "$_path" || "$_path" == "null" ]]; then
          err "Project has no path configured"
          _section_h=$(( _section_h + 1 ))
          rc=1
        elif [[ ! -d "$_path" ]]; then
          err "Project directory not found: ${_path}"
          _section_h=$(( _section_h + 1 ))
          rc=1
        else
          local _cfg=""
          [[ -f "${_path}/deploy.json" ]] && _cfg="${_path}/deploy.json"
          [[ -z "$_cfg" && -f "${_path}/muster.json" ]] && _cfg="${_path}/muster.json"

          if [[ -z "$_cfg" ]]; then
            err "No deploy.json found in ${_path}"
            _section_h=$(( _section_h + 1 ))
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

            # Deploy each service with full-section redraw
            update_term_size
            local _sp_f=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local _svc_idx=0
            local _pw=$(( TERM_COLS - 8 ))
            (( _pw > 68 )) && _pw=68
            (( _pw < 10 )) && _pw=10
            rc=0

            for _svc in "${_services[@]}"; do
              _svc_idx=$(( _svc_idx + 1 ))
              local _svc_name
              _svc_name=$(jq -r --arg s "$_svc" '.services[$s].name // $s' "$_cfg" 2>/dev/null)

              if [[ "$_group_interrupted" == "true" ]]; then rc=130; break; fi

              # Handle credentials (before animation)
              local _cred_env=""
              _cred_env=$(_group_cred_for_service "$_cfg" "$_svc") || true
              if [[ -n "$_cred_env" ]]; then
                while IFS='=' read -r _ck _cv; do
                  [[ -z "$_ck" ]] && continue
                  export "$_ck=$_cv"
                done <<< "$_cred_env"
                local _g_cur_mode
                _g_cur_mode=$(jq -r --arg s "$_svc" '.services[$s].credentials.mode // ""' "$_cfg" 2>/dev/null)
                if [[ "$_g_cur_mode" == "session" || "$_g_cur_mode" == "always" ]]; then
                  printf '    %bSave?%b  0) Close  1) Keychain  2) Session  3) Skip ' "${DIM}" "${RESET}"
                  local _save_ch=""
                  IFS= read -rsn1 _save_ch 2>/dev/null || true
                  case "$_save_ch" in
                    1) local _tmp_cfg
                       _tmp_cfg=$(jq --arg s "$_svc" '.services[$s].credentials.mode = "save"' "$_cfg") && printf '%s' "$_tmp_cfg" > "$_cfg"
                       printf '\r\033[K    %b✓%b Keychain\n' "${GREEN}" "${RESET}" ;;
                    2) printf '\r\033[K    %b✓%b Session\n' "${GREEN}" "${RESET}" ;;
                    3) printf '\r\033[K    %b✓%b Skip\n' "${GREEN}" "${RESET}" ;;
                    *) printf '\r\033[K' ;;
                  esac
                fi
              fi

              # Export k8s/deploy env vars
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

              local _hook="${_path}/.muster/hooks/${_svc}/deploy.sh"
              if [[ ! -x "$_hook" ]]; then
                warn "No deploy hook for ${_svc_name}, skipping"
                continue
              fi

              local _svc_log
              _svc_log="${log_dir}/group-${group_name}-${_pname}-${_svc}-$(date +%Y%m%d-%H%M%S).log"
              : > "$_svc_log"

              # Run hook in background
              (cd "$_path" && "$_hook") >> "$_svc_log" 2>&1 &
              local _hook_pid=$!

              # Full-section redraw: bar + results + spinner + 3 preview
              _section_h=$(( 1 + ${#_result_lines[@]} + 4 ))
              _bar_state=""
              # Print initial frame
              progress_bar "$_steps_done" "$_total_steps" "${_pname}  ${_pdesc}"
              printf '\n'
              local _ri=0
              while (( _ri < ${#_result_lines[@]} )); do
                printf '%b\033[K\n' "${_result_lines[$_ri]}"
                _ri=$(( _ri + 1 ))
              done
              printf '  %b%s%b %bDeploying %s (%d/%d)%b\033[K\n' \
                "${ACCENT}" "${_sp_f[0]}" "${RESET}" "${WHITE}" "$_svc_name" "$_svc_idx" "$_svc_total" "${RESET}"
              printf '\033[K\n\033[K\n\033[K\n'

              # Animation loop
              local _sp_i=0
              while kill -0 "$_hook_pid" 2>/dev/null; do
                printf '\033[%dA' "$_section_h"
                progress_bar "$_steps_done" "$_total_steps" "${_pname}  ${_pdesc}"
                printf '\n'
                _ri=0
                while (( _ri < ${#_result_lines[@]} )); do
                  printf '%b\033[K\n' "${_result_lines[$_ri]}"
                  _ri=$(( _ri + 1 ))
                done
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
                [[ "$_group_interrupted" == "true" ]] && { kill "$_hook_pid" 2>/dev/null; break; }
                sleep 0.2
              done

              wait "$_hook_pid" 2>/dev/null
              local _svc_rc=$?
              cat "$_svc_log" >> "$log_file" 2>/dev/null

              # Add result to tracking
              if (( _svc_rc == 0 )); then
                _steps_done=$(( _steps_done + 1 ))
                _result_lines[${#_result_lines[@]}]="$(printf '  %b✓%b %s' "${GREEN}" "${RESET}" "$_svc_name")"
              else
                _result_lines[${#_result_lines[@]}]="$(printf '  %b✗%b %s' "${RED}" "${RESET}" "$_svc_name")"
                _bar_state="error"
              fi

              # Redraw section without animation (bar + results only)
              printf '\033[%dA' "$_section_h"
              progress_bar "$_steps_done" "$_total_steps" "${_pname}  ${_pdesc}" "$_bar_state"
              printf '\n'
              _ri=0
              while (( _ri < ${#_result_lines[@]} )); do
                printf '%b\033[K\n' "${_result_lines[$_ri]}"
                _ri=$(( _ri + 1 ))
              done
              printf '\033[J'
              _section_h=$(( 1 + ${#_result_lines[@]} ))

              if (( _svc_rc != 0 )); then
                echo ""
                _section_h=$(( _section_h + 1 ))
                if [[ -s "$_svc_log" ]]; then
                  while IFS= read -r _eline; do
                    _eline=$(printf '%s' "$_eline" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
                    printf '    %b%s%b\n' "${RED}" "$_eline" "${RESET}"
                    _section_h=$(( _section_h + 1 ))
                  done < <(tail -5 "$_svc_log")
                fi
                rc="$_svc_rc"
                break
              fi

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

        # Pre-flight: verify SSH connectivity in foreground (can re-prompt on failure)
        _groups_load_remote "$group_name" "$i"
        if [[ "$_GP_AUTH_METHOD" == "password" ]]; then
          _groups_load_ssh_password
        fi

        local _preflight_ok=false
        local _preflight_tries=0
        while (( _preflight_tries < 3 )); do
          _groups_build_ssh_opts
          local _ssh_err=""
          if [[ "$_GP_AUTH_METHOD" == "password" ]]; then
            export SSHPASS="$_GP_PASSWORD"
            # shellcheck disable=SC2086
            if _ssh_err=$(sshpass -e ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "echo ok" 2>&1); then
              unset SSHPASS
              _preflight_ok=true
              break
            fi
            unset SSHPASS
            if [[ "$_ssh_err" == *"Permission denied"* || "$_ssh_err" == *"incorrect password"* ]]; then
              # Wrong password — re-prompt
              printf '  %b!%b Wrong password for %s@%s\n' "${YELLOW}" "${RESET}" "$_GP_USER" "$_GP_HOST"
              _section_h=$(( _section_h + 1 ))
              _GP_PASSWORD=$(_cred_prompt_password "SSH password for ${_GP_USER}@${_GP_HOST}")
              _section_h=$(( _section_h + 1 ))  # prompt line
              if [[ -z "$_GP_PASSWORD" ]]; then break; fi
              local _cred_key="ssh_${_GP_USER}@${_GP_HOST}:${_GP_PORT}"
              _cred_session_set "$_cred_key" "$_GP_PASSWORD"
              [[ "$_GP_AUTH_MODE" == "save" ]] && _cred_keychain_save "groups" "$_cred_key" "$_GP_PASSWORD" 2>/dev/null || true
              _preflight_tries=$(( _preflight_tries + 1 ))
              continue
            fi
          else
            # shellcheck disable=SC2086
            if _ssh_err=$(ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "echo ok" 2>&1); then
              _preflight_ok=true
              break
            fi
            # Key auth failed — offer to switch to password
            if [[ "$_ssh_err" == *"Permission denied"* ]]; then
              echo ""
              printf '  %b!%b SSH key auth failed for %s@%s\n' "${YELLOW}" "${RESET}" "$_GP_USER" "$_GP_HOST"
              _section_h=$(( _section_h + 2 ))
              menu_select "SSH auth failed" \
                "Switch to password auth" "Enter SSH key path" "Skip" "Abort"
              _section_h=$(( _section_h + 3 ))

              case "$MENU_RESULT" in
                "Switch to password auth")
                  if has_cmd sshpass; then
                    _GP_AUTH_METHOD="password"
                    _GP_PASSWORD=$(_cred_prompt_password "SSH password for ${_GP_USER}@${_GP_HOST}")
                    _section_h=$(( _section_h + 1 ))
                    if [[ -n "$_GP_PASSWORD" ]]; then
                      local _cred_key="ssh_${_GP_USER}@${_GP_HOST}:${_GP_PORT}"
                      _cred_session_set "$_cred_key" "$_GP_PASSWORD"
                      # Update project config to remember password auth
                      local _pcfg
                      _pcfg="$(fleet_cfg_project_dir "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT")/project.json"
                      if [[ -f "$_pcfg" ]]; then
                        local _ptmp="${_pcfg}.tmp"
                        jq '.auth = {method: "password", mode: "save"}' "$_pcfg" > "$_ptmp" && mv "$_ptmp" "$_pcfg"
                      fi
                      # Save to keychain
                      _cred_keychain_save "groups" "$_cred_key" "$_GP_PASSWORD" 2>/dev/null || true
                      # Rebuild SSH opts without BatchMode for password
                      _GROUPS_SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
                      [[ "$_GP_PORT" != "22" ]] && _GROUPS_SSH_OPTS="${_GROUPS_SSH_OPTS} -p ${_GP_PORT}"
                      export SSHPASS="$_GP_PASSWORD"
                      # shellcheck disable=SC2086
                      if sshpass -e ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "echo ok" &>/dev/null; then
                        unset SSHPASS
                        _preflight_ok=true
                        ok "Connected with password auth"
                        _section_h=$(( _section_h + 1 ))
                        # Copy SSH key to remote for future key auth
                        printf '  %bCopy SSH key to server for future logins? (y/N): %b' "${DIM}" "${RESET}"
                        local _copy_key=""
                        IFS= read -rsn1 _copy_key 2>/dev/null || true
                        _section_h=$(( _section_h + 1 ))
                        if [[ "$_copy_key" == "y" || "$_copy_key" == "Y" ]]; then
                          printf '\n'
                          export SSHPASS="$_GP_PASSWORD"
                          local _key_to_copy=""
                          [[ -f "$HOME/.ssh/id_ed25519.pub" ]] && _key_to_copy="$HOME/.ssh/id_ed25519.pub"
                          [[ -z "$_key_to_copy" && -f "$HOME/.ssh/id_rsa.pub" ]] && _key_to_copy="$HOME/.ssh/id_rsa.pub"
                          if [[ -n "$_key_to_copy" ]]; then
                            local _pub_key
                            _pub_key=$(cat "$_key_to_copy")
                            # shellcheck disable=SC2086
                            if sshpass -e ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" \
                              "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${_pub_key}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null; then
                              ok "SSH key copied — future deploys will use key auth"
                              # Revert config to key auth since key is now installed
                              if [[ -f "$_pcfg" ]]; then
                                local _ptmp="${_pcfg}.tmp"
                                jq 'del(.auth)' "$_pcfg" > "$_ptmp" && mv "$_ptmp" "$_pcfg"
                              fi
                            else
                              warn "Could not copy SSH key (password auth will be used)"
                            fi
                          else
                            warn "No SSH public key found (~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)"
                          fi
                          unset SSHPASS
                          _section_h=$(( _section_h + 1 ))
                        else
                          printf '\n'
                        fi
                      else
                        unset SSHPASS
                        warn "Password auth also failed"
                        _section_h=$(( _section_h + 1 ))
                      fi
                    fi
                  else
                    warn "sshpass not installed — cannot use password auth"
                    printf '  %bInstall: brew install hudochenkov/sshpass/sshpass%b\n' "${DIM}" "${RESET}"
                    _section_h=$(( _section_h + 2 ))
                  fi
                  ;;
                "Enter SSH key path")
                  printf '  SSH key path: '
                  local _new_key_path; IFS= read -r _new_key_path
                  _section_h=$(( _section_h + 1 ))
                  if [[ -n "$_new_key_path" ]]; then
                    local _resolved="$_new_key_path"
                    case "$_resolved" in "~"/*) _resolved="${HOME}/${_resolved#\~/}" ;; esac
                    if [[ -f "$_resolved" ]]; then
                      _GP_IDENTITY="$_new_key_path"
                      # Update project config
                      local _pcfg
                      _pcfg="$(fleet_cfg_project_dir "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT")/project.json"
                      if [[ -f "$_pcfg" ]]; then
                        local _ptmp="${_pcfg}.tmp"
                        jq --arg k "$_new_key_path" '.machine.identity_file = $k' "$_pcfg" > "$_ptmp" && mv "$_ptmp" "$_pcfg"
                      fi
                      _groups_build_ssh_opts
                      # shellcheck disable=SC2086
                      if ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "echo ok" &>/dev/null; then
                        _preflight_ok=true
                        ok "Connected with key: ${_new_key_path}"
                        _section_h=$(( _section_h + 1 ))
                      else
                        warn "Key auth still failed with ${_new_key_path}"
                        _section_h=$(( _section_h + 1 ))
                      fi
                    else
                      warn "Key file not found: ${_new_key_path}"
                      _section_h=$(( _section_h + 1 ))
                    fi
                  fi
                  ;;
                "Abort"|"__back__")
                  break
                  ;;
                "Skip")
                  break
                  ;;
              esac
              if [[ "$_preflight_ok" == "true" ]]; then break; fi
            fi
          fi
          # Non-recoverable failure — don't retry
          break
        done

        if [[ "$_preflight_ok" != "true" ]]; then
          printf 'Cannot reach %s@%s\n' "$_GP_USER" "$_GP_HOST" > "$log_file"
          [[ -n "$_ssh_err" ]] && printf '%s\n' "$_ssh_err" >> "$log_file"
          rc=1

          _result_lines[${#_result_lines[@]}]="$(printf '  %b✗%b %s  %b%s%b' "${RED}" "${RESET}" "$_pname" "${DIM}" "$_pdesc" "${RESET}")"
          _bar_state="error"
          printf '\033[%dA' "$_section_h"
          progress_bar "$_steps_done" "$_total_steps" "${_pname}  ${_pdesc}" "$_bar_state"
          printf '\n'
          local _ri=0
          while (( _ri < ${#_result_lines[@]} )); do
            printf '%b\033[K\n' "${_result_lines[$_ri]}"
            _ri=$(( _ri + 1 ))
          done
          printf '\033[J'
          _section_h=$(( 1 + ${#_result_lines[@]} ))

          echo ""
          _section_h=$(( _section_h + 1 ))
          if [[ -s "$log_file" ]]; then
            while IFS= read -r _eline; do
              _eline=$(printf '%s' "$_eline" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
              printf '    %b%s%b\n' "${RED}" "$_eline" "${RESET}"
              _section_h=$(( _section_h + 1 ))
            done < <(tail -5 "$log_file")
          fi

          # Skip to failure handling below (menu_select)
        fi

        if [[ "$_preflight_ok" == "true" ]]; then

        : > "$log_file"
        _group_deploy_remote "$group_name" "$i" "$log_file" &
        local _remote_pid=$!

        update_term_size
        local _sp_f=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        local _sp_i=0
        local _pw=$(( TERM_COLS - 8 ))
        (( _pw > 68 )) && _pw=68
        (( _pw < 10 )) && _pw=10

        # Full-section redraw: bar + results + spinner + 5 preview lines
        local _preview_n=5
        _section_h=$(( 1 + ${#_result_lines[@]} + 1 + _preview_n ))
        _bar_state=""
        # Print initial frame
        progress_bar "$_steps_done" "$_total_steps" "${_pname}  ${_pdesc}"
        printf '\n'
        local _ri=0
        while (( _ri < ${#_result_lines[@]} )); do
          printf '%b\033[K\n' "${_result_lines[$_ri]}"
          _ri=$(( _ri + 1 ))
        done
        printf '  %b%s%b %bDeploying %s remotely%b\033[K\n' \
          "${ACCENT}" "${_sp_f[0]}" "${RESET}" "${WHITE}" "$_pname" "${RESET}"
        local _pi_init=0
        while (( _pi_init < _preview_n )); do printf '\033[K\n'; _pi_init=$((_pi_init+1)); done

        while kill -0 "$_remote_pid" 2>/dev/null; do
          printf '\033[%dA' "$_section_h"
          progress_bar "$_steps_done" "$_total_steps" "${_pname}  ${_pdesc}"
          printf '\n'
          _ri=0
          while (( _ri < ${#_result_lines[@]} )); do
            printf '%b\033[K\n' "${_result_lines[$_ri]}"
            _ri=$(( _ri + 1 ))
          done
          printf '  %b%s%b %bDeploying %s remotely%b\033[K\n' \
            "${ACCENT}" "${_sp_f[$((_sp_i % 10))]}" "${RESET}" \
            "${WHITE}" "$_pname" "${RESET}"
          _sp_i=$(( _sp_i + 1 ))

          # Read last N lines from log for streaming preview
          local _tlines=()
          while IFS= read -r _tl; do
            _tl=$(printf '%s' "$_tl" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
            [[ -z "$_tl" ]] && continue
            _tlines[${#_tlines[@]}]="$_tl"
          done < <(tail -"$_preview_n" "$log_file" 2>/dev/null)

          local _tp_i=0
          while (( _tp_i < _preview_n )); do
            local _tp="${_tlines[$_tp_i]:-}"
            (( ${#_tp} > _pw )) && _tp="${_tp:0:$((_pw - 3))}..."
            printf '    %b%s%b\033[K\n' "${DIM}" "$_tp" "${RESET}"
            _tp_i=$(( _tp_i + 1 ))
          done
          [[ "$_group_interrupted" == "true" ]] && { kill "$_remote_pid" 2>/dev/null; break; }

          sleep 0.2
        done

        wait "$_remote_pid" 2>/dev/null
        rc=$?

        # Add result to tracking
        if (( rc == 0 )); then
          _steps_done=$(( _steps_done + 1 ))
          _result_lines[${#_result_lines[@]}]="$(printf '  %b✓%b %s  %b%s%b' "${GREEN}" "${RESET}" "$_pname" "${DIM}" "$_pdesc" "${RESET}")"
        elif (( rc == 130 )); then
          # Exit 130 = cancelled from remote dashboard
          _result_lines[${#_result_lines[@]}]="$(printf '  %b-%b %s  %bcancelled%b' "${YELLOW}" "${RESET}" "$_pname" "${DIM}" "${RESET}")"
          _bar_state="error"
        else
          _result_lines[${#_result_lines[@]}]="$(printf '  %b✗%b %s  %b%s%b' "${RED}" "${RESET}" "$_pname" "${DIM}" "$_pdesc" "${RESET}")"
          _bar_state="error"
        fi

        # Redraw section without animation
        printf '\033[%dA' "$_section_h"
        progress_bar "$_steps_done" "$_total_steps" "${_pname}  ${_pdesc}" "$_bar_state"
        printf '\n'
        _ri=0
        while (( _ri < ${#_result_lines[@]} )); do
          printf '%b\033[K\n' "${_result_lines[$_ri]}"
          _ri=$(( _ri + 1 ))
        done
        printf '\033[J'
        _section_h=$(( 1 + ${#_result_lines[@]} ))

        if (( rc == 0 )); then
          # Show remote deploy details (services deployed)
          if [[ -s "$log_file" ]]; then
            local _detail_count=0
            while IFS= read -r _dline; do
              _dline=$(printf '%s' "$_dline" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
              [[ -z "$_dline" ]] && continue
              # Skip empty or noise lines
              [[ "$_dline" == "ok" ]] && continue
              printf '    %b%s%b\n' "${DIM}" "$_dline" "${RESET}"
              _section_h=$(( _section_h + 1 ))
              _detail_count=$(( _detail_count + 1 ))
            done < <(tail -8 "$log_file")
          fi
        elif (( rc == 130 )); then
          # Cancelled — no error log needed
          :
        else
          echo ""
          _section_h=$(( _section_h + 1 ))
          if [[ -s "$log_file" ]]; then
            while IFS= read -r _eline; do
              _eline=$(printf '%s' "$_eline" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
              printf '    %b%s%b\n' "${RED}" "$_eline" "${RESET}"
              _section_h=$(( _section_h + 1 ))
            done < <(tail -5 "$log_file")
          fi
        fi

        fi # _preflight_ok == true
      fi

      # Handle interruption
      if [[ "$_group_interrupted" == "true" ]]; then
        err "${_pname} deploy interrupted"
        failed=$(( total - succeeded - skipped ))
        echo ""
        _group_deploy_summary "$succeeded" "$skipped" "$failed" "$total"
        trap - INT
        rm -f "$_group_lock"
        return 130
      fi

      if (( rc == 0 )); then
        succeeded=$(( succeeded + 1 ))
        break
      elif (( rc == 130 )); then
        # Remote deploy was cancelled from dashboard
        echo ""
        warn "Deploy cancelled on ${_pname}"
        skipped=$(( skipped + 1 ))
        break
      else
        # Bar already turned red in service/remote handler above
        echo ""
        _section_h=$(( _section_h + 1 ))
        menu_select "Deploy failed on ${_pname}" \
          "Retry" "Skip and continue" "Abort"
        # menu_select net footprint: 3 lines (blank + title + collapsed choice)
        _section_h=$(( _section_h + 3 ))

        case "$MENU_RESULT" in
          "Retry")
            # Clear everything from bar down, restart this project
            printf '\033[%dA' "$_section_h"
            _steps_done="$_steps_before"
            _bar_state=""
            # Truncate _result_lines back to _results_before
            if (( _results_before == 0 )); then
              _result_lines=()
            else
              local _kept=()
              local _rr=0
              while (( _rr < _results_before )); do
                _kept[${#_kept[@]}]="${_result_lines[$_rr]}"
                _rr=$(( _rr + 1 ))
              done
              _result_lines=("${_kept[@]}")
            fi
            progress_bar "$_steps_done" "$_total_steps" "${_pname}  ${_pdesc}"
            printf '\n\033[J'
            _section_h=1
            log_file="${log_dir}/group-${group_name}-${_pname}-$(date +%Y%m%d-%H%M%S).log"
            continue
            ;;
          "Skip and continue")
            # Remove un-deployed steps for this project from total
            if (( _svc_total > 0 )); then
              _total_steps=$(( _total_steps - _svc_total + (_steps_done - _steps_before) ))
            else
              _total_steps=$(( _total_steps - 1 ))
            fi
            # Update bar in-place (clear error state)
            printf '\033[%dA' "$_section_h"
            _bar_state=""
            progress_bar "$_steps_done" "$_total_steps" "${_pname}  ${_pdesc}"
            printf '\033[%dB' "$_section_h"
            skipped=$(( skipped + 1 ))
            break
            ;;
          "Abort"|"__back__")
            failed=$(( total - succeeded - skipped ))
            echo ""
            _group_deploy_summary "$succeeded" "$skipped" "$failed" "$total"
            trap - INT
            rm -f "$_group_lock"
            return 1
            ;;
        esac
      fi
    done

    i=$(( i + 1 ))
  done

  trap - INT
  rm -f "$_group_lock"
  echo ""
  _group_deploy_summary "$succeeded" "$skipped" "$failed" "$total"
}

_group_deploy_remote() {
  local group_name="$1" index="$2" log_file="$3"
  _groups_load_remote "$group_name" "$index"

  # Re-load password from session cache (pre-auth stored it, but _groups_load_remote resets _GP_PASSWORD)
  if [[ "$_GP_AUTH_METHOD" == "password" ]]; then
    _groups_load_ssh_password
  fi

  # Deploy gate: verify trust before deploying
  local _my_fp
  _my_fp=$(trust_fingerprint)
  local _trust_status=""
  _trust_status=$(groups_remote_exec "$group_name" "$index" \
    "muster trust verify --fingerprint '${_my_fp}'" 2>/dev/null) || true

  case "$_trust_status" in
    trusted) ;; # proceed
    pending)
      printf 'Deploy rejected: trust request pending approval on %s@%s\n' "$_GP_USER" "$_GP_HOST" > "$log_file"
      printf 'Accept on remote: muster trust accept %s\n' "$_my_fp" >> "$log_file"
      return 1
      ;;
    unknown)
      # Remote has trust system but doesn't know us — auto-send a join request
      # This handles groups added before the trust update
      local _my_label
      _my_label=$(trust_label)
      groups_remote_exec "$group_name" "$index" \
        "muster trust request --fingerprint '${_my_fp}' --label '${_my_label}'" &>/dev/null || true
      printf 'Trust request auto-sent to %s@%s\n' "$_GP_USER" "$_GP_HOST" > "$log_file"
      printf 'Deploy blocked until remote accepts. Run on remote: muster trust accept %s\n' "$_my_fp" >> "$log_file"
      return 1
      ;;
    "")
      # Empty = older muster without trust system, or muster not installed — allow deploy
      ;;
  esac

  # Build remote deploy command:
  # 1. Fix PATH for non-interactive SSH (muster installs to ~/.local/bin)
  # 2. Write .fleet_deploying so remote dashboard shows "deploying" status
  # 3. Export source info so remote history tracks who triggered the deploy
  # 4. Clean up .fleet_deploying on exit (even on failure)
  local _source_host
  _source_host=$(hostname 2>/dev/null || echo "unknown")
  local _source_label="${USER:-unknown}@${_source_host}"
  local cmd
  cmd="$(cat <<'REMOTECMD'
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"
REMOTECMD
  )"
  cmd="${cmd}; export MUSTER_DEPLOY_SOURCE='${_source_label}'"
  # Write fleet marker with source label (line 1) and event log line count (line 2)
  # so cancel knows exactly which services were deployed in THIS session
  cmd="${cmd}; mkdir -p .muster .muster/logs"
  cmd="${cmd}; touch .muster/logs/deploy-events.log"
  cmd="${cmd}; _evt_before=\$(wc -l < .muster/logs/deploy-events.log 2>/dev/null || echo 0)"
  cmd="${cmd}; printf '%s\n%s\n' '${_source_label}' \"\$_evt_before\" > .muster/.fleet_deploying"
  # Signal the remote dashboard to refresh (if running) so "Cancel" appears immediately
  cmd="${cmd}; [ -f .muster/.dashboard_pid ] && kill -USR1 \$(cat .muster/.dashboard_pid) 2>/dev/null"
  # Run deploy in background with a cancel watcher.
  # The watcher checks .fleet_deploying every second — when the remote
  # dashboard removes it (cancel), the watcher kills all session processes
  # and exits, which closes the SSH connection and stops the host.
  cmd="${cmd}; muster deploy --force & _dpid=\$!"
  cmd="${cmd}; while kill -0 \$_dpid 2>/dev/null; do"
  cmd="${cmd}   if [ ! -f .muster/.fleet_deploying ]; then"
  cmd="${cmd}     kill -KILL \$_dpid 2>/dev/null;"
  cmd="${cmd}     pkill -KILL -P \$_dpid 2>/dev/null;"
  # Kill grandchildren (timeout→hook→docker) without pkill -f (which self-matches)
  cmd="${cmd}     for _c in \$(pgrep -P \$_dpid 2>/dev/null); do pkill -KILL -P \$_c 2>/dev/null; done;"
  cmd="${cmd}     wait \$_dpid 2>/dev/null;"
  cmd="${cmd}     rm -f .muster/.fleet_deploying .muster/deploy.lock;"
  cmd="${cmd}     rm -f .muster/locks/*.lock 2>/dev/null;"
  cmd="${cmd}     exit 130;"
  cmd="${cmd}   fi; sleep 1;"
  cmd="${cmd} done"
  cmd="${cmd}; wait \$_dpid 2>/dev/null; _rc=\$?"
  # If .fleet_deploying was removed (cancel from dashboard), exit 130
  cmd="${cmd}; if [ ! -f .muster/.fleet_deploying ]; then rm -f .muster/deploy.lock; rm -f .muster/locks/*.lock 2>/dev/null; exit 130; fi"
  # Clean up and signal dashboard to refresh back to normal
  cmd="${cmd}; rm -f .muster/.fleet_deploying"
  cmd="${cmd}; [ -f .muster/.dashboard_pid ] && kill -USR1 \$(cat .muster/.dashboard_pid) 2>/dev/null"
  cmd="${cmd}; exit \$_rc"

  if [[ "$_GP_CLOUD" == "true" ]]; then
    # Cloud transport — pass cwd natively (agent handles directory change)
    source "$MUSTER_ROOT/lib/core/cloud.sh"
    _groups_cloud_config
    if ! _fleet_cloud_check "$_GP_HOST" 2>/dev/null; then
      printf 'Cannot reach cloud agent %s — check tunnel and relay\n' "$_GP_HOST" > "$log_file"
      return 1
    fi
    _fleet_cloud_exec "$_GP_HOST" "$cmd" "$_GP_PROJECT_DIR" >> "$log_file" 2>&1
  else
    # SSH transport — prepend cd for project dir
    if [[ -n "$_GP_PROJECT_DIR" ]]; then
      local _escaped_dir
      printf -v _escaped_dir '%q' "$_GP_PROJECT_DIR"
      cmd="cd ${_escaped_dir} && ${cmd}"
    fi
    # SSH transport (pre-flight already done in foreground)
    _groups_build_ssh_opts

    if [[ "$_GP_AUTH_METHOD" == "password" ]]; then
      export SSHPASS="$_GP_PASSWORD"
      # shellcheck disable=SC2086
      sshpass -e ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "$cmd" >> "$log_file" 2>&1
      local _rc=$?
      unset SSHPASS
      return $_rc
    else
      # shellcheck disable=SC2086
      ssh $_GROUPS_SSH_OPTS "${_GP_USER}@${_GP_HOST}" "$cmd" >> "$log_file" 2>&1
    fi
  fi
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
    local _pname _desc
    _pname=$(groups_project_name "$group_name" "$i")
    _desc=$(groups_project_desc "$group_name" "$i")

    local _is_local_dr=false
    _group_load_project_at "$group_name" "$i" && [[ "$_FP_TRANSPORT" == "local" ]] && _is_local_dr=true

    local _icon _color _tag
    if [[ "$_is_local_dr" == "true" ]]; then
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

    [[ "${_desc:0:1}" == "/" ]] && _desc="${_desc/#$HOME/~}"
    printf '  %b%d.%b %b%s%b %b%s%b  %b%s  %s%b\n' \
      "${DIM}" "$(( i + 1 ))" "${RESET}" \
      "$_color" "$_icon" "${RESET}" \
      "${WHITE}" "$_pname" "${RESET}" \
      "${DIM}" "$_tag" "$_desc" "${RESET}"

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
  display_name="$group_name"
  fleet_cfg_load "$group_name" 2>/dev/null && [[ -n "$_FL_NAME" && "$_FL_NAME" != "null" ]] && display_name="$_FL_NAME"

  echo ""
  printf '  %b%bGroup Status%b — %s\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}" "$display_name"
  echo ""

  local i=0
  while (( i < total )); do
    local _pname _pdesc
    _pname=$(groups_project_name "$group_name" "$i")
    _pdesc=$(groups_project_desc "$group_name" "$i")
    [[ "${_pdesc:0:1}" == "/" ]] && _pdesc="${_pdesc/#$HOME/~}"

    local _icon _color _tag _result=""
    local _is_local_st=false
    _group_load_project_at "$group_name" "$i" && [[ "$_FP_TRANSPORT" == "local" ]] && _is_local_st=true

    if [[ "$_is_local_st" == "true" ]]; then
      local _path="$_FP_PATH"

      if [[ -z "$_path" || "$_path" == "null" || ! -d "$_path" ]]; then
        _icon="●"; _color="${RED}"; _tag="missing"
      else
        local _muster_bin="${MUSTER_ROOT}/bin/muster"
        _result=$(cd "$_path" && "$_muster_bin" status --json 2>/dev/null) || true
      fi
    else
      # Remote: check connectivity then muster status (via transport dispatch)
      _groups_load_remote "$group_name" "$i"
      if [[ "$_GP_AUTH_METHOD" == "password" ]]; then
        _groups_load_ssh_password
      fi

      if groups_remote_check "$group_name" "$i"; then
        local cmd="muster status --json"
        if [[ "$_GP_CLOUD" == "true" ]]; then
          # Cloud: agent handles cwd natively
          source "$MUSTER_ROOT/lib/core/cloud.sh"
          _groups_cloud_config
          _result=$(_fleet_cloud_exec "$_GP_HOST" "$cmd" "$_GP_PROJECT_DIR" 2>/dev/null) || true
        else
          # SSH: prepend cd for project dir
          if [[ -n "$_GP_PROJECT_DIR" ]]; then
            local _escaped_dir
            printf -v _escaped_dir '%q' "$_GP_PROJECT_DIR"
            cmd="cd ${_escaped_dir} && ${cmd}"
          fi
          _result=$(groups_remote_exec "$group_name" "$i" "$cmd" 2>/dev/null) || true
        fi
      else
        _icon="●"; _color="${RED}"; _tag="unreachable"
      fi
    fi

    # Parse service results
    local _svc_keys="" _svc_count=0 _healthy=0
    if [[ -n "$_result" ]] && printf '%s' "$_result" | jq -e '.services' &>/dev/null; then
      # Use deploy_order for local projects, keys[] for remote/fallback
      _svc_keys=""
      if [[ "$_is_local_st" == "true" && -n "${_path:-}" ]]; then
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
    printf '    %b%s%b\n' "${DIM}" "$_pdesc" "${RESET}"

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
    local _pname _desc
    _pname=$(groups_project_name "$group_name" "$i")
    _desc=$(groups_project_desc "$group_name" "$i")

    local _is_local_json=false _type="remote"
    _group_load_project_at "$group_name" "$i" && [[ "$_FP_TRANSPORT" == "local" ]] && { _is_local_json=true; _type="local"; }

    local _status="unknown"
    if [[ "$_is_local_json" == "true" ]]; then
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
        display_name="$gname"
        fleet_cfg_load "$gname" 2>/dev/null && [[ -n "$_FL_NAME" && "$_FL_NAME" != "null" ]] && display_name="$_FL_NAME"
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
      local _dn="${group_names[$gi]}"
      fleet_cfg_load "${group_names[$gi]}" 2>/dev/null && [[ -n "$_FL_NAME" && "$_FL_NAME" != "null" ]] && _dn="$_FL_NAME"
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
          local _dn="${group_names[$mi]}"
          fleet_cfg_load "${group_names[$mi]}" 2>/dev/null && [[ -n "$_FL_NAME" && "$_FL_NAME" != "null" ]] && _dn="$_FL_NAME"
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
  display_name="$group_name"
  fleet_cfg_load "$group_name" 2>/dev/null && [[ -n "$_FL_NAME" && "$_FL_NAME" != "null" ]] && display_name="$_FL_NAME"

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
    local _pname _desc
    _pname=$(groups_project_name "$group_name" "$pi")
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

  if _group_project_is_local "$group_name" "$sel_idx"; then
    local _path="$_FP_PATH"
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

  # Load current values from fleet dirs
  _groups_load_remote "$group_name" "$idx" || { err "Project not found"; return 1; }

  local cur_host="$_GP_HOST"
  local cur_user="$_GP_USER"
  local cur_port="$_GP_PORT"
  local cur_key="$_GP_IDENTITY"
  local cur_dir="$_GP_PROJECT_DIR"
  local cur_cloud="false"
  [[ "$_FP_TRANSPORT" == "cloud" ]] && cur_cloud="true"
  local cur_auth="$_GP_AUTH_METHOD"
  local cur_auth_mode="$_GP_AUTH_MODE"
  local cur_hook_mode="$_FP_HOOK_MODE"
  [[ -z "$cur_hook_mode" || "$cur_hook_mode" == "null" ]] && cur_hook_mode="manual"

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

  # Cloud transport
  local _cloud_display="no"
  [[ "$cur_cloud" == "true" ]] && _cloud_display="yes"
  printf '  Cloud tunnel [%s] (yes/no): ' "$_cloud_display"
  local new_cloud_input; IFS= read -r new_cloud_input
  local new_cloud="$cur_cloud"
  case "$new_cloud_input" in
    yes|y|true)  new_cloud="true" ;;
    no|n|false)  new_cloud="false" ;;
    "") ;;  # keep current
    *) warn "Invalid value, keeping current"; ;;
  esac

  # Auth method
  printf '  Auth method [%s] (key/password/agent): ' "$cur_auth"
  local new_auth_input; IFS= read -r new_auth_input
  local new_auth="$cur_auth"
  case "$new_auth_input" in
    key|password|agent) new_auth="$new_auth_input" ;;
    "") ;;  # keep current
    *) warn "Invalid value, keeping current"; ;;
  esac

  # SSH key (only for key auth)
  local new_key="$cur_key"
  if [[ "$new_auth" == "key" ]]; then
    printf '  SSH key [%s]: ' "${cur_key:-(none)}"
    local key_input; IFS= read -r key_input
    [[ -n "$key_input" ]] && new_key="$key_input"
    _group_validate_ssh_key "$new_key"
  fi

  # Auth mode (only for password auth)
  local new_auth_mode="$cur_auth_mode"
  if [[ "$new_auth" == "password" ]]; then
    _ensure_sshpass || return 1
    printf '  Password mode [%s] (save/session/always): ' "${cur_auth_mode:-session}"
    local mode_input; IFS= read -r mode_input
    case "$mode_input" in
      save|session|always) new_auth_mode="$mode_input" ;;
      "") [[ -z "$new_auth_mode" ]] && new_auth_mode="session" ;;
      *) warn "Invalid value, using session"; new_auth_mode="session" ;;
    esac
  fi

  printf '  Project dir [%s]: ' "${cur_dir:-(none)}"
  local new_dir; IFS= read -r new_dir
  [[ -z "$new_dir" ]] && new_dir="$cur_dir"

  # Hook mode
  printf '  Hook mode [%s] (manual/sync): ' "$cur_hook_mode"
  local new_hook_mode_input; IFS= read -r new_hook_mode_input
  local new_hook_mode="$cur_hook_mode"
  case "$new_hook_mode_input" in
    manual|sync) new_hook_mode="$new_hook_mode_input" ;;
    "") ;;  # keep current
    *) warn "Invalid value, keeping current" ;;
  esac
  if [[ "$new_hook_mode" == "sync" && "$cur_hook_mode" != "sync" ]]; then
    printf '  %b  Sync mode: this machine pushes hooks before each deploy.%b\n' "${DIM}" "${RESET}"
    printf '  %b  No muster install needed on the target — just SSH access.%b\n' "${DIM}" "${RESET}"
  fi

  # Prompt for password now if switching to password auth with save/session
  if [[ "$new_auth" == "password" && "$new_auth_mode" != "always" ]]; then
    local _cred_key="ssh_${new_user}@${new_host}:${new_port}"
    local _pw
    _pw=$(_cred_prompt_password "SSH password for ${new_user}@${new_host}")
    if [[ -n "$_pw" ]]; then
      if [[ "$new_auth_mode" == "save" ]]; then
        _cred_keychain_save "groups" "$_cred_key" "$_pw" 2>/dev/null && ok "Password saved to keychain" || warn "Could not save to keychain"
      fi
      _cred_session_set "$_cred_key" "$_pw"
    fi
  fi

  # Test connectivity with new settings
  echo ""
  printf '  %bTesting connection...%b ' "${DIM}" "${RESET}"
  local _test_opts="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
  local _test_transport="ssh"
  [[ "$new_cloud" == "true" ]] && _test_transport="cloud"

  if [[ "$_test_transport" != "cloud" ]]; then
    if [[ "$new_auth" != "password" ]]; then
      _test_opts="${_test_opts} -o BatchMode=yes"
    fi
    if [[ -n "$new_key" ]]; then
      local _id_path="$new_key"
      case "$_id_path" in "~"/*) _id_path="${HOME}/${_id_path#\~/}" ;; esac
      _test_opts="${_test_opts} -i ${_id_path}"
    fi
    [[ "$new_port" != "22" ]] && _test_opts="${_test_opts} -p ${new_port}"

    local _test_ok=false
    if [[ "$new_auth" == "password" ]]; then
      local _test_pw=""
      _test_pw=$(_cred_session_get "ssh_${new_user}@${new_host}:${new_port}" 2>/dev/null) || true
      if [[ -n "$_test_pw" ]]; then
        export SSHPASS="$_test_pw"
        # shellcheck disable=SC2086
        if sshpass -e ssh $_test_opts "${new_user}@${new_host}" "echo ok" &>/dev/null; then
          _test_ok=true
        fi
        unset SSHPASS
      fi
    else
      # shellcheck disable=SC2086
      if ssh $_test_opts "${new_user}@${new_host}" "echo ok" &>/dev/null; then
        _test_ok=true
      fi
    fi

    if [[ "$_test_ok" == "true" ]]; then
      printf '%b✓%b\n' "${GREEN}" "${RESET}"
    else
      printf '%b✗%b\n' "${RED}" "${RESET}"
      warn "Connection failed — settings will be saved anyway"
      if [[ "$new_auth" == "key" ]]; then
        printf '  %bHint: try switching auth to "password" if this host requires a password%b\n' "${DIM}" "${RESET}"
      fi
    fi
  fi

  # Save to fleet dir project.json
  local _pcfg
  _pcfg="$(fleet_cfg_project_dir "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT")/project.json"

  local _new_transport="ssh"
  [[ "$new_cloud" == "true" ]] && _new_transport="cloud"

  local tmp="${_pcfg}.tmp"
  jq --arg host "$new_host" --arg user "$new_user" --argjson port "$new_port" \
    --arg key "$new_key" --arg dir "$new_dir" \
    --arg transport "$_new_transport" \
    --arg auth "$new_auth" --arg authmode "$new_auth_mode" \
    --arg hookmode "$new_hook_mode" \
    '.machine.host = $host |
     .machine.user = $user |
     .machine.port = $port |
     .machine.transport = $transport |
     .hook_mode = $hookmode |
     (if $auth == "key" and $key != "" then .machine.identity_file = $key
      else del(.machine.identity_file) end) |
     (if $auth == "password" then .auth = {method: "password"} + (if $authmode != "" then {mode: $authmode} else {} end)
      else del(.auth) end) |
     (if $dir != "" then .remote_path = $dir
      else del(.remote_path) end)' \
    "$_pcfg" > "$tmp" && mv "$tmp" "$_pcfg"

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

  # Cache project names and types before input loop (avoid jq per redraw)
  local _ro_names=() _ro_types=()
  local _ri=0
  while (( _ri < total )); do
    _ro_names[$_ri]=$(groups_project_name "$group_name" "$_ri")
    if _group_project_is_local "$group_name" "$_ri"; then
      _ro_types[$_ri]="local"
    else
      _ro_types[$_ri]="remote"
    fi
    _ri=$((_ri + 1))
  done

  _ro_draw() {
    local ri=0
    while (( ri < total )); do
      local _pname="${_ro_names[$ri]}"
      local _icon
      [[ "${_ro_types[$ri]}" == "local" ]] && _icon="●" || _icon="◆"

      if (( ri == selected )); then
        local text="  ▸ ${_icon} ${_pname}"
        local text_len=${#text}
        local bar_pad=$(( _ro_w - text_len ))
        (( bar_pad < 0 )) && bar_pad=0
        local pad
        printf -v pad '%*s' "$bar_pad" ""
        printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
      else
        printf '    %s %s\n' "$_icon" "$_pname"
      fi
      ri=$(( ri + 1 ))
    done

    # Done row
    if (( selected == total )); then
      local text="  ▸ Done"
      local text_len=${#text}
      local bar_pad=$(( _ro_w - text_len ))
      (( bar_pad < 0 )) && bar_pad=0
      local pad
      printf -v pad '%*s' "$bar_pad" ""
      printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
    else
      printf '    %bDone%b\n' "${DIM}" "${RESET}"
    fi
  }

  local total_lines=$(( total + 1 ))

  _ro_clear() {
    (( total_lines > 0 )) && printf '\033[%dA' "$total_lines"
    printf '\033[J'
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
          local next=$(( selected + 1 ))
          # Swap in fleet dir deploy_order
          local _ro_group
          for _ro_group in $(fleet_cfg_groups "$group_name"); do
            local _gcfg
            _gcfg="$(fleet_cfg_group_dir "$group_name" "$_ro_group")/group.json"
            if [[ -f "$_gcfg" ]]; then
              local _gtmp="${_gcfg}.tmp"
              jq --argjson a "$selected" --argjson b "$next" \
                '.deploy_order as $o | .deploy_order[$a] = $o[$b] | .deploy_order[$b] = $o[$a]' \
                "$_gcfg" > "$_gtmp" && mv "$_gtmp" "$_gcfg"
            fi
          done
          # Swap cached display data
          local _swap_n="${_ro_names[$selected]}" _swap_t="${_ro_types[$selected]}"
          _ro_names[$selected]="${_ro_names[$next]}"
          _ro_types[$selected]="${_ro_types[$next]}"
          _ro_names[$next]="$_swap_n"
          _ro_types[$next]="$_swap_t"
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
    display_name="$group_name"
    fleet_cfg_load "$group_name" 2>/dev/null && [[ -n "$_FL_NAME" && "$_FL_NAME" != "null" ]] && display_name="$_FL_NAME"

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
        local _pname _desc
        _pname=$(groups_project_name "$group_name" "$pi")
        _desc=$(groups_project_desc "$group_name" "$pi")

        local _icon _color
        local _hook_mode_badge=""
        local _is_local_dm=false
        _group_load_project_at "$group_name" "$pi" && [[ "$_FP_TRANSPORT" == "local" ]] && _is_local_dm=true

        if [[ "$_is_local_dm" == "true" ]]; then
          _icon="●"; _color="${GREEN}"
          _desc="${_desc/#$HOME/~}"
          local _raw_path
          _raw_path=$(groups_project_desc "$group_name" "$pi")
          [[ ! -d "$_raw_path" ]] && _color="${RED}"
        else
          _icon="◆"; _color="${ACCENT}"
          [[ "$_FP_HOOK_MODE" == "sync" ]] && _hook_mode_badge=" sync"
        fi

        if [[ -n "$_hook_mode_badge" ]]; then
          printf '    %b%s%b %b%s%b %b%s%b %b%s%b\n' \
            "$_color" "$_icon" "${RESET}" \
            "${WHITE}" "$_pname" "${RESET}" \
            "${DIM}" "$_desc" "${RESET}" \
            "${YELLOW}" "$_hook_mode_badge" "${RESET}"
        else
          printf '    %b%s%b %b%s%b %b%s%b\n' \
            "$_color" "$_icon" "${RESET}" \
            "${WHITE}" "$_pname" "${RESET}" \
            "${DIM}" "$_desc" "${RESET}"
        fi

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
