#!/usr/bin/env bash
# muster/lib/core/engine.sh — Helpers for the machine-readable (--json) API
#
# Everything a frontend (muster-tui, scripts, CI) reads goes through these:
# JSON string escaping, error documents, per-service stack detection and a
# way to run a generated command for a service locally or on its remote.
# The contract is documented in docs/ENGINE-API.md.

# ── JSON encoding ──

_JSON_CR=$'\r'

# Escape a string for use inside JSON double quotes (no surrounding quotes).
# Pure bash so it is cheap enough to run on every streamed log line:
# backslash, quote, \t \r \n and ESC are escaped; any other control
# character is dropped (they have no meaning in a log line).
_json_esc() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  s=${s//$'\033'/\\u001b}
  case "$s" in
    *[[:cntrl:]]*) s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\037\177') ;;
  esac
  printf '%s' "$s"
}

# Print a JSON string literal (with quotes)
_json_str() {
  printf '"%s"' "$(_json_esc "$1")"
}

# Print a JSON string literal, or null when empty / "null"
_json_str_or_null() {
  if [[ -z "$1" || "$1" == "null" ]]; then
    printf 'null'
  else
    _json_str "$1"
  fi
}

# Print an integer, or the fallback (default: null) when not an integer
_json_int() {
  if [[ "$1" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$1"
  else
    printf '%s' "${2:-null}"
  fi
}

# Print true/false from a shell value ("true" → true, anything else → false)
_json_bool() {
  if [[ "$1" == "true" ]]; then printf 'true'; else printf 'false'; fi
}

# Read lines on stdin and print them as a JSON array of strings
_json_lines_array() {
  local _l _first=true
  printf '['
  while IFS= read -r _l || [[ -n "$_l" ]]; do
    [[ "$_first" == "true" ]] && _first=false || printf ','
    _json_str "$_l"
  done
  printf ']'
}

# Print an error document to stderr: {"error":"<code>","message":"…"}
# Usage: _json_error code message
_json_error() {
  printf '{"error":%s,"message":%s}\n' "$(_json_str "$1")" "$(_json_str "$2")" >&2
}

# ── Per-service introspection ──

# Print the service's stack: k8s, compose, docker, dev or bare.
# k8s: a "k8s" config key or kubectl in the hooks. compose/docker: the
# deploy hook drives docker compose / docker. dev: PID-managed process.
# Usage: _engine_service_stack svc project_dir
_engine_service_stack() {
  local svc="$1" project_dir="$2"
  local hd="${project_dir}/.muster/hooks/${svc}"
  local files="" f
  for f in "${hd}/deploy.sh" "${hd}/justfile" "${hd}/logs.sh"; do
    [[ -f "$f" ]] && files="${files} ${f}"
  done
  local k8s_cfg
  k8s_cfg=$(config_get ".services.${svc}.k8s" 2>/dev/null)
  if [[ -n "$k8s_cfg" && "$k8s_cfg" != "null" ]]; then
    printf 'k8s'; return 0
  fi
  if [[ -z "$files" ]]; then
    printf 'bare'; return 0
  fi
  # shellcheck disable=SC2086
  if grep -q 'kubectl' $files 2>/dev/null; then
    printf 'k8s'
  elif grep -Eq '(^|[^-[:alnum:]_])docker[[:space:]]+compose([^-[:alnum:]_]|$)|docker-compose' $files 2>/dev/null; then
    printf 'compose'
  elif grep -Eq '(^|[^-[:alnum:]_])docker([^-[:alnum:]_]|$)' $files 2>/dev/null; then
    printf 'docker'
  elif grep -q '\.muster/pids' $files 2>/dev/null; then
    printf 'dev'
  else
    printf 'bare'
  fi
}

# Compose file a service's hooks use (COMPOSE_FILE default in the template),
# else the first compose file in the project root.
_engine_compose_file() {
  local svc="$1" project_dir="$2"
  local hd="${project_dir}/.muster/hooks/${svc}" f v
  for f in "${hd}/deploy.sh" "${hd}/logs.sh"; do
    [[ -f "$f" ]] || continue
    v=$(sed -n 's/^COMPOSE_FILE="\${COMPOSE_FILE:-\(.*\)}"[[:space:]]*$/\1/p' "$f" 2>/dev/null | head -1)
    if [[ -n "$v" ]]; then
      printf '%s' "$v"; return 0
    fi
  done
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "${project_dir}/${f}" ]]; then
      printf '%s' "$f"; return 0
    fi
  done
  printf 'docker-compose.yml'
}

