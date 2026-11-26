#!/usr/bin/env bash
# muster/lib/core/remote.sh — Remote execution wrapper (SSH, cloud, password auth)

# Check if a service has remote deployment enabled
# Usage: remote_is_enabled "svc"
# Returns 0 if enabled, 1 if not
remote_is_enabled() {
  local svc="$1"
  local enabled
  enabled=$(config_get ".services.${svc}.remote.enabled")
  [[ "$enabled" == "true" ]]
}

# Get remote config values for a service
# Sets: _REMOTE_HOST, _REMOTE_USER, _REMOTE_PORT, _REMOTE_IDENTITY, _REMOTE_PROJECT_DIR
#       _REMOTE_CLOUD, _REMOTE_AUTH_METHOD, _REMOTE_AUTH_MODE, _REMOTE_PASSWORD
_remote_load_config() {
  local svc="$1"
  _REMOTE_HOST=$(config_get ".services.${svc}.remote.host")
  _REMOTE_USER=$(config_get ".services.${svc}.remote.user")
  _REMOTE_PORT=$(config_get ".services.${svc}.remote.port")
  _REMOTE_PROJECT_DIR=$(config_get ".services.${svc}.remote.project_dir")

  # Cloud flag
  _REMOTE_CLOUD=$(config_get ".services.${svc}.remote.cloud")
  [[ "$_REMOTE_CLOUD" != "true" ]] && _REMOTE_CLOUD="false"

  # Auth block (with backwards-compat fallback for identity_file)
  _REMOTE_AUTH_METHOD=$(config_get ".services.${svc}.remote.auth.method")
  _REMOTE_AUTH_MODE=$(config_get ".services.${svc}.remote.auth.mode")
  local _auth_identity
  _auth_identity=$(config_get ".services.${svc}.remote.auth.identity_file")
  if [[ -n "$_auth_identity" && "$_auth_identity" != "null" ]]; then
    _REMOTE_IDENTITY="$_auth_identity"
  else
    _REMOTE_IDENTITY=$(config_get ".services.${svc}.remote.identity_file")
  fi

  # Defaults
  [[ "$_REMOTE_PORT" == "null" || -z "$_REMOTE_PORT" ]] && _REMOTE_PORT="22"
  [[ "$_REMOTE_IDENTITY" == "null" ]] && _REMOTE_IDENTITY=""
  [[ "$_REMOTE_PROJECT_DIR" == "null" ]] && _REMOTE_PROJECT_DIR=""
  [[ -z "$_REMOTE_AUTH_METHOD" || "$_REMOTE_AUTH_METHOD" == "null" ]] && _REMOTE_AUTH_METHOD="key"
  [[ "$_REMOTE_AUTH_MODE" == "null" ]] && _REMOTE_AUTH_MODE=""
  _REMOTE_PASSWORD=""
}

# Load SSH password using the credential system
# Requires _remote_load_config() to have been called first
_remote_load_ssh_password() {
  local svc="$1"
  local cred_key="ssh_${_REMOTE_USER}@${_REMOTE_HOST}:${_REMOTE_PORT}"

  case "$_REMOTE_AUTH_MODE" in
    save)
      _REMOTE_PASSWORD=$(_cred_keychain_get "remote" "$cred_key" 2>/dev/null) || true
      if [[ -z "$_REMOTE_PASSWORD" ]]; then
        _REMOTE_PASSWORD=$(_cred_prompt_password "SSH password for ${_REMOTE_USER}@${_REMOTE_HOST}")
        _cred_keychain_save "remote" "$cred_key" "$_REMOTE_PASSWORD" 2>/dev/null || true
      fi
      _cred_session_set "$cred_key" "$_REMOTE_PASSWORD"
      ;;
    session)
      _REMOTE_PASSWORD=$(_cred_session_get "$cred_key" 2>/dev/null) || true
      if [[ -z "$_REMOTE_PASSWORD" ]]; then
        _REMOTE_PASSWORD=$(_cred_prompt_password "SSH password for ${_REMOTE_USER}@${_REMOTE_HOST}")
        _cred_session_set "$cred_key" "$_REMOTE_PASSWORD"
      fi
      ;;
    always)
      _REMOTE_PASSWORD=$(_cred_prompt_password "SSH password for ${_REMOTE_USER}@${_REMOTE_HOST}")
      ;;
    *)
      _REMOTE_PASSWORD=""
      ;;
  esac
}

