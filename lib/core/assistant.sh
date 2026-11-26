#!/usr/bin/env bash
# muster/lib/core/assistant.sh — Muster Assistant availability + consent
#
# Small and dependency-light so `muster deploy` can ask "should I offer
# Explain with AI?" without loading the whole assistant client.

MUSTER_ASSIST_DEFAULT_URL="https://cloud.getmuster.dev"

# Base URL of the assistant server (no trailing slash)
_assistant_url() {
  local url="${MUSTER_ASSIST_URL:-}"
  if [[ -z "$url" ]]; then
    url=$(global_config_get "cloud.assist_url" 2>/dev/null)
    [[ "$url" == "null" ]] && url=""
  fi
  [[ -z "$url" ]] && url="$MUSTER_ASSIST_DEFAULT_URL"
  printf '%s' "${url%/}"
}

# True when the global kill switch is on (muster settings --global assistant off)
_assistant_disabled() {
  local v
  v=$(global_config_get "assistant" 2>/dev/null)
  [[ "$v" == "off" ]]
}

# The Fleet Cloud CLI token (empty when not logged in)
_assistant_token() {
  if ! declare -f _fleet_cloud_token_get >/dev/null 2>&1; then
    source "$MUSTER_ROOT/lib/core/cloud.sh"
  fi
  _fleet_cloud_token_get default 2>/dev/null
}

# True when `muster ask` can run: not disabled, curl + jq present, logged in
_assistant_available() {
  _assistant_disabled && return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [[ -n "$(_assistant_token)" ]]
}

# ── Per-project consent (.muster/assistant.json, gitignored) ──

_assistant_consent_file() {
  printf '%s/.muster/assistant.json' "$1"
}

_assistant_has_consent() {
  local f
  f=$(_assistant_consent_file "$1")
  [[ -f "$f" ]] || return 1
  [[ "$(jq -r '.consent // false' "$f" 2>/dev/null)" == "true" ]]
}

_assistant_save_consent() {
  local project_dir="$1" f who ts
  f=$(_assistant_consent_file "$project_dir")
  mkdir -p "$(dirname "$f")"
  who=$(whoami 2>/dev/null || echo "")
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  jq -n --arg who "$who" --arg ts "$ts" \
    '{consent: true, granted_at: $ts, granted_by: $who}' > "$f" || return 1
  chmod 600 "$f" 2>/dev/null || true

  # Keep it out of git (it is per-person, per-machine)
  local gi="${project_dir}/.gitignore"
  if [[ -f "$gi" ]]; then
    grep -qF '.muster/assistant.json' "$gi" 2>/dev/null || printf '%s\n' '.muster/assistant.json' >> "$gi"
  elif [[ -d "${project_dir}/.git" ]]; then
    printf '%s\n' '.muster/assistant.json' > "$gi"
  fi
}
