#!/usr/bin/env bash
# tests/test_health_wait.sh — _engine_health_wait retries while a service starts
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
P="$TMP/p"
mkdir -p "$P/.muster/hooks/web"
cat > "$P/muster.json" <<'EOF'
{"project":"t","services":{"web":{"name":"web","health":{"type":"command","enabled":true}}},"deploy_order":["web"]}
EOF
# Unhealthy for the first two checks, healthy after that.
cat > "$P/.muster/hooks/web/health.sh" <<EOF
#!/usr/bin/env bash
n=\$(cat "$TMP/count" 2>/dev/null || echo 0)
echo \$((n + 1)) > "$TMP/count"
(( n >= 2 ))
EOF
chmod +x "$P/.muster/hooks/web/health.sh"

source "$MUSTER_ROOT/lib/core/colors.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"
source "$MUSTER_ROOT/lib/core/remote.sh"
source "$MUSTER_ROOT/lib/core/engine.sh"
CONFIG_FILE="$P/muster.json"
_just_available() { return 1; }

echo "  Health wait"

rc=0
MUSTER_HEALTH_WAIT=10 _engine_health_wait web "$P" || rc=$?
_test_eq "healthy once the service finishes starting" "0" "$rc"
_test_eq "checked three times" "3" "$(cat "$TMP/count")"

echo 0 > "$TMP/count"
rc=0
MUSTER_HEALTH_WAIT=0 _engine_health_wait web "$P" || rc=$?
_test_eq "MUSTER_HEALTH_WAIT=0 checks once and gives up" "1" "$rc"

sed -i.bak 's/"enabled":true/"enabled":false/' "$P/muster.json"
rc=0
_engine_health_wait web "$P" || rc=$?
_test_eq "disabled health check returns 2 without waiting" "2" "$rc"

_test_summary
