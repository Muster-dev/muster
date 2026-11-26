#!/usr/bin/env bash
# muster/lib/core/preflight.sh — fast checks before any deploy hook runs.
#
# _preflight [--no-prompt] PROJECT_DIR SERVICE...
#   Each check passes silently or adds one actionable line. Problems are
#   "block" (the deploy would fail) or "warn" (worth knowing).
#   TTY:      blocking problems offer Fix it / Continue anyway / Abort.
#   no TTY:   problems are printed; any blocking problem returns 1.
#   --minimal prints "# warning:" / "# error:" lines on stderr.
#   A clean result is cached for MUSTER_PREFLIGHT_TTL seconds (default 60).
#
# Requires: utils.sh, config.sh, hints.sh (sourced below), remote.sh for SSH.

source "$MUSTER_ROOT/lib/core/hints.sh"

_PF_SEV=() _PF_ID=() _PF_MSG=() _PF_FIX=() _PF_FIXLABEL=()

_pf_reset() { _PF_SEV=() _PF_ID=() _PF_MSG=() _PF_FIX=() _PF_FIXLABEL=(); }

# Args: block|warn id message [fix_cmd] [fix_label]
_pf_add() {
  local i=${#_PF_SEV[@]}
  _PF_SEV[$i]="$1"
  _PF_ID[$i]="$2"
  _PF_MSG[$i]="$3"
  _PF_FIX[$i]="${4:-}"
  _PF_FIXLABEL[$i]="${5:-}"
}

_pf_blocking_count() {
  local n=0 i=0
  while (( i < ${#_PF_SEV[@]} )); do
    [[ "${_PF_SEV[$i]}" == "block" ]] && n=$(( n + 1 ))
    i=$(( i + 1 ))
  done
  printf '%s' "$n"
}

# Signature of the inputs that affect preflight (for the short-lived cache)
_pf_signature() {
  local dir="$1"; shift
  {
    printf '%s\n' "$@"
    cat "${dir}/muster.json" "${dir}/deploy.json" "${dir}/.env" 2>/dev/null
    local s
    for s in "$@"; do
      ls -l "${dir}/.muster/hooks/${s}/" 2>/dev/null
      cat "${dir}/.muster/hooks/${s}/deploy.sh" 2>/dev/null
    done
  } | cksum | awk '{print $1}'
}

# ── Individual checks ──

# Which tools do the selected services need? Sets _PF_NEED_{DOCKER,COMPOSE,K8S}
_pf_detect_needs() {
  local dir="$1"; shift
  _PF_NEED_DOCKER=false _PF_NEED_COMPOSE=false _PF_NEED_K8S=false _PF_NEED_COMPOSE_V2=false
  local svc
  for svc in "$@"; do
    declare -F remote_is_enabled >/dev/null 2>&1 && remote_is_enabled "$svc" && continue
    local hd="${dir}/.muster/hooks/${svc}" files=""
    [[ -f "${hd}/deploy.sh" ]] && files="${hd}/deploy.sh"
    [[ -f "${hd}/justfile" ]] && files="${files} ${hd}/justfile"
    [[ -z "$files" ]] && continue
    local k8s_cfg
    k8s_cfg=$(config_get ".services.${svc}.k8s" 2>/dev/null)
    # shellcheck disable=SC2086
    if [[ -n "$k8s_cfg" && "$k8s_cfg" != "null" ]] || grep -q 'kubectl' $files 2>/dev/null; then
      _PF_NEED_K8S=true
    fi
    # shellcheck disable=SC2086
    if grep -Eq '(^|[^-[:alnum:]_])docker[[:space:]]+compose([^-[:alnum:]_]|$)' $files 2>/dev/null; then
      _PF_NEED_DOCKER=true; _PF_NEED_COMPOSE=true; _PF_NEED_COMPOSE_V2=true
    elif grep -Eq 'docker-compose' $files 2>/dev/null; then
      _PF_NEED_DOCKER=true; _PF_NEED_COMPOSE=true
    elif grep -Eq '(^|[^-[:alnum:]_])docker([^-[:alnum:]_]|$)' $files 2>/dev/null; then
      _PF_NEED_DOCKER=true
    fi
  done
}

_pf_check_tools() {
  local dir="$1"; shift
  _pf_detect_needs "$dir" "$@"

  if [[ "$_PF_NEED_DOCKER" == "true" ]]; then
    if ! has_cmd docker; then
      local ic; ic=$(_hints_install_cmd docker)
      _pf_add block tool_missing "Docker isn't installed, but the hooks use it${ic:+ — install: ${ic}}" "$ic" "Install Docker (${ic})"
    else
      local out=""
      if ! out=$(_run_with_timeout 10 docker info 2>&1 >/dev/null); then
        if hints_match_text "$out" "" "" && [[ "$HINT_ID" == "docker_sock_permission" ]]; then
          _pf_add block docker_sock_permission "You don't have permission to use Docker — ${HINT_TRY}" "$HINT_FIX_CMD" "$HINT_FIX_LABEL"
        else
          hints_lookup docker_not_running
          local how="${HINT_FIX_CMD:-start Docker}"
          _pf_add block docker_not_running "Docker is installed but not running — start it with: ${how}" "$HINT_FIX_CMD" "$HINT_FIX_LABEL"
        fi
      fi
    fi
    if [[ "$_PF_NEED_COMPOSE" == "true" ]] && has_cmd docker; then
      local v2=false v1=false
      docker compose version >/dev/null 2>&1 && v2=true
      has_cmd docker-compose && v1=true
      if [[ "$v2" == "false" && "$v1" == "false" ]]; then
        local ic; ic=$(_hints_install_cmd docker-compose)
        _pf_add block tool_missing "Docker Compose isn't installed (neither 'docker compose' nor 'docker-compose')${ic:+ — install: ${ic}}" "$ic" "Install Docker Compose"
      elif [[ "$v2" == "false" && "$_PF_NEED_COMPOSE_V2" == "true" ]]; then
        local ic; ic=$(_hints_install_cmd docker-compose)
        _pf_add block tool_missing "Hooks use 'docker compose' (v2) but only 'docker-compose' (v1) is installed — install the Compose v2 plugin${ic:+: ${ic}}" "$ic" "Install the Compose v2 plugin"
      fi
    fi
  fi

  if [[ "$_PF_NEED_K8S" == "true" ]]; then
    if ! has_cmd kubectl; then
      local ic; ic=$(_hints_install_cmd kubectl)
      [[ "$ic" == \#* ]] && ic=""
      _pf_add block tool_missing "kubectl isn't installed, but the hooks use it${ic:+ — install: ${ic}}" "$ic" "Install kubectl"
      return 0
    fi
    _pf_check_k8s "$dir" "$@"
  fi
}

_pf_check_k8s() {
  local dir="$1"; shift
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null)
  if [[ -z "$ctx" ]]; then
    _pf_add block k8s_context "kubectl has no current context — pick one: kubectl config use-context <name>"
    return 0
  fi
  local out=""
  if ! out=$(_run_with_timeout 10 kubectl version --request-timeout=5s 2>&1 >/dev/null); then
    if hints_match_text "$out" "" "" && [[ "$HINT_ID" == k8s_* ]]; then
      _pf_add block "$HINT_ID" "Kubernetes (context ${ctx}): ${HINT_TITLE}"
    else
      _pf_add block k8s_unreachable "Can't reach the Kubernetes cluster for context '${ctx}' — check VPN/network: kubectl cluster-info"
    fi
    return 0
  fi

  # Namespaces exist?
  local svc seen=" "
  for svc in "$@"; do
    local ns
    ns=$(config_get ".services.${svc}.k8s.namespace" 2>/dev/null)
    [[ -z "$ns" || "$ns" == "null" ]] && continue
    [[ "$seen" == *" ${ns} "* ]] && continue
    seen="${seen}${ns} "
    local nout=""
    if ! nout=$(_run_with_timeout 8 kubectl get namespace "$ns" --request-timeout=5s 2>&1 >/dev/null); then
      if printf '%s' "$nout" | grep -qi 'not found'; then
        if [[ "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
          _pf_add block k8s_namespace "Namespace '${ns}' doesn't exist in context '${ctx}' — create it: kubectl create namespace ${ns}" \
            "kubectl create namespace ${ns}" "Create namespace ${ns}"
        else
          _pf_add block k8s_namespace "Namespace '${ns}' doesn't exist in context '${ctx}'"
        fi
      fi
    fi
  done

  # Context looks like prod but the project doesn't?
  local lctx project
  lctx=$(printf '%s' "$ctx" | tr '[:upper:]' '[:lower:]')
  project=$(config_get '.project' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if printf '%s' "$lctx" | grep -Eq '(^|[^a-z])(prod|production|prd)([^a-z]|$)'; then
    local hay="${project} ${seen}"
    if ! printf '%s' "$hay" | grep -Eq '(prod|production|prd)'; then
      _pf_add warn prod_context "kubectl context '${ctx}' looks like production — make sure that's where ${project:-this project} should go"
    fi
  fi
}

_pf_check_disk() {
  local dir="$1" avail
  avail=$(_run_with_timeout 5 df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')
  [[ "$avail" =~ ^[0-9]+$ ]] || return 0
  local mb=$(( avail / 1024 ))
  local fix="" label=""
  if has_cmd docker; then
    fix="docker system df; docker system prune -f"
    label="Prune unused Docker data"
  fi
  if (( mb < 100 )); then
    _pf_add block disk_full "Only ${mb}MB of disk left — builds will likely fail (see: docker system df)" "$fix" "$label"
  elif (( mb < 500 )); then
    _pf_add warn disk_full "Low disk space: ${mb}MB left" "$fix" "$label"
  fi
}

_pf_check_hooks() {
  local dir="$1"; shift
  local svc
  for svc in "$@"; do
    local hd="${dir}/.muster/hooks/${svc}"
    if [[ -f "${hd}/justfile" ]]; then
      continue
    fi
    if [[ ! -f "${hd}/deploy.sh" ]]; then
      _pf_add block hook_missing "${svc} has no deploy hook (.muster/hooks/${svc}/deploy.sh) — run muster setup to regenerate it"
      continue
    fi
    if [[ ! -x "${hd}/deploy.sh" ]]; then
      _pf_add block hook_not_executable "${svc}: deploy.sh isn't executable — fix: chmod +x .muster/hooks/${svc}/deploy.sh" \
        "chmod +x .muster/hooks/${svc}/*.sh" "Make ${svc} hooks executable"
    fi
  done
}

# Environment variable names a script references without a default.
# Prints "NAME" or "NAME!" (required via ${NAME:?}) one per line.
_pf_env_refs() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local body
  body=$(grep -v '^[[:space:]]*#' "$file" 2>/dev/null)
  # Names assigned in the script itself
  local assigned
  assigned=$(printf '%s\n' "$body" \
    | grep -Eo '(^|[;[:space:]]|export[[:space:]]+|local[[:space:]]+|readonly[[:space:]]+|declare[[:space:]]+)[A-Za-z_][A-Za-z0-9_]*=' \
    | sed -E 's/^.*[;[:space:]]//; s/^(export|local|readonly|declare)//; s/=$//' ; \
    printf '%s\n' "$body" | grep -Eo '(for|read)[[:space:]]+(-[a-z]+[[:space:]]+)*[A-Za-z_][A-Za-z0-9_]*' | awk '{print $NF}')
  {
    printf '%s\n' "$body" | grep -Eo '\$\{[A-Z_][A-Z0-9_]*\}' | sed -E 's/^\$\{//; s/\}$//'
    printf '%s\n' "$body" | grep -Eo '\$[A-Z_][A-Z0-9_]*' | sed -E 's/^\$//'
    printf '%s\n' "$body" | grep -Eo '\$\{[A-Z_][A-Z0-9_]*:?\?' | sed -E 's/^\$\{//; s/:?\?$/!/'
  } | sort -u | while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local bare="${name%!}"
    printf '%s\n' "$assigned" | grep -qxF -- "$bare" && continue
    printf '%s\n' "$name"
  done
}

_pf_env_ignored() {
  case "$1" in
    MUSTER_*|HOME|PATH|USER|PWD|OLDPWD|SHELL|TERM|HOSTNAME|TMPDIR|LANG|LC_*|RANDOM|SECONDS|LINENO|BASH*|PPID|UID|EUID|OSTYPE|IFS|OPT*|PIPESTATUS|FUNCNAME|REPLY|COLUMNS|LINES|CI|DEBUG|EDITOR|LOGNAME|DISPLAY|SSH_*|XDG_*|GITHUB_*|DOCKER_HOST|KUBECONFIG|NO_COLOR) return 0 ;;
  esac
  return 1
}

_pf_check_env() {
  local dir="$1"; shift
  local svc missing="" count=0
  for svc in "$@"; do
    declare -F remote_is_enabled >/dev/null 2>&1 && remote_is_enabled "$svc" && continue
    local hook="${dir}/.muster/hooks/${svc}/deploy.sh"
    [[ -f "$hook" ]] || continue
    local creds
    creds=" $(config_get ".services.${svc}.credentials.required[]" 2>/dev/null | tr '\n' ' ') "
    # Compose file used by this hook (COMPOSE_FILE="…" or the project default)
    local files="$hook" cf=""
    if grep -q 'compose' "$hook" 2>/dev/null; then
      cf=$(sed -nE 's/^[[:space:]]*COMPOSE_FILE="?([^"$]+)"?.*/\1/p' "$hook" | head -1)
      [[ -z "$cf" ]] && for cf in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "${dir}/${cf}" ]] && break
        cf=""
      done
      [[ -n "$cf" && -f "${dir}/${cf}" ]] && files="${files} ${dir}/${cf}"
    fi
    local f name
    for f in $files; do
      while IFS= read -r name; do
        local bare="${name%!}"
        _pf_env_ignored "$bare" && continue
        [[ "$creds" == *" ${bare} "* ]] && continue
        [[ -n "${!bare+x}" ]] && continue
        [[ "$missing" == *"|${bare}|"* ]] && continue
        missing="${missing}|${bare}|"
        count=$(( count + 1 ))
        (( count > 5 )) && continue
        local where="${f##*/}"
        if [[ "$name" == *"!" ]]; then
          _pf_add block env_missing "${svc}: ${where} requires \$${bare}, which isn't set — add ${bare}=… to .env"
        else
          _pf_add warn env_missing "${svc}: ${where} uses \$${bare}, which isn't set — add ${bare}=… to .env if it's needed"
        fi
      done < <(_pf_env_refs "$f")
    done
  done
}

_pf_check_ports() {
  local dir="$1"; shift
  local svc
  for svc in "$@"; do
    declare -F remote_is_enabled >/dev/null 2>&1 && remote_is_enabled "$svc" && continue
    local hook="${dir}/.muster/hooks/${svc}/deploy.sh"
    [[ -f "$hook" ]] || continue
    # Only dev/bare-style services that start a local process
    grep -Eq 'docker|kubectl' "$hook" 2>/dev/null && continue
    local htype port
    htype=$(config_get ".services.${svc}.health.type" 2>/dev/null)
    port=$(config_get ".services.${svc}.health.port" 2>/dev/null)
    [[ "$htype" == "http" || "$htype" == "tcp" ]] || continue
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    _hints_port_owner "$port" || continue
    # Our own previous instance is fine — the hook restarts it
    local own=""
    [[ -f "${dir}/.muster/pids/${svc}.pid" ]] && own=$(tr -cd '0-9' < "${dir}/.muster/pids/${svc}.pid")
    if [[ "$_HPO_KIND" == "process" && -n "$own" ]]; then
      [[ "$_HPO_PID" == "$own" ]] && continue
      local ppid
      ppid=$(ps -o ppid= -p "$_HPO_PID" 2>/dev/null | tr -cd '0-9')
      [[ "$ppid" == "$own" ]] && continue
    fi
    if [[ "$_HPO_KIND" == "container" ]]; then
      _pf_add block port_in_use "${svc}: port ${port} is taken by container '${_HPO_NAME}' — stop it: docker stop ${_HPO_NAME}" \
        "docker stop ${_HPO_NAME}" "Stop container ${_HPO_NAME}"
    else
      _pf_add block port_in_use "${svc}: port ${port} is taken by ${_HPO_NAME} (PID ${_HPO_PID}) — stop it or change the port" \
        "kill ${_HPO_PID}" "Stop ${_HPO_NAME} (PID ${_HPO_PID})"
    fi
  done
}

_pf_check_git() {
  local dir="$1"; shift
  ( cd "$dir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ) || return 0
  local pulls=false svc
  for svc in "$@"; do
    [[ "$(config_get ".services.${svc}.git_pull.enabled" 2>/dev/null)" == "true" ]] && pulls=true
  done
  if [[ "$pulls" == "true" ]]; then
    local dirty
    dirty=$(cd "$dir" && git status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$dirty" =~ ^[0-9]+$ ]] && (( dirty > 0 )); then
      _pf_add warn git_dirty "${dirty} uncommitted change$( (( dirty != 1 )) && echo s) — git pull may refuse to run (commit or git stash first)"
    fi
  else
    local behind upstream
    upstream=$(cd "$dir" && git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    [[ -z "$upstream" ]] && return 0
    behind=$(cd "$dir" && git rev-list --count 'HEAD..@{u}' 2>/dev/null)
    if [[ "$behind" =~ ^[0-9]+$ ]] && (( behind > 0 )); then
      _pf_add warn git_behind "${behind} commit$( (( behind != 1 )) && echo s) behind ${upstream} (as of last fetch) — you may be deploying old code" \
        "git pull --ff-only" "Pull ${behind} commit$( (( behind != 1 )) && echo s) (git pull --ff-only)"
    fi
  fi
}

_pf_check_locks() {
  local dir="$1" f
  for f in "${dir}/.muster/locks/"*.lock; do
    [[ -f "$f" ]] || continue
    declare -F _service_lock_is_stale >/dev/null 2>&1 || return 0
    if _service_lock_is_stale "$f"; then
      local s="${f##*/}"; s="${s%.lock}"
      _pf_add warn stale_lock "Stale lock for ${s} (PID ${_SLOCK_PID:-?} by ${_SLOCK_USER:-unknown} is gone)" \
        "rm -f .muster/locks/${s}.lock" "Remove the stale ${s} lock"
    fi
  done
}

_pf_check_ssh() {
  local dir="$1"; shift
  declare -F remote_is_enabled >/dev/null 2>&1 || return 0
  has_cmd ssh || return 0
  local svc seen=" "
  for svc in "$@"; do
    remote_is_enabled "$svc" || continue
    _remote_load_config "$svc"
    [[ "$_REMOTE_CLOUD" == "true" || "$_REMOTE_AUTH_METHOD" == "password" ]] && continue
    local key="${_REMOTE_USER}@${_REMOTE_HOST}:${_REMOTE_PORT}"
    [[ "$seen" == *" ${key} "* ]] && continue
    seen="${seen}${key} "
    local opts="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p ${_REMOTE_PORT}"
    if [[ -n "$_REMOTE_IDENTITY" ]]; then
      local id="${_REMOTE_IDENTITY/#\~/$HOME}"
      opts="${opts} -i ${id}"
    fi
    local out=""
    # shellcheck disable=SC2086
    if ! out=$(_run_with_timeout 10 ssh $opts "${_REMOTE_USER}@${_REMOTE_HOST}" true 2>&1); then
      if hints_match_text "$out" "" "$svc" && [[ "$HINT_ID" == ssh_* ]]; then
        _pf_add block "$HINT_ID" "${svc}: SSH to ${key%:*} failed — ${HINT_TITLE}"
      else
        _pf_add block ssh_timeout "${svc}: can't reach ${key%:*} over SSH — test with: ssh -p ${_REMOTE_PORT} ${_REMOTE_USER}@${_REMOTE_HOST}"
      fi
    fi
  done
}

# Run every check. Args: project_dir service...
_preflight_collect() {
  local dir="$1"; shift
  _pf_reset
  _pf_check_hooks "$dir" "$@"
  _pf_check_tools "$dir" "$@"
  _pf_check_disk "$dir"
  _pf_check_ports "$dir" "$@"
  _pf_check_env "$dir" "$@"
  _pf_check_git "$dir" "$@"
  _pf_check_locks "$dir"
  _pf_check_ssh "$dir" "$@"
}

# Print collected problems
_preflight_report() {
  local to_stderr="$1" i=0
  while (( i < ${#_PF_SEV[@]} )); do
    local sev="${_PF_SEV[$i]}" msg="${_PF_MSG[$i]}"
    if [[ "${MUSTER_MINIMAL:-false}" == "true" ]]; then
      if [[ "$sev" == "block" ]]; then
        printf '# error: %s\n' "$msg" >&2
      else
        printf '# warning: %s\n' "$msg" >&2
      fi
    elif [[ "$to_stderr" == "true" ]]; then
      printf '  %s %s\n' "$( [[ "$sev" == "block" ]] && echo x || echo !)" "$msg" >&2
    elif [[ "$sev" == "block" ]]; then
      printf '  %bx%b %s\n' "${RED}" "${RESET}" "$msg"
    else
      printf '  %b!%b %s\n' "${YELLOW}" "${RESET}" "$msg"
    fi
    i=$(( i + 1 ))
  done
}

_preflight() {
  local prompt=true
  if [[ "${1:-}" == "--no-prompt" ]]; then prompt=false; shift; fi
  local dir="$1"; shift
  (( $# == 0 )) && return 0
  [[ -t 0 ]] || prompt=false

  # Short-lived cache of a clean result
  local ttl="${MUSTER_PREFLIGHT_TTL:-60}" cache="${dir}/.muster/.preflight_ok" sig=""
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=60
  if (( ttl > 0 )); then
    sig=$(_pf_signature "$dir" "$@")
    if [[ -f "$cache" ]]; then
      local cts csig
      IFS='|' read -r cts csig < "$cache"
      if [[ "$cts" =~ ^[0-9]+$ && "$csig" == "$sig" ]] && (( $(date +%s) - cts < ttl )); then
        return 0
      fi
    fi
  fi

  _preflight_collect "$dir" "$@"

  if (( ${#_PF_SEV[@]} == 0 )); then
    (( ttl > 0 )) && printf '%s|%s\n' "$(date +%s)" "$sig" > "$cache" 2>/dev/null
    return 0
  fi
  rm -f "$cache" 2>/dev/null

  _preflight_report false

  local blocking
  blocking=$(_pf_blocking_count)
  if (( blocking == 0 )); then
    [[ "${MUSTER_MINIMAL:-false}" != "true" ]] && echo ""
    return 0
  fi

  if [[ "$prompt" == "false" ]]; then
    if [[ "${MUSTER_MINIMAL:-false}" == "true" ]]; then
      printf '# error: preflight found %d blocking problem(s); fix them or rerun with --no-preflight\n' "$blocking" >&2
    else
      echo ""
      err "Preflight found ${blocking} blocking problem$( (( blocking != 1 )) && echo s) — fix $( (( blocking != 1 )) && echo them || echo it), or rerun with --no-preflight to skip these checks."
    fi
    return 1
  fi

  # Interactive: walk each blocking problem
  echo ""
  local i=0 fixed_any=false
  while (( i < ${#_PF_SEV[@]} )); do
    if [[ "${_PF_SEV[$i]}" == "block" ]]; then
      local opts=() fixopt=""
      if [[ -n "${_PF_FIX[$i]}" ]]; then
        fixopt="Fix it: ${_PF_FIXLABEL[$i]:-${_PF_FIX[$i]}}"
        opts[0]="$fixopt"
      fi
      opts[${#opts[@]}]="Continue anyway"
      opts[${#opts[@]}]="Abort"
      menu_select "${_PF_MSG[$i]}" "${opts[@]}"
      case "$MENU_RESULT" in
        "Continue anyway") ;;
        "Abort"|"__back__"|"")
          err "Deploy aborted before any hook ran."
          return 1 ;;
        *)
          if [[ -n "$fixopt" && "$MENU_RESULT" == "$fixopt" ]]; then
            HINT_FIX_CMD="${_PF_FIX[$i]}" HINT_FIX_LABEL="${_PF_FIXLABEL[$i]}"
            hints_run_fix --yes && fixed_any=true
            if [[ "${_PF_ID[$i]}" == "docker_not_running" ]]; then
              _pf_wait_docker
            fi
          fi ;;
      esac
    fi
    i=$(( i + 1 ))
  done
  echo ""
  if [[ "$fixed_any" == "true" ]]; then
    # Re-check once so we don't start a deploy that will fail anyway
    _preflight_collect "$dir" "$@"
    blocking=$(_pf_blocking_count)
    if (( blocking > 0 )); then
      _preflight_report false
      echo ""
      menu_select "Still ${blocking} blocking problem$( (( blocking != 1 )) && echo s). Deploy anyway?" "Continue anyway" "Abort"
      [[ "$MENU_RESULT" == "Continue anyway" ]] || { err "Deploy aborted before any hook ran."; return 1; }
    else
      ok "Preflight checks pass"
      echo ""
    fi
  fi
  return 0
}

# After starting Docker, give the daemon up to 60s to come up
_pf_wait_docker() {
  local n=0
  printf '  %bWaiting for Docker to start' "${DIM}"
  while (( n < 30 )); do
    if _run_with_timeout 5 docker info >/dev/null 2>&1; then
      printf ' ready%b\n' "${RESET}"
      return 0
    fi
    printf '.'
    sleep 2
    n=$(( n + 1 ))
  done
  printf ' still not ready%b\n' "${RESET}"
  return 1
}
