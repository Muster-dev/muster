#!/usr/bin/env bash
# tests/test_cloud_connect.sh — muster cloud connect with a fake muster-agent
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/proj" "$TMP/elsewhere"
export MUSTER_CLOUD_NO_KEYCHAIN=1 MUSTER_NO_VERIFY=true MUSTER_NO_BROWSER=1 NO_COLOR=1 MUSTER_CONNECT_WAIT=3
M="$MUSTER_ROOT/bin/muster"
CALLS="$TMP/calls"

# Fake agent: records every call; behaviour from env
cat > "$TMP/fake-agent" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$1" in
  pair)
    echo "  Pair code: KX7-42QP"
    echo "  Approve at https://cloud.getmuster.dev/pair?code=KX7-42QP"
    exit "\${FAKE_PAIR_RC:-0}"
    ;;
  install-service) exit "\${FAKE_SERVICE_RC:-0}" ;;
  status) exit "\${FAKE_STATUS_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$TMP/fake-agent"
cp "$TMP/fake-agent" "$TMP/bin/muster-agent"
printf '{"project":"p","services":{}}\n' > "$TMP/proj/muster.json"

echo "  Pairing from a project directory"
: > "$CALLS"
out=$(cd "$TMP/proj" && PATH="$TMP/bin:$PATH" "$M" cloud connect --name prod-1 --user-service </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "exits 0" "0" "$rc"
_test_contains "agent output (code) shown" "KX7-42QP" "$out"
_test_contains "pair called with name and cwd project" "pair --name prod-1 --project $(cd "$TMP/proj" && pwd)" "$(cat "$CALLS")"
_test_contains "user service installed" "install-service --user" "$(cat "$CALLS")"
_test_contains "connection verified" "status --connected" "$(cat "$CALLS")"
_test_contains "reports connected" "Agent connected to Fleet Cloud" "$out"

echo "  Flags: --project, --relay, --no-service"
: > "$CALLS"
out=$(cd "$TMP/elsewhere" && PATH="$TMP/bin:$PATH" "$M" cloud connect --project "$TMP/proj" --relay wss://relay.example.test --no-service </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "exits 0" "0" "$rc"
_test_contains "explicit project and relay" "--project $(cd "$TMP/proj" && pwd) --relay wss://relay.example.test" "$(cat "$CALLS")"
_test_not_contains "no service with --no-service" "install-service" "$(cat "$CALLS")"
_test_contains "explains how to run the agent" "muster-agent run" "$out"

echo "  Non-interactive defaults outside a project"
: > "$CALLS"
out=$(cd "$TMP/elsewhere" && PATH="$TMP/bin:$PATH" "$M" cloud connect </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "exits 0" "0" "$rc"
_test_eq "probes pair support first" "pair --help" "$(sed -n 1p "$CALLS")"
_test_eq "pair without project" "pair" "$(sed -n 2p "$CALLS")"
_test_not_contains "no service by default without a terminal" "install-service" "$(cat "$CALLS")"

echo "  Failures"
out=$(cd "$TMP/proj" && FAKE_PAIR_RC=1 PATH="$TMP/bin:$PATH" "$M" cloud connect --no-service </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "pair failure exits 1" "1" "$rc"
_test_contains "pair failure message" "Pairing did not complete" "$out"

out=$(cd "$TMP/proj" && FAKE_STATUS_RC=3 PATH="$TMP/bin:$PATH" "$M" cloud connect --user-service </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "not yet connected still exits 0" "0" "$rc"
_test_contains "warns when not connected" "hasn't connected yet" "$out"

out=$(PATH="$TMP/bin:$PATH" "$M" cloud connect --project "$TMP/nope" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "missing project dir exits 1" "1" "$rc"

echo "  Installing muster-agent when missing"
if command -v muster-agent >/dev/null 2>&1; then
  echo "  (skipped: a real muster-agent is on PATH)"
else
  cat > "$TMP/install.sh" <<EOF
#!/usr/bin/env bash
[[ "\$*" == "--agent --yes" ]] || { echo "bad args: \$*"; exit 9; }
mkdir -p "\$HOME/.muster/bin"
cp "$TMP/fake-agent" "\$HOME/.muster/bin/muster-agent"
EOF
  : > "$CALLS"
  out=$(cd "$TMP/proj" && "$M" cloud connect --no-service </dev/null 2>&1) && rc=0 || rc=$?
  _test_eq "missing agent without --yes (non-TTY) exits 1" "1" "$rc"
  _test_contains "suggests --yes" "--yes" "$out"
  out=$(cd "$TMP/proj" && MUSTER_AGENT_INSTALL_URL="file://$TMP/install.sh" "$M" cloud connect --yes --no-service </dev/null 2>&1) && rc=0 || rc=$?
  _test_eq "install + pair exits 0" "0" "$rc"
  _test "agent installed to ~/.muster/bin" test -x "$HOME/.muster/bin/muster-agent"
  _test_contains "installed agent used for pairing" "pair --project" "$(cat "$CALLS")"
fi

echo "  Old agent without pair is updated first"
mkdir -p "$TMP/oldbin"
cat > "$TMP/oldbin/muster-agent" <<EOF
#!/usr/bin/env bash
printf 'old %s\n' "\$*" >> "$CALLS"
[[ "\$1" == "pair" ]] && { echo "unknown command: pair"; exit 1; }
exit 0
EOF
chmod +x "$TMP/oldbin/muster-agent"
: > "$CALLS"
out=$(cd "$TMP/proj" && PATH="$TMP/oldbin:$PATH" "$M" cloud connect --no-service </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "old agent without --yes (non-TTY) exits 1" "1" "$rc"
_test_contains "explains the agent is too old" "too old" "$out"
_test_not_contains "old agent never asked to pair for real" "old pair --project" "$(cat "$CALLS")"

out=$(cd "$TMP/proj" && FAKE_PAIR_RC=130 PATH="$TMP/bin:$PATH" "$M" cloud connect --no-service </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "Ctrl+C during pair exits 130" "130" "$rc"

echo "  login --qr is optional"
out=$("$M" cloud login --qr --relay "http://127.0.0.1:1" </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "--qr accepted (fails only on the unreachable relay)" "1" "$rc"
_test_contains "unreachable relay message" "Can't reach the relay" "$out"

if command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  PORT=$((20000 + RANDOM % 20000))
  MODE=approve python3 "$SCRIPT_DIR/fixtures/mock_relay.py" "$PORT" &
  RELAY_PID=$!
  disown "$RELAY_PID" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:${PORT}/healthz" && break
    sleep 0.2
  done
  printf '#!/usr/bin/env bash\necho "QR[$*]"\n' > "$TMP/bin/qrencode"
  chmod +x "$TMP/bin/qrencode"
  out=$(MUSTER_FORCE_QR=1 PATH="$TMP/bin:$PATH" "$M" cloud login --qr --relay "http://127.0.0.1:${PORT}" </dev/null 2>&1) && rc=0 || rc=$?
  kill "$RELAY_PID" 2>/dev/null || true
  _test_eq "login --qr succeeds" "0" "$rc"
  _test_contains "QR of the verification URL via qrencode" "QR[-t ansiutf8 -m 2 http://localhost/device?code=WXYZ-2345]" "$out"
  rm -f "$TMP/bin/qrencode"
fi

_test_summary
