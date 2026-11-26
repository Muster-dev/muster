#!/usr/bin/env bash
# tests/test_setup.sh — Tests for muster setup / muster init
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

TMPDIR=$(mktemp -d)
export HOME="${TMPDIR}/home"
mkdir -p "$HOME"
trap 'rm -rf "$TMPDIR"' EXIT

# ────────────────────────────────────────
echo "  Setup --scan — 3-service Docker Compose project"
# ────────────────────────────────────────

PROJ="${TMPDIR}/sample-app"
mkdir -p "${PROJ}/api" "${PROJ}/web"
cat > "${PROJ}/docker-compose.yml" << 'EOF'
services:
  api: { build: ./api, ports: ["8080:8080"] }
  web: { build: ./web, ports: ["3000:3000"] }
  redis: { image: "redis:7", ports: ["6379:6379"] }
EOF
printf 'FROM node:20\nEXPOSE 8080\n' > "${PROJ}/api/Dockerfile"
printf 'FROM node:20\nEXPOSE 3000\n' > "${PROJ}/web/Dockerfile"
printf '{"name":"web","dependencies":{"express":"^4.18.0"}}\n' > "${PROJ}/web/package.json"

_out=$(cd "$PROJ" && "$MUSTER_ROOT/bin/muster" --no-verify setup --scan 2>&1)

_test_file_exists "creates muster.json" "${PROJ}/muster.json"
_test_not_contains "no jq error in output" "jq: error" "$_out"
_test_not_contains "no empty filename error in output" "Could not open file" "$_out"
_test_not_contains "no ANSI escape codes when stdout is not a TTY" $'\033[' "$_out"

# Check actionable completion summary
_test_contains "summary lists redis tcp :6379" "tcp :6379" "$_out"
_test_contains "summary lists api tcp :8080" "tcp :8080" "$_out"
_test_contains "summary lists web tcp :3000" "tcp :3000" "$_out"
_test_contains "summary prints muster deploy --dry-run" "muster deploy --dry-run" "$_out"
_test_contains "summary prints muster deploy" "muster deploy" "$_out"
_test_contains "summary prints dashboard command" "Open the dashboard" "$_out"

# Verify generated muster.json structure
_has_root=$(jq 'has("root")' "${PROJ}/muster.json")
_test_eq "generated muster.json has no root key" "false" "$_has_root"

# Service names default to keys (not friendly names like "API Server")
_test_eq "api name defaults to key" "api" "$(jq -r '.services.api.name' "${PROJ}/muster.json")"
_test_eq "web name defaults to key" "web" "$(jq -r '.services.web.name' "${PROJ}/muster.json")"
_test_eq "redis name defaults to key" "redis" "$(jq -r '.services.redis.name' "${PROJ}/muster.json")"

# Inferred TCP health checks (timeout 10, enabled true)
_test_eq "api health type is tcp" "tcp" "$(jq -r '.services.api.health.type' "${PROJ}/muster.json")"
_test_eq "api health port is 8080" "8080" "$(jq -r '.services.api.health.port' "${PROJ}/muster.json")"
_test_eq "api health timeout is 10" "10" "$(jq -r '.services.api.health.timeout' "${PROJ}/muster.json")"
_test_eq "api health enabled is true" "true" "$(jq -r '.services.api.health.enabled' "${PROJ}/muster.json")"

_test_eq "web health type is tcp" "tcp" "$(jq -r '.services.web.health.type' "${PROJ}/muster.json")"
_test_eq "web health port is 3000" "3000" "$(jq -r '.services.web.health.port' "${PROJ}/muster.json")"
_test_eq "web health enabled is true" "true" "$(jq -r '.services.web.health.enabled' "${PROJ}/muster.json")"

_test_eq "redis health type is tcp" "tcp" "$(jq -r '.services.redis.health.type' "${PROJ}/muster.json")"
_test_eq "redis health port is 6379" "6379" "$(jq -r '.services.redis.health.port' "${PROJ}/muster.json")"
_test_eq "redis health enabled is true" "true" "$(jq -r '.services.redis.health.enabled' "${PROJ}/muster.json")"

# Deploy order: infra first
_test_eq "deploy_order puts infra first" "redis,api,web" "$(jq -r '.deploy_order | join(",")' "${PROJ}/muster.json")"

