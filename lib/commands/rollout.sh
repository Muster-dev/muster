#!/usr/bin/env bash
# muster/lib/commands/rollout.sh — muster rollout status | promote | abort
# (progressive delivery; see docs/rollouts.md and lib/core/rollout_k8s.sh)

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/core/rollout_k8s.sh"
source "$MUSTER_ROOT/lib/core/suggest.sh"
source "$MUSTER_ROOT/lib/commands/history.sh"

# Exit with an error in the right format. Usage: _rollout_fail json code message
_rollout_fail() {
  if [[ "$1" == "true" ]]; then
    _json_error "$2" "$3"
  else
    err "$3"
  fi
  return 1
}

# Validate a service name (prints did-you-mean). Usage: _rollout_known_svc svc json
_rollout_known_svc() {
  local svc="$1" known
  known=" $(config_services | tr '\n' ' ') "
  [[ "$known" == *" ${svc} "* ]] && return 0
  if [[ "$2" == "true" ]]; then
    _json_error "unknown_service" "Unknown service: ${svc}"
  else
    err "Unknown service: ${svc}"
    # shellcheck disable=SC2046
    _suggest_print "$svc" $(config_services) || true
  fi
  return 1
}

# Snapshot for any service: k8s via kubectl, else history
_rollout_any_snapshot() {
  local svc="$1" dep
  dep=$(config_get ".services.${svc}.k8s.deployment" 2>/dev/null)
  if [[ -n "$dep" && "$dep" != "null" ]] && { remote_is_enabled "$svc" || has_cmd kubectl; }; then
    _rollout_snapshot "$svc"
  else
    _rollout_history_snapshot "$svc"
  fi
}

# ── muster rollout ──

cmd_rollout() {
  local sub="${1:-}"
  case "$sub" in
    status) shift; _rollout_cmd_status "$@" ;;
    --help|-h|help|"")
      echo "Usage: muster rollout status [service...] [--watch] [--interval N] [--json]"
      echo ""
      echo "Show what each service is running: versions, replicas and traffic share,"
      echo "and the step / next gate of a blue-green or canary rollout. Works for plain"
      echo "rolling deploys too (every live ReplicaSet is listed while it rolls)."
      echo ""
      echo "Related:"
      echo "  muster promote <svc> [--to N | --full]   Continue a paused rollout"
      echo "  muster abort <svc>                       Restore 100% to the stable version"
      echo "  muster deploy <svc> --strategy canary    Start one"
      echo ""
      echo "See docs/rollouts.md."
      [[ -z "$sub" ]] && return 1
      return 0
      ;;
    *)
      err "Unknown rollout command: ${sub}"
      _suggest_print "$sub" status || true
      echo "Run 'muster rollout --help' for usage."
      return 1
      ;;
  esac
}

