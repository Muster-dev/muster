#!/usr/bin/env bash
# tests/test_hooks_approve.sh — Tests for muster hooks approve (no sudo, TTY prompt, non-TTY --yes)
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUSTER_BIN="$MUSTER_ROOT/bin/muster"

source "$SCRIPT_DIR/test_helpers.sh"

TMPDIR=$(mktemp -d)
export HOME="${TMPDIR}/home"
mkdir -p "$HOME"
trap 'rm -rf "$TMPDIR"' EXIT

export MUSTER_NO_VERIFY=true
export NO_COLOR=1
unset MUSTER_APPROVE_HOOKS

# Put a failing fake sudo on PATH to prove hooks approve never invokes sudo
FAKE_BIN="${TMPDIR}/fake_bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/sudo" << 'FAKE_SUDO'
#!/usr/bin/env bash
echo "SUDO_SHOULD_NOT_BE_CALLED" >&2
exit 99
FAKE_SUDO
chmod +x "${FAKE_BIN}/sudo"
export PATH="${FAKE_BIN}:$PATH"

# Create test project
PROJ="${TMPDIR}/app"
mkdir -p "${PROJ}/.muster/hooks/api"
cat > "${PROJ}/muster.json" << 'EOF'
{
  "project": "approve-test",
  "version": "1",
  "services": {
    "api": { "name": "API", "health": { "enabled": false } }
  },
  "deploy_order": ["api"]
}
EOF
printf '#!/usr/bin/env bash\necho "deployed api"\n' > "${PROJ}/.muster/hooks/api/deploy.sh"
chmod +x "${PROJ}/.muster/hooks/api/deploy.sh"

# ────────────────────────────────────────
echo "  hooks approve — non-TTY requires --yes, never calls sudo"
# ────────────────────────────────────────

_rc=0
_out=$(cd "$PROJ" && "$MUSTER_BIN" hooks approve </dev/null 2>&1) || _rc=$?
_test_eq "non-TTY approve without --yes exits 1" "1" "$_rc"
_test_contains "non-TTY tells user to pass --yes" "--yes" "$_out"
_test_not_contains "non-TTY approve does not call sudo" "SUDO_SHOULD_NOT_BE_CALLED" "$_out"

# Deploy should still be blocked (nothing was approved)
_rc=0
_out=$(cd "$PROJ" && "$MUSTER_BIN" deploy api </dev/null 2>&1) || _rc=$?
_test_eq "deploy remains blocked after refused approve" "1" "$_rc"

# Now approve with --yes non-interactively
_rc=0
_out=$(cd "$PROJ" && "$MUSTER_BIN" hooks approve --yes </dev/null 2>&1) || _rc=$?
_test_eq "non-TTY approve --yes exits 0" "0" "$_rc"
_test_contains "approve --yes reports success" "All hooks approved" "$_out"
_test_not_contains "approve --yes never calls sudo" "SUDO_SHOULD_NOT_BE_CALLED" "$_out"

# Deploy now succeeds
_rc=0
_out=$(cd "$PROJ" && "$MUSTER_BIN" deploy api </dev/null 2>&1) || _rc=$?
_test_eq "deploy succeeds after hooks approve --yes" "0" "$_rc"

# ────────────────────────────────────────
echo ""
echo "  hooks approve — interactive TTY shows diff and asks y/N"
# ────────────────────────────────────────

if command -v python3 >/dev/null 2>&1; then
  # Edit hook so there is a real diff to show
  echo 'echo "step 2"' >> "${PROJ}/.muster/hooks/api/deploy.sh"

  _run_pty() {
    local reply="$1"
    python3 -c '
import os, pty, select, subprocess, sys, time
master, slave = pty.openpty()
p = subprocess.Popen(
    [sys.argv[1], "hooks", "approve"],
    cwd=sys.argv[2], stdin=slave, stdout=slave, stderr=slave, close_fds=True
)
os.close(slave)
sent = False
out = b""
deadline = time.time() + 10
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            out += chunk
            if not sent and b"[y/N]" in out:
                os.write(master, (sys.argv[3] + "\n").encode())
                sent = True
        except OSError:
            break
    if p.poll() is not None:
        break
os.close(master)
rc = p.wait(timeout=5)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(rc)
' "$MUSTER_BIN" "$PROJ" "$reply"
  }

  # Answering 'n' aborts without approving
  _rc=0
  _pty_no=$(_run_pty "n" 2>&1) || _rc=$?
  _test_eq "TTY approve answered 'n' exits 1" "1" "$_rc"
  _test_contains "TTY approve shows changed file" "api/deploy.sh" "$_pty_no"
  _test_contains "TTY approve shows diff hunk" '+echo "step 2"' "$_pty_no"
  _test_contains "TTY approve prompts y/N" "[y/N]" "$_pty_no"
  _test_not_contains "TTY approve never calls sudo" "SUDO_SHOULD_NOT_BE_CALLED" "$_pty_no"

  # Still unapproved after 'n'
  _rc=0
  (cd "$PROJ" && "$MUSTER_BIN" deploy api </dev/null >/dev/null 2>&1) || _rc=$?
  _test_eq "deploy still blocked after answering 'n'" "1" "$_rc"

  # Answering 'y' approves
  _rc=0
  _pty_yes=$(_run_pty "y" 2>&1) || _rc=$?
  _test_eq "TTY approve answered 'y' exits 0" "0" "$_rc"
  _test_contains "TTY approve 'y' confirms approval" "All hooks approved" "$_pty_yes"

  # Deploy now succeeds
  _rc=0
  (cd "$PROJ" && "$MUSTER_BIN" deploy api </dev/null >/dev/null 2>&1) || _rc=$?
  _test_eq "deploy succeeds after TTY approval" "0" "$_rc"
fi

_test_summary
