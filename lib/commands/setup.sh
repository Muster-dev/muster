#!/usr/bin/env bash
# muster/lib/commands/setup.sh — Guided setup wizard (scan-first)

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/tui/checklist.sh"
source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/tui/order.sh"
source "$MUSTER_ROOT/lib/core/scanner.sh"
source "$MUSTER_ROOT/lib/core/templates.sh"

SETUP_TOTAL_STEPS=7

_setup_phrases=(
  "Let's get this show on the road"
  "Deploying happiness since 2026"
  "Your services called. They want order."
  "Chaos to calm in one setup"
  "Because 'it works on my machine' isn't a strategy"
  "Bringing the mustard to your deploy"
  "Rally your services. Deploy with confidence."
  "One script to rule them all"
  "SSH into production? Not today."
  "Making deploys boring (the good kind)"
  "Hot dogs optional. Deploy scripts required."
  "Gather your troops. It's deploy time."
  "Less YAML, more mustard"
  "Your ops team called. You ARE the ops team."
  "Spreadin' that mustard on your stack"
)

_setup_pick_phrase() {
  local count=${#_setup_phrases[@]}
  local idx=$(( RANDOM % count ))
  echo "${_setup_phrases[$idx]}"
}

# ── Mustard header bar (matches dashboard style) ──
_setup_bar() {
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

# Current screen state for resize redraw
_SETUP_CUR_STEP=1
_SETUP_CUR_LABEL=""
_SETUP_CUR_PHRASE=""
_SETUP_CUR_SUMMARY=()
_SETUP_CUR_PROMPT="false"

_setup_redraw() {
  if [[ "$_SETUP_CUR_PROMPT" == "true" ]]; then
    _setup_screen_inner
  fi
}

_setup_screen_inner() {
  muster_tui_fullscreen
  clear
  update_term_size

  # Mustard header bar
  local _step_right="step ${_SETUP_CUR_STEP}/${SETUP_TOTAL_STEPS}  "
  echo ""
  _setup_bar "muster  setup" "$_step_right"

  # Progress bar
  local bar_w=$(( TERM_COLS - 6 ))
  (( bar_w > 50 )) && bar_w=50
  (( bar_w < 10 )) && bar_w=10
  local filled=$(( _SETUP_CUR_STEP * bar_w / SETUP_TOTAL_STEPS ))
  local empty_count=$(( bar_w - filled ))
  local bar_filled=""
  local bar_empty=""
  local i=0
  while (( i < filled )); do bar_filled="${bar_filled}#"; i=$((i + 1)); done
  i=0
  while (( i < empty_count )); do bar_empty="${bar_empty}-"; i=$((i + 1)); done
  printf '  %b%s%b%s%b\n' "${ACCENT_BRIGHT}" "$bar_filled" "${GRAY}" "$bar_empty" "${RESET}"

  # Phrase subtitle
  if [[ -n "$_SETUP_CUR_PHRASE" ]]; then
    printf '  %b%s%b\n' "${DIM}" "$_SETUP_CUR_PHRASE" "${RESET}"
  fi

  if [[ -n "$_SETUP_CUR_LABEL" ]]; then
    echo ""
    printf '%b\n' "  ${BOLD}${_SETUP_CUR_LABEL}${RESET}"
  fi

  local _sum_count=${#_SETUP_CUR_SUMMARY[@]}
  local _sum_i=0
  local s
  for s in "${_SETUP_CUR_SUMMARY[@]}"; do
    _sum_i=$((_sum_i + 1))
    if (( _sum_i == _sum_count )) && [[ "$_SETUP_CUR_PROMPT" == "true" ]]; then
      printf '%b' "$s"
    else
      printf '%b\n' "$s"
    fi
  done
}

_SETUP_SESSION_PHRASE=""

_setup_screen() {
  _SETUP_CUR_STEP="${1:-1}"
  _SETUP_CUR_LABEL="${2:-}"
  if [[ -z "$_SETUP_SESSION_PHRASE" ]]; then
    _SETUP_SESSION_PHRASE=$(_setup_pick_phrase)
  fi
  _SETUP_CUR_PHRASE="$_SETUP_SESSION_PHRASE"
  # shellcheck disable=SC2034
  MUSTER_REDRAW_FN="_setup_redraw"
  _setup_screen_inner
}

# ── Fleet Cloud: remote agent join ──
_setup_remote_agent() {
  local agent_bin=""
  if command -v muster-agent >/dev/null 2>&1; then
    agent_bin="muster-agent"
  elif [[ -x "${HOME}/.local/bin/muster-agent" ]]; then
    agent_bin="${HOME}/.local/bin/muster-agent"
  fi

  if [[ -z "$agent_bin" ]]; then
    err "muster-agent not found"
    return 1
  fi

  clear
  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}— Remote Agent Setup${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}Connect this machine to your fleet relay so it can${RESET}"
  printf '%b\n' "  ${DIM}receive deployments from your host machine.${RESET}"
  echo ""

  printf '%b\n' "  ${BOLD}Relay URL${RESET} ${DIM}(e.g. wss://relay.example.com/v1/tunnel)${RESET}"
  printf '  %b>%b ' "$ACCENT" "$RESET"
  read -r _relay_url
  if [[ -z "$_relay_url" ]]; then
    err "Relay URL is required"
    return 1
  fi

  echo ""
  printf '%b\n' "  ${BOLD}Organization ID${RESET}"
  printf '  %b>%b ' "$ACCENT" "$RESET"
  read -r _org_id
  if [[ -z "$_org_id" ]]; then
    err "Organization ID is required"
    return 1
  fi

  echo ""
  printf '%b\n' "  ${BOLD}Join token${RESET} ${DIM}(from: muster-cloud token create --type agent-join)${RESET}"
  printf '  %b>%b ' "$ACCENT" "$RESET"
  read -r _join_token
  if [[ -z "$_join_token" ]]; then
    err "Join token is required"
    return 1
  fi

  local _default_name
  _default_name="$(hostname -s 2>/dev/null || hostname)"
  echo ""
  printf '%b\n' "  ${BOLD}Agent name${RESET} ${DIM}[${_default_name}]${RESET}"
  printf '  %b>%b ' "$ACCENT" "$RESET"
  read -r _agent_name
  _agent_name="${_agent_name:-$_default_name}"

  echo ""
  info "Joining fleet as '${_agent_name}'..."
  echo ""

  if "$agent_bin" join \
    --relay "$_relay_url" \
    --token "$_join_token" \
    --org "$_org_id" \
    --name "$_agent_name"; then
    echo ""
    ok "Agent joined successfully!"
    echo ""
    printf '%b\n' "  ${DIM}Start the agent daemon with:${RESET}"
    printf '%b\n' "    ${WHITE}muster-agent run${RESET}"
    echo ""
  else
    echo ""
    err "Failed to join fleet. Check your relay URL and token."
    echo ""
  fi
}

# ── Control host: guided fleet setup ──
_setup_control_host() {
  clear
  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}— Fleet Control Setup${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}Set up this machine to deploy to other machines.${RESET}"
  echo ""

  menu_select "Where are your target machines?" \
    "Same network (SSH)   — Direct SSH connection, simple setup" \
    "Remote / cloud       — Different networks, NATs, firewalls. Uses cloud relay" \
    "Both                 — Mix of local SSH and remote cloud targets"

  local _transport="ssh"
  case "$MENU_RESULT" in
    *"Remote"*)  _transport="cloud" ;;
    *"Both"*)    _transport="both" ;;
  esac

  if [[ "$_transport" == "cloud" || "$_transport" == "both" ]]; then
    _setup_control_cloud
    [[ $? -ne 0 ]] && return 1
  fi

  # Offer to create a fleet group
  clear
  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}— Fleet Control Setup${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}Fleet groups let you deploy multiple projects together.${RESET}"
  printf '%b\n' "  ${DIM}You can add machines and projects to groups later.${RESET}"
  echo ""

  menu_select "Create a fleet group now?" "Yes" "Skip"

  if [[ "$MENU_RESULT" == "Yes" ]]; then
    source "$MUSTER_ROOT/lib/core/groups.sh"
    echo ""
    printf '%b\n' "  ${BOLD}Group name${RESET} ${DIM}(e.g. production, staging)${RESET}"
    printf '  %b>%b ' "$ACCENT" "$RESET"
    local _grp_name=""
    read -r _grp_name
    if [[ -n "$_grp_name" ]]; then
      groups_create "$_grp_name" "$_grp_name" 2>/dev/null && \
        ok "Created fleet group: ${_grp_name}" || \
        err "Failed to create group"
    fi
  fi

  echo ""
  printf '%b\n' "  ${GREEN}*${RESET} ${BOLD}Setup complete${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}Next steps:${RESET}"
  if [[ "$_transport" == "ssh" || "$_transport" == "both" ]]; then
    printf '%b\n' "  ${DIM}  Add SSH machines:   muster fleet add <name> user@host${RESET}"
    printf '%b\n' "  ${DIM}  Add to a group:     muster group add <group> user@host${RESET}"
  fi
  if [[ "$_transport" == "cloud" || "$_transport" == "both" ]]; then
    printf '%b\n' "  ${DIM}  Add cloud targets:  muster group add <group> <agent-name> --cloud${RESET}"
  fi
  printf '%b\n' "  ${DIM}  Deploy a group:     muster group deploy <group>${RESET}"
  printf '%b\n' "  ${DIM}  Open dashboard:     muster${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}Press any key to exit...${RESET}"
  IFS= read -rsn1 || true
}

# ── Control host: cloud config ──
_setup_control_cloud() {
  clear
  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}— Cloud Transport Setup${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}Cloud transport connects to remote machines through a WebSocket relay.${RESET}"
  printf '%b\n' "  ${DIM}No direct SSH needed — works across different networks, NATs, and firewalls.${RESET}"
  echo ""

  # Check if cloud config already exists
  local _existing_relay=""
  _existing_relay=$(global_config_get "cloud.relay" 2>/dev/null)
  if [[ -n "$_existing_relay" && "$_existing_relay" != "null" && "$_existing_relay" != "" ]]; then
    printf '%b\n' "  ${DIM}Current relay: ${_existing_relay}${RESET}"
    echo ""
    menu_select "Cloud config already set. Update it?" "Keep existing" "Update"
    [[ "$MENU_RESULT" == "Keep existing" ]] && return 0
    echo ""
  fi

  printf '%b\n' "  ${BOLD}Relay URL${RESET} ${DIM}(e.g. wss://relay.example.com)${RESET}"
  printf '  %b>%b ' "$ACCENT" "$RESET"
  local _relay=""
  read -r _relay
  if [[ -z "$_relay" ]]; then
    err "Relay URL is required for cloud transport"
    return 1
  fi

  echo ""
  printf '%b\n' "  ${BOLD}Organization ID${RESET}"
  printf '  %b>%b ' "$ACCENT" "$RESET"
  local _org=""
  read -r _org
  if [[ -z "$_org" ]]; then
    err "Organization ID is required"
    return 1
  fi

  echo ""
  printf '%b\n' "  ${BOLD}CLI token${RESET} ${DIM}(mst_cli_...)${RESET}"
  printf '  %b>%b ' "$ACCENT" "$RESET"
  local _token=""
  read -r _token
  if [[ -z "$_token" ]]; then
    err "CLI token is required"
    return 1
  fi

  # Verify relay is reachable
  echo ""
  start_spinner "Verifying relay..."

  local _relay_ok=false
  # Convert wss:// to https:// for health check
  local _health_url="$_relay"
  _health_url="${_health_url/wss:\/\//https://}"
  _health_url="${_health_url/ws:\/\//http://}"
  # Strip trailing path and add /healthz
  _health_url="${_health_url%/}"
  _health_url="${_health_url}/healthz"

  if curl -fsSL --connect-timeout 5 --max-time 10 "$_health_url" >/dev/null 2>&1; then
    _relay_ok=true
  fi
  stop_spinner

  if [[ "$_relay_ok" == "true" ]]; then
    printf '  %b✓%b Relay reachable\n' "${GREEN}" "${RESET}"
  else
    printf '  %b!%b Could not reach relay at %s\n' "${YELLOW}" "${RESET}" "$_health_url"
    echo ""
    menu_select "Save config anyway?" "Yes — save and fix later" "No — re-enter URL"
    if [[ "$MENU_RESULT" == *"No"* ]]; then
      return 1
    fi
  fi

  # Save to global settings
  global_config_set "cloud.relay" "\"$_relay\""
  global_config_set "cloud.org_id" "\"$_org\""
  global_config_set "cloud.token" "\"$_token\""

  echo ""
  ok "Cloud transport configured"

  # Check if muster-tunnel is installed
  if ! command -v muster-tunnel >/dev/null 2>&1 && [[ ! -x "$HOME/.muster/bin/muster-tunnel" ]]; then
    echo ""
    printf '%b\n' "  ${YELLOW}!${RESET} ${DIM}muster-tunnel not installed. Install it to deploy via cloud:${RESET}"
    printf '%b\n' "    ${WHITE}curl -fsSL https://getmuster.dev/cloud | bash${RESET}"
  fi

  return 0
}

