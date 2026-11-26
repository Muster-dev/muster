#!/usr/bin/env bash
# muster/lib/commands/logs.sh — Log streaming

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/core/just_runner.sh"

cmd_logs() {
  local _lg_target="" _lg_tail="" _lg_follow=false _lg_json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: muster logs <service> [flags]"
        echo ""
        echo "Stream logs for a service."
        echo ""
        echo "Flags:"
        echo "  --tail N, -n N  Print the last N lines and exit (add --follow to keep streaming)"
        echo "  --follow, -f    With --tail: keep streaming after the last N lines"
        echo "  --json          One NDJSON event per line: {\"event\":\"log\",…}"
        echo "  -h, --help      Show this help"
        return 0
        ;;
      --tail|-n)
        _lg_tail="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
      --tail=*) _lg_tail="${1#--tail=}"; shift ;;
      --follow|-f) _lg_follow=true; shift ;;
      --no-follow) _lg_follow=false; shift ;;
      --json) _lg_json=true; shift ;;
      -*)
        err "Unknown flag: $1"
        echo "Run 'muster logs --help' for usage."
        return 1
        ;;
      *) _lg_target="$1"; shift ;;
    esac
  done
  if [[ -n "$_lg_tail" ]] && ! [[ "$_lg_tail" =~ ^[0-9]+$ && "$_lg_tail" -gt 0 ]]; then
    err "--tail needs a positive number of lines"
    return 1
  fi
  set -- ${_lg_target:+"$_lg_target"}

  load_config

  if [[ -n "$_lg_tail" || "$_lg_json" == "true" ]]; then
    source "$MUSTER_ROOT/lib/commands/logs_api.sh"
    _logs_api "$_lg_target" "$_lg_tail" "$_lg_follow" "$_lg_json"
    return $?
  fi

  local target="${1:-}"
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  # If no target, let user pick
  if [[ -z "$target" ]]; then
    local service_names=()
    local services
    services=$(config_services)

    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      service_names[${#service_names[@]}]="$svc"
    done <<< "$services"

    service_names[${#service_names[@]}]="Back"
    menu_select "Stream logs for which service?" "${service_names[@]}"
    if [[ "$MENU_RESULT" == "Back" || "$MENU_RESULT" == "__back__" ]]; then
      return 2
    fi
    target="$MENU_RESULT"
  fi

  local hook="${project_dir}/.muster/hooks/${target}/logs.sh"
  local _logs_hook_dir="${project_dir}/.muster/hooks/${target}"

  if _just_available "$_logs_hook_dir" && _just_has_recipe "$_logs_hook_dir" "logs"; then
    info "Streaming logs for ${target}... (Ctrl+C to stop)"
    echo ""
    just --justfile "${_logs_hook_dir}/justfile" logs
  elif [[ -x "$hook" ]]; then
    info "Streaming logs for ${target}... (Ctrl+C to stop)"
    echo ""
    bash "$hook"
  else
    # Fallback: show recent deploy logs
    local log_dir="${project_dir}/.muster/logs"
    local latest
    latest=$(ls -t "${log_dir}/${target}-"*.log 2>/dev/null | head -1)

    if [[ -n "$latest" ]]; then
      info "No log hook. Showing latest deploy log:"
      echo ""
      tail -f "$latest"
    else
      err "No log hook and no deploy logs found for ${target}"
    fi
  fi
}
