#!/usr/bin/env bash
# muster/lib/tui/order.sh — Reorderable list (bash 3.2+)
# Arrow keys navigate, Enter grabs/drops, q confirms

ORDER_RESULT=()

order_select() {
  if [[ ! -t 0 ]]; then
    printf '%b\n' "${RED}Error: interactive terminal required${RESET}" >&2
    printf '%b\n' "Use flag-based setup instead: muster setup --help" >&2
    return 1
  fi

  local title="$1"
  shift
  local items=("$@")
  local count=${#items[@]}
  local selected=0
  local grabbed=-1  # -1 = nothing grabbed

  local _ord_w=$(( TERM_COLS - 4 ))
  (( _ord_w > 50 )) && _ord_w=50
  (( _ord_w < 20 )) && _ord_w=20

  muster_tui_enter
  tput civis

  _ord_draw_header() {
    echo ""
    printf '  %b%s%b\n' "${BOLD}" "$title" "${RESET}"
    if (( grabbed >= 0 )); then
      printf '  %b↑/↓ move item  ⏎ drop  q done%b\n' "${DIM}" "${RESET}"
    else
      printf '  %b↑/↓ navigate  ⏎ grab  q done%b\n' "${DIM}" "${RESET}"
    fi
  }

  _ord_draw() {
    _ord_w=$(( TERM_COLS - 4 ))
    (( _ord_w > 50 )) && _ord_w=50
    (( _ord_w < 20 )) && _ord_w=20

    local i=0
    while (( i < count )); do
      local label="${items[$i]}"
      local num=$((i + 1))

      if (( i == selected && grabbed >= 0 )); then
        # Grabbed and selected — bright highlight bar
        local text="  ✦ ${num}. ${label}"
        local text_len=${#text}
        local bar_pad=$(( _ord_w - text_len ))
        (( bar_pad < 0 )) && bar_pad=0
        local pad
        pad=$(printf '%*s' "$bar_pad" "")
        printf '\033[48;5;220m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
      elif (( i == selected )); then
        # Selected — mustard highlight bar
        local text="  ▸ ${num}. ${label}"
        local text_len=${#text}
        local bar_pad=$(( _ord_w - text_len ))
        (( bar_pad < 0 )) && bar_pad=0
        local pad
        pad=$(printf '%*s' "$bar_pad" "")
        printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
      elif (( i == grabbed )); then
        printf '    %b%s. %b%s%b\n' "${DIM}" "$num" "${ACCENT_BRIGHT}" "$label" "${RESET}"
      else
        printf '    %b%s.%b %s\n' "${DIM}" "$num" "${RESET}" "$label"
      fi
      i=$((i + 1))
    done
  }

  local total_lines=$((count))

  _ord_clear() {
    local i=0
    while (( i < total_lines )); do
      tput cuu1
      i=$((i + 1))
    done
    tput ed
  }

  _ord_read_key() {
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

  _ord_swap() {
    local a="$1" b="$2"
    local tmp="${items[$a]}"
    items[$a]="${items[$b]}"
    items[$b]="$tmp"
  }

  _ord_draw_header
  _ord_draw

  while true; do
    _ord_read_key

    if [[ "$_MUSTER_INPUT_DIRTY" == "true" ]]; then
      _MUSTER_INPUT_DIRTY="false"
      _ord_draw_header
      _ord_draw
      continue
    fi

    case "$REPLY" in
      $'\x1b[A')
        if (( grabbed >= 0 && selected > 0 )); then
          _ord_swap "$selected" "$((selected - 1))"
          grabbed=$((selected - 1))
          selected=$((selected - 1))
        elif (( grabbed < 0 && selected > 0 )); then
          selected=$((selected - 1))
        fi
        ;;
      $'\x1b[B')
        if (( grabbed >= 0 && selected < count - 1 )); then
          _ord_swap "$selected" "$((selected + 1))"
          grabbed=$((selected + 1))
          selected=$((selected + 1))
        elif (( grabbed < 0 && selected < count - 1 )); then
          selected=$((selected + 1))
        fi
        ;;
      'q'|'Q')
        _ord_clear
        tput cnorm
        local i=0
        while (( i < count )); do
          printf '  %b✓%b %b%s.%b %s\n' "${GREEN}" "${RESET}" "${DIM}" "$((i + 1))" "${RESET}" "${items[$i]}"
          i=$((i + 1))
        done
        ORDER_RESULT=("${items[@]}")
        return 0
        ;;
      '')
        if (( grabbed >= 0 )); then
          grabbed=-1
        else
          grabbed=$selected
        fi
        ;;
      *)
        continue
        ;;
    esac

    _ord_clear
    _ord_draw
  done
}
