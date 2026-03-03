#!/usr/bin/env bash
# muster/lib/tui/progress.sh — Progress bars

progress_bar() {
  local current=$1
  local total=$2
  local label="${3:-}"
  local state="${4:-}"
  local bar_width=$(( TERM_COLS - 16 ))
  (( bar_width > 50 )) && bar_width=50
  (( bar_width < 10 )) && bar_width=10

  local pct=0
  (( total > 0 )) && pct=$(( current * 100 / total ))
  local filled=$(( pct * bar_width / 100 ))
  local empty=$(( bar_width - filled ))

  # Build bar using background-colored spaces
  local bar_filled=""
  local bar_empty=""
  local _fi=0
  while (( _fi < filled )); do bar_filled="${bar_filled} "; _fi=$((_fi+1)); done
  local _ei=0
  while (( _ei < empty )); do bar_empty="${bar_empty} "; _ei=$((_ei+1)); done

  # Mustard fill, dark gray track — red on error
  local _bg_fill='\033[48;5;178m'
  local _bg_empty='\033[48;5;236m'
  if [[ "$state" == "error" ]]; then
    _bg_fill='\033[48;5;160m'
    _bg_empty='\033[48;5;52m'
  fi

  local counter="${current}/${total}"

  printf '\r  %b%s%b%b%s%b %b%s%b  %b%s%b' \
    "$_bg_fill" "$bar_filled" "$RESET" \
    "$_bg_empty" "$bar_empty" "$RESET" \
    "${DIM}" "$counter" "${RESET}" \
    "${WHITE}" "$label" "${RESET}"
}
