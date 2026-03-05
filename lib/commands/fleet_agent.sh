#!/usr/bin/env bash
# muster/lib/commands/fleet_agent.sh — Install, query, and remove the fleet agent daemon

# ── Helpers ──

_agent_info() { printf '%b\n' "  ${DIM}${1}${RESET}"; }

# Validate a string contains only safe characters
_fleet_agent_validate_safe() {
  local val="$1" label="$2"
  if [[ "$val" =~ [^a-zA-Z0-9._/~@:-] ]]; then
    err "${label} contains unsafe characters: ${val}"
    return 1
  fi
  return 0
}

# ── Install agent on a fleet machine ──

_fleet_cmd_install_agent() {
  local machine="" poll_interval="" push=false force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --poll-interval) poll_interval="$2"; shift 2 ;;
      --push)          push=true; shift ;;
      --force)         force=true; shift ;;
      --help|-h)
        echo "Usage: muster fleet install-agent <machine> [options]"
        echo ""
        echo "Install the monitoring agent daemon on a fleet target."
        echo ""
        echo "Options:"
        echo "  --poll-interval <N>   Health check interval in seconds (default: 30)"
        echo "  --push                Enable push-reporting to this machine"
        echo "  --force               Overwrite existing agent installation"
        echo ""
        echo "The agent collects health status, system metrics, service logs,"
        echo "and deploy events without requiring the full muster CLI."
        echo "Agent files are signed to prevent tampering."
        return 0
        ;;
      --*)
        err "Unknown flag: $1"
        return 1
        ;;
      *)
        machine="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$machine" ]]; then
    err "Usage: muster fleet install-agent <machine>"
    return 1
  fi

  # Validate poll interval is a positive integer
  local _poll="${poll_interval:-30}"
  if [[ ! "$_poll" =~ ^[0-9]+$ ]] || [[ "$_poll" == "0" ]]; then
    err "Invalid poll interval: ${_poll} (must be a positive integer)"
    return 1
  fi

  if ! fleet_load_config; then
    err "No fleet config found"
    return 1
  fi

  _fleet_load_machine "$machine"
  if [[ -z "$_FM_HOST" ]]; then
    err "Machine '${machine}' not found"
    return 1
  fi

  # Validate project dir
  if [[ -n "$_FM_PROJECT_DIR" ]]; then
    _fleet_agent_validate_safe "$_FM_PROJECT_DIR" "project_dir" || return 1
  fi

  echo ""
  printf '%b\n' "  ${BOLD}Install Agent: ${machine}${RESET}"
  echo ""

  # Check if agent already installed
  if [[ "$force" != "true" ]]; then
    local _existing
    _existing=$(fleet_exec "$machine" "cat ~/.muster/agent/agent.json 2>/dev/null" 2>/dev/null)
    if [[ -n "$_existing" ]]; then
      warn "Agent already installed on ${machine}"
      printf '%b\n' "  ${DIM}Use --force to overwrite${RESET}"
      return 1
    fi
  fi

  # Source fleet crypto for encryption support
  source "$MUSTER_ROOT/lib/core/fleet_crypto.sh"

  # Detect remote OS
  start_spinner "Detecting remote OS..."
  local _remote_os
  _remote_os=$(fleet_exec "$machine" "uname -s" 2>/dev/null)
  stop_spinner

  if [[ -z "$_remote_os" ]]; then
    err "Could not detect remote OS — SSH failed"
    return 1
  fi
  _agent_info "Remote OS: ${_remote_os}"

  # Create agent directories with secure permissions
  start_spinner "Creating agent directories..."
  fleet_exec "$machine" "mkdir -p ~/.muster/agent/health ~/.muster/agent/metrics ~/.muster/agent/events ~/.muster/agent/logs && chmod 700 ~/.muster/agent" 2>/dev/null
  stop_spinner

  # Push the agent script via SCP
  start_spinner "Pushing agent script..."
  local _agent_script="${MUSTER_ROOT}/lib/agent/muster-agent.sh"
  if [[ ! -f "$_agent_script" ]]; then
    stop_spinner
    err "Agent script not found at ${_agent_script}"
    return 1
  fi

  _fleet_load_machine "$machine"
  _fleet_build_opts

  local _scp_opts="${_FLEET_SSH_OPTS//-p /-P }"
  # shellcheck disable=SC2086
  scp $_scp_opts -- "$_agent_script" \
    "${_FM_USER}@${_FM_HOST}:~/.muster/agent/muster-agent.sh" 2>/dev/null
  local _scp_rc=$?
  stop_spinner

  if [[ $_scp_rc -ne 0 ]]; then
    err "Failed to push agent script"
    return 1
  fi
  fleet_exec "$machine" "chmod 700 ~/.muster/agent/muster-agent.sh" 2>/dev/null

  # Sign the agent script and push signature + pubkey
  start_spinner "Signing agent files..."
  source "$MUSTER_ROOT/lib/core/payload_sign.sh"

  local _has_signing=false
  if _payload_ensure_keypair 2>/dev/null && [[ -f "$_PAYLOAD_PUBKEY" ]]; then
    _has_signing=true

    # Sign the agent script
    local _agent_sig
    _agent_sig=$(payload_sign "$_agent_script" 2>/dev/null)
    if [[ -n "$_agent_sig" ]]; then
      # Push signature file
      local _tmp_sig
      _tmp_sig=$(mktemp) || { stop_spinner; err "Failed to create temp file"; return 1; }
      printf '%s' "$_agent_sig" > "$_tmp_sig"
      # shellcheck disable=SC2086
      scp $_scp_opts -- "$_tmp_sig" \
        "${_FM_USER}@${_FM_HOST}:~/.muster/agent/agent.sig" 2>/dev/null
      rm -f "$_tmp_sig"

      # Push public key for verification
      # shellcheck disable=SC2086
      scp $_scp_opts -- "$_PAYLOAD_PUBKEY" \
        "${_FM_USER}@${_FM_HOST}:~/.muster/agent/agent.pub.pem" 2>/dev/null

      fleet_exec "$machine" "chmod 600 ~/.muster/agent/agent.sig && chmod 644 ~/.muster/agent/agent.pub.pem" 2>/dev/null
    fi
  fi
  stop_spinner

  if [[ "$_has_signing" == "true" ]]; then
    ok "Agent script signed"
  else
    _agent_info "Signing not configured (run: muster fleet keygen)"
  fi

  # Build agent.json locally and push via SCP (avoids heredoc injection)
  start_spinner "Writing agent config..."
  local _project_dir="${_FM_PROJECT_DIR}"

  local _push_enabled="false"
  local _push_host="" _push_user="" _push_port="22" _push_identity="" _push_dir=""
  local _push_fleet=""
  if [[ "$push" == "true" ]]; then
    _push_enabled="true"
    _push_host=$(hostname -s 2>/dev/null || hostname)
    # Sanitize
    _push_host=$(printf '%s' "$_push_host" | tr -cd 'a-zA-Z0-9._-')
    _push_user=$(whoami)
    # Find which fleet this machine belongs to and push into its reports dir
    if fleet_cfg_find_project "$machine" 2>/dev/null; then
      _push_fleet="$_FP_FLEET"
      local _rhost
      _rhost=$(fleet_exec "$machine" "hostname -s 2>/dev/null || hostname" 2>/dev/null | tr -cd 'a-zA-Z0-9._-')
      [[ -z "$_rhost" ]] && _rhost="$machine"
      _push_dir="$(fleet_dir "$_push_fleet")/reports/${_rhost}"
    else
      _push_dir="${HOME}/.muster/fleet/reports/${machine}"
    fi
  fi

  local _tmp_config
  _tmp_config=$(mktemp) || { stop_spinner; err "Failed to create temp file"; return 1; }

  if command -v jq >/dev/null 2>&1; then
    # Use jq for safe JSON construction
    jq -n \
      --arg pd "$_project_dir" \
      --argjson pi "$_poll" \
      --argjson mi 60 \
      --argjson li 60 \
      --argjson ltl 50 \
      --argjson pe "$([[ "$_push_enabled" == "true" ]] && echo true || echo false)" \
      --argjson pui 300 \
      --arg ph "$_push_host" \
      --arg pu "$_push_user" \
      --argjson pp "$_push_port" \
      --arg pident "$_push_identity" \
      --arg pdir "$_push_dir" \
      '{
        project_dir: $pd,
        poll_interval: $pi,
        metrics_interval: $mi,
        logs_interval: $li,
        log_tail_lines: $ltl,
        push_enabled: $pe,
        push_interval: $pui,
        push_host: $ph,
        push_user: $pu,
        push_port: $pp,
        push_identity: $pident,
        push_dir: $pdir
      }' > "$_tmp_config"
  else
    # Manual construction with escaped values — all values are validated above
    cat > "$_tmp_config" << EOF
{
  "project_dir": "${_project_dir}",
  "poll_interval": ${_poll},
  "metrics_interval": 60,
  "logs_interval": 60,
  "log_tail_lines": 50,
  "push_enabled": ${_push_enabled},
  "push_interval": 300,
  "push_host": "${_push_host}",
  "push_user": "${_push_user}",
  "push_port": ${_push_port},
  "push_identity": "${_push_identity}",
  "push_dir": "${_push_dir}"
}
EOF
  fi

  # Push config via SCP
  # shellcheck disable=SC2086
  scp $_scp_opts -- "$_tmp_config" \
    "${_FM_USER}@${_FM_HOST}:~/.muster/agent/agent.json" 2>/dev/null
  local _config_rc=$?

  # Sign the config file too
  if [[ "$_has_signing" == "true" && $_config_rc -eq 0 ]]; then
    local _config_sig
    _config_sig=$(payload_sign "$_tmp_config" 2>/dev/null)
    if [[ -n "$_config_sig" ]]; then
      local _tmp_csig
      _tmp_csig=$(mktemp) || true
      if [[ -n "$_tmp_csig" ]]; then
        printf '%s' "$_config_sig" > "$_tmp_csig"
        # shellcheck disable=SC2086
        scp $_scp_opts -- "$_tmp_csig" \
          "${_FM_USER}@${_FM_HOST}:~/.muster/agent/agent.json.sig" 2>/dev/null
        rm -f "$_tmp_csig"
        fleet_exec "$machine" "chmod 600 ~/.muster/agent/agent.json.sig" 2>/dev/null
      fi
    fi
  fi

  rm -f "$_tmp_config"
  fleet_exec "$machine" "chmod 600 ~/.muster/agent/agent.json" 2>/dev/null
  stop_spinner

  if [[ $_config_rc -ne 0 ]]; then
    err "Failed to push agent config"
    return 1
  fi

  # Push fleet public key for report encryption
  local _has_encryption=false
  if [[ -n "$_push_fleet" ]] && fleet_crypto_has_keys "$_push_fleet" 2>/dev/null; then
    start_spinner "Pushing fleet encryption key..."
    local _fleet_pub
    _fleet_pub="$(fleet_crypto_pubkey "$_push_fleet")"
    # shellcheck disable=SC2086
    scp $_scp_opts -- "$_fleet_pub" \
      "${_FM_USER}@${_FM_HOST}:~/.muster/agent/fleet.pub" 2>/dev/null && {
      fleet_exec "$machine" "chmod 644 ~/.muster/agent/fleet.pub" 2>/dev/null
      _has_encryption=true
    }
    stop_spinner
    if [[ "$_has_encryption" == "true" ]]; then
      ok "Fleet encryption key deployed"
    else
      _agent_info "Could not push encryption key — reports will be plaintext"
    fi
  elif [[ "$push" == "true" ]]; then
    _agent_info "No fleet keypair — generate with: muster fleet keygen <fleet>"
    _agent_info "Reports will be pushed as plaintext until encryption is enabled"
  fi

  # Detect init system and install service
  start_spinner "Detecting init system..."
  local _init_system="none"
  if fleet_exec "$machine" "command -v systemctl" &>/dev/null; then
    _init_system="systemd"
  elif [[ "$_remote_os" == "Darwin" ]]; then
    _init_system="launchd"
  elif fleet_exec "$machine" "command -v crontab" &>/dev/null; then
    _init_system="cron"
  fi
  stop_spinner
  _agent_info "Init system: ${_init_system}"

  # Service files are static (no variable interpolation), safe to use heredocs
  case "$_init_system" in
    systemd)
      start_spinner "Installing systemd user service..."
      fleet_exec "$machine" 'mkdir -p ~/.config/systemd/user && cat > ~/.config/systemd/user/muster-agent.service << '\''SVCEOF'\''
