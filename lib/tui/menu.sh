#!/usr/bin/env bash
# muster/lib/tui/menu.sh — Arrow-key interactive menu (bash 3.2+, macOS compatible)
# Uses tput cuu1 + tput ed for reliable in-place redraw (no tput sc/rc)
# Falls back to numbered input when MUSTER_MINIMAL=true

MENU_RESULT=""

# Optional per-call settings (reset after each menu_select):
#   MENU_REMEMBER=key     remember the chosen label per project (.muster/.menu_state)
#                         and preselect it next time
#   MENU_NONTTY_HINT=txt  what to tell non-interactive callers (equivalent flag)
MENU_REMEMBER=""
MENU_NONTTY_HINT=""

# Explain that a prompt needs a terminal, pointing at the equivalent flag
_menu_need_tty() {
  local title="$1"
  printf '%b\n' "${RED}Error: \"${title}\" needs an interactive terminal.${RESET}" >&2
  printf '%s\n' "${MENU_NONTTY_HINT:-Run the command with flags instead (see its --help), e.g. muster deploy <service>.}" >&2
  MENU_NONTTY_HINT=""
}

# Per-project file that remembers picker choices
_menu_state_file() {
  [[ -n "${CONFIG_FILE:-}" && -f "${CONFIG_FILE:-}" ]] || return 1
  local d
  d="$(dirname "$CONFIG_FILE")/.muster"
  [[ -d "$d" ]] || return 1
  printf '%s/.menu_state' "$d"
}

# Remembered label for a key (echo)
_menu_recall() {
  local f
  f=$(_menu_state_file) || return 0
  [[ -f "$f" ]] || return 0
  awk -F'\t' -v k="$1" '$1 == k {v=$2} END {if (v != "") print v}' "$f" 2>/dev/null
}

_menu_remember() {
  local key="$1" val="$2" f
  [[ -z "$key" || "$val" == __* ]] && return 0
  f=$(_menu_state_file) || return 0
  { [[ -f "$f" ]] && awk -F'\t' -v k="$key" '$1 != k' "$f"; printf '%s\t%s\n' "$key" "$val"; } > "${f}.tmp" 2>/dev/null \
    && mv "${f}.tmp" "$f" 2>/dev/null
  return 0
}

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
    _menu_need_tty "$1"
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

  # Track actual drawn lines (updated after each draw)
  local _last_drawn_lines=0

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
    # Calculate how many terminal lines the description wraps to
    local _desc_visible_len=$(( 2 + ${#descs[$selected]} ))
    local _tw=${TERM_COLS:-80}
    (( _tw < 1 )) && _tw=80
    local _desc_wrap=$(( (_desc_visible_len + _tw - 1) / _tw ))
    (( _desc_wrap < 1 )) && _desc_wrap=1
    printf '  %b%s%b\n' "${DIM}" "${descs[$selected]}" "${RESET}"
    echo ""
    # options + blank + desc wrapped lines + trailing blank
    _last_drawn_lines=$(( count + 1 + _desc_wrap + 1 ))
  }

  _msd_clear() {
    (( _last_drawn_lines > 0 )) && printf '\033[%dA' "$_last_drawn_lines"
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
    _menu_need_tty "$1"
    MENU_REMEMBER=""
    return 1
  fi

  local title="$1"
  shift
  local options=()
  (( $# > 0 )) && options=("$@")
  local count=${#options[@]}

  # Empty state instead of a blank menu
  if (( count == 0 )); then
    echo ""
    printf '  %b%s%b\n' "${BOLD}" "$title" "${RESET}"
    printf '  %bNothing to choose from here yet.%b\n' "${DIM}" "${RESET}"
    MENU_RESULT="__back__"
    MENU_REMEMBER=""
    return 0
  fi

  # Remembered choice (per project) becomes the default
  local _remember_key="$MENU_REMEMBER"
  MENU_REMEMBER=""
  local selected=0
  if [[ -n "$_remember_key" ]]; then
    local _prev _ri=0
    _prev=$(_menu_recall "$_remember_key")
    while [[ -n "$_prev" ]] && (( _ri < count )); do
      if [[ "${options[$_ri]}" == "$_prev" ]]; then selected=$_ri; break; fi
      _ri=$(( _ri + 1 ))
    done
  fi

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
    _choice="${_choice:-$(( selected + 1 ))}"
    case "$_choice" in q|Q) MENU_RESULT="__back__"; return 0 ;; esac
    # Validate
    if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= count )); then
      MENU_RESULT="${options[$(( _choice - 1 ))]}"
    else
      MENU_RESULT="${options[$selected]}"
    fi
    _menu_remember "$_remember_key" "$MENU_RESULT"
    return 0
  fi

  # ── TUI mode: arrow-key selection ──

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
    # Keep each option on one line so redraws stay aligned on narrow terminals
    local _maxl=$(( TERM_COLS - 6 ))
    (( _maxl < 8 )) && _maxl=8
    while (( i < count )); do
      local label="${options[$i]}"
      (( ${#label} > _maxl )) && label="${label:0:$(( _maxl - 3 ))}..."
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
        _menu_remember "$_remember_key" "$MENU_RESULT"
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
