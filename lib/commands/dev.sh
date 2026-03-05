#!/usr/bin/env bash
# muster/lib/commands/dev.sh — Dev mode: deploy + watch + auto-cleanup

source "$MUSTER_ROOT/lib/commands/deploy.sh"
source "$MUSTER_ROOT/lib/commands/cleanup.sh"

_dev_cleanup() {
  echo ""
  echo ""
  printf '  %bShutting down dev environment...%b\n' "${BOLD}" "${RESET}"
  echo ""

  load_config

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  # Run cleanup hooks for all services
  local services
  services=$(config_services)
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local hook="${project_dir}/.muster/hooks/${svc}/cleanup.sh"
    local _dev_hook_dir="${project_dir}/.muster/hooks/${svc}"
    local name
    name=$(config_get ".services.${svc}.name")
    if _just_available "$_dev_hook_dir" && _just_has_recipe "$_dev_hook_dir" "cleanup"; then
      start_spinner "Cleaning up ${name}..."
      just --justfile "${_dev_hook_dir}/justfile" cleanup &>/dev/null
      stop_spinner
      ok "${name} stopped"
    elif [[ -x "$hook" ]]; then
      start_spinner "Cleaning up ${name}..."
      bash "$hook" &>/dev/null
      stop_spinner
      ok "${name} stopped"
    fi
  done <<< "$services"

  # Kill any remaining PIDs in .muster/pids/
  local pid_dir="${project_dir}/.muster/pids"
  if [[ -d "$pid_dir" ]]; then
    local killed_any=false
    for pid_file in "$pid_dir"/*.pid; do
      [[ -f "$pid_file" ]] || continue
      local pid
      pid=$(cat "$pid_file" 2>/dev/null)
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        killed_any=true
      fi
      rm -f "$pid_file"
    done
    if [[ "$killed_any" == "true" ]]; then
      ok "Killed remaining background processes"
    fi
  fi

  echo ""
  ok "Dev environment stopped"
  echo ""
  exit 0
}

_dev_show_status() {
  local project_dir="$1"

  # Move cursor up past previous status display (if any)
  if [[ "${_dev_first_status:-true}" == "false" ]]; then
    # Clear the previous status block
    local line_count="${_dev_status_lines:-0}"
    if (( line_count > 0 )); then
      printf '\033[%dA' "$line_count"
      printf '\033[J'
    fi
  fi
  _dev_first_status=false

  local lines=0

  printf '  %bService Health%b\n' "${BOLD}" "${RESET}"
  lines=$(( lines + 1 ))

  local services
  services=$(config_services)
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local name
    name=$(config_get ".services.${svc}.name")

    local health_enabled
    health_enabled=$(config_get ".services.${svc}.health.enabled")

    local hook="${project_dir}/.muster/hooks/${svc}/health.sh"
    local _dev_health_dir="${project_dir}/.muster/hooks/${svc}"
    local _has_dev_health=false
    if [[ -x "$hook" ]]; then
      _has_dev_health=true
    elif _just_available "$_dev_health_dir" && _just_has_recipe "$_dev_health_dir" "health"; then
      _has_dev_health=true
    fi

    if [[ "$health_enabled" == "false" ]]; then
      printf '  %b○%b %s %b(disabled)%b\n' "${GRAY}" "${RESET}" "$name" "${DIM}" "${RESET}"
    elif [[ "$_has_dev_health" == "true" ]]; then
      # Export k8s env vars for health hook
      local _k8s_env=""
      _k8s_env=$(k8s_env_for_service "$svc")
      if [[ -n "$_k8s_env" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          export "$_ek=$_ev"
        done <<< "$_k8s_env"
      fi

      local _health_ok=false _hpid="" _health_timeout=""
      _health_timeout=$(config_get ".services.${svc}.health.timeout" 2>/dev/null)
      [[ -z "$_health_timeout" || "$_health_timeout" == "null" ]] && _health_timeout=10
      if remote_is_enabled "$svc"; then
        remote_exec_stdout "$svc" "$hook" "$_k8s_env" &>/dev/null &
        _hpid=$!
      elif _just_available "$_dev_health_dir" && _just_has_recipe "$_dev_health_dir" "health"; then
        just --justfile "${_dev_health_dir}/justfile" health &>/dev/null &
        _hpid=$!
      else
        bash "$hook" &>/dev/null &
        _hpid=$!
      fi
      # Wait with timeout — kill if health hook hangs
      ( sleep "$_health_timeout" && kill "$_hpid" 2>/dev/null ) &
      local _tpid=$!
      if wait "$_hpid" 2>/dev/null; then
        _health_ok=true
      fi
      kill "$_tpid" 2>/dev/null
      wait "$_tpid" 2>/dev/null

      # Clean up k8s env
      if [[ -n "$_k8s_env" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          unset "$_ek"
        done <<< "$_k8s_env"
      fi

      if [[ "$_health_ok" == "true" ]]; then
        printf '  %b●%b %s\n' "${GREEN}" "${RESET}" "$name"
      else
        printf '  %b●%b %s\n' "${RED}" "${RESET}" "$name"
      fi
    else
      printf '  %b○%b %s %b(no health check)%b\n' "${GRAY}" "${RESET}" "$name" "${DIM}" "${RESET}"
    fi
    lines=$(( lines + 1 ))
  done <<< "$services"

  echo ""
  lines=$(( lines + 1 ))
  printf '  %bLast checked: %s%b  %b|%b  %bCtrl+C to stop%b\n' "${DIM}" "$(date +%H:%M:%S)" "${RESET}" "${DIM}" "${RESET}" "${DIM}" "${RESET}"
  lines=$(( lines + 1 ))

  _dev_status_lines="$lines"
}

cmd_dev() {
  case "${1:-}" in
    --help|-h)
      echo "Usage: muster dev"
      echo ""
      echo "Deploy all services, then watch health every 5 seconds."
      echo "Press Ctrl+C to stop and clean up all services."
      return 0
      ;;
    --*)
      err "Unknown flag: $1"
      echo "Run 'muster dev --help' for usage."
      return 1
      ;;
  esac

  load_config

  local project
  project=$(config_get '.project')
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  # Trap SIGINT/SIGTERM for clean shutdown
  trap '_dev_cleanup' INT TERM

  echo ""
  printf '  %b%bDev Mode%b %b%s%b\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}" "${WHITE}" "$project" "${RESET}"
  echo ""

  # Deploy all services
  cmd_deploy "$@"
  local rc=$?
  if (( rc != 0 )); then
    err "Deploy failed — aborting dev mode"
    return 1
  fi

  echo ""
  printf '  %b✓%b %bDev environment running%b\n' "${GREEN}" "${RESET}" "${BOLD}" "${RESET}"
  echo ""

  _dev_first_status=true

  # Watch loop — refresh health every 5 seconds (read -t instead of sleep for Ctrl+C)
  while true; do
    _dev_show_status "$project_dir"
    IFS= read -rsn1 -t 5 _dev_key 2>/dev/null || true
    [[ "$_dev_key" == "q" ]] && break
  done
}
