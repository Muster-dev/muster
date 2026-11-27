#!/usr/bin/env bash
# muster/lib/commands/ask.sh — Muster Assistant client (`muster ask`)
#
# Protocol: docs/assistant-and-pairing.md. The server runs the model and
# owns the conversation; this client streams the answer (SSE over curl),
# executes the tools the model asks for on this machine, and sends the
# (redacted) results back. Read tools run immediately; action tools need an
# explicit approval from the user every time.

source "$MUSTER_ROOT/lib/core/cloud.sh"
source "$MUSTER_ROOT/lib/core/credentials.sh"
source "$MUSTER_ROOT/lib/core/redact.sh"
source "$MUSTER_ROOT/lib/core/assistant.sh"

# Max characters of one tool result sent to the server (the tail is kept)
_ASK_MAX_RESULT=30000
# Max tool rounds for one user message (guards against a looping model)
_ASK_MAX_ROUNDS=25

_ASK_READ_TOOLS=" muster_status muster_logs muster_history muster_doctor muster_diagnose muster_hooks_status read_config read_hook "
_ASK_ACTION_TOOLS=" muster_deploy muster_rollback muster_restart propose_hook_edit "
_ASK_HOOKS=" deploy health rollback logs cleanup "

_ASK_JSON=false
_ASK_TTY=false
_ASK_ALLOW_ACTIONS=false
_ASK_READ_ONLY=false
_ASK_TMP=""
_ASK_PROJECT=""
_ASK_SESSION=""
_ASK_BASE=""

# ── Output helpers ──

# Print a JSON line on stdout (--json mode)
_ask_emit() {
  printf '%s\n' "$1"
}

# Human error (or a JSON error event in --json mode)
_ask_fail() {
  local code="$1" msg="$2" extra="${3:-}"
  if [[ "$_ASK_JSON" == "true" ]]; then
    _ask_emit "$(jq -cn --arg e "$code" --arg m "$msg" --argjson x "${extra:-null}" \
      '{type: "error", error: $e, message: $m} + ($x // {})')"
  else
    err "$msg"
  fi
}

_ask_cleanup() {
  [[ -n "$_ASK_TMP" && -d "$_ASK_TMP" ]] && rm -rf "$_ASK_TMP"
  _ASK_TMP=""
}

_ask_interrupt() {
  trap - INT TERM
  if [[ "$_ASK_JSON" == "true" ]]; then
    _ask_emit '{"type":"cancelled"}'
  else
    [[ "$MUSTER_ANSI" != "false" ]] && printf '%b' "$RESET"
    printf '\n'
    info "Cancelled."
  fi
  _ask_cleanup
  exit 130
}

_ask_help() {
  echo "Usage: muster ask [flags] [question]"
  echo ""
  echo "Ask the Muster Assistant about this project: why a deploy failed, what a"
  echo "log means, how to fix a hook. It can read status, logs, history and hooks"
  echo "on this machine, and propose actions (deploy, rollback, restart, hook"
  echo "edits) that only run after you approve them."
  echo ""
  echo "Requires a Fleet Cloud login (muster cloud login). Logs, config and hook"
  echo "contents are redacted on this machine before anything is sent."
  echo ""
  echo "Flags:"
  echo "  --yes, -y         Consent to sending redacted project data (non-interactive)"
  echo "  --allow-actions   Without a terminal, approve action tools automatically"
  echo "  --read-only       Decline every action tool (only read tools run)"
  echo "  --json            NDJSON events on stdout; approvals from stdin lines"
  echo "                    {\"approve\":\"<tool_use_id>\"} / {\"decline\":\"<id>\"},"
  echo "                    follow-ups as {\"message\":\"…\"}"
  echo "  -h, --help        Show this help"
  echo ""
  echo "Examples:"
  echo "  muster ask \"why did api fail?\""
  echo "  muster ask                      # interactive, uses the last failed deploy"
  echo ""
  echo "Turn it off on this machine: muster settings --global assistant off"
}

# ── Markdown-ish streaming renderer ──
# Text arrives in arbitrary fragments, so this is a small state machine:
# **bold**, `code`, ``` fences, "- " / "* " bullets and "# " headings.

_MD_BOL=1
_MD_LEAD=""
_MD_BOLD=0
_MD_CODE=0
_MD_STAR=0
_MD_HEAD=0
_MD_FENCE=0
_MD_SKIP=0
_MD_OUT=""

# Real escape bytes (the color variables hold printf %b sequences), so the
# rendered text can be printed with %s and backslashes in it stay literal.
_E_BOLD="" _E_RESET="" _E_ACCENT="" _E_DIM=""
_md_init_colors() {
  printf -v _E_BOLD '%b' "$BOLD"
  printf -v _E_RESET '%b' "$RESET"
  printf -v _E_ACCENT '%b' "$ACCENT"
  printf -v _E_DIM '%b' "$DIM"
}

_md_reset() {
  [[ -n "$_E_RESET$_E_BOLD" || -z "$RESET" ]] || _md_init_colors
  _MD_BOL=1 _MD_LEAD="" _MD_BOLD=0 _MD_CODE=0 _MD_STAR=0 _MD_HEAD=0 _MD_FENCE=0 _MD_SKIP=0 _MD_OUT=""
}

# Re-apply the active style after a RESET
_md_style() {
  if ((_MD_BOLD || _MD_HEAD)); then _MD_OUT="${_MD_OUT}${_E_BOLD}"; fi
}

_md_inline() {
  local c="$1"
  if ((_MD_SKIP)); then
    [[ "$c" == $'\n' ]] && { _MD_SKIP=0; _MD_BOL=1; _MD_LEAD=""; }
    return
  fi
  if ((_MD_FENCE)); then
    if [[ "$c" == $'\n' ]]; then
      _MD_OUT="${_MD_OUT}${_E_RESET}"$'\n'
      _MD_BOL=1
      _MD_LEAD=""
    else
      _MD_OUT="${_MD_OUT}${c}"
    fi
    return
  fi
  if [[ "$c" == '`' ]]; then
    if ((_MD_STAR)); then _MD_OUT="${_MD_OUT}*"; _MD_STAR=0; fi
    if ((_MD_CODE)); then
      _MD_CODE=0
      _MD_OUT="${_MD_OUT}${_E_RESET}"
      _md_style
    else
      _MD_CODE=1
      _MD_OUT="${_MD_OUT}${_E_ACCENT}"
    fi
    return
  fi
  if ((_MD_CODE)) && [[ "$c" != $'\n' ]]; then
    _MD_OUT="${_MD_OUT}${c}"
    return
  fi
  if [[ "$c" == '*' ]]; then
    if ((_MD_STAR)); then
      _MD_STAR=0
      if ((_MD_BOLD)); then
        _MD_BOLD=0
        _MD_OUT="${_MD_OUT}${_E_RESET}"
        _md_style
      else
        _MD_BOLD=1
        _MD_OUT="${_MD_OUT}${_E_BOLD}"
      fi
    else
      _MD_STAR=1
    fi
    return
  fi
  if ((_MD_STAR)); then _MD_OUT="${_MD_OUT}*"; _MD_STAR=0; fi
  if [[ "$c" == $'\n' ]]; then
    if ((_MD_HEAD || _MD_CODE || _MD_BOLD)); then
      _MD_HEAD=0 _MD_CODE=0 _MD_BOLD=0
      _MD_OUT="${_MD_OUT}${_E_RESET}"
    fi
    _MD_OUT="${_MD_OUT}"$'\n'
    _MD_BOL=1
    _MD_LEAD=""
    return
  fi
  _MD_OUT="${_MD_OUT}${c}"
}

