#!/usr/bin/env bash
# muster/lib/core/cloud.sh — Cloud transport helpers (shells out to muster-tunnel)

if ! declare -f _cred_keychain_get >/dev/null 2>&1; then
  source "$MUSTER_ROOT/lib/core/credentials.sh"
fi

# ── Binary detection ──

_fleet_cloud_available() {
  command -v muster-tunnel &>/dev/null || {
    [[ -x "$HOME/.muster/bin/muster-tunnel" ]] && return 0
    return 1
  }
}

_fleet_cloud_bin() {
  if command -v muster-tunnel &>/dev/null; then
    printf 'muster-tunnel'
  else
    printf '%s/.muster/bin/muster-tunnel' "$HOME"
  fi
}

# ── Cloud config (from remotes.json .cloud section) ──

# Re-sourcing this file (callers do it freely) must not wipe a config that
# is already loaded.
FLEET_CLOUD_RELAY="${FLEET_CLOUD_RELAY:-}"
FLEET_CLOUD_ORG="${FLEET_CLOUD_ORG:-}"
FLEET_CLOUD_TOKEN="${FLEET_CLOUD_TOKEN:-}"

_fleet_cloud_config() {
  # Skip if already configured (allows callers to pre-populate from other sources)
  [[ -n "${FLEET_CLOUD_RELAY:-}" && -n "${FLEET_CLOUD_TOKEN:-}" ]] && return 0

  # Per-project remotes.json .cloud section (fleet only)
  if declare -f fleet_get >/dev/null 2>&1; then
    FLEET_CLOUD_RELAY=$(fleet_get '.cloud.relay // ""' 2>/dev/null)
    FLEET_CLOUD_ORG=$(fleet_get '.cloud.org_id // ""' 2>/dev/null)
    local token_ref
    token_ref=$(fleet_get '.cloud.token_ref // ""' 2>/dev/null)
    if [[ -n "$token_ref" ]]; then
      FLEET_CLOUD_TOKEN=$(_fleet_cloud_token_get "$token_ref")
    fi
  fi

  # Fall back to the account from `muster cloud login`
  if [[ -z "$FLEET_CLOUD_RELAY" || -z "$FLEET_CLOUD_TOKEN" ]]; then
    local g_relay g_org g_ref
    g_relay=$(global_config_get "cloud.relay" 2>/dev/null)
    g_org=$(global_config_get "cloud.org_id" 2>/dev/null)
    g_ref=$(global_config_get "cloud.token_ref" 2>/dev/null)
    [[ -z "$FLEET_CLOUD_RELAY" && -n "$g_relay" && "$g_relay" != "null" ]] && FLEET_CLOUD_RELAY="$g_relay"
    [[ -z "$FLEET_CLOUD_ORG" && -n "$g_org" && "$g_org" != "null" ]] && FLEET_CLOUD_ORG="$g_org"
    if [[ -z "$FLEET_CLOUD_TOKEN" && -n "$g_ref" && "$g_ref" != "null" ]]; then
      FLEET_CLOUD_TOKEN=$(_fleet_cloud_token_get "$g_ref")
    fi
  fi
}

# ── Cloud token storage (~/.muster/cloud-tokens.json) ──

FLEET_CLOUD_TOKENS_FILE="$HOME/.muster/tokens/cloud.json"

_fleet_cloud_token_file() {
  if [[ ! -d "$HOME/.muster" ]]; then
    mkdir -p "$HOME/.muster"
    chmod 700 "$HOME/.muster"
  fi
  if [[ ! -d "$HOME/.muster/tokens" ]]; then
    mkdir -p "$HOME/.muster/tokens"
    chmod 700 "$HOME/.muster/tokens"
  fi
  # Migrate from old path
  if [[ -f "$HOME/.muster/cloud-tokens.json" && ! -f "$FLEET_CLOUD_TOKENS_FILE" ]]; then
    mv "$HOME/.muster/cloud-tokens.json" "$FLEET_CLOUD_TOKENS_FILE"
  fi
  if [[ ! -f "$FLEET_CLOUD_TOKENS_FILE" ]]; then
    printf '{"tokens":{}}\n' > "$FLEET_CLOUD_TOKENS_FILE"
  fi
  chmod 600 "$FLEET_CLOUD_TOKENS_FILE"
}

# Tokens live in the system keychain when one is available (macOS Keychain,
# secret-tool); the 0600 JSON file is the fallback for headless machines.
_fleet_cloud_keychain_ok() {
  [[ -z "${MUSTER_CLOUD_NO_KEYCHAIN:-}" ]] || return 1
  command -v security &>/dev/null || command -v secret-tool &>/dev/null
}

