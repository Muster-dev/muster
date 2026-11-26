#!/usr/bin/env bash
# muster/lib/commands/doctor.sh — Comprehensive project diagnostics

cmd_doctor() {
  local fix=false
  local _json_mode=false
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: muster doctor [flags]"
        echo ""
        echo "Run comprehensive project diagnostics across 6 categories."
        echo ""
        echo "Categories:"
        echo "  Platform & Tools      OS, Docker, kubectl, jq, git, SSH"
        echo "  Configuration         Config file, hooks, services, health checks"
        echo "  Stack Readiness       Docker daemon, k8s cluster, compose files"
        echo "  Connectivity          SSH remotes, fleet machines"
        echo "  Health & Runtime      Health endpoints, ports, timeouts"
        echo "  Storage & Maintenance Logs, PIDs, build context, disk space"
        echo ""
        echo "Flags:"
        echo "  --fix           Auto-fix issues where possible"
        echo "  --json          Output as JSON"
        echo "  -h, --help      Show this help"
        return 0
        ;;
      --fix) fix=true; shift ;;
      --json) _json_mode=true; shift ;;
      *)
        err "Unknown flag: $1"
        echo "Run 'muster doctor --help' for usage."
        return 1
        ;;
    esac
  done

  load_config
  source "$MUSTER_ROOT/lib/core/build_context.sh"
  source "$MUSTER_ROOT/lib/tui/spinner.sh"

  # Auth gate: JSON mode requires valid token
  if [[ "$_json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
  fi

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  # ── Counters via temp file (survives subshells) ──
  local _DOC_COUNTS
  _DOC_COUNTS=$(mktemp 2>/dev/null || echo "/tmp/muster-doc-$$")
  printf '0 0 0\n' > "$_DOC_COUNTS"

  _doc_bump() {
    local _p _w _f
    read _p _w _f < "$_DOC_COUNTS"
    case "$1" in
      pass) _p=$((_p + 1)) ;; warn) _w=$((_w + 1)) ;; fail) _f=$((_f + 1)) ;;
    esac
    printf '%d %d %d\n' "$_p" "$_w" "$_f" > "$_DOC_COUNTS"
  }

  # JSON mode: collect checks
  local _JSON_FILE
  _JSON_FILE=$(mktemp 2>/dev/null || echo "/tmp/muster-doc-json-$$")
  printf '' > "$_JSON_FILE"

  _doc_json_add() {
    local _name="$1" _status="$2" _cat="$3"
    # Escape quotes in name
    _name="${_name//\"/\\\"}"
    local _sep=""
    [[ -s "$_JSON_FILE" ]] && _sep=","
    printf '%s{"name":"%s","status":"%s","category":"%s"}' "$_sep" "$_name" "$_status" "$_cat" >> "$_JSON_FILE"
  }

  # Current category for JSON tagging
  local _DOC_CAT=""

  _doc_pass() {
    _doc_bump pass
    if [[ "$_json_mode" == "true" ]]; then
      _doc_json_add "$1" "pass" "$_DOC_CAT"
    elif [[ "$MUSTER_MINIMAL" == "true" ]]; then
      printf 'PASS: %s\n' "$1"
    else
      printf '%b\n' "  ${GREEN}✓${RESET} $1"
    fi
  }
  _doc_warn() {
    _doc_bump warn
    if [[ "$_json_mode" == "true" ]]; then
      _doc_json_add "$1" "warn" "$_DOC_CAT"
    elif [[ "$MUSTER_MINIMAL" == "true" ]]; then
      printf 'WARN: %s\n' "$1"
    else
      printf '%b\n' "  ${YELLOW}!${RESET} $1"
    fi
  }
  _doc_fail() {
    _doc_bump fail
    if [[ "$_json_mode" == "true" ]]; then
      _doc_json_add "$1" "fail" "$_DOC_CAT"
    elif [[ "$MUSTER_MINIMAL" == "true" ]]; then
      printf 'FAIL: %s\n' "$1"
    else
      printf '%b\n' "  ${RED}✗${RESET} $1"
    fi
  }
  _doc_detail() {
    if [[ "$_json_mode" == "false" && "$MUSTER_MINIMAL" != "true" ]]; then
      printf '%b\n' "    ${DIM}$1${RESET}"
    fi
  }

  # ── Category runner ──
  _doc_run_category() {
    local _cat_name="$1" _spinner_msg="$2" _cat_fn="$3"
    _DOC_CAT="$_cat_name"

    if [[ "$_json_mode" == "false" && "$MUSTER_MINIMAL" != "true" ]]; then
      start_spinner "$_spinner_msg"
      # Run checks with master timeout (prevents any single category from hanging)
      local _cat_output="" _cat_tmp="/tmp/.muster_cat_$$"
      rm -f "$_cat_tmp"
      ( "$_cat_fn" > "$_cat_tmp" 2>&1 ) &
      local _cat_pid=$!
      ( sleep 30 && kill "$_cat_pid" 2>/dev/null ) &
      local _cat_kill_pid=$!
      wait "$_cat_pid" 2>/dev/null || true
      kill "$_cat_kill_pid" 2>/dev/null; wait "$_cat_kill_pid" 2>/dev/null || true
      _cat_output=$(cat "$_cat_tmp" 2>/dev/null)
      rm -f "$_cat_tmp"
      stop_spinner
      printf '  %b%b%s%b\n' "${BOLD}" "${WHITE}" "$_cat_name" "${RESET}"
      [[ -n "$_cat_output" ]] && printf '%s\n' "$_cat_output"
      echo ""
    else
      "$_cat_fn"
    fi
  }

  # ── Detect stack type from hooks ──
  local _needs_docker=false _needs_kubectl=false _needs_compose=false
  local hooks_dir="${project_dir}/.muster/hooks"
  if [[ -d "$hooks_dir" ]]; then
    local _all_hooks=""
    for _hf in "$hooks_dir"/*/*.sh; do
      [[ -f "$_hf" ]] || continue
      _all_hooks="${_all_hooks}
$(cat "$_hf" 2>/dev/null)"
    done
    case "$_all_hooks" in *docker\ build*|*docker\ push*) _needs_docker=true ;; esac
    case "$_all_hooks" in *kubectl*) _needs_kubectl=true ;; esac
    case "$_all_hooks" in *docker\ compose*|*docker-compose*) _needs_compose=true ;; esac
  fi

  # Get services list once
  local services
  services=$(config_services)

  # ── Header ──
  if [[ "$_json_mode" == "false" && "$MUSTER_MINIMAL" != "true" ]]; then
    echo ""
    printf '%b\n' "  ${BOLD}Doctor${RESET}"
    echo ""
  fi

  # ════════════════════════════════════════════════
  # Category 1: Platform & Tools
  # ════════════════════════════════════════════════
  _doc_cat_platform() {
    # OS + arch
    _doc_pass "OS: ${MUSTER_OS} ${MUSTER_ARCH}"

    # Docker
    if [[ "$MUSTER_HAS_DOCKER" == "true" ]]; then
      if docker info &>/dev/null; then
        _doc_pass "Docker installed and running"
      else
        _doc_warn "Docker installed but daemon not running"
      fi
    elif [[ "$_needs_docker" == "true" ]]; then
      _doc_fail "Docker not found (required by hooks)"
    else
      _doc_pass "Docker not needed"
    fi

    # Docker Compose
    if [[ "$_needs_compose" == "true" ]]; then
      if docker compose version &>/dev/null 2>&1; then
        _doc_pass "Docker Compose available"
      elif command -v docker-compose &>/dev/null; then
        _doc_pass "Docker Compose (standalone) available"
      else
        _doc_fail "Docker Compose not found (required by hooks)"
      fi
    fi

    # kubectl
    if [[ "$MUSTER_HAS_KUBECTL" == "true" ]]; then
      _doc_pass "kubectl installed"
    elif [[ "$_needs_kubectl" == "true" ]]; then
      _doc_fail "kubectl not found (required by hooks)"
    fi

    # jq
    if [[ "$MUSTER_HAS_JQ" == "true" ]]; then
      _doc_pass "jq available"
    else
      _doc_warn "jq not found (some features unavailable)"
    fi

    # Git
    if has_cmd git; then
      _doc_pass "Git installed"
    else
      _doc_warn "Git not found"
    fi

    # SSH
    if has_cmd ssh; then
      _doc_pass "SSH client available"
    else
      local _has_remotes=false
      while IFS= read -r _svc; do
        [[ -z "$_svc" ]] && continue
        local _re
        _re=$(config_get ".services.${_svc}.remote.enabled" 2>/dev/null)
        [[ "$_re" == "true" ]] && _has_remotes=true
      done <<< "$services"
      if [[ "$_has_remotes" == "true" ]]; then
        _doc_fail "SSH not found (required for remote deploys)"
      fi
    fi
  }

  _doc_run_category "Platform & Tools" "Checking platform & tools..." _doc_cat_platform

  # ════════════════════════════════════════════════
  # Category 2: Configuration
  # ════════════════════════════════════════════════
  _doc_cat_config() {
    # Config file valid
    if [[ -f "$CONFIG_FILE" ]]; then
      local _json_valid=false
      if has_cmd jq; then
        jq '.' "$CONFIG_FILE" &>/dev/null && _json_valid=true
      elif has_cmd python3; then
        python3 -c "import json; json.load(open('$CONFIG_FILE'))" &>/dev/null && _json_valid=true
      else
        _json_valid=true
      fi
      local _config_name
      _config_name="$(basename "$CONFIG_FILE")"
      if [[ "$_json_valid" == "true" ]]; then
        _doc_pass "${_config_name} valid JSON"
      else
        _doc_fail "${_config_name} has invalid JSON"
      fi
    else
      _doc_fail "Config file not found"
    fi

    # Hooks directory
    if [[ -d "$hooks_dir" ]]; then
      _doc_pass ".muster/hooks/ directory exists"
    else
      _doc_fail ".muster/hooks/ directory missing"
    fi

    # Service count
    local _svc_count=0
    while IFS= read -r _svc; do
      [[ -z "$_svc" ]] && continue
      _svc_count=$(( _svc_count + 1 ))
    done <<< "$services"
    _doc_pass "${_svc_count} services configured"

    # Per-service hook checks
    local _missing_dirs=0 _missing_hooks=0 _not_exec=0 _fixed_exec=0
    local _justfile_count=0 _justfile_no_just=0
    local _expected="deploy.sh health.sh rollback.sh logs.sh cleanup.sh"
    while IFS= read -r _svc; do
      [[ -z "$_svc" ]] && continue
      local _shd="${hooks_dir}/${_svc}"
      if [[ ! -d "$_shd" ]]; then
        _missing_dirs=$(( _missing_dirs + 1 ))
        continue
      fi
      # Check for justfile
      local _has_justfile=false
      if [[ -f "${_shd}/justfile" ]]; then
        _has_justfile=true
        _justfile_count=$(( _justfile_count + 1 ))
        if ! has_cmd just; then
          _justfile_no_just=$(( _justfile_no_just + 1 ))
        fi
      fi
      for _h in $_expected; do
        local _hp="${_shd}/${_h}"
        if [[ ! -f "$_hp" ]]; then
          # Skip missing .sh if justfile has the recipe
          if [[ "$_has_justfile" == "true" ]]; then
            continue
          fi
          _missing_hooks=$(( _missing_hooks + 1 ))
        elif [[ ! -x "$_hp" ]]; then
          if [[ "$fix" == "true" ]]; then
            chmod +x "$_hp"
            _fixed_exec=$(( _fixed_exec + 1 ))
          else
            _not_exec=$(( _not_exec + 1 ))
          fi
        fi
      done
    done <<< "$services"

    if (( _missing_dirs > 0 )); then
      _doc_fail "${_missing_dirs} service(s) missing hooks directory"
    fi
    if (( _missing_hooks > 0 )); then
      _doc_warn "${_missing_hooks} hook script(s) missing"
    fi
    if (( _not_exec > 0 )); then
      _doc_fail "${_not_exec} hook scripts not executable (--fix)"
    elif (( _fixed_exec > 0 )); then
      _doc_pass "Fixed ${_fixed_exec} hook scripts (chmod +x)"
    elif (( _missing_dirs == 0 && _missing_hooks == 0 )); then
      _doc_pass "All hook scripts present and executable"
    fi

    # Hook integrity (manifest verification)
    source "$MUSTER_ROOT/lib/core/hook_security.sh"
    local _manifest_file="${project_dir}/.muster/hooks.manifest"
    if [[ -f "$_manifest_file" ]]; then
      # Manifest signature check
      _hook_manifest_verify_sig "$_manifest_file"
      local _sig_rc=$?
      if [[ "$_sig_rc" == "1" ]]; then
        _doc_fail "Hooks manifest signature invalid (possible tampering)"
      elif [[ "$_sig_rc" == "0" ]]; then
        _doc_pass "Hooks manifest signature valid"
      fi

      # Hook integrity check
      local _tampered=0 _untracked=0
      local _sd
      for _sd in "${hooks_dir}"/*/; do
        [[ ! -d "$_sd" ]] && continue
        local _sv
        _sv=$(basename "$_sd")
        [[ "$_sv" == "logs" || "$_sv" == "pids" ]] && continue
        local _hf
        for _hf in "${_sd}"*.sh "${_sd}"justfile; do
          [[ ! -f "$_hf" ]] && continue
          _hook_manifest_verify "$_hf" "$project_dir"
          case $? in
            1) _tampered=$(( _tampered + 1 )) ;;
            2) _untracked=$(( _untracked + 1 )) ;;
          esac
        done
      done
      if (( _tampered > 0 )); then
        _doc_fail "${_tampered} hook(s) tampered (run 'muster hooks approve' to re-sign)"
      elif (( _untracked > 0 )); then
        _doc_warn "${_untracked} hook(s) not in manifest"
      else
        _doc_pass "All hooks pass integrity check"
      fi

      # Config file integrity
      _config_integrity_check "$project_dir"
      local _cfg_rc=$?
      if [[ "$_cfg_rc" == "1" ]]; then
        _doc_fail "Config file tampered (run 'muster hooks approve' to re-sign)"
      elif [[ "$_cfg_rc" == "0" ]]; then
        _doc_pass "Config file passes integrity check"
      fi

      # .env integrity
      if [[ -f "${project_dir}/.env" ]]; then
        _env_integrity_check "$project_dir"
        local _env_rc=$?
        if [[ "$_env_rc" == "1" ]]; then
          _doc_warn ".env file modified since last approve (run 'muster hooks approve')"
        elif [[ "$_env_rc" == "0" ]]; then
          _doc_pass ".env file passes integrity check"
        fi
      fi
    else
      _doc_warn "No hooks manifest (run 'muster hooks approve' to create)"
    fi

    # Justfile checks
    if (( _justfile_count > 0 )); then
      if (( _justfile_no_just > 0 )); then
        _doc_warn "${_justfile_no_just} service(s) have justfile but 'just' is not installed"
        _doc_detail "Install: https://just.systems"
      else
        _doc_pass "${_justfile_count} service(s) using justfile hooks"
      fi
    fi

    # Deploy order check
    if has_cmd jq; then
      local _deploy_order
      _deploy_order=$(jq -r '.deploy_order // [] | .[]' "$CONFIG_FILE" 2>/dev/null)
      if [[ -n "$_deploy_order" ]]; then
        local _order_missing=0
        while IFS= read -r _svc; do
          [[ -z "$_svc" ]] && continue
          local _in_order=false
          while IFS= read -r _os; do
            [[ "$_os" == "$_svc" ]] && _in_order=true
          done <<< "$_deploy_order"
          if [[ "$_in_order" == "false" ]]; then
            local _skip
            _skip=$(config_get ".services.${_svc}.skip_deploy" 2>/dev/null)
            if [[ "$_skip" != "true" ]]; then
              _order_missing=$(( _order_missing + 1 ))
            fi
          fi
        done <<< "$services"
        if (( _order_missing > 0 )); then
          _doc_warn "${_order_missing} service(s) not in deploy_order"
        else
          _doc_pass "Deploy order matches configured services"
        fi
      fi
    fi

    # Health check configuration
    local _health_on=0 _health_off=0 _health_no_type=0
    while IFS= read -r _svc; do
      [[ -z "$_svc" ]] && continue
      local _he
      _he=$(config_get ".services.${_svc}.health.enabled" 2>/dev/null)
      if [[ "$_he" == "false" ]]; then
        _health_off=$(( _health_off + 1 ))
      else
        _health_on=$(( _health_on + 1 ))
        local _ht
        _ht=$(config_get ".services.${_svc}.health.type" 2>/dev/null)
        if [[ -z "$_ht" || "$_ht" == "null" ]]; then
          _health_no_type=$(( _health_no_type + 1 ))
        fi
      fi
    done <<< "$services"
    if (( _health_off > 0 && _health_on == 0 )); then
      _doc_warn "Health checks disabled for all ${_health_off} services"
    elif (( _health_off > 0 )); then
      _doc_warn "Health checks disabled for ${_health_off} service(s)"
    else
      _doc_pass "Health checks enabled for all services"
    fi
    if (( _health_no_type > 0 )); then
      _doc_warn "${_health_no_type} service(s) have no health check type set"
    fi

    # .env file
    local _env_file="${project_dir}/.env"
    if [[ -f "$_env_file" ]]; then
      local _env_count=0
      while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$_line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]]; then
          _env_count=$(( _env_count + 1 ))
        fi
      done < "$_env_file"
      _doc_pass ".env file found (${_env_count} vars)"
    else
      _doc_warn ".env file not found"
    fi
  }

  _doc_run_category "Configuration" "Validating configuration..." _doc_cat_config

  # ════════════════════════════════════════════════
  # Category 3: Stack Readiness
  # ════════════════════════════════════════════════
  _doc_cat_stack() {
    local _has_checks=false

    # Docker stack checks
    if [[ "$_needs_docker" == "true" && "$MUSTER_HAS_DOCKER" == "true" ]]; then
      _has_checks=true
      # Docker daemon
      if docker info &>/dev/null; then
        _doc_pass "Docker daemon responding"

        # Check for Dockerfiles
        local _missing_df=0
        while IFS= read -r _svc; do
          [[ -z "$_svc" ]] && continue
          local _deploy_hook="${hooks_dir}/${_svc}/deploy.sh"
          [[ -f "$_deploy_hook" ]] || continue
          if grep -q 'docker build' "$_deploy_hook" 2>/dev/null; then
            # Extract Dockerfile path from hook
            local _df_path=""
            _df_path=$(grep 'docker build' "$_deploy_hook" 2>/dev/null | grep -o '\-f [^ "]*' | head -1 | sed 's/-f //')
            if [[ -z "$_df_path" ]]; then
              _df_path=$(grep 'docker build' "$_deploy_hook" 2>/dev/null | grep -o "\-f '[^']*'" | head -1 | sed "s/-f '//;s/'$//")
            fi
            [[ -z "$_df_path" ]] && _df_path="Dockerfile"

            # Resolve relative to project dir
            if [[ "$_df_path" != /* ]]; then
              _df_path="${project_dir}/${_df_path}"
            fi
            if [[ ! -f "$_df_path" ]]; then
              _missing_df=$(( _missing_df + 1 ))
              _doc_fail "Dockerfile missing for ${_svc}: ${_df_path##*/}"
            fi
          fi
        done <<< "$services"
        if (( _missing_df == 0 )); then
          _doc_pass "All Dockerfiles found"
        fi
      else
        _doc_fail "Docker daemon not responding"
      fi
    fi

    # Docker Compose checks
    if [[ "$_needs_compose" == "true" ]]; then
      _has_checks=true
      local _compose_file=""
      [[ -f "${project_dir}/docker-compose.yml" ]] && _compose_file="${project_dir}/docker-compose.yml"
      [[ -z "$_compose_file" && -f "${project_dir}/docker-compose.yaml" ]] && _compose_file="${project_dir}/docker-compose.yaml"
      [[ -z "$_compose_file" && -f "${project_dir}/compose.yml" ]] && _compose_file="${project_dir}/compose.yml"
      [[ -z "$_compose_file" && -f "${project_dir}/compose.yaml" ]] && _compose_file="${project_dir}/compose.yaml"

      if [[ -n "$_compose_file" ]]; then
        _doc_pass "Compose file found: $(basename "$_compose_file")"
      else
        _doc_warn "No docker-compose.yml found"
      fi
    fi

    # Kubernetes checks
    if [[ "$_needs_kubectl" == "true" && "$MUSTER_HAS_KUBECTL" == "true" ]]; then
      _has_checks=true

      # Context
      local _kctx
      _kctx=$(kubectl config current-context 2>/dev/null)
      if [[ -n "$_kctx" ]]; then
        _doc_pass "K8s context: ${_kctx}"
      else
        _doc_fail "No Kubernetes context set"
      fi

      # Cluster reachable
      if kubectl cluster-info &>/dev/null; then
        _doc_pass "K8s cluster reachable"

        # Namespace checks
        local _ns_checked=""
        while IFS= read -r _svc; do
          [[ -z "$_svc" ]] && continue
          local _ns
          _ns=$(config_get ".services.${_svc}.k8s.namespace" 2>/dev/null)
          [[ -z "$_ns" || "$_ns" == "null" ]] && continue
          # Skip if already checked this namespace
          case " $_ns_checked " in *" $_ns "*) continue ;; esac
          _ns_checked="${_ns_checked} ${_ns}"

          if kubectl get namespace "$_ns" &>/dev/null; then
            _doc_pass "Namespace exists: ${_ns}"
          else
            _doc_fail "Namespace not found: ${_ns}"
          fi
        done <<< "$services"

        # Deployment checks
        local _deploy_found=0 _deploy_missing=0
        while IFS= read -r _svc; do
          [[ -z "$_svc" ]] && continue
          local _dep _ns
          _dep=$(config_get ".services.${_svc}.k8s.deployment" 2>/dev/null)
          _ns=$(config_get ".services.${_svc}.k8s.namespace" 2>/dev/null)
          [[ -z "$_dep" || "$_dep" == "null" ]] && continue
          [[ -z "$_ns" || "$_ns" == "null" ]] && _ns="default"

          if kubectl get deployment "$_dep" -n "$_ns" &>/dev/null; then
            _deploy_found=$(( _deploy_found + 1 ))
          else
            _deploy_missing=$(( _deploy_missing + 1 ))
            _doc_warn "Deployment not found: ${_dep} (ns: ${_ns})"
          fi
        done <<< "$services"
        if (( _deploy_found > 0 && _deploy_missing == 0 )); then
          _doc_pass "All ${_deploy_found} K8s deployment(s) found"
        fi
      else
        _doc_fail "K8s cluster not reachable"
      fi
    fi

    if [[ "$_has_checks" == "false" ]]; then
      _doc_pass "No stack-specific checks needed"
    fi
  }

  _doc_run_category "Stack Readiness" "Checking stack readiness..." _doc_cat_stack

  # ════════════════════════════════════════════════
  # Category 4: Connectivity
  # ════════════════════════════════════════════════
  _doc_cat_connectivity() {
    local _has_checks=false

    # Remote service SSH checks
    while IFS= read -r _svc; do
      [[ -z "$_svc" ]] && continue
      local _re
      _re=$(config_get ".services.${_svc}.remote.enabled" 2>/dev/null)
      [[ "$_re" != "true" ]] && continue
      _has_checks=true

      local _rh _ru _rp _ri
      _rh=$(config_get ".services.${_svc}.remote.host" 2>/dev/null)
      _ru=$(config_get ".services.${_svc}.remote.user" 2>/dev/null)
      _rp=$(config_get ".services.${_svc}.remote.port" 2>/dev/null)
      _ri=$(config_get ".services.${_svc}.remote.identity_file" 2>/dev/null)
      [[ -z "$_rp" || "$_rp" == "null" ]] && _rp="22"
      [[ "$_ri" == "null" ]] && _ri=""

      # Check identity file exists
      if [[ -n "$_ri" ]]; then
        local _ri_expanded="${_ri/#\~/$HOME}"
        if [[ -f "$_ri_expanded" ]]; then
          _doc_pass "SSH key exists: ${_svc} (${_ri})"
        else
          _doc_fail "SSH key not found: ${_svc} (${_ri})"
        fi
      fi

      # SSH connectivity
      local _sopts="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
      [[ -n "$_ri" ]] && _sopts="${_sopts} -i ${_ri/#\~/$HOME}"
      [[ "$_rp" != "22" ]] && _sopts="${_sopts} -p ${_rp}"

      if ssh -n $_sopts "${_ru}@${_rh}" "echo ok" &>/dev/null; then
        _doc_pass "SSH reachable: ${_svc} (${_ru}@${_rh})"
      else
        _doc_fail "SSH unreachable: ${_svc} (${_ru}@${_rh})"
      fi
    done <<< "$services"

    # Fleet connectivity (remotes.json or fleet dirs)
    local _fleet_cfg="${project_dir}/remotes.json"
    local _has_fleet_cfg=false
    [[ -f "$_fleet_cfg" ]] && _has_fleet_cfg=true
    fleet_cfg_has_any 2>/dev/null && _has_fleet_cfg=true

    if [[ "$_has_fleet_cfg" == "true" ]] && has_cmd jq; then
      local _fleet_machines=""
      if fleet_cfg_has_any 2>/dev/null; then
        _fleet_machines=$(fleet_machines 2>/dev/null)
      elif [[ -f "$_fleet_cfg" ]]; then
        _fleet_machines=$(jq -r '.machines | keys[]' "$_fleet_cfg" 2>/dev/null)
      fi
      if [[ -n "$_fleet_machines" ]]; then
        _has_checks=true
        source "$MUSTER_ROOT/lib/core/fleet.sh"
        if [[ -f "$_fleet_cfg" ]]; then
          # shellcheck disable=SC2034
          FLEET_CONFIG_FILE="$_fleet_cfg"
        else
          # shellcheck disable=SC2034
          FLEET_CONFIG_FILE="__fleet_dirs__"
        fi

        local _fleet_ok=0 _fleet_fail=0 _fleet_total=0 _fleet_root=0
        while IFS= read -r _fm; do
          [[ -z "$_fm" ]] && continue
          _fleet_total=$(( _fleet_total + 1 ))
          if fleet_check "$_fm" 2>/dev/null; then
            _fleet_ok=$(( _fleet_ok + 1 ))
            # Non-root check
            local _uid
            _uid=$(fleet_exec "$_fm" "id -u" 2>/dev/null | tr -d '[:space:]')
            if [[ "$_uid" == "0" ]]; then
              _fleet_root=$(( _fleet_root + 1 ))
              _doc_warn "Fleet: ${_fm} running as root"
              _doc_detail "Consider: muster fleet setup-user ${_fm}"
            fi
          else
            _fleet_fail=$(( _fleet_fail + 1 ))
            _doc_fail "Fleet machine unreachable: ${_fm}"
          fi
        done <<< "$_fleet_machines"

        if (( _fleet_fail == 0 )); then
          _doc_pass "Fleet: all ${_fleet_ok} machine(s) reachable"
        elif (( _fleet_ok > 0 )); then
          _doc_warn "Fleet: ${_fleet_ok}/${_fleet_total} reachable"
        fi

        # Fleet agent checks
        local _agent_ok=0 _agent_stale=0 _agent_stopped=0 _agent_total=0
        while IFS= read -r _am; do
          [[ -z "$_am" ]] && continue
          local _ai
          _ai="false"
          if fleet_cfg_find_project "$_am" 2>/dev/null; then
            local _doc_pdir
            _doc_pdir="$(fleet_cfg_project_dir "$_FP_FLEET" "$_FP_GROUP" "$_FP_PROJECT")"
            _ai=$(jq -r '.agent_installed // false' "${_doc_pdir}/project.json" 2>/dev/null)
          elif [[ -f "$_fleet_cfg" ]]; then
            _ai=$(jq -r --arg n "$_am" '.machines[$n].agent_installed // false' "$_fleet_cfg" 2>/dev/null)
          fi
          [[ "$_ai" != "true" ]] && continue
          _agent_total=$(( _agent_total + 1 ))

          # Check PID
          local _apid
          _apid=$(fleet_exec "$_am" "cat ~/.muster/agent/agent.pid 2>/dev/null && kill -0 \$(cat ~/.muster/agent/agent.pid 2>/dev/null) 2>/dev/null && echo ok" 2>/dev/null)
          if [[ "$_apid" != *"ok"* ]]; then
            _agent_stopped=$(( _agent_stopped + 1 ))
            _doc_warn "Fleet agent stopped: ${_am}"
          else
            _agent_ok=$(( _agent_ok + 1 ))
          fi
        done <<< "$_fleet_machines"

        if (( _agent_total > 0 )); then
          if (( _agent_stopped == 0 )); then
            _doc_pass "Fleet agents: all ${_agent_ok} running"
          else
            _doc_warn "Fleet agents: ${_agent_stopped}/${_agent_total} stopped"
          fi
        fi
      fi
    fi

    if [[ "$_has_checks" == "false" ]]; then
      _doc_pass "No remote connections configured"
    fi

    # App file integrity
    if [[ -f "${MUSTER_ROOT}/.muster.manifest" ]]; then
      source "$MUSTER_ROOT/lib/core/payload_sign.sh"
      source "$MUSTER_ROOT/lib/core/app_verify.sh"
      if _app_verify_full >/dev/null 2>&1; then
        _doc_pass "App integrity: all files verified"
      else
        _doc_warn "App integrity: files modified"
        _doc_detail "Run 'muster verify' for details"
        if [[ "$fix" == "true" ]]; then
          _app_manifest_generate
          _doc_detail "Manifest regenerated (re-sign with 'make manifest-sign')"
        fi
      fi
    else
      _doc_pass "App integrity: no manifest (development install)"
    fi
  }

  _doc_run_category "Connectivity" "Checking connectivity..." _doc_cat_connectivity

  # ════════════════════════════════════════════════
  # Category 5: Health & Runtime
  # ════════════════════════════════════════════════
  _doc_cat_health() {
    local _checked=0

    while IFS= read -r _svc; do
      [[ -z "$_svc" ]] && continue
      local _he
      _he=$(config_get ".services.${_svc}.health.enabled" 2>/dev/null)
      [[ "$_he" == "false" ]] && continue

      local _ht _hp _hep _hto _name
      _ht=$(config_get ".services.${_svc}.health.type" 2>/dev/null)
      _hp=$(config_get ".services.${_svc}.health.port" 2>/dev/null)
      _hep=$(config_get ".services.${_svc}.health.endpoint" 2>/dev/null)
      _hto=$(config_get ".services.${_svc}.health.timeout" 2>/dev/null)
      _name=$(config_get ".services.${_svc}.name" 2>/dev/null)
      [[ -z "$_name" || "$_name" == "null" ]] && _name="$_svc"
      [[ -z "$_hto" || "$_hto" == "null" ]] && _hto="10"

      # Timeout validation
      case "$_hto" in
        *[!0-9]*) ;;
        *)
          if (( _hto < 2 )); then
            _doc_warn "${_name}: health timeout very low (${_hto}s)"
          elif (( _hto > 60 )); then
            _doc_warn "${_name}: health timeout very high (${_hto}s)"
          fi
          ;;
      esac

      # Health script exists
      local _health_hook="${hooks_dir}/${_svc}/health.sh"
      if [[ ! -x "$_health_hook" ]]; then
        _doc_warn "${_name}: health script missing or not executable"
        continue
      fi

      _checked=$(( _checked + 1 ))

      # Try running actual health check (3s timeout to avoid blocking)
      case "$_ht" in
        http)
          if [[ -n "$_hp" && "$_hp" != "null" ]]; then
            local _url="http://localhost:${_hp}${_hep:-/}"
            if has_cmd curl; then
              if curl -sf -o /dev/null --max-time 3 "$_url" 2>/dev/null; then
                _doc_pass "${_name}: HTTP health OK (${_url})"
              else
                _doc_warn "${_name}: HTTP health unreachable (${_url})"
              fi
            else
              _doc_pass "${_name}: HTTP health configured (port ${_hp})"
            fi
          fi
          ;;
        tcp)
          if [[ -n "$_hp" && "$_hp" != "null" ]]; then
            if (echo >/dev/tcp/localhost/"$_hp") 2>/dev/null; then
              _doc_pass "${_name}: TCP port ${_hp} open"
            else
              _doc_warn "${_name}: TCP port ${_hp} not responding"
            fi
          fi
          ;;
        command)
          if "$_health_hook" &>/dev/null; then
            _doc_pass "${_name}: health command OK"
          else
            _doc_warn "${_name}: health command failed"
          fi
          ;;
        *)
          if [[ -n "$_ht" && "$_ht" != "null" ]]; then
            _doc_pass "${_name}: health check configured (${_ht})"
          fi
          ;;
      esac
    done <<< "$services"

    if (( _checked == 0 )); then
      _doc_pass "No active health checks to validate"
    fi
  }

  _doc_run_category "Health & Runtime" "Checking health endpoints..." _doc_cat_health

  # ════════════════════════════════════════════════
  # Category 6: Storage & Maintenance
  # ════════════════════════════════════════════════
  _doc_cat_storage() {
    # Logs directory
    local _log_dir="${project_dir}/.muster/logs"
    if [[ -d "$_log_dir" ]]; then
      if [[ -w "$_log_dir" ]]; then
        _doc_pass ".muster/logs/ exists and writable"
      else
        _doc_fail ".muster/logs/ not writable"
      fi
    else
      _doc_warn ".muster/logs/ directory missing"
    fi

    # Stale PID files
    local _pids_dir="${project_dir}/.muster/pids"
    if [[ -d "$_pids_dir" ]]; then
      local _stale_pids=0 _removed_pids=0
      for _pid_file in "$_pids_dir"/*.pid; do
        [[ -f "$_pid_file" ]] || continue
        local _stored_pid
        _stored_pid=$(cat "$_pid_file" 2>/dev/null)
        if [[ -n "$_stored_pid" ]] && ! kill -0 "$_stored_pid" 2>/dev/null; then
          if [[ "$fix" == "true" ]]; then
            rm -f "$_pid_file"
            _removed_pids=$(( _removed_pids + 1 ))
          else
            _stale_pids=$(( _stale_pids + 1 ))
          fi
        fi
      done
      if (( _removed_pids > 0 )); then
        _doc_pass "Removed ${_removed_pids} stale PID files"
      elif (( _stale_pids > 0 )); then
        _doc_warn "${_stale_pids} stale PID files (--fix to remove)"
      else
        _doc_pass "No stale PID files"
      fi
    else
      _doc_pass "No stale PID files"
    fi

    # Old log retention
    local _retention
    _retention=$(global_config_get "log_retention_days" 2>/dev/null)
    case "$_retention" in ''|*[!0-9]*) _retention=7 ;; esac

    if [[ -d "$_log_dir" ]]; then
      local _old_logs _find_tmp="/tmp/.muster_find_$$"
      ( find "$_log_dir" -name "*.log" -mtime +"$_retention" 2>/dev/null | wc -l | tr -d ' ' > "$_find_tmp" ) &
      local _fp=$!
      ( sleep 10 && kill "$_fp" 2>/dev/null ) &
      local _fkp=$!
      wait "$_fp" 2>/dev/null || true
      kill "$_fkp" 2>/dev/null; wait "$_fkp" 2>/dev/null || true
      _old_logs=$(cat "$_find_tmp" 2>/dev/null)
      rm -f "$_find_tmp"
      case "$_old_logs" in ''|*[!0-9]*) _old_logs=0 ;; esac
      if (( _old_logs > 0 )); then
        if [[ "$fix" == "true" ]]; then
          find "$_log_dir" -name "*.log" -mtime +"$_retention" -delete 2>/dev/null
          _doc_pass "Removed ${_old_logs} old log files (>${_retention} days)"
        else
          _doc_warn "${_old_logs} log files older than ${_retention} days (--fix)"
        fi
      else
        _doc_pass "No old log files"
      fi
    fi

    # Build context overlaps
    _build_context_detect

    if (( ${#_BUILD_CONTEXT_ISSUES[@]} > 0 )); then
      local _bc_count=${#_BUILD_CONTEXT_ISSUES[@]}
      _doc_warn "Build context overlap (${_bc_count} issue$( (( _bc_count > 1 )) && echo s))"

      if [[ "$_json_mode" == "false" && "$MUSTER_MINIMAL" != "true" ]]; then
        local _bi=0
        while (( _bi < _bc_count )); do
          local _bline="${_BUILD_CONTEXT_ISSUES[$_bi]}"
          local _bparent _bchild _bctx _bdir
          IFS='|' read -r _bparent _bchild _bctx _bdir <<< "$_bline"
          _doc_detail "${_bparent} (${_bctx}) contains ${_bchild} (${_bdir}/)"
          _doc_detail "→ Fix: add '${_bdir}' to .dockerignore"
          _bi=$(( _bi + 1 ))
        done
      fi

      if [[ "$fix" == "true" ]]; then
        local _di_file="${project_dir}/.dockerignore"
        local _fixed_count=0
        local _bi=0
        while (( _bi < _bc_count )); do
          local _bline="${_BUILD_CONTEXT_ISSUES[$_bi]}"
          local _bparent _bchild _bctx _bdir
          IFS='|' read -r _bparent _bchild _bctx _bdir <<< "$_bline"
          if ! _build_context_in_dockerignore "$project_dir" "$_bdir"; then
            printf '%s\n' "$_bdir" >> "$_di_file"
            _fixed_count=$(( _fixed_count + 1 ))
          fi
          _bi=$(( _bi + 1 ))
        done
        if (( _fixed_count > 0 )); then
          _doc_pass "Added ${_fixed_count} to .dockerignore"
        fi
      fi
    else
      _doc_pass "No build context overlaps"
    fi

    # Disk space on project directory (timeout to avoid NFS hangs)
    local _avail_kb=0
    if has_cmd df; then
      local _df_tmp="/tmp/.muster_df_$$"
      ( df -k "$project_dir" 2>/dev/null | tail -1 | awk '{print $4}' > "$_df_tmp" ) &
      local _dp=$!
      ( sleep 5 && kill "$_dp" 2>/dev/null ) &
      local _kp=$!
      wait "$_dp" 2>/dev/null || true
      kill "$_kp" 2>/dev/null; wait "$_kp" 2>/dev/null || true
      _avail_kb=$(cat "$_df_tmp" 2>/dev/null)
      rm -f "$_df_tmp"
      case "$_avail_kb" in ''|*[!0-9]*) _avail_kb=0 ;; esac
      if (( _avail_kb > 0 )); then
        local _avail_mb=$(( _avail_kb / 1024 ))
        if (( _avail_mb < 100 )); then
          _doc_warn "Low disk space: ${_avail_mb}MB available"
        elif (( _avail_mb < 500 )); then
          _doc_pass "Disk space: ${_avail_mb}MB available"
        else
          local _avail_gb=$(( _avail_mb / 1024 ))
          if (( _avail_gb > 0 )); then
            _doc_pass "Disk space: ${_avail_gb}GB available"
          else
            _doc_pass "Disk space: ${_avail_mb}MB available"
          fi
        fi
      fi
    fi

    # .muster/ directory writable
    local _muster_dir="${project_dir}/.muster"
    if [[ -d "$_muster_dir" ]]; then
      if [[ -w "$_muster_dir" ]]; then
        _doc_pass ".muster/ directory writable"
      else
        _doc_fail ".muster/ directory not writable"
      fi
    fi
  }

  _doc_run_category "Storage & Maintenance" "Checking storage & maintenance..." _doc_cat_storage

  # ════════════════════════════════════════════════
  # Summary
  # ════════════════════════════════════════════════
  local _p _w _f
  read _p _w _f < "$_DOC_COUNTS"

  if [[ "$_json_mode" == "true" ]]; then
    local _json_checks_str
    _json_checks_str=$(cat "$_JSON_FILE")
    printf '{"pass":%d,"warnings":%d,"failures":%d,"checks":[%s]}\n' \
      "$_p" "$_w" "$_f" "$_json_checks_str"
  elif [[ "$MUSTER_MINIMAL" == "true" ]]; then
    printf '%d passed, %d warnings, %d failures\n' "$_p" "$_w" "$_f"
  else
    local _rule_w=$(( TERM_COLS - 4 ))
    (( _rule_w > 50 )) && _rule_w=50
    (( _rule_w < 10 )) && _rule_w=10
    local _rule
    printf -v _rule '%*s' "$_rule_w" ""
    _rule="${_rule// /─}"
    printf '  %b%s%b\n' "${GRAY}" "$_rule" "${RESET}"
    echo ""

    local _summary="  ${_p} passed"
    if (( _w > 0 )); then
      _summary="${_summary}, ${YELLOW}${_w} warning$( (( _w > 1 )) && echo s)${RESET}"
    fi
    if (( _f > 0 )); then
      _summary="${_summary}, ${RED}${_f} failure$( (( _f > 1 )) && echo s)${RESET}"
    fi
    printf '%b\n' "$_summary"

    if (( _f > 0 || _w > 0 )); then
      if [[ "$fix" == "false" ]]; then
        printf '%b\n' "  ${DIM}Run 'muster doctor --fix' to auto-repair${RESET}"
      fi
    fi
    echo ""
  fi

  # Cleanup temp files
  rm -f "$_DOC_COUNTS" "$_JSON_FILE" 2>/dev/null
}
