#!/usr/bin/env bash
# muster/lib/commands/deploy.sh — Deploy orchestration

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/tui/checklist.sh"
source "$MUSTER_ROOT/lib/tui/spinner.sh"
source "$MUSTER_ROOT/lib/tui/progress.sh"
source "$MUSTER_ROOT/lib/tui/streambox.sh"
source "$MUSTER_ROOT/lib/core/credentials.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"
source "$MUSTER_ROOT/lib/core/k8s_diag.sh"
source "$MUSTER_ROOT/lib/skills/manager.sh"
source "$MUSTER_ROOT/lib/commands/history.sh"

cmd_deploy() {
  local dry_run=false
  local _json_mode=false
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: muster deploy [flags] [service]"
        echo ""
        echo "Deploy services. Without a service name, choose interactively."
        echo ""
        echo "Flags:"
        echo "  --dry-run       Preview deploy plan without executing"
        echo "  --json          Output as NDJSON (one JSON object per line)"
        echo "  -h, --help      Show this help"
        echo ""
        echo "Examples:"
        echo "  muster deploy              Interactive: pick all or select services"
        echo "  muster deploy api          Deploy just the api service"
        echo "  muster deploy --dry-run    Preview all services"
        echo "  muster deploy --json       Stream deploy events as NDJSON"
        return 0
        ;;
      --dry-run) dry_run=true; shift ;;
      --json) _json_mode=true; shift ;;
      *)
        err "Unknown flag: $1"
        echo "Run 'muster deploy --help' for usage."
        return 1
        ;;
    esac
  done

  load_config
  _load_env_file

  local target="${1:-all}"
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local log_dir="${project_dir}/.muster/logs"
  mkdir -p "$log_dir"

  local project
  project=$(config_get '.project')

  # Auth gate: JSON mode requires valid token
  if [[ "$_json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "deploy" || return 1
  fi

  if [[ "$_json_mode" == "false" ]]; then
    echo ""
    echo -e "  ${BOLD}${ACCENT_BRIGHT}Deploying${RESET} ${WHITE}${project}${RESET}"
    echo ""
  fi

  # Get deploy order
  local services=()
  if [[ "$target" == "all" ]]; then
    local all_services=()
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      local skip
      skip=$(config_get ".services.${svc}.skip_deploy")
      [[ "$skip" == "true" ]] && continue
      all_services[${#all_services[@]}]="$svc"
    done < <(config_get '.deploy_order[]' 2>/dev/null || config_services)

    # Interactive: let user choose all or specific services (skip in JSON mode)
    if [[ "$_json_mode" == "false" && -t 0 ]] && (( ${#all_services[@]} > 1 )); then
      menu_select "Deploy which services?" "All services" "Select services" "Back"
      if [[ "$MENU_RESULT" == "Back" || "$MENU_RESULT" == "__back__" ]]; then
        _unload_env_file
        return 2
      elif [[ "$MENU_RESULT" == "Select services" ]]; then
        checklist_select "Select services to deploy:" "${all_services[@]}"
        if [[ "$CHECKLIST_RESULT" == "__back__" ]]; then
          _unload_env_file
          return 2
        elif [[ -z "$CHECKLIST_RESULT" ]]; then
          warn "No services selected"
          _unload_env_file
          return 0
        fi
        while IFS= read -r svc; do
          [[ -z "$svc" ]] && continue
          services[${#services[@]}]="$svc"
        done <<< "$CHECKLIST_RESULT"
      else
        local _i=0
        while (( _i < ${#all_services[@]} )); do
          services[${#services[@]}]="${all_services[$_i]}"
          _i=$(( _i + 1 ))
        done
      fi
    else
      local _i=0
      while (( _i < ${#all_services[@]} )); do
        services[${#services[@]}]="${all_services[$_i]}"
        _i=$(( _i + 1 ))
      done
    fi
  else
    services[0]="$target"
  fi

  local total=${#services[@]}
  local current=0

  for svc in "${services[@]}"; do
    (( current++ ))
    local name
    name=$(config_get ".services.${svc}.name")
    local hook="${project_dir}/.muster/hooks/${svc}/deploy.sh"

    if [[ ! -x "$hook" ]]; then
      warn "No deploy hook for ${name}, skipping"
      continue
    fi

    if [[ "$_json_mode" == "true" && "$dry_run" == "true" ]]; then
      # ── JSON dry-run ──
      local _hook_lines
      _hook_lines=$(wc -l < "$hook" | tr -d ' ')
      printf '{"event":"dry_run","service":"%s","name":"%s","index":%d,"total":%d,"hook":"%s","hook_lines":%s}\n' \
        "$svc" "$name" "$current" "$total" "$hook" "$_hook_lines"
      continue

    elif [[ "$_json_mode" == "true" ]]; then
      # ── JSON deploy mode — stream NDJSON events ──

      # Gather credentials
      local _cred_env_lines=""
      _cred_env_lines=$(cred_env_for_service "$svc")

      # Export k8s config
      local _k8s_env_lines=""
      _k8s_env_lines=$(k8s_env_for_service "$svc")
      if [[ -n "$_k8s_env_lines" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          export "$_ek=$_ev"
        done <<< "$_k8s_env_lines"
      fi

      export MUSTER_DEPLOY_STATUS=""
      export MUSTER_SERVICE_NAME="$name"

      local log_file="${log_dir}/${svc}-deploy-$(date +%Y%m%d-%H%M%S).log"

      printf '{"event":"start","service":"%s","name":"%s","index":%d,"total":%d,"log_file":"%s"}\n' \
        "$svc" "$name" "$current" "$total" "$log_file"

      # Auto git pull (JSON mode)
      local _gp_enabled=""
      _gp_enabled=$(config_get ".services.${svc}.git_pull.enabled")
      if [[ "$_gp_enabled" == "true" ]]; then
        local _gp_remote _gp_branch
        _gp_remote=$(config_get ".services.${svc}.git_pull.remote")
        _gp_branch=$(config_get ".services.${svc}.git_pull.branch")
        [[ "$_gp_remote" == "null" || -z "$_gp_remote" ]] && _gp_remote="origin"
        [[ "$_gp_branch" == "null" || -z "$_gp_branch" ]] && _gp_branch="main"

        printf '{"event":"git_pull","service":"%s","remote":"%s","branch":"%s","status":"pulling"}\n' \
          "$svc" "$_gp_remote" "$_gp_branch"

        local _gp_rc=0
        if remote_is_enabled "$svc"; then
          _remote_load_config "$svc"
          _remote_build_opts
          local _gp_cmd="cd ${_REMOTE_PROJECT_DIR:-.} && git pull ${_gp_remote} ${_gp_branch}"
          ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "$_gp_cmd" >/dev/null 2>&1 || _gp_rc=$?
        else
          git pull "$_gp_remote" "$_gp_branch" >/dev/null 2>&1 || _gp_rc=$?
        fi

        if (( _gp_rc != 0 )); then
          printf '{"event":"git_pull","service":"%s","status":"failed","exit_code":%d}\n' "$svc" "$_gp_rc"
        else
          printf '{"event":"git_pull","service":"%s","status":"done"}\n' "$svc"
        fi
      fi

      # Run the hook, tee to log file, and stream each line as NDJSON
      local _deploy_rc=0
      if [[ -n "$_cred_env_lines" ]]; then
        while IFS='=' read -r _ck _cv; do
          [[ -z "$_ck" ]] && continue
          export "$_ck=$_cv"
        done <<< "$_cred_env_lines"
      fi

      {
        if remote_is_enabled "$svc"; then
          remote_exec_stdout "$svc" "$hook" "${_cred_env_lines}
${_k8s_env_lines}" 2>&1
        else
          "$hook" 2>&1
        fi
      } | while IFS= read -r _jline; do
        printf '%s\n' "$_jline" >> "$log_file"
        # Escape backslashes and double quotes for JSON
        _jline=$(printf '%s' "$_jline" | sed 's/\\/\\\\/g;s/"/\\"/g' | tr -d '\r')
        printf '{"event":"log","service":"%s","line":"%s"}\n' "$svc" "$_jline"
      done
      _deploy_rc=${PIPESTATUS[0]}

      if (( _deploy_rc == 0 )); then
        printf '{"event":"done","service":"%s","status":"success"}\n' "$svc"
        _history_log_event "$svc" "deploy" "ok" ""
        export MUSTER_DEPLOY_STATUS="success"
        run_skill_hooks "post-deploy" "$svc" 2>/dev/null

        # Health check
        local health_hook="${project_dir}/.muster/hooks/${svc}/health.sh"
        local health_enabled
        health_enabled=$(config_get ".services.${svc}.health.enabled")
        if [[ "$health_enabled" != "false" && -x "$health_hook" ]]; then
          printf '{"event":"health","service":"%s","status":"checking"}\n' "$svc"
          local _health_ok=false
          if remote_is_enabled "$svc"; then
            remote_exec_stdout "$svc" "$health_hook" "" &>/dev/null && _health_ok=true
          else
            "$health_hook" &>/dev/null && _health_ok=true
          fi
          if [[ "$_health_ok" == "true" ]]; then
            printf '{"event":"health","service":"%s","status":"healthy"}\n' "$svc"
          else
            printf '{"event":"health","service":"%s","status":"unhealthy"}\n' "$svc"
          fi
        fi
      else
        printf '{"event":"done","service":"%s","status":"failed","exit_code":%d}\n' "$svc" "$_deploy_rc"
        _history_log_event "$svc" "deploy" "failed" ""
        export MUSTER_DEPLOY_STATUS="failed"
        run_skill_hooks "post-deploy" "$svc" 2>/dev/null
      fi

      # Clean up env vars
      if [[ -n "$_cred_env_lines" ]]; then
        while IFS='=' read -r _ck _cv; do
          [[ -z "$_ck" ]] && continue
          unset "$_ck"
        done <<< "$_cred_env_lines"
      fi
      if [[ -n "$_k8s_env_lines" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          unset "$_ek"
        done <<< "$_k8s_env_lines"
      fi
      continue

    elif [[ "$dry_run" == "true" ]]; then
      # ── Dry-run: show plan without executing anything ──
      progress_bar "$current" "$total" "Deploying ${name}..."
      echo ""
      echo ""
      echo -e "  ${ACCENT}[DRY-RUN]${RESET} ${BOLD}Deploying ${name}${RESET} (${current}/${total})"
      echo -e "  ${DIM}Hook:${RESET} ${hook}"

      # Show first 10 lines of the hook script
      local _line_num=0
      local _separator=""
      printf -v _separator '%*s' 34 ''
      _separator="${_separator// /-}"
      echo -e "  ${DIM}${_separator}${RESET}"
      while IFS= read -r _line; do
        _line_num=$(( _line_num + 1 ))
        (( _line_num > 10 )) && break
        echo -e "  ${DIM}${_line}${RESET}"
      done < "$hook"
      if (( _line_num > 10 )); then
        echo -e "  ${DIM}...${RESET}"
      fi
      echo -e "  ${DIM}${_separator}${RESET}"

      # Show credential key names (without fetching values)
      local _cred_enabled
      _cred_enabled=$(config_get ".services.${svc}.credentials.enabled")
      if [[ "$_cred_enabled" == "true" ]]; then
        local _cred_keys=""
        _cred_keys=$(config_get ".services.${svc}.credentials.required[]" 2>/dev/null)
        if [[ -n "$_cred_keys" && "$_cred_keys" != "null" ]]; then
          local _cred_display=""
          while IFS= read -r _ck; do
            [[ -z "$_ck" ]] && continue
            local _upper_ck
            _upper_ck=$(printf '%s' "$_ck" | tr '[:lower:]' '[:upper:]')
            if [[ -n "$_cred_display" ]]; then
              _cred_display="${_cred_display}, MUSTER_CRED_${_upper_ck}"
            else
              _cred_display="MUSTER_CRED_${_upper_ck}"
            fi
          done <<< "$_cred_keys"
          echo -e "  ${DIM}Credentials:${RESET} ${_cred_display}"
        fi
      fi

      # Show health check status
      local health_hook="${project_dir}/.muster/hooks/${svc}/health.sh"
      local health_enabled
      health_enabled=$(config_get ".services.${svc}.health.enabled")
      if [[ "$health_enabled" != "false" && -x "$health_hook" ]]; then
        echo -e "  ${DIM}Health check:${RESET} ${health_hook} ${GREEN}(enabled)${RESET}"
      else
        echo -e "  ${DIM}Health check:${RESET} ${RED}(disabled)${RESET}"
      fi

      # Show remote status
      if remote_is_enabled "$svc"; then
        local _remote_pdir
        _remote_pdir=$(config_get ".services.${svc}.remote.project_dir")
        [[ "$_remote_pdir" == "null" ]] && _remote_pdir=""
        echo -e "  ${DIM}Remote:${RESET} $(remote_desc "$svc") ${GREEN}(enabled)${RESET}"
        if [[ -n "$_remote_pdir" ]]; then
          echo -e "  ${DIM}Project dir:${RESET} ${_remote_pdir}"
        fi
      fi

      # Show git pull status
      local _gp_enabled
      _gp_enabled=$(config_get ".services.${svc}.git_pull.enabled")
      if [[ "$_gp_enabled" == "true" ]]; then
        local _gp_remote _gp_branch
        _gp_remote=$(config_get ".services.${svc}.git_pull.remote")
        _gp_branch=$(config_get ".services.${svc}.git_pull.branch")
        [[ "$_gp_remote" == "null" || -z "$_gp_remote" ]] && _gp_remote="origin"
        [[ "$_gp_branch" == "null" || -z "$_gp_branch" ]] && _gp_branch="main"
        echo -e "  ${DIM}Git pull:${RESET} ${_gp_remote}/${_gp_branch} ${GREEN}(enabled)${RESET}"
      fi

      echo ""
    else
      # ── Normal deploy ──

      # Gather credentials if configured
      local _cred_env_lines=""
      _cred_env_lines=$(cred_env_for_service "$svc")

      # Export k8s config as env vars (hooks read these at runtime)
      local _k8s_env_lines=""
      _k8s_env_lines=$(k8s_env_for_service "$svc")
      if [[ -n "$_k8s_env_lines" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          export "$_ek=$_ev"
        done <<< "$_k8s_env_lines"
      fi

      export MUSTER_DEPLOY_STATUS=""
      export MUSTER_SERVICE_NAME="$name"

      # Load previous deploy SHA (before hook runs, which may git pull)
      local _git_in_repo="" _git_sha="" _git_prev_sha=""
      if _git_is_repo; then
        _git_in_repo="true"
        _git_prev_sha=$(_git_prev_deploy_sha "$svc")
        export MUSTER_GIT_PREV_COMMIT="$_git_prev_sha"
      fi

      run_skill_hooks "pre-deploy" "$svc"

      # Read git_pull config for this service
      local _gp_enabled=""
      _gp_enabled=$(config_get ".services.${svc}.git_pull.enabled")
      local _gp_remote="" _gp_branch=""
      if [[ "$_gp_enabled" == "true" ]]; then
        _gp_remote=$(config_get ".services.${svc}.git_pull.remote")
        _gp_branch=$(config_get ".services.${svc}.git_pull.branch")
        [[ "$_gp_remote" == "null" || -z "$_gp_remote" ]] && _gp_remote="origin"
        [[ "$_gp_branch" == "null" || -z "$_gp_branch" ]] && _gp_branch="main"
      fi

      progress_bar "$current" "$total" "Deploying ${name}..."
      echo ""

      # Preamble callback for stream_in_box to redraw context after viewer
      _deploy_redraw_preamble() {
        echo ""
        printf '  %b%bDeploying%b %b%s%b\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}" "${WHITE}" "$project" "${RESET}"
        echo ""
        progress_bar "$current" "$total" "Deploying ${name}..."
        echo ""
      }
      _SIB_REDRAW_FN="_deploy_redraw_preamble"

      while true; do
        local log_file="${log_dir}/${svc}-deploy-$(date +%Y%m%d-%H%M%S).log"

        # Auto git pull before deploy hook
        if [[ "$_gp_enabled" == "true" ]]; then
          local _gp_output="" _gp_rc=0
          if remote_is_enabled "$svc"; then
            start_spinner "Pulling ${_gp_remote}/${_gp_branch} on $(remote_desc "$svc")"
            _remote_load_config "$svc"
            _remote_build_opts
            local _gp_cmd="cd ${_REMOTE_PROJECT_DIR:-.} && git pull ${_gp_remote} ${_gp_branch}"
            _gp_output=$(ssh $_SSH_OPTS "${_REMOTE_USER}@${_REMOTE_HOST}" "$_gp_cmd" 2>&1) || _gp_rc=$?
          else
            start_spinner "Pulling ${_gp_remote}/${_gp_branch}"
            _gp_output=$(git pull "$_gp_remote" "$_gp_branch" 2>&1) || _gp_rc=$?
          fi
          stop_spinner

          if (( _gp_rc != 0 )); then
            err "git pull failed for ${name}"
            echo -e "  ${DIM}${_gp_output}${RESET}"
            echo ""
            menu_select "Git pull failed. What do you want to do?" "Retry" "Skip git pull" "Abort"
            case "$MENU_RESULT" in
              "Retry")
                continue
                ;;
              "Skip git pull")
                warn "Skipping git pull, deploying with current code"
                ;;
              "Abort")
                _unload_env_file
                return 1
                ;;
            esac
          else
            ok "Pulled ${_gp_remote}/${_gp_branch}"
          fi
        fi

        if remote_is_enabled "$svc"; then
          # ── Remote deploy via SSH ──
          info "Deploying ${name} remotely ($(remote_desc "$svc"))"
          local _all_env="${_cred_env_lines}"
          [[ -n "$_k8s_env_lines" ]] && _all_env="${_all_env}
${_k8s_env_lines}"
          stream_in_box "$name" "$log_file" remote_exec_stdout "$svc" "$hook" "$_all_env"
        else
          # ── Local deploy ──
          if [[ -n "$_cred_env_lines" ]]; then
            while IFS='=' read -r _ck _cv; do
              [[ -z "$_ck" ]] && continue
              export "$_ck=$_cv"
            done <<< "$_cred_env_lines"
          fi

          stream_in_box "$name" "$log_file" "$hook"
        fi
        unset _SIB_REDRAW_FN
        local rc=$?

        if (( rc == 0 )); then
          ok "${name} deployed"

          # Capture SHA after hook (hook may have done git pull)
          if [[ "$_git_in_repo" == "true" ]]; then
            _git_sha=$(_git_current_sha)
            export MUSTER_GIT_COMMIT="$_git_sha"
            if [[ -n "$_git_prev_sha" ]]; then
              echo ""
              _git_deploy_diff "$_git_prev_sha" "$_git_sha"
            fi
            _git_save_deploy_sha "$svc" "$_git_sha"
          fi

          _history_log_event "$svc" "deploy" "ok" "$_git_sha"
          export MUSTER_DEPLOY_STATUS="success"
          run_skill_hooks "post-deploy" "$svc"

          # Run health check
          local health_hook="${project_dir}/.muster/hooks/${svc}/health.sh"
          local health_enabled
          health_enabled=$(config_get ".services.${svc}.health.enabled")
          if [[ "$health_enabled" != "false" && -x "$health_hook" ]]; then
            start_spinner "Health check: ${name}"
            local _health_ok=false
            if remote_is_enabled "$svc"; then
              if remote_exec_stdout "$svc" "$health_hook" "" &>/dev/null; then
                _health_ok=true
              fi
            else
              if "$health_hook" &>/dev/null; then
                _health_ok=true
              fi
            fi
            if [[ "$_health_ok" == "true" ]]; then
              stop_spinner
              ok "${name} healthy"
            else
              stop_spinner
              err "${name} health check failed"
              echo ""
              menu_select "Health check failed. What do you want to do?" "Continue anyway" "Rollback ${name}" "Abort"
              case "$MENU_RESULT" in
                "Rollback ${name}")
                  local rb_hook="${project_dir}/.muster/hooks/${svc}/rollback.sh"
                  if [[ -x "$rb_hook" ]]; then
                    if remote_is_enabled "$svc"; then
                      remote_exec_stdout "$svc" "$rb_hook" "$_cred_env_lines" 2>&1 | tee "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log"
                    else
                      "$rb_hook" 2>&1 | tee "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log"
                    fi
                    ok "${name} rolled back"
                    _history_log_event "$svc" "rollback" "ok"
                  else
                    err "No rollback hook for ${name}"
                  fi
                  ;;
                "Abort")
                  err "Deploy aborted"
                  _unload_env_file
                  return 1
                  ;;
              esac
            fi
          fi

          # After-deploy: offer log viewer, then wait for keypress
          if [[ -f "$log_file" && -t 0 ]]; then
            echo ""
            printf '  %bCtrl+O view full log  •  any key to continue%b ' "${DIM}" "${RESET}"
            while true; do
              local _post_key=""
              IFS= read -rsn1 _post_key 2>/dev/null || true
              if [[ "$_post_key" == $'\x0f' ]]; then
                _log_viewer "$name deploy log" "$log_file"
                # Viewer cleared screen; reprint hint
                tput clear
                printf '  %bCtrl+O view full log  •  any key to continue%b ' "${DIM}" "${RESET}"
              else
                # Any other key — continue
                break
              fi
            done
            # Clear the hint line
            printf '\r'
            tput el 2>/dev/null || true
          fi

          break
        else
          err "${name} deploy failed (exit code ${rc})"
          # Re-capture SHA after hook (may have done git pull before failing)
          if [[ "$_git_in_repo" == "true" ]]; then
            _git_sha=$(_git_current_sha)
            export MUSTER_GIT_COMMIT="$_git_sha"
          fi
          _history_log_event "$svc" "deploy" "failed" "$_git_sha"

          # Show last few lines of log for context
          echo ""
          if [[ -f "$log_file" ]]; then
            tail -5 "$log_file" | while IFS= read -r _line; do
              echo -e "  ${DIM}${_line}${RESET}"
            done
          fi
          echo ""

          k8s_diagnose_failure "$svc"

          # Notify skills immediately so team knows action is needed
          export MUSTER_DEPLOY_STATUS="failed"
          run_skill_hooks "post-deploy" "$svc"

          # Build menu options (add "Rollback & restart" for k8s update deploys)
          local _fail_opts=()
          _fail_opts[0]="Retry"
          if [[ "${MUSTER_DEPLOY_MODE:-}" == "update" && -n "${MUSTER_K8S_DEPLOYMENT:-}" ]]; then
            _fail_opts[${#_fail_opts[@]}]="Rollback & restart"
          fi
          _fail_opts[${#_fail_opts[@]}]="Rollback ${name}"
          _fail_opts[${#_fail_opts[@]}]="Skip and continue"
          _fail_opts[${#_fail_opts[@]}]="Abort"

          menu_select "Deploy failed. What do you want to do?" "${_fail_opts[@]}"

          case "$MENU_RESULT" in
            "Retry")
              ;; # loop continues
            "Rollback & restart")
              local _rb_ns="${MUSTER_K8S_NAMESPACE:-default}"
              local _rb_dep="${MUSTER_K8S_DEPLOYMENT}"
              start_spinner "Rolling back & restarting ${name}..."
              _diag_run_kubectl "$svc" "kubectl rollout undo deployment/${_rb_dep} -n ${_rb_ns}" \
                >> "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log" 2>&1
              _diag_run_kubectl "$svc" "kubectl rollout restart deployment/${_rb_dep} -n ${_rb_ns}" \
                >> "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log" 2>&1
              stop_spinner
              ok "${name} rolled back & restarted"
              _history_log_event "$svc" "rollback" "ok"
              break
              ;;
            "Rollback ${name}")
              local rb_hook="${project_dir}/.muster/hooks/${svc}/rollback.sh"
              if [[ -x "$rb_hook" ]]; then
                start_spinner "Rolling back ${name}..."
                if remote_is_enabled "$svc"; then
                  remote_exec_stdout "$svc" "$rb_hook" "$_cred_env_lines" >> "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log" 2>&1
                else
                  "$rb_hook" >> "${log_dir}/${svc}-rollback-$(date +%Y%m%d-%H%M%S).log" 2>&1
                fi
                stop_spinner
                ok "${name} rolled back"
                _history_log_event "$svc" "rollback" "ok"
              else
                err "No rollback hook for ${name}"
              fi
              break
              ;;
            "Skip and continue")
              warn "Skipping ${name}, continuing with next service"
              export MUSTER_DEPLOY_STATUS="skipped"
              run_skill_hooks "post-deploy" "$svc"
              break
              ;;
            "Abort")
              _unload_env_file
              return 1
              ;;
          esac
        fi
      done

      # Clean up exported env vars (local deploy only)
      if ! remote_is_enabled "$svc"; then
        if [[ -n "$_cred_env_lines" ]]; then
          while IFS='=' read -r _ck _cv; do
            [[ -z "$_ck" ]] && continue
            unset "$_ck"
          done <<< "$_cred_env_lines"
        fi
      fi
      if [[ -n "$_k8s_env_lines" ]]; then
        while IFS='=' read -r _ek _ev; do
          [[ -z "$_ek" ]] && continue
          unset "$_ek"
        done <<< "$_k8s_env_lines"
      fi
      unset MUSTER_GIT_COMMIT MUSTER_GIT_PREV_COMMIT

      echo ""
    fi
  done

  if [[ "$_json_mode" == "true" ]]; then
    printf '{"event":"complete","total":%d,"dry_run":%s}\n' "$total" "$dry_run"
  else
    progress_bar "$total" "$total" "Complete"
    echo ""
    echo ""
    if [[ "$dry_run" == "true" ]]; then
      info "[DRY-RUN] Deploy plan complete — no changes made"
    else
      ok "Deploy complete"
    fi
    echo ""
  fi

  _unload_env_file
}
