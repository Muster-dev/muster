#!/usr/bin/env bash
set -euo pipefail
# Deploy {{SERVICE_NAME}} to Kubernetes — {{STRATEGY}} (muster's rollout engine)
#
# muster prepares the candidate Deployment ($MUSTER_TARGET_DEPLOYMENT, e.g.
# {{K8S_DEPLOY_NAME}}-green or {{K8S_DEPLOY_NAME}}-canary) at 0 replicas, then scales it,
# runs the health gates and shifts traffic itself. This hook only builds and
# pushes an immutable image and points the target Deployment at it.
#
# Manifests are not re-applied here: `kubectl apply` mid-rollout would reset
# the stable Deployment and the Service selector. Ship manifest changes with
# `muster deploy {{SERVICE_NAME}} --strategy rolling` (or kubectl) between rollouts.

NAMESPACE="${MUSTER_K8S_NAMESPACE:-{{NAMESPACE}}}"
SERVICE="${MUSTER_K8S_SERVICE:-{{SERVICE_NAME}}}"
DEPLOY_NAME="${MUSTER_TARGET_DEPLOYMENT:-${MUSTER_K8S_DEPLOYMENT:-{{K8S_DEPLOY_NAME}}}}"
CONTAINER="${MUSTER_K8S_CONTAINER:-$SERVICE}"
REGISTRY="${DOCKER_REGISTRY:-localhost:5000}"
TAG="${MUSTER_IMAGE_TAG:-${IMAGE_TAG:-latest}}"
IMAGE="${REGISTRY}/${SERVICE}:${TAG}"
: "${NAMESPACE:?NAMESPACE is required}"
: "${DEPLOY_NAME:?DEPLOY_NAME is required}"

echo "Building ${IMAGE}..."
docker build -t "$IMAGE" -f "{{DOCKERFILE}}" .

echo "Pushing image..."
docker push "$IMAGE"

echo "Updating ${DEPLOY_NAME} (${MUSTER_ROLLOUT_TRACK:-candidate})..."
kubectl set image "deployment/${DEPLOY_NAME}" "${CONTAINER}=${IMAGE}" -n "$NAMESPACE"

echo "${SERVICE} ${TAG} pushed and applied — muster shifts traffic next"
