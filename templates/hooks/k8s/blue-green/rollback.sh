#!/usr/bin/env bash
set -euo pipefail
# Rollback {{SERVICE_NAME}} on Kubernetes (blue-green)
#
# `muster rollback {{SERVICE_NAME}}` normally doesn't run this hook: while a rollout
# is in progress it aborts it, and after a completed one it switches the
# Service back to the previous colour (instant when that colour is warm).
# This hook only runs when muster has no rollout state for the service; it
# then undoes the last change on the live colour.

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
BASE="${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}"
TRAFFIC_SVC="${MUSTER_K8S_TRAFFIC_SERVICE:-{{K8S_DEPLOY_NAME}}}"
TRACK=$(kubectl get service "$TRAFFIC_SVC" -n "$NAMESPACE" \
  -o 'jsonpath={.spec.selector.muster\.dev/track}' 2>/dev/null || true)
DEPLOY_NAME="$BASE"
[[ -n "$TRACK" ]] && DEPLOY_NAME="${BASE}-${TRACK}"

echo "Rolling back ${DEPLOY_NAME}..."
kubectl rollout undo "deployment/${DEPLOY_NAME}" -n "$NAMESPACE"
kubectl rollout status "deployment/${DEPLOY_NAME}" -n "$NAMESPACE" --timeout="${MUSTER_DEPLOY_TIMEOUT:-120}s"
echo "{{SERVICE_NAME}} rolled back"
