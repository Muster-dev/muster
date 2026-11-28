#!/usr/bin/env bash
set -euo pipefail
# Rollback {{SERVICE_NAME}} (infrastructure) on Kubernetes

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
SERVICE="${MUSTER_K8S_SERVICE:-{{SERVICE_NAME}}}"
DEPLOY_NAME="${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}"

echo "Rolling back ${SERVICE}..."
kubectl rollout undo "deployment/${DEPLOY_NAME}" -n "$NAMESPACE"

echo "Waiting for rollback..."
kubectl rollout status "deployment/${DEPLOY_NAME}" -n "$NAMESPACE" --timeout=120s

echo "${SERVICE} rolled back"
