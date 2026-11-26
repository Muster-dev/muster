#!/usr/bin/env bash
# tests/test_setup_smart.sh — setup re-run (update/merge, edited hooks kept),
# atomic writes on interrupt, key sanitizing, empty projects, did-you-mean.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUSTER_BIN="$MUSTER_ROOT/bin/muster"

source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/mock_helpers.sh"

TEST_TMP=$(mktemp -d)
export HOME="$TEST_TMP/home"
mkdir -p "$HOME/.muster"
printf '{"machine_role":"local"}\n' > "$HOME/.muster/settings.json"
export MUSTER_NO_VERIFY=true
unset NO_COLOR
_mock_init
# compose v2 available, daemon up
_mock_cmd docker 'exit 0'
trap 'rm -rf "${TEST_TMP:?}"; _mock_cleanup' EXIT

_mk_compose() {
  local d="$1"
  mkdir -p "$d"
  cat > "$d/docker-compose.yml" <<'YAML'
services:
  api:
    build: .
    ports:
      - "3000:3000"
  redis:
    image: redis:7
YAML
  echo 'FROM node:20' > "$d/Dockerfile"
}

_run() {
  local d="$1"; shift
  RC=0
  OUT=$(cd "$d" && "$MUSTER_BIN" "$@" </dev/null 2>&1) || RC=$?
}

# ────────────────────────────────────────
echo "  Setup re-run — update keeps edits"
# ────────────────────────────────────────

P="$TEST_TMP/shop"
_mk_compose "$P"
_run "$P" setup --scan
_test_eq "first setup succeeds" "0" "$RC"
_test_file_exists "muster.json written" "$P/muster.json"
_test_file_exists "generated-hook checksums recorded" "$P/.muster/.template_hashes"

# The user customizes things
echo 'echo "my custom step"' >> "$P/.muster/hooks/api/deploy.sh"
jq '.services.api.deploy_timeout = 300' "$P/muster.json" > "$P/m.tmp" && mv "$P/m.tmp" "$P/muster.json"
_redis_before=$(cksum < "$P/.muster/hooks/redis/deploy.sh")

# ...and adds a service
cat >> "$P/docker-compose.yml" <<'YAML'
  worker:
    build: .
YAML

_run "$P" setup --scan
_test_eq "re-run without --update/--force refuses" "1" "$RC"
_test_contains "refusal explains --update and --force" "--update" "$OUT"

_run "$P" setup --scan --update
_test_eq "setup --update succeeds" "0" "$RC"
_test_contains "edited hook kept" "my custom step" "$(cat "$P/.muster/hooks/api/deploy.sh")"
_test_contains "tells the user which hooks were kept" "Kept your edited hooks: api/deploy.sh" "$OUT"
_test_file_exists "new service gets hooks" "$P/.muster/hooks/worker/deploy.sh"
_test_eq "new service added to muster.json" "true" "$(jq '.services | has("worker")' "$P/muster.json")"
_test_eq "custom muster.json value preserved" "300" "$(jq -r '.services.api.deploy_timeout' "$P/muster.json")"
_test_contains "new service in deploy_order" "worker" "$(jq -r '.deploy_order | join(",")' "$P/muster.json")"
_test_contains "reports the new service" "Added new service: worker" "$OUT"
_test_eq "unedited hooks are refreshed in place" "$_redis_before" "$(cksum < "$P/.muster/hooks/redis/deploy.sh")"
_test "no staging dirs left behind" bash -c "! ls -d '$P'/.muster-setup.* >/dev/null 2>&1"

# Start over: regenerates, but backs the edited hook up first
_run "$P" setup --scan --force
_test_eq "setup --force succeeds" "0" "$RC"
_test_not_contains "--force regenerates the edited hook" "my custom step" "$(cat "$P/.muster/hooks/api/deploy.sh")"
_bk=$(ls -d "$P"/.muster/backup-* 2>/dev/null | head -1)
_test_file_exists "--force backs up the edited hook" "${_bk}/api/deploy.sh"
_test_contains "backup has the user's edit" "my custom step" "$(cat "${_bk}/api/deploy.sh" 2>/dev/null)"
_test_contains "tells the user about the backup" "Backed up your edited hooks" "$OUT"

