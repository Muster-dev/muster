#!/usr/bin/env bash
# muster/lib/commands/cleanup.sh — Cleanup stuck processes

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/core/just_runner.sh"

cmd_cleanup() {
  case "${1:-}" in
    --help|-h)
      echo "Usage: muster cleanup"
      echo ""
      echo "Clean up stuck processes and old log files."
      return 0
      ;;
    --*)
      err "Unknown flag: $1"
      echo "Run 'muster cleanup --help' for usage."
      return 1
      ;;
  esac

  load_config

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  # Acquire deploy lock (prevents concurrent deploy/rollback/cleanup)
  if ! _deploy_lock_acquire "$project_dir"; then
    return 1
  fi
  trap '_deploy_lock_release "'"$project_dir"'"; cleanup_term' EXIT

  local services
  services=$(config_services)

  echo ""
  printf '  %bCleanup%b\n' "${BOLD}" "${RESET}"
  echo ""

  # Run cleanup hooks if they exist
  local ran_any=false
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local hook="${project_dir}/.muster/hooks/${svc}/cleanup.sh"
    local _clean_hook_dir="${project_dir}/.muster/hooks/${svc}"
    local name
    name=$(config_get ".services.${svc}.name")

    # Security check (silent — don't break cleanup flow)
    source "$MUSTER_ROOT/lib/core/hook_security.sh"
    local _clean_check="$hook"
    if _just_available "$_clean_hook_dir" && _just_has_recipe "$_clean_hook_dir" "cleanup"; then
      _clean_check="${_clean_hook_dir}/justfile"
    fi
    if [[ -f "$_clean_check" ]] && ! _hook_security_check "$_clean_check" "$project_dir" "silent"; then
      warn "${name}: hook blocked by security check"
      continue
    fi

    if _just_available "$_clean_hook_dir" && _just_has_recipe "$_clean_hook_dir" "cleanup"; then
      start_spinner "Cleaning up ${name}..."
      just --justfile "${_clean_hook_dir}/justfile" cleanup &>/dev/null
      stop_spinner
      ok "${name} cleaned up"
      ran_any=true
    elif [[ -x "$hook" ]]; then
      start_spinner "Cleaning up ${name}..."
      bash "$hook" &>/dev/null
      stop_spinner
      ok "${name} cleaned up"
      ran_any=true
    fi
  done <<< "$services"

  # Clean old logs (use global log_retention_days, default 7)
  local retention_days
  retention_days=$(global_config_get "log_retention_days" 2>/dev/null)
  case "$retention_days" in
    ''|*[!0-9]*) retention_days=7 ;;
  esac

  local log_dir="${project_dir}/.muster/logs"
  if [[ -d "$log_dir" ]]; then
    local old_logs
    old_logs=$(find "$log_dir" -name "*.log" -mtime +"$retention_days" 2>/dev/null | wc -l | tr -d ' ')
    if (( old_logs > 0 )); then
      find "$log_dir" -name "*.log" -mtime +"$retention_days" -delete 2>/dev/null
      ok "Removed ${old_logs} old log files (>${retention_days} days)"
      ran_any=true
    fi
  fi

  if [[ "$ran_any" == "false" ]]; then
    info "Nothing to clean up"
  fi

  echo ""

  _deploy_lock_release "$project_dir"
  trap - EXIT
}
