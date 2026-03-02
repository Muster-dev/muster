#!/usr/bin/env bash
# muster/lib/commands/history.sh — Deploy history tracking and display

# ── Event logger ──
# Appends a structured line to deploy-events.log
# Usage: _history_log_event "service" "action" "status"
#   action: deploy | rollback
#   status: ok | failed
_history_log_event() {
  local svc="$1" action="$2" status="$3" commit="${4:-}"
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local log_dir="${project_dir}/.muster/logs"
  mkdir -p "$log_dir"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "${ts}|${svc}|${action}|${status}|${commit}" >> "${log_dir}/deploy-events.log"
}

# ── History display ──
cmd_history() {
  load_config

  local show_all=false
  local filter=""
  local _json_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: muster history [flags] [service]"
        echo ""
        echo "Show deploy and rollback event history."
        echo ""
        echo "Flags:"
        echo "  --all, -a       Show full history (not just recent)"
        echo "  --json          Output as JSON"
        echo "  -h, --help      Show this help"
        echo ""
        echo "Examples:"
        echo "  muster history             Recent events"
        echo "  muster history --all       Full history"
        echo "  muster history api         Events for api only"
        echo "  muster history --json      JSON output"
        return 0
        ;;
      --all|-a) show_all=true; shift ;;
      --json) _json_mode=true; shift ;;
      --*)
        err "Unknown flag: $1"
        echo "Run 'muster history --help' for usage."
        return 1
        ;;
      *)
        filter="$1"
        shift
        ;;
    esac
  done

  # Auth gate: JSON mode requires valid token
  if [[ "$_json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
  fi

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local log_file="${project_dir}/.muster/logs/deploy-events.log"

  if [[ ! -f "$log_file" ]]; then
    if [[ "$_json_mode" == "true" ]]; then
      printf '[]\n'
      return 0
    fi
    info "No deploy history found."
    return 0
  fi

  # Read events into arrays (bash 3.2 compatible)
  local timestamps=()
  local services=()
  local actions=()
  local statuses=()
  local commits=()

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local ts="" svc="" action="" status=""

    local commit=""

    if [[ "$line" == *"|"* ]]; then
      # Format: YYYY-MM-DD HH:MM:SS|service|action|status[|commit]
      ts="${line%%|*}"
      local rest="${line#*|}"
      svc="${rest%%|*}"
      rest="${rest#*|}"
      action="${rest%%|*}"
      rest="${rest#*|}"
      # status may be followed by |commit
      if [[ "$rest" == *"|"* ]]; then
        status="${rest%%|*}"
        commit="${rest#*|}"
      else
        status="$rest"
      fi
    elif [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\]\ ([A-Z]+)\ ([A-Z]+):\ (.+) ]]; then
      # Legacy format: [YYYY-MM-DD HH:MM:SS] ACTION STATUS: service
      ts="${BASH_REMATCH[1]}"
      action="${BASH_REMATCH[2]}"
      status="${BASH_REMATCH[3]}"
      svc="${BASH_REMATCH[4]}"
      # Normalize legacy values
      action=$(printf '%s' "$action" | tr '[:upper:]' '[:lower:]')
      status=$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')
      # Skip START entries — only show results
      [[ "$action" == *"start"* ]] && continue
      [[ "$status" == "start" ]] && continue
    else
      continue
    fi

    # Apply service filter
    if [[ -n "$filter" && "$svc" != "$filter" ]]; then
      continue
    fi

    timestamps[${#timestamps[@]}]="$ts"
    services[${#services[@]}]="$svc"
    actions[${#actions[@]}]="$action"
    statuses[${#statuses[@]}]="$status"
    commits[${#commits[@]}]="$commit"
  done < "$log_file"

  local count=${#timestamps[@]}

  if (( count == 0 )); then
    if [[ "$_json_mode" == "true" ]]; then
      printf '[]\n'
      return 0
    fi
    if [[ -n "$filter" ]]; then
      info "No history found for '${filter}'."
    else
      info "No deploy history found."
    fi
    return 0
  fi

  # Determine range to display
  local start=0
  if [[ "$show_all" == "false" && $count -gt 20 ]]; then
    start=$(( count - 20 ))
  fi

  # ── JSON output ──
  if [[ "$_json_mode" == "true" ]]; then
    printf '['
    local _jfirst=true
    local i
    for (( i = start; i < count; i++ )); do
      $_jfirst || printf ','
      _jfirst=false
      # Escape values for JSON safety
      local _jts="${timestamps[$i]}"
      local _jsvc="${services[$i]}"
      local _jact="${actions[$i]}"
      local _jst="${statuses[$i]}"
      local _jcm="${commits[$i]}"
      printf '{"timestamp":"%s","service":"%s","action":"%s","status":"%s","commit":"%s"}' \
        "$_jts" "$_jsvc" "$_jact" "$_jst" "$_jcm"
    done
    printf ']\n'
    return 0
  fi

  # ── TUI output ──
  local project
  project=$(config_get '.project')

  echo ""
  echo -e "  ${BOLD}${ACCENT_BRIGHT}Deploy History${RESET} ${DIM}${project}${RESET}"
  if [[ -n "$filter" ]]; then
    echo -e "  ${DIM}Filtered: ${filter}${RESET}"
  fi
  echo ""

  # Table header
  printf "  ${BOLD}%-20s  %-12s  %-10s  %-8s  %-9s${RESET}\n" "TIMESTAMP" "SERVICE" "ACTION" "STATUS" "COMMIT"
  printf "  ${DIM}%-20s  %-12s  %-10s  %-8s  %-9s${RESET}\n" "--------------------" "------------" "----------" "--------" "---------"

  local i
  for (( i = start; i < count; i++ )); do
    local ts="${timestamps[$i]}"
    local svc="${services[$i]}"
    local action="${actions[$i]}"
    local st="${statuses[$i]}"
    local cm="${commits[$i]}"

    local color="$RESET"
    if [[ "$st" == "ok" ]]; then
      color="$GREEN"
    elif [[ "$st" == "failed" ]]; then
      color="$RED"
    fi

    printf "  %-20s  %-12s  %-10s  ${color}%-8s${RESET}  ${DIM}%-9s${RESET}\n" "$ts" "$svc" "$action" "$st" "$cm"
  done

  echo ""
  if [[ "$show_all" == "false" && $start -gt 0 ]]; then
    echo -e "  ${DIM}Showing last 20 of ${count} events. Use --all to see all.${RESET}"
    echo ""
  fi
}
