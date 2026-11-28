#!/usr/bin/env bash
# muster/lib/commands/setup_strategy.sh — `muster setup --update --strategy
# svc=blue-green|canary|rolling` on an existing project: set the strategy in
# muster.json and regenerate that service's hooks from the strategy template.
# Unedited hooks are replaced; edited ones are kept and the new template is
# written next to them as <hook>.strategy-new.

source "$MUSTER_ROOT/lib/core/templates.sh"
source "$MUSTER_ROOT/lib/core/setup_txn.sh"
source "$MUSTER_ROOT/lib/core/engine.sh"

_setup_apply_strategies() {
  local project_path
  project_path=$(cd "${1:-.}" 2>/dev/null && pwd) || { err "No such directory: ${1}"; return 1; }
  local cfg="${project_path}/muster.json"
  [[ -f "$cfg" ]] || cfg="${project_path}/deploy.json"
  [[ -f "$cfg" ]] || { err "No muster.json in ${project_path} — run muster setup first"; return 1; }
  has_cmd jq || { err "jq is required"; return 1; }
  CONFIG_FILE="$cfg"

  # Validate every spec before touching anything
  local i=0 spec svc type
  local svcs=() types=()
  while (( i < ${#_FLAG_STRATEGY[@]} )); do
    spec="${_FLAG_STRATEGY[$i]}"
    svc="${spec%%=*}"; type="${spec#*=}"
    i=$(( i + 1 ))
    if [[ "$spec" != *=* || -z "$svc" || -z "$type" ]]; then
      err "--strategy needs svc=type (got \"${spec}\")"; return 1
    fi
    case "$type" in
      rolling|blue-green|canary) ;;
      *)
        err "Unknown strategy \"${type}\" for ${svc} (use rolling, blue-green or canary)"
        source "$MUSTER_ROOT/lib/core/suggest.sh"
        _suggest_print "$type" rolling blue-green canary || true
        return 1 ;;
    esac
    if [[ "$(jq -r --arg s "$svc" '.services | has($s)' "$cfg")" != "true" ]]; then
      err "Unknown service: ${svc}"
      return 1
    fi
    if [[ "$type" != "rolling" && -z "$(jq -r --arg s "$svc" '.services[$s].k8s.deployment // empty' "$cfg")" ]]; then
      err "${svc} isn't a Kubernetes service (no k8s.deployment) — blue-green/canary support Kubernetes only in this version"
      return 1
    fi
    svcs[${#svcs[@]}]="$svc"; types[${#types[@]}]="$type"
  done

  _SETUP_TXN_MODE="update"
  _SETUP_NOTICES=()
  _setup_txn_begin "$project_path" || return 1
  cp "$cfg" "$_SETUP_TXN_CONFIG"

  i=0
  local regen=""
  while (( i < ${#svcs[@]} )); do
    svc="${svcs[$i]}"; type="${types[$i]}"
    i=$(( i + 1 ))
    local stack
    stack=$(_engine_service_stack "$svc" "$project_path")
    [[ "$stack" == "k8s" ]] || continue
    local hd_old="${project_path}/.muster/hooks/${svc}" hd="${_SETUP_TXN_MUSTER}/hooks/${svc}"
    mkdir -p "$hd"
    local ns dep df port k8sdir
    ns=$(jq -r --arg s "$svc" '.services[$s].k8s.namespace // "default"' "$cfg")
    dep=$(jq -r --arg s "$svc" '.services[$s].k8s.deployment // $s' "$cfg")
    port=$(jq -r --arg s "$svc" '.services[$s].health.port // 8080' "$cfg")
    df=""; k8sdir=""
    if [[ -f "${hd_old}/deploy.sh" ]]; then
      df=$(sed -n 's/.*docker build .* -f "\([^"]*\)".*/\1/p' "${hd_old}/deploy.sh" | head -1)
      k8sdir=$(sed -n 's/.*kubectl apply -f "\([^"]*\)".*/\1/p' "${hd_old}/deploy.sh" | head -1)
    fi
    _setup_copy_hooks k8s "$svc" "$svc" "$hd" "docker-compose.yml" "${df:-Dockerfile}" \
      "${k8sdir:-k8s/${svc}/}" "$ns" "$port" "$dep" "" "$type"
    regen="${regen}${regen:+ }${svc}"
  done

  _SETUP_STRATEGY_NEW=true
  _setup_txn_commit || { _SETUP_STRATEGY_NEW=""; return 1; }
  _SETUP_STRATEGY_NEW=""
  # The config merge notice ("No new services found") doesn't apply here
  local _kept_notices=() _n
  for _n in ${_SETUP_NOTICES[@]+"${_SETUP_NOTICES[@]}"}; do
    [[ "$_n" == "No new services found"* ]] && continue
    _kept_notices[${#_kept_notices[@]}]="$_n"
  done
  _SETUP_NOTICES=(${_kept_notices[@]+"${_kept_notices[@]}"})

  # muster.json: the merge above keeps existing entries, so set strategies here
  local tmp="${cfg}.tmp.$$"
  cp "$cfg" "$tmp"
  i=0
  while (( i < ${#svcs[@]} )); do
    svc="${svcs[$i]}"; type="${types[$i]}"
    i=$(( i + 1 ))
    if [[ "$type" == "rolling" ]]; then
      jq --arg s "$svc" 'del(.services[$s].strategy)' "$tmp" > "${tmp}.2"
    else
      jq --arg s "$svc" --arg t "$type" '
        .services[$s].strategy = (
          (.services[$s].strategy // {}) | if type == "string" then {} else . end
          | if .type != $t then {type: $t} else . end)' "$tmp" > "${tmp}.2"
    fi
    mv "${tmp}.2" "$tmp"
  done
  mv "$tmp" "$cfg"

  source "$MUSTER_ROOT/lib/core/hook_security.sh"
  _hook_manifest_generate "$project_path"

  i=0
  while (( i < ${#svcs[@]} )); do
    ok "${svcs[$i]}: strategy ${types[$i]}"
    i=$(( i + 1 ))
  done
  [[ -n "$regen" ]] && _setup_notice "Hooks regenerated from the strategy templates for: ${regen}"
  _setup_print_notices
  echo ""
  printf '  %bNext:%b muster hooks approve %s   then   muster deploy %s --dry-run\n' \
    "${BOLD}" "${RESET}" "${svcs[0]}" "${svcs[0]}"
  printf '  %bSee docs/rollouts.md for steps, gates and promote/abort.%b\n' "${DIM}" "${RESET}"
  return 0
}
