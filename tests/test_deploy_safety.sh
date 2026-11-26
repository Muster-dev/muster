#!/usr/bin/env bash
# tests/test_deploy_safety.sh — exit codes, hook approval (trust store),
# writable hooks, deploy summary, and plain (no-ANSI) piped output.
# Runs bin/muster end-to-end against fake bare hooks. HOME is a temp dir.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUSTER_BIN="$MUSTER_ROOT/bin/muster"

source "$SCRIPT_DIR/test_helpers.sh"

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# Never touch the real ~/.muster
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"
unset NO_COLOR MUSTER_APPROVE_HOOKS MUSTER_TOKEN MUSTER_HOOK_UNSAFE
export MUSTER_NO_VERIFY=true

ESC=$'\033'

# Create a project: ok1 (passes), bad (exit 3), ok2 (passes, healthy)
# Args: dir
_mk_project() {
  local d="$1"
  mkdir -p "$d/.muster/hooks/ok1" "$d/.muster/hooks/bad" "$d/.muster/hooks/ok2"
  cat > "$d/muster.json" <<'JSON'
{"project":"fx","version":"1","services":{
 "ok1":{"name":"Alpha","health":{"enabled":false}},
 "bad":{"name":"Bravo","health":{"enabled":false}},
 "ok2":{"name":"Charlie","health":{"enabled":true,"type":"command"}}},
 "deploy_order":["ok1","bad","ok2"]}
JSON
  printf '#!/usr/bin/env bash\necho "alpha deployed"\n' > "$d/.muster/hooks/ok1/deploy.sh"
  printf '#!/usr/bin/env bash\necho "alpha rolled back"\n' > "$d/.muster/hooks/ok1/rollback.sh"
  printf '#!/usr/bin/env bash\necho "building bravo"\nexit 3\n' > "$d/.muster/hooks/bad/deploy.sh"
  printf '#!/usr/bin/env bash\necho "rollback failed"\nexit 4\n' > "$d/.muster/hooks/bad/rollback.sh"
  printf '#!/usr/bin/env bash\necho "charlie deployed"\n' > "$d/.muster/hooks/ok2/deploy.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.muster/hooks/ok2/health.sh"
  chmod +x "$d"/.muster/hooks/*/*.sh
}

# Run muster non-interactively in a project. Sets OUT and RC.
# Args: dir args...
_run() {
  local d="$1"; shift
  RC=0
  OUT=$(cd "$d" && "$MUSTER_BIN" "$@" </dev/null 2>&1) || RC=$?
}

# Approve all hooks for a project on this machine (what setup does)
_approve() {
  (
    cd "$1"
    MUSTER_ROOT="$MUSTER_ROOT"
    source "$MUSTER_ROOT/lib/core/colors.sh"
    source "$MUSTER_ROOT/lib/core/logger.sh"
    source "$MUSTER_ROOT/lib/core/utils.sh"
    source "$MUSTER_ROOT/lib/core/hook_security.sh"
    _hook_manifest_generate "$1"
  )
}

_trust_dir_for() {
  local abs
  abs=$(cd "$1" && pwd -P)
  printf '%s/.muster/trust/%s\n' "$HOME" "$(printf '%s' "$abs" | shasum -a 256 | cut -c1-64)"
}

# ────────────────────────────────────────
echo "  Trust store — location"
# ────────────────────────────────────────

P1="$TEST_TMP/p1"
_mk_project "$P1"
_approve "$P1"
T1=$(_trust_dir_for "$P1")
_test_file_exists "manifest lives in ~/.muster/trust/<sha256-of-path>/" "$T1/hooks.manifest"
_test_file_exists "signature lives in the trust store" "$T1/hooks.manifest.sig"
_test_file_exists "approved copy saved for diffs" "$T1/approved/ok1/deploy.sh"
_test "no manifest written into the project" test ! -f "$P1/.muster/hooks.manifest"
_test "no signature written into the project" test ! -f "$P1/.muster/hooks.manifest.sig"

# ────────────────────────────────────────
echo ""
echo "  Exit codes — deploy"
# ────────────────────────────────────────

_run "$P1" deploy ok1
_test_eq "successful deploy exits 0" "0" "$RC"
_test_contains "summary final line" "1 deployed in" "$OUT"
_test_not_contains "no 'Deploy complete'" "Deploy complete" "$OUT"

_run "$P1" deploy
_test_eq "deploy with a failing service exits 1" "1" "$RC"
_test_contains "summary counts failure" "1 deployed, 1 failed, 1 skipped" "$OUT"
_test_contains "summary points at the failed log" "see .muster/logs/bad-deploy-" "$OUT"
_test_contains "summary table lists failed service" "Bravo" "$OUT"
_test_not_contains "no 'Deploy complete' after failure" "Deploy complete" "$OUT"

_run "$P1" deploy bad
_test_eq "deploying only the failing service exits 1" "1" "$RC"

_run "$P1" deploy nosuch
_test_eq "deploying a service with no hook exits 1" "1" "$RC"

# ────────────────────────────────────────
echo ""
echo "  Exit codes — rollback"
# ────────────────────────────────────────

_run "$P1" rollback ok1
_test_eq "successful rollback exits 0" "0" "$RC"

_run "$P1" rollback bad
_test_eq "failed rollback exits 1 (no menu, no retry loop)" "1" "$RC"

_run "$P1" rollback
_test_eq "rollback without a service and no TTY exits 1" "1" "$RC"

# ────────────────────────────────────────
echo ""
echo "  Edited hook — non-interactive"
# ────────────────────────────────────────

echo 'echo "extra step"' >> "$P1/.muster/hooks/ok1/deploy.sh"
_run "$P1" deploy ok1
_test_eq "edited hook blocks deploy with exit 1" "1" "$RC"
_test_contains "names the changed hook" "ok1/deploy.sh changed since it was approved on this machine. Review it, then run: muster hooks approve" "$OUT"
_test_not_contains "hook did not run" "Alpha deployed" "$OUT"

_run "$P1" rollback ok1
_test_eq "rollback is gated too (rollback.sh unchanged, deploy.sh changed)" "1" "$RC"

_run "$P1" deploy --yes ok1
_test_eq "--yes approves and deploys" "0" "$RC"
_test_contains "--yes prints a warning" "Approving 1 unreviewed hook file(s)" "$OUT"
_test_contains "--yes deploy ran" "Alpha deployed" "$OUT"

echo 'echo "another step"' >> "$P1/.muster/hooks/ok1/deploy.sh"
RC=0
OUT=$(cd "$P1" && MUSTER_APPROVE_HOOKS=1 "$MUSTER_BIN" deploy ok1 </dev/null 2>&1) || RC=$?
_test_eq "MUSTER_APPROVE_HOOKS=1 approves and deploys" "0" "$RC"

echo 'echo "ok2 change"' >> "$P1/.muster/hooks/ok2/deploy.sh"
_run "$P1" deploy --yes ok1
_run "$P1" deploy ok2
_test_eq "--yes only approved the services being deployed" "1" "$RC"

# ────────────────────────────────────────
echo ""
echo "  Fresh clone — no approval on this machine"
# ────────────────────────────────────────

P2="$TEST_TMP/p2"
_mk_project "$P2"
_run "$P2" deploy ok1
_test_eq "unapproved project exits 1 non-interactively" "1" "$RC"
_test_contains "explains approval is per machine" "haven't been approved on this machine" "$OUT"
_test_contains "lists hooks to review" "ok2/health.sh" "$OUT"
_test_contains "tells how to approve" "muster hooks approve" "$OUT"

# ────────────────────────────────────────
echo ""
echo "  Legacy in-repo manifest — migration"
# ────────────────────────────────────────

P3="$TEST_TMP/p3"
_mk_project "$P3"
_approve "$P3"
T3=$(_trust_dir_for "$P3")
# Simulate an older muster: manifest + sig inside the project, none in the store
mv "$T3/hooks.manifest" "$P3/.muster/hooks.manifest"
mv "$T3/hooks.manifest.sig" "$P3/.muster/hooks.manifest.sig"
rm -rf "$T3"
_run "$P3" deploy ok1
_test_eq "own legacy manifest is imported (deploy proceeds)" "0" "$RC"
_test_file_exists "imported into the trust store" "$T3/hooks.manifest"
_test "legacy manifest removed from the project" test ! -f "$P3/.muster/hooks.manifest"
_test "legacy signature removed from the project" test ! -f "$P3/.muster/hooks.manifest.sig"
_test "legacy files are gitignored" grep -qx "hooks.manifest" "$P3/.muster/.gitignore"

# A teammate's committed manifest (signed with another key) is ignored
P4="$TEST_TMP/p4"
_mk_project "$P4"
printf '{"ok1/deploy.sh":{"sha256":"x"}}\n' > "$P4/.muster/hooks.manifest"
printf 'deadbeef\n' > "$P4/.muster/hooks.manifest.sig"
_run "$P4" deploy ok1
_test_eq "foreign manifest grants nothing (exit 1)" "1" "$RC"
_test_contains "foreign manifest → treated as unapproved" "haven't been approved on this machine" "$OUT"
_test_file_exists "foreign manifest left alone" "$P4/.muster/hooks.manifest"

# ────────────────────────────────────────
echo ""
echo "  Writable hooks + opt-in lock"
# ────────────────────────────────────────

(
  source "$MUSTER_ROOT/lib/core/templates.sh" 2>/dev/null || true
  _is_infra_service() { return 1; }
  mkdir -p "$TEST_TMP/gen"
  _setup_copy_hooks bare api api "$TEST_TMP/gen"
) >/dev/null 2>&1
_test "generated hooks are owner-writable" test -w "$TEST_TMP/gen/deploy.sh"
_test "generated hooks are executable" test -x "$TEST_TMP/gen/deploy.sh"
(
  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  _hook_lock "$TEST_TMP/gen" || true
)
_test "muster hooks lock still makes hooks read-only" test ! -w "$TEST_TMP/gen/deploy.sh"
(
  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  _hook_unlock "$TEST_TMP/gen" || true
)
_test "unlock makes them writable again" test -w "$TEST_TMP/gen/deploy.sh"

# ────────────────────────────────────────
echo ""
echo "  --json summary event"
# ────────────────────────────────────────

MUSTER_TOKEN=$(
  MUSTER_ROOT="$MUSTER_ROOT"
  source "$MUSTER_ROOT/lib/core/colors.sh"
  source "$MUSTER_ROOT/lib/core/logger.sh"
  source "$MUSTER_ROOT/lib/core/utils.sh"
  source "$MUSTER_ROOT/lib/core/auth.sh"
  _auth_create_token_internal "test-ci" "admin" 2>/dev/null
)
export MUSTER_TOKEN

P5="$TEST_TMP/p5"
_mk_project "$P5"
_approve "$P5"
RC=0
OUT=$(cd "$P5" && "$MUSTER_BIN" deploy --json </dev/null 2>/dev/null) || RC=$?
_test_eq "deploy --json with a failure exits 1" "1" "$RC"
_last=$(printf '%s\n' "$OUT" | tail -1)
_test_contains "last line is the summary event" '"event":"summary"' "$_last"
_test_contains "summary counts" '"deployed":2,"failed":1' "$_last"
_test_contains "summary exit code" '"exit_code":1' "$_last"
_json_three() { jq -e '.services | length == 3' <<< "$1" >/dev/null; }
_test "summary is valid JSON" _json_three "$_last"
_bad_lines=$(printf '%s\n' "$OUT" | while IFS= read -r l; do jq -e . >/dev/null 2>&1 <<< "$l" || echo bad; done)
_test_eq "every stdout line is JSON" "" "$_bad_lines"

RC=0
OUT=$(cd "$P5" && "$MUSTER_BIN" deploy --json ok1 </dev/null 2>/dev/null) || RC=$?
_test_eq "deploy --json success exits 0" "0" "$RC"
_test_contains "success summary" '"deployed":1,"failed":0' "$(printf '%s\n' "$OUT" | tail -1)"

echo 'echo changed' >> "$P5/.muster/hooks/ok1/deploy.sh"
RC=0
OUT=$(cd "$P5" && "$MUSTER_BIN" deploy --json ok1 </dev/null 2>/dev/null) || RC=$?
_test_eq "deploy --json with edited hook exits 1" "1" "$RC"
_test_contains "error event for unapproved hooks" '"reason":"hooks_not_approved"' "$OUT"
unset MUSTER_TOKEN

# ────────────────────────────────────────
echo ""
echo "  No ANSI when piped"
# ────────────────────────────────────────

OUT=$(cd "$P5" && "$MUSTER_BIN" deploy --dry-run </dev/null 2>&1 | cat) || true
_test_not_contains "dry-run piped: no escape sequences" "$ESC" "$OUT"
_test_contains "dry-run piped: plain progress lines" "[1/3] Alpha" "$OUT"
_test_not_contains "dry-run piped: no carriage returns" $'\r' "$OUT"

OUT=$(cd "$P1" && "$MUSTER_BIN" deploy --yes </dev/null 2>&1 | cat) || true
_test_not_contains "deploy piped: no escape sequences" "$ESC" "$OUT"

_nc_out=$(
  MUSTER_ROOT="$MUSTER_ROOT"
  NO_COLOR=1
  source "$MUSTER_ROOT/lib/core/colors.sh"
  printf '%s|%s|%s' "$RED" "$BOLD" "$MUSTER_ANSI"
)
_test_eq "NO_COLOR disables colors + ANSI" "||false" "$_nc_out"

_pb_out=$(
  MUSTER_ANSI=false MUSTER_MINIMAL=false
  source "$MUSTER_ROOT/lib/tui/progress.sh"
  progress_bar 1 3 "redis"
)
_test_eq "progress_bar without ANSI prints a plain line" "  [1/3] redis" "$_pb_out"

# ────────────────────────────────────────
echo ""
echo "  --minimal status — disabled health"
# ────────────────────────────────────────

mkdir -p "$HOME/.muster/health_cache"
printf 'unhealthy' > "$HOME/.muster/health_cache/ok1"   # stale entry from another project
_min_out=$(
  cd "$P5"
  export MUSTER_ROOT MUSTER_MINIMAL=true MUSTER_QUIET=false MUSTER_VERBOSE=false
  source "$MUSTER_ROOT/lib/core/colors.sh"
  source "$MUSTER_ROOT/lib/core/logger.sh"
  source "$MUSTER_ROOT/lib/core/utils.sh"
  source "$MUSTER_ROOT/lib/core/config.sh"
  source "$MUSTER_ROOT/lib/tui/dashboard.sh"
  load_config >/dev/null 2>&1
  _dashboard_minimal_status 2>/dev/null
)
_test_contains "disabled service reported as disabled" "Alpha: disabled" "$_min_out"
_test_contains "healthy service reported" "Charlie: healthy" "$_min_out"
_test_contains "summary counts disabled" "(1 healthy, 0 unhealthy, 2 disabled)" "$_min_out"

_test_summary
