#!/usr/bin/env bash
# muster/lib/commands/explain.sh — explain the last failure in plain words
# using the offline rules engine (lib/core/hints.sh). No AI involved.

source "$MUSTER_ROOT/lib/core/hints.sh"
source "$MUSTER_ROOT/lib/core/suggest.sh"
source "$MUSTER_ROOT/lib/core/nextstep.sh"

_explain_usage() {
  echo "Usage: muster explain [service] [flags]"
  echo ""
  echo "Explain why a deploy, rollback or health check failed — what happened,"
  echo "why, and what to do next. Works offline from known problem patterns."
  echo ""
  echo "Targets:"
  echo "  (none), --last    The most recent failure in this project"
  echo "  <service>         The newest deploy/rollback log for a service"
  echo "  --log FILE        Any log file (works outside a project too)"
  echo ""
  echo "Flags:"
  echo "  --json            Machine-readable output (for muster-tui and scripts)"
  echo "  --fix             Offer to run the suggested fix"
  echo "  --yes             With --fix: run it without asking"
  echo "  --exit-code N     Exit code of the failed hook (improves matching)"
  echo "  --rules           List every known problem pattern"
  echo "  -h, --help        Show this help"
  echo ""
  echo "Examples:"
  echo "  muster explain                 Why did the last deploy fail?"
  echo "  muster explain api             Explain api's newest log"
  echo "  muster explain --log build.log Explain any log file"
  echo "  muster explain --fix           Explain, then offer the one-key fix"
}

