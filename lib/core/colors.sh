#!/usr/bin/env bash
# muster/lib/core/colors.sh — Terminal colors and styling

BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Mustard accent — the muster brand color
MUSTARD='\033[38;5;178m'
MUSTARD_BRIGHT='\033[38;5;220m'
MUSTARD_DIM='\033[38;5;136m'

GREEN='\033[38;5;114m'
RED='\033[38;5;203m'
YELLOW='\033[38;5;221m'
GRAY='\033[38;5;243m'
WHITE='\033[38;5;255m'
BLUE='\033[38;5;75m'
MAGENTA='\033[38;5;176m'

# Accent alias — used throughout the TUI
ACCENT="$MUSTARD"
ACCENT_BRIGHT="$MUSTARD_BRIGHT"

# ── Apply color_mode from global settings ──
# Read directly (config.sh may not be sourced yet, and we must avoid circular deps)
_muster_color_mode=""
if [[ -f "$HOME/.muster/settings.json" ]]; then
  if command -v jq &>/dev/null; then
    _muster_color_mode=$(jq -r '.color_mode // "auto"' "$HOME/.muster/settings.json" 2>/dev/null)
  elif command -v python3 &>/dev/null; then
    _muster_color_mode=$(python3 -c "
import json
with open('$HOME/.muster/settings.json') as f:
    print(json.load(f).get('color_mode', 'auto'))
" 2>/dev/null)
  fi
fi

# MUSTER_ANSI=true when escape sequences (colors, cursor movement, redrawing
# progress bars) may be written to stdout. Set to false when colors are off so
# TUI widgets can fall back to plain line-oriented output.
# shellcheck disable=SC2034
MUSTER_ANSI=true

_muster_apply_color_mode() {
  local mode="$1"
  local want_color=true

  # https://no-color.org — any non-empty NO_COLOR disables color, unless the
  # user explicitly forced color_mode=always.
  if [[ -n "${NO_COLOR:-}" && "$mode" != "always" ]]; then
    mode="never"
  fi

  case "$mode" in
    never)
      want_color=false
      ;;
    always)
      want_color=true
      ;;
    *)
      # auto: FORCE_COLOR wins; CI logs get plain text; otherwise only on a TTY
      case "${FORCE_COLOR:-}" in
        ""|0|false|no) ;;
        *) return 0 ;;
      esac
      if [[ ! -t 1 ]]; then
        want_color=false
      elif [[ "${GITHUB_ACTIONS:-}" == "true" || "${CI:-}" == "true" || "${CI:-}" == "1" ]]; then
        want_color=false
      fi
      ;;
  esac

  # shellcheck disable=SC2034
  if [[ "$want_color" == "false" ]]; then
    MUSTER_ANSI=false
    BOLD=""
    DIM=""
    RESET=""
    MUSTARD=""
    MUSTARD_BRIGHT=""
    MUSTARD_DIM=""
    GREEN=""
    RED=""
    YELLOW=""
    GRAY=""
    WHITE=""
    BLUE=""
    MAGENTA=""
    ACCENT=""
    ACCENT_BRIGHT=""
  fi
}

_muster_apply_color_mode "${_muster_color_mode:-auto}"
unset _muster_color_mode
