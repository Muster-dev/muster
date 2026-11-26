#!/usr/bin/env bash
# muster/lib/core/nextstep.sh — the dashboard's single context-aware
# "Next step" line. Pure function of project state, so it's testable.
#
# _next_step PROJECT_DIR
#   Sets NEXT_STEP_TEXT   (what to show, "" when nothing to suggest)
#        NEXT_STEP_ACTION (dashboard action that Enter should run, may be "")
#        NEXT_STEP_KIND   (failure|approval|lock|first_deploy|update|ok|"")
#
# shellcheck disable=SC2034
# Priority: recent failure > hooks need approval > stale lock >
#           no deploys yet > update available.

# "5m ago" for an epoch timestamp
_next_step_ago() {
  local then="$1" now diff
  now=$(date +%s)
  [[ "$then" =~ ^[0-9]+$ ]] || { printf 'recently'; return; }
  diff=$(( now - then ))
  (( diff < 0 )) && diff=0
  if (( diff < 60 )); then printf '%ss ago' "$diff"
  elif (( diff < 3600 )); then printf '%sm ago' $(( diff / 60 ))
  elif (( diff < 86400 )); then printf '%sh ago' $(( diff / 3600 ))
  else printf '%sd ago' $(( diff / 86400 ))
  fi
}

# Epoch seconds of the newest successful deploy of a service in the events
# log (echo 0 when none). Events use "YYYY-MM-DD HH:MM:SS" local time.
_next_step_last_ok() {
  local events="$1" svc="$2" ts
  [[ -f "$events" ]] || { printf '0'; return; }
  ts=$(grep -F "\"service\":\"${svc}\"" "$events" 2>/dev/null \
    | grep -F '"action":"deploy"' | grep -F '"status":"ok"' | tail -1 \
    | sed -nE 's/.*"ts":"([^"]+)".*/\1/p')
  [[ -z "$ts" ]] && { printf '0'; return; }
  local e
  e=$(date -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null \
    || date -d "$ts" +%s 2>/dev/null || echo 0)
  printf '%s' "$e"
}

_next_step() {
  local dir="$1"
  NEXT_STEP_TEXT="" NEXT_STEP_ACTION="" NEXT_STEP_KIND=""
  local logs="${dir}/.muster/logs"
  local events="${logs}/deploy-events.log"

  # 1. A failure that hasn't been fixed by a later successful deploy
  local lf="${logs}/.last_failure"
  if [[ -f "$lf" ]]; then
    local ts svc action _rest
    IFS='|' read -r ts svc action _rest < "$lf"
    if [[ "$ts" =~ ^[0-9]+$ && -n "$svc" ]]; then
      local age=$(( $(date +%s) - ts ))
      local last_ok
      last_ok=$(_next_step_last_ok "$events" "$svc")
      if (( age < 86400 )) && (( last_ok < ts )); then
        local what="failed"
        [[ "$action" == "rollback" ]] && what="rollback failed"
        [[ "$action" == "health" ]] && what="failed its health check"
        NEXT_STEP_TEXT="${svc} ${what} $(_next_step_ago "$ts") — press Enter to see why"
        NEXT_STEP_ACTION="Explain last failure"
        NEXT_STEP_KIND="failure"
        return 0
      fi
    fi
  fi

  # 2. Hooks that need approval on this machine
  local _hs=""
  declare -F global_config_get >/dev/null 2>&1 && _hs=$(global_config_get "hook_security" 2>/dev/null || true)
  if declare -F _hook_trust_pending >/dev/null 2>&1 && [[ "$_hs" != "off" ]]; then
    local svcs=() s
    for s in "${dir}/.muster/hooks"/*/; do
      [[ -d "$s" ]] || continue
      s="${s%/}"
      svcs[${#svcs[@]}]="${s##*/}"
    done
    if (( ${#svcs[@]} > 0 )) && _hook_trust_pending "$dir" "${svcs[@]}" 2>/dev/null; then
      local n=${#_HOOK_PENDING[@]}
      NEXT_STEP_TEXT="${n} hook$( (( n != 1 )) && echo s) need$( (( n == 1 )) && echo s) approval before deploying — press Enter to review"
      NEXT_STEP_ACTION="Approve hooks"
      NEXT_STEP_KIND="approval"
      return 0
    fi
  fi

  # 3. A deploy lock whose process is gone
  local lock="${dir}/.muster/deploy.lock"
  if [[ -f "$lock" ]]; then
    local pid
    pid=$(sed -nE 's/.*"pid"[[:space:]]*:[[:space:]]*"?([0-9]+).*/\1/p' "$lock" 2>/dev/null | head -1)
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      NEXT_STEP_TEXT="A crashed deploy left its lock behind — press Enter to clear it"
      NEXT_STEP_ACTION="Doctor --fix"
      NEXT_STEP_KIND="lock"
      return 0
    fi
  fi

  # 4. Never deployed
  if [[ ! -s "$events" ]] || ! grep -q '"action":"deploy"' "$events" 2>/dev/null; then
    NEXT_STEP_TEXT="No deploys yet — press Enter to deploy"
    NEXT_STEP_ACTION="Deploy"
    NEXT_STEP_KIND="first_deploy"
    return 0
  fi

  # 5. Update available
  if [[ "${MUSTER_UPDATE_AVAILABLE:-false}" == "true" ]]; then
    local v=""
    [[ -n "${_MUSTER_LATEST_TAG:-}" ]] && v=" (${_MUSTER_LATEST_TAG})"
    NEXT_STEP_TEXT="Update available${v} — press Enter to update"
    NEXT_STEP_ACTION="Update muster"
    NEXT_STEP_KIND="update"
    return 0
  fi

  NEXT_STEP_KIND="ok"
  return 0
}