_fleet_cloud_token_get() {
  local name="$1"
  if _fleet_cloud_keychain_ok; then
    local kc
    kc=$(_cred_keychain_get "cloud" "token_${name}" 2>/dev/null) || kc=""
    if [[ -n "$kc" ]]; then
      printf '%s' "$kc"
      return 0
    fi
  fi
  _fleet_cloud_token_file
  local val
  val=$(jq -r --arg n "$name" '.tokens[$n] // ""' "$FLEET_CLOUD_TOKENS_FILE" 2>/dev/null)
  [[ -n "$val" && "$val" != "null" ]] && printf '%s' "$val"
}

_fleet_cloud_token_set() {
  local name="$1" token="$2"
  if _fleet_cloud_keychain_ok && _cred_keychain_save "cloud" "token_${name}" "$token"; then
    # Don't leave a plaintext copy behind
    _fleet_cloud_token_delete_file "$name"
    return 0
  fi
  _fleet_cloud_token_file
  local tmp="${FLEET_CLOUD_TOKENS_FILE}.tmp"
  jq --arg n "$name" --arg v "$token" '.tokens[$n] = $v' \
    "$FLEET_CLOUD_TOKENS_FILE" > "$tmp" && mv "$tmp" "$FLEET_CLOUD_TOKENS_FILE"
  chmod 600 "$FLEET_CLOUD_TOKENS_FILE"
}

_fleet_cloud_token_delete() {
  local name="$1"
  if _fleet_cloud_keychain_ok; then
    if command -v security &>/dev/null; then
      security delete-generic-password -a "muster-cloud" -s "muster-token_${name}" >/dev/null 2>&1 || true
    elif command -v secret-tool &>/dev/null; then
      secret-tool clear service "muster-cloud" key "token_${name}" >/dev/null 2>&1 || true
    fi
  fi
  _fleet_cloud_token_delete_file "$name"
}

_fleet_cloud_token_delete_file() {
  local name="$1"
  [[ -f "$FLEET_CLOUD_TOKENS_FILE" ]] || return 0
  local tmp="${FLEET_CLOUD_TOKENS_FILE}.tmp"
  jq --arg n "$name" 'del(.tokens[$n])' \
    "$FLEET_CLOUD_TOKENS_FILE" > "$tmp" && mv "$tmp" "$FLEET_CLOUD_TOKENS_FILE"
  chmod 600 "$FLEET_CLOUD_TOKENS_FILE"
}

# ── Transport primitives ──
#
# The cloud agent (muster-agent) runs `exec` commands WITHOUT a shell: the
# command line is split into argv, any shell metacharacter is rejected, and
# the leading words must match its allowlist (default: muster deploy, muster
# status, muster rollback, muster logs). Requests carry no env vars and
# `push_hook` only works when the agent is in push mode.
#
# So nothing in muster should send an SSH-style shell string over the cloud
# transport. Callers use _cloud_muster (an argv of plain words) instead, and
# _cloud_exec_plain refuses anything that would need a shell.

_fleet_cloud_tunnel_missing() {
  err "muster-tunnel not installed. Install: curl -fsSL https://getmuster.dev/fleet-cloud/install.sh | bash -s -- --tunnel"
}

# Low-level: muster-tunnel exec. Prefer _cloud_muster.
# Args: agent command [cwd]
_fleet_cloud_exec() {
  local machine="$1" cmd="$2" cwd="${3:-}"
  _fleet_cloud_config

  if ! _fleet_cloud_available; then
    _fleet_cloud_tunnel_missing
    return 1
  fi

  local bin
  bin=$(_fleet_cloud_bin)
  if [[ -n "$cwd" ]]; then
    MUSTER_CLOUD_TOKEN="$FLEET_CLOUD_TOKEN" "$bin" exec \
      --relay "$FLEET_CLOUD_RELAY" \
      --org "$FLEET_CLOUD_ORG" \
      --agent "$machine" \
      --cmd "$cmd" \
      --cwd "$cwd"
  else
    MUSTER_CLOUD_TOKEN="$FLEET_CLOUD_TOKEN" "$bin" exec \
      --relay "$FLEET_CLOUD_RELAY" \
      --org "$FLEET_CLOUD_ORG" \
      --agent "$machine" \
      --cmd "$cmd"
  fi
}

