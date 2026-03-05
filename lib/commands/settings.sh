#!/usr/bin/env bash
# muster/lib/commands/settings.sh — Interactive project settings

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"

source "$MUSTER_ROOT/lib/commands/settings_tui.sh"
source "$MUSTER_ROOT/lib/commands/group.sh"
source "$MUSTER_ROOT/lib/commands/projects.sh"

# Toggle selector and TUI widgets loaded from lib/commands/settings_tui.sh


_settings_open_config() {
  local config_dir
  config_dir="$(dirname "$CONFIG_FILE")"

  echo ""

  # Try to open in system file manager / reveal in GUI
  if [[ "$MUSTER_OS" == "macos" ]]; then
    # macOS: open Finder to the folder, highlighting deploy.json
    open -R "$CONFIG_FILE" 2>/dev/null && {
      ok "Opened in Finder"
      printf '%b\n' "  ${DIM}${CONFIG_FILE}${RESET}"
      echo ""
      return 0
    }
  elif [[ "$MUSTER_OS" == "linux" ]]; then
    # Linux: try xdg-open on the directory
    if has_cmd xdg-open; then
      xdg-open "$config_dir" 2>/dev/null &
      ok "Opened file manager"
      printf '%b\n' "  ${DIM}${CONFIG_FILE}${RESET}"
      echo ""
      return 0
    fi
  fi

  # No GUI or open failed — just print the path
  info "Config file:"
  echo ""
  printf '%b\n' "  ${WHITE}${CONFIG_FILE}${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
  IFS= read -rsn1 || true
}

# ── Non-interactive global settings ──

