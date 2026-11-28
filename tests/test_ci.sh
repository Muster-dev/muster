#!/usr/bin/env bash
# tests/test_ci.sh — muster ci init/env/run, GitHub annotations, CI defaults,
# never blocking on stdin without a TTY, and the GitHub Action definition.
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
_SLEEP_PIDS=""
trap '{ for p in $_SLEEP_PIDS; do kill "$p"; done; wait; } 2>/dev/null; rm -rf "$TMP"' EXIT
# Start from a clean CI environment, whatever runs this file
unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_WORKSPACE GITHUB_SHA CI GITLAB_CI \
  MUSTER_GITHUB_ANNOTATIONS MUSTER_TOKEN MUSTER_SSH_HOSTKEY_CHECK MUSTER_NONINTERACTIVE FORCE_COLOR \
  MUSTER_CLOUD_TOKEN MUSTER_CLOUD_RELAY MUSTER_APPROVE_HOOKS
export HOME="$TMP/home" MUSTER_NO_VERIFY=true NO_COLOR=1 MUSTER_CLOUD_NO_KEYCHAIN=1
mkdir -p "$HOME"
M="$MUSTER_ROOT/bin/muster"

# Run "$@" with a hard time limit; returns 124 when it had to be killed.
_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( n >= secs * 10 )); then
      kill -TERM "$pid" 2>/dev/null; sleep 0.2; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    n=$(( n + 1 ))
  done
  wait "$pid"
}

# A FIFO whose writer never closes: reading it blocks forever (the
# "non-TTY stdin that stays open" case: CI wrappers, ssh -T, pipes).
# Sets $pipe. Call it directly, never inside $(…).
_open_pipe() {
  pipe="$TMP/fifo.$RANDOM$RANDOM"
  mkfifo "$pipe"
  sleep 300 > "$pipe" 2>/dev/null &
  _SLEEP_PIDS="$_SLEEP_PIDS $!"
}

