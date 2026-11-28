#!/usr/bin/env bash
set -euo pipefail
# Health check for {{SERVICE_NAME}} on Kubernetes (blue-green)
#
# During a rollout muster sets MUSTER_TARGET_DEPLOYMENT to the colour under
# test. Otherwise check the colour the Service currently sends traffic to.

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
BASE="${MUSTER_K8S_BASE_DEPLOYMENT:-${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}}"
TRAFFIC_SVC="${MUSTER_K8S_TRAFFIC_SERVICE:-{{K8S_DEPLOY_NAME}}}"
DEPLOY_NAME="${MUSTER_TARGET_DEPLOYMENT:-}"
if [[ -z "$DEPLOY_NAME" ]]; then
  TRACK=$(kubectl get service "$TRAFFIC_SVC" -n "$NAMESPACE" \
    -o 'jsonpath={.spec.selector.muster\.dev/track}' 2>/dev/null || true)
  DEPLOY_NAME="$BASE"
  [[ -n "$TRACK" ]] && DEPLOY_NAME="${BASE}-${TRACK}"
fi

kubectl rollout status "deployment/${DEPLOY_NAME}" -n "$NAMESPACE" --timeout=10s &>/dev/null || exit 1
exit 0
