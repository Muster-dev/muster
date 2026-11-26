#!/usr/bin/env bash
# muster/lib/commands/hooks.sh — List and inspect hook scripts

cmd_hooks() {
  local _json_mode=false
  local _service=""
  local _hook=""

  # Route security subcommands first
  case "${1:-}" in
    verify)   shift; _hooks_cmd_verify "$@"; return $? ;;
    approve)
      shift
      # --yes / --json: non-interactive approval (lib/commands/hooks_api.sh)
      case " $* " in
        *" --yes "*|*" -y "*|*" --json "*)
          source "$MUSTER_ROOT/lib/commands/hooks_api.sh"
          _hooks_cmd_approve_api "$@"; return $? ;;
      esac
      _hooks_cmd_approve "$@"; return $? ;;
    status)   shift; source "$MUSTER_ROOT/lib/commands/hooks_api.sh"; _hooks_cmd_status "$@"; return $? ;;
    lock)     shift; _hooks_cmd_lock "$@"; return $? ;;
    unlock)   shift; _hooks_cmd_unlock "$@"; return $? ;;
  esac

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: muster hooks [command] [service] [hook] [flags]"
        echo ""
        echo "List and inspect hook scripts for your services."
        echo ""
        echo "Commands:"
        echo "  verify [service]    Check hooks against integrity manifest"
        echo "  approve [service]   Re-sign hooks after intentional edits"
        echo "  approve --yes [service...] [--json]"
        echo "                      Approve without a prompt (frontends, CI)"
        echo "  status [--json]     Approval state of every hook, muster.json and .env"
        echo "  lock [service]      Opt-in: set hooks read-only (chmod 555)"
        echo "  unlock [service]    Allow editing (chmod 755)"
        echo ""
        echo "Examples:"
        echo "  muster hooks              List all services and their hooks"
        echo "  muster hooks api          Show hooks for a service"
        echo "  muster hooks api deploy   Print the deploy hook script"
        echo "  muster hooks verify       Check all hooks for tampering"
        echo "  muster hooks approve api  Re-sign after editing api hooks"
        echo "  muster hooks --json       JSON output of all hooks info"
        echo ""
        echo "Flags:"
        echo "  --json          Output as JSON"
        echo "  -h, --help      Show this help"
        return 0
        ;;
      --json) _json_mode=true; shift ;;
      -*)
        err "Unknown flag: $1"
        echo "Run 'muster hooks --help' for usage."
        return 1
        ;;
      *)
        if [[ -z "$_service" ]]; then
          _service="$1"
        elif [[ -z "$_hook" ]]; then
          _hook="$1"
        else
          err "Too many arguments"
          echo "Run 'muster hooks --help' for usage."
          return 1
        fi
        shift
        ;;
    esac
  done

  # Auth gate: JSON mode requires valid token
  if [[ "$_json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
  fi

  # Load config
  if ! find_config &>/dev/null; then
    err "No muster project found. Run 'muster setup' first."
    return 1
  fi
  load_config

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local hooks_dir="${project_dir}/.muster/hooks"
  local _hook_names="deploy health rollback logs cleanup"

  # Get services list
  local services
  services=$(config_services)

  # Validate service argument
  if [[ -n "$_service" ]]; then
    local _found=false
    while IFS= read -r _s; do
      [[ -z "$_s" ]] && continue
      [[ "$_s" == "$_service" ]] && _found=true
    done <<< "$services"
    if [[ "$_found" == "false" ]]; then
      err "Unknown service: $_service"
      echo "Run 'muster hooks' to see available services."
      return 1
    fi
  fi

  # Validate hook argument
  if [[ -n "$_hook" ]]; then
    # Strip .sh suffix if provided
    _hook="${_hook%.sh}"
    local _valid_hook=false
    for _h in $_hook_names; do
      [[ "$_h" == "$_hook" ]] && _valid_hook=true
    done
    if [[ "$_valid_hook" == "false" ]]; then
      err "Unknown hook: $_hook"
      echo "Valid hooks: ${_hook_names}"
      return 1
    fi
  fi

  # ── Mode 1: Inspect a specific hook script ──
  if [[ -n "$_service" && -n "$_hook" ]]; then
    _hooks_inspect "$hooks_dir" "$_service" "$_hook" "$_json_mode"
    return $?
  fi

  # ── Mode 2: Show hooks for a specific service ──
  if [[ -n "$_service" ]]; then
    _hooks_service_detail "$hooks_dir" "$_service" "$_hook_names" "$_json_mode"
    return $?
  fi

  # ── Mode 3: List all services and hooks ──
  _hooks_list "$hooks_dir" "$services" "$_hook_names" "$_json_mode"
}

# ── Inspect a single hook script ──
_hooks_inspect() {
  local hooks_dir="$1" svc="$2" hook="$3" json_mode="$4"
  local hook_path="${hooks_dir}/${svc}/${hook}.sh"

  if [[ ! -f "$hook_path" ]]; then
    if [[ "$json_mode" == "true" ]]; then
      printf '{"service":"%s","hook":"%s","exists":false}\n' "$svc" "$hook"
    else
      err "${svc}/${hook}.sh does not exist"
    fi
    return 1
  fi

  local line_count
  line_count=$(wc -l < "$hook_path" | tr -d ' ')
  local _exec_str="not executable"
  [[ -x "$hook_path" ]] && _exec_str="executable"

  if [[ "$json_mode" == "true" ]]; then
    local _content
    _content=$(cat "$hook_path")
    # Escape for JSON: backslashes, quotes, tabs, then newlines
    _content="${_content//\\/\\\\}"
    _content="${_content//\"/\\\"}"
    _content="${_content//$'\t'/\\t}"
    _content=$(printf '%s' "$_content" | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//')
    printf '{"service":"%s","hook":"%s","exists":true,"executable":%s,"lines":%d,"path":"%s","content":"%s"}\n' \
      "$svc" "$hook" "$( [[ -x "$hook_path" ]] && echo true || echo false )" \
      "$line_count" "$hook_path" "$_content"
    return 0
  fi

  echo ""
  printf '%b\n' "  ${BOLD}${svc}/${hook}.sh${RESET} ${DIM}(${_exec_str}, ${line_count} lines)${RESET}"
  echo ""

  # Print with line numbers and syntax highlighting
  local _line_num=0
  local _gutter_w=${#line_count}
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    _line_num=$(( _line_num + 1 ))
    # Highlight comments dim
    if [[ "$_line" =~ ^[[:space:]]*#  ]]; then
      printf '%b' "  ${DIM}"
      printf '%*d' "$_gutter_w" "$_line_num"
      printf '%b' "${RESET}${GRAY}|${RESET} ${DIM}"
      printf '%s' "$_line"
      printf '%b\n' "${RESET}"
    else
      printf '%b' "  ${DIM}"
      printf '%*d' "$_gutter_w" "$_line_num"
      printf '%b' "${RESET}${GRAY}|${RESET} "
      printf '%s\n' "$_line"
    fi
  done < "$hook_path"
  echo ""
}

# ── Show detail for a single service ──
_hooks_service_detail() {
  local hooks_dir="$1" svc="$2" hook_names="$3" json_mode="$4"
  local svc_dir="${hooks_dir}/${svc}"

  if [[ "$json_mode" == "true" ]]; then
    local _first=true
    printf '{"service":"%s","hooks":[' "$svc"
    for _h in $hook_names; do
      local _hp="${svc_dir}/${_h}.sh"
      local _exists=false _exec=false _lines=0
      if [[ -f "$_hp" ]]; then
        _exists=true
        [[ -x "$_hp" ]] && _exec=true
        _lines=$(wc -l < "$_hp" | tr -d ' ')
      fi
      [[ "$_first" == "true" ]] && _first=false || printf ','
      printf '{"name":"%s","exists":%s,"executable":%s,"lines":%d}' \
        "$_h" "$_exists" "$_exec" "$_lines"
    done
    printf ']}\n'
    return 0
  fi

  echo ""
  printf '%b\n' "  ${BOLD}${svc}${RESET} ${DIM}hooks${RESET}"
  echo ""

  local _desc_deploy="Build and deploy the service"
  local _desc_health="Check if the service is healthy"
  local _desc_rollback="Revert to the previous version"
  local _desc_logs="Stream or tail service logs"
  local _desc_cleanup="Stop processes and clean up resources"

  for _h in $hook_names; do
    local _hp="${svc_dir}/${_h}.sh"
    local _desc=""
    case "$_h" in
      deploy)   _desc="$_desc_deploy" ;;
      health)   _desc="$_desc_health" ;;
      rollback) _desc="$_desc_rollback" ;;
      logs)     _desc="$_desc_logs" ;;
      cleanup)  _desc="$_desc_cleanup" ;;
    esac

    if [[ -f "$_hp" ]]; then
      local _lines
      _lines=$(wc -l < "$_hp" | tr -d ' ')

      # Integrity check
      local _integrity_icon=""
      source "$MUSTER_ROOT/lib/core/hook_security.sh"
      local _proj_dir
      _proj_dir=$(cd "${hooks_dir}/../.." 2>/dev/null && pwd)
      if _hook_trust_exists "$_proj_dir"; then
        _hook_manifest_verify "$_hp" "$_proj_dir"
        case $? in
          0) _integrity_icon=" ${GREEN}✓${RESET}" ;;
          1) _integrity_icon=" ${RED}tampered${RESET}" ;;
          2) _integrity_icon=" ${YELLOW}unsigned${RESET}" ;;
        esac
      fi

      # Permissions + last modified
      local _perms _modified
      _perms=$(stat -f '%Sp' "$_hp" 2>/dev/null || stat -c '%A' "$_hp" 2>/dev/null || echo "?")
      _modified=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$_hp" 2>/dev/null || stat -c '%y' "$_hp" 2>/dev/null | cut -d. -f1 || echo "?")

      if [[ -x "$_hp" ]]; then
        printf '%b' "  ${GREEN}✓${RESET} ${BOLD}${_h}.sh${RESET}"
      else
        printf '%b' "  ${YELLOW}!${RESET} ${BOLD}${_h}.sh${RESET}"
      fi
      printf '%b\n' "${_integrity_icon} ${DIM}(${_lines} lines)${RESET}"
      printf '%b\n' "    ${DIM}${_desc}${RESET}"
      printf '%b\n' "    ${DIM}${_perms}  modified ${_modified}${RESET}"
    else
      printf '%b\n' "  ${DIM}✗ ${_h}.sh (missing)${RESET}"
      printf '%b\n' "    ${DIM}${_desc}${RESET}"
    fi
  done

  echo ""
  printf '%b\n' "  ${DIM}View a hook: muster hooks ${svc} <hook>${RESET}"
  echo ""
}