# ────────────────────────────────────────
echo ""
echo "  Setup --scan — infra defaults, HTTP healthcheck, unknown port"
# ────────────────────────────────────────

PROJ2="${TMPDIR}/mixed-app"
mkdir -p "${PROJ2}/worker"
cat > "${PROJ2}/docker-compose.yml" << 'EOF'
services:
  api:
    image: my-api:latest
    ports:
      - "8080:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
  postgres:
    image: postgres:16
  worker:
    build: ./worker
EOF
printf 'FROM alpine\n' > "${PROJ2}/worker/Dockerfile"

_out2=$(cd "$PROJ2" && "$MUSTER_ROOT/bin/muster" --no-verify setup --scan 2>&1)
_test_not_contains "mixed-app has no jq error" "jq: error" "$_out2"
_test_eq "mixed-app has no root key" "false" "$(jq 'has("root")' "${PROJ2}/muster.json")"
_test_eq "api uses http from compose healthcheck" "http" "$(jq -r '.services.api.health.type' "${PROJ2}/muster.json")"
_test_eq "api health endpoint is /health" "/health" "$(jq -r '.services.api.health.endpoint' "${PROJ2}/muster.json")"
_test_eq "postgres infers default port 5432" "5432" "$(jq -r '.services.postgres.health.port' "${PROJ2}/muster.json")"
_test_eq "postgres health type is tcp" "tcp" "$(jq -r '.services.postgres.health.type' "${PROJ2}/muster.json")"
_test_eq "worker with no port leaves health disabled" "false" "$(jq -r '.services.worker.health.enabled' "${PROJ2}/muster.json")"

# ────────────────────────────────────────
echo ""
echo "  Alias — muster init"
# ────────────────────────────────────────

PROJ3="${TMPDIR}/init-app"
mkdir -p "$PROJ3"
cat > "${PROJ3}/docker-compose.yml" << 'EOF'
services:
  redis:
    image: redis:7
EOF

_init_out=$(cd "$PROJ3" && "$MUSTER_ROOT/bin/muster" --no-verify init --scan 2>&1)
_test_file_exists "muster init --scan creates muster.json" "${PROJ3}/muster.json"
_test_not_contains "muster init --scan has no jq error" "jq: error" "$_init_out"
_test_eq "muster init infers redis port 6379" "6379" "$(jq -r '.services.redis.health.port' "${PROJ3}/muster.json")"

_help_out=$("$MUSTER_ROOT/bin/muster" --no-verify help 2>&1)
_test_contains "muster help documents init alias" "init" "$_help_out"

# ────────────────────────────────────────
echo ""
echo "  Setup — quick-path summary formatting"
# ────────────────────────────────────────

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE="" GRAY=""
MUSTER_QUIET="false"
MUSTER_VERBOSE="false"
MUSTER_MINIMAL="true"
export MUSTER_ROOT
source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/core/config.sh"
source "$MUSTER_ROOT/lib/core/registry.sh"
source "$MUSTER_ROOT/lib/commands/setup.sh"

scan_project "$PROJ" 2>/dev/null
_setup_sort_services "${_SCAN_SERVICES[@]}"
_setup_build_summary_lines "$_SCAN_STACK" "${_SETUP_SORTED_SERVICES[@]}"
_summary_str=$(printf '%s\n' "${_SETUP_SUMMARY_LINES[@]}")

_test_contains "summary header shows count and stack" "Found 3 services (Docker Compose)" "$_summary_str"
_test_contains "summary shows redis infra tcp :6379" "redis" "$_summary_str"
_test_contains "summary shows infra tag" "infra" "$_summary_str"
_test_contains "summary shows app tag" "app" "$_summary_str"
_test_contains "summary shows deploy order" "Deploy order: redis → api → web" "$_summary_str"

# ────────────────────────────────────────
echo ""
echo "  Interactive wizard — quick path via PTY"
# ────────────────────────────────────────

if command -v python3 >/dev/null 2>&1; then
  PTY_HOME="${TMPDIR}/pty-home"
  mkdir -p "$PTY_HOME"

  PROJ_INT1="${TMPDIR}/int-proj-1"
  mkdir -p "${PROJ_INT1}/api" "${PROJ_INT1}/web"
  cat > "${PROJ_INT1}/docker-compose.yml" << 'EOF'
services:
  api: { build: ./api, ports: ["8080:8080"] }
  web: { build: ./web, ports: ["3000:3000"] }
  redis: { image: "redis:7", ports: ["6379:6379"] }