cmd_explain() {
  local target="" mode="last" log_file="" json=false want_fix=false yes=false rc_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) _explain_usage; return 0 ;;
      --last) mode="last"; shift ;;
      --log)
        [[ -z "${2:-}" ]] && { err "--log needs a file path"; return 1; }
        mode="log"; log_file="$2"; shift 2 ;;
      --log=*) mode="log"; log_file="${1#--log=}"; shift ;;
      --json) json=true; shift ;;
      --fix) want_fix=true; shift ;;
      --yes|-y) yes=true; shift ;;
      --exit-code)
        rc_arg="${2:-}"; shift 2 ;;
      --rules)
        hints_list_rules | while IFS='|' read -r _id _title _try; do
          printf '  %b%s%b\n    %s\n' "${BOLD}" "$_id" "${RESET}" "$_title"
        done
        return 0 ;;
      -*)
        err "Unknown flag: $1"
        _suggest_print "$1" --last --log --json --fix --yes --exit-code --rules --help
        echo "Run 'muster explain --help' for usage."
        return 1 ;;
      *)
        [[ -n "$target" ]] && { err "Explain one service at a time (got '$target' and '$1')"; return 1; }
        target="$1"; mode="service"; shift ;;
    esac
  done

  local have_project=false
  if find_config &>/dev/null; then
    load_config
    have_project=true
  fi

  local svc="" action="" rc="$rc_arg" when="" recorded_hint=""
  case "$mode" in
    log)
      if [[ ! -f "$log_file" ]]; then
        err "Log file not found: ${log_file}"
        return 1
      fi
      ;;
    service|last)
      if [[ "$have_project" != "true" ]]; then
        err "No muster project here (no muster.json found)."
        printf '  %bcd into a project, run muster setup, or explain a file: muster explain --log <file>%b\n' "${DIM}" "${RESET}"
        return 1
      fi
      local pdir logs
      pdir="$(dirname "$CONFIG_FILE")"
      logs="${pdir}/.muster/logs"
      if [[ "$mode" == "service" ]]; then
        local known
        known=$(config_services)
        if ! printf '%s\n' "$known" | grep -qxF -- "$target"; then
          err "Unknown service: ${target}"
          # shellcheck disable=SC2086
          _suggest_print "$target" $known || \
            printf '  %bServices in this project:%b %s\n' "$DIM" "$RESET" "$(printf '%s' "$known" | tr '\n' ' ')"
          return 1
        fi
        svc="$target"
      fi
      # Recorded failure (deploy/rollback/health) from this machine
      if [[ -f "${logs}/.last_failure" ]]; then
        local _ts _svc _act _rc _log _hid
        IFS='|' read -r _ts _svc _act _rc _log _hid < "${logs}/.last_failure"
        if [[ -z "$svc" || "$svc" == "$_svc" ]]; then
          svc="$_svc" action="$_act" when="$_ts" recorded_hint="$_hid"
          [[ -z "$rc" ]] && rc="$_rc"
          [[ -f "$_log" ]] && log_file="$_log"
        fi
      fi
      # Otherwise: newest log for the service (or any service)
      if [[ -z "$log_file" && "$action" != "health" ]]; then
        local pattern="*.log"
        [[ -n "$svc" ]] && pattern="${svc}-*.log"
        # shellcheck disable=SC2012,SC2010
        log_file=$(ls -t "${logs}"/$pattern 2>/dev/null | grep -v 'deploy-events.log' | head -1)
        if [[ -n "$log_file" && -z "$svc" ]]; then
          svc=$(basename "$log_file"); svc="${svc%%-deploy-*}"; svc="${svc%%-rollback-*}"
        fi
        case "$log_file" in *-rollback-*) action="rollback" ;; *) [[ -n "$log_file" ]] && action="deploy" ;; esac
      fi
      if [[ -z "$log_file" && "$action" != "health" ]]; then
        if [[ "$json" == "true" ]]; then
          printf '{"service":"%s","matched":false,"reason":"no_logs","hint":null,"hints":[]}\n' "$(_json_escape "$svc")"
          return 0
        fi
        echo ""
        if [[ -n "$svc" ]]; then
          info "Nothing to explain yet — ${svc} has no deploy logs."
        else
          info "Nothing to explain yet — no failed deploys recorded in this project."
        fi
        printf '  %bWhen a deploy fails, run muster explain to see why.%b\n\n' "${DIM}" "${RESET}"
        return 0
      fi
      ;;
  esac

  # ── Match ──
  local matched=false
  if [[ "$action" == "health" && -n "$svc" ]]; then
    hints_health "$svc" && matched=true
  else
    hints_match_file "$log_file" "$rc" "$svc" && matched=true
    # Health type info when a deploy log has no clue but health failed
    if [[ "$matched" == "false" && -n "$svc" && "$recorded_hint" == health_* ]]; then
      hints_health "$svc" && matched=true
    fi
  fi

  if [[ "$json" == "true" ]]; then
    _explain_json "$svc" "$action" "$rc" "$log_file" "$when" "$matched"
    return 0
  fi

  # ── Human output ──
  echo ""
  local head="Explaining"
  if [[ -n "$svc" ]]; then
    local what="${action:-deploy} failed"
    [[ "$action" == "health" ]] && what="health check failed"
    head="${head} ${BOLD}${svc}${RESET} — ${what}"
    [[ -n "$when" ]] && head="${head} $(_next_step_ago "$when")"
    [[ -n "$rc" && "$rc" != "0" ]] && head="${head} (exit ${rc})"
  else
    head="${head} ${BOLD}$(basename "$log_file")${RESET}"
  fi
  printf '  %b\n' "$head"
  if [[ -n "$log_file" ]]; then
    local shown="$log_file"
    [[ "$have_project" == "true" ]] && shown="${log_file#"$(dirname "$CONFIG_FILE")"/}"
    printf '  %bLog: %s%b\n' "${DIM}" "$shown" "${RESET}"
  fi
  echo ""

  if [[ "$matched" == "true" ]]; then
    hints_print "  "
    if [[ -n "$HINT_LINE" ]]; then
      local ml="$HINT_LINE"
      (( ${#ml} > 160 )) && ml="${ml:0:157}..."
      printf '  %bMatched: %s%b\n' "${DIM}" "$ml" "${RESET}"
    fi
    if (( ${#_HINT_ALL_IDS[@]} > 1 )); then
      local others="" i=1
      while (( i < ${#_HINT_ALL_IDS[@]} )); do
        others="${others}${others:+, }${_HINT_ALL_IDS[$i]}"
        i=$(( i + 1 ))
      done
      printf '  %bAlso seen in the log: %s%b\n' "${DIM}" "$others" "${RESET}"
    fi
    echo ""
    if [[ -n "$HINT_FIX_CMD" ]]; then
      if [[ "$want_fix" == "true" ]]; then
        if [[ "$yes" == "true" ]]; then
          hints_run_fix --yes
        elif [[ -t 0 ]]; then
          hints_run_fix
        else
          err "Not running the fix without a terminal — add --yes to run it: ${HINT_FIX_CMD}"
          return 1
        fi
        echo ""
      else
        printf '  %bRun %bmuster explain --fix%b%b to apply the fix.%b\n\n' "${DIM}" "${RESET}${BOLD}" "${RESET}" "${DIM}" "${RESET}"
      fi
    fi
  else
    printf '  %bNo known problem pattern matched.%b\n' "${YELLOW}" "${RESET}"
    if [[ -n "$log_file" && -f "$log_file" ]]; then
      printf '  %bLast lines of the log:%b\n' "${DIM}" "${RESET}"
      tail -n 8 "$log_file" | _hints_clean | while IFS= read -r _l; do
        printf '    %b%s%b\n' "${DIM}" "$_l" "${RESET}"
      done
    fi
    echo ""
    printf '  %bNext:%b ' "${BOLD}" "${RESET}"
    if [[ -n "$svc" ]]; then
      printf 'muster logs %s  ·  muster doctor  ·  muster deploy %s\n' "$svc" "$svc"
    else
      printf 'muster doctor  ·  read the full log above\n'
    fi
    echo ""
  fi
  return 0
}

_explain_json() {
  local svc="$1" action="$2" rc="$3" log="$4" when="$5" matched="$6"
  local primary="null" list="" i=0
  if [[ "$matched" == "true" ]]; then
    primary=$(hints_json)
    local ids=("${_HINT_ALL_IDS[@]}") lines=("${_HINT_ALL_LINES[@]}")
    if (( ${#ids[@]} == 0 )); then
      list="$primary"
    else
      while (( i < ${#ids[@]} )); do
        hints_lookup "${ids[$i]}" "$svc" "${lines[$i]:-}" "$rc"
        list="${list}${list:+,}$(hints_json)"
        i=$(( i + 1 ))
      done
    fi
  fi
  local rc_json="null"
  [[ "$rc" =~ ^[0-9]+$ ]] && rc_json="$rc"
  local when_json="null"
  [[ "$when" =~ ^[0-9]+$ ]] && when_json="$when"
  printf '{"service":"%s","action":"%s","exit_code":%s,"log":"%s","when":%s,"matched":%s,"hint":%s,"hints":[%s]}\n' \
    "$(_json_escape "$svc")" "$(_json_escape "$action")" "$rc_json" "$(_json_escape "$log")" \
    "$when_json" "$matched" "$primary" "$list"
}
