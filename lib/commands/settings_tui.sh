#!/usr/bin/env bash
# muster/lib/commands/settings_tui.sh — Interactive settings TUI widgets
# Extracted from settings.sh: toggle selector, global settings TUI, project settings TUI.

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

  local _tog_w=$(( TERM_COLS - 4 ))
  (( _tog_w > 50 )) && _tog_w=50
  (( _tog_w < 20 )) && _tog_w=20

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
    printf '  %b%s%b\n' "${BOLD}" "$title" "${RESET}"
    printf '  %b↑/↓ navigate  ⏎ cycle  q/esc back%b\n' "${DIM}" "${RESET}"
  }

  _tog_draw() {
    _tog_w=$(( TERM_COLS - 4 ))
    (( _tog_w > 50 )) && _tog_w=50
    (( _tog_w < 20 )) && _tog_w=20

    local i=0
    while (( i < count )); do
      local label="${_TOG_LABELS[$i]}"
      # Inline _tog_get_opt (avoids subshell per item)
      local cur_opt="${_TOG_OPTIONS[$i]}"
      local _oi=0
      while (( _oi < _TOG_STATES[i] )); do
        cur_opt="${cur_opt#*|}"
        _oi=$((_oi + 1))
      done
      cur_opt="${cur_opt%%|*}"

      # Color: first option (index 0) = red/off, anything else = green/on
      local state_color="$GREEN"
      (( _TOG_STATES[i] == 0 )) && state_color="$RED"

      if (( i == selected )); then
        local text="  ▸ ${label}  ${cur_opt}"
        local text_len=${#text}
        local bar_pad=$(( _tog_w - text_len ))
        (( bar_pad < 0 )) && bar_pad=0
        local pad
        printf -v pad '%*s' "$bar_pad" ""
        printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
      else
        local content_len=$(( 4 + ${#label} + 2 + ${#cur_opt} ))
        local pad_len=$(( _tog_w - content_len ))
        (( pad_len < 0 )) && pad_len=0
        local pad
        printf -v pad '%*s' "$pad_len" ""
        printf '    %s%s %b%s%b\n' "$label" "$pad" "$state_color" "$cur_opt" "${RESET}"
      fi
      i=$((i + 1))
    done

    # Back row
    if (( selected == count )); then
      local text="  ▸ Back"
      local text_len=${#text}
      local bar_pad=$(( _tog_w - text_len ))
      (( bar_pad < 0 )) && bar_pad=0
      local pad
      printf -v pad '%*s' "$bar_pad" ""
      printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
    else
      printf '    %bBack%b\n' "${DIM}" "${RESET}"
    fi
  }

  local total_lines=$(( count + 1 ))

  _tog_clear() {
    (( total_lines > 0 )) && printf '\033[%dA' "$total_lines"
    printf '\033[J'
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
      'q'|'Q'|$'\x1b')
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

_settings_muster_global() {
  while true; do
    local color_mode log_color_mode log_retention default_stack health_timeout update_check update_mode scanner_ex signing

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
    update_mode=$(global_config_get "update_mode" 2>/dev/null)
    : "${update_mode:=release}"
    signing=$(global_config_get "signing" 2>/dev/null)
    : "${signing:=off}"
    scanner_ex=$(global_config_get "scanner_exclude" 2>/dev/null)
    if [[ "$scanner_ex" == "[]" || -z "$scanner_ex" ]]; then
      scanner_ex="(none)"
    fi

    local tui_mode
    tui_mode=$(global_config_get "tui_mode" 2>/dev/null)
    : "${tui_mode:=go}"

    local deploy_name
    deploy_name=$(global_config_get "deploy_name" 2>/dev/null)
    [[ "$deploy_name" == "null" ]] && deploy_name=""

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

    # Update mode: release / source
    _TOG_LABELS[4]="Update channel"
    _TOG_OPTIONS[4]="release|source"
    case "$update_mode" in
      source) _TOG_STATES[4]=1 ;;
      *)      _TOG_STATES[4]=0 ;;
    esac

    # Default stack: bare / docker / compose / k8s
    _TOG_LABELS[5]="Default stack"
    _TOG_OPTIONS[5]="bare|docker|compose|k8s"
    case "$default_stack" in
      docker)  _TOG_STATES[5]=1 ;;
      compose) _TOG_STATES[5]=2 ;;
      k8s)     _TOG_STATES[5]=3 ;;
      *)       _TOG_STATES[5]=0 ;;
    esac

    # Log retention days: 3 / 7 / 14 / 30 / 90
    _TOG_LABELS[6]="Log retention (days)"
    _TOG_OPTIONS[6]="3|7|14|30|90"
    case "$log_retention" in
      3)  _TOG_STATES[6]=0 ;;
      14) _TOG_STATES[6]=2 ;;
      30) _TOG_STATES[6]=3 ;;
      90) _TOG_STATES[6]=4 ;;
      *)  _TOG_STATES[6]=1 ;;
    esac

    # Health timeout: 5 / 10 / 15 / 30 / 60
    _TOG_LABELS[7]="Health timeout (s)"
    _TOG_OPTIONS[7]="5|10|15|30|60"
    case "$health_timeout" in
      5)  _TOG_STATES[7]=0 ;;
      15) _TOG_STATES[7]=2 ;;
      30) _TOG_STATES[7]=3 ;;
      60) _TOG_STATES[7]=4 ;;
      *)  _TOG_STATES[7]=1 ;;
    esac

    # Signing: off / on
    _TOG_LABELS[8]="Fleet signing"
    _TOG_OPTIONS[8]="off|on"
    case "$signing" in
      on) _TOG_STATES[8]=1 ;;
      *)  _TOG_STATES[8]=0 ;;
    esac

    # Minimal output: off / on
    local minimal_val
    minimal_val=$(global_config_get "minimal" 2>/dev/null)
    _TOG_LABELS[9]="Minimal output"
    _TOG_OPTIONS[9]="off|on"
    case "$minimal_val" in
      true) _TOG_STATES[9]=1 ;;
      *)    _TOG_STATES[9]=0 ;;
    esac

    # Machine role: local / control / target / both
    local machine_role
    machine_role=$(global_config_get "machine_role" 2>/dev/null)
    : "${machine_role:=local}"
    _TOG_LABELS[10]="Machine role"
    _TOG_OPTIONS[10]="local|control|target|both"
    case "$machine_role" in
      control) _TOG_STATES[10]=1 ;;
      target)  _TOG_STATES[10]=2 ;;
      both)    _TOG_STATES[10]=3 ;;
      *)       _TOG_STATES[10]=0 ;;
    esac

    # Service lock timeout: 60 / 300 / 900 / 1800 / 3600 / 7200 / 86400
    local lock_timeout
    lock_timeout=$(global_config_get "service_lock_timeout" 2>/dev/null)
    : "${lock_timeout:=1800}"
    _TOG_LABELS[11]="Lock timeout (s)"
    _TOG_OPTIONS[11]="60|300|900|1800|3600|7200|86400"
    case "$lock_timeout" in
      60)    _TOG_STATES[11]=0 ;;
      300)   _TOG_STATES[11]=1 ;;
      900)   _TOG_STATES[11]=2 ;;
      3600)  _TOG_STATES[11]=4 ;;
      7200)  _TOG_STATES[11]=5 ;;
      86400) _TOG_STATES[11]=6 ;;
      *)     _TOG_STATES[11]=3 ;;
    esac

    echo ""
    _toggle_select "Muster Settings"

    # Read back chosen values
    local new_tui new_color new_log_color new_update new_update_mode new_stack new_retention new_timeout
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
      1) new_update_mode="source" ;;
      *) new_update_mode="release" ;;
    esac
    case $(( _TOG_STATES[5] )) in
      1) new_stack="docker" ;;
      2) new_stack="compose" ;;
      3) new_stack="k8s" ;;
      *) new_stack="bare" ;;
    esac
    case $(( _TOG_STATES[6] )) in
      0) new_retention=3 ;;
      2) new_retention=14 ;;
      3) new_retention=30 ;;
      4) new_retention=90 ;;
      *) new_retention=7 ;;
    esac
    case $(( _TOG_STATES[7] )) in
      0) new_timeout=5 ;;
      2) new_timeout=15 ;;
      3) new_timeout=30 ;;
      4) new_timeout=60 ;;
      *) new_timeout=10 ;;
    esac
    local new_signing
    case $(( _TOG_STATES[8] )) in
      1) new_signing="on" ;;
      *) new_signing="off" ;;
    esac
    local new_minimal
    case $(( _TOG_STATES[9] )) in
      1) new_minimal="true" ;;
      *) new_minimal="false" ;;
    esac
    local new_role
    case $(( _TOG_STATES[10] )) in
      1) new_role="control" ;;
      2) new_role="target" ;;
      3) new_role="both" ;;
      *) new_role="local" ;;
    esac
    local new_lock_timeout
    case $(( _TOG_STATES[11] )) in
      0) new_lock_timeout=60 ;;
      1) new_lock_timeout=300 ;;
      2) new_lock_timeout=900 ;;
      4) new_lock_timeout=3600 ;;
      5) new_lock_timeout=7200 ;;
      6) new_lock_timeout=86400 ;;
      *) new_lock_timeout=1800 ;;
    esac

    # Confirm source mode switch
    if [[ "$new_update_mode" == "source" && "$update_mode" != "source" ]]; then
      echo ""
      printf '  %b! Source mode tracks the development branch (main)%b\n' "${YELLOW}" "${RESET}"
      printf '  %b  - Frequent updates with untested changes%b\n' "${DIM}" "${RESET}"
      printf '  %b  - Not recommended for production%b\n' "${DIM}" "${RESET}"
      printf '  %b  - Can cause breaking changes without notice%b\n' "${DIM}" "${RESET}"
      echo ""
      printf '  %bSwitch to source? [y/N]%b ' "${YELLOW}" "${RESET}"
      local _src_confirm=""
      IFS= read -rsn1 _src_confirm || true
      echo ""
      case "$_src_confirm" in
        y|Y) ;;
        *) new_update_mode="release" ;;
      esac
    fi

    # Deploy name (free-text input)
    echo ""
    local _dn_display="${deploy_name:-(not set)}"
    printf '  %bDeploy name (shown in locks)%b [%s]: ' "${DIM}" "${RESET}" "$_dn_display"
    local new_deploy_name=""
    IFS= read -r new_deploy_name
    # If empty input, keep existing value
    if [[ -z "$new_deploy_name" ]]; then
      new_deploy_name="$deploy_name"
    fi

    # Save all settings
    global_config_set "tui_mode" "\"$new_tui\""
    global_config_set "color_mode" "\"$new_color\""
    global_config_set "log_color_mode" "\"$new_log_color\""
    global_config_set "update_check" "\"$new_update\""
    global_config_set "update_mode" "\"$new_update_mode\""
    global_config_set "default_stack" "\"$new_stack\""
    global_config_set "log_retention_days" "$new_retention"
    global_config_set "default_health_timeout" "$new_timeout"
    global_config_set "signing" "\"$new_signing\""
    global_config_set "minimal" "$new_minimal"
    global_config_set "machine_role" "\"$new_role\""
    global_config_set "service_lock_timeout" "$new_lock_timeout"
    if [[ -n "$new_deploy_name" ]]; then
      global_config_set "deploy_name" "\"$new_deploy_name\""
    fi

    return 0
  done
}

