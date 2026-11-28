#!/usr/bin/env bash
set -euo pipefail
# Cleanup stuck pods for {{SERVICE_NAME}} on Kubernetes (stable and candidate tracks)

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
DEPLOY_NAME="${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}"

echo "Cleaning up failed pods..."
for sel in "app=${DEPLOY_NAME}" "muster.dev/service=${MUSTER_K8S_TRAFFIC_SERVICE:-{{K8S_DEPLOY_NAME}}}"; do
  kubectl delete pods -n "$NAMESPACE" -l "$sel" \
    --field-selector=status.phase!=Running 2>/dev/null || true
done

echo "Cleanup complete"
