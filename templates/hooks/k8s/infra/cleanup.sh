#!/usr/bin/env bash
set -euo pipefail
# Cleanup stuck pods for {{SERVICE_NAME}} (infrastructure) on Kubernetes

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
DEPLOY_NAME="${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}"

echo "Cleaning up failed pods..."
kubectl delete pods -n "$NAMESPACE" \
  -l app="${DEPLOY_NAME}" \
  --field-selector=status.phase!=Running \
  2>/dev/null || true

echo "Cleanup complete"