# Line start resolved: emit margin, then replay buffered chars inline
_md_resolve_lead() {
  local lead="$1" i
  _MD_BOL=0
  _MD_LEAD=""
  ((_MD_FENCE)) || _MD_OUT="${_MD_OUT}  "
  for ((i = 0; i < ${#lead}; i++)); do
    _md_inline "${lead:i:1}"
  done
}

_md_char() {
  local c="$1"
  if ((!_MD_BOL)); then
    _md_inline "$c"
    return
  fi
  local lead="$_MD_LEAD"
  local trimmed="${lead#"${lead%%[! ]*}"}"
  # Fence lines (```lang) toggle code blocks and are not printed
  if [[ "$trimmed" == '```' ]]; then
    _MD_LEAD=""
    _MD_BOL=0
    if ((_MD_FENCE)); then _MD_FENCE=0; else _MD_FENCE=1; fi
    _MD_SKIP=1
    _md_inline "$c"
    return
  fi
  if ((_MD_FENCE)); then
    if [[ "$c" == '`' && ${#lead} -lt 3 && ( -z "$lead" || "$lead" == '`' || "$lead" == '``' ) ]]; then
      _MD_LEAD="${lead}${c}"
      return
    fi
    _MD_OUT="${_MD_OUT}  ${_E_DIM}"
    _md_resolve_lead "$lead"
    _md_inline "$c"
    return
  fi
  case "$c" in
    ' ')
      if [[ -z "$trimmed" && ${#lead} -lt 8 ]]; then
        _MD_LEAD="${lead}${c}"
        return
      fi
      case "$trimmed" in
        '-' | '*' | '+')
          local indent="${lead%"$trimmed"}"
          _MD_BOL=0
          _MD_LEAD=""
          if [[ "$MUSTER_ANSI" == "false" ]]; then
            _MD_OUT="${_MD_OUT}  ${indent}- "
          else
            _MD_OUT="${_MD_OUT}  ${indent}${_E_ACCENT}•${_E_RESET} "
          fi
          return
          ;;
        '#' | '##' | '###' | '####')
          _MD_BOL=0
          _MD_LEAD=""
          _MD_HEAD=1
          _MD_OUT="${_MD_OUT}  ${_E_BOLD}"
          return
          ;;
      esac
      ;;
    '-' | '*' | '+' | '#' | '`')
      if [[ ${#lead} -lt 12 ]]; then
        case "$trimmed" in
          '' | '#' | '##' | '###' | '`' | '``' | '*')
            _MD_LEAD="${lead}${c}"
            return
            ;;
        esac
      fi
      ;;
    $'\n')
      _md_resolve_lead "$lead"
      _md_inline "$c"
      return
      ;;
  esac
  _md_resolve_lead "$lead"
  _md_inline "$c"
}

_md_feed() {
  local s="$1" i
  _MD_OUT=""
  for ((i = 0; i < ${#s}; i++)); do
    _md_char "${s:i:1}"
  done
  printf '%s' "$_MD_OUT"
  _MD_OUT=""
}

# Finish the current line (end of a turn, or before a status line)
_md_break() {
  _MD_OUT=""
  if ((_MD_STAR)); then _MD_OUT="${_MD_OUT}*"; _MD_STAR=0; fi
  if [[ -n "$_MD_LEAD" ]]; then _md_resolve_lead "$_MD_LEAD"; fi
  if ((_MD_BOLD || _MD_CODE || _MD_HEAD || _MD_FENCE)); then
    _MD_OUT="${_MD_OUT}${_E_RESET}"
  fi
  _MD_BOLD=0 _MD_CODE=0 _MD_HEAD=0 _MD_SKIP=0
  ((_MD_BOL)) || _MD_OUT="${_MD_OUT}"$'\n'
  _MD_BOL=1
  _MD_LEAD=""
  printf '%s' "$_MD_OUT"
  _MD_OUT=""
}

# ── HTTP ──

# Write the auth header to a file so the token never appears in argv
_ask_auth_header() {
  local tok="$1"
  printf 'Authorization: Bearer %s\n' "$tok" > "$_ASK_TMP/auth"
  chmod 600 "$_ASK_TMP/auth"
}

_ASK_HTTP_STATUS=""
_ASK_HTTP_BODY=""
# POST JSON (non-streaming). Body is read from a file.
_ask_post() {
  local url="$1" body_file="$2" out
  if ! out=$(curl -sS --max-time 30 -w '\n%{http_code}' \
    -H @"$_ASK_TMP/auth" \
    -H 'Content-Type: application/json' \
    -H "User-Agent: muster/${MUSTER_VERSION:-dev}" \
    -X POST --data-binary @"$body_file" "$url" 2>"$_ASK_TMP/curl_err"); then
    _ASK_HTTP_STATUS="000"
    _ASK_HTTP_BODY=""
    return 1
  fi
  _ASK_HTTP_STATUS="${out##*$'\n'}"
  _ASK_HTTP_BODY="${out%$'\n'*}"
}

# Explain a non-2xx response. Returns 1.
_ask_http_error() {
  local status="$1" body="$2" what="$3"
  local code msg upgrade
  code=$(printf '%s' "$body" | jq -r '.error // empty' 2>/dev/null)
  msg=$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null)
  case "$status" in
    000)
      local cerr=""
      [[ -f "$_ASK_TMP/curl_err" ]] && cerr=$(head -1 "$_ASK_TMP/curl_err" | sed 's/^curl: ([0-9]*) //')
      _ask_fail "network_error" "Can't reach the Muster Assistant at ${_ASK_BASE}${cerr:+ (${cerr})}"
      [[ "$_ASK_JSON" != "true" ]] && printf '  %bCheck your connection and try again.%b\n' "$DIM" "$RESET"
      ;;
    401 | 403)
      _ask_fail "unauthorized" "Fleet Cloud rejected your login (HTTP ${status})."
      [[ "$_ASK_JSON" != "true" ]] && printf '  %bSign in again with: muster cloud login%b\n' "$DIM" "$RESET"
      ;;
    402)
      upgrade=$(printf '%s' "$body" | jq -r '.upgrade_url // empty' 2>/dev/null)
      [[ -z "$upgrade" ]] && upgrade="${_ASK_BASE}/billing"
      _ask_fail "payment_required" "Your Muster Assistant sessions are used up for this plan." \
        "$(jq -cn --arg u "$upgrade" '{upgrade_url: $u}')"
      [[ "$_ASK_JSON" != "true" ]] && printf '  Upgrade to keep going: %b%s%b\n' "$WHITE" "$upgrade" "$RESET"
      ;;
    429)
      _ask_fail "rate_limited" "The Muster Assistant is busy (rate limited). Try again in a minute."
      ;;
    *)
      [[ -z "$msg" ]] && msg="$code"
      _ask_fail "${code:-http_${status}}" "${what} failed (HTTP ${status}${msg:+: ${msg}})"
      ;;
  esac
  return 1
}

# Raw SSE lines → one record per line:
#   E<TAB>type<TAB>delta (escaped for printf %b)<TAB>compact event JSON
#   R<TAB>line            (anything that isn't an SSE data line: error bodies)
# Control characters are stripped from deltas so the server can't drive
# the terminal.
# shellcheck disable=SC2016
_ASK_SSE_JQ='
rtrimstr("\r") as $l
| if ($l | startswith("data:")) then
    ($l | ltrimstr("data:") | ltrimstr(" ")) as $d
    | ($d | try fromjson catch null) as $e
    | if ($e | type) != "object" then "R\t" + $d
      else "E\t"
        + (($e.type // "") | tostring | gsub("[^A-Za-z0-9_]"; ""))
        + "\t"
        + (($e.delta // "") | tostring
           | explode | map(select(. == 9 or . == 10 or (. >= 32 and . != 127))) | implode
           | gsub("\\\\"; "\\\\") | gsub("\n"; "\\n") | gsub("\t"; "\\t"))
        + "\t" + ($e | tojson)
      end
  elif ($l == "" or ($l | test("^(:|event:|id:|retry:)"))) then empty
  else "R\t" + $l
  end
'

_ASK_STOP=""
_ASK_STREAM_ERR=""
_ASK_STREAM_STATUS=""
_ASK_RAW=""
_TR_N=0
_TR_EV=()

# POST a turn and consume its event stream. Sets _ASK_STOP (stop_reason),
# _TR_EV/_TR_N (tool requests) and _ASK_STREAM_ERR. Returns 1 on HTTP or
# transport errors (already reported).
_ask_stream_turn() {
  local body_file="$1"
  local url="${_ASK_BASE}/api/assist/sessions/${_ASK_SESSION}/turns"
  local hdr="$_ASK_TMP/headers"
  : > "$hdr"
  : > "$_ASK_TMP/curl_err"
  _ASK_STOP=""
  _ASK_STREAM_ERR=""
  _ASK_RAW=""
  _TR_N=0
  _TR_EV=()

  local rec rest type delta ev
  while IFS= read -r rec; do
    case "$rec" in
      R$'\t'*)
        _ASK_RAW="${_ASK_RAW}${rec#R$'\t'}"$'\n'
        continue
        ;;
      E$'\t'*) ;;
      *) continue ;;
    esac
    rest="${rec#E$'\t'}"
    type="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    delta="${rest%%$'\t'*}"
    ev="${rest#*$'\t'}"

    [[ "$_ASK_JSON" == "true" ]] && _ask_emit "$ev"

    case "$type" in
      text)
        if [[ "$_ASK_JSON" != "true" ]]; then
          printf -v delta '%b' "$delta"
          _md_feed "$delta"
        fi
        ;;
      thinking_summary)
        if [[ "$_ASK_JSON" != "true" && -n "$delta" ]]; then
          _md_break
          printf '  %b%b%b\n' "$DIM" "$delta" "$RESET"
        fi
        ;;
      tool_request)
        _TR_EV[_TR_N]="$ev"
        _TR_N=$((_TR_N + 1))
        ;;
      turn_end)
        _ASK_STOP=$(printf '%s' "$ev" | jq -r '.stop_reason // "end_turn"')
        ;;
      error)
        _ASK_STREAM_ERR=$(printf '%s' "$ev" | jq -r '.error // .message // "unknown error"')
        ;;
    esac
  done < <(curl -sS -N --no-buffer --max-time "${MUSTER_ASK_TIMEOUT:-600}" -D "$hdr" \
    -H @"$_ASK_TMP/auth" \
    -H 'Content-Type: application/json' \
    -H 'Accept: text/event-stream' \
    -H "User-Agent: muster/${MUSTER_VERSION:-dev}" \
    -X POST --data-binary @"$body_file" "$url" 2>"$_ASK_TMP/curl_err" |
    jq --unbuffered -Rr "$_ASK_SSE_JQ" 2>/dev/null)

  [[ "$_ASK_JSON" == "true" ]] || _md_break

  _ASK_STREAM_STATUS=$(tr -d '\r' < "$hdr" | awk '/^HTTP\//{s=$2} END{print s}')
  [[ -z "$_ASK_STREAM_STATUS" ]] && _ASK_STREAM_STATUS="000"
  # Return 2 = transient: nothing was saved, resend the same body.
  # The server persists a turn only when it completes, so a resend is safe.
  local code
  case "$_ASK_STREAM_STATUS" in
    2??) ;;
    409)
      code=$(printf '%s' "$_ASK_RAW" | jq -r '.error // empty' 2>/dev/null)
      if [[ "$code" == "turn_in_progress" ]]; then
        return 2
      fi
      _ask_http_error "$_ASK_STREAM_STATUS" "$_ASK_RAW" "The assistant request"
      return 1
      ;;
    000|429|502|503|504) return 2 ;;
    *)
      _ask_http_error "$_ASK_STREAM_STATUS" "$_ASK_RAW" "The assistant request"
      return 1
      ;;
  esac
  if [[ -n "$_ASK_STREAM_ERR" ]]; then
    # An error followed by turn_end: the server saved the turn (e.g. it
    # gave up on an invalid tool call). Say so and keep the chat going.
    if [[ -n "$_ASK_STOP" ]]; then
      [[ "$_ASK_JSON" == "true" ]] || printf '  %b%s%b\n' "$DIM" "$_ASK_STREAM_ERR" "$RESET"
      return 0
    fi
    case "$_ASK_STREAM_ERR" in
      *"interrupted before it finished"*|*"handling a lot of requests"*|*"temporarily unavailable. Try again shortly"*)
        return 2
        ;;
    esac
    _ask_fail "assistant_error" "The assistant hit an error: ${_ASK_STREAM_ERR}"
    return 1
  fi
  if [[ -z "$_ASK_STOP" && "$_TR_N" -eq 0 ]]; then
    return 2
  fi
  return 0
}

