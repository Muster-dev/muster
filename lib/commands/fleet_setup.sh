#!/usr/bin/env bash
# muster/lib/commands/fleet_setup.sh — Fleet setup wizard
# Creates fleet directory structure at ~/.muster/fleets/<name>/

source "$MUSTER_ROOT/lib/tui/checklist.sh"
source "$MUSTER_ROOT/lib/core/templates.sh"

# ── Rally phrases ──

_fleet_phrases=(
  "Mustering the troops"
  "Assembling the fleet"
  "Rally your machines. It's deploy time."
  "Reporting for duty"
  "All hands on deck"
  "From chaos to formation in one setup"
  "Your servers called. They want orders."
  "Deploying confidence across the wire"
  "One fleet to rule them all"
  "Spreading mustard across the fleet"
  "No machine left behind"
  "Fleet command, standing by"
  "Battle stations, everyone"
)

_fleet_pick_phrase() {
  local count=${#_fleet_phrases[@]}
  local idx=$(( RANDOM % count ))
  echo "${_fleet_phrases[$idx]}"
}

# ── Visual helpers ──

_FLEET_SETUP_STEP=1
_FLEET_SETUP_TOTAL=6
_FLEET_SETUP_PHRASE=""
_FLEET_SETUP_LABEL=""

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

_fleet_setup_screen_inner() {
  muster_tui_fullscreen
  clear
  update_term_size

  local step="$_FLEET_SETUP_STEP"

  # Branded header bar
  echo ""
  _fleet_setup_bar "muster  fleet setup" "step ${step}/${_FLEET_SETUP_TOTAL}  "

  # Progress bar (matches setup.sh style: ACCENT_BRIGHT filled, GRAY empty)
  local bar_w=$(( TERM_COLS - 6 ))
  (( bar_w > 50 )) && bar_w=50
  (( bar_w < 10 )) && bar_w=10
  local filled=$(( step * bar_w / _FLEET_SETUP_TOTAL ))
  local empty_count=$(( bar_w - filled ))
  local bar_filled="" bar_empty=""
  local _bi=0
  while (( _bi < filled )); do bar_filled="${bar_filled}#"; _bi=$((_bi + 1)); done
  _bi=0
  while (( _bi < empty_count )); do bar_empty="${bar_empty}-"; _bi=$((_bi + 1)); done
  printf '  %b%s%b%s%b\n' "${ACCENT_BRIGHT}" "$bar_filled" "${GRAY}" "$bar_empty" "${RESET}"

  # Phrase subtitle
  if [[ -n "$_FLEET_SETUP_PHRASE" ]]; then
    printf '  %b%s%b\n' "${DIM}" "$_FLEET_SETUP_PHRASE" "${RESET}"
  fi

  # Step label
  if [[ -n "$_FLEET_SETUP_LABEL" ]]; then
    echo ""
    printf '%b\n' "  ${BOLD}${_FLEET_SETUP_LABEL}${RESET}"
  fi
}

_fleet_setup_redraw() {
  _fleet_setup_screen_inner
}

_fleet_setup_screen() {
  local step="$1" label="$2"
  _FLEET_SETUP_STEP="$step"
  _FLEET_SETUP_LABEL="$label"
  if [[ -z "$_FLEET_SETUP_PHRASE" ]]; then
    _FLEET_SETUP_PHRASE=$(_fleet_pick_phrase)
  fi
  # shellcheck disable=SC2034
  MUSTER_REDRAW_FN="_fleet_setup_redraw"
  _fleet_setup_screen_inner
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

# ── Boxed display helpers ──

_fleet_box_top() {
  local label="$1"
  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local label_pad_len=$(( w - ${#label} - 3 ))
  (( label_pad_len < 1 )) && label_pad_len=1
  local label_pad
  printf -v label_pad '%*s' "$label_pad_len" ""
  label_pad="${label_pad// /-}"
  printf '  %b+-%b%s%b-%s+%b\n' "${ACCENT}" "${BOLD}" "$label" "${RESET}${ACCENT}" "$label_pad" "${RESET}"
}

_fleet_box_row() {
  local icon_color="$1" icon="$2" text="$3" tag="${4:-}"
  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local inner=$(( w - 2 ))

  local tag_len=${#tag}
  local max_text=$(( inner - 4 - tag_len ))
  (( max_text < 5 )) && max_text=5
  if (( ${#text} > max_text )); then
    text="${text:0:$((max_text - 2))}.."
  fi

  local content_len=$(( 4 + ${#text} + tag_len ))
  local pad_len=$(( inner - content_len ))
  (( pad_len < 0 )) && pad_len=0
  local pad
  printf -v pad '%*s' "$pad_len" ""

  printf '  %b|%b  %b%s%b %s%s%b%s%b%b|%b\n' \
    "${ACCENT}" "${RESET}" "$icon_color" "$icon" "${RESET}" \
    "$text" "$pad" "${DIM}" "$tag" "${RESET}" "${ACCENT}" "${RESET}"
}

_fleet_box_bottom() {
  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local bottom
  printf -v bottom '%*s' "$w" ""
  bottom="${bottom// /-}"
  printf '  %b+%s+%b\n' "${ACCENT}" "$bottom" "${RESET}"
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

  # ============================================
  # Step 1: Name your fleet
  # ============================================
  _FLEET_SETUP_TOTAL=6
  _fleet_setup_screen 1 "Name your fleet"

  # Check for existing fleets
  local _existing_fleets=()
  while IFS= read -r _ef; do
    [[ -n "$_ef" ]] && _existing_fleets[${#_existing_fleets[@]}]="$_ef"
  done < <(fleets_list 2>/dev/null)

  if (( ${#_existing_fleets[@]} > 0 )); then
    printf '%b\n' "  ${DIM}Reinforce an existing fleet, or raise a new one.${RESET}"
    echo ""

    # Build menu with fleet info
    local _fleet_opts=()
    local _fi=0
    while (( _fi < ${#_existing_fleets[@]} )); do
      local _ef_name="${_existing_fleets[$_fi]}"
      local _ef_count=0
      local _ef_grp _ef_proj
      for _ef_grp in $(fleet_cfg_groups "$_ef_name" 2>/dev/null); do
        for _ef_proj in $(fleet_cfg_group_projects "$_ef_name" "$_ef_grp" 2>/dev/null); do
          _ef_count=$(( _ef_count + 1 ))
        done
      done
      _fleet_opts[${#_fleet_opts[@]}]="${_ef_name}  (${_ef_count} machines)"
      _fi=$(( _fi + 1 ))
    done
    _fleet_opts[${#_fleet_opts[@]}]="+ Raise new fleet"

    menu_select "Fleet" "${_fleet_opts[@]}"

    if [[ "$MENU_RESULT" == "+ Raise new fleet" ]]; then
      echo ""
      printf '%b\n' "  ${DIM}Name it after the environment it defends.${RESET}"
      echo ""
      printf '  %b>%b Fleet name %b(production)%b: ' "${ACCENT}" "${RESET}" "${DIM}" "${RESET}"
      IFS= read -r _fleet_name
      [[ -z "$_fleet_name" ]] && _fleet_name="production"
    elif [[ "$MENU_RESULT" == "__back__" ]]; then
      return 0
    else
      # Strip the machine count suffix
      _fleet_name="${MENU_RESULT%%  (*}"
      _is_existing_fleet=true
    fi
  else
    printf '%b\n' "  ${DIM}A fleet is your deploy formation -- machines marching${RESET}"
    printf '%b\n' "  ${DIM}in step toward the same mission. Name it after the${RESET}"
    printf '%b\n' "  ${DIM}environment it defends.${RESET}"
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

  # ============================================
  # Step 2: Recruit machines
  # ============================================
  while true; do
    local _machine_count=$(( ${#_machines[@]} + 1 ))
    _fleet_setup_screen 2 "Recruit machines"

    # Show machines already in this fleet
    local _roster_shown=false
    if [[ "$_is_existing_fleet" == "true" ]]; then
      local _existing_count=0
      local _ex_grp _ex_proj
      for _ex_grp in $(fleet_cfg_groups "$_fleet_name" 2>/dev/null); do
        for _ex_proj in $(fleet_cfg_group_projects "$_fleet_name" "$_ex_grp" 2>/dev/null); do
          if (( _existing_count == 0 )); then
            printf '%b\n' "  ${ACCENT}Current roster:${RESET}"
          fi
          fleet_cfg_project_load "$_fleet_name" "$_ex_grp" "$_ex_proj"
          printf '%b\n' "    ${GREEN}*${RESET} ${BOLD}${_ex_proj}${RESET}  ${DIM}${_FP_USER}@${_FP_HOST}${RESET}"
          _existing_count=$(( _existing_count + 1 ))
        done
      done
      if (( _existing_count > 0 )); then
        echo ""
        _roster_shown=true
      fi
    fi

    # Show machines added this session
    if (( ${#_machines[@]} > 0 )); then
      if [[ "$_roster_shown" == "false" ]]; then
        printf '%b\n' "  ${ACCENT}New recruits:${RESET}"
      else
        printf '%b\n' "  ${ACCENT}Enlisted this session:${RESET}"
      fi
      local _mi=0
      while (( _mi < ${#_machines[@]} )); do
        printf '%b\n' "    ${GREEN}+${RESET} ${BOLD}${_machines[$_mi]}${RESET}  ${DIM}${_machine_users[$_mi]}@${_machine_hosts[$_mi]}${RESET}"
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

      printf '%b\n' "  ${DIM}Add the machines you want to deploy to. Muster will${RESET}"
    printf '%b\n' "  ${DIM}connect over SSH to detect what's running on each one.${RESET}"
    echo ""
    printf '%b\n' "  ${DIM}Found ${_ssh_count} host(s) in ~/.ssh/config ready for duty.${RESET}"
      echo ""

      menu_select "Enlist how?" "Import from SSH config" "Enter manually" "Done recruiting"

      case "$MENU_RESULT" in
        "Import from SSH config")
          echo ""
          checklist_select --none "Select recruits" "${_import_labels[@]}"

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
                start_spinner "Hailing ${_im_name}..."
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
                  printf '%b\n' "  ${GREEN}*${RESET} ${BOLD}${_im_name}${RESET} reporting for duty  ${DIM}${_im_user}@${_im_host}${RESET}"
                else
                  printf '%b\n' "  ${YELLOW}!${RESET} ${BOLD}${_im_name}${RESET} not responding  ${DIM}${_im_user}@${_im_host}${RESET}"
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
        "Done recruiting")
          if (( ${#_machines[@]} == 0 )); then
            if [[ "$_is_existing_fleet" == "true" ]]; then
              break
            fi
            warn "Every fleet needs at least one machine, soldier."
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
      # No SSH config hosts
      if (( ${#_machines[@]} > 0 )); then
        menu_select "Recruit more?" "Add another" "Fall in (continue)"
        if [[ "$MENU_RESULT" == "Fall in (continue)" || "$MENU_RESULT" == "__back__" ]]; then
          break
        fi
      fi
    fi

    # -- Manual entry --
    printf '%b\n' "  ${DIM}Recruit #${_machine_count}:${RESET}"
    echo ""

    printf '  %b>%b Callsign %b(name for this machine)%b: ' "${ACCENT}" "${RESET}" "${DIM}" "${RESET}"
    local _m_name=""
    IFS= read -r _m_name
    if [[ -z "$_m_name" ]]; then
      if (( ${#_machines[@]} == 0 )) && [[ "$_is_existing_fleet" == "false" ]]; then
        warn "Every fleet needs at least one machine, soldier."
        sleep 1
        continue
      fi
      break
    fi

    printf '  %b>%b Host %b(user@ip)%b: ' "${ACCENT}" "${RESET}" "${DIM}" "${RESET}"
    local _m_host=""
    IFS= read -r _m_host
    if [[ -z "$_m_host" || "$_m_host" != *"@"* ]]; then
      warn "Expected user@hostname format. Regroup and try again."
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

    # SSH key -- auto-detect
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

      menu_select "Credentials" "${_key_opts[@]}"
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
    start_spinner "Hailing ${_m_user}@${_m_hostname}..."
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
      printf '%b\n' "  ${GREEN}*${RESET} ${BOLD}${_m_name}${RESET} reporting for duty"
    else
      printf '%b\n' "  ${RED}x${RESET} ${BOLD}${_m_name}${RESET} not responding"
      printf '%b\n' "  ${DIM}Enlisted anyway. Fix connectivity before deploy.${RESET}"
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
    menu_select "Recruit more?" "Add another" "Fall in (continue)"
    [[ "$MENU_RESULT" == "Fall in (continue)" || "$MENU_RESULT" == "__back__" ]] && break
  done

  # If no new machines added to existing fleet, we're done with add step
  if (( ${#_machines[@]} == 0 )) && [[ "$_is_existing_fleet" == "false" ]]; then
    warn "No machines enlisted. Fleet disbanded."
    return 1
  fi

  # ============================================
  # Step 3: Brief each machine
  # ============================================
  local _mi=0
  while (( _mi < ${#_machines[@]} )); do
    local _mname="${_machines[$_mi]}"
    local _mhost="${_machine_hosts[$_mi]}"
    local _muser="${_machine_users[$_mi]}"
    _fleet_setup_screen 3 "Briefing: ${_mname}"

    # Auto-detect what's on the remote
    local _detected=false
    start_spinner "Scouting ${_mname}..."

    # Need to load machine config for fleet_exec to work
    _fleet_load_machine "$_mname" 2>/dev/null || true

    if _fleet_setup_detect_remote "$_mname" 2>/dev/null; then
      _detected=true
    fi
    stop_spinner

    if [[ "$_detected" == "true" ]]; then
      # Show recon results
      printf '%b\n' "  ${ACCENT}Recon report:${RESET}"
      printf '%b\n' "  ${GREEN}*${RESET} Comms established ${DIM}(SSH OK)${RESET}"

      if [[ "$_DETECT_MUSTER" == "yes" ]]; then
        printf '%b\n' "  ${GREEN}*${RESET} Muster already deployed on target"
      fi

      case "$_DETECT_STACK" in
        compose) printf '%b\n' "  ${GREEN}*${RESET} Docker Compose on deck" ;;
        k8s)     printf '%b\n' "  ${GREEN}*${RESET} Kubernetes cluster detected" ;;
        docker)  printf '%b\n' "  ${GREEN}*${RESET} Docker engine running" ;;
        bare)    printf '%b\n' "  ${DIM}  No container runtime found (bare metal)${RESET}" ;;
      esac

      if (( ${#_DETECT_PATHS[@]} > 0 )); then
        local _pi=0
        while (( _pi < ${#_DETECT_PATHS[@]} )); do
          printf '%b\n' "  ${GREEN}*${RESET} Project found at ${DIM}${_DETECT_PATHS[$_pi]}${RESET}"
          _pi=$((_pi + 1))
        done
      fi
      echo ""
    else
      printf '%b\n' "  ${YELLOW}!${RESET} Recon failed ${DIM}(SSH unreachable -- configuring blind)${RESET}"
      echo ""
    fi

    # Recommend hook mode based on detection
    printf '%b\n' "  ${DIM}How should deploys work on this machine?${RESET}"
    echo ""

    local _recommended_mode="sync"
    local _rec_label="Sync"
    local _rec_desc="Muster writes deploy/health/rollback scripts locally and pushes them to the machine over SSH. You control everything from HQ."
    local _alt_label="Manual"
    local _alt_desc="Muster is already installed on this machine. Just SSH in and tell it to deploy -- the remote handles the rest."

    if [[ "$_DETECT_MUSTER" == "yes" ]]; then
      _recommended_mode="manual"
      _rec_label="Manual"
      _rec_desc="Muster is already installed on this machine. Just SSH in and tell it to deploy -- the remote handles the rest."
      _alt_label="Sync"
      _alt_desc="Override: Muster writes deploy/health/rollback scripts locally and pushes them to the machine over SSH. You control everything from HQ."
    fi

    menu_select_desc "Deploy mode" \
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
        # -- Sync mode: configure services + hooks --
        echo ""
        printf '%b\n' "  ${DIM}What services run on this machine? Muster will generate${RESET}"
        printf '%b\n' "  ${DIM}deploy, health, and rollback scripts for each one.${RESET}"
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

        # Stack -- pre-select from detection
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

        printf '%b\n' "  ${DIM}How are services deployed on this machine?${RESET}"
        echo ""
        menu_select "Deploy stack" "${_stack_opts[@]}"
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
          printf '%b\n' "  ${GREEN}*${RESET} Battle plans generated:"
          local _gi=0
          while (( _gi < ${#_svc_names[@]} )); do
            printf '%b\n' "    ${ACCENT}>${RESET} ${_svc_names[$_gi]}/"
            _gi=$((_gi + 1))
          done
          echo ""
          printf '%b\n' "  ${DIM}Customize at ~/.muster/fleets/${_fleet_name}/default/${_mname}/hooks/${RESET}"
        fi

        # Remote project path for sync target
        local _sync_path=""
        if (( ${#_DETECT_PATHS[@]} > 0 )); then
          _sync_path="${_DETECT_PATHS[0]}"
        fi
        echo ""
        printf '  %b>%b Deploy target %b(%s)%b: ' "${ACCENT}" "${RESET}" "${DIM}" "${_sync_path:-~/myapp}" "${RESET}"
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
        # -- Manual mode --
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

  # ============================================
  # Step 4: Formation (deploy strategy)
  # ============================================
  _fleet_setup_screen 4 "Choose formation"

  # Count total machines (existing + new)
  local _total_machines=0
  local _tm_grp _tm_proj
  for _tm_grp in $(fleet_cfg_groups "$_fleet_name" 2>/dev/null); do
    for _tm_proj in $(fleet_cfg_group_projects "$_fleet_name" "$_tm_grp" 2>/dev/null); do
      _total_machines=$(( _total_machines + 1 ))
    done
  done

  if (( _total_machines <= 1 )); then
    printf '%b\n' "  ${DIM}Single soldier -- no formation needed. Sequential it is.${RESET}"
    _strategy="sequential"
    fleet_cfg_update "$_fleet_name" ".deploy_strategy = \"sequential\"" 2>/dev/null || true
    echo ""
    printf '%b\n' "  ${DIM}Press any key to advance...${RESET}"
    IFS= read -rsn1 || true
  else
    printf '%b\n' "  ${DIM}${_total_machines} machines in formation. When you deploy, in${RESET}"
    printf '%b\n' "  ${DIM}what order should machines receive updates?${RESET}"
    echo ""

    menu_select_desc "Deploy strategy" \
      "Sequential (recommended)" \
      "One at a time. If a machine fails, halt before it spreads. Good default." \
      "Parallel" \
      "All at once. Fastest, but if it breaks, it breaks everywhere." \
      "Rolling" \
      "Deploy to one, verify it's healthy, then move to the next. Safest for production."

    case "$MENU_RESULT" in
      *"Parallel"*) _strategy="parallel" ;;
      *"Rolling"*)  _strategy="rolling" ;;
      *)            _strategy="sequential" ;;
    esac

    fleet_cfg_update "$_fleet_name" ".deploy_strategy = \"${_strategy}\"" 2>/dev/null || true
  fi

  # ============================================
  # Step 5: Deploy scouts (agent install)
  # ============================================
  _fleet_setup_screen 5 "Deploy scouts"

  printf '%b\n' "  ${DIM}Scouts are lightweight monitoring agents that live on your${RESET}"
  printf '%b\n' "  ${DIM}machines. They collect:${RESET}"
  printf '%b\n' "    ${DIM}- Service health (every 30s)${RESET}"
  printf '%b\n' "    ${DIM}- System metrics: CPU, memory, disk (every 60s)${RESET}"
  printf '%b\n' "    ${DIM}- Deploy events (real-time)${RESET}"
  printf '%b\n' "    ${DIM}- Service log tails (every 60s)${RESET}"
  printf '%b\n' "  ${DIM}Scouts push reports back to HQ over SSH so you can${RESET}"
  printf '%b\n' "  ${DIM}check fleet health without SSHing into every box.${RESET}"
  echo ""

  # Generate fleet encryption keypair
  source "$MUSTER_ROOT/lib/core/fleet_crypto.sh"
  source "$MUSTER_ROOT/lib/core/fleet_config.sh"

  local _keygen_ok=false
  local _fleet_key_path="$(fleet_dir "$_fleet_name")/fleet.key"

  start_spinner "Generating fleet encryption keypair (RSA-4096)..."
  if fleet_crypto_keygen "$_fleet_name" 2>/dev/null; then
    _keygen_ok=true
  fi
  stop_spinner

  if [[ "$_keygen_ok" == "true" ]]; then
    _fleet_box_top "Encryption"
    _fleet_box_row "${GREEN}" "*" "RSA-4096 + AES-256 hybrid" "active"
    _fleet_box_bottom
    echo ""
    printf '%b\n' "  ${DIM}How it works:${RESET}"
    printf '%b\n' "    ${DIM}1. Each report is encrypted with a random AES-256 key${RESET}"
    printf '%b\n' "    ${DIM}2. That key is wrapped with your fleet's RSA-4096 public key${RESET}"
    printf '%b\n' "    ${DIM}3. Only your private key can unwrap and read the report${RESET}"
    echo ""
    printf '%b\n' "  ${ACCENT}Private key:${RESET} ${DIM}${_fleet_key_path}${RESET}"
    printf '%b\n' "  ${YELLOW}!${RESET} ${BOLD}Back this up.${RESET} ${DIM}Without it, encrypted reports are unreadable.${RESET}"
    printf '%b\n' "  ${DIM}  Scouts only receive the public key -- they can encrypt${RESET}"
    printf '%b\n' "  ${DIM}  but never decrypt reports from other machines.${RESET}"
  else
    printf '%b\n' "  ${YELLOW}!${RESET} Could not generate encryption keys (openssl missing?)"
    printf '%b\n' "  ${DIM}  Reports will be sent as plaintext over SSH.${RESET}"
    printf '%b\n' "  ${DIM}  Run 'muster fleet keygen' later to enable encryption.${RESET}"
  fi
  echo ""

  # Offer agent installation on each machine
  local _scout_deployed=()
  local _scout_failed=()

  if (( ${#_machines[@]} > 0 )); then
    menu_select "Deploy scouts?" "Install on all new machines" "Select machines" "Skip for now"

    local _scout_targets=()
    case "$MENU_RESULT" in
      "Install on all new machines")
        local _si=0
        while (( _si < ${#_machines[@]} )); do
          _scout_targets[${#_scout_targets[@]}]="${_machines[$_si]}"
          _si=$((_si + 1))
        done
        ;;
      "Select machines")
        local _scout_labels=()
        local _si=0
        while (( _si < ${#_machines[@]} )); do
          _scout_labels[${#_scout_labels[@]}]="${_machines[$_si]}  ${_machine_users[$_si]}@${_machine_hosts[$_si]}"
          _si=$((_si + 1))
        done
        checklist_select --none "Select scouts" "${_scout_labels[@]}"
        while IFS= read -r _selected; do
          [[ -z "$_selected" ]] && continue
          _scout_targets[${#_scout_targets[@]}]="${_selected%%  *}"
        done <<< "$CHECKLIST_RESULT"
        ;;
    esac

    if (( ${#_scout_targets[@]} > 0 )); then
      echo ""
      source "$MUSTER_ROOT/lib/commands/fleet_agent.sh"
      FLEET_CONFIG_FILE="__fleet_dirs__"

      local _si=0
      while (( _si < ${#_scout_targets[@]} )); do
        local _st="${_scout_targets[$_si]}"
        echo ""
        printf '%b\n' "  ${ACCENT}--- ${_st} ---${RESET}"
        if _fleet_cmd_install_agent "$_st" --push --force; then
          _scout_deployed[${#_scout_deployed[@]}]="$_st"
        else
          _scout_failed[${#_scout_failed[@]}]="$_st"
        fi
        _si=$((_si + 1))
      done
      echo ""

      # Scout deployment summary
      if (( ${#_scout_deployed[@]} > 0 )); then
        printf '%b\n' "  ${GREEN}*${RESET} ${#_scout_deployed[@]} scout(s) deployed and reporting"
      fi
      if (( ${#_scout_failed[@]} > 0 )); then
        printf '%b\n' "  ${YELLOW}!${RESET} ${#_scout_failed[@]} scout(s) failed to deploy:"
        local _fi=0
        while (( _fi < ${#_scout_failed[@]} )); do
          printf '%b\n' "    ${DIM}- ${_scout_failed[$_fi]}${RESET}"
          _fi=$((_fi + 1))
        done
        printf '%b\n' "  ${DIM}  Retry later: muster fleet install-agent <name> --push${RESET}"
      fi
    else
      printf '%b\n' "  ${DIM}No scouts deployed. Install later with:${RESET}"
      printf '%b\n' "    ${BOLD}muster fleet install-agent <machine> --push${RESET}"
      echo ""
    fi
  fi

  echo ""
  printf '%b\n' "  ${DIM}Press any key to advance...${RESET}"
  IFS= read -rsn1 || true

  # ============================================
  # Step 6: Fleet assembled
  # ============================================
  _fleet_setup_screen 6 "Fleet assembled"

  printf '%b\n' "  ${DIM}All units accounted for. Here's your command post:${RESET}"
  echo ""

  # Fleet roster box
  _fleet_box_top "${_fleet_name}"

  for _tm_grp in $(fleet_cfg_groups "$_fleet_name" 2>/dev/null); do
    for _tm_proj in $(fleet_cfg_group_projects "$_fleet_name" "$_tm_grp" 2>/dev/null); do
      fleet_cfg_project_load "$_fleet_name" "$_tm_grp" "$_tm_proj"

      local _hm_tag=""
      case "$_FP_HOOK_MODE" in
        sync)   _hm_tag=" sync" ;;
        manual) _hm_tag=" manual" ;;
      esac

      # Check if scout is deployed
      local _scout_icon="${GREEN}"
      local _scout_suffix=""
      local _is_scouted=false
      local _sdi=0
      while (( _sdi < ${#_scout_deployed[@]} )); do
        [[ "${_scout_deployed[$_sdi]}" == "$_tm_proj" ]] && _is_scouted=true
        _sdi=$((_sdi + 1))
      done
      if [[ "$_is_scouted" == "true" ]]; then
        _hm_tag="${_hm_tag}+scout"
      fi

      local _display="${_tm_proj}: ${_FP_USER}@${_FP_HOST}"
      _fleet_box_row "${GREEN}" "*" "$_display" "$_hm_tag"
    done
  done

  _fleet_box_bottom

  echo ""
  printf '%b\n' "  ${DIM}Strategy:${RESET}    ${BOLD}${_strategy}${RESET}"

  # Encryption status
  if [[ "$_keygen_ok" == "true" ]]; then
    printf '%b\n' "  ${DIM}Encryption:${RESET}  ${GREEN}RSA-4096 + AES-256${RESET}"
  else
    printf '%b\n' "  ${DIM}Encryption:${RESET}  ${YELLOW}disabled${RESET} ${DIM}(run: muster fleet keygen)${RESET}"
  fi

  # Scout count
  local _scout_total=$(( ${#_scout_deployed[@]} ))
  if (( _scout_total > 0 )); then
    printf '%b\n' "  ${DIM}Scouts:${RESET}      ${GREEN}${_scout_total} deployed${RESET}"
  else
    printf '%b\n' "  ${DIM}Scouts:${RESET}      ${DIM}none${RESET}"
  fi

  printf '%b\n' "  ${DIM}Config:${RESET}      ~/.muster/fleets/${_fleet_name}/"
  echo ""

  printf '%b\n' "  ${ACCENT}Orders:${RESET}"
  printf '%b\n' "    ${BOLD}muster fleet deploy${RESET}         Send the fleet"
  printf '%b\n' "    ${BOLD}muster fleet status${RESET}         Check all positions"
  printf '%b\n' "    ${BOLD}muster fleet agent-status${RESET}   Scout reports (health + metrics)"
  printf '%b\n' "    ${BOLD}muster fleet sync${RESET}           Push battle plans"
  printf '%b\n' "    ${BOLD}muster fleet${RESET}                Command center"
  echo ""

  menu_select "First orders?" "Dry run (test deploy)" "Dismissed"

  if [[ "$MENU_RESULT" == "Dry run (test deploy)" ]]; then
    echo ""
    FLEET_CONFIG_FILE="__fleet_dirs__"
    _fleet_cmd_deploy --dry-run
    printf '  %bPress any key to dismiss...%b' "$DIM" "$RESET"
    IFS= read -rsn1 || true
    echo ""
  fi

  return 0
}