# ── Scanner exclude ──

_settings_scanner_exclude() {
  while true; do
    clear
    echo ""
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Scanner Exclude${RESET}"
    echo ""

    local _se_val
    _se_val=$(global_config_get "scanner_exclude" 2>/dev/null)

    if [[ -z "$_se_val" || "$_se_val" == "[]" || "$_se_val" == "null" ]]; then
      printf '  %bNo patterns configured%b\n' "${DIM}" "${RESET}"
    else
      # Parse JSON array into lines
      local _se_items
      _se_items=$(printf '%s' "$_se_val" | jq -r '.[]' 2>/dev/null)
      if [[ -n "$_se_items" ]]; then
        while IFS= read -r _se_item; do
          [[ -z "$_se_item" ]] && continue
          printf '  %b- %s%b\n' "${DIM}" "$_se_item" "${RESET}"
        done <<< "$_se_items"
      else
        printf '  %bNo patterns configured%b\n' "${DIM}" "${RESET}"
      fi
    fi
    echo ""

    menu_select "Scanner Exclude" "Add pattern" "Remove pattern" "Back"

    case "$MENU_RESULT" in
      "Add pattern")
        printf '  Pattern to exclude: '
        local _se_new=""
        IFS= read -r _se_new
        if [[ -n "$_se_new" ]]; then
          local _se_quoted
          _se_quoted=$(printf '%s' "$_se_new" | sed 's/\\/\\\\/g;s/"/\\"/g')
          global_config_set "scanner_exclude" "(.scanner_exclude + [\"${_se_quoted}\"] | unique)"
          ok "Added: ${_se_new}"
          printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
          IFS= read -rsn1 || true
        fi
        ;;
      "Remove pattern")
        local _se_current
        _se_current=$(global_config_get "scanner_exclude" 2>/dev/null)
        if [[ -z "$_se_current" || "$_se_current" == "[]" || "$_se_current" == "null" ]]; then
          info "No patterns to remove"
          printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
          IFS= read -rsn1 || true
        else
          local _se_opts=()
          while IFS= read -r _se_o; do
            [[ -z "$_se_o" ]] && continue
            _se_opts[${#_se_opts[@]}]="$_se_o"
          done < <(printf '%s' "$_se_current" | jq -r '.[]' 2>/dev/null)

          if [[ ${#_se_opts[@]} -eq 0 ]]; then
            info "No patterns to remove"
            printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
            IFS= read -rsn1 || true
          else
            _se_opts[${#_se_opts[@]}]="Back"
            menu_select "Remove" "${_se_opts[@]}"
            if [[ "$MENU_RESULT" != "Back" && "$MENU_RESULT" != "__back__" ]]; then
              local _se_rm_quoted
              _se_rm_quoted=$(printf '%s' "$MENU_RESULT" | sed 's/\\/\\\\/g;s/"/\\"/g')
              global_config_set "scanner_exclude" "([.scanner_exclude[] | select(. != \"${_se_rm_quoted}\")])"
              ok "Removed: ${MENU_RESULT}"
              printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
              IFS= read -rsn1 || true
            fi
          fi
        fi
        ;;
      "Back"|"__back__")
        return 0
        ;;
    esac
  done
}

# ── Deploy password ──

_settings_deploy_password() {
  while true; do
    clear
    echo ""
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Deploy Password${RESET}"
    echo ""

    local _dp_hash
    _dp_hash=$(global_config_get "deploy_password_hash" 2>/dev/null)

    if [[ -n "$_dp_hash" && "$_dp_hash" != "null" && "$_dp_hash" != '""' && "$_dp_hash" != "" ]]; then
      printf '  %bStatus:%b %bset%b\n' "${DIM}" "${RESET}" "${GREEN}" "${RESET}"
    else
      printf '  %bStatus:%b %bnot set%b\n' "${DIM}" "${RESET}" "${YELLOW}" "${RESET}"
    fi
    echo ""

    menu_select "Deploy Password" "Set password" "Remove password" "Back"

    case "$MENU_RESULT" in
      "Set password")
        printf '  New password: '
        local _dp_new=""
        IFS= read -rs _dp_new
        echo ""
        if [[ -n "$_dp_new" ]]; then
          printf '  Confirm password: '
          local _dp_confirm=""
          IFS= read -rs _dp_confirm
          echo ""
          if [[ "$_dp_new" == "$_dp_confirm" ]]; then
            source "$MUSTER_ROOT/lib/core/auth.sh"
            local _dp_hashed
            _dp_hashed="sha256:$(_auth_hash "$_dp_new")"
            global_config_set "deploy_password_hash" "\"${_dp_hashed}\""
            ok "Deploy password set"
          else
            err "Passwords do not match"
          fi
        else
          info "Cancelled"
        fi
        printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
        IFS= read -rsn1 || true
        ;;
      "Remove password")
        global_config_set "deploy_password_hash" '""'
        ok "Deploy password removed"
        printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
        IFS= read -rsn1 || true
        ;;
      "Back"|"__back__")
        return 0
        ;;
    esac
  done
}

# ── Updates panel ──

_settings_updates() {
  source "$MUSTER_ROOT/lib/core/updater.sh"

  while true; do
    clear
    echo ""
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Updates${RESET}"
    echo ""

    # Current version + mode
    local _cur_ver _update_mode
    _cur_ver=$(grep 'MUSTER_VERSION=' "${MUSTER_ROOT}/bin/muster" 2>/dev/null \
      | head -1 | sed 's/.*MUSTER_VERSION="//;s/".*//')
    _update_mode=$(global_config_get "update_mode" 2>/dev/null)
    : "${_update_mode:=release}"

    local _w=$(( TERM_COLS - 4 ))
    (( _w > 50 )) && _w=50
    (( _w < 10 )) && _w=10
    local _inner=$(( _w - 2 ))

    # ── Info box ──
    local _label="Current"
    local _label_pad_len=$(( _w - ${#_label} - 3 ))
    (( _label_pad_len < 1 )) && _label_pad_len=1
    local _label_pad
    printf -v _label_pad '%*s' "$_label_pad_len" ""
    _label_pad="${_label_pad// /─}"
    printf '  %b┌─%b%s%b─%s┐%b\n' "${ACCENT}" "${BOLD}" "$_label" "${RESET}${ACCENT}" "$_label_pad" "${RESET}"

    # Version line
    local _vline="Version: v${_cur_ver}"
    local _vpad_len=$(( _inner - ${#_vline} - 2 ))
    (( _vpad_len < 0 )) && _vpad_len=0
    local _vpad
    printf -v _vpad '%*s' "$_vpad_len" ""
    printf '  %b│%b  %b%s%b%s%b│%b\n' "${ACCENT}" "${RESET}" "${WHITE}" "$_vline" "${RESET}" "$_vpad" "${ACCENT}" "${RESET}"

    # Channel line
    local _cline="Channel: ${_update_mode}"
    local _ctag=""
    if [[ "$_update_mode" == "source" ]]; then
      _ctag=" (dev)"
    fi
    local _cfull="${_cline}${_ctag}"
    local _cpad_len=$(( _inner - ${#_cfull} - 2 ))
    (( _cpad_len < 0 )) && _cpad_len=0
    local _cpad
    printf -v _cpad '%*s' "$_cpad_len" ""
    if [[ "$_update_mode" == "source" ]]; then
      printf '  %b│%b  %s%b%s%b%s%b│%b\n' "${ACCENT}" "${RESET}" "$_cline" "${YELLOW}" "$_ctag" "${RESET}" "$_cpad" "${ACCENT}" "${RESET}"
    else
      printf '  %b│%b  %s%s%b│%b\n' "${ACCENT}" "${RESET}" "$_cfull" "$_cpad" "${ACCENT}" "${RESET}"
    fi

    # Bottom of box
    local _bottom
    printf -v _bottom '%*s' "$_w" ""
    _bottom="${_bottom// /─}"
    printf '  %b└%s┘%b\n' "${ACCENT}" "$_bottom" "${RESET}"

    # ── Changelog ──
    local _changelog="${MUSTER_ROOT}/CHANGELOG.md"
    if [[ -f "$_changelog" ]]; then
      echo ""
      printf '  %b%bChangelog%b\n' "${BOLD}" "${WHITE}" "${RESET}"
      echo ""

      local _cl_lines=0 _in_section=false _shown_sections=0
      while IFS= read -r _cl_line; do
        # Skip the title line
        if [[ "$_cl_line" == "# "* ]]; then
          continue
        fi
        if [[ "$_cl_line" == "All notable"* || "$_cl_line" == "Format follows"* ]]; then
          continue
        fi

        # Section headers
        if [[ "$_cl_line" == "## "* ]]; then
          # Skip [Unreleased] section header
          case "$_cl_line" in *"[Unreleased]"*) continue ;; esac
          _shown_sections=$(( _shown_sections + 1 ))
          # Show up to 5 release sections
          if (( _shown_sections > 5 )); then
            printf '  %b  ... see CHANGELOG.md for full history%b\n' "${DIM}" "${RESET}"
            break
          fi
          _in_section=true
          # Format: ## [0.5.45] - 2026-03-04
          local _sec_ver="${_cl_line#\#\# }"
          printf '  %b  %b%s%b\n' "${ACCENT_BRIGHT}" "${BOLD}" "$_sec_ver" "${RESET}"
          continue
        fi

        if [[ "$_in_section" == "true" ]]; then
          if [[ -z "$_cl_line" ]]; then
            echo ""
            continue
          fi
          _cl_lines=$(( _cl_lines + 1 ))
          if (( _cl_lines > 40 )); then
            printf '  %b  ... truncated%b\n' "${DIM}" "${RESET}"
            break
          fi
          printf '  %b  %s%b\n' "${DIM}" "$_cl_line" "${RESET}"
        fi
      done < "$_changelog"
    fi

    echo ""

    # ── Action menu ──
    if [[ "$_update_mode" == "source" ]]; then
      menu_select "Action" "Check for updates" "Switch to release channel" "Back"
    else
      menu_select "Action" "Check for updates" "Back"
    fi

    case "$MENU_RESULT" in
      "Check for updates")
        update_apply
        printf '  %bPress any key to continue...%b\n' "${DIM}" "${RESET}"
        IFS= read -rsn1 || true
        ;;
      "Switch to release channel")
        global_config_set "update_mode" "\"release\""
        ok "Switched to release channel"
        printf '  %bPress any key to continue...%b\n' "${DIM}" "${RESET}"
        IFS= read -rsn1 || true
        ;;
      Back|__back__)
        return 0
        ;;
    esac
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
        printf '%b\n' "  ${YELLOW}!${RESET} ${DIM}Token created. Connect manually:${RESET}"
        printf '%b\n' "  ${DIM}  muster-tui --set-token ${tui_token}${RESET}"
      fi
    else
      printf '%b\n' "  ${YELLOW}!${RESET} ${DIM}Could not create token (jq may be missing).${RESET}"
    fi
  fi
}

_settings_download_tui() {
  local bin_dir="${HOME}/.local/bin"
  local tui_repo="Muster-dev/muster-tui"
  local tui_repo_old="ImJustRicky/muster-tui"

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
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}muster-tui${RESET} ${DIM}already installed (${tui_ver})${RESET}"
    echo ""
    menu_select "Options" "Pair auth token" "Reinstall / update" "Back"
    case "$MENU_RESULT" in
      "Pair auth token")
        echo ""
        _settings_pair_tui "$tui_bin"
        echo ""
        printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
        IFS= read -rsn1 || true
        return 0
        ;;
      Back|__back__)
        return 0
        ;;
    esac
  fi

  printf '%b\n' "  ${DIM}Downloading muster-tui...${RESET}"

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

  local tui_url_old="https://github.com/${tui_repo_old}/releases/latest/download/${_bin_name}"
  local tui_ok=false
  if has_cmd curl; then
    if curl -fsSL "$tui_url" -o "${bin_dir}/muster-tui" 2>/dev/null \
        || curl -fsSL "$tui_url_old" -o "${bin_dir}/muster-tui" 2>/dev/null; then
      chmod +x "${bin_dir}/muster-tui"
      tui_ok=true
    else
      # Fallback: resolve latest tag via API and try direct URL
      local _latest_tag=""
      _latest_tag=$(curl -fsSL "https://api.github.com/repos/${tui_repo}/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/".*//')
      [[ -z "$_latest_tag" ]] && _latest_tag=$(curl -fsSL "https://api.github.com/repos/${tui_repo_old}/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/".*//')
      if [[ -n "$_latest_tag" ]]; then
        local _fallback_url="https://github.com/${tui_repo}/releases/download/${_latest_tag}/${_bin_name}"
        local _fallback_url_old="https://github.com/${tui_repo_old}/releases/download/${_latest_tag}/${_bin_name}"
        if curl -fsSL "$_fallback_url" -o "${bin_dir}/muster-tui" 2>/dev/null \
            || curl -fsSL "$_fallback_url_old" -o "${bin_dir}/muster-tui" 2>/dev/null; then
          chmod +x "${bin_dir}/muster-tui"
          tui_ok=true
        fi
      fi
    fi
  elif has_cmd wget; then
    if wget -q "$tui_url" -O "${bin_dir}/muster-tui" 2>/dev/null \
        || wget -q "$tui_url_old" -O "${bin_dir}/muster-tui" 2>/dev/null; then
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
    printf '%b\n' "  ${DIM}No pre-built release for ${_os}/${_arch}.${RESET}"
    echo ""
    printf '%b\n' "  ${DIM}Build from source:${RESET}"
    printf '%b\n' "  ${DIM}  go install github.com/${tui_repo}@latest${RESET}"
  fi

  echo ""
  printf '%b\n' "  ${DIM}Press any key to continue...${RESET}"
  IFS= read -rsn1 || true
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
    printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Project Settings${RESET}  ${WHITE}${project}${RESET}"
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
    printf -v label_pad '%*s' "$label_pad_len" ""
    label_pad="${label_pad// /─}"
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
    printf -v bottom '%*s' "$w" ""
    bottom="${bottom// /─}"
    printf '  %b└%s┘%b\n' "${ACCENT}" "$bottom" "${RESET}"
    printf '%b\n' "  ${DIM}D=deploy H=health R=rollback L=logs C=cleanup${RESET}"
    echo ""

    menu_select "Project Settings" "Services" "Open config" "Back"

    case "$MENU_RESULT" in
      Services)
        _settings_services
        ;;
      "Open config")
        _settings_open_config
        ;;
      Back|__back__)
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

  [[ "$MENU_RESULT" == "Back" || "$MENU_RESULT" == "__back__" ]] && return 0

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
  printf -v pad '%*s' "$pad_len" ""

  printf '  %b│%b %b%s%b  %s%s%b│%b\n' \
    "${ACCENT}" "${RESET}" "${WHITE}" "$key" "${RESET}" "$val" "$pad" "${ACCENT}" "${RESET}"
}