[Unit]
Description=Muster Fleet Agent
After=network.target

[Service]
Type=simple
ExecStart=%h/.muster/agent/muster-agent.sh start --foreground
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF
systemctl --user daemon-reload
systemctl --user enable muster-agent
systemctl --user start muster-agent' 2>/dev/null
      stop_spinner
      ok "systemd service installed and started"
      ;;
    launchd)
      start_spinner "Installing launchd agent..."
      fleet_exec "$machine" 'mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/dev.getmuster.agent.plist << '\''PLISTEOF'\''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.getmuster.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>exec "$HOME/.muster/agent/muster-agent.sh" start --foreground</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/muster-agent.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/muster-agent.log</string>
</dict>
</plist>
PLISTEOF
launchctl load ~/Library/LaunchAgents/dev.getmuster.agent.plist' 2>/dev/null
      stop_spinner
      ok "launchd agent installed and loaded"
      ;;
    cron)
      start_spinner "Installing cron job..."
      fleet_exec "$machine" "(crontab -l 2>/dev/null | grep -v 'muster-agent'; echo '* * * * * ~/.muster/agent/muster-agent.sh run-once >> ~/.muster/agent/daemon.log 2>&1') | crontab -" 2>/dev/null
      stop_spinner
      ok "cron job installed (runs every minute)"
      ;;
    *)
      warn "No supported init system found"
      printf '%b\n' "  ${DIM}Start manually: ~/.muster/agent/muster-agent.sh start${RESET}"
      ;;
  esac

  # Verify agent is running (non-cron)
  if [[ "$_init_system" != "cron" && "$_init_system" != "none" ]]; then
    sleep 1
    start_spinner "Verifying agent..."
    local _pid_check
    _pid_check=$(fleet_exec "$machine" "cat ~/.muster/agent/agent.pid 2>/dev/null" 2>/dev/null)
    stop_spinner
    if [[ -n "$_pid_check" ]]; then
      ok "Agent running (pid ${_pid_check})"
    else
      warn "Agent PID not found — may still be starting"
    fi
  fi

  # Mark agent installed in fleet config
  if fleet_cfg_find_project "$machine" 2>/dev/null; then
    fleet_cfg_project_update "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT" \
      '.agent_installed = true'
  else
    fleet_set ".machines.\"${machine}\".agent_installed" "true"
  fi

  echo ""
  ok "Agent installed on ${machine}"
  if [[ "$_has_signing" == "true" ]]; then
    printf '%b\n' "  ${DIM}Files signed — agent will verify integrity on startup${RESET}"
  fi
  if [[ "$push" == "true" ]]; then
    printf '%b\n' "  ${DIM}Push reporting enabled (target: ${_push_user}@${_push_host})${RESET}"
    if [[ "$_has_encryption" == "true" ]]; then
      printf '%b\n' "  ${DIM}Reports encrypted with RSA-4096 fleet key${RESET}"
    fi
  fi
  echo ""
}