# ── Annotations ──
echo "  GitHub annotations"
_ann() { MUSTER_ROOT="$MUSTER_ROOT" bash -c 'source "$MUSTER_ROOT/lib/core/ci.sh"; _ci_annotate "$@"' _ "$@" 2>&1; }
out=$(GITHUB_ACTIONS=true _ann error "deploy failed: api, web" "line1
50% done")
_test_eq "escapes title and message" "::error title=deploy failed%3A api%2C web::line1%0A50%25 done" "$out"
out=$(GITHUB_ACTIONS=true MUSTER_GITHUB_ANNOTATIONS=off _ann error "t" "m")
_test_eq "MUSTER_GITHUB_ANNOTATIONS=off silences them" "" "$out"
out=$(_ann error "t" "m")
_test_eq "nothing outside GitHub Actions" "" "$out"
out=$(GITHUB_ACTIONS=true _ann warning "t" "m" ".muster/hooks/api/deploy.sh")
_test_eq "file property" "::warning file=.muster/hooks/api/deploy.sh,title=t::m" "$out"

# ── CI defaults ──
echo "  CI defaults"
_colors() { MUSTER_ROOT="$MUSTER_ROOT" bash -c 'source "$MUSTER_ROOT/lib/core/colors.sh"; [[ -n "$BOLD" ]] && echo on || echo off'; }
_test_eq "FORCE_COLOR turns colour on without a TTY" "on" "$(NO_COLOR= FORCE_COLOR=1 _colors)"
_test_eq "FORCE_COLOR=0 does not" "off" "$(NO_COLOR= FORCE_COLOR=0 _colors)"
_test_eq "CI without FORCE_COLOR: plain" "off" "$(NO_COLOR= CI=true _colors)"
_policy() { MUSTER_ROOT="$MUSTER_ROOT" bash -c 'source "$MUSTER_ROOT/lib/core/ci.sh"; echo "$MUSTER_SSH_HOSTKEY_CHECK"'; }
_test_eq "host keys strict on CI" "yes" "$(CI=true _policy)"
_test_eq "accept-new on a workstation" "accept-new" "$(_policy)"
_test_eq "explicit policy wins on CI" "accept-new" "$(GITHUB_ACTIONS=true MUSTER_SSH_HOSTKEY_CHECK=accept-new _policy)"
_test_eq "invalid policy value is normalised" "yes" "$(CI=1 MUSTER_SSH_HOSTKEY_CHECK=no _policy)"
_ni() { MUSTER_ROOT="$MUSTER_ROOT" bash -c 'source "$MUSTER_ROOT/lib/core/ci.sh"; _ci_noninteractive && echo yes || echo no' </dev/null; }
_test_eq "non-interactive on CI without a TTY" "yes" "$(GITHUB_ACTIONS=true _ni)"
_test_eq "not forced off a CI runner" "no" "$(_ni)"

# ── Project ──
P="$TMP/proj"
mkdir -p "$P"
cd "$P"
"$M" setup --services api,web --stack bare --health api=none --health web=none --name cidemo --force </dev/null >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho "api up"\n' > .muster/hooks/api/deploy.sh
printf '#!/usr/bin/env bash\necho "Error: connect ECONNREFUSED 127.0.0.1:6379"\nexit 3\n' > .muster/hooks/web/deploy.sh
chmod +x .muster/hooks/*/*.sh

# ── ci init github ──
echo "  ci init github"
wf=$("$M" ci init github --stdout </dev/null)
_test_contains "lists services in deploy order" "Services (deploy order): api web" "$wf"
_test_contains "uses the action" "uses: Muster-dev/muster@v0" "$wf"
_test_contains "deploys on push to main" "branches: [main]" "$wf"
_test_contains "workflow_dispatch services input" "workflow_dispatch:" "$wf"
_test_contains "dry run job on pull requests" "if: github.event_name == 'pull_request'" "$wf"
_test_contains "production environment" "environment: production" "$wf"
_test_contains "concurrency group" "group: muster-deploy-production" "$wf"
_test_contains "never cancels a running deploy" "cancel-in-progress: false" "$wf"
_test_not_contains "no SSH inputs for a local project" "ssh-key" "$wf"
wf2=$("$M" ci init github --stdout --branch release --environment prod-eu --action-ref v1 </dev/null)
_test_contains "custom branch" "branches: [release]" "$wf2"
_test_contains "custom environment" "environment: prod-eu" "$wf2"
_test_contains "custom ref" "Muster-dev/muster@v1" "$wf2"
"$M" ci init github --stdout --branch 'x]; rm' </dev/null >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "rejects unsafe values" "1" "$rc"

_yaml_ok() {
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$1" 2>/dev/null
  elif python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$1"
  else
    # Structural fallback: no tabs, top-level keys present
    ! grep -q "$(printf '\t')" "$1" && grep -q '^jobs:' "$1"
  fi
}
printf '%s\n' "$wf" > "$TMP/wf.yml"
_test "generated workflow is valid YAML" _yaml_ok "$TMP/wf.yml"

out=$("$M" ci init github </dev/null 2>&1)
_test_contains "non-TTY without --yes shows but doesn't write" "Re-run with --yes" "$out"
_test "nothing written" test ! -e .github/workflows/muster-deploy.yml
"$M" ci init github --yes </dev/null >/dev/null 2>&1
_test_file_exists "--yes writes the workflow" ".github/workflows/muster-deploy.yml"
"$M" ci init github --yes </dev/null >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "refuses to overwrite without --force" "1" "$rc"
"$M" ci init github --yes --force --environment staging </dev/null >/dev/null 2>&1
_test_contains "--force overwrites" "environment: staging" "$(cat .github/workflows/muster-deploy.yml)"

# ── secrets reach the workflow + ci env ──
echo "  ci env"
jq '.services.web.credentials = {"enabled": true, "mode": "save", "required": ["db_password"]}
    | .services.api.remote = {"enabled": true, "host": "203.0.113.5", "user": "deploy"}' muster.json > m.tmp && mv m.tmp muster.json
printf '#!/usr/bin/env bash\necho "$API_KEY ${REGION:?}"\n' > .muster/hooks/web/deploy.sh
env_json=$("$M" ci env --json </dev/null)
_test_contains "credential secret" "MUSTER_CRED_DB_PASSWORD" "$(printf '%s' "$env_json" | jq -r '[.secrets[].name] | join(",")')"
_test_contains "SSH key for remote services" "MUSTER_SSH_KEY,MUSTER_KNOWN_HOSTS" "$(printf '%s' "$env_json" | jq -r '[.secrets[].name] | join(",")')"
_test_eq "hook env vars" "API_KEY:false,REGION:true" "$(printf '%s' "$env_json" | jq -r '[.env[] | "\(.name):\(.required)"] | join(",")')"
_test_eq "remote flag" "true" "$(printf '%s' "$env_json" | jq -r .remote)"
human=$("$M" ci env </dev/null)
_test_contains "human output lists secrets" "MUSTER_CRED_DB_PASSWORD" "$human"
wf=$("$M" ci init github --stdout </dev/null)
_test_contains "credential secret wired as env" 'MUSTER_CRED_DB_PASSWORD: ${{ secrets.MUSTER_CRED_DB_PASSWORD }}' "$wf"
_test_contains "ssh-key input" 'ssh-key: ${{ secrets.MUSTER_SSH_KEY }}' "$wf"
_test_contains "known-hosts input" 'known-hosts: ${{ secrets.MUSTER_KNOWN_HOSTS }}' "$wf"
printf '%s\n' "$wf" > "$TMP/wf2.yml"
_test "workflow with secrets is valid YAML" _yaml_ok "$TMP/wf2.yml"

echo "  ci init gitlab"
gl=$("$M" ci init gitlab --stdout </dev/null)
_test_contains "stages" "stages: [plan, deploy]" "$gl"
_test_contains "resource_group serialises deploys" "resource_group: muster-deploy-production" "$gl"
_test_contains "runs muster ci run" "muster ci run deploy --stop-on-failure --approve-hooks" "$gl"
_test_contains "known_hosts, not disabled checking" "known_hosts" "$gl"
_test_not_contains "never disables host key checks" "StrictHostKeyChecking=no" "$gl$wf"
printf '%s\n' "$gl" > "$TMP/gl.yml"
_test "gitlab pipeline is valid YAML" _yaml_ok "$TMP/gl.yml"

# Back to a plain local project for the run tests
jq 'del(.services.web.credentials) | .services.web.credentials = {"mode": "off"} | del(.services.api.remote)' muster.json > m.tmp && mv m.tmp muster.json
printf '#!/usr/bin/env bash\necho "Error: connect ECONNREFUSED 127.0.0.1:6379"\nexit 3\n' > .muster/hooks/web/deploy.sh

# ── CLI annotations ──
echo "  CLI annotations on failure"
err=$(GITHUB_ACTIONS=true MUSTER_APPROVE_HOOKS=1 "$M" deploy web </dev/null 2>&1 >/dev/null) || true
_test_contains "deploy emits ::error for the failed hook" "::error file=.muster/hooks/web/deploy.sh,title=muster deploy failed%3A web::" "$err"
_test_contains "with the likely cause" "Likely cause" "$err"
T=$("$M" auth create t --scope deploy 2>/dev/null | awk '/Token:/{print $2}')
so=$(GITHUB_ACTIONS=true MUSTER_TOKEN="$T" "$M" deploy web --json --yes </dev/null 2>"$TMP/err") || true
_test "--json stdout stays pure NDJSON" bash -c 'printf "%s\n" "$1" | jq -e -s "length > 0" >/dev/null' _ "$so"
_test_contains "--json annotation on stderr" "::error" "$(cat "$TMP/err")"
err=$(GITHUB_ACTIONS=true MUSTER_GITHUB_ANNOTATIONS=off MUSTER_APPROVE_HOOKS=1 "$M" deploy web </dev/null 2>&1 >/dev/null) || true
_test_not_contains "off means off" "::error" "$err"
"$M" auth revoke t >/dev/null 2>&1 || true

# ── Never block on stdin without a TTY ──
echo "  no stdin reads without a TTY"
_cred_env() {
  MUSTER_ROOT="$MUSTER_ROOT" CF="$P/muster.json" bash -c '
    source "$MUSTER_ROOT/lib/core/colors.sh"; source "$MUSTER_ROOT/lib/core/logger.sh"
    source "$MUSTER_ROOT/lib/core/utils.sh"; source "$MUSTER_ROOT/lib/core/config.sh"
    source "$MUSTER_ROOT/lib/core/credentials.sh"
    CONFIG_FILE="$CF"
    cred_env_for_service web' 2>"$TMP/cred.err"
}
jq '.services.web.credentials = {"enabled": true, "mode": "always", "required": ["db_password", "api_token"]}' muster.json > m.tmp && mv m.tmp muster.json
_open_pipe
rc=0; _with_timeout 15 _cred_env < "$pipe" > "$TMP/cred.out" || rc=$?
_test "credential prompt returns instead of reading an open pipe" test "$rc" != 124
_test_contains "says which env var to set" "MUSTER_CRED_DB_PASSWORD" "$(cat "$TMP/cred.err")"
_open_pipe
rc=0; MUSTER_CRED_DB_PASSWORD=s3cret MUSTER_CRED_API_TOKEN=tok _with_timeout 15 _cred_env < "$pipe" > "$TMP/cred.out" || rc=$?
_test_eq "credentials come from the environment" "MUSTER_CRED_DB_PASSWORD=s3cret,MUSTER_CRED_API_TOKEN=tok" "$(paste -sd, - < "$TMP/cred.out")"

_ssh_pw() {
  MUSTER_ROOT="$MUSTER_ROOT" bash -c '
    source "$MUSTER_ROOT/lib/core/colors.sh"; source "$MUSTER_ROOT/lib/core/logger.sh"
    source "$MUSTER_ROOT/lib/core/utils.sh"; source "$MUSTER_ROOT/lib/core/credentials.sh"
    source "$MUSTER_ROOT/lib/core/remote.sh"
    _REMOTE_USER=deploy _REMOTE_HOST=h _REMOTE_PORT=22 _REMOTE_AUTH_MODE=always
    _remote_load_ssh_password api; echo "rc=$? pw=[$_REMOTE_PASSWORD]"' 2>/dev/null
}
_open_pipe
rc=0; out=$(_with_timeout 15 _ssh_pw < "$pipe") || rc=$?
_test "SSH password prompt doesn't hang without a TTY" test "$rc" != 124
_test_eq "and fails with no password" "rc=1 pw=[]" "$out"

# Whole deploy with an open-pipe stdin: a hook that reads, plus missing credentials
printf '#!/usr/bin/env bash\nread -r line || true\necho "got: [${line:-}]"\n' > .muster/hooks/api/deploy.sh
_open_pipe
rc=0; _with_timeout 60 env MUSTER_APPROVE_HOOKS=1 "$M" deploy api < "$pipe" > "$TMP/dep.out" 2>&1 || rc=$?
_test "deploy with an open non-TTY stdin finishes" test "$rc" != 124
_test_contains "hook's read got EOF, not the pipe" "got: []" "$(cat .muster/logs/api-deploy-*.log 2>/dev/null)"
_open_pipe
rc=0; _with_timeout 60 env MUSTER_APPROVE_HOOKS=1 "$M" deploy web < "$pipe" > "$TMP/dep2.out" 2>&1 || rc=$?
_test "deploy with credentials and no TTY finishes" test "$rc" != 124
_test_contains "names the missing credential" "MUSTER_CRED_DB_PASSWORD" "$(cat "$TMP/dep2.out")"
jq '.services.web.credentials = {"mode": "off"}' muster.json > m.tmp && mv m.tmp muster.json
printf '#!/usr/bin/env bash\necho "api up"\n' > .muster/hooks/api/deploy.sh

# ── ci run ──
echo "  ci run"
OUT="$TMP/gh_output" SUM="$TMP/gh_summary"
: > "$OUT"; : > "$SUM"
log=$(GITHUB_ACTIONS=true GITHUB_OUTPUT="$OUT" GITHUB_STEP_SUMMARY="$SUM" GITHUB_SHA=0123456789abcdef \
  "$M" ci run deploy --dry-run </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "dry run succeeds" "0" "$rc"
_test_contains "masks the one-off token" "::add-mask::" "$log"
_test_contains "dry run lists the plan" "would deploy api (1/2)" "$log"
_test_eq "planned rows" "api:planned,web:planned" "$(grep '^summary-json=' "$OUT" | cut -d= -f2- | jq -r '[.services[] | "\(.service):\(.result)"] | join(",")')"

: > "$OUT"; : > "$SUM"
log=$(GITHUB_ACTIONS=true GITHUB_OUTPUT="$OUT" GITHUB_STEP_SUMMARY="$SUM" GITHUB_WORKSPACE="$TMP" GITHUB_SHA=0123456789abcdef \
  "$M" ci run deploy --services "api, web" --approve-hooks --explain-on-failure </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "failing deploy exits 1" "1" "$rc"
_test_contains "groups per service" "::group::deploy api (1/2)" "$log"
_test_contains "closes groups" "::endgroup::" "$log"
_test_contains "streams hook output" "  api up" "$log"
_test_contains "annotation for the failed service" "::error file=proj/.muster/hooks/web/deploy.sh,title=muster deploy failed%3A web::Likely cause" "$log"
_test_eq "result output" "result=failure" "$(grep '^result=' "$OUT")"
_test_eq "deployed output" 'deployed=["api"]' "$(grep '^deployed=' "$OUT")"
_test_eq "failed output" 'failed=["web"]' "$(grep '^failed=' "$OUT")"
_test_eq "exit-code output" "exit-code=1" "$(grep '^exit-code=' "$OUT")"
_test "duration output" grep -Eq '^duration=[0-9]+$' "$OUT"
_test_eq "explain-json names the service" "web" "$(grep '^explain-json=' "$OUT" | cut -d= -f2- | jq -r .service)"
_test_eq "summary-json commit" "0123456" "$(grep '^summary-json=' "$OUT" | cut -d= -f2- | jq -r .commit)"
summary=$(cat "$SUM")
_test_contains "step summary heading" "### ❌ muster deploy failed" "$summary"
_test_contains "step summary table" "| Service | Result | Duration | Health | Commit |" "$summary"
_test_contains "step summary row" '| web | ❌ failed |' "$summary"
_test_contains "step summary likely cause" "**web — Likely cause:**" "$summary"
_test_eq "one-off token revoked" "0" "$(jq '[.tokens[] | select(.name | startswith("ci-"))] | length' "$HOME/.muster/tokens/auth.json")"

: > "$OUT"
log=$(GITHUB_OUTPUT="$OUT" "$M" ci run deploy --services api --approve-hooks </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "success exits 0" "0" "$rc"
_test_contains "outside GitHub: plain section headers" "==> deploy api" "$log"
_test_contains "outside GitHub: summary printed" "### ✅ muster deploy succeeded" "$log"
_test_not_contains "outside GitHub: no workflow commands" "::group::" "$log"

printf '# changed\n' >> .muster/hooks/web/deploy.sh
log=$(GITHUB_ACTIONS=true "$M" ci run deploy --services web </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "unapproved hooks fail" "1" "$rc"
_test_contains "explains how to approve" "approve-hooks" "$log"

"$M" ci run frobnicate </dev/null >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "unknown command rejected" "1" "$rc"
"$M" ci run deploy --services 'api;rm' </dev/null >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "unsafe service name rejected" "1" "$rc"
out=$("$M" ci run deploy --dry-run --services 'api_v1' </dev/null 2>&1) || true
_test_not_contains "underscored service names pass validation" "Invalid name" "$out"

: > "$OUT"
GITHUB_OUTPUT="$OUT" "$M" ci run status --services api </dev/null >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "status runs" "0" "$rc"
_test_eq "status rows" "api" "$(grep '^summary-json=' "$OUT" | cut -d= -f2- | jq -r '[.services[].service] | join(",")')"

# ── MUSTER_CLOUD_TOKEN ──
echo "  Fleet Cloud token from the environment"
cfg=$(MUSTER_ROOT="$MUSTER_ROOT" MUSTER_CLOUD_TOKEN=mst_cli_x bash -c '
  source "$MUSTER_ROOT/lib/core/colors.sh"; source "$MUSTER_ROOT/lib/core/logger.sh"
  source "$MUSTER_ROOT/lib/core/utils.sh"; source "$MUSTER_ROOT/lib/core/config.sh"
  source "$MUSTER_ROOT/lib/core/cloud.sh"
  _fleet_cloud_config; echo "$FLEET_CLOUD_TOKEN|$FLEET_CLOUD_RELAY"')
_test_eq "token + default relay" "mst_cli_x|https://relay.getmuster.dev" "$cfg"
cfg=$(MUSTER_ROOT="$MUSTER_ROOT" MUSTER_CLOUD_TOKEN=mst_cli_x MUSTER_CLOUD_RELAY=https://relay.example bash -c '
  source "$MUSTER_ROOT/lib/core/colors.sh"; source "$MUSTER_ROOT/lib/core/logger.sh"
  source "$MUSTER_ROOT/lib/core/utils.sh"; source "$MUSTER_ROOT/lib/core/config.sh"
  source "$MUSTER_ROOT/lib/core/cloud.sh"
  _fleet_cloud_config; echo "$FLEET_CLOUD_RELAY"')
_test_eq "MUSTER_CLOUD_RELAY" "https://relay.example" "$cfg"

# ── action.yml ──
echo "  action.yml"
A="$MUSTER_ROOT/action.yml"
_test "action.yml is valid YAML" _yaml_ok "$A"
_test "composite action" grep -q '^  using: composite' "$A"
for i in command services server group dry-run stop-on-failure from working-directory version \
  cloud-token ssh-key known-hosts approve-hooks explain-on-failure; do
  _test "input: $i" grep -q "^  ${i}:" "$A"
done
for o in result deployed failed summary-json duration; do
  _test "output: $o → steps.run" grep -q "value: \${{ steps.run.outputs.${o} }}" "$A"
done
_test_not_contains "inputs never interpolated into run scripts" 'run: |' "$(cat "$A")"
_test_not_contains "no disabled host key checking" "StrictHostKeyChecking=no" "$(cat "$A" "$MUSTER_ROOT"/action/*.sh)"
for f in "$MUSTER_ROOT"/action/*.sh; do
  _test "bash -n $(basename "$f")" bash -n "$f"
done
# Every script referenced by action.yml exists
while IFS= read -r s; do
  _test "referenced script exists: $s" test -f "$MUSTER_ROOT/action/$s"
done < <(grep -o 'action/[a-z-]*\.sh' "$A" | sed 's|action/||' | sort -u)

# setup-ssh requires known-hosts and never prints the key
o=$(INPUT_SSH_KEY="-----BEGIN KEY-----SECRETKEYDATA" INPUT_KNOWN_HOSTS="" RUNNER_TEMP="$TMP" GITHUB_ENV="$TMP/ghenv" \
  bash "$MUSTER_ROOT/action/setup-ssh.sh" 2>&1) && rc=0 || rc=$?
_test_eq "setup-ssh refuses without known-hosts" "1" "$rc"
_test_not_contains "and doesn't print the key" "SECRETKEYDATA" "$o"

# run.sh maps inputs to ci run
_mock_dir="$TMP/mockbin"; mkdir -p "$_mock_dir"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$_mock_dir/muster"; chmod +x "$_mock_dir/muster"
o=$(cd "$P" && PATH="$_mock_dir:$PATH" INPUT_COMMAND=deploy INPUT_SERVICES="api web" INPUT_DRY_RUN=true \
  INPUT_STOP_ON_FAILURE=true INPUT_APPROVE_HOOKS=true INPUT_EXPLAIN_ON_FAILURE=false INPUT_CLOUD_TOKEN=mst_cli_secret \
  bash "$MUSTER_ROOT/action/run.sh" | paste -sd' ' -)
_test_contains "run.sh builds the ci run call" "ci run deploy --services api web --dry-run --stop-on-failure --approve-hooks" "$o"
_test_not_contains "explain off when false" "--explain-on-failure" "$o"
_test_contains "cloud token masked" "::add-mask::mst_cli_secret" "$o"

_test_summary
