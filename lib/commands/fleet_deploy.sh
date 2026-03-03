#\!/usr/bin/env bash
# muster/lib/commands/fleet_deploy.sh — Fleet deploy orchestration
# Extracted from fleet.sh: deploy, dry-run, sequential, parallel, summary.

# ── deploy ──

_fleet_cmd_deploy() {
  local target="" parallel=false dry_run=false json_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel) parallel=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      --json) json_mode=true; shift ;;
      --help|-h)
        echo "Usage: muster fleet deploy [target] [--parallel] [--dry-run] [--json]"
        echo ""
        echo "Deploy to fleet machines. Target can be a machine name, group name,"
        echo "or omitted to deploy to all machines following deploy_order."
        echo ""
        echo "Options:"
        echo "  --parallel    Deploy to all target machines in parallel"
        echo "  --dry-run     Preview deploy plan without executing"
        echo "  --json        Output as NDJSON events"
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
    err "No remotes.json found. Run 'muster fleet init' first."
    return 1
  fi

  load_config

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
      local exists
      exists=$(fleet_get ".machines.\"${target}\" // empty")
      if [[ -z "$exists" ]]; then
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

  _load_env_file

  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Fleet Deploy${RESET} — ${total} machine(s)"
  echo ""

  if [[ "$parallel" == "true" ]]; then
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
  label_pad=$(printf '%*s' "$label_pad_len" "" | sed 's/ /─/g')
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
    pad=$(printf '%*s' "$pad_len" "")

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
  bottom=$(printf '%*s' "$w" "" | sed 's/ /─/g')
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

    local log_file="${log_dir}/fleet-${machine}-$(date +%Y%m%d-%H%M%S).log"
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

# Deploy to a muster-mode machine
_fleet_deploy_muster() {
  local machine="$1" log_file="$2"
  _fleet_load_machine "$machine"

  local token
  token=$(fleet_token_get "$machine")

  if [[ -z "$token" ]]; then
    err "No token for ${machine} — run: muster fleet pair ${machine} --token <token>"
    return 1
  fi

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
      local log_file="${log_dir}/fleet-${machine}-$(date +%Y%m%d-%H%M%S).log"
      local status_file="${tmp_dir}/${machine}.status"

      (
        _fleet_load_machine "$machine"
        local _rc=0
        local _start
        _start=$(date +%s)

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
      sleep 1
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
  _rlabel_pad=$(printf '%*s' "$_rlabel_pad_len" "" | sed 's/ /─/g')
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
    _rs_pad=$(printf '%*s' "$_rs_plen" "")

    printf '  %b│%b  %b%s%b %s%s%b%s%b%b│%b\n' \
      "${ACCENT}" "${RESET}" "$_rs_color" "$_rs_icon" "${RESET}" \
      "$_rs_display" "$_rs_pad" "$_rs_color" "$_rs_tag" "${RESET}" "${ACCENT}" "${RESET}"

    m_idx=$(( m_idx + 1 ))
  done

  local _rbottom
  _rbottom=$(printf '%*s' "$_rw" "" | sed 's/ /─/g')
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
