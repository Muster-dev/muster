#!/usr/bin/env bash
# muster/lib/tui/checklist.sh — Toggle checklist (bash 3.2+, macOS compatible)
# Uses tput cuu1 + tput ed for reliable in-place redraw

CHECKLIST_RESULT=""

checklist_select() {
  if [[ ! -t 0 ]]; then
    printf '%b\n' "${RED}Error: interactive terminal required${RESET}" >&2
    printf '%b\n' "Use flag-based setup instead: muster setup --help" >&2
    return 1
  fi

  local _cl_default=1
  if [[ "${1:-}" == "--none" ]]; then
    _cl_default=0
    shift
  fi

  local title="$1"
  shift
  local items=("$@")
  local count=${#items[@]}
  local selected=0
  local checked=()

  local i=0
  while (( i < count )); do checked[$i]=$_cl_default; i=$((i + 1)); done

  # Bar width for highlighted selection
  local _cl_w=$(( TERM_COLS - 4 ))
  (( _cl_w > 50 )) && _cl_w=50
  (( _cl_w < 20 )) && _cl_w=20

  muster_tui_enter
  tput civis

  _cl_draw_header() {
    echo ""
    printf '  %b%s%b\n' "${BOLD}" "$title" "${RESET}"
    printf '  %b↑/↓ navigate  ␣ toggle  ⏎ confirm  esc back%b\n' "${DIM}" "${RESET}"
  }

  # Lines to clear = count + 1 (help text line merged into header area)
  local total_lines=$((count))

  _cl_draw() {
    _cl_w=$(( TERM_COLS - 4 ))
    (( _cl_w > 50 )) && _cl_w=50
    (( _cl_w < 20 )) && _cl_w=20

    local i=0
    while (( i < count )); do
      local mark="○"
      local mcolor="${GRAY}"
      if (( checked[i] == 1 )); then
        mark="✓"
        mcolor="${GREEN}"
      fi

      local label="${items[$i]}"

      if (( i == selected )); then
        # Highlighted bar: mustard bg, black text
        local text="  ▸ ${mark} ${label}"
        local text_len=${#text}
        local bar_pad=$(( _cl_w - text_len ))
        (( bar_pad < 0 )) && bar_pad=0
        local pad
        pad=$(printf '%*s' "$bar_pad" "")
        printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
      else
        printf '    %b%s%b %s\n' "$mcolor" "$mark" "${RESET}" "$label"
      fi
      i=$((i + 1))
    done
  }

  _cl_clear() {
    local i=0
    while (( i < total_lines )); do
      tput cuu1
      i=$((i + 1))
    done
    tput ed
  }

  _cl_read_key() {
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

  _cl_draw_header
  _cl_draw

  while true; do
    _cl_read_key

    # If screen was cleared by resize, redraw everything immediately
    if [[ "$_MUSTER_INPUT_DIRTY" == "true" ]]; then
      _MUSTER_INPUT_DIRTY="false"
      _cl_w=$(( TERM_COLS - 4 ))
      (( _cl_w > 50 )) && _cl_w=50
      (( _cl_w < 20 )) && _cl_w=20
      _cl_draw_header
      _cl_draw
      continue
    fi

    case "$REPLY" in
      $'\x1b[A')
        (( selected > 0 )) && selected=$((selected - 1))
        ;;
      $'\x1b[B')
        (( selected < count - 1 )) && selected=$((selected + 1))
        ;;
      ' ')
        if (( checked[selected] == 1 )); then
          checked[$selected]=0
        else
          checked[$selected]=1
        fi
        ;;
      $'\x1b')
        _cl_clear
        tput cnorm
        CHECKLIST_RESULT="__back__"
        return 0
        ;;
      '')
        _cl_clear
        i=0
        while (( i < count )); do
          if (( checked[i] == 1 )); then
            printf '  %b✓%b %s\n' "${GREEN}" "${RESET}" "${items[$i]}"
          fi
          i=$((i + 1))
        done

        tput cnorm

        CHECKLIST_RESULT=""
        i=0
        while (( i < count )); do
          if (( checked[i] == 1 )); then
            if [[ -n "$CHECKLIST_RESULT" ]]; then
              CHECKLIST_RESULT="${CHECKLIST_RESULT}"$'\n'"${items[$i]}"
            else
              CHECKLIST_RESULT="${items[$i]}"
            fi
          fi
          i=$((i + 1))
        done
        return 0
        ;;
      *)
        continue
        ;;
    esac

    _cl_clear
    _cl_draw
  done
}
