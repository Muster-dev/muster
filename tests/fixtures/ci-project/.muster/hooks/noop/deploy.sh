#!/usr/bin/env bash
# Fixture for the action self-test: deploys nothing, succeeds.
set -euo pipefail
echo "Deploying ${MUSTER_SERVICE:-noop} (nothing to do)"
echo "noop deployed"
