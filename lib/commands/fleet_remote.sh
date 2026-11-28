#!/usr/bin/env bash
# muster/lib/commands/fleet_remote.sh — per-server fleet commands:
#   fleet test --json, fleet logs <server> <service>, fleet restart <server>
# Sourced by lib/commands/fleet.sh. JSON shapes: docs/ENGINE-API.md.

source "$MUSTER_ROOT/lib/core/engine.sh"

# True when <name> is a configured fleet server.
_fleet_machine_exists() {
  local name="$1" m
  [[ -z "$name" ]] && return 1
  while IFS= read -r m; do
    [[ "$m" == "$name" ]] && return 0
  done < <(fleet_machines 2>/dev/null)
  return 1
}

# Milliseconds since the epoch, as precisely as this system allows:
# $EPOCHREALTIME (bash 5) → GNU `date +%s%N` → perl Time::HiRes →
# whole seconds × 1000 (macOS bash 3.2 without perl).
_fleet_now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local _t="${EPOCHREALTIME/,/.}"
    local _s="${_t%.*}" _f="${_t#*.}000"
    printf '%s' "$(( _s * 1000 + 10#${_f:0:3} ))"
    return 0
  fi
  local _ns
  _ns=$(date +%s%N 2>/dev/null)
  if [[ "$_ns" =~ ^[0-9]+$ ]] && (( ${#_ns} > 12 )); then
    printf '%s' "$(( _ns / 1000000 ))"
    return 0
  fi
  if command -v perl >/dev/null 2>&1; then
    _ns=$(perl -MTime::HiRes=time -e 'printf "%d", time() * 1000' 2>/dev/null)
    if [[ "$_ns" =~ ^[0-9]+$ ]]; then
      printf '%s' "$_ns"
      return 0
    fi
  fi
  printf '%s' "$(( $(date +%s) * 1000 ))"
}

# ── fleet test ──

# Test one server. Sets:
#   _FT_TRANSPORT  ssh|cloud       _FT_MODE     muster|push
#   _FT_CONNECT    ok|fail         _FT_MUSTER   ok|fail|skip
#   _FT_LATENCY    ms (connectivity check only)
#   _FT_ERROR      short reason when not ok
#   _FT_OK         true|false
#   _FT_TAG        the human status tag (" cloud ok, muster ok" …)
#   _FT_LEVEL      ok|warn|fail (human colour)
# Returns 0 when the server passed.
_fleet_test_one() {
  local machine="$1"
  _FT_TRANSPORT="ssh" _FT_MODE="push" _FT_CONNECT="fail" _FT_MUSTER="skip"
  _FT_LATENCY=0 _FT_ERROR="" _FT_OK=false _FT_TAG="" _FT_LEVEL="fail"

  if ! _fleet_machine_exists "$machine" || ! _fleet_load_machine "$machine"; then
    _FT_ERROR="not in the fleet config"
    _FT_TAG=" unknown server"
    return 1
  fi
  _FT_TRANSPORT="${_FM_TRANSPORT:-ssh}"
  _FT_MODE="${_FM_MODE:-push}"

  local _label="SSH"
  if [[ "$_FT_TRANSPORT" == "cloud" ]]; then
    _label="cloud"
    source "$MUSTER_ROOT/lib/core/cloud.sh"
    if ! _fleet_cloud_available; then
      _FT_ERROR="muster-tunnel is not installed on this computer"
      _FT_TAG=" no tunnel"
      _FT_LEVEL="warn"
      return 1
    fi
  fi

  local _t0 _t1 _crc=0
  _t0=$(_fleet_now_ms)
  fleet_check "$machine" >/dev/null 2>&1 || _crc=$?
  _t1=$(_fleet_now_ms)
  _FT_LATENCY=$(( _t1 - _t0 ))
  (( _FT_LATENCY < 0 )) && _FT_LATENCY=0

  if (( _crc != 0 )); then
    if [[ "$_FT_TRANSPORT" == "cloud" ]]; then
      _FT_ERROR="cloud agent is not connected to the relay"
    else
      _FT_ERROR="SSH connection failed"
    fi
    _FT_TAG=" ${_label} fail"
    return 1
  fi
  _FT_CONNECT="ok"
  _FT_TAG=" ${_label} ok"

  if [[ "$_FT_MODE" != "muster" ]]; then
    _FT_OK=true
    _FT_LEVEL="ok"
    return 0
  fi

  _FT_MUSTER="fail"
  if [[ "$_FT_TRANSPORT" == "cloud" ]]; then
    # A real allowlisted command proves muster answers on the agent
    if _cloud_status_json "$(_fleet_cloud_agent "$machine")" "$_FM_PROJECT_DIR" >/dev/null 2>&1; then
      _FT_MUSTER="ok"
      _FT_TAG=" cloud ok, muster ok"
    else
      _FT_ERROR="muster did not answer on the agent"
      _FT_TAG=" cloud ok, muster fail"
      return 1
    fi
  else
    local _tok
    _tok=$(fleet_token_get "$machine" 2>/dev/null)
    if [[ -z "$_tok" ]]; then
      _FT_ERROR="unpaired: run muster fleet pair ${machine} --token <token>"
      _FT_TAG=" unpaired"
      _FT_LEVEL="warn"
      return 1
    elif fleet_verify_pair "$machine" >/dev/null 2>&1; then
      _FT_MUSTER="ok"
      _FT_TAG=" SSH ok, token ok"
    else
      _FT_ERROR="muster refused the token or did not answer"
      _FT_TAG=" SSH ok, token fail"
      return 1
    fi
  fi
  _FT_OK=true
  _FT_LEVEL="ok"
  return 0
}

# {"servers":[…],"passed":N,"failed":N}. Returns 1 if any server failed.
_fleet_test_json() {
  local out="" machine pass=0 fail=0
  for machine in "$@"; do
    [[ -z "$machine" ]] && continue
    if _fleet_test_one "$machine"; then
      pass=$(( pass + 1 ))
    else
      fail=$(( fail + 1 ))
    fi
    [[ -n "$out" ]] && out="${out},"
    out="${out}{\"name\":$(_json_str "$machine"),\"transport\":$(_json_str "$_FT_TRANSPORT"),\"mode\":$(_json_str "$_FT_MODE"),\"ok\":$(_json_bool "$_FT_OK"),\"connect\":$(_json_str "$_FT_CONNECT"),\"muster\":$(_json_str "$_FT_MUSTER"),\"latency_ms\":$(_json_int "$_FT_LATENCY" 0),\"error\":$(_json_str "$_FT_ERROR")}"
  done
  printf '{"servers":[%s],"passed":%s,"failed":%s}\n' "$out" "$pass" "$fail"
  (( fail == 0 ))
}

# ── shared: resolve a server for logs/restart ──

# Validate fleet config + server name; loads _FM_*. Prints errors in the
# right format for json_mode. Args: server json_mode
_fleet_remote_resolve() {
  local server="$1" json_mode="$2"
  # The local project (deploy order, push-mode hooks), when there is one
  if [[ -z "${CONFIG_FILE:-}" ]]; then
    CONFIG_FILE=$(find_config 2>/dev/null) || CONFIG_FILE=""
  fi
  if ! fleet_load_config; then
    if [[ "$json_mode" == "true" ]]; then
      _json_error "no_fleet" "No fleet configured. Run: muster fleet init"
    else
      err "No fleet configured. Run: muster fleet init"
    fi
    return 1
  fi
  if ! _fleet_machine_exists "$server" || ! _fleet_load_machine "$server"; then
    if [[ "$json_mode" == "true" ]]; then
      _json_error "unknown_server" "No server named '${server}' in the fleet (see: muster fleet list)"
    else
      err "No server named '${server}' in the fleet (see: muster fleet list)"
    fi
    return 1
  fi
  return 0
}

_FLEET_SVC_RE='^[A-Za-z0-9_.-]+$'

# Last non-empty line of a file, trimmed and shortened (an error summary).
_fleet_last_line() {
  local _l
  _l=$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1 | tr -d '\r')
  # Strip ANSI colour codes
  _l=$(printf '%s' "$_l" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')
  _l="${_l#"${_l%%[![:space:]]*}"}"
  (( ${#_l} > 200 )) && _l="${_l:0:197}..."
  printf '%s' "$_l"
}

# A bash script that runs a push-mode logs hook for at most 5s (like local
# `muster logs --tail`) and prints its last N lines. Args: hook tail out_file
_fleet_logs_wrapper() {
  local hook="$1" tail_n="$2" out="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'MUSTER_LOGS_TAIL=%s; export MUSTER_LOGS_TAIL\n' "$tail_n"
    printf '_mh=$(mktemp "${TMPDIR:-/tmp}/muster-logs-hook.XXXXXX") || exit 1\n'
    printf '_mo=$(mktemp "${TMPDIR:-/tmp}/muster-logs-out.XXXXXX") || exit 1\n'
    printf "cat > \"\$_mh\" <<'__MUSTER_FLEET_LOGS_HOOK__'\n"
    cat "$hook"
    printf '\n__MUSTER_FLEET_LOGS_HOOK__\n'
    # Own process group so a following hook (tail -f, kubectl logs -f) is
    # stopped with all its children
    printf 'set -m\n'
    printf 'bash "$_mh" > "$_mo" 2>&1 < /dev/null &\n'
    printf '_mp=$!\n_i=0\n_killed=0\n'
    printf 'while kill -0 "$_mp" 2>/dev/null && [ "$_i" -lt 5 ]; do sleep 1; _i=$((_i + 1)); done\n'
    printf 'if kill -0 "$_mp" 2>/dev/null; then _killed=1; kill -TERM -"$_mp" 2>/dev/null || kill "$_mp" 2>/dev/null; fi\n'
    printf 'wait "$_mp" 2>/dev/null; _rc=$?\n'
    printf '[ "$_killed" = 1 ] && _rc=0\n'
    printf 'tail -n %s "$_mo"\n' "$tail_n"
    printf 'rm -f "$_mh" "$_mo"\n'
    printf 'exit "$_rc"\n'
  } > "$out"
}

# Print captured remote output for --json: event lines to stdout, anything
# else to stderr (a remote {"error":…} document sets _FJP_ERROR_DOC).
# Returns 0 if at least one event line was printed.
_FJP_ERROR_DOC=false
_fleet_json_passthrough() {
  local file="$1" _l _n=0
  _FJP_ERROR_DOC=false
  while IFS= read -r _l || [[ -n "$_l" ]]; do
    _l="${_l%$'\r'}"
    case "$_l" in
      '{"event"'*) printf '%s\n' "$_l"; _n=$(( _n + 1 )) ;;
      '{"error"'*) printf '%s\n' "$_l" >&2; _FJP_ERROR_DOC=true ;;
      "") ;;
      *) printf '%s\n' "$_l" >&2 ;;
    esac
  done < "$file"
  (( _n > 0 ))
}

