#!/usr/bin/env bash
# muster/lib/tui/dashboard.sh — Live status dashboard

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/core/updater.sh"
source "$MUSTER_ROOT/lib/core/build_context.sh"
source "$MUSTER_ROOT/lib/core/just_runner.sh"

_HEALTH_CACHE_DIR="${HOME}/.muster/health_cache"

# ── Shared header bar ──
# Renders a mustard-background branded header bar
# Usage: _dashboard_bar "left text" "right text"
_dashboard_bar() {
  local left="$1" right="${2:-}"
  local bar_w=$(( TERM_COLS - 2 ))
  (( bar_w < 20 )) && bar_w=20
  local text="  ${left}"
  local text_len=${#text}
  local right_len=${#right}
  local pad_len=$(( bar_w - text_len - right_len ))
  (( pad_len < 1 )) && pad_len=1
  local pad
  printf -v pad '%*s' "$pad_len" ""
  printf ' \033[48;5;178m\033[38;5;0m\033[1m%s%s%s\033[0m\n' "$text" "$pad" "$right"
}

# ── Thin separator ──
_dashboard_rule() {
  local rule_w=$(( TERM_COLS - 4 ))
  (( rule_w > 50 )) && rule_w=50
  (( rule_w < 10 )) && rule_w=10
  local rule
  printf -v rule '%*s' "$rule_w" ""
  rule="${rule// /─}"
  printf '  %b%s%b\n' "${GRAY}" "$rule" "${RESET}"
}

_dashboard_pause() {
  echo ""
  printf '  %bPress any key to continue...%b' "$DIM" "$RESET"
  IFS= read -rsn1 -t 60 || true
  echo ""
}

_dashboard_print_svc_line() {
  local status_icon="$1" status_color="$2" display_name="$3" status_label="$4" cred_warn="$5" max_w="$6" lock_info="${7:-}"

  local left="  ${display_name}"
  local right="${status_label}"
  if [[ -n "$lock_info" ]]; then
    right="${lock_info} ${status_label}"
  fi
  if [[ -n "$cred_warn" ]]; then
    right="${cred_warn}  ${right}"
  fi

  local left_len=${#left}
  local right_len=${#right}
  local pad_len=$(( max_w - left_len - right_len - 4 ))
  (( pad_len < 1 )) && pad_len=1
  local pad
  printf -v pad '%*s' "$pad_len" ""

  if [[ -n "$cred_warn" && -n "$lock_info" ]]; then
    printf '  %b%s%b %s%s%b%s%b  %b%s%b %b%s%b\n' \
      "$status_color" "$status_icon" "${RESET}" "$display_name" "$pad" "${YELLOW}" "$cred_warn" "${RESET}" "${YELLOW}" "$lock_info" "${RESET}" "${DIM}" "$status_label" "${RESET}"
  elif [[ -n "$lock_info" ]]; then
    printf '  %b%s%b %s%s%b%s%b %b%s%b\n' \
      "$status_color" "$status_icon" "${RESET}" "$display_name" "$pad" "${YELLOW}" "$lock_info" "${RESET}" "${DIM}" "$status_label" "${RESET}"
  elif [[ -n "$cred_warn" ]]; then
    printf '  %b%s%b %s%s%b%s%b  %b%s%b\n' \
      "$status_color" "$status_icon" "${RESET}" "$display_name" "$pad" "${YELLOW}" "$cred_warn" "${RESET}" "${DIM}" "$status_label" "${RESET}"
  else
    printf '  %b%s%b %s%s%b%s%b\n' \
      "$status_color" "$status_icon" "${RESET}" "$display_name" "$pad" "${DIM}" "$status_label" "${RESET}"
  fi
}

_dashboard_header() {
  load_config

  local project
  project=$(config_get '.project')

  muster_tui_fullscreen
  clear

  # Branded header bar
  local _right="v${MUSTER_VERSION}  ${MUSTER_OS} ${MUSTER_ARCH}  "
  echo ""
  _dashboard_bar "muster  ${project}" "$_right"
  echo ""

  local services
  services=$(config_services)

  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  # Gather active service locks (also cleans stale locks)
  local _svc_locks=""
  _svc_locks=$(_service_lock_list "$project_dir" 2>/dev/null)

  # Launch health checks in background (write to persistent cache)
  # Migrate old cache dir
  if [[ -d "${HOME}/.muster/.health_cache" && ! -d "$_HEALTH_CACHE_DIR" ]]; then
    mv "${HOME}/.muster/.health_cache" "$_HEALTH_CACHE_DIR"
  fi
  mkdir -p "$_HEALTH_CACHE_DIR"
  local _svc_keys=()

  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    _svc_keys[${#_svc_keys[@]}]="$svc"

    local hook_dir="${project_dir}/.muster/hooks/${svc}"
    local health_enabled
    health_enabled=$(config_get ".services.${svc}.health.enabled")

    if [[ "$health_enabled" == "false" ]]; then
      printf 'disabled' > "${_HEALTH_CACHE_DIR}/${svc}"
    elif _just_available "$hook_dir" && _just_has_recipe "$hook_dir" "health"; then
      (
        if just --justfile "${hook_dir}/justfile" health &>/dev/null; then
          printf 'healthy' > "${_HEALTH_CACHE_DIR}/${svc}"
        else
          printf 'unhealthy' > "${_HEALTH_CACHE_DIR}/${svc}"
        fi
      ) &
    elif [[ -x "${hook_dir}/health.sh" ]]; then
      (
        if "${hook_dir}/health.sh" &>/dev/null; then
          printf 'healthy' > "${_HEALTH_CACHE_DIR}/${svc}"
        else
          printf 'unhealthy' > "${_HEALTH_CACHE_DIR}/${svc}"
        fi
      ) &
    else
      printf 'disabled' > "${_HEALTH_CACHE_DIR}/${svc}"
    fi
  done <<< "$services"

  # Check if a fleet deploy is in progress
  local _fleet_deploying="" _fleet_deploy_source=""
  if [[ -f "${project_dir}/.muster/.fleet_deploying" ]]; then
    _fleet_deploying="true"
    _fleet_deploy_source=$(cat "${project_dir}/.muster/.fleet_deploying" 2>/dev/null)
  fi

  # Check for pending fleet trust requests
  local _trust_pending_count=0
  if [[ -f "$HOME/.muster/fleet/pending.json" ]] && has_cmd jq; then
    _trust_pending_count=$(jq 'length' "$HOME/.muster/fleet/pending.json" 2>/dev/null)
    [[ -z "$_trust_pending_count" || "$_trust_pending_count" == "null" ]] && _trust_pending_count=0
  fi

  # Section header
  printf '  %b%bServices%b' "${BOLD}" "${WHITE}" "${RESET}"
  if [[ "$_fleet_deploying" == "true" ]]; then
    printf '  %b⟳ deploying via %s%b' "${YELLOW}" "${_fleet_deploy_source:-remote}" "${RESET}"
  fi
  printf '\n'

  if (( _trust_pending_count > 0 )); then
    printf '  %b⚠ %d trust request%s pending%b\n' \
      "${YELLOW}" "$_trust_pending_count" \
      "$([ "$_trust_pending_count" != "1" ] && echo "s")" "${RESET}"
  fi

  # Render each service from cached health status
  local _idx=0
  while (( _idx < ${#_svc_keys[@]} )); do
    local svc="${_svc_keys[$_idx]}"

    # Read from persistent cache
    local status_icon status_color status_label
    if [[ "$_fleet_deploying" == "true" ]]; then
      # Fleet deploy in progress — show deploying status
      status_icon="◆"; status_color="$YELLOW"; status_label="deploying"
    elif [[ -f "${_HEALTH_CACHE_DIR}/${svc}" ]]; then
      local _result
      _result=$(cat "${_HEALTH_CACHE_DIR}/${svc}")
      case "$_result" in
        healthy)   status_icon="●"; status_color="$GREEN";  status_label="healthy" ;;
        unhealthy) status_icon="●"; status_color="$RED";    status_label="unhealthy" ;;
        disabled)  status_icon="○"; status_color="$GRAY";   status_label="disabled" ;;
        *)         status_icon="○"; status_color="$YELLOW"; status_label="loading" ;;
      esac
    else
      status_icon="○"
      status_color="$YELLOW"
      status_label="loading"
    fi

    # Format service line
    local name
    name=$(config_get ".services.${svc}.name")
    local cred_enabled
    cred_enabled=$(config_get ".services.${svc}.credentials.enabled")

    local cred_warn=""
    if [[ "$cred_enabled" == "true" ]]; then
      cred_warn="KEY"
    fi

    # Check for active service lock
    local _lock_indicator=""
    if [[ -n "$_svc_locks" ]]; then
      local _lock_line=""
      _lock_line=$(printf '%s\n' "$_svc_locks" | grep "^${svc}|" | head -1)
      if [[ -n "$_lock_line" ]]; then
        local _lock_user _lock_source
        _lock_user=$(printf '%s' "$_lock_line" | cut -d'|' -f2)
        _lock_source=$(printf '%s' "$_lock_line" | cut -d'|' -f3)
        if [[ "$_lock_source" == "local" ]]; then
          _lock_indicator="[locked by ${_lock_user}]"
        else
          _lock_indicator="[locked by ${_lock_source}]"
        fi
        # Truncate if too long for TUI width
        local _max_lock_len=$(( w - ${#name} - ${#status_label} - ${#cred_warn} - 10 ))
        (( _max_lock_len < 8 )) && _max_lock_len=8
        if (( ${#_lock_indicator} > _max_lock_len )); then
          _lock_indicator="${_lock_indicator:0:$((_max_lock_len - 2))}..]"
        fi
      fi
    fi

    _dashboard_print_svc_line "$status_icon" "$status_color" "$name" "$status_label" "$cred_warn" "$w" "$_lock_indicator"

    _idx=$((_idx + 1))
  done

  _dashboard_rule
  echo ""

  # Fleet panel (remotes.json or fleet dirs)
  local _fleet_config="${project_dir}/remotes.json"
  local _has_fleet=false
  [[ -f "$_fleet_config" ]] && _has_fleet=true
  fleet_cfg_has_any 2>/dev/null && _has_fleet=true

  if [[ "$_has_fleet" == "true" ]] && has_cmd jq; then
    printf '  %b%bFleet%b\n' "${BOLD}" "${WHITE}" "${RESET}"

    # Collect machines from fleet dirs or legacy
    local _fleet_machines=""
    if fleet_cfg_has_any 2>/dev/null; then
      _fleet_machines=$(fleet_machines 2>/dev/null)
    elif [[ -f "$_fleet_config" ]]; then
      _fleet_machines=$(jq -r '.machines | keys[]' "$_fleet_config" 2>/dev/null)
    fi

    if [[ -z "$_fleet_machines" ]]; then
      printf '  %bNo machines configured%b\n' "${DIM}" "${RESET}"
    else
      # Launch background SSH checks
      local _fleet_cache_dir="${_HEALTH_CACHE_DIR}/fleet"
      mkdir -p "$_fleet_cache_dir"
      local _fleet_keys=()

      while IFS= read -r _fm; do
        [[ -z "$_fm" ]] && continue
        _fleet_keys[${#_fleet_keys[@]}]="$_fm"

        (
          _fleet_load_machine "$_fm" 2>/dev/null || true
          local _u="$_FM_USER" _h="$_FM_HOST" _p="$_FM_PORT" _id="$_FM_IDENTITY"
          [[ -z "$_p" || "$_p" == "null" ]] && _p="22"
          [[ "$_id" == "null" ]] && _id=""

          local _sopts="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
          [[ -n "$_id" ]] && _sopts="${_sopts} -i ${_id/#\~/$HOME}"
          [[ "$_p" != "22" ]] && _sopts="${_sopts} -p ${_p}"

          # shellcheck disable=SC2086
          if ssh -n $_sopts "${_u}@${_h}" "echo ok" &>/dev/null; then
            printf 'online' > "${_fleet_cache_dir}/${_fm}"
          else
            printf 'offline' > "${_fleet_cache_dir}/${_fm}"
          fi
        ) &
      done <<< "$_fleet_machines"

      # Render machines from cache
      local _fi=0
      while (( _fi < ${#_fleet_keys[@]} )); do
        local _fm="${_fleet_keys[$_fi]}"
        _fleet_load_machine "$_fm" 2>/dev/null || true
        local _fm_host="${_FM_USER}@${_FM_HOST}"
        local _fm_mode="${_FM_MODE}"

        local _fm_status_icon="○" _fm_status_color="$YELLOW" _fm_status_label="checking"
        if [[ -f "${_fleet_cache_dir}/${_fm}" ]]; then
          local _fm_cached
          _fm_cached=$(cat "${_fleet_cache_dir}/${_fm}")
          case "$_fm_cached" in
            online)  _fm_status_icon="●"; _fm_status_color="$GREEN"; _fm_status_label="online" ;;
            offline) _fm_status_icon="●"; _fm_status_color="$RED";   _fm_status_label="offline" ;;
          esac
        fi

        local _fm_display="${_fm}: ${_fm_host} (${_fm_mode})"
        _dashboard_print_svc_line "$_fm_status_icon" "$_fm_status_color" "$_fm_display" "$_fm_status_label" "" "$w"

        _fi=$(( _fi + 1 ))
      done
    fi

    _dashboard_rule
    echo ""
  fi
}

_dashboard_home() {
  set +u
  source "$MUSTER_ROOT/lib/core/registry.sh"
  source "$MUSTER_ROOT/lib/core/groups.sh"
  source "$MUSTER_ROOT/lib/commands/group.sh"

  # Kick off background update check (non-blocking)
  update_check_start

  while true; do
    muster_tui_fullscreen
    clear

    # Branded header bar
    local _right="v${MUSTER_VERSION}  ${MUSTER_OS} ${MUSTER_ARCH}  "
    echo ""
    _dashboard_bar "muster" "$_right"
    echo ""

    # Collect background update check result
    update_check_collect
    if [[ "$MUSTER_UPDATE_AVAILABLE" == "true" ]]; then
      local _banner_ver=""
      [[ -n "$_MUSTER_LATEST_TAG" ]] && _banner_ver=" (${_MUSTER_LATEST_TAG})"
      printf '  %b!%b %bUpdate available%s — run muster update%b\n' "${YELLOW}" "${RESET}" "${DIM}" "$_banner_ver" "${RESET}"
      echo ""
    fi

    # Load registered projects
    _registry_ensure_file
    local _project_names=()
    local _project_paths=()
    local _count=0

    if has_cmd jq; then
      _count=$(jq '.projects | length' "$MUSTER_PROJECTS_FILE" 2>/dev/null)
      [[ -z "$_count" ]] && _count=0

      local _i=0
      while (( _i < _count )); do
        local _pname _ppath
        _pname=$(jq -r ".projects[$_i].name" "$MUSTER_PROJECTS_FILE")
        _ppath=$(jq -r ".projects[$_i].path" "$MUSTER_PROJECTS_FILE")
        _project_names[${#_project_names[@]}]="$_pname"
        _project_paths[${#_project_paths[@]}]="$_ppath"
        _i=$(( _i + 1 ))
      done
    fi

    local actions=()

    local w=$(( TERM_COLS - 4 ))
    (( w > 50 )) && w=50
    (( w < 10 )) && w=10

    # Load groups and collect grouped project paths
    local _group_keys=()
    local _group_displays=()
    local _gcount=0
    local _grouped_paths=""

    # Use groups_list() which works with both fleet dirs and legacy groups.json
    while IFS= read -r _gkey; do
      [[ -z "$_gkey" ]] && continue
      _group_keys[${#_group_keys[@]}]="$_gkey"
      _group_displays[${#_group_displays[@]}]="$_gkey"
      _gcount=$(( _gcount + 1 ))

      # Collect local project paths from this group
      local _gpcount
      _gpcount=$(groups_project_count "$_gkey" 2>/dev/null)
      [[ -z "$_gpcount" ]] && _gpcount=0
      local _gpi=0
      while (( _gpi < _gpcount )); do
        local _gp_desc
        _gp_desc=$(groups_project_desc "$_gkey" "$_gpi" 2>/dev/null)
        # Only local transports have plain paths without @
        if [[ -n "$_gp_desc" && "$_gp_desc" != *"@"* && "$_gp_desc" != *"(cloud)"* ]]; then
          _grouped_paths="${_grouped_paths}|${_gp_desc}|"
        fi
        _gpi=$(( _gpi + 1 ))
      done
    done < <(groups_list 2>/dev/null)

    # ── Fleets section ──
    if (( _gcount > 0 )); then
      printf '  %b%bFleets%b\n' "${BOLD}" "${WHITE}" "${RESET}"

      local _gi=0
      while (( _gi < _gcount )); do
        local _gdisplay="${_group_displays[$_gi]}"
        local _gkey="${_group_keys[$_gi]}"
        local _gpcount
        _gpcount=$(groups_project_count "$_gkey" 2>/dev/null)
        [[ -z "$_gpcount" ]] && _gpcount=0

        local _right_text
        _right_text="${_gpcount} project$([ "$_gpcount" != "1" ] && echo "s")"
        local _left_len=$(( ${#_gdisplay} + 4 ))
        local _right_len=${#_right_text}
        local _pad_len=$(( w - _left_len - _right_len - 2 ))
        (( _pad_len < 1 )) && _pad_len=1
        local _pad
        printf -v _pad '%*s' "$_pad_len" ""

        printf '  %b○%b %b%s%b %s%b%s%b\n' \
          "${ACCENT}" "${RESET}" \
          "${WHITE}" "$_gdisplay" "${RESET}" \
          "$_pad" "${DIM}" "$_right_text" "${RESET}"

        actions[${#actions[@]}]="Fleet: ${_gdisplay}"
        _gi=$(( _gi + 1 ))
      done

      _dashboard_rule
      echo ""
    fi

    # ── Ungrouped projects section ──
    local _ungrouped_names=()
    local _ungrouped_paths=()
    local _ungrouped_count=0

    local _pi=0
    while (( _pi < _count )); do
      local _ppath="${_project_paths[$_pi]}"
      if [[ "$_grouped_paths" != *"|${_ppath}|"* ]]; then
        _ungrouped_names[${#_ungrouped_names[@]}]="${_project_names[$_pi]}"
        _ungrouped_paths[${#_ungrouped_paths[@]}]="$_ppath"
        _ungrouped_count=$(( _ungrouped_count + 1 ))
      fi
      _pi=$(( _pi + 1 ))
    done

    if (( _ungrouped_count > 0 )); then
      printf '  %b%bProjects%b\n' "${BOLD}" "${WHITE}" "${RESET}"

      local _ui=0
      while (( _ui < _ungrouped_count )); do
        local _display_path="${_ungrouped_paths[$_ui]}"
        _display_path="${_display_path/#$HOME/~}"
        local _pname="${_ungrouped_names[$_ui]}"

        # Truncate path to fit
        local max_path=$(( w - ${#_pname} - 6 ))
        (( max_path < 5 )) && max_path=5
        if (( ${#_display_path} > max_path )); then
          _display_path="...${_display_path: -$((max_path - 3))}"
        fi

        local content_len=$(( 4 + ${#_pname} + 1 + ${#_display_path} ))
        local pad_len=$(( w - content_len ))
        (( pad_len < 0 )) && pad_len=0
        local pad
        printf -v pad '%*s' "$pad_len" ""

        printf '  %b●%b %b%s%b %b%s%b%s\n' \
          "${GREEN}" "${RESET}" \
          "${WHITE}" "$_pname" "${RESET}" \
          "${DIM}" "$_display_path" "${RESET}" \
          "$pad"

        actions[${#actions[@]}]="${_pname}"
        _ui=$(( _ui + 1 ))
      done

      _dashboard_rule
    elif (( _gcount == 0 )); then
      printf '  %bNo projects registered yet.%b\n' "${DIM}" "${RESET}"
      printf '  %bRun '\''muster setup'\'' in a project directory.%b\n' "${DIM}" "${RESET}"
    fi

    echo ""
    # If we're in a project directory, offer quick access
    local _cwd_project="" _cwd_project_name=""
    if find_config &>/dev/null; then
      _cwd_project=$(find_config)
      if has_cmd jq; then
        _cwd_project_name=$(jq -r '.project // "project"' "$_cwd_project" 2>/dev/null)
      else
        _cwd_project_name="project"
      fi
      actions[${#actions[@]}]="Current: ${_cwd_project_name}"
    fi
    actions[${#actions[@]}]="Setup new project"
    actions[${#actions[@]}]="Settings"
    if [[ "$MUSTER_UPDATE_AVAILABLE" == "true" ]]; then
      actions[${#actions[@]}]="Update muster"
    fi
    actions[${#actions[@]}]="Quit"

    menu_select "Actions" "${actions[@]}"

    case "$MENU_RESULT" in
      "Update muster")
        update_apply
        ;;
      Current:\ *)
        cmd_dashboard
        return 0
        ;;
      "Setup new project")
        source "$MUSTER_ROOT/lib/commands/setup.sh"
        cmd_setup || true
        # shellcheck disable=SC2034
        MUSTER_REDRAW_FN=""
        # After setup, check if we now have a config and switch to dashboard
        if find_config &>/dev/null; then
          cmd_dashboard
          return 0
        fi
        continue
        ;;
      "Settings")
        source "$MUSTER_ROOT/lib/commands/settings.sh"
        cmd_settings
        ;;
      "Quit")
        echo ""
        exit 0
        ;;
      Fleet:\ *)
        # Fleet selection — open group detail menu
        local _selected_fleet="${MENU_RESULT#Fleet: }"
        local _gsi=0
        while (( _gsi < ${#_group_keys[@]} )); do
          if [[ "$_selected_fleet" == "${_group_displays[$_gsi]}" ]]; then
            _group_detail_menu "${_group_keys[$_gsi]}"
            break
          fi
          _gsi=$(( _gsi + 1 ))
        done
        ;;
      __back__)
        # ESC pressed — no-op on home screen, just redraw
        ;;
      *)
        # Must be a project selection — find matching ungrouped name
        local _si=0
        while (( _si < _ungrouped_count )); do
          if [[ "$MENU_RESULT" == "${_ungrouped_names[$_si]}" ]]; then
            local _target="${_ungrouped_paths[$_si]}"
            if [[ -d "$_target" ]]; then
              cd "$_target" || return
              cmd_dashboard
              return 0
            else
              printf '  %bDirectory not found:%b %s\n' "${RED}" "${RESET}" "$_target"
              _dashboard_pause
            fi
            break
          fi
          _si=$(( _si + 1 ))
        done
        ;;
    esac
  done
}

cmd_dashboard() {
  # Disable strict unset checking in the TUI — many variables are conditionally set
  # and set -u causes silent exits that are hard to debug
  set +u

  if [[ ! -t 0 ]]; then
    printf '%b\n' "${RED}Error: interactive terminal required${RESET}" >&2
    printf '%b\n' "Use flag-based setup instead: muster setup --help" >&2
    set -u
    return 1
  fi

  # If not inside a project, show the home screen
  if ! find_config &>/dev/null; then
    _dashboard_home
    local _rc=$?
    set -u
    return $_rc
  fi

  # Kick off background update check (non-blocking)
  update_check_start

  # Detect fleet membership for current project
  load_config
  source "$MUSTER_ROOT/lib/core/groups.sh"
  local _fleet_key="" _fleet_display=""
  local _project_abs
  _project_abs="$(cd "$(dirname "$CONFIG_FILE")" 2>/dev/null && pwd)"
  # Check fleet dirs first, then legacy groups.json
  while IFS= read -r _gk; do
    [[ -z "$_gk" ]] && continue
    local _gpcount
    _gpcount=$(groups_project_count "$_gk" 2>/dev/null)
    [[ -z "$_gpcount" ]] && _gpcount=0
    local _gpi=0
    while (( _gpi < _gpcount )); do
      local _gp_desc
      _gp_desc=$(groups_project_desc "$_gk" "$_gpi" 2>/dev/null)
      # Match local project paths
      if [[ -n "$_gp_desc" && "$_gp_desc" != *"@"* && "$_gp_desc" != *"(cloud)"* ]]; then
        local _gp_abs
        _gp_abs="$(cd "$_gp_desc" 2>/dev/null && pwd)" || true
        if [[ "$_gp_abs" == "$_project_abs" ]]; then
          _fleet_key="$_gk"
          _fleet_display="$_gk"
          break 2
        fi
      fi
      _gpi=$(( _gpi + 1 ))
    done
  done < <(groups_list 2>/dev/null)

  # Save dashboard PID so fleet deploys can signal us to refresh
  local _dash_proj_dir
  _dash_proj_dir="$(dirname "$CONFIG_FILE")"
  printf '%s\n' "$$" > "${_dash_proj_dir}/.muster/.dashboard_pid"
  # Clean up PID file on exit
  trap 'rm -f "'"${_dash_proj_dir}"'/.muster/.dashboard_pid"; cleanup_term' EXIT
  # Trap USR1 — interrupts read -t on Linux, triggering immediate refresh
  trap 'true' USR1

  while true; do
    _dashboard_header

    # Collect background update check result
    update_check_collect
    if [[ "$MUSTER_UPDATE_AVAILABLE" == "true" ]]; then
      local _banner_ver=""
      [[ -n "$_MUSTER_LATEST_TAG" ]] && _banner_ver=" (${_MUSTER_LATEST_TAG})"
      printf '  %b!%b %bUpdate available%s — run muster update%b\n' "${YELLOW}" "${RESET}" "${DIM}" "$_banner_ver" "${RESET}"
      echo ""
    fi

    # Build context overlap detection (refresh cache if stale)
    local _bc_issue_count=0
    if _build_context_cache_stale; then
      _build_context_detect
    fi
    if _build_context_read_cache; then
      _bc_issue_count=${#_BUILD_CONTEXT_ISSUES[@]}
      printf '  %b!%b %bBuild context overlap — %d issue%s%b\n' \
        "${YELLOW}" "${RESET}" "${DIM}" "$_bc_issue_count" \
        "$( (( _bc_issue_count > 1 )) && echo s)" "${RESET}"
      echo ""
    fi

    # Fleet info with remote machine status
    if [[ -n "$_fleet_key" ]] && has_cmd jq; then
      printf '  %b○%b %bFleet:%b %s\n' "${ACCENT}" "${RESET}" "${DIM}" "${RESET}" "$_fleet_display"

      # Show remote machines with status
      local _fleet_total _fi=0
      _fleet_total=$(groups_project_count "$_fleet_key")
      local _status_dir="$HOME/.muster/.fleet_status"
      mkdir -p "$_status_dir" 2>/dev/null

      while (( _fi < _fleet_total )); do
        local _fp_desc
        _fp_desc=$(groups_project_desc "$_fleet_key" "$_fi" 2>/dev/null)

        # Show remote machines (desc contains @)
        if [[ -n "$_fp_desc" && "$_fp_desc" == *"@"* ]]; then
          local _machine_label="$_fp_desc"
          local _fp_name
          _fp_name=$(groups_project_name "$_fleet_key" "$_fi" 2>/dev/null)

          local _cache_key
          _cache_key=$(printf '%s' "$_fp_desc" | tr '@: ' '___')
          local _cache_file="${_status_dir}/${_cache_key}"
          local _machine_status="unknown"

          # Read cached status
          if [[ -f "$_cache_file" ]]; then
            _machine_status=$(cat "$_cache_file" 2>/dev/null)
          fi

          # Kick off background check if not cloud
          if [[ "$_fp_desc" != *"(cloud)"* ]]; then
            _groups_load_remote "$_fleet_key" "$_fi" 2>/dev/null || true
            if [[ -n "$_GP_HOST" ]]; then
              ( ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                  -p "${_GP_PORT:-22}" "${_GP_USER}@${_GP_HOST}" "echo online" >"$_cache_file" 2>/dev/null \
                || printf 'offline' >"$_cache_file" ) &
            fi
          fi

          local _status_icon _status_color
          case "$_machine_status" in
            online)  _status_icon="●"; _status_color="$GREEN" ;;
            offline) _status_icon="●"; _status_color="$RED" ;;
            *)       _status_icon="○"; _status_color="$GRAY" ;;
          esac

          printf '    %b%s%b %s %b%s%b\n' \
            "$_status_color" "$_status_icon" "${RESET}" \
            "$_machine_label" "${DIM}" "$_machine_status" "${RESET}"
        fi

        _fi=$(( _fi + 1 ))
      done

      # Show group deploy lock status on host
      if [[ -f "$HOME/.muster/.group_deploying" ]]; then
        local _gd_name
        _gd_name=$(cat "$HOME/.muster/.group_deploying" 2>/dev/null)
        printf '    %b⟳ deploying %s%b\n' "${YELLOW}" "${_gd_name:-...}" "${RESET}"
      fi

      echo ""
    elif [[ -n "$_fleet_display" ]]; then
      printf '  %b○%b %bFleet:%b %s\n' "${ACCENT}" "${RESET}" "${DIM}" "${RESET}" "$_fleet_display"
      echo ""
    fi

    # Collect available actions
    local actions=()
    local project_dir
    project_dir="$(dirname "$CONFIG_FILE")"
    local services
    services=$(config_services)

    # Check for active fleet deploy
    local _fleet_deploying_now=false _fleet_deploy_src=""
    if [[ -f "${project_dir}/.muster/.fleet_deploying" ]]; then
      _fleet_deploying_now=true
      _fleet_deploy_src=$(cat "${project_dir}/.muster/.fleet_deploying" 2>/dev/null)
    fi

    if [[ "$_fleet_deploying_now" == "true" ]]; then
      actions[${#actions[@]}]="Cancel fleet deploy"
    fi
    actions[${#actions[@]}]="Deploy"

    local has_rollback=false has_logs=false
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      local hook_dir="${project_dir}/.muster/hooks/${svc}"
      [[ -x "${hook_dir}/rollback.sh" ]] && has_rollback=true
      [[ -x "${hook_dir}/logs.sh" ]] && has_logs=true
    done <<< "$services"

    actions[${#actions[@]}]="Status"
    [[ "$has_logs" == "true" ]] && actions[${#actions[@]}]="Logs"
    [[ "$has_rollback" == "true" ]] && actions[${#actions[@]}]="Rollback"
    actions[${#actions[@]}]="Cleanup"

    local _doctor_label="Doctor"
    if (( _bc_issue_count > 0 )); then
      _doctor_label="Doctor !"
    fi
    actions[${#actions[@]}]="$_doctor_label"

    # Add Fleet action if remotes.json or fleet dirs exist
    if [[ -f "${project_dir}/remotes.json" ]] || fleet_cfg_has_any 2>/dev/null; then
      actions[${#actions[@]}]="Fleet"
    fi

    # Fleet action — show fleet this project belongs to, or generic Groups
    if [[ -n "$_fleet_key" ]]; then
      actions[${#actions[@]}]="Fleet: ${_fleet_display}"
    elif fleet_cfg_has_any 2>/dev/null; then
      local _fcount=0
      while IFS= read -r _fl; do
        [[ -n "$_fl" ]] && _fcount=$(( _fcount + 1 ))
      done < <(fleets_list 2>/dev/null)
      if (( _fcount > 0 )); then
        actions[${#actions[@]}]="Groups"
      fi
    elif [[ -f "$GROUPS_CONFIG_FILE" ]] && has_cmd jq; then
      local _gcount
      _gcount=$(jq '.groups | length' "$GROUPS_CONFIG_FILE" 2>/dev/null)
      if [[ -n "$_gcount" && "$_gcount" != "0" ]]; then
        actions[${#actions[@]}]="Groups"
      fi
    fi

    # Trust requests badge
    local _trust_pending_count=0
    if [[ -f "$HOME/.muster/fleet/pending.json" ]] && has_cmd jq; then
      _trust_pending_count=$(jq 'length' "$HOME/.muster/fleet/pending.json" 2>/dev/null)
      [[ -z "$_trust_pending_count" || "$_trust_pending_count" == "null" ]] && _trust_pending_count=0
    fi
    if (( _trust_pending_count > 0 )); then
      actions[${#actions[@]}]="Trust requests (${_trust_pending_count} pending)"
    fi

    actions[${#actions[@]}]="Settings"

    # Add installed skills from project and global dirs (check for updates via cached registry)
    local _project_skills_dir=""
    if [[ -n "${CONFIG_FILE:-}" ]]; then
      _project_skills_dir="$(dirname "$CONFIG_FILE")/.muster/skills"
    fi
    local _global_skills_dir="${HOME}/.muster/skills"
    local _registry_cache="${HOME}/.muster/.registry_cache.json"
    local _registry_stale="true"

    # Fetch registry if cache is missing or older than 5 minutes
    if [[ -f "$_registry_cache" ]]; then
      local _cache_age=0
      if has_cmd stat; then
        local _cache_mtime _now
        _cache_mtime=$(stat -c %Y "$_registry_cache" 2>/dev/null || stat -f %m "$_registry_cache" 2>/dev/null || echo 0)
        _now=$(date +%s)
        _cache_age=$(( _now - _cache_mtime ))
      fi
      if (( _cache_age < 300 )); then
        _registry_stale="false"
      fi
    fi
    if [[ "$_registry_stale" == "true" ]]; then
      curl -fsSL "https://raw.githubusercontent.com/Muster-dev/muster-skills/main/registry.json" \
        -o "$_registry_cache" 2>/dev/null \
        || curl -fsSL "https://raw.githubusercontent.com/ImJustRicky/muster-skills/main/registry.json" \
        -o "$_registry_cache" 2>/dev/null || true
    fi

    # Track skill names to skip global duplicates
    local _seen_skills=""

    # Helper: add skills from a directory to the actions menu
    _dashboard_add_skills_from() {
      local _sdir="$1"
      [[ ! -d "$_sdir" ]] && return
      for _skill_dir in "${_sdir}"/*/; do
        [[ ! -d "$_skill_dir" ]] && continue
        local _sname _sdisplay
        _sname=$(basename "$_skill_dir")

        # Skip if already seen (project takes priority)
        case " $_seen_skills " in
          *" $_sname "*) continue ;;
        esac
        _seen_skills="${_seen_skills} ${_sname}"

        _sdisplay="$_sname"
        local _local_ver=""
        if [[ -f "${_skill_dir}/skill.json" ]]; then
          local _jname=""
          if has_cmd jq; then
            _jname=$(jq -r '.name // ""' "${_skill_dir}/skill.json")
            _local_ver=$(jq -r '.version // ""' "${_skill_dir}/skill.json")
          elif has_cmd python3; then
            _jname=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('name',''))" "${_skill_dir}/skill.json" 2>/dev/null)
            _local_ver=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('version',''))" "${_skill_dir}/skill.json" 2>/dev/null)
          fi
          if [[ -n "$_jname" ]]; then
            _sdisplay="$_jname"
          fi
        fi

        # Check registry for newer version
        local _update_tag=""
        if [[ -f "$_registry_cache" ]] && has_cmd jq && [[ -n "$_local_ver" ]]; then
          local _remote_ver=""
          _remote_ver=$(jq -r --arg n "$_sdisplay" '.skills[] | select(.name == $n) | .version // ""' "$_registry_cache" 2>/dev/null)
          if [[ -n "$_remote_ver" && "$_remote_ver" != "$_local_ver" ]]; then
            _update_tag=" <- update"
          fi
        fi

        local _mode_tag=""
        if [[ -f "${_skill_dir}/.enabled" ]]; then
          local _hooks_raw=""
          if has_cmd jq && [[ -f "${_skill_dir}/skill.json" ]]; then
            _hooks_raw=$(jq -r '(.hooks // []) | join(", ")' "${_skill_dir}/skill.json")
          fi
          if [[ -n "$_hooks_raw" ]]; then
            local _hooks_short
            _hooks_short=$(printf '%s' "$_hooks_raw" | sed 's/post-//g; s/pre-/pre-/g')
            _mode_tag=" (${_hooks_short})"
          else
            _mode_tag=" (active)"
          fi
        fi

        actions[${#actions[@]}]="Skill: ${_sdisplay}${_mode_tag}${_update_tag}"
      done
    }

    # Project skills first, then global (duplicates skipped)
    [[ -n "$_project_skills_dir" ]] && _dashboard_add_skills_from "$_project_skills_dir"
    _dashboard_add_skills_from "$_global_skills_dir"

    actions[${#actions[@]}]="Skill Marketplace"

    actions[${#actions[@]}]="Home"
    if [[ "$MUSTER_UPDATE_AVAILABLE" == "true" ]]; then
      actions[${#actions[@]}]="Update muster"
    fi
    actions[${#actions[@]}]="Quit"

    MENU_TIMEOUT=5
    menu_select "Actions" "${actions[@]}"
    MENU_TIMEOUT=0

    # Escape from main menu returns to dashboard
    if [[ "$MENU_RESULT" == "__back__" ]]; then
      continue
    fi

    case "$MENU_RESULT" in
      "__timeout__")
        continue
        ;;
      "Cancel fleet deploy")
        local _cancel_file="${project_dir}/.muster/.fleet_deploying"
        if [[ -f "$_cancel_file" ]]; then
          # Read fleet marker: line 1 = source, line 2 = event log offset
          local _fleet_source="" _evt_before=0
          _fleet_source=$(head -1 "$_cancel_file" 2>/dev/null)
          _evt_before=$(sed -n '2p' "$_cancel_file" 2>/dev/null)
          [[ -z "$_evt_before" ]] && _evt_before=0

          # Remove fleet marker → SSH cancel watcher detects within 1s
          rm -f "$_cancel_file"

          # Direct process kill for immediate stop
          local _lock_file="${project_dir}/.muster/deploy.lock"
          if [[ -f "$_lock_file" ]]; then
            local _deploy_pid=""
            if has_cmd jq; then
              _deploy_pid=$(jq -r '.pid // empty' "$_lock_file" 2>/dev/null)
            elif has_cmd python3; then
              _deploy_pid=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('pid',''))" "$_lock_file" 2>/dev/null)
            fi
            if [[ -n "$_deploy_pid" ]] && kill -0 "$_deploy_pid" 2>/dev/null; then
              # Kill deploy process and its direct children only.
              # Do NOT use pkill -f — it matches the SSH wrapper's command
              # line too, preventing it from exiting cleanly with code 130.
              kill -KILL "$_deploy_pid" 2>/dev/null
              pkill -KILL -P "$_deploy_pid" 2>/dev/null
            fi
            rm -f "$_lock_file"
          fi

          # Clean up per-service locks left by the cancelled deploy
          rm -f "${project_dir}/.muster/locks/"*.lock 2>/dev/null

          ok "Fleet deploy cancelled"

          # Rollback services that were already deployed in this session
          local _events_file="${project_dir}/.muster/logs/deploy-events.log"
          if [[ -f "$_events_file" ]] && has_cmd jq; then
            local _rollback_svcs=()
            while IFS= read -r _rsvc; do
              [[ -n "$_rsvc" ]] && _rollback_svcs[${#_rollback_svcs[@]}]="$_rsvc"
            done < <(tail -n +"$(( _evt_before + 1 ))" "$_events_file" 2>/dev/null \
              | jq -r 'select(.action=="deploy" and .status=="ok") | .service' 2>/dev/null \
              | sort -u)

            if [[ ${#_rollback_svcs[@]} -gt 0 ]]; then
              echo ""
              warn "Rolling back ${#_rollback_svcs[@]} deployed service(s)..."
              source "$MUSTER_ROOT/lib/commands/rollback.sh"
              local _rsvc
              for _rsvc in "${_rollback_svcs[@]}"; do
                cmd_rollback "$_rsvc"
              done
            else
              printf '  %bNo services were fully deployed yet.%b\n' "${DIM}" "${RESET}"
            fi
          fi
        else
          info "No fleet deploy in progress"
        fi
        _dashboard_pause
        ;;
      Deploy)
        source "$MUSTER_ROOT/lib/commands/deploy.sh"
        cmd_deploy
        [[ $? -ne 2 ]] && _dashboard_pause
        ;;
      Status)
        source "$MUSTER_ROOT/lib/commands/status.sh"
        cmd_status
        _dashboard_pause
        ;;
      Logs)
        source "$MUSTER_ROOT/lib/commands/logs.sh"
        cmd_logs
        [[ $? -ne 2 ]] && _dashboard_pause
        ;;
      Rollback)
        source "$MUSTER_ROOT/lib/commands/rollback.sh"
        cmd_rollback
        [[ $? -ne 2 ]] && _dashboard_pause
        ;;
      Cleanup)
        source "$MUSTER_ROOT/lib/commands/cleanup.sh"
        cmd_cleanup
        _dashboard_pause
        ;;
      Doctor|"Doctor !")
        source "$MUSTER_ROOT/lib/commands/doctor.sh"
        cmd_doctor
        _dashboard_pause
        ;;
      Fleet)
        source "$MUSTER_ROOT/lib/commands/fleet.sh"
        cmd_fleet
        _dashboard_pause
        ;;
      Groups)
        source "$MUSTER_ROOT/lib/commands/group.sh"
        cmd_group
        ;;
      Fleet:\ *)
        source "$MUSTER_ROOT/lib/commands/group.sh"
        _group_detail_menu "$_fleet_key"
        ;;
      "Trust requests"*)
        source "$MUSTER_ROOT/lib/commands/trust.sh"
        _trust_cmd_manager
        ;;
      Settings)
        source "$MUSTER_ROOT/lib/commands/settings.sh"
        cmd_settings
        ;;
      Skill:\ *)
        local _selected_display="${MENU_RESULT#Skill: }"
        # Strip tags
        _selected_display="${_selected_display% <- update}"
        # Strip mode/hooks tag: " (deploy, rollback)" or " (active)"
        _selected_display="${_selected_display%% (*}"
        local _has_update="false"
        [[ "$MENU_RESULT" == *"<- update"* ]] && _has_update="true"

        # Find skill in project dir first, then global
        local _run_name="" _found_skills_dir=""
        local _search_dirs=""
        [[ -n "$_project_skills_dir" && -d "$_project_skills_dir" ]] && _search_dirs="$_project_skills_dir"
        if [[ -n "$_search_dirs" ]]; then
          _search_dirs="${_search_dirs}:${_global_skills_dir}"
        else
          _search_dirs="$_global_skills_dir"
        fi
        local _IFS_SAVE="$IFS"
        IFS=':'
        local _sd
        for _sd in $_search_dirs; do
          IFS="$_IFS_SAVE"
          for _skill_dir in "${_sd}"/*/; do
            [[ ! -d "$_skill_dir" ]] && continue
            local _cname _cdisplay
            _cname=$(basename "$_skill_dir")
            _cdisplay="$_cname"
            if [[ -f "${_skill_dir}/skill.json" ]]; then
              local _cjname=""
              if has_cmd jq; then
                _cjname=$(jq -r '.name // ""' "${_skill_dir}/skill.json")
              elif has_cmd python3; then
                _cjname=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('name',''))" "${_skill_dir}/skill.json" 2>/dev/null)
              fi
              if [[ -n "$_cjname" ]]; then
                _cdisplay="$_cjname"
              fi
            fi
            if [[ "$_cdisplay" == "$_selected_display" ]]; then
              _run_name="$_cname"
              _found_skills_dir="$_sd"
              break 2
            fi
          done
        done
        IFS="$_IFS_SAVE"

        if [[ -n "$_run_name" ]]; then
          source "$MUSTER_ROOT/lib/skills/manager.sh"
          # shellcheck disable=SC2034
          SKILLS_DIR="$_found_skills_dir"
          # Build submenu
          local _skill_opts=()
          _skill_opts[0]="Run"
          _skill_opts[${#_skill_opts[@]}]="Configure"
          if [[ -f "${_found_skills_dir}/${_run_name}/.enabled" ]]; then
            _skill_opts[${#_skill_opts[@]}]="Disable"
          else
            _skill_opts[${#_skill_opts[@]}]="Enable"
          fi
          if [[ "$_has_update" == "true" ]]; then
            _skill_opts[${#_skill_opts[@]}]="Update"
          fi
          _skill_opts[${#_skill_opts[@]}]="Remove"
          _skill_opts[${#_skill_opts[@]}]="Back"

          menu_select "${_selected_display}" "${_skill_opts[@]}"

          case "$MENU_RESULT" in
            "Run")
              skill_run "$_run_name"
              _dashboard_pause
              ;;
            "Configure")
              skill_configure "$_run_name"
              _dashboard_pause
              ;;
            "Enable")
              skill_enable "$_run_name"
              _dashboard_pause
              ;;
            "Disable")
              skill_disable "$_run_name"
              _dashboard_pause
              ;;
            "Update")
              skill_marketplace_install "$_run_name"
              _dashboard_pause
              ;;
            "Remove")
              skill_remove "$_run_name"
              _dashboard_pause
              ;;
            "Back"|"__back__")
              ;;
          esac
        fi
        ;;
      "Skill Marketplace")
        source "$MUSTER_ROOT/lib/skills/manager.sh"
        skill_marketplace
        _dashboard_pause
        ;;
      "Update muster")
        update_apply
        ;;
      Home)
        _dashboard_home
        return 0
        ;;
      Quit)
        echo ""
        exit 0
        ;;
    esac
  done
}
