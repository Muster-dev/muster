#!/usr/bin/env bash
# muster/lib/commands/fleet.sh — Fleet command handler

source "$MUSTER_ROOT/lib/core/fleet.sh"
source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/tui/progress.sh"
source "$MUSTER_ROOT/lib/tui/streambox.sh"
source "$MUSTER_ROOT/lib/core/credentials.sh"
source "$MUSTER_ROOT/lib/commands/history.sh"

cmd_fleet() {
  case "${1:-}" in
    init)
      _fleet_cmd_init
      ;;
    add)
      shift
      _fleet_cmd_add "$@"
      ;;
    remove|rm)
      shift
      _fleet_cmd_remove "$@"
      ;;
    pair)
      shift
      _fleet_cmd_pair "$@"
      ;;
    list|ls)
      shift
      _fleet_cmd_list "$@"
      ;;
    test)
      shift
      _fleet_cmd_test "$@"
      ;;
    group)
      shift
      _fleet_cmd_group "$@"
      ;;
    ungroup)
      shift
      _fleet_cmd_ungroup "$@"
      ;;
    deploy)
      shift
      _fleet_cmd_deploy "$@"
      ;;
    status)
      shift
      _fleet_cmd_status "$@"
      ;;
    rollback)
      shift
      _fleet_cmd_rollback "$@"
      ;;
    --help|-h)
      _fleet_cmd_help
      ;;
    "")
      if [[ -t 0 ]]; then
        _fleet_cmd_manager
      else
        _fleet_cmd_help
      fi
      ;;
    *)
      err "Unknown fleet command: $1"
      echo "Run 'muster fleet --help' for usage."
      return 1
      ;;
  esac
}

_fleet_cmd_help() {
  echo "Usage: muster fleet <command>"
  echo ""
  echo "Manage fleet deployments across multiple machines."
  echo ""
  echo "Setup:"
  echo "  init                          Create empty remotes.json"
  echo "  add <name> user@host [opts]   Add a machine to the fleet"
  echo "  remove <name>                 Remove a machine (+ stored token)"
  echo "  pair <name> --token <token>   Manually pair a muster-mode machine"
  echo "  group <name> <m1> [m2...]     Create or update a machine group"
  echo "  ungroup <name>                Remove a group"
  echo ""
  echo "Info:"
  echo "  list [--json]                 Show machines, groups, status"
  echo "  test [name|group]             Test SSH connectivity + auth"
  echo ""
  echo "Operations:"
  echo "  deploy [target] [--parallel]  Deploy to fleet machines"
  echo "  status [target] [--json]      Check health across fleet"
  echo "  rollback [target]             Rollback fleet machines"
  echo ""
  echo "Examples:"
  echo "  muster fleet init"
  echo "  muster fleet add prod-1 deploy@10.0.1.10 --mode muster --path /opt/app"
  echo "  muster fleet add prod-2 deploy@10.0.1.11 --mode push"
  echo "  muster fleet group web prod-1 prod-2"
  echo "  muster fleet deploy web"
  echo "  muster fleet deploy --parallel"
}

# ── Interactive fleet manager (from dashboard or bare `muster fleet`) ──

_fleet_cmd_manager() {
  if ! fleet_load_config; then
    info "No remotes.json found. Set up fleet via CLI:"
    echo ""
    echo -e "  ${DIM}muster fleet init${RESET}"
    echo -e "  ${DIM}muster fleet add <name> user@host [--mode muster|push]${RESET}"
    echo -e "  ${DIM}muster fleet --help${RESET}"
    echo ""
    return 0
  fi

  while true; do
    # Show fleet overview using list TUI
    _fleet_cmd_list

    local machines
    machines=$(fleet_machines)

    if [[ -z "$machines" ]]; then
      echo -e "  ${DIM}Add machines via CLI: muster fleet add <name> user@host${RESET}"
      echo ""
      return 0
    fi

    # Operations menu (no CRUD — that's CLI only)
    local actions=()
    actions[${#actions[@]}]="Deploy"
    actions[${#actions[@]}]="Status"
    actions[${#actions[@]}]="Test connections"
    actions[${#actions[@]}]="Rollback"
    actions[${#actions[@]}]="Back"

    menu_select "Fleet" "${actions[@]}"

    case "$MENU_RESULT" in
      "Deploy")
        _fleet_cmd_deploy
        echo ""
        echo -e "  ${DIM}Press any key to continue...${RESET}"
        IFS= read -rsn1 || true
        ;;
      "Status")
        _fleet_cmd_status
        echo ""
        echo -e "  ${DIM}Press any key to continue...${RESET}"
        IFS= read -rsn1 || true
        ;;
      "Test connections")
        _fleet_cmd_test
        echo ""
        echo -e "  ${DIM}Press any key to continue...${RESET}"
        IFS= read -rsn1 || true
        ;;
      "Rollback")
        _fleet_cmd_rollback
        echo ""
        echo -e "  ${DIM}Press any key to continue...${RESET}"
        IFS= read -rsn1 || true
        ;;
      "Back")
        return 0
        ;;
    esac
  done
}

# ── init ──

_fleet_cmd_init() {
  fleet_init
}

# ── add ──

_fleet_cmd_add() {
  local name="" userhost="" mode="push" port="22" path="" key="" transport="ssh"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode|-m) mode="$2"; shift 2 ;;
      --port|-p) port="$2"; shift 2 ;;
      --path) path="$2"; shift 2 ;;
      --key|-k) key="$2"; shift 2 ;;
      --transport|-t) transport="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: muster fleet add <name> user@host [options]"
        echo ""
        echo "Options:"
        echo "  --mode, -m <muster|push>    Deploy mode (default: push)"
        echo "  --transport, -t <ssh|cloud>  Transport layer (default: ssh)"
        echo "  --port, -p <N>              SSH port (default: 22)"
        echo "  --path <dir>                Project directory on remote"
        echo "  --key, -k <file>            SSH identity file"
        echo ""
        echo "Modes:"
        echo "  muster   Remote has muster installed (SSH + muster deploy)"
        echo "  push     Pipe hook scripts over SSH (no muster needed)"
        echo ""
        echo "Transports:"
        echo "  ssh      Direct SSH connection (default)"
        echo "  cloud    Connect via muster-tunnel relay"
        return 0
        ;;
      --*)
        err "Unknown flag: $1"
        return 1
        ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
        elif [[ -z "$userhost" ]]; then
          userhost="$1"
        else
          err "Unexpected argument: $1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$name" || -z "$userhost" ]]; then
    err "Usage: muster fleet add <name> user@host [--mode muster|push] [--transport ssh|cloud]"
    return 1
  fi

  # Parse user@host
  local user host
  if [[ "$userhost" == *"@"* ]]; then
    user="${userhost%%@*}"
    host="${userhost#*@}"
  else
    err "Expected user@host format, got: ${userhost}"
    return 1
  fi

  # Ensure fleet config exists
  if ! fleet_load_config; then
    err "No remotes.json found. Run 'muster fleet init' first."
    return 1
  fi

  fleet_add_machine "$name" "$host" "$user" "$port" "$key" "$path" "$mode" "$transport" || return 1

  if [[ "$transport" == "cloud" ]]; then
    # Cloud transport: check for muster-tunnel, validate cloud config
    source "$MUSTER_ROOT/lib/core/cloud.sh"

    if ! _fleet_cloud_available; then
      echo ""
      warn "muster-tunnel not installed"
      echo -e "  ${DIM}Install: curl -sSL https://getmuster.dev/cloud | bash${RESET}"
    fi

    # Check if remotes.json has a cloud section
    local _relay
    _relay=$(fleet_get '.cloud.relay // ""')
    if [[ -z "$_relay" || "$_relay" == "null" ]]; then
      echo ""
      warn "No cloud config in remotes.json"
      echo -e "  ${DIM}Add a \"cloud\" section with relay URL and org_id to remotes.json${RESET}"
    fi

    echo ""
    info "Cloud machine added. Deploy via: muster fleet deploy ${name}"
    echo -e "  ${DIM}Ensure muster-agent is running on the remote and connected to the relay.${RESET}"
  else
    # SSH transport: test connectivity
    echo ""
    start_spinner "Testing SSH connectivity..."
    if fleet_check "$name"; then
      stop_spinner
      ok "SSH connection to ${user}@${host}:${port} succeeded"
    else
      stop_spinner
      warn "SSH connection to ${user}@${host}:${port} failed"
      echo -e "  ${DIM}Machine added but not reachable. Check SSH config and try: muster fleet test ${name}${RESET}"
    fi

    # Auto-pair for muster mode
    if [[ "$mode" == "muster" ]]; then
      echo ""
      fleet_auto_pair "$name"
    fi
  fi
}

