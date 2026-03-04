#!/usr/bin/env bash
# muster/lib/tui/menu.sh — Arrow-key interactive menu (bash 3.2+, macOS compatible)
# Uses tput cuu1 + tput ed for reliable in-place redraw (no tput sc/rc)
# Falls back to numbered input when MUSTER_MINIMAL=true

MENU_RESULT=""

# Read a single keypress (handles arrow key escape sequences)
_menu_read_key() {
  local key _rc=0
  if [[ "${MENU_TIMEOUT:-0}" -gt 0 ]]; then
    IFS= read -rsn1 -t "$MENU_TIMEOUT" key || _rc=$?
    if [[ "$_rc" -ne 0 && -z "$key" ]]; then
      REPLY="__timeout__"
      return
    fi
  else
    IFS= read -rsn1 key || true
  fi
  if [[ "$key" == $'\x1b' ]]; then
    local seq1 seq2
    IFS= read -rsn1 -t 1 seq1 || true
    IFS= read -rsn1 -t 1 seq2 || true
    key="${key}${seq1}${seq2}"
  fi
  REPLY="$key"
}

# Menu with description box that updates on selection change
# Usage: menu_select_desc "title" "label1" "desc1" "label2" "desc2" ...
# Descriptions appear below the options in a dim box
menu_select_desc() {
  if [[ ! -t 0 ]]; then
    printf '%b\n' "${RED}Error: interactive terminal required${RESET}" >&2
    return 1
  fi

  local title="$1"
  shift

  # Parse paired args into labels and descriptions
  local labels=()
  local descs=()
  while [[ $# -ge 2 ]]; do
    labels[${#labels[@]}]="$1"
    descs[${#descs[@]}]="$2"
    shift 2
  done
  local count=${#labels[@]}

  # Minimal mode fallback
  if [[ "$MUSTER_MINIMAL" == "true" ]]; then
    echo ""
    printf '  %s\n' "$title"
    local i=0
    while (( i < count )); do
      printf '    %d) %s\n' "$(( i + 1 ))" "${labels[$i]}"
      printf '       %b%s%b\n' "${DIM}" "${descs[$i]}" "${RESET}"
      i=$((i + 1))
    done
    printf '  Choose [1-%d]: ' "$count"
    local _choice
    read -r _choice
    _choice="${_choice:-1}"
    if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= count )); then
      MENU_RESULT="${labels[$(( _choice - 1 ))]}"
    else
      MENU_RESULT="${labels[0]}"
    fi
    return 0
  fi

  local selected=0
  local _menu_w=$(( TERM_COLS - 4 ))
  (( _menu_w > 50 )) && _menu_w=50
  (( _menu_w < 20 )) && _menu_w=20

  # Total lines = options + blank + desc (2 lines for desc box)
  local _total_lines=$(( count + 3 ))

  muster_tui_enter
  tput civis

  _msd_draw_header() {
    echo ""
    printf '  %b%s%b\n' "${BOLD}" "$title" "${RESET}"
  }

  _msd_draw() {
    local i=0
    while (( i < count )); do
      local label="${labels[$i]}"
      if (( i == selected )); then
        local text="  ▸ ${label}"
        local text_len=${#text}
        local bar_pad=$(( _menu_w - text_len ))
        (( bar_pad < 0 )) && bar_pad=0
        local pad
        printf -v pad '%*s' "$bar_pad" ""
        printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
      else
        printf '    %b%s%b\n' "${DIM}" "$label" "${RESET}"
      fi
      i=$((i + 1))
    done
    # Description box
    echo ""
    printf '  %b%s%b\n' "${DIM}" "${descs[$selected]}" "${RESET}"
    echo ""
  }

  _msd_clear() {
    (( _total_lines > 0 )) && printf '\033[%dA' "$_total_lines"
    printf '\033[J'
  }

  _msd_draw_header
  _msd_draw

  while true; do
    _menu_read_key

    if [[ "$_MUSTER_INPUT_DIRTY" == "true" ]]; then
      _MUSTER_INPUT_DIRTY="false"
      _menu_w=$(( TERM_COLS - 4 ))
      (( _menu_w > 50 )) && _menu_w=50
      (( _menu_w < 20 )) && _menu_w=20
      _msd_draw_header
      _msd_draw
      continue
    fi

    case "$REPLY" in
      "__timeout__")
        _msd_clear
        tput cnorm
        MENU_RESULT="__timeout__"
        return 0
        ;;
      $'\x1b[A')
        (( selected > 0 )) && selected=$((selected - 1))
        ;;
      $'\x1b[B')
        (( selected < count - 1 )) && selected=$((selected + 1))
        ;;
      $'\x1b'|'q'|'Q')
        _msd_clear
        tput cnorm
        MENU_RESULT="__back__"
        return 0
        ;;
      '')
        _msd_clear
        printf '  %b✓%b %s\n' "${GREEN}" "${RESET}" "${labels[$selected]}"
        tput cnorm
        # shellcheck disable=SC2034
        MENU_RESULT="${labels[$selected]}"
        return 0
        ;;
      *)
        continue
        ;;
    esac

    _msd_clear
    _msd_draw
  done
}

