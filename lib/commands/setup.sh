#!/usr/bin/env bash
# muster/lib/commands/setup.sh — Guided setup wizard (scan-first)

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/tui/checklist.sh"
source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/tui/order.sh"
source "$MUSTER_ROOT/lib/core/scanner.sh"
source "$MUSTER_ROOT/lib/core/templates.sh"
source "$MUSTER_ROOT/lib/core/setup_txn.sh"

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
  if [[ -n "$BOLD" ]]; then
    printf ' \033[48;5;178m\033[38;5;0m\033[1m%s%s%s\033[0m\n' "$text" "$pad" "$right"
  else
    printf ' %s%s%s\n' "$text" "$pad" "$right"
  fi
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
  printf '%b\n' "  ${BOLD}Join token${RESET} ${DIM}(from cloud.getmuster.dev → Connect a machine)${RESET}"
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

  # Sign in through the browser (device code). The token goes to the
  # keychain; nothing secret is written to settings.json.
  menu_select "Which relay?" "Fleet Cloud (relay.getmuster.dev)" "Self-hosted relay"
  local _relay_args=""
  if [[ "$MENU_RESULT" == "Self-hosted relay" ]]; then
    printf '%b\n' "  ${BOLD}Relay URL${RESET} ${DIM}(e.g. https://relay.example.com)${RESET}"
    printf '  %b>%b ' "$ACCENT" "$RESET"
    read -r _relay_args
    if [[ -z "$_relay_args" ]]; then
      err "Relay URL is required for a self-hosted relay"
      return 1
    fi
  fi

  source "$MUSTER_ROOT/lib/commands/cloud.sh"
  if [[ -n "$_relay_args" ]]; then
    _cloud_login --relay "$_relay_args" || return 1
  else
    _cloud_login || return 1
  fi
  # Drop any plaintext token saved by older versions
  global_config_set "cloud.token" 'null' >/dev/null 2>&1 || true

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
# Shared setup helpers
# ══════════════════════════════════════════════════════════════

# Write muster.json (pretty-printed via jq or python3, raw fallback)
# Omits absolute "root" path so config stays portable across machines/CI.
# Usage: _setup_write_config "$config_path" "$project_name" "$services_json" "$deploy_order_json"
_setup_write_config() {
  local config_path="$1" project_name="$2" services_json="$3" deploy_order_json="$4"
  local raw_json="{\"project\":\"${project_name}\",\"version\":\"1\",\"services\":${services_json},\"deploy_order\":${deploy_order_json},\"skills\":[]}"
  if has_cmd jq; then
    printf '%s\n' "$raw_json" | jq '.' > "$config_path"
  elif has_cmd python3; then
    python3 -c '
import json, sys
data = json.loads(sys.argv[1])
print(json.dumps(data, indent=2))
' "$raw_json" > "$config_path"
  else
    printf '%s\n' "$raw_json" > "$config_path"
  fi
}

# Human-readable stack label
_setup_stack_label() {
  case "${1:-}" in
    k8s)     echo "Kubernetes" ;;
    compose) echo "Docker Compose" ;;
    docker)  echo "Docker" ;;
    bare)    echo "Bare metal" ;;
    dev)     echo "Local dev" ;;
    *)       echo "Bare metal" ;;
  esac
}