# ── Deploy target: intro screen (shows transport info, falls through to project setup) ──
_setup_deploy_target_intro() {
  clear
  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}— Deploy Target Setup${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}This machine will receive deploys from a control host.${RESET}"
  printf '%b\n' "  ${DIM}How will the control host connect to this machine?${RESET}"
  echo ""
  printf '%b\n' "  ${BOLD}Direct SSH${RESET}"
  printf '%b\n' "  ${DIM}  The control host connects over SSH. Both machines must be${RESET}"
  printf '%b\n' "  ${DIM}  on the same network, or this machine needs a public IP or${RESET}"
  printf '%b\n' "  ${DIM}  port forwarding. Simple, no extra software needed.${RESET}"
  echo ""
  printf '%b\n' "  ${BOLD}Cloud tunnel${RESET}"
  printf '%b\n' "  ${DIM}  The control host connects through a WebSocket relay. Works${RESET}"
  printf '%b\n' "  ${DIM}  across different networks, behind NATs and firewalls.${RESET}"
  printf '%b\n' "  ${DIM}  Requires muster-agent running on this machine.${RESET}"
  echo ""

  menu_select "Transport" \
    "Direct SSH    — Same network, nothing extra needed" \
    "Cloud tunnel  — Cross-network, needs muster-agent"

  if [[ "$MENU_RESULT" == *"Cloud"* ]]; then
    # Check if muster-agent is installed
    local agent_bin=""
    if command -v muster-agent >/dev/null 2>&1; then
      agent_bin="muster-agent"
    elif [[ -x "${HOME}/.local/bin/muster-agent" ]]; then
      agent_bin="${HOME}/.local/bin/muster-agent"
    elif [[ -x "${HOME}/.muster/bin/muster-agent" ]]; then
      agent_bin="${HOME}/.muster/bin/muster-agent"
    fi

    if [[ -z "$agent_bin" ]]; then
      echo ""
      printf '%b\n' "  ${YELLOW}!${RESET} ${BOLD}muster-agent not installed${RESET}"
      echo ""
      printf '%b\n' "  ${DIM}Cloud transport requires the muster-agent daemon.${RESET}"
      echo ""

      menu_select "Install muster-agent now?" \
        "Yes — install muster-agent" \
        "Later — I'll install it myself"

      if [[ "$MENU_RESULT" == *"Yes"* ]]; then
        echo ""
        printf '%b\n' "  ${DIM}Installing muster-agent...${RESET}"
        echo ""
        local _agent_prefix="${MUSTER_BIN_DIR:-$HOME/.local/bin}"
        if command -v curl >/dev/null 2>&1; then
          bash <(curl -fsSL https://raw.githubusercontent.com/Muster-dev/muster-fleet-cloud/main/install.sh) --agent --prefix "$_agent_prefix" </dev/tty
        elif command -v wget >/dev/null 2>&1; then
          bash <(wget -qO- https://raw.githubusercontent.com/Muster-dev/muster-fleet-cloud/main/install.sh) --agent --prefix "$_agent_prefix" </dev/tty
        else
          printf '%b\n' "  ${RED}x${RESET} curl or wget required to install muster-agent"
          printf '%b\n' "  ${DIM}Install manually:${RESET}"
          printf '%b\n' "    ${WHITE}curl -fsSL https://getmuster.dev/cloud | bash -s -- --agent${RESET}"
        fi
        echo ""
      else
        echo ""
        printf '%b\n' "  ${DIM}Install later with:${RESET}"
        printf '%b\n' "    ${WHITE}curl -fsSL https://getmuster.dev/cloud | bash -s -- --agent${RESET}"
      fi
    else
      # Agent installed — run the join flow
      _setup_remote_agent
    fi
  else
    clear
    echo ""
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}— SSH Deploy Target${RESET}"
    echo ""
    printf '%b\n' "  ${GREEN}*${RESET} ${BOLD}SSH is ready to go${RESET}"
    echo ""
    printf '%b\n' "  ${DIM}Make sure SSH is enabled and the deploy user can access the project.${RESET}"
  fi

  echo ""
  printf '%b\n' "  ${DIM}Now let's set up your project so muster can deploy it.${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
  IFS= read -rsn1 || true
  # Returns to cmd_setup which continues with project setup
}


# Template utilities loaded from lib/core/templates.sh

