#!/usr/bin/env bash
# muster/lib/core/utils.sh — Shared utility functions

# Terminal size (updated on SIGWINCH)
TERM_COLS=80
# shellcheck disable=SC2034
TERM_ROWS=24

update_term_size() {
  TERM_COLS=$(tput cols 2>/dev/null || echo 80)
  # shellcheck disable=SC2034
  TERM_ROWS=$(tput lines 2>/dev/null || echo 24)
}
update_term_size

# Global redraw callback — set this to a function name to auto-redraw on resize
MUSTER_REDRAW_FN=""

# Flag: set to "true" by WINCH redraw to tell menu/checklist to do a full redraw
_MUSTER_INPUT_DIRTY="false"

_on_resize() {
  update_term_size
  _MUSTER_INPUT_DIRTY="true"
  if [[ -n "$MUSTER_REDRAW_FN" ]]; then
    $MUSTER_REDRAW_FN
  fi
}
trap '_on_resize' WINCH

# Track whether TUI modified terminal state
_MUSTER_TUI_ACTIVE="false"
_MUSTER_TUI_FULLSCREEN="false"

# Call this when entering TUI mode (dashboard, menus with cursor hidden, etc.)
muster_tui_enter() {
  [[ "${MUSTER_MINIMAL:-false}" == "true" ]] && return 0
  _MUSTER_TUI_ACTIVE="true"
}

# Call this when entering full-screen TUI (dashboard) — clear on exit
muster_tui_fullscreen() {
  [[ "${MUSTER_MINIMAL:-false}" == "true" ]] && return 0
  _MUSTER_TUI_ACTIVE="true"
  _MUSTER_TUI_FULLSCREEN="true"
}

# Cleanup terminal state on exit — only resets if TUI was active
cleanup_term() {
  if [[ "$_MUSTER_TUI_ACTIVE" = "true" ]]; then
    printf '\033[;r' 2>/dev/null
    tput cnorm 2>/dev/null || true
    printf '\033[0m' 2>/dev/null
    stty echo 2>/dev/null || true
    if [[ "$_MUSTER_TUI_FULLSCREEN" = "true" ]]; then
      clear 2>/dev/null || true
    fi
  fi
}
trap cleanup_term EXIT

# Double Ctrl+C to quit — first press warns, second within 5s exits
_SIGINT_LAST=0

_on_sigint() {
  local now
  now=$(date +%s)
  local diff=$(( now - _SIGINT_LAST ))
  if (( diff <= 5 )); then
    echo ""
    cleanup_term
    exit 0
  fi
  _SIGINT_LAST=$now
  # Move to a new line, show warning
  echo ""
  printf '  \033[38;5;221m!\033[0m Press Ctrl+C again to quit\n'
}
trap '_on_sigint' INT

# Check if a command exists
has_cmd() {
  command -v "$1" &>/dev/null
}

# ── Path input with Tab autocomplete ──