# Runs a turn, resending it after transient failures (dropped connection,
# rate limit, overloaded server, a turn still finishing).
_ask_turn() {
  local body_file="$1" attempt=0 rc
  while true; do
    _ask_stream_turn "$body_file"
    rc=$?
    ((rc == 2)) || return "$rc"
    attempt=$((attempt + 1))
    if ((attempt > 2)); then
      if [[ -n "$_ASK_STREAM_ERR" ]]; then
        _ask_fail "assistant_error" "The assistant hit an error: ${_ASK_STREAM_ERR}"
      else
        _ask_fail "stream_interrupted" "The connection dropped before the answer finished. Run muster ask again to retry."
      fi
      return 1
    fi
    if [[ "$_ASK_JSON" == "true" ]]; then
      _ask_emit "$(jq -cn --argjson n "$attempt" '{type: "retrying", attempt: $n}')"
    else
      printf '  %b(Connection hiccup, retrying…)%b\n' "$DIM" "$RESET"
    fi
    sleep $((attempt * 3))
    _md_reset
  done
}

# ── Local muster invocation (tool backends) ──

# A local API token for `muster … --json` (they require MUSTER_TOKEN).
# Created once as "muster-assistant" (deploy scope), stored 0600.
_ask_local_token() {
  if [[ -n "${MUSTER_TOKEN:-}" ]]; then
    printf '%s' "$MUSTER_TOKEN"
    return 0
  fi
  source "$MUSTER_ROOT/lib/core/auth.sh"
  local dir="$HOME/.muster/assistant" f tok hash
  f="$dir/local-token"
  if [[ -f "$f" ]]; then
    tok=$(cat "$f")
    hash=$(_auth_hash "$tok")
    if [[ -n "$tok" && -f "$MUSTER_TOKENS_FILE" ]] &&
      jq -e --arg h "sha256:${hash}" '.tokens[] | select(.token_hash == $h)' "$MUSTER_TOKENS_FILE" >/dev/null 2>&1; then
      printf '%s' "$tok"
      return 0
    fi
  fi
  _auth_ensure_file
  _auth_update_tokens --arg n "muster-assistant" 'del(.tokens[] | select(.name == $n))' >/dev/null 2>&1 || true
  tok=$(_auth_create_token_internal "muster-assistant" "deploy" 2>/dev/null) || return 1
  [[ -n "$tok" ]] || return 1
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  (umask 077 && printf '%s' "$tok" > "$f")
  printf '%s' "$tok"
}

_ASK_LOCAL_TOKEN=""