# ── remove ──

_fleet_cmd_remove() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    err "Usage: muster fleet remove <name>"
    return 1
  fi

  if ! fleet_load_config; then
    err "No remotes.json found"
    return 1
  fi

  fleet_remove_machine "$name"
}

# ── pair ──

_fleet_cmd_pair() {
  local name="" token=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token|-t) token="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: muster fleet pair <name> --token <token>"
        echo ""
        echo "Manually store an auth token for a muster-mode machine."
        echo ""
        echo "To get a token, run on the remote:"
        echo "  muster auth create fleet-\$(hostname) --scope deploy"
        return 0
        ;;
      --*)
        err "Unknown flag: $1"
        return 1
        ;;
      *)
        name="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$name" || -z "$token" ]]; then
    err "Usage: muster fleet pair <name> --token <token>"
    return 1
  fi

  if ! fleet_load_config; then
    err "No remotes.json found"
    return 1
  fi

  # Verify machine exists
  local existing
  existing=$(fleet_get ".machines.\"${name}\" // empty")
  if [[ -z "$existing" ]]; then
    err "Machine '${name}' not found in remotes.json"
    return 1
  fi

  fleet_token_set "$name" "$token"
  ok "Token stored for '${name}'"

  # Verify if possible
  start_spinner "Verifying token..."
  if fleet_verify_pair "$name"; then
    stop_spinner
    ok "Token verified — $(fleet_desc "$name") is paired"
  else
    stop_spinner
    warn "Token stored but verification failed. Check that the remote is reachable and the token is valid."
  fi
}

# ── list ──

