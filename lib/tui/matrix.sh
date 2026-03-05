#!/usr/bin/env bash
# muster/lib/tui/matrix.sh — LED dot-matrix display splash (airport board style)

_matrix_splash() {
  # Skip animation entirely in minimal mode
  if [[ "${MUSTER_MINIMAL:-false}" == "true" ]]; then
    return 0
  fi

  local cols=${TERM_COLS:-$(tput cols 2>/dev/null || echo 80)}

  # ── 5-row dot-matrix font for M U S T E R ──
  # Each letter is 5 cols wide; '#' = on, '.' = off
  local M0="#...#" M1="##.##" M2="#.#.#" M3="#...#" M4="#...#"
  local U0="#...#" U1="#...#" U2="#...#" U3="#...#" U4=".###."
  local S0=".####" S1="#...." S2=".###." S3="....#" S4="####."
  local T0="#####" T1="..#.." T2="..#.." T3="..#.." T4="..#.."
  local E0="#####" E1="#...." E2="####." E3="#...." E4="#####"
  local R0="####." R1="#...#" R2="####." R3="#..#." R4="#...#"

  # Full banner rows: "MUSTER" with 1-col gaps (35 cols total)
  local r0="${M0} ${U0} ${S0} ${T0} ${E0} ${R0}"
  local r1="${M1} ${U1} ${S1} ${T1} ${E1} ${R1}"
  local r2="${M2} ${U2} ${S2} ${T2} ${E2} ${R2}"
  local r3="${M3} ${U3} ${S3} ${T3} ${E3} ${R3}"
  local r4="${M4} ${U4} ${S4} ${T4} ${E4} ${R4}"

  local text_w=${#r0}  # 35
  local display_h=5

  # Hide cursor, save trap state
  tput civis 2>/dev/null
  local _mprev_int
  _mprev_int=$(trap -p INT 2>/dev/null || true)
  trap 'tput cnorm 2>/dev/null; if [[ -n "$_mprev_int" ]]; then eval "$_mprev_int"; else trap - INT 2>/dev/null || true; fi; return 130' INT

  # Cache cursor-up sequence
  local cuu1
  cuu1=$(tput cuu1 2>/dev/null || printf '\033[A')

  # Reserve animation area (5 rows)
  local i=0
  while [[ $i -lt $display_h ]]; do
    printf '\n'
    i=$(( i + 1 ))
  done

  # Calculate center position for final resting place
  local center=$(( (cols - text_w) / 2 ))
  if [[ $center -lt 0 ]]; then center=0; fi

  # Scroll speed: step through positions to keep ~12 frames for scroll-in
  local scroll_in_dist=$(( cols - center ))
  local step=$(( scroll_in_dist / 12 ))
  if [[ $step -lt 1 ]]; then step=1; fi

  local offset=$cols
  local phase="scroll_in"
  local hold_count=0

  while true; do
    local buf=""

    # Move cursor up to top of animation area
    i=0
    while [[ $i -lt $display_h ]]; do
      buf="${buf}${cuu1}"
      i=$(( i + 1 ))
    done

    # Render each of the 5 rows
    local row=0
    while [[ $row -lt $display_h ]]; do
      buf="${buf}\r\033[K"

      # Pick the source row
      local src=""
      case $row in
        0) src="$r0" ;; 1) src="$r1" ;; 2) src="$r2" ;;
        3) src="$r3" ;; 4) src="$r4" ;;
      esac

      # Calculate visible slice of the text within the display
      local vis_start=0
      local vis_end=$text_w
      local text_screen_start=$offset

      # Clip to screen bounds
      if [[ $text_screen_start -lt 0 ]]; then
        vis_start=$(( -text_screen_start ))
        text_screen_start=0
      fi
      local text_screen_end=$(( offset + text_w ))
      if [[ $text_screen_end -gt $cols ]]; then
        vis_end=$(( text_w - (text_screen_end - cols) ))
      fi

      if [[ $vis_start -lt $vis_end ]]; then
        # Extract the visible slice
        local slice="${src:$vis_start:$((vis_end - vis_start))}"

        # Build the colored line: pad to text_screen_start, then render slice
        if [[ $text_screen_start -gt 0 ]]; then
          buf="${buf}\033[${text_screen_start}C"
        fi

        # Render each character in the visible slice with color
        local ci=0
        local slice_len=${#slice}
        while [[ $ci -lt $slice_len ]]; do
          local ch="${slice:$ci:1}"
          if [[ "$ch" == "#" ]]; then
            buf="${buf}${ACCENT}${BOLD}#${RESET}"
          elif [[ "$ch" == "." ]]; then
            buf="${buf}${DIM}.${RESET}"
          else
            buf="${buf} "
          fi
          ci=$(( ci + 1 ))
        done
      fi

      buf="${buf}\n"
      row=$(( row + 1 ))
    done

    printf '%b' "$buf"

    # Advance animation state
    case "$phase" in
      scroll_in)
        offset=$(( offset - step ))
        if [[ $offset -le $center ]]; then
          offset=$center
          phase="hold"
          hold_count=0
        fi
        sleep 0.07
        ;;
      hold)
        hold_count=$(( hold_count + 1 ))
        if [[ $hold_count -ge 8 ]]; then
          phase="scroll_out"
        fi
        sleep 0.1
        ;;
      scroll_out)
        offset=$(( offset - step ))
        if [[ $offset -lt $(( -text_w )) ]]; then
          break
        fi
        sleep 0.07
        ;;
    esac
  done

  # Clear animation area
  i=0
  while [[ $i -lt $display_h ]]; do
    printf '%s' "$cuu1"
    i=$(( i + 1 ))
  done
  tput ed 2>/dev/null

  # Restore cursor and traps
  tput cnorm 2>/dev/null
  if [[ -n "$_mprev_int" ]]; then
    eval "$_mprev_int"
  else
    trap - INT 2>/dev/null || true
  fi
}
