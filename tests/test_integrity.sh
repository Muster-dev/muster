#!/usr/bin/env bash
# tests/test_integrity.sh — Tests for app file integrity verification
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"

# Check shasum is available
if ! command -v shasum >/dev/null 2>&1; then
  echo "  SKIP: shasum not available"
  exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Set up a fake muster install to test against
FAKE_ROOT="${TMPDIR}/muster"
mkdir -p "${FAKE_ROOT}/lib/core" "${FAKE_ROOT}/bin"
printf '#!/usr/bin/env bash\nMUSTER_VERSION="0.0.1-test"\necho "hello"\n' > "${FAKE_ROOT}/bin/muster"
echo 'echo "hello"' > "${FAKE_ROOT}/lib/core/utils.sh"
echo 'echo "colors"' > "${FAKE_ROOT}/lib/core/colors.sh"

# Copy the real app_verify.sh
cp "$MUSTER_ROOT/lib/core/app_verify.sh" "${FAKE_ROOT}/lib/core/app_verify.sh"

# ────────────────────────────────────────
echo "  Integrity — manifest generation"
# ────────────────────────────────────────

# Generate manifest (disable set -e in subshell since grep pipefail can fail)
(
  set +e
  MUSTER_ROOT="$FAKE_ROOT"
  export MUSTER_ROOT
  source "${FAKE_ROOT}/lib/core/app_verify.sh"
  _app_manifest_generate 2>/dev/null
)

_test_file_exists "manifest file generated" "${FAKE_ROOT}/.muster.manifest"

# Should contain entries for tracked files (JSON format)
_manifest=$(cat "${FAKE_ROOT}/.muster.manifest")
_test_contains "manifest has bin/muster" "bin/muster" "$_manifest"
_test_contains "manifest has lib/core/utils.sh" "lib/core/utils.sh" "$_manifest"

# Should contain SHA256 hashes (64 hex chars in the JSON)
_has_sha=$(echo "$_manifest" | python3 -c "import json,sys; d=json.load(sys.stdin); f=list(d['files'].values())[0]; print(len(f['sha256']))" 2>/dev/null || echo "0")
_test_eq "hash is 64 chars (SHA256)" "64" "$_has_sha"

# ────────────────────────────────────────
echo ""
echo "  Integrity — verification passes"
# ────────────────────────────────────────

_rc=0
(
  set +e
  MUSTER_ROOT="$FAKE_ROOT"
  export MUSTER_ROOT
  source "${FAKE_ROOT}/lib/core/app_verify.sh"
  _app_verify_full 2>/dev/null
) || _rc=$?
_test_eq "verification passes with clean files" "0" "$_rc"

# ────────────────────────────────────────
echo ""
echo "  Integrity — detects tampering"
# ────────────────────────────────────────

# Modify a tracked file
echo 'echo "tampered"' >> "${FAKE_ROOT}/lib/core/utils.sh"

_rc=0
(
  set +e
  MUSTER_ROOT="$FAKE_ROOT"
  export MUSTER_ROOT
  source "${FAKE_ROOT}/lib/core/app_verify.sh"
  _app_verify_full 2>/dev/null
) || _rc=$?
_test "verification fails after tampering" test "$_rc" -ne 0

# Restore the file
echo 'echo "hello"' > "${FAKE_ROOT}/lib/core/utils.sh"

# ────────────────────────────────────────
echo ""
echo "  Integrity — regeneration after fix"
# ────────────────────────────────────────

(
  set +e
  MUSTER_ROOT="$FAKE_ROOT"
  export MUSTER_ROOT
  source "${FAKE_ROOT}/lib/core/app_verify.sh"
  _app_manifest_generate 2>/dev/null
)

_rc=0
(
  set +e
  MUSTER_ROOT="$FAKE_ROOT"
  export MUSTER_ROOT
  source "${FAKE_ROOT}/lib/core/app_verify.sh"
  _app_verify_full 2>/dev/null
) || _rc=$?
_test_eq "verification passes after regen" "0" "$_rc"

_test_summary
