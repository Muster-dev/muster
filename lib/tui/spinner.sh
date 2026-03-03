#!/usr/bin/env bash
# muster/lib/tui/spinner.sh — Braille spinners

SPINNER_PID=""
_SPINNER_PREV_INT=""
_SPINNER_PREV_EXIT=""

start_spinner() {
  local msg="$1"
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  # Save existing traps before overwriting
  _SPINNER_PREV_INT=$(trap -p INT 2>/dev/null || true)
  _SPINNER_PREV_EXIT=$(trap -p EXIT 2>/dev/null || true)
  (
    i=0
    while true; do
      printf "\r  ${ACCENT}${frames[$i]}${RESET} ${DIM}%s${RESET}  " "$msg"
      i=$(( (i + 1) % ${#frames[@]} ))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null
  trap 'stop_spinner; exit 130' INT
  trap 'stop_spinner' EXIT
}

stop_spinner() {
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r\033[K"
  fi
  # Restore previous traps instead of clearing
  if [[ -n "${_SPINNER_PREV_INT:-}" ]]; then
    eval "$_SPINNER_PREV_INT"
  else
    trap - INT 2>/dev/null || true
  fi
  if [[ -n "${_SPINNER_PREV_EXIT:-}" ]]; then
    eval "$_SPINNER_PREV_EXIT"
  else
    trap - EXIT 2>/dev/null || true
  fi
  _SPINNER_PREV_INT=""
  _SPINNER_PREV_EXIT=""
}
