#!/usr/bin/env bash
# muster/lib/core/rollout_k8s.sh — Kubernetes blue-green, canary (replica
# ratio) and ReplicaSet version visibility. Zero CRDs: standard Deployments,
# Services and one ConfigMap per service (muster-rollout-<deployment>).
#
#   blue-green  <deploy>-blue / <deploy>-green, Service selector gets
#               muster.dev/track=<colour>; promote = one selector patch
#   canary      <deploy> (stable) + <deploy>-canary, both matched by the
#               Service; traffic follows the ready-replica ratio
#   rolling     the hook's own rollout; status shows every live ReplicaSet
#
# All kubectl calls go through _ro_kc (local, or over SSH for remote services).

source "$MUSTER_ROOT/lib/core/rollout.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"

# ── Context ──

_RO_SVC=""; _RO_NS=""; _RO_DEPLOY=""; _RO_KSVC=""; _RO_CONTAINER=""; _RO_CM=""
_RO_STRAT=""; _RO_TYPE=""; _RO_REMOTE=false; _RO_PROJECT_DIR=""
_RO_STATE=""
_RO_VER=""; _RO_VER_FULL=""
_RO_RESULT=""        # deployed | paused | aborted | failed | degraded
_RO_HOOK_FN=""       # deploy.sh callback that runs the deploy hook
_RO_NO_WAIT=false
_RO_INTERACTIVE=false
_RO_AN_FAILS=0

# Load a service's rollout context. Usage: _ro_ctx svc [type_override]
_ro_ctx() {
  local svc="$1" ovt="${2:-}"
  _RO_SVC="$svc"
  _RO_PROJECT_DIR="$(dirname "$CONFIG_FILE")"
  _RO_NS=$(_engine_k8s_namespace "$svc")
  _RO_DEPLOY=$(config_get ".services.${svc}.k8s.deployment" 2>/dev/null)
  [[ "$_RO_DEPLOY" == "null" ]] && _RO_DEPLOY=""
  _RO_KSVC=$(config_get ".services.${svc}.k8s.service" 2>/dev/null)
  [[ -z "$_RO_KSVC" || "$_RO_KSVC" == "null" ]] && _RO_KSVC="$_RO_DEPLOY"
  _RO_CONTAINER=$(config_get ".services.${svc}.k8s.container" 2>/dev/null)
  [[ "$_RO_CONTAINER" == "null" ]] && _RO_CONTAINER=""
  _RO_CM="muster-rollout-${_RO_DEPLOY}"
  _RO_STRAT=$(_rollout_strategy "$svc" "$ovt")
  _RO_TYPE=$(printf '%s' "$_RO_STRAT" | jq -r '.type')
  _RO_REMOTE=false
  remote_is_enabled "$svc" && _RO_REMOTE=true
  _RO_STATE=""
  [[ -n "$_RO_DEPLOY" ]]
}

# Strategy field (jq path without the dot): _ro_cfg analysis.max_failures
_ro_cfg() {
  printf '%s' "$_RO_STRAT" | jq -r ".$1 | if type == \"object\" or type == \"array\" then tojson else . end"
}

_ro_timeout() {
  local t
  t=$(config_get ".services.${_RO_SVC}.deploy_timeout" 2>/dev/null)
  [[ "$t" =~ ^[0-9]+$ ]] && (( t > 0 )) || t=120
  printf '%s' "$t"
}

# ── kubectl ──

_ro_kc() {
  if [[ "$_RO_REMOTE" == "true" ]]; then
    _remote_load_config "$_RO_SVC"
    _remote_build_opts
    local q
    q=$(printf '%q ' kubectl --request-timeout=30s "$@")
    # shellcheck disable=SC2086
    ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "$q"
  else
    kubectl --request-timeout=30s "$@"
  fi
}

_ro_get() { _ro_kc get "$1" "$2" -n "$_RO_NS" -o json 2>/dev/null; }
_ro_apply() { printf '%s' "$1" | _ro_kc apply -n "$_RO_NS" -f - >/dev/null 2>&1; }
_ro_scale() { _ro_kc scale "deployment/$1" -n "$_RO_NS" "--replicas=$2" >/dev/null 2>&1; }
_ro_set_selector() {
  _ro_kc patch service "$1" -n "$_RO_NS" --type=merge \
    -p "{\"spec\":{\"selector\":{\"muster.dev/track\":\"$2\"}}}" >/dev/null 2>&1
}

