#!/usr/bin/env bash
# muster/lib/commands/settings.sh — Interactive project settings

source "$MUSTER_ROOT/lib/tui/menu.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"

# Cycle menu: items cycle through options on Enter, "Back" exits
# Globals before calling:
#   _TOG_LABELS[]   — display label per item
#   _TOG_OPTIONS[]   — pipe-separated options per item (e.g. "OFF|ON" or "Off|Save|Session|Always")
#   _TOG_STATES[]    — current option index per item
# Updates _TOG_STATES[] in place
_toggle_select() {
  local title="$1"
  local count=${#_TOG_LABELS[@]}
  local selected=0

  tput civis

  local w=$(( TERM_COLS - 4 ))
  (( w > 50 )) && w=50
  (( w < 10 )) && w=10
  local inner=$(( w - 2 ))

  # Parse option counts per item
  local _tog_opt_counts=()
  local idx=0
  while (( idx < count )); do
    local opts="${_TOG_OPTIONS[$idx]}"
    local ocount=1
    local tmp="$opts"
    while [[ "$tmp" == *"|"* ]]; do
      ocount=$((ocount + 1))
      tmp="${tmp#*|}"
    done
    _tog_opt_counts[$idx]=$ocount
    idx=$((idx + 1))
  done

  # Get the Nth option from a pipe-separated string
  _tog_get_opt() {
    local opts="$1" n="$2"
    local i=0
    while (( i < n )); do
      opts="${opts#*|}"
      i=$((i + 1))
    done
    printf '%s' "${opts%%|*}"
  }

  _tog_draw_header() {
    echo ""
    echo -e "  ${BOLD}${title}${RESET}"
    echo -e "  ${DIM}↑/↓ navigate  ⏎ cycle  q back${RESET}"
    echo ""
  }

  _tog_draw() {
    local border
    border=$(printf '%*s' "$w" "" | sed 's/ /─/g')
    printf '%b' "  ${ACCENT}┌${border}┐${RESET}\n"

    local i=0
    while (( i < count )); do
      local label="${_TOG_LABELS[$i]}"
      local cur_opt
      cur_opt=$(_tog_get_opt "${_TOG_OPTIONS[$i]}" "${_TOG_STATES[$i]}")

      # Color: first option (index 0) = red/off, anything else = green/on
      local state_color="$GREEN"
      (( _TOG_STATES[i] == 0 )) && state_color="$RED"

      local prefix="  "
      (( i == selected )) && prefix="${ACCENT}>${RESET} "

      local content_len=$(( 5 + ${#label} + ${#cur_opt} ))
      local pad_len=$(( inner - content_len ))
      (( pad_len < 0 )) && pad_len=0
      local pad
      pad=$(printf '%*s' "$pad_len" "")

      printf '%b' "  ${ACCENT}│${RESET} ${prefix}${label}${pad} ${state_color}${cur_opt}${RESET}${ACCENT}│${RESET}\n"
      i=$((i + 1))
    done

    # Back row
    local back_prefix="  "
    (( selected == count )) && back_prefix="${ACCENT}>${RESET} "
    local back_pad_len=$(( inner - 3 - 4 ))
    (( back_pad_len < 0 )) && back_pad_len=0
    local back_pad
    back_pad=$(printf '%*s' "$back_pad_len" "")
    printf '%b' "  ${ACCENT}│${RESET} ${back_prefix}${DIM}Back${RESET}${back_pad}${ACCENT}│${RESET}\n"

    border=$(printf '%*s' "$w" "" | sed 's/ /─/g')
    printf '%b' "  ${ACCENT}└${border}┘${RESET}\n"
  }

  local total_lines=$(( count + 3 ))

  _tog_clear() {
    local i=0
    while (( i < total_lines )); do
      tput cuu1
      i=$((i + 1))
    done
    tput ed
  }

  _tog_read_key() {
    local key
    IFS= read -rsn1 key || true
    if [[ "$key" == $'\x1b' ]]; then
      local seq1 seq2
      IFS= read -rsn1 -t 1 seq1 || true
      IFS= read -rsn1 -t 1 seq2 || true
      key="${key}${seq1}${seq2}"
    fi
    REPLY="$key"
  }

  _tog_draw_header
  _tog_draw

  while true; do
    _tog_read_key

    if [[ "$_MUSTER_INPUT_DIRTY" == "true" ]]; then
      _MUSTER_INPUT_DIRTY="false"
      _tog_draw_header
      _tog_draw
      continue
    fi

    case "$REPLY" in
      $'\x1b[A')
        (( selected > 0 )) && selected=$((selected - 1))
        ;;
      $'\x1b[B')
        (( selected < count )) && selected=$((selected + 1))
        ;;
      'q'|'Q')
        _tog_clear
        tput cnorm
        return 0
        ;;
      '')
        if (( selected == count )); then
          _tog_clear
          tput cnorm
          return 0
        fi
        # Cycle to next option
        local next=$(( _TOG_STATES[selected] + 1 ))
        if (( next >= _tog_opt_counts[selected] )); then
          next=0
        fi
        _TOG_STATES[$selected]=$next
        ;;
      *)
        continue
        ;;
    esac

    _tog_clear
    _tog_draw
  done
}