# ────────────────────────────────────────
echo ""
echo "  Setup — Ctrl+C leaves no partial files"
# ────────────────────────────────────────

A="$TEST_TMP/atomic"
_mk_compose "$A"
RC=0
OUT=$(cd "$A" && MUSTER_TEST_SETUP_INTERRUPT=after-hooks "$MUSTER_BIN" setup --scan </dev/null 2>&1) || RC=$?
_test_eq "interrupted setup exits 130" "130" "$RC"
_test_contains "says nothing was written" "nothing was written" "$OUT"
_test "no muster.json after interrupt" test ! -f "$A/muster.json"
_test "no hooks after interrupt" test ! -d "$A/.muster/hooks"
_test "no staging dir after interrupt" bash -c "! ls -d '$A'/.muster-setup.* >/dev/null 2>&1"

# Interrupt during an update: existing files untouched
_run "$A" setup --scan
echo 'echo "keep me"' >> "$A/.muster/hooks/api/deploy.sh"
_cfg_before=$(cksum < "$A/muster.json")
_hook_before=$(cksum < "$A/.muster/hooks/api/deploy.sh")
printf '  worker:\n    build: .\n' >> "$A/docker-compose.yml"
RC=0
OUT=$(cd "$A" && MUSTER_TEST_SETUP_INTERRUPT=before-commit "$MUSTER_BIN" setup --scan --force </dev/null 2>&1) || RC=$?
_test_eq "interrupted update exits 130" "130" "$RC"
_test_eq "muster.json unchanged after interrupt" "$_cfg_before" "$(cksum < "$A/muster.json")"
_test_eq "hooks unchanged after interrupt" "$_hook_before" "$(cksum < "$A/.muster/hooks/api/deploy.sh")"
_test "new service not half-written" test ! -d "$A/.muster/hooks/worker"

# ────────────────────────────────────────
echo ""
echo "  Setup — names, empty projects, typos"
# ────────────────────────────────────────

N="$TEST_TMP/names"
mkdir -p "$N"
_run "$N" setup --stack bare --services "My API,my-api"
_test_eq "colliding names still set up" "0" "$RC"
_test_contains "sanitized key notice" "saved as 'my_api'" "$OUT"
_test_contains "collision notice" "renamed" "$OUT"
_test_eq "both services exist" "my_api,my_api_2" "$(jq -r '.services | keys | join(",")' "$N/muster.json")"

E="$TEST_TMP/empty"
mkdir -p "$E"
_run "$E" setup --scan
_test_eq "empty project --scan exits 1" "1" "$RC"
_test_contains "empty project is explained" "Nothing to deploy was detected" "$OUT"
_test_contains "empty project offers templates" "muster setup --stack bare --services app" "$OUT"

_run "$E" setup --updat
_test_contains "setup flag typo suggests the flag" "Did you mean: --update?" "$OUT"

# Compose v1 only: hooks adapted
V="$TEST_TMP/v1"
_mk_compose "$V"
_mock_cmd docker 'if [[ "$1" == "compose" ]]; then echo "docker: unknown command: docker compose" >&2; exit 1; fi; exit 0'
_mock_cmd docker-compose 'exit 0'
_run "$V" setup --scan
_test_contains "v1-only: notice shown" "docker-compose (v1)" "$OUT"
_test_not_contains "v1-only: hooks use docker-compose" "docker compose " "$(cat "$V/.muster/hooks/api/deploy.sh")"
_mock_cmd docker 'exit 0'
rm -f "${MOCK_BIN:?}/docker-compose"

# ────────────────────────────────────────
echo ""
echo "  Setup — interactive re-run menu (TTY)"
# ────────────────────────────────────────

if command -v python3 >/dev/null 2>&1; then
  _out=$(python3 "$SCRIPT_DIR/pty_drive.py" "$P" 20 "What do you want to do?=>" "Choose [1-3]:=>3\n" -- "$MUSTER_BIN" --minimal setup 2>&1) || true
  _test_contains "offers Update (keep my changes)" "Update (keep my changes)" "$_out"
  _test_contains "offers Start over" "Start over" "$_out"
  _test_contains "Cancel changes nothing" "nothing changed" "$_out"
fi

_test_summary