EOF
  printf 'FROM node:20\nEXPOSE 8080\n' > "${PROJ_INT1}/api/Dockerfile"
  printf 'FROM node:20\nEXPOSE 3000\n' > "${PROJ_INT1}/web/Dockerfile"
  printf '{"name":"web"}\n' > "${PROJ_INT1}/web/package.json"

  # First run (no saved machine_role): 2 prompts — 1 (Just this machine), 1 (Create it)
  _pty_out1=$(python3 -c '
import os, pty, select, subprocess, sys, time
master, slave = pty.openpty()
env = os.environ.copy()
env["HOME"] = sys.argv[1]
env["MUSTER_MINIMAL"] = "true"
env["TERM"] = "dumb"
p = subprocess.Popen([sys.argv[2], "--no-verify", "setup"], cwd=sys.argv[3], stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True)
os.close(slave)
answers = [b"1\n", b"1\n"]
ans_i = 0
out = b""
deadline = time.time() + 15
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            out += chunk
            if ans_i < len(answers) and b"Choose [" in out.split(b"\n")[-1]:
                os.write(master, answers[ans_i])
                ans_i += 1
        except OSError:
            break
    if p.poll() is not None:
        break
os.close(master)
p.wait(timeout=5)
sys.stdout.write(out.decode("utf-8", "replace"))
' "$PTY_HOME" "$MUSTER_ROOT/bin/muster" "$PROJ_INT1")

  _test_file_exists "interactive quick path creates muster.json" "${PROJ_INT1}/muster.json"
  _test_contains "interactive summary shows Found 3 services" "Found 3 services" "$_pty_out1"
  _test_contains "interactive summary shows Looks good?" "Looks good?" "$_pty_out1"
  _test_contains "interactive completion prints muster deploy --dry-run" "muster deploy --dry-run" "$_pty_out1"
  _test_eq "interactive quick path omits root" "false" "$(jq 'has("root")' "${PROJ_INT1}/muster.json")"
  _test_eq "interactive quick path infers api tcp 8080" "tcp:8080" "$(jq -r '"\(.services.api.health.type):\(.services.api.health.port)"' "${PROJ_INT1}/muster.json")"
  _test_eq "interactive quick path sets creds off" "off" "$(jq -r '.services.api.credentials.mode' "${PROJ_INT1}/muster.json")"
  _test_eq "interactive quick path leaves git_pull off" "false" "$(jq '.services.api | has("git_pull")' "${PROJ_INT1}/muster.json")"
  _test_eq "interactive quick path defaults name to key" "api" "$(jq -r '.services.api.name' "${PROJ_INT1}/muster.json")"

  # Second run (machine_role already saved as local): 1 prompt — 1 (Create it)
  PROJ_INT2="${TMPDIR}/int-proj-2"
  mkdir -p "${PROJ_INT2}/api"
  cat > "${PROJ_INT2}/docker-compose.yml" << 'EOF'
services:
  api: { build: ./api, ports: ["8080:8080"] }
  redis: { image: "redis:7" }
EOF
  _pty_out2=$(python3 -c '
import os, pty, select, subprocess, sys, time
master, slave = pty.openpty()
env = os.environ.copy()
env["HOME"] = sys.argv[1]
env["MUSTER_MINIMAL"] = "true"
env["TERM"] = "dumb"
p = subprocess.Popen([sys.argv[2], "--no-verify", "setup"], cwd=sys.argv[3], stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True)
os.close(slave)
answers = [b"1\n"]
ans_i = 0
out = b""
deadline = time.time() + 15
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            out += chunk
            if ans_i < len(answers) and b"Choose [" in out.split(b"\n")[-1]:
                os.write(master, answers[ans_i])
                ans_i += 1
        except OSError:
            break
    if p.poll() is not None:
        break
os.close(master)
p.wait(timeout=5)
sys.stdout.write(out.decode("utf-8", "replace"))
' "$PTY_HOME" "$MUSTER_ROOT/bin/muster" "$PROJ_INT2")

  _test_file_exists "subsequent interactive quick path completes in 1 prompt" "${PROJ_INT2}/muster.json"
  _test_eq "subsequent run infers redis default port 6379" "6379" "$(jq -r '.services.redis.health.port' "${PROJ_INT2}/muster.json")"
fi

_test_summary