_fleet_cmd_list() {
  local json_mode=false
  [[ "${1:-}" == "--json" ]] && json_mode=true

  if ! fleet_load_config; then
    if [[ "$json_mode" == "true" ]]; then
      printf '{"machines":[],"groups":[]}\n'
    else
      info "No remotes.json found. Run 'muster fleet init' to get started."
    fi
    return 0
  fi

  if [[ "$json_mode" == "true" ]]; then
    jq '.' "$FLEET_CONFIG_FILE"
    return 0
  fi

  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local inner=$(( w - 2 ))

  echo ""

  local machines
  machines=$(fleet_machines)

  # ── Machines box ──
  local label="Machines"
  local label_pad_len=$(( w - ${#label} - 3 ))
  (( label_pad_len < 1 )) && label_pad_len=1
  local label_pad
  label_pad=$(printf '%*s' "$label_pad_len" "" | sed 's/ /─/g')
  printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$label" "${RESET}${ACCENT}" "$label_pad" "${RESET}"

  if [[ -z "$machines" ]]; then
    local _empty="No machines configured"
    local _epad_len=$(( inner - ${#_empty} - 2 ))
    (( _epad_len < 0 )) && _epad_len=0
    local _epad
    _epad=$(printf '%*s' "$_epad_len" "")
    printf '  %b│%b  %b%s%b%s%b│%b\n' "${ACCENT}" "${RESET}" "${DIM}" "$_empty" "${RESET}" "$_epad" "${ACCENT}" "${RESET}"
  else
    while IFS= read -r machine; do
      [[ -z "$machine" ]] && continue
      _fleet_load_machine "$machine"

      local host_str="${_FM_USER}@${_FM_HOST}"
      [[ "$_FM_PORT" != "22" ]] && host_str="${host_str}:${_FM_PORT}"

      local status_icon status_color tag=""
      if [[ "$_FM_TRANSPORT" == "cloud" ]]; then
        status_icon="●"; status_color="$BLUE"
        tag=" cloud"
      elif [[ "$_FM_MODE" == "muster" ]]; then
        local token
        token=$(fleet_token_get "$machine")
        if [[ -n "$token" ]]; then
          status_icon="●"; status_color="$GREEN"
        else
          status_icon="●"; status_color="$YELLOW"
          tag=" unpaired"
        fi
      else
        status_icon="●"; status_color="$GREEN"
      fi

      local _transport_label=""
      [[ "$_FM_TRANSPORT" == "cloud" ]] && _transport_label=", cloud"
      local display="${machine}: ${host_str} (${_FM_MODE}${_transport_label})"
      local tag_len=${#tag}
      local max_display=$(( inner - 4 - tag_len ))
      (( max_display < 5 )) && max_display=5
      if (( ${#display} > max_display )); then
        display="${display:0:$((max_display - 3))}..."
      fi

      local content_len=$(( 4 + ${#display} + tag_len ))
      local pad_len=$(( inner - content_len ))
      (( pad_len < 0 )) && pad_len=0
      local pad
      pad=$(printf '%*s' "$pad_len" "")

      if [[ -n "$tag" ]]; then
        printf '  %b│%b  %b%s%b %s%s%b%s%b%b│%b\n' \
          "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" \
          "$display" "$pad" "${YELLOW}" "$tag" "${RESET}" "${ACCENT}" "${RESET}"
      else
        printf '  %b│%b  %b%s%b %s%s%b│%b\n' \
          "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" \
          "$display" "$pad" "${ACCENT}" "${RESET}"
      fi
    done <<< "$machines"
  fi

  local bottom
  bottom=$(printf '%*s' "$w" "" | sed 's/ /─/g')
  printf '  %b└%s┘%b\n' "${ACCENT}" "$bottom" "${RESET}"

  # ── Groups box ──
  local groups
  groups=$(fleet_groups)

  if [[ -n "$groups" ]]; then
    echo ""
    local glabel="Groups"
    local glabel_pad_len=$(( w - ${#glabel} - 3 ))
    (( glabel_pad_len < 1 )) && glabel_pad_len=1
    local glabel_pad
    glabel_pad=$(printf '%*s' "$glabel_pad_len" "" | sed 's/ /─/g')
    printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$glabel" "${RESET}${ACCENT}" "$glabel_pad" "${RESET}"

    while IFS= read -r group; do
      [[ -z "$group" ]] && continue
      local members
      members=$(fleet_group_machines "$group" | tr '\n' ', ' | sed 's/,$//')
      local gdisplay="${group}: ${members}"
      local gmax=$(( inner - 4 ))
      if (( ${#gdisplay} > gmax )); then
        gdisplay="${gdisplay:0:$((gmax - 3))}..."
      fi
      local gcontent_len=$(( 4 + ${#gdisplay} ))
      local gpad_len=$(( inner - gcontent_len ))
      (( gpad_len < 0 )) && gpad_len=0
      local gpad
      gpad=$(printf '%*s' "$gpad_len" "")
      printf '  %b│%b  %b○%b %b%s%b%s%b│%b\n' \
        "${ACCENT}" "${RESET}" "${DIM}" "${RESET}" \
        "${WHITE}" "$gdisplay" "${RESET}" "$gpad" "${ACCENT}" "${RESET}"
    done <<< "$groups"

    local gbottom
    gbottom=$(printf '%*s' "$w" "" | sed 's/ /─/g')
    printf '  %b└%s┘%b\n' "${ACCENT}" "$gbottom" "${RESET}"
  fi

  # Deploy order
  local deploy_order
  deploy_order=$(fleet_deploy_order)
  if [[ -n "$deploy_order" ]]; then
    echo ""
    local order_str=""
    while IFS= read -r _grp; do
      [[ -z "$_grp" ]] && continue
      if [[ -n "$order_str" ]]; then
        order_str="${order_str} -> ${_grp}"
      else
        order_str="$_grp"
      fi
    done <<< "$deploy_order"
    echo -e "  ${DIM}Deploy order:${RESET} ${order_str}"
  fi

  echo ""
}

# ── test ──

_fleet_cmd_test() {
  local target="${1:-}"

  if ! fleet_load_config; then
    err "No remotes.json found"
    return 1
  fi

  local machines_to_test=()

  if [[ -z "$target" ]]; then
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      machines_to_test[${#machines_to_test[@]}]="$m"
    done < <(fleet_machines)
  else
    local group_members
    group_members=$(fleet_group_machines "$target" 2>/dev/null)
    if [[ -n "$group_members" ]]; then
      while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        machines_to_test[${#machines_to_test[@]}]="$m"
      done <<< "$group_members"
    else
      machines_to_test[0]="$target"
    fi
  fi

  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local inner=$(( w - 2 ))

  echo ""

  local label="Connectivity"
  local label_pad_len=$(( w - ${#label} - 3 ))
  (( label_pad_len < 1 )) && label_pad_len=1
  local label_pad
  label_pad=$(printf '%*s' "$label_pad_len" "" | sed 's/ /─/g')
  printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$label" "${RESET}${ACCENT}" "$label_pad" "${RESET}"

  local pass=0 fail=0
  local i=0
  while (( i < ${#machines_to_test[@]} )); do
    local machine="${machines_to_test[$i]}"
    _fleet_load_machine "$machine"

    local status_icon status_color tag=""

    if [[ "$_FM_TRANSPORT" == "cloud" ]]; then
      # Cloud transport test
      if fleet_check "$machine"; then
        status_icon="●"; status_color="$GREEN"
        tag=" cloud ok"
        pass=$(( pass + 1 ))
      else
        source "$MUSTER_ROOT/lib/core/cloud.sh"
        if ! _fleet_cloud_available; then
          status_icon="●"; status_color="$YELLOW"
          tag=" no tunnel"
        else
          status_icon="●"; status_color="$RED"
          tag=" cloud fail"
        fi
        fail=$(( fail + 1 ))
      fi
    elif fleet_check "$machine"; then
      # SSH test passed
      status_icon="●"; status_color="$GREEN"
      tag=" SSH ok"

      # Token test (muster mode only)
      if [[ "$_FM_MODE" == "muster" ]]; then
        local token
        token=$(fleet_token_get "$machine")
        if [[ -z "$token" ]]; then
          status_icon="●"; status_color="$YELLOW"
          tag=" unpaired"
        elif fleet_verify_pair "$machine"; then
          tag=" SSH ok, token ok"
        else
          status_icon="●"; status_color="$RED"
          tag=" SSH ok, token fail"
          fail=$(( fail + 1 ))
          i=$(( i + 1 ))

          # Render line before continue
          local _display="$machine"
          local _tag_len=${#tag}
          local _max=$(( inner - 4 - _tag_len ))
          (( _max < 5 )) && _max=5
          (( ${#_display} > _max )) && _display="${_display:0:$((_max - 3))}..."
          local _clen=$(( 4 + ${#_display} + _tag_len ))
          local _plen=$(( inner - _clen ))
          (( _plen < 0 )) && _plen=0
          local _pad
          _pad=$(printf '%*s' "$_plen" "")
          printf '  %b│%b  %b%s%b %s%s%b%s%b%b│%b\n' \
            "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" \
            "$_display" "$_pad" "$RED" "$tag" "${RESET}" "${ACCENT}" "${RESET}"
          continue
        fi
      fi

      pass=$(( pass + 1 ))
    else
      status_icon="●"; status_color="$RED"
      tag=" SSH fail"
      fail=$(( fail + 1 ))
    fi

    local display="$machine"
    local tag_len=${#tag}
    local max_display=$(( inner - 4 - tag_len ))
    (( max_display < 5 )) && max_display=5
    if (( ${#display} > max_display )); then
      display="${display:0:$((max_display - 3))}..."
    fi

    local content_len=$(( 4 + ${#display} + tag_len ))
    local pad_len=$(( inner - content_len ))
    (( pad_len < 0 )) && pad_len=0
    local pad
    pad=$(printf '%*s' "$pad_len" "")

    local tag_color="$GREEN"
    (( fail > 0 )) && [[ "$status_color" == "$RED" ]] && tag_color="$RED"
    [[ "$status_color" == "$YELLOW" ]] && tag_color="$YELLOW"

    printf '  %b│%b  %b%s%b %s%s%b%s%b%b│%b\n' \
      "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" \
      "$display" "$pad" "$tag_color" "$tag" "${RESET}" "${ACCENT}" "${RESET}"

    i=$(( i + 1 ))
  done

  local bottom
  bottom=$(printf '%*s' "$w" "" | sed 's/ /─/g')
  printf '  %b└%s┘%b\n' "${ACCENT}" "$bottom" "${RESET}"

  echo ""
  if (( fail == 0 )); then
    ok "All ${pass} machine(s) passed"
  else
    warn "${pass} passed, ${fail} failed"
  fi
  echo ""
}

# ── group ──

_fleet_cmd_group() {
  local group_name="${1:-}"
  shift 2>/dev/null || true

  if [[ -z "$group_name" ]]; then
    err "Usage: muster fleet group <name> <machine1> [machine2...]"
    return 1
  fi

  if [[ $# -eq 0 ]]; then
    err "Usage: muster fleet group <name> <machine1> [machine2...]"
    return 1
  fi

  if ! fleet_load_config; then
    err "No remotes.json found"
    return 1
  fi

  # Validate all machines exist
  local _m
  for _m in "$@"; do
    local exists
    exists=$(fleet_get ".machines.\"${_m}\" // empty")
    if [[ -z "$exists" ]]; then
      err "Machine '${_m}' not found in remotes.json"
      return 1
    fi
  done

  fleet_set_group "$group_name" "$@"
}

# ── ungroup ──

_fleet_cmd_ungroup() {
  local group_name="${1:-}"
  if [[ -z "$group_name" ]]; then
    err "Usage: muster fleet ungroup <name>"
    return 1
  fi

  if ! fleet_load_config; then
    err "No remotes.json found"
    return 1
  fi

  fleet_remove_group "$group_name"
}

# ── deploy ──

_fleet_cmd_deploy() {
  local target="" parallel=false dry_run=false json_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel) parallel=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      --json) json_mode=true; shift ;;
      --help|-h)
        echo "Usage: muster fleet deploy [target] [--parallel] [--dry-run] [--json]"
        echo ""
        echo "Deploy to fleet machines. Target can be a machine name, group name,"
        echo "or omitted to deploy to all machines following deploy_order."
        echo ""
        echo "Options:"
        echo "  --parallel    Deploy to all target machines in parallel"
        echo "  --dry-run     Preview deploy plan without executing"
        echo "  --json        Output as NDJSON events"
        return 0
        ;;
      --*)
        err "Unknown flag: $1"
        return 1
        ;;
      *)
        target="$1"
        shift
        ;;
    esac
  done

  if ! fleet_load_config; then
    err "No remotes.json found. Run 'muster fleet init' first."
    return 1
  fi

  load_config

  # Resolve target to list of machines
  local machines=()
  if [[ -n "$target" ]]; then
    # Check if it's a group
    local group_members
    group_members=$(fleet_group_machines "$target" 2>/dev/null)
    if [[ -n "$group_members" ]]; then
      while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        machines[${#machines[@]}]="$m"
      done <<< "$group_members"
    else
      # Single machine
      local exists
      exists=$(fleet_get ".machines.\"${target}\" // empty")
      if [[ -z "$exists" ]]; then
        err "Unknown machine or group: ${target}"
        return 1
      fi
      machines[0]="$target"
    fi
  else
    # Use deploy_order (groups in order), then ungrouped machines
    local ordered_groups
    ordered_groups=$(fleet_deploy_order)
    local _added_machines=""

    if [[ -n "$ordered_groups" ]]; then
      while IFS= read -r grp; do
        [[ -z "$grp" ]] && continue
        local grp_members
        grp_members=$(fleet_group_machines "$grp" 2>/dev/null)
        while IFS= read -r m; do
          [[ -z "$m" ]] && continue
          # Skip duplicates
          case " $_added_machines " in
            *" $m "*) continue ;;
          esac
          machines[${#machines[@]}]="$m"
          _added_machines="${_added_machines} ${m}"
        done <<< "$grp_members"
      done <<< "$ordered_groups"
    fi

    # Add any machines not in groups
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      case " $_added_machines " in
        *" $m "*) continue ;;
      esac
      machines[${#machines[@]}]="$m"
    done < <(fleet_machines)
  fi

  if (( ${#machines[@]} == 0 )); then
    warn "No machines to deploy to"
    return 0
  fi

  local total=${#machines[@]}

  # Dry run (no env loading needed)
  if [[ "$dry_run" == "true" ]]; then
    _fleet_deploy_dry_run "${machines[@]}"
    return 0
  fi

  _load_env_file

  echo ""
  echo -e "  ${BOLD}${ACCENT_BRIGHT}Fleet Deploy${RESET} — ${total} machine(s)"
  echo ""

  if [[ "$parallel" == "true" ]]; then
    _fleet_deploy_parallel "${machines[@]}"
  else
    _fleet_deploy_sequential "${machines[@]}"
  fi

  _unload_env_file
}

# ── Deploy: dry run ──

_fleet_deploy_dry_run() {
  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local inner=$(( w - 2 ))

  echo ""

  local label="Deploy Plan (dry-run)"
  local label_pad_len=$(( w - ${#label} - 3 ))
  (( label_pad_len < 1 )) && label_pad_len=1
  local label_pad
  label_pad=$(printf '%*s' "$label_pad_len" "" | sed 's/ /─/g')
  printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$label" "${RESET}${ACCENT}" "$label_pad" "${RESET}"

  local idx=0
  for machine in "$@"; do
    idx=$(( idx + 1 ))
    _fleet_load_machine "$machine"

    local host_str="${_FM_USER}@${_FM_HOST}"
    [[ "$_FM_PORT" != "22" ]] && host_str="${host_str}:${_FM_PORT}"

    local status_icon="○" status_color="$DIM" tag=""

    if [[ "$_FM_MODE" == "muster" ]]; then
      local token
      token=$(fleet_token_get "$machine")
      if [[ -n "$token" ]]; then
        status_icon="●"; status_color="$GREEN"
      else
        status_icon="●"; status_color="$YELLOW"
        tag=" unpaired"
      fi
    else
      status_icon="●"; status_color="$GREEN"
    fi

    local display="${idx}. ${machine}: ${host_str} (${_FM_MODE})"
    local tag_len=${#tag}
    local max_display=$(( inner - 4 - tag_len ))
    (( max_display < 5 )) && max_display=5
    if (( ${#display} > max_display )); then
      display="${display:0:$((max_display - 3))}..."
    fi

    local content_len=$(( 4 + ${#display} + tag_len ))
    local pad_len=$(( inner - content_len ))
    (( pad_len < 0 )) && pad_len=0
    local pad
    pad=$(printf '%*s' "$pad_len" "")

    if [[ -n "$tag" ]]; then
      printf '  %b│%b  %b%s%b %s%s%b%s%b%b│%b\n' \
        "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" \
        "$display" "$pad" "${YELLOW}" "$tag" "${RESET}" "${ACCENT}" "${RESET}"
    else
      printf '  %b│%b  %b%s%b %s%s%b│%b\n' \
        "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" \
        "$display" "$pad" "${ACCENT}" "${RESET}"
    fi
  done

  local bottom
  bottom=$(printf '%*s' "$w" "" | sed 's/ /─/g')
  printf '  %b└%s┘%b\n' "${ACCENT}" "$bottom" "${RESET}"

  echo ""
  info "Dry-run complete — no changes made"
  echo ""
}

# ── Deploy: sequential ──

_fleet_deploy_sequential() {
  local total=$#
  local current=0
  local succeeded=0 failed=0

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local log_dir="${project_dir}/.muster/logs"
  mkdir -p "$log_dir"

  for machine in "$@"; do
    current=$(( current + 1 ))
    _fleet_load_machine "$machine"

    progress_bar "$current" "$total" "Fleet: ${machine}..."
    echo ""

    local log_file="${log_dir}/fleet-${machine}-$(date +%Y%m%d-%H%M%S).log"
    local rc=0

    while true; do
      if [[ "$_FM_MODE" == "muster" ]]; then
        _fleet_deploy_muster "$machine" "$log_file"
        rc=$?
      else
        _fleet_deploy_push "$machine" "$log_file"
        rc=$?
      fi

      if (( rc == 0 )); then
        ok "${machine} deployed"
        _history_log_event "fleet:${machine}" "deploy" "ok" ""
        succeeded=$(( succeeded + 1 ))
        break
      else
        err "${machine} deploy failed"
        _history_log_event "fleet:${machine}" "deploy" "failed" ""

        # Show last few lines
        if [[ -f "$log_file" ]]; then
          echo ""
          tail -5 "$log_file" | while IFS= read -r _line; do
            echo -e "  ${DIM}${_line}${RESET}"
          done
          echo ""
        fi

        menu_select "Fleet deploy failed on ${machine}. What do you want to do?" \
          "Retry" "Skip and continue" "Abort"

        case "$MENU_RESULT" in
          "Retry")
            log_file="${log_dir}/fleet-${machine}-$(date +%Y%m%d-%H%M%S).log"
            ;; # loop continues
          "Skip and continue")
            failed=$(( failed + 1 ))
            break
            ;;
          "Abort")
            failed=$(( failed + 1 ))
            echo ""
            _fleet_deploy_summary "$succeeded" "$failed" "$total"
            return 1
            ;;
        esac
      fi
    done
  done

  echo ""
  _fleet_deploy_summary "$succeeded" "$failed" "$total"
}

# Deploy to a muster-mode machine
_fleet_deploy_muster() {
  local machine="$1" log_file="$2"
  _fleet_load_machine "$machine"

  local token
  token=$(fleet_token_get "$machine")

  if [[ -z "$token" ]]; then
    err "No token for ${machine} — run: muster fleet pair ${machine} --token <token>"
    return 1
  fi

  info "Deploying on ${machine} via muster ($(fleet_desc "$machine"))"

  # Run muster deploy on remote with token
  local cmd="MUSTER_TOKEN=${token} muster deploy"
  if [[ -n "$_FM_PROJECT_DIR" ]]; then
    cmd="cd ${_FM_PROJECT_DIR} && ${cmd}"
  fi

  stream_in_box "${machine}" "$log_file" fleet_exec "$machine" "$cmd"
}

# Deploy to a push-mode machine
_fleet_deploy_push() {
  local machine="$1" log_file="$2"
  _fleet_load_machine "$machine"

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  info "Deploying to ${machine} via push ($(fleet_desc "$machine"))"

  # Get services to deploy
  local services=()
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local skip
    skip=$(config_get ".services.${svc}.skip_deploy")
    [[ "$skip" == "true" ]] && continue
    services[${#services[@]}]="$svc"
  done < <(config_get '.deploy_order[]' 2>/dev/null || config_services)

  local svc_rc=0
  for svc in "${services[@]}"; do
    local hook="${project_dir}/.muster/hooks/${svc}/deploy.sh"
    if [[ ! -x "$hook" ]]; then
      warn "No deploy hook for ${svc}, skipping"
      continue
    fi

    # Gather env vars
    local env_lines=""
    local _cred_env
    _cred_env=$(cred_env_for_service "$svc")
    [[ -n "$_cred_env" ]] && env_lines="${_cred_env}"
    local _k8s_env
    _k8s_env=$(k8s_env_for_service "$svc")
    if [[ -n "$_k8s_env" ]]; then
      [[ -n "$env_lines" ]] && env_lines="${env_lines}
${_k8s_env}"
      [[ -z "$env_lines" ]] && env_lines="$_k8s_env"
    fi

    info "  ${svc} → ${machine}"
    fleet_push_hook "$machine" "$hook" "$env_lines" >> "$log_file" 2>&1
    local hook_rc=$?
    if (( hook_rc != 0 )); then
      err "  ${svc} failed on ${machine}"
      svc_rc=1
      break
    fi
  done

  return $svc_rc
}

# ── Deploy: parallel ──

_fleet_deploy_parallel() {
  local total=$#
  local machines=("$@")

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local log_dir="${project_dir}/.muster/logs"
  mkdir -p "$log_dir"

  # Create temp dir for status tracking
  local tmp_dir="${TMPDIR:-/tmp}/muster-fleet-$$"
  mkdir -p "$tmp_dir"

  info "Deploying to ${total} machines in parallel..."
  echo ""

  # Spawn background processes (cap at 10 concurrent)
  local max_concurrent=10
  local pids=()
  local pid_machines=()
  local batch_start=0

  while (( batch_start < ${#machines[@]} )); do
    local batch_end=$(( batch_start + max_concurrent ))
    (( batch_end > ${#machines[@]} )) && batch_end=${#machines[@]}

    local i=$batch_start
    while (( i < batch_end )); do
      local machine="${machines[$i]}"
      local log_file="${log_dir}/fleet-${machine}-$(date +%Y%m%d-%H%M%S).log"
      local status_file="${tmp_dir}/${machine}.status"

      (
        _fleet_load_machine "$machine"
        local _rc=0
        local _start
        _start=$(date +%s)

        if [[ "$_FM_MODE" == "muster" ]]; then
          local _token
          _token=$(fleet_token_get "$machine")
          if [[ -z "$_token" ]]; then
            echo "1" > "$status_file"
            exit 1
          fi
          local _cmd="MUSTER_TOKEN=${_token} muster deploy"
          [[ -n "$_FM_PROJECT_DIR" ]] && _cmd="cd ${_FM_PROJECT_DIR} && ${_cmd}"
          fleet_exec "$machine" "$_cmd" >> "$log_file" 2>&1
          _rc=$?
        else
          local _proj_dir
          _proj_dir="$(dirname "$CONFIG_FILE")"
          while IFS= read -r _svc; do
            [[ -z "$_svc" ]] && continue
            local _skip
            _skip=$(config_get ".services.${_svc}.skip_deploy")
            [[ "$_skip" == "true" ]] && continue
            local _hook="${_proj_dir}/.muster/hooks/${_svc}/deploy.sh"
            [[ ! -x "$_hook" ]] && continue

            local _env=""
            local _ce
            _ce=$(cred_env_for_service "$_svc")
            [[ -n "$_ce" ]] && _env="$_ce"
            local _ke
            _ke=$(k8s_env_for_service "$_svc")
            if [[ -n "$_ke" ]]; then
              [[ -n "$_env" ]] && _env="${_env}
${_ke}"
              [[ -z "$_env" ]] && _env="$_ke"
            fi

            fleet_push_hook "$machine" "$_hook" "$_env" >> "$log_file" 2>&1 || { _rc=1; break; }
          done < <(config_get '.deploy_order[]' 2>/dev/null || config_services)
        fi

        local _end
        _end=$(date +%s)
        local _duration=$(( _end - _start ))

        if (( _rc == 0 )); then
          echo "0|${_duration}" > "$status_file"
          _history_log_event "fleet:${machine}" "deploy" "ok" ""
        else
          echo "1|${_duration}" > "$status_file"
          _history_log_event "fleet:${machine}" "deploy" "failed" ""
        fi
      ) &

      pids[${#pids[@]}]=$!
      pid_machines[${#pid_machines[@]}]="$machine"
      i=$(( i + 1 ))
    done

    # Wait for this batch
    local _done=0
    while (( _done < ${#pids[@]} )); do
      _done=0
      local p_idx=0
      while (( p_idx < ${#pids[@]} )); do
        if ! kill -0 "${pids[$p_idx]}" 2>/dev/null; then
          _done=$(( _done + 1 ))
        fi
        p_idx=$(( p_idx + 1 ))
      done

      printf '\r  %b%s%b Deploying (%d/%d done...)' "${DIM}" "⠋" "${RESET}" "$_done" "${#pids[@]}"
      sleep 1
    done
    printf '\r%*s\r' 60 ''

    # Wait for all pids in batch
    local p_idx=0
    while (( p_idx < ${#pids[@]} )); do
      wait "${pids[$p_idx]}" 2>/dev/null
      p_idx=$(( p_idx + 1 ))
    done

    batch_start=$batch_end
    pids=()
    pid_machines=()
  done

  # Collect results in a box
  local _rw=$(( TERM_COLS - 4 ))
  (( _rw > 50 )) && _rw=50
  (( _rw < 10 )) && _rw=10
  local _rinner=$(( _rw - 2 ))

  echo ""

  local _rlabel="Results"
  local _rlabel_pad_len=$(( _rw - ${#_rlabel} - 3 ))
  (( _rlabel_pad_len < 1 )) && _rlabel_pad_len=1
  local _rlabel_pad
  _rlabel_pad=$(printf '%*s' "$_rlabel_pad_len" "" | sed 's/ /─/g')
  printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$_rlabel" "${RESET}${ACCENT}" "$_rlabel_pad" "${RESET}"

  local succeeded=0 failed=0
  local failed_machines=""
  local m_idx=0
  while (( m_idx < ${#machines[@]} )); do
    local machine="${machines[$m_idx]}"
    local status_file="${tmp_dir}/${machine}.status"

    local rc="1" duration="?"
    if [[ -f "$status_file" ]]; then
      local status_line
      status_line=$(cat "$status_file")
      rc="${status_line%%|*}"
      duration="${status_line#*|}"
    fi

    local _rs_icon _rs_color _rs_tag
    if [[ "$rc" == "0" ]]; then
      _rs_icon="●"; _rs_color="$GREEN"; _rs_tag=" ${duration}s"
      succeeded=$(( succeeded + 1 ))
    else
      _rs_icon="●"; _rs_color="$RED"; _rs_tag=" failed (${duration}s)"
      failed=$(( failed + 1 ))
      [[ -n "$failed_machines" ]] && failed_machines="${failed_machines} ${machine}"
      [[ -z "$failed_machines" ]] && failed_machines="$machine"
    fi

    local _rs_display="$machine"
    local _rs_tag_len=${#_rs_tag}
    local _rs_max=$(( _rinner - 4 - _rs_tag_len ))
    (( _rs_max < 5 )) && _rs_max=5
    (( ${#_rs_display} > _rs_max )) && _rs_display="${_rs_display:0:$((_rs_max - 3))}..."
    local _rs_clen=$(( 4 + ${#_rs_display} + _rs_tag_len ))
    local _rs_plen=$(( _rinner - _rs_clen ))
    (( _rs_plen < 0 )) && _rs_plen=0
    local _rs_pad
    _rs_pad=$(printf '%*s' "$_rs_plen" "")

    printf '  %b│%b  %b%s%b %s%s%b%s%b%b│%b\n' \
      "${ACCENT}" "${RESET}" "$_rs_color" "$_rs_icon" "${RESET}" \
      "$_rs_display" "$_rs_pad" "$_rs_color" "$_rs_tag" "${RESET}" "${ACCENT}" "${RESET}"

    m_idx=$(( m_idx + 1 ))
  done

  local _rbottom
  _rbottom=$(printf '%*s' "$_rw" "" | sed 's/ /─/g')
  printf '  %b└%s┘%b\n' "${ACCENT}" "$_rbottom" "${RESET}"

  echo ""
  _fleet_deploy_summary "$succeeded" "$failed" "$total"

  # Cleanup
  rm -rf "$tmp_dir"

  # Offer retry for failed machines
  if (( failed > 0 )); then
    menu_select "Some machines failed. What do you want to do?" \
      "Retry failed" "View logs" "Continue"

    case "$MENU_RESULT" in
      "Retry failed")
        _fleet_deploy_sequential $failed_machines
        ;;
      "View logs")
        for m in $failed_machines; do
          local latest_log
          latest_log=$(ls -t "${log_dir}/fleet-${m}-"*.log 2>/dev/null | head -1)
          if [[ -n "$latest_log" ]]; then
            echo ""
            echo -e "  ${BOLD}${m}:${RESET}"
            tail -10 "$latest_log" | while IFS= read -r _line; do
              echo -e "  ${DIM}${_line}${RESET}"
            done
          fi
        done
        echo ""
        ;;
    esac
  fi
}

# Deploy summary line
_fleet_deploy_summary() {
  local succeeded="$1" failed="$2" total="$3"
  if (( failed == 0 )); then
    ok "Fleet deploy complete — ${succeeded}/${total} succeeded"
  else
    warn "Fleet deploy complete — ${succeeded} succeeded, ${failed} failed (${total} total)"
  fi
  echo ""
}

# ── status ──

_fleet_cmd_status() {
  local target="" json_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=true; shift ;;
      --help|-h)
        echo "Usage: muster fleet status [target] [--json]"
        return 0
        ;;
      --*)
        err "Unknown flag: $1"
        return 1
        ;;
      *)
        target="$1"
        shift
        ;;
    esac
  done

  if ! fleet_load_config; then
    err "No remotes.json found"
    return 1
  fi

  # Resolve machines
  local machines=()
  if [[ -n "$target" ]]; then
    local group_members
    group_members=$(fleet_group_machines "$target" 2>/dev/null)
    if [[ -n "$group_members" ]]; then
      while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        machines[${#machines[@]}]="$m"
      done <<< "$group_members"
    else
      machines[0]="$target"
    fi
  else
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      machines[${#machines[@]}]="$m"
    done < <(fleet_machines)
  fi

  if [[ "$json_mode" == "true" ]]; then
    _fleet_status_json "${machines[@]}"
    return 0
  fi

  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local inner=$(( w - 2 ))

  echo ""

  local label="Fleet Status"
  local label_pad_len=$(( w - ${#label} - 3 ))
  (( label_pad_len < 1 )) && label_pad_len=1
  local label_pad
  label_pad=$(printf '%*s' "$label_pad_len" "" | sed 's/ /─/g')
  printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$label" "${RESET}${ACCENT}" "$label_pad" "${RESET}"

  local i=0
  while (( i < ${#machines[@]} )); do
    local machine="${machines[$i]}"
    _fleet_load_machine "$machine"

    local host_str="${_FM_USER}@${_FM_HOST}"
    [[ "$_FM_PORT" != "22" ]] && host_str="${host_str}:${_FM_PORT}"

    local status_icon status_color tag=""

    # Check connectivity
    if fleet_check "$machine"; then
      if [[ "$_FM_MODE" == "muster" ]]; then
        local token
        token=$(fleet_token_get "$machine")
        if [[ -n "$token" ]]; then
          local remote_status
          remote_status=$(fleet_exec "$machine" "MUSTER_TOKEN=${token} muster status --json" 2>/dev/null)
          if printf '%s' "$remote_status" | jq -e '.services' &>/dev/null; then
            local svc_count healthy_count
            svc_count=$(printf '%s' "$remote_status" | jq '.services | length')
            healthy_count=$(printf '%s' "$remote_status" | jq '[.services[] | select(.healthy == true)] | length')
            status_icon="●"; status_color="$GREEN"
            tag=" ${healthy_count}/${svc_count} healthy"
          else
            status_icon="●"; status_color="$GREEN"
            tag=" reachable"
          fi
        else
          status_icon="●"; status_color="$YELLOW"
          tag=" unpaired"
        fi
      else
        status_icon="●"; status_color="$GREEN"
        tag=" reachable"
      fi
    else
      status_icon="●"; status_color="$RED"
      tag=" unreachable"
    fi

    local display="${machine}: ${host_str} (${_FM_MODE})"
    local tag_len=${#tag}
    local max_display=$(( inner - 4 - tag_len ))
    (( max_display < 5 )) && max_display=5
    if (( ${#display} > max_display )); then
      display="${display:0:$((max_display - 3))}..."
    fi

    local content_len=$(( 4 + ${#display} + tag_len ))
    local pad_len=$(( inner - content_len ))
    (( pad_len < 0 )) && pad_len=0
    local pad
    pad=$(printf '%*s' "$pad_len" "")

    local tag_color="$status_color"

    printf '  %b│%b  %b%s%b %s%s%b%s%b%b│%b\n' \
      "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" \
      "$display" "$pad" "$tag_color" "$tag" "${RESET}" "${ACCENT}" "${RESET}"

    i=$(( i + 1 ))
  done

  local bottom
  bottom=$(printf '%*s' "$w" "" | sed 's/ /─/g')
  printf '  %b└%s┘%b\n' "${ACCENT}" "$bottom" "${RESET}"
  echo ""
}

_fleet_status_json() {
  printf '['
  local first=true
  for machine in "$@"; do
    [[ "$first" == "true" ]] && first=false || printf ','
    _fleet_load_machine "$machine"
    local reachable=false
    fleet_check "$machine" && reachable=true
    printf '{"machine":"%s","host":"%s","port":%s,"mode":"%s","reachable":%s}' \
      "$machine" "$_FM_HOST" "$_FM_PORT" "$_FM_MODE" "$reachable"
  done
  printf ']\n'
}

# ── rollback ──

_fleet_cmd_rollback() {
  local target="" parallel=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel) parallel=true; shift ;;
      --help|-h)
        echo "Usage: muster fleet rollback [target] [--parallel]"
        return 0
        ;;
      --*)
        err "Unknown flag: $1"
        return 1
        ;;
      *)
        target="$1"
        shift
        ;;
    esac
  done

  if ! fleet_load_config; then
    err "No remotes.json found"
    return 1
  fi

  load_config

  # Resolve machines
  local machines=()
  if [[ -n "$target" ]]; then
    local group_members
    group_members=$(fleet_group_machines "$target" 2>/dev/null)
    if [[ -n "$group_members" ]]; then
      while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        machines[${#machines[@]}]="$m"
      done <<< "$group_members"
    else
      machines[0]="$target"
    fi
  else
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      machines[${#machines[@]}]="$m"
    done < <(fleet_machines)
  fi

  local total=${#machines[@]}
  echo ""
  echo -e "  ${BOLD}${YELLOW}Fleet Rollback${RESET} — ${total} machine(s)"
  echo ""

  local succeeded=0 failed=0
  local current=0

  for machine in "${machines[@]}"; do
    current=$(( current + 1 ))
    _fleet_load_machine "$machine"

    progress_bar "$current" "$total" "Rollback: ${machine}..."
    echo ""

    local project_dir
    project_dir="$(dirname "$CONFIG_FILE")"
    local log_dir="${project_dir}/.muster/logs"
    local log_file="${log_dir}/fleet-${machine}-rollback-$(date +%Y%m%d-%H%M%S).log"

    local rc=0

    if [[ "$_FM_MODE" == "muster" ]]; then
      local token
      token=$(fleet_token_get "$machine")
      if [[ -z "$token" ]]; then
        err "No token for ${machine}"
        failed=$(( failed + 1 ))
        continue
      fi

      local cmd="MUSTER_TOKEN=${token} muster rollback"
      [[ -n "$_FM_PROJECT_DIR" ]] && cmd="cd ${_FM_PROJECT_DIR} && ${cmd}"

      fleet_exec "$machine" "$cmd" >> "$log_file" 2>&1
      rc=$?
    else
      # Push mode: run rollback hooks
      while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        local hook="${project_dir}/.muster/hooks/${svc}/rollback.sh"
        [[ ! -x "$hook" ]] && continue

        fleet_push_hook "$machine" "$hook" "" >> "$log_file" 2>&1 || { rc=1; break; }
      done < <(config_get '.deploy_order[]' 2>/dev/null || config_services)
    fi

    if (( rc == 0 )); then
      ok "${machine} rolled back"
      _history_log_event "fleet:${machine}" "rollback" "ok" ""
      succeeded=$(( succeeded + 1 ))
    else
      err "${machine} rollback failed"
      _history_log_event "fleet:${machine}" "rollback" "failed" ""
      failed=$(( failed + 1 ))
    fi
  done

  echo ""
  if (( failed == 0 )); then
    ok "Fleet rollback complete — ${succeeded}/${total} succeeded"
  else
    warn "Fleet rollback — ${succeeded} succeeded, ${failed} failed (${total} total)"
  fi
  echo ""
}
