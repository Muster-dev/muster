#!/usr/bin/env bash
# tests/test_hook_templates.sh — Hook template generation, _is_infra_service, _infra_default_image
# Ported from legacy test/hooks.bats into plain bash tests.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

TMPDIR=$(mktemp -d)
export HOME="${TMPDIR}/home"
mkdir -p "$HOME"
trap 'rm -rf "$TMPDIR"' EXIT

source "$MUSTER_ROOT/lib/core/templates.sh"

# ────────────────────────────────────────
echo "  Templates — existence and syntax"
# ────────────────────────────────────────

for _hook in deploy.sh health.sh rollback.sh logs.sh cleanup.sh; do
  _test_file_exists "k8s template exists: ${_hook}" "$MUSTER_ROOT/templates/hooks/k8s/${_hook}"
  _test_file_exists "k8s/infra template exists: ${_hook}" "$MUSTER_ROOT/templates/hooks/k8s/infra/${_hook}"
done

_syntax_fail=0
for _stack in k8s compose docker bare dev; do
  _dir="$MUSTER_ROOT/templates/hooks/${_stack}"
  [[ -d "$_dir" ]] || continue
  for _f in "$_dir"/*.sh; do
    [[ -f "$_f" ]] || continue
    bash -n "$_f" 2>/dev/null || _syntax_fail=$(( _syntax_fail + 1 ))
  done
  if [[ -d "${_dir}/infra" ]]; then
    for _f in "${_dir}/infra"/*.sh; do
      [[ -f "$_f" ]] || continue
      bash -n "$_f" 2>/dev/null || _syntax_fail=$(( _syntax_fail + 1 ))
    done
  fi
done
_test_eq "all hook templates pass bash -n" "0" "$_syntax_fail"

# ────────────────────────────────────────
echo ""
echo "  _setup_copy_hooks — k8s app service"
# ────────────────────────────────────────

_hd="${TMPDIR}/hooks/k8s-api"
mkdir -p "$_hd"
_setup_copy_hooks "k8s" "api" "api" "$_hd" \
  "docker-compose.yml" "Dockerfile" "k8s/api/" "production" "8080" "waity-api" ""

_all_exec=true _leftover=false _bad_syn=false
for _hook in deploy.sh health.sh rollback.sh logs.sh cleanup.sh; do
  [[ -f "${_hd}/${_hook}" && -x "${_hd}/${_hook}" ]] || _all_exec=false
  grep -q '{{' "${_hd}/${_hook}" && _leftover=true
  bash -n "${_hd}/${_hook}" 2>/dev/null || _bad_syn=true
done
_test_eq "k8s app creates all 5 executable hooks" "true" "$_all_exec"
_test_eq "k8s app has no leftover placeholders" "false" "$_leftover"
_test_eq "k8s app hooks pass bash -n" "false" "$_bad_syn"
_deploy_txt=$(cat "${_hd}/deploy.sh")
_test_contains "k8s app substitutes deploy name" "waity-api" "$_deploy_txt"
_test_contains "k8s app substitutes namespace" "production" "$_deploy_txt"
_test_contains "k8s app uses docker build" "docker build" "$_deploy_txt"
_test_contains "k8s app defaults MUSTER_DEPLOY_MODE to update" "MUSTER_DEPLOY_MODE:-update" "$_deploy_txt"

# k8s_deploy_name differing from service key
_hd_diff="${TMPDIR}/hooks/k8s-diff"
mkdir -p "$_hd_diff"
_setup_copy_hooks "k8s" "api" "api" "$_hd_diff" \
  "" "Dockerfile" "k8s/api/" "staging" "8080" "myproject-api-server" ""
_diff_txt=$(cat "${_hd_diff}/deploy.sh")
_test_contains "k8s_deploy_name differs from svc key" "myproject-api-server" "$_diff_txt"
_test_contains "k8s staging namespace substituted" "staging" "$_diff_txt"

# ────────────────────────────────────────
echo ""
echo "  _setup_copy_hooks — k8s infra services"
# ────────────────────────────────────────

_hd_redis="${TMPDIR}/hooks/k8s-redis"
mkdir -p "$_hd_redis"
_setup_copy_hooks "k8s" "redis" "redis" "$_hd_redis" \
  "" "" "k8s/redis/" "production" "6379" "waity-redis" ""

_all_exec=true _leftover=false _bad_syn=false
for _hook in deploy.sh health.sh rollback.sh logs.sh cleanup.sh; do
  [[ -f "${_hd_redis}/${_hook}" && -x "${_hd_redis}/${_hook}" ]] || _all_exec=false
  grep -q '{{' "${_hd_redis}/${_hook}" && _leftover=true
  bash -n "${_hd_redis}/${_hook}" 2>/dev/null || _bad_syn=true
done
_test_eq "k8s infra creates all 5 executable hooks" "true" "$_all_exec"
_test_eq "k8s infra has no leftover placeholders" "false" "$_leftover"
_test_eq "k8s infra hooks pass bash -n" "false" "$_bad_syn"
_redis_txt=$(cat "${_hd_redis}/deploy.sh")
_test_contains "k8s redis uses rollout restart" "rollout restart" "$_redis_txt"
_test_contains "k8s redis defaults MUSTER_DEPLOY_MODE to restart" "MUSTER_DEPLOY_MODE:-restart" "$_redis_txt"
_test_not_contains "k8s redis does not docker build" "docker build" "$_redis_txt"
_test_contains "k8s redis gets default image" "redis:7-alpine" "$_redis_txt"

_hd_pg="${TMPDIR}/hooks/k8s-postgres"
mkdir -p "$_hd_pg"
_setup_copy_hooks "k8s" "postgres" "postgres" "$_hd_pg" \
  "" "" "k8s/postgres/" "production" "5432" "waity-postgres" ""
_pg_txt=$(cat "${_hd_pg}/deploy.sh")
_test_contains "k8s postgres uses rollout restart" "rollout restart" "$_pg_txt"
_test_contains "k8s postgres gets default image" "postgres:16-alpine" "$_pg_txt"
_test_not_contains "k8s postgres does not docker build" "docker build" "$_pg_txt"

# ────────────────────────────────────────
echo ""
echo "  _setup_copy_hooks — compose, dev, bare stacks"
# ────────────────────────────────────────

_hd_comp="${TMPDIR}/hooks/compose-web"
mkdir -p "$_hd_comp"
_setup_copy_hooks "compose" "web" "web" "$_hd_comp" \
  "docker-compose.prod.yml" "Dockerfile" "" "" "3000" "" ""
_all_exec=true
for _hook in deploy.sh health.sh rollback.sh logs.sh cleanup.sh; do
  [[ -f "${_hd_comp}/${_hook}" && -x "${_hd_comp}/${_hook}" ]] || _all_exec=false
done
_test_eq "compose creates all 5 executable hooks" "true" "$_all_exec"
_comp_txt=$(cat "${_hd_comp}/deploy.sh")
_test_contains "compose substitutes service name" "web" "$_comp_txt"
_test_contains "compose substitutes compose file" "docker-compose.prod.yml" "$_comp_txt"

_hd_dev_app="${TMPDIR}/hooks/dev-api"
mkdir -p "$_hd_dev_app"
_setup_copy_hooks "dev" "api" "api" "$_hd_dev_app" \
  "" "" "" "" "3000" "" "npm start"
_test "dev app creates executable deploy.sh" test -x "${_hd_dev_app}/deploy.sh"
_test_contains "dev app substitutes start cmd" "npm start" "$(cat "${_hd_dev_app}/deploy.sh")"

_hd_dev_infra="${TMPDIR}/hooks/dev-redis"
mkdir -p "$_hd_dev_infra"
_setup_copy_hooks "dev" "redis" "redis" "$_hd_dev_infra" \
  "docker-compose.yml" "" "" "" "6379" "" ""
_test "dev infra creates executable deploy.sh" test -x "${_hd_dev_infra}/deploy.sh"
_test_not_contains "dev infra uses compose, not npm start" "npm start" "$(cat "${_hd_dev_infra}/deploy.sh")"

_hd_bare="${TMPDIR}/hooks/bare-myapp"
mkdir -p "$_hd_bare"
_setup_copy_hooks "bare" "myapp" "myapp" "$_hd_bare" "" "" "" "" "" "" ""
_all_exec=true
for _hook in deploy.sh health.sh rollback.sh logs.sh cleanup.sh; do
  [[ -f "${_hd_bare}/${_hook}" && -x "${_hd_bare}/${_hook}" ]] || _all_exec=false
done
_test_eq "bare creates all 5 executable stub hooks" "true" "$_all_exec"

# ────────────────────────────────────────
echo ""
echo "  _is_infra_service & _infra_default_image"
# ────────────────────────────────────────

_test "_is_infra_service detects redis" _is_infra_service "redis"
_test "_is_infra_service detects postgres" _is_infra_service "postgres"
_test "_is_infra_service detects mongodb" _is_infra_service "mongodb"
_test "_is_infra_service detects rabbitmq" _is_infra_service "rabbitmq"
_test "_is_infra_service detects nginx" _is_infra_service "nginx"

_test "_is_infra_service is case insensitive (Redis)" _is_infra_service "Redis"
_test "_is_infra_service is case insensitive (POSTGRES)" _is_infra_service "POSTGRES"
_test "_is_infra_service is case insensitive (MongoDB)" _is_infra_service "MongoDB"

for _app in api web worker frontend; do
  _rc=0
  _is_infra_service "$_app" || _rc=$?
  _test "_is_infra_service rejects app service: ${_app}" test "$_rc" -ne 0
done

_test_eq "_infra_default_image redis" "redis:7-alpine" "$(_infra_default_image redis)"
_test_eq "_infra_default_image postgres" "postgres:16-alpine" "$(_infra_default_image postgres)"
_test_eq "_infra_default_image mongo" "mongo:7" "$(_infra_default_image mongo)"
_test_eq "_infra_default_image nginx" "nginx:alpine" "$(_infra_default_image nginx)"
_test_eq "_infra_default_image empty for api" "" "$(_infra_default_image api)"
_test_eq "_infra_default_image empty for web" "" "$(_infra_default_image web)"

_test_summary
