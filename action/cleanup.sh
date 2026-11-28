#!/usr/bin/env bash
# action/cleanup.sh — stop the ssh-agent this action started, remove temp files.
set -uo pipefail

if [[ -n "${MUSTER_ACTION_SSH_DIR:-}" ]]; then
  if [[ -n "${SSH_AGENT_PID:-}" ]]; then
    SSH_AGENT_PID="$SSH_AGENT_PID" ssh-agent -k >/dev/null 2>&1 || true
  fi
  rm -rf "$MUSTER_ACTION_SSH_DIR"
  {
    echo "SSH_AUTH_SOCK="
    echo "SSH_AGENT_PID="
    echo "MUSTER_ACTION_SSH_DIR="
  } >> "${GITHUB_ENV:-/dev/null}"
fi
exit 0
