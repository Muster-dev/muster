#!/usr/bin/env bash
# muster/lib/tui/menu.sh — Arrow-key interactive menu (bash 3.2+, macOS compatible)
# Uses tput cuu1 + tput ed for reliable in-place redraw (no tput sc/rc)

MENU_RESULT=""

menu_select() {
  if [[ ! -t 0 ]]; then
    printf '%b\n' "${RED}Error: interactive terminal required${RESET}" >&2
    printf '%b\n' "Use flag-based setup instead: muster setup --help" >&2
    return 1
  fi

  local title="$1"
  shift
  local options=("$@")
  local selected=0
  local count=${#options[@]}

  muster_tui_enter
  tput civis

  _menu_draw_header() {
    echo ""
    echo -e "  ${BOLD}${title}${RESET}"
    echo ""
  }

  _menu_draw() {
    local i=0
    while (( i < count )); do
      if (( i == selected )); then
        echo -e "  ${ACCENT}> ${options[$i]}${RESET}"
      else
        echo -e "    ${DIM}${options[$i]}${RESET}"
      fi
      i=$((i + 1))
    done
  }

  _menu_clear() {
    local i=0
    while (( i < count )); do
      tput cuu1
      i=$((i + 1))
    done
    tput ed
  }

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

  _menu_draw_header
  _menu_draw

  while true; do
    _menu_read_key

    # If screen was cleared by resize, redraw everything immediately
    if [[ "$_MUSTER_INPUT_DIRTY" == "true" ]]; then
      _MUSTER_INPUT_DIRTY="false"
      _menu_draw_header
      _menu_draw
      continue
    fi

    case "$REPLY" in
      "__timeout__")
        # Timeout — return for caller to refresh
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
      $'\x1b')
        # Bare Escape — go back
        _menu_clear
        tput cnorm
        MENU_RESULT="__back__"
        return 0
        ;;
      '')
        # Enter — collapse to selected choice
        _menu_clear
        echo -e "  ${GREEN}*${RESET} ${options[$selected]}"
        tput cnorm
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