_settings_open_config() {
  local config_dir
  config_dir="$(dirname "$CONFIG_FILE")"

  echo ""

  # Try to open in system file manager / reveal in GUI
  if [[ "$MUSTER_OS" == "macos" ]]; then
    # macOS: open Finder to the folder, highlighting deploy.json
    open -R "$CONFIG_FILE" 2>/dev/null && {
      ok "Opened in Finder"
      echo -e "  ${DIM}${CONFIG_FILE}${RESET}"
      echo ""
      return 0
    }
  elif [[ "$MUSTER_OS" == "linux" ]]; then
    # Linux: try xdg-open on the directory
    if has_cmd xdg-open; then
      xdg-open "$config_dir" 2>/dev/null &
      ok "Opened file manager"
      echo -e "  ${DIM}${CONFIG_FILE}${RESET}"
      echo ""
      return 0
    fi
  fi

  # No GUI or open failed — just print the path
  info "Config file:"
  echo ""
  echo -e "  ${WHITE}${CONFIG_FILE}${RESET}"
  echo ""
  echo -e "  ${DIM}Press any key to continue...${RESET}"
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

_settings_muster_global() {
  while true; do
    local color_mode log_color_mode log_retention default_stack health_timeout update_check scanner_ex

    color_mode=$(global_config_get "color_mode" 2>/dev/null)
    : "${color_mode:=auto}"
    log_color_mode=$(global_config_get "log_color_mode" 2>/dev/null)
    : "${log_color_mode:=auto}"
    log_retention=$(global_config_get "log_retention_days" 2>/dev/null)
    : "${log_retention:=7}"
    default_stack=$(global_config_get "default_stack" 2>/dev/null)
    : "${default_stack:=bare}"
    health_timeout=$(global_config_get "default_health_timeout" 2>/dev/null)
    : "${health_timeout:=10}"
    update_check=$(global_config_get "update_check" 2>/dev/null)
    : "${update_check:=on}"
    scanner_ex=$(global_config_get "scanner_exclude" 2>/dev/null)
    if [[ "$scanner_ex" == "[]" || -z "$scanner_ex" ]]; then
      scanner_ex="(none)"
    fi

    local tui_mode
    tui_mode=$(global_config_get "tui_mode" 2>/dev/null)
    : "${tui_mode:=go}"

    # Build toggle data
    _TOG_LABELS=()
    _TOG_OPTIONS=()
    _TOG_STATES=()

    # TUI mode: go / bash
    _TOG_LABELS[0]="TUI mode"
    _TOG_OPTIONS[0]="go|bash"
    case "$tui_mode" in
      bash) _TOG_STATES[0]=1 ;;
      *)    _TOG_STATES[0]=0 ;;
    esac

    # Color mode: auto / always / never
    _TOG_LABELS[1]="Color mode"
    _TOG_OPTIONS[1]="auto|always|never"
    case "$color_mode" in
      always) _TOG_STATES[1]=1 ;;
      never)  _TOG_STATES[1]=2 ;;
      *)      _TOG_STATES[1]=0 ;;
    esac

    # Log color mode: auto / raw / none
    _TOG_LABELS[2]="Log color mode"
    _TOG_OPTIONS[2]="auto|raw|none"
    case "$log_color_mode" in
      raw)  _TOG_STATES[2]=1 ;;
      none) _TOG_STATES[2]=2 ;;
      *)    _TOG_STATES[2]=0 ;;
    esac

    # Update check: on / off
    _TOG_LABELS[3]="Update check"
    _TOG_OPTIONS[3]="on|off"
    case "$update_check" in
      off) _TOG_STATES[3]=1 ;;
      *)   _TOG_STATES[3]=0 ;;
    esac

    # Default stack: bare / docker / compose / k8s
    _TOG_LABELS[4]="Default stack"
    _TOG_OPTIONS[4]="bare|docker|compose|k8s"
    case "$default_stack" in
      docker)  _TOG_STATES[4]=1 ;;
      compose) _TOG_STATES[4]=2 ;;
      k8s)     _TOG_STATES[4]=3 ;;
      *)       _TOG_STATES[4]=0 ;;
    esac

    # Log retention days: 3 / 7 / 14 / 30 / 90
    _TOG_LABELS[5]="Log retention (days)"
    _TOG_OPTIONS[5]="3|7|14|30|90"
    case "$log_retention" in
      3)  _TOG_STATES[5]=0 ;;
      14) _TOG_STATES[5]=2 ;;
      30) _TOG_STATES[5]=3 ;;
      90) _TOG_STATES[5]=4 ;;
      *)  _TOG_STATES[5]=1 ;;
    esac

    # Health timeout: 5 / 10 / 15 / 30 / 60
    _TOG_LABELS[6]="Health timeout (s)"
    _TOG_OPTIONS[6]="5|10|15|30|60"
    case "$health_timeout" in
      5)  _TOG_STATES[6]=0 ;;
      15) _TOG_STATES[6]=2 ;;
      30) _TOG_STATES[6]=3 ;;
      60) _TOG_STATES[6]=4 ;;
      *)  _TOG_STATES[6]=1 ;;
    esac

    echo ""
    _toggle_select "Muster Settings"

    # Read back chosen values
    local new_tui new_color new_log_color new_update new_stack new_retention new_timeout
    case $(( _TOG_STATES[0] )) in
      1) new_tui="bash" ;;
      *) new_tui="go" ;;
    esac
    case $(( _TOG_STATES[1] )) in
      1) new_color="always" ;;
      2) new_color="never" ;;
      *) new_color="auto" ;;
    esac
    case $(( _TOG_STATES[2] )) in
      1) new_log_color="raw" ;;
      2) new_log_color="none" ;;
      *) new_log_color="auto" ;;
    esac
    case $(( _TOG_STATES[3] )) in
      1) new_update="off" ;;
      *) new_update="on" ;;
    esac
    case $(( _TOG_STATES[4] )) in
      1) new_stack="docker" ;;
      2) new_stack="compose" ;;
      3) new_stack="k8s" ;;
      *) new_stack="bare" ;;
    esac
    case $(( _TOG_STATES[5] )) in
      0) new_retention=3 ;;
      2) new_retention=14 ;;
      3) new_retention=30 ;;
      4) new_retention=90 ;;
      *) new_retention=7 ;;
    esac
    case $(( _TOG_STATES[6] )) in
      0) new_timeout=5 ;;
      2) new_timeout=15 ;;
      3) new_timeout=30 ;;
      4) new_timeout=60 ;;
      *) new_timeout=10 ;;
    esac

    # Save all settings
    global_config_set "tui_mode" "\"$new_tui\""
    global_config_set "color_mode" "\"$new_color\""
    global_config_set "log_color_mode" "\"$new_log_color\""
    global_config_set "update_check" "\"$new_update\""
    global_config_set "default_stack" "\"$new_stack\""
    global_config_set "log_retention_days" "$new_retention"
    global_config_set "default_health_timeout" "$new_timeout"

    return 0
  done
}

