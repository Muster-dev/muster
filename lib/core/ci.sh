#!/usr/bin/env bash
# muster/lib/core/ci.sh — CI detection and GitHub Actions annotations
#
#   _ci_detected            true on a CI runner (CI, GITHUB_ACTIONS, GITLAB_CI, …)
#   _ci_github              true on GitHub Actions
#   _ci_noninteractive      CI (or MUSTER_NONINTERACTIVE=1) and stdin is not a TTY
#   _ci_annotations_on      GitHub Actions and MUSTER_GITHUB_ANNOTATIONS != off
#   _ci_annotate LEVEL TITLE MESSAGE   ::error/::warning/::notice to stderr
#   _ci_annotate_failure SVC ACTION RC  ::error for a failed hook, with the hint
#   _ci_annotate_health SVC             ::warning for a failed health check
#   _ci_gh_escape_data / _ci_gh_escape_prop   workflow-command escaping
#   _ci_ssh_hostkey_policy  sets MUSTER_SSH_HOSTKEY_CHECK (yes on CI)
#
# Annotations go to stderr: the Actions runner reads workflow commands from
# both streams, and stdout stays clean for --json.

_ci_truthy() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|on|ON) return 0 ;;
  esac
  return 1
}

_ci_detected() {
  [[ "${GITHUB_ACTIONS:-}" == "true" ]] && return 0
  [[ -n "${GITLAB_CI:-}" || -n "${BUILDKITE:-}" || -n "${CIRCLECI:-}" || -n "${JENKINS_URL:-}" ]] && return 0
  _ci_truthy "${CI:-}"
}

_ci_github() {
  [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}

_ci_noninteractive() {
  [[ -t 0 ]] && return 1
  _ci_truthy "${MUSTER_NONINTERACTIVE:-}" && return 0
  _ci_detected
}

_ci_annotations_on() {
  _ci_github || return 1
  case "${MUSTER_GITHUB_ANNOTATIONS:-}" in
    off|false|0|no) return 1 ;;
  esac
  return 0
}

# https://docs.github.com/actions/reference/workflow-commands-for-github-actions
_ci_gh_escape_data() {
  local s="$1"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

_ci_gh_escape_prop() {
  local s
  s=$(_ci_gh_escape_data "$1")
  s="${s//:/%3A}"
  s="${s//,/%2C}"
  printf '%s' "$s"
}

# Args: level(error|warning|notice) title message [file]
_ci_annotate() {
  _ci_annotations_on || return 0
  local level="$1" title="$2" msg="$3" file="${4:-}"
  case "$level" in error|warning|notice) ;; *) level="error" ;; esac
  local props
  props="title=$(_ci_gh_escape_prop "$title")"
  [[ -n "$file" ]] && props="file=$(_ci_gh_escape_prop "$file"),${props}"
  printf '::%s %s::%s\n' "$level" "$props" "$(_ci_gh_escape_data "$msg")" >&2
}

# Hook file (relative to the project) for a service + action, if it exists.
_ci_hook_rel() {
  local svc="$1" action="$2" root
  [[ -n "${CONFIG_FILE:-}" ]] || return 0
  root=$(dirname "$CONFIG_FILE")
  [[ -f "${root}/.muster/hooks/${svc}/${action}.sh" ]] || return 0
  # Relative to the workspace when GitHub knows it, else to the project
  local abs="${root}/.muster/hooks/${svc}/${action}.sh"
  if [[ -n "${GITHUB_WORKSPACE:-}" && "$abs" == "${GITHUB_WORKSPACE}/"* ]]; then
    printf '%s' "${abs#"${GITHUB_WORKSPACE}"/}"
  else
    printf '.muster/hooks/%s/%s.sh' "$svc" "$action"
  fi
}

# A failed deploy/rollback/restart hook. Uses HINT_* when a rule matched.
# Args: service action exit_code
_ci_annotate_failure() {
  _ci_annotations_on || return 0
  local svc="$1" action="${2:-deploy}" rc="${3:-1}" msg
  if [[ "$rc" == "124" ]]; then
    msg="The ${action} hook timed out (exit 124)."
  else
    msg="The ${action} hook exited with code ${rc}."
  fi
  if [[ -n "${HINT_ID:-}" ]]; then
    msg="${msg}
Likely cause: ${HINT_TITLE}
Try: ${HINT_TRY}"
  fi
  _ci_annotate error "muster ${action} failed: ${svc}" "$msg" "$(_ci_hook_rel "$svc" "$action")"
}

# Args: service
_ci_annotate_health() {
  _ci_annotations_on || return 0
  local svc="$1" msg="Health check failed after deploy."
  if [[ -n "${HINT_ID:-}" ]]; then
    msg="${msg}
Likely cause: ${HINT_TITLE}
Try: ${HINT_TRY}"
  fi
  _ci_annotate warning "muster: ${svc} unhealthy" "$msg" "$(_ci_hook_rel "$svc" "health")"
}

# SSH host key policy (MUSTER_SSH_HOSTKEY_CHECK, used as StrictHostKeyChecking):
# accept-new on a workstation; yes on CI, where an ephemeral runner has no
# known_hosts history and nobody would notice a swapped key. Provide
# known_hosts (the action's known-hosts input) or set accept-new explicitly.
_ci_ssh_hostkey_policy() {
  case "${MUSTER_SSH_HOSTKEY_CHECK:-}" in
    yes|accept-new) ;;
    *)
      if _ci_detected; then
        MUSTER_SSH_HOSTKEY_CHECK=yes
      else
        MUSTER_SSH_HOSTKEY_CHECK=accept-new
      fi
      ;;
  esac
  export MUSTER_SSH_HOSTKEY_CHECK
}
_ci_ssh_hostkey_policy
