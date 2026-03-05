#!/usr/bin/env bash
set -eo pipefail

# Generic webhook skill for muster
# Posts JSON payloads to any HTTP endpoint on deploy, rollback, and fleet events.
#
# Required config:
#   MUSTER_WEBHOOK_URL     — Endpoint URL
#   MUSTER_WEBHOOK_SECRET  — (optional) Sent as X-Webhook-Secret header
#
# Payload includes all available context: hook name, service, status, fleet info.

[[ -z "${MUSTER_WEBHOOK_URL:-}" ]] && exit 0

# --- Build JSON payload ---

HOOK="${MUSTER_HOOK:-unknown}"
STATUS="${MUSTER_DEPLOY_STATUS:-}"
SERVICE="${MUSTER_SERVICE:-}"
SERVICE_NAME="${MUSTER_SERVICE_NAME:-}"
FLEET="${MUSTER_FLEET_NAME:-}"
MACHINE="${MUSTER_FLEET_MACHINE:-}"
HOST="${MUSTER_FLEET_HOST:-}"
STRATEGY="${MUSTER_FLEET_STRATEGY:-}"
MODE="${MUSTER_FLEET_MODE:-}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Escape values for JSON
_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

PAYLOAD="{"
PAYLOAD="$PAYLOAD\"event\":\"$(_esc "$HOOK")\""
PAYLOAD="$PAYLOAD,\"timestamp\":\"$TIMESTAMP\""

[[ -n "$STATUS" ]]       && PAYLOAD="$PAYLOAD,\"status\":\"$(_esc "$STATUS")\""
[[ -n "$SERVICE" ]]      && PAYLOAD="$PAYLOAD,\"service\":\"$(_esc "$SERVICE")\""
[[ -n "$SERVICE_NAME" ]] && PAYLOAD="$PAYLOAD,\"service_name\":\"$(_esc "$SERVICE_NAME")\""

# Fleet context
if [[ -n "$FLEET" ]]; then
  PAYLOAD="$PAYLOAD,\"fleet\":{\"name\":\"$(_esc "$FLEET")\""
  [[ -n "$MACHINE" ]]  && PAYLOAD="$PAYLOAD,\"machine\":\"$(_esc "$MACHINE")\""
  [[ -n "$HOST" ]]     && PAYLOAD="$PAYLOAD,\"host\":\"$(_esc "$HOST")\""
  [[ -n "$STRATEGY" ]] && PAYLOAD="$PAYLOAD,\"strategy\":\"$(_esc "$STRATEGY")\""
  [[ -n "$MODE" ]]     && PAYLOAD="$PAYLOAD,\"mode\":\"$(_esc "$MODE")\""
  PAYLOAD="$PAYLOAD}"
fi

PAYLOAD="$PAYLOAD}"

# --- Send webhook ---

CURL_ARGS=(-sf -X POST "$MUSTER_WEBHOOK_URL" -H "Content-Type: application/json" -d "$PAYLOAD")

if [[ -n "${MUSTER_WEBHOOK_SECRET:-}" ]]; then
  CURL_ARGS[${#CURL_ARGS[@]}]="-H"
  CURL_ARGS[${#CURL_ARGS[@]}]="X-Webhook-Secret: ${MUSTER_WEBHOOK_SECRET}"
fi

curl "${CURL_ARGS[@]}" > /dev/null 2>&1 || true

exit 0
