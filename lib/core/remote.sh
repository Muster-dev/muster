#!/usr/bin/env bash
# muster/lib/core/remote.sh — SSH remote execution wrapper

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
_remote_load_config() {
  local svc="$1"
  _REMOTE_HOST=$(config_get ".services.${svc}.remote.host")
  _REMOTE_USER=$(config_get ".services.${svc}.remote.user")
  _REMOTE_PORT=$(config_get ".services.${svc}.remote.port")
  _REMOTE_IDENTITY=$(config_get ".services.${svc}.remote.identity_file")
  _REMOTE_PROJECT_DIR=$(config_get ".services.${svc}.remote.project_dir")

  # Defaults
  [[ "$_REMOTE_PORT" == "null" || -z "$_REMOTE_PORT" ]] && _REMOTE_PORT="22"
  [[ "$_REMOTE_IDENTITY" == "null" ]] && _REMOTE_IDENTITY=""
  [[ "$_REMOTE_PROJECT_DIR" == "null" ]] && _REMOTE_PROJECT_DIR=""
}

# Build SSH options array
# Sets: _SSH_OPTS (space-separated string of options)
_remote_build_opts() {
  _SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

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

# Run a hook script via SSH, outputting to stdout/stderr
# Usage: remote_exec_stdout "svc" "hook_file" "cred_env_lines"
# Designed to be passed to stream_in_box as the command
remote_exec_stdout() {
  local svc="$1"
  local hook_file="$2"
  local cred_env_lines="$3"

  _remote_load_config "$svc"
  _remote_build_opts

  # Build the wrapper: export creds, cd to project dir, then run hook
  {
    # Export credential env vars
    if [[ -n "$cred_env_lines" ]]; then
      while IFS= read -r _cred_line; do
        [[ -z "$_cred_line" ]] && continue
        local _ck="${_cred_line%%=*}"
        local _cv="${_cred_line#*=}"
        printf "export %s=%q\n" "$_ck" "$_cv"
      done <<< "$cred_env_lines"
    fi

    # cd to project directory if set
    if [[ -n "$_REMOTE_PROJECT_DIR" ]]; then
      printf 'cd %q || exit 1\n' "$_REMOTE_PROJECT_DIR"
    fi

    # Pipe the hook script content
    cat "$hook_file"
  } | ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "bash -s"
}

# Quick SSH connectivity test
# Usage: remote_check "svc"
# Returns 0 if reachable
remote_check() {
  local svc="$1"
  _remote_load_config "$svc"
  _remote_build_opts

  ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "echo ok" &>/dev/null
}

# Return a display string for a remote service
# Usage: remote_desc "svc"
# Outputs: "user@host:port"
remote_desc() {
  local svc="$1"
  _remote_load_config "$svc"

  printf '%s@%s:%s' "$_REMOTE_USER" "$_REMOTE_HOST" "$_REMOTE_PORT"
}
