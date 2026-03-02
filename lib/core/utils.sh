#!/usr/bin/env bash
# muster/lib/core/utils.sh — Shared utility functions

# Terminal size (updated on SIGWINCH)
TERM_COLS=80
TERM_ROWS=24

update_term_size() {
  TERM_COLS=$(tput cols 2>/dev/null || echo 80)
  TERM_ROWS=$(tput lines 2>/dev/null || echo 24)
}
update_term_size

# Global redraw callback — set this to a function name to auto-redraw on resize
MUSTER_REDRAW_FN=""

# Flag: set to "true" by WINCH redraw to tell menu/checklist to do a full redraw
_MUSTER_INPUT_DIRTY="false"

_on_resize() {
  update_term_size
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
  _MUSTER_TUI_ACTIVE="true"
}

# Call this when entering full-screen TUI (dashboard) — clear on exit
muster_tui_fullscreen() {
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
    echo -e "    ${DIM}Previous commit ${prev} not reachable (history rewritten?)${RESET}"
    return 0
  fi

  # Count total commits
  local total_commits
  total_commits=$(git rev-list --count "${prev}..${curr}" 2>/dev/null || echo "0")

  if [[ "$total_commits" == "0" ]]; then
    echo -e "    ${DIM}No new commits${RESET}"
    return 0
  fi

  echo -e "    ${DIM}Changes since last deploy (${total_commits} commit$( (( total_commits != 1 )) && echo "s")):${RESET}"

  # Show up to 5 commit one-liners (hash in accent, message dimmed)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local sha="${line%% *}"
    local msg="${line#* }"
    # Truncate message to 64 chars
    if (( ${#msg} > 64 )); then
      msg="${msg:0:61}..."
    fi
    echo -e "      ${ACCENT}${sha}${RESET} ${DIM}${msg}${RESET}"
  done < <(git log --oneline "${prev}..${curr}" --max-count=5 2>/dev/null)

  if (( total_commits > 5 )); then
    local remaining=$(( total_commits - 5 ))
    echo -e "      ${DIM}...and ${remaining} more${RESET}"
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
    local stat_line="${files} file$( (( files != 1 )) && echo "s") changed"
    [[ -n "$ins" ]] && stat_line="${stat_line}, ${GREEN}+${ins}${RESET}"
    [[ -n "$del" ]] && stat_line="${stat_line}, ${RED}-${del}${RESET}"
    echo -e "    ${DIM}${stat_line}${RESET}"
  fi
}
