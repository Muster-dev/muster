#\!/usr/bin/env bash
# muster/lib/commands/fleet_deploy.sh — Fleet deploy orchestration
# Extracted from fleet.sh: deploy, dry-run, sequential, parallel, summary.
# shellcheck disable=SC2034

# Module flag for --sync threading
_FLEET_DEPLOY_FORCE_SYNC="false"

# ── deploy ──

_fleet_cmd_deploy() {
  # shellcheck disable=SC2034
  local target="" parallel=false dry_run=false json_mode=false force_sync=false rolling=false
  local _strategy_override=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel) parallel=true; _strategy_override="parallel"; shift ;;
      --sequential) parallel=false; _strategy_override="sequential"; shift ;;
      --rolling) rolling=true; _strategy_override="rolling"; shift ;;
      --dry-run) dry_run=true; shift ;;
      --json) json_mode=true; shift ;;
      --sync) force_sync=true; shift ;;
      --help|-h)
        echo "Usage: muster fleet deploy [target] [--parallel] [--sequential] [--rolling] [--dry-run] [--sync] [--json]"
        echo ""
        echo "Deploy to fleet machines. Target can be a machine name, group name,"
        echo "or omitted to deploy to all machines following deploy_order."
        echo ""
        echo "Options:"
        echo "  --parallel      Deploy to all target machines in parallel"
        echo "  --sequential    Deploy one machine at a time (default)"
        echo "  --rolling       Deploy to one, verify health, then continue"
        echo "  --dry-run       Preview deploy plan without executing"
        echo "  --sync          Force sync hooks before deploy (regardless of hook_mode)"
        echo "  --json          Output as NDJSON events"
        return 0
        ;;
      --*)
        err "Unknown flag: $1"
        return 1
        ;;
      *)
        target="$1"
        shift
        ;;
    esac
  done

  if ! fleet_load_config; then
    err "No fleet config found. Run 'muster fleet setup' first."
    return 1
  fi

  # load_config is optional for fleet — fleet may run without a local project
  if [[ "$FLEET_CONFIG_FILE" != "__fleet_dirs__" ]]; then
    load_config
  else
    # Try loading local config but don't exit on failure
    CONFIG_FILE=$(find_config 2>/dev/null) || true
  fi

  # Resolve target to list of machines
  local machines=()
  if [[ -n "$target" ]]; then
    # Check if it's a group
    local group_members
    group_members=$(fleet_group_machines "$target" 2>/dev/null)
    if [[ -n "$group_members" ]]; then
      while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        machines[${#machines[@]}]="$m"
      done <<< "$group_members"
    else
      # Single machine
      if ! _fleet_load_machine "$target" 2>/dev/null; then
        err "Unknown machine or group: ${target}"
        return 1
      fi
      machines[0]="$target"
    fi
  else
    # Use deploy_order (groups in order), then ungrouped machines
    local ordered_groups
    ordered_groups=$(fleet_deploy_order)
    local _added_machines=""

    if [[ -n "$ordered_groups" ]]; then
      while IFS= read -r grp; do
        [[ -z "$grp" ]] && continue
        local grp_members
        grp_members=$(fleet_group_machines "$grp" 2>/dev/null)
        while IFS= read -r m; do
          [[ -z "$m" ]] && continue
          # Skip duplicates
          case " $_added_machines " in
            *" $m "*) continue ;;
          esac
          machines[${#machines[@]}]="$m"
          _added_machines="${_added_machines} ${m}"
        done <<< "$grp_members"
      done <<< "$ordered_groups"
    fi

    # Add any machines not in groups
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      case " $_added_machines " in
        *" $m "*) continue ;;
      esac
      machines[${#machines[@]}]="$m"
    done < <(fleet_machines)
  fi

  if (( ${#machines[@]} == 0 )); then
    warn "No machines to deploy to"
    return 0
  fi

  local total=${#machines[@]}

  # Dry run (no env loading needed)
  if [[ "$dry_run" == "true" ]]; then
    _fleet_deploy_dry_run "${machines[@]}"
    return 0
  fi

  # Thread --sync flag to deploy functions
  _FLEET_DEPLOY_FORCE_SYNC="$force_sync"

  _load_env_file

  # Read deploy_strategy from config if no CLI override
  if [[ -z "$_strategy_override" ]]; then
    local _cfg_strategy=""
    if fleet_cfg_has_any 2>/dev/null; then
      local _first_fleet
      _first_fleet=$(fleets_list | head -1)
      if [[ -n "$_first_fleet" ]]; then
        fleet_cfg_load "$_first_fleet"
        _cfg_strategy="$_FL_STRATEGY"
      fi
    fi
    [[ -z "$_cfg_strategy" ]] && _cfg_strategy=$(fleet_get '.deploy_strategy // "sequential"' 2>/dev/null || echo "sequential")
    case "$_cfg_strategy" in
      parallel) parallel=true ;;
      rolling)  rolling=true ;;
    esac
  fi

  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Fleet Deploy${RESET} — ${total} machine(s)"
  echo ""

  if [[ "$rolling" == "true" ]]; then
    _fleet_deploy_rolling "${machines[@]}"
  elif [[ "$parallel" == "true" ]]; then
    _fleet_deploy_parallel "${machines[@]}"
  else
    _fleet_deploy_sequential "${machines[@]}"
  fi

  _unload_env_file
}

# ── Deploy: dry run ──

_fleet_deploy_dry_run() {
  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local inner=$(( w - 2 ))

  echo ""

  local label="Deploy Plan (dry-run)"
  local label_pad_len=$(( w - ${#label} - 3 ))
  (( label_pad_len < 1 )) && label_pad_len=1
  local label_pad
  printf -v label_pad '%*s' "$label_pad_len" ""
  label_pad="${label_pad// /─}"
  printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$label" "${RESET}${ACCENT}" "$label_pad" "${RESET}"

  local idx=0
  for machine in "$@"; do
    idx=$(( idx + 1 ))
    _fleet_load_machine "$machine"

    local host_str="${_FM_USER}@${_FM_HOST}"
    [[ "$_FM_PORT" != "22" ]] && host_str="${host_str}:${_FM_PORT}"

    local status_icon="○" status_color="$DIM" tag=""

    if [[ "$_FM_MODE" == "muster" ]]; then
      local token
      token=$(fleet_token_get "$machine")
      if [[ -n "$token" ]]; then
        status_icon="●"; status_color="$GREEN"
      else
        status_icon="●"; status_color="$YELLOW"
        tag=" unpaired"
      fi
    else
      status_icon="●"; status_color="$GREEN"
    fi

    local display="${idx}. ${machine}: ${host_str} (${_FM_MODE})"
    local tag_len=${#tag}
    local max_display=$(( inner - 4 - tag_len ))
    (( max_display < 5 )) && max_display=5
    if (( ${#display} > max_display )); then
      display="${display:0:$((max_display - 3))}..."
    fi

    local content_len=$(( 4 + ${#display} + tag_len ))
    local pad_len=$(( inner - content_len ))
    (( pad_len < 0 )) && pad_len=0
    local pad
    printf -v pad '%*s' "$pad_len" ""

    if [[ -n "$tag" ]]; then
      printf '  %b│%b  %b%s%b %s%s%b%s%b%b│%b\n' \
        "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" \
        "$display" "$pad" "${YELLOW}" "$tag" "${RESET}" "${ACCENT}" "${RESET}"
    else
      printf '  %b│%b  %b%s%b %s%s%b│%b\n' \
        "${ACCENT}" "${RESET}" "$status_color" "$status_icon" "${RESET}" \
        "$display" "$pad" "${ACCENT}" "${RESET}"
    fi
  done

  local bottom
  printf -v bottom '%*s' "$w" ""
  bottom="${bottom// /─}"
  printf '  %b└%s┘%b\n' "${ACCENT}" "$bottom" "${RESET}"

  echo ""
  info "Dry-run complete — no changes made"
  echo ""
}

# ── Deploy: sequential ──

_fleet_deploy_sequential() {
  local total=$#
  local current=0
  local succeeded=0 failed=0

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local log_dir="${project_dir}/.muster/logs"
  mkdir -p "$log_dir"

  for machine in "$@"; do
    current=$(( current + 1 ))
    _fleet_load_machine "$machine"

    progress_bar "$current" "$total" "Fleet: ${machine}..."
    echo ""

    local log_file
    log_file="${log_dir}/fleet-${machine}-$(date +%Y%m%d-%H%M%S).log"
    local rc=0

    while true; do
      if [[ "$_FM_MODE" == "muster" ]]; then
        _fleet_deploy_muster "$machine" "$log_file"
        rc=$?
      else
        _fleet_deploy_push "$machine" "$log_file"
        rc=$?
      fi

      if (( rc == 0 )); then
        ok "${machine} deployed"
        _history_log_event "fleet:${machine}" "deploy" "ok" ""
        succeeded=$(( succeeded + 1 ))
        break
      else
        err "${machine} deploy failed"
        _history_log_event "fleet:${machine}" "deploy" "failed" ""

        # Show last few lines
        if [[ -f "$log_file" ]]; then
          echo ""
          tail -5 "$log_file" | while IFS= read -r _line; do
            printf '%b\n' "  ${DIM}${_line}${RESET}"
          done
          echo ""
        fi

        menu_select "Fleet deploy failed on ${machine}. What do you want to do?" \
          "Retry" "Skip and continue" "Abort"

        case "$MENU_RESULT" in
          "Retry")
            log_file="${log_dir}/fleet-${machine}-$(date +%Y%m%d-%H%M%S).log"
            ;; # loop continues
          "Skip and continue")
            failed=$(( failed + 1 ))
            break
            ;;
          "Abort")
            failed=$(( failed + 1 ))
            echo ""
            _fleet_deploy_summary "$succeeded" "$failed" "$total"
            return 1
            ;;
        esac
      fi
    done
  done

  echo ""
  _fleet_deploy_summary "$succeeded" "$failed" "$total"
}

# Auto-sync hooks if machine is in sync mode or --sync flag is set
# Returns: 0=ok (or no sync needed), 1=sync failed
_fleet_deploy_auto_sync() {
  local machine="$1"

  _fleet_load_machine "$machine"

  # Sync if hook_mode is "sync" or --sync flag was passed
  if [[ "$_FM_HOOK_MODE" != "sync" && "$_FLEET_DEPLOY_FORCE_SYNC" != "true" ]]; then
    return 0
  fi

  # Source fleet_sync.sh for _fleet_sync_one
  source "$MUSTER_ROOT/lib/commands/fleet_sync.sh"

  printf '%b\n' "  ${DIM}syncing hooks to ${machine}...${RESET}"
  if _fleet_sync_one "$machine" "false" ""; then
    return 0
  else
    warn "Hook sync failed for ${machine}"
    return 1
  fi
}

# Deploy to a muster-mode machine
_fleet_deploy_muster() {
  local machine="$1" log_file="$2"
  _fleet_load_machine "$machine"

  # Auto-sync hooks before deploy if needed
  _fleet_deploy_auto_sync "$machine" || return 1

  local token
  token=$(fleet_token_get "$machine")

  if [[ -z "$token" ]]; then
    err "No token for ${machine} — run: muster fleet pair ${machine} --token <token>"
    return 1
  fi

  # Deploy gate: verify trust
  source "$MUSTER_ROOT/lib/core/trust.sh"
  local _my_fp
  _my_fp=$(trust_fingerprint)
  local _trust_status=""
  _trust_status=$(fleet_exec "$machine" \
    "muster trust verify --fingerprint '${_my_fp}'" 2>/dev/null) || true

  case "$_trust_status" in
    trusted) ;; # proceed
    pending)
      printf 'Deploy rejected: trust request pending on %s\n' "$(fleet_desc "$machine")" > "$log_file"
      return 1
      ;;
    unknown)
      # Remote has trust system but doesn't know us — auto-send a join request
      local _my_label
      _my_label=$(trust_label)
      fleet_exec "$machine" \
        "muster trust request --fingerprint '${_my_fp}' --label '${_my_label}'" &>/dev/null || true
      printf 'Trust request auto-sent to %s\n' "$(fleet_desc "$machine")" > "$log_file"
      printf 'Deploy blocked until remote accepts: muster trust accept %s\n' "$_my_fp" >> "$log_file"
      return 1
      ;;
    "")
      # Empty = older muster without trust, allow deploy
      ;;
  esac

  info "Deploying on ${machine} via muster ($(fleet_desc "$machine"))"

  # Run muster deploy on remote with token
  local cmd="MUSTER_TOKEN=${token} muster deploy"
  if [[ -n "$_FM_PROJECT_DIR" ]]; then
    cmd="cd ${_FM_PROJECT_DIR} && ${cmd}"
  fi

  stream_in_box "${machine}" "$log_file" fleet_exec "$machine" "$cmd"
}

# Deploy to a push-mode machine
_fleet_deploy_push() {
  local machine="$1" log_file="$2"
  _fleet_load_machine "$machine"

  # Auto-sync hooks before deploy if needed
  _fleet_deploy_auto_sync "$machine" || return 1

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  info "Deploying to ${machine} via push ($(fleet_desc "$machine"))"

  # Get services to deploy
  local services=()
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local skip
    skip=$(config_get ".services.${svc}.skip_deploy")
    [[ "$skip" == "true" ]] && continue
    services[${#services[@]}]="$svc"
  done < <(config_get '.deploy_order[]' 2>/dev/null || config_services)

  local svc_rc=0
  for svc in "${services[@]}"; do
    local hook="${project_dir}/.muster/hooks/${svc}/deploy.sh"
    if [[ ! -x "$hook" ]]; then
      warn "No deploy hook for ${svc}, skipping"
      continue
    fi

    # Gather env vars
    local env_lines=""
    local _cred_env
    _cred_env=$(cred_env_for_service "$svc")
    [[ -n "$_cred_env" ]] && env_lines="${_cred_env}"
    local _k8s_env
    _k8s_env=$(k8s_env_for_service "$svc")
    if [[ -n "$_k8s_env" ]]; then
      [[ -n "$env_lines" ]] && env_lines="${env_lines}
${_k8s_env}"
      [[ -z "$env_lines" ]] && env_lines="$_k8s_env"
    fi

    info "  ${svc} → ${machine}"
    fleet_push_hook "$machine" "$hook" "$env_lines" >> "$log_file" 2>&1
    local hook_rc=$?
    if (( hook_rc != 0 )); then
      err "  ${svc} failed on ${machine}"
      svc_rc=1
      break
    fi
  done

  return $svc_rc
}

# ── Deploy: rolling ──
# Deploy to one machine, verify health, then continue to next

_fleet_deploy_rolling() {
  local total=$#
  local current=0
  local failed=0

  for machine in "$@"; do
    current=$((current + 1))
    _fleet_load_machine "$machine"

    printf '%b\n' "  ${BOLD}[${current}/${total}]${RESET} ${machine} (${_FM_USER}@${_FM_HOST})"

    # Sync hooks if needed
    if [[ "${_FM_HOOK_MODE}" == "sync" || "$_FLEET_DEPLOY_FORCE_SYNC" == "true" ]]; then
      _fleet_sync_hooks_before_deploy "$machine"
    fi

    # Deploy
    local svc_rc=0
    _fleet_deploy_one "$machine" || svc_rc=$?

    if [[ $svc_rc -ne 0 ]]; then
      printf '%b\n' "  ${RED}x${RESET} Deploy failed on ${machine}"
      failed=$((failed + 1))

      # Rolling: stop on first failure
      echo ""
      menu_select "Deploy failed on ${machine}. What to do?" \
        "Retry" "Skip and continue" "Abort"
      case "$MENU_RESULT" in
        "Retry")
          current=$((current - 1))
          continue
          ;;
        "Skip and continue")
          continue
          ;;
        *)
          warn "Fleet deploy aborted at ${machine}"
          return 1
          ;;
      esac
    fi

    # Rolling: verify health after successful deploy
    if (( current < total )); then
      printf '%b' "  ${DIM}Verifying health on ${machine}...${RESET} "

      local _health_ok=false
      # Simple health check: run muster status on remote or check connectivity
      if [[ "${_FM_MODE}" == "muster" ]]; then
        local _token=""
        _token=$(fleet_token_get "$machine" 2>/dev/null || true)
        local _h_cmd="muster status --minimal 2>/dev/null; echo \$?"
        if [[ -n "$_token" ]]; then
          _h_cmd="MUSTER_TOKEN=${_token} ${_h_cmd}"
        fi
        local _h_result=""
        _h_result=$(fleet_exec "$machine" "$_h_cmd" 2>/dev/null | tail -1 || echo "1")
        [[ "$_h_result" == "0" ]] && _health_ok=true
      else
        # Push mode: just verify SSH is still reachable
        fleet_check "$machine" &>/dev/null && _health_ok=true
      fi

      if [[ "$_health_ok" == "true" ]]; then
        printf '%b\n' "${GREEN}healthy${RESET}"
      else
        printf '%b\n' "${RED}unhealthy${RESET}"
        echo ""
        menu_select "Health check failed on ${machine}. Continue rolling?" \
          "Continue anyway" "Rollback ${machine}" "Abort"
        case "$MENU_RESULT" in
          "Continue anyway") ;;
          *"Rollback"*)
            fleet_exec "$machine" "muster rollback 2>/dev/null || true" 2>/dev/null || true
            printf '%b\n' "  ${DIM}Rolled back ${machine}${RESET}"
            ;;
          *)
            warn "Fleet deploy aborted after ${machine}"
            return 1
            ;;
        esac
      fi
    else
      printf '%b\n' "  ${GREEN}*${RESET} Deploy complete on ${machine}"
    fi

    echo ""
  done

  if (( failed > 0 )); then
    warn "${failed}/${total} machines had deploy failures"
    return 1
  fi

  ok "Rolling deploy complete — ${total} machines"
  return 0
}

# ── Deploy: parallel ──

_fleet_deploy_parallel() {
  local total=$#
  local machines=("$@")

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local log_dir="${project_dir}/.muster/logs"
  mkdir -p "$log_dir"

  # Create temp dir for status tracking
  local tmp_dir="${TMPDIR:-/tmp}/muster-fleet-$$"
  mkdir -p "$tmp_dir"

  info "Deploying to ${total} machines in parallel..."
  echo ""

  # Spawn background processes (cap at 10 concurrent)
  local max_concurrent=10
  local pids=()
  local pid_machines=()
  local batch_start=0

  while (( batch_start < ${#machines[@]} )); do
    local batch_end=$(( batch_start + max_concurrent ))
    (( batch_end > ${#machines[@]} )) && batch_end=${#machines[@]}

    local i=$batch_start
    while (( i < batch_end )); do
      local machine="${machines[$i]}"
      local log_file
      log_file="${log_dir}/fleet-${machine}-$(date +%Y%m%d-%H%M%S).log"
      local status_file="${tmp_dir}/${machine}.status"

      (
        _fleet_load_machine "$machine"
        local _rc=0
        local _start
        _start=$(date +%s)

        # Auto-sync hooks before deploy if needed
        if ! _fleet_deploy_auto_sync "$machine"; then
          echo "1|0" > "$status_file"
          _history_log_event "fleet:${machine}" "deploy" "failed" "sync failed"
          exit 1
        fi

        if [[ "$_FM_MODE" == "muster" ]]; then
          local _token
          _token=$(fleet_token_get "$machine")
          if [[ -z "$_token" ]]; then
            echo "1" > "$status_file"
            exit 1
          fi
          local _cmd="MUSTER_TOKEN=${_token} muster deploy"
          [[ -n "$_FM_PROJECT_DIR" ]] && _cmd="cd ${_FM_PROJECT_DIR} && ${_cmd}"
          fleet_exec "$machine" "$_cmd" >> "$log_file" 2>&1
          _rc=$?
        else
          local _proj_dir
          _proj_dir="$(dirname "$CONFIG_FILE")"
          while IFS= read -r _svc; do
            [[ -z "$_svc" ]] && continue
            local _skip
            _skip=$(config_get ".services.${_svc}.skip_deploy")
            [[ "$_skip" == "true" ]] && continue
            local _hook="${_proj_dir}/.muster/hooks/${_svc}/deploy.sh"
            [[ ! -x "$_hook" ]] && continue

            local _env=""
            local _ce
            _ce=$(cred_env_for_service "$_svc")
            [[ -n "$_ce" ]] && _env="$_ce"
            local _ke
            _ke=$(k8s_env_for_service "$_svc")
            if [[ -n "$_ke" ]]; then
              [[ -n "$_env" ]] && _env="${_env}
${_ke}"
              [[ -z "$_env" ]] && _env="$_ke"
            fi

            fleet_push_hook "$machine" "$_hook" "$_env" >> "$log_file" 2>&1 || { _rc=1; break; }
          done < <(config_get '.deploy_order[]' 2>/dev/null || config_services)
        fi

        local _end
        _end=$(date +%s)
        local _duration=$(( _end - _start ))

        if (( _rc == 0 )); then
          echo "0|${_duration}" > "$status_file"
          _history_log_event "fleet:${machine}" "deploy" "ok" ""
        else
          echo "1|${_duration}" > "$status_file"
          _history_log_event "fleet:${machine}" "deploy" "failed" ""
        fi
      ) &

      pids[${#pids[@]}]=$!
      pid_machines[${#pid_machines[@]}]="$machine"
      i=$(( i + 1 ))
    done

    # Wait for this batch
    local _done=0
    while (( _done < ${#pids[@]} )); do
      _done=0
      local p_idx=0
      while (( p_idx < ${#pids[@]} )); do
        if ! kill -0 "${pids[$p_idx]}" 2>/dev/null; then
          _done=$(( _done + 1 ))
        fi
        p_idx=$(( p_idx + 1 ))
      done

      printf '\r  %b%s%b Deploying (%d/%d done...)' "${DIM}" "⠋" "${RESET}" "$_done" "${#pids[@]}"
      sleep 0.2
    done
    printf '\r%*s\r' 60 ''

    # Wait for all pids in batch
    local p_idx=0
    while (( p_idx < ${#pids[@]} )); do
      wait "${pids[$p_idx]}" 2>/dev/null
      p_idx=$(( p_idx + 1 ))
    done

    batch_start=$batch_end
    pids=()
    pid_machines=()
  done

  # Collect results in a box
  local _rw=$(( TERM_COLS - 4 ))
  (( _rw > 50 )) && _rw=50
  (( _rw < 10 )) && _rw=10
  local _rinner=$(( _rw - 2 ))

  echo ""

  local _rlabel="Results"
  local _rlabel_pad_len=$(( _rw - ${#_rlabel} - 3 ))
  (( _rlabel_pad_len < 1 )) && _rlabel_pad_len=1
  local _rlabel_pad
  printf -v _rlabel_pad '%*s' "$_rlabel_pad_len" ""
  _rlabel_pad="${_rlabel_pad// /─}"
  printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$_rlabel" "${RESET}${ACCENT}" "$_rlabel_pad" "${RESET}"

  local succeeded=0 failed=0
  local failed_machines=""
  local m_idx=0
  while (( m_idx < ${#machines[@]} )); do
    local machine="${machines[$m_idx]}"
    local status_file="${tmp_dir}/${machine}.status"

    local rc="1" duration="?"
    if [[ -f "$status_file" ]]; then
      local status_line
      status_line=$(cat "$status_file")
      rc="${status_line%%|*}"
      duration="${status_line#*|}"
    fi

    local _rs_icon _rs_color _rs_tag
    if [[ "$rc" == "0" ]]; then
      _rs_icon="●"; _rs_color="$GREEN"; _rs_tag=" ${duration}s"
      succeeded=$(( succeeded + 1 ))
    else
      _rs_icon="●"; _rs_color="$RED"; _rs_tag=" failed (${duration}s)"
      failed=$(( failed + 1 ))
      [[ -n "$failed_machines" ]] && failed_machines="${failed_machines} ${machine}"
      [[ -z "$failed_machines" ]] && failed_machines="$machine"
    fi

    local _rs_display="$machine"
    local _rs_tag_len=${#_rs_tag}
    local _rs_max=$(( _rinner - 4 - _rs_tag_len ))
    (( _rs_max < 5 )) && _rs_max=5
    (( ${#_rs_display} > _rs_max )) && _rs_display="${_rs_display:0:$((_rs_max - 3))}..."
    local _rs_clen=$(( 4 + ${#_rs_display} + _rs_tag_len ))
    local _rs_plen=$(( _rinner - _rs_clen ))
    (( _rs_plen < 0 )) && _rs_plen=0
    local _rs_pad
    printf -v _rs_pad '%*s' "$_rs_plen" ""

    printf '  %b│%b  %b%s%b %s%s%b%s%b%b│%b\n' \
      "${ACCENT}" "${RESET}" "$_rs_color" "$_rs_icon" "${RESET}" \
      "$_rs_display" "$_rs_pad" "$_rs_color" "$_rs_tag" "${RESET}" "${ACCENT}" "${RESET}"

    m_idx=$(( m_idx + 1 ))
  done

  local _rbottom
  printf -v _rbottom '%*s' "$_rw" ""
  _rbottom="${_rbottom// /─}"
  printf '  %b└%s┘%b\n' "${ACCENT}" "$_rbottom" "${RESET}"

  echo ""
  _fleet_deploy_summary "$succeeded" "$failed" "$total"

  # Cleanup
  rm -rf "$tmp_dir"

  # Offer retry for failed machines
  if (( failed > 0 )); then
    menu_select "Some machines failed. What do you want to do?" \
      "Retry failed" "View logs" "Continue"

    case "$MENU_RESULT" in
      "Retry failed")
        _fleet_deploy_sequential $failed_machines
        ;;
      "View logs")
        for m in $failed_machines; do
          local latest_log
          latest_log=$(ls -t "${log_dir}/fleet-${m}-"*.log 2>/dev/null | head -1)
          if [[ -n "$latest_log" ]]; then
            echo ""
            printf '%b\n' "  ${BOLD}${m}:${RESET}"
            tail -10 "$latest_log" | while IFS= read -r _line; do
              printf '%b\n' "  ${DIM}${_line}${RESET}"
            done
          fi
        done
        echo ""
        ;;
    esac
  fi
}

# Deploy summary line
_fleet_deploy_summary() {
  local succeeded="$1" failed="$2" total="$3"
  if (( failed == 0 )); then
    ok "Fleet deploy complete — ${succeeded}/${total} succeeded"
  else
    warn "Fleet deploy complete — ${succeeded} succeeded, ${failed} failed (${total} total)"
  fi
  echo ""
}