# Run muster non-interactively in the project. Output (stdout+stderr) on
# stdout; returns muster's exit code.
_ask_muster() {
  local timeout="$1"
  shift
  if [[ -z "$_ASK_LOCAL_TOKEN" ]]; then
    _ASK_LOCAL_TOKEN=$(_ask_local_token 2>/dev/null) || _ASK_LOCAL_TOKEN=""
  fi
  (
    cd "$_ASK_PROJECT" || exit 1
    export NO_COLOR=1 MUSTER_MINIMAL=true MUSTER_NO_VERIFY=true MUSTER_DEPLOY_SOURCE="assistant"
    [[ -n "$_ASK_LOCAL_TOKEN" ]] && export MUSTER_TOKEN="$_ASK_LOCAL_TOKEN"
    unset MUSTER_ASK_FAILURE_SERVICE MUSTER_ASK_FAILURE_EXIT MUSTER_ASK_FAILURE_LOG
    if declare -f _run_with_timeout >/dev/null 2>&1; then
      _run_with_timeout "$timeout" "$MUSTER_ROOT/bin/muster" "$@" </dev/null 2>&1
    else
      "$MUSTER_ROOT/bin/muster" "$@" </dev/null 2>&1
    fi
  )
}

# Feature detection against the installed command files, so this works
# both before and after the engine JSON API (feat/engine-api) is merged.
_ask_supports() {
  case "$1" in
    logs_tail) grep -q -- '--tail' "$MUSTER_ROOT/lib/commands/logs.sh" 2>/dev/null ;;
    hooks_status) grep -qE '^[[:space:]]*status\)' "$MUSTER_ROOT/lib/commands/hooks.sh" 2>/dev/null ;;
    rollback_json) grep -q -- '--json' "$MUSTER_ROOT/lib/commands/rollback.sh" 2>/dev/null ;;
    restart) [[ -f "$MUSTER_ROOT/lib/commands/restart.sh" ]] ;;
    *) return 1 ;;
  esac
}

_ask_latest_log() {
  local svc="$1" kind="${2:-}"
  # shellcheck disable=SC2012
  ls -t "${_ASK_PROJECT}/.muster/logs/${svc}-${kind}"*.log 2>/dev/null | head -1
}

# ── Tool executors: each prints the result text, returns non-zero on error ──

_ask_tool_logs() {
  local svc="$1" lines="$2"
  local latest out rc=0
  if _ask_supports logs_tail; then
    out=$(_ask_muster 30 logs "$svc" --tail "$lines") || rc=$?
    if ((rc == 0)) && [[ -n "$out" ]]; then
      printf '%s\n' "$out"
      return 0
    fi
    # The live log source failed: add the newest deploy log, if any
    latest=$(_ask_latest_log "$svc")
    printf '%s\n' "$out"
    [[ -n "$latest" ]] || return 1
    printf '# muster logs exited %s; latest deploy log: %s\n' "$rc" "${latest#"${_ASK_PROJECT}"/}"
    tail -n "$lines" "$latest"
    return 0
  fi
  # FALLBACK (pre engine-api): no `muster logs --tail`; logs hooks stream
  # forever, so show the newest deploy log for the service instead.
  latest=$(_ask_latest_log "$svc")
  if [[ -z "$latest" ]]; then
    printf 'No logs found for %s (no deploy logs in .muster/logs).\n' "$svc"
    return 1
  fi
  printf '# Latest log file: %s\n' "${latest#"${_ASK_PROJECT}"/}"
  tail -n "$lines" "$latest"
}

_ask_tool_history() {
  local svc="$1" limit="$2" out rc
  if [[ -n "$svc" ]]; then
    out=$(_ask_muster 30 history --json "$svc") && rc=0 || rc=$?
  else
    out=$(_ask_muster 30 history --json) && rc=0 || rc=$?
  fi
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$out" | jq -c --argjson n "$limit" 'if type == "array" then .[-$n:] else . end'
  else
    printf '%s\n' "$out"
  fi
  return "$rc"
}

_ask_tool_diagnose() {
  local svc="$1" ev latest diag=""
  ev=$(grep -F "\"service\":\"${svc}\"" "${_ASK_PROJECT}/.muster/logs/deploy-events.log" 2>/dev/null |
    grep -F '"status":"failed"' | tail -1)
  latest=$(_ask_latest_log "$svc" "deploy")
  if grep -q '"k8s"' "${_ASK_PROJECT}/muster.json" 2>/dev/null ||
    grep -qs kubectl "${_ASK_PROJECT}/.muster/hooks/${svc}/deploy.sh"; then
    diag=$(
      cd "$_ASK_PROJECT" || exit 0
      export NO_COLOR=1
      source "$MUSTER_ROOT/lib/core/k8s_diag.sh" 2>/dev/null || exit 0
      declare -f k8s_diagnose_failure >/dev/null 2>&1 || exit 0
      if declare -f _run_with_timeout >/dev/null 2>&1; then
        _run_with_timeout 45 k8s_diagnose_failure "$svc" 2>&1
      else
        k8s_diagnose_failure "$svc" 2>&1
      fi
    ) </dev/null
    diag=$(printf '%s' "$diag" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')
  fi
  local tail_text=""
  [[ -n "$latest" ]] && tail_text=$(tail -n 80 "$latest")
  jq -n --arg svc "$svc" --arg ev "$ev" --arg log "${latest#"${_ASK_PROJECT}"/}" \
    --arg tail "$tail_text" --arg diag "$diag" '{
      service: $svc,
      last_failure: (if $ev == "" then null else ($ev | try fromjson catch $ev) end),
      log_file: (if $log == "" then null else $log end),
      log_tail: ($tail | split("\n")),
      k8s_diagnosis: (if $diag == "" then null else $diag end)
    }'
}

_ask_tool_hooks_status() {
  if _ask_supports hooks_status; then
    _ask_muster 30 hooks status --json
    return $?
  fi
  # FALLBACK (pre engine-api): no `muster hooks status --json`; report the
  # human-readable integrity check instead.
  _ask_muster 30 hooks verify
}

_ask_tool_read_config() {
  jq '
    del(.credentials)
    | if (.services | type) == "object" then .services |= map_values(del(.credentials)) else . end
    | (.. | objects | select(has("env")) | .env) |= (if type == "object" then map_values("‹redacted›") else "‹redacted›" end)
  ' "${_ASK_PROJECT}/muster.json"
}

_ask_tool_read_hook() {
  local svc="$1" hook="$2" f
  f="${_ASK_PROJECT}/.muster/hooks/${svc}/${hook}.sh"
  if [[ ! -f "$f" ]]; then
    printf 'No %s hook for %s (.muster/hooks/%s/%s.sh does not exist).\n' "$hook" "$svc" "$svc" "$hook"
    return 1
  fi
  cat "$f"
}

_ask_tool_rollback() {
  local svc="$1"
  if _ask_supports rollback_json; then
    _ask_muster 900 rollback "$svc" --json
  else
    _ask_muster 900 rollback "$svc"
  fi
}

_ask_tool_restart() {
  local svc="$1"
  if _ask_supports restart; then
    _ask_muster 600 restart "$svc"
    return $?
  fi
  # FALLBACK (pre engine-api): `muster restart` doesn't exist yet.
  printf 'muster restart is not available in this version of muster. Suggest muster_rollback or muster_deploy instead.\n'
  return 1
}

