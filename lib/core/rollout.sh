#!/usr/bin/env bash
# muster/lib/core/rollout.sh — Progressive delivery: strategy config, version
# resolution, NDJSON events, gates and the compact rollout display.
#
# Split of responsibility (docs/rollouts.md):
#   hooks          build/push the candidate and point the target Deployment at
#                  it (MUSTER_TARGET_DEPLOYMENT / MUSTER_IMAGE_TAG)
#   rollout engine shifts traffic, runs gates, owns state, promote/abort
#
# Kubernetes specifics live in lib/core/rollout_k8s.sh. State for a k8s
# service is a ConfigMap (muster-rollout-<deployment>) in its namespace, so
# every machine that can reach the cluster sees the same rollout.

source "$MUSTER_ROOT/lib/core/engine.sh"

# ── Strategy config ──

# Normalized strategy JSON for a service. Fills defaults, expands the
# shorthand forms ("strategy": "canary", "steps": [10, 50, 100]) and resolves
# traffic "auto". Optional 2nd arg overrides the type (deploy --strategy).
# Usage: _rollout_strategy svc [type_override]
_rollout_strategy() {
  local svc="$1" ovt="${2:-}"
  jq -c --arg s "$svc" --arg ovt "$ovt" '
    (.services[$s].strategy // {}) as $raw
    | ($raw | if type == "string" then {type: .} elif type == "object" then . else {} end) as $r0
    | (if $ovt != "" then ($r0 + {type: $ovt}) else $r0 end) as $r
    | ($r.type // "rolling") as $t
    | ($r.pause // (if $t == "canary" then 60 else "manual" end)) as $dp
    | {
        type: $t,
        traffic: (if ($r.traffic // "auto") == "auto" then
                    (if $t == "blue-green" then "service-selector"
                     elif $t == "canary" then "replicas" else "none" end)
                  else $r.traffic end),
        steps: (if $t == "canary" then
                  (($r.steps // [10, 25, 50, 100])
                   | map(if type == "number" then {weight: ., pause: (if . == 100 then 0 else $dp end)}
                         else {weight: .weight, pause: (if .weight == 100 then 0 else (.pause // $dp) end)} end)
                   | if (length == 0 or (last.weight != 100)) then . + [{weight: 100, pause: 0}] else . end)
                else [] end),
        pause: $dp,
        auto_promote: ($r.auto_promote == true),
        drain_seconds: ($r.drain_seconds // 30),
        keep_old_seconds: ($r.keep_old_seconds // 0),
        auto_rollback: ($r.auto_rollback != false),
        on_interrupt: ($r.on_interrupt // (if $t == "blue-green" then "pause" else "abort" end)),
        preview: {
          enabled: ($r.preview.enabled == true),
          service: ($r.preview.service // ""),
          host: ($r.preview.host // "")
        },
        analysis: {
          interval_seconds: ($r.analysis.interval_seconds // 10),
          max_failures: ($r.analysis.max_failures // 2),
          health_check: ($r.analysis.health_check != false),
          pod_stability: ($r.analysis.pod_stability != false),
          max_restarts: ($r.analysis.max_restarts // 0)
        }
      }' "$CONFIG_FILE"
}

# Strategy type for a service (rolling | blue-green | canary)
_rollout_type() {
  local t
  t=$(jq -r --arg s "$1" '(.services[$s].strategy // "rolling") | if type == "string" then . else (.type // "rolling") end' "$CONFIG_FILE" 2>/dev/null)
  [[ -z "$t" || "$t" == "null" ]] && t="rolling"
  printf '%s' "$t"
}

# True for blue-green / canary (the engine drives the deploy)
_rollout_is_progressive() {
  local t="${2:-}"
  [[ -z "$t" ]] && t=$(_rollout_type "$1")
  [[ "$t" == "blue-green" || "$t" == "canary" ]]
}

# ── Versions ──

# Label-safe copy of a version (k8s label value rules, max 63 chars)
_rollout_sanitize_label() {
  local v
  v=$(printf '%s' "$1" | LC_ALL=C sed -e 's/[^A-Za-z0-9._-]/-/g' -e 's/^[^A-Za-z0-9]*//' | cut -c1-63 | LC_ALL=C sed -e 's/[^A-Za-z0-9]*$//')
  [[ -z "$v" ]] && v="unknown"
  printf '%s' "$v"
}

# Version for this deploy: --version / MUSTER_DEPLOY_VERSION, IMAGE_TAG (not
# "latest"), exact git tag, short git SHA, else a timestamp.
# Usage: _rollout_resolve_version project_dir [override]
_rollout_resolve_version() {
  local dir="$1" v="${2:-${MUSTER_DEPLOY_VERSION:-}}"
  if [[ -z "$v" && -n "${IMAGE_TAG:-}" && "${IMAGE_TAG}" != "latest" ]]; then
    v="$IMAGE_TAG"
  fi
  if [[ -z "$v" ]] && git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    v=$(git -C "$dir" describe --tags --exact-match 2>/dev/null) || v=""
    [[ -z "$v" ]] && v=$(git -C "$dir" rev-parse --short=7 HEAD 2>/dev/null)
  fi
  [[ -z "$v" ]] && v="rev-$(date +%Y%m%d-%H%M%S)"
  printf '%s' "$v"
}

# Env lines handed to every deploy hook (KEY=VALUE per line).
# Rolling keeps IMAGE_TAG's old meaning (default "latest") so existing hooks
# and registries behave exactly as before; blue-green/canary need an
# immutable tag, so MUSTER_IMAGE_TAG defaults to the version there.
# Usage: _rollout_env_lines type version
_rollout_env_lines() {
  local type="$1" version="$2" label tag
  label=$(_rollout_sanitize_label "$version")
  if [[ "$type" == "rolling" ]]; then
    tag="${IMAGE_TAG:-latest}"
  else
    tag="${IMAGE_TAG:-}"
    [[ -z "$tag" || "$tag" == "latest" ]] && tag="$label"
  fi
  printf 'MUSTER_STRATEGY=%s\n' "$type"
  printf 'MUSTER_DEPLOY_VERSION=%s\n' "$label"
  printf 'MUSTER_IMAGE_TAG=%s\n' "$tag"
}

# ── Versions from history (non-Kubernetes services) ──

# Version info for a service without Kubernetes (from deploy history)
_rollout_history_snapshot() {
  local svc="$1" project_dir log ev
  project_dir="$(dirname "$CONFIG_FILE")"
  log="${project_dir}/.muster/logs/deploy-events.log"
  ev="null"
  if [[ -f "$log" ]]; then
    ev=$(jq -c --arg s "$svc" 'select(.service == $s and (.action == "deploy" or .action == "promote") and .status == "ok")' "$log" 2>/dev/null | tail -1)
    [[ -z "$ev" ]] && ev="null"
  fi
  jq -nc --argjson e "$ev" --arg t "$(_rollout_type "$svc")" '
    {strategy: $t, version: ($e.version // (if ($e.commit // "") != "" then $e.commit else null end)),
     image: ($e.image // null), revision: null, rollout: null,
     idle: {state: "idle", strategy: $t, traffic_mechanism: null,
            versions: (if $e then [{role: "stable", track: null, version: ($e.version // $e.commit // null),
                         image: ($e.image // null), revision: null, replicas: null, weight: 100,
                         effective_weight: 100, health: null}] else [] end)}}'
}

# ── Output (JSON events on stdout, human text on stderr in JSON mode) ──

_RO_JSON=false

_ro_emit() {
  [[ "$_RO_JSON" == "true" ]] && printf '%s\n' "$1"
  return 0
}

# Human line: stdout normally, stderr in JSON mode (stdout stays pure JSON)
_ro_say() {
  if [[ "$_RO_JSON" == "true" ]]; then
    printf '%b\n' "$1" >&2
  else
    printf '%b\n' "$1"
  fi
}
_ro_info() { _ro_say "  ${ACCENT}>${RESET} $1"; }
_ro_ok()   { _ro_say "  ${GREEN}✓${RESET} $1"; }
_ro_warn() { _ro_say "  ${YELLOW}!${RESET} $1"; }
_ro_err()  { _ro_say "  ${RED}x${RESET} $1"; }

# ── Interrupts ──
# deploy.sh's INT/TERM trap (and _run_with_timeout) set _MUSTER_CANCELLED;
# promote/abort install _ro_on_interrupt, which does the same. The engine
# polls _ro_interrupted at every checkpoint and restores traffic there,
# never inside the trap (bash 3.2 reaping bugs, see deploy.sh).
_ro_on_interrupt() {
  _MUSTER_CANCELLED=1
  trap '' INT TERM USR2
  if [[ -n "${_MUSTER_ACTIVE_PID:-}" ]]; then
    _kill_tree_hard "$_MUSTER_ACTIVE_PID"
  fi
}

_ro_interrupted() {
  [[ -n "${_MUSTER_CANCELLED:-}" ]]
}

# Sleep N seconds in 1s slices; returns 1 early when interrupted
_ro_sleep() {
  local n="${1:-0}" i=0
  while (( i < n )); do
    _ro_interrupted && return 1
    sleep 1
    i=$(( i + 1 ))
  done
  _ro_interrupted && return 1
  return 0
}

# ── Display ──

# Format seconds as 41s / 3m05s / 1h02m
_ro_fmt_dur() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  if (( s >= 3600 )); then
    printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  elif (( s >= 60 )); then
    printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%ds' "$s"
  fi
}

# Bar of `width` cells with `pct`% filled: [#####---------------]
_ro_bar() {
  local pct="${1:-0}" width="${2:-20}" fill bar=""
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  (( pct > 100 )) && pct=100
  fill=$(( (pct * width + 50) / 100 ))
  (( pct > 0 && fill == 0 )) && fill=1
  (( pct < 100 && fill == width )) && fill=$(( width - 1 ))
  local f e
  printf -v f '%*s' "$fill" ''
  printf -v e '%*s' "$(( width - fill ))" ''
  bar="${f// /#}${e// /-}"
  printf '[%s]' "$bar"
}

# Compact human display of a rollout object (status/rollout status/deploy).
#   api  CANARY · replicas                              step 2/4 · 3m05s
#     v1.4.1 stable 3/3   75%  [#####---------------]  25%  v1.4.2 canary 1/1
#     State: paused — next: 50% (muster promote api)
#     Gates: ok health  ok pod_stability
# Usage: _rollout_render svc rollout_json [indent]
_rollout_render() {
  local svc="$1" json="$2" ind="${3:-  }"
  [[ -z "$json" || "$json" == "null" ]] && return 0
  local hdr
  hdr=$(printf '%s' "$json" | jq -r '
    [ (.strategy // "rolling" | ascii_upcase),
      (.traffic_mechanism // ""),
      (.state // ""),
      (if .step != null and .total_steps != null then "step \(.step)/\(.total_steps)" else "" end),
      ((.elapsed_seconds // "") | tostring),
      (.next_gate.type // ""),
      ((.next_gate.next_weight // "") | tostring),
      ((.next_gate.remaining_seconds // "") | tostring),
      (.preview_service // ""),
      ((.weight // "") | tostring)
    ] | join("\u001f")' 2>/dev/null)
  local strat mech state stepstr elapsed gtype gnext grem preview weight
  IFS=$'\037' read -r strat mech state stepstr elapsed gtype gnext grem preview weight <<< "$hdr"
  local right="$stepstr"
  if [[ -n "$elapsed" ]]; then
    [[ -n "$right" ]] && right="${right} · "
    right="${right}$(_ro_fmt_dur "$elapsed")"
  fi
  printf '%b\n' "${ind}${BOLD}${svc}${RESET}  ${ACCENT}${strat}${RESET}${mech:+ ${DIM}· ${mech}${RESET}}${right:+   ${DIM}${right}${RESET}}"

  # Versions: stable on the left, candidate on the right
  local lines
  lines=$(printf '%s' "$json" | jq -r '
    .versions[]? | [ .role, (.track // ""), (.version // "?"), (.replicas.ready // 0 | tostring),
      (.replicas.desired // 0 | tostring), ((.effective_weight // .weight // 0) | tostring),
      ((.weight // "") | tostring) ] | join("\u001f")' 2>/dev/null)
  local s_line="" c_line="" s_pct=0 c_pct=0 c_target=""
  local role track ver rd ds eff wt
  while IFS=$'\037' read -r role track ver rd ds eff wt; do
    [[ -z "$role" ]] && continue
    if [[ "$role" == "stable" && -z "$s_line" ]]; then
      s_line="${ver} ${DIM}${track} ${rd}/${ds}${RESET}"
      s_pct="$eff"
    elif [[ -z "$c_line" ]]; then
      c_line="${ver} ${DIM}${track} ${rd}/${ds}${RESET}"
      c_pct="$eff"; c_target="$wt"
    fi
  done <<< "$lines"
  if [[ -n "$s_line" && -n "$c_line" ]]; then
    local note=""
    if [[ -n "$c_target" && "$c_target" != "$c_pct" && "$strat" == "CANARY" ]]; then
      note=" ${DIM}(target ${c_target}%)${RESET}"
    fi
    printf '%b\n' "${ind}  ${s_line}  $(printf '%3s' "$s_pct")%  $(_ro_bar "$c_pct")  $(printf '%3s' "$c_pct")%  ${c_line}${note}"
  elif [[ -n "$s_line" ]]; then
    printf '%b\n' "${ind}  ${s_line}  100%"
  elif [[ -n "$c_line" ]]; then
    printf '%b\n' "${ind}  ${c_line}"
  fi

  # State + next gate
  local st_text="$state"
  case "$gtype" in
    manual) st_text="${state} — next: ${gnext}% ${DIM}(muster promote ${svc} · muster abort ${svc})${RESET}" ;;
    promotion) st_text="${state} — preview is up ${DIM}(muster promote ${svc} · muster abort ${svc})${RESET}" ;;
    timer) st_text="${state} — next: ${gnext}% in $(_ro_fmt_dur "${grem:-0}")" ;;
  esac
  [[ -n "$state" ]] && printf '%b\n' "${ind}  ${DIM}State:${RESET} ${st_text}"
  [[ -n "$preview" ]] && printf '%b\n' "${ind}  ${DIM}Preview:${RESET} svc/${preview}"

  local gates
  gates=$(printf '%s' "$json" | jq -r '.last_analysis.checks[]? | "\(if .ok then "ok" else "FAIL" end) \(.name)"' 2>/dev/null | tr '\n' '|')
  if [[ -n "$gates" ]]; then
    local g out=""
    local IFS='|'
    for g in $gates; do
      [[ -z "$g" ]] && continue
      if [[ "$g" == ok* ]]; then
        out="${out}  ${GREEN}ok${RESET}${g#ok}"
      else
        out="${out}  ${RED}FAIL${RESET}${g#FAIL}"
      fi
    done
    printf '%b\n' "${ind}  ${DIM}Gates:${RESET}${out# }"
  fi
  return 0
}