menu_select() {
  if [[ ! -t 0 ]]; then
    printf '%b\n' "${RED}Error: interactive terminal required${RESET}" >&2
    printf '%b\n' "Use flag-based setup instead: muster setup --help" >&2
    return 1
  fi

  local title="$1"
  shift
  local options=("$@")
  local count=${#options[@]}

  # ── Minimal mode: numbered choices ──
  if [[ "$MUSTER_MINIMAL" == "true" ]]; then
    echo ""
    printf '  %s\n' "$title"
    local i=0
    while (( i < count )); do
      printf '    %d) %s\n' "$(( i + 1 ))" "${options[$i]}"
      i=$((i + 1))
    done
    printf '  Choose [1-%d]: ' "$count"
    local _choice
    read -r _choice
    _choice="${_choice:-1}"
    # Validate
    if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= count )); then
      MENU_RESULT="${options[$(( _choice - 1 ))]}"
    else
      MENU_RESULT="${options[0]}"
    fi
    return 0
  fi

  # ── TUI mode: arrow-key selection ──
  local selected=0

  # Calculate bar width for highlighted selection
  local _menu_w=$(( TERM_COLS - 4 ))
  (( _menu_w > 50 )) && _menu_w=50
  (( _menu_w < 20 )) && _menu_w=20

  muster_tui_enter
  tput civis

  _menu_draw_header() {
    echo ""
    printf '  %b%s%b\n' "${BOLD}" "$title" "${RESET}"
  }

  _menu_draw() {
    local i=0
    while (( i < count )); do
      local label="${options[$i]}"
      if (( i == selected )); then
        # Highlighted bar: mustard bg, black text, full width
        local text="  ▸ ${label}"
        local text_len=${#text}
        local bar_pad=$(( _menu_w - text_len ))
        (( bar_pad < 0 )) && bar_pad=0
        local pad
        printf -v pad '%*s' "$bar_pad" ""
        printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
      else
        printf '    %b%s%b\n' "${DIM}" "$label" "${RESET}"
      fi
      i=$((i + 1))
    done
  }

  _menu_clear() {
    (( count > 0 )) && printf '\033[%dA' "$count"
    printf '\033[J'
  }

  _menu_draw_header
  _menu_draw

  while true; do
    _menu_read_key

    # If screen was cleared by resize, redraw everything immediately
    if [[ "$_MUSTER_INPUT_DIRTY" == "true" ]]; then
      _MUSTER_INPUT_DIRTY="false"
      # Recalculate bar width
      _menu_w=$(( TERM_COLS - 4 ))
      (( _menu_w > 50 )) && _menu_w=50
      (( _menu_w < 20 )) && _menu_w=20
      _menu_draw_header
      _menu_draw
      continue
    fi

    case "$REPLY" in
      "__timeout__")
        _menu_clear
        tput cnorm
        MENU_RESULT="__timeout__"
        return 0
        ;;
      $'\x1b[A')
        (( selected > 0 )) && selected=$((selected - 1))
        ;;
      $'\x1b[B')
        (( selected < count - 1 )) && selected=$((selected + 1))
        ;;
      $'\x1b'|'q'|'Q')
        _menu_clear
        tput cnorm
        MENU_RESULT="__back__"
        return 0
        ;;
      '')
        # Enter — collapse to selected choice
        _menu_clear
        printf '  %b✓%b %s\n' "${GREEN}" "${RESET}" "${options[$selected]}"
        tput cnorm
        # shellcheck disable=SC2034
        MENU_RESULT="${options[$selected]}"
        return 0
        ;;
      *)
        continue
        ;;
    esac

    _menu_clear
    _menu_draw
  done
}
