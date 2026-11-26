#!/usr/bin/env bash
# tests/test_deploy_multi.sh — deploy several named services, flags in any position
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MUSTER_NO_VERIFY=true NO_COLOR=1 MUSTER_APPROVE_HOOKS=1
mkdir -p "$HOME" "$TMP/p"
cd "$TMP/p"
M="$MUSTER_ROOT/bin/muster"
"$M" setup --services api,web,worker --stack bare --health api=none --health web=none --health worker=none --name multi --force >/dev/null 2>&1
for s in api web worker; do
  mkdir -p ".muster/hooks/$s"
  printf '#!/usr/bin/env bash\necho "%s deployed"\n' "$s" > ".muster/hooks/$s/deploy.sh"
  chmod +x ".muster/hooks/$s/deploy.sh"
done
T=$("$M" auth create t --scope admin 2>/dev/null | awk '/Token:/{print $2}')

echo "  Multiple services"
out=$(MUSTER_TOKEN="$T" "$M" deploy --json web worker 2>/dev/null | jq -c 'select(.event=="summary")')
_test_eq "deploys both named services" "2" "$(printf '%s' "$out" | jq '.deployed')"
_test_eq "in the order given" "web,worker" "$(printf '%s' "$out" | jq -r '[.services[].service] | join(",")')"

echo "  Flags after service names"
out=$("$M" deploy worker api --dry-run 2>&1)
_test_contains "dry-run honoured after names" "[DRY-RUN] Deploying worker (1/2)" "$out"
_test_contains "second service planned" "[DRY-RUN] Deploying api (2/2)" "$out"

echo "  Unknown service"
out=$("$M" deploy nope 2>&1) && rc=0 || rc=$?
_test_eq "unknown service exits 1" "1" "$rc"
_test_contains "names the bad service" "Unknown service: nope" "$out"
_test "fails before starting a deploy" bash -c '[[ "$1" != *"Deploying multi"* ]]' _ "$out"

echo ""
printf '  %d/%d tests passed\n' "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]]