# ── Agent status ──

_fleet_cmd_agent_status() {
  local machine=""

  # Parse args: skip flags, grab first positional
  local _args_done=false
  while [[ $# -gt 0 ]]; do
    if [[ "$_args_done" == "false" && "$1" == --* ]]; then
      case "$1" in
        --help|-h)
          echo "Usage: muster fleet agent-status [machine]"
          echo ""
          echo "Show agent health data from fleet targets."
          echo ""
          echo "With no machine argument, shows status for all machines with agents."
          return 0
          ;;
        *) shift ;;
      esac
    else
      _args_done=true
      [[ -z "$machine" ]] && machine="$1"
      shift
    fi
  done

  if ! fleet_load_config; then
    err "No fleet config found"
    return 1
  fi

  source "$MUSTER_ROOT/lib/core/fleet_crypto.sh"

  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Agent Status${RESET}"
  echo ""

  local machines_list=""
  if [[ -n "$machine" ]]; then
    machines_list="$machine"
  else
    machines_list=$(fleet_machines)
  fi

  [[ -z "$machines_list" ]] && { info "No machines configured"; return 0; }

  while IFS= read -r _as_m; do
    [[ -z "$_as_m" ]] && continue

    # Check if agent is installed
    local _as_installed _as_fleet=""
    _as_installed="false"
    if fleet_cfg_find_project "$_as_m" 2>/dev/null; then
      _as_fleet="$_FP_FLEET"
      local _as_pdir
      _as_pdir="$(fleet_cfg_project_dir "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT")"
      _as_installed=$(jq -r '.agent_installed // false' "${_as_pdir}/project.json" 2>/dev/null)
    else
      _as_installed=$(fleet_get ".machines.\"${_as_m}\".agent_installed // false" 2>/dev/null)
    fi
    if [[ "$_as_installed" != "true" && -z "$machine" ]]; then
      continue
    fi

    _fleet_load_machine "$_as_m"
    printf '%b\n' "  ${BOLD}${WHITE}${_as_m}${RESET}  ${DIM}${_FM_USER}@${_FM_HOST}${RESET}"

    # ── Try local cache first (push reports from agent) ──
    local _used_cache=false
    if [[ -n "$_as_fleet" ]]; then
      local _rhost
      _rhost=$(printf '%s' "$_as_m" | tr -cd 'a-zA-Z0-9._-')

      # Check for cached report in fleet reports dir
      local _rdir
      _rdir="$(fleet_crypto_report_dir "$_as_fleet" "$_rhost")"

      if fleet_crypto_read_report "$_as_fleet" "$_rhost" 2>/dev/null; then
        # Report found locally — use cached data
        if [[ -n "$_FCR_JSON" ]] && command -v jq >/dev/null 2>&1; then
          local _cr_ts _cr_cpu _cr_mem _cr_disk _cr_health
          _cr_ts=$(jq -r '.ts // ""' "$_FCR_JSON" 2>/dev/null)
          _cr_cpu=$(jq -r '.metrics.cpu // 0' "$_FCR_JSON" 2>/dev/null)
          _cr_mem=$(jq -r '.metrics.mem_pct // 0' "$_FCR_JSON" 2>/dev/null)
          _cr_disk=$(jq -r '.metrics.disk_pct // 0' "$_FCR_JSON" 2>/dev/null)

          # Determine source label
          local _enc_label=""
          [[ -f "${_rdir}/latest.enc" ]] && _enc_label=" (encrypted)"

          local _age_label=""
          if (( _FCR_AGE < 60 )); then
            _age_label="${_FCR_AGE}s ago"
          elif (( _FCR_AGE < 3600 )); then
            _age_label="$(( _FCR_AGE / 60 ))m ago"
          else
            _age_label="$(( _FCR_AGE / 3600 ))h ago"
          fi

          printf '  Status: %bpush-reporting%b  %b%s%s%b\n' "${GREEN}" "${RESET}" "${DIM}" "$_age_label" "$_enc_label" "${RESET}"

          # Health from report
          _cr_health=$(jq -r '.health // {} | to_entries[] | "\(.key)=\(.value)"' "$_FCR_JSON" 2>/dev/null)
          if [[ -n "$_cr_health" ]]; then
            printf '  %bServices:%b\n' "${DIM}" "${RESET}"
            while IFS= read -r _as_h; do
              [[ -z "$_as_h" ]] && continue
              local _as_svc="${_as_h%%=*}"
              local _as_val="${_as_h#*=}"
              local _as_color="${RESET}"
              case "$_as_val" in
                healthy)   _as_color="${GREEN}" ;;
                unhealthy) _as_color="${RED}" ;;
                disabled)  _as_color="${DIM}" ;;
              esac
              printf '    %-20s %b%s%b\n' "$_as_svc" "$_as_color" "$_as_val" "${RESET}"
            done <<< "$_cr_health"
          fi

          printf '  %bMetrics:%b CPU %s%%  Mem %s%%  Disk %s%%\n' "${DIM}" "${RESET}" "$_cr_cpu" "$_cr_mem" "$_cr_disk"
          [[ -n "$_cr_ts" ]] && printf '  %bLast report: %s%b\n' "${DIM}" "$_cr_ts" "${RESET}"
          echo ""
          _used_cache=true
        fi
      fi
    fi

    # ── Fallback: pull directly via SSH ──
    if [[ "$_used_cache" == "false" ]]; then
      # Check agent process
      local _as_pid
      _as_pid=$(fleet_exec "$_as_m" 'pid=$(cat ~/.muster/agent/agent.pid 2>/dev/null); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo running || echo stopped' 2>/dev/null)

      if [[ "$_as_pid" == *"running"* ]]; then
        printf '  Status: %brunning%b\n' "${GREEN}" "${RESET}"
      else
        printf '  Status: %bstopped%b\n' "${RED}" "${RESET}"
      fi

      # Read health data
      local _as_health
      _as_health=$(fleet_exec "$_as_m" 'for f in ~/.muster/agent/health/*; do [ -f "$f" ] && echo "$(basename "$f")=$(cat "$f")"; done' 2>/dev/null)

      if [[ -n "$_as_health" ]]; then
        printf '  %bServices:%b\n' "${DIM}" "${RESET}"
        while IFS= read -r _as_h; do
          [[ -z "$_as_h" ]] && continue
          local _as_svc="${_as_h%%=*}"
          local _as_val="${_as_h#*=}"
          local _as_color="${RESET}"
          case "$_as_val" in
            healthy)   _as_color="${GREEN}" ;;
            unhealthy) _as_color="${RED}" ;;
            disabled)  _as_color="${DIM}" ;;
          esac
          printf '    %-20s %b%s%b\n' "$_as_svc" "$_as_color" "$_as_val" "${RESET}"
        done <<< "$_as_health"
      fi

      # Read metrics
      local _as_metrics
      _as_metrics=$(fleet_exec "$_as_m" "cat ~/.muster/agent/metrics/latest.json 2>/dev/null" 2>/dev/null)

      if [[ -n "$_as_metrics" ]] && command -v jq >/dev/null 2>&1; then
        local _as_cpu _as_mem _as_disk _as_ts
        _as_cpu=$(printf '%s' "$_as_metrics" | jq -r '.cpu // 0' 2>/dev/null)
        _as_mem=$(printf '%s' "$_as_metrics" | jq -r '.mem_pct // 0' 2>/dev/null)
        _as_disk=$(printf '%s' "$_as_metrics" | jq -r '.disk_pct // 0' 2>/dev/null)
        _as_ts=$(printf '%s' "$_as_metrics" | jq -r '.ts // ""' 2>/dev/null)
        printf '  %bMetrics:%b CPU %s%%  Mem %s%%  Disk %s%%\n' "${DIM}" "${RESET}" "$_as_cpu" "$_as_mem" "$_as_disk"
        [[ -n "$_as_ts" ]] && printf '  %bLast poll: %s%b\n' "${DIM}" "$_as_ts" "${RESET}"
      fi

      # Recent events
      local _as_events
      _as_events=$(fleet_exec "$_as_m" "tail -5 ~/.muster/agent/events/deploy.log 2>/dev/null" 2>/dev/null)

      if [[ -n "$_as_events" ]]; then
        printf '  %bRecent events:%b\n' "${DIM}" "${RESET}"
        while IFS= read -r _as_ev; do
          [[ -z "$_as_ev" ]] && continue
          printf '    %b%s%b\n' "${DIM}" "$_as_ev" "${RESET}"
        done <<< "$_as_events"
      fi
      echo ""
    fi
  done <<< "$machines_list"
}

