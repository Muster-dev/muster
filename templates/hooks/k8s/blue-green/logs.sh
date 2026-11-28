#!/usr/bin/env bash
set -euo pipefail
# Stream logs for {{SERVICE_NAME}} on Kubernetes (blue-green): the live colour,
# or the colour in MUSTER_ROLLOUT_TRACK (blue/green) when set.

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
BASE="${MUSTER_K8S_BASE_DEPLOYMENT:-${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}}"
TRAFFIC_SVC="${MUSTER_K8S_TRAFFIC_SERVICE:-{{K8S_DEPLOY_NAME}}}"
TRACK="${MUSTER_ROLLOUT_TRACK:-}"
if [[ -z "$TRACK" ]]; then
  TRACK=$(kubectl get service "$TRAFFIC_SVC" -n "$NAMESPACE" \
    -o 'jsonpath={.spec.selector.muster\.dev/track}' 2>/dev/null || true)
fi
DEPLOY_NAME="$BASE"
[[ -n "$TRACK" ]] && DEPLOY_NAME="${BASE}-${TRACK}"

kubectl logs -n "$NAMESPACE" "deployment/${DEPLOY_NAME}" --all-containers -f --tail=100
