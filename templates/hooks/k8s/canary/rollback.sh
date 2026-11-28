#!/usr/bin/env bash
set -euo pipefail
# Rollback {{SERVICE_NAME}} on Kubernetes (canary)
#
# While a canary is in progress `muster rollback {{SERVICE_NAME}}` aborts it instead
# of running this hook. After a completed canary the new version lives on the
# stable Deployment, so undoing its last revision is the right rollback.

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
DEPLOY_NAME="${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}"

echo "Rolling back ${DEPLOY_NAME}..."
kubectl rollout undo "deployment/${DEPLOY_NAME}" -n "$NAMESPACE"
kubectl rollout status "deployment/${DEPLOY_NAME}" -n "$NAMESPACE" --timeout="${MUSTER_DEPLOY_TIMEOUT:-120}s"
echo "{{SERVICE_NAME}} rolled back"