# Show a colored unified diff (old file → new content)
_ask_show_diff() {
  local old="$1" new="$2" label="$3" line n=0
  local src="$old"
  [[ -f "$src" ]] || src=/dev/null
  diff -u "$src" "$new" 2>/dev/null | sed "1s|.*|--- a/${label}|; 2s|.*|+++ b/${label}|" | while IFS= read -r line; do
    n=$((n + 1))
    if ((n > 200)); then
      printf '  %b… (diff truncated)%b\n' "$DIM" "$RESET"
      break
    fi
    case "$line" in
      '+++'* | '---'*) printf '  %b%s%b\n' "$BOLD" "$line" "$RESET" ;;
      '@@'*) printf '  %b%s%b\n' "$ACCENT" "$line" "$RESET" ;;
      '+'*) printf '  %b%s%b\n' "$GREEN" "$line" "$RESET" ;;
      '-'*) printf '  %b%s%b\n' "$RED" "$line" "$RESET" ;;
      *) printf '  %s\n' "$line" ;;
    esac
  done
}

# Apply an approved hook edit, then approve it on this machine (the same
# approval covers both) unless other unreviewed hook changes are pending.
_ask_apply_hook_edit() {
  local svc="$1" hook="$2" new_file="$3"
  local dir="${_ASK_PROJECT}/.muster/hooks/${svc}" f
  f="${dir}/${hook}.sh"
  mkdir -p "$dir" || return 1
  local tmp="${f}.muster-ask.$$"
  if ! { cp "$new_file" "$tmp" && chmod 755 "$tmp" && mv "$tmp" "$f"; }; then
    rm -f "$tmp"
    printf 'Could not write %s\n' "${f#"${_ASK_PROJECT}"/}"
    return 1
  fi
  printf 'Updated .muster/hooks/%s/%s.sh\n' "$svc" "$hook"

  # Only auto-approve when this file is the only pending change for the
  # service: approving is per service, and the user reviewed just this diff.
  local others=""
  (
    cd "$_ASK_PROJECT" || exit 1
    source "$MUSTER_ROOT/lib/core/hook_security.sh"
    _hook_trust_pending "$_ASK_PROJECT" "$svc" || true
    [[ "$_HOOK_PENDING_FRESH" == "true" ]] && { echo "__fresh__"; exit 0; }
    _i=0
    while ((_i < ${#_HOOK_PENDING[@]})); do
      _e="${_HOOK_PENDING[$_i]}"
      _k="${_e#*|}"
      _k="${_k%%|*}"
      [[ "$_k" != "${svc}/${hook}.sh" ]] && echo "$_k"
      _i=$((_i + 1))
    done
  ) > "$_ASK_TMP/pending" 2>/dev/null
  others=$(tr '\n' ' ' < "$_ASK_TMP/pending")
  if [[ "$others" == *__fresh__* ]]; then
    printf 'Not approved: hooks were never approved on this machine. Review them all with: muster hooks approve\n'
    return 0
  fi
  if [[ -n "${others// /}" ]]; then
    printf 'Not approved: other unreviewed hook changes are pending (%s). Review them with: muster hooks approve %s\n' "${others% }" "$svc"
    return 0
  fi
  local out rc
  out=$(_ask_muster 60 hooks approve "$svc" --yes) && rc=0 || rc=$?
  if ((rc == 0)); then
    printf 'Approved on this machine (muster hooks approve %s).\n' "$svc"
  else
    printf 'Hook approval failed:\n%s\n' "$out"
    return 1
  fi
}

# ── Validation ──

_ASK_SERVICES=" "

_ask_valid_service() {
  local s="$1"
  [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
  [[ "$_ASK_SERVICES" == *" $s "* ]]
}

# Validate a tool request. Prints an error message and returns 1 on failure.
_ask_validate() {
  local name="$1" input="$2"
  if [[ "$_ASK_READ_TOOLS" != *" $name "* && "$_ASK_ACTION_TOOLS" != *" $name "* ]]; then
    printf 'Unknown tool: %s' "$name"
    return 1
  fi
  if [[ "$(printf '%s' "$input" | jq -r 'type' 2>/dev/null)" != "object" ]]; then
    printf 'Tool input must be a JSON object'
    return 1
  fi
  # No shell metacharacters in any string value (file content and the
  # free-text reason are written/displayed, never passed to a shell)
  local bad
  bad=$(printf '%s' "$input" | jq -r '
    [paths(strings) as $p | select(($p[0] != "new_content") and ($p[0] != "reason")) | getpath($p)
     | select(test("[;&|`$<>(){}\\\\!*?\\n\\r\"'"'"']"))] | length')
  if [[ "$bad" != "0" ]]; then
    printf 'Rejected: shell metacharacters in tool input'
    return 1
  fi
  local svc hook n
  case "$name" in
    muster_logs | muster_diagnose | read_hook | muster_rollback | muster_restart | propose_hook_edit)
      svc=$(printf '%s' "$input" | jq -r '.service // "" | tostring')
      if ! _ask_valid_service "$svc"; then
        printf 'Unknown service: %s (services in muster.json:%s)' "$svc" "${_ASK_SERVICES% }"
        return 1
      fi
      ;;
    muster_history)
      svc=$(printf '%s' "$input" | jq -r '.service // "" | tostring')
      if [[ -n "$svc" ]] && ! _ask_valid_service "$svc"; then
        printf 'Unknown service: %s' "$svc"
        return 1
      fi
      ;;
    muster_deploy)
      if [[ "$(printf '%s' "$input" | jq -r '.services // [] | type')" != "array" ]]; then
        printf 'services must be an array'
        return 1
      fi
      while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if ! _ask_valid_service "$svc"; then
          printf 'Unknown service: %s' "$svc"
          return 1
        fi
      done < <(printf '%s' "$input" | jq -r '.services // [] | .[] | tostring')
      ;;
  esac
  case "$name" in
    read_hook | propose_hook_edit)
      hook=$(printf '%s' "$input" | jq -r '.hook // "" | tostring')
      if [[ "$_ASK_HOOKS" != *" $hook "* ]]; then
        printf 'Unknown hook: %s (deploy, health, rollback, logs, cleanup)' "$hook"
        return 1
      fi
      ;;
  esac
  if [[ "$name" == "propose_hook_edit" ]]; then
    n=$(printf '%s' "$input" | jq -r '.new_content | type')
    if [[ "$n" != "string" ]]; then
      printf 'new_content must be a string'
      return 1
    fi
  fi
  return 0
}

# Read or action, decided here (never trusted from the server)
_ask_kind() {
  local name="$1" input="$2"
  if [[ "$name" == "muster_deploy" && "$(printf '%s' "$input" | jq -r '.dry_run == true')" == "true" ]]; then
    printf 'read'
  elif [[ "$_ASK_READ_TOOLS" == *" $name "* ]]; then
    printf 'read'
  else
    printf 'action'
  fi
}

# Human one-liner for a read tool
_ask_read_label() {
  local name="$1" input="$2" svc
  svc=$(printf '%s' "$input" | jq -r '.service // empty')
  case "$name" in
    muster_status) printf 'Checking service status…' ;;
    muster_logs) printf 'Reading %s logs…' "$svc" ;;
    muster_history) printf 'Reading deploy history%s…' "${svc:+ for $svc}" ;;
    muster_doctor) printf 'Running diagnostics…' ;;
    muster_diagnose) printf 'Diagnosing the last %s failure…' "$svc" ;;
    muster_hooks_status) printf 'Checking hook approvals…' ;;
    read_config) printf 'Reading muster.json…' ;;
    read_hook) printf 'Reading the %s %s hook…' "$svc" "$(printf '%s' "$input" | jq -r '.hook')" ;;
    muster_deploy) printf 'Previewing the deploy plan…' ;;
    *) printf 'Running %s…' "$name" ;;
  esac
}

# ── Approvals ──

_DEC_ID=()
_DEC_VAL=()

