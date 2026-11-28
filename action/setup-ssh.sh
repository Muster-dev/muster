#!/usr/bin/env bash
# action/setup-ssh.sh — load the deploy key into an ssh-agent and trust only
# the given host keys. The key never reaches the log; its temp file (0600)
# is deleted as soon as the agent holds it. Host key checking stays on.
set -euo pipefail

ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=action/lib.sh
source "${ACTION_ROOT}/action/lib.sh"

if [[ -z "${INPUT_KNOWN_HOSTS:-}" ]]; then
  _a_err "known-hosts is required with ssh-key (muster never disables host key checking). Get it with: ssh-keyscan -H your.host"
  exit 1
fi

umask 077
dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/muster-ssh.XXXXXX")
chmod 700 "$dir"
key="${dir}/id"
printf '%s\n' "$INPUT_SSH_KEY" | tr -d '\r' > "$key"
chmod 600 "$key"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
printf '%s\n' "$INPUT_KNOWN_HOSTS" | tr -d '\r' >> "$HOME/.ssh/known_hosts"
chmod 600 "$HOME/.ssh/known_hosts"

eval "$(ssh-agent -s)" >/dev/null
if ! ssh-add "$key" >/dev/null 2>&1; then
  rm -f "$key"
  ssh-agent -k >/dev/null 2>&1 || true
  _a_err "ssh-key could not be loaded (expected an unencrypted private key)"
  exit 1
fi
rm -f "$key"

{
  echo "SSH_AUTH_SOCK=${SSH_AUTH_SOCK}"
  echo "SSH_AGENT_PID=${SSH_AGENT_PID}"
  echo "MUSTER_ACTION_SSH_DIR=${dir}"
  echo "MUSTER_SSH_HOSTKEY_CHECK=yes"
} >> "$GITHUB_ENV"
echo "SSH key loaded into ssh-agent; $(printf '%s\n' "$INPUT_KNOWN_HOSTS" | grep -c . | tr -d ' ') known_hosts line(s) added"
