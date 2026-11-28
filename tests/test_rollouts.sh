#!/usr/bin/env bash
# tests/test_rollouts.sh — blue-green / canary / rolling visibility against a
# stateful fake kubectl (tests/mock_helpers.sh _mock_kube_cluster).
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/mock_helpers.sh"
command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
trap '_mock_cleanup; rm -rf "$TMP"' EXIT
export MUSTER_NO_VERIFY=true NO_COLOR=1 MUSTER_APPROVE_HOOKS=1
M="$MUSTER_ROOT/bin/muster"
_mock_init

CANARY_MANUAL='{"type":"canary","steps":[25,50,100],"pause":"manual","drain_seconds":0,"analysis":{"interval_seconds":1,"max_failures":1}}'
BG='{"type":"blue-green","drain_seconds":0,"preview":{"enabled":true},"analysis":{"interval_seconds":1,"max_failures":1}}'

# Fresh project + fake cluster. Usage: _proj name strategy_json [replicas]
_proj() {
  local name="$1" strat="$2" reps="${3:-4}"
  P="$TMP/$name"
  mkdir -p "$P/home" "$P/p/.muster/hooks/api"
  export HOME="$P/home"
  export KUBE_STATE="$P/kube"
  _mock_kube_cluster
  _kube_seed_deployment acme-api prod registry/api:v1 "$reps" api
  _kube_seed_service acme-api prod api
  cd "$P/p"
  cat > muster.json <<J
{"project":"acme","deploy_order":["api"],"services":{"api":{"name":"API","k8s":{"deployment":"acme-api","namespace":"prod"},"health":{"type":"command","enabled":true},"strategy":${strat}}}}
J
  cat > .muster/hooks/api/deploy.sh <<'H'
#!/usr/bin/env bash
set -euo pipefail
echo "deploying ${MUSTER_IMAGE_TAG} to ${MUSTER_K8S_DEPLOYMENT} (track ${MUSTER_ROLLOUT_TRACK:-none})"
kubectl set image "deployment/${MUSTER_K8S_DEPLOYMENT}" "api=registry/api:${MUSTER_IMAGE_TAG}" -n "$MUSTER_K8S_NAMESPACE"
echo "deployed"
H
  cat > .muster/hooks/api/health.sh <<'H'
#!/usr/bin/env bash
[[ -f "$HOME/health_fail_${MUSTER_ROLLOUT_TRACK:-none}" ]] && exit 1
exit 0
H
  chmod +x .muster/hooks/api/*.sh
  unset MUSTER_TOKEN
}

_token() {
  MUSTER_TOKEN=$("$M" auth create t --scope admin 2>/dev/null | awk '/Token:/{print $2; exit}')
  export MUSTER_TOKEN
}
_dep() { _kube_get deployment "$1" prod | jq -r "$2"; }
_state() { _kube_get configmap muster-rollout-acme-api prod | jq -r '.data.state' | jq -r "$1"; }
_sel() { _kube_get service "$1" prod | jq -r '.spec.selector["muster.dev/track"] // "none"'; }

# ─────────────────────────────────────────────
echo "  Config validation"
_proj cfg '{"type":"canary","steps":[50,25],"traffic":"service-selector"}'
out=$("$M" status 2>&1) && rc=0 || rc=$?
_test_eq "invalid strategy fails config load" "1" "$rc"
_test_contains "unsorted steps rejected" "step weights must increase" "$out"
_test_contains "canary + service-selector rejected" "canary needs \"replicas\"" "$out"
cat > muster.json <<'J'
{"project":"acme","deploy_order":["web"],"services":{"web":{"name":"Web","strategy":"blue-green"}}}
J
out=$("$M" status 2>&1) && rc=0 || rc=$?
_test_contains "blue-green without k8s rejected" "needs a Kubernetes service" "$out"
cat > muster.json <<'J'
{"project":"acme","deploy_order":["api"],"services":{"api":{"name":"API","k8s":{"deployment":"acme-api","namespace":"prod"},"strategy":{"type":"canary","traffic":"gateway-api"}}}}
J
out=$("$M" status 2>&1) && rc=0 || rc=$?
_test_contains "gateway-api reserved for a later release" "not supported by this muster version yet" "$out"
cat > muster.json <<'J'
{"project":"acme","deploy_order":["api"],"services":{"api":{"name":"API","k8s":{"deployment":"acme-api","namespace":"prod"},"strategy":{"type":"canary","steps":[10,40],"analysis":{"prometheus":{"query":"x"}}}}}}
J
_token
out=$("$M" deploy --dry-run --json 2>&1) && rc=0 || rc=$?
_test_eq "warnings don't block" "0" "$rc"
_test_contains "missing 100% step is a warning" "a final 100% step is added" "$out"
_test_contains "phase-2 gate warned as ignored" "analysis.prometheus is not supported" "$out"
_test_contains "dry-run event carries normalized steps" '"steps":[{"weight":10,"pause":60},{"weight":40,"pause":60},{"weight":100,"pause":0}]' "$out"
out=$("$M" deploy api --strategy cannary --dry-run 2>&1) && rc=0 || rc=$?
_test_contains "--strategy typo gets did-you-mean" "canary" "$out"

# ─────────────────────────────────────────────
echo "  Canary: manual steps, --to, --full"
_proj canary "$CANARY_MANUAL"
_token
out=$("$M" deploy api --version v2 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "deploy exits 0 when paused" "0" "$rc"
_test_eq "summary result paused" "paused" "$(printf '%s\n' "$out" | jq -r 'select(.event == "summary") | .services[0].result')"
_test_eq "summary carries version" "v2" "$(printf '%s\n' "$out" | jq -r 'select(.event == "summary") | .services[0].version')"
_test_eq "hook targeted the canary Deployment" "registry/api:v2" "$(_dep acme-api-canary '.spec.template.spec.containers[0].image')"
_test_eq "stable untouched" "registry/api:v1" "$(_dep acme-api '.spec.template.spec.containers[0].image')"
_test_eq "25% of 4 replicas: canary=1" "1" "$(_dep acme-api-canary '.spec.replicas')"
_test_eq "25% of 4 replicas: stable=3" "3" "$(_dep acme-api '.spec.replicas')"
_test_eq "canary pods labelled track=canary" "canary" "$(_dep acme-api-canary '.spec.template.metadata.labels["muster.dev/track"]')"
_test_eq "canary pods labelled with version" "v2" "$(_dep acme-api-canary '.spec.template.metadata.labels["muster.dev/version"]')"
_test_eq "state ConfigMap: paused" "paused" "$(_state .state)"
_test_eq "state ConfigMap: step 1" "1" "$(_state .step)"
shift_ev=$(printf '%s\n' "$out" | jq -c 'select(.event == "traffic_shift")' | head -1)
_test_eq "traffic_shift target weight" "25" "$(printf '%s' "$shift_ev" | jq -r .candidate_weight)"
_test_eq "traffic_shift effective weight" "25" "$(printf '%s' "$shift_ev" | jq -r .effective_candidate_weight)"
_test_contains "analysis event emitted" '"event":"analysis"' "$out"
_test_contains "paused rollout_step emitted" '"status":"paused"' "$out"

rs=$("$M" rollout status api --json)
_test_eq "rollout status: state" "paused" "$(printf '%s' "$rs" | jq -r .services.api.state)"
_test_eq "rollout status: next gate manual → 50" "manual/50" "$(printf '%s' "$rs" | jq -r '.services.api.next_gate | "\(.type)/\(.next_weight)"')"
_test_eq "rollout status: two versions" "v1,v2" "$(printf '%s' "$rs" | jq -r '[.services.api.versions[].version] | join(",")')"
_test_eq "rollout status: weights" "75,25" "$(printf '%s' "$rs" | jq -r '[.services.api.versions[].effective_weight] | join(",")')"
_test_eq "rollout status: replicas" "3/3,1/1" "$(printf '%s' "$rs" | jq -r '[.services.api.versions[] | "\(.replicas.ready)/\(.replicas.desired)"] | join(",")')"
st=$("$M" status --json 2>/dev/null)
_test_eq "status --json: stable version" "v1" "$(printf '%s' "$st" | jq -r .services.api.version)"
_test_eq "status --json: strategy" "canary" "$(printf '%s' "$st" | jq -r .services.api.strategy)"
_test_eq "status --json: rollout embedded" "paused" "$(printf '%s' "$st" | jq -r .services.api.rollout.state)"
human=$("$M" rollout status api 2>&1)
_test_contains "human display shows the bar" "[#####---------------]" "$human"
_test_contains "human display names the next step" "next: 50%" "$human"

out=$("$M" deploy api --version v3 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "new deploy refused while paused" "1" "$rc"
_test_contains "says why" "rollout_in_progress" "$out"

out=$("$M" promote api --to 50 --json 2>/dev/null) && rc=0 || rc=$?
_test_eq "promote --to 50 exits 0" "0" "$rc"
_test_eq "50%: canary=2" "2" "$(_dep acme-api-canary '.spec.replicas')"
_test_eq "50%: stable=2" "2" "$(_dep acme-api '.spec.replicas')"
_test_eq "state step 2" "2" "$(_state .step)"
_test_contains "promote done event" '"action":"promote","status":"paused"' "$out"

out=$("$M" promote api --full --json 2>/dev/null) && rc=0 || rc=$?
_test_eq "promote --full exits 0" "0" "$rc"
_test_eq "stable now runs v2" "registry/api:v2" "$(_dep acme-api '.spec.template.spec.containers[0].image')"
_test_eq "stable back to 4 replicas" "4" "$(_dep acme-api '.spec.replicas')"
_test_eq "stable labelled v2" "v2" "$(_dep acme-api '.spec.template.metadata.labels["muster.dev/version"]')"
_test_eq "canary scaled to 0" "0" "$(_dep acme-api-canary '.spec.replicas')"
_test_eq "state complete" "complete" "$(_state .state)"
_test_contains "promoted event" '"event":"promoted"' "$out"
_test_eq "promoted previous_version" "v1" "$(printf '%s\n' "$out" | jq -r 'select(.event == "promoted") | .previous_version')"
hist=$("$M" history --json)
_test_eq "history: promote with version + strategy" "promote ok v2 canary" \
  "$(printf '%s' "$hist" | jq -r '[.[] | select(.action == "promote")][0] | "\(.action) \(.status) \(.version) \(.strategy)"')"
out=$("$M" promote api 2>&1) && rc=0 || rc=$?
_test_eq "promote with nothing in progress fails" "1" "$rc"

# ─────────────────────────────────────────────
echo "  Canary: effective weight with few replicas"
_proj canary1 '{"type":"canary","steps":[10,100],"pause":"manual","drain_seconds":0}' 1
_token
out=$("$M" deploy api --version v2 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
shift_ev=$(printf '%s\n' "$out" | jq -c 'select(.event == "traffic_shift")' | head -1)
_test_eq "target 10%" "10" "$(printf '%s' "$shift_ev" | jq -r .candidate_weight)"
_test_eq "effective 50% (1 of 2 pods)" "50" "$(printf '%s' "$shift_ev" | jq -r .effective_candidate_weight)"
_test_contains "human display flags the target" "(target 10%)" "$("$M" rollout status api 2>&1)"

# ─────────────────────────────────────────────
echo "  Canary: timed steps run to completion"
_proj timed '{"type":"canary","steps":[{"weight":50,"pause":2},100],"drain_seconds":0,"analysis":{"interval_seconds":1}}'
_token
out=$("$M" deploy api --version v2 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "timed canary exits 0" "0" "$rc"
_test_eq "result deployed" "deployed" "$(printf '%s\n' "$out" | jq -r 'select(.event == "summary") | .services[0].result')"
_test_eq "stable promoted" "registry/api:v2" "$(_dep acme-api '.spec.template.spec.containers[0].image')"
_test "several analysis passes during the bake" test "$(printf '%s\n' "$out" | grep -c '"event":"analysis"')" -ge 2

# ─────────────────────────────────────────────
echo "  Canary: gate failure auto-aborts"
_proj gatefail "$CANARY_MANUAL"
_token
touch "$HOME/health_fail_canary"
out=$("$M" deploy api --version v2 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "deploy exits 1" "1" "$rc"
_test_eq "result rolled back" "rolled back" "$(printf '%s\n' "$out" | jq -r 'select(.event == "summary") | .services[0].result')"
_test_eq "aborted reason analysis_failed" "analysis_failed" "$(printf '%s\n' "$out" | jq -r 'select(.event == "aborted") | .reason')"
_test_eq "stable restored to 4" "4" "$(_dep acme-api '.spec.replicas')"
_test_eq "canary at 0" "0" "$(_dep acme-api-canary '.spec.replicas')"
_test_eq "state aborted" "aborted" "$(_state .state)"
_test_eq "analysis event says fail" "fail" "$(printf '%s\n' "$out" | jq -r 'select(.event == "analysis") | .status' | tail -1)"

echo "  Canary: crashing pods fail fast"
_proj crash "$CANARY_MANUAL"
_token
_kube_fault acme-api-canary CrashLoopBackOff
out=$("$M" deploy api --version v2 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "deploy exits 1" "1" "$rc"
_test_contains "detail names CrashLoopBackOff" "CrashLoopBackOff" "$(printf '%s\n' "$out" | jq -r 'select(.event == "aborted") | .detail')"
_test_eq "stable restored to 4" "4" "$(_dep acme-api '.spec.replicas')"
_test_eq "stable image untouched" "registry/api:v1" "$(_dep acme-api '.spec.template.spec.containers[0].image')"

echo "  Canary: failing deploy hook leaves production alone"
_proj hookfail "$CANARY_MANUAL"
_token
printf '#!/usr/bin/env bash\necho boom\nexit 3\n' > .muster/hooks/api/deploy.sh
out=$("$M" deploy api --version v2 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "deploy exits 1" "1" "$rc"
_test_eq "aborted reason deploy_failed" "deploy_failed" "$(printf '%s\n' "$out" | jq -r 'select(.event == "aborted") | .reason')"
_test_eq "stable still 4 replicas" "4" "$(_dep acme-api '.spec.replicas')"

# ─────────────────────────────────────────────
echo "  Canary: Ctrl+C mid-rollout restores stable"
_proj cancel '{"type":"canary","steps":[{"weight":50,"pause":60},100],"drain_seconds":0,"analysis":{"interval_seconds":1}}'
_token
set -m
"$M" deploy api --version v2 --json --no-preflight > "$TMP/cancel.out" 2>/dev/null &
pid=$!
set +m
for _ in $(seq 1 100); do
  [[ "$(_state .weight 2>/dev/null)" == "50" ]] && break
  sleep 0.2
done
_test_eq "traffic was split 50/50" "2" "$(_dep acme-api-canary '.spec.replicas')"
sleep 1
kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
_test_eq "exits 130" "130" "$rc"
_test_eq "stable back to 4" "4" "$(_dep acme-api '.spec.replicas')"
_test_eq "canary at 0" "0" "$(_dep acme-api-canary '.spec.replicas')"
_test_eq "state aborted (interrupted)" "aborted/interrupted" "$(_state '"\(.state)/\(.reason)"')"
_test_contains "aborted event" '"reason":"interrupted"' "$(cat "$TMP/cancel.out")"
_test_contains "cancelled event with safe version" '"event":"cancelled","service":"api","safe_version":"v1"' "$(cat "$TMP/cancel.out")"
_test "deploy lock released" test ! -f .muster/deploy.lock
_test_contains "history records cancelled" "cancelled" "$(cat .muster/logs/deploy-events.log)"

# ─────────────────────────────────────────────
echo "  Blue-green: adopt, preview, promote, rollback"
_proj bg "$BG"
_token
out=$("$M" deploy api --version v2 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "deploy exits 0 (awaiting promotion)" "0" "$rc"
_test_eq "legacy Deployment scaled to 0" "0" "$(_dep acme-api '.spec.replicas')"
_test_eq "blue adopted with 4 replicas" "4" "$(_dep acme-api-blue '.spec.replicas')"
_test_eq "blue runs v1" "registry/api:v1" "$(_dep acme-api-blue '.spec.template.spec.containers[0].image')"
_test_eq "green runs v2" "registry/api:v2" "$(_dep acme-api-green '.spec.template.spec.containers[0].image')"
_test_eq "green scaled to match" "4" "$(_dep acme-api-green '.spec.replicas')"
_test_eq "Service still on blue" "blue" "$(_sel acme-api)"
_test_eq "preview Service on green" "green" "$(_sel acme-api-preview)"
_test_eq "state awaiting_promotion" "awaiting_promotion" "$(_state .state)"
rs=$("$M" rollout status api --json)
_test_eq "next gate: promotion" "promotion" "$(printf '%s' "$rs" | jq -r .services.api.next_gate.type)"
_test_eq "blue 100 / green 0" "blue:100,green:0" "$(printf '%s' "$rs" | jq -r '[.services.api.versions[] | "\(.track):\(.weight)"] | join(",")')"
_test_eq "preview service reported" "acme-api-preview" "$(printf '%s' "$rs" | jq -r .services.api.preview_service)"
out=$("$M" promote api --json 2>/dev/null) && rc=0 || rc=$?
_test_eq "promote exits 0" "0" "$rc"
_test_eq "Service switched to green" "green" "$(_sel acme-api)"
_test_eq "blue scaled to 0 (keep_old_seconds 0)" "0" "$(_dep acme-api-blue '.spec.replicas')"
_test_eq "traffic_shift 0/100" "0/100" "$(printf '%s\n' "$out" | jq -r 'select(.event == "traffic_shift") | "\(.stable_weight)/\(.candidate_weight)"' | head -1)"
_test_eq "status: version v2 after promote" "v2" "$("$M" status --json 2>/dev/null | jq -r .services.api.version)"
out=$("$M" rollback api --json 2>/dev/null) && rc=0 || rc=$?
_test_eq "rollback exits 0" "0" "$rc"
_test_eq "rollback switched Service back to blue" "blue" "$(_sel acme-api)"
_test_eq "blue scaled back up" "4" "$(_dep acme-api-blue '.spec.replicas')"
_test_eq "green scaled down" "0" "$(_dep acme-api-green '.spec.replicas')"
_test_contains "rollback summary" '"rolled_back":1' "$out"
_test_eq "state rolled_back" "rolled_back" "$(_state .state)"

echo "  Blue-green: abort before cutover"
out=$("$M" deploy api --version v3 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "second deploy targets green again" "registry/api:v3" "$(_dep acme-api-green '.spec.template.spec.containers[0].image')"
out=$("$M" abort api --yes 2>&1) && rc=0 || rc=$?
_test_eq "abort exits 0" "0" "$rc"
_test_eq "Service never left blue" "blue" "$(_sel acme-api)"
_test_eq "candidate scaled to 0" "0" "$(_dep acme-api-green '.spec.replicas')"
_test_eq "preview points back at blue" "blue" "$(_sel acme-api-preview)"

echo "  Blue-green: failing gate never touches production"
_proj bgfail "$BG"
_token
touch "$HOME/health_fail_green"
out=$("$M" deploy api --version v2 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "deploy exits 1" "1" "$rc"
_test_eq "Service on blue" "blue" "$(_sel acme-api)"
_test_eq "green scaled to 0" "0" "$(_dep acme-api-green '.spec.replicas')"

echo "  Blue-green: auto_promote, rollback while awaiting = abort"
_proj bgauto '{"type":"blue-green","auto_promote":true,"drain_seconds":0,"keep_old_seconds":300}'
_token
out=$("$M" deploy api --version v2 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "auto-promoted deploy exits 0" "deployed" "$(printf '%s\n' "$out" | jq -r 'select(.event == "summary") | .services[0].result')"
_test_eq "Service on green" "green" "$(_sel acme-api)"
_test_eq "keep_old_seconds keeps blue warm" "4" "$(_dep acme-api-blue '.spec.replicas')"
_proj bgrb "$BG"
_token
"$M" deploy api --version v2 --json --no-preflight >/dev/null 2>&1 || true
out=$("$M" rollback api 2>&1) && rc=0 || rc=$?
_test_eq "rollback during awaiting_promotion aborts" "aborted" "$(_state .state)"
_test_contains "and says so" "aborting it" "$out"

# ─────────────────────────────────────────────
echo "  Rolling: per-ReplicaSet version visibility"
_proj rolling '"rolling"'
_token
mkdir -p "$KUBE_STATE/prod/replicaset"
_mkrs() {
  jq -nc --arg n "$1" --arg img "$2" --arg rev "$3" --argjson r "$4" --argjson ready "$5" --arg v "$6" '{
    kind: "ReplicaSet", metadata: {name: $n, namespace: "prod",
      annotations: {"deployment.kubernetes.io/revision": $rev},
      ownerReferences: [{kind: "Deployment", name: "acme-api"}]},
    spec: {replicas: $r, template: {metadata: {labels: ({app: "api"} + (if $v != "" then {"muster.dev/version": $v} else {} end))},
      spec: {containers: [{name: "api", image: $img}]}}},
    status: {replicas: $r, readyReplicas: $ready}}' > "$KUBE_STATE/prod/replicaset/$1.json"
}
_mkrs acme-api-aaa registry/api:v1 13 6 6 ""
_mkrs acme-api-bbb registry/api:v2 14 4 4 "v2"
_mkrs acme-api-old registry/api:v0 12 0 0 ""
rs=$("$M" rollout status api --json)
_test_eq "rolling rollout detected" "progressing/rolling" "$(printf '%s' "$rs" | jq -r '.services.api | "\(.state)/\(.strategy)"')"
_test_eq "scaled-down RS ignored, two live" "2" "$(printf '%s' "$rs" | jq -r '.services.api.versions | length')"
_test_eq "versions (tag fallback + label)" "v1,v2" "$(printf '%s' "$rs" | jq -r '[.services.api.versions[].version] | join(",")')"
_test_eq "revisions" "13,14" "$(printf '%s' "$rs" | jq -r '[.services.api.versions[].revision] | join(",")')"
_test_eq "traffic share 60/40" "60,40" "$(printf '%s' "$rs" | jq -r '[.services.api.versions[].effective_weight] | join(",")')"
_test_eq "roles stable/candidate" "stable,candidate" "$(printf '%s' "$rs" | jq -r '[.services.api.versions[].role] | join(",")')"
st=$("$M" status --json 2>/dev/null)
_test_eq "status --json: version = newest RS" "v2" "$(printf '%s' "$st" | jq -r .services.api.version)"
_test_eq "status --json: revision" "14" "$(printf '%s' "$st" | jq -r .services.api.revision)"
_test_eq "status --json: rollout during rolling update" "rolling" "$(printf '%s' "$st" | jq -r .services.api.rollout.strategy)"
rm "$KUBE_STATE/prod/replicaset/acme-api-aaa.json"
_test_eq "single RS: rollout null" "null" "$("$M" status --json 2>/dev/null | jq -r .services.api.rollout)"
_test_eq "rollout status idle object" "idle" "$("$M" rollout status api --json | jq -r .services.api.state)"
out=$("$M" deploy api --version v9 --json --no-preflight 2>/dev/null) && rc=0 || rc=$?
_test_eq "rolling deploy exits 0" "0" "$rc"
_test_eq "rolling hook got MUSTER_IMAGE_TAG=latest (unchanged behaviour)" "registry/api:latest" "$(_dep acme-api '.spec.template.spec.containers[0].image')"
_test_eq "rolling summary has version + strategy" "v9 rolling" "$(printf '%s\n' "$out" | jq -r 'select(.event == "summary") | .services[0] | "\(.version) \(.strategy)"')"
_test_eq "rolling summary has image" "registry/api:latest" "$(printf '%s\n' "$out" | jq -r 'select(.event == "summary") | .services[0].image')"

# ─────────────────────────────────────────────
echo "  Commands and help"
out=$("$M" promot 2>&1) && rc=0 || rc=$?
_test_contains "did-you-mean for promote" "promote" "$out"
out=$("$M" rollout statsu 2>&1) && rc=0 || rc=$?
_test_contains "did-you-mean for rollout status" "status" "$out"
_test_contains "deploy --help documents --strategy" "--strategy" "$("$M" deploy --help)"
_test_contains "top-level help lists rollout" "rollout" "$("$M" --help)"
out=$("$M" promote nope 2>&1) && rc=0 || rc=$?
_test_contains "unknown service rejected" "Unknown service" "$out"

echo ""
printf '  %d/%d tests passed\n' "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]]
