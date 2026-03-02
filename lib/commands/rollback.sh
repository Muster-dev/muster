#!/usr/bin/env bash
# muster/lib/commands/rollback.sh — Rollback last deploy

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/core/credentials.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"
source "$MUSTER_ROOT/lib/core/k8s_diag.sh"
source "$MUSTER_ROOT/lib/skills/manager.sh"
source "$MUSTER_ROOT/lib/commands/history.sh"

cmd_rollback() {
  case "${1:-}" in
    --help|-h)
      echo "Usage: muster rollback [service]"
      echo ""
      echo "Rollback a service to its previous state. Without a service name, pick interactively."
      return 0
      ;;
    --*)
      err "Unknown flag: $1"
      echo "Run 'muster rollback --help' for usage."
      return 1
      ;;
  esac

  load_config
  _load_env_file

  local target="${1:-}"
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  # If no target, let user pick from services that have rollback hooks
  if [[ -z "$target" ]]; then
    local rollback_services=()
    local services
    services=$(config_services)

    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      [[ -x "${project_dir}/.muster/hooks/${svc}/rollback.sh" ]] && rollback_services[${#rollback_services[@]}]="$svc"
    done <<< "$services"

    if [[ ${#rollback_services[@]} -eq 0 ]]; then
      err "No services have rollback hooks configured"
      return 1
    fi

    rollback_services[${#rollback_services[@]}]="Back"
    menu_select "Rollback which service?" "${rollback_services[@]}"
    if [[ "$MENU_RESULT" == "Back" || "$MENU_RESULT" == "__back__" ]]; then
      _unload_env_file
      return 2
    fi
    target="$MENU_RESULT"
  fi

  local hook="${project_dir}/.muster/hooks/${target}/rollback.sh"

  if [[ ! -x "$hook" ]]; then
    err "No rollback hook for ${target}"
    return 1
  fi

  local name
  name=$(config_get ".services.${target}.name")

  echo ""
  warn "Rolling back ${name}..."

  local log_dir="${project_dir}/.muster/logs"
  mkdir -p "$log_dir"

  # Gather credentials if configured
  local _cred_env_lines=""
  _cred_env_lines=$(cred_env_for_service "$target")
  if [[ -n "$_cred_env_lines" ]]; then
    while IFS='=' read -r _ck _cv; do
      [[ -z "$_ck" ]] && continue
      export "$_ck=$_cv"
    done <<< "$_cred_env_lines"
  fi

  # Export k8s config as env vars
  local _k8s_env_lines=""
  _k8s_env_lines=$(k8s_env_for_service "$target")
  if [[ -n "$_k8s_env_lines" ]]; then
    while IFS='=' read -r _ek _ev; do
      [[ -z "$_ek" ]] && continue
      export "$_ek=$_ev"
    done <<< "$_k8s_env_lines"
  fi

  export MUSTER_DEPLOY_STATUS=""
  export MUSTER_SERVICE_NAME="$name"
  run_skill_hooks "pre-rollback" "$target"

  if remote_is_enabled "$target"; then
    info "Rolling back ${name} remotely ($(remote_desc "$target"))"
  fi

  while true; do
    local log_file="${log_dir}/${target}-rollback-$(date +%Y%m%d-%H%M%S).log"

    start_spinner "Rolling back ${name}..."
    if remote_is_enabled "$target"; then
      local _all_env="${_cred_env_lines}"
      [[ -n "$_k8s_env_lines" ]] && _all_env="${_all_env}
${_k8s_env_lines}"
      remote_exec_stdout "$target" "$hook" "$_all_env" >> "$log_file" 2>&1
    else
      "$hook" >> "$log_file" 2>&1
    fi
    local rc=$?
    stop_spinner

    if (( rc == 0 )); then
      ok "${name} rolled back successfully"
      _history_log_event "$target" "rollback" "ok"
      export MUSTER_DEPLOY_STATUS="success"
      run_skill_hooks "post-rollback" "$target"
      break
    else
      err "${name} rollback failed (exit code ${rc})"
      _history_log_event "$target" "rollback" "failed"

      # Show last few lines of log for context
      echo ""
      if [[ -f "$log_file" ]]; then
        tail -5 "$log_file" | while IFS= read -r _line; do
          echo -e "  ${DIM}${_line}${RESET}"
        done
      fi
      echo ""

      k8s_diagnose_failure "$target"

      menu_select "Rollback failed. What do you want to do?" "Retry" "Force cleanup and retry" "Abort"

      case "$MENU_RESULT" in
        "Retry")
          ;; # loop continues
        "Force cleanup and retry")
          local cleanup_hook="${project_dir}/.muster/hooks/${target}/cleanup.sh"
          if [[ -x "$cleanup_hook" ]]; then
            start_spinner "Running cleanup for ${name}..."
            if remote_is_enabled "$target"; then
              remote_exec_stdout "$target" "$cleanup_hook" "" >> "${log_dir}/${target}-cleanup-$(date +%Y%m%d-%H%M%S).log" 2>&1
            else
              "$cleanup_hook" >> "${log_dir}/${target}-cleanup-$(date +%Y%m%d-%H%M%S).log" 2>&1
            fi
            stop_spinner
            ok "${name} cleaned up"
          else
            warn "No cleanup hook for ${name}, retrying rollback anyway"
          fi
          ;; # loop continues with rollback retry
        "Abort")
          export MUSTER_DEPLOY_STATUS="failed"
          run_skill_hooks "post-rollback" "$target"
          break
          ;;
      esac
    fi
  done

  # Clean up exported cred vars (local only)
  if [[ -n "$_cred_env_lines" ]] && ! remote_is_enabled "$target"; then
    while IFS='=' read -r _ck _cv; do
      [[ -z "$_ck" ]] && continue
      unset "$_ck"
    done <<< "$_cred_env_lines"
  fi
  # Clean up k8s env vars
  if [[ -n "$_k8s_env_lines" ]]; then
    while IFS='=' read -r _ek _ev; do
      [[ -z "$_ek" ]] && continue
      unset "$_ek"
    done <<< "$_k8s_env_lines"
  fi

  echo ""

  _unload_env_file
}