# Compose service / container name the hooks act on (falls back to the key)
_engine_container_name() {
  local svc="$1" project_dir="$2"
  local hd="${project_dir}/.muster/hooks/${svc}" v=""
  if [[ -f "${hd}/logs.sh" ]]; then
    v=$(sed -n 's/.*docker compose .* logs -f \([[:alnum:]_.-]*\).*/\1/p; s/.*docker logs -f "\{0,1\}\([[:alnum:]_.-]*\)"\{0,1\}.*/\1/p' "${hd}/logs.sh" 2>/dev/null | head -1)
  fi
  if [[ -z "$v" && -f "${hd}/deploy.sh" ]]; then
    v=$(sed -n 's/.*docker compose .* up -d \([[:alnum:]_.-]*\).*/\1/p; s/^SERVICE="\([[:alnum:]_.-]*\)".*/\1/p' "${hd}/deploy.sh" 2>/dev/null | head -1)
  fi
  [[ -z "$v" ]] && v="$svc"
  printf '%s' "$v"
}

# k8s deployment / namespace for a service (config first, then defaults)
_engine_k8s_deployment() {
  local d
  d=$(config_get ".services.${1}.k8s.deployment" 2>/dev/null)
  [[ -z "$d" || "$d" == "null" ]] && d="$1"
  printf '%s' "$d"
}
_engine_k8s_namespace() {
  local n
  n=$(config_get ".services.${1}.k8s.namespace" 2>/dev/null)
  [[ -z "$n" || "$n" == "null" ]] && n="default"
  printf '%s' "$n"
}

# Run a generated shell script for a service: locally with bash, or on the
# service's remote host when remote deploy is enabled. stdout+stderr pass
# through. Usage: _engine_run_script svc script_file [env_lines]
_engine_run_script() {
  local svc="$1" script="$2" env_lines="${3:-}"
  if remote_is_enabled "$svc"; then
    _remote_load_config "$svc"
    _remote_build_opts
    remote_exec_stdout "$svc" "$script" "$env_lines"
  else
    (cd "$(dirname "$CONFIG_FILE")" && bash "$script")
  fi
}

# Latest history entry for a service+action as a compact JSON object, or
# "null". Usage: _engine_last_event svc action project_dir
_engine_last_event() {
  local svc="$1" action="$2" project_dir="$3"
  local log="${project_dir}/.muster/logs/deploy-events.log"
  if [[ ! -f "$log" ]]; then
    printf 'null'; return 0
  fi
  local line=""
  if has_cmd jq; then
    line=$(jq -c --arg s "$svc" --arg a "$action" \
      'select(.service == $s and .action == $a) | {ts, status, commit: (.commit // ""), source: (.source // "local")}' \
      "$log" 2>/dev/null | tail -1)
  else
    line=$(grep "\"service\":\"${svc}\",\"action\":\"${action}\"" "$log" 2>/dev/null | tail -1)
  fi
  if [[ -n "$line" ]]; then
    printf '%s' "$line"
  else
    printf 'null'
  fi
}

# ISO-8601 timestamp with zone for "now" (e.g. 2026-11-26T13:40:05-05:00)
_engine_now_iso() {
  local z
  z=$(date '+%z')
  printf '%s%s:%s' "$(date '+%Y-%m-%dT%H:%M:%S')" "${z:0:3}" "${z:3:2}"
}

# ── Running actions with NDJSON output ──