_settings_pair_tui() {
  local bin_path="$1"
  source "$MUSTER_ROOT/lib/core/auth.sh"
  local has_tui_token=false
  if [[ -f "$MUSTER_TOKENS_FILE" ]] && has_cmd jq; then
    local existing_tui
    existing_tui=$(jq -r '.tokens[] | select(.name == "muster-tui") | .name' "$MUSTER_TOKENS_FILE" 2>/dev/null)
    [[ -n "$existing_tui" ]] && has_tui_token=true
  fi

  if [[ "$has_tui_token" = true ]]; then
    ok "Auth token already exists."
  else
    local tui_token=""
    if tui_token=$(_auth_create_token_internal "muster-tui" "admin" 2>/dev/null) && [[ -n "$tui_token" ]]; then
      if "$bin_path" --set-token "$tui_token" >/dev/null 2>&1; then
        ok "Auth token created and linked."
      else
        echo -e "  ${YELLOW}!${RESET} ${DIM}Token created. Connect manually:${RESET}"
        echo -e "  ${DIM}  muster-tui --set-token ${tui_token}${RESET}"
      fi
    else
      echo -e "  ${YELLOW}!${RESET} ${DIM}Could not create token (jq may be missing).${RESET}"
    fi
  fi
}

_settings_download_tui() {
  local bin_dir="${HOME}/.local/bin"
  local tui_repo="ImJustRicky/muster-tui"

  echo ""

  # Check if already installed
  local tui_bin="" tui_ver=""
  if command -v muster-tui >/dev/null 2>&1; then
    tui_bin="$(command -v muster-tui)"
    tui_ver="$(muster-tui --version 2>/dev/null || true)"
  elif [[ -x "${bin_dir}/muster-tui" ]]; then
    tui_bin="${bin_dir}/muster-tui"
    tui_ver="$("${bin_dir}/muster-tui" --version 2>/dev/null || true)"
  fi

  if [[ -n "$tui_ver" ]]; then
    echo -e "  ${BOLD}${ACCENT_BRIGHT}muster-tui${RESET} ${DIM}already installed (${tui_ver})${RESET}"
    echo ""
    menu_select "Options" "Pair auth token" "Reinstall / update" "Back"
    case "$MENU_RESULT" in
      "Pair auth token")
        echo ""
        _settings_pair_tui "$tui_bin"
        echo ""
        echo -e "  ${DIM}Press any key to continue...${RESET}"
        IFS= read -rsn1 || true
        return 0
        ;;
      Back)
        return 0
        ;;
    esac
  fi

  echo -e "  ${DIM}Downloading muster-tui...${RESET}"

  local _os _arch
  _os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  _arch="$(uname -m)"
  case "$_arch" in
    x86_64)       _arch="amd64" ;;
    aarch64|arm64) _arch="arm64" ;;
  esac

  local _bin_name="muster-tui-${_os}-${_arch}"
  local tui_url="https://github.com/${tui_repo}/releases/latest/download/${_bin_name}"
  mkdir -p "$bin_dir"

  local tui_ok=false
  if has_cmd curl; then
    if curl -fsSL "$tui_url" -o "${bin_dir}/muster-tui" 2>/dev/null; then
      chmod +x "${bin_dir}/muster-tui"
      tui_ok=true
    else
      # Fallback: resolve latest tag via API and try direct URL
      local _latest_tag=""
      _latest_tag=$(curl -fsSL "https://api.github.com/repos/${tui_repo}/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/".*//')
      if [[ -n "$_latest_tag" ]]; then
        local _fallback_url="https://github.com/${tui_repo}/releases/download/${_latest_tag}/${_bin_name}"
        if curl -fsSL "$_fallback_url" -o "${bin_dir}/muster-tui" 2>/dev/null; then
          chmod +x "${bin_dir}/muster-tui"
          tui_ok=true
        fi
      fi
    fi
  elif has_cmd wget; then
    if wget -q "$tui_url" -O "${bin_dir}/muster-tui" 2>/dev/null; then
      chmod +x "${bin_dir}/muster-tui"
      tui_ok=true
    fi
  fi

  if [[ "$tui_ok" = true ]]; then
    local new_ver
    new_ver="$("${bin_dir}/muster-tui" --version 2>/dev/null || echo "unknown")"
    echo ""
    ok "muster-tui installed! (${new_ver})"
    echo ""
    _settings_pair_tui "${bin_dir}/muster-tui"
  else
    err "Could not download muster-tui binary."
    echo -e "  ${DIM}No pre-built release for ${_os}/${_arch}.${RESET}"
    echo ""
    echo -e "  ${DIM}Build from source:${RESET}"
    echo -e "  ${DIM}  go install github.com/${tui_repo}@latest${RESET}"
  fi

  echo ""
  echo -e "  ${DIM}Press any key to continue...${RESET}"
  IFS= read -rsn1 || true
}

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
    echo -e "  ${BOLD}${ACCENT_BRIGHT}Settings${RESET}"
    echo ""

    if [[ "$_has_project" == "true" ]]; then
      menu_select "Settings" "Project Settings" "Muster Settings" "Download muster-tui (Go)" "Back"
    else
      menu_select "Settings" "Muster Settings" "Download muster-tui (Go)" "Back"
    fi

    case "$MENU_RESULT" in
      "Project Settings")
        _settings_project
        ;;
      "Muster Settings")
        _settings_muster_global
        ;;
      "Download muster-tui (Go)")
        _settings_download_tui
        ;;
      Back)
        return 0
        ;;
    esac
  done
}

