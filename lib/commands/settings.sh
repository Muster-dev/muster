#!/usr/bin/env bash
# muster/lib/commands/settings.sh — Interactive project settings

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"

source "$MUSTER_ROOT/lib/commands/settings_tui.sh"

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
    tui_mode|color_mode|log_color_mode|log_retention_days|default_stack|default_health_timeout|scanner_exclude|update_check) ;;
    *)
      err "Unknown global setting: ${key}"
      echo "  Valid keys: tui_mode, color_mode, log_color_mode, log_retention_days, default_stack,"
      echo "              default_health_timeout, scanner_exclude, update_check"
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
  esac

  ok "${key} = ${value}"
  return 0
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
      echo "  muster settings                          Interactive editor"
      echo "  muster settings --global                 Dump all global settings"
      echo "  muster settings --global color_mode      Get a setting"
      echo "  muster settings --global color_mode never  Set a setting"
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
      menu_select "Settings" "Project Settings" "Muster Settings" "Back"
    else
      menu_select "Settings" "Muster Settings" "Back"
    fi

    case "$MENU_RESULT" in
      "Project Settings")
        _settings_project
        ;;
      "Muster Settings")
        _settings_muster_global
        ;;
      Back)
        return 0
        ;;
    esac
  done
}