# Build SSH options array
# Sets: _SSH_OPTS (space-separated string of options)
_remote_build_opts() {
  _SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

  # BatchMode=yes prevents password prompts — only for key/agent auth
  if [[ "$_REMOTE_AUTH_METHOD" != "password" ]]; then
    _SSH_OPTS="${_SSH_OPTS} -o BatchMode=yes"
  fi

  if [[ -n "$_REMOTE_IDENTITY" ]]; then
    # Expand ~ to $HOME
    local id_path="$_REMOTE_IDENTITY"
    case "$id_path" in
      "~"/*) id_path="${HOME}/${id_path#\~/}" ;;
    esac
    _SSH_OPTS="${_SSH_OPTS} -i ${id_path}"
  fi

  if [[ "$_REMOTE_PORT" != "22" ]]; then
    _SSH_OPTS="${_SSH_OPTS} -p ${_REMOTE_PORT}"
  fi
}

# Run a hook script via SSH or cloud, outputting to stdout/stderr
# Usage: remote_exec_stdout "svc" "hook_file" "cred_env_lines"
# Designed to be passed to stream_in_box as the command
remote_exec_stdout() {
  local svc="$1"
  local hook_file="$2"
  local cred_env_lines="$3"

  _remote_load_config "$svc"
  [[ "$_REMOTE_AUTH_METHOD" == "password" ]] && _remote_load_ssh_password "$svc"

  if [[ "$_REMOTE_CLOUD" == "true" ]]; then
    # Per-service cloud remotes pipe the hook to the agent (push_hook), which
    # only works for agents joined with `--mode push`. Agents in muster mode
    # refuse it; _cloud_run_explained turns that into a clear message.
    source "$MUSTER_ROOT/lib/core/cloud.sh"
    # Cloud config should be pre-populated by caller or from global settings
    if [[ -z "${FLEET_CLOUD_RELAY:-}" ]]; then
      _groups_cloud_config 2>/dev/null || _fleet_cloud_config
    fi
    _cloud_run_explained "$_REMOTE_HOST" \
      _fleet_cloud_push "$_REMOTE_HOST" "$hook_file" "$cred_env_lines" "$_REMOTE_PROJECT_DIR"
    return $?
  fi

  _remote_build_opts

  # Build the wrapper script: export creds, cd to project dir, then run hook
  local _script=""
  if [[ -n "$cred_env_lines" ]]; then
    while IFS= read -r _cred_line; do
      [[ -z "$_cred_line" ]] && continue
      local _ck="${_cred_line%%=*}"
      local _cv="${_cred_line#*=}"
      _script="${_script}$(printf "export %s=%q\n" "$_ck" "$_cv")"
    done <<< "$cred_env_lines"
  fi
  if [[ -n "$_REMOTE_PROJECT_DIR" ]]; then
    _script="${_script}$(printf 'cd %q || exit 1\n' "$_REMOTE_PROJECT_DIR")"
  fi
  _script="${_script}$(cat "$hook_file")"

  if [[ "$_REMOTE_AUTH_METHOD" == "password" ]]; then
    export SSHPASS="$_REMOTE_PASSWORD"
    # shellcheck disable=SC2086
    printf '%s' "$_script" | sshpass -e ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "bash -s"
    local _rc=$?
    unset SSHPASS
    return $_rc
  else
    # shellcheck disable=SC2086
    printf '%s' "$_script" | ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "bash -s"
  fi
}

# Quick connectivity test (SSH or cloud)
# Usage: remote_check "svc"
# Returns 0 if reachable
remote_check() {
  local svc="$1"
  _remote_load_config "$svc"
  [[ "$_REMOTE_AUTH_METHOD" == "password" ]] && _remote_load_ssh_password "$svc"

  if [[ "$_REMOTE_CLOUD" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/cloud.sh"
    if [[ -z "${FLEET_CLOUD_RELAY:-}" ]]; then
      _groups_cloud_config 2>/dev/null || _fleet_cloud_config
    fi
    _fleet_cloud_check "$_REMOTE_HOST"
    return $?
  fi

  _remote_build_opts

  if [[ "$_REMOTE_AUTH_METHOD" == "password" ]]; then
    export SSHPASS="$_REMOTE_PASSWORD"
    # shellcheck disable=SC2086
    sshpass -e ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "echo ok" &>/dev/null
    local _rc=$?
    unset SSHPASS
    return $_rc
  else
    # shellcheck disable=SC2086
    ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "echo ok" &>/dev/null
  fi
}

# Return a display string for a remote service
# Usage: remote_desc "svc"
# Outputs: "user@host:port" or "host (cloud)"
remote_desc() {
  local svc="$1"
  _remote_load_config "$svc"

  if [[ "$_REMOTE_CLOUD" == "true" ]]; then
    printf '%s (cloud)' "$_REMOTE_HOST"
  else
    printf '%s@%s:%s' "$_REMOTE_USER" "$_REMOTE_HOST" "$_REMOTE_PORT"
  fi
}