_rollout_cmd_status() {
  local json=false watch=false interval=3 targets=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=true; shift ;;
      --watch|-w) watch=true; shift ;;
      --interval)
        interval="${2:-}"; shift 2 ;;
      --interval=*) interval="${1#--interval=}"; shift ;;
      --help|-h) cmd_rollout --help; return 0 ;;
      -*)
        err "Unknown flag: $1"
        _suggest_print "$1" --json --watch --interval --help || true
        return 1
        ;;
      *) targets[${#targets[@]}]="$1"; shift ;;
    esac
  done
  [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 )) || { err "--interval needs whole seconds (1 or more)"; return 1; }
  load_config
  has_cmd jq || { _rollout_fail "$json" "missing_dependency" "jq is required for muster rollout"; return 1; }
  if [[ "$json" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
  fi
  local svc
  if (( ${#targets[@]} == 0 )); then
    while IFS= read -r svc; do
      [[ -n "$svc" ]] && targets[${#targets[@]}]="$svc"
    done < <(config_services)
  else
    for svc in "${targets[@]}"; do
      _rollout_known_svc "$svc" "$json" || return 1
    done
  fi
  local project
  project=$(config_get '.project')

  while true; do
    local docs="" any_live=false snap obj
    for svc in "${targets[@]}"; do
      snap=$(_rollout_any_snapshot "$svc" 2>/dev/null)
      [[ -z "$snap" || "$snap" == "null" ]] && snap='{"rollout":null,"idle":{"state":"unknown"}}'
      obj=$(printf '%s' "$snap" | jq -c '.rollout // .idle')
      [[ "$(printf '%s' "$snap" | jq -r '.rollout != null')" == "true" ]] && any_live=true
      if [[ "$json" == "true" && "$watch" == "true" ]]; then
        printf '{"event":"rollout_state","service":%s,"checked_at":%s,"rollout":%s}\n' \
          "$(_json_str "$svc")" "$(_json_str "$(_engine_now_iso)")" "$obj"
      fi
      docs="${docs}${docs:+,}$(_json_str "$svc"):${obj}"
    done
    if [[ "$json" == "true" && "$watch" != "true" ]]; then
      printf '{"project":%s,"checked_at":%s,"services":{%s}}\n' \
        "$(_json_str "$project")" "$(_json_str "$(_engine_now_iso)")" "$docs"
    elif [[ "$json" != "true" ]]; then
      if [[ "$watch" == "true" && -t 1 && "${MUSTER_ANSI:-true}" != "false" ]]; then
        printf '\033[H\033[J'
      fi
      echo ""
      printf '  %b%s%b — Rollouts %b%s%b\n' "${BOLD}" "$project" "${RESET}" "${DIM}" "$(date '+%H:%M:%S')" "${RESET}"
      echo ""
      for svc in "${targets[@]}"; do
        obj=$(printf '%s' "{${docs}}" | jq -c --arg s "$svc" '.[$s]')
        if [[ "$(printf '%s' "$obj" | jq -r '.versions | length')" == "0" ]]; then
          printf '%b\n' "  ${BOLD}${svc}${RESET}  ${DIM}no version information yet${RESET}"
        else
          _rollout_render "$svc" "$obj" "  "
        fi
        echo ""
      done
    fi
    [[ "$watch" == "true" ]] || return 0
    [[ "$any_live" == "true" ]] || return 0
    sleep "$interval"
  done
}

# ── promote / abort ──

# Shared setup for promote/abort: parse, validate, lock, load state.
# Sets: _RC_SVC _RC_JSON _RC_YES _RC_TO _RC_FULL _RC_PROJECT_DIR
_rollout_action_setup() {
  local action="$1"; shift
  _RC_SVC=""; _RC_JSON=false; _RC_YES=false; _RC_TO=""; _RC_FULL=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) _RC_JSON=true; shift ;;
      --yes|-y) _RC_YES=true; shift ;;
      --full)
        [[ "$action" == "promote" ]] || { err "--full only applies to promote"; return 1; }
        _RC_FULL=true; shift ;;
      --to)
        [[ "$action" == "promote" ]] || { err "--to only applies to promote"; return 1; }
        _RC_TO="${2:-}"; shift 2 ;;
      --to=*) _RC_TO="${1#--to=}"; shift ;;
      --help|-h)
        if [[ "$action" == "promote" ]]; then
          echo "Usage: muster promote <service> [--to <weight> | --full] [--yes] [--json]"
          echo ""
          echo "Continue a paused rollout:"
          echo "  (default)   canary: next step (runs timed steps until the next manual pause)"
          echo "              blue-green: switch the Service to the new colour"
          echo "  --to N      canary: go to N% and pause there"
          echo "  --full      go straight to 100%"
          echo "  --yes       don't ask for confirmation"
          echo "  --json      NDJSON events (rollout_step, traffic_shift, analysis, promoted)"
        else
          echo "Usage: muster abort <service> [--yes] [--json]"
          echo ""
          echo "Stop a rollout and send 100% of traffic back to the stable version; the"
          echo "candidate is scaled to 0. 'muster rollback <svc>' does the same while a"
          echo "rollout is in progress."
        fi
        return 2
        ;;
      -*)
        err "Unknown flag: $1"
        _suggest_print "$1" --to --full --yes --json --help || true
        return 1
        ;;
      *)
        [[ -n "$_RC_SVC" ]] && { err "${action} takes one service"; return 1; }
        _RC_SVC="$1"; shift ;;
    esac
  done
  if [[ -z "$_RC_SVC" ]]; then
    err "Usage: muster ${action} <service>"
    return 1
  fi
  if [[ -n "$_RC_TO" ]] && ! [[ "$_RC_TO" =~ ^[0-9]+$ && "$_RC_TO" -ge 1 && "$_RC_TO" -le 100 ]]; then
    err "--to needs a weight between 1 and 100"
    return 1
  fi
  load_config
  _load_env_file
  _rollout_known_svc "$_RC_SVC" "$_RC_JSON" || return 1
  if [[ "$_RC_JSON" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "deploy" || return 1
  fi
  has_cmd jq || { _rollout_fail "$_RC_JSON" "missing_dependency" "jq is required"; return 1; }
  _RC_PROJECT_DIR="$(dirname "$CONFIG_FILE")"
  _RO_JSON="$_RC_JSON"
  if ! _ro_ctx "$_RC_SVC"; then
    _rollout_fail "$_RC_JSON" "not_kubernetes" "${_RC_SVC} isn't a Kubernetes service (no k8s.deployment) — nothing to ${action}"
    return 1
  fi
  if [[ "$_RO_REMOTE" != "true" ]] && ! has_cmd kubectl; then
    _rollout_fail "$_RC_JSON" "missing_dependency" "kubectl not found"
    return 1
  fi
  if ! _ro_state_load; then
    _rollout_fail "$_RC_JSON" "no_rollout" "No rollout recorded for ${_RC_SVC} (ConfigMap ${_RO_CM} in ${_RO_NS})"
    return 1
  fi
  if ! _ro_state_active; then
    _rollout_fail "$_RC_JSON" "no_rollout" "No rollout in progress for ${_RC_SVC} (last: $(_ro_st state))"
    return 1
  fi
  _RO_TYPE=$(_ro_st strategy)
  return 0
}

# Confirm in a TTY unless --yes. Usage: _rollout_confirm "question"
_rollout_confirm() {
  [[ "$_RC_YES" == "true" || "$_RC_JSON" == "true" || ! -t 0 ]] && return 0
  echo ""
  menu_select "$1" "Yes" "Cancel"
  [[ "$MENU_RESULT" == "Yes" ]]
}

# Take the deploy + service locks for the action; EXIT releases them.
_rollout_lock() {
  local out=/dev/stdout
  [[ "$_RC_JSON" == "true" ]] && out=/dev/stderr
  _deploy_lock_acquire "$_RC_PROJECT_DIR" > "$out" || return 1
  MUSTER_LOCK_SOURCE="local"; export MUSTER_LOCK_SOURCE
  if ! _service_lock_acquire "$_RC_PROJECT_DIR" "$_RC_SVC" > "$out"; then
    _deploy_lock_release "$_RC_PROJECT_DIR"
    return 1
  fi
  trap '_service_lock_release "'"$_RC_PROJECT_DIR"'" "'"$_RC_SVC"'"; _deploy_lock_release "'"$_RC_PROJECT_DIR"'"; _unload_env_file' EXIT
  trap '_ro_on_interrupt' INT TERM
  return 0
}

_rollout_unlock() {
  _service_lock_release "$_RC_PROJECT_DIR" "$_RC_SVC"
  _deploy_lock_release "$_RC_PROJECT_DIR"
  trap - EXIT
  trap '_on_sigint' INT
  trap - TERM
  _unload_env_file
}

# Final NDJSON line for promote/abort. Usage: _rollout_done action rc
_rollout_done() {
  local action="$1" rc="$2" status
  case "$_RO_RESULT" in
    deployed) status="promoted" ;;
    paused) status="paused" ;;
    aborted) status="aborted" ;;
    degraded) status="degraded" ;;
    *) status=$([[ "$rc" == "0" ]] && echo ok || echo failed) ;;
  esac
  if [[ "$_RC_JSON" == "true" ]]; then
    printf '{"event":"done","service":%s,"action":%s,"status":%s,"rollout_state":%s,"exit_code":%d}\n' \
      "$(_json_str "$_RC_SVC")" "$(_json_str "$action")" "$(_json_str "$status")" \
      "$(_json_str_or_null "$(_ro_st state)")" "$rc"
  fi
}

