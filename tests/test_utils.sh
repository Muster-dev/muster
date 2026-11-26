#!/usr/bin/env bash
# tests/test_utils.sh — Tests for lock file JSON escaping, revoke-key quoting, and utils
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE="" GRAY=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

TMPDIR=$(mktemp -d)
export HOME="${TMPDIR}/home"
mkdir -p "$HOME/.muster"
trap 'rm -rf "$TMPDIR"' EXIT

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"

_is_valid_json() { jq -e . "$1" >/dev/null 2>&1; }

# ────────────────────────────────────────
echo "  Lock files — JSON escaping with jq"
# ────────────────────────────────────────

PROJ="${TMPDIR}/proj1"
mkdir -p "$PROJ"

# Set a deploy_name containing double quotes and backslashes in settings.json
if command -v jq >/dev/null 2>&1; then
  jq -n --arg dn 'Alice "The\Admin" O'\''Brien' '{deploy_name: $dn}' > "$HOME/.muster/settings.json"

  _deploy_lock_acquire "$PROJ" "api" "my\"svc"
  _dlock="${PROJ}/.muster/deploy.lock"
  _test_file_exists "deploy.lock created (jq)" "$_dlock"
  _test "deploy.lock is valid JSON (jq)" _is_valid_json "$_dlock"
  _test_eq "deploy.lock preserves quoted deploy_name (jq)" 'Alice "The\Admin" O'\''Brien' "$(jq -r '.user' "$_dlock")"
  _test_eq "deploy.lock preserves quoted service name (jq)" 'my"svc' "$(jq -r '.services[1]' "$_dlock")"
  _deploy_lock_release "$PROJ"

  _service_lock_acquire "$PROJ" "api"
  _slock="${PROJ}/.muster/locks/api.lock"
  _test_file_exists "service lock created (jq)" "$_slock"
  _test "service lock is valid JSON (jq)" _is_valid_json "$_slock"
  _test_eq "service lock preserves quoted deploy_name (jq)" 'Alice "The\Admin" O'\''Brien' "$(jq -r '.user' "$_slock")"
  _service_lock_release "$PROJ" "api"
fi

# ────────────────────────────────────────
echo ""
echo "  Lock files — JSON escaping fallback (without jq)"
# ────────────────────────────────────────

PROJ2="${TMPDIR}/proj2"
mkdir -p "$PROJ2"

# Simulate missing jq by shadowing has_cmd in a subshell, while exporting MUSTER_DEPLOY_USER
(
  export MUSTER_DEPLOY_USER='Bob "Ops\Lead"'
  has_cmd() {
    [[ "$1" == "jq" ]] && return 1
    command -v "$1" &>/dev/null
  }
  _deploy_lock_acquire "$PROJ2" "api" 'svc"1'
  _service_lock_acquire "$PROJ2" "api"
)

_dlock2="${PROJ2}/.muster/deploy.lock"
_slock2="${PROJ2}/.muster/locks/api.lock"
_test_file_exists "deploy.lock created (no-jq fallback)" "$_dlock2"
_test_file_exists "service lock created (no-jq fallback)" "$_slock2"
if command -v jq >/dev/null 2>&1; then
  _test "deploy.lock fallback is valid JSON" _is_valid_json "$_dlock2"
  _test_eq "deploy.lock fallback preserves quotes & backslash" 'Bob "Ops\Lead"' "$(jq -r '.user' "$_dlock2")"
  _test_eq "deploy.lock fallback preserves service quotes" 'svc"1' "$(jq -r '.services[1]' "$_dlock2")"
  _test "service lock fallback is valid JSON" _is_valid_json "$_slock2"
  _test_eq "service lock fallback preserves quotes & backslash" 'Bob "Ops\Lead"' "$(jq -r '.user' "$_slock2")"
fi

# ────────────────────────────────────────
echo ""
echo "  fleet revoke-key — label with quotes/backslash/shell chars"
# ────────────────────────────────────────

