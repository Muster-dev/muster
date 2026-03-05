#!/usr/bin/env bash
set -eo pipefail

# Discord notification skill for muster
# Sends deploy, rollback, and fleet notifications to a Discord channel.
#
# Required config:
#   MUSTER_DISCORD_BOT_TOKEN  — Discord bot token
#   MUSTER_DISCORD_CHANNEL_ID — Target channel ID
#
# Supports all deploy hooks and fleet hooks.
# Per-fleet config lets you send to different channels per fleet.

[[ -z "${MUSTER_DISCORD_BOT_TOKEN:-}" ]] && exit 0
[[ -z "${MUSTER_DISCORD_CHANNEL_ID:-}" ]] && exit 0

# --- Build notification content ---

HOOK="${MUSTER_HOOK:-unknown}"
STATUS="${MUSTER_DEPLOY_STATUS:-unknown}"
SERVICE="${MUSTER_SERVICE_NAME:-${MUSTER_SERVICE:-}}"
FLEET="${MUSTER_FLEET_NAME:-}"
MACHINE="${MUSTER_FLEET_MACHINE:-}"
HOST="${MUSTER_FLEET_HOST:-}"
STRATEGY="${MUSTER_FLEET_STRATEGY:-}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Colors: green=success, red=failed, orange=rollback, blue=info, grey=skip
COLOR_GREEN=3066993
COLOR_RED=15158332
COLOR_ORANGE=15105570
COLOR_BLUE=3447003
COLOR_GREY=9807270

COLOR=$COLOR_GREY
TITLE=""
DESC=""

case "$HOOK" in
  # --- Fleet hooks ---
  fleet-deploy-start)
    COLOR=$COLOR_BLUE
    TITLE="Fleet deploy started: ${FLEET}"
    DESC="Strategy: ${STRATEGY}"
    ;;
  fleet-deploy-end)
    if [[ "$STATUS" == "ok" ]]; then
      COLOR=$COLOR_GREEN
      TITLE="Fleet deploy complete: ${FLEET}"
    else
      COLOR=$COLOR_RED
      TITLE="Fleet deploy FAILED: ${FLEET}"
    fi
    DESC="Strategy: ${STRATEGY}"
    ;;
  fleet-machine-deploy-start)
    COLOR=$COLOR_BLUE
    TITLE="Deploying to ${MACHINE}"
    DESC="Host: ${HOST}"
    ;;
  fleet-machine-deploy-end)
    if [[ "$STATUS" == "ok" ]]; then
      COLOR=$COLOR_GREEN
      TITLE="Deployed to ${MACHINE}"
    else
      COLOR=$COLOR_RED
      TITLE="Deploy FAILED: ${MACHINE}"
    fi
    DESC="Host: ${HOST}"
    ;;
  fleet-rollback-start)
    COLOR=$COLOR_ORANGE
    TITLE="Fleet rollback started: ${FLEET}"
    ;;
  fleet-rollback-end)
    if [[ "$STATUS" == "ok" ]]; then
      COLOR=$COLOR_GREEN
      TITLE="Fleet rollback complete: ${FLEET}"
    else
      COLOR=$COLOR_RED
      TITLE="Fleet rollback FAILED: ${FLEET}"
    fi
    ;;
  # --- Standard deploy hooks ---
  post-deploy)
    case "$STATUS" in
      success) COLOR=$COLOR_GREEN;  TITLE="Deployed ${SERVICE}" ;;
      failed)  COLOR=$COLOR_RED;    TITLE="Deploy FAILED: ${SERVICE}" ;;
      skipped) COLOR=$COLOR_GREY;   TITLE="Deploy skipped: ${SERVICE}" ;;
      *)       COLOR=$COLOR_GREY;   TITLE="Deploy ${STATUS}: ${SERVICE}" ;;
    esac
    ;;
  post-rollback)
    case "$STATUS" in
      success) COLOR=$COLOR_GREEN;  TITLE="Rolled back ${SERVICE}" ;;
      failed)  COLOR=$COLOR_RED;    TITLE="Rollback FAILED: ${SERVICE}" ;;
      *)       COLOR=$COLOR_ORANGE; TITLE="Rollback ${STATUS}: ${SERVICE}" ;;
    esac
    ;;
  # --- Pre hooks (optional info) ---
  pre-deploy)
    COLOR=$COLOR_BLUE
    TITLE="Deploying ${SERVICE}..."
    ;;
  pre-rollback)
    COLOR=$COLOR_ORANGE
    TITLE="Rolling back ${SERVICE}..."
    ;;
  *)
    TITLE="${HOOK}: ${SERVICE:-fleet}"
    ;;
esac

# --- Build embed JSON ---

# Escape double quotes in title and desc
TITLE="${TITLE//\"/\\\"}"
DESC="${DESC//\"/\\\"}"

EMBED="{\"title\":\"${TITLE}\",\"color\":${COLOR},\"timestamp\":\"${TIMESTAMP}\""

# Add description if present
if [[ -n "$DESC" ]]; then
  EMBED="${EMBED},\"description\":\"${DESC}\""
fi

# Add fleet footer if this is a fleet event
if [[ -n "$FLEET" ]]; then
  FOOTER="Fleet: ${FLEET}"
  [[ -n "$STRATEGY" ]] && FOOTER="${FOOTER} | ${STRATEGY}"
  FOOTER="${FOOTER//\"/\\\"}"
  EMBED="${EMBED},\"footer\":{\"text\":\"${FOOTER}\"}"
fi

EMBED="${EMBED}}"

# --- Send to Discord ---

curl -sf -X POST \
  "https://discord.com/api/v10/channels/${MUSTER_DISCORD_CHANNEL_ID}/messages" \
  -H "Authorization: Bot ${MUSTER_DISCORD_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"embeds\":[${EMBED}]}" \
  > /dev/null 2>&1 || true

exit 0
