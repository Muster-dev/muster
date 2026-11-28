#!/usr/bin/env bash
# muster/lib/core/setup_txn.sh — atomic, merge-aware writes for muster setup.
#
# Setup generates everything into a staging directory inside the project
# (.muster-setup.XXXXXX), then commits it in one step. Ctrl+C before the
# commit leaves no partial files.
#
#   _setup_txn_begin PROJECT        create staging; sets _SETUP_TXN_CONFIG and
#                                   _SETUP_TXN_MUSTER (write there, not to the project)
#   _setup_txn_commit               move staged files into place
#   _setup_txn_abort                drop staging
#
# Re-running setup on an existing project:
#   _SETUP_TXN_MODE=update  keep muster.json entries you already have, add new
#                           services, keep hooks you edited (a hook is "edited"
#                           when it differs from what muster last generated)
#   _SETUP_TXN_MODE=fresh   start over, but back up edited hooks first
#
# Generated-hook checksums live in .muster/.template_hashes ("svc/file cksum").

_SETUP_TXN_MODE="${_SETUP_TXN_MODE:-fresh}"
_SETUP_TXN_DIR=""
_SETUP_TXN_PROJECT=""
_SETUP_TXN_CONFIG=""
_SETUP_TXN_MUSTER=""
_SETUP_NOTICES=()

