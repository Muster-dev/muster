#!/usr/bin/env bash
set -euo pipefail
# Health check for {{SERVICE_NAME}} on Kubernetes (canary)
#
# During a rollout muster sets MUSTER_TARGET_DEPLOYMENT to the canary
# ({{K8S_DEPLOY_NAME}}-canary); otherwise this checks the stable Deployment.

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
DEPLOY_NAME="${MUSTER_TARGET_DEPLOYMENT:-${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}}"

kubectl rollout status "deployment/${DEPLOY_NAME}" -n "$NAMESPACE" --timeout=10s &>/dev/null || exit 1
exit 0
