#!/usr/bin/env bash
# muster/lib/core/suggest.sh — "Did you mean …?" for commands, flags and
# service names. Plain edit distance, bash 3.2 compatible.

# Levenshtein distance between two strings (echo)
_suggest_distance() {
  local a="$1" b="$2"
  local la=${#a} lb=${#b} i j cost del ins sub m
  local prev=() cur=()
  for (( j = 0; j <= lb; j++ )); do prev[$j]=$j; done
  for (( i = 1; i <= la; i++ )); do
    cur=()
    cur[0]=$i
    local ca="${a:i-1:1}"
    for (( j = 1; j <= lb; j++ )); do
      cost=1
      [[ "$ca" == "${b:j-1:1}" ]] && cost=0
      del=$(( prev[j] + 1 ))
      ins=$(( cur[j-1] + 1 ))
      sub=$(( prev[j-1] + cost ))
      m=$del
      (( ins < m )) && m=$ins
      (( sub < m )) && m=$sub
      cur[$j]=$m
    done
    prev=("${cur[@]}")
  done
  printf '%s' "${prev[$lb]}"
}

# Closest candidate to a word (echo), empty when nothing is close enough.
# Close enough: a unique prefix match (len >= 2), or an edit distance of at
# most ceil(len/3).
# Args: word candidate...
_suggest_closest() {
  local word="$1"; shift
  [[ -z "$word" ]] && return 0
  local lw
  lw=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
  lw="${lw#--}"

  # Prefix match first (dep → deploy), only when unambiguous
  local c lc prefix_hit="" prefix_count=0
  if (( ${#lw} >= 2 )); then
    for c in "$@"; do
      lc=$(printf '%s' "$c" | tr '[:upper:]' '[:lower:]')
      lc="${lc#--}"
      if [[ "$lc" == "$lw"* && "$lc" != "$lw" ]]; then
        prefix_hit="$c"
        prefix_count=$(( prefix_count + 1 ))
      fi
    done
    if (( prefix_count == 1 )); then
      printf '%s' "$prefix_hit"
      return 0
    fi
  fi

  local max=$(( (${#lw} + 2) / 3 ))
  (( max < 1 )) && max=1
  local best="" best_d=999 d
  for c in "$@"; do
    lc=$(printf '%s' "$c" | tr '[:upper:]' '[:lower:]')
    lc="${lc#--}"
    d=$(_suggest_distance "$lw" "$lc")
    if (( d < best_d )); then
      best_d=$d
      best="$c"
    fi
  done
  if (( best_d <= max )); then
    printf '%s' "$best"
  fi
}

# Print "Did you mean: X?" when a close candidate exists.
# Args: word candidate...   Returns 0 when a suggestion was printed.
_suggest_print() {
  local s
  s=$(_suggest_closest "$@")
  [[ -z "$s" ]] && return 1
  printf '  %bDid you mean:%b %b%s%b?\n' "${DIM}" "${RESET}" "${BOLD}" "$s" "${RESET}"
  return 0
}

# Top-level muster commands, read from bin/muster's router so commands added
# later (by other modules) are picked up automatically.
_suggest_commands() {
  local bin="${MUSTER_ROOT}/bin/muster"
  [[ -f "$bin" ]] || return 0
  sed -n '/^# ── Route commands ──/,$p' "$bin" \
    | grep -E '^  [a-z][a-z|-]*\)' \
    | sed -E 's/^  //; s/\)$//' | tr '|' '\n' \
    | grep -Ev '^-' | sort -u
}
