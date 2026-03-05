#!/usr/bin/env bash
set -eo pipefail

# Slack notification skill for muster
# Sends deploy, rollback, and fleet notifications via Slack Incoming Webhook.
#
# Required config:
#   MUSTER_SLACK_WEBHOOK_URL — Slack incoming webhook URL
#
# Supports all deploy hooks and fleet hooks.
# Per-fleet config lets you send to different Slack channels per fleet.

[[ -z "${MUSTER_SLACK_WEBHOOK_URL:-}" ]] && exit 0

# --- Build notification ---

HOOK="${MUSTER_HOOK:-unknown}"
STATUS="${MUSTER_DEPLOY_STATUS:-unknown}"
SERVICE="${MUSTER_SERVICE_NAME:-${MUSTER_SERVICE:-}}"
FLEET="${MUSTER_FLEET_NAME:-}"
MACHINE="${MUSTER_FLEET_MACHINE:-}"
HOST="${MUSTER_FLEET_HOST:-}"
STRATEGY="${MUSTER_FLEET_STRATEGY:-}"

# Slack colors: good=green, danger=red, warning=orange, #hex for custom
COLOR=""
TEXT=""
FALLBACK=""

case "$HOOK" in
  # --- Fleet hooks ---
  fleet-deploy-end)
    if [[ "$STATUS" == "ok" ]]; then
      COLOR="good"
      TEXT="Fleet deploy complete: *${FLEET}* (${STRATEGY})"
    else
      COLOR="danger"
      TEXT="Fleet deploy FAILED: *${FLEET}* (${STRATEGY})"
    fi
    ;;
  fleet-machine-deploy-end)
    if [[ "$STATUS" == "ok" ]]; then
      COLOR="good"
      TEXT="Deployed to *${MACHINE}* (${HOST})"
    else
      COLOR="danger"
      TEXT="Deploy FAILED: *${MACHINE}* (${HOST})"
    fi
    ;;
  fleet-rollback-end)
    if [[ "$STATUS" == "ok" ]]; then
      COLOR="good"
      TEXT="Fleet rollback complete: *${FLEET}*"
    else
      COLOR="danger"
      TEXT="Fleet rollback FAILED: *${FLEET}*"
    fi
    ;;
  # --- Standard deploy hooks ---
  post-deploy)
    case "$STATUS" in
      success) COLOR="good";    TEXT="Deployed *${SERVICE}*" ;;
      failed)  COLOR="danger";  TEXT="Deploy FAILED: *${SERVICE}*" ;;
      skipped) COLOR="#cccccc"; TEXT="Deploy skipped: *${SERVICE}*" ;;
      *)       COLOR="#cccccc"; TEXT="Deploy ${STATUS}: *${SERVICE}*" ;;
    esac
    ;;
  post-rollback)
    case "$STATUS" in
      success) COLOR="good";    TEXT="Rolled back *${SERVICE}*" ;;
      failed)  COLOR="danger";  TEXT="Rollback FAILED: *${SERVICE}*" ;;
      *)       COLOR="warning"; TEXT="Rollback ${STATUS}: *${SERVICE}*" ;;
    esac
    ;;
  *)
    COLOR="#cccccc"
    TEXT="${HOOK}: ${SERVICE:-${FLEET:-unknown}}"
    ;;
esac

FALLBACK="${TEXT//\*/}"

# --- Build Slack payload ---

# Escape for JSON
TEXT="${TEXT//\\/\\\\}"
TEXT="${TEXT//\"/\\\"}"
FALLBACK="${FALLBACK//\\/\\\\}"
FALLBACK="${FALLBACK//\"/\\\"}"

PAYLOAD="{\"attachments\":[{\"color\":\"${COLOR}\",\"text\":\"${TEXT}\",\"fallback\":\"${FALLBACK}\",\"mrkdwn_in\":[\"text\"]"

# Add fleet context as footer
if [[ -n "$FLEET" ]]; then
  FOOTER="Fleet: ${FLEET}"
  [[ -n "$STRATEGY" ]] && FOOTER="${FOOTER} | ${STRATEGY}"
  FOOTER="${FOOTER//\"/\\\"}"
  PAYLOAD="${PAYLOAD},\"footer\":\"${FOOTER}\""
fi

PAYLOAD="${PAYLOAD}}]}"

# --- Send to Slack ---

curl -sf -X POST "$MUSTER_SLACK_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  > /dev/null 2>&1 || true

exit 0