_setup_notice() { _SETUP_NOTICES[${#_SETUP_NOTICES[@]}]="$1"; }

_setup_print_notices() {
  (( ${#_SETUP_NOTICES[@]} == 0 )) && return 0
  echo ""
  local n
  for n in "${_SETUP_NOTICES[@]}"; do
    printf '  %bi%b %s\n' "${ACCENT}" "${RESET}" "$n"
  done
  _SETUP_NOTICES=()
}

_setup_cksum() { cksum < "$1" 2>/dev/null | awk '{print $1"-"$2}'; }

_setup_txn_on_interrupt() {
  _setup_txn_abort
  echo ""
  printf '  %b!%b Setup cancelled — nothing was written.\n' "${YELLOW}" "${RESET}"
  cleanup_term 2>/dev/null || true
  exit 130
}

_setup_txn_begin() {
  local project="$1"
  _SETUP_TXN_PROJECT="$project"
  _SETUP_TXN_DIR=$(mktemp -d "${project}/.muster-setup.XXXXXX" 2>/dev/null) || {
    err "Can't write to ${project} (permission denied?)"
    return 1
  }
  _SETUP_TXN_CONFIG="${_SETUP_TXN_DIR}/muster.json"
  _SETUP_TXN_MUSTER="${_SETUP_TXN_DIR}/.muster"
  mkdir -p "${_SETUP_TXN_MUSTER}/hooks"
  trap '_setup_txn_on_interrupt' INT TERM
  return 0
}

# Test hook: simulate Ctrl+C at a point inside the transaction
_setup_txn_checkpoint() {
  if [[ -n "${MUSTER_TEST_SETUP_INTERRUPT:-}" && "$MUSTER_TEST_SETUP_INTERRUPT" == "$1" ]]; then
    kill -INT $$
    sleep 1
  fi
}

_setup_txn_abort() {
  if [[ -n "$_SETUP_TXN_DIR" && -d "$_SETUP_TXN_DIR" && "$_SETUP_TXN_DIR" == *"/.muster-setup."* ]]; then
    rm -rf "${_SETUP_TXN_DIR:?}"
  fi
  _SETUP_TXN_DIR=""
  trap '_on_sigint' INT
  trap - TERM
}

# Recorded checksum of the hook muster last generated (echo), empty if none
_setup_recorded_hash() {
  local hashes="$1" key="$2"
  [[ -f "$hashes" ]] || return 0
  awk -v k="$key" '$1 == k {print $2}' "$hashes" | tail -1
}

# Merge staged hooks into the project, honouring edits. Prints nothing;
# collects notices.
_setup_txn_merge_hooks() {
  local stage_hooks="${_SETUP_TXN_MUSTER}/hooks"
  local dest_root="${_SETUP_TXN_PROJECT}/.muster"
  local hashes="${dest_root}/.template_hashes"
  local new_hashes="${_SETUP_TXN_DIR}/.template_hashes.new"
  local backup_dir="" kept="" backed="" f
  : > "$new_hashes"
  [[ -f "$hashes" ]] && cp "$hashes" "$new_hashes"

  for f in "$stage_hooks"/*/*; do
    [[ -f "$f" ]] || continue
    local rel="${f#"${stage_hooks}"/}"           # svc/deploy.sh
    local dest="${dest_root}/hooks/${rel}"
    local gen_hash cur_hash rec_hash
    gen_hash=$(_setup_cksum "$f")
    if [[ -f "$dest" ]]; then
      cur_hash=$(_setup_cksum "$dest")
      rec_hash=$(_setup_recorded_hash "$hashes" "$rel")
      local edited=false
      if [[ "$cur_hash" != "$gen_hash" ]]; then
        # Unedited = still exactly what muster generated last time.
        # No record (older muster): anything different counts as edited.
        if [[ -z "$rec_hash" || "$cur_hash" != "$rec_hash" ]]; then
          edited=true
        fi
      fi
      if [[ "$edited" == "true" ]]; then
        if [[ "$_SETUP_TXN_MODE" == "update" ]]; then
          kept="${kept}${kept:+, }${rel}"
          # Strategy switch: leave the new template next to the edited hook
          if [[ -n "${_SETUP_STRATEGY_NEW:-}" ]]; then
            cp -p "$f" "${dest}.strategy-new" 2>/dev/null && \
              _setup_notice "Your edited ${rel} was kept; the strategy template is in ${rel}.strategy-new (wire in MUSTER_TARGET_DEPLOYMENT and MUSTER_IMAGE_TAG)"
          fi
          continue
        fi
        if [[ -z "$backup_dir" ]]; then
          backup_dir="${dest_root}/backup-$(date +%Y%m%d-%H%M%S)"
        fi
        mkdir -p "${backup_dir}/$(dirname "$rel")"
        cp -p "$dest" "${backup_dir}/${rel}"
        backed="${backed}${backed:+, }${rel}"
      fi
    fi
    mkdir -p "$(dirname "$dest")"
    [[ -f "$dest" && ! -w "$dest" ]] && chmod u+w "$dest" 2>/dev/null
    cp -p "$f" "${dest}.tmp.$$" && mv "${dest}.tmp.$$" "$dest"
    # Update the generated-hash record
    awk -v k="$rel" '$1 != k' "$new_hashes" > "${new_hashes}.t" && mv "${new_hashes}.t" "$new_hashes"
    printf '%s %s\n' "$rel" "$gen_hash" >> "$new_hashes"
  done
  mv "$new_hashes" "$hashes"
  [[ -n "$kept" ]] && _setup_notice "Kept your edited hooks: ${kept}"
  [[ -n "$backed" ]] && _setup_notice "Backed up your edited hooks to ${backup_dir#"${_SETUP_TXN_PROJECT}"/}/ before regenerating: ${backed}"
  return 0
}

# Merge a staged muster.json with the existing one (update mode).
# Existing services keep their config; new ones are added (infra first in
# deploy_order); services no longer detected are kept and reported.
_setup_txn_merge_config() {
  local old="$1" new="$2" out="$3"
  if ! has_cmd jq; then
    cp "$new" "$out"
    return 0
  fi
  local added kept_missing
  added=$(jq -r --slurpfile o "$old" '(.services // {}) | keys[] | . as $k | select(($o[0].services // {}) | has($k) | not)' "$new" 2>/dev/null)
  kept_missing=$(jq -r --slurpfile n "$new" '(.services // {}) | keys[] | . as $k | select(($n[0].services // {}) | has($k) | not)' "$old" 2>/dev/null)
  local infra_new="[]" app_new="[]" s
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if declare -F _is_infra_service >/dev/null 2>&1 && _is_infra_service "$s"; then
      infra_new=$(printf '%s' "$infra_new" | jq -c --arg s "$s" '. + [$s]')
    else
      app_new=$(printf '%s' "$app_new" | jq -c --arg s "$s" '. + [$s]')
    fi
  done <<< "$added"
  jq --slurpfile n "$new" --argjson infra "$infra_new" --argjson app "$app_new" '
    . as $o
    | .services = (($o.services // {}) + (($n[0].services // {}) | with_entries(select(.key as $k | ($o.services // {}) | has($k) | not))))
    | .deploy_order = ($infra + (($o.deploy_order // []) - $infra - $app) + $app)
    | .project = ($o.project // $n[0].project)
  ' "$old" > "$out" || return 1
  if [[ -n "$added" ]]; then
    _setup_notice "Added new service$( [[ "$added" == *$'\n'* ]] && echo s): $(printf '%s' "$added" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')"
  else
    _setup_notice "No new services found — kept your existing muster.json as is."
  fi
  if [[ -n "$kept_missing" ]]; then
    _setup_notice "Not detected anymore but kept (remove by hand if gone): $(printf '%s' "$kept_missing" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')"
  fi
  return 0
}

# Hooks generated for compose v2 but only docker-compose (v1) is installed?
_setup_txn_adapt_compose() {
  has_cmd docker || return 0
  docker compose version >/dev/null 2>&1 && return 0
  has_cmd docker-compose || return 0
  local f changed=false
  for f in "${_SETUP_TXN_MUSTER}/hooks"/*/*.sh; do
    [[ -f "$f" ]] || continue
    if grep -q 'docker compose ' "$f" 2>/dev/null; then
      sed 's/docker compose /docker-compose /g' "$f" > "${f}.t" && mv "${f}.t" "$f"
      chmod 755 "$f"
      changed=true
    fi
  done
  [[ "$changed" == "true" ]] && _setup_notice "Only docker-compose (v1) is installed, so hooks use 'docker-compose' instead of 'docker compose'."
  return 0
}

_setup_txn_commit() {
  [[ -n "$_SETUP_TXN_DIR" && -d "$_SETUP_TXN_DIR" ]] || { err "Setup staging area missing"; return 1; }
  local project="$_SETUP_TXN_PROJECT"
  [[ -f "$_SETUP_TXN_CONFIG" ]] || { err "Setup didn't produce a config"; _setup_txn_abort; return 1; }

  _setup_txn_checkpoint "before-commit"
  _setup_txn_adapt_compose

  # Ignore Ctrl+C during the few renames that make up the commit
  trap '' INT TERM
  mkdir -p "${project}/.muster/hooks" "${project}/.muster/logs" "${project}/.muster/skills"
  [[ -d "${_SETUP_TXN_MUSTER}/pids" ]] && mkdir -p "${project}/.muster/pids"

  # Config first into a temp file in the project, then rename
  local existing=""
  [[ -f "${project}/muster.json" ]] && existing="${project}/muster.json"
  [[ -z "$existing" && -f "${project}/deploy.json" ]] && existing="${project}/deploy.json"
  local cfg_tmp="${project}/.muster.json.tmp.$$"
  if [[ "$_SETUP_TXN_MODE" == "update" && -n "$existing" ]]; then
    if ! _setup_txn_merge_config "$existing" "$_SETUP_TXN_CONFIG" "$cfg_tmp"; then
      rm -f "$cfg_tmp"
      _setup_txn_abort
      err "Couldn't merge with the existing $(basename "$existing") — nothing was changed."
      return 1
    fi
  else
    cp "$_SETUP_TXN_CONFIG" "$cfg_tmp"
  fi

  _setup_txn_merge_hooks
  mv "$cfg_tmp" "${project}/muster.json"

  _setup_txn_abort
  return 0
}

# ── Service names → config keys ──
# Sanitizes names and resolves collisions in the caller's selected_services
# array (bash dynamic scoping), recording notices for anything changed.
_setup_dedupe_services() {
  local i=0 seen=" " out=()
  while (( i < ${#selected_services[@]} )); do
    local svc="${selected_services[$i]}" key
    key=$(_svc_to_key "$svc")
    if [[ -z "$key" ]]; then
      key="service"
      _setup_notice "Service '${svc}' has no usable characters for a key — using '${key}'."
      svc="$key"
    fi
    if [[ "$seen" == *" ${key} "* ]]; then
      local n=2
      while [[ "$seen" == *" ${key}_${n} "* ]]; do n=$(( n + 1 )); done
      _setup_notice "Two services map to the key '${key}' — renamed '${svc}' to '${key}_${n}'."
      key="${key}_${n}"
      svc="$key"
    elif [[ "$key" != "$svc" ]]; then
      _setup_notice "Service '${svc}' is saved as '${key}' (keys use lowercase letters, digits and _)."
    fi
    seen="${seen}${key} "
    out[${#out[@]}]="$svc"
    i=$(( i + 1 ))
  done
  if (( ${#out[@]} > 0 )); then
    selected_services=("${out[@]}")
  fi
}

# ── Tools for a stack: missing / installed-but-not-running ──
# Collects notices; in a TTY offers to run the install/start command.
_setup_check_tools() {
  local stack="$1" interactive="${2:-false}"
  source "$MUSTER_ROOT/lib/core/hints.sh"
  local need=""
  case "$stack" in
    docker|compose) need="docker" ;;
    k8s) need="kubectl docker" ;;
    dev) need="" ;;
  esac
  local t
  for t in $need; do
    if ! has_cmd "$t"; then
      local ic
      ic=$(_hints_install_cmd "$t")
      [[ "$ic" == \#* ]] && ic=""
      if [[ -n "$ic" ]]; then
        _setup_notice "${t} isn't installed — this stack needs it. Install: ${ic}"
        if [[ "$interactive" == "true" && -t 0 ]]; then
          # shellcheck disable=SC2034
          HINT_FIX_CMD="$ic" HINT_FIX_LABEL="Install ${t}"
          printf '\n  %b!%b %s isn'\''t installed — the %s stack needs it.\n' "${YELLOW}" "${RESET}" "$t" "$stack"
          hints_run_fix || true
        fi
      else
        _setup_notice "${t} isn't installed — this stack needs it."
      fi
    fi
  done
  if [[ " $need " == *" docker "* ]] && has_cmd docker && ! _run_with_timeout 8 docker info >/dev/null 2>&1; then
    local sc
    sc=$(_hints_docker_start_cmd)
    _setup_notice "Docker is installed but not running${sc:+ — start it with: ${sc}}. Setup continues; deploys need it running."
  fi
  if (( ${#_SCAN_EXTRA_COMPOSE[@]} > 0 )); then
    local main_cf
    main_cf=$(scan_get_compose_file 2>/dev/null)
    _setup_notice "Also found ${_SCAN_EXTRA_COMPOSE[*]} — hooks use ${main_cf:-docker-compose.yml}. To layer files, set COMPOSE_FILE in .env (e.g. COMPOSE_FILE=${main_cf:-docker-compose.yml}:${_SCAN_EXTRA_COMPOSE[0]})."
  fi
  if [[ "$stack" == "compose" ]] && has_cmd docker && ! docker compose version >/dev/null 2>&1 && ! has_cmd docker-compose; then
    _setup_notice "Docker Compose isn't installed (neither 'docker compose' nor 'docker-compose')."
  fi
  return 0
}

# ── Health check verification ──
# Probe a health check once. If nothing answers but the service is running on
# another port, offer that port (sets _SVH_PORT). Silent when it can't tell.
# Args: svc type port [endpoint] [interactive]
_setup_verify_health() {
  local svc="$1" type="$2" port="$3" endpoint="${4:-/health}" interactive="${5:-false}"
  _SVH_PORT="$port"
  [[ "$type" == "http" || "$type" == "tcp" ]] || return 0
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  source "$MUSTER_ROOT/lib/core/hints.sh"
  if _hints_port_listening "$port"; then
    if [[ "$type" == "http" ]] && has_cmd curl; then
      local code
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}${endpoint}" 2>/dev/null)
      case "$code" in
        2??|3??) printf '  %b✓%b Health check answered (HTTP %s)\n' "${GREEN}" "${RESET}" "$code" ;;
        4??) _setup_notice "${svc}: ${endpoint} on port ${port} answered HTTP ${code} — check the health path." ;;
      esac
    else
      printf '  %b✓%b Port %s is answering\n' "${GREEN}" "${RESET}" "$port"
    fi
    return 0
  fi
  # Not listening. Is a container for this service published elsewhere?
  local other=""
  if has_cmd docker; then
    other=$(_run_with_timeout 5 docker ps --filter "name=${svc}" --format '{{.Ports}}' 2>/dev/null \
      | grep -Eo '(0\.0\.0\.0|\[::\]|127\.0\.0\.1):[0-9]+->' | head -1 | sed -E 's/.*:([0-9]+)->/\1/' || true)
  fi
  if [[ -n "$other" && "$other" != "$port" ]]; then
    if [[ "$interactive" == "true" && -t 0 ]]; then
      menu_select "Nothing answers on port ${port}, but ${svc} is running on port ${other}. Use ${other}?" "Use port ${other}" "Keep ${port}"
      [[ "$MENU_RESULT" == "Use port ${other}" ]] && _SVH_PORT="$other"
    else
      _setup_notice "${svc}: nothing answers on port ${port}, but a ${svc} container publishes port ${other} — check the health port."
    fi
  fi
  return 0
}

# Read a port with a default, re-asking until it's a number 1-65535.
# Args: prompt default   Sets _SRP_PORT
_setup_read_port() {
  local prompt="$1" def="$2" ans
  while true; do
    printf '  %b>%b %s [%s]: ' "${ACCENT}" "${RESET}" "$prompt" "$def"
    IFS= read -r ans || ans=""
    ans="${ans:-$def}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= 65535 )); then
      _SRP_PORT="$ans"
      return 0
    fi
    printf '  %b!%b "%s" isn'\''t a port — use a number from 1 to 65535.\n' "${YELLOW}" "${RESET}" "$ans"
  done
}