# ══════════════════════════════════════════════════════════════
# Non-interactive setup via flags
# ══════════════════════════════════════════════════════════════
_setup_noninteractive() {
  local flag_path="$1" flag_scan="$2" flag_stack="$3" flag_services="$4"
  local flag_order="$5" flag_name="$6" flag_force="$7" flag_namespace="$8"
  # flag_health, flag_creds, and flag_remote are in global arrays _FLAG_HEALTH[], _FLAG_CREDS[], _FLAG_REMOTE[]

  # ── Resolve project path ──
  local project_path
  project_path="$(cd "$flag_path" 2>/dev/null && pwd)" || {
    err "Path does not exist: $flag_path"
    return 1
  }

  # ── Check for existing config ──
  if [[ ( -f "${project_path}/muster.json" || -f "${project_path}/deploy.json" ) && "$flag_force" != "true" ]]; then
    err "Config already exists. Use --force to overwrite."
    return 1
  fi

  local stack="$flag_stack"
  local selected_services=()

  # ── Scan if requested ──
  if [[ "$flag_scan" == "true" ]]; then
    scan_project "$project_path"

    # Use scanned stack if not explicitly provided
    if [[ -z "$stack" && -n "$_SCAN_STACK" ]]; then
      stack="$_SCAN_STACK"
    fi

    # Use scanned services if not explicitly provided
    if [[ -z "$flag_services" && ${#_SCAN_SERVICES[@]} -gt 0 ]]; then
      selected_services=("${_SCAN_SERVICES[@]}")
    fi
  fi

  # ── Live k8s cluster scan ──
  if [[ "${stack:-$_SCAN_STACK}" == "k8s" ]]; then
    local resolved_ns
    resolved_ns=$(_scan_resolve_namespace "${flag_namespace:-}" "$project_path")
    scan_k8s_cluster "$resolved_ns"
    if [[ -z "$flag_services" && ${#_SCAN_SERVICES[@]} -gt 0 ]]; then
      selected_services=("${_SCAN_SERVICES[@]}")
    fi
  fi

  # ── Dev stack: detect start commands ──
  if [[ "${stack:-}" == "dev" ]]; then
    _scan_detect_dev_cmds "$project_path"
    mkdir -p "${project_path}/.muster/pids"
  fi

  # ── Parse explicit services ──
  if [[ -n "$flag_services" ]]; then
    selected_services=()
    local IFS=','
    for s in $flag_services; do
      selected_services[${#selected_services[@]}]="$s"
    done
  fi

  # Default stack
  [[ -z "$stack" ]] && stack="bare"

  # Validate
  if [[ ${#selected_services[@]} -eq 0 ]]; then
    err "No services specified. Use --services or --scan to detect them."
    return 1
  fi

  # Validate stack value
  case "$stack" in
    k8s|compose|docker|bare|dev) ;;
    *)
      err "Invalid stack: $stack (must be k8s, compose, docker, bare, or dev)"
      return 1
      ;;
  esac

  # ── Deploy order ──
  local ordered_services=()
  if [[ -n "$flag_order" ]]; then
    local IFS=','
    for s in $flag_order; do
      ordered_services[${#ordered_services[@]}]="$s"
    done
  else
    # Smart ordering: infra services first, then app services
    local _infra_order=()
    local _app_order=()
    local _si=0
    while (( _si < ${#selected_services[@]} )); do
      if _is_infra_service "${selected_services[$_si]}"; then
        _infra_order[${#_infra_order[@]}]="${selected_services[$_si]}"
      else
        _app_order[${#_app_order[@]}]="${selected_services[$_si]}"
      fi
      _si=$((_si + 1))
    done
    # Infra first, then app services
    local _oi=0
    while (( _oi < ${#_infra_order[@]} )); do
      ordered_services[${#ordered_services[@]}]="${_infra_order[$_oi]}"
      _oi=$((_oi + 1))
    done
    _oi=0
    while (( _oi < ${#_app_order[@]} )); do
      ordered_services[${#ordered_services[@]}]="${_app_order[$_oi]}"
      _oi=$((_oi + 1))
    done
  fi

  # ── Project name ──
  local project_name="${flag_name:-$(basename "$project_path")}"

  # ── Build health map from --health flags ──
  # _FLAG_HEALTH[] contains "svc=type:arg:arg" entries
  # Build parallel arrays for lookup
  local _h_keys=()
  local _h_vals=()
  local hi=0
  while (( hi < ${#_FLAG_HEALTH[@]} )); do
    local spec="${_FLAG_HEALTH[$hi]}"
    local h_svc="${spec%%=*}"
    local h_rest="${spec#*=}"
    _h_keys[${#_h_keys[@]}]="$h_svc"
    _h_vals[${#_h_vals[@]}]="$h_rest"
    hi=$((hi + 1))
  done

  # ── Build creds map from --creds flags ──
  local _c_keys=()
  local _c_vals=()
  local ci=0
  while (( ci < ${#_FLAG_CREDS[@]} )); do
    local spec="${_FLAG_CREDS[$ci]}"
    local c_svc="${spec%%=*}"
    local c_rest="${spec#*=}"
    _c_keys[${#_c_keys[@]}]="$c_svc"
    _c_vals[${#_c_vals[@]}]="$c_rest"
    ci=$((ci + 1))
  done

  # ── Build remote map from --remote flags ──
  # Format: svc=user@host[:port][:path]
  local _r_keys=()
  local _r_vals=()
  local ri=0
  while (( ri < ${#_FLAG_REMOTE[@]} )); do
    local spec="${_FLAG_REMOTE[$ri]}"
    local r_svc="${spec%%=*}"
    local r_rest="${spec#*=}"
    _r_keys[${#_r_keys[@]}]="$r_svc"
    _r_vals[${#_r_vals[@]}]="$r_rest"
    ri=$((ri + 1))
  done

  # ── Build git-pull map from --git-pull flags ──
  # Format: svc[=remote:branch]  (defaults: origin:main)
  local _gp_keys=()
  local _gp_vals=()
  local gpi=0
  while (( gpi < ${#_FLAG_GIT_PULL[@]} )); do
    local spec="${_FLAG_GIT_PULL[$gpi]}"
    local gp_svc="${spec%%=*}"
    local gp_rest="${spec#*=}"
    [[ "$gp_rest" == "$spec" ]] && gp_rest=""
    _gp_keys[${#_gp_keys[@]}]="$gp_svc"
    _gp_vals[${#_gp_vals[@]}]="$gp_rest"
    gpi=$((gpi + 1))
  done

  # ── Build services JSON ──
  local services_json="{"
  local deploy_order_json="["
  local first=true

  for svc in "${ordered_services[@]}"; do
    local key
    key=$(_svc_to_key "$svc")

    # Look up health for this service (explicit --health flags first)
    local health_json="{\"enabled\":false}"
    local found_explicit=false
    local li=0
    while (( li < ${#_h_keys[@]} )); do
      if [[ "${_h_keys[$li]}" == "$svc" || "${_h_keys[$li]}" == "$key" ]]; then
        found_explicit=true
        local h_spec="${_h_vals[$li]}"
        local h_type="${h_spec%%:*}"
        local h_args="${h_spec#*:}"

        case "$h_type" in
          http)
            local h_endpoint="${h_args%%:*}"
            local h_port="${h_args#*:}"
            [[ -z "$h_endpoint" ]] && h_endpoint="/health"
            [[ -z "$h_port" || "$h_port" == "$h_endpoint" ]] && h_port="8080"
            health_json="{\"type\":\"http\",\"endpoint\":\"${h_endpoint}\",\"port\":${h_port},\"timeout\":10,\"enabled\":true}"
            ;;
          tcp)
            local h_port="${h_args}"
            [[ -z "$h_port" ]] && h_port="0"
            health_json="{\"type\":\"tcp\",\"port\":${h_port},\"timeout\":5,\"enabled\":true}"
            ;;
          command)
            local h_cmd="${h_args}"
            health_json="{\"type\":\"command\",\"command\":\"${h_cmd}\",\"timeout\":10,\"enabled\":true}"
            ;;
          none)
            health_json="{\"enabled\":false}"
            ;;
        esac
        break
      fi
      li=$((li + 1))
    done

    # Fallback: auto-detect health from k8s cluster scan
    if [[ "$found_explicit" == "false" ]]; then
      local auto_health=""
      auto_health=$(scan_get_health "$svc")
      [[ -z "$auto_health" ]] && auto_health=$(scan_get_health "$key")
      if [[ -n "$auto_health" ]]; then
        local ah_type="${auto_health%%|*}"
        local ah_rest="${auto_health#*|}"
        local ah_endpoint="${ah_rest%%|*}"
        local ah_port="${ah_rest#*|}"
        case "$ah_type" in
          http)
            [[ -z "$ah_endpoint" ]] && ah_endpoint="/health"
            [[ -z "$ah_port" ]] && ah_port="8080"
            health_json="{\"type\":\"http\",\"endpoint\":\"${ah_endpoint}\",\"port\":${ah_port},\"timeout\":10,\"enabled\":true}"
            ;;
          tcp)
            [[ -z "$ah_port" ]] && ah_port="0"
            health_json="{\"type\":\"tcp\",\"port\":${ah_port},\"timeout\":5,\"enabled\":true}"
            ;;
          command)
            health_json="{\"type\":\"command\",\"command\":\"${ah_endpoint}\",\"timeout\":10,\"enabled\":true}"
            ;;
        esac
      fi
    fi

    # Look up creds for this service
    local cred_mode="off"
    li=0
    while (( li < ${#_c_keys[@]} )); do
      if [[ "${_c_keys[$li]}" == "$svc" || "${_c_keys[$li]}" == "$key" ]]; then
        cred_mode="${_c_vals[$li]}"
        break
      fi
      li=$((li + 1))
    done

    # Validate cred mode
    case "$cred_mode" in
      off|save|session|always) ;;
      *) cred_mode="off" ;;
    esac

    # Look up remote for this service
    local remote_json=""
    li=0
    while (( li < ${#_r_keys[@]} )); do
      if [[ "${_r_keys[$li]}" == "$svc" || "${_r_keys[$li]}" == "$key" ]]; then
        local r_spec="${_r_vals[$li]}"
        # Parse user@host[:port][:path]
        local r_user="${r_spec%%@*}"
        local r_after_user="${r_spec#*@}"
        local r_host="" r_port="22" r_project_dir=""

        # Split on colons: host[:port][:path]
        # host is everything up to the first colon (or the whole string)
        r_host="${r_after_user%%:*}"
        local r_remainder="${r_after_user#*:}"

        if [[ "$r_remainder" != "$r_after_user" ]]; then
          # There was at least one colon after host
          local r_first_part="${r_remainder%%:*}"
          local r_second_remainder="${r_remainder#*:}"

          if [[ "$r_first_part" == /* ]]; then
            # First part starts with / — it's a path, no port
            r_project_dir="$r_first_part"
          else
            # First part is a port number
            r_port="$r_first_part"
            # Check for a second part (path)
            if [[ "$r_second_remainder" != "$r_remainder" ]]; then
              r_project_dir="$r_second_remainder"
            fi
          fi
        fi

        remote_json=",\"remote\":{\"enabled\":true,\"host\":\"${r_host}\",\"user\":\"${r_user}\",\"port\":${r_port}"
        if [[ -n "$r_project_dir" ]]; then
          remote_json="${remote_json},\"project_dir\":\"${r_project_dir}\""
        fi
        remote_json="${remote_json}}"
        break
      fi
      li=$((li + 1))
    done

    local display_name
    display_name=$(_friendly_name "$svc")

    # Build k8s config block if stack is k8s
    local k8s_json=""
    local skip_deploy_json=""
    if [[ "$stack" == "k8s" ]]; then
      local _k8s_deploy _k8s_ns
      _k8s_deploy=$(scan_get_k8s_name "$svc")
      [[ -z "$_k8s_deploy" || "$_k8s_deploy" == "$svc" ]] && _k8s_deploy=$(scan_get_k8s_name "$key")
      [[ -z "$_k8s_deploy" || "$_k8s_deploy" == "$key" ]] && _k8s_deploy="$svc"
      _k8s_ns="${_SCAN_K8S_NS:-${flag_namespace:-default}}"
      k8s_json=",\"k8s\":{\"deployment\":\"${_k8s_deploy}\",\"namespace\":\"${_k8s_ns}\"}"

      # Auto skip_deploy if live scan ran but didn't find this service as a deployment
      if [[ ${#_SCAN_K8S_NAMES[@]} -gt 0 ]]; then
        if ! scan_has_k8s_deployment "$svc" && ! scan_has_k8s_deployment "$key"; then
          skip_deploy_json=",\"skip_deploy\":true"
        fi
      fi
    fi

    # Build git_pull config from --git-pull flags
    local git_pull_json=""
    li=0
    while (( li < ${#_gp_keys[@]} )); do
      if [[ "${_gp_keys[$li]}" == "$svc" || "${_gp_keys[$li]}" == "$key" ]]; then
        local gp_spec="${_gp_vals[$li]}"
        local gp_remote="origin"
        local gp_branch="main"
        if [[ -n "$gp_spec" ]]; then
          gp_remote="${gp_spec%%:*}"
          gp_branch="${gp_spec#*:}"
          [[ "$gp_branch" == "$gp_remote" ]] && gp_branch="main"
        fi
        git_pull_json=",\"git_pull\":{\"enabled\":true,\"remote\":\"${gp_remote}\",\"branch\":\"${gp_branch}\"}"
        break
      fi
      li=$((li + 1))
    done

    [[ "$first" == "true" ]] && first=false || services_json+=","
    services_json+="\"${key}\":{\"name\":\"${display_name}\",\"health\":${health_json},\"credentials\":{\"mode\":\"${cred_mode}\"}${remote_json}${k8s_json}${skip_deploy_json}${git_pull_json}}"
    deploy_order_json+="\"${key}\","
  done

  services_json+="}"
  deploy_order_json="${deploy_order_json%,}]"

  # ── Generate files ──
  local config_path="${project_path}/muster.json"
  local muster_dir="${project_path}/.muster"

  mkdir -p "${muster_dir}/hooks"
  mkdir -p "${muster_dir}/logs"
  mkdir -p "${muster_dir}/skills"

  # Resolve detected paths for template generation
  local _detected_compose _detected_dockerfile _detected_k8s
  _detected_compose=$(scan_get_compose_file)
  local _ns="${_SCAN_K8S_NS:-${flag_namespace:-default}}"
  for svc in "${ordered_services[@]}"; do
    local key
    key=$(_svc_to_key "$svc")
    local hook_dir="${muster_dir}/hooks/${key}"
    mkdir -p "$hook_dir"
    _detected_dockerfile=$(scan_get_path "$svc" "dockerfile")
    _detected_k8s=$(scan_get_path "$svc" "k8s_dir")

    # Extract port from health spec for this service
    local _svc_port="8080"
    local _hi=0
    while (( _hi < ${#_h_keys[@]} )); do
      if [[ "${_h_keys[$_hi]}" == "$svc" || "${_h_keys[$_hi]}" == "$key" ]]; then
        local _h_spec="${_h_vals[$_hi]}"
        local _h_type="${_h_spec%%:*}"
        local _h_args="${_h_spec#*:}"
        case "$_h_type" in
          http)
            local _hp="${_h_args#*:}"
            [[ -n "$_hp" && "$_hp" != "${_h_args%%:*}" ]] && _svc_port="$_hp"
            ;;
          tcp)
            [[ -n "$_h_args" ]] && _svc_port="$_h_args"
            ;;
        esac
        break
      fi
      _hi=$((_hi + 1))
    done

    # Fallback: port from auto-detected k8s health
    if [[ "$_svc_port" == "8080" ]]; then
      local _auto_h=""
      _auto_h=$(scan_get_health "$svc")
      [[ -z "$_auto_h" ]] && _auto_h=$(scan_get_health "$key")
      if [[ -n "$_auto_h" ]]; then
        local _auto_port="${_auto_h##*|}"
        [[ -n "$_auto_port" ]] && _svc_port="$_auto_port"
      fi
    fi

    # Resolve real k8s deployment name (may differ from service key)
    local _k8s_deploy_name
    _k8s_deploy_name=$(scan_get_k8s_name "$svc")
    [[ -z "$_k8s_deploy_name" ]] && _k8s_deploy_name=$(scan_get_k8s_name "$key")
    [[ -z "$_k8s_deploy_name" || "$_k8s_deploy_name" == "$svc" ]] && _k8s_deploy_name="$svc"

    # Resolve dev start command + port
    local _start_cmd=""
    if [[ "$stack" == "dev" ]]; then
      _start_cmd=$(scan_get_dev_cmd "$svc")
      [[ -z "$_start_cmd" ]] && _start_cmd=$(scan_get_dev_cmd "$key")
      local _dev_port
      _dev_port=$(scan_get_dev_port "$svc")
      [[ -z "$_dev_port" ]] && _dev_port=$(scan_get_dev_port "$key")
      [[ -n "$_dev_port" ]] && _svc_port="$_dev_port"
    fi

    _setup_copy_hooks "$stack" "$key" "$svc" "$hook_dir" \
      "${_detected_compose:-docker-compose.yml}" \
      "${_detected_dockerfile:-Dockerfile}" \
      "${_detected_k8s:-k8s/${svc}/}" \
      "$_ns" "$_svc_port" "$_k8s_deploy_name" "$_start_cmd"
  done

  # Write deploy.json
  if has_cmd jq; then
    echo "{\"project\":\"${project_name}\",\"version\":\"1\",\"root\":\"${project_path}\",\"services\":${services_json},\"deploy_order\":${deploy_order_json},\"skills\":[]}" | jq '.' > "$config_path"
  elif has_cmd python3; then
    python3 -c "
import json, sys
data = json.loads(sys.argv[1])
print(json.dumps(data, indent=2))
" "{\"project\":\"${project_name}\",\"version\":\"1\",\"root\":\"${project_path}\",\"services\":${services_json},\"deploy_order\":${deploy_order_json},\"skills\":[]}" > "$config_path"
  else
    echo "{\"project\":\"${project_name}\",\"version\":\"1\",\"root\":\"${project_path}\",\"services\":${services_json},\"deploy_order\":${deploy_order_json},\"skills\":[]}" > "$config_path"
  fi

  # .gitignore
  local gitignore="${project_path}/.gitignore"
  if [[ -f "$gitignore" ]]; then
    grep -q '.muster/logs' "$gitignore" || echo '.muster/logs/' >> "$gitignore"
    grep -q '.muster/pids' "$gitignore" || echo '.muster/pids/' >> "$gitignore"
  else
    printf '%s\n%s\n' '.muster/logs/' '.muster/pids/' > "$gitignore"
  fi

  # ── Print summary (plain text, no TUI) ──
  local stack_display=""
  case "$stack" in
    k8s)     stack_display="Kubernetes" ;;
    compose) stack_display="Docker Compose" ;;
    docker)  stack_display="Docker" ;;
    bare)    stack_display="Bare metal" ;;
    dev)     stack_display="Local dev" ;;
  esac

  # Register project in global registry
  _registry_touch "$project_path"

  # Generate hook security manifest and lock hooks
  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  _hook_manifest_generate "$project_path"

  ok "Setup complete"

  # Check for build context overlaps in the new config
  source "$MUSTER_ROOT/lib/core/build_context.sh"
  _build_context_detect
  if (( ${#_BUILD_CONTEXT_ISSUES[@]} > 0 )); then
    echo ""
    local _bc_count=${#_BUILD_CONTEXT_ISSUES[@]}
    printf '  %b!%b Build context overlap detected — %d issue%s\n' \
      "${YELLOW}" "${RESET}" "$_bc_count" "$( (( _bc_count > 1 )) && echo s)"
    local _bi=0
    while (( _bi < _bc_count )); do
      local _bline="${_BUILD_CONTEXT_ISSUES[$_bi]}"
      local _bparent _bchild _bctx _bdir
      IFS='|' read -r _bparent _bchild _bctx _bdir <<< "$_bline"
      printf '    %b%s (%s) contains %s (%s/)%b\n' "${DIM}" "$_bparent" "$_bctx" "$_bchild" "$_bdir" "${RESET}"
      printf '    %b→ Add '\''%s'\'' to .dockerignore%b\n' "${DIM}" "$_bdir" "${RESET}"
      _bi=$(( _bi + 1 ))
    done
  fi

  echo ""
  echo "  Project:  ${project_name}"
  echo "  Root:     ${project_path}"
  echo "  Stack:    ${stack_display}"
  echo "  Config:   ${config_path}"
  echo ""
  echo "  Services:"
  for svc in "${ordered_services[@]}"; do
    local key
    key=$(_svc_to_key "$svc")
    echo "    ${svc}  →  .muster/hooks/${key}/"
  done
  echo ""
  echo "  Next: review hooks in .muster/hooks/ then run 'muster'"
}

# ══════════════════════════════════════════════════════════════
# Main setup command
# ══════════════════════════════════════════════════════════════
_FLAG_HEALTH=()
_FLAG_CREDS=()
_FLAG_REMOTE=()
_FLAG_GIT_PULL=()

cmd_setup() {
  # ── Parse flags ──
  local flag_path="" flag_scan="false" flag_stack="" flag_services=""
  local flag_order="" flag_name="" flag_force="false" flag_namespace=""
  _FLAG_HEALTH=()
  _FLAG_CREDS=()
  _FLAG_REMOTE=()
  _FLAG_GIT_PULL=()
  local has_flags=false

  while [[ $# -gt 0 ]]; do
    has_flags=true
    case "$1" in
      --path|-p)
        flag_path="$2"; shift 2 ;;
      --scan)
        flag_scan="true"; shift ;;
      --stack|-s)
        flag_stack="$2"; shift 2 ;;
      --services)
        flag_services="$2"; shift 2 ;;
      --order)
        flag_order="$2"; shift 2 ;;
      --health)
        _FLAG_HEALTH[${#_FLAG_HEALTH[@]}]="$2"; shift 2 ;;
      --creds)
        _FLAG_CREDS[${#_FLAG_CREDS[@]}]="$2"; shift 2 ;;
      --remote)
        _FLAG_REMOTE[${#_FLAG_REMOTE[@]}]="$2"; shift 2 ;;
      --git-pull)
        _FLAG_GIT_PULL[${#_FLAG_GIT_PULL[@]}]="$2"; shift 2 ;;
      --name|-n)
        flag_name="$2"; shift 2 ;;
      --namespace)
        flag_namespace="$2"; shift 2 ;;
      --force|-f)
        flag_force="true"; shift ;;
      --help|-h)
        echo "Usage: muster setup [flags]"
        echo ""
        echo "Without flags, runs the interactive setup wizard."
        echo ""
        echo "Flags:"
        echo "  --path, -p <dir>      Project directory (default: .)"
        echo "  --scan                Auto-detect stack and services from project files"
        echo "  --stack, -s <type>    Stack: k8s, compose, docker, bare, dev"
        echo "  --services <list>     Comma-separated service names"
        echo "  --order <list>        Comma-separated deploy order (default: services order)"
        echo "  --health <spec>       Per-service health: svc=type[:arg:arg] (repeatable)"
        echo "  --creds <spec>        Per-service credentials: svc=mode (repeatable)"
        echo "  --remote <spec>       Per-service remote: svc=user@host[:port][:path] (repeatable)"
        echo "  --git-pull <spec>     Per-service git pull: svc[=remote:branch] (repeatable)"
        echo "  --namespace <ns>      Kubernetes namespace (default: default)"
        echo "  --name, -n <name>     Project name (default: directory basename)"
        echo "  --force, -f           Overwrite existing muster.json without prompting"
        echo ""
        echo "Health spec examples:"
        echo "  --health api=http:/health:8080"
        echo "  --health redis=tcp:6379"
        echo "  --health worker=command:./check.sh"
        echo "  --health api=none"
        echo ""
        echo "Credential modes: off, save, session, always"
        echo ""
        echo "Git pull spec examples:"
        echo "  --git-pull api                           (defaults: origin/main)"
        echo "  --git-pull api=origin:main"
        echo "  --git-pull api=upstream:develop"
        echo ""
        echo "Remote spec examples:"
        echo "  --remote api=deploy@prod.example.com"
        echo "  --remote api=deploy@prod.example.com:2222"
        echo "  --remote api=deploy@prod.example.com:/opt/myapp"
        echo "  --remote api=deploy@prod.example.com:2222:/opt/myapp"
        echo ""
        echo "Examples:"
        echo "  muster setup --path /app --scan"
        echo "  muster setup --stack k8s --services api,redis --name myapp"
        echo "  muster setup --scan --health api=http:/health:3000 --name myapp"
        return 0
        ;;
      *)
        err "Unknown flag: $1"
        echo "Run 'muster setup --help' for usage."
        return 1
        ;;
    esac
  done

  # If flags were provided, run non-interactive
  if [[ "$has_flags" == "true" ]]; then
    [[ -z "$flag_path" ]] && flag_path="."
    _setup_noninteractive "$flag_path" "$flag_scan" "$flag_stack" "$flag_services" "$flag_order" "$flag_name" "$flag_force" "$flag_namespace"
    return $?
  fi

  # ── Interactive TUI wizard ──

  # ── Non-TTY guard: fail early if stdin is not a terminal ──
  if [[ ! -t 0 ]]; then
    err "Interactive setup requires a terminal (TTY)."
    echo "  For non-interactive usage, try:"
    echo "    muster setup --scan"
    echo "    muster setup --services api,redis --stack k8s"
    echo "  Run 'muster setup --help' for all options."
    return 1
  fi

  # ── Machine role ──
  local _existing_role=""
  _existing_role=$(global_config_get "machine_role" 2>/dev/null)
  [[ "$_existing_role" == "null" ]] && _existing_role=""

  local _setup_role="local"
  local _role_changed=true

  if [[ -n "$_existing_role" ]]; then
    # Show current role and offer to keep or change
    local _role_label=""
    case "$_existing_role" in
      local)   _role_label="Just this machine" ;;
      control) _role_label="Deploy to others" ;;
      target)  _role_label="Receive deploys" ;;
      both)    _role_label="Both (local + fleet control)" ;;
    esac

    clear
    echo ""
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}setup${RESET}"
    echo ""
    printf '%b\n' "  ${DIM}Current role: ${RESET}${BOLD}${_role_label}${RESET}"
    echo ""

    menu_select "Machine role" "Keep — ${_role_label}" "Change role"

    if [[ "$MENU_RESULT" == *"Keep"* ]]; then
      _setup_role="$_existing_role"
      _role_changed=false
    fi
  fi

  if [[ "$_role_changed" == "true" ]]; then
    clear
    echo ""
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}setup${RESET}"
    echo ""
    printf '%b\n' "  ${DIM}What will this machine do?${RESET}"
    echo ""

    menu_select "Role" \
      "Just this machine    — Set up and deploy locally" \
      "Deploy to others     — Configure fleet targets" \
      "Receive deploys      — Set up as a deploy target" \
      "Both (1 + 2)         — Local project + fleet control"

    case "$MENU_RESULT" in
      *"Deploy to others"*)
        _setup_role="control"
        ;;
      *"Receive deploys"*)
        _setup_role="target"
        ;;
      *"Both"*)
        _setup_role="both"
        ;;
      *)
        _setup_role="local"
        ;;
    esac

    global_config_set "machine_role" "\"$_setup_role\""
  fi

  # Route based on role
  case "$_setup_role" in
    control)
      # Launch fleet setup wizard
      if [[ -f "$MUSTER_ROOT/lib/commands/fleet_setup.sh" ]]; then
        source "$MUSTER_ROOT/lib/commands/fleet_setup.sh"
        cmd_fleet_setup
      else
        _setup_control_host
      fi
      return $?
      ;;
    target)
      _setup_deploy_target_intro
      # Falls through to project setup below
      ;;
    both)
      # Falls through to project setup below, then offers fleet config at the end
      ;;
  esac

  # ── Question 2: Environment ──
  local _setup_env="production"
  local _setup_health_timeout=10
  local _setup_cred_default="off"

  clear
  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}setup${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}What environment is this?${RESET}"
  echo ""

  menu_select_desc "Environment" \
    "Production" \
    "Live environment serving real users. Enables thorough health checks (30s timeout), session-based credentials for secrets, and deploy notifications." \
    "Staging" \
    "Pre-production environment that mirrors prod. Moderate health checks (15s timeout) and session credentials. Good for testing before going live." \
    "Development" \
    "Local development machine. Lightweight defaults — fast health checks (5s), no credentials, dev stack. Optimized for quick iteration."

  case "$MENU_RESULT" in
    *Production*)
      _setup_env="production"
      _setup_health_timeout=30
      _setup_cred_default="session"
      ;;
    *Staging*)
      _setup_env="staging"
      _setup_health_timeout=15
      _setup_cred_default="session"
      ;;
    *Development*)
      _setup_env="development"
      _setup_health_timeout=5
      _setup_cred_default="off"
      ;;
  esac

  # ── Question 3: What you're running ──
  clear
  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster${RESET} ${DIM}setup${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}What does this project run?  (select all that apply)${RESET}"
  echo ""

  checklist_select --none "Components" \
    "Web app / API" \
    "Background workers / queues" \
    "Database (managed here)" \
    "Cache (Redis, Memcached)" \
    "Reverse proxy (Nginx, Caddy)" \
    "Other"

  local _setup_components=()
  while IFS= read -r _comp; do
    [[ -n "$_comp" ]] && _setup_components[${#_setup_components[@]}]="$_comp"
  done <<< "$CHECKLIST_RESULT"

  # ── Step 1: Choose project location ──
  local _cwd_display
  _cwd_display="$(pwd)"
  _cwd_display="${_cwd_display/#$HOME/~}"

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 1 "Get started"

  menu_select "Where is your project?" "Setup here (${_cwd_display})" "Choose location" "Back"

  local project_path=""
  case "$MENU_RESULT" in
    "Back"|"__back__")
      return 0
      ;;
    "Choose location")
      _SETUP_CUR_SUMMARY=(
        ""
        "  ${DIM}Enter the path to your project directory (Tab to autocomplete)${RESET}"
        ""
      )
      _SETUP_CUR_PROMPT="false"
      _setup_screen 1 "Project location"
      _read_path "  > "
      project_path="$REPLY"

      case "$project_path" in
        [Bb][Aa][Cc][Kk]|[Hh][Oo][Mm][Ee]|[Qq][Uu][Ii][Tt]|[Ee][Xx][Ii][Tt]|[Qq]) return 0 ;;
      esac
      project_path="${project_path:-.}"
      ;;
    *)
      # "Setup here" — use current directory
      project_path="$(pwd)"
      ;;
  esac

  local _resolved_path
  _resolved_path="$(cd "$project_path" 2>/dev/null && pwd)" || {
    err "Path does not exist: $project_path"
    printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
    IFS= read -rsn1 || true
    return 0
  }
  project_path="$_resolved_path"

  # ── Check for existing config ──
  if [[ -f "${project_path}/muster.json" || -f "${project_path}/deploy.json" ]]; then
    _SETUP_CUR_SUMMARY=("")
    _setup_screen 1 "Existing config found"
    menu_select "Config already exists at ${project_path}. Overwrite?" "Overwrite" "Cancel"
    if [[ "$MENU_RESULT" == "Cancel" ]]; then
      info "Setup cancelled."
      return 0
    fi
  fi

  # ── Step 4: Scan + Smart Preview ──
  _SETUP_CUR_SUMMARY=("")
  _setup_screen 4 "Scanning project"
  echo ""
  start_spinner "Scanning ${project_path}..."
  scan_project "$project_path"

  # For dev environment, force dev stack
  if [[ "$_setup_env" == "development" && -z "$_SCAN_STACK" ]]; then
    _SCAN_STACK="dev"
  fi

  stop_spinner

  if (( ${#_SCAN_FILES[@]} > 0 || ${#_SCAN_SERVICES[@]} > 0 )); then
    # ────── Smart scan preview ──────
    local stack="$_SCAN_STACK"

    # Build preview display
    local stack_label=""
    case "$stack" in
      k8s)     stack_label="Kubernetes" ;;
      compose) stack_label="Docker Compose" ;;
      docker)  stack_label="Docker" ;;
      bare)    stack_label="Bare metal / Systemd" ;;
      dev)     stack_label="Local dev" ;;
      *)       stack_label="(not detected)" ;;
    esac

    # Build services display with ports
    local _svc_display=""
    local _si=0
    while (( _si < ${#_SCAN_SERVICES[@]} )); do
      local _sn="${_SCAN_SERVICES[$_si]}"
      local _sp
      _sp=$(scan_get_port "$_sn")
      if [[ -n "$_sp" ]]; then
        _svc_display="${_svc_display}${_sn} (port ${_sp})"
      else
        _svc_display="${_svc_display}${_sn}"
      fi
      _si=$((_si + 1))
      (( _si < ${#_SCAN_SERVICES[@]} )) && _svc_display="${_svc_display}, "
    done
    [[ -z "$_svc_display" ]] && _svc_display="(none detected)"

    # Build health display
    local _health_lines=""
    _si=0
    while (( _si < ${#_SCAN_HEALTH[@]} )); do
      local _he="${_SCAN_HEALTH[$_si]}"
      local _h_svc="${_he%%|*}"
      local _h_rest="${_he#*|}"
      local _h_type="${_h_rest%%|*}"
      _h_rest="${_h_rest#*|}"
      local _h_ep="${_h_rest%%|*}"
      local _h_port="${_h_rest#*|}"
      case "$_h_type" in
        http)    _health_lines="${_health_lines}\n              ${_h_svc} -> HTTP ${_h_ep}:${_h_port}" ;;
        tcp)     _health_lines="${_health_lines}\n              ${_h_svc} -> TCP :${_h_port}" ;;
        command) _health_lines="${_health_lines}\n              ${_h_svc} -> command" ;;
      esac
      _si=$((_si + 1))
    done

    # Build secrets display
    local _secrets_display=""
    if (( ${#_SCAN_SECRETS[@]} > 0 )); then
      _si=0
      while (( _si < ${#_SCAN_SECRETS[@]} )); do
        _secrets_display="${_secrets_display}${_SCAN_SECRETS[$_si]}"
        _si=$((_si + 1))
        (( _si < ${#_SCAN_SECRETS[@]} )) && _secrets_display="${_secrets_display}, "
      done
      _secrets_display="${_secrets_display} (from .env)"
    fi

    # Build git display
    local _git_display=""
    if [[ -n "$_SCAN_GIT_REMOTE" || -n "$_SCAN_GIT_BRANCH" ]]; then
      local _git_short=""
      if [[ -n "$_SCAN_GIT_REMOTE" ]]; then
        _git_short="${_SCAN_GIT_REMOTE##*/}"
        _git_short="${_git_short%.git}"
      fi
      _git_display="${_git_short:+${_git_short}/}${_SCAN_GIT_BRANCH:-main}"
    fi

    # Show scan preview
    local _preview_summary=(
      ""
      "  ${BOLD}Stack:${RESET}      ${stack_label}"
      "  ${BOLD}Services:${RESET}   ${_svc_display}"
    )
    if [[ -n "$_health_lines" ]]; then
      _preview_summary[${#_preview_summary[@]}]="  ${BOLD}Health:${RESET}     $(printf '%b' "$_health_lines" | head -1 | sed 's/^ *//')"
      # Additional health lines
      local _hl_idx=0
      while IFS= read -r _hl; do
        _hl_idx=$((_hl_idx + 1))
        (( _hl_idx <= 1 )) && continue
        [[ -n "$_hl" ]] && _preview_summary[${#_preview_summary[@]}]="  ${_hl}"
      done <<< "$(printf '%b' "$_health_lines")"
    fi
    if [[ -n "$_git_display" ]]; then
      _preview_summary[${#_preview_summary[@]}]="  ${BOLD}Git:${RESET}        ${_git_display}"
    fi
    if [[ -n "$_secrets_display" ]]; then
      _preview_summary[${#_preview_summary[@]}]="  ${BOLD}Secrets:${RESET}    ${_secrets_display}"
    fi
    _preview_summary[${#_preview_summary[@]}]=""

    _SETUP_CUR_SUMMARY=("${_preview_summary[@]}")
    _setup_screen 4 "Scan results"

    menu_select "This look right?" "Yes" "Let me adjust"

    local _auto_mode="true"
    if [[ "$MENU_RESULT" == "Let me adjust" ]]; then
      _auto_mode="false"
    fi

    # ── Stack override (if user wants to adjust or nothing detected) ──
    if [[ "$_auto_mode" == "false" || -z "$stack" ]]; then
      if [[ -n "$stack" && "$_auto_mode" == "false" ]]; then
        _SETUP_CUR_SUMMARY=("")
        _setup_screen 4 "Confirm stack"
        menu_select "Detected ${stack_label}. Correct?" "Yes" "No, let me pick"
        if [[ "$MENU_RESULT" == "No, let me pick" ]]; then
          stack=""
        fi
      fi
      if [[ -z "$stack" ]]; then
        _SETUP_CUR_SUMMARY=("")
        _setup_screen 4 "Select stack"
        menu_select "What deploys your services?" "Kubernetes" "Docker Compose" "Docker (standalone)" "Bare metal / Systemd" "Local dev"
        case "$MENU_RESULT" in
          Kubernetes)              stack="k8s" ;;
          "Docker Compose")        stack="compose" ;;
          "Docker (standalone)")   stack="docker" ;;
          "Bare metal / Systemd")  stack="bare" ;;
          "Local dev")             stack="dev" ;;
        esac
      fi
    fi

    # ── Service selection ──
    local selected_services=()
    if [[ "$_auto_mode" == "true" && ${#_SCAN_SERVICES[@]} -gt 0 ]]; then
      # Auto-mode: use all detected services
      local _si=0
      while (( _si < ${#_SCAN_SERVICES[@]} )); do
        selected_services[${#selected_services[@]}]="${_SCAN_SERVICES[$_si]}"
        _si=$((_si + 1))
      done
    elif (( ${#_SCAN_SERVICES[@]} > 0 )); then
      _SETUP_CUR_SUMMARY=("")
      _setup_screen 4 "Select services"
      checklist_select "Manage these services?" "${_SCAN_SERVICES[@]}"
      while IFS= read -r line; do
        [[ -n "$line" ]] && selected_services[${#selected_services[@]}]="$line"
      done <<< "$CHECKLIST_RESULT"
    else
      # No services detected, ask for names
      _SETUP_CUR_SUMMARY=(
        ""
        "  ${DIM}Enter service names separated by spaces${RESET}"
        "  ${DIM}Example: api worker redis${RESET}"
        ""
        "  ${ACCENT}>${RESET} "
      )
      _SETUP_CUR_PROMPT="true"
      _setup_screen 4 "Name your services"
      read -r svc_input
      _SETUP_CUR_PROMPT="false"
      for s in $svc_input; do
        selected_services[${#selected_services[@]}]="$s"
      done
    fi

    if [[ ${#selected_services[@]} -eq 0 ]]; then
      warn "No services selected."
      return 1
    fi

    # ── Step 5: Deploy order (auto-sort: infra first, then workers, then API/web) ──
    _SETUP_CUR_SUMMARY=("")
    _setup_screen 5 "Deploy order"

    if (( ${#selected_services[@]} > 1 )); then
      # Auto-sort: infra services first
      local _sorted_infra=()
      local _sorted_other=()
      local _si=0
      while (( _si < ${#selected_services[@]} )); do
        local _sn="${selected_services[$_si]}"
        if _is_infra_service "$_sn" 2>/dev/null; then
          _sorted_infra[${#_sorted_infra[@]}]="$_sn"
        else
          _sorted_other[${#_sorted_other[@]}]="$_sn"
        fi
        _si=$((_si + 1))
      done
      selected_services=("${_sorted_infra[@]}" "${_sorted_other[@]}")

      printf '\n  %b%s%b\n' "${DIM}" "Services that others depend on deploy first." "${RESET}"
      echo ""
      order_select "Deploy order" "${selected_services[@]}"
      selected_services=("${ORDER_RESULT[@]}")
    else
      printf '\n  %b1.%b %s\n' "${GREEN}" "${RESET}" "${selected_services[0]}"
    fi

    # ── Auto-config or manual per-service config ──
    local services_json="{"
    local deploy_order_json="["
    local first=true
    local svc_index=0
    local _svc_ports=()

    if [[ "$_auto_mode" == "true" ]]; then
      # ── Auto-config from scan results ──
      for svc in "${selected_services[@]}"; do
        svc_index=$((svc_index + 1))
        local key
        key=$(_svc_to_key "$svc")

        # Auto-detect health
        local health_json="{\"enabled\":false}"
        local port_num=""
        local _h_info
        _h_info=$(scan_get_health "$svc")
        if [[ -n "$_h_info" ]]; then
          local _h_type="${_h_info%%|*}"
          local _h_rest="${_h_info#*|}"
          local _h_ep="${_h_rest%%|*}"
          local _h_port="${_h_rest#*|}"
          port_num="${_h_port}"
          case "$_h_type" in
            http)    health_json="{\"type\":\"http\",\"endpoint\":\"${_h_ep}\",\"port\":${_h_port:-8080},\"timeout\":${_setup_health_timeout},\"enabled\":true}" ;;
            tcp)     health_json="{\"type\":\"tcp\",\"port\":${_h_port:-0},\"timeout\":${_setup_health_timeout},\"enabled\":true}" ;;
            command) health_json="{\"type\":\"command\",\"command\":\"${_h_ep}\",\"timeout\":${_setup_health_timeout},\"enabled\":true}" ;;
          esac
        else
          # Try port-based detection
          port_num=$(scan_get_port "$svc")
          if [[ -n "$port_num" ]]; then
            if _is_infra_service "$svc" 2>/dev/null; then
              health_json="{\"type\":\"tcp\",\"port\":${port_num},\"timeout\":${_setup_health_timeout},\"enabled\":true}"
            else
              health_json="{\"type\":\"http\",\"endpoint\":\"/health\",\"port\":${port_num},\"timeout\":${_setup_health_timeout},\"enabled\":true}"
            fi
          fi
        fi
        _svc_ports[${#_svc_ports[@]}]="${port_num:-8080}"

        # Auto-credentials from environment + secrets
        local cred_mode="$_setup_cred_default"
        if [[ "$cred_mode" == "session" && ${#_SCAN_SECRETS[@]} -eq 0 ]]; then
          cred_mode="off"
        fi
        # Infra services don't need credentials
        if _is_infra_service "$svc" 2>/dev/null; then
          cred_mode="off"
        fi

        # Auto git pull
        local git_pull_json=""
        if [[ -n "$_SCAN_GIT_REMOTE" && -n "$_SCAN_GIT_BRANCH" ]]; then
          # Only enable for non-infra services
          if ! _is_infra_service "$svc" 2>/dev/null; then
            git_pull_json=",\"git_pull\":{\"enabled\":true,\"remote\":\"origin\",\"branch\":\"${_SCAN_GIT_BRANCH}\"}"
          fi
        fi

        [[ "$first" == "true" ]] && first=false || services_json+=","
        services_json+="\"${key}\":{\"name\":\"${svc}\",\"health\":${health_json},\"credentials\":{\"mode\":\"${cred_mode}\"}${git_pull_json}}"
        deploy_order_json+="\"${key}\","
      done
    else
      # ── Manual per-service config (existing flow) ──
      for svc in "${selected_services[@]}"; do
        svc_index=$((svc_index + 1))
        local key
        key=$(_svc_to_key "$svc")

        # Pre-fill from scan
        local _prefill_health="" _prefill_port=""
        _prefill_health=$(scan_get_health "$svc")
        _prefill_port=$(scan_get_port "$svc")

        # Health check
        _SETUP_CUR_SUMMARY=("")
        _setup_screen 5 "Configure ${svc} (${svc_index}/${#selected_services[@]})"
        menu_select "Health check for ${svc}?" "HTTP" "TCP" "Command" "None"
        local health_choice="$MENU_RESULT"

        local health_json="{}"
        local port_num=""
        case "$health_choice" in
          HTTP)
            local _def_ep="/health" _def_port="${_prefill_port:-8080}"
            if [[ -n "$_prefill_health" ]]; then
              local _pht="${_prefill_health%%|*}"
              local _phr="${_prefill_health#*|}"
              if [[ "$_pht" == "http" ]]; then
                _def_ep="${_phr%%|*}"
                _def_port="${_phr#*|}"
              fi
            fi
            printf "\n  ${ACCENT}>${RESET} Health endpoint [${_def_ep}]: "
            read -r endpoint
            printf "  ${ACCENT}>${RESET} Port [${_def_port}]: "
            read -r port_num
            health_json="{\"type\":\"http\",\"endpoint\":\"${endpoint:-$_def_ep}\",\"port\":${port_num:-$_def_port},\"timeout\":${_setup_health_timeout},\"enabled\":true}"
            ;;
          TCP)
            printf "\n  ${ACCENT}>${RESET} Port [${_prefill_port:-0}]: "
            read -r port_num
            health_json="{\"type\":\"tcp\",\"port\":${port_num:-${_prefill_port:-0}},\"timeout\":${_setup_health_timeout},\"enabled\":true}"
            ;;
          Command)
            printf "\n  ${ACCENT}>${RESET} Health command: "
            read -r health_cmd
            health_json="{\"type\":\"command\",\"command\":\"${health_cmd}\",\"timeout\":${_setup_health_timeout},\"enabled\":true}"
            ;;
          None)
            health_json="{\"enabled\":false}"
            ;;
        esac
        _svc_ports[${#_svc_ports[@]}]="${port_num:-${_prefill_port:-8080}}"

        # Credentials
        _SETUP_CUR_SUMMARY=(
          ""
          "  ${GREEN}*${RESET} Health: ${health_choice}"
        )
        _setup_screen 5 "Configure ${svc} (${svc_index}/${#selected_services[@]})"
        menu_select "Credentials for ${svc}?" "None" "Save always (keychain)" "Once per session" "Every time"
        local cred_choice="$MENU_RESULT"

        local cred_mode="off"
        case "$cred_choice" in
          "Save always (keychain)") cred_mode="save" ;;
          "Once per session")       cred_mode="session" ;;
          "Every time")             cred_mode="always" ;;
        esac

        # Git pull
        local _def_remote="origin"
        local _def_branch="${_SCAN_GIT_BRANCH:-main}"
        _SETUP_CUR_SUMMARY=(
          ""
          "  ${GREEN}*${RESET} Health: ${health_choice}"
          "  ${GREEN}*${RESET} Credentials: ${cred_choice}"
        )
        _setup_screen 5 "Configure ${svc} (${svc_index}/${#selected_services[@]})"
        menu_select "Auto git pull before deploy for ${svc}?" "No" "Yes"
        local gp_choice="$MENU_RESULT"
        local git_pull_json=""
        if [[ "$gp_choice" == "Yes" ]]; then
          printf '\n  %b>%b Git remote [%s]: ' "${ACCENT}" "${RESET}" "$_def_remote"
          local _gp_remote_in=""
          IFS= read -r _gp_remote_in
          printf '  %b>%b Git branch [%s]: ' "${ACCENT}" "${RESET}" "$_def_branch"
          local _gp_branch_in=""
          IFS= read -r _gp_branch_in
          [[ -z "$_gp_remote_in" ]] && _gp_remote_in="$_def_remote"
          [[ -z "$_gp_branch_in" ]] && _gp_branch_in="$_def_branch"
          git_pull_json=",\"git_pull\":{\"enabled\":true,\"remote\":\"${_gp_remote_in}\",\"branch\":\"${_gp_branch_in}\"}"
        fi

        [[ "$first" == "true" ]] && first=false || services_json+=","
        services_json+="\"${key}\":{\"name\":\"${svc}\",\"health\":${health_json},\"credentials\":{\"mode\":\"${cred_mode}\"}${git_pull_json}}"
        deploy_order_json+="\"${key}\","
      done
    fi

    services_json+="}"
    deploy_order_json="${deploy_order_json%,}]"

    # ── Step 6: Review screen ──
    local project_name
    project_name=$(basename "$project_path")

    local stack_display=""
    case "$stack" in
      k8s)     stack_display="Kubernetes" ;;
      compose) stack_display="Docker Compose" ;;
      docker)  stack_display="Docker" ;;
      bare)    stack_display="Bare metal" ;;
      dev)     stack_display="Local dev" ;;
    esac

    local _review_summary=(
      ""
      "  ${BOLD}Project:${RESET}    ${project_name} (${_setup_env})"
      "  ${BOLD}Stack:${RESET}      ${stack_display}"
      ""
    )

    # Show per-service config in review
    local _ri=0
    for svc in "${selected_services[@]}"; do
      _ri=$((_ri + 1))
      local _rh=""
      _rh=$(scan_get_health "$svc")
      local _rh_display="none"
      if [[ -n "$_rh" ]]; then
        local _rht="${_rh%%|*}"
        local _rhr="${_rh#*|}"
        case "$_rht" in
          http) _rh_display="HTTP ${_rhr%%|*}:${_rhr#*|}" ;;
          tcp)  _rh_display="TCP :${_rhr#*|}" ;;
          command) _rh_display="command" ;;
        esac
      else
        local _rp
        _rp=$(scan_get_port "$svc")
        if [[ -n "$_rp" ]]; then
          if _is_infra_service "$svc" 2>/dev/null; then
            _rh_display="TCP :${_rp}"
          else
            _rh_display="HTTP /health:${_rp}"
          fi
        fi
      fi
      local _infra_tag=""
      _is_infra_service "$svc" 2>/dev/null && _infra_tag=" ${DIM}(infra)${RESET}"
      _review_summary[${#_review_summary[@]}]="  ${_ri}. ${BOLD}${svc}${RESET}    ${_rh_display}${_infra_tag}"
    done

    if [[ -n "$_SCAN_GIT_BRANCH" ]]; then
      _review_summary[${#_review_summary[@]}]=""
      _review_summary[${#_review_summary[@]}]="  ${BOLD}Git pull:${RESET}   origin/${_SCAN_GIT_BRANCH}"
    fi

    _review_summary[${#_review_summary[@]}]=""

    _SETUP_CUR_SUMMARY=("${_review_summary[@]}")
    _setup_screen 6 "Review"

    menu_select "Ready?" "Generate" "Go back"

    if [[ "$MENU_RESULT" == "Go back" || "$MENU_RESULT" == "__back__" ]]; then
      info "Setup cancelled."
      return 0
    fi

    # ── Hook format (offer justfile if just is installed) ──
    local _hook_format="bash"
    if has_cmd just; then
      _SETUP_CUR_SUMMARY=("")
      _setup_screen 7 "Hook format"
      menu_select "Hook format?" "Bash scripts (default)" "Justfile"
      case "$MENU_RESULT" in
        "Justfile") _hook_format="just" ;;
      esac
    fi

    # ── Step 7: Generate ──
    local config_path="${project_path}/muster.json"
    local muster_dir="${project_path}/.muster"

    mkdir -p "${muster_dir}/hooks"
    mkdir -p "${muster_dir}/logs"
    mkdir -p "${muster_dir}/skills"
    [[ "$stack" == "dev" ]] && mkdir -p "${muster_dir}/pids"

    # Dev stack: detect start commands
    if [[ "$stack" == "dev" ]]; then
      _scan_detect_dev_cmds "$project_path"
    fi

    # Copy template hooks for each service, using real detected paths
    local generated_hooks=()
    local _detected_compose _detected_dockerfile _detected_k8s
    _detected_compose=$(scan_get_compose_file)
    local _si=0
    for svc in "${selected_services[@]}"; do
      local key
      key=$(_svc_to_key "$svc")
      local hook_dir="${muster_dir}/hooks/${key}"
      mkdir -p "$hook_dir"
      _detected_dockerfile=$(scan_get_path "$svc" "dockerfile")
      _detected_k8s=$(scan_get_path "$svc" "k8s_dir")
      local _start_cmd_i=""
      if [[ "$stack" == "dev" ]]; then
        _start_cmd_i=$(scan_get_dev_cmd "$svc")
        [[ -z "$_start_cmd_i" ]] && _start_cmd_i=$(scan_get_dev_cmd "$key")
      fi
      if [[ "$_hook_format" == "just" ]]; then
        _setup_copy_justfile "$key" "$svc" "$hook_dir" "${_svc_ports[$_si]:-8080}"
      else
        _setup_copy_hooks "$stack" "$key" "$svc" "$hook_dir" \
          "${_detected_compose:-docker-compose.yml}" \
          "${_detected_dockerfile:-Dockerfile}" \
          "${_detected_k8s:-k8s/${svc}/}" \
          "default" "${_svc_ports[$_si]:-8080}" \
          "$(scan_get_k8s_name "$svc")" "$_start_cmd_i"
      fi
      generated_hooks[${#generated_hooks[@]}]=".muster/hooks/${key}/"
      _si=$((_si + 1))
    done

    # Write deploy.json
    if has_cmd jq; then
      echo "{\"project\":\"${project_name}\",\"version\":\"1\",\"root\":\"${project_path}\",\"services\":${services_json},\"deploy_order\":${deploy_order_json},\"skills\":[]}" | jq '.' > "$config_path"
    elif has_cmd python3; then
      python3 -c "
import json, sys
data = json.loads(sys.argv[1])
print(json.dumps(data, indent=2))
" "{\"project\":\"${project_name}\",\"version\":\"1\",\"root\":\"${project_path}\",\"services\":${services_json},\"deploy_order\":${deploy_order_json},\"skills\":[]}" > "$config_path"
    else
      echo "{\"project\":\"${project_name}\",\"version\":\"1\",\"root\":\"${project_path}\",\"services\":${services_json},\"deploy_order\":${deploy_order_json},\"skills\":[]}" > "$config_path"
    fi

    # .gitignore
    local gitignore="${project_path}/.gitignore"
    if [[ -f "$gitignore" ]]; then
      grep -q '.muster/logs' "$gitignore" || echo '.muster/logs/' >> "$gitignore"
      grep -q '.muster/pids' "$gitignore" || echo '.muster/pids/' >> "$gitignore"
    else
      printf '%s\n%s\n' '.muster/logs/' '.muster/pids/' > "$gitignore"
    fi

    # Register project in global registry
    _registry_touch "$project_path"

    # ── Context-aware post-setup ──
    local _post_summary=(
      ""
      "  ${GREEN}*${RESET} Project: ${BOLD}${project_name}${RESET} (${_setup_env})"
      "  ${GREEN}*${RESET} Stack:   ${stack_display}"
      "  ${GREEN}*${RESET} Config:  muster.json"
      ""
      "  ${BOLD}Generated:${RESET}"
    )

    for h in "${generated_hooks[@]}"; do
      local hook_path="${muster_dir}/hooks/${h##*.muster/hooks/}"
      local hook_files=""
      for hf in "${hook_path}"*.sh; do
        [[ -f "$hf" ]] && hook_files="${hook_files} $(basename "$hf")"
      done
      _post_summary[${#_post_summary[@]}]="    ${h}  ${DIM}${hook_files}${RESET}"
    done

    _post_summary[${#_post_summary[@]}]=""
    _post_summary[${#_post_summary[@]}]="  ${ACCENT}Next:${RESET}"
    _post_summary[${#_post_summary[@]}]="    ${BOLD}muster${RESET}              Open the dashboard"
    _post_summary[${#_post_summary[@]}]="    ${BOLD}muster deploy${RESET}       Deploy all services"
    _post_summary[${#_post_summary[@]}]="    ${BOLD}muster doctor${RESET}       Check everything is ready"

    # Notifications tip
    _post_summary[${#_post_summary[@]}]=""
    _post_summary[${#_post_summary[@]}]="  ${DIM}Deploy notifications (Discord, Slack, etc.):${RESET}"
    _post_summary[${#_post_summary[@]}]="    ${BOLD}muster skill add discord${RESET}"

    # Fleet tip
    _post_summary[${#_post_summary[@]}]=""
    _post_summary[${#_post_summary[@]}]="  ${DIM}Deploying to multiple machines?${RESET}"
    _post_summary[${#_post_summary[@]}]="    ${BOLD}muster fleet setup${RESET}  Set up fleet deployment"

    _post_summary[${#_post_summary[@]}]=""

    # Production-specific tips
    if [[ "$_setup_env" == "production" || "$_setup_env" == "staging" ]]; then
      _post_summary[${#_post_summary[@]}]="  ${ACCENT}Tips:${RESET}"
      # Check for .dockerignore
      if [[ ! -f "${project_path}/.dockerignore" ]] && [[ "$stack" == "compose" || "$stack" == "docker" ]]; then
        _post_summary[${#_post_summary[@]}]="    ${BOLD}!${RESET} No .dockerignore found — recommended for faster builds"
      fi
      _post_summary[${#_post_summary[@]}]="    ${DIM}* Health timeout set to ${_setup_health_timeout}s for ${_setup_env}${RESET}"
      _post_summary[${#_post_summary[@]}]="    ${DIM}* Run 'muster doctor' to verify${RESET}"
      _post_summary[${#_post_summary[@]}]=""
    fi

    _SETUP_CUR_SUMMARY=("${_post_summary[@]}")
    _setup_screen 7 "Setup complete"

    # Production: offer dry-run
    if [[ "$_setup_env" == "production" ]]; then
      menu_select "Preview your first deploy?" "Yes (dry-run)" "Later"
      if [[ "$MENU_RESULT" == *"dry-run"* ]]; then
        source "$MUSTER_ROOT/lib/commands/deploy.sh"
        cmd_deploy --dry-run
      fi
    elif [[ "$_setup_env" == "development" ]]; then
      printf '%b\n' "  ${DIM}Run '${BOLD}muster dev${RESET}${DIM}' to start everything.${RESET}"
      echo ""
      printf '%b\n' "  ${DIM}Press enter to exit${RESET}"
      read -rs
    else
      printf '%b\n' "  ${DIM}Press enter to exit${RESET}"
      read -rs
    fi

    # ── Offer to add project to a fleet group ──
    if has_cmd jq && [[ -f "$HOME/.muster/groups.json" ]]; then
      local _grp_count
      _grp_count=$(jq '.groups | length' "$HOME/.muster/groups.json" 2>/dev/null)
      if [[ -n "$_grp_count" && "$_grp_count" != "0" ]]; then
        echo ""
        printf '%b\n' "  ${DIM}You have fleet groups configured. Add this project to one?${RESET}"
        echo ""
        local _grp_options=()
        local _grp_keys=()
        local _gi=0
        while (( _gi < _grp_count )); do
          local _gk _gd
          _gk=$(jq -r ".groups | keys[$_gi]" "$HOME/.muster/groups.json")
          _gd=$(jq -r --arg g "$_gk" '.groups[$g].name // $g' "$HOME/.muster/groups.json")
          _grp_keys[${#_grp_keys[@]}]="$_gk"
          _grp_options[${#_grp_options[@]}]="$_gd"
          _gi=$(( _gi + 1 ))
        done
        _grp_options[${#_grp_options[@]}]="Skip"
        menu_select "Add to fleet" "${_grp_options[@]}"
        if [[ "$MENU_RESULT" != "Skip" && "$MENU_RESULT" != "__back__" ]]; then
          local _gmi=0
          while (( _gmi < ${#_grp_keys[@]} )); do
            local _gmd
            _gmd=$(jq -r --arg g "${_grp_keys[$_gmi]}" '.groups[$g].name // $g' "$HOME/.muster/groups.json")
            if [[ "$MENU_RESULT" == "$_gmd" ]]; then
              source "$MUSTER_ROOT/lib/core/groups.sh"
              groups_add_local "${_grp_keys[$_gmi]}" "$project_path" 2>/dev/null && \
                ok "Added to fleet: ${MENU_RESULT}" || true
              break
            fi
            _gmi=$(( _gmi + 1 ))
          done
        fi
      fi
    fi

    # ── "Both" role: offer fleet control setup after project is complete ──
    if [[ "$_setup_role" == "both" ]]; then
      echo ""
      printf '%b\n' "  ${DIM}Project setup done. Now let's configure fleet deployment.${RESET}"
      echo ""
      printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
      IFS= read -rsn1 || true
      if [[ -f "$MUSTER_ROOT/lib/commands/fleet_setup.sh" ]]; then
        source "$MUSTER_ROOT/lib/commands/fleet_setup.sh"
        cmd_fleet_setup
      else
        _setup_control_host
      fi
      return $?
    fi

  else
    # ────── Fallback: manual question flow ──────
    _setup_manual_flow

    # ── "Both" role: offer fleet control after manual setup too ──
    if [[ "$_setup_role" == "both" ]]; then
      echo ""
      printf '%b\n' "  ${DIM}Project setup done. Now let's configure fleet control.${RESET}"
      echo ""
      printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
      IFS= read -rsn1 || true
      _setup_control_host
      return $?
    fi
  fi
}

# ══════════════════════════════════════════════════════════════
# Manual fallback (no files detected)
# ══════════════════════════════════════════════════════════════
_setup_manual_flow() {
  info "No project files detected. Let's set things up manually."
  echo ""
  sleep 1

  # ── Step 3: Stack questions ──
  local has_db="no" db_type="" has_api="no" api_type=""
  local has_workers="no" has_proxy="no" stack="bare"

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 3 "Your stack"
  menu_select "Do you manage a database here?" "Yes" "No"
  if [[ "$MENU_RESULT" == "Yes" ]]; then
    has_db="yes"
    _SETUP_CUR_SUMMARY=("")
    _setup_screen 3 "Your stack"
    menu_select "What kind of database?" "PostgreSQL" "MySQL" "Redis" "MongoDB" "SQLite" "Other"
    db_type="$MENU_RESULT"
  fi

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 3 "Your stack"
  menu_select "Do you have a web server or API?" "Yes" "No"
  if [[ "$MENU_RESULT" == "Yes" ]]; then
    has_api="yes"
    _SETUP_CUR_SUMMARY=("")
    _setup_screen 3 "Your stack"
    menu_select "What runs it?" "Docker" "Node.js" "Go" "Python" "Rust" "Other"
    # shellcheck disable=SC2034
    api_type="$MENU_RESULT"
  fi

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 3 "Your stack"
  menu_select "Any background workers or jobs?" "Yes" "No"
  [[ "$MENU_RESULT" == "Yes" ]] && has_workers="yes"

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 3 "Your stack"
  menu_select "Any reverse proxy (nginx, caddy, etc)?" "Yes" "No"
  [[ "$MENU_RESULT" == "Yes" ]] && has_proxy="yes"

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 3 "Your stack"
  menu_select "Do you use containers?" "Docker Compose" "Kubernetes" "Docker (standalone)" "Local dev" "None"
  case "$MENU_RESULT" in
    "Docker Compose")        stack="compose" ;;
    Kubernetes)              stack="k8s" ;;
    "Docker (standalone)")   stack="docker" ;;
    "Local dev")             stack="dev" ;;
    None)                    stack="bare" ;;
  esac

  # ── Step 4: Build service list + select ──
  local service_list=()
  [[ "$has_api" == "yes" ]] && service_list[${#service_list[@]}]="api"
  [[ "$has_db" == "yes" ]] && service_list[${#service_list[@]}]="$(_svc_to_key "$db_type")"
  [[ "$has_workers" == "yes" ]] && service_list[${#service_list[@]}]="worker"
  [[ "$has_proxy" == "yes" ]] && service_list[${#service_list[@]}]="proxy"

  if [[ ${#service_list[@]} -eq 0 ]]; then
    warn "No services defined. Add at least one service."
    return 1
  fi

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 4 "Select services"
  checklist_select "Select services to manage" "${service_list[@]}"

  local selected_services=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && selected_services[${#selected_services[@]}]="$line"
  done <<< "$CHECKLIST_RESULT"

  if [[ ${#selected_services[@]} -eq 0 ]]; then
    warn "No services selected."
    return 1
  fi

  # Deploy order
  if (( ${#selected_services[@]} > 1 )); then
    _SETUP_CUR_SUMMARY=("")
    _setup_screen 4 "Deploy order"
    order_select "What order should services deploy?" "${selected_services[@]}"
    selected_services=("${ORDER_RESULT[@]}")
  fi

  # ── Step 5: Per-service config ──
  local services_json="{"
  local deploy_order_json="["
  local first=true
  local svc_index=0
  local _svc_ports=()

  for svc in "${selected_services[@]}"; do
    svc_index=$((svc_index + 1))
    local key
    key=$(_svc_to_key "$svc")

    _SETUP_CUR_SUMMARY=("")
    _setup_screen 5 "Configure ${svc} (${svc_index}/${#selected_services[@]})"
    menu_select "Health check type for ${svc}?" "HTTP" "TCP" "Command" "None"
    local health_choice="$MENU_RESULT"

    local health_json="{}"
    local port_num=""
    case "$health_choice" in
      HTTP)
        printf "\n  ${ACCENT}>${RESET} Health endpoint [/health]: "
        read -r endpoint
        printf "  ${ACCENT}>${RESET} Port [8080]: "
        read -r port_num
        health_json="{\"type\":\"http\",\"endpoint\":\"${endpoint:-/health}\",\"port\":${port_num:-8080},\"timeout\":10,\"enabled\":true}"
        ;;
      TCP)
        printf "\n  ${ACCENT}>${RESET} Port: "
        read -r port_num
        health_json="{\"type\":\"tcp\",\"port\":${port_num:-0},\"timeout\":5,\"enabled\":true}"
        ;;
      Command)
        printf "\n  ${ACCENT}>${RESET} Health command: "
        read -r health_cmd
        health_json="{\"type\":\"command\",\"command\":\"${health_cmd}\",\"timeout\":10,\"enabled\":true}"
        ;;
      None)
        health_json="{\"enabled\":false}"
        ;;
    esac
    _svc_ports[${#_svc_ports[@]}]="${port_num:-8080}"

    # Credentials
    _SETUP_CUR_SUMMARY=(
      ""
      "  ${GREEN}*${RESET} Health: ${health_choice}"
    )
    _setup_screen 5 "Configure ${svc} (${svc_index}/${#selected_services[@]})"
    menu_select "Credentials for ${svc}?" "None" "Save always (keychain)" "Once per session" "Every time"
    local cred_choice="$MENU_RESULT"

    local cred_mode="off"
    case "$cred_choice" in
      "Save always (keychain)") cred_mode="save" ;;
      "Once per session")       cred_mode="session" ;;
      "Every time")             cred_mode="always" ;;
    esac

    # Git pull
    _SETUP_CUR_SUMMARY=(
      ""
      "  ${GREEN}*${RESET} Health: ${health_choice}"
      "  ${GREEN}*${RESET} Credentials: ${cred_choice}"
    )
    _setup_screen 5 "Configure ${svc} (${svc_index}/${#selected_services[@]})"
    menu_select "Auto git pull before deploy for ${svc}?" "No" "Yes"
    local gp_choice="$MENU_RESULT"
    local git_pull_json=""
    if [[ "$gp_choice" == "Yes" ]]; then
      printf '\n  %b>%b Git remote [origin]: ' "${ACCENT}" "${RESET}"
      local _gp_remote_in=""
      IFS= read -r _gp_remote_in
      printf '  %b>%b Git branch [main]: ' "${ACCENT}" "${RESET}"
      local _gp_branch_in=""
      IFS= read -r _gp_branch_in
      [[ -z "$_gp_remote_in" ]] && _gp_remote_in="origin"
      [[ -z "$_gp_branch_in" ]] && _gp_branch_in="main"
      git_pull_json=",\"git_pull\":{\"enabled\":true,\"remote\":\"${_gp_remote_in}\",\"branch\":\"${_gp_branch_in}\"}"
    fi

    [[ "$first" == "true" ]] && first=false || services_json+=","
    services_json+="\"${key}\":{\"name\":\"${svc}\",\"health\":${health_json},\"credentials\":{\"mode\":\"${cred_mode}\"}${git_pull_json}}"
    deploy_order_json+="\"${key}\","
  done

  services_json+="}"
  deploy_order_json="${deploy_order_json%,}]"

  # ── Step 6: Project name ──
  local project_name
  project_name=$(basename "$project_path")
  _SETUP_CUR_SUMMARY=(
    ""
    "  ${ACCENT}>${RESET} Project name [${project_name}]: "
  )
  _SETUP_CUR_PROMPT="true"
  _setup_screen 6 "Project name"
  read -r custom_name
  _SETUP_CUR_PROMPT="false"
  project_name="${custom_name:-$project_name}"

  # ── Hook format (offer justfile if just is installed) ──
  local _hook_format="bash"
  if has_cmd just; then
    _SETUP_CUR_SUMMARY=("")
    _setup_screen 7 "Hook format"
    menu_select "Hook format?" "Bash scripts (default)" "Justfile"
    case "$MENU_RESULT" in
      "Justfile") _hook_format="just" ;;
    esac
  fi

  # ── Step 7: Generate ──
  local config_path="${project_path}/muster.json"
  local muster_dir="${project_path}/.muster"

  mkdir -p "${muster_dir}/hooks"
  mkdir -p "${muster_dir}/logs"
  mkdir -p "${muster_dir}/skills"
  [[ "$stack" == "dev" ]] && mkdir -p "${muster_dir}/pids"

  # Dev stack: detect start commands
  if [[ "$stack" == "dev" ]]; then
    _scan_detect_dev_cmds "$project_path"
  fi

  local _si=0
  for svc in "${selected_services[@]}"; do
    local key
    key=$(_svc_to_key "$svc")
    local hook_dir="${muster_dir}/hooks/${key}"
    mkdir -p "$hook_dir"
    local _start_cmd_m=""
    if [[ "$stack" == "dev" ]]; then
      _start_cmd_m=$(scan_get_dev_cmd "$svc")
      [[ -z "$_start_cmd_m" ]] && _start_cmd_m=$(scan_get_dev_cmd "$key")
    fi
    if [[ "$_hook_format" == "just" ]]; then
      _setup_copy_justfile "$key" "$svc" "$hook_dir" "${_svc_ports[$_si]:-8080}"
    else
      _setup_copy_hooks "$stack" "$key" "$svc" "$hook_dir" \
        "docker-compose.yml" "Dockerfile" "k8s/${svc}/" \
        "default" "${_svc_ports[$_si]:-8080}" \
        "$(scan_get_k8s_name "$svc")" "$_start_cmd_m"
    fi
    _si=$((_si + 1))
  done

  if has_cmd jq; then
    echo "{\"project\":\"${project_name}\",\"version\":\"1\",\"root\":\"${project_path}\",\"services\":${services_json},\"deploy_order\":${deploy_order_json},\"skills\":[]}" | jq '.' > "$config_path"
  elif has_cmd python3; then
    python3 -c "
import json, sys
data = json.loads(sys.argv[1])
print(json.dumps(data, indent=2))
" "{\"project\":\"${project_name}\",\"version\":\"1\",\"root\":\"${project_path}\",\"services\":${services_json},\"deploy_order\":${deploy_order_json},\"skills\":[]}" > "$config_path"
  else
    echo "{\"project\":\"${project_name}\",\"version\":\"1\",\"root\":\"${project_path}\",\"services\":${services_json},\"deploy_order\":${deploy_order_json},\"skills\":[]}" > "$config_path"
  fi

  local gitignore="${project_path}/.gitignore"
  if [[ -f "$gitignore" ]]; then
    grep -q '.muster/logs' "$gitignore" || echo '.muster/logs/' >> "$gitignore"
    grep -q '.muster/pids' "$gitignore" || echo '.muster/pids/' >> "$gitignore"
  else
    printf '%s\n%s\n' '.muster/logs/' '.muster/pids/' > "$gitignore"
  fi

  _SETUP_CUR_SUMMARY=(
    ""
    "  ${GREEN}*${RESET} Project: ${BOLD}${project_name}${RESET}"
    "  ${GREEN}*${RESET} Root:    ${project_path}"
    "  ${GREEN}*${RESET} Config:  ${config_path}"
    "  ${GREEN}*${RESET} Hooks:   ${muster_dir}/hooks/"
    ""
    "  ${ACCENT}Next steps:${RESET}"
    "  ${DIM}1. Review hooks in .muster/hooks/ (look for TODO comments)${RESET}"
    "  ${DIM}2. Run ${BOLD}muster${RESET}${DIM} to open the dashboard${RESET}"
    ""
    "  ${DIM}Press enter to exit${RESET}"
    ""
  )

  # Register project in global registry
  _registry_touch "$project_path"

  # Generate hook security manifest and lock hooks
  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  _hook_manifest_generate "$project_path"

  _SETUP_CUR_PROMPT="false"
  _setup_screen 7 "Setup complete"
  read -rs
}
