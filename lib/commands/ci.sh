#!/usr/bin/env bash
# muster/lib/commands/ci.sh — CI/CD helpers
#
#   muster ci init github|gitlab   write a deploy workflow tailored to muster.json
#   muster ci env                  which secrets / env vars CI needs
#   muster ci run <command> …      run a command for CI: --json under the hood,
#                                  grouped logs, outputs, step summary, annotations
#                                  (the engine behind the GitHub Action)

source "$MUSTER_ROOT/lib/core/ci.sh"

_ci_usage() {
  echo "Usage: muster ci <command> [flags]"
  echo ""
  echo "Commands:"
  echo "  init github       Write .github/workflows/muster-deploy.yml (shows it first)"
  echo "  init gitlab       Write .gitlab-ci.yml (shows it first)"
  echo "  env [--json]      List the secrets and env vars a CI deploy needs"
  echo "  run <command>     Run deploy|rollback|restart|status|fleet-deploy|fleet-rollback|"
  echo "                    fleet-restart|fleet-status for CI (logs, summary, outputs)"
  echo ""
  echo "init flags:"
  echo "  --yes, -y         Write the file without asking"
  echo "  --force           Overwrite an existing file"
  echo "  --stdout          Only print the file"
  echo "  --branch B        Deploy on push to B (default: main)"
  echo "  --environment E   GitHub environment for the deploy job (default: production)"
  echo "  --action-ref R    Muster-dev/muster action ref (default: v0)"
  echo ""
  echo "run flags:"
  echo "  --services \"a b\"     Services (space or comma separated; default: all)"
  echo "  --server NAME        Fleet server (fleet-* commands; deploy → fleet-deploy)"
  echo "  --group NAME         Fleet group  (fleet-* commands; deploy → fleet-deploy)"
  echo "  --dry-run            Plan only"
  echo "  --stop-on-failure    Stop at the first failed service"
  echo "  --from SVC           Resume from SVC in deploy order"
  echo "  --approve-hooks      Approve the repo's hooks on this runner (--yes)"
  echo "  --explain-on-failure Add muster explain --json for the first failure"
  echo "  --events FILE        Keep the raw NDJSON events here"
  echo "  --args \"…\"           Extra arguments for the muster command"
  echo ""
  echo "  Writes \$GITHUB_OUTPUT (result, deployed, failed, summary-json, duration),"
  echo "  \$GITHUB_STEP_SUMMARY and ::error annotations when they exist; elsewhere it"
  echo "  prints the summary. Exit code is the command's."
}

cmd_ci() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    init) _ci_cmd_init "$@" ;;
    env) _ci_cmd_env "$@" ;;
    run) _ci_cmd_run "$@" ;;
    ""|-h|--help|help) _ci_usage ;;
    *)
      err "Unknown ci command: ${sub}"
      source "$MUSTER_ROOT/lib/core/suggest.sh"
      _suggest_print "$sub" init env run || true
      echo "Run 'muster ci --help' for usage."
      return 1
      ;;
  esac
}

# ══════════════════════════════════════════════════════════════
# Project facts shared by init and env
# ══════════════════════════════════════════════════════════════

