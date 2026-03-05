#!/usr/bin/env bash
# muster/lib/commands/status.sh — Service health status

source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"
source "$MUSTER_ROOT/lib/core/just_runner.sh"

cmd_status() {
  local _json_mode=false

  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: muster status [flags]"
        echo ""
        echo "Check health of all services."
        echo ""
        echo "Flags:"
        echo "  --json          Output as JSON"
        echo "  -h, --help      Show this help"
        return 0
        ;;
      --json) _json_mode=true; shift ;;
      *)
        err "Unknown flag: $1"
        echo "Run 'muster status --help' for usage."
        return 1
        ;;
    esac
  done

  load_config

  local project
  project=$(config_get '.project')
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  # Auth gate: JSON mode requires valid token
  if [[ "$_json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
  fi

  if [[ "$_json_mode" == "false" ]]; then
    echo ""
    printf '  %b%s%b — Service Status\n' "${BOLD}" "$project" "${RESET}"
    echo ""
  fi

  local services
  services=$(config_services)

  # JSON mode: collect results, print at end
  local _json_first=true
  if [[ "$_json_mode" == "true" ]]; then
    printf '{"project":"%s","services":{' "$project"
  fi

  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local name
    name=$(config_get ".services.${svc}.name")

    local hook="${project_dir}/.muster/hooks/${svc}/health.sh"
    local _status_hook_dir="${project_dir}/.muster/hooks/${svc}"

    # Silent security check for health hooks
    if [[ -f "$hook" ]]; then
      source "$MUSTER_ROOT/lib/core/hook_security.sh"
      if ! _hook_security_check "$hook" "$project_dir" "silent"; then
        printf '  %b!%b %s: %bhook blocked by security check%b\n' "${YELLOW}" "${RESET}" "$name" "${DIM}" "${RESET}"
        continue
      fi
    fi

    local health_enabled
    health_enabled=$(config_get ".services.${svc}.health.enabled")

    local health_type
    health_type=$(config_get ".services.${svc}.health.type")
    [[ "$health_type" == "null" ]] && health_type=""

    local _remote_tag=""
    if remote_is_enabled "$svc"; then
      _remote_tag=" ${DIM}($(remote_desc "$svc"))${RESET}"
    fi

    # Check if health hook is available (bash script or justfile recipe)
    local _has_health_hook=false
    if [[ -x "$hook" ]]; then
      _has_health_hook=true
    elif _just_available "$_status_hook_dir" && _just_has_recipe "$_status_hook_dir" "health"; then
      _has_health_hook=true
    fi

    if [[ "$health_enabled" == "false" ]]; then
      if [[ "$_json_mode" == "true" ]]; then
        $_json_first || printf ','
        _json_first=false
        printf '"%s":{"name":"%s","status":"disabled","health_type":"%s","detail":"health check disabled"}' \
          "$svc" "$name" "$health_type"
      else
        printf '  %b○%b %s%s %b(disabled)%b\n' "${GRAY}" "${RESET}" "$name" "$_remote_tag" "${DIM}" "${RESET}"
      fi
    elif [[ "$_has_health_hook" == "true" ]]; then
      # Export k8s env vars for health hook
      local _k8s_env=""
      _k8s_env=$(k8s_env_for_service "$svc")
      if [[ -n "$_k8s_env" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          export "$_ek=$_ev"
        done <<< "$_k8s_env"
      fi

      if [[ "$_json_mode" == "false" ]]; then
        start_spinner "Checking ${name}..."
      fi
      local _health_ok=false
      if remote_is_enabled "$svc"; then
        if remote_exec_stdout "$svc" "$hook" "$_k8s_env" &>/dev/null; then
          _health_ok=true
        fi
      elif _just_available "$_status_hook_dir" && _just_has_recipe "$_status_hook_dir" "health"; then
        if just --justfile "${_status_hook_dir}/justfile" health &>/dev/null; then
          _health_ok=true
        fi
      else
        if bash "$hook" &>/dev/null; then
          _health_ok=true
        fi
      fi

      # Clean up k8s env
      if [[ -n "$_k8s_env" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          unset "$_ek"
        done <<< "$_k8s_env"
      fi

      if [[ "$_json_mode" == "true" ]]; then
        $_json_first || printf ','
        _json_first=false
        local _status="unhealthy"
        [[ "$_health_ok" == "true" ]] && _status="healthy"
        printf '"%s":{"name":"%s","status":"%s","health_type":"%s"}' \
          "$svc" "$name" "$_status" "$health_type"
      else
        if [[ "$_health_ok" == "true" ]]; then
          stop_spinner
          printf '  %b●%b %s%s\n' "${GREEN}" "${RESET}" "$name" "$_remote_tag"
        else
          stop_spinner
          printf '  %b●%b %s%s\n' "${RED}" "${RESET}" "$name" "$_remote_tag"
        fi
      fi
    else
      if [[ "$_json_mode" == "true" ]]; then
        $_json_first || printf ','
        _json_first=false
        printf '"%s":{"name":"%s","status":"no_health_check","health_type":"","detail":"no health hook"}' \
          "$svc" "$name"
      else
        printf '  %b○%b %s%s %b(no health check)%b\n' "${GRAY}" "${RESET}" "$name" "$_remote_tag" "${DIM}" "${RESET}"
      fi
    fi
  done <<< "$services"

  if [[ "$_json_mode" == "true" ]]; then
    printf '}}\n'
  else
    echo ""
  fi
}
