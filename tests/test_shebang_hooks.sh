#!/usr/bin/env bash
# tests/test_shebang_hooks.sh — Hooks with #! shebang run directly (Python, etc.)
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
export MUSTER_APPROVE_HOOKS=1

# ────────────────────────────────────────
echo "  Hooks — non-shebang fallback to bash"
# ────────────────────────────────────────

(
  source "$MUSTER_ROOT/lib/core/colors.sh"
  source "$MUSTER_ROOT/lib/core/logger.sh"
  source "$MUSTER_ROOT/lib/core/utils.sh"
  _no_sb="${TMPDIR}/plain.sh"
  printf 'echo "from-bash-fallback"\n' > "$_no_sb"
  chmod +x "$_no_sb"
  _out=$(_run_hook "$_no_sb")
  [[ "$_out" == "from-bash-fallback" ]]
)
_test_eq "executable hook without shebang falls back to bash" "0" "$?"

# ────────────────────────────────────────
echo ""
echo "  Hooks — python3 shebang end-to-end"
# ────────────────────────────────────────

if ! command -v python3 >/dev/null 2>&1; then
  echo "  (skipped python3 hook tests: python3 not installed)"
  _test_summary
  exit $?
fi

PROJ="${TMPDIR}/pyproj"
mkdir -p "${PROJ}/.muster/hooks/pyapp"
cat > "${PROJ}/muster.json" << 'EOF'
{
  "project": "pyproj",
  "version": "1",
  "services": {
    "pyapp": {
      "name": "PyApp",
      "health": { "enabled": true, "type": "command" }
    }
  },
  "deploy_order": ["pyapp"]
}
EOF

# Pure Python syntax that bash cannot execute
cat > "${PROJ}/.muster/hooks/pyapp/deploy.sh" << 'EOF'
#!/usr/bin/env python3
import pathlib, sys
pathlib.Path("deployed.marker").write_text("py-deploy-ok\n")
print("deployed via python3")
sys.exit(0)
EOF

cat > "${PROJ}/.muster/hooks/pyapp/health.sh" << 'EOF'
#!/usr/bin/env python3
import pathlib, sys
sys.exit(0 if pathlib.Path("deployed.marker").exists() else 1)
EOF

cat > "${PROJ}/.muster/hooks/pyapp/rollback.sh" << 'EOF'
#!/usr/bin/env python3
import pathlib
pathlib.Path("rolledback.marker").write_text("py-rb-ok\n")
print("rolled back via python3")
EOF

cat > "${PROJ}/.muster/hooks/pyapp/logs.sh" << 'EOF'
#!/usr/bin/env python3
print("python-log-line-42")
EOF

cat > "${PROJ}/.muster/hooks/pyapp/cleanup.sh" << 'EOF'
#!/usr/bin/env python3
import pathlib
pathlib.Path("cleaned.marker").write_text("py-clean-ok\n")
EOF

chmod +x "${PROJ}/.muster/hooks/pyapp/"*.sh

_rc=0
_out=$(cd "$PROJ" && "$MUSTER_BIN" deploy pyapp </dev/null 2>&1) || _rc=$?
_test_eq "python3 deploy hook exits 0" "0" "$_rc"
_test_file_exists "python3 deploy hook ran python code" "${PROJ}/deployed.marker"

_rc=0
_out=$(cd "$PROJ" && "$MUSTER_BIN" status </dev/null 2>&1) || _rc=$?
_test_eq "python3 health hook exits 0 in muster status" "0" "$_rc"
_test_contains "muster status shows PyApp" "PyApp" "$_out"

_rc=0
_out=$(cd "$PROJ" && "$MUSTER_BIN" --minimal </dev/null 2>&1) || _rc=$?
_test_eq "python3 health hook works in muster --minimal" "0" "$_rc"
_test_contains "minimal dashboard reports PyApp healthy" "PyApp: healthy" "$_out"

_rc=0
_out=$(cd "$PROJ" && "$MUSTER_BIN" logs pyapp </dev/null 2>&1) || _rc=$?
_test_eq "python3 logs hook exits 0" "0" "$_rc"
_test_contains "python3 logs hook output returned" "python-log-line-42" "$_out"

_rc=0
_out=$(cd "$PROJ" && "$MUSTER_BIN" rollback pyapp </dev/null 2>&1) || _rc=$?
_test_eq "python3 rollback hook exits 0" "0" "$_rc"
_test_file_exists "python3 rollback hook ran python code" "${PROJ}/rolledback.marker"

_rc=0
_out=$(cd "$PROJ" && "$MUSTER_BIN" cleanup </dev/null 2>&1) || _rc=$?
_test_eq "python3 cleanup hook exits 0" "0" "$_rc"
_test_file_exists "python3 cleanup hook ran python code" "${PROJ}/cleaned.marker"

_test_summary
