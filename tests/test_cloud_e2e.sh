#!/usr/bin/env bash
# tests/test_cloud_e2e.sh — fleet/group over the REAL Fleet Cloud stack
#
# Builds muster-cloud (relay), muster-agent and muster-tunnel from the sibling
# Go repos, starts a relay on a random localhost port, enrolls a real agent
# (default allowlist, no shell) for a temp project whose hooks just echo, logs
# the CLI in with the device flow, then drives `muster fleet` and
# `muster group` through the cloud transport.
#
# Skips (exit 0) when Go or the sibling repos aren't available. Override the
# locations with MUSTER_FLEET_CLOUD_REPO / MUSTER_CLOUD_REPO / GO.
# Set MUSTER_E2E_VERBOSE=1 to print every command's output.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

skip() {
  echo "  (skipped: $1)"
  exit 0
}

for _c in jq curl python3; do
  command -v "$_c" >/dev/null 2>&1 || skip "needs $_c"
done

# test_runner.sh isolates HOME; Go still needs the real module/build caches
REAL_HOME=$(python3 -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null)
[[ -n "$REAL_HOME" ]] || REAL_HOME="$HOME"

GO="${GO:-}"
if [[ -z "$GO" ]]; then
  GO=$(command -v go 2>/dev/null || true)
  [[ -z "$GO" && -x /opt/homebrew/bin/go ]] && GO=/opt/homebrew/bin/go
  [[ -z "$GO" && -x /usr/local/go/bin/go ]] && GO=/usr/local/go/bin/go
fi
[[ -n "$GO" && -x "$GO" ]] || skip "go not installed"