_settings_project() {
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  while true; do
    local project
    project=$(config_get '.project')
    local services
    services=$(config_services)

    clear
    echo ""
    echo -e "  ${BOLD}${ACCENT_BRIGHT}Project Settings${RESET}  ${WHITE}${project}${RESET}"
    echo ""

    local w=$(( TERM_COLS - 4 ))
    (( w > 50 )) && w=50
    (( w < 10 )) && w=10
    local inner=$(( w - 2 ))

    # Overview box
    local label="Overview"
    local label_pad_len=$(( w - ${#label} - 3 ))
    (( label_pad_len < 1 )) && label_pad_len=1
    local label_pad
    label_pad=$(printf '%*s' "$label_pad_len" "" | sed 's/ /─/g')
    printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$label" "${RESET}${ACCENT}" "$label_pad" "${RESET}"

    _settings_row "$inner" "Project" "$project"

    local config_display="$CONFIG_FILE"
    [[ "$config_display" == "$HOME"* ]] && config_display="~${config_display#$HOME}"
    _settings_row "$inner" "Config" "$config_display"

    local svc_count=0
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      svc_count=$((svc_count + 1))
    done <<< "$services"
    _settings_row "$inner" "Services" "$svc_count"

    # Hooks summary per service
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      local name
      name=$(config_get ".services.${svc}.name")
      local hooks=""
      local hook_dir="${project_dir}/.muster/hooks/${svc}"
      [[ -x "${hook_dir}/deploy.sh" ]] && hooks="${hooks}D"
      [[ -x "${hook_dir}/health.sh" ]] && hooks="${hooks}H"
      [[ -x "${hook_dir}/rollback.sh" ]] && hooks="${hooks}R"
      [[ -x "${hook_dir}/logs.sh" ]] && hooks="${hooks}L"
      [[ -x "${hook_dir}/cleanup.sh" ]] && hooks="${hooks}C"
      [[ -z "$hooks" ]] && hooks="none"
      _settings_row "$inner" "$name" "$hooks"
    done <<< "$services"

    local bottom
    bottom=$(printf '%*s' "$w" "" | sed 's/ /─/g')
    printf '  %b└%s┘%b\n' "${ACCENT}" "$bottom" "${RESET}"
    echo -e "  ${DIM}D=deploy H=health R=rollback L=logs C=cleanup${RESET}"
    echo ""

    menu_select "Project Settings" "Services" "Open config" "Back"

    case "$MENU_RESULT" in
      Services)
        _settings_services
        ;;
      "Open config")
        _settings_open_config
        ;;
      Back)
        return 0
        ;;
    esac
  done
}