# Push a hook script (agent must be in push mode).
# Args: agent hook_file [env_lines] [cwd]
_fleet_cloud_push() {
  local machine="$1" hook_file="$2" env_lines="${3:-}" cwd="${4:-}"
  _fleet_cloud_config

  if ! _fleet_cloud_available; then
    _fleet_cloud_tunnel_missing
    return 1
  fi

  local bin
  bin=$(_fleet_cloud_bin)

  local env_csv=""
  if [[ -n "$env_lines" ]]; then
    local _env_line
    while IFS= read -r _env_line; do
      [[ -z "$_env_line" ]] && continue
      if [[ "$_env_line" == *,* ]]; then
        # muster-tunnel splits --env on commas
        err "Env value for ${_env_line%%=*} contains a comma; it can't be sent over the cloud transport"
        return 1
      fi
      if [[ -n "$env_csv" ]]; then
        env_csv="${env_csv},${_env_line}"
      else
        env_csv="$_env_line"
      fi
    done <<< "$env_lines"
  fi

  local args=()
  args[${#args[@]}]="push"
  args[${#args[@]}]="--relay"; args[${#args[@]}]="$FLEET_CLOUD_RELAY"
  args[${#args[@]}]="--org"; args[${#args[@]}]="$FLEET_CLOUD_ORG"
  args[${#args[@]}]="--agent"; args[${#args[@]}]="$machine"
  args[${#args[@]}]="--hook"; args[${#args[@]}]="$hook_file"
  if [[ -n "$env_csv" ]]; then
    args[${#args[@]}]="--env"; args[${#args[@]}]="$env_csv"
  fi
  if [[ -n "$cwd" ]]; then
    args[${#args[@]}]="--cwd"; args[${#args[@]}]="$cwd"
  fi

  MUSTER_CLOUD_TOKEN="$FLEET_CLOUD_TOKEN" "$bin" "${args[@]}"
}

# Relay-level reachability (muster-tunnel ping → agent HEARTBEAT).
_fleet_cloud_check() {
  local machine="$1"
  _fleet_cloud_config

  if ! _fleet_cloud_available; then
    return 1
  fi

  local bin
  bin=$(_fleet_cloud_bin)
  MUSTER_CLOUD_TOKEN="$FLEET_CLOUD_TOKEN" "$bin" ping \
    --relay "$FLEET_CLOUD_RELAY" \
    --org "$FLEET_CLOUD_ORG" \
    --agent "$machine" >/dev/null 2>&1
}

# ── Plain-argv helpers ──

# A word the agent accepts as-is: no whitespace, quotes or shell
# metacharacters. Deliberately an allowlist of characters.
_CLOUD_WORD_RE='^[A-Za-z0-9._/:=@%+,-]+$'

_cloud_word_ok() {
  [[ "$1" =~ $_CLOUD_WORD_RE ]]
}

# The cloud agent name for a fleet machine. Cloud machines are added as
# `muster fleet add <name> <user>@<agent> --transport cloud`, so the agent is
# the host part (same as groups); fall back to the machine name.
_fleet_cloud_agent() {
  local machine="$1"
  _fleet_load_machine "$machine" 2>/dev/null || true
  if [[ -n "${_FM_HOST:-}" && "$_FM_HOST" != "null" ]]; then
    printf '%s' "$_FM_HOST"
  else
    printf '%s' "$machine"
  fi
}

# Run `muster <args…> --no-verify` on a cloud agent as a plain argv.
# Args: agent cwd arg...
#   cwd: absolute project dir on the agent, or "" for the agent's own
#        project dir (set at `muster-agent join --project`).
# Returns the remote exit code (1 on local validation errors).
_cloud_muster() {
  local agent="$1" cwd="$2"
  shift 2

  if [[ -n "$cwd" && "$cwd" != /* ]]; then
    err "Cloud project dir must be an absolute path (got: ${cwd})"
    return 1
  fi
  if [[ -n "$cwd" ]] && ! _cloud_word_ok "$cwd"; then
    err "Cloud project dir contains characters the agent can't accept: ${cwd}"
    return 1
  fi

  local cmd="muster" a
  for a in "$@"; do
    if ! _cloud_word_ok "$a"; then
      err "Refusing to send '${a}' to cloud agent ${agent}: only plain words are allowed (no spaces, quotes or shell characters)"
      return 1
    fi
    cmd="${cmd} ${a}"
  done
  # The agent passes no env vars, so use the flag form of MUSTER_NO_VERIFY
  cmd="${cmd} --no-verify"

  _fleet_cloud_exec "$agent" "$cmd" "$cwd"
}

# Bridge for generic call sites (fleet_exec, groups_remote_exec): forwards a
# command only if it is already a plain argv; anything that needs a shell is
# refused locally with a clear message instead of being rejected remotely.
# Args: agent cmd [cwd]
_cloud_exec_plain() {
  local agent="$1" cmd="$2" cwd="${3:-}"
  local words=() w
  set -f
  for w in $cmd; do
    words[${#words[@]}]="$w"
  done
  set +f
  if (( ${#words[@]} == 0 )); then
    return 1
  fi
  for w in "${words[@]}"; do
    if ! _cloud_word_ok "$w"; then
      printf 'Not supported over the cloud transport (needs a shell on %s): %s\n' "$agent" "$cmd" >&2
      return 1
    fi
  done
  if [[ "${words[0]}" != "muster" ]]; then
    printf 'Not supported over the cloud transport (only muster commands run on %s): %s\n' "$agent" "$cmd" >&2
    return 1
  fi
  _fleet_cloud_exec "$agent" "$cmd" "$cwd"
}

# `muster status --json` on a cloud agent. Prints the JSON on success.
# Args: agent cwd
_cloud_status_json() {
  local agent="$1" cwd="$2" out
  out=$(_cloud_muster "$agent" "$cwd" status --json 2>/dev/null) || true
  # Drop any non-JSON preamble lines before the object
  out=$(printf '%s\n' "$out" | sed -n '/^{/,$p')
  if [[ -n "$out" ]] && printf '%s' "$out" | jq -e '.services' >/dev/null 2>&1; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

# "<healthy>/<total> healthy" from muster status --json output.
_cloud_status_summary() {
  local json="$1" total healthy
  local disabled
  total=$(printf '%s' "$json" | jq '[.services | to_entries[] | select(.value.status != "disabled")] | length' 2>/dev/null)
  healthy=$(printf '%s' "$json" | jq '[.services | to_entries[] | select(.value.status == "healthy")] | length' 2>/dev/null)
  disabled=$(printf '%s' "$json" | jq '[.services | to_entries[] | select(.value.status == "disabled")] | length' 2>/dev/null)
  if [[ "${total:-0}" == "0" && "${disabled:-0}" != "0" ]]; then
    printf 'health checks off'
  elif [[ "${disabled:-0}" != "0" ]]; then
    printf '%s/%s healthy, %s unchecked' "${healthy:-0}" "${total:-0}" "$disabled"
  else
    printf '%s/%s healthy' "${healthy:-0}" "${total:-0}"
  fi
}

# True when no service reports "unhealthy".
_cloud_status_all_healthy() {
  local json="$1" bad
  bad=$(printf '%s' "$json" | jq '[.services | to_entries[] | select(.value.status == "unhealthy")] | length' 2>/dev/null)
  [[ "$bad" == "0" ]]
}

# Translate known failure output into an actionable message (printed to
# stdout, so it lands in the same log/stream as the failure).
# Args: machine_label output_file
_cloud_explain_failure() {
  local label="$1" file="$2"
  [[ -f "$file" ]] || return 1
  if grep -q -e "approved on this machine" -e "Hooks not approved" "$file" 2>/dev/null; then
    printf "Hooks on %s aren't approved yet. On that machine run: muster hooks approve\n" "$label"
  elif grep -q "push_hook is disabled" "$file" 2>/dev/null; then
    printf "The agent on %s is not in push mode, so it won't run pushed hooks.\n" "$label"
    printf "Either deploy it in muster mode (muster installed on that machine; muster fleet add ... --mode muster --transport cloud),\n"
    printf "or enable push mode on the agent: muster-agent join --mode push\n"
  elif grep -q "not in allowlist" "$file" 2>/dev/null; then
    printf "The agent on %s refused the command (not in its allowed_commands).\n" "$label"
    printf "Add it to allowed_commands in ~/.muster-agent/config.json on that machine.\n"
  elif grep -q -e "E_NOT_CONNECTED" -e "not connected" "$file" 2>/dev/null; then
    printf "Cloud agent %s is not connected to the relay. Check muster-agent on that machine.\n" "$label"
  elif grep -q -e "auth_required" -e "auth_failed" "$file" 2>/dev/null; then
    printf "muster on %s refused the request (auth). Update muster on that machine.\n" "$label"
  else
    return 1
  fi
  return 0
}

# Run a command, tee its output, and explain known failures afterwards.
# Args: machine_label cmd...
_cloud_run_explained() {
  local label="$1"
  shift
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/muster-cloud.XXXXXX") || {
    "$@"
    return $?
  }
  "$@" 2>&1 | tee "$tmp"
  local rc=${PIPESTATUS[0]}
  if (( rc != 0 )); then
    _cloud_explain_failure "$label" "$tmp" || true
  fi
  rm -f "$tmp"
  return "$rc"
}
