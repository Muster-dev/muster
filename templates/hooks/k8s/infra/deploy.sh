#!/usr/bin/env bash
set -euo pipefail
# Deploy {{SERVICE_NAME}} (infrastructure) to Kubernetes

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
SERVICE="${MUSTER_K8S_SERVICE:-{{SERVICE_NAME}}}"
DEPLOY_NAME="${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}"
IMAGE="{{SERVICE_IMAGE}}"
TIMEOUT="${MUSTER_DEPLOY_TIMEOUT:-120}"
: "${SERVICE:?SERVICE is required}"
: "${NAMESPACE:?NAMESPACE is required}"
: "${DEPLOY_NAME:?DEPLOY_NAME is required}"

# Smart rollout wait: progress updates + early error detection
_k8s_smart_wait() {
  local deploy="$1" ns="$2" timeout="$3"

  # Get label selector for this deployment's pods
  local selector
  selector=$(kubectl get deployment "$deploy" -n "$ns" \
    -o jsonpath='{range .spec.selector.matchLabels}{@}' 2>/dev/null) || true
  local use_prefix=false
  if [[ -z "$selector" ]]; then
    selector=$(kubectl get deployment "$deploy" -n "$ns" \
      -o json 2>/dev/null | grep -A50 '"matchLabels"' | head -20 | \
      grep '"' | sed 's/[" ]//g; s/:/=/g' | paste -sd, -) || true
  fi
  if [[ -z "$selector" ]]; then
    use_prefix=true
  fi

  kubectl rollout status "deployment/${deploy}" -n "$ns" --timeout="${timeout}s" &
  local rollout_pid=$!

  local elapsed=0
  while kill -0 "$rollout_pid" 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))

    local pod_output
    if [[ "$use_prefix" == "true" ]]; then
      pod_output=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep "^${deploy}" || true)
    else
      pod_output=$(kubectl get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null || true)
    fi

    [[ -z "$pod_output" ]] && continue

    local error_pattern='ErrImageNeverPull\|ImagePullBackOff\|ErrImagePull\|InvalidImageName'
    if printf '%s' "$pod_output" | grep -q "$error_pattern"; then
      echo "ERROR: Image problem detected"
      local bad_pod
      bad_pod=$(printf '%s\n' "$pod_output" | grep "$error_pattern" | head -1 | awk '{print $1}')
      if [[ -n "$bad_pod" ]]; then
        echo "Pod: $bad_pod"
        kubectl get events -n "$ns" --field-selector "involvedObject.name=$bad_pod" \
          --sort-by='.lastTimestamp' 2>/dev/null | tail -3 || true
      fi
      kill "$rollout_pid" 2>/dev/null; wait "$rollout_pid" 2>/dev/null || true
      return 1
    fi

    local crash_pattern='CrashLoopBackOff\|RunContainerError\|CreateContainerConfigError'
    if printf '%s' "$pod_output" | grep -q "$crash_pattern"; then
      echo "ERROR: Container startup failure"
      local bad_pod
      bad_pod=$(printf '%s\n' "$pod_output" | grep "$crash_pattern" | head -1 | awk '{print $1}')
      if [[ -n "$bad_pod" ]]; then
        echo "Pod: $bad_pod"
        kubectl logs "$bad_pod" -n "$ns" --tail=5 2>/dev/null || true
      fi
      kill "$rollout_pid" 2>/dev/null; wait "$rollout_pid" 2>/dev/null || true
      return 1
    fi

    if printf '%s' "$pod_output" | grep -q "OOMKilled"; then
      echo "ERROR: Container killed — out of memory"
      kill "$rollout_pid" 2>/dev/null; wait "$rollout_pid" 2>/dev/null || true
      return 1
    fi

    local ready running total_pods
    running=$(printf '%s\n' "$pod_output" | grep -c "Running" || true)
    total_pods=$(printf '%s\n' "$pod_output" | wc -l | tr -d ' ')
    ready=$(printf '%s\n' "$pod_output" | awk '{print $2}' | grep -c '1/1\|2/2\|3/3\|4/4\|5/5' || true)
    echo "${ready}/${total_pods} pods ready (${elapsed}s)"
  done

  wait "$rollout_pid"
  return $?
}

# Apply manifests (picks up any image/config changes in YAML)
echo "Applying Kubernetes manifests for ${SERVICE}..."
kubectl apply -f {{K8S_DIR}} -n "$NAMESPACE" 2>/dev/null || true

if [[ "${MUSTER_DEPLOY_MODE:-restart}" == "update" ]]; then
  # Pull latest image version
  echo "Updating deployment to ${IMAGE}..."
  kubectl set image "deployment/${DEPLOY_NAME}" \
    "${SERVICE}=${IMAGE}" \
    -n "$NAMESPACE"
else
  # Restart only — uses image version from manifest
  echo "Restarting ${SERVICE}..."
  kubectl rollout restart "deployment/${DEPLOY_NAME}" -n "$NAMESPACE"
fi

# Wait for rollout with progress + early error detection
echo "Waiting for rollout..."
_k8s_smart_wait "$DEPLOY_NAME" "$NAMESPACE" "$TIMEOUT"

echo "${SERVICE} deployed"
