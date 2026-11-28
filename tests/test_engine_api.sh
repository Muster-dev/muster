#!/usr/bin/env bash
# tests/test_engine_api.sh — JSON shapes muster-tui relies on (docs/ENGINE-API.md)
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MUSTER_NO_VERIFY=true NO_COLOR=1 MUSTER_CLOUD_RELAY="http://127.0.0.1:9"
mkdir -p "$HOME" "$TMP/p" "$TMP/bin" "$TMP/scan/api"
M="$MUSTER_ROOT/bin/muster"
cd "$TMP/p"

# Every line of stdout must be valid JSON
_all_json() { printf '%s\n' "$1" | jq -e -s 'length >= 0' >/dev/null 2>&1; }

T=$("$M" auth create t --scope admin 2>/dev/null | awk '/Token:/{print $2}')
R=$(MUSTER_TOKEN="$T" "$M" auth create r --scope read 2>/dev/null | awk '/Token:/{print $2}')
export MUSTER_TOKEN="$T"

# ── JSON escaping ──
echo "  JSON escaping"
esc=$(MUSTER_ROOT="$MUSTER_ROOT" bash -c 'source "$MUSTER_ROOT/lib/core/engine.sh"; _json_str "$(printf "a\tb \"q\" \\\\ \033[31mred\001")"')
_test_eq "tabs, quotes, backslashes, ESC and control chars" 'a	b "q" \ [31mred' "$(printf '%s' "$esc" | jq -r . | sed "s/$(printf '\033')//g")"

# ── setup --scan --dry-run --json ──
echo "  setup --scan --dry-run --json"
cat > "$TMP/scan/docker-compose.yml" <<'EOF'
services:
  redis:
    image: redis:7
    ports: ["6379:6379"]
  api:
    build: ./api
    ports: ["8080:8080"]
  web:
    image: nginx:alpine
    ports: ["80:80"]
EOF
printf 'FROM node\nEXPOSE 8080\n' > "$TMP/scan/api/Dockerfile"
out=$("$M" setup --scan --dry-run --json --path "$TMP/scan" 2>/dev/null)
_test "single JSON document" bash -c 'printf "%s" "$1" | jq -e .dry_run >/dev/null' _ "$out"
_test_eq "stack" "compose" "$(printf '%s' "$out" | jq -r .stack)"
_test_eq "infra first in deploy_order" "redis,api,web" "$(printf '%s' "$out" | jq -r '.deploy_order | join(",")')"
_test_eq "no phantom nginx service from an image name" "0" "$(printf '%s' "$out" | jq '[.services[] | select(.key=="nginx")] | length')"
_test_eq "redis role" "infra" "$(printf '%s' "$out" | jq -r '.services[] | select(.key=="redis") | .role')"
_test_eq "redis uses infra hook template" "compose/infra" "$(printf '%s' "$out" | jq -r '.services[] | select(.key=="redis") | .hooks_template')"
_test_eq "api health" "tcp:8080" "$(printf '%s' "$out" | jq -r '.services[] | select(.key=="api") | "\(.health.type):\(.health.port)"')"
_test_contains "api source files include its Dockerfile" "api/Dockerfile" "$(printf '%s' "$out" | jq -r '.services[] | select(.key=="api") | .source_files | join(",")')"
_test "nothing written" bash -c '[[ ! -e "$1/muster.json" && ! -d "$1/.muster" ]]' _ "$TMP/scan"
out=$(MUSTER_TOKEN="" "$M" setup --scan --dry-run --json --path "$TMP/scan" 2>&1) && rc=0 || rc=$?
_test_eq "needs a token" "1" "$rc"

# ── project ──
"$M" setup --services api,web,worker --stack bare --health api=none --health web=none --health worker=none --name eng --force >/dev/null 2>&1
for s in api web worker; do
  printf '#!/usr/bin/env bash\necho "%s deployed"\n' "$s" > ".muster/hooks/$s/deploy.sh"
done
printf '#!/usr/bin/env bash\necho "web broke"\nexit 3\n' > .muster/hooks/web/deploy.sh