# Sibling repos: next to this checkout, next to the main checkout (when this
# is a git worktree), or in ~/Documents/GitHub
_find_repo() {
  local name="$1" override="$2" d common
  if [[ -n "$override" ]]; then
    [[ -d "$override" ]] && printf '%s' "$override"
    return 0
  fi
  common=$(git -C "$MUSTER_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  for d in "$MUSTER_ROOT/.." "${common:+$common/../..}" "$REAL_HOME/Documents/GitHub"; do
    [[ -n "$d" && -f "$d/$name/go.mod" ]] && { (cd "$d/$name" && pwd); return 0; }
  done
}
FLEET_REPO=$(_find_repo muster-fleet-cloud "${MUSTER_FLEET_CLOUD_REPO:-}")
CLOUD_REPO=$(_find_repo muster-cloud "${MUSTER_CLOUD_REPO:-}")
[[ -n "$FLEET_REPO" ]] || skip "muster-fleet-cloud repo not found (set MUSTER_FLEET_CLOUD_REPO)"
[[ -n "$CLOUD_REPO" ]] || skip "muster-cloud repo not found (set MUSTER_CLOUD_REPO)"

TMP=$(mktemp -d)
RELAY_PID=""
AGENT_PID=""
cleanup() {
  [[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null
  [[ -n "$RELAY_PID" ]] && kill "$RELAY_PID" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

VERBOSE="${MUSTER_E2E_VERBOSE:-}"
show() {
  [[ -n "$VERBOSE" ]] || return 0
  printf '    ┄┄ %s\n' "$1"
  printf '%s\n' "$2" | sed 's/^/    │ /'
}

# ── Build ──
BIN="$TMP/bin"
mkdir -p "$BIN"
_goenv() {
  HOME="$REAL_HOME" "$GO" env "$1" 2>/dev/null
}
export GOMODCACHE GOCACHE GOPATH
GOMODCACHE=$(_goenv GOMODCACHE)
GOCACHE=$(_goenv GOCACHE)
GOPATH=$(_goenv GOPATH)
if ! (cd "$FLEET_REPO" && "$GO" build -o "$BIN/" ./cmd/muster-agent ./cmd/muster-tunnel) >"$TMP/build.log" 2>&1 \
  || ! (cd "$CLOUD_REPO" && "$GO" build -o "$BIN/" ./cmd/muster-cloud) >>"$TMP/build.log" 2>&1; then
  cat "$TMP/build.log"
  skip "Go build failed (see output above)"
fi
echo "  built muster-cloud, muster-agent, muster-tunnel"

# ── Relay ──
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
RELAY_HTTP="http://127.0.0.1:${PORT}"
DATA="$TMP/relay-data"
mkdir -p "$DATA"
ORG="org_e2e"
ADMIN=$("$BIN/muster-cloud" token create --type admin --data-dir "$DATA" --json | jq -r .token)
JOIN=$("$BIN/muster-cloud" token create --type agent-join --org "$ORG" --name edge-1 --data-dir "$DATA" --json | jq -r .token)

"$BIN/muster-cloud" serve --listen "127.0.0.1:${PORT}" --data-dir "$DATA" \
  --dashboard-url "$RELAY_HTTP" --device-interval 1 \
  --rate-auth-fail 1000 --rate-connect 10000 --rate-device 1000 \
  >"$TMP/relay.log" 2>&1 &
RELAY_PID=$!
for _i in $(seq 1 50); do
  curl -fsS "$RELAY_HTTP/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done
_test "relay is healthy" curl -fsS -o /dev/null "$RELAY_HTTP/healthz"

# ── Agent machine: project + muster + real muster-agent ──
AGENT_HOME="$TMP/agent-home"
EDGE="$TMP/edge-proj"
mkdir -p "$AGENT_HOME" "$EDGE"

write_project() {
  local dir="$1"
  mkdir -p "$dir/.muster/hooks/api" "$dir/.muster/hooks/worker"
  cat > "$dir/muster.json" <<'JSON'
{
  "project": "e2eapp",
  "services": {
    "api": { "name": "API", "health": { "type": "command", "enabled": true }, "credentials": { "mode": "off" } },
    "worker": { "name": "Worker", "health": { "type": "command", "enabled": true }, "credentials": { "mode": "off" } }
  },
  "deploy_order": ["api", "worker"]
}
JSON
  local svc
  for svc in api worker; do
    printf '#!/usr/bin/env bash\necho "deploying %s on $(basename "$PWD")"\necho "%s deployed" >> "$PWD/.e2e-events"\n' "$svc" "$svc" \
      > "$dir/.muster/hooks/$svc/deploy.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/.muster/hooks/$svc/health.sh"
    printf '#!/usr/bin/env bash\necho "rolling back %s"\necho "%s rolled back" >> "$PWD/.e2e-events"\n' "$svc" "$svc" \
      > "$dir/.muster/hooks/$svc/rollback.sh"
    chmod +x "$dir/.muster/hooks/$svc/"*.sh
  done
}
write_project "$EDGE"

agent_env() {
  env HOME="$AGENT_HOME" PATH="$MUSTER_ROOT/bin:$BIN:$PATH" NO_COLOR=1 \
    MUSTER_NO_VERIFY=true "$@"
}

out=$(agent_env "$BIN/muster-agent" join --relay "ws://127.0.0.1:${PORT}" --token "$JOIN" \
  --name edge-1 --project "$EDGE" 2>&1)
show "muster-agent join" "$out"
_test_contains "agent enrolls with the join token" "edge-1" "$out"

agent_env "$BIN/muster-agent" run >"$TMP/agent.log" 2>&1 &
AGENT_PID=$!

# ── CLI machine: device-flow login exactly like a user ──
CLI_HOME="$TMP/cli-home"
LOCAL="$TMP/local-proj"
mkdir -p "$CLI_HOME"
write_project "$LOCAL"

cli() {
  (cd "$LOCAL" && env HOME="$CLI_HOME" PATH="$MUSTER_ROOT/bin:$BIN:$PATH" NO_COLOR=1 \
    MUSTER_CLOUD_NO_KEYCHAIN=1 MUSTER_NO_BROWSER=1 MUSTER_NO_VERIFY=true \
    "$MUSTER_ROOT/bin/muster" "$@" </dev/null 2>&1)
}

cli cloud login --relay "$RELAY_HTTP" >"$TMP/login.log" 2>&1 &
LOGIN_PID=$!
CODE=""
for _i in $(seq 1 50); do
  CODE=$(grep -Eo '[A-Z0-9]{4}-[A-Z0-9]{4}' "$TMP/login.log" 2>/dev/null | head -1)
  [[ -n "$CODE" ]] && break
  sleep 0.1
done
curl -fsS -X POST -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' \
  -d "{\"org_id\":\"$ORG\",\"user_id\":\"user_e2e\"}" \
  "$RELAY_HTTP/api/v1/device/$CODE/approve" >/dev/null 2>&1
wait "$LOGIN_PID"
show "muster cloud login" "$(cat "$TMP/login.log")"
_test_contains "muster cloud login (device flow)" "Logged in to Fleet Cloud" "$(cat "$TMP/login.log")"

# Wait until the agent is online
for _i in $(seq 1 50); do
  curl -fsS -H "Authorization: Bearer $ADMIN" "$RELAY_HTTP/api/v1/agents?org_id=$ORG" 2>/dev/null \
    | jq -e '.[] | select(.name=="edge-1" and .connected)' >/dev/null 2>&1 && break
  sleep 0.1
done

# ── Fleet ──
echo ""
echo "  fleet"
out=$(cli fleet init)
show "fleet init" "$out"
out=$(cli fleet add edge-1 muster@edge-1 --transport cloud --mode muster --path "$EDGE")
show "fleet add" "$out"
_test_contains "fleet add pings the cloud agent" "Cloud agent edge-1 is connected" "$out"
_test_not_contains "fleet add skips SSH auto-pairing" "pair" "$out"

out=$(cli fleet test)
show "fleet test" "$out"
_test_contains "fleet test: relay ping + muster status" "cloud ok, muster ok" "$out"
_test_contains "fleet test passes" "All 1 machine(s) passed" "$out"

out=$(cli fleet status)
show "fleet status" "$out"
_test_contains "fleet status reports per-service health over cloud" "2/2 healthy" "$out"

# Hooks are not approved on the agent's machine yet
out=$(cli fleet deploy edge-1)
show "fleet deploy (hooks not approved)" "$out"
_test_contains "unapproved hooks give the approve hint" \
  "Hooks on edge-1 aren't approved yet. On that machine run: muster hooks approve" \
  "$out$(cat "$LOCAL"/.muster/logs/fleet-edge-1-*.log 2>/dev/null)"
_test "nothing ran on the agent before approval" test ! -f "$EDGE/.e2e-events"

# Approve on the agent's machine, as the agent's user (CI-style approval)
agent_env MUSTER_APPROVE_HOOKS=1 bash -c "cd '$EDGE' && '$MUSTER_ROOT/bin/muster' deploy --dry-run" >/dev/null 2>&1
agent_env bash -c "cd '$EDGE' && MUSTER_TRUST_DIR= '$MUSTER_ROOT/bin/muster' hooks verify" >"$TMP/verify.log" 2>&1 || true
if grep -q "not approved" "$TMP/verify.log"; then
  # dry-run doesn't approve: approve via a real (echo-only) local deploy
  agent_env MUSTER_APPROVE_HOOKS=1 bash -c "cd '$EDGE' && '$MUSTER_ROOT/bin/muster' deploy" >/dev/null 2>&1
fi
rm -f "$EDGE/.e2e-events"

out=$(cli fleet deploy edge-1)
show "fleet deploy" "$out"
_test_contains "fleet deploy over cloud succeeds" "deployed" "$out"
_test "deploy hooks ran on the agent (api)" grep -q "api deployed" "$EDGE/.e2e-events"
_test "deploy hooks ran on the agent (worker)" grep -q "worker deployed" "$EDGE/.e2e-events"

out=$(cli fleet rollback edge-1 --service api)
show "fleet rollback --service api" "$out"
_test_contains "fleet rollback over cloud succeeds" "edge-1 rolled back" "$out"
_test "rollback hook ran on the agent" grep -q "api rolled back" "$EDGE/.e2e-events"
_test "rollback --service only touched api" bash -c "! grep -q 'worker rolled back' '$EDGE/.e2e-events'"

# Push mode against an agent in muster mode → clear explanation
# (fleet dirs derive push mode from hook_mode: --sync)
out=$(cli fleet add edge-push muster@edge-1 --transport cloud --sync --path "$EDGE")
out=$(cli fleet deploy edge-push)
show "fleet deploy (push mode vs muster-mode agent)" "$out"
_test_contains "push to a muster-mode agent explains push mode" "not in push mode" \
  "$out$(cat "$LOCAL"/.muster/logs/fleet-edge-push-*.log 2>/dev/null)"
cli fleet remove edge-push >/dev/null

# ── Safety: nothing shell-shaped reaches the agent ──
echo ""
echo "  argv safety"
helper() {
  (cd "$LOCAL" && env HOME="$CLI_HOME" PATH="$MUSTER_ROOT/bin:$BIN:$PATH" NO_COLOR=1 \
    MUSTER_CLOUD_NO_KEYCHAIN=1 MUSTER_ROOT="$MUSTER_ROOT" bash -c '
      source "$MUSTER_ROOT/lib/core/colors.sh"
      source "$MUSTER_ROOT/lib/core/logger.sh"
      source "$MUSTER_ROOT/lib/core/utils.sh"
      source "$MUSTER_ROOT/lib/core/config.sh"
      source "$MUSTER_ROOT/lib/core/fleet.sh"
      source "$MUSTER_ROOT/lib/core/cloud.sh"
      fleet_load_config >/dev/null 2>&1
      '"$1" </dev/null 2>&1)
}
out=$(helper '_cloud_muster edge-1 "" status "x;id"; echo "rc=$?"')
show "_cloud_muster with a metacharacter" "$out"
_test_contains "_cloud_muster refuses shell characters locally" "only plain words are allowed" "$out"
_test_contains "_cloud_muster returns non-zero" "rc=1" "$out"
out=$(helper 'fleet_exec edge-1 "id -u"; echo "rc=$?"')
show "fleet_exec non-muster command" "$out"
_test_contains "fleet_exec refuses non-muster commands over cloud" "only muster commands" "$out"
out=$(helper 'fleet_exec edge-1 "cd /tmp && muster status"; echo "rc=$?"')
_test_contains "fleet_exec refuses shell strings over cloud" "needs a shell" "$out"
# The agent itself rejects shell syntax (defence in depth)
out=$(env HOME="$CLI_HOME" MUSTER_CLOUD_TOKEN="$(jq -r '.tokens.default' "$CLI_HOME/.muster/tokens/cloud.json")" \
  "$BIN/muster-tunnel" exec --relay "ws://127.0.0.1:${PORT}" --agent edge-1 --cmd 'muster status; id' 2>&1)
show "raw muster-tunnel exec with ';'" "$out"
_test_contains "agent rejects metacharacters (E_COMMAND_REJECTED)" "metacharacter" "$out"

# ── Group with a cloud project ──
echo ""
echo "  group"
out=$(cli group create e2e)
show "group create" "$out"
out=$(cli group add e2e edge-1 --cloud --path "$EDGE")
show "group add --cloud" "$out"
_test_contains "group add pings the cloud agent" "Cloud agent reachable" "$out"
rm -f "$EDGE/.e2e-events"
out=$(cli group deploy e2e)
show "group deploy" "$out"
_test "group deploy ran both services on the agent" \
  bash -c "grep -q 'api deployed' '$EDGE/.e2e-events' && grep -q 'worker deployed' '$EDGE/.e2e-events'"
out=$(cli group status e2e)
show "group status" "$out"
_test_contains "group status shows cloud project health" "2/2" "$out"

# ── Cancel (opt-in, documents current agent behaviour) ──
# The relay protocol has no cancel message: stopping muster-tunnel closes the
# session but the agent keeps running the command it already started.
if [[ -n "${MUSTER_E2E_CANCEL:-}" ]]; then
  echo ""
  echo "  cancel (informational)"
  printf '#!/usr/bin/env bash\nsleep 4\necho "worker deployed (slow)" >> "$PWD/.e2e-events"\n' > "$EDGE/.muster/hooks/worker/deploy.sh"
  agent_env MUSTER_APPROVE_HOOKS=1 bash -c "cd '$EDGE' && '$MUSTER_ROOT/bin/muster' deploy worker" >/dev/null 2>&1
  rm -f "$EDGE/.e2e-events"
  helper "_cloud_muster edge-1 '$EDGE' deploy worker" >"$TMP/cancel.log" 2>&1 &
  _hp=$!
  sleep 1.5
  pkill -TERM -f "muster-tunnel exec.*deploy worker" 2>/dev/null
  wait "$_hp" 2>/dev/null
  echo "    local tunnel stopped (exit after SIGTERM)"
  sleep 5
  show "cancel: local output" "$(cat "$TMP/cancel.log")"
  show "cancel: agent log" "$(tail -5 "$TMP/agent.log")"
  if grep -q "worker deployed (slow)" "$EDGE/.e2e-events" 2>/dev/null; then
    echo "    remote deploy still ran to completion on the agent (no cancel in protocol)"
  else
    echo "    remote deploy was stopped on the agent"
  fi
fi

if (( FAIL > 0 )); then
  echo ""
  echo "  --- relay log (tail) ---"; tail -20 "$TMP/relay.log" | sed 's/^/  /'
  echo "  --- agent log (tail) ---"; tail -20 "$TMP/agent.log" | sed 's/^/  /'
fi

_test_summary
