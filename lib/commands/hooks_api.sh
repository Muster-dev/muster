#!/usr/bin/env bash
# muster/lib/commands/hooks_api.sh — Machine-readable hook approval
#
#   muster hooks status [--json]              what's approved on this machine
#   muster hooks approve --yes [svc…] [--json] approve without a prompt
#
# Frontends use these instead of reading ~/.muster/trust directly.
# Shapes are documented in docs/ENGINE-API.md.

source "$MUSTER_ROOT/lib/core/engine.sh"
source "$MUSTER_ROOT/lib/core/hook_security.sh"

# Dangerous-pattern descriptions found in a hook file, one per line
# ("line N: description"). Prints nothing when clean or bypassed.
_hooks_api_dangers() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  [[ "${MUSTER_HOOK_UNSAFE:-}" == "1" ]] && return 0
  local line n=0 pi entry
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$(( n + 1 ))
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    pi=0
    while (( pi < ${#_HOOK_DANGER_PATTERNS[@]} )); do
      entry="${_HOOK_DANGER_PATTERNS[$pi]}"
      if printf '%s' "$line" | grep -qE "${entry%|*}" 2>/dev/null; then
        printf 'line %d: %s\n' "$n" "${entry##*|}"
      fi
      pi=$(( pi + 1 ))
    done
  done < "$f"
}

# Manifest value for a key (sha256 / generated_at), empty when absent
_hooks_api_manifest_get() {
  local manifest="$1" key="$2" field="$3"
  [[ -f "$manifest" ]] && has_cmd jq || return 0
  jq -r --arg k "$key" --arg f "$field" '.[$k][$f] // empty' "$manifest" 2>/dev/null
}

# Approval state of one manifest key into _HOOKS_API_STATE / _HOOKS_API_AT.
# Call directly (not in $(...)). Args: manifest fresh key path
_HOOKS_API_STATE=""
_HOOKS_API_AT=""
_hooks_api_state() {
  local manifest="$1" fresh="$2" key="$3" path="$4"
  local expected actual
  _HOOKS_API_STATE="approved"
  _HOOKS_API_AT=$(_hooks_api_manifest_get "$manifest" "$key" "generated_at")
  expected=$(_hooks_api_manifest_get "$manifest" "$key" "sha256")
  if [[ "$fresh" == "true" ]]; then
    _HOOKS_API_STATE="new"; _HOOKS_API_AT=""
  elif [[ ! -f "$path" ]]; then
    _HOOKS_API_STATE="missing"
  elif [[ -z "$expected" ]]; then
    _HOOKS_API_STATE="new"
  else
    actual=$(shasum -a 256 "$path" 2>/dev/null | cut -d' ' -f1)
    [[ "$actual" != "$expected" ]] && _HOOKS_API_STATE="changed"
  fi
  return 0
}

# One file entry as JSON, for the state _hooks_api_state just computed.
# Args: project_dir key path service file
_hooks_api_entry() {
  local project_dir="$1" key="$2" path="$3" svc="$4" file="$5"
  local state="$_HOOKS_API_STATE" approved_at="$_HOOKS_API_AT"
  local rel="${path#"${project_dir}"/}"
  local copy
  copy="${_HOOK_TRUST_DIR}/approved/${key}"
  [[ -f "$copy" ]] || copy=""
  local dangers="[]"
  if [[ "$state" != "missing" && "$key" != _config/* ]]; then
    local d
    d=$(_hooks_api_dangers "$path")
    [[ -n "$d" ]] && dangers=$(printf '%s\n' "$d" | _json_lines_array)
  fi
  printf '{"service":%s,"file":%s,"key":%s,"path":%s,"state":"%s","approved_at":%s,"approved_copy":%s,"dangerous":%s}' \
    "$(_json_str_or_null "$svc")" "$(_json_str "$file")" "$(_json_str "$key")" "$(_json_str "$rel")" "$state" \
    "$(_json_str_or_null "$approved_at")" "$(_json_str_or_null "$copy")" "$dangers"
}

# muster hooks status [--json]
_hooks_cmd_status() {
  local json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=true; shift ;;
      -h|--help)
        echo "Usage: muster hooks status [--json]"
        echo ""
        echo "Show which hook files (and muster.json / .env) are approved on this"
        echo "machine: approved, changed, new, or missing."
        return 0
        ;;
      *) err "Unknown argument: $1"; return 1 ;;
    esac
  done

  if [[ "$json" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
  fi
  if ! find_config &>/dev/null; then
    if [[ "$json" == "true" ]]; then
      _json_error "no_project" "No muster project found. Run 'muster setup' first."
    else
      err "No muster project found. Run 'muster setup' first."
    fi
    return 1
  fi
  load_config
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  _hook_trust_resolve "$project_dir"
  local manifest="${_HOOK_TRUST_DIR}/hooks.manifest"

  local sig="none" fresh=false
  if [[ -f "$manifest" ]]; then
    _hook_manifest_verify_sig "$manifest"
    case $? in
      0) sig="valid" ;;
      1) sig="invalid"; fresh=true ;;
      *) sig="unsigned" ;;
    esac
  else
    fresh=true
  fi
  local security=true
  [[ "$(global_config_get "hook_security" 2>/dev/null || true)" == "off" ]] && security=false

  local files="" pending="" all_ok=true seen=" "
  local hooks_dir="${project_dir}/.muster/hooks"
  local svc_dir svc f key
  local human=()
  for svc_dir in "${hooks_dir}"/*/; do
    [[ -d "$svc_dir" ]] || continue
    svc=$(basename "$svc_dir")
    [[ "$svc" == "logs" || "$svc" == "pids" ]] && continue
    for f in "${svc_dir}"*.sh "${svc_dir}"justfile; do
      [[ -f "$f" ]] || continue
      key="${svc}/$(basename "$f")"
      seen="${seen}${key} "
      [[ -n "$files" ]] && files="${files},"
      _hooks_api_state "$manifest" "$fresh" "$key" "$f"
      files="${files}$(_hooks_api_entry "$project_dir" "$key" "$f" "$svc" "$(basename "$f")")"
      human[${#human[@]}]="${_HOOKS_API_STATE}|${key}"
      if [[ "$_HOOKS_API_STATE" != "approved" ]]; then
        all_ok=false
        [[ -n "$pending" ]] && pending="${pending},"
        pending="${pending}$(_json_str "$key")"
      fi
    done
  done
  # Hooks approved earlier whose files are gone
  if [[ "$fresh" == "false" ]] && has_cmd jq; then
    while IFS= read -r key; do
      [[ -z "$key" || "$key" == _config/* ]] && continue
      [[ "$seen" == *" ${key} "* ]] && continue
      [[ -n "$files" ]] && files="${files},"
      _hooks_api_state "$manifest" "$fresh" "$key" "${hooks_dir}/${key}"
      files="${files}$(_hooks_api_entry "$project_dir" "$key" "${hooks_dir}/${key}" "${key%%/*}" "${key#*/}")"
      human[${#human[@]}]="missing|${key}"
    done < <(jq -r 'keys[]' "$manifest" 2>/dev/null)
  fi

  # muster.json (or deploy.json) and .env
  local cfg cfg_json="null" env_json="null"
  cfg=$(_hook_config_file "$project_dir")
  if [[ -n "$cfg" ]]; then
    _hooks_api_state "$manifest" "$fresh" "_config/$(basename "$cfg")" "$cfg"
    cfg_json=$(_hooks_api_entry "$project_dir" "_config/$(basename "$cfg")" "$cfg" "" "$(basename "$cfg")")
    human[${#human[@]}]="${_HOOKS_API_STATE}|$(basename "$cfg")"
    if [[ "$_HOOKS_API_STATE" != "approved" ]]; then
      all_ok=false
      [[ -n "$pending" ]] && pending="${pending},"
      pending="${pending}$(_json_str "_config/$(basename "$cfg")")"
    fi
  fi
  local env_tracked=""
  env_tracked=$(_hooks_api_manifest_get "$manifest" "_config/.env" "sha256")
  if [[ -f "${project_dir}/.env" || ( "$fresh" == "false" && -n "$env_tracked" ) ]]; then
    _hooks_api_state "$manifest" "$fresh" "_config/.env" "${project_dir}/.env"
    env_json=$(_hooks_api_entry "$project_dir" "_config/.env" "${project_dir}/.env" "" ".env")
    human[${#human[@]}]="${_HOOKS_API_STATE}|.env"
    if [[ "$_HOOKS_API_STATE" != "approved" ]]; then
      all_ok=false
      [[ -n "$pending" ]] && pending="${pending},"
      pending="${pending}\"_config/.env\""
    fi
  fi

  if [[ "$json" == "true" ]]; then
    printf '{"approved":%s,"security_enabled":%s,"trust_dir":%s,"manifest":%s,"signature":"%s","files":[%s],"config":%s,"env":%s,"pending":[%s]}\n' \
      "$all_ok" "$security" "$(_json_str "$_HOOK_TRUST_DIR")" "$(_json_str_or_null "$( [[ -f "$manifest" ]] && printf '%s' "$manifest")")" \
      "$sig" "$files" "$cfg_json" "$env_json" "$pending"
    return 0
  fi

  echo ""
  printf '%b\n' "  ${BOLD}Hook approval on this machine${RESET}"
  echo ""
  local e st k
  for e in ${human[@]+"${human[@]}"}; do
    st="${e%%|*}"; k="${e#*|}"
    case "$st" in
      approved) printf '  %b✓%b %s\n' "$GREEN" "$RESET" "$k" ;;
      changed) printf '  %b✗%b %s %b— changed since approval%b\n' "$RED" "$RESET" "$k" "$DIM" "$RESET" ;;
      missing) printf '  %b!%b %s %b— approved but missing%b\n' "$YELLOW" "$RESET" "$k" "$DIM" "$RESET" ;;
      *) printf '  %b!%b %s %b— not approved yet%b\n' "$YELLOW" "$RESET" "$k" "$DIM" "$RESET" ;;
    esac
  done
  echo ""
  if [[ "$all_ok" == "true" ]]; then
    ok "Everything is approved"
  else
    printf '  Review them, then run: muster hooks approve\n'
  fi
  echo ""
}

# muster hooks approve --yes [service…] [--json]
# Non-interactive approval: no prompt and no sudo; --yes is the explicit
# confirmation. Refuses hooks with dangerous commands (MUSTER_HOOK_UNSAFE=1
# bypasses, as everywhere else).
_hooks_cmd_approve_api() {
  local json=false yes=false
  local services=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=true; shift ;;
      --yes|-y) yes=true; shift ;;
      -*) err "Unknown flag: $1"; return 1 ;;
      *) services[${#services[@]}]="$1"; shift ;;
    esac
  done

  _hooks_api_fail() {
    if [[ "$json" == "true" ]]; then
      _json_error "$1" "$2"
    else
      err "$2"
    fi
  }

  if [[ "$json" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "deploy" || return 1
  fi
  if [[ "$yes" != "true" ]]; then
    _hooks_api_fail "confirmation_required" "Pass --yes to approve without a prompt: muster hooks approve --yes [service...]"
    return 1
  fi
  if ! find_config &>/dev/null; then
    _hooks_api_fail "no_project" "No muster project found. Run 'muster setup' first."
    return 1
  fi
  load_config
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local hooks_dir="${project_dir}/.muster/hooks"

  local s
  for s in ${services[@]+"${services[@]}"}; do
    if [[ -z "$s" || "$s" == */* || "$s" == *..* || ! -d "${hooks_dir}/${s}" ]]; then
      _hooks_api_fail "unknown_service" "No hooks for service: ${s}"
      return 1
    fi
  done
  local scope=()
  if (( ${#services[@]} > 0 )); then
    scope=("${services[@]}")
  else
    local d
    for d in "${hooks_dir}"/*/; do
      [[ -d "$d" ]] || continue
      s=$(basename "$d")
      [[ "$s" == "logs" || "$s" == "pids" ]] && continue
      scope[${#scope[@]}]="$s"
    done
  fi

  # Refuse dangerous hooks
  local dangers="" svc f d_lines
  for svc in ${scope[@]+"${scope[@]}"}; do
    for f in "${hooks_dir}/${svc}"/*.sh; do
      [[ -f "$f" ]] || continue
      d_lines=$(_hooks_api_dangers "$f")
      [[ -z "$d_lines" ]] && continue
      while IFS= read -r s; do
        [[ -n "$dangers" ]] && dangers="${dangers},"
        dangers="${dangers}{\"key\":$(_json_str "${svc}/$(basename "$f")"),\"issue\":$(_json_str "$s")}"
      done <<< "$d_lines"
    done
  done
  if [[ -n "$dangers" ]]; then
    if [[ "$json" == "true" ]]; then
      printf '{"error":"dangerous_hooks","message":"Cannot approve: dangerous commands found (fix them, or set MUSTER_HOOK_UNSAFE=1)","files":[%s]}\n' "$dangers" >&2
    else
      err "Cannot approve — dangerous commands found"
      printf '  %bFix the hooks first, or set MUSTER_HOOK_UNSAFE=1 to bypass%b\n' "${DIM}" "${RESET}"
    fi
    return 1
  fi

  # What's pending now (for the report), then approve exactly that
  _hook_trust_pending "$project_dir" ${scope[@]+"${scope[@]}"}
  local approved="" i=0 e k
  local env_changed=false
  if (( ${#services[@]} == 0 )); then
    _env_integrity_check "$project_dir"
    local erc=$?
    if [[ -f "${project_dir}/.env" ]] && { (( erc != 0 )) || [[ "$_HOOK_PENDING_FRESH" == "true" ]]; }; then
      env_changed=true
    fi
  fi
  while (( i < ${#_HOOK_PENDING[@]} )); do
    e="${_HOOK_PENDING[$i]}"; k="${e#*|}"; k="${k%%|*}"
    [[ -n "$approved" ]] && approved="${approved},"
    approved="${approved}{\"key\":$(_json_str "$k"),\"was\":$(_json_str "${e%%|*}")}"
    i=$(( i + 1 ))
  done
  if [[ "$env_changed" == "true" ]]; then
    [[ -n "$approved" ]] && approved="${approved},"
    approved="${approved}{\"key\":\"_config/.env\",\"was\":\"changed\"}"
  fi
  local count=$i
  [[ "$env_changed" == "true" ]] && count=$(( count + 1 ))

  if (( ${#services[@]} == 0 )); then
    _hook_manifest_approve "$project_dir" ""
  else
    _hook_trust_approve_pending "$project_dir" "${scope[@]}"
  fi

  if [[ "$json" == "true" ]]; then
    local svc_json="" sv
    for sv in ${scope[@]+"${scope[@]}"}; do
      [[ -n "$svc_json" ]] && svc_json="${svc_json},"
      svc_json="${svc_json}$(_json_str "$sv")"
    done
    printf '{"ok":true,"count":%d,"approved":[%s],"services":[%s],"trust_dir":%s}\n' \
      "$count" "$approved" "$svc_json" "$(_json_str "$_HOOK_TRUST_DIR")"
  else
    if (( count == 0 )); then
      ok "Nothing to approve — everything was already approved"
    else
      i=0
      while (( i < ${#_HOOK_PENDING[@]} )); do
        e="${_HOOK_PENDING[$i]}"; k="${e#*|}"; k="${k%%|*}"
        printf '    %s %b(%s)%b\n' "${k#_config/}" "$DIM" "${e%%|*}" "$RESET"
        i=$(( i + 1 ))
      done
      [[ "$env_changed" == "true" ]] && printf '    .env\n'
      ok "Approved ${count} file(s) on this machine"
    fi
  fi
  return 0
}
