#!/usr/bin/env bash
# muster/lib/commands/fleet_sync.sh — Push hooks to remote machines + setup-user

# ── fleet sync ──

_fleet_cmd_sync() {
  local target="" dry_run="false" service_filter="" sync_all="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  dry_run="true"; shift ;;
      --service)  service_filter="$2"; shift 2 ;;
      --all)      sync_all="true"; shift ;;
      -*)         err "Unknown flag: $1"; return 1 ;;
      *)          target="$1"; shift ;;
    esac
  done

  if [[ -z "$target" && "$sync_all" == "false" ]]; then
    err "Usage: muster fleet sync <server|group> [--dry-run] [--service svc]"
    printf '%b\n' "  ${DIM}Or: muster fleet sync --all${RESET}"
    return 1
  fi

  fleet_load_config || {
    err "No remotes.json found — run: muster fleet init"
    return 1
  }

  # Resolve targets
  local machines=""
  if [[ "$sync_all" == "true" ]]; then
    machines=$(fleet_machines)
  else
    # Check if target is a group
    local group_machines
    group_machines=$(fleet_group_machines "$target" 2>/dev/null)
    if [[ -n "$group_machines" ]]; then
      machines="$group_machines"
    else
      # Single machine — verify it exists
      local exists
      exists=$(jq -r --arg n "$target" '.machines[$n] // empty' "$FLEET_CONFIG_FILE" 2>/dev/null)
      if [[ -z "$exists" ]]; then
        err "Server or group '${target}' not found"
        return 1
      fi
      machines="$target"
    fi
  fi

  local total=0 success=0 failed=0
  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Fleet sync${RESET}"
  echo ""

  while IFS= read -r machine; do
    [[ -z "$machine" ]] && continue
    total=$(( total + 1 ))

    if _fleet_sync_one "$machine" "$dry_run" "$service_filter"; then
      success=$(( success + 1 ))
    else
      failed=$(( failed + 1 ))
    fi
  done <<< "$machines"

  echo ""
  if [[ "$dry_run" == "true" ]]; then
    printf '%b\n' "  ${DIM}Dry run — no files were transferred${RESET}"
  else
    printf '%b\n' "  ${DIM}${success}/$(_fleet_plural "$total" server) synced${RESET}"
  fi
  echo ""

  (( failed > 0 )) && return 1
  return 0
}