cmd_promote() {
  local src=0
  _rollout_action_setup promote "$@" || src=$?
  (( src == 2 )) && return 0
  (( src != 0 )) && return 1

  local cur next desc
  cur=$(_ro_st weight)
  if [[ "$_RO_TYPE" == "blue-green" ]]; then
    desc="Switch ${_RC_SVC} to $(_ro_st candidate_version) ($(_ro_st candidate_track))?"
  elif [[ "$_RC_FULL" == "true" ]]; then
    desc="Promote ${_RC_SVC} straight to 100% ($(_ro_st candidate_version))?"
  elif [[ -n "$_RC_TO" ]]; then
    desc="Promote ${_RC_SVC} from ${cur}% to ${_RC_TO}% ($(_ro_st candidate_version))?"
  else
    next=$(printf '%s' "$_RO_STATE" | jq -r '.steps[.step].weight // 100')
    desc="Promote ${_RC_SVC} from ${cur}% to ${next}% ($(_ro_st candidate_version))?"
  fi
  if ! _rollout_confirm "$desc"; then
    info "Nothing changed."
    return 0
  fi
  _rollout_lock || return 1
  _RO_INTERACTIVE=false; _RO_NO_WAIT=false; _RO_HOOK_FN=""; _RO_RESULT=""
  _RO_STRAT=$(_rollout_strategy "$_RC_SVC" "$_RO_TYPE")
  local rc=0
  if [[ "$_RC_FULL" == "true" ]]; then
    _rollout_promote_current --full || rc=$?
  elif [[ -n "$_RC_TO" ]]; then
    _rollout_promote_current --to "$_RC_TO" || rc=$?
  else
    _rollout_promote_current || rc=$?
  fi
  _rollout_done promote "$rc"
  _rollout_unlock
  return $rc
}

