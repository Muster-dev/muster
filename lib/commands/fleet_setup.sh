#!/usr/bin/env bash
# muster/lib/commands/fleet_setup.sh — Fleet setup wizard
# Creates fleet directory structure at ~/.muster/fleets/<name>/

source "$MUSTER_ROOT/lib/tui/checklist.sh"
source "$MUSTER_ROOT/lib/core/templates.sh"

# ── Visual helpers ──

_FLEET_SETUP_STEP=1
_FLEET_SETUP_TOTAL=5

_fleet_setup_bar() {
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

_fleet_setup_screen() {
  local step="$1" label="$2"
  _FLEET_SETUP_STEP="$step"
  clear
  echo ""
  _fleet_setup_bar "muster  fleet setup" "step ${step}/${_FLEET_SETUP_TOTAL}  "

  local bar_w=$(( TERM_COLS - 6 ))
  (( bar_w < 10 )) && bar_w=10
  (( bar_w > 50 )) && bar_w=50
  local filled=$(( step * bar_w / _FLEET_SETUP_TOTAL ))
  local empty=$(( bar_w - filled ))
  local bar_filled="" bar_empty=""
  local _bi=0
  while (( _bi < filled )); do bar_filled="${bar_filled}#"; _bi=$((_bi + 1)); done
  _bi=0
  while (( _bi < empty )); do bar_empty="${bar_empty}-"; _bi=$((_bi + 1)); done
  printf '  \033[38;5;178m%s\033[2m%s\033[0m\n' "$bar_filled" "$bar_empty"

  echo ""
  printf '%b\n' "  ${BOLD}${label}${RESET}"
  echo ""
}

# ── SSH config scanner ──
# Parses ~/.ssh/config and outputs: alias|hostname|user|key|port
_fleet_setup_scan_ssh_config() {
  local config_file="$HOME/.ssh/config"
  [[ ! -f "$config_file" ]] && return

  local _cur_host="" _cur_hostname="" _cur_user="" _cur_key="" _cur_port="22"

  while IFS= read -r _line; do
    # Trim whitespace
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [[ -z "$_line" || "$_line" == "#"* ]] && continue

    local _key="${_line%% *}"
    local _val="${_line#* }"
    _val="${_val#"${_val%%[![:space:]]*}"}"

    case "$_key" in
      Host|host)
        # Emit previous entry
        if [[ -n "$_cur_host" && "$_cur_host" != "*" && -n "$_cur_hostname" ]]; then
          echo "${_cur_host}|${_cur_hostname}|${_cur_user}|${_cur_key}|${_cur_port}"
        fi
        _cur_host="$_val"
        # Skip wildcard and multi-host entries
        case "$_cur_host" in *"*"*|*" "*) _cur_host="" ;; esac
        _cur_hostname="" _cur_user="" _cur_key="" _cur_port="22"
        ;;
      HostName|Hostname|hostname) _cur_hostname="$_val" ;;
      User|user)                  _cur_user="$_val" ;;
      IdentityFile|identityfile)  _cur_key="$_val" ;;
      Port|port)                  _cur_port="$_val" ;;
    esac
  done < "$config_file"

  # Emit last entry
  if [[ -n "$_cur_host" && "$_cur_host" != "*" && -n "$_cur_hostname" ]]; then
    echo "${_cur_host}|${_cur_hostname}|${_cur_user}|${_cur_key}|${_cur_port}"
  fi
}

