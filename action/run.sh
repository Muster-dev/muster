#!/usr/bin/env bash
# action/run.sh — map the action inputs to `muster ci run`.
# Inputs arrive as environment variables (never interpolated into the script).
set -uo pipefail

ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=action/lib.sh
source "${ACTION_ROOT}/action/lib.sh"

if [[ -n "${INPUT_CLOUD_TOKEN:-}" ]]; then
  printf '::add-mask::%s\n' "$INPUT_CLOUD_TOKEN"
  export MUSTER_CLOUD_TOKEN="$INPUT_CLOUD_TOKEN"
fi
[[ -n "${INPUT_CLOUD_RELAY:-}" ]] && export MUSTER_CLOUD_RELAY="$INPUT_CLOUD_RELAY"

if [[ ! -f muster.json && ! -f deploy.json ]]; then
  case "${INPUT_COMMAND:-deploy}" in
    fleet-*) ;;
    *)
      if [[ -z "${INPUT_SERVER:-}${INPUT_GROUP:-}" ]]; then
        _a_err "No muster.json in $(pwd). Set working-directory, or run muster setup and commit muster.json + .muster/hooks."
        exit 1
      fi
      ;;
  esac
fi

args=(ci run "${INPUT_COMMAND:-deploy}")
_add() {
  local a
  for a in "$@"; do args[${#args[@]}]="$a"; done
}
[[ -n "${INPUT_SERVICES:-}" ]] && _add --services "$INPUT_SERVICES"
[[ -n "${INPUT_SERVER:-}" ]] && _add --server "$INPUT_SERVER"
[[ -n "${INPUT_GROUP:-}" ]] && _add --group "$INPUT_GROUP"
[[ -n "${INPUT_FROM:-}" ]] && _add --from "$INPUT_FROM"
[[ -n "${INPUT_ARGS:-}" ]] && _add --args "$INPUT_ARGS"
_a_truthy "${INPUT_DRY_RUN:-}" && _add --dry-run
_a_truthy "${INPUT_STOP_ON_FAILURE:-}" && _add --stop-on-failure
_a_truthy "${INPUT_APPROVE_HOOKS:-}" && _add --approve-hooks
_a_truthy "${INPUT_EXPLAIN_ON_FAILURE:-}" && _add --explain-on-failure

export MUSTER_NONINTERACTIVE=1
exec muster "${args[@]}" </dev/null
