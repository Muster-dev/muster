#!/usr/bin/env bash
# tests/test_build_context.sh — Tests for build context overlap detection
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE="" GRAY=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/build_context.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Override cache location to temp
_BUILD_CONTEXT_CACHE="${TMPDIR}/.build_context_cache"

# ────────────────────────────────────────
echo "  Build context — extract from hook"
# ────────────────────────────────────────

# Hook with docker build and context path
_hook="${TMPDIR}/deploy_with_ctx.sh"
cat > "$_hook" << 'SCRIPT'
#!/usr/bin/env bash
docker build -t myapp:latest -f Dockerfile.api .
SCRIPT

_ctx=$(_build_context_from_hook "$_hook")
_test_eq "extracts context path (.)" "." "$_ctx"

# Hook with explicit context directory
_hook2="${TMPDIR}/deploy_subdir.sh"
cat > "$_hook2" << 'SCRIPT'
#!/usr/bin/env bash
docker build -t myapp:latest -f services/api/Dockerfile services/api
SCRIPT

_ctx2=$(_build_context_from_hook "$_hook2")
_test_eq "extracts explicit context dir" "services/api" "$_ctx2"

# Hook without docker build
_hook3="${TMPDIR}/deploy_no_docker.sh"
cat > "$_hook3" << 'SCRIPT'
#!/usr/bin/env bash
kubectl apply -f k8s/
SCRIPT

_ctx3=$(_build_context_from_hook "$_hook3")
_test_eq "no docker build returns empty" "" "$_ctx3"

# ────────────────────────────────────────
echo ""
echo "  Build context — dockerignore matching"
# ────────────────────────────────────────

_proj="${TMPDIR}/project"
mkdir -p "$_proj"

# Create .dockerignore
cat > "${_proj}/.dockerignore" << 'EOF'
node_modules
.git
dashboard
services/worker
EOF

_build_context_in_dockerignore "$_proj" "dashboard"
_test_eq "matches exact directory" "0" "$?"

_build_context_in_dockerignore "$_proj" "node_modules"
_test_eq "matches node_modules" "0" "$?"

_rc=0
_build_context_in_dockerignore "$_proj" "api" || _rc=$?
_test "non-matching dir returns 1" test "$_rc" -ne 0

# ────────────────────────────────────────
echo ""
echo "  Build context — cache read/write"
# ────────────────────────────────────────

# Write test cache
cat > "$_BUILD_CONTEXT_CACHE" << 'EOF'
api|dashboard|.|dashboard
api|worker|.|services/worker
EOF

_build_context_read_cache
_test_eq "reads 2 issues from cache" "2" "${#_BUILD_CONTEXT_ISSUES[@]}"
_test_contains "first issue has api" "api" "${_BUILD_CONTEXT_ISSUES[0]}"
_test_contains "second issue has worker" "worker" "${_BUILD_CONTEXT_ISSUES[1]}"

# ────────────────────────────────────────
echo ""
echo "  Build context — empty cache"
# ────────────────────────────────────────

rm -f "$_BUILD_CONTEXT_CACHE"
_rc=0
_build_context_read_cache || _rc=$?
_test "empty cache returns 1" test "$_rc" -ne 0
_test_eq "no issues in empty cache" "0" "${#_BUILD_CONTEXT_ISSUES[@]}"

# ────────────────────────────────────────
echo ""
echo "  Build context — cache staleness"
# ────────────────────────────────────────

_proj2="${TMPDIR}/project2"
mkdir -p "$_proj2"
CONFIG_FILE="${_proj2}/deploy.json"
echo '{}' > "$CONFIG_FILE"

# No cache file = stale
_build_context_cache_stale
_test_eq "missing cache is stale" "0" "$?"

# Create cache, then modify config
echo "" > "$_BUILD_CONTEXT_CACHE"
sleep 1
touch "$CONFIG_FILE"
_build_context_cache_stale
_test_eq "config newer than cache is stale" "0" "$?"

# ────────────────────────────────────────
echo ""
echo "  Build context — warn formatting"
# ────────────────────────────────────────

# Write cache with known issues
cat > "$_BUILD_CONTEXT_CACHE" << 'EOF'
api|dashboard|.|dashboard
EOF

_output=$(_build_context_warn 2>&1)
_test_contains "warn mentions overlap" "overlap" "$_output"

_output=$(_build_context_warn_minimal 2>&1)
_test_contains "minimal warn mentions overlap" "overlap" "$_output"

_test_summary
