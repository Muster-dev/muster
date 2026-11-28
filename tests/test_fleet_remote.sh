#!/usr/bin/env bash
# tests/test_fleet_remote.sh — fleet test --json, fleet logs, fleet restart
#
# Stub muster-tunnel (cloud) and ssh binaries record what would be sent to
# each server; nothing touches a real machine.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MUSTER_NO_VERIFY=true NO_COLOR=1 MUSTER_CLOUD_NO_KEYCHAIN=1
mkdir -p "$HOME/.muster/tokens" "$TMP/bin" "$TMP/p/.muster/hooks/web" "$TMP/p/.muster/hooks/api"
M="$MUSTER_ROOT/bin/muster"
export CALLS="$TMP/calls.log"

# ── stubs ──
cat > "$TMP/bin/muster-tunnel" <<'STUB'
#!/usr/bin/env bash
sub="$1"; shift
cmd="" agent=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cmd) cmd="$2"; shift 2 ;;
    --agent) agent="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'tunnel %s %s %s\n' "$sub" "$agent" "$cmd" >> "$CALLS"
case "$sub" in
  ping) exit "${PING_RC:-0}" ;;
  exec)
    case "$cmd" in
      "muster status --json --no-verify")
        printf '{"project":"x","services":{"web":{"status":"healthy"}}}\n' ;;
      "muster logs web --tail "*" --json --no-verify")
        printf '{"event":"log","service":"web","source":"docker compose","line":"hello \\"world\\""}\n'
        printf 'a stray stderr line\n'
        printf '{"event":"end","service":"web","source":"docker compose","exit_code":0}\n' ;;
      "muster logs web --tail "*" --no-verify")
        printf 'web-1  | hello\n' ;;
      "muster logs nope --tail "*)
        printf '{"error":"unknown_service","message":"Unknown service: nope"}\n'; exit 1 ;;
      "muster restart web --no-verify")
        printf 'restarted web\n'; exit "${RESTART_RC:-0}" ;;
      "muster restart api --no-verify")
        printf 'Error: command not in allowlist\n'; exit 1 ;;
      *) printf 'unexpected\n'; exit 2 ;;
    esac ;;
esac
STUB
cat > "$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
host="" cmd=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|-i|-p) shift 2 ;;
    *@*) host="$1"; shift; cmd="$*"; break ;;
    *) shift ;;
  esac
done
printf 'ssh %s %s\n' "$host" "$cmd" >> "$CALLS"
[[ -n "${SSH_FAIL:-}" ]] && exit 255
case "$cmd" in
  "echo ok") echo ok ;;
  "bash -s") bash -s ;;   # push mode: run the piped script "remotely" (here)
  *"muster status --json"*) printf '{"services":{"web":{"status":"healthy"}}}\n' ;;
  *"muster logs web --tail 7 --json"*) printf '{"event":"log","service":"web","source":"file","line":"x"}\n{"event":"end","service":"web","source":"file","exit_code":0}\n' ;;
  *"muster logs web --tail 7"*) printf 'ssh log line\n' ;;
  *"muster restart web"*) printf 'restarted\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/muster-tunnel" "$TMP/bin/ssh"
export PATH="$TMP/bin:$PATH"

cd "$TMP/p"
cat > muster.json <<'EOF'
{"project":"fr","services":{"web":{"name":"Web"},"api":{"name":"API"}},"deploy_order":["web","api"]}
EOF
# Push-mode logs hook that never exits on its own (like tail -f)
cat > .muster/hooks/web/logs.sh <<'EOF'
#!/usr/bin/env bash
for i in 1 2 3 4 5 6; do echo "push line $i (tail=${MUSTER_LOGS_TAIL})"; done
sleep 30
EOF
mkdir -p "$TMP/remote-p"
cat > remotes.json <<EOF
{"cloud":{"relay":"ws://127.0.0.1:1","org_id":"org_t","token_ref":"default"},
 "machines":{
  "edge":{"host":"edge-agent","user":"u","mode":"muster","transport":"cloud","project_dir":"/opt/app"},
  "box":{"host":"10.0.0.9","user":"deploy","mode":"muster","project_dir":"/srv/app"},
  "pusher":{"host":"10.0.0.8","user":"deploy","mode":"push","project_dir":"$TMP/remote-p"}},
 "groups":{"all":["edge","box","pusher"]},"deploy_order":["all"]}
EOF
printf '{"tokens":{"default":"mst_test"}}\n' > "$HOME/.muster/tokens/cloud.json"
chmod 600 "$HOME/.muster/tokens/cloud.json"
T=$("$M" auth create t --scope admin 2>/dev/null | awk '/Token:/{print $2}')
R=$(MUSTER_TOKEN="$T" "$M" auth create r --scope read 2>/dev/null | awk '/Token:/{print $2}')
export MUSTER_TOKEN="$T"
MUSTER_TOKEN="$T" "$M" fleet pair box --token boxtok >/dev/null 2>&1