# --json mode: wait for {"approve":"<id>"} / {"decline":"<id>"} on stdin.
# Decisions for other ids are remembered. EOF declines.
_ask_json_decision() {
  local id="$1" i line a d
  i=0
  while ((i < ${#_DEC_ID[@]})); do
    if [[ "${_DEC_ID[$i]}" == "$id" ]]; then
      [[ "${_DEC_VAL[$i]}" == "approve" ]]
      return
    fi
    i=$((i + 1))
  done
  while IFS= read -r line; do
    a=$(printf '%s' "$line" | jq -r '.approve // empty' 2>/dev/null)
    d=$(printf '%s' "$line" | jq -r '.decline // empty' 2>/dev/null)
    if [[ -n "$a" ]]; then
      [[ "$a" == "$id" ]] && return 0
      _DEC_ID[${#_DEC_ID[@]}]="$a"
      _DEC_VAL[${#_DEC_VAL[@]}]="approve"
    elif [[ -n "$d" ]]; then
      [[ "$d" == "$id" ]] && return 1
      _DEC_ID[${#_DEC_ID[@]}]="$d"
      _DEC_VAL[${#_DEC_VAL[@]}]="decline"
    fi
  done
  return 1
}

# Decide whether an action may run. Prints why it was declined (if it was)
# into _ASK_DECLINE_MSG.
_ASK_DECLINE_MSG=""
_ask_approve() {
  local id="$1" name="$2" summary="$3" input="$4" diff_text="$5"
  _ASK_DECLINE_MSG="The user declined this action."
  if [[ "$_ASK_READ_ONLY" == "true" ]]; then
    _ASK_DECLINE_MSG="Actions are disabled in this session (read-only). Tell the user what to run instead."
    [[ "$_ASK_JSON" == "true" ]] || printf '  %bSkipped (read-only): %s%b\n' "$DIM" "$summary" "$RESET"
    return 1
  fi
  if [[ "$_ASK_JSON" == "true" ]]; then
    _ask_emit "$(jq -cn --arg id "$id" --arg n "$name" --arg s "$summary" --argjson in "$input" --arg diff "$diff_text" \
      '{type: "approval_needed", tool_use_id: $id, name: $n, summary: $s, input: ($in | if has("new_content") then del(.new_content) else . end)}
       + (if $diff == "" then {} else {diff: $diff} end)')"
    _ask_json_decision "$id"
    return
  fi
  if [[ "$_ASK_TTY" == "true" ]]; then
    local ans=""
    printf '  %b?%b %bRun this?%b [y/N] ' "$YELLOW" "$RESET" "$BOLD" "$RESET"
    IFS= read -r ans || ans=""
    case "$ans" in
      y | Y | yes | YES | Yes) return 0 ;;
    esac
    printf '  %bDeclined.%b\n' "$DIM" "$RESET"
    return 1
  fi
  if [[ "$_ASK_ALLOW_ACTIONS" == "true" ]]; then
    printf '  %bApproved by --allow-actions%b\n' "$DIM" "$RESET"
    return 0
  fi
  printf '  %bDeclined (no terminal to confirm; pass --allow-actions to allow).%b\n' "$DIM" "$RESET"
  return 1
}

# ── Running one tool request ──

_ASK_RESULTS_FILE=""

_ask_add_result() {
  local id="$1" content="$2" is_error="$3" name="$4"
  jq -cn --arg id "$id" --arg c "$content" --argjson e "$is_error" \
    '{tool_use_id: $id, content: $c, is_error: $e}' >> "$_ASK_RESULTS_FILE"
  if [[ "$_ASK_JSON" == "true" ]]; then
    _ask_emit "$(jq -cn --arg id "$id" --arg n "$name" --arg c "$content" --argjson e "$is_error" \
      '{type: "tool_result", tool_use_id: $id, name: $n, is_error: $e, content: $c}')"
  fi
}

# Redact + cap a tool result
_ask_prepare_content() {
  local text="$1" out
  out=$(printf '%s' "$text" | redact_text "${_ASK_PROJECT}/.env") || {
    printf '(result withheld: redaction unavailable)'
    return 1
  }
  if ((${#out} > _ASK_MAX_RESULT)); then
    out="[truncated: showing the last ${_ASK_MAX_RESULT} characters]"$'\n'"${out: -$_ASK_MAX_RESULT}"
  fi
  printf '%s' "$out"
}

_ask_run_tool() {
  local ev="$1"
  local id name input summary
  id=$(printf '%s' "$ev" | jq -r '.tool_use_id // ""')
  name=$(printf '%s' "$ev" | jq -r '.name // ""')
  input=$(printf '%s' "$ev" | jq -c '.input // {}')
  summary=$(printf '%s' "$ev" | jq -r '.summary // ""' | LC_ALL=C tr -d '\000-\010\013-\037\177')
  [[ -z "$summary" ]] && summary="$name"

  local verr
  if ! verr=$(_ask_validate "$name" "$input"); then
    [[ "$_ASK_JSON" == "true" ]] || printf '  %b! Refused %s: %s%b\n' "$YELLOW" "$name" "$verr" "$RESET"
    _ask_add_result "$id" "$verr" true "$name"
    return 0
  fi

  local kind svc
  kind=$(_ask_kind "$name" "$input")
  svc=$(printf '%s' "$input" | jq -r '.service // ""')

  local new_file="" diff_text=""
  if [[ "$kind" == "action" ]]; then
    if [[ "$_ASK_JSON" != "true" ]]; then
      printf '\n  %b▸ %s%b\n' "$BOLD" "$summary" "$RESET"
    fi
    if [[ "$name" == "propose_hook_edit" ]]; then
      local hook reason old
      hook=$(printf '%s' "$input" | jq -r '.hook')
      reason=$(printf '%s' "$input" | jq -r '.reason // ""' | LC_ALL=C tr -d '\000-\010\013-\037\177')
      new_file="$_ASK_TMP/hook_new"
      printf '%s' "$input" | jq -j '.new_content' > "$new_file"
      old="${_ASK_PROJECT}/.muster/hooks/${svc}/${hook}.sh"
      if [[ "$_ASK_JSON" == "true" ]]; then
        local src="$old"
        [[ -f "$src" ]] || src=/dev/null
        diff_text=$(diff -u "$src" "$new_file" 2>/dev/null | sed "1s|.*|--- a/.muster/hooks/${svc}/${hook}.sh|; 2s|.*|+++ b/.muster/hooks/${svc}/${hook}.sh|")
      else
        [[ -n "$reason" ]] && printf '  %b%s%b\n' "$DIM" "$reason" "$RESET"
        echo ""
        _ask_show_diff "$old" "$new_file" ".muster/hooks/${svc}/${hook}.sh"
        echo ""
      fi
    fi
    if ! _ask_approve "$id" "$name" "$summary" "$input" "$diff_text"; then
      _ask_add_result "$id" "$_ASK_DECLINE_MSG" true "$name"
      return 0
    fi
  fi

  if [[ "$_ASK_JSON" == "true" ]]; then
    _ask_emit "$(jq -cn --arg id "$id" --arg n "$name" --arg k "$kind" --arg s "$summary" \
      '{type: "tool_running", tool_use_id: $id, name: $n, kind: $k, summary: $s}')"
  elif [[ "$kind" == "read" ]]; then
    printf '  %b%s%b\n' "$DIM" "$(_ask_read_label "$name" "$input")" "$RESET"
  else
    printf '  %bRunning…%b\n' "$DIM" "$RESET"
  fi

  local out rc=0 lines limit
  case "$name" in
    muster_status) out=$(_ask_muster 60 status --json) || rc=$? ;;
    muster_logs)
      lines=$(printf '%s' "$input" | jq -r '(.lines // 100) | tonumber? // 100 | floor | if . < 1 then 1 elif . > 500 then 500 else . end')
      out=$(_ask_tool_logs "$svc" "$lines") || rc=$?
      ;;
    muster_history)
      limit=$(printf '%s' "$input" | jq -r '(.limit // 20) | tonumber? // 20 | floor | if . < 1 then 1 elif . > 200 then 200 else . end')
      out=$(_ask_tool_history "$svc" "$limit") || rc=$?
      ;;
    muster_doctor) out=$(_ask_muster 120 doctor --json) || rc=$? ;;
    muster_diagnose) out=$(_ask_tool_diagnose "$svc") || rc=$? ;;
    muster_hooks_status) out=$(_ask_tool_hooks_status) || rc=$? ;;
    read_config) out=$(_ask_tool_read_config) || rc=$? ;;
    read_hook) out=$(_ask_tool_read_hook "$svc" "$(printf '%s' "$input" | jq -r '.hook')") || rc=$? ;;
    muster_deploy)
      local dargs=() s
      while IFS= read -r s; do
        [[ -n "$s" ]] && dargs[${#dargs[@]}]="$s"
      done < <(printf '%s' "$input" | jq -r '.services // [] | .[]')
      if [[ "$kind" == "read" ]]; then
        dargs[${#dargs[@]}]="--dry-run"
      fi
      out=$(_ask_muster 1800 deploy "${dargs[@]+"${dargs[@]}"}") || rc=$?
      ;;
    muster_rollback) out=$(_ask_tool_rollback "$svc") || rc=$? ;;
    muster_restart) out=$(_ask_tool_restart "$svc") || rc=$? ;;
    propose_hook_edit)
      out=$(_ask_apply_hook_edit "$svc" "$(printf '%s' "$input" | jq -r '.hook')" "$new_file") || rc=$?
      ;;
  esac

  local is_error=false
  if [[ "$kind" == "action" || "$name" == "read_hook" || "$name" == "muster_logs" ]]; then
    ((rc != 0)) && is_error=true
  elif ((rc != 0)); then
    out="${out}"$'\n'"(exit code ${rc})"
  fi
  [[ -z "$out" ]] && out="(no output)"

  local content
  content=$(_ask_prepare_content "$out") || is_error=true

  if [[ "$_ASK_JSON" != "true" && "$kind" == "action" ]]; then
    if [[ "$is_error" == "true" ]]; then
      printf '  %bx%b %s failed\n' "$RED" "$RESET" "$summary"
      printf '%s\n' "$content" | tail -5 | while IFS= read -r l; do printf '    %b%s%b\n' "$DIM" "$l" "$RESET"; done
    else
      printf '  %b*%b Done\n' "$GREEN" "$RESET"
      [[ "$name" == "propose_hook_edit" ]] &&
        printf '%s\n' "$content" | while IFS= read -r l; do printf '    %b%s%b\n' "$DIM" "$l" "$RESET"; done
    fi
    echo ""
  fi

  _ask_add_result "$id" "$content" "$is_error" "$name"
}

# ── Session context ──

_ask_detect_stack() {
  local s
  s=$(jq -r '.stack // empty' "${_ASK_PROJECT}/muster.json" 2>/dev/null)
  if [[ -n "$s" ]]; then
    printf '%s' "$s"
    return
  fi
  local hooks="${_ASK_PROJECT}/.muster/hooks"
  if grep -rqs kubectl "$hooks" 2>/dev/null; then
    printf 'k8s'
  elif grep -rqsE 'docker[ -]compose' "$hooks" 2>/dev/null; then
    printf 'compose'
  elif grep -rqs 'docker ' "$hooks" 2>/dev/null; then
    printf 'docker'
  else
    printf 'bare'
  fi
}

# The failure to explain: from `muster deploy` (env) or the last failed
# deploy in the event log. Prints "service|exit_code|log_file" or nothing.
_ask_find_failure() {
  if [[ -n "${MUSTER_ASK_FAILURE_SERVICE:-}" ]]; then
    printf '%s|%s|%s' "$MUSTER_ASK_FAILURE_SERVICE" "${MUSTER_ASK_FAILURE_EXIT:-}" "${MUSTER_ASK_FAILURE_LOG:-}"
    return 0
  fi
  local events="${_ASK_PROJECT}/.muster/logs/deploy-events.log" last svc status
  [[ -f "$events" ]] || return 1
  last=$(grep -F '"action":"deploy"' "$events" 2>/dev/null | tail -1)
  [[ -n "$last" ]] || return 1
  status=$(printf '%s' "$last" | jq -r '.status // empty' 2>/dev/null)
  [[ "$status" == "failed" ]] || return 1
  svc=$(printf '%s' "$last" | jq -r '.service // empty' 2>/dev/null)
  _ask_valid_service "$svc" || return 1
  printf '%s||%s' "$svc" "$(_ask_latest_log "$svc" "deploy")"
}

_ask_build_context() {
  local failure="$1" os stack services fsvc="" fexit="" flog="" ftail=""
  os="${MUSTER_OS:-$(uname -s)} $(uname -m 2>/dev/null)"
  stack=$(_ask_detect_stack)
  services=$(jq -c '.services | keys' "${_ASK_PROJECT}/muster.json" 2>/dev/null || echo '[]')
  if [[ -n "$failure" ]]; then
    fsvc="${failure%%|*}"
    local r="${failure#*|}"
    fexit="${r%%|*}"
    flog="${r#*|}"
    if [[ -n "$flog" && -f "$flog" ]]; then
      ftail=$(tail -n 40 "$flog" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | redact_text "${_ASK_PROJECT}/.env") || ftail=""
    fi
  fi
  jq -cn --arg v "${MUSTER_VERSION:-dev}" --arg os "$os" --arg stack "$stack" \
    --argjson services "$services" --arg fsvc "$fsvc" --arg fexit "$fexit" --arg ftail "$ftail" '{
      muster_version: $v, os: $os, stack: $stack, services: $services
    } + (if $fsvc == "" then {} else {failure: ({service: $fsvc, log_tail: ($ftail | split("\n") | map(select(length > 0)))}
          + (if ($fexit | test("^[0-9]+$")) then {exit_code: ($fexit | tonumber)} else {} end))} end)'
}

# ── Main ──

cmd_ask() {
  local question="" give_consent=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        _ask_help
        return 0
        ;;
      -y | --yes) give_consent=true ;;
      --json) _ASK_JSON=true ;;
      --allow-actions) _ASK_ALLOW_ACTIONS=true ;;
      --read-only) _ASK_READ_ONLY=true ;;
      --)
        shift
        question="${question:+$question }$*"
        break
        ;;
      -*)
        err "Unknown flag: $1"
        echo "Run 'muster ask --help' for usage."
        return 1
        ;;
      *) question="${question:+$question }$1" ;;
    esac
    shift
  done

  if [[ "$_ASK_JSON" != "true" && -t 0 && -t 1 ]]; then
    _ASK_TTY=true
  fi

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    _ask_fail "missing_dependency" "muster ask needs curl and jq"
    return 1
  fi
  if _assistant_disabled; then
    _ask_fail "disabled" "The Muster Assistant is turned off on this machine."
    [[ "$_ASK_JSON" == "true" ]] || printf '  %bTurn it on with: muster settings --global assistant on%b\n' "$DIM" "$RESET"
    return 1
  fi

  local config
  if ! config=$(find_config 2>/dev/null); then
    _ask_fail "no_project" "No muster project here. Run muster ask inside a project (muster setup creates one)."
    return 1
  fi
  # shellcheck disable=SC2034  # read by config helpers
  CONFIG_FILE="$config"
  _ASK_PROJECT="$(cd "$(dirname "$config")" && pwd)"
  local s
  while IFS= read -r s; do
    [[ -n "$s" ]] && _ASK_SERVICES="${_ASK_SERVICES}${s} "
  done < <(jq -r '.services // {} | keys[]' "$config" 2>/dev/null)

  local token
  token=$(_assistant_token)
  if [[ -z "$token" ]]; then
    _ask_fail "not_logged_in" "The Muster Assistant needs a Fleet Cloud login."
    [[ "$_ASK_JSON" == "true" ]] || printf '  %bSign in with: muster cloud login%b\n' "$DIM" "$RESET"
    return 1
  fi

  # Consent (per project)
  local project_name
  project_name=$(jq -r '.project // .name // empty' "$config" 2>/dev/null)
  [[ -z "$project_name" ]] && project_name=$(basename "$_ASK_PROJECT")
  if ! _assistant_has_consent "$_ASK_PROJECT"; then
    if [[ "$give_consent" != "true" ]]; then
      if [[ "$_ASK_TTY" == "true" ]]; then
        echo ""
        printf '  Send redacted logs and config from %b%s%b to the Muster Assistant? [y/N] ' "$BOLD" "$project_name" "$RESET"
        local ans=""
        IFS= read -r ans || ans=""
        case "$ans" in
          y | Y | yes | YES | Yes) ;;
          *)
            info "Nothing was sent."
            return 1
            ;;
        esac
      else
        _ask_fail "consent_required" "Sending project data to the Muster Assistant needs your consent for ${project_name}."
        [[ "$_ASK_JSON" == "true" ]] || printf '  %bRun muster ask once in a terminal, or pass --yes.%b\n' "$DIM" "$RESET"
        return 1
      fi
    fi
    _assistant_save_consent "$_ASK_PROJECT" || {
      _ask_fail "consent_write_failed" "Couldn't save consent to .muster/assistant.json"
      return 1
    }
  fi

  _ASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/muster-ask.XXXXXX") || return 1
  chmod 700 "$_ASK_TMP"
  trap '_ask_interrupt' INT TERM
  _ask_auth_header "$token"
  token=""
  _ASK_BASE=$(_assistant_url)
  _ASK_RESULTS_FILE="$_ASK_TMP/results"

  local failure=""
  failure=$(_ask_find_failure) || failure=""

  # Question
  if [[ -z "$question" ]]; then
    if [[ -n "$failure" ]]; then
      question="Why did the ${failure%%|*} deploy fail, and how do I fix it?"
    elif [[ "$_ASK_TTY" == "true" ]]; then
      echo ""
      printf '  %bWhat do you need help with?%b\n  %b›%b ' "$BOLD" "$RESET" "$ACCENT" "$RESET"
      IFS= read -r question || question=""
      if [[ -z "$question" ]]; then
        _ask_cleanup
        return 0
      fi
    else
      _ask_fail "no_question" "Usage: muster ask <question>"
      _ask_cleanup
      return 1
    fi
  fi

  # Session
  local ctx
  if ! ctx=$(_ask_build_context "$failure") || [[ -z "$ctx" ]]; then
    _ask_fail "context_failed" "Couldn't build the (redacted) project context"
    _ask_cleanup
    return 1
  fi
  jq -cn --arg p "$project_name" --argjson c "$ctx" '{project: $p, context: $c}' > "$_ASK_TMP/body"
  _ask_post "${_ASK_BASE}/api/assist/sessions" "$_ASK_TMP/body" || true
  case "$_ASK_HTTP_STATUS" in
    200 | 201) ;;
    *)
      _ask_http_error "$_ASK_HTTP_STATUS" "$_ASK_HTTP_BODY" "Starting an assistant session"
      _ask_cleanup
      return 1
      ;;
  esac
  _ASK_SESSION=$(printf '%s' "$_ASK_HTTP_BODY" | jq -r '.session_id // empty' 2>/dev/null)
  if [[ ! "$_ASK_SESSION" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    _ask_fail "bad_response" "Unexpected response from the assistant server"
    _ask_cleanup
    return 1
  fi
  local remaining plan
  remaining=$(printf '%s' "$_ASK_HTTP_BODY" | jq -r '.remaining_sessions // empty' 2>/dev/null)
  plan=$(printf '%s' "$_ASK_HTTP_BODY" | jq -r '.plan // empty' 2>/dev/null)
  if [[ "$_ASK_JSON" == "true" ]]; then
    _ask_emit "$(printf '%s' "$_ASK_HTTP_BODY" | jq -c '{type: "session", session_id, plan, remaining_sessions}')"
  else
    echo ""
    printf '  %bMuster Assistant%b' "${BOLD}${ACCENT_BRIGHT}" "$RESET"
    [[ -n "$plan" ]] && printf '  %b%s plan%b' "$DIM" "$plan" "$RESET"
    [[ -n "$remaining" ]] && printf '  %b· %s sessions left%b' "$DIM" "$remaining" "$RESET"
    printf '\n'
    if [[ -n "$failure" && -z "${MUSTER_ASK_FAILURE_SERVICE:-}" ]]; then
      printf '  %bIncluding the last failed deploy (%s) as context%b\n' "$DIM" "${failure%%|*}" "$RESET"
    fi
    echo ""
  fi

  # Conversation loop
  local rc=0
  while true; do
    jq -cn --arg m "$question" '{message: $m}' > "$_ASK_TMP/body"
    local rounds=0
    while true; do
      _md_reset
      if ! _ask_turn "$_ASK_TMP/body"; then
        rc=1
        break 2
      fi
      if ((_TR_N == 0)); then
        case "$_ASK_STOP" in
          max_tokens) [[ "$_ASK_JSON" == "true" ]] || printf '  %b(The answer was cut off.)%b\n' "$DIM" "$RESET" ;;
          refusal) [[ "$_ASK_JSON" == "true" ]] || printf '  %b(The assistant declined to answer.)%b\n' "$DIM" "$RESET" ;;
        esac
        break
      fi
      rounds=$((rounds + 1))
      if ((rounds > _ASK_MAX_ROUNDS)); then
        _ask_fail "too_many_tool_rounds" "Stopped after ${_ASK_MAX_ROUNDS} tool rounds."
        rc=1
        break 2
      fi
      : > "$_ASK_RESULTS_FILE"
      local i=0
      while ((i < _TR_N)); do
        _ask_run_tool "${_TR_EV[$i]}"
        i=$((i + 1))
      done
      [[ "$_ASK_JSON" == "true" ]] || echo ""
      jq -cs '{tool_results: .}' "$_ASK_RESULTS_FILE" > "$_ASK_TMP/body"
    done

    # Follow-ups
    question=""
    if [[ "$_ASK_JSON" == "true" ]]; then
      _ask_emit '{"type":"awaiting_input"}'
      local line
      while IFS= read -r line; do
        question=$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null)
        [[ -n "$question" ]] && break
        [[ "$(printf '%s' "$line" | jq -r '.end // false' 2>/dev/null)" == "true" ]] && break
      done
    elif [[ "$_ASK_TTY" == "true" ]]; then
      printf '\n  %bAsk a follow-up, or press Enter to finish%b\n  %b›%b ' "$DIM" "$RESET" "$ACCENT" "$RESET"
      IFS= read -r question || question=""
      echo ""
    fi
    [[ -z "$question" ]] && break
  done

  [[ "$_ASK_JSON" == "true" ]] && _ask_emit "$(jq -cn --arg s "$_ASK_SESSION" --argjson ok "$([[ $rc -eq 0 ]] && echo true || echo false)" '{type: "done", session_id: $s, ok: $ok}')"
  trap - INT TERM
  _ask_cleanup
  return "$rc"
}