# Fills: _CIF_SERVICES (deployable, in order), _CIF_PROJECT, _CIF_DIR,
# _CIF_REMOTE (true if any service deploys over SSH), _CIF_K8S, _CIF_FLEET
# (none|ssh|cloud|both), _CIF_SECRETS (NAME|description lines), _CIF_VARS
# (env vars hooks use; NAME|service|required lines)
_ci_project_facts() {
  _CIF_SERVICES=() _CIF_PROJECT="" _CIF_DIR="" _CIF_REMOTE=false _CIF_K8S=false
  _CIF_FLEET="none" _CIF_SECRETS="" _CIF_VARS=""

  _CIF_DIR=$(dirname "$CONFIG_FILE")
  _CIF_PROJECT=$(config_get '.project' 2>/dev/null)
  [[ -z "$_CIF_PROJECT" || "$_CIF_PROJECT" == "null" ]] && _CIF_PROJECT=$(basename "$_CIF_DIR")

  local order svc
  order=$(jq -r '(.deploy_order // (.services | keys))[]' "$CONFIG_FILE" 2>/dev/null)
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    [[ "$(config_get ".services.${svc}.skip_deploy" 2>/dev/null)" == "true" ]] && continue
    _CIF_SERVICES[${#_CIF_SERVICES[@]}]="$svc"
  done <<< "$order"

  source "$MUSTER_ROOT/lib/core/preflight.sh" 2>/dev/null || true

  local seen="|"
  for svc in "${_CIF_SERVICES[@]+"${_CIF_SERVICES[@]}"}"; do
    if [[ "$(config_get ".services.${svc}.remote.enabled" 2>/dev/null)" == "true" ]]; then
      _CIF_REMOTE=true
    fi
    local hook="${_CIF_DIR}/.muster/hooks/${svc}/deploy.sh"
    if [[ "$(config_get ".services.${svc}.k8s" 2>/dev/null)" != "null" ]] \
      || grep -q 'kubectl' "$hook" 2>/dev/null; then
      _CIF_K8S=true
    fi
    # Credentials → MUSTER_CRED_<KEY>
    local mode key upper
    mode=$(config_get ".services.${svc}.credentials.mode" 2>/dev/null)
    if [[ "$mode" != "off" && "$mode" != "null" && -n "$mode" ]]; then
      while IFS= read -r key; do
        [[ -z "$key" || "$key" == "null" ]] && continue
        upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
        [[ "$upper" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [[ "$seen" == *"|MUSTER_CRED_${upper}|"* ]] && continue
        seen="${seen}MUSTER_CRED_${upper}|"
        _CIF_SECRETS="${_CIF_SECRETS}MUSTER_CRED_${upper}|credential '${key}' for ${svc}
"
      done < <(config_get ".services.${svc}.credentials.required[]" 2>/dev/null)
    fi
    # Env vars the hook reads that nothing provides
    if declare -f _pf_env_refs >/dev/null 2>&1 && [[ -f "$hook" ]]; then
      local name bare
      while IFS= read -r name; do
        bare="${name%!}"
        [[ -z "$bare" ]] && continue
        _pf_env_ignored "$bare" && continue
        _ci_env_file_defines "$bare" && continue
        [[ "$seen" == *"|${bare}|"* ]] && continue
        seen="${seen}${bare}|"
        local req=optional
        [[ "$name" == *"!" ]] && req=required
        _CIF_VARS="${_CIF_VARS}${bare}|${svc}|${req}
"
      done < <(_pf_env_refs "$hook")
    fi
  done

  # Fleet transport (project remotes.json)
  if [[ -f "${_CIF_DIR}/remotes.json" ]]; then
    local t_ssh t_cloud
    t_cloud=$(jq '[.machines // {} | to_entries[] | select(.value.transport == "cloud")] | length' "${_CIF_DIR}/remotes.json" 2>/dev/null)
    t_ssh=$(jq '[.machines // {} | to_entries[] | select((.value.transport // "ssh") != "cloud")] | length' "${_CIF_DIR}/remotes.json" 2>/dev/null)
    if [[ "${t_cloud:-0}" -gt 0 && "${t_ssh:-0}" -gt 0 ]]; then _CIF_FLEET=both
    elif [[ "${t_cloud:-0}" -gt 0 ]]; then _CIF_FLEET=cloud
    elif [[ "${t_ssh:-0}" -gt 0 ]]; then _CIF_FLEET=ssh
    fi
  fi

  if [[ "$_CIF_REMOTE" == "true" || "$_CIF_FLEET" == "ssh" || "$_CIF_FLEET" == "both" ]]; then
    _CIF_SECRETS="${_CIF_SECRETS}MUSTER_SSH_KEY|private key for SSH deploys (ssh-key input)
MUSTER_KNOWN_HOSTS|known_hosts lines for your servers: ssh-keyscan -H host (known-hosts input)
"
  fi
  if [[ "$_CIF_FLEET" == "cloud" || "$_CIF_FLEET" == "both" ]]; then
    _CIF_SECRETS="${_CIF_SECRETS}MUSTER_CLOUD_TOKEN|Fleet Cloud CLI token, mst_cli_… (cloud-token input)
"
  fi
  if [[ "$_CIF_K8S" == "true" ]]; then
    _CIF_SECRETS="${_CIF_SECRETS}KUBECONFIG|kubeconfig for the cluster (written to ~/.kube/config)
"
  fi
}

# .env committed to the repo defines NAME (then CI already has it)
_ci_env_file_defines() {
  local f="${_CIF_DIR}/.env"
  [[ -f "$f" ]] || return 1
  ( cd "$_CIF_DIR" && git ls-files --error-unmatch .env >/dev/null 2>&1 ) || return 1
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?${1}=" "$f" 2>/dev/null
}

_ci_require_project() {
  if ! CONFIG_FILE=$(find_config 2>/dev/null); then
    err "No muster.json found here (run: muster setup)"
    return 1
  fi
  export CONFIG_FILE
  has_cmd jq || { err "jq is required"; return 1; }
}

# ══════════════════════════════════════════════════════════════
# muster ci env
# ══════════════════════════════════════════════════════════════

_ci_cmd_env() {
  local json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=true; shift ;;
      -h|--help) echo "Usage: muster ci env [--json]"; return 0 ;;
      *) err "Unknown flag: $1"; return 1 ;;
    esac
  done
  _ci_require_project || return 1
  _ci_project_facts

  if [[ "$json" == "true" ]]; then
    local secrets vars services
    secrets=$(printf '%s' "$_CIF_SECRETS" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("|") | {name: .[0], description: .[1]})')
    vars=$(printf '%s' "$_CIF_VARS" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("|") | {name: .[0], service: .[1], required: (.[2] == "required")})')
    services=$(printf '%s\n' "${_CIF_SERVICES[@]+"${_CIF_SERVICES[@]}"}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
    jq -n -c --arg p "$_CIF_PROJECT" --argjson s "$services" --argjson sec "$secrets" --argjson v "$vars" \
      --arg fleet "$_CIF_FLEET" --argjson remote "$_CIF_REMOTE" --argjson k8s "$_CIF_K8S" \
      '{project: $p, services: $s, secrets: $sec, env: $v, fleet: $fleet, remote: $remote, k8s: $k8s,
        always: [{name: "MUSTER_APPROVE_HOOKS", description: "1 approves the repo hooks on the runner (the action does this with approve-hooks)"}]}'
    return 0
  fi

  echo ""
  printf '  %bCI needs for %s%b  %b(%d service%s)%b\n' "${BOLD}" "$_CIF_PROJECT" "${RESET}" "${DIM}" \
    "${#_CIF_SERVICES[@]}" "$( (( ${#_CIF_SERVICES[@]} != 1 )) && echo s)" "${RESET}"
  echo ""
  printf '  %bSecrets%b %b(Settings → Secrets and variables → Actions)%b\n' "${BOLD}" "${RESET}" "${DIM}" "${RESET}"
  if [[ -z "$_CIF_SECRETS" ]]; then
    printf '    %bnone%b\n' "${DIM}" "${RESET}"
  else
    printf '%s' "$_CIF_SECRETS" | while IFS='|' read -r n d; do
      [[ -z "$n" ]] && continue
      printf '    %-22s %b%s%b\n' "$n" "${DIM}" "$d" "${RESET}"
    done
  fi
  echo ""
  printf '  %bEnv vars your hooks read%b %b(secrets or variables; not in a committed .env)%b\n' "${BOLD}" "${RESET}" "${DIM}" "${RESET}"
  if [[ -z "$_CIF_VARS" ]]; then
    printf '    %bnone%b\n' "${DIM}" "${RESET}"
  else
    printf '%s' "$_CIF_VARS" | while IFS='|' read -r n s r; do
      [[ -z "$n" ]] && continue
      printf '    %-22s %b%s, %s%b\n' "$n" "${DIM}" "$s" "$r" "${RESET}"
    done
  fi
  echo ""
  printf '  %bAlways%b\n' "${BOLD}" "${RESET}"
  printf '    %-22s %b%s%b\n' "MUSTER_APPROVE_HOOKS" "${DIM}" "1 approves the repo's hooks on the runner (action: approve-hooks)" "${RESET}"
  printf '    %-22s %b%s%b\n' "MUSTER_TOKEN" "${DIM}" "not needed: muster ci run / the action make a one-off token" "${RESET}"
  echo ""
}

# ══════════════════════════════════════════════════════════════
# muster ci init github|gitlab
# ══════════════════════════════════════════════════════════════

_ci_cmd_init() {
  local provider="" yes=false force=false to_stdout=false branch="main" envname="production" ref="v0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      github|gitlab) provider="$1"; shift ;;
      --yes|-y) yes=true; shift ;;
      --force|-f) force=true; shift ;;
      --stdout) to_stdout=true; shift ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --environment) envname="${2:-}"; shift 2 ;;
      --action-ref) ref="${2:-}"; shift 2 ;;
      -h|--help) _ci_usage; return 0 ;;
      *)
        err "Unknown argument: $1"
        echo "Usage: muster ci init github|gitlab [--yes] [--force] [--stdout] [--branch B] [--environment E]"
        return 1
        ;;
    esac
  done
  if [[ -z "$provider" ]]; then
    err "Which CI? muster ci init github  or  muster ci init gitlab"
    return 1
  fi
  # Values end up in YAML: keep them to safe characters
  local _v
  for _v in "$branch" "$envname" "$ref"; do
    if [[ ! "$_v" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      err "Invalid value: ${_v}"
      return 1
    fi
  done

  _ci_require_project || return 1
  _ci_project_facts

  local rel content
  if [[ "$provider" == "github" ]]; then
    rel=".github/workflows/muster-deploy.yml"
    content=$(_ci_github_workflow "$branch" "$envname" "$ref")
  else
    rel=".gitlab-ci.yml"
    content=$(_ci_gitlab_pipeline "$branch" "$envname")
  fi

  if [[ "$to_stdout" == "true" ]]; then
    printf '%s\n' "$content"
    return 0
  fi

  local dest="${_CIF_DIR}/${rel}"
  echo ""
  printf '  %b%s%b %b(%s)%b\n' "${BOLD}" "$rel" "${RESET}" "${DIM}" "$_CIF_PROJECT" "${RESET}"
  printf '  %b%s%b\n' "${DIM}" "────────────────────────────────────────" "${RESET}"
  printf '%s\n' "$content" | sed 's/^/  /'
  printf '  %b%s%b\n' "${DIM}" "────────────────────────────────────────" "${RESET}"
  echo ""

  if [[ -f "$dest" && "$force" != "true" ]]; then
    warn "${rel} already exists. Pass --force to overwrite it."
    return 1
  fi

  if [[ "$yes" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      info "Not written. Re-run with --yes to write ${rel}."
      return 0
    fi
    printf '  Write %s? [y/N] ' "$rel"
    local ans=""
    IFS= read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) info "Not written."; return 0 ;; esac
  fi

  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" > "$dest"
  ok "Wrote ${rel}"
  if [[ -n "$_CIF_SECRETS" ]]; then
    printf '  %bAdd these secrets:%b %s\n' "${DIM}" "${RESET}" \
      "$(printf '%s' "$_CIF_SECRETS" | cut -d'|' -f1 | grep -v '^$' | paste -sd ' ' -)"
  fi
  printf '  %bDetails: muster ci env%b\n' "${DIM}" "${RESET}"
  echo ""
}

# Secrets/env lines for a YAML env: block. Args: indent style(github|gitlab)
_ci_env_yaml() {
  local ind="$1" style="$2" n d
  printf '%s' "$_CIF_SECRETS" | while IFS='|' read -r n d; do
    [[ -z "$n" ]] && continue
    case "$n" in MUSTER_SSH_KEY|MUSTER_KNOWN_HOSTS|MUSTER_CLOUD_TOKEN|KUBECONFIG) continue ;; esac
    if [[ "$style" == "github" ]]; then
      printf '%s%s: ${{ secrets.%s }}\n' "$ind" "$n" "$n"
    fi
  done
  printf '%s' "$_CIF_VARS" | while IFS='|' read -r n d _r; do
    [[ -z "$n" ]] && continue
    if [[ "$style" == "github" ]]; then
      printf '%s%s: ${{ secrets.%s }}\n' "$ind" "$n" "$n"
    fi
  done
}

_ci_github_workflow() {
  local branch="$1" envname="$2" ref="$3"
  local services_list
  services_list=$(printf '%s ' "${_CIF_SERVICES[@]+"${_CIF_SERVICES[@]}"}")
  services_list="${services_list% }"
  local env_lines
  env_lines=$(_ci_env_yaml "          " github)

  cat <<EOF
# Generated by muster ci init github — edit freely.
# Services (deploy order): ${services_list:-none}
# Secrets: see \`muster ci env\`
name: muster deploy

on:
  push:
    branches: [${branch}]
  pull_request:
    branches: [${branch}]
  workflow_dispatch:
    inputs:
      services:
        description: "Services to deploy, space separated (empty = all: ${services_list})"
        required: false
        default: ""
        type: string
      dry-run:
        description: "Plan only"
        required: false
        default: false
        type: boolean

permissions:
  contents: read

jobs:
  plan:
    name: Deploy plan (dry run)
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: Muster-dev/muster@${ref}
        with:
          command: deploy
          dry-run: true

  deploy:
    name: Deploy
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    environment: ${envname}
    # One deploy at a time; a newer push waits instead of cancelling a running deploy
    concurrency:
      group: muster-deploy-${envname}
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v4
EOF
  if [[ "$_CIF_K8S" == "true" ]]; then
    cat <<'EOF'
      - name: Configure kubectl
        env:
          KUBECONFIG_DATA: ${{ secrets.KUBECONFIG }}
        run: |
          mkdir -p ~/.kube
          printf '%s\n' "$KUBECONFIG_DATA" > ~/.kube/config
          chmod 600 ~/.kube/config
EOF
  fi
  cat <<EOF
      - uses: Muster-dev/muster@${ref}
        id: muster
        with:
          command: deploy
          services: \${{ inputs.services }}
          dry-run: \${{ inputs.dry-run || false }}
          stop-on-failure: true
          explain-on-failure: true
EOF
  if [[ "$_CIF_REMOTE" == "true" || "$_CIF_FLEET" == "ssh" || "$_CIF_FLEET" == "both" ]]; then
    cat <<'EOF'
          ssh-key: ${{ secrets.MUSTER_SSH_KEY }}
          known-hosts: ${{ secrets.MUSTER_KNOWN_HOSTS }}
EOF
  fi
  if [[ "$_CIF_FLEET" == "cloud" || "$_CIF_FLEET" == "both" ]]; then
    cat <<'EOF'
          cloud-token: ${{ secrets.MUSTER_CLOUD_TOKEN }}
EOF
  fi
  if [[ -n "$env_lines" ]]; then
    printf '        env:\n%s\n' "$env_lines"
  fi
}

_ci_gitlab_pipeline() {
  local branch="$1" envname="$2" ver="${MUSTER_VERSION:-0.7.3}"
  local services_list
  services_list=$(printf '%s ' "${_CIF_SERVICES[@]+"${_CIF_SERVICES[@]}"}")
  services_list="${services_list% }"
  cat <<EOF
# Generated by muster ci init gitlab — edit freely.
# Services (deploy order): ${services_list:-none}
# Secrets: add them as masked CI/CD variables (see \`muster ci env\`).
stages: [plan, deploy]

variables:
  MUSTER_VERSION: "${ver}"
  MUSTER_APPROVE_HOOKS: "1"
  # Space-separated services; empty deploys all
  MUSTER_SERVICES: ""

.muster:
  image: ubuntu:24.04
  before_script:
    - apt-get update -qq && apt-get install -y -qq bash git jq curl ca-certificates openssh-client >/dev/null
    - git clone --quiet --depth 1 --branch "v\${MUSTER_VERSION}" https://github.com/Muster-dev/muster.git /opt/muster
    - export PATH="/opt/muster/bin:\$PATH"
EOF
  if [[ "$_CIF_REMOTE" == "true" || "$_CIF_FLEET" == "ssh" || "$_CIF_FLEET" == "both" ]]; then
    cat <<'EOF'
    # SSH: MUSTER_SSH_KEY (file variable) and MUSTER_KNOWN_HOSTS; host keys are checked
    - install -d -m 700 ~/.ssh
    - printf '%s\n' "$MUSTER_KNOWN_HOSTS" > ~/.ssh/known_hosts
    - eval "$(ssh-agent -s)" && ssh-add "$MUSTER_SSH_KEY"
EOF
  fi
  if [[ "$_CIF_K8S" == "true" ]]; then
    cat <<'EOF'
    - install -d -m 700 ~/.kube && cp "$KUBECONFIG" ~/.kube/config 2>/dev/null || true
EOF
  fi
  cat <<EOF

muster:plan:
  extends: .muster
  stage: plan
  rules:
    - if: \$CI_PIPELINE_SOURCE == "merge_request_event"
  script:
    - muster ci run deploy --dry-run --services "\$MUSTER_SERVICES"

muster:deploy:
  extends: .muster
  stage: deploy
  environment: ${envname}
  resource_group: muster-deploy-${envname}
  rules:
    - if: \$CI_COMMIT_BRANCH == "${branch}" && \$CI_PIPELINE_SOURCE != "merge_request_event"
    - if: \$CI_PIPELINE_SOURCE == "web"
  script:
    - muster ci run deploy --stop-on-failure --approve-hooks --explain-on-failure --services "\$MUSTER_SERVICES" --events muster-events.ndjson
  artifacts:
    when: always
    paths: [muster-events.ndjson, muster-summary.md]
EOF
}

# ══════════════════════════════════════════════════════════════
# muster ci run
# ══════════════════════════════════════════════════════════════

_CIR_TOKEN_NAME=""
_CIR_TMP=""
_CIR_ANNOT_ORIG=""
_CIR_RC=0

_ci_run_cleanup() {
  if [[ -n "$_CIR_TOKEN_NAME" ]] && declare -f _auth_update_tokens >/dev/null 2>&1; then
    _auth_update_tokens --arg n "$_CIR_TOKEN_NAME" '.tokens = [.tokens[] | select(.name != $n)]' >/dev/null 2>&1 || true
    _CIR_TOKEN_NAME=""
  fi
  [[ -n "$_CIR_TMP" && -d "$_CIR_TMP" ]] && rm -rf "$_CIR_TMP"
  _CIR_TMP=""
}

# One-off deploy-scope token so the --json API gate passes; revoked at exit.
_ci_run_token() {
  [[ -n "${MUSTER_TOKEN:-}" ]] && return 0
  source "$MUSTER_ROOT/lib/core/auth.sh"
  local name tok
  name="ci-$(date +%s)-$$"
  tok=$(_auth_create_token_internal "$name" "deploy" 2>/dev/null) || tok=""
  if [[ -z "$tok" ]]; then
    err "Could not create a local API token for this run" >&2
    return 1
  fi
  _CIR_TOKEN_NAME="$name"
  _ci_github && printf '::add-mask::%s\n' "$tok"
  export MUSTER_TOKEN="$tok"
}

# jq filter: NDJSON events → readable log lines (::group:: per service on GitHub)
# shellcheck disable=SC2016
_CIR_RENDER='
def openg(t): if $gh == "1" then "::group::" + t else "==> " + t end;
def closeg: if $gh == "1" then ["::endgroup::"] else [] end;
def s: if . == null then "" else tostring end;
foreach (inputs | ((fromjson? | objects) // {event: "_raw", line: .})) as $e
  ({open: false, out: []};
   .out = []
   | ($e.event // "") as $ev
   | if $ev == "start" then
       (if .open then .out += closeg else . end)
       | .out += [openg((($e.action // $act) | s) + " " + ($e.service | s)
           + (if $e.total then " (" + ($e.index | s) + "/" + ($e.total | s) + ")" else "" end))]
       | .open = true
     elif $ev == "log" then .out += ["  " + ($e.line | s)]
     elif $ev == "git_pull" then .out += ["  git pull " + ($e.remote | s) + " " + ($e.branch | s) + ": " + ($e.status | s)]
     elif $ev == "done" then
       .out += [ if $e.status == "success" then "✓ " + ($e.service | s) + " " + ($act) + " ok"
                 elif $e.status == "timeout" then "✗ " + ($e.service | s) + " timed out after " + ($e.timeout | s) + "s"
                 elif $e.status == "blocked" then "✗ " + ($e.service | s) + " blocked by hook security (approve the hooks or fix dangerous commands)"
                 else "✗ " + ($e.service | s) + " failed (exit " + ($e.exit_code | s) + ")" end ]
     elif $ev == "health" then
       .out += [ if $e.status == "healthy" then "  ✓ healthy"
                 elif $e.status == "unhealthy" then "  ✗ health check failed"
                 else "  health check…" end ]
     elif $ev == "hint" then
       .out += ["  Likely cause: " + ($e.hint.title | s), "  Try: " + ($e.hint.try | s)]
     elif $ev == "diagnosis" then
       .out += ["  k8s: " + ($e.pattern | s) + " — " + ($e.summary | s) + ". " + ($e.hint | s)]
     elif $ev == "verify_warning" then .out += ["  ! " + ($e.message | s)]
     elif $ev == "restart" then .out += [($e.message | s)]
     elif $ev == "dry_run" then
       .out += ["• would " + $act + " " + ($e.service | s) + " (" + ($e.index | s) + "/" + ($e.total | s) + ")"
                + (if $e.hook then " — " + ($e.hook | s | sub(".*/\\.muster/"; ".muster/")) + ", " + ($e.hook_lines | s) + " lines" else "" end)]
     elif $ev == "skipped" then .out += ["- " + ($e.service | s) + " skipped (" + ($e.reason | s) + ")"]
     elif ($ev == "summary" or $ev == "complete" or $ev == "stopped" or $ev == "error" or $ev == "cancelled") then
       (if .open then .out += closeg | .open = false else . end)
       | .out += [ if $ev == "summary" then
                     "Summary: " + ([ ("deployed", "rolled_back", "restarted", "failed", "skipped", "not_run") as $k
                                      | select(($e[$k] // 0) > 0) | ($e[$k] | s) + " " + ($k | gsub("_"; " ")) ] | join(", "))
                     + " in " + ($e.duration | s) + "s"
                   elif $ev == "complete" then (if $e.dry_run then "Dry run complete (" + ($e.total | s) + " services)" else "Complete" end)
                   elif $ev == "stopped" then "Stopped after " + ($e.after | s) + " failed; not run: " + (($e.remaining // []) | join(", "))
                   elif $ev == "cancelled" then "Cancelled"
                   else "✗ " + ($e.reason | s) + ": " + ($e.message | s)
                        + (if $e.files then " [" + ([$e.files[] | (.key | s) + " " + (.state // .issue | s)] | join(", ")) + "]" else "" end) end ]
     elif $ev == "_raw" then .out += [$e.line | s]
     else . end;
   .out[])
'

_ci_split_list() {
  printf '%s' "$1" | tr ',' ' ' | tr -s ' \t\n' '\n' | grep -v '^$' || true
}

_ci_md_cell() {
  local s="$1"
  s="${s//|/\\|}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

_ci_cmd_run() {
  local command="" services_raw="" server="" group="" dry_run=false stop=false from="" approve=false
  local explain=false events="" extra=""
  local summary_file="${GITHUB_STEP_SUMMARY:-}" output_file="${GITHUB_OUTPUT:-}"
  local pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --services) services_raw="${services_raw} ${2:-}"; shift 2 ;;
      --services=*) services_raw="${services_raw} ${1#--services=}"; shift ;;
      --server) server="${2:-}"; shift 2 ;;
      --group) group="${2:-}"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --stop-on-failure) stop=true; shift ;;
      --from) from="${2:-}"; shift 2 ;;
      --approve-hooks|--yes|-y) approve=true; shift ;;
      --explain-on-failure|--explain) explain=true; shift ;;
      --events) events="${2:-}"; shift 2 ;;
      --summary) summary_file="${2:-}"; shift 2 ;;
      --output) output_file="${2:-}"; shift 2 ;;
      --args) extra="${2:-}"; shift 2 ;;
      -h|--help) _ci_usage; return 0 ;;
      -*) err "Unknown flag: $1"; return 1 ;;
      *) if [[ -z "$command" ]]; then command="$1"; else pos[${#pos[@]}]="$1"; fi; shift ;;
    esac
  done
  [[ -z "$command" ]] && command="deploy"
  _ci_truthy "${MUSTER_APPROVE_HOOKS:-}" && approve=true

  local services=() _s
  while IFS= read -r _s; do
    [[ -n "$_s" ]] && services[${#services[@]}]="$_s"
  done < <(_ci_split_list "${services_raw} ${pos[*]+"${pos[*]}"}")

  local extra_args=()
  if [[ -n "$extra" ]]; then
    local _w
    # shellcheck disable=SC2086
    for _w in $extra; do extra_args[${#extra_args[@]}]="$_w"; done
  fi

  # deploy/rollback/restart/status to a server or group → fleet
  local target="${server:-$group}"
  if [[ -n "$server" && -n "$group" ]]; then
    err "Pass --server or --group, not both"
    return 1
  fi
  if [[ -n "$target" ]]; then
    case "$command" in
      deploy|rollback|restart|status) command="fleet-${command}" ;;
    esac
  fi

  local action="$command"
  case "$command" in
    deploy|rollback|restart|status|fleet-deploy|fleet-rollback|fleet-restart|fleet-status) ;;
    *)
      err "Unsupported command for ci run: ${command}"
      echo "Use one of: deploy rollback restart status fleet-deploy fleet-rollback fleet-restart fleet-status"
      return 1
      ;;
  esac
  local _vw
  for _vw in "$target" "$from" "${services[@]+"${services[@]}"}"; do
    if [[ -n "$_vw" && ! "$_vw" =~ ^[A-Za-z0-9_.@:-]+$ ]]; then
      err "Invalid name: ${_vw}"
      return 1
    fi
  done

  case "$command" in
    deploy|rollback|restart|status) _ci_require_project || return 1 ;;
  esac

  has_cmd jq || { err "jq is required"; return 1; }
  _CIR_TMP=$(mktemp -d "${TMPDIR:-/tmp}/muster-ci.XXXXXX") || return 1
  trap '_ci_run_cleanup; exit 130' INT TERM

  [[ -z "$events" ]] && events="${_CIR_TMP}/events.ndjson"
  : > "$events"
  local rows="${_CIR_TMP}/rows.json"
  printf '[]' > "$rows"

  _ci_run_token || { _ci_run_cleanup; return 1; }

  local gh=0
  _ci_github && gh=1
  local M="$MUSTER_ROOT/bin/muster"
  # The CLI's own annotations would duplicate ours
  _CIR_ANNOT_ORIG="${MUSTER_GITHUB_ANNOTATIONS:-}"
  export MUSTER_GITHUB_ANNOTATIONS=off MUSTER_NONINTERACTIVE=1 NO_COLOR="${NO_COLOR:-1}"

  local t0 rc=0
  t0=$(date +%s)

  case "$command" in
    deploy)
      local args=(deploy --json)
      [[ "$dry_run" == "true" ]] && args[${#args[@]}]="--dry-run"
      [[ "$stop" == "true" ]] && args[${#args[@]}]="--stop-on-failure"
      [[ -n "$from" ]] && { args[${#args[@]}]="--from"; args[${#args[@]}]="$from"; }
      [[ "$approve" == "true" ]] && args[${#args[@]}]="--yes"
      _ci_run_stream "$events" "deploy" "$gh" "$M" "${args[@]}" "${extra_args[@]+"${extra_args[@]}"}" "${services[@]+"${services[@]}"}"
      rc=$_CIR_RC
      ;;
    rollback|restart)
      if (( ${#services[@]} == 0 )); then
        err "${command} needs --services (one or more services)"
        _ci_run_cleanup; return 1
      fi
      local svc
      for svc in "${services[@]}"; do
        local args=("$command" "$svc" --json)
        [[ "$approve" == "true" || "$command" == "restart" ]] && args[${#args[@]}]="--yes"
        _ci_run_stream "$events" "$command" "$gh" "$M" "${args[@]}" "${extra_args[@]+"${extra_args[@]}"}"
        (( _CIR_RC != 0 )) && rc=$_CIR_RC
        if (( _CIR_RC != 0 )) && [[ "$stop" == "true" ]]; then break; fi
      done
      ;;
    status)
      local doc="${_CIR_TMP}/status.json"
      "$M" status --json </dev/null > "$doc" 2>"${_CIR_TMP}/status.err" || rc=$?
      cat "${_CIR_TMP}/status.err" >&2
      if (( rc == 0 )) && jq -e .services "$doc" >/dev/null 2>&1; then
        local want=""
        (( ${#services[@]} > 0 )) && want=$(printf '%s\n' "${services[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
        jq -c --argjson want "${want:-null}" '[.services | to_entries[]
            | select($want == null or (.key as $k | $want | index($k)))
            | {service: .key, name: (.value.name // .key), result: .value.status, duration: 0,
               health: .value.status, commit: (.value.last_deploy.commit // null)}]' "$doc" > "$rows"
        jq -r '.[] | (if .result == "healthy" then "✓ " elif (.result == "unhealthy" or .result == "blocked") then "✗ " else "- " end) + .service + ": " + .result' "$rows"
        if jq -e 'any(.[]; .result == "unhealthy" or .result == "blocked")' "$rows" >/dev/null; then
          rc=1
        fi
      fi
      ;;
    fleet-*)
      local sub="${command#fleet-}" args=(fleet "${command#fleet-}")
      [[ -n "$target" ]] && args[${#args[@]}]="$target"
      case "$sub" in
        deploy) [[ "$dry_run" == "true" ]] && args[${#args[@]}]="--dry-run" ;;
        rollback)
          local svc
          for svc in "${services[@]+"${services[@]}"}"; do args[${#args[@]}]="--service"; args[${#args[@]}]="$svc"; done ;;
        restart)
          [[ -z "$target" ]] && { err "fleet-restart needs --server"; _ci_run_cleanup; return 1; }
          local svc
          for svc in "${services[@]+"${services[@]}"}"; do args[${#args[@]}]="$svc"; done
          args[${#args[@]}]="--yes" ;;
      esac
      local label="${target:-all servers}"
      if (( gh == 1 )); then printf '::group::%s %s\n' "$command" "$label"; else printf '==> %s %s\n' "$command" "$label"; fi
      "$M" "${args[@]}" "${extra_args[@]+"${extra_args[@]}"}" </dev/null 2>&1 | sed 's/^/  /'
      rc=${PIPESTATUS[0]}
      (( gh == 1 )) && echo "::endgroup::"
      local res="ok"
      (( rc != 0 )) && res="failed"
      [[ "$dry_run" == "true" && "$sub" == "deploy" && $rc -eq 0 ]] && res="planned"
      jq -n -c --arg s "$label" --arg r "$res" --argjson d "$(( $(date +%s) - t0 ))" \
        '[{service: $s, name: $s, result: $r, duration: $d, health: "-"}]' > "$rows"
      ;;
  esac

  local duration=$(( $(date +%s) - t0 ))

  # Rows from the event stream (deploy/rollback/restart)
  case "$command" in
    deploy|rollback|restart)
      if [[ "$dry_run" == "true" && "$command" == "deploy" ]]; then
        jq -c -s '[.[] | select(.event == "dry_run") | {service, name, result: "planned", duration: 0, health: "-"}]' \
          "$events" > "$rows" 2>/dev/null || printf '[]' > "$rows"
      else
        jq -c -s '[.[] | select(.event == "summary") | .services[]?
                   | {service, name, result, duration, health}]' "$events" > "$rows" 2>/dev/null || printf '[]' > "$rows"
      fi
      # A stream that died before its summary still failed
      if (( rc == 0 )) && ! jq -e -s 'any(.[]; .event == "summary" or .event == "complete")' "$events" >/dev/null 2>&1; then
        rc=1
      fi
      ;;
  esac

  # Commit for the table
  local commit=""
  if [[ -n "${GITHUB_SHA:-}" ]]; then
    commit="${GITHUB_SHA:0:7}"
  elif [[ -n "${CI_COMMIT_SHORT_SHA:-}" ]]; then
    commit="$CI_COMMIT_SHORT_SHA"
  else
    commit=$(git rev-parse --short HEAD 2>/dev/null || true)
  fi

  local result="success"
  (( rc != 0 )) && result="failure"

  # Explain the first failure
  local explain_json="null"
  if [[ "$explain" == "true" && "$result" == "failure" ]]; then
    local first_failed
    first_failed=$(jq -r '[.[] | select(.result == "failed")][0].service // empty' "$rows" 2>/dev/null)
    case "$command" in
      deploy|rollback|restart)
        local ex_out
        if [[ -n "$first_failed" ]]; then
          ex_out=$("$M" explain "$first_failed" --json </dev/null 2>/dev/null) || true
        else
          ex_out=$("$M" explain --json </dev/null 2>/dev/null) || true
        fi
        if printf '%s' "$ex_out" | jq -e 'type == "object"' >/dev/null 2>&1; then
          explain_json=$(printf '%s' "$ex_out" | jq -c .)
        fi
        ;;
    esac
  fi

  # Hint per failed service from the stream (falls back to explain)
  local hints="${_CIR_TMP}/hints.json"
  jq -c -s '[.[] | select(.event == "hint") | {service, title: .hint.title, try: .hint.try}]' "$events" > "$hints" 2>/dev/null \
    || printf '[]' > "$hints"
  if [[ "$explain_json" != "null" ]] && printf '%s' "$explain_json" | jq -e '.hint.title' >/dev/null 2>&1; then
    jq -c --argjson ex "$explain_json" \
      'if any(.[]; .service == $ex.service) then . else . + [{service: $ex.service, title: $ex.hint.title, try: $ex.hint.try}] end' \
      "$hints" > "${hints}.tmp" && mv "${hints}.tmp" "$hints"
  fi

  local errors="${_CIR_TMP}/errors.json"
  jq -c -s '[.[] | select(.event == "error") | {reason, message, files: (.files // [])}]' "$events" > "$errors" 2>/dev/null \
    || printf '[]' > "$errors"

  local summary_json
  summary_json=$(jq -c -n --arg cmd "$command" --arg result "$result" --argjson duration "$duration" \
    --argjson rc "$rc" --argjson dry "$dry_run" --arg commit "$commit" --arg ver "${MUSTER_VERSION:-}" \
    --arg target "$target" --slurpfile rows "$rows" --slurpfile hints "$hints" --slurpfile errors "$errors" \
    --argjson explain "$explain_json" \
    '{command: $cmd, result: $result, exit_code: $rc, duration: $duration, dry_run: $dry,
      target: (if $target == "" then null else $target end), commit: $commit, muster_version: $ver,
      services: $rows[0], hints: $hints[0], errors: $errors[0], explain: $explain}')

  # ── Annotations ──
  if _ci_annotations_on_for_run; then
    _ci_run_annotations "$summary_json" "$action"
  fi

  # ── Outputs ──
  local deployed failed
  deployed=$(printf '%s' "$summary_json" | jq -c '[.services[] | select(.result == "deployed" or .result == "rolled back" or .result == "restarted" or .result == "ok") | .service]')
  failed=$(printf '%s' "$summary_json" | jq -c '[.services[] | select(.result == "failed" or .health == "unhealthy" or .result == "unhealthy" or .result == "blocked") | .service] | unique')
  if [[ -n "$output_file" ]]; then
    {
      printf 'result=%s\n' "$result"
      printf 'deployed=%s\n' "$deployed"
      printf 'failed=%s\n' "$failed"
      printf 'duration=%s\n' "$duration"
      printf 'exit-code=%s\n' "$rc"
      printf 'summary-json=%s\n' "$summary_json"
      printf 'explain-json=%s\n' "$explain_json"
    } >> "$output_file"
  fi

  # ── Summary ──
  local md
  md=$(_ci_run_markdown "$summary_json" "$action")
  if [[ -n "$summary_file" ]]; then
    printf '%s\n\n' "$md" >> "$summary_file"
  fi
  if [[ -n "${GITLAB_CI:-}" ]]; then
    printf '%s\n' "$md" > muster-summary.md 2>/dev/null || true
  fi
  if [[ -z "$summary_file" ]]; then
    echo ""
    printf '%s\n' "$md"
  fi

  _ci_run_cleanup
  trap - INT TERM
  return "$rc"
}

# Annotations are emitted by ci run even though the child has them off
_ci_annotations_on_for_run() {
  _ci_github || return 1
  case "${_CIR_ANNOT_ORIG:-}" in
    off|false|0|no) return 1 ;;
  esac
  return 0
}

# Run one muster --json command; raw events appended to FILE, rendered to stdout.
# Args: events_file action gh muster args...   Sets _CIR_RC.
_ci_run_stream() {
  local events="$1" act="$2" gh="$3"
  shift 3
  _CIR_RC=0
  "$@" </dev/null | tee -a "$events" | jq -n -R -r --unbuffered --arg gh "$gh" --arg act "$act" "$_CIR_RENDER"
  _CIR_RC=${PIPESTATUS[0]}
  return 0
}

_ci_run_annotations() {
  local sj="$1" action="$2" root rel=""
  root=$(dirname "${CONFIG_FILE:-.}")
  printf '%s' "$sj" | jq -r '
    . as $r
    | ($r.services[] | select(.result == "failed")
       | . as $s | ([$r.hints[] | select(.service == $s.service)][0]) as $h
       | ["error", $s.service, (if $h then "Likely cause: " + $h.title + "\nTry: " + $h.try else "See the job log for " + $s.service + "." end)]),
    ($r.services[] | select(.health == "unhealthy" or .result == "unhealthy")
       | ["warning", .service, "Health check failed."]),
    ($r.errors[] | ["error", "", (.reason + ": " + .message
       + (if .reason == "hooks_not_approved" then "\nSet approve-hooks: true (the action default) or MUSTER_APPROVE_HOOKS=1 to approve the repo hooks on the runner." else "" end))])
    | map(tostring | gsub("\n"; "\\n")) | join("\u001f")' 2>/dev/null | while IFS=$'\x1f' read -r level svc msg; do
      msg="${msg//\\n/$'\n'}"
      rel=""
      if [[ -n "$svc" && -f "${root}/.muster/hooks/${svc}/${action}.sh" ]]; then
        local abs="${root}/.muster/hooks/${svc}/${action}.sh"
        if [[ -n "${GITHUB_WORKSPACE:-}" && "$abs" == "${GITHUB_WORKSPACE}/"* ]]; then
          rel="${abs#"${GITHUB_WORKSPACE}"/}"
        fi
      fi
      local title="muster ${action} failed"
      [[ -n "$svc" ]] && title="muster ${action} failed: ${svc}"
      [[ "$level" == "warning" ]] && title="muster: ${svc} unhealthy"
      local props
      props="title=$(_ci_gh_escape_prop "$title")"
      [[ -n "$rel" ]] && props="file=$(_ci_gh_escape_prop "$rel"),${props}"
      printf '::%s %s::%s\n' "$level" "$props" "$(_ci_gh_escape_data "$msg")"
    done
}

_ci_run_markdown() {
  local sj="$1" action="$2"
  local result dry dur commit ver target icon verb
  result=$(printf '%s' "$sj" | jq -r .result)
  dry=$(printf '%s' "$sj" | jq -r .dry_run)
  dur=$(printf '%s' "$sj" | jq -r .duration)
  commit=$(printf '%s' "$sj" | jq -r .commit)
  ver=$(printf '%s' "$sj" | jq -r .muster_version)
  target=$(printf '%s' "$sj" | jq -r '.target // ""')
  if [[ "$result" == "success" ]]; then icon="✅"; verb="succeeded"; else icon="❌"; verb="failed"; fi
  [[ "$dry" == "true" ]] && verb="${verb} (dry run)"

  printf '### %s muster %s %s\n\n' "$icon" "$action${target:+ → ${target}}" "$verb"
  local n
  n=$(printf '%s' "$sj" | jq '.services | length')
  if (( n > 0 )); then
    printf '| Service | Result | Duration | Health | Commit |\n'
    printf '|---|---|---|---|---|\n'
    printf '%s' "$sj" | jq -r '.services[] | [.service, .result, (.duration | tostring), (.health // "-"), (.commit // "")] | map(tostring) | join("\u001f")' \
      | while IFS=$'\x1f' read -r svc res d h c; do
        local ri="•"
        case "$res" in
          deployed|"rolled back"|restarted|ok|healthy) ri="✅" ;;
          failed|unhealthy|blocked) ri="❌" ;;
          not_run|skipped) ri="⏭️" ;;
          planned) ri="📝" ;;
        esac
        [[ "$h" == "unhealthy" ]] && ri="⚠️"
        printf '| %s | %s %s | %ss | %s | `%s` |\n' "$(_ci_md_cell "$svc")" "$ri" "$(_ci_md_cell "$res")" "$d" \
          "$(_ci_md_cell "$h")" "$(_ci_md_cell "${c:-${commit:--}}")"
      done
    echo ""
  else
    printf '_No services ran._\n\n'
  fi

  printf '%s' "$sj" | jq -r '.hints[] | [.service, .title, .try] | map(tostring | gsub("\n"; " ")) | join("\u001f")' 2>/dev/null \
    | while IFS=$'\x1f' read -r svc t tr; do
      printf '**%s — Likely cause:** %s  \n**Try:** %s\n\n' "$(_ci_md_cell "$svc")" "$(_ci_md_cell "$t")" "$(_ci_md_cell "$tr")"
    done
  printf '%s' "$sj" | jq -r '.errors[] | [.reason, .message] | map(tostring | gsub("\n"; " ")) | join("\u001f")' 2>/dev/null \
    | while IFS=$'\x1f' read -r r m; do
      printf '> **%s:** %s\n\n' "$(_ci_md_cell "$r")" "$(_ci_md_cell "$m")"
      if [[ "$r" == "hooks_not_approved" ]]; then
        printf '> Set `approve-hooks: true` (the action default) or `MUSTER_APPROVE_HOOKS=1`.\n\n'
      fi
    done
  printf '<sub>muster v%s · %ss total%s</sub>\n' "$ver" "$dur" "${commit:+ · \`${commit}\`}"
}