# ── fleet test --json ──
echo ""
echo "  fleet test --json"
out=$("$M" fleet test --json 2>/dev/null); rc=$?
_test "single JSON document" bash -c 'printf "%s" "$1" | jq -e .servers >/dev/null' _ "$out"
_test_eq "all pass → exit 0" "0" "$rc"
_test_eq "counts" "3|0" "$(printf '%s' "$out" | jq -r '"\(.passed)|\(.failed)"')"
_test_eq "cloud server fields" "cloud|muster|true|ok|ok|" \
  "$(printf '%s' "$out" | jq -r '.servers[] | select(.name=="edge") | "\(.transport)|\(.mode)|\(.ok)|\(.connect)|\(.muster)|\(.error)"')"
_test_eq "push mode → muster skip" "skip" "$(printf '%s' "$out" | jq -r '.servers[] | select(.name=="pusher") | .muster')"
_test_eq "latency_ms is an integer" "true" "$(printf '%s' "$out" | jq '[.servers[].latency_ms | type == "number" and . == floor and . >= 0] | all')"
_test_eq "exact keys" "connect,error,latency_ms,mode,muster,name,ok,transport" \
  "$(printf '%s' "$out" | jq -r '.servers[0] | keys | join(",")')"

out=$(SSH_FAIL=1 "$M" fleet test box --json 2>/dev/null); rc=$?
_test_eq "failed server → exit 1" "1" "$rc"
_test_eq "ssh failure fields" "false|fail|SSH connection failed|0|1" \
  "$(printf '%s' "$out" | jq -r '"\(.servers[0].ok)|\(.servers[0].connect)|\(.servers[0].error)|\(.passed)|\(.failed)"')"
out=$(PING_RC=1 "$M" fleet test edge --json 2>/dev/null)
_test_eq "cloud agent offline" "fail|cloud agent is not connected to the relay" \
  "$(printf '%s' "$out" | jq -r '.servers[0] | "\(.connect)|\(.error)"')"
out=$("$M" fleet test ghost --json 2>/dev/null); rc=$?
_test_eq "unknown server reported, exit 1" "1|false|not in the fleet config" \
  "$rc|$(printf '%s' "$out" | jq -r '.servers[0] | "\(.ok)|\(.error)"')"
out=$(MUSTER_TOKEN="" "$M" fleet test --json 2>&1); rc=$?
_test_eq "needs a token" "1" "$rc"
out=$("$M" fleet test 2>&1)
_test_contains "human summary says servers" "All 3 servers passed" "$out"
out=$("$M" fleet test edge 2>&1)
_test_contains "singular server" "All 1 server passed" "$out"
_test_not_contains "no machine(s)" "machine(s)" "$out"

# ── fleet logs ──
echo ""
echo "  fleet logs"
: > "$CALLS"
out=$("$M" fleet logs edge web --tail 5 --json 2>"$TMP/err"); rc=$?
_test_eq "cloud json logs exit 0" "0" "$rc"
_test_eq "stdout is only event lines" "2" "$(printf '%s\n' "$out" | jq -s 'length')"
_test_eq "event line passes through" 'hello "world"' "$(printf '%s\n' "$out" | head -1 | jq -r .line)"
_test_contains "non-JSON goes to stderr" "a stray stderr line" "$(cat "$TMP/err")"
_test_contains "cloud argv" "tunnel exec edge-agent muster logs web --tail 5 --json --no-verify" "$(cat "$CALLS")"

out=$("$M" fleet logs edge web 2>/dev/null)
_test_eq "human logs" "web-1  | hello" "$out"
_test_contains "default tail 100" "muster logs web --tail 100 --no-verify" "$(cat "$CALLS")"
"$M" fleet logs edge web --tail 5000 >/dev/null 2>&1
_test_contains "tail capped at 1000" "muster logs web --tail 1000 --no-verify" "$(cat "$CALLS")"

out=$("$M" fleet logs edge nope --json 2>"$TMP/err"); rc=$?
_test_eq "remote error → exit 1, empty stdout" "1|" "$rc|$out"
_test_eq "remote error document forwarded once" "unknown_service" "$(jq -r .error < "$TMP/err")"

: > "$CALLS"
out=$("$M" fleet logs box web --tail 7 --json 2>/dev/null)
_test_eq "ssh json logs" "log,end" "$(printf '%s\n' "$out" | jq -r -s 'map(.event) | join(",")')"
_test_contains "ssh: token + cd + quoted argv" "cd /srv/app && MUSTER_TOKEN=boxtok muster logs web --tail 7 --json" "$(cat "$CALLS")"
out=$("$M" fleet logs box web --tail 7 2>/dev/null)
_test_eq "ssh human logs" "ssh log line" "$out"

