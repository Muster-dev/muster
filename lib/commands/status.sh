#!/usr/bin/env bash
# muster/lib/commands/status.sh — Service health status

source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"
source "$MUSTER_ROOT/lib/core/just_runner.sh"
source "$MUSTER_ROOT/lib/core/engine.sh"

# Extra per-service fields for `status --json` (leading comma included):
# stack, health config + target, remote, last deploy, lock holder, k8s replicas
_status_json_extra() {
  local svc="$1" project_dir="$2"
  local stack htype hport hep htimeout hcmd
  stack=$(_engine_service_stack "$svc" "$project_dir")
  htype=$(config_get ".services.${svc}.health.type" 2>/dev/null)
  hport=$(config_get ".services.${svc}.health.port" 2>/dev/null)
  hep=$(config_get ".services.${svc}.health.endpoint" 2>/dev/null)
  htimeout=$(config_get ".services.${svc}.health.timeout" 2>/dev/null)
  hcmd=$(config_get ".services.${svc}.health.command" 2>/dev/null)
  local henabled=true
  [[ "$(config_get ".services.${svc}.health.enabled" 2>/dev/null)" == "false" ]] && henabled=false
  [[ "$htype" == "null" ]] && htype=""
  [[ "$hep" == "null" ]] && hep=""
  [[ "$hcmd" == "null" ]] && hcmd=""

  local host="localhost" target=""
  if remote_is_enabled "$svc"; then
    host=$(config_get ".services.${svc}.remote.host" 2>/dev/null)
  fi
  case "$htype" in
    http) [[ -n "$hport" && "$hport" != "null" ]] && target="http://${host}:${hport}${hep}" ;;
    tcp) [[ -n "$hport" && "$hport" != "null" ]] && target="tcp://${host}:${hport}" ;;
    command) target="$hcmd" ;;
  esac

  local remote="null"
  if remote_is_enabled "$svc"; then
    remote=$(_json_str "$(remote_desc "$svc")")
  fi

  # Service lock (a deploy of this service running anywhere)
  local locked="null" lf
  lf=$(_service_lock_file "$project_dir" "$svc")
  if [[ -f "$lf" ]] && ! _service_lock_is_stale "$lf" 2>/dev/null; then
    _service_lock_read "$lf"
    locked="{\"user\":$(_json_str "$_SLOCK_USER"),\"host\":$(_json_str "$_SLOCK_HOST"),\"source\":$(_json_str "$_SLOCK_SOURCE"),\"pid\":$(_json_int "$_SLOCK_PID"),\"started\":$(_json_str "$_SLOCK_STARTED")}"
  fi
  local deploying=false
  [[ "$locked" != "null" ]] && deploying=true

  # k8s replica counts (only when kubectl can answer quickly)
  local replicas="null"
  if [[ "$stack" == "k8s" && "${MUSTER_HAS_KUBECTL:-false}" == "true" ]] && ! remote_is_enabled "$svc"; then
    local rr
    rr=$(_run_with_timeout 5 kubectl get deployment "$(_engine_k8s_deployment "$svc")" \
      -n "$(_engine_k8s_namespace "$svc")" -o 'jsonpath={.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)
    if [[ "$rr" == */* ]]; then
      replicas="{\"ready\":$(_json_int "${rr%%/*}" 0),\"desired\":$(_json_int "${rr#*/}" 0)}"
    fi
  fi

  printf ',"stack":%s,"health":{"type":%s,"port":%s,"endpoint":%s,"command":%s,"timeout":%s,"enabled":%s},"target":%s,"remote":%s,"last_deploy":%s,"locked_by":%s,"deploying":%s,"replicas":%s' \
    "$(_json_str "$stack")" "$(_json_str_or_null "$htype")" "$(_json_int "$hport")" "$(_json_str_or_null "$hep")" \
    "$(_json_str_or_null "$hcmd")" "$(_json_int "$htimeout")" "$henabled" "$(_json_str_or_null "$target")" "$remote" \
    "$(_engine_last_event "$svc" "deploy" "$project_dir")" "$locked" "$deploying" "$replicas"
}

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
        echo "  --json          Output as JSON (exits 0 even when services are unhealthy)"
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
    local _dl_file _dl_json="null"
    _dl_file=$(_deploy_lock_file "$project_dir")
    if [[ -f "$_dl_file" ]]; then
      _deploy_lock_read "$_dl_file"
      if [[ -n "$_LOCK_PID" ]] && kill -0 "$_LOCK_PID" 2>/dev/null; then
        _dl_json="{\"user\":$(_json_str "$_LOCK_USER"),\"pid\":$(_json_int "$_LOCK_PID"),\"started\":$(_json_str "$_LOCK_STARTED"),\"services\":$(_json_str "$_LOCK_SERVICES")}"
      fi
    fi
    local _dl_active=false
    [[ "$_dl_json" != "null" ]] && _dl_active=true
    printf '{"project":%s,"checked_at":%s,"deploying":%s,"deploy_lock":%s,"services":{' \
      "$(_json_str "$project")" "$(_json_str "$(_engine_now_iso)")" "$_dl_active" "$_dl_json"
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
        if [[ "$_json_mode" == "true" ]]; then
          $_json_first || printf ','
          _json_first=false
          printf '%s:{"name":%s,"status":"blocked","health_type":"","detail":"health hook blocked by security check (muster hooks status --json)"%s}' \
            "$(_json_str "$svc")" "$(_json_str "$name")" "$(_status_json_extra "$svc" "$project_dir")"
        else
          printf '  %b!%b %s: %bhook blocked by security check%b\n' "${YELLOW}" "${RESET}" "$name" "${DIM}" "${RESET}"
        fi
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
        printf '%s:{"name":%s,"status":"disabled","health_type":%s,"detail":"health check disabled"%s}' \
          "$(_json_str "$svc")" "$(_json_str "$name")" "$(_json_str "$health_type")" "$(_status_json_extra "$svc" "$project_dir")"
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
        if _run_hook "$hook" &>/dev/null; then
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
        printf '%s:{"name":%s,"status":"%s","health_type":%s%s}' \
          "$(_json_str "$svc")" "$(_json_str "$name")" "$_status" "$(_json_str "$health_type")" "$(_status_json_extra "$svc" "$project_dir")"
      else
        if [[ "$_health_ok" == "true" ]]; then
          stop_spinner
          printf '  %b●%b %s%s\n' "${GREEN}" "${RESET}" "$name" "$_remote_tag"
        else
          stop_spinner
          printf '  %b●%b %s%s\n' "${RED}" "${RESET}" "$name" "$_remote_tag"
          # Plain-words reason from the rules engine (wrong port, 5xx, ...)
          declare -F hints_health >/dev/null 2>&1 || source "$MUSTER_ROOT/lib/core/hints.sh"
          if hints_health "$svc"; then
            printf '    %b%s%b\n    %bTry:%b %s\n' "${DIM}" "$HINT_TITLE" "${RESET}" "${BOLD}" "${RESET}" "$HINT_TRY"
          fi
        fi
      fi
    else
      if [[ "$_json_mode" == "true" ]]; then
        $_json_first || printf ','
        _json_first=false
        printf '%s:{"name":%s,"status":"no_health_check","health_type":"","detail":"no health hook"%s}' \
          "$(_json_str "$svc")" "$(_json_str "$name")" "$(_status_json_extra "$svc" "$project_dir")"
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