# Sync hooks to a single machine
_fleet_sync_one() {
  local machine="$1" dry_run="${2:-false}" service_filter="${3:-}"

  _fleet_load_machine "$machine"
  fleet_require_ssh "$machine" "Hook sync" || return 1

  # Find local hooks dir — fleet dirs first, then project dir
  local hooks_dir=""
  if fleet_cfg_find_project "$machine" 2>/dev/null; then
    local _fleet_hooks
    _fleet_hooks="$(fleet_cfg_project_hooks_dir "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT")"
    if [[ -d "$_fleet_hooks" ]]; then
      hooks_dir="$_fleet_hooks"
    fi
  fi

  if [[ -z "$hooks_dir" ]]; then
    local project_dir
    if [[ -n "$CONFIG_FILE" ]]; then
      project_dir="$(dirname "$CONFIG_FILE")"
    else
      project_dir="$(pwd)"
    fi
    hooks_dir="${project_dir}/.muster/hooks"
  fi

  if [[ ! -d "$hooks_dir" ]]; then
    warn "No hooks directory at ${hooks_dir}"
    return 1
  fi

  # Resolve services to sync
  local services_list=""
  if [[ -n "$service_filter" ]]; then
    if [[ ! -d "${hooks_dir}/${service_filter}" ]]; then
      warn "No hooks for service '${service_filter}'"
      return 1
    fi
    services_list="$service_filter"
  else
    local d
    for d in "${hooks_dir}"/*/; do
      [[ ! -d "$d" ]] && continue
      local svc_name
      svc_name=$(basename "$d")
      [[ "$svc_name" == "logs" || "$svc_name" == "pids" ]] && continue
      if [[ -n "$services_list" ]]; then
        services_list="${services_list}
${svc_name}"
      else
        services_list="$svc_name"
      fi
    done
  fi

  if [[ -z "$services_list" ]]; then
    warn "No services to sync for ${machine}"
    return 1
  fi

  local remote_base="${_FM_PROJECT_DIR:-.}/.muster/hooks"
  local desc
  desc=$(fleet_desc "$machine")

  if [[ "$dry_run" == "true" ]]; then
    printf '%b\n' "  ${BOLD}${machine}${RESET} ${DIM}(${desc})${RESET}"
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      printf '%b\n' "    ${DIM}would sync: ${svc}/ → ${remote_base}/${svc}/${RESET}"
    done <<< "$services_list"
    return 0
  fi

  printf '%b\n' "  ${BOLD}${machine}${RESET} ${DIM}(${desc})${RESET}"

  case "$_FM_TRANSPORT" in
    ssh)  _fleet_sync_ssh "$machine" "$hooks_dir" "$remote_base" "$services_list" ;;
    cloud) _fleet_sync_cloud "$machine" "$hooks_dir" "$remote_base" "$services_list" ;;
    *)
      err "Unknown transport: ${_FM_TRANSPORT}"
      return 1
      ;;
  esac
}

# SSH-based sync via scp
_fleet_sync_ssh() {
  local machine="$1" hooks_dir="$2" remote_base="$3" services_list="$4"

  _fleet_load_machine "$machine"
  _fleet_build_opts

  # Build scp options from SSH opts
  local scp_opts="-o ConnectTimeout=10 -o StrictHostKeyChecking=${MUSTER_SSH_HOSTKEY_CHECK:-accept-new} -o BatchMode=yes"
  if [[ -n "$_FM_IDENTITY" ]]; then
    local id_path="$_FM_IDENTITY"
    case "$id_path" in
      "~"/*) id_path="${HOME}/${id_path#\~/}" ;;
    esac
    scp_opts="${scp_opts} -i ${id_path}"
  fi
  [[ "$_FM_PORT" != "22" ]] && scp_opts="${scp_opts} -P ${_FM_PORT}"

  # Ensure remote base dir exists
  # shellcheck disable=SC2086
  ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" "mkdir -p '${remote_base}'" 2>/dev/null || {
    warn "Failed to create remote directory"
    return 1
  }

  local sync_failed=0
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local local_svc_dir="${hooks_dir}/${svc}"
    [[ ! -d "$local_svc_dir" ]] && continue

    printf '%b\n' "    ${DIM}syncing ${svc}...${RESET}"

    # shellcheck disable=SC2086
    scp $scp_opts -r "$local_svc_dir" \
      "${_FM_USER}@${_FM_HOST}:${remote_base}/" 2>/dev/null || {
      warn "    failed to sync ${svc}"
      sync_failed=$(( sync_failed + 1 ))
      continue
    }

    # Set permissions on remote
    # shellcheck disable=SC2086
    ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" \
      "chmod 750 '${remote_base}/${svc}' 2>/dev/null; chmod 550 '${remote_base}/${svc}'/*.sh 2>/dev/null" \
      2>/dev/null || true

  done <<< "$services_list"

  # Distribute signing pubkey if signing is enabled
  _fleet_sync_pubkey "$machine"

  (( sync_failed > 0 )) && return 1
  ok "    synced to ${machine}"
  return 0
}

# Cloud-based sync (stub for muster-tunnel)
_fleet_sync_cloud() {
  local machine="$1" hooks_dir="$2" remote_base="$3" services_list="$4"

  warn "Cloud sync not yet implemented — use muster-tunnel sync manually"
  return 1
}

# Distribute signing public key to remote
_fleet_sync_pubkey() {
  local machine="$1"

  local signing
  signing=$(global_config_get "signing" 2>/dev/null || echo "off")
  [[ "$signing" != "on" ]] && return 0

  source "$MUSTER_ROOT/lib/core/payload_sign.sh"

  [[ ! -f "$_PAYLOAD_PUBKEY" ]] && return 0

  _fleet_load_machine "$machine"
  _fleet_build_opts

  local pubkey_content
  pubkey_content=$(cat "$_PAYLOAD_PUBKEY" 2>/dev/null)
  [[ -z "$pubkey_content" ]] && return 0

  local label
  label="$(whoami)@$(hostname -s 2>/dev/null || echo "unknown")"

  local fingerprint
  fingerprint=$(payload_fingerprint 2>/dev/null || echo "default")

  # Build the JSON for remote authorized_keys
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # SCP pubkey to remote, then run a script to add it to authorized_keys
  local scp_opts="-o ConnectTimeout=10 -o StrictHostKeyChecking=${MUSTER_SSH_HOSTKEY_CHECK:-accept-new} -o BatchMode=yes"
  if [[ -n "$_FM_IDENTITY" ]]; then
    local id_path="$_FM_IDENTITY"
    case "$id_path" in
      "~"/*) id_path="${HOME}/${id_path#\~/}" ;;
    esac
    scp_opts="${scp_opts} -i ${id_path}"
  fi
  [[ "$_FM_PORT" != "22" ]] && scp_opts="${scp_opts} -P ${_FM_PORT}"

  local remote_tmp="/tmp/.muster_pubkey_$$"

  # shellcheck disable=SC2086
  scp $scp_opts "$_PAYLOAD_PUBKEY" "${_FM_USER}@${_FM_HOST}:${remote_tmp}" 2>/dev/null || {
    warn "    failed to copy signing key"
    return 0
  }

  # Run script on remote to add key to authorized_keys JSON
  # Unquoted heredoc on purpose: local vars expand here, \$-escaped vars remotely
  # shellcheck disable=SC2086,SC2087
  ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" "bash -s" 2>/dev/null <<TRUST_EOF
AUTH_DIR="\$HOME/.muster/fleet/authorized_keys"
mkdir -p "\$AUTH_DIR" 2>/dev/null
chmod 700 "\$AUTH_DIR" 2>/dev/null
AUTH_FILE="\$AUTH_DIR/${fingerprint}.json"
[ ! -f "\$AUTH_FILE" ] && printf '{"keys":[]}\n' > "\$AUTH_FILE"
if command -v jq >/dev/null 2>&1; then
  PK=\$(cat "${remote_tmp}")
  TMP="\${AUTH_FILE}.tmp"
  jq --arg l "${label}" --arg pk "\$PK" --arg ts "${ts}" \
    'if (.keys | map(.label) | index(\$l)) then
       .keys = [.keys[] | if .label == \$l then .pubkey = \$pk | .added = \$ts else . end]
     else
       .keys += [{"label": \$l, "pubkey": \$pk, "added": \$ts}]
     end' "\$AUTH_FILE" > "\$TMP" && mv "\$TMP" "\$AUTH_FILE"
fi
chmod 600 "\$AUTH_FILE" 2>/dev/null
rm -f "${remote_tmp}"
TRUST_EOF
  # shellcheck disable=SC2181
  [[ $? -ne 0 ]] && warn "    failed to register signing key"

  return 0
}

# ── fleet setup-user ──

_fleet_cmd_setup_user() {
  local machine="" username="deploy" project_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)        username="$2"; shift 2 ;;
      --project-dir) project_dir="$2"; shift 2 ;;
      -*)            err "Unknown flag: $1"; return 1 ;;
      *)             machine="$1"; shift ;;
    esac
  done

  if [[ -z "$machine" ]]; then
    err "Usage: muster fleet setup-user <machine> [--user deploy] [--project-dir /opt/app]"
    return 1
  fi

  fleet_load_config || {
    err "No remotes.json found"
    return 1
  }

  _fleet_load_machine "$machine"
  fleet_require_ssh "$machine" "setup-user" || return 1

  [[ -z "$project_dir" ]] && project_dir="${_FM_PROJECT_DIR:-/opt/app}"

  local desc
  desc=$(fleet_desc "$machine")

  echo ""
  printf '%b\n' "  ${BOLD}Setup deploy user on ${machine}${RESET} ${DIM}(${desc})${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}This will:${RESET}"
  printf '%b\n' "  ${DIM}  1. Create user '${username}' on the remote${RESET}"
  printf '%b\n' "  ${DIM}  2. Create ${project_dir}/.muster/hooks/ owned by ${username}${RESET}"
  printf '%b\n' "  ${DIM}  3. Set up SSH authorized_keys for ${username}${RESET}"
  echo ""

  local reply=""
  if [[ ! -t 0 ]]; then
    err "setup-user needs an interactive terminal to confirm"
    return 1
  fi
  printf '  Continue? [y/N] '
  read -r reply || reply=""
  case "$reply" in
    y|Y) ;;
    *)
      info "Skipped"
      return 0
      ;;
  esac

  _fleet_build_opts

  # Detect remote platform
  local remote_os
  remote_os=$(fleet_exec "$machine" "uname -s" 2>/dev/null | tr -d '[:space:]')

  echo ""

  # Create user
  case "$remote_os" in
    Linux)
      printf '%b\n' "  ${DIM}Creating user '${username}'...${RESET}"
      # shellcheck disable=SC2086
      ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" \
        "id '${username}' &>/dev/null || sudo useradd -r -m -s /bin/bash '${username}'" 2>/dev/null || {
        warn "Failed to create user — you may need to do this manually"
      }
      ;;
    Darwin)
      printf '%b\n' "  ${DIM}Creating user '${username}'...${RESET}"
      # shellcheck disable=SC2086
      ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" \
        "id '${username}' &>/dev/null || sudo sysadminctl -addUser '${username}' -shell /bin/bash -home /Users/${username}" 2>/dev/null || {
        warn "Failed to create user — you may need to do this manually"
      }
      ;;
    *)
      warn "Unknown remote OS: ${remote_os} — create user '${username}' manually"
      ;;
  esac

  # Create project dirs
  printf '%b\n' "  ${DIM}Creating directories...${RESET}"
  # shellcheck disable=SC2086
  ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" \
    "sudo mkdir -p '${project_dir}/.muster/hooks' && sudo chown -R '${username}:${username}' '${project_dir}'" \
    2>/dev/null || {
    warn "Failed to create directories"
  }

  # Copy SSH key
  local local_pubkey=""
  if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    local_pubkey="$HOME/.ssh/id_ed25519.pub"
  elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
    local_pubkey="$HOME/.ssh/id_rsa.pub"
  fi

  if [[ -n "$local_pubkey" ]]; then
    printf '%b\n' "  ${DIM}Adding SSH key for ${username}...${RESET}"
    local pubkey_content
    pubkey_content=$(cat "$local_pubkey" 2>/dev/null)
    # shellcheck disable=SC2086
    ssh $_FLEET_SSH_OPTS "${_FM_USER}@${_FM_HOST}" \
      "sudo mkdir -p ~${username}/.ssh && sudo chmod 700 ~${username}/.ssh && echo '${pubkey_content}' | sudo tee -a ~${username}/.ssh/authorized_keys >/dev/null && sudo chmod 600 ~${username}/.ssh/authorized_keys && sudo chown -R '${username}:${username}' ~${username}/.ssh" \
      2>/dev/null || {
      warn "Failed to set up SSH key"
    }
  fi

  echo ""
  ok "Setup complete"
  echo ""
  printf '%b\n' "  ${DIM}Next steps:${RESET}"
  printf '%b\n' "  ${DIM}  Update the machine config:${RESET}"
  printf '%b\n' "  ${DIM}    muster fleet edit ${machine} --user ${username}${RESET}"
  echo ""
}