# Run a command with a timeout, append its output to a log file and stream
# each line as {"event":"log","service":…,"line":…}. Returns the command's
# exit code (124 on timeout).
# Usage: _engine_stream svc log_file timeout command [args...]
_engine_stream() {
  local svc="$1" log="$2" timeout="$3"
  shift 3
  local _l _svc_json
  _svc_json=$(_json_str "$svc")
  _run_with_timeout "$timeout" "$@" 2>&1 | while IFS= read -r _l || [[ -n "$_l" ]]; do
    printf '%s\n' "$_l" >> "$log"
    printf '{"event":"log","service":%s,"line":"%s"}\n' "$_svc_json" "$(_json_esc "${_l//$_JSON_CR/}")"
  done
  return "${PIPESTATUS[0]}"
}

# Run the service's health check (health.sh or justfile recipe, local or
# remote). Returns 0 healthy, 1 unhealthy, 2 no health check configured.
# Usage: _engine_health_check svc project_dir
_engine_health_check() {
  local svc="$1" project_dir="$2"
  local hd="${project_dir}/.muster/hooks/${svc}"
  local hook="${hd}/health.sh"
  local enabled
  enabled=$(config_get ".services.${svc}.health.enabled" 2>/dev/null)
  [[ "$enabled" == "false" ]] && return 2
  local use_just=false
  if _just_available "$hd" && _just_has_recipe "$hd" "health"; then
    use_just=true
  elif [[ ! -x "$hook" ]]; then
    return 2
  fi
  if remote_is_enabled "$svc"; then
    _remote_load_config "$svc"
    _remote_build_opts
    if [[ "$use_just" == "true" ]] && _just_remote_available; then
      _just_remote_run "$svc" "health" "" &>/dev/null && return 0
    else
      remote_exec_stdout "$svc" "$hook" "" &>/dev/null && return 0
    fi
  elif [[ "$use_just" == "true" ]]; then
    just --justfile "${hd}/justfile" health &>/dev/null && return 0
  else
    "$hook" &>/dev/null && return 0
  fi
  return 1
}

# Like _engine_health_check, but keeps retrying for a while: right after a
# restart or rollback the service is often still starting. Waits up to
# MUSTER_HEALTH_WAIT seconds (default 30), checking every 2 seconds.
# Usage: _engine_health_wait svc project_dir
_engine_health_wait() {
  local svc="$1" project_dir="$2" hrc=0
  local wait="${MUSTER_HEALTH_WAIT:-30}"
  [[ "$wait" =~ ^[0-9]+$ ]] || wait=30
  local deadline=$(( $(date +%s) + wait ))
  while true; do
    hrc=0
    _engine_health_check "$svc" "$project_dir" || hrc=$?
    (( hrc != 1 )) && return "$hrc"
    (( $(date +%s) >= deadline )) && return 1
    sleep 2
  done
}

# Emit health events after a successful action; echoes nothing else.
# Sets _ENGINE_HEALTH to healthy|unhealthy|disabled.
_ENGINE_HEALTH="disabled"
_engine_health_events() {
  local svc="$1" project_dir="$2" hrc=0
  _ENGINE_HEALTH="disabled"
  _engine_health_check "$svc" "$project_dir" || hrc=$?
  (( hrc == 2 )) && return 0
  printf '{"event":"health","service":%s,"status":"checking"}\n' "$(_json_str "$svc")"
  (( hrc == 1 )) && { hrc=0; _engine_health_wait "$svc" "$project_dir" || hrc=$?; }
  if (( hrc == 0 )); then
    _ENGINE_HEALTH="healthy"
  else
    _ENGINE_HEALTH="unhealthy"
  fi
  printf '{"event":"health","service":%s,"status":"%s"}\n' "$(_json_str "$svc")" "$_ENGINE_HEALTH"
}

# Print the "files" array for the hooks the last _hook_trust_pending found
_engine_pending_files_json() {
  local out="" i=0 e k
  while (( i < ${#_HOOK_PENDING[@]} )); do
    e="${_HOOK_PENDING[$i]}"; k="${e#*|}"; k="${k%%|*}"
    [[ -n "$out" ]] && out="${out},"
    out="${out}{\"key\":$(_json_str "$k"),\"state\":$(_json_str "${e%%|*}")}"
    i=$(( i + 1 ))
  done
  printf '[%s]' "$out"
}

# One-service summary event for rollback / restart.
# Usage: _engine_action_summary action svc name result duration health log_file
#   result: the past-tense outcome (e.g. "rolled back", "restarted") or failed
_engine_action_summary() {
  local action="$1" svc="$2" name="$3" result="$4" dur="$5" health="$6" log="$7"
  local rc=0 ok_n=1 fail_n=0
  if [[ "$result" == "failed" || "$result" == "skipped" || "$health" == "unhealthy" ]]; then
    rc=1
  fi
  if [[ "$result" == "failed" || "$result" == "skipped" ]]; then
    ok_n=0; fail_n=1
  fi
  local ok_key="succeeded"
  case "$action" in
    rollback) ok_key="rolled_back" ;;
    restart) ok_key="restarted" ;;
  esac
  printf '{"event":"summary","action":%s,"total":1,"%s":%d,"failed":%d,"duration":%d,"exit_code":%d,"services":[{"service":%s,"name":%s,"result":%s,"duration":%d,"health":%s,"log_file":%s}]}\n' \
    "$(_json_str "$action")" "$ok_key" "$ok_n" "$fail_n" "$(_json_int "$dur" 0)" "$rc" \
    "$(_json_str "$svc")" "$(_json_str "$name")" "$(_json_str "$result")" "$(_json_int "$dur" 0)" \
    "$(_json_str "$health")" "$(_json_str "$log")"
  return $rc
}