# ── fleet logs ──

_fleet_logs_help() {
  echo "Usage: muster fleet logs <server> <service> [--tail N] [--json]"
  echo ""
  echo "Print the last N log lines of a service on a fleet server (runs"
  echo "'muster logs <service> --tail N' there; push-mode servers run the"
  echo "service's logs hook for up to 5 seconds)."
  echo ""
  echo "Options:"
  echo "  --tail N, -n N  Lines to show (default 100, max 1000)"
  echo "  --json          NDJSON log events (same shape as muster logs --json)"
  echo ""
  echo "--follow is not supported for fleet servers."
}

_fleet_cmd_logs() {
  local server="" svc="" tail_n=100 json_mode=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail|-n) tail_n="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
      --tail=*) tail_n="${1#--tail=}"; shift ;;
      --json) json_mode=true; shift ;;
      --follow|-f)
        if [[ "$json_mode" == "true" ]]; then
          _json_error "usage" "--follow is not supported for fleet servers"
        else
          err "--follow is not supported for fleet servers"
        fi
        return 1
        ;;
      --help|-h) _fleet_logs_help; return 0 ;;
      -*)
        err "Unknown flag: $1"
        return 1
        ;;
      *)
        if [[ -z "$server" ]]; then server="$1"
        elif [[ -z "$svc" ]]; then svc="$1"
        else
          err "Too many arguments: $1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ "$json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
  fi

  local _usage_err=""
  if [[ -z "$server" || -z "$svc" ]]; then
    _usage_err="Usage: muster fleet logs <server> <service> [--tail N] [--json]"
  elif ! [[ "$svc" =~ $_FLEET_SVC_RE ]]; then
    _usage_err="Invalid service name: ${svc}"
  elif ! [[ "$tail_n" =~ ^[0-9]+$ ]] || (( 10#$tail_n < 1 )); then
    _usage_err="--tail needs a positive number of lines"
  fi
  if [[ -n "$_usage_err" ]]; then
    if [[ "$json_mode" == "true" ]]; then _json_error "usage" "$_usage_err"; else err "$_usage_err"; fi
    return 1
  fi
  tail_n=$(( 10#$tail_n ))
  (( tail_n > 1000 )) && tail_n=1000

  _fleet_remote_resolve "$server" "$json_mode" || return 1

  local _rargs=()
  _rargs=(logs "$svc" --tail "$tail_n")
  [[ "$json_mode" == "true" ]] && _rargs[${#_rargs[@]}]="--json"

  local tmp rc=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/muster-fleet-logs.XXXXXX") || return 1

  if [[ "$_FM_MODE" == "muster" && "$_FM_TRANSPORT" == "cloud" ]]; then
    # Read-only commands run on the agent without a MUSTER_TOKEN
    source "$MUSTER_ROOT/lib/core/cloud.sh"
    _cloud_muster "$(_fleet_cloud_agent "$server")" "$_FM_PROJECT_DIR" "${_rargs[@]}" > "$tmp" 2>&1 || rc=$?
    if (( rc != 0 )) && [[ "$json_mode" != "true" ]]; then
      cat "$tmp"
      _cloud_explain_failure "$server" "$tmp" >&2 || true
      rm -f "$tmp"
      return "$rc"
    fi
  elif [[ "$_FM_MODE" == "muster" ]]; then
    local _cmd="" _q _a
    if [[ "$json_mode" == "true" ]]; then
      local _tok
      _tok=$(fleet_token_get "$server" 2>/dev/null)
      if [[ -z "$_tok" ]]; then
        rm -f "$tmp"
        _json_error "unpaired" "${server} is not paired (run: muster fleet pair ${server} --token <token>)"
        return 1
      fi
      printf -v _q '%q' "$_tok"
      _cmd="MUSTER_TOKEN=${_q} "
    fi
    _cmd="${_cmd}muster"
    for _a in "${_rargs[@]}"; do
      printf -v _q '%q' "$_a"
      _cmd="${_cmd} ${_q}"
    done
    if [[ -n "$_FM_PROJECT_DIR" ]]; then
      printf -v _q '%q' "$_FM_PROJECT_DIR"
      _cmd="cd ${_q} && ${_cmd}"
    fi
    if [[ "$json_mode" != "true" ]]; then
      rm -f "$tmp"
      fleet_exec "$server" "$_cmd"
      return $?
    fi
    fleet_exec "$server" "$_cmd" > "$tmp" 2>&1 || rc=$?
  else
    # Push mode: no muster on the server; run its logs hook from this project
    local hook=".muster/hooks/${svc}/logs.sh"
    if [[ -n "${CONFIG_FILE:-}" ]]; then
      hook="$(dirname "$CONFIG_FILE")/${hook}"
    fi
    if [[ ! -f "$hook" ]]; then
      rm -f "$tmp"
      local _m="No logs hook for ${svc} in this project (${hook}); push-mode servers run the local hook remotely"
      if [[ "$json_mode" == "true" ]]; then _json_error "no_logs" "$_m"; else err "$_m"; fi
      return 1
    fi
    local wrapper
    wrapper=$(mktemp "${TMPDIR:-/tmp}/muster-fleet-logs-hook.XXXXXX") || { rm -f "$tmp"; return 1; }
    _fleet_logs_wrapper "$hook" "$tail_n" "$wrapper"
    fleet_push_hook "$server" "$wrapper" "" > "$tmp" 2>&1 || rc=$?
    rm -f "$wrapper"
    if [[ "$json_mode" == "true" ]]; then
      local _l
      while IFS= read -r _l || [[ -n "$_l" ]]; do
        _l="${_l%$'\r'}"
        printf '{"event":"log","service":%s,"source":"hook","line":%s}\n' "$(_json_str "$svc")" "$(_json_str "$_l")"
      done < "$tmp"
      printf '{"event":"end","service":%s,"source":"hook","exit_code":%s}\n' "$(_json_str "$svc")" "$rc"
      rm -f "$tmp"
      return "$rc"
    fi
  fi

  if [[ "$json_mode" == "true" ]]; then
    if ! _fleet_json_passthrough "$tmp" && (( rc != 0 )) && [[ "$_FJP_ERROR_DOC" != "true" ]]; then
      local _why=""
      if [[ "$_FM_TRANSPORT" == "cloud" ]]; then
        _why=$(_cloud_explain_failure "$server" "$tmp" 2>/dev/null | head -1)
      fi
      [[ -z "$_why" ]] && _why=$(_fleet_last_line "$tmp")
      [[ -z "$_why" ]] && _why="muster logs failed on ${server} (exit ${rc})"
      _json_error "remote_failed" "$_why"
    fi
  else
    cat "$tmp"
  fi
  rm -f "$tmp"
  return "$rc"
}

# ── fleet restart ──

_fleet_restart_help() {
  echo "Usage: muster fleet restart <server> [service...] [--yes] [--json]"
  echo ""
  echo "Restart services on a fleet server without redeploying (runs"
  echo "'muster restart <service>' there). With no service, restarts every"
  echo "service in this project's deploy order."
  echo ""
  echo "Options:"
  echo "  --yes, -y   Don't ask for confirmation (required without a TTY)"
  echo "  --json      Print {\"server\",\"results\":[{\"service\",\"ok\",\"error\"}]}"
  echo ""
  echo "Hooks must be approved on the server itself (muster hooks approve)."
}

# Restart one service on the loaded server. Output (remote) goes to $3.
# Args: server service out_file. Sets _FR_ERROR on failure.
_fleet_restart_one() {
  local server="$1" svc="$2" out="$3" rc=0
  _FR_ERROR=""
  _fleet_load_machine "$server"
  if [[ "$_FM_MODE" == "muster" && "$_FM_TRANSPORT" == "cloud" ]]; then
    source "$MUSTER_ROOT/lib/core/cloud.sh"
    _cloud_muster "$(_fleet_cloud_agent "$server")" "$_FM_PROJECT_DIR" restart "$svc" > "$out" 2>&1 || rc=$?
    if (( rc != 0 )); then
      _FR_ERROR=$(_cloud_explain_failure "$server" "$out" 2>/dev/null | head -1)
    fi
  elif [[ "$_FM_MODE" == "muster" ]]; then
    local _tok _q _cmd
    _tok=$(fleet_token_get "$server" 2>/dev/null)
    if [[ -z "$_tok" ]]; then
      _FR_ERROR="${server} is not paired (run: muster fleet pair ${server} --token <token>)"
      return 1
    fi
    printf -v _q '%q' "$_tok"
    _cmd="MUSTER_TOKEN=${_q}"
    printf -v _q '%q' "$svc"
    _cmd="${_cmd} muster restart ${_q}"
    if [[ -n "$_FM_PROJECT_DIR" ]]; then
      printf -v _q '%q' "$_FM_PROJECT_DIR"
      _cmd="cd ${_q} && ${_cmd}"
    fi
    fleet_exec "$server" "$_cmd" > "$out" 2>&1 || rc=$?
  else
    local hook=".muster/hooks/${svc}/restart.sh"
    if [[ -n "${CONFIG_FILE:-}" ]]; then
      hook="$(dirname "$CONFIG_FILE")/${hook}"
    fi
    if [[ ! -f "$hook" ]]; then
      _FR_ERROR="push mode needs a restart hook (${hook}); use muster mode or add one"
      return 1
    fi
    fleet_push_hook "$server" "$hook" "" > "$out" 2>&1 || rc=$?
  fi
  if (( rc != 0 )); then
    [[ -z "$_FR_ERROR" ]] && _FR_ERROR=$(_fleet_last_line "$out")
    [[ -z "$_FR_ERROR" ]] && _FR_ERROR="restart failed (exit ${rc})"
    return 1
  fi
  return 0
}

_fleet_cmd_restart() {
  local server="" json_mode=false yes=false
  local svcs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=true; shift ;;
      --json) json_mode=true; shift ;;
      --help|-h) _fleet_restart_help; return 0 ;;
      -*)
        err "Unknown flag: $1"
        return 1
        ;;
      *)
        if [[ -z "$server" ]]; then server="$1"; else svcs[${#svcs[@]}]="$1"; fi
        shift
        ;;
    esac
  done

  if [[ "$json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "deploy" || return 1
  fi

  local _usage_err="" _s
  if [[ -z "$server" ]]; then
    _usage_err="Usage: muster fleet restart <server> [service...] [--yes] [--json]"
  else
    for _s in ${svcs[@]+"${svcs[@]}"}; do
      if ! [[ "$_s" =~ $_FLEET_SVC_RE ]]; then
        _usage_err="Invalid service name: ${_s}"
        break
      fi
    done
  fi
  if [[ -n "$_usage_err" ]]; then
    if [[ "$json_mode" == "true" ]]; then _json_error "usage" "$_usage_err"; else err "$_usage_err"; fi
    return 1
  fi

  _fleet_remote_resolve "$server" "$json_mode" || return 1

  # No services named: this project's deploy order (fleet = one project on
  # many servers), same as fleet rollback
  if (( ${#svcs[@]} == 0 )); then
    if [[ -n "${CONFIG_FILE:-}" ]]; then
      _fleet_resolve_rollback_services
      for _s in ${_FLEET_RB_SVCS[@]+"${_FLEET_RB_SVCS[@]}"}; do
        svcs[${#svcs[@]}]="$_s"
      done
    fi
    if (( ${#svcs[@]} == 0 )); then
      local _m="Name a service to restart: muster fleet restart ${server} <service>"
      if [[ "$json_mode" == "true" ]]; then _json_error "usage" "$_m"; else err "$_m"; fi
      return 1
    fi
  fi

  local _list="" _desc
  for _s in "${svcs[@]}"; do
    [[ -n "$_list" ]] && _list="${_list}, "
    _list="${_list}${_s}"
  done
  _desc=$(fleet_desc "$server")

  if [[ "$yes" != "true" ]]; then
    if [[ -t 0 ]]; then
      local _ans=""
      printf '%b' "  Restart ${BOLD}${_list}${RESET} on ${BOLD}${server}${RESET} (${_desc})? [y/N] " >&2
      IFS= read -r _ans || _ans=""
      case "$_ans" in
        y|Y|yes|YES) ;;
        *)
          if [[ "$json_mode" == "true" ]]; then
            _json_error "cancelled" "Restart cancelled"
          else
            info "Cancelled" >&2
          fi
          return 1
          ;;
      esac
    else
      if [[ "$json_mode" == "true" ]]; then
        _json_error "confirmation_required" "Restarting services on ${server} needs --yes when there is no TTY"
      else
        err "Restarting services on ${server} needs --yes when there is no TTY"
      fi
      return 1
    fi
  fi

  local tmp results="" failed=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/muster-fleet-restart.XXXXXX") || return 1
  for _s in "${svcs[@]}"; do
    local _ok=true
    [[ "$json_mode" != "true" ]] && info "Restarting ${_s} on ${server}..."
    _fleet_restart_one "$server" "$_s" "$tmp" || _ok=false
    if [[ "$json_mode" == "true" ]]; then
      [[ -n "$results" ]] && results="${results},"
      results="${results}{\"service\":$(_json_str "$_s"),\"ok\":${_ok},\"error\":$(_json_str "$_FR_ERROR")}"
    else
      [[ -s "$tmp" ]] && sed 's/^/    /' "$tmp"
      if [[ "$_ok" == "true" ]]; then
        ok "${_s} restarted on ${server}"
      else
        err "${_s} failed on ${server}: ${_FR_ERROR}"
      fi
    fi
    [[ "$_ok" == "true" ]] || failed=$(( failed + 1 ))
    : > "$tmp"
  done
  rm -f "$tmp"

  if [[ "$json_mode" == "true" ]]; then
    printf '{"server":%s,"results":[%s]}\n' "$(_json_str "$server")" "$results"
  fi
  (( failed == 0 ))
}
