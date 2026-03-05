#!/usr/bin/env bash
# muster/lib/tui/checklist.sh — Toggle checklist (bash 3.2+, macOS compatible)
# Uses tput cuu1 + tput ed for reliable in-place redraw
# Falls back to numbered input when MUSTER_MINIMAL=true

CHECKLIST_RESULT=""

# Grouped checklist — items prefixed with "---:" are non-selectable group headers
# Example: checklist_grouped_select "title" "---:Server A" "svc1" "svc2" "---:Server B" "svc3"
# CHECKLIST_RESULT returns newline-separated selected items (without headers)
checklist_grouped_select() {
  if [[ ! -t 0 ]]; then
    printf '%b\n' "${RED}Error: interactive terminal required${RESET}" >&2
    return 1
  fi

  local title="$1"
  shift
  local items=("$@")
  local count=${#items[@]}

  # Track which items are headers (non-selectable)
  local is_header=()
  local i=0
  while (( i < count )); do
    if [[ "${items[$i]}" == "---:"* ]]; then
      is_header[$i]=1
    else
      is_header[$i]=0
    fi
    i=$(( i + 1 ))
  done

  # ── Minimal mode ──
  if [[ "$MUSTER_MINIMAL" == "true" ]]; then
    echo ""
    printf '  %s\n' "$title"
    i=0
    local _num=0
    while (( i < count )); do
      if (( is_header[i] == 1 )); then
        printf '    %s\n' "${items[$i]#---:}"
      else
        _num=$(( _num + 1 ))
        printf '    %d) [x] %s\n' "$_num" "${items[$i]}"
      fi
      i=$(( i + 1 ))
    done
    echo ""
    printf '  Enter numbers to deselect (comma-separated), or Enter for all: '
    local _input; read -r _input

    local checked=()
    i=0
    while (( i < count )); do checked[$i]=1; i=$(( i + 1 )); done

    if [[ -n "$_input" ]]; then
      local _num_val _old_ifs="$IFS"
      IFS=','
      for _num_val in $_input; do
        IFS="$_old_ifs"
        _num_val="${_num_val// /}"
        if [[ "$_num_val" =~ ^[0-9]+$ ]]; then
          # Map display number to array index
          local _mi=0 _mn=0
          while (( _mi < count )); do
            if (( is_header[_mi] == 0 )); then
              _mn=$(( _mn + 1 ))
              if (( _mn == _num_val )); then
                checked[$_mi]=0
                break
              fi
            fi
            _mi=$(( _mi + 1 ))
          done
        fi
      done
      IFS="$_old_ifs"
    fi

    CHECKLIST_RESULT=""
    i=0
    while (( i < count )); do
      if (( is_header[i] == 0 && checked[i] == 1 )); then
        if [[ -n "$CHECKLIST_RESULT" ]]; then
          CHECKLIST_RESULT="${CHECKLIST_RESULT}"$'\n'"${items[$i]}"
        else
          CHECKLIST_RESULT="${items[$i]}"
        fi
      fi
      i=$(( i + 1 ))
    done
    return 0
  fi

  # ── TUI mode ──
  # Find first selectable item
  local selected=0
  i=0
  while (( i < count )); do
    if (( is_header[i] == 0 )); then
      selected=$i
      break
    fi
    i=$(( i + 1 ))
  done

  local checked=()
  i=0
  while (( i < count )); do
    if (( is_header[i] == 1 )); then
      checked[$i]=0
    else
      checked[$i]=1
    fi
    i=$(( i + 1 ))
  done

  local _cl_w=$(( TERM_COLS - 4 ))
  (( _cl_w > 56 )) && _cl_w=56
  (( _cl_w < 20 )) && _cl_w=20

  muster_tui_enter
  tput civis

  _gcl_draw_header() {
    echo ""
    printf '  %b%s%b\n' "${BOLD}" "$title" "${RESET}"
    printf '  %b↑/↓ navigate  ␣ toggle  ⏎ confirm  q back%b\n' "${DIM}" "${RESET}"
  }

  local total_lines=$count

  _gcl_draw() {
    _cl_w=$(( TERM_COLS - 4 ))
    (( _cl_w > 56 )) && _cl_w=56
    (( _cl_w < 20 )) && _cl_w=20

    local i=0
    while (( i < count )); do
      if (( is_header[i] == 1 )); then
        # Group header — non-selectable separator
        local hlabel="${items[$i]#---:}"
        if (( i == selected )); then
          printf '  %b%b── %s ──%b\n' "${BOLD}" "${ACCENT}" "$hlabel" "${RESET}"
        else
          printf '  %b── %s ──%b\n' "${DIM}" "$hlabel" "${RESET}"
        fi
      else
        local mark="○" mcolor="${GRAY}"
        if (( checked[i] == 1 )); then
          mark="✓"
          mcolor="${GREEN}"
        fi
        local label="${items[$i]}"
        if (( i == selected )); then
          local text="  ▸ ${mark} ${label}"
          local text_len=${#text}
          local bar_pad=$(( _cl_w - text_len ))
          (( bar_pad < 0 )) && bar_pad=0
          local pad
          printf -v pad '%*s' "$bar_pad" ""
          printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
        else
          printf '      %b%s%b %s\n' "$mcolor" "$mark" "${RESET}" "$label"
        fi
      fi
      i=$(( i + 1 ))
    done
  }

  _gcl_clear() {
    (( total_lines > 0 )) && printf '\033[%dA' "$total_lines"
    printf '\033[J'
  }

  _gcl_read_key() {
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

  # Skip to next selectable item in direction (1=down, -1=up)
  _gcl_skip() {
    local dir="$1" cur="$selected"
    while true; do
      cur=$(( cur + dir ))
      (( cur < 0 || cur >= count )) && return
      if (( is_header[cur] == 0 )); then
        selected=$cur
        return
      fi
    done
  }

  _gcl_draw_header
  _gcl_draw

  while true; do
    _gcl_read_key

    if [[ "$_MUSTER_INPUT_DIRTY" == "true" ]]; then
      _MUSTER_INPUT_DIRTY="false"
      _gcl_draw_header
      _gcl_draw
      continue
    fi

    case "$REPLY" in
      $'\x1b[A')
        _gcl_skip -1
        ;;
      $'\x1b[B')
        _gcl_skip 1
        ;;
      ' ')
        if (( is_header[selected] == 0 )); then
          if (( checked[selected] == 1 )); then
            checked[$selected]=0
          else
            checked[$selected]=1
          fi
        fi
        ;;
      $'\x1b'|'q'|'Q')
        _gcl_clear
        tput cnorm
        CHECKLIST_RESULT="__back__"
        return 0
        ;;
      '')
        _gcl_clear
        # Print summary
        i=0
        while (( i < count )); do
          if (( is_header[i] == 1 )); then
            printf '  %b── %s ──%b\n' "${DIM}" "${items[$i]#---:}" "${RESET}"
          elif (( checked[i] == 1 )); then
            printf '    %b✓%b %s\n' "${GREEN}" "${RESET}" "${items[$i]}"
          fi
          i=$(( i + 1 ))
        done

        tput cnorm

        CHECKLIST_RESULT=""
        i=0
        while (( i < count )); do
          if (( is_header[i] == 0 && checked[i] == 1 )); then
            if [[ -n "$CHECKLIST_RESULT" ]]; then
              CHECKLIST_RESULT="${CHECKLIST_RESULT}"$'\n'"${items[$i]}"
            else
              CHECKLIST_RESULT="${items[$i]}"
            fi
          fi
          i=$(( i + 1 ))
        done
        return 0
        ;;
      *)
        continue
        ;;
    esac

    _gcl_clear
    _gcl_draw
  done
}

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

  # ── Minimal mode: numbered choices ──
  if [[ "$MUSTER_MINIMAL" == "true" ]]; then
    echo ""
    printf '  %s\n' "$title"
    local i=0
    while (( i < count )); do
      local _mark="x"
      (( _cl_default == 0 )) && _mark=" "
      printf '    %d) [%s] %s\n' "$(( i + 1 ))" "$_mark" "${items[$i]}"
      i=$((i + 1))
    done
    echo ""
    if (( _cl_default == 1 )); then
      printf '  Enter numbers to deselect (comma-separated), or Enter for all: '
    else
      printf '  Enter numbers to select (comma-separated), or "all": '
    fi
    local _input
    read -r _input

    # Build checked array
    local checked=()
    i=0
    while (( i < count )); do checked[$i]=$_cl_default; i=$((i + 1)); done

    if [[ -n "$_input" ]]; then
      if [[ "$_input" == "all" ]]; then
        i=0
        while (( i < count )); do checked[$i]=1; i=$((i + 1)); done
      elif [[ "$_input" == "none" ]]; then
        i=0
        while (( i < count )); do checked[$i]=0; i=$((i + 1)); done
      else
        # Toggle the specified numbers
        local _num
        local _old_ifs="$IFS"
        IFS=','
        for _num in $_input; do
          IFS="$_old_ifs"
          _num="${_num// /}"
          if [[ "$_num" =~ ^[0-9]+$ ]] && (( _num >= 1 && _num <= count )); then
            if (( _cl_default == 1 )); then
              checked[$(( _num - 1 ))]=0
            else
              checked[$(( _num - 1 ))]=1
            fi
          fi
        done
        IFS="$_old_ifs"
      fi
    fi

    # Build result
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
  fi

  # ── TUI mode: arrow-key toggle ──
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
    printf '  %b↑/↓ navigate  ␣ toggle  ⏎ confirm  q back%b\n' "${DIM}" "${RESET}"
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
        printf -v pad '%*s' "$bar_pad" ""
        printf '\033[48;5;178m\033[38;5;0m%s%s\033[0m\n' "$text" "$pad"
      else
        printf '    %b%s%b %s\n' "$mcolor" "$mark" "${RESET}" "$label"
      fi
      i=$((i + 1))
    done
  }

  _cl_clear() {
    (( total_lines > 0 )) && printf '\033[%dA' "$total_lines"
    printf '\033[J'
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
      $'\x1b'|'q'|'Q')
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
