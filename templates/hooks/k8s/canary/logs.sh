#!/usr/bin/env bash
set -euo pipefail
# Stream logs for {{SERVICE_NAME}} on Kubernetes (canary): the stable
# Deployment, or the canary when MUSTER_ROLLOUT_TRACK=canary.

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
DEPLOY_NAME="${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}"
[[ "${MUSTER_ROLLOUT_TRACK:-}" == "canary" ]] && DEPLOY_NAME="${DEPLOY_NAME}-canary"

kubectl logs -n "$NAMESPACE" "deployment/${DEPLOY_NAME}" --all-containers -f --tail=100
