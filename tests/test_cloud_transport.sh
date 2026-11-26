#!/usr/bin/env bash
# tests/test_cloud_transport.sh — cloud transport argv helpers (no Go needed)
#
# A stub muster-tunnel records the exact argv it was given, so these tests
# check what would be sent to the agent. tests/test_cloud_e2e.sh covers the
# real relay + agent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MUSTER_CLOUD_NO_KEYCHAIN=1 NO_COLOR=1 MUSTER_ROOT
mkdir -p "$HOME" "$TMP/bin"

# Stub tunnel: print argv one per line, exit with $STUB_RC
cat > "$TMP/bin/muster-tunnel" <<'STUB'
#!/usr/bin/env bash
printf 'token=%s\n' "${MUSTER_CLOUD_TOKEN:-}" >> "$STUB_LOG"
for a in "$@"; do printf 'arg=%s\n' "$a" >> "$STUB_LOG"; done
[[ -n "${STUB_OUT:-}" ]] && printf '%s\n' "$STUB_OUT"
exit "${STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/muster-tunnel"
export PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/stub.log"

source "$MUSTER_ROOT/lib/core/colors.sh"
source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/config.sh"
source "$MUSTER_ROOT/lib/core/cloud.sh"
FLEET_CLOUD_RELAY="ws://127.0.0.1:1"
FLEET_CLOUD_ORG="org_x"
FLEET_CLOUD_TOKEN="mst_cli_test"

stub_args() { grep '^arg=' "$STUB_LOG" | sed 's/^arg=//' | tr '\n' ' '; }

echo ""
echo "  word filter"
_test "plain service name ok" _cloud_word_ok "api-v1"
_test "flag ok" _cloud_word_ok "--no-verify"
_test "absolute path ok" _cloud_word_ok "/opt/app"
for bad in "a;b" 'a$b' 'a`b`' "a b" "a|b" "a&b" "a>b" "a'b" 'a"b' "a*" "~/x" "a(b)" ""; do
  _test "rejects '${bad}'" env BAD="$bad" bash -c 'source "$MUSTER_ROOT/lib/core/cloud.sh" 2>/dev/null; ! _cloud_word_ok "$BAD"'
done

echo ""
echo "  _cloud_muster"
: > "$STUB_LOG"
_cloud_muster edge-1 /opt/app deploy --force api >/dev/null
_test_eq "builds a plain argv with --no-verify and --cwd" \
  "exec --relay ws://127.0.0.1:1 --org org_x --agent edge-1 --cmd muster deploy --force api --no-verify --cwd /opt/app " \
  "$(stub_args)"
_test_contains "token travels in the env, not argv" "token=mst_cli_test" "$(cat "$STUB_LOG")"
_test_not_contains "token never in argv" "arg=mst_cli_test" "$(cat "$STUB_LOG")"

: > "$STUB_LOG"
_cloud_muster edge-1 "" status --json >/dev/null
_test_eq "empty cwd → agent's own project dir (no --cwd)" \
  "exec --relay ws://127.0.0.1:1 --org org_x --agent edge-1 --cmd muster status --json --no-verify " \
  "$(stub_args)"

: > "$STUB_LOG"
out=$(_cloud_muster edge-1 "" rollback 'api;id' 2>&1); rc=$?
_test_eq "metacharacter arg → rc 1" "1" "$rc"
_test_contains "metacharacter arg → clear error" "only plain words" "$out"
_test_eq "metacharacter arg → nothing sent" "" "$(cat "$STUB_LOG")"

out=$(_cloud_muster edge-1 relative/dir status 2>&1); rc=$?
_test_eq "relative cwd refused" "1" "$rc"

STUB_RC=3 _cloud_muster edge-1 "" deploy >/dev/null 2>&1; rc=$?
_test_eq "remote exit code propagates" "3" "$rc"