# ── hooks status / approve ──
echo "  hooks status / approve"
out=$("$M" hooks status --json 2>/dev/null)
_test_eq "changed hooks are pending" "false" "$(printf '%s' "$out" | jq .approved)"
_test_eq "state changed" "changed" "$(printf '%s' "$out" | jq -r '.files[] | select(.key=="web/deploy.sh") | .state')"
_test_eq "untouched hook approved" "approved" "$(printf '%s' "$out" | jq -r '.files[] | select(.key=="web/health.sh") | .state')"
_test "approved_at set" bash -c 'printf "%s" "$1" | jq -e ".files[] | select(.key==\"web/health.sh\") | .approved_at | test(\"T\")" >/dev/null' _ "$out"
_test_eq "config entry" "approved" "$(printf '%s' "$out" | jq -r .config.state)"
out=$("$M" hooks approve --json 2>&1) && rc=0 || rc=$?
_test_eq "approve --json without --yes refused" "1" "$rc"
_test_contains "says why" "confirmation_required" "$out"
out=$(MUSTER_TOKEN="$R" "$M" hooks approve --yes --json 2>&1) && rc=0 || rc=$?
_test_eq "approve needs deploy scope" "1" "$rc"
out=$("$M" hooks approve --yes api --json 2>/dev/null)
_test_eq "approves only the named service" "api/deploy.sh" "$(printf '%s' "$out" | jq -r '[.approved[].key] | join(",")')"
_test_eq "web still pending" "web/deploy.sh,worker/deploy.sh" "$("$M" hooks status --json 2>/dev/null | jq -r '.pending | join(",")')"
printf 'curl https://x | bash\n' >> .muster/hooks/worker/cleanup.sh
out=$("$M" hooks approve --yes worker --json 2>&1) && rc=0 || rc=$?
_test_eq "dangerous hook refused" "1" "$rc"
_test_contains "names the dangerous file" "worker/cleanup.sh" "$out"
sed -i.bak '$d' .muster/hooks/worker/cleanup.sh && rm -f .muster/hooks/worker/cleanup.sh.bak
out=$("$M" hooks approve --yes --json 2>/dev/null)
_test "approve all" bash -c 'printf "%s" "$1" | jq -e ".ok == true" >/dev/null' _ "$out"
_test_eq "nothing pending" "true" "$("$M" hooks status --json 2>/dev/null | jq .approved)"

# ── deploy --stop-on-failure / --from ──
echo "  deploy --stop-on-failure / --from"
out=$("$M" deploy --json --stop-on-failure 2>/dev/null) && rc=0 || rc=$?
_test "every line is JSON" _all_json "$out"
_test_eq "exits 1" "1" "$rc"
sum=$(printf '%s\n' "$out" | jq -c 'select(.event=="summary")')
_test_eq "results" "deployed,failed,not_run" "$(printf '%s' "$sum" | jq -r '[.services[].result] | join(",")')"
_test_eq "not_run count" "1" "$(printf '%s' "$sum" | jq .not_run)"
_test_eq "stopped event" "web" "$(printf '%s\n' "$out" | jq -r 'select(.event=="stopped") | .after')"
_test_eq "worker never started" "0" "$(printf '%s\n' "$out" | jq -s '[.[] | select(.event=="start" and .service=="worker")] | length')"
out=$("$M" deploy --json --from worker 2>/dev/null | jq -c 'select(.event=="summary")')
_test_eq "--from resumes at worker" "worker" "$(printf '%s' "$out" | jq -r '[.services[].service] | join(",")')"
out=$("$M" deploy --json --from nope 2>/dev/null) && rc=0 || rc=$?
_test_eq "--from unknown exits 1" "1" "$rc"
_test_eq "--from unknown error event" "unknown_service" "$(printf '%s' "$out" | jq -r 'select(.event=="error") | .reason')"
printf '#!/usr/bin/env bash\necho "edited"\n' > .muster/hooks/api/deploy.sh
out=$("$M" deploy --json api 2>/dev/null) || true
_test_eq "unapproved hooks: error lists files" "api/deploy.sh" "$(printf '%s\n' "$out" | jq -r 'select(.event=="error") | [.files[].key] | join(",")')"
_test_eq "unapproved hooks: services" "api" "$(printf '%s\n' "$out" | jq -r 'select(.event=="error") | .services | join(",")')"
"$M" hooks approve --yes --json >/dev/null 2>&1

# ── k8s diagnosis ──
echo "  k8s diagnosis"
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "config current-context"*) echo "test-ctx" ;;
  "describe deployment"*) echo "NewReplicaSet:   api-7d9c (1/1 replicas created)" ;;
  "get pods"*) echo "api-7d9c-xk2   0/1   ImagePullBackOff   0   1m" ;;
  "describe pod"*) printf 'Name: api-7d9c-xk2\nEvents:\n  Warning  Failed  kubelet  Failed to pull image "acme/api:4f2a"\n  Normal   BackOff  kubelet  Back-off pulling image (ImagePullBackOff)\n' ;;
  "logs"*) echo "pod log line" ;;
  "get pod "*) echo "api-7d9c-xk2   0/1   ImagePullBackOff   0   1m" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/kubectl"
