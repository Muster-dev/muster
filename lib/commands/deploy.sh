#!/usr/bin/env bash
# muster/lib/commands/deploy.sh — Deploy orchestration

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/tui/checklist.sh"
source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/tui/progress.sh"
source "$MUSTER_ROOT/lib/tui/streambox.sh"
source "$MUSTER_ROOT/lib/core/credentials.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"
source "$MUSTER_ROOT/lib/core/k8s_diag.sh"
source "$MUSTER_ROOT/lib/core/just_runner.sh"
source "$MUSTER_ROOT/lib/core/hook_security.sh"
source "$MUSTER_ROOT/lib/skills/manager.sh"
source "$MUSTER_ROOT/lib/commands/history.sh"

# Run a deploy command with TUI stream box (interactive) or plain (non-interactive)
# Usage: _deploy_run_hook "title" "log_file" command args...
_deploy_run_hook() {
  local _drh_title="$1" _drh_log="$2"
  shift 2
  if [[ -t 0 && "$MUSTER_MINIMAL" != "true" ]]; then
    stream_in_box "$_drh_title" "$_drh_log" "$@"
  elif [[ "${MUSTER_DEPLOY_SOURCE:-}" != "" ]]; then
    # Fleet deploy (non-interactive): tee to log + stdout so deployer sees progress
    "$@" 2>&1 | tee -a "$_drh_log"
  else
    # Non-interactive: run directly, output to log file
    "$@" >> "$_drh_log" 2>&1
  fi
}

# Verify a deploy hook actually did something meaningful
# Args: log_file, service_name, start_time [json]
# Pass "json" as 4th arg to emit NDJSON warnings instead of TUI output
# Returns 0 always (warnings only, never blocks deploy)
_deploy_verify() {
  local log_file="$1" svc="$2" start_time="$3"
  local json_mode="${4:-}"
  local warnings=0

  _deploy_verify_warn() {
    local msg="$1"
    if [[ "$json_mode" == "json" ]]; then
      local _escaped
      _escaped=$(printf '%s' "$msg" | sed 's/\\/\\\\/g;s/"/\\"/g')
      printf '{"event":"verify_warning","service":"%s","message":"%s"}\n' "$svc" "$_escaped"
    else
      printf '%b\n' "  ${YELLOW}!${RESET} ${svc}: ${msg}"
    fi
  }

  # Check 1: empty log
  if [[ ! -s "$log_file" ]]; then
    _deploy_verify_warn "deploy produced no output"
    warnings=$((warnings + 1))
  fi

  # Check 2: suspiciously fast
  local end_time
  end_time=$(date +%s)
  local duration=$(( end_time - start_time ))
  if (( duration < 1 )); then
    _deploy_verify_warn "deploy completed in <1s — verify it ran"
    warnings=$((warnings + 1))
  fi

  # Check 3: success markers in log output
  if [[ -s "$log_file" ]]; then
    if ! grep -qiE '(deployed|started|restarted|applied|pushed|built|running|complete|success|ready)' "$log_file" 2>/dev/null; then
      _deploy_verify_warn "no success markers in deploy output"
      warnings=$((warnings + 1))
    fi
  fi

  unset -f _deploy_verify_warn
  return 0
}

# ── Per-service results (for the end-of-deploy summary + exit code) ──
_DR_SVC=()
_DR_NAME=()
_DR_RESULT=()   # deployed | failed | skipped | rolled back
_DR_DUR=()      # seconds
_DR_HEALTH=()   # healthy | unhealthy | disabled | -
_DR_LOG=()      # deploy log path ("" if none)
_DR_ERROR=()    # true when this entry should make the deploy exit non-zero