echo ""
echo "  _cloud_exec_plain"
: > "$STUB_LOG"
out=$(_cloud_exec_plain edge-1 "id -u" 2>&1); rc=$?
_test_eq "non-muster command refused" "1" "$rc"
_test_contains "non-muster command message" "only muster commands" "$out"
out=$(_cloud_exec_plain edge-1 "MUSTER_TOKEN=x muster status --json" 2>&1); rc=$?
_test_eq "env-prefixed command refused" "1" "$rc"
out=$(_cloud_exec_plain edge-1 "cd /opt && muster deploy" 2>&1); rc=$?
_test_contains "shell string refused" "needs a shell" "$out"
_test_eq "nothing sent for refused commands" "" "$(cat "$STUB_LOG")"
_cloud_exec_plain edge-1 "muster status" /opt/app >/dev/null
_test_contains "plain muster command forwarded" "arg=muster status" "$(cat "$STUB_LOG")"

echo ""
echo "  status parsing"
STUB_OUT='muster-tunnel: pinning key for agent edge-1
{"project":"p","services":{"api":{"status":"healthy"},"web":{"status":"unhealthy"},"db":{"status":"disabled"}}}'
export STUB_OUT
json=$(_cloud_status_json edge-1 "")
_test_eq "status json extracted past preamble" "p" "$(printf '%s' "$json" | jq -r .project)"
_test_eq "summary counts healthy" "1/3 healthy" "$(_cloud_status_summary "$json")"
_test "unhealthy detected" bash -c "source '$MUSTER_ROOT/lib/core/cloud.sh'; ! _cloud_status_all_healthy '$json'"
STUB_OUT='{"error":"auth_required"}'
_test "non-status output → failure" bash -c "! _cloud_status_json edge-1 ''"
unset STUB_OUT

echo ""
echo "  failure explanations"
printf 'x worker/deploy.sh hasn'"'"'t been approved on this machine\n' > "$TMP/o1"
_test_contains "unapproved hooks" "Hooks on edge-1 aren't approved yet. On that machine run: muster hooks approve" \
  "$(_cloud_explain_failure edge-1 "$TMP/o1")"
printf 'error: E_COMMAND_REJECTED: push_hook is disabled (agent is not in push mode)\n' > "$TMP/o2"
_test_contains "push mode disabled" "not in push mode" "$(_cloud_explain_failure edge-1 "$TMP/o2")"
printf 'error: E_COMMAND_REJECTED: command rejected: "muster hooks" not in allowlist\n' > "$TMP/o3"
_test_contains "allowlist" "allowed_commands" "$(_cloud_explain_failure edge-1 "$TMP/o3")"
printf 'boom\n' > "$TMP/o4"
_test "unknown failure → no explanation" bash -c "source '$MUSTER_ROOT/lib/core/cloud.sh'; ! _cloud_explain_failure edge-1 '$TMP/o4' >/dev/null"

echo ""
echo "  json auth gate"
source "$MUSTER_ROOT/lib/core/auth.sh"
_test "parent is not muster-agent → gate needs a token" bash -c \
  "source '$MUSTER_ROOT/lib/core/colors.sh'; source '$MUSTER_ROOT/lib/core/logger.sh'; source '$MUSTER_ROOT/lib/core/auth.sh'; unset MUSTER_TOKEN; ! _json_auth_gate read 2>/dev/null"
# A process named muster-agent as the direct parent → read scope allowed.
# Needs a real binary with that name that forks (copied system binaries are
# killed on macOS), so compile a tiny fork/exec/wait wrapper.
if command -v cc >/dev/null 2>&1; then
  cat > "$TMP/agent.c" <<'C'
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
  int st = 0;
  pid_t p = fork();
  if (p == 0) { execvp(argv[1], argv + 1); _exit(127); }
  waitpid(p, &st, 0);
  return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}
C
  if cc -o "$TMP/bin/muster-agent" "$TMP/agent.c" 2>/dev/null; then
    out=$("$TMP/bin/muster-agent" bash -c '
      source "$MUSTER_ROOT/lib/core/colors.sh"
      source "$MUSTER_ROOT/lib/core/logger.sh"
      source "$MUSTER_ROOT/lib/core/auth.sh"
      unset MUSTER_TOKEN
      _json_auth_gate read && echo read-ok
      _json_auth_gate deploy 2>/dev/null || echo deploy-denied')
    _test_contains "muster-agent parent → read scope without token" "read-ok" "$out"
    _test_contains "muster-agent parent → deploy scope still needs a token" "deploy-denied" "$out"
  fi
else
  echo "  (skipped muster-agent parent check: no C compiler)"
fi

_test_summary
