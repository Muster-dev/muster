#!/usr/bin/env bash
# muster/lib/core/k8s_diag.sh — K8s deploy failure diagnostics
#
# _k8s_diag_collect gathers the facts (deployment → new ReplicaSet → pod →
# describe + logs) and matches known error patterns into structured fields.
# k8s_diagnose_failure prints them for people; k8s_diagnose_json emits one
# NDJSON "diagnosis" event for frontends (see docs/ENGINE-API.md).

source "$MUSTER_ROOT/lib/core/engine.sh"

# Run kubectl locally or via SSH for remote services
# Usage: _diag_run_kubectl "svc" "kubectl command string"
_diag_run_kubectl() {
  local svc="$1" cmd="$2"
  if remote_is_enabled "$svc"; then
    _remote_load_config "$svc"
    _remote_build_opts
    # shellcheck disable=SC2086
    printf '%s\n' "$cmd" | ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "bash -s" 2>/dev/null
  else
    bash -c "$cmd" 2>/dev/null
  fi
}

# Display a diagnosis line
_diag_show() {
  local diagnosis="$1" suggestion="$2"
  printf '%b\n' "  ${RED}•${RESET} ${BOLD}${diagnosis}${RESET}"
  printf '%b\n' "    ${DIM}${suggestion}${RESET}"
}

# Known error patterns: "id|grep -i regex|summary|hint" (checked in order;
# the first two are alternatives — only one of them is reported)
_K8S_DIAG_RULES=(
  'ErrImageNeverPull|ErrImageNeverPull|Image not found locally and pull policy is Never|Push the image to the node or change imagePullPolicy'
  'ImagePullBackOff|ImagePullBackOff\|ErrImagePull|Can'"'"'t pull container image|Check registry auth, image name, and tag'
  'InvalidImageName|InvalidImageName|Invalid image name in deployment spec|Check the image field in your deployment YAML'
  'OOMKilled|OOMKilled|Out of memory (OOMKilled)|Increase memory limits in deployment spec'
  'CrashLoopBackOff|CrashLoopBackOff|Container keeps crashing (CrashLoopBackOff)|Check application logs and entrypoint config'
  'CreateContainerConfigError|CreateContainerConfigError|Container config error (missing ConfigMap or Secret mount)|Check that all referenced ConfigMaps and Secrets exist'
  'RunContainerError|RunContainerError|Container failed to start|Check entrypoint, command, and volume mounts in deployment spec'
  'Unschedulable|Unschedulable|No node has enough capacity|Check node resources or scale up the cluster'
  'SecretNotFound|secret.*not found|Missing Kubernetes secret|Create the required secret before deploying'
  'PVCNotFound|persistentvolumeclaim.*not found|Missing PersistentVolumeClaim|Create the required PVC before deploying'
  'VersionMismatch|incompatible.*engine version\|version.*mismatch|Version mismatch|Pin to a compatible version or check migration docs'
)

# Results of the last _k8s_diag_collect
_K8S_DIAG_MATCHES=()     # "id|summary|hint" per matched pattern
_K8S_DIAG_DEPLOYMENT=""
_K8S_DIAG_NAMESPACE=""
_K8S_DIAG_POD=""
_K8S_DIAG_POD_STATUS=""  # `kubectl get pod --no-headers` line
_K8S_DIAG_POD_DESC=""
_K8S_DIAG_LOGS=""        # current + previous container log tail
_K8S_DIAG_HINT_CMD=""    # what to inspect when nothing matched

