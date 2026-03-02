#!/usr/bin/env bash
# muster/lib/commands/status.sh — Service health status

source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"

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
    echo -e "  ${BOLD}${project}${RESET} — Service Status"
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

    local health_enabled
    health_enabled=$(config_get ".services.${svc}.health.enabled")

    local health_type
    health_type=$(config_get ".services.${svc}.health.type")
    [[ "$health_type" == "null" ]] && health_type=""

    local _remote_tag=""
    if remote_is_enabled "$svc"; then
      _remote_tag=" ${DIM}($(remote_desc "$svc"))${RESET}"
    fi

    if [[ "$health_enabled" == "false" ]]; then
      if [[ "$_json_mode" == "true" ]]; then
        $_json_first || printf ','
        _json_first=false
        printf '"%s":{"name":"%s","status":"disabled","health_type":"%s","detail":"health check disabled"}' \
          "$svc" "$name" "$health_type"
      else
        echo -e "  ${GRAY}○${RESET} ${name}${_remote_tag} ${DIM}(disabled)${RESET}"
      fi
    elif [[ -x "$hook" ]]; then
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
      else
        if "$hook" &>/dev/null; then
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
          echo -e "  ${GREEN}●${RESET} ${name}${_remote_tag}"
        else
          stop_spinner
          echo -e "  ${RED}●${RESET} ${name}${_remote_tag}"
        fi
      fi
    else
      if [[ "$_json_mode" == "true" ]]; then
        $_json_first || printf ','
        _json_first=false
        printf '"%s":{"name":"%s","status":"no_health_check","health_type":"","detail":"no health hook"}' \
          "$svc" "$name"
      else
        echo -e "  ${GRAY}○${RESET} ${name}${_remote_tag} ${DIM}(no health check)${RESET}"
      fi
    fi
  done <<< "$services"

  if [[ "$_json_mode" == "true" ]]; then
    printf '}}\n'
  else
    echo ""
  fi
}