start=$(date +%s)
out=$("$M" fleet logs pusher web --tail 3 --json 2>/dev/null); rc=$?
elapsed=$(( $(date +%s) - start ))
_test_eq "push: hook wrapped as NDJSON" "push line 4 (tail=3)|push line 6 (tail=3)|end|0" \
  "$(printf '%s\n' "$out" | jq -r -s '"\(.[0].line)|\(.[2].line)|\(.[3].event)|\(.[3].exit_code)"')"
_test "push: following hook stopped after ~5s" test "$elapsed" -lt 15

for bad in "web;id" "../x" "a b"; do
  out=$("$M" fleet logs edge "$bad" --json 2>&1); rc=$?
  _test_eq "invalid service '${bad}' → usage" "1|usage" "$rc|$(printf '%s' "$out" | jq -r .error 2>/dev/null)"
done
out=$("$M" fleet logs ghost web --json 2>&1); rc=$?
_test_eq "unknown server" "1|unknown_server" "$rc|$(printf '%s' "$out" | jq -r .error)"
out=$("$M" fleet logs edge web --follow 2>&1); rc=$?
_test_eq "--follow refused" "1" "$rc"
_test_contains "help mentions no --follow" "--follow is not supported" "$("$M" fleet logs --help)"
out=$(MUSTER_TOKEN="" "$M" fleet logs edge web --json 2>&1); rc=$?
_test_eq "logs --json needs a token" "1" "$rc"

# ── fleet restart ──
echo ""
echo "  fleet restart"
: > "$CALLS"
out=$("$M" fleet restart edge web --json </dev/null 2>&1); rc=$?
_test_eq "no TTY without --yes → confirmation_required" "1|confirmation_required" "$rc|$(printf '%s' "$out" | jq -r .error)"
_test_eq "nothing sent without confirmation" "" "$(grep 'restart' "$CALLS")"

out=$("$M" fleet restart edge web --yes --json 2>/dev/null); rc=$?
_test_eq "cloud restart ok" "0|edge|web|true|" \
  "$rc|$(printf '%s' "$out" | jq -r '"\(.server)|\(.results[0].service)|\(.results[0].ok)|\(.results[0].error)"')"
_test_contains "cloud restart argv" "tunnel exec edge-agent muster restart web --no-verify" "$(cat "$CALLS")"

out=$("$M" fleet restart edge --yes --json 2>/dev/null); rc=$?
_test_eq "no services → deploy order; api fails → exit 1" "1|web:true,api:false" \
  "$rc|$(printf '%s' "$out" | jq -r '[.results[] | "\(.service):\(.ok)"] | join(",")')"
_test_contains "failure explained" "allowed_commands" "$(printf '%s' "$out" | jq -r '.results[1].error')"

: > "$CALLS"
out=$("$M" fleet restart box web -y --json 2>/dev/null); rc=$?
_test_eq "ssh restart ok" "0|true" "$rc|$(printf '%s' "$out" | jq -r '.results[0].ok')"
_test_contains "ssh restart command" "cd /srv/app && MUSTER_TOKEN=boxtok muster restart web" "$(cat "$CALLS")"

out=$("$M" fleet restart pusher web --yes --json 2>/dev/null); rc=$?
_test_contains "push mode without restart hook explains" "restart hook" "$(printf '%s' "$out" | jq -r '.results[0].error')"

out=$(MUSTER_TOKEN="$R" "$M" fleet restart edge web --yes --json 2>&1); rc=$?
_test_eq "restart --json needs deploy scope" "1|forbidden" "$rc|$(printf '%s' "$out" | jq -r .error)"
out=$("$M" fleet restart edge 'web;id' --yes --json 2>&1); rc=$?
_test_eq "invalid service refused" "1|usage" "$rc|$(printf '%s' "$out" | jq -r .error)"

# ── status / list / dry-run consistency ──
echo ""
echo "  status, list, dry-run"
out=$("$M" fleet status edge --json 2>/dev/null)
_test_eq "fleet status has muster_version (\"\" when remote doesn't report it)" "string|" \
  "$(printf '%s' "$out" | jq -r '.status[0].muster_version | "\(type)|\(.)"')"
out=$("$M" fleet list --json 2>/dev/null)
_test_eq "cloud server paired in list" "true" "$(printf '%s' "$out" | jq -r '.machines[] | select(.name=="edge") | .paired')"
out=$("$M" fleet deploy edge --dry-run 2>&1)
_test_not_contains "dry-run agrees: cloud server not unpaired" "unpaired" "$out"
_test_contains "dry-run shows cloud host" "cloud:edge-agent" "$out"

_test_summary