# Args: svc name result duration health log is_error
_deploy_record() {
  local i=${#_DR_SVC[@]}
  _DR_SVC[$i]="$1"
  _DR_NAME[$i]="$2"
  _DR_RESULT[$i]="$3"
  _DR_DUR[$i]="$4"
  _DR_HEALTH[$i]="$5"
  _DR_LOG[$i]="$6"
  _DR_ERROR[$i]="$7"
}

# Record every service after position $1 (0-based) as skipped — used when a
# deploy stops early (non-interactive failure, Abort).
# Args: next_index service...
_deploy_record_remaining() {
  local next="$1"; shift
  local idx=0 svc
  for svc in "$@"; do
    if (( idx >= next )); then
      local _rn
      _rn=$(config_get ".services.${svc}.name" 2>/dev/null)
      [[ -z "$_rn" || "$_rn" == "null" ]] && _rn="$svc"
      _deploy_record "$svc" "$_rn" "skipped" 0 "-" "" "true"
    fi
    idx=$(( idx + 1 ))
  done
}

# Format seconds as 41s / 2m05s
_deploy_fmt_dur() {
  local s="${1:-0}"
  if (( s >= 60 )); then
    printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%ds' "$s"
  fi
}

# Print the end-of-deploy summary (table or NDJSON) and return the exit code:
#   0  every selected service deployed (and passed its health check)
#   1  one or more services failed, were skipped because of an error,
#      were rolled back, or failed their health check
# Args: json(true|false) project_dir total_seconds
_deploy_summary() {
  local json="$1" project_dir="$2" total_s="$3"
  local n=${#_DR_SVC[@]}
  local deployed=0 failed=0 skipped=0 rolled=0 errors=0
  local i=0
  while (( i < n )); do
    case "${_DR_RESULT[$i]}" in
      deployed) deployed=$(( deployed + 1 )) ;;
      failed) failed=$(( failed + 1 )) ;;
      skipped) skipped=$(( skipped + 1 )) ;;
      "rolled back") rolled=$(( rolled + 1 )) ;;
    esac
    [[ "${_DR_ERROR[$i]}" == "true" ]] && errors=$(( errors + 1 ))
    i=$(( i + 1 ))
  done
  local rc=0
  (( errors > 0 )) && rc=1

  if [[ "$json" == "true" ]]; then
    local items="" first=true
    i=0
    while (( i < n )); do
      [[ "$first" == "true" ]] && first=false || items="${items},"
      items="${items}{\"service\":\"${_DR_SVC[$i]}\",\"result\":\"${_DR_RESULT[$i]}\",\"duration\":${_DR_DUR[$i]},\"health\":\"${_DR_HEALTH[$i]}\",\"log_file\":\"${_DR_LOG[$i]}\"}"
      i=$(( i + 1 ))
    done
    printf '{"event":"summary","total":%d,"deployed":%d,"failed":%d,"skipped":%d,"rolled_back":%d,"duration":%d,"exit_code":%d,"services":[%s]}\n' \
      "$n" "$deployed" "$failed" "$skipped" "$rolled" "$total_s" "$rc" "$items"
    return $rc
  fi

  (( n == 0 )) && return $rc

  # Column widths from plain text (colors are applied outside the padding)
  local w_name=7 w_res=6
  i=0
  while (( i < n )); do
    (( ${#_DR_NAME[$i]} > w_name )) && w_name=${#_DR_NAME[$i]}
    (( ${#_DR_RESULT[$i]} > w_res )) && w_res=${#_DR_RESULT[$i]}
    i=$(( i + 1 ))
  done

  echo ""
  printf '  %b%-*s  %-*s  %6s  %s%b\n' "${DIM}" "$w_name" "Service" "$w_res" "Result" "Time" "Health" "${RESET}"
  i=0
  while (( i < n )); do
    local color="$GREEN" hcolor="$DIM"
    case "${_DR_RESULT[$i]}" in
      failed) color="$RED" ;;
      skipped|"rolled back") color="$YELLOW" ;;
    esac
    case "${_DR_HEALTH[$i]}" in
      healthy) hcolor="$GREEN" ;;
      unhealthy) hcolor="$RED" ;;
    esac
    printf '  %-*s  %b%-*s%b  %6s  %b%s%b\n' \
      "$w_name" "${_DR_NAME[$i]}" \
      "$color" "$w_res" "${_DR_RESULT[$i]}" "$RESET" \
      "$(_deploy_fmt_dur "${_DR_DUR[$i]}")" \
      "$hcolor" "${_DR_HEALTH[$i]}" "$RESET"
    i=$(( i + 1 ))
  done
  echo ""

  # Final line: "3 deployed in 41s" / "2 deployed, 1 failed — see <log>"
  local parts="${deployed} deployed"
  (( failed > 0 )) && parts="${parts}, ${failed} failed"
  (( rolled > 0 )) && parts="${parts}, ${rolled} rolled back"
  (( skipped > 0 )) && parts="${parts}, ${skipped} skipped"

  if (( rc == 0 )); then
    ok "${parts} in $(_deploy_fmt_dur "$total_s")"
  else
    local logs=()
    i=0
    while (( i < n )); do
      if [[ "${_DR_ERROR[$i]}" == "true" && -n "${_DR_LOG[$i]}" ]]; then
        logs[${#logs[@]}]="${_DR_LOG[$i]#"${project_dir}/"}"
      fi
      i=$(( i + 1 ))
    done
    if (( ${#logs[@]} > 0 )); then
      err "${parts} — see ${logs[0]}"
      local li=1
      while (( li < ${#logs[@]} )); do
        printf '      see %s\n' "${logs[$li]}"
        li=$(( li + 1 ))
      done
    else
      err "${parts} in $(_deploy_fmt_dur "$total_s")"
    fi
  fi
  return $rc
}

# Progress line before/after a service. With ANSI: the redrawing bar.
# Without (piped / NO_COLOR): one plain "[n/total] name" line per service.
# Args: current total label [done]
_deploy_progress() {
  if [[ "${MUSTER_ANSI:-true}" == "false" ]]; then
    [[ "${4:-}" == "done" ]] && return 0
    printf '  [%d/%d] %s\n' "$1" "$2" "$3"
    return 0
  fi
  if [[ "${4:-}" == "done" ]]; then
    progress_bar "$1" "$2" "$3"
  else
    progress_bar "$(( $1 - 1 ))" "$2" "$3"
  fi
  echo ""
}

# ── Preflight: check the tools selected services need before any hook runs ──
# Detection: k8s via the service's "k8s" config key or kubectl in its hooks;
# docker/compose by grepping the deploy hook (or justfile). Remote services
# are skipped (their tools live on the remote host; ssh is checked elsewhere).
# Args: project_dir service...
# Returns: 0 ok, 1 a required tool is missing/unreachable (message printed)
_deploy_preflight() {
  local project_dir="$1"; shift
  local need_docker=false need_compose=false need_k8s=false
  local svc
  for svc in "$@"; do
    remote_is_enabled "$svc" && continue
    local hd="${project_dir}/.muster/hooks/${svc}"
    local files=""
    [[ -f "${hd}/deploy.sh" ]] && files="${hd}/deploy.sh"
    [[ -f "${hd}/justfile" ]] && files="${files} ${hd}/justfile"
    [[ -z "$files" ]] && continue
    local k8s_cfg
    k8s_cfg=$(config_get ".services.${svc}.k8s" 2>/dev/null)
    # shellcheck disable=SC2086
    if [[ -n "$k8s_cfg" && "$k8s_cfg" != "null" ]] || grep -q 'kubectl' $files 2>/dev/null; then
      need_k8s=true
    fi
    # shellcheck disable=SC2086
    if grep -Eq '(^|[^-[:alnum:]_])docker[[:space:]]+compose([^-[:alnum:]_]|$)' $files 2>/dev/null; then
      need_docker=true; need_compose=true
    elif grep -Eq '(^|[^-[:alnum:]_])docker([^-[:alnum:]_]|$)' $files 2>/dev/null; then
      need_docker=true
    fi
  done

  if [[ "$need_docker" == "true" ]]; then
    if ! has_cmd docker; then
      err "Docker isn't installed (no 'docker' on PATH). Install Docker Desktop or colima and retry."
      return 1
    fi
    if [[ "$need_compose" == "true" ]] && ! docker compose version >/dev/null 2>&1; then
      err "Docker Compose isn't available ('docker compose' failed). Install the Compose v2 plugin and retry."
      return 1
    fi
    if ! _run_with_timeout 15 docker info >/dev/null 2>&1; then
      err "Docker isn't running. Start Docker Desktop/colima and retry."
      return 1
    fi
  fi

  if [[ "$need_k8s" == "true" ]]; then
    if ! has_cmd kubectl; then
      err "kubectl isn't installed. Install it and retry."
      return 1
    fi
    if ! _run_with_timeout 10 kubectl version --request-timeout=5s >/dev/null 2>&1; then
      local ctx
      ctx=$(kubectl config current-context 2>/dev/null)
      err "Can't reach the Kubernetes cluster (context: ${ctx:-none}). Check 'kubectl config current-context' and retry."
      return 1
    fi
  fi
  return 0
}

cmd_deploy() {
  _deploy_main "$@"
  local rc=$?
  # bin/muster's deploy route ignores our return status (it falls through to
  # the return-to-dashboard check), so when we're the top-level command and
  # nothing else runs after us (no TTY, or --json), exit with it directly.
  if (( rc != 0 )) && [[ "${FUNCNAME[1]:-}" == "main" ]]; then
    local _a _json=false
    for _a in "$@"; do [[ "$_a" == "--json" ]] && _json=true; done
    if [[ ! -t 0 || "$_json" == "true" ]]; then
      exit "$rc"
    fi
  fi
  return $rc
}

# Per-service hook timeout in seconds: .services.<svc>.deploy_timeout,
# else 120. Read from config for every service (not inherited from the
# environment, where a previous k8s service's value could leak in).
_deploy_timeout_for() {
  local t
  t=$(config_get ".services.${1}.deploy_timeout" 2>/dev/null)
  if [[ "$t" =~ ^[0-9]+$ ]] && (( t > 0 )); then
    printf '%s' "$t"
  else
    printf '120'
  fi
}

_deploy_main() {
  local dry_run=false
  local _json_mode=false
  local _force=false
  local _approve_hooks=false
  [[ "${MUSTER_APPROVE_HOOKS:-}" == "1" || "${MUSTER_APPROVE_HOOKS:-}" == "true" ]] && _approve_hooks=true
  _DR_SVC=(); _DR_NAME=(); _DR_RESULT=(); _DR_DUR=(); _DR_HEALTH=(); _DR_LOG=(); _DR_ERROR=()
  local _deploy_t0
  _deploy_t0=$(date +%s)
  # Flags and service names may come in any order:
  #   muster deploy api web --dry-run
  local _targets=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: muster deploy [flags] [service...]"
        echo ""
        echo "Deploy services. Without a service name, choose interactively."
        echo ""
        echo "Flags:"
        echo "  --dry-run       Preview deploy plan without executing"
        echo "  --force         Override deploy lock if one exists"
        echo "  --json          Output as NDJSON (one JSON object per line)"
        echo "  --yes           Approve changed/unapproved hooks without review (for CI;"
        echo "                  same as MUSTER_APPROVE_HOOKS=1)"
        echo "  -h, --help      Show this help"
        echo ""
        echo "Exit codes:"
        echo "  0  every selected service deployed and passed its health check"
        echo "  1  a service failed, was rolled back, failed its health check, was"
        echo "     skipped because of an error, or hooks weren't approved"
        echo ""
        echo "Examples:"
        echo "  muster deploy              Interactive: pick all or select services"
        echo "  muster deploy api          Deploy just the api service"
        echo "  muster deploy api web      Deploy several services, in that order"
        echo "  muster deploy --dry-run    Preview all services"
        echo "  muster deploy --json       Stream deploy events as NDJSON"
        echo "  muster deploy fleet test   Deploy a fleet group (shortcut for muster group deploy)"
        return 0
        ;;
      --dry-run) dry_run=true; shift ;;
      --force) _force=true; shift ;;
      --json) _json_mode=true; shift ;;
      --yes) _approve_hooks=true; shift ;;
      -*)
        err "Unknown flag: $1"
        echo "Run 'muster deploy --help' for usage."
        return 1
        ;;
      *) _targets[${#_targets[@]}]="$1"; shift ;;
    esac
  done
  set -- "${_targets[@]+"${_targets[@]}"}"

  # Redirect: muster deploy fleet <name> → muster group deploy <name>
  if [[ "${1:-}" == "fleet" ]]; then
    shift
    source "$MUSTER_ROOT/lib/commands/group.sh"
    _group_cmd_deploy "$@"
    return $?
  fi

  load_config
  _load_env_file
  source "$MUSTER_ROOT/lib/core/build_context.sh"

  local target="all"
  [[ $# -gt 0 ]] && target="selected"
  if [[ $# -gt 0 ]]; then
    local _known_early _te
    _known_early=" $(config_services | tr '\n' ' ') "
    for _te in "$@"; do
      if [[ "$_known_early" != *" ${_te} "* ]]; then
        err "Unknown service: ${_te}"
        printf '  %bServices in this project:%b %s\n' "$DIM" "$RESET" "$(config_services | tr '\n' ' ')"
        _unload_env_file
        return 1
      fi
    done
  fi
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local log_dir="${project_dir}/.muster/logs"
  mkdir -p "$log_dir"

  # Block local deploys while a fleet deploy is in progress (remote pushing to us)
  if [[ -z "${MUSTER_DEPLOY_SOURCE:-}" && -f "${project_dir}/.muster/.fleet_deploying" ]]; then
    local _fleet_src
    _fleet_src=$(cat "${project_dir}/.muster/.fleet_deploying" 2>/dev/null)
    err "Deploy blocked — fleet deploy in progress from ${_fleet_src:-remote}"
    printf '  %bWait for the fleet deploy to finish, or remove %s%b\n' \
      "${DIM}" "${project_dir}/.muster/.fleet_deploying" "${RESET}"
    _unload_env_file
    return 1
  fi

  # Block local deploys while a group deploy is running from this machine
  if [[ -z "${MUSTER_DEPLOY_SOURCE:-}" && -f "$HOME/.muster/.group_deploying" ]]; then
    local _group_src
    _group_src=$(cat "$HOME/.muster/.group_deploying" 2>/dev/null)
    err "Deploy blocked — group deploy in progress: ${_group_src:-unknown}"
    _unload_env_file
    return 1
  fi

  # Acquire deploy lock (skip for dry runs)
  if [[ "$dry_run" == "false" ]]; then
    if [[ "$_force" == "true" ]]; then
      _deploy_lock_release "$project_dir"
    fi
    if ! _deploy_lock_acquire "$project_dir"; then
      _unload_env_file
      return 1
    fi
    trap '_service_lock_release_all "'"$project_dir"'"; _deploy_lock_release "'"$project_dir"'"; _unload_env_file; cleanup_term' EXIT
    # One Ctrl+C (or SIGTERM) cancels a running deploy: stop the hook and
    # everything it started; the EXIT trap above releases the locks.
    trap '_deploy_on_interrupt' INT TERM USR2
  fi

  local project
  project=$(config_get '.project')

  # Auth gate: JSON mode requires valid token
  if [[ "$_json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "deploy" || return 1
  fi

  # Deploy password gate (skip for fleet deploys which use --force)
  if [[ "$_force" != "true" && -t 0 ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    if ! _deploy_password_gate; then
      [[ "$dry_run" == "false" ]] && _deploy_lock_release "$project_dir"
      _unload_env_file
      return 1
    fi
  fi

  if [[ "$_json_mode" == "false" ]]; then
    echo ""
    printf '  %b%bDeploying%b %b%s%b\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}" "${WHITE}" "$project" "${RESET}"
    echo ""

    # Build context overlap warning (detect if cache stale, then read)
    if _build_context_cache_stale; then
      _build_context_detect 2>/dev/null
    fi
    if _build_context_read_cache; then
      local _bc_count=${#_BUILD_CONTEXT_ISSUES[@]}
      printf '  %b!%b %bBuild context overlap — %d issue%s (run muster doctor)%b\n' \
        "${YELLOW}" "${RESET}" "${DIM}" "$_bc_count" \
        "$( (( _bc_count > 1 )) && echo s)" "${RESET}"
      echo ""
    fi
  fi

  if [[ "$MUSTER_MINIMAL" == "true" ]]; then
    if _build_context_cache_stale; then
      _build_context_detect 2>/dev/null
    fi
    _build_context_warn_minimal
  fi

  # Get deploy order
  local services=()
  if [[ "$target" == "all" ]]; then
    local all_services=()
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      local skip
      skip=$(config_get ".services.${svc}.skip_deploy")
      [[ "$skip" == "true" ]] && continue
      all_services[${#all_services[@]}]="$svc"
    done < <(config_get '.deploy_order[]' 2>/dev/null || config_services)

    # Interactive: let user choose all or specific services (skip in JSON mode)
    if [[ "$_json_mode" == "false" && -t 0 ]] && (( ${#all_services[@]} > 1 )); then
      menu_select "Deploy which services?" "All services" "Select services" "Back"
      if [[ "$MENU_RESULT" == "Back" || "$MENU_RESULT" == "__back__" ]]; then
        _unload_env_file
        return 2
      elif [[ "$MENU_RESULT" == "Select services" ]]; then
        checklist_select "Select services to deploy:" "${all_services[@]}"
        if [[ "$CHECKLIST_RESULT" == "__back__" ]]; then
          _unload_env_file
          return 2
        elif [[ -z "$CHECKLIST_RESULT" ]]; then
          warn "No services selected"
          _unload_env_file
          return 0
        fi
        while IFS= read -r svc; do
          [[ -z "$svc" ]] && continue
          services[${#services[@]}]="$svc"
        done <<< "$CHECKLIST_RESULT"
      else
        local _i=0
        while (( _i < ${#all_services[@]} )); do
          services[${#services[@]}]="${all_services[$_i]}"
          _i=$(( _i + 1 ))
        done
      fi
    else
      local _i=0
      while (( _i < ${#all_services[@]} )); do
        services[${#services[@]}]="${all_services[$_i]}"
        _i=$(( _i + 1 ))
      done
    fi
  else
    # Explicit services, in the order given; reject unknown names up front
    local _known _t
    _known=" $(config_services | tr '\n' ' ') "
    for _t in "$@"; do
      if [[ "$_known" != *" ${_t} "* ]]; then
        err "Unknown service: ${_t}"
        printf '  %bServices in this project:%b %s\n' "$DIM" "$RESET" "$(config_services | tr '\n' ' ')"
        _unload_env_file
        return 1
      fi
      services[${#services[@]}]="$_t"
    done
  fi

  # ── Check for deploy_phases (phased parallel deploy) ──
  # Reorders services to match phase order if deploy_phases exists
  local _has_phases=false
  local _phases_json=""
  _phases_json=$(config_get '.deploy_phases' 2>/dev/null || echo "")
  if [[ -n "$_phases_json" && "$_phases_json" != "null" && "$target" == "all" ]]; then
    local _phase_count=0
    _phase_count=$(config_get '.deploy_phases | length' 2>/dev/null || echo "0")
    if (( _phase_count > 0 )); then
      _has_phases=true
      # Reorder services based on phases
      local _phased_services=()
      local _pi=0
      while (( _pi < _phase_count )); do
        local _phase_svcs=""
        _phase_svcs=$(config_get ".deploy_phases[$_pi].services[]" 2>/dev/null || true)
        local _ps
        while IFS= read -r _ps; do
          [[ -z "$_ps" ]] && continue
          # Only include if in selected services
          local _found=false _fi=0
          while (( _fi < ${#services[@]} )); do
            [[ "${services[$_fi]}" == "$_ps" ]] && { _found=true; break; }
            _fi=$((_fi + 1))
          done
          [[ "$_found" == "true" ]] && _phased_services[${#_phased_services[@]}]="$_ps"
        done <<< "$_phase_svcs"
        _pi=$((_pi + 1))
      done
      # Add any services not in phases at the end
      local _si=0
      while (( _si < ${#services[@]} )); do
        local _in_phase=false _pi=0
        while (( _pi < ${#_phased_services[@]} )); do
          [[ "${_phased_services[$_pi]}" == "${services[$_si]}" ]] && { _in_phase=true; break; }
          _pi=$((_pi + 1))
        done
        [[ "$_in_phase" == "false" ]] && _phased_services[${#_phased_services[@]}]="${services[$_si]}"
        _si=$((_si + 1))
      done
      services=("${_phased_services[@]}")
    fi
  fi

  local total=${#services[@]}
  local current=0

  # Release the deploy lock + env when returning early (also covered by the
  # EXIT trap when muster exits, but the dashboard calls us in-process).
  _deploy_end() {
    if [[ "$dry_run" == "false" ]]; then
      _service_lock_release_all "$project_dir" 2>/dev/null
      _deploy_lock_release "$project_dir"
      trap - EXIT
      trap '_on_sigint' INT
      trap - TERM USR2
    fi
    _unload_env_file
  }

  # ── Hook approval gate + tool preflight (real deploys only) ──
  if [[ "$dry_run" == "false" ]] && (( total > 0 )); then
    local _gate_ok=true _gate_reason=""
    if [[ "$_json_mode" == "true" ]]; then
      _hook_trust_gate "$project_dir" "deploy" false "$_approve_hooks" "${services[@]}" >&2 || { _gate_ok=false; _gate_reason="hooks_not_approved"; }
    else
      local _gate_tty=false
      [[ -t 0 ]] && _gate_tty=true
      _hook_trust_gate "$project_dir" "deploy" "$_gate_tty" "$_approve_hooks" "${services[@]}" || { _gate_ok=false; _gate_reason="hooks_not_approved"; }
    fi
    if [[ "$_gate_ok" == "true" ]]; then
      if [[ "$_json_mode" == "true" ]]; then
        _deploy_preflight "$project_dir" "${services[@]}" >&2 || { _gate_ok=false; _gate_reason="preflight_failed"; }
      else
        _deploy_preflight "$project_dir" "${services[@]}" || { _gate_ok=false; _gate_reason="preflight_failed"; }
      fi
    fi
    if [[ "$_gate_ok" == "false" ]]; then
      if [[ "$_json_mode" == "true" ]]; then
        printf '{"event":"error","reason":"%s"}\n' "$_gate_reason"
        _deploy_record_remaining 0 "${services[@]}"
        _deploy_summary true "$project_dir" "$(( $(date +%s) - _deploy_t0 ))"
      else
        echo ""
      fi
      _deploy_end
      return 1
    fi
  fi

  # Pre-authenticate SSH passwords for remote services (before deploy loop)
  # Check sshpass availability first
  local _needs_sshpass=false
  local _si=0
  while (( _si < total )); do
    local _psvc="${services[$_si]}"
    if remote_is_enabled "$_psvc"; then
      _remote_load_config "$_psvc"
      if [[ "$_REMOTE_CLOUD" != "true" && "$_REMOTE_AUTH_METHOD" == "password" ]]; then
        _needs_sshpass=true; break
      fi
    fi
    _si=$(( _si + 1 ))
  done
  if [[ "$_needs_sshpass" == "true" ]]; then
    _ensure_sshpass || return 1
  fi

  local _preauth_hosts=()
  _si=0
  while (( _si < total )); do
    local _psvc="${services[$_si]}"
    if remote_is_enabled "$_psvc"; then
      _remote_load_config "$_psvc"
      if [[ "$_REMOTE_CLOUD" != "true" && "$_REMOTE_AUTH_METHOD" == "password" ]]; then
        local _hk="${_REMOTE_USER}@${_REMOTE_HOST}:${_REMOTE_PORT}"
        local _found=false _phi=0
        while (( _phi < ${#_preauth_hosts[@]} )); do
          [[ "${_preauth_hosts[$_phi]}" == "$_hk" ]] && { _found=true; break; }
          _phi=$(( _phi + 1 ))
        done
        if [[ "$_found" == "false" ]]; then
          _remote_load_ssh_password "$_psvc"
          _preauth_hosts[${#_preauth_hosts[@]}]="$_hk"
        fi
      fi
    fi
    _si=$(( _si + 1 ))
  done

  # Set lock source for per-service locks
  if [[ -n "${MUSTER_DEPLOY_SOURCE:-}" ]]; then
    MUSTER_LOCK_SOURCE="fleet:${MUSTER_DEPLOY_SOURCE}"
  else
    MUSTER_LOCK_SOURCE="local"
  fi
  export MUSTER_LOCK_SOURCE

  for svc in ${services[@]+"${services[@]}"}; do
    _deploy_check_cancel
    (( current++ ))

    local name
    name=$(config_get ".services.${svc}.name")
    [[ -z "$name" || "$name" == "null" ]] && name="$svc"
    local _svc_t0 _svc_result="" _svc_health="-" _svc_log=""
    _svc_t0=$(date +%s)
    local hook="${project_dir}/.muster/hooks/${svc}/deploy.sh"
    local _hook_dir="${project_dir}/.muster/hooks/${svc}"
    local _use_just=false
    if _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "deploy"; then
      _use_just=true
    fi

    if [[ "$_use_just" == "false" && ! -x "$hook" ]]; then
      if [[ "$target" == "all" ]]; then
        warn "No deploy hook for ${name}, skipping"
        [[ "$dry_run" == "false" ]] && _deploy_record "$svc" "$name" "skipped" 0 "-" "" "false"
      else
        # Explicitly requested service with nothing to run is an error
        err "No deploy hook for ${name} (.muster/hooks/${svc}/deploy.sh)"
        [[ "$dry_run" == "false" ]] && _deploy_record "$svc" "$name" "failed" 0 "-" "" "true"
      fi
      [[ "$_json_mode" == "true" ]] && printf '{"event":"skipped","service":"%s","reason":"no_hook"}\n' "$svc"
      continue
    fi

    if [[ "$_json_mode" == "true" && "$dry_run" == "true" ]]; then
      # ── JSON dry-run ──
      local _hook_lines _hook_display="$hook"
      if [[ "$_use_just" == "true" ]]; then
        _hook_display="${_hook_dir}/justfile"
        _hook_lines=$(wc -l < "$_hook_display" | tr -d ' ')
      else
        _hook_lines=$(wc -l < "$hook" | tr -d ' ')
      fi
      printf '{"event":"dry_run","service":"%s","name":"%s","index":%d,"total":%d,"hook":"%s","hook_lines":%s}\n' \
        "$svc" "$name" "$current" "$total" "$_hook_display" "$_hook_lines"
      continue

    elif [[ "$_json_mode" == "true" ]]; then
      # ── JSON deploy mode — stream NDJSON events ──

      # Per-service lock
      if [[ "$_force" == "true" ]]; then
        _service_lock_release "$project_dir" "$svc"
      fi
      if ! _service_lock_acquire "$project_dir" "$svc" >&2; then
        printf '{"event":"skipped","service":"%s","reason":"locked"}\n' "$svc"
        _deploy_record "$svc" "$name" "skipped" 0 "-" "" "true"
        continue
      fi

      # Gather credentials
      local _cred_env_lines=""
      _cred_env_lines=$(cred_env_for_service "$svc")

      # Export k8s config
      local _k8s_env_lines=""
      _k8s_env_lines=$(k8s_env_for_service "$svc")
      if [[ -n "$_k8s_env_lines" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          export "$_ek=$_ev"
        done <<< "$_k8s_env_lines"
      fi

      export MUSTER_DEPLOY_STATUS=""
      export MUSTER_SERVICE_NAME="$name"

      local log_file
      log_file="${log_dir}/${svc}-deploy-$(date +%Y%m%d-%H%M%S).log"

      printf '{"event":"start","service":"%s","name":"%s","index":%d,"total":%d,"log_file":"%s"}\n' \
        "$svc" "$name" "$current" "$total" "$log_file"

      # Auto git pull (JSON mode)
      local _gp_enabled=""
      _gp_enabled=$(config_get ".services.${svc}.git_pull.enabled")
      if [[ "$_gp_enabled" == "true" ]]; then
        local _gp_remote _gp_branch
        _gp_remote=$(config_get ".services.${svc}.git_pull.remote")
        _gp_branch=$(config_get ".services.${svc}.git_pull.branch")
        [[ "$_gp_remote" == "null" || -z "$_gp_remote" ]] && _gp_remote="origin"
        [[ "$_gp_branch" == "null" || -z "$_gp_branch" ]] && _gp_branch="main"

        printf '{"event":"git_pull","service":"%s","remote":"%s","branch":"%s","status":"pulling"}\n' \
          "$svc" "$_gp_remote" "$_gp_branch"

        local _gp_rc=0
        if remote_is_enabled "$svc"; then
          _remote_load_config "$svc"
          _remote_build_opts
          local _gp_cmd="cd ${_REMOTE_PROJECT_DIR:-.} && git pull ${_gp_remote} ${_gp_branch}"
          # shellcheck disable=SC2086
          ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "$_gp_cmd" >/dev/null 2>&1 || _gp_rc=$?
        else
          git pull "$_gp_remote" "$_gp_branch" >/dev/null 2>&1 || _gp_rc=$?
        fi

        if (( _gp_rc != 0 )); then
          printf '{"event":"git_pull","service":"%s","status":"failed","exit_code":%d}\n' "$svc" "$_gp_rc"
        else
          printf '{"event":"git_pull","service":"%s","status":"done"}\n' "$svc"
        fi
      fi

      # Run the hook, tee to log file, and stream each line as NDJSON
      local _deploy_rc=0
      if [[ -n "$_cred_env_lines" ]]; then
        while IFS='=' read -r _ck _cv; do
          [[ -z "$_ck" ]] && continue
          export "$_ck=$_cv"
        done <<< "$_cred_env_lines"
      fi

      # Security gate (integrity re-check + dangerous command scan)
      local _jhook_check="$hook"
      [[ "$_use_just" == "true" ]] && _jhook_check="${_hook_dir}/justfile"
      if ! _hook_security_check "$_jhook_check" "$project_dir" >&2; then
        printf '{"event":"done","service":"%s","status":"blocked"}\n' "$svc"
        _history_log_event "$svc" "deploy" "failed" ""
        _deploy_record "$svc" "$name" "failed" "$(( $(date +%s) - _svc_t0 ))" "-" "" "true"
        _service_lock_release "$project_dir" "$svc"
        continue
      fi

      local _json_hook_timeout
      _json_hook_timeout=$(_deploy_timeout_for "$svc")
      local _json_deploy_start_time
      _json_deploy_start_time=$(date +%s)
      _MUSTER_CANCEL_SVC="$svc"
      {
        if remote_is_enabled "$svc"; then
          _remote_load_config "$svc"
          _remote_build_opts
          local _json_all_env="${_cred_env_lines}
${_k8s_env_lines}"
          if [[ "$_use_just" == "true" ]] && _just_remote_available; then
            _run_with_timeout "$_json_hook_timeout" _just_remote_run "$svc" "deploy" "$_json_all_env" 2>&1
          else
            _run_with_timeout "$_json_hook_timeout" remote_exec_stdout "$svc" "$hook" "$_json_all_env" 2>&1
          fi
        elif [[ "$_use_just" == "true" ]]; then
          _run_with_timeout "$_json_hook_timeout" just --justfile "${_hook_dir}/justfile" deploy 2>&1
        else
          _run_hook_with_timeout "$_json_hook_timeout" "$hook" 2>&1
        fi
      } | while IFS= read -r _jline; do
        printf '%s\n' "$_jline" >> "$log_file"
        # Escape backslashes and double quotes for JSON
        _jline=$(printf '%s' "$_jline" | sed 's/\\/\\\\/g;s/"/\\"/g' | tr -d '\r')
        printf '{"event":"log","service":"%s","line":"%s"}\n' "$svc" "$_jline"
      done
      _deploy_rc=${PIPESTATUS[0]}
      _deploy_check_cancel
      _MUSTER_CANCEL_SVC=""

      _svc_log="$log_file"
      if (( _deploy_rc == 0 )); then
        _svc_result="deployed"
        _svc_health="disabled"
        printf '{"event":"done","service":"%s","status":"success"}\n' "$svc"
        _deploy_verify "$log_file" "$svc" "$_json_deploy_start_time" "json"
        _history_log_event "$svc" "deploy" "ok" ""
        export MUSTER_DEPLOY_STATUS="success"
        run_skill_hooks "post-deploy" "$svc" 2>/dev/null

        # Health check
        local health_hook="${project_dir}/.muster/hooks/${svc}/health.sh"
        local health_enabled
        health_enabled=$(config_get ".services.${svc}.health.enabled")
        local _health_avail=false
        if [[ "$health_enabled" != "false" ]]; then
          if [[ -x "$health_hook" ]]; then
            _health_avail=true
          elif _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "health"; then
            _health_avail=true
          fi
        fi
        if [[ "$_health_avail" == "true" ]]; then
          printf '{"event":"health","service":"%s","status":"checking"}\n' "$svc"
          local _health_ok=false
          if remote_is_enabled "$svc"; then
            _remote_load_config "$svc"
            _remote_build_opts
            if _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "health" && _just_remote_available; then
              _just_remote_run "$svc" "health" "" &>/dev/null && _health_ok=true
            else
              remote_exec_stdout "$svc" "$health_hook" "" &>/dev/null && _health_ok=true
            fi
          elif _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "health"; then
            just --justfile "${_hook_dir}/justfile" health &>/dev/null && _health_ok=true
          else
            "$health_hook" &>/dev/null && _health_ok=true
          fi
          if [[ "$_health_ok" == "true" ]]; then
            _svc_health="healthy"
            printf '{"event":"health","service":"%s","status":"healthy"}\n' "$svc"
          else
            _svc_health="unhealthy"
            printf '{"event":"health","service":"%s","status":"unhealthy"}\n' "$svc"
          fi
        fi
      else
        _svc_result="failed"
        if (( _deploy_rc == 124 )); then
          printf '{"event":"done","service":"%s","status":"timeout","timeout":%d}\n' "$svc" "$_json_hook_timeout"
        else
          printf '{"event":"done","service":"%s","status":"failed","exit_code":%d}\n' "$svc" "$_deploy_rc"
        fi
        _history_log_event "$svc" "deploy" "failed" ""
        export MUSTER_DEPLOY_STATUS="failed"
        run_skill_hooks "post-deploy" "$svc" 2>/dev/null
      fi

      # Clean up env vars
      if [[ -n "$_cred_env_lines" ]]; then
        while IFS='=' read -r _ck _cv; do
          [[ -z "$_ck" ]] && continue
          unset "$_ck"
        done <<< "$_cred_env_lines"
      fi
      if [[ -n "$_k8s_env_lines" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          unset "$_ek"
        done <<< "$_k8s_env_lines"
      fi
      _service_lock_release "$project_dir" "$svc"
      local _jerr=false
      [[ "$_svc_result" != "deployed" || "$_svc_health" == "unhealthy" ]] && _jerr=true
      _deploy_record "$svc" "$name" "$_svc_result" "$(( $(date +%s) - _svc_t0 ))" "$_svc_health" "$_svc_log" "$_jerr"
      continue

    elif [[ "$dry_run" == "true" ]]; then
      # ── Dry-run: show plan without executing anything ──
      _deploy_progress "$current" "$total" "$name"
      echo ""
      printf '  %b[DRY-RUN]%b %bDeploying %s%b (%s/%s)\n' "${ACCENT}" "${RESET}" "${BOLD}" "$name" "${RESET}" "$current" "$total"
      local _dryrun_file="$hook"
      if [[ "$_use_just" == "true" ]]; then
        _dryrun_file="${_hook_dir}/justfile"
        printf '  %bHook:%b %s %b(justfile)%b\n' "${DIM}" "${RESET}" "$_dryrun_file" "${ACCENT}" "${RESET}"
      else
        printf '  %bHook:%b %s\n' "${DIM}" "${RESET}" "$hook"
      fi

      # Show first 10 lines of the hook script/justfile
      local _line_num=0
      local _separator=""
      printf -v _separator '%*s' 34 ''
      _separator="${_separator// /-}"
      printf '  %b%s%b\n' "${DIM}" "$_separator" "${RESET}"
      while IFS= read -r _line; do
        _line_num=$(( _line_num + 1 ))
        (( _line_num > 10 )) && break
        printf '  %b%s%b\n' "${DIM}" "$_line" "${RESET}"
      done < "$_dryrun_file"
      if (( _line_num > 10 )); then
        printf '  %b...%b\n' "${DIM}" "${RESET}"
      fi
      printf '  %b%s%b\n' "${DIM}" "$_separator" "${RESET}"

      # Show credential key names (without fetching values)
      local _cred_enabled
      _cred_enabled=$(config_get ".services.${svc}.credentials.enabled")
      if [[ "$_cred_enabled" == "true" ]]; then
        local _cred_keys=""
        _cred_keys=$(config_get ".services.${svc}.credentials.required[]" 2>/dev/null)
        if [[ -n "$_cred_keys" && "$_cred_keys" != "null" ]]; then
          local _cred_display=""
          while IFS= read -r _ck; do
            [[ -z "$_ck" ]] && continue
            local _upper_ck
            _upper_ck=$(printf '%s' "$_ck" | tr '[:lower:]' '[:upper:]')
            if [[ -n "$_cred_display" ]]; then
              _cred_display="${_cred_display}, MUSTER_CRED_${_upper_ck}"
            else
              _cred_display="MUSTER_CRED_${_upper_ck}"
            fi
          done <<< "$_cred_keys"
          printf '  %bCredentials:%b %s\n' "${DIM}" "${RESET}" "$_cred_display"
        fi
      fi

      # Show health check status
      local health_hook="${project_dir}/.muster/hooks/${svc}/health.sh"
      local health_enabled
      health_enabled=$(config_get ".services.${svc}.health.enabled")
      local _has_health_hook=false
      if [[ "$health_enabled" != "false" ]]; then
        if [[ -x "$health_hook" ]]; then
          _has_health_hook=true
        elif _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "health"; then
          _has_health_hook=true
        fi
      fi
      if [[ "$_has_health_hook" == "true" ]]; then
        printf '  %bHealth check:%b %b(enabled)%b\n' "${DIM}" "${RESET}" "${GREEN}" "${RESET}"
      else
        printf '  %bHealth check:%b %b(disabled)%b\n' "${DIM}" "${RESET}" "${RED}" "${RESET}"
      fi

      # Show remote status
      if remote_is_enabled "$svc"; then
        local _remote_pdir
        _remote_pdir=$(config_get ".services.${svc}.remote.project_dir")
        [[ "$_remote_pdir" == "null" ]] && _remote_pdir=""
        printf '  %bRemote:%b %s %b(enabled)%b\n' "${DIM}" "${RESET}" "$(remote_desc "$svc")" "${GREEN}" "${RESET}"
        if [[ -n "$_remote_pdir" ]]; then
          printf '  %bProject dir:%b %s\n' "${DIM}" "${RESET}" "$_remote_pdir"
        fi
      fi

      # Show git pull status
      local _gp_enabled
      _gp_enabled=$(config_get ".services.${svc}.git_pull.enabled")
      if [[ "$_gp_enabled" == "true" ]]; then
        local _gp_remote _gp_branch
        _gp_remote=$(config_get ".services.${svc}.git_pull.remote")
        _gp_branch=$(config_get ".services.${svc}.git_pull.branch")
        [[ "$_gp_remote" == "null" || -z "$_gp_remote" ]] && _gp_remote="origin"
        [[ "$_gp_branch" == "null" || -z "$_gp_branch" ]] && _gp_branch="main"
        printf '  %bGit pull:%b %s/%s %b(enabled)%b\n' "${DIM}" "${RESET}" "$_gp_remote" "$_gp_branch" "${GREEN}" "${RESET}"
      fi

      echo ""
    else
      # ── Normal deploy ──

      # Per-service lock
      if [[ "$_force" == "true" ]]; then
        _service_lock_release "$project_dir" "$svc"
      fi
      if ! _service_lock_acquire "$project_dir" "$svc"; then
        warn "Skipping ${name} — service is locked"
        _deploy_record "$svc" "$name" "skipped" 0 "-" "" "true"
        continue
      fi

      # Gather credentials if configured
      local _cred_env_lines=""
      _cred_env_lines=$(cred_env_for_service "$svc")

      # Export k8s config as env vars (hooks read these at runtime)
      local _k8s_env_lines=""
      _k8s_env_lines=$(k8s_env_for_service "$svc")
      if [[ -n "$_k8s_env_lines" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          export "$_ek=$_ev"
        done <<< "$_k8s_env_lines"
      fi

      export MUSTER_DEPLOY_STATUS=""
      export MUSTER_SERVICE_NAME="$name"

      # Load previous deploy SHA (before hook runs, which may git pull)
      local _git_in_repo="" _git_sha="" _git_prev_sha=""
      if _git_is_repo; then
        _git_in_repo="true"
        _git_prev_sha=$(_git_prev_deploy_sha "$svc")
        export MUSTER_GIT_PREV_COMMIT="$_git_prev_sha"
      fi

      run_skill_hooks "pre-deploy" "$svc"

      # Read git_pull config for this service
      local _gp_enabled=""
      _gp_enabled=$(config_get ".services.${svc}.git_pull.enabled")
      local _gp_remote="" _gp_branch=""
      if [[ "$_gp_enabled" == "true" ]]; then
        _gp_remote=$(config_get ".services.${svc}.git_pull.remote")
        _gp_branch=$(config_get ".services.${svc}.git_pull.branch")
        [[ "$_gp_remote" == "null" || -z "$_gp_remote" ]] && _gp_remote="origin"
        [[ "$_gp_branch" == "null" || -z "$_gp_branch" ]] && _gp_branch="main"
      fi

      _deploy_progress "$current" "$total" "Deploying ${name}..."

      # Preamble callback for stream_in_box to redraw context after viewer
      _deploy_redraw_preamble() {
        echo ""
        printf '  %b%bDeploying%b %b%s%b\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}" "${WHITE}" "$project" "${RESET}"
        echo ""
        _deploy_progress "$current" "$total" "Deploying ${name}..."
      }
      _SIB_REDRAW_FN="_deploy_redraw_preamble"

      while true; do
        local log_file
        log_file="${log_dir}/${svc}-deploy-$(date +%Y%m%d-%H%M%S).log"

        # Auto git pull before deploy hook
        if [[ "$_gp_enabled" == "true" ]]; then
          local _gp_output="" _gp_rc=0
          if remote_is_enabled "$svc"; then
            start_spinner "Pulling ${_gp_remote}/${_gp_branch} on $(remote_desc "$svc")"
            _remote_load_config "$svc"
            _remote_build_opts
            local _gp_cmd="cd ${_REMOTE_PROJECT_DIR:-.} && git pull ${_gp_remote} ${_gp_branch}"
            # shellcheck disable=SC2086
            _gp_output=$(ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "$_gp_cmd" 2>&1) || _gp_rc=$?
          else
            start_spinner "Pulling ${_gp_remote}/${_gp_branch}"
            _gp_output=$(git pull "$_gp_remote" "$_gp_branch" 2>&1) || _gp_rc=$?
          fi
          stop_spinner

          if (( _gp_rc != 0 )); then
            err "git pull failed for ${name}"
            printf '  %b%s%b\n' "${DIM}" "$_gp_output" "${RESET}"
            if [[ ! -t 0 ]]; then
              # Non-interactive: skip git pull, continue with deploy
              warn "Skipping git pull (non-interactive), deploying with current code"
            else
              echo ""
              menu_select "Git pull failed. What do you want to do?" "Retry" "Skip git pull" "Abort"
              case "$MENU_RESULT" in
                "Retry")
                  continue
                  ;;
                "Skip git pull")
                  warn "Skipping git pull, deploying with current code"
                  ;;
                "Abort")
                  _deploy_record "$svc" "$name" "failed" "$(( $(date +%s) - _svc_t0 ))" "-" "" "true"
                  _deploy_record_remaining "$current" "${services[@]}"
                  _deploy_summary false "$project_dir" "$(( $(date +%s) - _deploy_t0 ))"
                  _deploy_end
                  return 1
                  ;;
              esac
            fi
          else
            ok "Pulled ${_gp_remote}/${_gp_branch}"
          fi
        fi

        local _hook_timeout
        _hook_timeout=$(_deploy_timeout_for "$svc")
        local _deploy_start_time
        _deploy_start_time=$(date +%s)

        # Security gate: verify hook integrity + scan for dangerous commands
        local _hook_check_path="$hook"
        [[ "$_use_just" == "true" ]] && _hook_check_path="${_hook_dir}/justfile"
        if ! _hook_security_check "$_hook_check_path" "$project_dir"; then
          err "${name} not deployed — hook blocked by security check"
          _svc_result="failed"
          break
        fi
        _svc_log="$log_file"

        local rc=0
        _MUSTER_CANCEL_SVC="$svc"
        if remote_is_enabled "$svc"; then
          # ── Remote deploy via SSH ──
          info "Deploying ${name} remotely ($(remote_desc "$svc"))"
          local _all_env="${_cred_env_lines}"
          [[ -n "$_k8s_env_lines" ]] && _all_env="${_all_env}
${_k8s_env_lines}"
          _remote_load_config "$svc"
          _remote_build_opts
          if [[ "$_use_just" == "true" ]] && _just_remote_available; then
            _deploy_run_hook "$name" "$log_file" _run_with_timeout "$_hook_timeout" _just_remote_run "$svc" "deploy" "$_all_env"
          else
            _deploy_run_hook "$name" "$log_file" _run_with_timeout "$_hook_timeout" remote_exec_stdout "$svc" "$hook" "$_all_env"
          fi
        else
          # ── Local deploy ──
          if [[ -n "$_cred_env_lines" ]]; then
            while IFS='=' read -r _ck _cv; do
              [[ -z "$_ck" ]] && continue
              export "$_ck=$_cv"
            done <<< "$_cred_env_lines"
          fi

          if [[ "$_use_just" == "true" ]]; then
            _deploy_run_hook "$name" "$log_file" _run_with_timeout "$_hook_timeout" just --justfile "${_hook_dir}/justfile" deploy
          else
            _deploy_run_hook "$name" "$log_file" _run_hook_with_timeout "$_hook_timeout" "$hook"
          fi
        fi
        rc=$?
        unset _SIB_REDRAW_FN
        _deploy_check_cancel
        _MUSTER_CANCEL_SVC=""

        if (( rc == 0 )); then
          _deploy_progress "$current" "$total" "Deploying ${name}..." "done"
          ok "${name} deployed"
          _svc_result="deployed"
          _svc_health="disabled"
          _deploy_verify "$log_file" "$svc" "$_deploy_start_time"

          # Capture SHA after hook (hook may have done git pull)
          if [[ "$_git_in_repo" == "true" ]]; then
            _git_sha=$(_git_current_sha)
            export MUSTER_GIT_COMMIT="$_git_sha"
            if [[ -n "$_git_prev_sha" ]]; then
              echo ""
              _git_deploy_diff "$_git_prev_sha" "$_git_sha"
              # Export diff context for skills (notifications)
              MUSTER_GIT_COMMIT_COUNT="$(git rev-list --count "${_git_prev_sha}..${_git_sha}" 2>/dev/null || echo 0)"
              export MUSTER_GIT_COMMIT_COUNT
              MUSTER_GIT_DIFF_SUMMARY="$(git diff --shortstat "${_git_prev_sha}..${_git_sha}" 2>/dev/null || echo '')"
              export MUSTER_GIT_DIFF_SUMMARY
            else
              export MUSTER_GIT_COMMIT_COUNT=""
              export MUSTER_GIT_DIFF_SUMMARY=""
            fi
            _git_save_deploy_sha "$svc" "$_git_sha"
          fi

          _history_log_event "$svc" "deploy" "ok" "$_git_sha"
          export MUSTER_DEPLOY_STATUS="success"
          run_skill_hooks "post-deploy" "$svc"

          # Run health check
          local health_hook="${project_dir}/.muster/hooks/${svc}/health.sh"
          local health_enabled
          health_enabled=$(config_get ".services.${svc}.health.enabled")
          local _has_health=false
          if [[ "$health_enabled" != "false" ]]; then
            if [[ -x "$health_hook" ]]; then
              _has_health=true
            elif _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "health"; then
              _has_health=true
            fi
          fi
          if [[ "$_has_health" == "true" ]]; then
            start_spinner "Health check: ${name}"
            local _health_ok=false
            if remote_is_enabled "$svc"; then
              _remote_load_config "$svc"
              _remote_build_opts
              if _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "health" && _just_remote_available; then
                if _just_remote_run "$svc" "health" "" &>/dev/null; then
                  _health_ok=true
                fi
              elif remote_exec_stdout "$svc" "$health_hook" "" &>/dev/null; then
                _health_ok=true
              fi
            elif _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "health"; then
              if just --justfile "${_hook_dir}/justfile" health &>/dev/null; then
                _health_ok=true
              fi
            else
              if "$health_hook" &>/dev/null; then
                _health_ok=true
              fi
            fi
            if [[ "$_health_ok" == "true" ]]; then
              stop_spinner
              ok "${name} healthy"
              _svc_health="healthy"
            else
              stop_spinner
              err "${name} health check failed"
              _svc_health="unhealthy"
              if [[ ! -t 0 ]]; then
                # Non-interactive: log and continue
                warn "Continuing despite health check failure (non-interactive)"
              else
                echo ""
                menu_select "Health check failed. What do you want to do?" "Continue anyway" "Rollback ${name}" "Abort"
                case "$MENU_RESULT" in
                  "Rollback ${name}")
                    local rb_hook="${project_dir}/.muster/hooks/${svc}/rollback.sh"
                    local _has_rb=false
                    if [[ -x "$rb_hook" ]]; then
                      _has_rb=true
                    elif _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "rollback"; then
                      _has_rb=true
                    fi
                    if [[ "$_has_rb" == "true" ]]; then
                      if remote_is_enabled "$svc"; then
                        _remote_load_config "$svc"
                        _remote_build_opts
                        if _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "rollback" && _just_remote_available; then
                          _just_remote_run "$svc" "rollback" "$_cred_env_lines" 2>&1 | tee "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log"
                        else
                          remote_exec_stdout "$svc" "$rb_hook" "$_cred_env_lines" 2>&1 | tee "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log"
                        fi
                      elif _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "rollback"; then
                        just --justfile "${_hook_dir}/justfile" rollback 2>&1 | tee "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log"
                      else
                        "$rb_hook" 2>&1 | tee "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log"
                      fi
                      ok "${name} rolled back"
                      _history_log_event "$svc" "rollback" "ok"
                      _svc_result="rolled back"
                    else
                      err "No rollback hook for ${name}"
                    fi
                    ;;
                  "Abort")
                    err "Deploy aborted"
                    _service_lock_release "$project_dir" "$svc"
                    _deploy_record "$svc" "$name" "$_svc_result" "$(( $(date +%s) - _svc_t0 ))" "$_svc_health" "$_svc_log" "true"
                    _deploy_record_remaining "$current" "${services[@]}"
                    _deploy_summary false "$project_dir" "$(( $(date +%s) - _deploy_t0 ))"
                    _deploy_end
                    return 1
                    ;;
                esac
              fi
            fi
          fi

          # After-deploy: offer log viewer, then wait for keypress
          if [[ -f "$log_file" && -t 0 ]]; then
            echo ""
            printf '  %bCtrl+O view full log  •  any key to continue%b ' "${DIM}" "${RESET}"
            while true; do
              local _post_key=""
              IFS= read -rsn1 -t 30 _post_key 2>/dev/null || true
              if [[ -z "$_post_key" ]]; then
                # Timeout — auto-continue
                break
              elif [[ "$_post_key" == $'\x0f' ]]; then
                _log_viewer "$name deploy log" "$log_file"
                # Viewer cleared screen; reprint hint
                tput clear
                printf '  %bCtrl+O view full log  •  any key to continue%b ' "${DIM}" "${RESET}"
              else
                # Any other key — continue
                break
              fi
            done
            # Clear the hint line
            printf '\r'
            tput el 2>/dev/null || true
          fi

          break
        else
          if (( rc == 124 )); then
            err "${name} deploy timed out after ${_hook_timeout}s"
          else
            err "${name} deploy failed (exit code ${rc})"
          fi
          # Re-capture SHA after hook (may have done git pull before failing)
          if [[ "$_git_in_repo" == "true" ]]; then
            _git_sha=$(_git_current_sha)
            export MUSTER_GIT_COMMIT="$_git_sha"
          fi
          _history_log_event "$svc" "deploy" "failed" "$_git_sha"

          # Show last few lines of log for context
          echo ""
          if [[ -f "$log_file" ]]; then
            tail -5 "$log_file" | while IFS= read -r _line; do
              printf '  %b%s%b\n' "${DIM}" "$_line" "${RESET}"
            done
          fi
          echo ""

          k8s_diagnose_failure "$svc"

          # Notify skills immediately so team knows action is needed
          export MUSTER_DEPLOY_STATUS="failed"
          run_skill_hooks "post-deploy" "$svc"

          _svc_result="failed"
          if [[ ! -t 0 ]]; then
            # Non-interactive: stop here; remaining services are not attempted
            _service_lock_release "$project_dir" "$svc"
            _deploy_record "$svc" "$name" "failed" "$(( $(date +%s) - _svc_t0 ))" "-" "$_svc_log" "true"
            _deploy_record_remaining "$current" "${services[@]}"
            _deploy_summary false "$project_dir" "$(( $(date +%s) - _deploy_t0 ))"
            _deploy_end
            return 1
          fi

          # Build menu options (add "Rollback & restart" for k8s update deploys)
          local _fail_opts=()
          _fail_opts[0]="Retry"
          if [[ "${MUSTER_DEPLOY_MODE:-}" == "update" && -n "${MUSTER_K8S_DEPLOYMENT:-}" ]]; then
            _fail_opts[${#_fail_opts[@]}]="Rollback & restart"
          fi
          _fail_opts[${#_fail_opts[@]}]="Rollback ${name}"
          _fail_opts[${#_fail_opts[@]}]="Skip and continue"
          _fail_opts[${#_fail_opts[@]}]="Abort"

          menu_select "Deploy failed. What do you want to do?" "${_fail_opts[@]}"

          case "$MENU_RESULT" in
            "Retry")
              ;; # loop continues
            "Rollback & restart")
              local _rb_ns="${MUSTER_K8S_NAMESPACE:-default}"
              local _rb_dep="${MUSTER_K8S_DEPLOYMENT}"
              start_spinner "Rolling back & restarting ${name}..."
              _diag_run_kubectl "$svc" "kubectl rollout undo deployment/${_rb_dep} -n ${_rb_ns}" \
                >> "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log" 2>&1
              _diag_run_kubectl "$svc" "kubectl rollout restart deployment/${_rb_dep} -n ${_rb_ns}" \
                >> "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log" 2>&1
              stop_spinner
              ok "${name} rolled back & restarted"
              _history_log_event "$svc" "rollback" "ok"
              _svc_result="rolled back"
              break
              ;;
            "Rollback ${name}")
              local rb_hook="${project_dir}/.muster/hooks/${svc}/rollback.sh"
              local _has_rb=false
              if [[ -x "$rb_hook" ]]; then
                _has_rb=true
              elif _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "rollback"; then
                _has_rb=true
              fi
              if [[ "$_has_rb" == "true" ]]; then
                start_spinner "Rolling back ${name}..."
                if remote_is_enabled "$svc"; then
                  _remote_load_config "$svc"
                  _remote_build_opts
                  if _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "rollback" && _just_remote_available; then
                    _just_remote_run "$svc" "rollback" "$_cred_env_lines" >> "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log" 2>&1
                  else
                    remote_exec_stdout "$svc" "$rb_hook" "$_cred_env_lines" >> "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log" 2>&1
                  fi
                elif _just_available "$_hook_dir" && _just_has_recipe "$_hook_dir" "rollback"; then
                  just --justfile "${_hook_dir}/justfile" rollback >> "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log" 2>&1
                else
                  "$rb_hook" >> "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log" 2>&1
                fi
                stop_spinner
                ok "${name} rolled back"
                _history_log_event "$svc" "rollback" "ok"
                _svc_result="rolled back"
              else
                err "No rollback hook for ${name}"
              fi
              break
              ;;
            "Skip and continue")
              warn "Skipping ${name}, continuing with next service"
              export MUSTER_DEPLOY_STATUS="skipped"
              run_skill_hooks "post-deploy" "$svc"
              break
              ;;
            "Abort")
              _service_lock_release "$project_dir" "$svc"
              _deploy_record "$svc" "$name" "failed" "$(( $(date +%s) - _svc_t0 ))" "-" "$_svc_log" "true"
              _deploy_record_remaining "$current" "${services[@]}"
              _deploy_summary false "$project_dir" "$(( $(date +%s) - _deploy_t0 ))"
              _deploy_end
              return 1
              ;;
          esac
        fi
      done

      local _serr=false
      [[ "$_svc_result" != "deployed" || "$_svc_health" == "unhealthy" ]] && _serr=true
      _deploy_record "$svc" "$name" "${_svc_result:-failed}" "$(( $(date +%s) - _svc_t0 ))" "$_svc_health" "$_svc_log" "$_serr"

      # Clean up exported env vars (local deploy only)
      if ! remote_is_enabled "$svc"; then
        if [[ -n "$_cred_env_lines" ]]; then
          while IFS='=' read -r _ck _cv; do
            [[ -z "$_ck" ]] && continue
            unset "$_ck"
          done <<< "$_cred_env_lines"
        fi
      fi
      if [[ -n "$_k8s_env_lines" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          unset "$_ek"
        done <<< "$_k8s_env_lines"
      fi
      unset MUSTER_GIT_COMMIT MUSTER_GIT_PREV_COMMIT
      _service_lock_release "$project_dir" "$svc"

      echo ""
    fi
  done

  local _final_rc=0
  local _elapsed=$(( $(date +%s) - _deploy_t0 ))
  if [[ "$_json_mode" == "true" ]]; then
    printf '{"event":"complete","total":%d,"dry_run":%s}\n' "$total" "$dry_run"
    if [[ "$dry_run" == "false" ]]; then
      _deploy_summary true "$project_dir" "$_elapsed" || _final_rc=1
    fi
  elif [[ "$dry_run" == "true" ]]; then
    if [[ "${MUSTER_ANSI:-true}" != "false" ]]; then
      progress_bar "$total" "$total" "Complete"
      echo ""
      echo ""
    fi
    info "[DRY-RUN] Deploy plan complete — no changes made"
    echo ""
  else
    _deploy_summary false "$project_dir" "$_elapsed" || _final_rc=1
    echo ""
  fi

  _deploy_lock_release "$project_dir"
  trap - EXIT
  trap '_on_sigint' INT
  trap - TERM USR2
  _unload_env_file
  return $_final_rc
}

# Ctrl+C / SIGTERM during a deploy. Keep the handler tiny: under bash 3.2 a
# handler that runs foreground commands while a background job is being
# reaped can be abandoned halfway. So: flag it, kill the hook's process
# tree, and let the main flow finish the cancel at its next checkpoint
# (_deploy_check_cancel), which prints the message and exits 130.
_MUSTER_CANCELLED=""
_deploy_on_interrupt() {
  _MUSTER_CANCELLED=1
  trap '' INT TERM USR2
  if [[ -n "${_MUSTER_ACTIVE_PID:-}" ]]; then
    _kill_tree_hard "$_MUSTER_ACTIVE_PID"
  fi
}

_deploy_check_cancel() {
  [[ -z "${_MUSTER_CANCELLED:-}" ]] && return 0
  # Record the service whose hook was running when the cancel landed
  if [[ -n "${_MUSTER_CANCEL_SVC:-}" ]] && declare -f _history_log_event >/dev/null 2>&1; then
    _history_log_event "$_MUSTER_CANCEL_SVC" "deploy" "cancelled" "" 2>/dev/null || true
  fi
  local _c
  for _c in $(pgrep -P $$ 2>/dev/null); do
    _kill_tree_hard "$_c"
  done
  if [[ "${_json_mode:-false}" == "true" ]]; then
    printf '{"event":"cancelled","service":"%s","exit_code":130}\n' "${_MUSTER_CANCEL_SVC:-}"
  else
    printf '\n%b\n' "  ${YELLOW}!${RESET} Deploy cancelled"
  fi
  exit 130
}
