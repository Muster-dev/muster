#!/usr/bin/env bash
# muster/lib/commands/restart.sh — Restart a running service without redeploying
#
# Method, in order:
#   hook     .muster/hooks/<svc>/restart.sh (or a `restart` justfile recipe)
#   k8s      kubectl rollout restart deployment/<deployment> (+ rollout status)
#   compose  docker compose -f <file> restart <service>
#   docker   docker restart <container>
#   redeploy anything else (bare, dev): a normal `muster deploy <svc>`, said so
# Remote services run the command on their remote host.

source "$MUSTER_ROOT/lib/core/engine.sh"
source "$MUSTER_ROOT/lib/core/credentials.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"
source "$MUSTER_ROOT/lib/core/k8s_diag.sh"
source "$MUSTER_ROOT/lib/core/just_runner.sh"
source "$MUSTER_ROOT/lib/core/hook_security.sh"
source "$MUSTER_ROOT/lib/commands/history.sh"

_restart_help() {
  echo "Usage: muster restart <service> [flags]"
  echo ""
  echo "Restart a running service without rebuilding or redeploying it."
  echo ""
  echo "How it restarts, first match wins:"
  echo "  .muster/hooks/<svc>/restart.sh   your own restart hook (or a justfile recipe)"
  echo "  k8s services                     kubectl rollout restart deployment/<name>"
  echo "  compose services                 docker compose restart <service>"
  echo "  docker services                  docker restart <container>"
  echo "  anything else                    redeploys the service (muster deploy <svc>)"
  echo ""
  echo "Flags:"
  echo "  --json          Stream NDJSON events (start/log/done/health/summary)"
  echo "  --yes           Approve a changed/unapproved restart hook without review"
  echo "  -h, --help      Show this help"
  echo ""
  echo "Exit codes: 0 restarted (and healthy if checked), 1 otherwise"
}

