#!/usr/bin/env bash
# muster/lib/tui/dashboard.sh — Live status dashboard

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/core/updater.sh"

_HEALTH_CACHE_DIR="${HOME}/.muster/.health_cache"

_dashboard_pause() {
  echo ""
  echo -e "  ${DIM}Press any key to continue...${RESET}"
  IFS= read -rsn1 || true
}

_dashboard_print_svc_line() {
  local status_icon="$1" status_color="$2" display_name="$3" pad="$4" cred_warn="$5"
  if [[ -n "$cred_warn" ]]; then
    printf '  %b│%b  %b%s%b %s%s %b%s%b%b│%b\n' \
      "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" "$display_name" "$pad" "${YELLOW}" "$cred_warn" "${RESET}" "${ACCENT}" "${RESET}"
  else
    printf '  %b│%b  %b%s%b %s%s%b│%b\n' \
      "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" "$display_name" "$pad" "${ACCENT}" "${RESET}"
  fi
}

_dashboard_header() {
  load_config

  local project
  project=$(config_get '.project')

  muster_tui_fullscreen
  clear
  echo -e "\n  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}v${MUSTER_VERSION}${RESET}  ${WHITE}${project}${RESET}"
  print_platform
  echo ""

  local services
  services=$(config_services)

  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local inner=$(( w - 2 ))

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  # Launch health checks in background (write to persistent cache)
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

  # Top border with "Services" label
  local label="Services"
  local label_pad_len=$(( w - ${#label} - 3 ))
  (( label_pad_len < 1 )) && label_pad_len=1
  local label_pad
  label_pad=$(printf '%*s' "$label_pad_len" "" | sed 's/ /─/g')
  printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$label" "${RESET}${ACCENT}" "$label_pad" "${RESET}"

  # Render each service from cached health status
  local _idx=0
  while (( _idx < ${#_svc_keys[@]} )); do
    local svc="${_svc_keys[$_idx]}"

    # Read from persistent cache
    local status_icon status_color
    if [[ -f "${_HEALTH_CACHE_DIR}/${svc}" ]]; then
      local _result
      _result=$(cat "${_HEALTH_CACHE_DIR}/${svc}")
      case "$_result" in
        healthy)   status_icon="●"; status_color="$GREEN" ;;
        unhealthy) status_icon="●"; status_color="$RED" ;;
        disabled)  status_icon="○"; status_color="$GRAY" ;;
        *)         status_icon="○"; status_color="$YELLOW" ;;
      esac
    else
      # No cache yet — first run
      status_icon="○"
      status_color="$YELLOW"
    fi

    # Format service line
    local name
    name=$(config_get ".services.${svc}.name")
    local cred_enabled
    cred_enabled=$(config_get ".services.${svc}.credentials.enabled")

    local cred_warn=""
    local cred_extra=0
    if [[ "$cred_enabled" == "true" ]]; then
      cred_warn="! KEY"
      cred_extra=${#cred_warn}
      cred_extra=$((cred_extra + 1))
    fi

    local max_name=$(( inner - 4 - cred_extra ))
    (( max_name < 5 )) && max_name=5
    local display_name="$name"
    if (( ${#display_name} > max_name )); then
      display_name="${display_name:0:$((max_name - 3))}..."
    fi

    local content_len=$(( 4 + ${#display_name} + cred_extra ))
    local pad_len=$(( inner - content_len ))
    (( pad_len < 0 )) && pad_len=0
    local pad
    pad=$(printf '%*s' "$pad_len" "")

    _dashboard_print_svc_line "$status_icon" "$status_color" "$display_name" "$pad" "$cred_warn"

    _idx=$((_idx + 1))
  done

  local bottom
  bottom=$(printf '%*s' "$w" "" | sed 's/ /─/g')
  printf '  %b└%s┘%b\n' "${ACCENT}" "$bottom" "${RESET}"
  echo ""

  # Fleet panel (only if remotes.json exists)
  local _fleet_config="${project_dir}/remotes.json"
  if [[ -f "$_fleet_config" ]] && has_cmd jq; then
    local _fleet_label="Fleet"
    local _fleet_label_pad_len=$(( w - ${#_fleet_label} - 3 ))
    (( _fleet_label_pad_len < 1 )) && _fleet_label_pad_len=1
    local _fleet_label_pad
    _fleet_label_pad=$(printf '%*s' "$_fleet_label_pad_len" "" | sed 's/ /─/g')
    printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$_fleet_label" "${RESET}${ACCENT}" "$_fleet_label_pad" "${RESET}"

    local _fleet_machines
    _fleet_machines=$(jq -r '.machines | keys[]' "$_fleet_config" 2>/dev/null)

    if [[ -z "$_fleet_machines" ]]; then
      local _empty_msg="No machines configured"
      local _empty_pad_len=$(( inner - ${#_empty_msg} - 2 ))
      (( _empty_pad_len < 0 )) && _empty_pad_len=0
      local _empty_pad
      _empty_pad=$(printf '%*s' "$_empty_pad_len" "")
      printf '  %b│%b  %b%s%b%s%b│%b\n' "${ACCENT}" "${RESET}" "${DIM}" "$_empty_msg" "${RESET}" "$_empty_pad" "${ACCENT}" "${RESET}"
    else
      # Launch background SSH checks (same pattern as health checks)
      local _fleet_cache_dir="${_HEALTH_CACHE_DIR}/fleet"
      mkdir -p "$_fleet_cache_dir"
      local _fleet_keys=()

      while IFS= read -r _fm; do
        [[ -z "$_fm" ]] && continue
        _fleet_keys[${#_fleet_keys[@]}]="$_fm"

        # Background connectivity check
        (
          local _fm_data
          _fm_data=$(jq -r --arg n "$_fm" '.machines[$n] | "\(.user // "")\n\(.host // "")\n\(.port // 22)\n\(.identity_file // "")"' "$_fleet_config" 2>/dev/null)
          local _u="" _h="" _p="" _id=""
          local _li=0
          while IFS= read -r _line; do
            case $_li in
              0) _u="$_line" ;; 1) _h="$_line" ;; 2) _p="$_line" ;; 3) _id="$_line" ;;
            esac
            _li=$(( _li + 1 ))
          done <<< "$_fm_data"
          [[ -z "$_p" || "$_p" == "null" ]] && _p="22"
          [[ "$_id" == "null" ]] && _id=""

          local _sopts="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
          [[ -n "$_id" ]] && _sopts="${_sopts} -i ${_id/#\~/$HOME}"
          [[ "$_p" != "22" ]] && _sopts="${_sopts} -p ${_p}"

          if ssh $_sopts "${_u}@${_h}" "echo ok" &>/dev/null; then
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
        local _fm_data
        _fm_data=$(jq -r --arg n "$_fm" '.machines[$n] | "\(.user)@\(.host) \(.mode // "push")"' "$_fleet_config" 2>/dev/null)
        local _fm_host="${_fm_data% *}"
        local _fm_mode="${_fm_data##* }"

        # Read cached status
        local _fm_status_icon="○" _fm_status_color="$YELLOW"
        if [[ -f "${_fleet_cache_dir}/${_fm}" ]]; then
          local _fm_cached
          _fm_cached=$(cat "${_fleet_cache_dir}/${_fm}")
          case "$_fm_cached" in
            online)  _fm_status_icon="●"; _fm_status_color="$GREEN" ;;
            offline) _fm_status_icon="●"; _fm_status_color="$RED" ;;
          esac
        fi

        local _fm_display="${_fm}: ${_fm_host} (${_fm_mode})"
        local _max_fm=$(( inner - 4 ))
        if (( ${#_fm_display} > _max_fm )); then
          _fm_display="${_fm_display:0:$((_max_fm - 3))}..."
        fi

        local _fm_content_len=$(( 4 + ${#_fm_display} ))
        local _fm_pad_len=$(( inner - _fm_content_len ))
        (( _fm_pad_len < 0 )) && _fm_pad_len=0
        local _fm_pad
        _fm_pad=$(printf '%*s' "$_fm_pad_len" "")

        printf '  %b│%b  %b%s%b %s%s%b│%b\n' \
          "${ACCENT}" "${RESET}" "$_fm_status_color" "$_fm_status_icon" "${RESET}" "$_fm_display" "$_fm_pad" "${ACCENT}" "${RESET}"

        _fi=$(( _fi + 1 ))
      done
    fi

    local _fleet_bottom
    _fleet_bottom=$(printf '%*s' "$w" "" | sed 's/ /─/g')
    printf '  %b└%s┘%b\n' "${ACCENT}" "$_fleet_bottom" "${RESET}"
    echo ""
  fi
}

_dashboard_home() {
  source "$MUSTER_ROOT/lib/core/registry.sh"

  # Kick off background update check (non-blocking)
  update_check_start

  while true; do
    muster_tui_fullscreen
    clear
    echo -e "\n  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}v${MUSTER_VERSION}${RESET}"
    echo ""

    # Collect background update check result
    update_check_collect
    if [[ "$MUSTER_UPDATE_AVAILABLE" == "true" ]]; then
      echo -e "  ${YELLOW}!${RESET} ${DIM}A new version of muster is available${RESET}"
      echo ""
    fi

    # Promote muster-tui if not installed
    if ! command -v muster-tui >/dev/null 2>&1; then
      echo -e "  ${ACCENT_BRIGHT}*${RESET} ${DIM}Try the new Go TUI:${RESET} ${WHITE}go install github.com/ImJustRicky/muster-tui@latest${RESET} ${DIM}(beta)${RESET}"
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
    local inner=$(( w - 2 ))

    if (( _count > 0 )); then
      # Top border with "Projects" label
      local label="Projects"
      local label_pad_len=$(( w - ${#label} - 3 ))
      (( label_pad_len < 1 )) && label_pad_len=1
      local label_pad
      label_pad=$(printf '%*s' "$label_pad_len" "" | sed 's/ /─/g')
      printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$label" "${RESET}${ACCENT}" "$label_pad" "${RESET}"

      local _pi=0
      while (( _pi < _count )); do
        local _display_path="${_project_paths[$_pi]}"
        _display_path="${_display_path/#$HOME/~}"
        local _pname="${_project_names[$_pi]}"

        # Truncate path to fit
        local max_path=$(( inner - ${#_pname} - 5 ))
        (( max_path < 5 )) && max_path=5
        if (( ${#_display_path} > max_path )); then
          _display_path="...${_display_path: -$((max_path - 3))}"
        fi

        local content_len=$(( 4 + ${#_pname} + 1 + ${#_display_path} ))
        local pad_len=$(( inner - content_len ))
        (( pad_len < 0 )) && pad_len=0
        local pad
        pad=$(printf '%*s' "$pad_len" "")

        printf '  %b│%b  %b●%b %b%s%b %b%s%b%s%b│%b\n' \
          "${ACCENT}" "${RESET}" "${GREEN}" "${RESET}" \
          "${WHITE}" "$_pname" "${RESET}" \
          "${DIM}" "$_display_path" "${RESET}" \
          "$pad" "${ACCENT}" "${RESET}"

        actions[${#actions[@]}]="${_pname}"
        _pi=$(( _pi + 1 ))
      done

      local bottom
      bottom=$(printf '%*s' "$w" "" | sed 's/ /─/g')
      printf '  %b└%s┘%b\n' "${ACCENT}" "$bottom" "${RESET}"
    else
      echo -e "  ${DIM}No projects registered yet.${RESET}"
      echo -e "  ${DIM}Run 'muster setup' in a project directory.${RESET}"
    fi

    echo ""
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
      "Setup new project")
        source "$MUSTER_ROOT/lib/commands/setup.sh"
        cmd_setup || true
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
      *)
        # Must be a project selection — find matching name
        local _si=0
        while (( _si < _count )); do
          if [[ "$MENU_RESULT" == "${_project_names[$_si]}" ]]; then
            local _target="${_project_paths[$_si]}"
            if [[ -d "$_target" ]]; then
              cd "$_target"
              cmd_dashboard
              return 0
            else
              echo -e "  ${RED}Directory not found:${RESET} $_target"
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
  if [[ ! -t 0 ]]; then
    printf '%b\n' "${RED}Error: interactive terminal required${RESET}" >&2
    printf '%b\n' "Use flag-based setup instead: muster setup --help" >&2
    return 1
  fi

  # If not inside a project, show the home screen
  if ! find_config &>/dev/null; then
    _dashboard_home
    return $?
  fi

  # Kick off background update check (non-blocking)
  update_check_start

  while true; do
    _dashboard_header

    # Collect background update check result
    update_check_collect
    if [[ "$MUSTER_UPDATE_AVAILABLE" == "true" ]]; then
      echo -e "  ${YELLOW}!${RESET} ${DIM}A new version of muster is available${RESET}"
      echo ""
    fi

    # Promote muster-tui if not installed
    if ! command -v muster-tui >/dev/null 2>&1; then
      echo -e "  ${ACCENT_BRIGHT}*${RESET} ${DIM}Try the new Go TUI:${RESET} ${WHITE}go install github.com/ImJustRicky/muster-tui@latest${RESET} ${DIM}(beta)${RESET}"
      echo ""
    fi

    # Collect available actions
    local actions=()
    local project_dir
    project_dir="$(dirname "$CONFIG_FILE")"
    local services
    services=$(config_services)

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

    # Add Fleet action if remotes.json exists
    if [[ -f "${project_dir}/remotes.json" ]]; then
      actions[${#actions[@]}]="Fleet"
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
      curl -fsSL "https://raw.githubusercontent.com/ImJustRicky/muster-skills/main/registry.json" \
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

    if [[ "$MUSTER_UPDATE_AVAILABLE" == "true" ]]; then
      actions[${#actions[@]}]="Update muster"
    fi
    actions[${#actions[@]}]="Quit"

    MENU_TIMEOUT=20
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
      Fleet)
        source "$MUSTER_ROOT/lib/commands/fleet.sh"
        cmd_fleet
        _dashboard_pause
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
      Quit)
        echo ""
        exit 0
        ;;
    esac
  done
}