# ── List all services and their hooks ──
_hooks_list() {
  local hooks_dir="$1" services="$2" hook_names="$3" json_mode="$4"

  local _svc_count=0
  local _hook_count=0
  local _warn_count=0

  # Build rows: "svc|status|status|status|status|status"
  local _rows=""
  while IFS= read -r _svc; do
    [[ -z "$_svc" ]] && continue
    _svc_count=$(( _svc_count + 1 ))
    local _svc_dir="${hooks_dir}/${_svc}"
    local _row="${_svc}"
    for _h in $hook_names; do
      local _hp="${_svc_dir}/${_h}.sh"
      if [[ -f "$_hp" ]]; then
        if [[ -x "$_hp" ]]; then
          _row="${_row}|present"
          _hook_count=$(( _hook_count + 1 ))
        else
          _row="${_row}|noexec"
          _hook_count=$(( _hook_count + 1 ))
          _warn_count=$(( _warn_count + 1 ))
        fi
      else
        _row="${_row}|missing"
      fi
    done
    if [[ -z "$_rows" ]]; then
      _rows="$_row"
    else
      _rows="${_rows}
${_row}"
    fi
  done <<< "$services"

  # JSON output
  if [[ "$json_mode" == "true" ]]; then
    local _first_svc=true
    printf '{"services":['
    while IFS= read -r _svc; do
      [[ -z "$_svc" ]] && continue
      [[ "$_first_svc" == "true" ]] && _first_svc=false || printf ','
      local _svc_dir="${hooks_dir}/${_svc}"
      local _first_hook=true
      printf '{"name":"%s","hooks":[' "$_svc"
      for _h in $hook_names; do
        local _hp="${_svc_dir}/${_h}.sh"
        local _exists=false _exec=false _lines=0
        if [[ -f "$_hp" ]]; then
          _exists=true
          [[ -x "$_hp" ]] && _exec=true
          _lines=$(wc -l < "$_hp" | tr -d ' ')
        fi
        [[ "$_first_hook" == "true" ]] && _first_hook=false || printf ','
        printf '{"name":"%s","exists":%s,"executable":%s,"lines":%d}' \
          "$_h" "$_exists" "$_exec" "$_lines"
      done
      printf ']}'
    done <<< "$services"
    printf '],"total_services":%d,"total_hooks":%d}\n' "$_svc_count" "$_hook_count"
    return 0
  fi

  # ── TUI table output ──
  echo ""
  printf '%b\n' "  ${BOLD}Hooks${RESET}"
  echo ""

  # Calculate max service name length for column padding
  local _max_svc_len=7  # "SERVICE" header length
  while IFS= read -r _svc; do
    [[ -z "$_svc" ]] && continue
    local _len=${#_svc}
    (( _len > _max_svc_len )) && _max_svc_len=$_len
  done <<< "$services"

  local _pad=$(( _max_svc_len + 2 ))
  local _col_w=10

  # Header row
  printf '  %b' "${DIM}"
  printf '%-*s' "$_pad" "SERVICE"
  for _h in $hook_names; do
    printf '%-*s' "$_col_w" "$_h"
  done
  printf '%b\n' "${RESET}"

  # Data rows
  while IFS= read -r _row; do
    [[ -z "$_row" ]] && continue
    local _svc="${_row%%|*}"
    local _rest="${_row#*|}"

    printf '  %-*s' "$_pad" "$_svc"

    # Parse each pipe-separated status
    while [[ -n "$_rest" ]]; do
      local _status
      if [[ "$_rest" == *"|"* ]]; then
        _status="${_rest%%|*}"
        _rest="${_rest#*|}"
      else
        _status="$_rest"
        _rest=""
      fi

      case "$_status" in
        present)
          # Print colored symbol then pad the rest with spaces
          printf '%b' "${GREEN}"
          printf '%s' "✓"
          printf '%b' "${RESET}"
          printf '%*s' "$(( _col_w - 1 ))" ""
          ;;
        noexec)
          printf '%b' "${YELLOW}"
          printf '%s' "!"
          printf '%b' "${RESET}"
          printf '%*s' "$(( _col_w - 1 ))" ""
          ;;
        missing)
          printf '%b' "${DIM}"
          printf '%s' "✗"
          printf '%b' "${RESET}"
          printf '%*s' "$(( _col_w - 1 ))" ""
          ;;
      esac
    done
    printf '\n'
  done <<< "$_rows"

  echo ""
  local _summary="  ${_svc_count} service"
  (( _svc_count != 1 )) && _summary="${_summary}s"
  _summary="${_summary}, ${_hook_count} hook"
  (( _hook_count != 1 )) && _summary="${_summary}s"
  if (( _warn_count > 0 )); then
    _summary="${_summary} ${DIM}(${_warn_count} not executable)${RESET}"
  fi
  printf '%b\n' "$_summary"
  echo ""
}