_settings_global_cli() {
  local key="$1"
  shift

  # No key: dump all global settings
  if [[ -z "$key" ]]; then
    global_config_dump
    return 0
  fi

  # Validate key
  case "$key" in
    tui_mode|color_mode|log_color_mode|log_retention_days|default_stack|default_health_timeout|scanner_exclude|update_check|update_mode|minimal|machine_role|deploy_password|signing|service_lock_timeout|deploy_name) ;;
    *)
      err "Unknown global setting: ${key}"
      echo "  Valid keys: tui_mode, color_mode, log_color_mode, log_retention_days, default_stack,"
      echo "              default_health_timeout, scanner_exclude, update_check, update_mode, minimal,"
      echo "              machine_role, deploy_password, signing, service_lock_timeout, deploy_name"
      return 1
      ;;
  esac

  # scanner_exclude has sub-commands: add/remove
  if [[ "$key" == "scanner_exclude" ]]; then
    local action="${1:-}"
    shift 2>/dev/null || true
    case "$action" in
      add)
        local patterns="$*"
        if [[ -z "$patterns" ]]; then
          err "Usage: muster settings --global scanner_exclude add <patterns>"
          return 1
        fi
        # Split on comma and add each
        local IFS=','
        local p
        for p in $patterns; do
          # Trim whitespace
          p=$(printf '%s' "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          [[ -z "$p" ]] && continue
          local quoted
          quoted=$(printf '%s' "$p" | sed 's/\\/\\\\/g;s/"/\\"/g')
          global_config_set "scanner_exclude" "(.scanner_exclude + [\"${quoted}\"] | unique)"
        done
        ok "Updated scanner_exclude"
        global_config_get "scanner_exclude"
        return 0
        ;;
      remove)
        local patterns="$*"
        if [[ -z "$patterns" ]]; then
          err "Usage: muster settings --global scanner_exclude remove <patterns>"
          return 1
        fi
        local IFS=','
        local p
        for p in $patterns; do
          p=$(printf '%s' "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          [[ -z "$p" ]] && continue
          local quoted
          quoted=$(printf '%s' "$p" | sed 's/\\/\\\\/g;s/"/\\"/g')
          global_config_set "scanner_exclude" "([.scanner_exclude[] | select(. != \"${quoted}\")])"
        done
        ok "Updated scanner_exclude"
        global_config_get "scanner_exclude"
        return 0
        ;;
      *)
        # Just print current value
        global_config_get "scanner_exclude"
        return 0
        ;;
    esac
  fi

  local value="${1:-}"

  # No value: print current
  if [[ -z "$value" ]]; then
    global_config_get "$key"
    return 0
  fi

  # Validate and set
  case "$key" in
    tui_mode)
      case "$value" in
        go|bash) ;;
        *) err "tui_mode must be go or bash"; return 1 ;;
      esac
      global_config_set "$key" "\"$value\""
      ;;
    color_mode)
      case "$value" in
        auto|always|never) ;;
        *) err "color_mode must be auto, always, or never"; return 1 ;;
      esac
      global_config_set "$key" "\"$value\""
      ;;
    log_color_mode)
      case "$value" in
        auto|raw|none) ;;
        *) err "log_color_mode must be auto, raw, or none"; return 1 ;;
      esac
      global_config_set "$key" "\"$value\""
      ;;
    log_retention_days|default_health_timeout)
      case "$value" in
        *[!0-9]*) err "${key} must be a number"; return 1 ;;
      esac
      global_config_set "$key" "$value"
      ;;
    service_lock_timeout)
      case "$value" in
        *[!0-9]*) err "service_lock_timeout must be a positive integer"; return 1 ;;
      esac
      if (( value < 60 )); then
        err "service_lock_timeout minimum is 60 (1 minute)"
        return 1
      fi
      if (( value > 86400 )); then
        err "service_lock_timeout maximum is 86400 (24 hours)"
        return 1
      fi
      global_config_set "$key" "$value"
      ;;
    default_stack)
      case "$value" in
        bare|docker|compose|k8s) ;;
        *) err "default_stack must be bare, docker, compose, or k8s"; return 1 ;;
      esac
      global_config_set "$key" "\"$value\""
      ;;
    update_check)
      case "$value" in
        on|off) ;;
        *) err "update_check must be on or off"; return 1 ;;
      esac
      global_config_set "$key" "\"$value\""
      ;;
    update_mode)
      case "$value" in
        release|source) ;;
        *) err "update_mode must be release or source"; return 1 ;;
      esac
      if [[ "$value" == "source" ]]; then
        echo ""
        warn "Source mode tracks the development branch (main)"
        printf '  %b- Updates are frequent and may include untested changes%b\n' "${DIM}" "${RESET}"
        printf '  %b- Not recommended for production environments%b\n' "${DIM}" "${RESET}"
        printf '  %b- Can cause breaking changes without notice%b\n' "${DIM}" "${RESET}"
        printf '  %b- Version numbers will be ahead of official releases%b\n' "${DIM}" "${RESET}"
        printf '  %b- Switching back to release may require waiting for releases to catch up%b\n' "${DIM}" "${RESET}"
        echo ""
        printf '  %bSwitch to source mode? [y/N]%b ' "${YELLOW}" "${RESET}"
        local _src_confirm=""
        IFS= read -rsn1 _src_confirm || true
        echo ""
        case "$_src_confirm" in
          y|Y) ;;
          *)
            info "Staying on release channel"
            return 0
            ;;
        esac
      fi
      global_config_set "$key" "\"$value\""
      ;;
    minimal)
      case "$value" in
        true|false) ;;
        *) err "minimal must be true or false"; return 1 ;;
      esac
      global_config_set "$key" "$value"
      ;;
    machine_role)
      case "$value" in
        local|control|target|both|"") ;;
        *) err "machine_role must be local, control, target, or both"; return 1 ;;
      esac
      global_config_set "$key" "\"$value\""
      ;;
    deploy_password)
      if [[ "$value" == "off" || "$value" == "false" || "$value" == "" ]]; then
        global_config_set "deploy_password_hash" '""'
        ok "Deploy password removed"
        return 0
      fi
      source "$MUSTER_ROOT/lib/core/auth.sh"
      local _dp_hash
      _dp_hash="sha256:$(_auth_hash "$value")"
      global_config_set "deploy_password_hash" "\"${_dp_hash}\""
      ok "Deploy password set"
      return 0
      ;;
    signing)
      case "$value" in
        on|off) ;;
        *) err "signing must be on or off"; return 1 ;;
      esac
      global_config_set "$key" "\"$value\""
      ;;
    deploy_name)
      # Validate: no quotes or special shell chars
      case "$value" in
        *[\'\"\\$\`\;]*)
          err "deploy_name must not contain quotes or special shell characters"
          return 1
          ;;
      esac
      global_config_set "$key" "\"$value\""
      ;;
  esac

  ok "${key} = ${value}"
  return 0
}

# ── Hook Security settings ──