jq '.services.api.k8s = {"deployment":"api","namespace":"shop"}' muster.json > m.tmp && mv m.tmp muster.json
printf '#!/usr/bin/env bash\necho "rollout failed"\nexit 1\n' > .muster/hooks/api/deploy.sh
out=$(PATH="$TMP/bin:$PATH" MUSTER_APPROVE_HOOKS=1 "$M" deploy --json api 2>/dev/null) || true
d=$(printf '%s\n' "$out" | jq -c 'select(.event=="diagnosis")')
_test "diagnosis event after failed k8s deploy" test -n "$d"
_test_eq "pattern" "ImagePullBackOff" "$(printf '%s' "$d" | jq -r .pattern)"
_test_eq "pod" "api-7d9c-xk2" "$(printf '%s' "$d" | jq -r .pod)"
_test_eq "pod_status" "0/1 ImagePullBackOff" "$(printf '%s' "$d" | jq -r .pod_status)"
_test_eq "namespace" "shop" "$(printf '%s' "$d" | jq -r .namespace)"
_test_contains "hint" "registry" "$(printf '%s' "$d" | jq -r .hint)"
_test_contains "log_tail" "pod log line" "$(printf '%s' "$d" | jq -r '.log_tail | join("\n")')"
_test_contains "details from pod events" "Failed to pull image" "$(printf '%s' "$d" | jq -r '.details | join("\n")')"
_test "diagnosis comes after done" bash -c 'printf "%s\n" "$1" | jq -s -e "(map(.event) | index(\"done\")) < (map(.event) | index(\"diagnosis\"))" >/dev/null' _ "$out"
human=$(PATH="$TMP/bin:$PATH" MUSTER_HAS_KUBECTL=true MUSTER_K8S_DEPLOYMENT=api MUSTER_K8S_NAMESPACE=shop MUSTER_ROOT="$MUSTER_ROOT" bash -c '
  source "$MUSTER_ROOT/lib/core/colors.sh"; source "$MUSTER_ROOT/lib/core/logger.sh"; source "$MUSTER_ROOT/lib/core/utils.sh"
  source "$MUSTER_ROOT/lib/core/config.sh"; source "$MUSTER_ROOT/lib/core/remote.sh"; source "$MUSTER_ROOT/lib/core/k8s_diag.sh"
  remote_is_enabled() { return 1; }
  k8s_diagnose_failure api')
_test_contains "human output unchanged: diagnosis line" "Can't pull container image" "$human"
_test_contains "human output unchanged: pod status" "Pod status: api-7d9c-xk2" "$human"
jq 'del(.services.api.k8s)' muster.json > m.tmp && mv m.tmp muster.json
printf '#!/usr/bin/env bash\necho "api deployed"\n' > .muster/hooks/api/deploy.sh
"$M" hooks approve --yes --json >/dev/null 2>&1

# ── rollback --json ──
echo "  rollback --json"
printf '#!/usr/bin/env bash\necho "rolled back"\n' > .muster/hooks/api/rollback.sh
printf '#!/usr/bin/env bash\necho "nope"\nexit 4\n' > .muster/hooks/web/rollback.sh
"$M" hooks approve --yes --json >/dev/null 2>&1
out=$("$M" rollback api --json 2>/dev/null) && rc=0 || rc=$?
_test "every line is JSON" _all_json "$out"
_test_eq "exit 0" "0" "$rc"
_test_eq "events" "start,log,done,summary" "$(printf '%s\n' "$out" | jq -r -s 'map(.event) | join(",")')"
_test_eq "summary result" "rolled back" "$(printf '%s\n' "$out" | jq -r 'select(.event=="summary") | .services[0].result')"
out=$("$M" rollback --json web 2>/dev/null) && rc=0 || rc=$?
_test_eq "failed rollback exits 1" "1" "$rc"
_test_eq "done failed with exit code" "failed:4" "$(printf '%s\n' "$out" | jq -r 'select(.event=="done") | "\(.status):\(.exit_code)"')"
out=$("$M" rollback --json 2>&1) && rc=0 || rc=$?
_test_eq "no service exits 1" "1" "$rc"
_test_contains "usage error document" '"error":"usage"' "$out"
_test_contains "history records rollback" '"action":"rollback"' "$(cat .muster/logs/deploy-events.log)"

# ── restart ──
echo "  restart"
out=$("$M" restart api --json 2>/dev/null) && rc=0 || rc=$?
_test_eq "no restart method: redeploy announced" "redeploy" "$(printf '%s\n' "$out" | head -1 | jq -r .method)"
_test_eq "then a normal deploy" "deployed" "$(printf '%s\n' "$out" | jq -r 'select(.event=="summary") | .services[0].result')"
printf '#!/usr/bin/env bash\necho "custom restart"\n' > .muster/hooks/api/restart.sh
chmod +x .muster/hooks/api/restart.sh
out=$("$M" restart api --json 2>/dev/null) && rc=0 || rc=$?
_test_eq "unapproved restart hook refused" "hooks_not_approved" "$(printf '%s\n' "$out" | jq -r 'select(.event=="error") | .reason')"
out=$("$M" restart api --json --yes 2>/dev/null) && rc=0 || rc=$?
_test_eq "restart hook runs" "0" "$rc"
_test_eq "method hook" "hook" "$(printf '%s\n' "$out" | jq -r 'select(.event=="start") | .method')"
_test_eq "summary restarted" "1" "$(printf '%s\n' "$out" | jq -r 'select(.event=="summary") | .restarted')"
printf '#!/usr/bin/env bash\necho "docker $*"\n' > "$TMP/bin/docker"
chmod +x "$TMP/bin/docker"
printf '#!/usr/bin/env bash\nSERVICE="workerctr"\ndocker run -d --name "$SERVICE" img\necho deployed\n' > .muster/hooks/worker/deploy.sh
"$M" hooks approve --yes --json >/dev/null 2>&1
out=$(PATH="$TMP/bin:$PATH" "$M" restart worker --json 2>/dev/null) && rc=0 || rc=$?
_test_eq "docker service restarts its container" "docker restart workerctr" "$(printf '%s\n' "$out" | jq -r 'select(.event=="log") | .line' | grep '^docker')"
_test_eq "stack reported" "docker" "$(printf '%s\n' "$out" | jq -r 'select(.event=="start") | .stack')"
_test_contains "restart in help" "restart" "$("$M" help)"

# ── logs ──
echo "  logs --tail / --json"
printf '#!/usr/bin/env bash\nfor i in 1 2 3 4 5; do echo "line $i"; done\nsleep 20\n' > .muster/hooks/api/logs.sh
out=$("$M" logs api --tail 2 2>/dev/null)
_test_eq "--tail prints the last N lines and exits" "line 4,line 5" "$(printf '%s\n' "$out" | paste -sd, -)"
out=$("$M" logs api --tail 3 --json 2>/dev/null)
_test "every line is JSON" _all_json "$out"
_test_eq "log events" "line 3,line 4,line 5" "$(printf '%s\n' "$out" | jq -r 'select(.event=="log") | .line' | paste -sd, -)"
_test_eq "end event" "0" "$(printf '%s\n' "$out" | jq -r 'select(.event=="end") | .exit_code')"
printf '#!/usr/bin/env bash\ndocker logs -f "workerctr" --tail=100\n' > .muster/hooks/worker/logs.sh
out=$(PATH="$TMP/bin:$PATH" "$M" logs worker --tail 7 --json 2>/dev/null)
_test_eq "docker stack uses docker logs --tail" "docker logs --tail 7 workerctr" "$(printf '%s\n' "$out" | jq -r 'select(.event=="log") | .line')"
out=$("$M" logs api --tail x 2>&1) && rc=0 || rc=$?
_test_eq "bad --tail exits 1" "1" "$rc"

# ── status --json ──
echo "  status --json"
out=$(MUSTER_TOKEN="$R" "$M" status --json 2>/dev/null)
_test "single JSON document" bash -c 'printf "%s" "$1" | jq -e .services >/dev/null' _ "$out"
_test "checked_at" bash -c 'printf "%s" "$1" | jq -e ".checked_at | test(\"T\")" >/dev/null' _ "$out"
_test_eq "stack" "bare" "$(printf '%s' "$out" | jq -r .services.api.stack)"
_test_eq "health config" "false" "$(printf '%s' "$out" | jq -r .services.api.health.enabled)"
_test_eq "last_deploy" "ok" "$(printf '%s' "$out" | jq -r .services.api.last_deploy.status)"
_test_eq "not locked" "null" "$(printf '%s' "$out" | jq -r .services.api.locked_by)"
_test_eq "deploying flag" "false" "$(printf '%s' "$out" | jq -r .deploying)"
_test_eq "muster_version" "$(grep -m1 'MUSTER_VERSION=' "$M" | sed 's/.*="//;s/"//')" "$(printf '%s' "$out" | jq -r .muster_version)"

# ── doctor --json ──
echo "  doctor --json"
chmod -x .muster/hooks/web/logs.sh
out=$("$M" doctor --json 2>/dev/null)
_test_eq "non-executable hook is fixable" "true" "$(printf '%s' "$out" | jq '.checks[] | select(.name | test("not executable")) | .fixable')"
_test "every check has fixable" bash -c 'printf "%s" "$1" | jq -e "all(.checks[]; has(\"fixable\"))" >/dev/null' _ "$out"
_test "fixable count" bash -c 'printf "%s" "$1" | jq -e ".fixable >= 1" >/dev/null' _ "$out"
chmod +x .muster/hooks/web/logs.sh

# ── fleet / cloud ──
echo "  fleet list / status, cloud status"
out=$("$M" fleet list --json 2>/dev/null)
_test_eq "empty fleet" '{"source":"none","machines":[],"groups":[]}' "$out"
cat > remotes.json <<'EOF'
{"machines":{"prod-1":{"host":"192.0.2.10","user":"deploy","port":2222,"mode":"muster","project_dir":"/opt/eng"}},"groups":{"prod":["prod-1"]},"deploy_order":["prod"]}
EOF
out=$("$M" fleet list --json 2>/dev/null)
_test_eq "machines is an array of objects" "prod-1" "$(printf '%s' "$out" | jq -r '.machines[0].name')"
_test_eq "machine fields" "192.0.2.10|deploy|2222|ssh|muster|/opt/eng|prod" \
  "$(printf '%s' "$out" | jq -r '.machines[0] | "\(.host)|\(.user)|\(.port)|\(.transport)|\(.mode)|\(.project_dir)|\(.group)"')"
_test_eq "groups" "prod:prod-1" "$(printf '%s' "$out" | jq -r '.groups[0] | "\(.name):\(.machines | join(","))"')"
out=$(MUSTER_TOKEN="" "$M" fleet list --json 2>&1) && rc=0 || rc=$?
_test_eq "fleet list --json needs a token" "1" "$rc"
cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 255
EOF
chmod +x "$TMP/bin/ssh"
out=$(PATH="$TMP/bin:$PATH" "$M" fleet status --json 2>/dev/null)
_test_eq "fleet status shape" "prod-1|false|unreachable" "$(printf '%s' "$out" | jq -r '.status[0] | "\(.machine)|\(.reachable)|\(.error)"')"
_test_eq "fleet status muster_version" "string" "$(printf '%s' "$out" | jq -r '.status[0].muster_version | type')"
out=$(PATH="$TMP/bin:$PATH" "$M" fleet test --json 2>/dev/null) && rc=0 || rc=$?
_test_eq "fleet test --json exits 1 on failure" "1" "$rc"
_test_eq "fleet test --json shape" "prod-1|ssh|muster|false|fail|skip|number|SSH connection failed|0|1" \
  "$(printf '%s' "$out" | jq -r '.servers[0] as $s | "\($s.name)|\($s.transport)|\($s.mode)|\($s.ok)|\($s.connect)|\($s.muster)|\($s.latency_ms | type)|\($s.error)|\(.passed)|\(.failed)"')"
out=$("$M" fleet logs ghost api --json 2>&1) && rc=0 || rc=$?
_test_eq "fleet logs unknown server" "1|unknown_server" "$rc|$(printf '%s' "$out" | jq -r .error)"
out=$("$M" fleet restart prod-1 api --json </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "fleet restart needs --yes without a TTY" "1|confirmation_required" "$rc|$(printf '%s' "$out" | jq -r .error)"
out=$(MUSTER_TOKEN="$R" "$M" fleet restart prod-1 api --yes --json 2>&1) && rc=0 || rc=$?
_test_eq "fleet restart needs deploy scope (valid JSON error)" "1|forbidden" "$rc|$(printf '%s' "$out" | jq -r .error)"
rm -f remotes.json
out=$("$M" cloud status --json 2>/dev/null)
_test_eq "cloud status" "false|false|false" "$(printf '%s' "$out" | jq -r '"\(.logged_in)|\(.relay_reachable)|\(.tunnel_installed)"')"

_test_summary