# ── Security subcommands ──

_hooks_cmd_verify() {
  if ! find_config &>/dev/null; then
    err "No muster project found. Run 'muster setup' first."
    return 1
  fi
  load_config

  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  echo ""
  printf '%b\n' "  ${BOLD}Hook Integrity Check${RESET}"
  echo ""

  if _hook_manifest_verify_all "$project_dir"; then
    echo ""
    ok "All hooks verified"
  else
    echo ""
    err "Integrity issues found"
    printf '  %bRun %bmuster hooks approve%b%b to re-sign after intentional edits%b\n' \
      "${DIM}" "${RESET}${WHITE}" "${RESET}" "${DIM}" "${RESET}"
  fi
  echo ""
}

_hooks_cmd_approve() {
  local service="${1:-}"

  if ! find_config &>/dev/null; then
    err "No muster project found. Run 'muster setup' first."
    return 1
  fi
  load_config

  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  # Require authentication to approve hooks
  if ! sudo -v 2>/dev/null; then
    err "Authentication required to approve hooks"
    return 1
  fi

  # Scan for dangerous commands before approving
  local hooks_dir="${project_dir}/.muster/hooks"
  local danger_found=false
  local svc_dir
  for svc_dir in "${hooks_dir}"/*/; do
    [[ ! -d "$svc_dir" ]] && continue
    local svc
    svc=$(basename "$svc_dir")
    [[ "$svc" == "logs" || "$svc" == "pids" ]] && continue
    [[ -n "$service" && "$svc" != "$service" ]] && continue

    local hook_file
    for hook_file in "${svc_dir}"*.sh; do
      [[ ! -f "$hook_file" ]] && continue
      if ! _hook_scan_dangerous "$hook_file"; then
        danger_found=true
      fi
    done
  done

  if [[ "$danger_found" == "true" ]]; then
    err "Cannot approve — dangerous commands found"
    printf '  %bFix the hooks first, or set MUSTER_HOOK_UNSAFE=1 to bypass%b\n' "${DIM}" "${RESET}"
    return 1
  fi

  _hook_manifest_approve "$project_dir" "$service"

  if [[ -n "$service" ]]; then
    ok "Approved: ${service}"
  else
    ok "All hooks approved"
  fi
}

_hooks_cmd_lock() {
  local service="${1:-}"

  if ! find_config &>/dev/null; then
    err "No muster project found. Run 'muster setup' first."
    return 1
  fi
  load_config

  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local hooks_dir="${project_dir}/.muster/hooks"

  if [[ -n "$service" ]]; then
    if [[ ! -d "${hooks_dir}/${service}" ]]; then
      err "Service not found: ${service}"
      return 1
    fi
    _hook_lock "${hooks_dir}/${service}"
    ok "Locked: ${service}"
  else
    local svc_dir
    for svc_dir in "${hooks_dir}"/*/; do
      [[ ! -d "$svc_dir" ]] && continue
      local svc
      svc=$(basename "$svc_dir")
      [[ "$svc" == "logs" || "$svc" == "pids" ]] && continue
      _hook_lock "$svc_dir"
    done
    ok "All hooks locked (read-only)"
  fi
}

_hooks_cmd_unlock() {
  local service="${1:-}"

  if ! find_config &>/dev/null; then
    err "No muster project found. Run 'muster setup' first."
    return 1
  fi
  load_config

  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local hooks_dir="${project_dir}/.muster/hooks"

  # Require authentication to unlock hooks
  if ! sudo -v 2>/dev/null; then
    err "Authentication required to unlock hooks"
    return 1
  fi

  if [[ -n "$service" ]]; then
    if [[ ! -d "${hooks_dir}/${service}" ]]; then
      err "Service not found: ${service}"
      return 1
    fi
    _hook_unlock "${hooks_dir}/${service}"
    ok "Unlocked: ${service}"
  else
    local svc_dir
    for svc_dir in "${hooks_dir}"/*/; do
      [[ ! -d "$svc_dir" ]] && continue
      local svc
      svc=$(basename "$svc_dir")
      [[ "$svc" == "logs" || "$svc" == "pids" ]] && continue
      _hook_unlock "$svc_dir"
    done
    ok "All hooks unlocked (editable)"
  fi
}