# Collect diagnostics for a failed k8s service into _K8S_DIAG_*.
# Returns 1 (and collects nothing) for non-k8s services, without kubectl,
# or when the deployment can't be described.
# Usage: _k8s_diag_collect svc
_k8s_diag_collect() {
  local svc="$1"
  _K8S_DIAG_MATCHES=()
  _K8S_DIAG_POD="" _K8S_DIAG_POD_STATUS="" _K8S_DIAG_POD_DESC="" _K8S_DIAG_LOGS="" _K8S_DIAG_HINT_CMD=""
  _K8S_DIAG_DEPLOYMENT="${MUSTER_K8S_DEPLOYMENT:-}"
  _K8S_DIAG_NAMESPACE="${MUSTER_K8S_NAMESPACE:-default}"
  local deployment="$_K8S_DIAG_DEPLOYMENT" namespace="$_K8S_DIAG_NAMESPACE"

  # Guard: only for k8s services with kubectl available
  [[ -z "$deployment" ]] && return 1
  [[ "${MUSTER_HAS_KUBECTL:-false}" != "true" ]] && return 1

  # Step 1: Describe the deployment (includes events, conditions, RS info)
  local deploy_desc
  deploy_desc=$(_diag_run_kubectl "$svc" "kubectl describe deployment ${deployment} -n ${namespace}")
  [[ -z "$deploy_desc" ]] && return 1

  # Step 2: Extract the new ReplicaSet name
  local new_rs
  new_rs=$(printf '%s\n' "$deploy_desc" | grep "NewReplicaSet:" | awk '{print $2}')

  local pod_name="" pod_desc="" pod_logs="" pod_prev_logs=""

  if [[ -n "$new_rs" && "$new_rs" != "<none>" ]]; then
    # Get pods list, then find the first pod from the new RS locally
    local _pods_output
    _pods_output=$(_diag_run_kubectl "$svc" "kubectl get pods -n ${namespace} --no-headers")

    if [[ -n "$_pods_output" ]]; then
      pod_name=$(printf '%s\n' "$_pods_output" | grep "^${new_rs}" | head -1 | awk '{print $1}')
    fi

    if [[ -n "$pod_name" ]]; then
      # Step 3: Describe the pod (events, conditions)
      pod_desc=$(_diag_run_kubectl "$svc" "kubectl describe pod ${pod_name} -n ${namespace}")

      # Step 4: Get pod logs (current + previous container)
      pod_logs=$(_diag_run_kubectl "$svc" "kubectl logs ${pod_name} -n ${namespace} --tail=30")
      pod_prev_logs=$(_diag_run_kubectl "$svc" "kubectl logs ${pod_name} -n ${namespace} --previous --tail=30")
    fi
  fi

  _K8S_DIAG_POD="$pod_name"
  _K8S_DIAG_POD_DESC="$pod_desc"
  _K8S_DIAG_LOGS="$pod_logs"
  if [[ -n "$pod_prev_logs" ]]; then
    [[ -n "$_K8S_DIAG_LOGS" ]] && _K8S_DIAG_LOGS="${_K8S_DIAG_LOGS}
"
    _K8S_DIAG_LOGS="${_K8S_DIAG_LOGS}${pod_prev_logs}"
  fi

  # Combine all output for pattern matching
  local all_output="${deploy_desc}
${pod_desc}
${pod_logs}
${pod_prev_logs}"

  # ── Match known error patterns ──
  local i=0 rule id rx rest summary hint image_pull_matched=false
  while (( i < ${#_K8S_DIAG_RULES[@]} )); do
    rule="${_K8S_DIAG_RULES[$i]}"
    id="${rule%%|*}"; rest="${rule#*|}"
    rx="${rest%%|*}"; rest="${rest#*|}"
    summary="${rest%%|*}"; hint="${rest#*|}"
    i=$(( i + 1 ))
    # ErrImageNeverPull and ImagePullBackOff are reported as one or the other
    if [[ "$id" == "ImagePullBackOff" && "$image_pull_matched" == "true" ]]; then
      continue
    fi
    if printf '%s' "$all_output" | grep -qi "$rx"; then
      _K8S_DIAG_MATCHES[${#_K8S_DIAG_MATCHES[@]}]="${id}|${summary}|${hint}"
      [[ "$id" == "ErrImageNeverPull" ]] && image_pull_matched=true
    fi
  done

  if [[ -n "$pod_name" ]]; then
    _K8S_DIAG_HINT_CMD="kubectl describe pod ${pod_name} -n ${namespace}"
    _K8S_DIAG_POD_STATUS=$(_diag_run_kubectl "$svc" "kubectl get pod ${pod_name} -n ${namespace} --no-headers")
  else
    _K8S_DIAG_HINT_CMD="kubectl describe deployment ${deployment} -n ${namespace}"
  fi
  return 0
}

# Run k8s deploy failure diagnostics for a service (human output)
# Called after deploy/rollback failure, before the recovery menu
# Usage: k8s_diagnose_failure "svc"
k8s_diagnose_failure() {
  local svc="$1"

  # Guard: only for k8s services with kubectl available
  [[ -z "${MUSTER_K8S_DEPLOYMENT:-}" ]] && return 0
  [[ "${MUSTER_HAS_KUBECTL:-false}" != "true" ]] && return 0

  printf '%b\n' "  ${ACCENT}Diagnosing deploy failure...${RESET}"
  echo ""

  _k8s_diag_collect "$svc" || return 0

  local i=0 m rest
  while (( i < ${#_K8S_DIAG_MATCHES[@]} )); do
    m="${_K8S_DIAG_MATCHES[$i]}"
    rest="${m#*|}"
    _diag_show "${rest%%|*}" "${rest#*|}"
    i=$(( i + 1 ))
  done

  if (( ${#_K8S_DIAG_MATCHES[@]} == 0 )); then
    printf '%b\n' "  ${DIM}No specific error pattern detected (likely a timeout)${RESET}"
    printf '%b\n' "  ${DIM}Inspect: ${_K8S_DIAG_HINT_CMD}${RESET}"
  fi

  # Show the pod status line so user sees the exact state
  if [[ -n "$_K8S_DIAG_POD_STATUS" ]]; then
    printf '%b\n' "  ${DIM}Pod status: ${_K8S_DIAG_POD_STATUS}${RESET}"
  fi

  echo ""
}

# Emit one NDJSON diagnosis event on stdout for a failed k8s service.
# Prints nothing for non-k8s services or when nothing can be collected.
# Usage: k8s_diagnose_json "svc"
k8s_diagnose_json() {
  local svc="$1"
  _k8s_diag_collect "$svc" || return 0

  local pattern="unknown" summary="No specific error pattern detected (likely a timeout)"
  local hint="Inspect: ${_K8S_DIAG_HINT_CMD}"
  local patterns="" i=0 m id rest
  while (( i < ${#_K8S_DIAG_MATCHES[@]} )); do
    m="${_K8S_DIAG_MATCHES[$i]}"
    id="${m%%|*}"; rest="${m#*|}"
    if (( i == 0 )); then
      pattern="$id"; summary="${rest%%|*}"; hint="${rest#*|}"
    else
      patterns="${patterns},"
    fi
    patterns="${patterns}{\"pattern\":$(_json_str "$id"),\"summary\":$(_json_str "${rest%%|*}"),\"hint\":$(_json_str "${rest#*|}")}"
    i=$(( i + 1 ))
  done

  # Pod status column (e.g. "ImagePullBackOff") and ready count
  local pod_status=""
  if [[ -n "$_K8S_DIAG_POD_STATUS" ]]; then
    pod_status=$(printf '%s' "$_K8S_DIAG_POD_STATUS" | awk '{print $2" "$3}')
  fi

  # Events section of the pod description, last 15 lines
  local details=""
  if [[ -n "$_K8S_DIAG_POD_DESC" ]]; then
    details=$(printf '%s\n' "$_K8S_DIAG_POD_DESC" | sed -n '/^Events:/,$p' | tail -15)
  fi
  local log_tail=""
  [[ -n "$_K8S_DIAG_LOGS" ]] && log_tail=$(printf '%s\n' "$_K8S_DIAG_LOGS" | tail -30)

  local details_json="[]" logs_json="[]"
  [[ -n "$details" ]] && details_json=$(printf '%s\n' "$details" | _json_lines_array)
  [[ -n "$log_tail" ]] && logs_json=$(printf '%s\n' "$log_tail" | _json_lines_array)

  printf '{"event":"diagnosis","service":%s,"kind":"k8s","pattern":%s,"summary":%s,"hint":%s,"patterns":[%s],"deployment":%s,"namespace":%s,"pod":%s,"pod_status":%s,"details":%s,"log_tail":%s,"logs":%s}\n' \
    "$(_json_str "$svc")" "$(_json_str "$pattern")" "$(_json_str "$summary")" "$(_json_str "$hint")" \
    "$patterns" "$(_json_str "$_K8S_DIAG_DEPLOYMENT")" "$(_json_str "$_K8S_DIAG_NAMESPACE")" \
    "$(_json_str_or_null "$_K8S_DIAG_POD")" "$(_json_str_or_null "$pod_status")" \
    "$details_json" "$logs_json" "$logs_json"
}
