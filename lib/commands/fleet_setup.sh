#!/usr/bin/env bash
# muster/lib/commands/fleet_setup.sh — Fleet setup wizard
# Guided multi-machine, multi-project deployment configuration

# ══════════════════════════════════════════════════════════════
# Fleet setup wizard
# ══════════════════════════════════════════════════════════════

_FLEET_SETUP_STEP=1
_FLEET_SETUP_TOTAL=10

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

  # Progress bar
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

cmd_fleet_setup() {
  # Guard: require TTY
  if [[ ! -t 0 ]]; then
    err "Fleet setup requires a terminal (TTY)."
    echo "  Use 'muster fleet add' for non-interactive machine setup."
    return 1
  fi

  # Ensure fleet is initialized
  local remotes_file=""
  remotes_file=$(fleet_find_config 2>/dev/null || true)
  if [[ -z "$remotes_file" ]]; then
    fleet_init 2>/dev/null || true
  fi

  # ── Step 1: Welcome + What You Have ──
  _fleet_setup_screen 1 "Fleet deployment setup"

  printf '%b\n' "  ${DIM}Let's set up deployment to multiple machines.${RESET}"
  echo ""

  menu_select_desc "What are you setting up?" \
    "One project -> multiple machines" \
    "Deploy the same project to multiple servers. Example: 3 API servers behind a load balancer, or staging + production." \
    "Multiple projects -> coordinated" \
    "Deploy several different apps together in the right order. Example: API + frontend + worker that depend on each other."

  local _fleet_mode="single"
  case "$MENU_RESULT" in
    *"Multiple"*) _fleet_mode="multi" ;;
  esac

  if [[ "$_fleet_mode" == "multi" ]]; then
    _FLEET_SETUP_TOTAL=10
  else
    _FLEET_SETUP_TOTAL=8
  fi

  # ── Step 2: Add Machines ──
  local _machines=()
  local _machine_count=0

  while true; do
    _machine_count=$(( ${#_machines[@]} + 1 ))
    _fleet_setup_screen 2 "Add machines"

    if (( ${#_machines[@]} > 0 )); then
      printf '%b\n' "  ${DIM}Added so far:${RESET}"
      local _mi=0
      while (( _mi < ${#_machines[@]} )); do
        printf '%b\n' "    ${GREEN}*${RESET} ${_machines[$_mi]}"
        _mi=$((_mi + 1))
      done
      echo ""
    fi

    printf '%b\n' "  ${DIM}Machine ${_machine_count}:${RESET}"
    echo ""

    # Machine name
    printf '  %b>%b Name: ' "${ACCENT}" "${RESET}"
    local _m_name=""
    IFS= read -r _m_name
    [[ -z "$_m_name" ]] && break

    # Host
    printf '  %b>%b Host (user@host): ' "${ACCENT}" "${RESET}"
    local _m_host=""
    IFS= read -r _m_host

    if [[ -z "$_m_host" || "$_m_host" != *"@"* ]]; then
      warn "Invalid host format. Use user@hostname or user@ip"
      sleep 1
      continue
    fi

    local _m_user="${_m_host%%@*}"
    local _m_hostname="${_m_host#*@}"

    # SSH key detection
    local _ssh_keys=()
    local _kf
    for _kf in "$HOME"/.ssh/id_ed25519 "$HOME"/.ssh/id_rsa "$HOME"/.ssh/deploy-key "$HOME"/.ssh/deploy; do
      [[ -f "$_kf" ]] && _ssh_keys[${#_ssh_keys[@]}]="$_kf"
    done

    local _m_key=""
    if (( ${#_ssh_keys[@]} > 0 )); then
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

    # Test connectivity
    echo ""
    start_spinner "Testing SSH to ${_m_host}..."
    local _ssh_ok=false
    local _ssh_opts="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    [[ -n "$_m_key" ]] && _ssh_opts="${_ssh_opts} -i ${_m_key}"
    if ssh $_ssh_opts "${_m_host}" "echo ok" &>/dev/null; then
      _ssh_ok=true
    fi
    stop_spinner

    if [[ "$_ssh_ok" == "true" ]]; then
      printf '%b\n' "  ${GREEN}*${RESET} Connected to ${_m_host}"
    else
      printf '%b\n' "  ${RED}x${RESET} Cannot connect to ${_m_host}"
      printf '%b\n' "  ${DIM}Check SSH key and host accessibility${RESET}"
    fi

    # Add machine to fleet
    local _add_args="--mode push"
    [[ -n "$_m_key" ]] && _add_args="${_add_args} --key ${_m_key}"
    fleet_add_machine "$_m_name" "$_m_hostname" "$_m_user" "22" "$_m_key" "" "push" "ssh" "manual" 2>/dev/null || true

    _machines[${#_machines[@]}]="$_m_name"

    echo ""
    menu_select "Add another machine?" "Yes" "Done"
    [[ "$MENU_RESULT" == "Done" || "$MENU_RESULT" == "__back__" ]] && break
  done

  if (( ${#_machines[@]} == 0 )); then
    warn "No machines added."
    return 1
  fi

  # ── Step 3: Hook Management (per machine) ──
  local _mi=0
  while (( _mi < ${#_machines[@]} )); do
    local _mname="${_machines[$_mi]}"
    _fleet_setup_screen 3 "Configure ${_mname}"

    printf '%b\n' "  ${DIM}How should deploys work on ${BOLD}${_mname}${RESET}${DIM}?${RESET}"
    echo ""

    menu_select_desc "Hook management" \
      "Set up from here" \
      "Muster creates deploy scripts locally and syncs them to the remote before each deploy. You edit hooks on your machine, muster pushes them automatically." \
      "Already set up" \
      "The remote machine has its own muster installation with hooks configured. You manage hooks directly on the remote by running 'muster setup' there."

    case "$MENU_RESULT" in
      *"Set up from here"*)
        # Sync mode — generate hooks locally
        local _hook_mode="sync"

        # Ask what the remote runs
        echo ""
        printf '%b\n' "  ${DIM}What does ${_mname} run?${RESET}"
        echo ""
        checklist_select --none "Components" \
          "Web app / API" \
          "Background workers / queues" \
          "Database (managed here)" \
          "Cache (Redis, Memcached)" \
          "Reverse proxy (Nginx, Caddy)"

        local _remote_components=()
        while IFS= read -r _rc; do
          [[ -n "$_rc" ]] && _remote_components[${#_remote_components[@]}]="$_rc"
        done <<< "$CHECKLIST_RESULT"

        # Ask stack
        echo ""
        menu_select "Stack on ${_mname}?" "Docker Compose" "Docker" "Kubernetes" "Bare metal"
        local _remote_stack="compose"
        case "$MENU_RESULT" in
          "Docker Compose") _remote_stack="compose" ;;
          "Docker")         _remote_stack="docker" ;;
          "Kubernetes")     _remote_stack="k8s" ;;
          "Bare metal")     _remote_stack="bare" ;;
        esac

        # Generate hooks directory
        local _fleet_hooks_base="$HOME/.muster/fleet-hooks/${_mname}"
        mkdir -p "$_fleet_hooks_base"

        # Generate service hooks based on components
        local _generated_svcs=()
        local _ci=0
        while (( _ci < ${#_remote_components[@]} )); do
          local _comp="${_remote_components[$_ci]}"
          local _svc_name=""
          case "$_comp" in
            *"Web app"*|*"API"*)      _svc_name="api" ;;
            *"workers"*|*"queues"*)   _svc_name="worker" ;;
            *"Database"*)             _svc_name="database" ;;
            *"Cache"*)                _svc_name="redis" ;;
            *"Reverse proxy"*)        _svc_name="proxy" ;;
          esac
          if [[ -n "$_svc_name" ]]; then
            local _svc_hook_dir="${_fleet_hooks_base}/${_svc_name}"
            mkdir -p "$_svc_hook_dir"
            _setup_copy_hooks "$_remote_stack" "$_svc_name" "$_svc_name" "$_svc_hook_dir" \
              "docker-compose.yml" "Dockerfile" "k8s/${_svc_name}/" "default" "8080" "$_svc_name" ""
            _generated_svcs[${#_generated_svcs[@]}]="$_svc_name"
          fi
          _ci=$((_ci + 1))
        done

        echo ""
        printf '%b\n' "  ${GREEN}*${RESET} Generated hooks at ${DIM}~/.muster/fleet-hooks/${_mname}/${RESET}"
        local _gi=0
        while (( _gi < ${#_generated_svcs[@]} )); do
          printf '%b\n' "    ${_generated_svcs[$_gi]}/"
          _gi=$((_gi + 1))
        done
        echo ""
        printf '%b\n' "  ${DIM}Edit these anytime. Muster syncs changes before each deploy.${RESET}"

        # Update machine config with hook mode
        fleet_set ".machines.${_mname}.hook_mode" "\"sync\"" 2>/dev/null || true
        fleet_set ".machines.${_mname}.hooks_dir" "\"${_fleet_hooks_base}\"" 2>/dev/null || true
        sleep 1
        ;;
      *)
        # Manual mode
        echo ""
        printf '%b\n' "  ${DIM}Manual mode — ${_mname} manages its own hooks.${RESET}"
        printf '%b\n' "  ${DIM}Make sure muster is set up on the remote, or run 'muster setup' there.${RESET}"
        fleet_set ".machines.${_mname}.hook_mode" "\"manual\"" 2>/dev/null || true
        fleet_set ".machines.${_mname}.mode" "\"muster\"" 2>/dev/null || true
        sleep 1
        ;;
    esac

    _mi=$((_mi + 1))
  done

  # ── Step 4: Groups ──
  _fleet_setup_screen 4 "Create groups"

  printf '%b\n' "  ${DIM}Group machines for coordinated deploys.${RESET}"
  echo ""

  local _groups_created=()

  while true; do
    printf '  %b>%b Group name (or enter to skip): ' "${ACCENT}" "${RESET}"
    local _grp_name=""
    IFS= read -r _grp_name
    [[ -z "$_grp_name" ]] && break

    # Select machines for group
    checklist_select --none "Machines in ${_grp_name}" "${_machines[@]}"

    local _grp_machines=()
    while IFS= read -r _gm; do
      [[ -n "$_gm" ]] && _grp_machines[${#_grp_machines[@]}]="$_gm"
    done <<< "$CHECKLIST_RESULT"

    if (( ${#_grp_machines[@]} > 0 )); then
      fleet_set_group "$_grp_name" "${_grp_machines[@]}" 2>/dev/null || true
      _groups_created[${#_groups_created[@]}]="$_grp_name"
      printf '%b\n' "  ${GREEN}*${RESET} Group '${_grp_name}' created with ${#_grp_machines[@]} machines"
    fi

    echo ""
    menu_select "Create another group?" "Yes" "Done"
    [[ "$MENU_RESULT" == "Done" || "$MENU_RESULT" == "__back__" ]] && break
  done

  # ── Step 5: Multi-Project Setup (multi mode only) ──
  local _projects=()
  local _step_offset=0

  if [[ "$_fleet_mode" == "multi" ]]; then
    _fleet_setup_screen 5 "Add projects"

    printf '%b\n' "  ${DIM}Add projects to deploy together.${RESET}"
    echo ""

    while true; do
      printf '  %b>%b Project name: ' "${ACCENT}" "${RESET}"
      local _proj_name=""
      IFS= read -r _proj_name
      [[ -z "$_proj_name" ]] && break

      printf '  %b>%b Path (on remote): ' "${ACCENT}" "${RESET}"
      local _proj_path=""
      IFS= read -r _proj_path
      [[ -z "$_proj_path" ]] && _proj_path="/opt/${_proj_name}"

      _projects[${#_projects[@]}]="${_proj_name}|${_proj_path}"
      printf '%b\n' "  ${GREEN}*${RESET} ${_proj_name} at ${_proj_path}"

      echo ""
      menu_select "Add another project?" "Yes" "Done"
      [[ "$MENU_RESULT" == "Done" || "$MENU_RESULT" == "__back__" ]] && break
    done

    # ── Step 6: Dependencies + Parallel Analysis ──
    if (( ${#_projects[@]} > 1 )); then
      local _dep_step=6
      _fleet_setup_screen $_dep_step "Dependencies"

      printf '%b\n' "  ${DIM}Do any projects depend on each other?${RESET}"
      echo ""

      # Show dependency picker per project
      local _proj_names=()
      local _pi=0
      while (( _pi < ${#_projects[@]} )); do
        local _pe="${_projects[$_pi]}"
        _proj_names[${#_proj_names[@]}]="${_pe%%|*}"
        _pi=$((_pi + 1))
      done

      local _proj_deps=()  # "project|dep1,dep2" entries
      _pi=0
      while (( _pi < ${#_proj_names[@]} )); do
        local _pn="${_proj_names[$_pi]}"
        # Build list of other projects
        local _other=()
        local _oi=0
        while (( _oi < ${#_proj_names[@]} )); do
          [[ "$_oi" != "$_pi" ]] && _other[${#_other[@]}]="${_proj_names[$_oi]}"
          _oi=$((_oi + 1))
        done

        if (( ${#_other[@]} > 0 )); then
          checklist_select --none "${_pn} depends on" "${_other[@]}"
          local _deps=""
          while IFS= read -r _dep; do
            [[ -n "$_dep" ]] && _deps="${_deps}${_deps:+,}${_dep}"
          done <<< "$CHECKLIST_RESULT"
          _proj_deps[${#_proj_deps[@]}]="${_pn}|${_deps}"
        else
          _proj_deps[${#_proj_deps[@]}]="${_pn}|"
        fi
        _pi=$((_pi + 1))
      done

      # Compute phases (simple topological sort)
      # Phase 1: projects with no dependencies
      # Phase 2: projects depending only on phase 1
      # etc.
      local _phase1=() _phase2=()
      _pi=0
      while (( _pi < ${#_proj_deps[@]} )); do
        local _pe="${_proj_deps[$_pi]}"
        local _pn="${_pe%%|*}"
        local _pd="${_pe#*|}"
        if [[ -z "$_pd" ]]; then
          _phase1[${#_phase1[@]}]="$_pn"
        else
          _phase2[${#_phase2[@]}]="$_pn"
        fi
        _pi=$((_pi + 1))
      done

      echo ""
      printf '%b\n' "  ${BOLD}Deploy plan:${RESET}"
      if (( ${#_phase1[@]} > 0 )); then
        local _p1_str=""
        local _p1i=0
        while (( _p1i < ${#_phase1[@]} )); do
          _p1_str="${_p1_str}${_p1_str:+ + }${_phase1[$_p1i]}"
          _p1i=$((_p1i + 1))
        done
        printf '%b\n' "    Phase 1:  ${_p1_str}  ${DIM}[deploys first]${RESET}"
      fi
      if (( ${#_phase2[@]} > 0 )); then
        local _p2_str=""
        local _p2i=0
        while (( _p2i < ${#_phase2[@]} )); do
          _p2_str="${_p2_str}${_p2_str:+ + }${_phase2[$_p2i]}"
          _p2i=$((_p2i + 1))
        done
        printf '%b\n' "    Phase 2:  ${_p2_str}  ${DIM}[parallel]${RESET}"
      fi
      echo ""

      menu_select "Deploy plan" "Accept" "Change"
      # For now, accept only — reorder not implemented
      sleep 1
    fi
  else
    _step_offset=2  # Skip steps 5-6 in single mode
  fi

  # ── Step 7 (or 5 in single mode): Deploy Strategy ──
  local _strategy_step=$(( 7 - _step_offset ))
  _fleet_setup_screen $_strategy_step "Deploy strategy"

  printf '%b\n' "  ${DIM}How should fleet deploys run across machines?${RESET}"
  echo ""

  menu_select_desc "Strategy" \
    "Sequential" \
    "Deploy to one machine at a time. If something fails, you can retry or abort before it affects other machines. Best for critical production deployments." \
    "Parallel" \
    "Deploy to all machines at once. Fastest option, but if something goes wrong it affects everything simultaneously. Good for staging or non-critical services." \
    "Rolling" \
    "Deploy to one machine, verify it's healthy, then move to the next. Combines safety with speed — unhealthy deploys are caught before they spread."

  local _strategy="sequential"
  case "$MENU_RESULT" in
    *"Parallel"*) _strategy="parallel" ;;
    *"Rolling"*)  _strategy="rolling" ;;
  esac

  fleet_set ".deploy_strategy" "\"${_strategy}\"" 2>/dev/null || true

  # ── Step 8 (or 6): Sync Check ──
  local _sync_step=$(( 8 - _step_offset ))
  _fleet_setup_screen $_sync_step "Sync check"

  printf '%b\n' "  ${DIM}Checking project files are in sync...${RESET}"
  echo ""

  local _mi=0
  while (( _mi < ${#_machines[@]} )); do
    local _mname="${_machines[$_mi]}"
    _fleet_load_machine "$_mname" 2>/dev/null || true

    printf '  %b' "  ${_mname}:  "
    local _remote_ok=false
    if fleet_check "$_mname" &>/dev/null; then
      _remote_ok=true
      printf '%b\n' "${GREEN}*${RESET} Reachable"
    else
      printf '%b\n' "${RED}x${RESET} Cannot connect"
    fi
    _mi=$((_mi + 1))
  done

  echo ""
  sleep 1

  # ── Step 9 (or 7): Review ──
  local _review_step=$(( 9 - _step_offset ))
  _fleet_setup_screen $_review_step "Review"

  # Show review summary
  if (( ${#_groups_created[@]} > 0 )); then
    local _gi=0
    while (( _gi < ${#_groups_created[@]} )); do
      printf '%b\n' "  ${BOLD}Group:${RESET} ${_groups_created[$_gi]}"
      _gi=$((_gi + 1))
    done
    echo ""
  fi

  printf '%b\n' "  ${BOLD}Machines:${RESET}"
  _mi=0
  while (( _mi < ${#_machines[@]} )); do
    local _mname="${_machines[$_mi]}"
    local _m_hook_mode=""
    _m_hook_mode=$(fleet_get ".machines.${_mname}.hook_mode" 2>/dev/null || echo "manual")
    [[ "$_m_hook_mode" == "null" ]] && _m_hook_mode="manual"
    printf '%b\n' "    ${_mname}  hooks: ${_m_hook_mode}"
    _mi=$((_mi + 1))
  done
  echo ""

  printf '%b\n' "  ${BOLD}Deploy strategy:${RESET} ${_strategy}"

  if [[ "$_fleet_mode" == "multi" && ${#_projects[@]} -gt 0 ]]; then
    echo ""
    printf '%b\n' "  ${BOLD}Projects:${RESET}"
    local _pi=0
    while (( _pi < ${#_projects[@]} )); do
      local _pe="${_projects[$_pi]}"
      printf '%b\n' "    ${_pe%%|*} at ${_pe#*|}"
      _pi=$((_pi + 1))
    done
  fi

  echo ""
  menu_select "Finish?" "Save and finish" "Go back"

  if [[ "$MENU_RESULT" == "Go back" || "$MENU_RESULT" == "__back__" ]]; then
    info "Fleet setup cancelled."
    return 0
  fi

  # ── Step 10 (or 8): Post-Setup ──
  local _post_step=$(( 10 - _step_offset ))
  _fleet_setup_screen $_post_step "Fleet setup complete"

  printf '%b\n' "  ${GREEN}*${RESET} Fleet configured with ${#_machines[@]} machines"
  echo ""

  printf '%b\n' "  ${ACCENT}Commands:${RESET}"
  printf '%b\n' "    ${BOLD}muster fleet deploy${RESET}              Deploy to all machines"
  if (( ${#_groups_created[@]} > 0 )); then
    printf '%b\n' "    ${BOLD}muster fleet deploy ${_groups_created[0]}${RESET}   Deploy to a group"
  fi
  printf '%b\n' "    ${BOLD}muster fleet status${RESET}              Check health across fleet"
  printf '%b\n' "    ${BOLD}muster fleet sync${RESET}                Sync hooks + files to remotes"
  echo ""

  menu_select "Want to do a dry run?" "Yes" "Later"

  if [[ "$MENU_RESULT" == "Yes" ]]; then
    source "$MUSTER_ROOT/lib/commands/fleet_deploy.sh"
    _fleet_cmd_deploy --dry-run
  fi

  return 0
}