# Shared jq helpers for Deployments / ReplicaSets
_RO_JQ='
def ctr($c): (.spec.template.spec.containers // []) as $cs
  | ((if $c != "" then ([$cs[] | select(.name == $c)] | first) else null end) // $cs[0] // {});
def img($c): (ctr($c).image // "");
def tagof: if . == "" then ""
  elif test("@sha256:") then "sha256:" + (split("@sha256:")[1][0:7])
  else (split("/") | last | if test(":") then (split(":") | last) else "latest" end) end;
def ver($c): (.spec.template.metadata.labels["muster.dev/version"]
  // .spec.template.metadata.annotations["muster.dev/version"] // (img($c) | tagof));
def rev: ((.metadata.annotations["deployment.kubernetes.io/revision"] // "") | tonumber? // null);
def ready: (.status.readyReplicas // 0);
def desired: (.spec.replicas // 0);
def live($x): (["progressing","paused","awaiting_promotion","degraded"] | index($x)) != null;
def health: if desired == 0 then "scaled_down" elif ready >= desired then "healthy" else "progressing" end;
'

# Read one field from a Deployment JSON: version | image | replicas | ready | revision
_ro_dfield() {
  printf '%s' "$1" | jq -r --arg c "$_RO_CONTAINER" "${_RO_JQ}"'
    if $f == "version" then ver($c) elif $f == "image" then img($c)
    elif $f == "replicas" then desired elif $f == "ready" then ready
    elif $f == "revision" then (rev // "") else "" end' --arg f "$2"
}

# Clone a Deployment as a track (blue/green/canary) with `replicas` replicas.
# Usage: _ro_clone src_json name track version replicas
_ro_clone() {
  printf '%s' "$1" | jq -c --arg n "$2" --arg t "$3" --arg v "$4" --argjson r "$5" \
    --arg vf "${_RO_VER_FULL:-$4}" --arg svc "$_RO_KSVC" --arg at "$(_engine_now_iso)" '
    del(.status)
    | .metadata = {
        name: $n,
        namespace: .metadata.namespace,
        labels: ((.metadata.labels // {}) + {"muster.dev/service": $svc, "muster.dev/track": $t, "muster.dev/version": $v}),
        annotations: ((.metadata.annotations // {})
          | with_entries(select((.key | startswith("deployment.kubernetes.io/")) or (.key == "kubectl.kubernetes.io/last-applied-configuration") | not)))
      }
    | .spec.replicas = $r
    | .spec.selector.matchLabels = ((.spec.selector.matchLabels // {}) + {"muster.dev/track": $t})
    | .spec.template.metadata.labels = ((.spec.template.metadata.labels // {}) + {"muster.dev/track": $t, "muster.dev/version": $v, "muster.dev/service": $svc})
    | .spec.template.metadata.annotations = ((.spec.template.metadata.annotations // {}) + {"muster.dev/version-full": $vf, "muster.dev/deployed-at": $at})'
}

# Strip server-managed fields so a fetched object can be re-applied
_ro_clean() {
  printf '%s' "$1" | jq -c 'del(.status) | .metadata |= del(.resourceVersion, .uid, .creationTimestamp, .generation, .managedFields, .selfLink)'
}

# ── State (ConfigMap muster-rollout-<deployment>) ──

_ro_state_load() {
  local cm
  _RO_STATE=""
  cm=$(_ro_get configmap "$_RO_CM") || return 1
  _RO_STATE=$(printf '%s' "$cm" | jq -c '.data.state // empty | fromjson' 2>/dev/null)
  [[ -n "$_RO_STATE" ]]
}

_ro_state_save() {
  local doc
  doc=$(jq -nc --arg n "$_RO_CM" --arg ns "$_RO_NS" --arg svc "$_RO_KSVC" --arg st "$_RO_STATE" '{
    apiVersion: "v1", kind: "ConfigMap",
    metadata: {name: $n, namespace: $ns, labels: {"muster.dev/rollout": "true", "muster.dev/service": $svc}},
    data: {state: $st}}')
  _ro_apply "$doc" || _ro_warn "Couldn't save rollout state (ConfigMap ${_RO_CM}) — check RBAC for configmaps"
}

# Update the state with a jq filter and save. Usage: _ro_st_set [jq args] 'filter'
_ro_st_set() {
  local cur="$_RO_STATE"
  [[ -z "$cur" ]] && cur='{}'
  _RO_STATE=$(printf '%s' "$cur" | jq -c "$@") || return 1
  _ro_state_save
}

_ro_st() { printf '%s' "${_RO_STATE:-null}" | jq -r ".$1 // empty | if type == \"object\" or type == \"array\" then tojson else tostring end"; }

# Numeric state field with a default. Usage: _ro_stn field default
_ro_stn() {
  local v
  v=$(_ro_st "$1")
  [[ "$v" =~ ^-?[0-9]+$ ]] || v="$2"
  printf '%s' "$v"
}

# In-progress states block a new deploy until promote/abort
_ro_state_active() {
  case "$(_ro_st state)" in
    progressing|paused|awaiting_promotion|degraded) return 0 ;;
  esac
  return 1
}

_ro_now() { date +%s; }

# ── Waiting & pod checks ──

# Pod problems for a Deployment's pods: prints "reason<TAB>pod" for the first
# terminal problem, "restarts<TAB>N" when restarts exceed the limit, nothing
# when fine. Usage: _ro_pod_problem deploy_json max_restarts
_ro_pod_problem() {
  local sel pods
  sel=$(printf '%s' "$1" | jq -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")')
  [[ -z "$sel" ]] && return 0
  pods=$(_ro_kc get pods -n "$_RO_NS" -l "$sel" -o json 2>/dev/null) || return 0
  printf '%s' "$pods" | jq -r --argjson max "${2:-0}" '
    ["CrashLoopBackOff","ImagePullBackOff","ErrImagePull","ErrImageNeverPull","InvalidImageName",
     "CreateContainerConfigError","RunContainerError","OOMKilled"] as $bad
    | [.items[]? | .metadata.name as $p | (.status.containerStatuses // [])[]
        | {p: $p, r: (.state.waiting.reason // .state.terminated.reason // (if .lastState.terminated.reason == "OOMKilled" then "OOMKilled" else null end)),
           n: (.restartCount // 0)}] as $cs
    | ([$cs[] | select(.r != null and (.r as $r | $bad | index($r)))] | first) as $hit
    | if $hit then "\($hit.r)\t\($hit.p)"
      elif ([$cs[].n] | max // 0) > $max then "restarts\t\([$cs[].n] | max)"
      else empty end'
}

# Wait until a Deployment has all replicas ready. Fails fast on terminal pod
# errors. Returns 0 ready, 1 timeout, 2 pod failure, 130 interrupted.
# Usage: _ro_wait_ready deploy [timeout]
_RO_WAIT_DETAIL=""
_ro_wait_ready() {
  local dep="$1" timeout="${2:-$(_ro_timeout)}" t0 j d r u prob
  t0=$(_ro_now)
  _RO_WAIT_DETAIL=""
  while true; do
    _ro_interrupted && return 130
    j=$(_ro_get deployment "$dep")
    if [[ -n "$j" ]]; then
      d=$(printf '%s' "$j" | jq -r '.spec.replicas // 0')
      r=$(printf '%s' "$j" | jq -r '.status.readyReplicas // 0')
      u=$(printf '%s' "$j" | jq -r '.status.updatedReplicas // .status.readyReplicas // 0')
      (( d == 0 )) && return 0
      if (( r >= d && u >= d )); then
        return 0
      fi
      prob=$(_ro_pod_problem "$j" 999999)
      if [[ -n "$prob" ]]; then
        _RO_WAIT_DETAIL="${prob%%$'\t'*} (pod ${prob#*$'\t'})"
        return 2
      fi
    fi
    if (( $(_ro_now) - t0 >= timeout )); then
      _RO_WAIT_DETAIL="not ready after ${timeout}s (${r:-0}/${d:-?} ready)"
      return 1
    fi
    _ro_sleep 2 || return 130
  done
}

# ── Gates ──

_RO_AN_OK=true; _RO_AN_FATAL=false; _RO_AN_DETAIL=""; _RO_AN_CHECKS="[]"

# One analysis pass against a track's Deployment: pod_stability + health hook.
# Emits an "analysis" event and records last_analysis in the state.
# Usage: _ro_analyze track deploy step
_ro_analyze() {
  local track="$1" dep="$2" step="$3"
  local checks="[]" ok=true fatal=false detail=""
  if [[ "$(_ro_cfg analysis.pod_stability)" == "true" ]]; then
    local j prob maxr
    maxr=$(_ro_cfg analysis.max_restarts)
    j=$(_ro_get deployment "$dep")
    prob=$(_ro_pod_problem "$j" "$maxr")
    if [[ -n "$prob" ]]; then
      local why="${prob%%$'\t'*}" what="${prob#*$'\t'}"
      if [[ "$why" == "restarts" ]]; then
        detail="${what} restarts (max ${maxr})"
      else
        detail="${why} (pod ${what})"
      fi
      checks=$(printf '%s' "$checks" | jq -c --arg d "$detail" '. + [{name: "pod_stability", ok: false, detail: $d}]')
      ok=false; fatal=true
    else
      local rd ds
      rd=$(_ro_dfield "$j" ready); ds=$(_ro_dfield "$j" replicas)
      checks=$(printf '%s' "$checks" | jq -c --arg d "${rd}/${ds} ready, restarts <= ${maxr}" '. + [{name: "pod_stability", ok: true, detail: $d}]')
    fi
  fi
  local hh="${_RO_PROJECT_DIR}/.muster/hooks/${_RO_SVC}/health.sh"
  if [[ "$(_ro_cfg analysis.health_check)" == "true" && -x "$hh" \
        && "$(config_get ".services.${_RO_SVC}.health.enabled" 2>/dev/null)" != "false" ]]; then
    local env_lines="MUSTER_K8S_DEPLOYMENT=${dep}
MUSTER_TARGET_DEPLOYMENT=${dep}
MUSTER_K8S_NAMESPACE=${_RO_NS}
MUSTER_K8S_SERVICE=${_RO_SVC//_/-}
MUSTER_ROLLOUT_TRACK=${track}
MUSTER_STRATEGY=${_RO_TYPE}"
    local hrc=0
    if [[ "$_RO_REMOTE" == "true" ]]; then
      remote_exec_stdout "$_RO_SVC" "$hh" "$env_lines" >/dev/null 2>&1 || hrc=$?
    else
      (
        while IFS='=' read -r _k _v; do [[ -n "$_k" ]] && export "$_k=$_v"; done <<< "$env_lines"
        cd "$_RO_PROJECT_DIR" && _run_hook_with_timeout 30 "$hh"
      ) >/dev/null 2>&1 || hrc=$?
    fi
    if (( hrc == 0 )); then
      checks=$(printf '%s' "$checks" | jq -c '. + [{name: "health", ok: true, detail: "health.sh passed"}]')
    else
      checks=$(printf '%s' "$checks" | jq -c --arg d "health.sh exited ${hrc}" '. + [{name: "health", ok: false, detail: $d}]')
      ok=false
      [[ -z "$detail" ]] && detail="health.sh exited ${hrc}"
    fi
  fi
  _RO_AN_OK="$ok"; _RO_AN_FATAL="$fatal"; _RO_AN_DETAIL="$detail"; _RO_AN_CHECKS="$checks"
  if [[ "$ok" == "true" ]]; then _RO_AN_FAILS=0; else _RO_AN_FAILS=$(( _RO_AN_FAILS + 1 )); fi
  local status="pass"
  [[ "$ok" == "true" ]] || status="fail"
  local maxf
  maxf=$(_ro_cfg analysis.max_failures)
  _ro_st_set --arg st "$status" --arg at "$(_engine_now_iso)" --argjson c "$checks" \
    '.last_analysis = {status: $st, checked_at: $at, checks: $c}'
  _ro_ev --arg s "$_RO_SVC" --argjson step "${step:-0}" --arg st "$status" --argjson f "$_RO_AN_FAILS" \
    --argjson m "$maxf" --argjson c "$checks" --arg t "$track" \
    '{event: "analysis", service: $s, step: $step, track: $t, status: $st, consecutive_failures: $f, max_failures: $m, checks: $c}'
  [[ "$ok" == "true" ]]
}

# Gate: pass within max_failures attempts (pod failures fail at once).
# Returns 0 pass, 1 fail, 130 interrupted. Usage: _ro_gate track deploy step
_ro_gate() {
  local maxf iv
  maxf=$(_ro_cfg analysis.max_failures)
  iv=$(_ro_cfg analysis.interval_seconds)
  _RO_AN_FAILS=0
  while true; do
    _ro_interrupted && return 130
    if _ro_analyze "$1" "$2" "$3"; then return 0; fi
    _ro_interrupted && return 130
    [[ "$_RO_AN_FATAL" == "true" ]] && return 1
    (( _RO_AN_FAILS >= maxf )) && return 1
    _ro_sleep "$iv" || return 130
  done
}

# Timed bake: analyse every interval until `pause` seconds pass.
# Returns 0 pass, 1 fail, 130 interrupted. Usage: _ro_bake track deploy step pause
_ro_bake() {
  local track="$1" dep="$2" step="$3" pause="$4" maxf iv t0 left
  maxf=$(_ro_cfg analysis.max_failures)
  iv=$(_ro_cfg analysis.interval_seconds)
  t0=$(_ro_now)
  _RO_AN_FAILS=0
  while true; do
    _ro_interrupted && return 130
    if ! _ro_analyze "$track" "$dep" "$step"; then
      [[ "$_RO_AN_FATAL" == "true" ]] && return 1
      (( _RO_AN_FAILS >= maxf )) && return 1
    fi
    _ro_interrupted && return 130
    left=$(( pause - ($(_ro_now) - t0) ))
    (( left <= 0 )) && { [[ "$_RO_AN_OK" == "true" ]] && return 0; }
    (( left <= 0 )) && left=0
    (( left > iv )) && left="$iv"
    (( left == 0 )) && left=1
    _ro_sleep "$left" || return 130
  done
}

# ── Events ──

_ro_ev() {
  [[ "$_RO_JSON" == "true" ]] || return 0
  jq -nc "$@"
}

_ro_ev_step() {
  # Usage: _ro_ev_step step weight status
  _ro_ev --arg s "$_RO_SVC" --arg strat "$_RO_TYPE" --argjson step "$1" --argjson total "$(_ro_stn total_steps 0)" \
    --argjson w "$2" --arg st "$3" --arg v "$(_ro_st candidate_version)" --arg sv "$(_ro_st stable_version)" \
    --arg p "$(_ro_step_pause "$1")" --argjson el "$(( $(_ro_now) - $(_ro_stn started_epoch "$(_ro_now)") ))" \
    '{event: "rollout_step", service: $s, strategy: $strat, step: $step, total_steps: $total, weight: $w,
      status: $st, version: $v, stable_version: $sv,
      pause: ($p | if . == "" then null elif test("^[0-9]+$") then tonumber else . end), elapsed_seconds: $el}'
}

_ro_step_pause() {
  [[ "$_RO_TYPE" == "canary" && "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )) || return 0
  printf '%s' "$_RO_STATE" | jq -r --argjson i "$1" '.steps[$i - 1].pause // empty | tostring'
}

# Usage: _ro_ev_shift stable_w cand_w effective_cand_w
_ro_ev_shift() {
  _ro_ev --arg s "$_RO_SVC" --arg m "$(_ro_st traffic_mechanism)" --arg sv "$(_ro_st stable_version)" \
    --arg cv "$(_ro_st candidate_version)" --argjson sw "$1" --argjson cw "$2" --argjson ew "$3" \
    --arg pv "$(_ro_st preview_service)" \
    '{event: "traffic_shift", service: $s, mechanism: $m, stable_version: $sv, candidate_version: $cv,
      stable_weight: $sw, candidate_weight: $cw, effective_candidate_weight: $ew,
      preview_service: (if $pv == "" then null else $pv end)}'
}

_ro_duration() { echo $(( $(_ro_now) - $(_ro_stn started_epoch "$(_ro_now)") )); }

_ro_ev_promoted() {
  _ro_ev --arg s "$_RO_SVC" --arg strat "$_RO_TYPE" --arg v "$(_ro_st candidate_version)" \
    --arg pv "$(_ro_st stable_version)" --arg img "$(_ro_st candidate_image)" --argjson d "$(_ro_duration)" \
    '{event: "promoted", service: $s, strategy: $strat, version: $v, previous_version: $pv, image: $img, duration: $d}'
}

# Usage: _ro_ev_aborted reason detail
_ro_ev_aborted() {
  _ro_ev --arg s "$_RO_SVC" --arg strat "$_RO_TYPE" --arg r "$1" --arg dt "${2:-}" \
    --arg rv "$(_ro_st stable_version)" --arg av "$(_ro_st candidate_version)" --argjson d "$(_ro_duration)" \
    '{event: "aborted", service: $s, strategy: $strat, reason: $r, detail: $dt,
      restored_version: $rv, aborted_version: $av, duration: $d}'
}

_ro_history() {
  # Usage: _ro_history action status [version] [image]
  declare -F _history_log_event >/dev/null 2>&1 || source "$MUSTER_ROOT/lib/commands/history.sh"
  _history_log_event "$_RO_SVC" "$1" "$2" "$(_git_current_sha 2>/dev/null)" "${3:-$(_ro_st candidate_version)}" \
    "${4:-$(_ro_st candidate_image)}" "$_RO_TYPE" 2>/dev/null || true
}

# Print the current rollout (human mode only)
_ro_show() {
  [[ "$_RO_JSON" == "true" ]] && return 0
  local snap
  snap=$(_rollout_snapshot "$_RO_SVC" 2>/dev/null | jq -c '.rollout // .idle' 2>/dev/null)
  [[ -n "$snap" && "$snap" != "null" ]] && _rollout_render "$_RO_SVC" "$snap" "  "
}

# Cancelled mid-rollout: record it, emit cancelled, exit 130 (the EXIT trap
# of the calling command releases the locks). Usage: _ro_exit_cancelled
_ro_exit_cancelled() {
  _ro_history "deploy" "cancelled"
  _ro_ev --arg s "$_RO_SVC" --arg sv "$(_ro_st stable_version)" \
    '{event: "cancelled", service: $s, safe_version: $sv, exit_code: 130}'
  [[ "$_RO_JSON" == "true" ]] || printf '\n%b\n' "  ${YELLOW}!${RESET} Rollout cancelled"
  exit 130
}

# ── Deploy entry point ──

# Run a blue-green / canary deploy for one service. The deploy hook runs via
# $_RO_HOOK_FN with env lines targeting the candidate Deployment.
# Sets _RO_RESULT. Returns 0 deployed/paused, 1 failed/aborted.
# Usage: _rollout_deploy svc version [type_override]
_rollout_deploy() {
  local svc="$1"
  _RO_VER=$(_rollout_sanitize_label "$2")
  _RO_VER_FULL="$2"
  _RO_RESULT=""
  _ro_ctx "$svc" "${3:-}" || { _ro_err "${svc}: k8s.deployment missing in muster.json"; _RO_RESULT="failed"; return 1; }
  if ! has_cmd jq; then _ro_err "jq is required for ${_RO_TYPE} deploys"; _RO_RESULT="failed"; return 1; fi
  if [[ "$_RO_REMOTE" != "true" ]] && ! has_cmd kubectl; then
    _ro_err "kubectl not found — ${_RO_TYPE} deploys drive the cluster directly"; _RO_RESULT="failed"; return 1
  fi
  if [[ "$_RO_REMOTE" == "true" ]]; then
    _remote_load_config "$svc"
    if [[ "${_REMOTE_CLOUD:-}" == "true" || "${_REMOTE_AUTH_METHOD:-}" == "password" ]]; then
      _ro_err "${_RO_TYPE} over Fleet Cloud or password SSH isn't supported yet — use key-based SSH or run muster on the cluster host"
      _RO_RESULT="failed"; return 1
    fi
  fi
  case "$_RO_TYPE" in
    blue-green) _ro_bg_deploy ;;
    canary) _ro_canary_deploy ;;
    *) _ro_err "Unknown strategy ${_RO_TYPE}"; _RO_RESULT="failed"; return 1 ;;
  esac
}

# Run the deploy hook against the candidate. Usage: _ro_run_hook track deploy
_ro_run_hook() {
  local track="$1" dep="$2"
  [[ -z "$_RO_HOOK_FN" ]] && return 0
  local env_lines="MUSTER_STRATEGY_TRAFFIC=$(_ro_cfg traffic)
MUSTER_ROLLOUT_TRACK=${track}
MUSTER_TARGET_DEPLOYMENT=${dep}
MUSTER_K8S_DEPLOYMENT=${dep}
MUSTER_K8S_BASE_DEPLOYMENT=${_RO_DEPLOY}"
  [[ -n "$_RO_CONTAINER" ]] && env_lines="${env_lines}
MUSTER_K8S_CONTAINER=${_RO_CONTAINER}"
  "$_RO_HOOK_FN" "$env_lines"
}

# New state document. Usage: _ro_state_init stable_dep cand_dep stable_ver stable_img total_steps extra_json
_ro_state_init() {
  _RO_STATE=$(jq -nc --arg svc "$_RO_SVC" --arg strat "$_RO_TYPE" --arg mech "$(_ro_cfg traffic)" \
    --arg sd "$1" --arg cd "$2" --arg sv "$3" --arg si "$4" --arg cv "$_RO_VER" --arg cvf "$_RO_VER_FULL" \
    --argjson total "$5" --argjson extra "$6" --arg at "$(_engine_now_iso)" --argjson now "$(_ro_now)" \
    --arg by "$(_deploy_identity 2>/dev/null || whoami)" --arg ns "$_RO_NS" --arg base "$_RO_DEPLOY" '
    {service: $svc, strategy: $strat, traffic_mechanism: $mech, state: "progressing",
     namespace: $ns, deployment: $base, step: 0, total_steps: $total, weight: 0, effective_weight: 0,
     stable_deployment: $sd, candidate_deployment: $cd,
     stable_version: $sv, stable_image: $si, candidate_version: $cv, candidate_version_full: $cvf,
     candidate_image: "", started_at: $at, started_epoch: $now, step_started_epoch: $now,
     deployed_by: $by, last_analysis: null, reason: null} + $extra')
  _ro_state_save
}

# Refuse to start over a rollout that's still in progress
# Usage: _rollout_check_idle svc  (returns 1 + message when busy)
_rollout_check_idle() {
  _ro_ctx "$1" || return 0
  _ro_state_load || return 0
  if _ro_state_active; then
    local st w
    st=$(_ro_st state); w=$(_ro_st weight)
    _RO_BUSY_MSG="${1} has a ${_RO_TYPE} rollout in progress (${st}${w:+ at ${w}%}) — run 'muster promote ${1}' or 'muster abort ${1}' (or deploy --force to abort it first)"
    return 1
  fi
  return 0
}

# Offer next actions after a pause (interactive TTY only).
# Returns 0 promote-next, 2 promote-full, 3 abort, 1 keep paused.
_ro_menu() {
  [[ "$_RO_INTERACTIVE" == "true" ]] || return 1
  declare -F menu_select >/dev/null 2>&1 || source "$MUSTER_ROOT/lib/tui/menu.sh"
  local label_next="$1"
  echo ""
  if [[ "$_RO_TYPE" == "canary" ]]; then
    menu_select "Rollout paused. What now?" "$label_next" "Promote to 100%" "Abort (restore $(_ro_st stable_version))" "Keep paused (decide later)"
  else
    menu_select "Preview is up. What now?" "Promote (switch traffic)" "Abort (keep $(_ro_st stable_version))" "Keep preview (decide later)"
  fi
  case "$MENU_RESULT" in
    "$label_next"|"Promote (switch traffic)") return 0 ;;
    "Promote to 100%") return 2 ;;
    Abort*) return 3 ;;
  esac
  return 1
}

# ══════════════════════════════════════════════════════════════
# Blue-green
# ══════════════════════════════════════════════════════════════

_ro_other_colour() { [[ "$1" == "blue" ]] && echo green || echo blue; }

# Adopt an existing single Deployment: clone it as <deploy>-blue, wait for it,
# point the Service at track=blue, scale the original to 0 (kept for audit).
_ro_bg_bootstrap() {
  local base blue reps ver
  base=$(_ro_get deployment "$_RO_DEPLOY") || { _ro_err "Deployment ${_RO_DEPLOY} not found in ${_RO_NS}"; return 1; }
  reps=$(_ro_dfield "$base" replicas); (( reps < 1 )) && reps=1
  ver=$(_ro_dfield "$base" version)
  _ro_info "First blue-green deploy: adopting ${_RO_DEPLOY} as ${_RO_DEPLOY}-blue (zero downtime)"
  if blue=$(_ro_get deployment "${_RO_DEPLOY}-blue"); then
    _ro_scale "${_RO_DEPLOY}-blue" "$reps"
  else
    blue=$(_RO_VER_FULL="$ver" _ro_clone "$base" "${_RO_DEPLOY}-blue" blue "$ver" "$reps")
    _ro_apply "$blue" || { _ro_err "Couldn't create ${_RO_DEPLOY}-blue"; return 1; }
  fi
  local wrc=0
  _ro_wait_ready "${_RO_DEPLOY}-blue" || wrc=$?
  (( wrc == 130 )) && return 130
  (( wrc != 0 )) && { _ro_err "${_RO_DEPLOY}-blue didn't become ready: ${_RO_WAIT_DETAIL}"; return 1; }
  _ro_set_selector "$_RO_KSVC" blue || { _ro_err "Couldn't patch Service ${_RO_KSVC}"; return 1; }
  _ro_scale "$_RO_DEPLOY" 0
  _ro_ok "Service ${_RO_KSVC} now selects muster.dev/track=blue (${_RO_DEPLOY} scaled to 0)"
  return 0
}

_ro_bg_preview() {
  [[ "$(_ro_cfg preview.enabled)" == "true" ]] || return 0
  local cand="$1" name base doc
  name=$(_ro_cfg preview.service)
  [[ -z "$name" ]] && name="${_RO_KSVC}-preview"
  base=$(_ro_get service "$_RO_KSVC") || return 0
  doc=$(printf '%s' "$base" | jq -c --arg n "$name" --arg t "$cand" --arg svc "$_RO_KSVC" '{
    apiVersion: "v1", kind: "Service",
    metadata: {name: $n, namespace: .metadata.namespace, labels: {"muster.dev/service": $svc, "muster.dev/preview": "true"}},
    spec: {type: "ClusterIP", ports: [(.spec.ports // [])[] | del(.nodePort)],
           selector: ((.spec.selector // {}) + {"muster.dev/track": $t})}}')
  if _ro_apply "$doc"; then
    _ro_st_set --arg p "$name" '.preview_service = $p'
  else
    _ro_warn "Couldn't create preview Service ${name}"
  fi
}

_ro_bg_deploy() {
  local svcj active cand adep cdep aj reps sv si
  # Old colour kept warm past keep_old_seconds? Scale it down now.
  if _ro_state_load; then _ro_bg_cleanup_due; fi
  _RO_STATE=""
  svcj=$(_ro_get service "$_RO_KSVC") || { _ro_err "Service ${_RO_KSVC} not found in ${_RO_NS} (set k8s.service in muster.json)"; _RO_RESULT="failed"; return 1; }
  active=$(printf '%s' "$svcj" | jq -r '.spec.selector["muster.dev/track"] // empty')
  if [[ -z "$active" ]]; then
    local brc=0
    _ro_bg_bootstrap || brc=$?
    (( brc == 130 )) && _ro_exit_cancelled
    (( brc != 0 )) && { _RO_RESULT="failed"; return 1; }
    active=blue
  fi
  cand=$(_ro_other_colour "$active")
  adep="${_RO_DEPLOY}-${active}"; cdep="${_RO_DEPLOY}-${cand}"
  aj=$(_ro_get deployment "$adep") || { _ro_err "Active Deployment ${adep} not found"; _RO_RESULT="failed"; return 1; }
  reps=$(_ro_dfield "$aj" replicas); (( reps < 1 )) && reps=1
  sv=$(_ro_dfield "$aj" version); si=$(_ro_dfield "$aj" image)

  _ro_apply "$(_ro_clone "$aj" "$cdep" "$cand" "$_RO_VER" 0)" || { _ro_err "Couldn't create ${cdep}"; _RO_RESULT="failed"; return 1; }
  _ro_state_init "$adep" "$cdep" "$sv" "$si" 2 \
    "$(jq -nc --arg a "$active" --arg c "$cand" --argjson r "$reps" '{active_track: $a, candidate_track: $c, replicas: $r}')"
  _ro_info "Blue-green: ${sv} live on ${active}; deploying ${_RO_VER} to ${cand} (0% traffic)"
  _ro_ev_step 0 0 starting

  local rc=0
  _ro_run_hook "$cand" "$cdep" || rc=$?
  if _ro_interrupted; then
    _ro_scale "$cdep" 0
    _ro_st_set '.state = "aborted" | .reason = "interrupted"'
    _ro_ev_aborted interrupted "cancelled while deploying the candidate"
    _ro_exit_cancelled
  fi
  if (( rc != 0 )); then
    _ro_bg_fail_precut deploy_failed "deploy hook exited ${rc}"
    return 1
  fi
  _ro_st_set --arg i "$(_ro_dfield "$(_ro_get deployment "$cdep")" image)" '.candidate_image = $i'

  _ro_scale "$cdep" "$reps"
  rc=0; _ro_wait_ready "$cdep" || rc=$?
  (( rc == 130 )) && { _ro_bg_interrupt_precut; }
  if (( rc != 0 )); then
    _ro_bg_fail_precut health_failed "${cdep}: ${_RO_WAIT_DETAIL}"
    return 1
  fi
  _ro_bg_preview "$cand"

  rc=0; _ro_gate "$cand" "$cdep" 1 || rc=$?
  (( rc == 130 )) && { _ro_bg_interrupt_precut; }
  if (( rc != 0 )); then
    if [[ "$(_ro_cfg auto_rollback)" == "true" ]]; then
      _ro_bg_fail_precut analysis_failed "$_RO_AN_DETAIL"
    else
      _ro_st_set '.state = "degraded" | .reason = "analysis_failed"'
      _ro_err "Candidate failed its gates (${_RO_AN_DETAIL}); left at 0% traffic for inspection (muster abort ${_RO_SVC})"
      _RO_RESULT="degraded"
    fi
    return 1
  fi

  _ro_st_set --argjson now "$(_ro_now)" '.state = "awaiting_promotion" | .step = 1 | .step_started_epoch = $now'
  _ro_ev_step 1 0 awaiting_promotion
  if [[ "$(_ro_cfg auto_promote)" == "true" ]]; then
    _ro_bg_promote
    return $?
  fi
  _ro_ok "${_RO_VER} is up on ${cand} with 0% traffic"
  _ro_show
  if [[ "$_RO_NO_WAIT" != "true" ]]; then
    local m=0
    _ro_menu "Promote (switch traffic)" || m=$?
    case "$m" in
      0|2) _ro_bg_promote; return $? ;;
      3) _rollout_abort_current user_abort; _RO_RESULT="aborted"; return 1 ;;
    esac
  fi
  local pv
  pv=$(_ro_st preview_service)
  if [[ -n "$pv" ]]; then
    local pport
    pport=$(_ro_get service "$pv" | jq -r '.spec.ports[0].port // 80' 2>/dev/null)
    _ro_say "    ${DIM}Try it: kubectl port-forward svc/${pv} 8080:${pport:-80} -n ${_RO_NS}${RESET}"
  fi
  _ro_say "    ${DIM}Then: muster promote ${_RO_SVC}   or   muster abort ${_RO_SVC}${RESET}"
  _RO_RESULT="paused"
  return 0
}

# Candidate failed before cutover: production never changed.
_ro_bg_fail_precut() {
  local reason="$1" detail="$2"
  _ro_scale "$(_ro_st candidate_deployment)" 0
  _ro_st_set --arg r "$reason" --arg d "$detail" '.state = "aborted" | .reason = $r | .detail = $d'
  _ro_err "${_RO_VER} not promoted: ${detail} — production stays on $(_ro_st stable_version)"
  _ro_ev_aborted "$reason" "$detail"
  _ro_history "deploy" "failed"
  _RO_RESULT="aborted"
}

# Ctrl+C before cutover. on_interrupt=pause keeps a healthy candidate up
# (awaiting promotion); otherwise the candidate is scaled to 0.
_ro_bg_interrupt_precut() {
  if [[ "$(_ro_cfg on_interrupt)" == "pause" && "$_RO_AN_OK" == "true" && "$(_ro_st last_analysis)" != "" ]]; then
    _ro_st_set '.state = "awaiting_promotion" | .step = 1'
    _ro_warn "Preview kept at 0% traffic — run 'muster promote ${_RO_SVC}' or 'muster abort ${_RO_SVC}'"
  else
    _ro_scale "$(_ro_st candidate_deployment)" 0
    _ro_st_set '.state = "aborted" | .reason = "interrupted"'
    _ro_ev_aborted interrupted "cancelled before cutover"
  fi
  _ro_exit_cancelled
}

# Switch the Service to the candidate colour. Usage: _ro_bg_promote
_ro_bg_promote() {
  local cand active cdep adep
  cand=$(_ro_st candidate_track); active=$(_ro_st active_track)
  cdep=$(_ro_st candidate_deployment); adep=$(_ro_st stable_deployment)
  _ro_ev_step 2 100 active
  if ! _ro_set_selector "$_RO_KSVC" "$cand"; then
    _ro_err "Couldn't patch Service ${_RO_KSVC}"
    _RO_RESULT="failed"; return 1
  fi
  _ro_st_set --argjson now "$(_ro_now)" '.state = "progressing" | .step = 2 | .weight = 100 | .effective_weight = 100 | .cutover_epoch = $now'
  _ro_ev_shift 0 100 100
  _ro_ok "Traffic switched: Service ${_RO_KSVC} → ${cand} ($(_ro_st candidate_version))"

  local rc=0
  if _ro_interrupted; then rc=130; else _ro_gate "$cand" "$cdep" 2 || rc=$?; fi
  if (( rc != 0 )); then
    local why="analysis_failed" detail="$_RO_AN_DETAIL"
    (( rc == 130 )) && { why="interrupted"; detail="cancelled during post-cutover checks"; }
    if [[ "$(_ro_cfg auto_rollback)" == "true" || "$why" == "interrupted" ]]; then
      _ro_set_selector "$_RO_KSVC" "$active"
      _ro_scale "$cdep" 0
      _ro_st_set --arg r "$why" --arg d "$detail" '.state = "aborted" | .reason = $r | .detail = $d | .weight = 0 | .effective_weight = 0'
      _ro_ev_shift 100 0 0
      _ro_err "Post-cutover check failed — traffic switched back to ${active} ($(_ro_st stable_version))"
      _ro_ev_aborted "$why" "$detail"
      _ro_history "deploy" "failed"
      _RO_RESULT="aborted"
      (( rc == 130 )) && _ro_exit_cancelled
    else
      _ro_st_set '.state = "degraded" | .reason = "analysis_failed"'
      _ro_err "Post-cutover check failed (${detail}); traffic stays on ${cand} — 'muster abort ${_RO_SVC}' switches back"
      _RO_RESULT="degraded"
    fi
    return 1
  fi

  # Verified. A Ctrl+C from here on just skips the old-colour cleanup.
  local drain keep
  drain=$(_ro_cfg drain_seconds); keep=$(_ro_cfg keep_old_seconds)
  if _ro_sleep "$drain"; then
    if [[ "$keep" == "0" ]]; then
      _ro_scale "$adep" 0
    elif [[ "$keep" =~ ^[0-9]+$ ]]; then
      _ro_st_set --argjson t "$(( $(_ro_now) + keep ))" '.cleanup_after_epoch = $t'
    fi
  fi
  _ro_bg_complete
  _ro_interrupted && _ro_exit_cancelled
  return 0
}

_ro_bg_complete() {
  _ro_ev_promoted
  _ro_history "promote" "ok"
  _ro_st_set '.state = "complete" | .previous_track = .active_track | .active_track = .candidate_track
    | .previous_version = .stable_version | .previous_image = .stable_image | .previous_deployment = .stable_deployment
    | .stable_version = .candidate_version | .stable_image = .candidate_image | .stable_deployment = .candidate_deployment
    | .reason = null'
  _ro_ok "Promoted ${_RO_SVC} to $(_ro_st candidate_version)"
  _RO_RESULT="deployed"
}

# Old colour still warm past keep_old_seconds? Scale it to 0.
_ro_bg_cleanup_due() {
  local due
  due=$(_ro_st cleanup_after_epoch)
  [[ -n "$due" && "$(_ro_st state)" == "complete" ]] || return 0
  (( $(_ro_now) >= due )) || return 0
  _ro_scale "$(_ro_st previous_deployment)" 0
  _ro_st_set 'del(.cleanup_after_epoch)'
}

# Completed blue-green: switch back to the previous colour (warm = instant;
# cold = scale it up and wait first).
_ro_bg_rollback() {
  local prev cur pdep cdep reps pj rc=0
  prev=$(_ro_st previous_track); cur=$(_ro_st active_track)
  pdep=$(_ro_st previous_deployment); cdep="${_RO_DEPLOY}-${cur}"
  [[ -n "$prev" && -n "$pdep" ]] || { _ro_err "No previous colour recorded for ${_RO_SVC}"; return 1; }
  pj=$(_ro_get deployment "$pdep") || { _ro_err "Deployment ${pdep} not found"; return 1; }
  reps=$(_ro_st replicas); [[ "$reps" =~ ^[0-9]+$ ]] && (( reps > 0 )) || reps=1
  if (( $(_ro_dfield "$pj" replicas) < reps )); then
    _ro_info "Scaling ${pdep} back up to ${reps}"
    _ro_scale "$pdep" "$reps"
  fi
  _ro_wait_ready "$pdep" || rc=$?
  (( rc != 0 )) && { _ro_err "${pdep} isn't ready (${_RO_WAIT_DETAIL}) — traffic unchanged"; return 1; }
  _ro_set_selector "$_RO_KSVC" "$prev" || { _ro_err "Couldn't patch Service ${_RO_KSVC}"; return 1; }
  _ro_ok "Traffic switched back: Service ${_RO_KSVC} → ${prev} ($(_ro_st previous_version))"
  _ro_sleep "$(_ro_cfg drain_seconds)" || true
  _ro_scale "$cdep" 0
  _ro_st_set '.state = "rolled_back"
    | {a: .active_track, p: .previous_track, sv: .stable_version, si: .stable_image, pv: .previous_version, pi: .previous_image} as $o
    | .active_track = $o.p | .previous_track = $o.a
    | .stable_version = $o.pv | .stable_image = $o.pi
    | .previous_version = $o.sv | .previous_image = $o.si
    | .candidate_version = $o.sv | .candidate_image = $o.si
    | .stable_deployment = (.deployment + "-" + $o.p) | .previous_deployment = (.deployment + "-" + $o.a)'
  _ro_ev_shift 100 0 0
  _ro_history "rollback" "ok" "$(_ro_st stable_version)" "$(_ro_st stable_image)"
  return 0
}

# ══════════════════════════════════════════════════════════════
# Canary (replica ratio)
# ══════════════════════════════════════════════════════════════

_ro_canary_deploy() {
  local sj orig sv si cdep
  sj=$(_ro_get deployment "$_RO_DEPLOY") || { _ro_err "Deployment ${_RO_DEPLOY} not found in ${_RO_NS}"; _RO_RESULT="failed"; return 1; }
  orig=$(_ro_dfield "$sj" replicas); (( orig < 1 )) && orig=1
  sv=$(_ro_dfield "$sj" version); si=$(_ro_dfield "$sj" image)
  cdep="${_RO_DEPLOY}-canary"
  _ro_apply "$(_ro_clone "$sj" "$cdep" canary "$_RO_VER" 0)" || { _ro_err "Couldn't create ${cdep}"; _RO_RESULT="failed"; return 1; }
  local steps total
  steps=$(_ro_cfg steps)
  total=$(printf '%s' "$steps" | jq 'length')
  _ro_state_init "$_RO_DEPLOY" "$cdep" "$sv" "$si" "$total" \
    "$(jq -nc --argjson st "$steps" --argjson o "$orig" '{steps: $st, stable_replicas_original: $o, active_track: "stable", candidate_track: "canary"}')"
  _ro_info "Canary: ${sv} stable (${orig} replicas); deploying ${_RO_VER} to ${cdep} (0% traffic)"
  _ro_ev_step 0 0 starting

  local rc=0
  _ro_run_hook canary "$cdep" || rc=$?
  if _ro_interrupted; then
    _ro_scale "$cdep" 0
    _ro_st_set '.state = "aborted" | .reason = "interrupted"'
    _ro_ev_aborted interrupted "cancelled while deploying the canary"
    _ro_exit_cancelled
  fi
  if (( rc != 0 )); then
    _ro_scale "$cdep" 0
    _ro_st_set --arg d "deploy hook exited ${rc}" '.state = "aborted" | .reason = "deploy_failed" | .detail = $d'
    _ro_err "${_RO_VER} not rolled out: deploy hook exited ${rc} — production stays on ${sv}"
    _ro_ev_aborted deploy_failed "deploy hook exited ${rc}"
    _ro_history "deploy" "failed"
    _RO_RESULT="aborted"
    return 1
  fi
  _ro_st_set --arg i "$(_ro_dfield "$(_ro_get deployment "$cdep")" image)" '.candidate_image = $i'
  _ro_canary_run 1
}

# Replica counts for weight W: prints "canary stable"
_ro_canary_counts() {
  local w="$1" orig="$2" total c s
  total="$orig"; (( total < 2 )) && total=2
  c=$(( (total * w + 99) / 100 )); (( c < 1 )) && c=1
  s=$(( total - c )); (( s < 1 )) && s=1
  printf '%s %s' "$c" "$s"
}

# Shift traffic to W% by replica ratio. Returns 0, 1 (not ready), 2 (pod
# failure), 130 (interrupted).
_ro_canary_shift() {
  local w="$1" orig cdep counts c s rc=0
  orig=$(_ro_st stable_replicas_original); cdep=$(_ro_st candidate_deployment)
  counts=$(_ro_canary_counts "$w" "$orig"); c="${counts% *}"; s="${counts#* }"
  _ro_scale "$cdep" "$c"
  _ro_wait_ready "$cdep" || rc=$?
  (( rc != 0 )) && return $rc
  _ro_scale "$_RO_DEPLOY" "$s"
  _ro_wait_ready "$_RO_DEPLOY" || rc=$?
  (( rc != 0 )) && return $rc
  local cr sr eff
  cr=$(_ro_dfield "$(_ro_get deployment "$cdep")" ready)
  sr=$(_ro_dfield "$(_ro_get deployment "$_RO_DEPLOY")" ready)
  eff=0
  (( cr + sr > 0 )) && eff=$(( (cr * 100 + (cr + sr) / 2) / (cr + sr) ))
  _ro_st_set --argjson w "$w" --argjson e "$eff" '.weight = $w | .effective_weight = $e'
  _ro_ev_shift "$(( 100 - w ))" "$w" "$eff"
  return 0
}

# Run steps from index `from` (1-based) until a manual pause or the end.
_ro_canary_run() {
  local i="$1" total
  total=$(_ro_st total_steps)
  while (( i <= total )); do
    local w p rc=0
    w=$(printf '%s' "$_RO_STATE" | jq -r --argjson i "$i" '.steps[$i - 1].weight')
    p=$(printf '%s' "$_RO_STATE" | jq -r --argjson i "$i" '.steps[$i - 1].pause | tostring')
    if (( w >= 100 )); then
      _ro_canary_final
      return $?
    fi
    _ro_ev_step "$i" "$w" active
    _ro_canary_shift "$w" || rc=$?
    (( rc == 130 )) && _ro_canary_interrupt
    if (( rc != 0 )); then
      _ro_canary_fail health_failed "${_RO_WAIT_DETAIL:-not ready}"
      return 1
    fi
    _ro_st_set --argjson i "$i" --argjson now "$(_ro_now)" '.step = $i | .state = "progressing" | .step_started_epoch = $now'
    _ro_show

    if [[ "$p" == "manual" || ( "$_RO_NO_WAIT" == "true" && "$i" == "$1" ) ]]; then
      _ro_gate canary "$(_ro_st candidate_deployment)" "$i" || rc=$?
    elif [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then
      _ro_info "Baking at ${w}% for $(_ro_fmt_dur "$p")"
      _ro_bake canary "$(_ro_st candidate_deployment)" "$i" "$p" || rc=$?
    else
      _ro_gate canary "$(_ro_st candidate_deployment)" "$i" || rc=$?
    fi
    (( rc == 130 )) && _ro_canary_interrupt
    if (( rc != 0 )); then
      _ro_canary_fail analysis_failed "$_RO_AN_DETAIL"
      return 1
    fi

    if [[ "$p" == "manual" || ( "$_RO_NO_WAIT" == "true" && "$i" == "$1" ) ]]; then
      _ro_st_set '.state = "paused"'
      _ro_ev_step "$i" "$w" paused
      local nw
      nw=$(printf '%s' "$_RO_STATE" | jq -r --argjson i "$i" '.steps[$i].weight // 100')
      if [[ "$_RO_NO_WAIT" != "true" ]]; then
        local m=0
        _ro_menu "Promote to ${nw}%" || m=$?
        case "$m" in
          0) i=$(( i + 1 )); continue ;;
          2) _ro_canary_final; return $? ;;
          3) _rollout_abort_current user_abort; _RO_RESULT="aborted"; return 1 ;;
        esac
      fi
      _ro_ok "Paused at ${w}% — next: ${nw}% (muster promote ${_RO_SVC}) or muster abort ${_RO_SVC}"
      _RO_RESULT="paused"
      return 0
    fi
    i=$(( i + 1 ))
  done
  _ro_canary_final
}

# Gate failure during a step: auto-rollback (default) or leave it degraded.
_ro_canary_fail() {
  local reason="$1" detail="$2"
  if [[ "$(_ro_cfg auto_rollback)" == "true" ]]; then
    _ro_err "Canary failed: ${detail} — rolling back"
    _ro_canary_restore "$reason" "$detail"
    _ro_history "deploy" "failed"
    _RO_RESULT="aborted"
  else
    _ro_st_set --arg r "$reason" --arg d "$detail" '.state = "degraded" | .reason = $r | .detail = $d'
    _ro_err "Canary failed: ${detail} — traffic left at $(_ro_st weight)% for inspection (muster abort ${_RO_SVC})"
    _RO_RESULT="degraded"
  fi
}

# Ctrl+C with traffic split: restore (default) or pause when on_interrupt=pause
# and the canary was passing.
_ro_canary_interrupt() {
  if [[ "$(_ro_cfg on_interrupt)" == "pause" && "$_RO_AN_OK" == "true" && "$(_ro_st weight)" != "0" ]]; then
    _ro_st_set '.state = "paused"'
    _ro_warn "Rollout paused at $(_ro_st weight)% — run 'muster promote ${_RO_SVC}' or 'muster abort ${_RO_SVC}'"
  else
    _ro_canary_restore interrupted "cancelled at $(_ro_st weight)%"
  fi
  _ro_exit_cancelled
}

# Back to 100% stable: stable to its original replicas, canary to 0.
_ro_canary_restore() {
  local reason="$1" detail="${2:-}" orig cdep
  orig=$(_ro_st stable_replicas_original); cdep=$(_ro_st candidate_deployment)
  [[ "$orig" =~ ^[0-9]+$ ]] || orig=1
  _ro_scale "$_RO_DEPLOY" "$orig"
  local _was="${_MUSTER_CANCELLED:-}"
  _MUSTER_CANCELLED=""
  _ro_wait_ready "$_RO_DEPLOY" || _ro_warn "${_RO_DEPLOY} not fully ready yet (${_RO_WAIT_DETAIL})"
  _MUSTER_CANCELLED="$_was"
  _ro_scale "$cdep" 0
  _ro_st_set --arg r "$reason" --arg d "$detail" '.state = "aborted" | .reason = $r | .detail = $d | .weight = 0 | .effective_weight = 0'
  _ro_ev_shift 100 0 0
  _ro_ok "Traffic restored to 100% $(_ro_st stable_version)"
  _ro_ev_aborted "$reason" "$detail"
}

# Promote the canary's image to the stable Deployment, then retire the canary.
_ro_canary_final() {
  local cdep sj cj orig total newj rc=0
  cdep=$(_ro_st candidate_deployment); orig=$(_ro_st stable_replicas_original); total=$(_ro_st total_steps)
  [[ "$orig" =~ ^[0-9]+$ ]] || orig=1
  sj=$(_ro_get deployment "$_RO_DEPLOY"); cj=$(_ro_get deployment "$cdep")
  _ro_ev_step "$total" 100 active
  _ro_info "Promoting $(_ro_st candidate_version) to ${_RO_DEPLOY}"
  newj=$(jq -nc --argjson s "$(_ro_clean "$sj")" --argjson c "$cj" --argjson r "$orig" \
    --arg v "$(_ro_st candidate_version)" --arg vf "$(_ro_st candidate_version_full)" '
    ($c.spec.template.spec.containers // []) as $cc
    | $s | .spec.replicas = $r
    | .spec.template.spec.containers = [(.spec.template.spec.containers // [])[] | . as $x
        | (([$cc[] | select(.name == $x.name)] | first) // null) as $m
        | if $m then .image = $m.image else . end]
    | .spec.template.metadata.labels = ((.spec.template.metadata.labels // {}) + {"muster.dev/version": $v})
    | .spec.template.metadata.annotations = ((.spec.template.metadata.annotations // {}) + {"muster.dev/version-full": $vf})')
  if ! _ro_apply "$newj"; then
    _ro_canary_fail deploy_failed "couldn't update ${_RO_DEPLOY}"
    return 1
  fi
  _ro_wait_ready "$_RO_DEPLOY" || rc=$?
  if (( rc != 0 )); then
    # Put the stable template back, then restore traffic
    _ro_apply "$(_ro_clean "$sj" | jq -c --argjson r "$orig" '.spec.replicas = $r')"
    (( rc == 130 )) && { _ro_canary_restore interrupted "cancelled during final promotion"; _ro_exit_cancelled; }
    _ro_canary_fail health_failed "${_RO_DEPLOY}: ${_RO_WAIT_DETAIL}"
    return 1
  fi
  _ro_st_set --argjson t "$total" '.step = $t | .weight = 100 | .effective_weight = 100'
  _ro_sleep "$(_ro_cfg drain_seconds)" || true
  _ro_scale "$cdep" 0
  _ro_ev_shift 100 0 0
  _ro_st_set '.state = "complete" | .previous_version = .stable_version | .previous_image = .stable_image | .reason = null'
  _ro_ok "Promoted ${_RO_SVC} to $(_ro_st candidate_version) (${orig}/${orig} replicas)"
  _ro_ev_promoted
  _ro_history "promote" "ok"
  _RO_RESULT="deployed"
  _ro_interrupted && _ro_exit_cancelled
  return 0
}

# ══════════════════════════════════════════════════════════════
# promote / abort / rollback (state already loaded by the caller)
# ══════════════════════════════════════════════════════════════

# Usage: _rollout_promote_current [--to N | --full]
_rollout_promote_current() {
  local to="" full=false
  case "${1:-}" in
    --full) full=true ;;
    --to) to="${2:-}" ;;
  esac
  _RO_TYPE=$(_ro_st strategy)
  local st
  st=$(_ro_st state)
  if [[ "$_RO_TYPE" == "blue-green" ]]; then
    if [[ "$st" != "awaiting_promotion" ]]; then
      _ro_err "Nothing to promote for ${_RO_SVC} (rollout is ${st:-idle})"; return 1
    fi
    [[ -n "$to" && "$to" != "100" ]] && { _ro_err "--to only applies to canary rollouts (blue-green switches 0 → 100%)"; return 1; }
    _ro_bg_promote
    return $?
  fi
  if [[ "$st" != "paused" && "$st" != "degraded" ]]; then
    _ro_err "Nothing to promote for ${_RO_SVC} (rollout is ${st:-idle})"; return 1
  fi
  if [[ "$full" == "true" || "$to" == "100" ]]; then
    _ro_canary_final; return $?
  fi
  if [[ -n "$to" ]]; then
    local cur rc=0
    cur=$(_ro_st weight)
    if ! [[ "$to" =~ ^[0-9]+$ ]] || (( to < 1 || to > 100 )); then
      _ro_err "--to needs a weight between 1 and 100"; return 1
    fi
    if (( to <= cur )); then
      _ro_err "--to ${to} must be above the current weight (${cur}%) — use 'muster abort' to go back"; return 1
    fi
    _ro_ev_step "$(_ro_st step)" "$to" active
    _ro_canary_shift "$to" || rc=$?
    (( rc == 130 )) && _ro_canary_interrupt
    (( rc != 0 )) && { _ro_canary_fail health_failed "${_RO_WAIT_DETAIL:-not ready}"; return 1; }
    local idx
    idx=$(printf '%s' "$_RO_STATE" | jq --argjson w "$to" '[.steps | to_entries[] | select(.value.weight <= $w) | .key + 1] | max // 0')
    rc=0; _ro_gate canary "$(_ro_st candidate_deployment)" "$idx" || rc=$?
    (( rc == 130 )) && _ro_canary_interrupt
    (( rc != 0 )) && { _ro_canary_fail analysis_failed "$_RO_AN_DETAIL"; return 1; }
    _ro_st_set --argjson i "$idx" --argjson now "$(_ro_now)" '.step = $i | .state = "paused" | .step_started_epoch = $now'
    _ro_ev_step "$idx" "$to" paused
    _ro_ok "Paused at ${to}%"
    _ro_show
    _RO_RESULT="paused"
    return 0
  fi
  _ro_canary_run "$(( $(_ro_st step) + 1 ))"
}

# Usage: _rollout_abort_current reason
_rollout_abort_current() {
  local reason="${1:-user_abort}" st
  _RO_TYPE=$(_ro_st strategy)
  st=$(_ro_st state)
  case "$st" in
    progressing|paused|awaiting_promotion|degraded) ;;
    *) _ro_err "No rollout in progress for ${_RO_SVC} (state: ${st:-idle})"; return 1 ;;
  esac
  if [[ "$_RO_TYPE" == "canary" ]]; then
    _ro_canary_restore "$reason" "aborted by $(_deploy_identity 2>/dev/null || whoami)"
    _ro_history "abort" "ok" "$(_ro_st candidate_version)"
    return 0
  fi
  # blue-green: undo the cutover if it happened, else just drop the candidate
  local active cdep sel
  active=$(_ro_st active_track); cdep=$(_ro_st candidate_deployment)
  sel=$(_ro_get service "$_RO_KSVC" | jq -r '.spec.selector["muster.dev/track"] // empty')
  if [[ -n "$sel" && "$sel" != "$active" ]]; then
    local adep reps
    adep=$(_ro_st stable_deployment); reps=$(_ro_st replicas)
    [[ "$reps" =~ ^[0-9]+$ ]] && (( reps > 0 )) || reps=1
    _ro_scale "$adep" "$reps"
    _ro_wait_ready "$adep" || _ro_warn "${adep} not fully ready (${_RO_WAIT_DETAIL})"
    _ro_set_selector "$_RO_KSVC" "$active"
    _ro_ev_shift 100 0 0
  fi
  _ro_scale "$cdep" 0
  local pv
  pv=$(_ro_st preview_service)
  [[ -n "$pv" ]] && _ro_kc patch service "$pv" -n "$_RO_NS" --type=merge \
    -p "{\"spec\":{\"selector\":{\"muster.dev/track\":\"${active}\"}}}" >/dev/null 2>&1
  _ro_st_set --arg r "$reason" '.state = "aborted" | .reason = $r | .weight = 0 | .effective_weight = 0'
  _ro_ok "Aborted — ${_RO_KSVC} stays on ${active} ($(_ro_st stable_version))"
  _ro_ev_aborted "$reason" ""
  _ro_history "abort" "ok" "$(_ro_st candidate_version)"
  return 0
}

# How `muster rollback <svc>` should behave for this service:
#   abort    rollout in progress → abort it
#   bg       completed blue-green → switch the Service back
#   hook     anything else → run rollback.sh as before
_rollout_rollback_mode() {
  local svc="$1"
  has_cmd jq || { echo hook; return 0; }
  _rollout_is_progressive "$svc" || { echo hook; return 0; }
  _ro_ctx "$svc" || { echo hook; return 0; }
  [[ "$_RO_REMOTE" == "true" ]] || has_cmd kubectl || { echo hook; return 0; }
  _ro_state_load || { echo hook; return 0; }
  if _ro_state_active; then echo abort; return 0; fi
  if [[ "$(_ro_st strategy)" == "blue-green" && -n "$(_ro_st previous_track)" ]]; then
    case "$(_ro_st state)" in complete|rolled_back) echo bg; return 0 ;; esac
  fi
  echo hook
}

# ══════════════════════════════════════════════════════════════
# Version visibility
# ══════════════════════════════════════════════════════════════

# Snapshot of what's running for a k8s service:
#   {"strategy","version","image","revision","rollout":{…}|null,"idle":{…}}
# rollout is non-null while a blue-green/canary rollout is in progress, or
# while a rolling update has more than one live ReplicaSet.
# Usage: _rollout_snapshot svc
_rollout_snapshot() {
  local svc="$1"
  _ro_ctx "$svc" || { printf 'null'; return 0; }
  local now cfgtype
  now=$(_ro_now)
  cfgtype="$_RO_TYPE"
  _ro_state_load || _RO_STATE=""
  local stype=""
  [[ -n "$_RO_STATE" ]] && stype=$(_ro_st strategy)

  if [[ "$stype" == "blue-green" || ( -z "$stype" && "$cfgtype" == "blue-green" ) ]]; then
    local svcj sel blue green
    svcj=$(_ro_get service "$_RO_KSVC" 2>/dev/null)
    [[ -z "$svcj" ]] && svcj='{}'
    sel=$(printf '%s' "$svcj" | jq -r '.spec.selector["muster.dev/track"] // empty' 2>/dev/null)
    if [[ -n "$sel" ]]; then
      blue=$(_ro_get deployment "${_RO_DEPLOY}-blue" || echo null)
      green=$(_ro_get deployment "${_RO_DEPLOY}-green" || echo null)
      jq -nc --argjson st "${_RO_STATE:-null}" --argjson b "${blue:-null}" --argjson g "${green:-null}" \
        --arg sel "$sel" --arg c "$_RO_CONTAINER" --argjson now "$now" --arg cfg "$cfgtype" "${_RO_JQ}"'
        def ent($role; $track; $w): {role: $role, track: $track, deployment: .metadata.name, version: ver($c),
          image: img($c), revision: rev, replicas: {ready: ready, desired: desired}, weight: $w,
          effective_weight: $w, health: health};
        (if $sel == "blue" then $b else $g end) as $act
        | (if $sel == "blue" then $g else $b end) as $oth
        | ($st // {}) as $s
        | live($s.state) as $live
        | ([ ($act | select(. != null) | ent("stable"; $sel; 100)) ]
           + [ ($oth | select(. != null and (desired > 0 or $live)) | ent("candidate"; (if $sel == "blue" then "green" else "blue" end); 0)) ]) as $vers
        | {strategy: "blue-green",
           version: ($act | if . then ver($c) else null end), image: ($act | if . then img($c) else null end),
           revision: ($act | if . then rev else null end),
           rollout: (if $live then {
               state: $s.state, strategy: "blue-green", traffic_mechanism: ($s.traffic_mechanism // "service-selector"),
               step: $s.step, total_steps: $s.total_steps, weight: ($s.weight // 0),
               started_at: $s.started_at, elapsed_seconds: ($now - ($s.started_epoch // $now)),
               preview_service: ($s.preview_service // null),
               next_gate: (if $s.state == "awaiting_promotion" then {type: "promotion", next_weight: 100, remaining_seconds: null} else null end),
               versions: $vers, last_analysis: ($s.last_analysis // null)} else null end),
           idle: {state: "idle", strategy: "blue-green", traffic_mechanism: "service-selector",
                  last_state: ($s.state // null), versions: $vers}}'
      return 0
    fi
  fi

  if [[ "$stype" == "canary" ]]; then
    local sj cj
    sj=$(_ro_get deployment "$_RO_DEPLOY" || echo null)
    cj=$(_ro_get deployment "${_RO_DEPLOY}-canary" || echo null)
    jq -nc --argjson st "$_RO_STATE" --argjson s "${sj:-null}" --argjson k "${cj:-null}" \
      --arg c "$_RO_CONTAINER" --argjson now "$now" "${_RO_JQ}"'
      def ent($role; $track; $w): {role: $role, track: $track, deployment: .metadata.name, version: ver($c),
        image: img($c), revision: rev, replicas: {ready: ready, desired: desired}, weight: $w, health: health};
      live($st.state) as $live
      | ($st.weight // 0) as $w
      | ([ ($s | select(. != null) | ent("stable"; "stable"; (if $live then 100 - $w else 100 end))) ]
         + [ ($k | select(. != null and (desired > 0 or $live)) | ent("canary"; "canary"; (if $live then $w else 0 end))) ]) as $v0
      | ([$v0[].replicas.ready] | add // 0) as $tot
      | ($v0 | map(.effective_weight = (if $tot > 0 then ((.replicas.ready * 100 / $tot) + 0.5 | floor) else .weight end))) as $vers
      | ($st.steps // []) as $steps
      | {strategy: "canary",
         version: ($s | if . then ver($c) else null end), image: ($s | if . then img($c) else null end),
         revision: ($s | if . then rev else null end),
         rollout: (if $live then {
             state: $st.state, strategy: "canary", traffic_mechanism: ($st.traffic_mechanism // "replicas"),
             step: $st.step, total_steps: $st.total_steps, weight: $w,
             effective_weight: ([$vers[] | select(.role == "canary") | .effective_weight] | first // 0),
             started_at: $st.started_at, elapsed_seconds: ($now - ($st.started_epoch // $now)),
             preview_service: null,
             next_gate: (($steps[$st.step] // null) as $nx
               | if $st.state == "paused" then {type: "manual", next_weight: ($nx.weight // 100), remaining_seconds: null}
                 elif $st.state == "progressing" and (($steps[$st.step - 1].pause // 0) | type) == "number" and $st.step > 0 then
                   {type: "timer", next_weight: ($nx.weight // 100),
                    remaining_seconds: ([0, (($st.step_started_epoch // $now) + ($steps[$st.step - 1].pause // 0) - $now)] | max)}
                 else null end),
             versions: $vers, last_analysis: ($st.last_analysis // null)} else null end),
         idle: {state: "idle", strategy: "canary", traffic_mechanism: ($st.traffic_mechanism // "replicas"),
                last_state: $st.state, versions: $vers}}'
    return 0
  fi

  # Rolling (or nothing recorded yet): every live ReplicaSet of the Deployment
  local rs
  rs=$(_ro_kc get replicasets -n "$_RO_NS" -o json 2>/dev/null) || rs='{"items":[]}'
  printf '%s' "$rs" | jq -c --arg d "$_RO_DEPLOY" --arg c "$_RO_CONTAINER" --arg cfg "$cfgtype" "${_RO_JQ}"'
    [.items[]? | select(any(.metadata.ownerReferences[]?; .kind == "Deployment" and .name == $d))
      | select((.spec.replicas // 0) > 0 or (.status.replicas // 0) > 0)] | sort_by(rev // 0) as $live
    | ([$live[] | ready] | add // 0) as $tot
    | ($live | length) as $n
    | [ $live | to_entries[] | .key as $i | .value
        | {role: (if $i == $n - 1 then (if $n > 1 then "candidate" else "stable" end) else "stable" end),
           track: "rs-\(rev // "?")", replicaset: .metadata.name, version: ver($c), image: img($c), revision: rev,
           replicas: {ready: ready, desired: desired},
           weight: (if $tot > 0 then ((ready * 100 / $tot) + 0.5 | floor) else 0 end),
           effective_weight: (if $tot > 0 then ((ready * 100 / $tot) + 0.5 | floor) else 0 end),
           health: health} ] as $vers
    | ($live | last) as $top
    | {strategy: $cfg,
       version: ($top | if . then ver($c) else null end), image: ($top | if . then img($c) else null end),
       revision: ($top | if . then rev else null end),
       rollout: (if $n > 1 then {
           state: "progressing", strategy: "rolling", traffic_mechanism: "replicas",
           step: null, total_steps: null,
           weight: ($vers | last | .effective_weight), started_at: null, elapsed_seconds: null,
           preview_service: null, next_gate: null, versions: $vers, last_analysis: null} else null end),
       idle: {state: "idle", strategy: $cfg, traffic_mechanism: (if $cfg == "rolling" then "replicas" else null end), versions: $vers}}'
}