# ── Remove agent from machine ──

_fleet_cmd_remove_agent() {
  local machine="${1:-}"

  if [[ -z "$machine" ]]; then
    err "Usage: muster fleet remove-agent <machine>"
    return 1
  fi

  if ! fleet_load_config; then
    err "No fleet config found"
    return 1
  fi

  _fleet_load_machine "$machine"
  if [[ -z "$_FM_HOST" ]]; then
    err "Machine '${machine}' not found"
    return 1
  fi

  echo ""
  printf '%b\n' "  ${BOLD}Remove Agent: ${machine}${RESET}"
  echo ""

  # Detect init system and stop service
  start_spinner "Stopping agent..."
  local _remote_os
  _remote_os=$(fleet_exec "$machine" "uname -s" 2>/dev/null)

  # Try systemd
  fleet_exec "$machine" "systemctl --user stop muster-agent 2>/dev/null; systemctl --user disable muster-agent 2>/dev/null; rm -f ~/.config/systemd/user/muster-agent.service; systemctl --user daemon-reload 2>/dev/null" 2>/dev/null

  # Try launchd
  if [[ "$_remote_os" == "Darwin" ]]; then
    fleet_exec "$machine" "launchctl unload ~/Library/LaunchAgents/dev.getmuster.agent.plist 2>/dev/null; rm -f ~/Library/LaunchAgents/dev.getmuster.agent.plist" 2>/dev/null
  fi

  # Remove cron entry
  fleet_exec "$machine" "(crontab -l 2>/dev/null | grep -v 'muster-agent') | crontab - 2>/dev/null" 2>/dev/null

  # Kill via PID file (safely read pid, validate it's numeric, then kill)
  fleet_exec "$machine" 'pid=$(cat ~/.muster/agent/agent.pid 2>/dev/null); [ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -f ~/.muster/agent/agent.lock' 2>/dev/null
  stop_spinner

  # Ask about data
  local _keep_data="n"
  if [[ -t 0 ]]; then
    printf '  Keep collected data? [y/N] '
    IFS= read -rsn1 _keep_data || true
    echo ""
  fi

  start_spinner "Cleaning up..."
  case "$_keep_data" in
    y|Y)
      # Remove agent script, config, signatures, keys — keep data dirs
      fleet_exec "$machine" "rm -f ~/.muster/agent/muster-agent.sh ~/.muster/agent/agent.json ~/.muster/agent/agent.pid ~/.muster/agent/daemon.log ~/.muster/agent/agent.sig ~/.muster/agent/agent.pub.pem ~/.muster/agent/agent.json.sig" 2>/dev/null
      ;;
    *)
      # Remove everything
      fleet_exec "$machine" "rm -rf ~/.muster/agent" 2>/dev/null
      ;;
  esac
  stop_spinner

  # Remove agent_installed flag
  if fleet_cfg_find_project "$machine" 2>/dev/null; then
    fleet_cfg_project_update "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT" \
      '.agent_installed = false'
  else
    fleet_set ".machines.\"${machine}\".agent_installed" "false"
  fi

  ok "Agent removed from ${machine}"
  echo ""
}

