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

  muster_tui_enter
  tput civis

  _cl_draw_header() {
    echo ""
    echo -e "  ${BOLD}${title}${RESET}"
    echo -e "  ${DIM}↑/↓ navigate  ␣ toggle  ⏎ confirm  esc back${RESET}"
    echo ""
  }

  _cl_calc_width() {
    _cl_w=$(( TERM_COLS - 4 ))
    (( _cl_w > 50 )) && _cl_w=50
    (( _cl_w < 10 )) && _cl_w=10
    _cl_inner=$(( _cl_w - 2 ))
    _cl_border=$(printf '%*s' "$_cl_w" "" | sed 's/ /─/g')
  }

  _cl_calc_width
  local total_lines=$((count + 2))

  _cl_draw() {
    _cl_calc_width
    printf '  %b┌%s┐%b\n' "${ACCENT}" "$_cl_border" "${RESET}"
    local i=0
    while (( i < count )); do
      local mark="✓"
      local mcolor="${GREEN}"
      if (( checked[i] == 0 )); then
        mark=" "
        mcolor="${DIM}"
      fi

      local label="${items[$i]}"
      local prefix
      if (( i == selected )); then
        prefix="> "
      else
        prefix="  "
      fi

      local max_label=$(( _cl_inner - 6 ))
      (( max_label < 3 )) && max_label=3
      if (( ${#label} > max_label )); then
        label="${label:0:$((max_label - 3))}..."
      fi

      local content_len=$(( 6 + ${#label} ))
      local pad_len=$(( _cl_inner - content_len ))
      (( pad_len < 0 )) && pad_len=0
      local pad
      pad=$(printf '%*s' "$pad_len" "")

      if (( i == selected )); then
        printf '  %b│%b %b%s[%b%s%b%b] %s%b%s%b│%b\n' \
          "${ACCENT}" "${RESET}" "${ACCENT}" "$prefix" "$mcolor" "$mark" "${RESET}" "${ACCENT}" "$label" "${RESET}" "$pad" "${ACCENT}" "${RESET}"
      else
        printf '  %b│%b %s[%b%s%b] %s%s%b│%b\n' \
          "${ACCENT}" "${RESET}" "$prefix" "$mcolor" "$mark" "${RESET}" "$label" "$pad" "${ACCENT}" "${RESET}"
      fi
      i=$((i + 1))
    done
    printf '  %b└%s┘%b\n' "${ACCENT}" "$_cl_border" "${RESET}"
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
        # Bare Escape — go back
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
            echo -e "  ${GREEN}*${RESET} ${items[$i]}"
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