# Sort services: infra services first, then app services (preserving relative order)
_SETUP_SORTED_SERVICES=()
_setup_sort_services() {
  _SETUP_SORTED_SERVICES=()
  local _infra=()
  local _app=()
  local _s
  for _s in "$@"; do
    if _is_infra_service "$_s" 2>/dev/null; then
      _infra[${#_infra[@]}]="$_s"
    else
      _app[${#_app[@]}]="$_s"
    fi
  done
  local _i=0
  while (( _i < ${#_infra[@]} )); do
    _SETUP_SORTED_SERVICES[${#_SETUP_SORTED_SERVICES[@]}]="${_infra[$_i]}"
    _i=$((_i + 1))
  done
  _i=0
  while (( _i < ${#_app[@]} )); do
    _SETUP_SORTED_SERVICES[${#_SETUP_SORTED_SERVICES[@]}]="${_app[$_i]}"
    _i=$((_i + 1))
  done
}

# Convert "type|endpoint|port" health tuple into JSON object
# Usage: _setup_health_to_json "$h_info" [timeout]
_setup_health_to_json() {
  local h_info="$1" timeout="${2:-10}"
  if [[ -z "$h_info" ]]; then
    echo '{"enabled":false}'
    return 0
  fi
  local h_type="${h_info%%|*}"
  local h_rest="${h_info#*|}"
  local h_ep="${h_rest%%|*}"
  local h_port="${h_rest#*|}"
  case "$h_type" in
    http)
      [[ -z "$h_ep" ]] && h_ep="/health"
      [[ -z "$h_port" ]] && h_port="8080"
      echo "{\"type\":\"http\",\"endpoint\":\"${h_ep}\",\"port\":${h_port},\"timeout\":${timeout},\"enabled\":true}"
      ;;
    tcp)
      if [[ -n "$h_port" && "$h_port" =~ ^[0-9]+$ ]] && (( h_port > 0 )); then
        echo "{\"type\":\"tcp\",\"port\":${h_port},\"timeout\":${timeout},\"enabled\":true}"
      else
        echo '{"enabled":false}'
      fi
      ;;
    command)
      if [[ -n "$h_ep" ]]; then
        echo "{\"type\":\"command\",\"command\":\"${h_ep}\",\"timeout\":${timeout},\"enabled\":true}"
      else
        echo '{"enabled":false}'
      fi
      ;;
    *)
      echo '{"enabled":false}'
      ;;
  esac
}

# Format "type|endpoint|port" health tuple for human display
_setup_format_health() {
  local h_info="$1"
  if [[ -z "$h_info" ]]; then
    echo "disabled"
    return 0
  fi
  local h_type="${h_info%%|*}"
  local h_rest="${h_info#*|}"
  local h_ep="${h_rest%%|*}"
  local h_port="${h_rest#*|}"
  case "$h_type" in
    http)    echo "http :${h_port}${h_ep}" ;;
    tcp)     echo "tcp :${h_port}" ;;
    command) echo "command" ;;
    *)       echo "disabled" ;;
  esac
}

# Extract port number from a "type|endpoint|port" tuple (empty if none)
_setup_health_port() {
  local h_info="$1"
  [[ -z "$h_info" ]] && return 0
  local h_type="${h_info%%|*}"
  local h_rest="${h_info#*|}"
  local h_port="${h_rest#*|}"
  case "$h_type" in
    http|tcp)
      if [[ -n "$h_port" && "$h_port" =~ ^[0-9]+$ ]] && (( h_port > 0 )); then
        echo "$h_port"
      fi
      ;;
  esac
}

# Build quick-path scan summary lines into _SETUP_SUMMARY_LINES[]
# Usage: _setup_build_summary_lines "$stack" "${ordered_services[@]}"
_SETUP_SUMMARY_LINES=()
_setup_build_summary_lines() {
  local stack="$1"
  shift
  local svcs=("$@")
  local count=${#svcs[@]}
  local stack_label
  stack_label=$(_setup_stack_label "$stack")
  local noun="services"
  if (( count == 1 )); then
    noun="service"
  fi

  # Compute padded column width for service names
  local max_w=5
  local _s
  for _s in "${svcs[@]}"; do
    if (( ${#_s} > max_w )); then
      max_w=${#_s}
    fi
  done
  local col_w=$(( max_w + 3 ))

  _SETUP_SUMMARY_LINES=(
    ""
    "  ${BOLD}Found ${count} ${noun}${RESET} ${DIM}(${stack_label})${RESET}"
  )

  local deploy_chain=""
  local _i=0
  while (( _i < count )); do
    local svc="${svcs[$_i]}"
    local role="app  "
    if _is_infra_service "$svc" 2>/dev/null; then
      role="infra"
    fi
    local h_info=""
    h_info=$(scan_infer_health "$svc")
    local h_disp
    h_disp=$(_setup_format_health "$h_info")
    local pad_len=$(( col_w - ${#svc} ))
    if (( pad_len < 2 )); then
      pad_len=2
    fi
    local pad=""
    printf -v pad '%*s' "$pad_len" ""
    _SETUP_SUMMARY_LINES[${#_SETUP_SUMMARY_LINES[@]}]="    ${BOLD}${svc}${RESET}${pad}${DIM}${role}${RESET}   ${h_disp}"
    if [[ -n "$deploy_chain" ]]; then
      deploy_chain="${deploy_chain} → ${svc}"
    else
      deploy_chain="${svc}"
    fi
    _i=$((_i + 1))
  done

  _SETUP_SUMMARY_LINES[${#_SETUP_SUMMARY_LINES[@]}]="  ${DIM}Deploy order:${RESET} ${deploy_chain}"
  _SETUP_SUMMARY_LINES[${#_SETUP_SUMMARY_LINES[@]}]=""
  return 0
}

# Print actionable setup completion summary (uses only colors.sh vars, safe for non-TTY)
# Expects _SETUP_DONE_KEYS[], _SETUP_DONE_HEALTH[] populated in deploy order.
_SETUP_DONE_KEYS=()
_SETUP_DONE_HEALTH=()
_setup_print_complete_summary() {
  local project_name="$1" stack_display="$2" config_path="$3"

  echo ""
  printf '  %bProject:%b  %s\n' "${BOLD}" "${RESET}" "$project_name"
  printf '  %bStack:%b    %s\n' "${BOLD}" "${RESET}" "$stack_display"
  printf '  %bConfig:%b   %s\n' "${BOLD}" "${RESET}" "$config_path"
  echo ""
  printf '  %bServices:%b\n' "${BOLD}" "${RESET}"

  local max_k=5 max_h=8
  local _i=0
  local count=${#_SETUP_DONE_KEYS[@]}
  while (( _i < count )); do
    local _k="${_SETUP_DONE_KEYS[$_i]}"
    local _h="${_SETUP_DONE_HEALTH[$_i]}"
    if (( ${#_k} > max_k )); then max_k=${#_k}; fi
    if (( ${#_h} > max_h )); then max_h=${#_h}; fi
    _i=$((_i + 1))
  done

  _i=0
  while (( _i < count )); do
    local _k="${_SETUP_DONE_KEYS[$_i]}"
    local _h="${_SETUP_DONE_HEALTH[$_i]}"
    local _role="app  "
    if _is_infra_service "$_k" 2>/dev/null; then
      _role="infra"
    fi
    local _kpad="" _hpad=""
    printf -v _kpad '%*s' "$(( max_k - ${#_k} + 3 ))" ""
    printf -v _hpad '%*s' "$(( max_h - ${#_h} + 3 ))" ""
    printf '    %b%s%b%s%b%s%b   %s%s%b.muster/hooks/%s/%b\n' \
      "${BOLD}" "$_k" "${RESET}" "$_kpad" "${DIM}" "$_role" "${RESET}" \
      "$_h" "$_hpad" "${DIM}" "$_k" "${RESET}"
    _i=$((_i + 1))
  done

  echo ""
  printf '  %bNext:%b\n' "${ACCENT}" "${RESET}"
  printf '    %bmuster deploy --dry-run%b   Preview the deploy plan\n' "${BOLD}" "${RESET}"
  printf '    %bmuster deploy%b             Deploy all services\n' "${BOLD}" "${RESET}"
  printf '    %bmuster%b                    Open the dashboard\n' "${BOLD}" "${RESET}"
  return 0
}

# Print build context overlap warnings if detected
_setup_check_build_context() {
  local config_path="$1"
  # shellcheck disable=SC2034
  CONFIG_FILE="$config_path"
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
}

# Update .gitignore with .muster/logs/ and .muster/pids/
_setup_update_gitignore() {
  local project_path="$1"
  local gitignore="${project_path}/.gitignore"
  if [[ -f "$gitignore" ]]; then
    grep -q '.muster/logs' "$gitignore" || echo '.muster/logs/' >> "$gitignore"
    grep -q '.muster/pids' "$gitignore" || echo '.muster/pids/' >> "$gitignore"
  else
    printf '%s\n%s\n' '.muster/logs/' '.muster/pids/' > "$gitignore"
  fi
}

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
  if [[ ( -f "${project_path}/muster.json" || -f "${project_path}/deploy.json" ) && "$flag_force" != "true" && "$_SETUP_TXN_MODE" != "update" ]]; then
    err "This project already has a muster config."
    printf '  %bUse --update to add new services and keep your changes, or --force to start over.%b\n' "${DIM}" "${RESET}"
    return 1
  fi
  [[ "$flag_force" == "true" && "$_SETUP_TXN_MODE" != "update" ]] && _SETUP_TXN_MODE="fresh"

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
    if [[ "$flag_scan" == "true" ]]; then
      warn "Nothing to deploy was detected in ${project_path}."
      printf '  %bmuster looks for Dockerfiles, compose files, k8s manifests, package.json, go.mod,%b\n' "${DIM}" "${RESET}"
      printf '  %brequirements.txt and similar. Start from a template instead:%b\n' "${DIM}" "${RESET}"
      echo "    muster setup --stack bare --services app      # plain scripts"
      echo "    muster setup --stack docker --services api    # one container"
      echo "    muster setup --stack dev --services web       # local dev process"
    else
      err "No services specified. Use --services or --scan to detect them."
    fi
    return 1
  fi
  _setup_dedupe_services

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
  _SETUP_DONE_KEYS=()
  _SETUP_DONE_HEALTH=()

  for svc in "${ordered_services[@]}"; do
    local key
    key=$(_svc_to_key "$svc")

    # Look up health for this service (explicit --health flags first)
    local health_json="{\"enabled\":false}"
    local health_display="disabled"
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
            health_display="http :${h_port}${h_endpoint}"
            ;;
          tcp)
            local h_port="${h_args}"
            [[ -z "$h_port" ]] && h_port="0"
            health_json="{\"type\":\"tcp\",\"port\":${h_port},\"timeout\":10,\"enabled\":true}"
            health_display="tcp :${h_port}"
            ;;
          command)
            local h_cmd="${h_args}"
            health_json="{\"type\":\"command\",\"command\":\"${h_cmd}\",\"timeout\":10,\"enabled\":true}"
            health_display="command"
            ;;
          none)
            health_json="{\"enabled\":false}"
            health_display="disabled"
            ;;
        esac
        break
      fi
      li=$((li + 1))
    done

    # Fallback: infer health from scan (real HTTP/k8s probes > detected ports > infra defaults)
    if [[ "$found_explicit" == "false" ]]; then
      local auto_health=""
      auto_health=$(scan_infer_health "$svc")
      [[ -z "$auto_health" && "$key" != "$svc" ]] && auto_health=$(scan_infer_health "$key")
      if [[ -n "$auto_health" ]]; then
        health_json=$(_setup_health_to_json "$auto_health" 10)
        health_display=$(_setup_format_health "$auto_health")
      fi
    fi

    _SETUP_DONE_KEYS[${#_SETUP_DONE_KEYS[@]}]="$key"
    _SETUP_DONE_HEALTH[${#_SETUP_DONE_HEALTH[@]}]="$health_display"

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

    # Default display name to service key so it matches CLI usage (e.g. `muster deploy api`)
    local display_name="$key"

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

  # ── Generate files (staged; committed atomically below) ──
  _setup_check_tools "$stack" false
  _setup_txn_begin "$project_path" || return 1
  local config_path="$_SETUP_TXN_CONFIG"
  local muster_dir="$_SETUP_TXN_MUSTER"

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

    # Fallback: port from inferred health (compose ports, Dockerfile EXPOSE, k8s, infra defaults)
    if [[ "$_svc_port" == "8080" ]]; then
      local _auto_h=""
      _auto_h=$(scan_infer_health "$svc")
      [[ -z "$_auto_h" && "$key" != "$svc" ]] && _auto_h=$(scan_infer_health "$key")
      if [[ -n "$_auto_h" ]]; then
        local _auto_port=""
        _auto_port=$(_setup_health_port "$_auto_h")
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

  # Write muster.json (without absolute root path)
  _setup_write_config "$config_path" "$project_name" "$services_json" "$deploy_order_json"
  _setup_txn_checkpoint "after-hooks"
  _setup_txn_commit || return 1
  config_path="${project_path}/muster.json"

  # .gitignore
  _setup_update_gitignore "$project_path"

  # ── Print summary (plain text, no TUI) ──
  local stack_display=""
  stack_display=$(_setup_stack_label "$stack")

  # Register project in global registry
  _registry_touch "$project_path"

  # Generate hook security manifest and lock hooks
  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  _hook_manifest_generate "$project_path"

  if [[ "$_SETUP_TXN_MODE" == "update" ]]; then
    ok "Setup updated"
  else
    ok "Setup complete"
  fi
  _setup_print_notices

  # Check for build context overlaps in the new config
  _setup_check_build_context "$config_path"

  _setup_print_complete_summary "$project_name" "$stack_display" "$config_path"
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
  local flag_dry_run="false" flag_json="false"
  _FLAG_HEALTH=()
  _FLAG_CREDS=()
  _FLAG_REMOTE=()
  _FLAG_GIT_PULL=()
  _SETUP_TXN_MODE="fresh"
  _SETUP_NOTICES=()
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
      --dry-run)
        flag_dry_run="true"; shift ;;
      --json)
        flag_json="true"; shift ;;
      --update|-u)
        _SETUP_TXN_MODE="update"; shift ;;
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
        echo "  --force, -f           Start over: regenerate muster.json and hooks"
        echo "                        (hooks you edited are backed up first)"
        echo "  --update, -u          Re-run on an existing project: add new services,"
        echo "                        keep your muster.json changes and edited hooks"
        echo "  --dry-run             With --scan: show what setup would configure, write nothing"
        echo "  --json                With --scan --dry-run: print the preview as JSON"
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
        echo "  muster setup --scan --dry-run --json    Preview detected services as JSON"
        return 0
        ;;
      *)
        err "Unknown flag: $1"
        source "$MUSTER_ROOT/lib/core/suggest.sh"
        _suggest_print "$1" --path --scan --stack --services --order --health --creds \
          --remote --git-pull --name --namespace --force --update --help || true
        echo "Run 'muster setup --help' for usage."
        return 1
        ;;
    esac
  done

  # Scan preview: run the scanner, report, write nothing
  if [[ "$flag_dry_run" == "true" || "$flag_json" == "true" ]]; then
    source "$MUSTER_ROOT/lib/commands/setup_scan.sh"
    _setup_scan_preview "${flag_path:-.}" "$flag_stack" "$flag_namespace" "$flag_name" "$flag_force" "$flag_json"
    return $?
  fi

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

  if [[ "$_existing_role" == "local" ]]; then
    # Already configured for local projects — skip redundant role prompt
    _setup_role="local"
    _role_changed=false
  elif [[ -n "$_existing_role" ]]; then
    # Show current fleet/target role and offer to keep or change
    local _role_label=""
    case "$_existing_role" in
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

  # ── Scan current directory first; only prompt for location if nothing detected ──
  local project_path
  project_path="$(pwd)"

  SETUP_TOTAL_STEPS=3
  _SETUP_CUR_SUMMARY=(
    ""
    "  ${DIM}Looking for Dockerfiles, k8s manifests, compose files, and services...${RESET}"
    ""
  )
  _setup_screen 1 "Scanning project"
  echo ""
  start_spinner "Scanning ${project_path}..."
  scan_project "$project_path"
  stop_spinner

  if (( ${#_SCAN_FILES[@]} == 0 && ${#_SCAN_SERVICES[@]} == 0 )); then
    local _cwd_display
    _cwd_display="${project_path/#$HOME/~}"
    _SETUP_CUR_SUMMARY=(
      ""
      "  ${DIM}No project files found in ${_cwd_display}.${RESET}"
      ""
    )
    _setup_screen 1 "Project location"
    menu_select "Where is your project?" "Setup here (${_cwd_display})" "Choose location" "Back"

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
        project_path="${REPLY:-.}"

        case "$project_path" in
          [Bb][Aa][Cc][Kk]|[Hh][Oo][Mm][Ee]|[Qq][Uu][Ii][Tt]|[Ee][Xx][Ii][Tt]|[Qq]) return 0 ;;
        esac

        local _resolved_path
        _resolved_path="$(cd "$project_path" 2>/dev/null && pwd)" || {
          err "Path does not exist: $project_path"
          printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
          IFS= read -rsn1 || true
          return 0
        }
        project_path="$_resolved_path"

        start_spinner "Scanning ${project_path}..."
        scan_project "$project_path"
        stop_spinner
        ;;
    esac
  fi

  # ── Check for existing config ──
  if [[ -f "${project_path}/muster.json" || -f "${project_path}/deploy.json" ]]; then
    _SETUP_CUR_SUMMARY=("")
    _setup_screen 1 "Existing config found"
    menu_select "This project is already set up. What do you want to do?" \
      "Update (keep my changes)" "Start over" "Cancel"
    case "$MENU_RESULT" in
      "Update (keep my changes)") _SETUP_TXN_MODE="update" ;;
      "Start over") _SETUP_TXN_MODE="fresh" ;;
      *)
        info "Setup cancelled — nothing changed."
        return 0 ;;
    esac
  fi

  local _setup_env="default"
  local _setup_health_timeout=10

  if (( ${#_SCAN_FILES[@]} > 0 || ${#_SCAN_SERVICES[@]} > 0 )); then
    local stack="$_SCAN_STACK"
    local _k8s_scanned="false"

    # Live k8s cluster introspection when k8s manifests detected
    if [[ "$stack" == "k8s" ]]; then
      local _resolved_ns
      _resolved_ns=$(_scan_resolve_namespace "" "$project_path")
      scan_k8s_cluster "$_resolved_ns"
      _k8s_scanned="true"
    fi

    # Only ask for stack if scan could not identify one
    if [[ -z "$stack" ]]; then
      _SETUP_CUR_SUMMARY=("")
      _setup_screen 1 "Select stack"
      menu_select "What deploys your services?" "Docker Compose" "Kubernetes" "Docker (standalone)" "Bare metal / Systemd" "Local dev"
      case "$MENU_RESULT" in
        Kubernetes)              stack="k8s" ;;
        "Docker Compose")        stack="compose" ;;
        "Docker (standalone)")   stack="docker" ;;
        "Bare metal / Systemd")  stack="bare" ;;
        "Local dev")             stack="dev" ;;
        *)                       stack="bare" ;;
      esac
      if [[ "$stack" == "k8s" && "$_k8s_scanned" == "false" ]]; then
        local _resolved_ns
        _resolved_ns=$(_scan_resolve_namespace "" "$project_path")
        scan_k8s_cluster "$_resolved_ns"
        _k8s_scanned="true"
      fi
    fi

    # Only ask for service names if scan detected files but no services
    if (( ${#_SCAN_SERVICES[@]} == 0 )); then
      _SETUP_CUR_SUMMARY=(
        ""
        "  ${DIM}Enter service names separated by spaces${RESET}"
        "  ${DIM}Example: api worker redis${RESET}"
        ""
        "  ${ACCENT}>${RESET} "
      )
      _SETUP_CUR_PROMPT="true"
      _setup_screen 1 "Name your services"
      read -r svc_input
      _SETUP_CUR_PROMPT="false"
      [[ -z "${svc_input// /}" ]] && svc_input="app"
      local _s
      for _s in $svc_input; do
        _SCAN_SERVICES[${#_SCAN_SERVICES[@]}]="$_s"
      done
    fi

    if (( ${#_SCAN_SERVICES[@]} == 0 )); then
      warn "No services selected."
      return 1
    fi

    # Missing tools / Docker not running (offers install in a TTY)
    _setup_check_tools "$stack" true

    # Auto-sort: infra services first, then app services
    _setup_sort_services "${_SCAN_SERVICES[@]}"
    local ordered_services=("${_SETUP_SORTED_SERVICES[@]}")

    # ── Quick summary screen (ONE confirmation) ──
    _setup_build_summary_lines "$stack" "${ordered_services[@]}"
    _SETUP_CUR_SUMMARY=("${_SETUP_SUMMARY_LINES[@]}")
    _setup_screen 2 "Scan results"

    menu_select "Looks good?" "Create it" "Customize" "Cancel"

    if [[ "$MENU_RESULT" == "Cancel" || "$MENU_RESULT" == "__back__" ]]; then
      info "Setup cancelled."
      return 0
    fi

    local _quick_mode="true"
    if [[ "$MENU_RESULT" == "Customize" ]]; then
      _quick_mode="false"
    fi

    local selected_services=()
    local services_json="{"
    local deploy_order_json="["
    local first=true
    local svc_index=0
    local _svc_ports=()
    local _hook_format="bash"
    _SETUP_DONE_KEYS=()
    _SETUP_DONE_HEALTH=()

    if [[ "$_quick_mode" == "true" ]]; then
      # ── Quick path: write config + hooks immediately with inferred defaults ──
      selected_services=("${ordered_services[@]}")
      _setup_dedupe_services
      for svc in "${selected_services[@]}"; do
        svc_index=$((svc_index + 1))
        local key
        key=$(_svc_to_key "$svc")

        local _h_info=""
        _h_info=$(scan_infer_health "$svc")
        [[ -z "$_h_info" && "$key" != "$svc" ]] && _h_info=$(scan_infer_health "$key")

        local health_json
        health_json=$(_setup_health_to_json "$_h_info" 10)
        local health_display
        health_display=$(_setup_format_health "$_h_info")
        local port_num=""
        port_num=$(_setup_health_port "$_h_info")
        _svc_ports[${#_svc_ports[@]}]="${port_num:-8080}"

        # Build k8s block if stack is k8s
        local k8s_json="" skip_deploy_json=""
        if [[ "$stack" == "k8s" ]]; then
          local _k8s_deploy _k8s_ns
          _k8s_deploy=$(scan_get_k8s_name "$svc")
          [[ -z "$_k8s_deploy" || "$_k8s_deploy" == "$svc" ]] && _k8s_deploy=$(scan_get_k8s_name "$key")
          [[ -z "$_k8s_deploy" || "$_k8s_deploy" == "$key" ]] && _k8s_deploy="$svc"
          _k8s_ns="${_SCAN_K8S_NS:-default}"
          k8s_json=",\"k8s\":{\"deployment\":\"${_k8s_deploy}\",\"namespace\":\"${_k8s_ns}\"}"
          if (( ${#_SCAN_K8S_NAMES[@]} > 0 )); then
            if ! scan_has_k8s_deployment "$svc" && ! scan_has_k8s_deployment "$key"; then
              skip_deploy_json=",\"skip_deploy\":true"
            fi
          fi
        fi

        _SETUP_DONE_KEYS[${#_SETUP_DONE_KEYS[@]}]="$key"
        _SETUP_DONE_HEALTH[${#_SETUP_DONE_HEALTH[@]}]="$health_display"

        [[ "$first" == "true" ]] && first=false || services_json+=","
        services_json+="\"${key}\":{\"name\":\"${key}\",\"health\":${health_json},\"credentials\":{\"mode\":\"off\"}${k8s_json}${skip_deploy_json}}"
        deploy_order_json+="\"${key}\","
      done
    else
      # ── Customize path: environment, stack, services, order, per-service config ──
      SETUP_TOTAL_STEPS=6

      # Environment
      _SETUP_CUR_SUMMARY=(
        ""
        "  ${DIM}This determines default health check timeouts and credential defaults.${RESET}"
        ""
      )
      _setup_screen 2 "Environment"
      menu_select_desc "Environment" \
        "Production" \
        "Live environment serving real users. Thorough health checks (30s timeout)." \
        "Staging" \
        "Pre-production environment that mirrors prod. Moderate health checks (15s timeout)." \
        "Development" \
        "Local development machine. Fast health checks (5s timeout)."

      case "$MENU_RESULT" in
        *Production*)
          _setup_env="production"
          _setup_health_timeout=30
          ;;
        *Staging*)
          _setup_env="staging"
          _setup_health_timeout=15
          ;;
        *Development*)
          _setup_env="development"
          _setup_health_timeout=5
          ;;
      esac

      # Stack (single menu with detected stack as first option — no double confirmation)
      local stack_label
      stack_label=$(_setup_stack_label "$stack")
      _SETUP_CUR_SUMMARY=("")
      _setup_screen 3 "Stack"
      menu_select "What deploys your services?" \
        "Keep ${stack_label}" \
        "Docker Compose" \
        "Kubernetes" \
        "Docker (standalone)" \
        "Bare metal / Systemd" \
        "Local dev"
      case "$MENU_RESULT" in
        "Keep "*)                ;;
        Kubernetes)              stack="k8s" ;;
        "Docker Compose")        stack="compose" ;;
        "Docker (standalone)")   stack="docker" ;;
        "Bare metal / Systemd")  stack="bare" ;;
        "Local dev")             stack="dev" ;;
      esac
      if [[ "$stack" == "k8s" && "$_k8s_scanned" == "false" ]]; then
        local _resolved_ns
        _resolved_ns=$(_scan_resolve_namespace "" "$project_path")
        scan_k8s_cluster "$_resolved_ns"
        _k8s_scanned="true"
      fi

      # Service selection
      _SETUP_CUR_SUMMARY=("")
      _setup_screen 3 "Select services"
      checklist_select "Manage these services?" "${ordered_services[@]}"
      while IFS= read -r line; do
        [[ -n "$line" ]] && selected_services[${#selected_services[@]}]="$line"
      done <<< "$CHECKLIST_RESULT"

      if [[ ${#selected_services[@]} -eq 0 ]]; then
        warn "No services selected."
        return 1
      fi

      # Deploy order
      if (( ${#selected_services[@]} > 1 )); then
        _SETUP_CUR_SUMMARY=(
          ""
          "  ${DIM}Services deploy in this order. Infra (databases, caches) should go first.${RESET}"
          ""
        )
        _setup_screen 4 "Deploy order"
        order_select "Deploy order" "${selected_services[@]}"
        selected_services=("${ORDER_RESULT[@]}")
      fi
      _setup_dedupe_services

      # Per-service questions
      for svc in "${selected_services[@]}"; do
        svc_index=$((svc_index + 1))
        local key
        key=$(_svc_to_key "$svc")

        # Pre-fill from inferred scan health/port
        local _prefill_health="" _prefill_port=""
        _prefill_health=$(scan_infer_health "$svc")
        [[ -z "$_prefill_health" && "$key" != "$svc" ]] && _prefill_health=$(scan_infer_health "$key")
        _prefill_port=$(_setup_health_port "$_prefill_health")

        # Health check
        _SETUP_CUR_SUMMARY=(
          ""
          "  ${DIM}Health checks verify your services are running after each deploy.${RESET}"
          ""
        )
        _setup_screen 4 "Configure ${svc} (${svc_index}/${#selected_services[@]})"
        # Detected type first so Enter accepts it
        case "${_prefill_health%%|*}" in
          http) menu_select "Health check for ${svc}? (detected: HTTP)" "HTTP" "TCP" "Command" "None" ;;
          tcp)  menu_select "Health check for ${svc}? (detected: TCP)" "TCP" "HTTP" "Command" "None" ;;
          *)    menu_select "Health check for ${svc}?" "TCP" "HTTP" "Command" "None" ;;
        esac
        local health_choice="$MENU_RESULT"
        [[ "$health_choice" == "__back__" ]] && health_choice="None"

        local health_json="{}"
        local health_display="disabled"
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
            printf '\n  %b>%b Health endpoint [%s]: ' "${ACCENT}" "${RESET}" "${_def_ep}"
            read -r endpoint
            _setup_read_port "Port" "$_def_port"
            port_num="$_SRP_PORT"
            local _final_ep="${endpoint:-$_def_ep}"
            [[ "$_final_ep" != /* ]] && _final_ep="/${_final_ep}"
            _setup_verify_health "$svc" http "$port_num" "$_final_ep" true
            port_num="$_SVH_PORT"
            local _final_port="$port_num"
            health_json="{\"type\":\"http\",\"endpoint\":\"${_final_ep}\",\"port\":${_final_port},\"timeout\":${_setup_health_timeout},\"enabled\":true}"
            health_display="http :${_final_port}${_final_ep}"
            ;;
          TCP)
            echo ""
            _setup_read_port "Port" "${_prefill_port:-8080}"
            _setup_verify_health "$svc" tcp "$_SRP_PORT" "" true
            port_num="$_SVH_PORT"
            local _final_port="$port_num"
            health_json="{\"type\":\"tcp\",\"port\":${_final_port},\"timeout\":${_setup_health_timeout},\"enabled\":true}"
            health_display="tcp :${_final_port}"
            ;;
          Command)
            printf '\n  %b>%b Health command: ' "${ACCENT}" "${RESET}"
            read -r health_cmd
            health_json="{\"type\":\"command\",\"command\":\"${health_cmd}\",\"timeout\":${_setup_health_timeout},\"enabled\":true}"
            health_display="command"
            ;;
          None)
            health_json="{\"enabled\":false}"
            health_display="disabled"
            ;;
        esac
        _svc_ports[${#_svc_ports[@]}]="${port_num:-${_prefill_port:-8080}}"

        # Credentials
        _SETUP_CUR_SUMMARY=(
          ""
          "  ${GREEN}*${RESET} Health: ${health_display}"
          ""
          "  ${DIM}Credentials are used for secrets (API keys, tokens). Never stored in config.${RESET}"
          ""
        )
        _setup_screen 4 "Configure ${svc} (${svc_index}/${#selected_services[@]})"
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
          "  ${GREEN}*${RESET} Health: ${health_display}"
          "  ${GREEN}*${RESET} Credentials: ${cred_choice}"
        )
        _setup_screen 4 "Configure ${svc} (${svc_index}/${#selected_services[@]})"
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

        # Build k8s block if stack is k8s
        local k8s_json="" skip_deploy_json=""
        if [[ "$stack" == "k8s" ]]; then
          local _k8s_deploy _k8s_ns
          _k8s_deploy=$(scan_get_k8s_name "$svc")
          [[ -z "$_k8s_deploy" || "$_k8s_deploy" == "$svc" ]] && _k8s_deploy=$(scan_get_k8s_name "$key")
          [[ -z "$_k8s_deploy" || "$_k8s_deploy" == "$key" ]] && _k8s_deploy="$svc"
          _k8s_ns="${_SCAN_K8S_NS:-default}"
          k8s_json=",\"k8s\":{\"deployment\":\"${_k8s_deploy}\",\"namespace\":\"${_k8s_ns}\"}"
          if (( ${#_SCAN_K8S_NAMES[@]} > 0 )); then
            if ! scan_has_k8s_deployment "$svc" && ! scan_has_k8s_deployment "$key"; then
              skip_deploy_json=",\"skip_deploy\":true"
            fi
          fi
        fi

        _SETUP_DONE_KEYS[${#_SETUP_DONE_KEYS[@]}]="$key"
        _SETUP_DONE_HEALTH[${#_SETUP_DONE_HEALTH[@]}]="$health_display"

        [[ "$first" == "true" ]] && first=false || services_json+=","
        services_json+="\"${key}\":{\"name\":\"${key}\",\"health\":${health_json},\"credentials\":{\"mode\":\"${cred_mode}\"}${k8s_json}${skip_deploy_json}${git_pull_json}}"
        deploy_order_json+="\"${key}\","
      done

      # Hook format (offer justfile if just is installed)
      if has_cmd just; then
        _SETUP_CUR_SUMMARY=("")
        _setup_screen 5 "Hook format"
        menu_select "Hook format?" "Bash scripts (default)" "Justfile"
        case "$MENU_RESULT" in
          "Justfile") _hook_format="just" ;;
        esac
      fi

      # Review screen (Customize path only)
      local _rev_project_name
      _rev_project_name=$(basename "$project_path")
      local _rev_stack_display
      _rev_stack_display=$(_setup_stack_label "$stack")
      local _review_summary=(
        ""
        "  ${BOLD}Project:${RESET}    ${_rev_project_name} (${_setup_env})"
        "  ${BOLD}Stack:${RESET}      ${_rev_stack_display}"
        ""
      )
      local _ri=0
      while (( _ri < ${#_SETUP_DONE_KEYS[@]} )); do
        local _rk="${_SETUP_DONE_KEYS[$_ri]}"
        local _rh="${_SETUP_DONE_HEALTH[$_ri]}"
        local _infra_tag=""
        _is_infra_service "$_rk" 2>/dev/null && _infra_tag=" ${DIM}(infra)${RESET}"
        _review_summary[${#_review_summary[@]}]="  $((_ri + 1)). ${BOLD}${_rk}${RESET}    ${_rh}${_infra_tag}"
        _ri=$((_ri + 1))
      done
      _review_summary[${#_review_summary[@]}]=""

      _SETUP_CUR_SUMMARY=("${_review_summary[@]}")
      _setup_screen 5 "Review"
      menu_select "Ready?" "Generate" "Go back"
      if [[ "$MENU_RESULT" == "Go back" || "$MENU_RESULT" == "__back__" ]]; then
        info "Setup cancelled."
        return 0
      fi
    fi

    services_json+="}"
    deploy_order_json="${deploy_order_json%,}]"

    # ── Generate config + hooks ──
    local project_name
    project_name=$(basename "$project_path")
    local stack_display
    stack_display=$(_setup_stack_label "$stack")
    _setup_txn_begin "$project_path" || return 1
    local config_path="$_SETUP_TXN_CONFIG"
    local muster_dir="$_SETUP_TXN_MUSTER"

    mkdir -p "${muster_dir}/hooks"
    mkdir -p "${muster_dir}/logs"
    mkdir -p "${muster_dir}/skills"
    [[ "$stack" == "dev" ]] && mkdir -p "${muster_dir}/pids"

    # Dev stack: detect start commands
    if [[ "$stack" == "dev" ]]; then
      _scan_detect_dev_cmds "$project_path"
    fi

    # Copy template hooks for each service, using real detected paths
    local _detected_compose _detected_dockerfile _detected_k8s
    _detected_compose=$(scan_get_compose_file)
    local _k8s_ns_out="${_SCAN_K8S_NS:-default}"
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
          "$_k8s_ns_out" "${_svc_ports[$_si]:-8080}" \
          "$(scan_get_k8s_name "$svc")" "$_start_cmd_i"
      fi
      _si=$((_si + 1))
    done

    # Write muster.json (without absolute root path)
    _setup_write_config "$config_path" "$project_name" "$services_json" "$deploy_order_json"
    _setup_txn_commit || return 1
    config_path="${project_path}/muster.json"

    # .gitignore
    _setup_update_gitignore "$project_path"

    # Register project in global registry
    _registry_touch "$project_path"

    # Generate hook security manifest and lock hooks
    source "$MUSTER_ROOT/lib/core/hook_security.sh"
    _hook_manifest_generate "$project_path"

    # Keep final summary visible after exit (don't clear on EXIT trap)
    # shellcheck disable=SC2034
    _MUSTER_TUI_FULLSCREEN="false"
    clear 2>/dev/null || true
    echo ""
    if [[ "$_SETUP_TXN_MODE" == "update" ]]; then ok "Setup updated"; else ok "Setup complete"; fi
    _setup_print_notices
    _setup_check_build_context "$config_path"
    _setup_print_complete_summary "$project_name" "$stack_display" "muster.json"
    echo ""

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
    SETUP_TOTAL_STEPS=7
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
  info "Nothing detected here yet — no problem."
  printf '  %bAnswer a few questions (Enter accepts the default) and muster will\n  generate starter hooks from templates that you can edit later.%b\n' "${DIM}" "${RESET}"
  echo ""
  sleep 1

  # ── Step 4: Stack questions (manual path) ──
  local has_db="no" db_type="" has_api="no" api_type=""
  local has_workers="no" has_proxy="no" stack="bare"

  _SETUP_CUR_SUMMARY=(
    ""
    "  ${DIM}Tell muster about your infrastructure so it can generate the right hooks.${RESET}"
    ""
  )
  _setup_screen 4 "Your stack"
  menu_select "Do you manage a database here?" "Yes" "No"
  if [[ "$MENU_RESULT" == "Yes" ]]; then
    has_db="yes"
    _SETUP_CUR_SUMMARY=("")
    _setup_screen 4 "Your stack"
    menu_select "What kind of database?" "PostgreSQL" "MySQL" "Redis" "MongoDB" "SQLite" "Other"
    db_type="$MENU_RESULT"
  fi

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 4 "Your stack"
  menu_select "Do you have a web server or API?" "Yes" "No"
  if [[ "$MENU_RESULT" == "Yes" ]]; then
    has_api="yes"
    _SETUP_CUR_SUMMARY=("")
    _setup_screen 4 "Your stack"
    menu_select "What runs it?" "Docker" "Node.js" "Go" "Python" "Rust" "Other"
    # shellcheck disable=SC2034
    api_type="$MENU_RESULT"
  fi

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 4 "Your stack"
  menu_select "Any background workers or jobs?" "Yes" "No"
  [[ "$MENU_RESULT" == "Yes" ]] && has_workers="yes"

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 4 "Your stack"
  menu_select "Any reverse proxy (nginx, caddy, etc)?" "Yes" "No"
  [[ "$MENU_RESULT" == "Yes" ]] && has_proxy="yes"

  _SETUP_CUR_SUMMARY=("")
  _setup_screen 4 "Your stack"
  menu_select "Do you use containers?" "Docker Compose" "Kubernetes" "Docker (standalone)" "Local dev" "None"
  case "$MENU_RESULT" in
    "Docker Compose")        stack="compose" ;;
    Kubernetes)              stack="k8s" ;;
    "Docker (standalone)")   stack="docker" ;;
    "Local dev")             stack="dev" ;;
    None)                    stack="bare" ;;
  esac

  # ── Step 5: Build service list + select ──
  local service_list=()
  [[ "$has_api" == "yes" ]] && service_list[${#service_list[@]}]="api"
  [[ "$has_db" == "yes" ]] && service_list[${#service_list[@]}]="$(_svc_to_key "$db_type")"
  [[ "$has_workers" == "yes" ]] && service_list[${#service_list[@]}]="worker"
  [[ "$has_proxy" == "yes" ]] && service_list[${#service_list[@]}]="proxy"

  if [[ ${#service_list[@]} -eq 0 ]]; then
    # Nothing chosen: start with one generic service rather than a dead end
    service_list[0]="app"
    _setup_notice "Started with a single 'app' service — add more later by re-running muster setup (Update)."
  fi

  _SETUP_CUR_SUMMARY=(
    ""
    "  ${DIM}Services deploy in this order. Infra (databases, caches) should go first.${RESET}"
    ""
  )
  _setup_screen 5 "Select services"
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
    _setup_screen 5 "Deploy order"
    order_select "What order should services deploy?" "${selected_services[@]}"
    selected_services=("${ORDER_RESULT[@]}")
  fi
  _setup_dedupe_services

  # ── Step 5: Per-service config ──
  local services_json="{"
  local deploy_order_json="["
  local first=true
  local svc_index=0
  local _svc_ports=()
  _SETUP_DONE_KEYS=()
  _SETUP_DONE_HEALTH=()

  for svc in "${selected_services[@]}"; do
    svc_index=$((svc_index + 1))
    local key
    key=$(_svc_to_key "$svc")
    local _infra_port=""
    _infra_port=$(_scan_infra_default_port "$svc")

    _SETUP_CUR_SUMMARY=(
      ""
      "  ${DIM}Health checks verify your services are running after each deploy.${RESET}"
      ""
    )
    _setup_screen 5 "Configure ${svc} (${svc_index}/${#selected_services[@]})"
    menu_select "Health check type for ${svc}?" "TCP" "HTTP" "Command" "None"
    local health_choice="$MENU_RESULT"

    local health_json="{}"
    local health_display="disabled"
    local port_num=""
    case "$health_choice" in
      HTTP)
        printf '\n  %b>%b Health endpoint [/health]: ' "${ACCENT}" "${RESET}"
        read -r endpoint
        _setup_read_port "Port" "${_infra_port:-8080}"
        port_num="$_SRP_PORT"
        local _m_ep="${endpoint:-/health}"
        [[ "$_m_ep" != /* ]] && _m_ep="/${_m_ep}"
        local _m_port="$port_num"
        health_json="{\"type\":\"http\",\"endpoint\":\"${_m_ep}\",\"port\":${_m_port},\"timeout\":10,\"enabled\":true}"
        health_display="http :${_m_port}${_m_ep}"
        ;;
      TCP)
        echo ""
        _setup_read_port "Port" "${_infra_port:-8080}"
        port_num="$_SRP_PORT"
        local _m_port="$port_num"
        health_json="{\"type\":\"tcp\",\"port\":${_m_port},\"timeout\":10,\"enabled\":true}"
        health_display="tcp :${_m_port}"
        ;;
      Command)
        printf '\n  %b>%b Health command: ' "${ACCENT}" "${RESET}"
        read -r health_cmd
        health_json="{\"type\":\"command\",\"command\":\"${health_cmd}\",\"timeout\":10,\"enabled\":true}"
        health_display="command"
        ;;
      None)
        health_json="{\"enabled\":false}"
        health_display="disabled"
        ;;
    esac
    _svc_ports[${#_svc_ports[@]}]="${port_num:-${_infra_port:-8080}}"

    # Credentials
    _SETUP_CUR_SUMMARY=(
      ""
      "  ${GREEN}*${RESET} Health: ${health_display}"
      ""
      "  ${DIM}Credentials are used for secrets (API keys, tokens). Never stored in config.${RESET}"
      ""
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
      "  ${GREEN}*${RESET} Health: ${health_display}"
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

    _SETUP_DONE_KEYS[${#_SETUP_DONE_KEYS[@]}]="$key"
    _SETUP_DONE_HEALTH[${#_SETUP_DONE_HEALTH[@]}]="$health_display"

    [[ "$first" == "true" ]] && first=false || services_json+=","
    services_json+="\"${key}\":{\"name\":\"${key}\",\"health\":${health_json},\"credentials\":{\"mode\":\"${cred_mode}\"}${git_pull_json}}"
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

  # ── Step 7: Generate (staged; committed atomically below) ──
  _setup_txn_begin "$project_path" || return 1
  local config_path="$_SETUP_TXN_CONFIG"
  local muster_dir="$_SETUP_TXN_MUSTER"

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

  # Write muster.json (without absolute root path)
  _setup_write_config "$config_path" "$project_name" "$services_json" "$deploy_order_json"
  _setup_txn_commit || return 1
  config_path="${project_path}/muster.json"

  _setup_update_gitignore "$project_path"

  # Register project in global registry
  _registry_touch "$project_path"

  # Generate hook security manifest and lock hooks
  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  _hook_manifest_generate "$project_path"

  local stack_display
  stack_display=$(_setup_stack_label "$stack")

  # shellcheck disable=SC2034
  _MUSTER_TUI_FULLSCREEN="false"
  clear 2>/dev/null || true
  echo ""
  if [[ "$_SETUP_TXN_MODE" == "update" ]]; then ok "Setup updated"; else ok "Setup complete"; fi
  _setup_print_notices
  _setup_check_build_context "$config_path"
  _setup_print_complete_summary "$project_name" "$stack_display" "muster.json"
  echo ""
}
