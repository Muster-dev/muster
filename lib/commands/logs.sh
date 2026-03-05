#!/usr/bin/env bash
# muster/lib/commands/logs.sh — Log streaming

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/core/just_runner.sh"

cmd_logs() {
  case "${1:-}" in
    --help|-h)
      echo "Usage: muster logs <service>"
      echo ""
      echo "Stream logs for a service."
      return 0
      ;;
    --*)
      err "Unknown flag: $1"
      echo "Run 'muster logs --help' for usage."
      return 1
      ;;
  esac

  load_config

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