if command -v jq >/dev/null 2>&1; then
  # Fake ssh that executes the remote command locally against an isolated remote HOME
  REMOTE_HOME="${TMPDIR}/remote_home"
  AUTH_DIR="${REMOTE_HOME}/.muster/fleet/authorized_keys"
  mkdir -p "$AUTH_DIR"
  _bad_label='bad"key\name'\''$(touch /tmp/nope)'
  jq -n --arg l1 "$_bad_label" --arg l2 "keep-me" \
    '{keys: [{label: $l1, pubkey: "p1", added: "now"}, {label: $l2, pubkey: "p2", added: "now"}]}' \
    > "${AUTH_DIR}/proj.json"

  FAKE_BIN="${TMPDIR}/fake_bin"
  mkdir -p "$FAKE_BIN"
  cat > "${FAKE_BIN}/ssh" << 'FAKE_SSH'
#!/usr/bin/env bash
# Last arg is the remote command; stdin is the script piped to ssh
cmd=""
for a in "$@"; do cmd="$a"; done
HOME="$FAKE_REMOTE_HOME" bash -c "$cmd"
FAKE_SSH
  chmod +x "${FAKE_BIN}/ssh"

  (
    export PATH="${FAKE_BIN}:$PATH"
    export FAKE_REMOTE_HOME="$REMOTE_HOME"
    source "$MUSTER_ROOT/lib/core/config.sh"
    source "$MUSTER_ROOT/lib/core/fleet.sh"
    source "$MUSTER_ROOT/lib/commands/fleet.sh"
    fleet_init >/dev/null 2>&1
    fleet_add_machine "box1" "127.0.0.1" "deploy" "22" "" "" "muster" "ssh" "manual" >/dev/null 2>&1
    fleet_load_config
    _fleet_cmd_revoke_key "box1" --label "$_bad_label" >/dev/null 2>&1
  )

  _test "authorized_keys JSON remains valid after revoke-key" _is_valid_json "${AUTH_DIR}/proj.json"
  _test_eq "target key with quotes/backslash/metachars removed" "1" "$(jq '.keys | length' "${AUTH_DIR}/proj.json")"
  _test_eq "other key preserved" "keep-me" "$(jq -r '.keys[0].label' "${AUTH_DIR}/proj.json")"
fi

# ────────────────────────────────────────
echo ""
echo "  .env file loading & unloading"
# ────────────────────────────────────────

_env_dir="${TMPDIR}/envtest"
mkdir -p "$_env_dir"
CONFIG_FILE="${_env_dir}/muster.json"
: > "$CONFIG_FILE"

printf 'MUSTER_TEST_FOO=bar\nMUSTER_TEST_BAZ=qux\n' > "${_env_dir}/.env"
_load_env_file "${_env_dir}/.env"
_test_eq "_load_env_file loads KEY=VALUE (FOO)" "bar" "${MUSTER_TEST_FOO:-}"
_test_eq "_load_env_file loads KEY=VALUE (BAZ)" "qux" "${MUSTER_TEST_BAZ:-}"
_unload_env_file
_test_eq "_unload_env_file clears loaded vars" "" "${MUSTER_TEST_FOO:-}"

printf '# comment\n\nMUSTER_TEST_FOO=bar\n  # indented comment\n' > "${_env_dir}/.env"
_load_env_file "${_env_dir}/.env"
_test_eq "_load_env_file skips comments and blank lines" "bar" "${MUSTER_TEST_FOO:-}"
_unload_env_file

printf 'MUSTER_TEST_DQ="hello world"\nMUSTER_TEST_SQ='\''single quotes'\''\n' > "${_env_dir}/.env"
_load_env_file "${_env_dir}/.env"
_test_eq "_load_env_file strips double quotes" "hello world" "${MUSTER_TEST_DQ:-}"
_test_eq "_load_env_file strips single quotes" "single quotes" "${MUSTER_TEST_SQ:-}"
_unload_env_file

export MUSTER_TEST_EXISTING="original"
printf 'MUSTER_TEST_EXISTING=overwritten\n' > "${_env_dir}/.env"
_load_env_file "${_env_dir}/.env"
_test_eq "_load_env_file does not override existing env vars" "original" "$MUSTER_TEST_EXISTING"
_unload_env_file
unset MUSTER_TEST_EXISTING

_test_summary