# Read a directory path with Tab-triggered autocomplete.
# Usage: _read_path "  > "
#   Result in: REPLY
# Regular typing is instant (no subprocesses). Tab runs compgen.
# Tab: complete/cycle. Up/Down: select suggestion. Enter: accept. Esc: cancel.
_read_path() {
  local _rp_prompt="${1:-  > }"
  REPLY=""

  # Minimal mode or no TTY: plain read
  if [[ "${MUSTER_MINIMAL:-false}" == "true" ]] || [[ ! -t 0 ]]; then
    printf '%s' "$_rp_prompt"
    read -r REPLY
    [[ "$REPLY" == "~"* ]] && REPLY="${HOME}${REPLY:1}"
    return 0
  fi

  local _rp_input=""
  local _rp_matches=()
  local _rp_sel=-1
  local _rp_max=8
  local _rp_below=0
  local _rp_pending=""

  # Clear suggestion lines below input
  _rp_clear_below() {
    if (( _rp_below > 0 )); then
      printf '\n'
      tput ed
      tput cuu1
      _rp_below=0
    fi
    _rp_matches=()
    _rp_sel=-1
  }

  # Redraw just the input line — zero subprocesses
  # Shows _rp_input as-is (preserves user's path style)
  _rp_redraw_input() {
    printf '\r\033[K%s%s' "$_rp_prompt" "$_rp_input"
  }

  # Run compgen (only called on Tab)
  _rp_get_matches() {
    _rp_matches=()
    [[ -z "$_rp_input" ]] && return

    local _expanded="$_rp_input"
    [[ "$_expanded" == "~"* ]] && _expanded="${HOME}${_expanded:1}"

    local _m
    while IFS= read -r _m; do
      [[ -z "$_m" ]] && continue
      [[ -d "$_m" && "$_m" != */ ]] && _m="${_m}/"
      _rp_matches[${#_rp_matches[@]}]="$_m"
    done < <(compgen -d -- "$_expanded" 2>/dev/null | head -n "$_rp_max")
  }

  # Longest common prefix (only called on Tab)
  _rp_common_prefix() {
    (( ${#_rp_matches[@]} == 0 )) && return
    local _cp="${_rp_matches[0]}"
    local _i=1
    while (( _i < ${#_rp_matches[@]} )); do
      local _other="${_rp_matches[$_i]}"
      local _j=0 _new=""
      while (( _j < ${#_cp} && _j < ${#_other} )); do
        [[ "${_cp:$_j:1}" == "${_other:$_j:1}" ]] || break
        _new="${_new}${_cp:$_j:1}"
        _j=$((_j + 1))
      done
      _cp="$_new"
      _i=$((_i + 1))
    done
    printf '%s' "$_cp"
  }

  # Draw suggestions below input — all display logic inlined (no subshells)
  _rp_draw_suggestions() {
    printf '\n'
    tput ed
    local _newbelow=1

    # Compute strip prefix inline
    local _expanded="$_rp_input"
    [[ "$_expanded" == "~"* ]] && _expanded="${HOME}${_expanded:1}"
    local _strip=""
    if [[ "$_expanded" == */ ]]; then
      _strip="$_expanded"
    elif [[ "$_expanded" == */* ]]; then
      _strip="${_expanded%/*}/"
    fi

    local _i=0
    while (( _i < ${#_rp_matches[@]} )); do
      (( _i > 0 )) && { printf '\n'; _newbelow=$((_newbelow + 1)); }

      # Inline entry display (no subshell)
      local _full="${_rp_matches[$_i]}" _display
      if [[ -n "$_strip" && "$_full" == "$_strip"* ]]; then
        _display="${_full#$_strip}"
      else
        _display="$_full"
        [[ "$_display" == "$HOME"* ]] && _display="~${_display#$HOME}"
      fi

      if (( _i == _rp_sel )); then
        printf '    \033[48;5;178m\033[38;5;0m %s \033[0m' "$_display"
      else
        printf '    \033[2m%s\033[0m' "$_display"
      fi
      _i=$((_i + 1))
    done

    # Move cursor back up
    _i=0
    while (( _i < _newbelow )); do
      tput cuu1
      _i=$((_i + 1))
    done
    _rp_below=$_newbelow
    _rp_redraw_input
  }

  # Print initial prompt
  printf '%s' "$_rp_prompt"

  while true; do
    local _key
    if [[ -n "$_rp_pending" ]]; then
      _key="$_rp_pending"
      _rp_pending=""
    else
      IFS= read -rsn1 _key || true
    fi

    # Detect escape sequences (arrow keys)
    if [[ "$_key" == $'\x1b' ]]; then
      local _s1="" _s2=""
      IFS= read -rsn1 -t 1 _s1 2>/dev/null || true
      if [[ -n "$_s1" ]]; then
        IFS= read -rsn1 -t 1 _s2 2>/dev/null || true
      fi
      _key="${_key}${_s1}${_s2}"
    fi

    case "$_key" in
      $'\x7f'|$'\x08')  # Backspace
        if [[ -n "$_rp_input" ]]; then
          _rp_input="${_rp_input%?}"
          _rp_clear_below
          _rp_redraw_input
        fi
        ;;
      $'\t')  # Tab — trigger autocomplete
        local _was_tilde=false
        [[ "$_rp_input" == "~"* ]] && _was_tilde=true
        _rp_get_matches
        if (( ${#_rp_matches[@]} == 1 )); then
          _rp_input="${_rp_matches[0]}"
          # Preserve user's path style: only shorten to ~ if they typed ~
          if [[ "$_was_tilde" == true && "$_rp_input" == "$HOME"* ]]; then
            _rp_input="~${_rp_input#$HOME}"
          fi
          _rp_matches=()
          _rp_sel=-1
          _rp_clear_below
          _rp_redraw_input
        elif (( ${#_rp_matches[@]} > 1 )); then
          local _cp
          _cp=$(_rp_common_prefix)
          local _exp_input="$_rp_input"
          [[ "$_exp_input" == "~"* ]] && _exp_input="${HOME}${_exp_input:1}"
          if [[ -n "$_cp" && "$_cp" != "$_exp_input" ]]; then
            _rp_input="$_cp"
            # Preserve tilde style
            if [[ "$_was_tilde" == true && "$_rp_input" == "$HOME"* ]]; then
              _rp_input="~${_rp_input#$HOME}"
            fi
            _rp_sel=-1
            _rp_get_matches
          else
            _rp_sel=$(( (_rp_sel + 1) % ${#_rp_matches[@]} ))
          fi
          _rp_draw_suggestions
        fi
        ;;
      $'\x1b[A')  # Up arrow
        if (( ${#_rp_matches[@]} > 0 && _rp_sel > 0 )); then
          _rp_sel=$((_rp_sel - 1))
          _rp_draw_suggestions
        fi
        ;;
      $'\x1b[B')  # Down arrow
        if (( ${#_rp_matches[@]} > 0 && _rp_sel < ${#_rp_matches[@]} - 1 )); then
          _rp_sel=$((_rp_sel + 1))
          _rp_draw_suggestions
        fi
        ;;
      $'\x1b'|$'\x1b['|$'\x1b[C'|$'\x1b[D')  # Escape or L/R arrows
        if [[ "$_key" == $'\x1b' ]]; then
          _rp_clear_below
          printf '\r\033[K%s\n' "$_rp_prompt"
          REPLY=""
          return 0
        fi
        # Left/Right arrows — ignore
        ;;
      ''|$'\n')  # Enter — accept
        if (( _rp_sel >= 0 && _rp_sel < ${#_rp_matches[@]} )); then
          local _sel_path="${_rp_matches[$_rp_sel]}"
          # Preserve tilde style from what user typed
          if [[ "$_rp_input" == "~"* && "$_sel_path" == "$HOME"* ]]; then
            _rp_input="~${_sel_path#$HOME}"
          else
            _rp_input="$_sel_path"
          fi
        fi
        _rp_clear_below
        printf '\r\033[K%s%s\n' "$_rp_prompt" "$_rp_input"
        REPLY="$_rp_input"
        [[ "$REPLY" == "~"* ]] && REPLY="${HOME}${REPLY:1}"
        return 0
        ;;
      *)
        # Regular character — append (zero subprocesses)
        if [[ -n "$_key" ]]; then
          _rp_input="${_rp_input}${_key}"

          # Drain queued chars from fast typing (batch before redraw)
          while read -t 0 2>/dev/null; do
            local _e
            IFS= read -rsn1 _e 2>/dev/null || break
            case "$_e" in
              $'\x1b'|$'\t'|$'\x7f'|$'\x08'|''|$'\n')
                _rp_pending="$_e"
                break ;;
              *) _rp_input="${_rp_input}${_e}" ;;
            esac
          done

          # Dismiss suggestions if showing
          (( _rp_below > 0 )) && _rp_clear_below
          _rp_redraw_input
        fi
        ;;
    esac
  done
}

# ── Hook timeout wrapper ──

# Run a command with a timeout. Returns the command's exit code, or 124 on timeout.
# Uses GNU timeout if available, falls back to bash background process + watchdog.
# Usage: _run_with_timeout <timeout_secs> <command> [args...]
# The command's stdout/stderr are NOT redirected — caller handles that.
_run_with_timeout() {
  local _timeout_secs="$1"
  shift

  # No timeout (0 or empty) — run directly
  if [[ -z "$_timeout_secs" || "$_timeout_secs" == "0" ]]; then
    "$@"
    return $?
  fi

  # Try GNU timeout (available on Linux, Homebrew gtimeout on macOS)
  if has_cmd timeout; then
    timeout "$_timeout_secs" "$@"
    return $?
  fi
  if has_cmd gtimeout; then
    gtimeout "$_timeout_secs" "$@"
    return $?
  fi

  # Fallback: bash background process + watchdog (macOS bash 3.2 compatible)
  "$@" &
  local _cmd_pid=$!

  # Watchdog: sleep then kill the command if still running
  (
    local _elapsed=0
    while (( _elapsed < _timeout_secs )); do
      sleep 1
      _elapsed=$(( _elapsed + 1 ))
      kill -0 "$_cmd_pid" 2>/dev/null || exit 0
    done
    # Timeout reached — kill the command
    kill -TERM "$_cmd_pid" 2>/dev/null
    sleep 2
    kill -KILL "$_cmd_pid" 2>/dev/null
  ) &
  local _watchdog_pid=$!

  wait "$_cmd_pid" 2>/dev/null
  local _rc=$?

  # Clean up watchdog
  kill "$_watchdog_pid" 2>/dev/null
  wait "$_watchdog_pid" 2>/dev/null

  # Detect if killed by signal (bash reports 128+signal for killed processes)
  # SIGTERM=15 → 143, SIGKILL=9 → 137
  if (( _rc == 143 || _rc == 137 )); then
    return 124
  fi

  return "$_rc"
}

# ── .env file loading ──

# Tracks variable names loaded from .env for cleanup
_MUSTER_ENV_VARS=()

# Load a .env file, exporting KEY=VALUE pairs without overriding existing env vars.
# Usage: _load_env_file [path]   (defaults to $(dirname "$CONFIG_FILE")/.env)
_load_env_file() {
  local env_file="${1:-}"
  if [[ -z "$env_file" ]]; then
    [[ -z "${CONFIG_FILE:-}" ]] && return 0
    env_file="$(dirname "$CONFIG_FILE")/.env"
  fi
  [[ -f "$env_file" ]] || return 0

  _MUSTER_ENV_VARS=()
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and comments
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # Strip inline comments only outside quotes, but keep it simple:
    # Match KEY=VALUE (value may be quoted)
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"

      # Strip surrounding quotes
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi

      # Do NOT override existing env vars
      if [[ -z "${!key+set}" ]]; then
        export "$key=$val"
        _MUSTER_ENV_VARS[${#_MUSTER_ENV_VARS[@]}]="$key"
      fi
    fi
  done < "$env_file"
}

# Unset all variables loaded by _load_env_file
_unload_env_file() {
  local k
  # bash 3.2: "${arr[@]}" with empty array triggers "unbound variable" under set -u
  if [[ ${#_MUSTER_ENV_VARS[@]} -gt 0 ]]; then
    for k in "${_MUSTER_ENV_VARS[@]}"; do
      unset "$k"
    done
  fi
  _MUSTER_ENV_VARS=()
}

# Find the project deploy.json by walking up from cwd
find_config() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    # Prefer muster.json, fall back to deploy.json
    if [[ -f "$dir/muster.json" ]]; then
      echo "$dir/muster.json"
      return 0
    fi
    if [[ -f "$dir/deploy.json" ]]; then
      echo "$dir/deploy.json"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# ── Git deploy tracking ──

# Check if current directory is inside a git work tree
_git_is_repo() {
  git rev-parse --is-inside-work-tree &>/dev/null
}

# Get short SHA of current HEAD (empty string if not a git repo)
_git_current_sha() {
  git rev-parse --short HEAD 2>/dev/null || echo ""
}

# Read the previously deployed SHA for a service from .muster/deploy-commits.json
# Usage: _git_prev_deploy_sha "api"
# Returns: short SHA string, or empty if none tracked
_git_prev_deploy_sha() {
  local svc="$1"
  [[ -z "${CONFIG_FILE:-}" ]] && return 0
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local tracker="${project_dir}/.muster/deploy-commits.json"
  [[ -f "$tracker" ]] || return 0
  if has_cmd jq; then
    jq -r ".\"${svc}\" // empty" "$tracker" 2>/dev/null
  elif has_cmd python3; then
    python3 -c "
import json
with open('${tracker}') as f:
    data = json.load(f)
print(data.get('${svc}', ''))
" 2>/dev/null
  fi
}

# Save the current SHA as the deployed commit for a service
# Usage: _git_save_deploy_sha "api" "abc1234"
_git_save_deploy_sha() {
  local svc="$1" sha="$2"
  [[ -z "${CONFIG_FILE:-}" ]] && return 0
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local tracker="${project_dir}/.muster/deploy-commits.json"
  mkdir -p "$(dirname "$tracker")"

  if [[ ! -f "$tracker" ]]; then
    printf '{}' > "$tracker"
  fi

  if has_cmd jq; then
    local tmp="${tracker}.tmp"
    jq ".\"${svc}\" = \"${sha}\"" "$tracker" > "$tmp" && mv "$tmp" "$tracker"
  elif has_cmd python3; then
    python3 -c "
import json
with open('${tracker}') as f:
    data = json.load(f)
data['${svc}'] = '${sha}'
with open('${tracker}', 'w') as f:
    json.dump(data, f, indent=2)
"
  fi
}

# Print a formatted diff summary between two SHAs
# Usage: _git_deploy_diff "prev_sha" "current_sha"
# If prev_sha is empty, prints "Initial deploy" message
_git_deploy_diff() {
  local prev="$1" curr="$2"

  # No previous deploy — nothing to diff, skip silently
  [[ -z "$prev" ]] && return 0

  # Verify previous SHA is reachable
  if ! git cat-file -t "$prev" &>/dev/null; then
    printf '%b\n' "    ${DIM}Previous commit ${prev} not reachable (history rewritten?)${RESET}"
    return 0
  fi

  # Count total commits
  local total_commits
  total_commits=$(git rev-list --count "${prev}..${curr}" 2>/dev/null || echo "0")

  if [[ "$total_commits" == "0" ]]; then
    printf '%b\n' "    ${DIM}No new commits${RESET}"
    return 0
  fi

  printf '%b\n' "    ${DIM}Changes since last deploy (${total_commits} commit$( (( total_commits != 1 )) && echo "s")):${RESET}"

  # Show up to 5 commit one-liners (hash in accent, message dimmed)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local sha="${line%% *}"
    local msg="${line#* }"
    # Truncate message to 64 chars
    if (( ${#msg} > 64 )); then
      msg="${msg:0:61}..."
    fi
    printf '%b\n' "      ${ACCENT}${sha}${RESET} ${DIM}${msg}${RESET}"
  done < <(git log --oneline "${prev}..${curr}" --max-count=5 2>/dev/null)

  if (( total_commits > 5 )); then
    local remaining=$(( total_commits - 5 ))
    printf '%b\n' "      ${DIM}...and ${remaining} more${RESET}"
  fi

  # Diffstat summary with colored +/-
  local shortstat
  shortstat=$(git diff --shortstat "${prev}..${curr}" 2>/dev/null)
  if [[ -n "$shortstat" ]]; then
    local ins="" del=""
    ins=$(echo "$shortstat" | grep -o '[0-9]* insertion' | grep -o '[0-9]*')
    del=$(echo "$shortstat" | grep -o '[0-9]* deletion' | grep -o '[0-9]*')
    local files=""
    files=$(echo "$shortstat" | grep -o '[0-9]* file' | grep -o '[0-9]*')
    local stat_line
    stat_line="${files} file$( (( files != 1 )) && echo "s") changed"
    [[ -n "$ins" ]] && stat_line="${stat_line}, ${GREEN}+${ins}${RESET}"
    [[ -n "$del" ]] && stat_line="${stat_line}, ${RED}-${del}${RESET}"
    printf '%b\n' "    ${DIM}${stat_line}${RESET}"
  fi
}

# ---------------------------------------------------------------------------
# Deploy identity — who is deploying (for lock files)
# ---------------------------------------------------------------------------

_deploy_identity() {
  # 1. Check deploy_name from global settings
  if [[ -f "$HOME/.muster/settings.json" ]]; then
    local _di_name=""
    if has_cmd jq; then
      _di_name=$(jq -r '.deploy_name // ""' "$HOME/.muster/settings.json" 2>/dev/null)
    elif has_cmd python3; then
      _di_name=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('deploy_name',''))" "$HOME/.muster/settings.json" 2>/dev/null)
    fi
    if [[ -n "$_di_name" && "$_di_name" != "null" ]]; then
      printf '%s' "$_di_name"
      return 0
    fi
  fi

  # 2. Fall back to git config user.name
  local _di_git=""
  _di_git=$(git config user.name 2>/dev/null || true)
  if [[ -n "$_di_git" ]]; then
    printf '%s' "$_di_git"
    return 0
  fi

  # 3. Fall back to whoami
  whoami
}

# ---------------------------------------------------------------------------
# Deploy lock — prevent concurrent deploys
# ---------------------------------------------------------------------------

_deploy_lock_file() {
  local project_dir="$1"
  echo "${project_dir}/.muster/deploy.lock"
}

_deploy_lock_read() {
  local lock_file="$1"
  _LOCK_USER="" _LOCK_PID="" _LOCK_STARTED="" _LOCK_TERMINAL="" _LOCK_SERVICES=""
  if has_cmd jq; then
    _LOCK_USER=$(jq -r '.user // "unknown"' "$lock_file" 2>/dev/null)
    _LOCK_PID=$(jq -r '.pid // ""' "$lock_file" 2>/dev/null)
    _LOCK_STARTED=$(jq -r '.started // "unknown"' "$lock_file" 2>/dev/null)
    _LOCK_TERMINAL=$(jq -r '.terminal // "unknown"' "$lock_file" 2>/dev/null)
    _LOCK_SERVICES=$(jq -r '(.services // []) | join(", ")' "$lock_file" 2>/dev/null)
  elif has_cmd python3; then
    _LOCK_USER=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('user','unknown'))" "$lock_file" 2>/dev/null)
    _LOCK_PID=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('pid',''))" "$lock_file" 2>/dev/null)
    _LOCK_STARTED=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('started','unknown'))" "$lock_file" 2>/dev/null)
    _LOCK_TERMINAL=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('terminal','unknown'))" "$lock_file" 2>/dev/null)
    _LOCK_SERVICES=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(', '.join(d.get('services',[])))" "$lock_file" 2>/dev/null)
  fi
}

_deploy_lock_duration() {
  local started="$1"
  local start_epoch=0 now_epoch=0
  if has_cmd gdate; then
    start_epoch=$(gdate -d "$started" +%s 2>/dev/null || echo 0)
    now_epoch=$(gdate +%s)
  elif date -d "2000-01-01" +%s &>/dev/null; then
    start_epoch=$(date -d "$started" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
  else
    # macOS date
    start_epoch=$(date -jf "%Y-%m-%d %H:%M:%S" "$started" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
  fi
  if (( start_epoch == 0 )); then
    echo "unknown"
    return
  fi
  local diff=$(( now_epoch - start_epoch ))
  (( diff < 0 )) && diff=0
  local mins=$(( diff / 60 ))
  local secs=$(( diff % 60 ))
  if (( mins > 0 )); then
    echo "${mins}m ${secs}s"
  else
    echo "${secs}s"
  fi
}

_deploy_lock_show_tui() {
  local lock_user="$1" lock_pid="$2" lock_started="$3" lock_terminal="$4" lock_services="$5"

  # Header bar (same pattern as dashboard)
  local bar_w=$(( TERM_COLS - 2 ))
  (( bar_w < 20 )) && bar_w=20
  local bar_text="  Deploy in Progress"
  local bar_text_len=${#bar_text}
  local bar_pad_len=$(( bar_w - bar_text_len ))
  (( bar_pad_len < 1 )) && bar_pad_len=1
  local bar_pad
  printf -v bar_pad '%*s' "$bar_pad_len" ""
  printf '\n \033[48;5;178m\033[38;5;0m\033[1m%s%s\033[0m\n' "$bar_text" "$bar_pad"

  # Lock details
  local duration
  duration=$(_deploy_lock_duration "$lock_started")
  echo ""
  printf '%b  %b*%b User:      %s\n' "" "${ACCENT}" "${RESET}" "$lock_user"
  printf '%b  %b*%b PID:       %s\n' "" "${ACCENT}" "${RESET}" "$lock_pid"
  printf '%b  %b*%b Started:   %s\n' "" "${ACCENT}" "${RESET}" "$lock_started"
  printf '%b  %b*%b Duration:  %s\n' "" "${ACCENT}" "${RESET}" "$duration"
  if [[ -n "$lock_services" ]]; then
    printf '%b  %b*%b Services:  %s\n' "" "${ACCENT}" "${RESET}" "$lock_services"
  fi
  if [[ "$lock_terminal" != "unknown" && -n "$lock_terminal" ]]; then
    printf '%b  %b*%b Terminal:  %s\n' "" "${ACCENT}" "${RESET}" "$lock_terminal"
  fi

  # Separator
  echo ""
  local rule_w=$(( TERM_COLS - 4 ))
  (( rule_w > 50 )) && rule_w=50
  (( rule_w < 10 )) && rule_w=10
  local rule
  printf -v rule '%*s' "$rule_w" ""
  rule="${rule// /─}"
  printf '  %b%s%b\n' "${GRAY}" "$rule" "${RESET}"
  printf '  %bDeploy is running in another session.%b\n' "${DIM}" "${RESET}"
}

_deploy_lock_acquire() {
  local project_dir="$1"
  shift
  local lock_file
  lock_file=$(_deploy_lock_file "$project_dir")

  if [[ -f "$lock_file" ]]; then
    # Read existing lock
    _deploy_lock_read "$lock_file"
    local lock_user="$_LOCK_USER" lock_pid="$_LOCK_PID"
    local lock_started="$_LOCK_STARTED" lock_terminal="$_LOCK_TERMINAL"
    local lock_services="$_LOCK_SERVICES"

    # Check if PID is still alive (empty PID = malformed lock = stale)
    if [[ -z "$lock_pid" ]] || ! kill -0 "$lock_pid" 2>/dev/null; then
      # Stale lock — remove it
      warn "Removing stale deploy lock (PID ${lock_pid:-unknown} is dead)"
      rm -f "$lock_file"
    else
      # Active lock — show enhanced TUI and offer options
      if [[ -t 0 ]]; then
        _deploy_lock_show_tui "$lock_user" "$lock_pid" "$lock_started" "$lock_terminal" "$lock_services"
        menu_select "" "Wait" "Override" "Abort"
        case "$MENU_RESULT" in
          "Wait")
            # Live spinner with updating duration
            local _lock_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local _lock_fi=0
            tput civis 2>/dev/null || true
            while [[ -f "$lock_file" ]]; do
              if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                rm -f "$lock_file"
                break
              fi
              local _wait_dur
              _wait_dur=$(_deploy_lock_duration "$lock_started")
              printf '\r  %b%s%b %bWaiting for deploy to finish... (%s)%b  ' \
                "${ACCENT}" "${_lock_frames[$_lock_fi]}" "${RESET}" \
                "${DIM}" "$_wait_dur" "${RESET}"
              _lock_fi=$(( (_lock_fi + 1) % ${#_lock_frames[@]} ))
              sleep 0.2
            done
            printf '\r\033[K'
            tput cnorm 2>/dev/null || true
            ok "Lock released, proceeding"
            ;;
          "Override")
            warn "Overriding deploy lock"
            rm -f "$lock_file"
            ;;
          "Abort"|"__back__")
            return 1
            ;;
        esac
      else
        err "Deploy locked by ${lock_user} (PID ${lock_pid}). Use --force to override."
        return 1
      fi
    fi
  fi

  # Create lock
  mkdir -p "$(dirname "$lock_file")"
  local _svcs=""
  local _i=1
  while (( _i <= $# )); do
    [[ -n "$_svcs" ]] && _svcs="${_svcs},"
    _svcs="${_svcs}\"${!_i}\""
    _i=$((_i + 1))
  done
  local _tty_name
  _tty_name=$(tty 2>/dev/null || echo "unknown")
  cat > "$lock_file" <<EOF
{"user":"$(_deploy_identity)","pid":$$,"started":"$(date '+%Y-%m-%d %H:%M:%S')","terminal":"${_tty_name}","services":[${_svcs}]}
EOF
  return 0
}

_deploy_lock_release() {
  local project_dir="$1"
  local lock_file
  lock_file=$(_deploy_lock_file "$project_dir")
  rm -f "$lock_file"
}

# ---------------------------------------------------------------------------
# Per-service deploy locks
# ---------------------------------------------------------------------------

_service_lock_file() {
  local project_dir="$1" service="$2"
  echo "${project_dir}/.muster/locks/${service}.lock"
}

_service_lock_read() {
  local lock_file="$1"
  _SLOCK_USER="" _SLOCK_PID="" _SLOCK_STARTED="" _SLOCK_SOURCE="" _SLOCK_HOST=""
  if has_cmd jq; then
    _SLOCK_USER=$(jq -r '.user // "unknown"' "$lock_file" 2>/dev/null)
    _SLOCK_PID=$(jq -r '.pid // ""' "$lock_file" 2>/dev/null)
    _SLOCK_STARTED=$(jq -r '.started // "unknown"' "$lock_file" 2>/dev/null)
    _SLOCK_SOURCE=$(jq -r '.source // "local"' "$lock_file" 2>/dev/null)
    _SLOCK_HOST=$(jq -r '.host // "unknown"' "$lock_file" 2>/dev/null)
  elif has_cmd python3; then
    _SLOCK_USER=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('user','unknown'))" "$lock_file" 2>/dev/null)
    _SLOCK_PID=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('pid',''))" "$lock_file" 2>/dev/null)
    _SLOCK_STARTED=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('started','unknown'))" "$lock_file" 2>/dev/null)
    _SLOCK_SOURCE=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('source','local'))" "$lock_file" 2>/dev/null)
    _SLOCK_HOST=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('host','unknown'))" "$lock_file" 2>/dev/null)
  fi
}

_service_lock_timeout() {
  local val=""
  if [[ -f "$HOME/.muster/settings.json" ]]; then
    if has_cmd jq; then
      val=$(jq -r '.service_lock_timeout // ""' "$HOME/.muster/settings.json" 2>/dev/null)
    elif has_cmd python3; then
      val=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('service_lock_timeout',''))" "$HOME/.muster/settings.json" 2>/dev/null)
    fi
  fi
  if [[ -z "$val" || "$val" == "null" ]]; then
    echo "1800"
  else
    echo "$val"
  fi
}

# Check if a service lock is stale. Returns 0 if stale, 1 if active.
_service_lock_is_stale() {
  local lock_file="$1"
  _service_lock_read "$lock_file"

  # Local lock: check PID
  if [[ "$_SLOCK_SOURCE" == "local" ]]; then
    if [[ -z "$_SLOCK_PID" ]] || ! kill -0 "$_SLOCK_PID" 2>/dev/null; then
      return 0
    fi
    return 1
  fi

  # Fleet lock: check timeout
  case "$_SLOCK_SOURCE" in
    fleet:*)
      local timeout_secs
      timeout_secs=$(_service_lock_timeout)
      local start_epoch=0 now_epoch=0
      if has_cmd gdate; then
        start_epoch=$(gdate -d "$_SLOCK_STARTED" +%s 2>/dev/null || echo 0)
        now_epoch=$(gdate +%s)
      elif date -d "2000-01-01" +%s &>/dev/null; then
        start_epoch=$(date -d "$_SLOCK_STARTED" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
      else
        start_epoch=$(date -jf "%Y-%m-%d %H:%M:%S" "$_SLOCK_STARTED" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
      fi
      if (( start_epoch == 0 )); then
        return 0
      fi
      local elapsed=$(( now_epoch - start_epoch ))
      if (( elapsed > timeout_secs )); then
        return 0
      fi
      return 1
      ;;
  esac

  # Unknown source type — treat as active
  return 1
}

_service_lock_acquire() {
  local project_dir="$1" service="$2"
  local lock_file
  lock_file=$(_service_lock_file "$project_dir" "$service")

  if [[ -f "$lock_file" ]]; then
    if _service_lock_is_stale "$lock_file"; then
      warn "Removing stale service lock for '${service}' (${_SLOCK_SOURCE}, PID ${_SLOCK_PID:-unknown})"
      rm -f "$lock_file"
    else
      # Active lock
      _service_lock_read "$lock_file"
      if [[ -t 0 ]]; then
        local duration
        duration=$(_deploy_lock_duration "$_SLOCK_STARTED")
        printf '\n'
        printf '%b  %b!%b Service %b%s%b is locked\n' "" "${YELLOW}" "${RESET}" "${BOLD}" "$service" "${RESET}"
        printf '%b  %b*%b User:    %s\n' "" "${ACCENT}" "${RESET}" "$_SLOCK_USER"
        printf '%b  %b*%b Source:  %s\n' "" "${ACCENT}" "${RESET}" "$_SLOCK_SOURCE"
        printf '%b  %b*%b Host:    %s\n' "" "${ACCENT}" "${RESET}" "$_SLOCK_HOST"
        printf '%b  %b*%b Started: %s (%s ago)\n' "" "${ACCENT}" "${RESET}" "$_SLOCK_STARTED" "$duration"
        if [[ "$_SLOCK_SOURCE" == "local" ]]; then
          printf '%b  %b*%b PID:     %s\n' "" "${ACCENT}" "${RESET}" "$_SLOCK_PID"
        fi
        printf '\n'

        menu_select "" "Wait" "Override" "Abort"
        case "$MENU_RESULT" in
          "Wait")
            local _lock_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local _lock_fi=0
            tput civis 2>/dev/null || true
            while [[ -f "$lock_file" ]]; do
              if _service_lock_is_stale "$lock_file"; then
                rm -f "$lock_file"
                break
              fi
              local _wait_dur
              _wait_dur=$(_deploy_lock_duration "$_SLOCK_STARTED")
              printf '\r  %b%s%b %bWaiting for %s lock to release... (%s)%b  ' \
                "${ACCENT}" "${_lock_frames[$_lock_fi]}" "${RESET}" \
                "${DIM}" "$service" "$_wait_dur" "${RESET}"
              _lock_fi=$(( (_lock_fi + 1) % ${#_lock_frames[@]} ))
              sleep 0.2
            done
            printf '\r\033[K'
            tput cnorm 2>/dev/null || true
            ok "Service lock released for '${service}', proceeding"
            ;;
          "Override")
            warn "Overriding service lock for '${service}'"
            rm -f "$lock_file"
            ;;
          "Abort"|"__back__")
            return 1
            ;;
        esac
      else
        err "Service '${service}' is locked by ${_SLOCK_USER} (${_SLOCK_SOURCE}). Use --force to override."
        return 1
      fi
    fi
  fi

  # Create lock
  mkdir -p "$(dirname "$lock_file")"
  local _tty_name _hostname
  _tty_name=$(tty 2>/dev/null || echo "unknown")
  _hostname=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
  local _source="${MUSTER_LOCK_SOURCE:-local}"
  cat > "$lock_file" <<EOF
{"user":"$(_deploy_identity)","pid":$$,"started":"$(date '+%Y-%m-%d %H:%M:%S')","terminal":"${_tty_name}","source":"${_source}","host":"${_hostname}"}
EOF
  return 0
}

_service_lock_release() {
  local project_dir="$1" service="$2"
  local lock_file
  lock_file=$(_service_lock_file "$project_dir" "$service")
  rm -f "$lock_file"
}

_service_lock_release_all() {
  local project_dir="$1"
  local locks_dir="${project_dir}/.muster/locks"
  if [[ -d "$locks_dir" ]]; then
    rm -f "${locks_dir}"/*.lock 2>/dev/null
  fi
}

_service_lock_list() {
  local project_dir="$1"
  local locks_dir="${project_dir}/.muster/locks"
  [[ -d "$locks_dir" ]] || return 0
  local f svc
  for f in "${locks_dir}"/*.lock; do
    [[ -f "$f" ]] || continue
    svc="${f##*/}"
    svc="${svc%.lock}"
    if _service_lock_is_stale "$f"; then
      rm -f "$f"
      continue
    fi
    _service_lock_read "$f"
    printf '%s|%s|%s|%s\n' "$svc" "$_SLOCK_USER" "$_SLOCK_SOURCE" "$_SLOCK_STARTED"
  done
}
