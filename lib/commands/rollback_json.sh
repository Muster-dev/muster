#!/usr/bin/env bash
# muster/lib/commands/rollback_json.sh — `muster rollback <svc> --json`
#
# Same event shapes as `deploy --json` (start / log / done / diagnosis /
# health / summary), one service, no recovery menu. See docs/ENGINE-API.md.
# Sourced by rollback.sh, which has already sourced credentials, remote,
# k8s_diag, just_runner, hook_security, the skill manager and history.

source "$MUSTER_ROOT/lib/core/engine.sh"

# Usage: _rollback_json target approve_hooks(true|false)
# Returns: 0 rolled back (and healthy if checked), 1 otherwise
_rollback_json() {
  local target="$1" approve="$2"

  source "$MUSTER_ROOT/lib/core/auth.sh"
  _json_auth_gate "deploy" || return 1

  if [[ -z "$target" ]]; then
    _json_error "usage" "No service given. Usage: muster rollback <service> --json"
    return 1
  fi
  local _known
  _known=" $(config_services | tr '\n' ' ') "
  if [[ "$_known" != *" ${target} "* ]]; then
    _json_error "unknown_service" "Unknown service: ${target}"
    return 1
  fi

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local name
  name=$(config_get ".services.${target}.name")
  [[ -z "$name" || "$name" == "null" ]] && name="$target"
  local t0
  t0=$(date +%s)

  local hook="${project_dir}/.muster/hooks/${target}/rollback.sh"
  local hook_dir="${project_dir}/.muster/hooks/${target}"
  local use_just=false
  if _just_available "$hook_dir" && _just_has_recipe "$hook_dir" "rollback"; then
    use_just=true
  fi

  _rbj_fail() {
    # Args: reason message [extra_json]
    printf '{"event":"error","reason":%s,"message":%s%s,"services":[%s]}\n' \
      "$(_json_str "$1")" "$(_json_str "$2")" "${3:-}" "$(_json_str "$target")"
    _engine_action_summary "rollback" "$target" "$name" "skipped" "$(( $(date +%s) - t0 ))" "-" ""
    return 1
  }

  if [[ "$use_just" == "false" && ! -x "$hook" ]]; then
    _rbj_fail "no_hook" "No rollback hook for ${target} (.muster/hooks/${target}/rollback.sh)"
    return 1
  fi

  _load_env_file
  if ! _deploy_lock_acquire "$project_dir" >&2; then
    _unload_env_file
    _rbj_fail "locked" "Another deploy or rollback is running in this project"
    return 1
  fi
  trap '_deploy_lock_release "'"$project_dir"'"; _unload_env_file' EXIT

  _rbj_end() {
    _deploy_lock_release "$project_dir"
    trap - EXIT
    _unload_env_file
  }

  if ! _hook_trust_gate "$project_dir" "roll back" false "$approve" "$target" >&2; then
    _rbj_fail "hooks_not_approved" "Hooks changed or not approved on this machine (muster hooks status --json)" \
      ",\"files\":$(_engine_pending_files_json)"
    _rbj_end
    return 1
  fi

  local check_path="$hook"
  [[ "$use_just" == "true" ]] && check_path="${hook_dir}/justfile"
  if ! _hook_security_check "$check_path" "$project_dir" >&2; then
    printf '{"event":"done","service":%s,"status":"blocked"}\n' "$(_json_str "$target")"
    _history_log_event "$target" "rollback" "failed"
    _engine_action_summary "rollback" "$target" "$name" "failed" "$(( $(date +%s) - t0 ))" "-" ""
    _rbj_end
    return 1
  fi

  local log_dir="${project_dir}/.muster/logs"
  mkdir -p "$log_dir"
  local log_file
  log_file="${log_dir}/${target}-rollback-$(date +%Y%m%d-%H%M%S).log"

  # Credentials + k8s env for the hook
  local cred_env k8s_env
  cred_env=$(cred_env_for_service "$target" 2>/dev/null)
  k8s_env=$(k8s_env_for_service "$target")
  local _k _v
  while IFS='=' read -r _k _v; do
    [[ -z "$_k" ]] && continue
    export "$_k=$_v"
  done <<< "${cred_env}
${k8s_env}"

  export MUSTER_DEPLOY_STATUS=""
  export MUSTER_SERVICE_NAME="$name"
  run_skill_hooks "pre-rollback" "$target" >&2 2>/dev/null

  local timeout
  timeout=$(config_get ".services.${target}.deploy_timeout" 2>/dev/null)
  [[ "$timeout" =~ ^[0-9]+$ ]] && (( timeout > 0 )) || timeout=120

  printf '{"event":"start","service":%s,"name":%s,"action":"rollback","index":1,"total":1,"log_file":%s}\n' \
    "$(_json_str "$target")" "$(_json_str "$name")" "$(_json_str "$log_file")"

  local rc=0
  if remote_is_enabled "$target"; then
    local all_env="${cred_env}
${k8s_env}"
    _remote_load_config "$target"
    _remote_build_opts
    if [[ "$use_just" == "true" ]] && _just_remote_available; then
      _engine_stream "$target" "$log_file" "$timeout" _just_remote_run "$target" "rollback" "$all_env" || rc=$?
    else
      _engine_stream "$target" "$log_file" "$timeout" remote_exec_stdout "$target" "$hook" "$all_env" || rc=$?
    fi
  elif [[ "$use_just" == "true" ]]; then
    _engine_stream "$target" "$log_file" "$timeout" just --justfile "${hook_dir}/justfile" rollback || rc=$?
  else
    _engine_stream "$target" "$log_file" "$timeout" "$hook" || rc=$?
  fi

  local result="failed" health="-"
  if (( rc == 0 )); then
    result="rolled back"
    printf '{"event":"done","service":%s,"status":"success"}\n' "$(_json_str "$target")"
    _history_log_event "$target" "rollback" "ok"
    export MUSTER_DEPLOY_STATUS="success"
    run_skill_hooks "post-rollback" "$target" >&2 2>/dev/null
    _engine_health_events "$target" "$project_dir"
    health="$_ENGINE_HEALTH"
  else
    if (( rc == 124 )); then
      printf '{"event":"done","service":%s,"status":"timeout","timeout":%d}\n' "$(_json_str "$target")" "$timeout"
    else
      printf '{"event":"done","service":%s,"status":"failed","exit_code":%d}\n' "$(_json_str "$target")" "$rc"
    fi
    _history_log_event "$target" "rollback" "failed"
    k8s_diagnose_json "$target" 2>/dev/null
    export MUSTER_DEPLOY_STATUS="failed"
    run_skill_hooks "post-rollback" "$target" >&2 2>/dev/null
  fi

  while IFS='=' read -r _k _v; do
    [[ -z "$_k" ]] && continue
    unset "$_k"
  done <<< "${cred_env}
${k8s_env}"

  local final=0
  _engine_action_summary "rollback" "$target" "$name" "$result" "$(( $(date +%s) - t0 ))" "$health" "$log_file" || final=1
  _rbj_end
  unset -f _rbj_fail _rbj_end
  return $final
}