_settings_services() {
  local services
  services=$(config_services)

  local svc_list=()
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    svc_list[${#svc_list[@]}]="$svc"
  done <<< "$services"

  local svc_names=()
  local i=0
  while (( i < ${#svc_list[@]} )); do
    local name
    name=$(config_get ".services.${svc_list[$i]}.name")
    svc_names[$i]="$name"
    i=$((i + 1))
  done
  svc_names[${#svc_names[@]}]="Back"

  echo ""
  menu_select "Which service?" "${svc_names[@]}"

  [[ "$MENU_RESULT" == "Back" ]] && return 0

  # Find the service key from the selected name
  local target_svc=""
  i=0
  while (( i < ${#svc_list[@]} )); do
    if [[ "${svc_names[$i]}" == "$MENU_RESULT" ]]; then
      target_svc="${svc_list[$i]}"
      break
    fi
    i=$((i + 1))
  done

  [[ -z "$target_svc" ]] && return 0

  _settings_service_toggles "$target_svc"
}

_settings_service_toggles() {
  local svc="$1"
  local name
  name=$(config_get ".services.${svc}.name")

  # Build toggle data in globals
  local _tog_keys=()
  _TOG_LABELS=()
  _TOG_OPTIONS=()
  _TOG_STATES=()

  # Skip deploy — ON/OFF toggle
  local skip_deploy
  skip_deploy=$(config_get ".services.${svc}.skip_deploy")
  _tog_keys[${#_tog_keys[@]}]="skip_deploy"
  _TOG_LABELS[${#_TOG_LABELS[@]}]="Skip deploy"
  _TOG_OPTIONS[${#_TOG_OPTIONS[@]}]="OFF|ON"
  if [[ "$skip_deploy" == "true" ]]; then
    _TOG_STATES[${#_TOG_STATES[@]}]=1
  else
    _TOG_STATES[${#_TOG_STATES[@]}]=0
  fi

  # Health check — ON/OFF toggle
  local health_enabled
  health_enabled=$(config_get ".services.${svc}.health.enabled")
  _tog_keys[${#_tog_keys[@]}]="health"
  _TOG_LABELS[${#_TOG_LABELS[@]}]="Health check"
  _TOG_OPTIONS[${#_TOG_OPTIONS[@]}]="OFF|ON"
  if [[ "$health_enabled" == "false" ]]; then
    _TOG_STATES[${#_TOG_STATES[@]}]=0
  else
    local health_type
    health_type=$(config_get ".services.${svc}.health.type")
    if [[ "$health_type" != "null" && -n "$health_type" ]]; then
      _TOG_STATES[${#_TOG_STATES[@]}]=1
    else
      _TOG_STATES[${#_TOG_STATES[@]}]=0
    fi
  fi

  # Credentials — cycle: Off / Save always / Once per session / Every time
  local cred_mode
  cred_mode=$(config_get ".services.${svc}.credentials.mode")
  _tog_keys[${#_tog_keys[@]}]="credentials"
  _TOG_LABELS[${#_TOG_LABELS[@]}]="Credentials"
  _TOG_OPTIONS[${#_TOG_OPTIONS[@]}]="Off|Save always|Once per session|Every time"
  case "$cred_mode" in
    save)    _TOG_STATES[${#_TOG_STATES[@]}]=1 ;;
    session) _TOG_STATES[${#_TOG_STATES[@]}]=2 ;;
    always)  _TOG_STATES[${#_TOG_STATES[@]}]=3 ;;
    *)       _TOG_STATES[${#_TOG_STATES[@]}]=0 ;;
  esac

  # Deploy mode — Restart / Update image (k8s services only)
  local _k8s_dep
  _k8s_dep=$(config_get ".services.${svc}.k8s.deployment")
  if [[ -n "$_k8s_dep" && "$_k8s_dep" != "null" ]]; then
    local deploy_mode
    deploy_mode=$(config_get ".services.${svc}.deploy_mode")
    _tog_keys[${#_tog_keys[@]}]="deploy_mode"
    _TOG_LABELS[${#_TOG_LABELS[@]}]="Deploy mode"
    _TOG_OPTIONS[${#_TOG_OPTIONS[@]}]="Restart|Update image"
    case "$deploy_mode" in
      update) _TOG_STATES[${#_TOG_STATES[@]}]=1 ;;
      *)      _TOG_STATES[${#_TOG_STATES[@]}]=0 ;;
    esac

    # Deploy timeout
    local deploy_timeout
    deploy_timeout=$(config_get ".services.${svc}.deploy_timeout")
    [[ "$deploy_timeout" == "null" || -z "$deploy_timeout" ]] && deploy_timeout="120"
    _tog_keys[${#_tog_keys[@]}]="deploy_timeout"
    _TOG_LABELS[${#_TOG_LABELS[@]}]="Deploy timeout"
    _TOG_OPTIONS[${#_TOG_OPTIONS[@]}]="120s|60s|180s|300s|600s"
    case "$deploy_timeout" in
      60)  _TOG_STATES[${#_TOG_STATES[@]}]=1 ;;
      180) _TOG_STATES[${#_TOG_STATES[@]}]=2 ;;
      300) _TOG_STATES[${#_TOG_STATES[@]}]=3 ;;
      600) _TOG_STATES[${#_TOG_STATES[@]}]=4 ;;
      *)   _TOG_STATES[${#_TOG_STATES[@]}]=0 ;;
    esac
  fi

  # Git pull — ON/OFF toggle
  local gp_enabled
  gp_enabled=$(config_get ".services.${svc}.git_pull.enabled")
  local gp_label="Git pull"
  if [[ "$gp_enabled" == "true" ]]; then
    local _gp_r _gp_b
    _gp_r=$(config_get ".services.${svc}.git_pull.remote")
    _gp_b=$(config_get ".services.${svc}.git_pull.branch")
    [[ "$_gp_r" == "null" || -z "$_gp_r" ]] && _gp_r="origin"
    [[ "$_gp_b" == "null" || -z "$_gp_b" ]] && _gp_b="main"
    gp_label="Git pull: ${_gp_r}/${_gp_b}"
  fi
  _tog_keys[${#_tog_keys[@]}]="git_pull"
  _TOG_LABELS[${#_TOG_LABELS[@]}]="$gp_label"
  _TOG_OPTIONS[${#_TOG_OPTIONS[@]}]="OFF|ON"
  if [[ "$gp_enabled" == "true" ]]; then
    _TOG_STATES[${#_TOG_STATES[@]}]=1
  else
    _TOG_STATES[${#_TOG_STATES[@]}]=0
  fi

  # Remote — ON/OFF toggle
  local remote_label="Remote: Off"
  if remote_is_enabled "$svc"; then
    remote_label="Remote: $(remote_desc "$svc")"
  fi
  _tog_keys[${#_tog_keys[@]}]="remote"
  _TOG_LABELS[${#_TOG_LABELS[@]}]="$remote_label"
  _TOG_OPTIONS[${#_TOG_OPTIONS[@]}]="OFF|ON"
  if remote_is_enabled "$svc"; then
    _TOG_STATES[${#_TOG_STATES[@]}]=1
  else
    _TOG_STATES[${#_TOG_STATES[@]}]=0
  fi

  echo ""
  _toggle_select "$name"

  # Apply changes
  local i=0
  while (( i < ${#_tog_keys[@]} )); do
    case "${_tog_keys[$i]}" in
      skip_deploy)
        if (( _TOG_STATES[i] >= 1 )); then
          config_set ".services.${svc}.skip_deploy" "true"
        else
          config_set ".services.${svc}.skip_deploy" "false"
        fi
        ;;
      health)
        if (( _TOG_STATES[i] >= 1 )); then
          config_set ".services.${svc}.health.enabled" "true"
        else
          config_set ".services.${svc}.health.enabled" "false"
        fi
        ;;
      credentials)
        case $(( _TOG_STATES[i] )) in
          0) config_set ".services.${svc}.credentials" '{"enabled":false,"mode":"off"}' ;;
          1) config_set ".services.${svc}.credentials" '{"enabled":true,"mode":"save"}' ;;
          2) config_set ".services.${svc}.credentials" '{"enabled":true,"mode":"session"}' ;;
          3) config_set ".services.${svc}.credentials" '{"enabled":true,"mode":"always"}' ;;
        esac
        ;;
      deploy_mode)
        case $(( _TOG_STATES[i] )) in
          1) config_set ".services.${svc}.deploy_mode" '"update"' ;;
          *) config_set ".services.${svc}.deploy_mode" '"restart"' ;;
        esac
        ;;
      deploy_timeout)
        local _timeout_val
        case $(( _TOG_STATES[i] )) in
          1) _timeout_val=60 ;;
          2) _timeout_val=180 ;;
          3) _timeout_val=300 ;;
          4) _timeout_val=600 ;;
          *) _timeout_val=120 ;;
        esac
        config_set ".services.${svc}.deploy_timeout" "$_timeout_val"
        ;;
      git_pull)
        if (( _TOG_STATES[i] >= 1 )); then
          # Toggling ON — prompt for remote + branch if not already configured
          local _existing_gp
          _existing_gp=$(config_get ".services.${svc}.git_pull.enabled")
          if [[ "$_existing_gp" != "true" ]]; then
            echo ""
            printf '  %b>%b Git remote [origin]: ' "${ACCENT}" "${RESET}"
            local _gp_remote_in=""
            IFS= read -r _gp_remote_in
            printf '  %b>%b Git branch [main]: ' "${ACCENT}" "${RESET}"
            local _gp_branch_in=""
            IFS= read -r _gp_branch_in
            [[ -z "$_gp_remote_in" ]] && _gp_remote_in="origin"
            [[ -z "$_gp_branch_in" ]] && _gp_branch_in="main"
            config_set ".services.${svc}.git_pull" "{\"enabled\":true,\"remote\":\"${_gp_remote_in}\",\"branch\":\"${_gp_branch_in}\"}"
          fi
        else
          config_set ".services.${svc}.git_pull.enabled" 'false'
        fi
        ;;
      remote)
        if (( _TOG_STATES[i] >= 1 )); then
          # Toggling ON — check if already configured
          if ! remote_is_enabled "$svc"; then
            # Prompt for user@host
            echo ""
            printf '  %b>%b Remote target (user@host): ' "${ACCENT}" "${RESET}"
            local _remote_input=""
            IFS= read -r _remote_input
            if [[ -n "$_remote_input" ]]; then
              local _rm_user="${_remote_input%%@*}"
              local _rm_host="${_remote_input#*@}"
              config_set ".services.${svc}.remote" "{\"enabled\":true,\"host\":\"${_rm_host}\",\"user\":\"${_rm_user}\",\"port\":22}"
            fi
          fi
        else
          # Toggling OFF — disable without deleting config
          config_set ".services.${svc}.remote.enabled" 'false'
        fi
        ;;
    esac
    i=$((i + 1))
  done

  ok "Settings saved for ${name}"
  echo ""
}

# Print a key-value row inside a box
_settings_row() {
  local inner="$1" key="$2" val="$3"

  local max_val=$(( inner - ${#key} - 5 ))
  (( max_val < 3 )) && max_val=3
  if (( ${#val} > max_val )); then
    val="...${val: -$((max_val - 3))}"
  fi

  local content_len=$(( 3 + ${#key} + 2 + ${#val} ))
  local pad_len=$(( inner - content_len ))
  (( pad_len < 0 )) && pad_len=0
  local pad
  pad=$(printf '%*s' "$pad_len" "")

  printf '  %b│%b %b%s%b  %s%s%b│%b\n' \
    "${ACCENT}" "${RESET}" "${WHITE}" "$key" "${RESET}" "$val" "$pad" "${ACCENT}" "${RESET}"
}