cmd_abort() {
  local src=0
  _rollout_action_setup abort "$@" || src=$?
  (( src == 2 )) && return 0
  (( src != 0 )) && return 1
  if ! _rollout_confirm "Abort the ${_RC_SVC} rollout and send 100% of traffic back to $(_ro_st stable_version)?"; then
    info "Nothing changed."
    return 0
  fi
  _rollout_lock || return 1
  _RO_STRAT=$(_rollout_strategy "$_RC_SVC" "$_RO_TYPE")
  local rc=0
  _rollout_abort_current user_abort || rc=$?
  (( rc == 0 )) && _RO_RESULT="aborted"
  _rollout_done abort "$rc"
  _rollout_unlock
  return $rc
}

# `muster rollback <svc>` for blue-green/canary services (called from
# rollback.sh after _rollout_rollback_mode said abort|bg).
# Usage: _rollout_cmd_rollback svc mode json
_rollout_cmd_rollback() {
  local svc="$1" mode="$2" json="$3"
  _RC_SVC="$svc"; _RC_JSON="$json"; _RC_YES=true
  _RC_PROJECT_DIR="$(dirname "$CONFIG_FILE")"
  _RO_JSON="$json"
  if [[ "$json" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "deploy" || return 1
  fi
  _rollout_lock || return 1
  local _rb_t0
  _rb_t0=$(date +%s)
  _ro_ctx "$svc"; _ro_state_load
  _RO_STRAT=$(_rollout_strategy "$svc" "$(_ro_st strategy)")
  local rc=0
  if [[ "$json" == "true" ]]; then
    printf '{"event":"start","service":%s,"action":"rollback","strategy":%s,"mode":%s}\n' \
      "$(_json_str "$svc")" "$(_json_str "$(_ro_st strategy)")" "$(_json_str "$mode")"
  else
    echo ""
    if [[ "$mode" == "abort" ]]; then
      info "${svc} has a rollout in progress — aborting it (same as muster abort ${svc})"
    else
      info "${svc} is blue-green — switching traffic back to the previous colour"
    fi
  fi
  if [[ "$mode" == "abort" ]]; then
    _rollout_abort_current user_abort || rc=$?
  else
    _ro_bg_rollback || rc=$?
  fi
  if [[ "$json" == "true" ]]; then
    local st="success"
    (( rc != 0 )) && st="failed"
    printf '{"event":"done","service":%s,"status":"%s","rollout_state":%s}\n' \
      "$(_json_str "$svc")" "$st" "$(_json_str_or_null "$(_ro_st state)")"
    local _rn
    _rn=$(config_get ".services.${svc}.name" 2>/dev/null); [[ -z "$_rn" || "$_rn" == "null" ]] && _rn="$svc"
    _engine_action_summary "rollback" "$svc" "$_rn" "$( (( rc == 0 )) && echo "rolled back" || echo failed)" \
      "$(( $(date +%s) - _rb_t0 ))" "-" "" || true
  fi
  _rollout_unlock
  return $rc
}