cmd_restart() {
  local json=false approve=false target=""
  [[ "${MUSTER_APPROVE_HOOKS:-}" == "1" || "${MUSTER_APPROVE_HOOKS:-}" == "true" ]] && approve=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) _restart_help; return 0 ;;
      --json) json=true; shift ;;
      --yes) approve=true; shift ;;
      -*)
        err "Unknown flag: $1"
        echo "Run 'muster restart --help' for usage."
        return 1
        ;;
      *)
        if [[ -n "$target" ]]; then
          err "restart takes one service (got ${target} and $1)"
          return 1
        fi
        target="$1"; shift ;;
    esac
  done

  load_config

  if [[ "$json" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "deploy" || return 1
  fi

  if [[ -z "$target" ]]; then
    if [[ "$json" == "true" ]]; then
      _json_error "usage" "No service given. Usage: muster restart <service>"
    else
      err "No service given. Usage: muster restart <service>"
    fi
    return 1
  fi
  local _known
  _known=" $(config_services | tr '\n' ' ') "
  if [[ "$_known" != *" ${target} "* ]]; then
    if [[ "$json" == "true" ]]; then
      _json_error "unknown_service" "Unknown service: ${target}"
    else
      err "Unknown service: ${target}"
      printf '  %bServices in this project:%b %s\n' "$DIM" "$RESET" "$(config_services | tr '\n' ' ')"
    fi
    return 1
  fi

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local name
  name=$(config_get ".services.${target}.name")
  [[ -z "$name" || "$name" == "null" ]] && name="$target"
  local hook_dir="${project_dir}/.muster/hooks/${target}"
  local hook="${hook_dir}/restart.sh"
  local stack
  stack=$(_engine_service_stack "$target" "$project_dir")

  local method="" use_just=false
  if _just_available "$hook_dir" && _just_has_recipe "$hook_dir" "restart"; then
    method="hook"; use_just=true
  elif [[ -x "$hook" ]]; then
    method="hook"
  else
    case "$stack" in
      k8s|compose|docker) method="$stack" ;;
      *) method="redeploy" ;;
    esac
  fi

  # ── No restart for this stack: redeploy instead, and say so ──
  if [[ "$method" == "redeploy" ]]; then
    local msg="No restart hook and no built-in restart for ${stack} services — redeploying ${target} instead (no rollback)"
    local args=("deploy")
    [[ "$json" == "true" ]] && args[${#args[@]}]="--json"
    [[ "$approve" == "true" ]] && args[${#args[@]}]="--yes"
    args[${#args[@]}]="$target"
    if [[ "$json" == "true" ]]; then
      printf '{"event":"restart","service":%s,"method":"redeploy","stack":%s,"message":%s}\n' \
        "$(_json_str "$target")" "$(_json_str "$stack")" "$(_json_str "$msg")"
    else
      warn "$msg"
    fi
    exec "$MUSTER_ROOT/bin/muster" "${args[@]}"
  fi

  local t0
  t0=$(date +%s)
  local timeout
  timeout=$(config_get ".services.${target}.deploy_timeout" 2>/dev/null)
  [[ "$timeout" =~ ^[0-9]+$ ]] && (( timeout > 0 )) || timeout=120

  _restart_fail() {
    # Args: reason message [extra_json]
    if [[ "$json" == "true" ]]; then
      printf '{"event":"error","reason":%s,"message":%s%s,"services":[%s]}\n' \
        "$(_json_str "$1")" "$(_json_str "$2")" "${3:-}" "$(_json_str "$target")"
      _engine_action_summary "restart" "$target" "$name" "skipped" "$(( $(date +%s) - t0 ))" "-" ""
    else
      err "$2"
    fi
    return 1
  }

  _load_env_file
  local _lock_out=/dev/stdout
  [[ "$json" == "true" ]] && _lock_out=/dev/stderr
  if ! _deploy_lock_acquire "$project_dir" > "$_lock_out"; then
    _unload_env_file
    _restart_fail "locked" "Another deploy or rollback is running in this project"
    return 1
  fi
  trap '_deploy_lock_release "'"$project_dir"'"; _unload_env_file' EXIT
  _restart_end() {
    _deploy_lock_release "$project_dir"
    trap - EXIT
    _unload_env_file
  }

  # ── Build what to run ──
  local script
  script=$(mktemp "${TMPDIR:-/tmp}/muster-restart.XXXXXX") || { _restart_end; return 1; }
  local cred_env="" k8s_env=""
  k8s_env=$(k8s_env_for_service "$target")
  case "$method" in
    hook)
      local check_path="$hook"
      [[ "$use_just" == "true" ]] && check_path="${hook_dir}/justfile"
      local gate_tty=false
      [[ "$json" == "false" && -t 0 ]] && gate_tty=true
      local gate_rc=0
      if [[ "$json" == "true" ]]; then
        _hook_trust_gate "$project_dir" "restart" false "$approve" "$target" >&2 || gate_rc=1
      else
        _hook_trust_gate "$project_dir" "restart" "$gate_tty" "$approve" "$target" || gate_rc=1
      fi
      if (( gate_rc != 0 )); then
        rm -f "$script"
        _restart_fail "hooks_not_approved" "Hooks changed or not approved on this machine (muster hooks status --json)" \
          ",\"files\":$(_engine_pending_files_json)"
        _restart_end
        return 1
      fi
      local sec_out=/dev/stdout
      [[ "$json" == "true" ]] && sec_out=/dev/stderr
      if ! _hook_security_check "$check_path" "$project_dir" > "$sec_out"; then
        rm -f "$script"
        _restart_fail "blocked" "Restart hook blocked by the security check"
        _restart_end
        return 1
      fi
      cred_env=$(cred_env_for_service "$target" 2>/dev/null)
      ;;
    k8s)
      local dep ns
      dep=$(_engine_k8s_deployment "$target")
      ns=$(_engine_k8s_namespace "$target")
      printf 'set -euo pipefail\necho "Restarting deployment/%s in %s..."\nkubectl rollout restart %q -n %q\nkubectl rollout status %q -n %q --timeout=%ss\necho "%s restarted"\n' \
        "$dep" "$ns" "deployment/${dep}" "$ns" "deployment/${dep}" "$ns" "$timeout" "$target" > "$script"
      ;;
    compose)
      local cf cname
      cf=$(_engine_compose_file "$target" "$project_dir")
      cname=$(_engine_container_name "$target" "$project_dir")
      printf 'set -euo pipefail\necho "Restarting %s (docker compose)..."\ndocker compose -f %q restart %q\necho "%s restarted"\n' \
        "$cname" "$cf" "$cname" "$target" > "$script"
      ;;
    docker)
      local cname
      cname=$(_engine_container_name "$target" "$project_dir")
      printf 'set -euo pipefail\necho "Restarting container %s..."\ndocker restart %q\necho "%s restarted"\n' \
        "$cname" "$cname" "$target" > "$script"
      ;;
  esac

  local log_dir="${project_dir}/.muster/logs"
  mkdir -p "$log_dir"
  local log_file
  log_file="${log_dir}/${target}-restart-$(date +%Y%m%d-%H%M%S).log"

  local _k _v
  while IFS='=' read -r _k _v; do
    [[ -z "$_k" ]] && continue
    export "$_k=$_v"
  done <<< "${cred_env}
${k8s_env}"
  export MUSTER_SERVICE_NAME="$name"
  local all_env="${cred_env}
${k8s_env}"

  # The command to run, as an argv
  local run=()
  if [[ "$method" == "hook" ]]; then
    if remote_is_enabled "$target"; then
      _remote_load_config "$target"
      _remote_build_opts
      if [[ "$use_just" == "true" ]] && _just_remote_available; then
        run=(_just_remote_run "$target" "restart" "$all_env")
      else
        run=(remote_exec_stdout "$target" "$hook" "$all_env")
      fi
    elif [[ "$use_just" == "true" ]]; then
      run=(just --justfile "${hook_dir}/justfile" restart)
    else
      run=("$hook")
    fi
  else
    run=(_engine_run_script "$target" "$script" "$all_env")
  fi

  local rc=0
  if [[ "$json" == "true" ]]; then
    printf '{"event":"start","service":%s,"name":%s,"action":"restart","method":%s,"stack":%s,"index":1,"total":1,"log_file":%s}\n' \
      "$(_json_str "$target")" "$(_json_str "$name")" "$(_json_str "$method")" "$(_json_str "$stack")" "$(_json_str "$log_file")"
    _engine_stream "$target" "$log_file" "$timeout" "${run[@]}" || rc=$?
  else
    echo ""
    info "Restarting ${name} (${method})"
    _run_with_timeout "$timeout" "${run[@]}" 2>&1 | tee -a "$log_file"
    rc=${PIPESTATUS[0]}
  fi
  rm -f "$script"

  local result="failed" health="-"
  if (( rc == 0 )); then
    result="restarted"
    _history_log_event "$target" "restart" "ok"
    if [[ "$json" == "true" ]]; then
      printf '{"event":"done","service":%s,"status":"success"}\n' "$(_json_str "$target")"
      _engine_health_events "$target" "$project_dir"
      health="$_ENGINE_HEALTH"
    else
      ok "${name} restarted"
      local hrc=0
      _engine_health_check "$target" "$project_dir" || hrc=$?
      case "$hrc" in
        0) health="healthy"; ok "${name} is healthy" ;;
        1) health="unhealthy"; err "${name} failed its health check" ;;
        *) health="disabled" ;;
      esac
    fi
  else
    _history_log_event "$target" "restart" "failed"
    if [[ "$json" == "true" ]]; then
      if (( rc == 124 )); then
        printf '{"event":"done","service":%s,"status":"timeout","timeout":%d}\n' "$(_json_str "$target")" "$timeout"
      else
        printf '{"event":"done","service":%s,"status":"failed","exit_code":%d}\n' "$(_json_str "$target")" "$rc"
      fi
      k8s_diagnose_json "$target" 2>/dev/null
    else
      if (( rc == 124 )); then
        err "${name} restart timed out after ${timeout}s"
      else
        err "${name} restart failed (exit code ${rc})"
      fi
      printf '  %bLog: %s%b\n' "${DIM}" "$log_file" "${RESET}"
      k8s_diagnose_failure "$target"
    fi
  fi

  while IFS='=' read -r _k _v; do
    [[ -z "$_k" ]] && continue
    unset "$_k"
  done <<< "${cred_env}
${k8s_env}"

  local final=0
  if [[ "$json" == "true" ]]; then
    _engine_action_summary "restart" "$target" "$name" "$result" "$(( $(date +%s) - t0 ))" "$health" "$log_file" || final=1
  else
    [[ "$result" == "failed" || "$health" == "unhealthy" ]] && final=1
  fi
  _restart_end
  unset -f _restart_fail _restart_end
  return $final
}