# ── Remote auto-detection ──
# SSHes into a machine and detects stack, project paths, muster presence
# Sets: _DETECT_MUSTER, _DETECT_STACK, _DETECT_PATHS[], _DETECT_SERVICES
_fleet_setup_detect_remote() {
  local machine="$1"

  _DETECT_MUSTER="no"
  _DETECT_STACK=""
  _DETECT_PATHS=()
  _DETECT_SERVICES=""

  local _detect_output
  _detect_output=$(fleet_exec "$machine" '
    # Check tools
    printf "MUSTER=%s\n" "$(command -v muster >/dev/null 2>&1 && echo yes || echo no)"
    printf "DOCKER=%s\n" "$(command -v docker >/dev/null 2>&1 && echo yes || echo no)"
    printf "K8S=%s\n" "$(command -v kubectl >/dev/null 2>&1 && echo yes || echo no)"
    printf "COMPOSE=%s\n" "$(docker compose version >/dev/null 2>&1 && echo yes || echo no)"
    # Find project dirs
    for d in $HOME/*/; do
      [ ! -d "$d" ] && continue
      [ -f "${d}deploy.json" ] && printf "MUSTER_PROJECT=%s\n" "${d%/}"
      [ -f "${d}docker-compose.yml" ] && printf "COMPOSE_DIR=%s\n" "${d%/}"
      [ -f "${d}docker-compose.yaml" ] && printf "COMPOSE_DIR=%s\n" "${d%/}"
    done
    # Check common paths
    for p in /opt /srv /var/www; do
      [ ! -d "$p" ] && continue
      for d in "$p"/*/; do
        [ ! -d "$d" ] && continue
        [ -f "${d}deploy.json" ] && printf "MUSTER_PROJECT=%s\n" "${d%/}"
        [ -f "${d}docker-compose.yml" ] && printf "COMPOSE_DIR=%s\n" "${d%/}"
        [ -f "${d}docker-compose.yaml" ] && printf "COMPOSE_DIR=%s\n" "${d%/}"
      done
    done
  ' 2>/dev/null) || return 1

  while IFS= read -r _dl; do
    [[ -z "$_dl" ]] && continue
    case "$_dl" in
      MUSTER=yes)  _DETECT_MUSTER="yes" ;;
      COMPOSE=yes) [[ -z "$_DETECT_STACK" ]] && _DETECT_STACK="compose" ;;
      K8S=yes)     _DETECT_STACK="k8s" ;;
      DOCKER=yes)  [[ -z "$_DETECT_STACK" ]] && _DETECT_STACK="docker" ;;
      MUSTER_PROJECT=*) _DETECT_PATHS[${#_DETECT_PATHS[@]}]="${_dl#MUSTER_PROJECT=}" ;;
      COMPOSE_DIR=*)    _DETECT_PATHS[${#_DETECT_PATHS[@]}]="${_dl#COMPOSE_DIR=}" ;;
    esac
  done <<< "$_detect_output"

  [[ -z "$_DETECT_STACK" ]] && _DETECT_STACK="bare"
  return 0
}

# ── Main entry ──

cmd_fleet_setup() {
  if [[ ! -t 0 ]]; then
    err "Fleet setup requires a terminal (TTY)."
    echo "  Use 'muster fleet add' for non-interactive machine setup."
    return 1
  fi

  source "$MUSTER_ROOT/lib/core/fleet_config.sh"
  fleets_ensure_dir

  local _fleet_name=""
  local _machines=()
  local _machine_hosts=()
  local _machine_users=()
  local _machine_keys=()
  local _machine_ports=()
  local _machine_hook_modes=()
  local _strategy="sequential"
  local _is_existing_fleet=false

  # ═══════════════════════════════════════════
  # Step 1: Fleet Selection
  # ═══════════════════════════════════════════
  _FLEET_SETUP_TOTAL=5
  _fleet_setup_screen 1 "Select fleet"

  # Check for existing fleets
  local _existing_fleets=()
  while IFS= read -r _ef; do
    [[ -n "$_ef" ]] && _existing_fleets[${#_existing_fleets[@]}]="$_ef"
  done < <(fleets_list 2>/dev/null)

  if (( ${#_existing_fleets[@]} > 0 )); then
    printf '%b\n' "  ${DIM}Add machines to an existing fleet, or create a new one.${RESET}"
    echo ""

    # Build menu with fleet info
    local _fleet_opts=()
    local _fi=0
    while (( _fi < ${#_existing_fleets[@]} )); do
      local _ef_name="${_existing_fleets[$_fi]}"
      local _ef_count=0
      # Count machines in this fleet
      local _ef_grp _ef_proj
      for _ef_grp in $(fleet_cfg_groups "$_ef_name" 2>/dev/null); do
        for _ef_proj in $(fleet_cfg_group_projects "$_ef_name" "$_ef_grp" 2>/dev/null); do
          _ef_count=$(( _ef_count + 1 ))
        done
      done
      local _ef_label="${_ef_name}  ${DIM}(${_ef_count} machine"
      (( _ef_count != 1 )) && _ef_label="${_ef_label}s"
      _ef_label="${_ef_label})${RESET}"
      _fleet_opts[${#_fleet_opts[@]}]="$_ef_name"
      _fi=$(( _fi + 1 ))
    done
    _fleet_opts[${#_fleet_opts[@]}]="Create new fleet"

    menu_select "Fleet" "${_fleet_opts[@]}"

    if [[ "$MENU_RESULT" == "Create new fleet" ]]; then
      echo ""
      printf '  %b>%b Fleet name %b(production)%b: ' "${ACCENT}" "${RESET}" "${DIM}" "${RESET}"
      IFS= read -r _fleet_name
      [[ -z "$_fleet_name" ]] && _fleet_name="production"
    elif [[ "$MENU_RESULT" == "__back__" ]]; then
      return 0
    else
      _fleet_name="$MENU_RESULT"
      _is_existing_fleet=true
    fi
  else
    printf '%b\n' "  ${DIM}A fleet deploys your project across multiple machines.${RESET}"
    printf '%b\n' "  ${DIM}Name it after your environment.${RESET}"
    echo ""
    printf '  %b>%b Fleet name %b(production)%b: ' "${ACCENT}" "${RESET}" "${DIM}" "${RESET}"
    IFS= read -r _fleet_name
    [[ -z "$_fleet_name" ]] && _fleet_name="production"
  fi

  # Sanitize
  _fleet_name=$(printf '%s' "$_fleet_name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')

  # Create fleet + default group if new
  if [[ "$_is_existing_fleet" == "false" ]]; then
    if [[ -f "$(fleet_dir "$_fleet_name")/fleet.json" ]]; then
      _is_existing_fleet=true
    else
      fleet_cfg_create "$_fleet_name" "$_fleet_name" "sequential"
      fleet_cfg_group_create "$_fleet_name" "default" "default"
    fi
  fi

  # ═══════════════════════════════════════════
  # Step 2: Add Machines
  # ═══════════════════════════════════════════
  while true; do
    local _machine_count=$(( ${#_machines[@]} + 1 ))
    _fleet_setup_screen 2 "Add machines"

    # Show machines already in this fleet
    if [[ "$_is_existing_fleet" == "true" ]]; then
      local _existing_count=0
      local _ex_grp _ex_proj
      for _ex_grp in $(fleet_cfg_groups "$_fleet_name" 2>/dev/null); do
        for _ex_proj in $(fleet_cfg_group_projects "$_fleet_name" "$_ex_grp" 2>/dev/null); do
          if (( _existing_count == 0 )); then
            printf '%b\n' "  ${DIM}Already in fleet:${RESET}"
          fi
          fleet_cfg_project_load "$_fleet_name" "$_ex_grp" "$_ex_proj"
          printf '%b\n' "    ${GREEN}*${RESET} ${_ex_proj}  ${DIM}${_FP_USER}@${_FP_HOST}${RESET}"
          _existing_count=$(( _existing_count + 1 ))
        done
      done
      (( _existing_count > 0 )) && echo ""
    fi

    # Show machines added this session
    if (( ${#_machines[@]} > 0 )); then
      printf '%b\n' "  ${DIM}Added this session:${RESET}"
      local _mi=0
      while (( _mi < ${#_machines[@]} )); do
        printf '%b\n' "    ${GREEN}*${RESET} ${_machines[$_mi]}  ${DIM}${_machine_users[$_mi]}@${_machine_hosts[$_mi]}${RESET}"
        _mi=$((_mi + 1))
      done
      echo ""
    fi

    # Scan SSH config for importable hosts
    local _ssh_hosts=()
    local _ssh_hostnames=()
    local _ssh_users=()
    local _ssh_keys_found=()
    local _ssh_ports_found=()
    local _ssh_count=0

    while IFS='|' read -r _sh_alias _sh_hostname _sh_user _sh_key _sh_port; do
      [[ -z "$_sh_alias" ]] && continue
      # Skip if already in fleet or already added this session
      local _already=false
      local _mi=0
      while (( _mi < ${#_machines[@]} )); do
        [[ "${_machines[$_mi]}" == "$_sh_alias" ]] && _already=true
        _mi=$((_mi + 1))
      done
      # Check existing fleet projects
      if fleet_cfg_find_project "$_sh_alias" 2>/dev/null; then
        _already=true
      fi
      [[ "$_already" == "true" ]] && continue

      _ssh_hosts[${#_ssh_hosts[@]}]="$_sh_alias"
      _ssh_hostnames[${#_ssh_hostnames[@]}]="$_sh_hostname"
      _ssh_users[${#_ssh_users[@]}]="$_sh_user"
      _ssh_keys_found[${#_ssh_keys_found[@]}]="$_sh_key"
      _ssh_ports_found[${#_ssh_ports_found[@]}]="$_sh_port"
      _ssh_count=$(( _ssh_count + 1 ))
    done < <(_fleet_setup_scan_ssh_config)

    # Offer import from SSH config
    if (( _ssh_count > 0 )); then
      local _import_labels=()
      local _si=0
      while (( _si < _ssh_count )); do
        local _il="${_ssh_hosts[$_si]}"
        if [[ -n "${_ssh_users[$_si]}" ]]; then
          _il="${_il}  ${_ssh_users[$_si]}@${_ssh_hostnames[$_si]}"
        else
          _il="${_il}  ${_ssh_hostnames[$_si]}"
        fi
        _import_labels[${#_import_labels[@]}]="$_il"
        _si=$((_si + 1))
      done

      menu_select "How to add?" "Import from SSH config" "Enter manually" "Done adding"

      case "$MENU_RESULT" in
        "Import from SSH config")
          echo ""
          checklist_select --none "Select hosts" "${_import_labels[@]}"

          while IFS= read -r _selected; do
            [[ -z "$_selected" ]] && continue
            # Find the matching SSH config entry
            local _match_alias="${_selected%%  *}"
            local _si=0
            while (( _si < _ssh_count )); do
              if [[ "${_ssh_hosts[$_si]}" == "$_match_alias" ]]; then
                local _im_name="${_ssh_hosts[$_si]}"
                local _im_host="${_ssh_hostnames[$_si]}"
                local _im_user="${_ssh_users[$_si]}"
                local _im_key="${_ssh_keys_found[$_si]}"
                local _im_port="${_ssh_ports_found[$_si]}"
                [[ -z "$_im_user" ]] && _im_user="deploy"
                [[ -z "$_im_port" ]] && _im_port="22"

                # Test connection
                echo ""
                start_spinner "Testing ${_im_user}@${_im_host}..."
                local _ssh_ok=false
                local _sopts="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
                [[ -n "$_im_key" ]] && _sopts="${_sopts} -i ${_im_key/#\~/$HOME}"
                [[ "$_im_port" != "22" ]] && _sopts="${_sopts} -p ${_im_port}"
                # shellcheck disable=SC2086
                if ssh $_sopts "${_im_user}@${_im_host}" "echo ok" &>/dev/null; then
                  _ssh_ok=true
                fi
                stop_spinner

                if [[ "$_ssh_ok" == "true" ]]; then
                  printf '%b\n' "  ${GREEN}*${RESET} ${_im_name}  ${_im_user}@${_im_host}"
                else
                  printf '%b\n' "  ${YELLOW}!${RESET} ${_im_name}  ${_im_user}@${_im_host}  ${DIM}(unreachable)${RESET}"
                fi

                # Create project
                local _proj_json
                _proj_json=$(jq -n \
                  --arg n "$_im_name" \
                  --arg host "$_im_host" \
                  --arg user "$_im_user" \
                  --arg key "$_im_key" \
                  --argjson port "$_im_port" \
                  '{name: $n, machine: ({host: $host, user: $user, port: $port, transport: "ssh"} +
                    (if $key != "" then {identity_file: $key} else {} end)),
                    hook_mode: "manual"}')

                fleet_cfg_project_create "$_fleet_name" "default" "$_im_name" "$_proj_json" 2>/dev/null || true

                _machines[${#_machines[@]}]="$_im_name"
                _machine_hosts[${#_machine_hosts[@]}]="$_im_host"
                _machine_users[${#_machine_users[@]}]="$_im_user"
                _machine_keys[${#_machine_keys[@]}]="$_im_key"
                _machine_ports[${#_machine_ports[@]}]="$_im_port"
                _machine_hook_modes[${#_machine_hook_modes[@]}]="manual"
                break
              fi
              _si=$((_si + 1))
            done
          done <<< "$CHECKLIST_RESULT"

          continue
          ;;
        "Done adding")
          if (( ${#_machines[@]} == 0 )); then
            # Check if existing fleet has machines
            if [[ "$_is_existing_fleet" == "true" ]]; then
              break
            fi
            warn "At least one machine is required."
            sleep 1
            continue
          fi
          break
          ;;
        "__back__")
          if (( ${#_machines[@]} > 0 )); then
            break
          fi
          continue
          ;;
      esac
      # Fall through to manual entry
    else
      # No SSH config hosts — check if we have enough machines or need more
      if (( ${#_machines[@]} > 0 )); then
        menu_select "Add another?" "Add machine" "Continue"
        if [[ "$MENU_RESULT" == "Continue" || "$MENU_RESULT" == "__back__" ]]; then
          break
        fi
      fi
    fi

    # ── Manual entry ──
    printf '%b\n' "  ${DIM}Machine ${_machine_count}:${RESET}"
    echo ""

    printf '  %b>%b Name: ' "${ACCENT}" "${RESET}"
    local _m_name=""
    IFS= read -r _m_name
    if [[ -z "$_m_name" ]]; then
      if (( ${#_machines[@]} == 0 && _is_existing_fleet == false )); then
        warn "At least one machine is required."
        sleep 1
        continue
      fi
      break
    fi

    printf '  %b>%b Host %b(user@ip)%b: ' "${ACCENT}" "${RESET}" "${DIM}" "${RESET}"
    local _m_host=""
    IFS= read -r _m_host
    if [[ -z "$_m_host" || "$_m_host" != *"@"* ]]; then
      warn "Expected user@hostname format"
      sleep 1
      continue
    fi

    local _m_user="${_m_host%%@*}"
    local _m_hostname="${_m_host#*@}"

    # Port
    local _m_port="22"
    printf '  %b>%b Port %b(22)%b: ' "${ACCENT}" "${RESET}" "${DIM}" "${RESET}"
    local _m_port_in=""
    IFS= read -r _m_port_in
    [[ -n "$_m_port_in" ]] && _m_port="$_m_port_in"

    # SSH key — auto-detect
    local _ssh_keys=()
    local _kf
    for _kf in "$HOME"/.ssh/id_ed25519 "$HOME"/.ssh/id_rsa "$HOME"/.ssh/deploy-key "$HOME"/.ssh/deploy; do
      [[ -f "$_kf" ]] && _ssh_keys[${#_ssh_keys[@]}]="$_kf"
    done

    local _m_key=""
    if (( ${#_ssh_keys[@]} > 0 )); then
      echo ""
      local _key_opts=()
      local _ki=0
      while (( _ki < ${#_ssh_keys[@]} )); do
        _key_opts[${#_key_opts[@]}]="${_ssh_keys[$_ki]}"
        _ki=$((_ki + 1))
      done
      _key_opts[${#_key_opts[@]}]="Other"
      _key_opts[${#_key_opts[@]}]="None (SSH agent)"

      menu_select "SSH key" "${_key_opts[@]}"
      case "$MENU_RESULT" in
        "None (SSH agent)") _m_key="" ;;
        "Other")
          printf '  %b>%b Key path: ' "${ACCENT}" "${RESET}"
          IFS= read -r _m_key
          ;;
        *) _m_key="$MENU_RESULT" ;;
      esac
    fi

    # Test connection
    echo ""
    start_spinner "Connecting to ${_m_user}@${_m_hostname}..."
    local _ssh_ok=false
    local _ssh_opts="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    [[ -n "$_m_key" ]] && _ssh_opts="${_ssh_opts} -i ${_m_key}"
    [[ "$_m_port" != "22" ]] && _ssh_opts="${_ssh_opts} -p ${_m_port}"
    # shellcheck disable=SC2086
    if ssh $_ssh_opts "${_m_user}@${_m_hostname}" "echo ok" &>/dev/null; then
      _ssh_ok=true
    fi
    stop_spinner

    if [[ "$_ssh_ok" == "true" ]]; then
      printf '%b\n' "  ${GREEN}*${RESET} Connected to ${_m_user}@${_m_hostname}"
    else
      printf '%b\n' "  ${RED}x${RESET} Cannot reach ${_m_user}@${_m_hostname}"
      printf '%b\n' "  ${DIM}Machine will be added — fix connectivity later.${RESET}"
    fi

    # Create project
    local _proj_json
    _proj_json=$(jq -n \
      --arg n "$_m_name" \
      --arg host "$_m_hostname" \
      --arg user "$_m_user" \
      --arg key "$_m_key" \
      --argjson port "$_m_port" \
      '{name: $n, machine: ({host: $host, user: $user, port: $port, transport: "ssh"} +
        (if $key != "" then {identity_file: $key} else {} end)),
        hook_mode: "manual"}')

    fleet_cfg_project_create "$_fleet_name" "default" "$_m_name" "$_proj_json" 2>/dev/null || true

    _machines[${#_machines[@]}]="$_m_name"
    _machine_hosts[${#_machine_hosts[@]}]="$_m_hostname"
    _machine_users[${#_machine_users[@]}]="$_m_user"
    _machine_keys[${#_machine_keys[@]}]="$_m_key"
    _machine_ports[${#_machine_ports[@]}]="$_m_port"
    _machine_hook_modes[${#_machine_hook_modes[@]}]="manual"

    echo ""
    menu_select "Add another?" "Add another machine" "Continue"
    [[ "$MENU_RESULT" == "Continue" || "$MENU_RESULT" == "__back__" ]] && break
  done

  # If no new machines added to existing fleet, we're done with add step
  if (( ${#_machines[@]} == 0 )) && [[ "$_is_existing_fleet" == "false" ]]; then
    warn "No machines added."
    return 1
  fi

  # ═══════════════════════════════════════════
  # Step 3: Configure Each Machine
  # ═══════════════════════════════════════════
  local _mi=0
  while (( _mi < ${#_machines[@]} )); do
    local _mname="${_machines[$_mi]}"
    local _mhost="${_machine_hosts[$_mi]}"
    local _muser="${_machine_users[$_mi]}"
    _fleet_setup_screen 3 "Configure ${_mname}"

    # Auto-detect what's on the remote
    local _detected=false
    printf '%b\n' "  ${DIM}Scanning ${_mname}...${RESET}"
    echo ""

    start_spinner "Detecting remote environment..."

    # Need to load machine config for fleet_exec to work
    _fleet_load_machine "$_mname" 2>/dev/null || true

    if _fleet_setup_detect_remote "$_mname" 2>/dev/null; then
      _detected=true
    fi
    stop_spinner

    if [[ "$_detected" == "true" ]]; then
      # Show detection results
      printf '%b\n' "  ${GREEN}*${RESET} SSH connected"

      if [[ "$_DETECT_MUSTER" == "yes" ]]; then
        printf '%b\n' "  ${GREEN}*${RESET} Muster installed on remote"
      fi

      case "$_DETECT_STACK" in
        compose) printf '%b\n' "  ${GREEN}*${RESET} Docker Compose detected" ;;
        k8s)     printf '%b\n' "  ${GREEN}*${RESET} Kubernetes detected" ;;
        docker)  printf '%b\n' "  ${GREEN}*${RESET} Docker detected" ;;
        bare)    printf '%b\n' "  ${DIM}  No container runtime detected${RESET}" ;;
      esac

      if (( ${#_DETECT_PATHS[@]} > 0 )); then
        local _pi=0
        while (( _pi < ${#_DETECT_PATHS[@]} )); do
          printf '%b\n' "  ${GREEN}*${RESET} Found project at ${DIM}${_DETECT_PATHS[$_pi]}${RESET}"
          _pi=$((_pi + 1))
        done
      fi
      echo ""
    else
      printf '%b\n' "  ${YELLOW}!${RESET} Could not scan remote ${DIM}(SSH failed or timed out)${RESET}"
      echo ""
    fi

    # Recommend hook mode based on detection
    local _recommended_mode="sync"
    local _rec_label="Sync"
    local _rec_desc="Muster creates deploy scripts locally and pushes them to the remote."
    local _alt_label="Manual"
    local _alt_desc="The remote has muster set up with its own hooks."

    if [[ "$_DETECT_MUSTER" == "yes" ]]; then
      _recommended_mode="manual"
      _rec_label="Manual"
      _rec_desc="Muster is already on the remote — trigger 'muster deploy' remotely."
      _alt_label="Sync"
      _alt_desc="Override: create deploy scripts locally and push them to the remote."
    fi

    menu_select_desc "Hook management" \
      "${_rec_label} (recommended)" \
      "$_rec_desc" \
      "$_alt_label" \
      "$_alt_desc"

    local _chosen_mode="$_recommended_mode"
    case "$MENU_RESULT" in
      *"Sync"*) _chosen_mode="sync" ;;
      *"Manual"*) _chosen_mode="manual" ;;
    esac

    _machine_hook_modes[$_mi]="$_chosen_mode"

    case "$_chosen_mode" in
      sync)
        # ── Sync mode: configure services + hooks ──
        echo ""
        printf '%b\n' "  ${DIM}What services does ${_mname} run?${RESET}"
        echo ""
        checklist_select --none "Services" \
          "Web app / API" \
          "Background workers" \
          "Database" \
          "Cache (Redis)" \
          "Reverse proxy"

        local _remote_components=()
        while IFS= read -r _rc; do
          [[ -n "$_rc" ]] && _remote_components[${#_remote_components[@]}]="$_rc"
        done <<< "$CHECKLIST_RESULT"

        # Stack — pre-select from detection
        echo ""
        local _stack_default="Docker Compose"
        case "$_DETECT_STACK" in
          k8s)     _stack_default="Kubernetes" ;;
          docker)  _stack_default="Docker" ;;
          bare)    _stack_default="Bare metal" ;;
        esac

        # Build stack list with detected option first (no duplicates)
        local _stack_opts=()
        _stack_opts[0]="$_stack_default"
        local _so
        for _so in "Docker Compose" "Docker" "Kubernetes" "Bare metal"; do
          [[ "$_so" != "$_stack_default" ]] && _stack_opts[${#_stack_opts[@]}]="$_so"
        done

        menu_select "Stack on ${_mname}?" "${_stack_opts[@]}"
        local _remote_stack="compose"
        case "$MENU_RESULT" in
          "Docker Compose") _remote_stack="compose" ;;
          "Docker")         _remote_stack="docker" ;;
          "Kubernetes")     _remote_stack="k8s" ;;
          "Bare metal")     _remote_stack="bare" ;;
        esac

        # Generate hooks
        local _hooks_base
        _hooks_base="$(fleet_cfg_project_hooks_dir "$_fleet_name" "default" "$_mname")"
        mkdir -p "$_hooks_base"

        local _svc_names=()
        local _ci=0
        while (( _ci < ${#_remote_components[@]} )); do
          local _comp="${_remote_components[$_ci]}"
          local _svc_name=""
          case "$_comp" in
            *"Web app"*|*"API"*)  _svc_name="api" ;;
            *"workers"*)          _svc_name="worker" ;;
            *"Database"*)         _svc_name="database" ;;
            *"Cache"*|*"Redis"*)  _svc_name="redis" ;;
            *"Reverse proxy"*)    _svc_name="proxy" ;;
          esac
          if [[ -n "$_svc_name" ]]; then
            local _svc_hook_dir="${_hooks_base}/${_svc_name}"
            mkdir -p "$_svc_hook_dir"
            _setup_copy_hooks "$_remote_stack" "$_svc_name" "$_svc_name" "$_svc_hook_dir" \
              "docker-compose.yml" "Dockerfile" "k8s/${_svc_name}/" "default" "8080" "$_svc_name" ""
            _svc_names[${#_svc_names[@]}]="$_svc_name"
          fi
          _ci=$((_ci + 1))
        done

        echo ""
        if (( ${#_svc_names[@]} > 0 )); then
          printf '%b\n' "  ${GREEN}*${RESET} Generated hooks:"
          local _gi=0
          while (( _gi < ${#_svc_names[@]} )); do
            printf '%b\n' "    ${DIM}${_svc_names[$_gi]}/${RESET}"
            _gi=$((_gi + 1))
          done
          echo ""
          printf '%b\n' "  ${DIM}Edit anytime at ~/.muster/fleets/${_fleet_name}/default/${_mname}/hooks/${RESET}"
        fi

        # Remote project path for sync target
        local _sync_path=""
        if (( ${#_DETECT_PATHS[@]} > 0 )); then
          _sync_path="${_DETECT_PATHS[0]}"
        fi
        echo ""
        printf '  %b>%b Remote project path %b(%s)%b: ' "${ACCENT}" "${RESET}" "${DIM}" "${_sync_path:-~/myapp}" "${RESET}"
        local _path_in=""
        IFS= read -r _path_in
        [[ -n "$_path_in" ]] && _sync_path="$_path_in"
        [[ -z "$_sync_path" ]] && _sync_path="~/myapp"

        # Update project.json
        fleet_cfg_project_update "$_fleet_name" "default" "$_mname" \
          ".hook_mode = \"sync\" | .stack = \"${_remote_stack}\" | .remote_path = \"${_sync_path}\"" 2>/dev/null || true

        if (( ${#_svc_names[@]} > 0 )); then
          local _svcs_json="[]"
          local _si=0
          while (( _si < ${#_svc_names[@]} )); do
            _svcs_json=$(printf '%s' "$_svcs_json" | jq --arg s "${_svc_names[$_si]}" '. + [$s]')
            _si=$((_si + 1))
          done
          fleet_cfg_project_update "$_fleet_name" "default" "$_mname" \
            ".services = ${_svcs_json} | .deploy_order = ${_svcs_json}" 2>/dev/null || true
        fi
        ;;

      manual)
        # ── Manual mode ──
        echo ""
        local _manual_path=""
        if (( ${#_DETECT_PATHS[@]} > 0 )); then
          _manual_path="${_DETECT_PATHS[0]}"
        fi
        printf '  %b>%b Remote project path %b(%s)%b: ' "${ACCENT}" "${RESET}" "${DIM}" "${_manual_path:-~/myapp}" "${RESET}"
        local _path_in=""
        IFS= read -r _path_in
        [[ -n "$_path_in" ]] && _manual_path="$_path_in"
        [[ -z "$_manual_path" ]] && _manual_path="~/myapp"

        fleet_cfg_project_update "$_fleet_name" "default" "$_mname" \
          ".hook_mode = \"manual\" | .remote_path = \"${_manual_path}\"" 2>/dev/null || true
        ;;
    esac

    _mi=$((_mi + 1))
  done

  # ═══════════════════════════════════════════
  # Step 4: Deploy Strategy
  # ═══════════════════════════════════════════
  _fleet_setup_screen 4 "Deploy strategy"

  # Count total machines (existing + new)
  local _total_machines=0
  local _tm_grp _tm_proj
  for _tm_grp in $(fleet_cfg_groups "$_fleet_name" 2>/dev/null); do
    for _tm_proj in $(fleet_cfg_group_projects "$_fleet_name" "$_tm_grp" 2>/dev/null); do
      _total_machines=$(( _total_machines + 1 ))
    done
  done

  if (( _total_machines <= 1 )); then
    printf '%b\n' "  ${DIM}Single machine — sequential deploy.${RESET}"
    _strategy="sequential"
    fleet_cfg_update "$_fleet_name" ".deploy_strategy = \"sequential\"" 2>/dev/null || true
    echo ""
    printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
    IFS= read -rsn1 || true
  else
    printf '%b\n' "  ${DIM}How should deploys run across ${_total_machines} machines?${RESET}"
    echo ""

    menu_select_desc "Strategy" \
      "Sequential (recommended)" \
      "Deploy one machine at a time. If something fails, you can fix it before it reaches the next machine." \
      "Parallel" \
      "Deploy all machines at once. Fastest, but failures hit everything. Good for staging." \
      "Rolling" \
      "Deploy one, verify it's healthy, then continue. Catches bad deploys early."

    case "$MENU_RESULT" in
      *"Parallel"*) _strategy="parallel" ;;
      *"Rolling"*)  _strategy="rolling" ;;
      *)            _strategy="sequential" ;;
    esac

    fleet_cfg_update "$_fleet_name" ".deploy_strategy = \"${_strategy}\"" 2>/dev/null || true
  fi

  # ═══════════════════════════════════════════
  # Step 5: Summary
  # ═══════════════════════════════════════════
  _fleet_setup_screen 5 "Fleet ready"

  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local inner=$(( w - 2 ))

  # Fleet header box
  local label="${_fleet_name}"
  local label_pad_len=$(( w - ${#label} - 3 ))
  (( label_pad_len < 1 )) && label_pad_len=1
  local label_pad
  printf -v label_pad '%*s' "$label_pad_len" ""
  label_pad="${label_pad// /─}"
  printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$label" "${RESET}${ACCENT}" "$label_pad" "${RESET}"

  # Show ALL machines in fleet (existing + new)
  for _tm_grp in $(fleet_cfg_groups "$_fleet_name" 2>/dev/null); do
    for _tm_proj in $(fleet_cfg_group_projects "$_fleet_name" "$_tm_grp" 2>/dev/null); do
      fleet_cfg_project_load "$_fleet_name" "$_tm_grp" "$_tm_proj"

      local _hm_tag=""
      case "$_FP_HOOK_MODE" in
        sync)   _hm_tag=" sync" ;;
        manual) _hm_tag=" manual" ;;
      esac

      local display="${_tm_proj}: ${_FP_USER}@${_FP_HOST}"
      local tag_len=${#_hm_tag}
      local max_display=$(( inner - 4 - tag_len ))
      (( max_display < 5 )) && max_display=5
      if (( ${#display} > max_display )); then
        display="${display:0:$((max_display - 3))}..."
      fi

      local content_len=$(( 4 + ${#display} + tag_len ))
      local pad_len=$(( inner - content_len ))
      (( pad_len < 0 )) && pad_len=0
      local pad
      printf -v pad '%*s' "$pad_len" ""

      printf '  %b│%b  %b*%b %s%s%b%s%b%b│%b\n' \
        "${ACCENT}" "${RESET}" "${GREEN}" "${RESET}" \
        "$display" "$pad" "${DIM}" "$_hm_tag" "${RESET}" "${ACCENT}" "${RESET}"
    done
  done

  local bottom
  printf -v bottom '%*s' "$w" ""
  bottom="${bottom// /─}"
  printf '  %b└%s┘%b\n' "${ACCENT}" "$bottom" "${RESET}"

  echo ""
  printf '%b\n' "  ${DIM}Strategy:${RESET} ${_strategy}"
  printf '%b\n' "  ${DIM}Config:${RESET}   ~/.muster/fleets/${_fleet_name}/"
  echo ""

  printf '%b\n' "  ${ACCENT}Next steps:${RESET}"
  printf '%b\n' "    ${BOLD}muster fleet deploy${RESET}    Deploy to all machines"
  printf '%b\n' "    ${BOLD}muster fleet status${RESET}    Check health across fleet"
  printf '%b\n' "    ${BOLD}muster fleet sync${RESET}      Push hooks to remotes"
  printf '%b\n' "    ${BOLD}muster fleet${RESET}           Interactive fleet manager"
  echo ""

  menu_select "Run a test deploy?" "Dry run" "Done"

  if [[ "$MENU_RESULT" == "Dry run" ]]; then
    echo ""
    FLEET_CONFIG_FILE="__fleet_dirs__"
    _fleet_cmd_deploy --dry-run
  fi

  return 0
}