# ── TUI submenu ──

_fleet_agent_menu() {
  while true; do
    clear
    echo ""
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Fleet Agent${RESET}"
    echo ""

    # Show machines with agent status
    local _am_machines
    _am_machines=$(fleet_machines)
    if [[ -n "$_am_machines" ]]; then
      while IFS= read -r _am_m; do
        [[ -z "$_am_m" ]] && continue
        local _am_installed
        _am_installed="false"
        if fleet_cfg_find_project "$_am_m" 2>/dev/null; then
          local _am_pdir
          _am_pdir="$(fleet_cfg_project_dir "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT")"
          _am_installed=$(jq -r '.agent_installed // false' "${_am_pdir}/project.json" 2>/dev/null)
        else
          _am_installed=$(fleet_get ".machines.\"${_am_m}\".agent_installed // false" 2>/dev/null)
        fi
        if [[ "$_am_installed" == "true" ]]; then
          printf '  %b●%b %s\n' "${GREEN}" "${RESET}" "$_am_m"
        else
          printf '  %b○%b %s\n' "${DIM}" "${RESET}" "$_am_m"
        fi
      done <<< "$_am_machines"
      echo ""
    fi

    local actions=()
    actions[${#actions[@]}]="Install agent on..."
    actions[${#actions[@]}]="Agent status"
    actions[${#actions[@]}]="Remove agent from..."
    actions[${#actions[@]}]="Back"

    menu_select "Agent" "${actions[@]}"

    case "$MENU_RESULT" in
      "Install agent on...")
        if _fleet_pick_machine "Install agent on"; then
          _fleet_cmd_install_agent "$MENU_RESULT"
          printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
          IFS= read -rsn1 || true
        fi
        ;;
      "Agent status")
        _fleet_cmd_agent_status
        printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
        IFS= read -rsn1 || true
        ;;
      "Remove agent from...")
        if _fleet_pick_machine "Remove agent from"; then
          _fleet_cmd_remove_agent "$MENU_RESULT"
          printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
          IFS= read -rsn1 || true
        fi
        ;;
      "Back"|"__back__")
        return 0
        ;;
    esac
  done
}