_settings_hook_security() {
  source "$MUSTER_ROOT/lib/core/hook_security.sh"

  while true; do
    clear
    echo ""
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Hook Security${RESET}"
    echo ""

    # Show current setting
    local _sec_val
    _sec_val=$(global_config_get "hook_security" 2>/dev/null || true)
    [[ -z "$_sec_val" || "$_sec_val" == "null" ]] && _sec_val="on"
    printf '  %bStatus:%b %s\n' "${DIM}" "${RESET}" "$_sec_val"

    # Show manifest signature status if in a project
    if find_config &>/dev/null; then
      load_config
      local _pd0
      _pd0="$(dirname "$CONFIG_FILE")"
      local _mf0="${_pd0}/.muster/hooks.manifest"
      if [[ -f "$_mf0" ]]; then
        _hook_manifest_verify_sig "$_mf0"
        case $? in
          0) printf '  %bManifest:%b %b✓%b signed\n' "${DIM}" "${RESET}" "${GREEN}" "${RESET}" ;;
          1) printf '  %bManifest:%b %b✗%b signature invalid\n' "${DIM}" "${RESET}" "${RED}" "${RESET}" ;;
          2) printf '  %bManifest:%b %b?%b not signed\n' "${DIM}" "${RESET}" "${YELLOW}" "${RESET}" ;;
        esac
      fi
    fi
    echo ""

    # Show hook table if in a project
    if find_config &>/dev/null; then
      load_config
      local _pd
      _pd="$(dirname "$CONFIG_FILE")"
      local _hd="${_pd}/.muster/hooks"

      if [[ -d "$_hd" ]]; then
        printf '  %b%-20s %-10s %-10s %-20s%b\n' "${DIM}" "HOOK" "INTEGRITY" "PERMS" "MODIFIED" "${RESET}"

        local _sd
        for _sd in "${_hd}"/*/; do
          [[ ! -d "$_sd" ]] && continue
          local _svc
          _svc=$(basename "$_sd")
          [[ "$_svc" == "logs" || "$_svc" == "pids" ]] && continue

          local _hf
          for _hf in "${_sd}"*.sh; do
            [[ ! -f "$_hf" ]] && continue
            local _hn
            _hn=$(basename "$_hf")
            local _key="${_svc}/${_hn}"

            # Integrity
            local _int_icon
            _hook_manifest_verify "$_hf" "$_pd"
            case $? in
              0) _int_icon="${GREEN}✓${RESET}" ;;
              1) _int_icon="${RED}✗${RESET}" ;;
              2) _int_icon="${YELLOW}?${RESET}" ;;
            esac

            # Permissions
            local _perms
            _perms=$(stat -f '%Sp' "$_hf" 2>/dev/null || stat -c '%A' "$_hf" 2>/dev/null || echo "?")

            # Modified
            local _mod
            _mod=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$_hf" 2>/dev/null || stat -c '%y' "$_hf" 2>/dev/null | cut -d. -f1 || echo "?")

            printf '  %-20s %b  %-10s %-20s\n' "$_key" "$_int_icon" "$_perms" "$_mod"
          done
        done
        echo ""
      fi
    fi

    local _actions=()
    _actions[${#_actions[@]}]="Verify all hooks"
    _actions[${#_actions[@]}]="Approve all hooks"
    _actions[${#_actions[@]}]="Lock all hooks"
    _actions[${#_actions[@]}]="Unlock all hooks"
    if [[ "$_sec_val" == "on" ]]; then
      _actions[${#_actions[@]}]="Disable hook security"
    else
      _actions[${#_actions[@]}]="Enable hook security"
    fi
    _actions[${#_actions[@]}]="Back"

    menu_select "Hook Security" "${_actions[@]}"

    case "$MENU_RESULT" in
      "Verify all hooks")
        if find_config &>/dev/null; then
          load_config
          local _pd2
          _pd2="$(dirname "$CONFIG_FILE")"
          echo ""
          _hook_manifest_verify_all "$_pd2"
          echo ""
          printf '  %bPress any key to continue...%b' "${DIM}" "${RESET}"
          IFS= read -rsn1 || true
        else
          warn "No project found"
        fi
        ;;
      "Approve all hooks")
        if find_config &>/dev/null; then
          load_config
          local _pd3
          _pd3="$(dirname "$CONFIG_FILE")"
          # Require sudo for approve
          if ! sudo -v 2>/dev/null; then
            err "Authentication required to approve hooks"
            printf '  %bPress any key to continue...%b' "${DIM}" "${RESET}"
            IFS= read -rsn1 || true
            continue
          fi
          _hook_manifest_approve "$_pd3"
          ok "All hooks approved"
          printf '  %bPress any key to continue...%b' "${DIM}" "${RESET}"
          IFS= read -rsn1 || true
        fi
        ;;
      "Lock all hooks")
        if find_config &>/dev/null; then
          load_config
          local _pd4
          _pd4="$(dirname "$CONFIG_FILE")"
          local _hd4="${_pd4}/.muster/hooks"
          local _sd4
          for _sd4 in "${_hd4}"/*/; do
            [[ ! -d "$_sd4" ]] && continue
            local _s4
            _s4=$(basename "$_sd4")
            [[ "$_s4" == "logs" || "$_s4" == "pids" ]] && continue
            _hook_lock "$_sd4"
          done
          ok "All hooks locked"
          printf '  %bPress any key to continue...%b' "${DIM}" "${RESET}"
          IFS= read -rsn1 || true
        fi
        ;;
      "Unlock all hooks")
        if find_config &>/dev/null; then
          load_config
          local _pd5
          _pd5="$(dirname "$CONFIG_FILE")"
          # Require sudo for unlock
          if ! sudo -v 2>/dev/null; then
            err "Authentication required to unlock hooks"
            printf '  %bPress any key to continue...%b' "${DIM}" "${RESET}"
            IFS= read -rsn1 || true
            continue
          fi
          local _hd5="${_pd5}/.muster/hooks"
          local _sd5
          for _sd5 in "${_hd5}"/*/; do
            [[ ! -d "$_sd5" ]] && continue
            local _s5
            _s5=$(basename "$_sd5")
            [[ "$_s5" == "logs" || "$_s5" == "pids" ]] && continue
            _hook_unlock "$_sd5"
          done
          ok "All hooks unlocked"
          printf '  %bPress any key to continue...%b' "${DIM}" "${RESET}"
          IFS= read -rsn1 || true
        fi
        ;;
      "Enable hook security")
        global_config_set "hook_security" '"on"'
        ok "Hook security enabled"
        ;;
      "Disable hook security")
        # Require sudo to disable
        if ! sudo -v 2>/dev/null; then
          err "Authentication required to disable hook security"
          printf '  %bPress any key to continue...%b' "${DIM}" "${RESET}"
          IFS= read -rsn1 || true
          continue
        fi
        global_config_set "hook_security" '"off"'
        warn "Hook security disabled"
        ;;
      Back|__back__)
        return 0
        ;;
    esac
  done
}

# ── Interactive global settings ──


cmd_settings() {
  # Handle --help flag
  case "${1:-}" in
    --help|-h)
      echo "Usage: muster settings [flags]"
      echo ""
      echo "Interactive project and global settings editor."
      echo ""
      echo "Flags:"
      echo "  --global [key] [value]    View or set global settings"
      echo "  -h, --help                Show this help"
      echo ""
      echo "Examples:"
      echo "  muster settings                              Interactive editor"
      echo "  muster settings --global                     Dump all global settings"
      echo "  muster settings --global color_mode          Get a setting"
      echo "  muster settings --global color_mode never    Set a setting"
      echo "  muster settings --global minimal true        Always use plain text mode"
      return 0
      ;;
  esac

  # Handle --global flag for non-interactive use
  if [[ "${1:-}" == "--global" ]]; then
    shift
    _settings_global_cli "$@"
    return $?
  fi

  # Reject unknown flags
  if [[ "${1:-}" == --* ]]; then
    err "Unknown flag: $1"
    echo "Run 'muster settings --help' for usage."
    return 1
  fi

  # Check if we're inside a project
  local _has_project=false
  if find_config &>/dev/null; then
    load_config
    _has_project=true
  fi

  while true; do
    clear
    echo ""
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Settings${RESET}"
    echo ""

    if [[ "$_has_project" == "true" ]]; then
      menu_select "Settings" "Project Settings" "Muster Settings" "Scanner Exclude" "Deploy Password" "Updates" "Hook Security" "Auth Tokens" "Fleet Groups" "Fleet Trust" "Projects" "Back"
    else
      menu_select "Settings" "Muster Settings" "Scanner Exclude" "Deploy Password" "Updates" "Hook Security" "Auth Tokens" "Fleet Groups" "Fleet Trust" "Projects" "Back"
    fi

    case "$MENU_RESULT" in
      "Project Settings")
        _settings_project
        ;;
      "Muster Settings")
        _settings_muster_global
        ;;
      "Scanner Exclude")
        _settings_scanner_exclude
        ;;
      "Deploy Password")
        _settings_deploy_password
        ;;
      "Updates")
        _settings_updates
        ;;
      "Hook Security")
        _settings_hook_security
        ;;
      "Auth Tokens")
        source "$MUSTER_ROOT/lib/core/auth.sh"
        source "$MUSTER_ROOT/lib/commands/auth.sh"
        _auth_cmd_manager
        ;;
      "Fleet Groups")
        _group_cmd_manager
        ;;
      "Fleet Trust")
        source "$MUSTER_ROOT/lib/core/trust.sh"
        source "$MUSTER_ROOT/lib/commands/trust.sh"
        _trust_cmd_manager
        ;;
      "Projects")
        _projects_manage
        ;;
      Back|__back__)
        return 0
        ;;
    esac
  done
}
