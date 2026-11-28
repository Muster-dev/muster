#!/usr/bin/env bash
set -euo pipefail
# Health check for {{SERVICE_NAME}} (infrastructure) on Kubernetes

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
DEPLOY_NAME="${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}"
: "${NAMESPACE:?NAMESPACE is required}"
: "${DEPLOY_NAME:?DEPLOY_NAME is required}"

# Check deployment rollout status
kubectl rollout status "deployment/${DEPLOY_NAME}" -n "$NAMESPACE" --timeout=10s &>/dev/null || exit 1

exit 0
