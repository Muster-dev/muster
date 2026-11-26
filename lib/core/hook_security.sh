#!/usr/bin/env bash
# muster/lib/core/hook_security.sh — Hook integrity, scanning, and lockdown

# ── Dangerous command patterns ──
# Each entry: "regex|description"
_HOOK_DANGER_PATTERNS=(
  'rm -rf /[^a-zA-Z]|Filesystem destruction (rm -rf /)'
  'rm -rf /\*|Filesystem destruction (rm -rf /*)'
  'rm -rf ~|Home directory destruction'
  'rm -rf \$HOME|Home directory destruction'
  'rm -rf "\$HOME"|Home directory destruction'
  'mkfs\b|Disk format command'
  'dd if=|Raw disk write'
  '> /dev/sd|Disk overwrite'
  '> /dev/nvme|Disk overwrite'
  'curl.*\|.*bash|Remote code execution (curl pipe bash)'
  'wget.*\|.*bash|Remote code execution (wget pipe bash)'
  'curl.*\|.*sh\b|Remote code execution (curl pipe sh)'
  'wget.*\|.*sh\b|Remote code execution (wget pipe sh)'
  'chmod 777|Insecure permissions (world-writable)'
  'nc -l|Reverse shell listener'
  'ncat -l|Reverse shell listener'
)

# ── Manifest signing key ──
# Machine-local secret prevents attacker from editing both hook + manifest

_hook_signing_key_file() {
  echo "$HOME/.muster/.hook_signing_key"
}

_hook_ensure_signing_key() {
  local key_file
  key_file=$(_hook_signing_key_file)
  if [[ ! -f "$key_file" ]]; then
    mkdir -p "$(dirname "$key_file")"
    # Generate a random 64-char hex key
    if has_cmd openssl; then
      openssl rand -hex 32 > "$key_file" 2>/dev/null
    elif [[ -r /dev/urandom ]]; then
      head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$key_file"
    else
      # Last resort: use date + PID + RANDOM
      printf '%s%s%s' "$(date +%s%N 2>/dev/null || date +%s)" "$$" "$RANDOM$RANDOM$RANDOM" | shasum -a 256 | cut -d' ' -f1 > "$key_file"
    fi
    chmod 600 "$key_file"
  fi
}

# HMAC-sign a manifest file — writes signature to .manifest.sig
_hook_manifest_sign() {
  local manifest_file="$1"
  local sig_file="${manifest_file}.sig"

  _hook_ensure_signing_key
  local key_file
  key_file=$(_hook_signing_key_file)
  [[ ! -f "$key_file" ]] && return 0

  local key
  key=$(cat "$key_file" 2>/dev/null)
  [[ -z "$key" ]] && return 0

  if has_cmd openssl; then
    openssl dgst -sha256 -hmac "$key" -hex "$manifest_file" 2>/dev/null | awk '{print $NF}' > "$sig_file"
  else
    # Fallback: hash key + manifest content together
    printf '%s' "$key" | cat - "$manifest_file" | shasum -a 256 | cut -d' ' -f1 > "$sig_file"
  fi
  chmod 600 "$sig_file"
}

# Verify manifest signature
# Returns: 0=valid, 1=invalid, 2=no signature
_hook_manifest_verify_sig() {
  local manifest_file="$1"
  local sig_file="${manifest_file}.sig"

  [[ ! -f "$sig_file" ]] && return 2
  [[ ! -f "$manifest_file" ]] && return 1

  local key_file
  key_file=$(_hook_signing_key_file)
  [[ ! -f "$key_file" ]] && return 2

  local key
  key=$(cat "$key_file" 2>/dev/null)
  [[ -z "$key" ]] && return 2

  local expected
  expected=$(cat "$sig_file" 2>/dev/null)
  [[ -z "$expected" ]] && return 2

  local actual
  if has_cmd openssl; then
    actual=$(openssl dgst -sha256 -hmac "$key" -hex "$manifest_file" 2>/dev/null | awk '{print $NF}')
  else
    actual=$(printf '%s' "$key" | cat - "$manifest_file" | shasum -a 256 | cut -d' ' -f1)
  fi

  if [[ "$actual" == "$expected" ]]; then
    return 0
  else
    return 1
  fi
}

# ── Per-user trust store ──
# Approvals are per machine (HMAC key in ~/.muster/.hook_signing_key), so the
# manifest, its signature and approved copies of each hook live outside the
# project, keyed by the project's absolute path — like direnv's allow list:
#   ~/.muster/trust/<sha256-of-project-path>/
#     hooks.manifest      JSON: key → sha256/size/generated_at
#     hooks.manifest.sig  HMAC-SHA256 of hooks.manifest
#     approved/<svc>/<hook>, approved/_config/<file>   copies for diffs
#     project             the project path (informational)

_HOOK_TRUST_PD=""
_HOOK_TRUST_DIR=""

# Resolve the trust dir for a project into _HOOK_TRUST_DIR (cached per process).
# Also migrates a legacy in-repo manifest the first time a project is seen.
# Call directly (not in $(...)) so the cache sticks.
_hook_trust_resolve() {
  local project_dir="$1"
  if [[ -n "$_HOOK_TRUST_DIR" && "$_HOOK_TRUST_PD" == "$project_dir" ]]; then
    return 0
  fi
  local abs
  abs=$(cd "$project_dir" 2>/dev/null && pwd -P) || abs="$project_dir"
  local id
  id=$(printf '%s' "$abs" | shasum -a 256 2>/dev/null | cut -c1-64)
  _HOOK_TRUST_PD="$project_dir"
  _HOOK_TRUST_DIR="$HOME/.muster/trust/${id}"
  _hook_trust_migrate "$project_dir"
}

# Print the trust-store manifest path for a project
_hook_manifest_path() {
  _hook_trust_resolve "$1"
  printf '%s\n' "${_HOOK_TRUST_DIR}/hooks.manifest"
}

# True when this machine has approved hooks for the project
_hook_trust_exists() {
  _hook_trust_resolve "$1"
  [[ -f "${_HOOK_TRUST_DIR}/hooks.manifest" ]]
}

_hook_trust_init_dir() {
  mkdir -p "${_HOOK_TRUST_DIR}/approved"
  chmod 700 "$HOME/.muster/trust" "${_HOOK_TRUST_DIR}" 2>/dev/null
  printf '%s\n' "$1" > "${_HOOK_TRUST_DIR}/project"
}

# Path of the approved copy for a manifest key (may not exist)
_hook_approved_copy() {
  _hook_trust_resolve "$1"
  printf '%s\n' "${_HOOK_TRUST_DIR}/approved/$2"
}

# Save a copy of one file as the approved version of a manifest key
_hook_trust_save_copy() {
  local key="$2" src="$3"
  local dst="${_HOOK_TRUST_DIR}/approved/${key}"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst" 2>/dev/null && chmod 600 "$dst" 2>/dev/null
}

# Keep the legacy in-repo manifest out of git (older versions wrote it there)
_hook_trust_ensure_gitignore() {
  local project_dir="$1"
  [[ -d "${project_dir}/.muster" ]] || return 0
  local gi="${project_dir}/.muster/.gitignore"
  local entry
  for entry in hooks.manifest hooks.manifest.sig; do
    if ! grep -qxF "$entry" "$gi" 2>/dev/null; then
      printf '%s\n' "$entry" >> "$gi"
    fi
  done
}

# Import a legacy .muster/hooks.manifest (+ .sig) into the trust store if it
# was signed by this machine's key, then delete the in-repo copies. A manifest
# signed by someone else's key is ignored (it can't vouch for anything here).
_hook_trust_migrate() {
  local project_dir="$1"
  local legacy="${project_dir}/.muster/hooks.manifest"
  [[ -f "$legacy" ]] || return 0

  _hook_trust_ensure_gitignore "$project_dir"

  _hook_manifest_verify_sig "$legacy"
  [[ $? -eq 0 ]] || return 0

  if [[ ! -f "${_HOOK_TRUST_DIR}/hooks.manifest" ]]; then
    _hook_trust_init_dir "$project_dir"
    cp "$legacy" "${_HOOK_TRUST_DIR}/hooks.manifest"
    cp "${legacy}.sig" "${_HOOK_TRUST_DIR}/hooks.manifest.sig"
    chmod 600 "${_HOOK_TRUST_DIR}/hooks.manifest" "${_HOOK_TRUST_DIR}/hooks.manifest.sig" 2>/dev/null

    # Seed approved copies with files that still match the imported manifest
    if has_cmd jq; then
      local key file expected actual
      while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        case "$key" in
          _config/.env) continue ;;
          _config/*) file="${project_dir}/${key#_config/}" ;;
          *) file="${project_dir}/.muster/hooks/${key}" ;;
        esac
        [[ -f "$file" ]] || continue
        expected=$(jq -r --arg k "$key" '.[$k].sha256 // empty' "$legacy" 2>/dev/null)
        actual=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
        [[ -n "$expected" && "$expected" == "$actual" ]] && _hook_trust_save_copy "$project_dir" "$key" "$file"
      done < <(jq -r 'keys[]' "$legacy" 2>/dev/null)
    fi
  fi

  rm -f "$legacy" "${legacy}.sig"
}

# Snapshot current hooks (+ config) as the approved copies
# Args: project_dir [service]
_hook_trust_save_all() {
  local project_dir="$1" service="${2:-}"
  local hooks_dir="${project_dir}/.muster/hooks"
  local svc_dir hook_file svc
  for svc_dir in "${hooks_dir}"/*/; do
    [[ ! -d "$svc_dir" ]] && continue
    svc=$(basename "$svc_dir")
    [[ "$svc" == "logs" || "$svc" == "pids" ]] && continue
    [[ -n "$service" && "$svc" != "$service" ]] && continue
    for hook_file in "${svc_dir}"*.sh "${svc_dir}"justfile; do
      [[ -f "$hook_file" ]] || continue
      _hook_trust_save_copy "$project_dir" "${svc}/$(basename "$hook_file")" "$hook_file"
    done
  done
  local cfg
  cfg=$(_hook_config_file "$project_dir")
  [[ -n "$cfg" ]] && _hook_trust_save_copy "$project_dir" "_config/$(basename "$cfg")" "$cfg"
  return 0
}

# Print the project's config file path (muster.json, legacy deploy.json)
_hook_config_file() {
  local project_dir="$1"
  if [[ -f "${project_dir}/muster.json" ]]; then
    printf '%s\n' "${project_dir}/muster.json"
  elif [[ -f "${project_dir}/deploy.json" ]]; then
    printf '%s\n' "${project_dir}/deploy.json"
  fi
}

# ── Path traversal validation ──

# Validate that a hook path resolves inside the expected hooks directory.
# Prevents service keys like "../../tmp/evil" from escaping .muster/hooks/
# Args: hook_path project_dir
# Returns: 0=safe, 1=traversal detected
_hook_validate_path() {
  local hook_path="$1" project_dir="$2"
  local expected_base="${project_dir}/.muster/hooks"

  # If hooks directory doesn't exist yet (fresh setup), allow
  [[ ! -d "$expected_base" ]] && return 0

  # Resolve to absolute path (macOS bash 3.2 compatible — no readlink -f)
  local resolved="$hook_path"

  # Use cd + pwd to resolve the directory part
  local hook_dir
  hook_dir=$(cd "$(dirname "$hook_path")" 2>/dev/null && pwd) || return 1
  resolved="${hook_dir}/$(basename "$hook_path")"

  local resolved_base
  resolved_base=$(cd "$expected_base" 2>/dev/null && pwd) || return 1

  # Check that resolved path starts with the expected base
  case "$resolved" in
    "${resolved_base}/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Validate a service key doesn't contain path traversal characters
# Args: service_key
# Returns: 0=safe, 1=dangerous
_hook_validate_service_key() {
  local key="$1"
  [[ -z "$key" ]] && return 1
  case "$key" in
    *..*)    return 1 ;;  # Path traversal
    /*)      return 1 ;;  # Absolute path
    *$'\0'*) return 1 ;;  # Null byte injection
  esac
  return 0
}

# ── Manifest ──

# Generate manifest for all hooks + config files in a project
# Args: project_dir
_hook_manifest_generate() {
  local project_dir="$1"
  local hooks_dir="${project_dir}/.muster/hooks"

  [[ ! -d "$hooks_dir" ]] && return 0

  _hook_trust_resolve "$project_dir"
  _hook_trust_init_dir "$project_dir"
  local manifest_file="${_HOOK_TRUST_DIR}/hooks.manifest"

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Build JSON manifest
  local json="{"
  local first=true

  # Include hook files
  local svc_dir
  for svc_dir in "${hooks_dir}"/*/; do
    [[ ! -d "$svc_dir" ]] && continue
    local svc
    svc=$(basename "$svc_dir")
    [[ "$svc" == "logs" || "$svc" == "pids" ]] && continue

    local hook_file
    for hook_file in "${svc_dir}"*.sh "${svc_dir}"justfile; do
      [[ ! -f "$hook_file" ]] && continue
      local hook_name
      hook_name=$(basename "$hook_file")
      local key="${svc}/${hook_name}"

      local sha
      sha=$(shasum -a 256 "$hook_file" 2>/dev/null | cut -d' ' -f1)
      [[ -z "$sha" ]] && continue

      local size
      size=$(wc -c < "$hook_file" | tr -d ' ')

      [[ "$first" == "true" ]] && first=false || json="${json},"
      json="${json}\"${key}\":{\"sha256\":\"${sha}\",\"generated_at\":\"${ts}\",\"size\":${size}}"
    done
  done

  # Include config file (deploy.json or muster.json)
  local config_file=""
  if [[ -f "${project_dir}/muster.json" ]]; then
    config_file="${project_dir}/muster.json"
  elif [[ -f "${project_dir}/deploy.json" ]]; then
    config_file="${project_dir}/deploy.json"
  fi
  if [[ -n "$config_file" ]]; then
    local cfg_sha
    cfg_sha=$(shasum -a 256 "$config_file" 2>/dev/null | cut -d' ' -f1)
    if [[ -n "$cfg_sha" ]]; then
      local cfg_size
      cfg_size=$(wc -c < "$config_file" | tr -d ' ')
      local cfg_key
      cfg_key=$(basename "$config_file")
      [[ "$first" == "true" ]] && first=false || json="${json},"
      json="${json}\"_config/${cfg_key}\":{\"sha256\":\"${cfg_sha}\",\"generated_at\":\"${ts}\",\"size\":${cfg_size}}"
    fi
  fi

  # Include .env if it exists
  if [[ -f "${project_dir}/.env" ]]; then
    local env_sha
    env_sha=$(shasum -a 256 "${project_dir}/.env" 2>/dev/null | cut -d' ' -f1)
    if [[ -n "$env_sha" ]]; then
      local env_size
      env_size=$(wc -c < "${project_dir}/.env" | tr -d ' ')
      [[ "$first" == "true" ]] && first=false || json="${json},"
      json="${json}\"_config/.env\":{\"sha256\":\"${env_sha}\",\"generated_at\":\"${ts}\",\"size\":${env_size}}"
    fi
  fi

  json="${json}}"
  printf '%s\n' "$json" > "$manifest_file"
  chmod 600 "$manifest_file"

  # Sign the manifest
  _hook_manifest_sign "$manifest_file"

  # Approved copies (for diffs) + keep any legacy in-repo manifest out of git
  _hook_trust_save_all "$project_dir"
  _hook_trust_ensure_gitignore "$project_dir"
}

# Verify a single hook against manifest
# Args: hook_path project_dir
# Returns: 0=ok, 1=tampered, 2=not in manifest
_hook_manifest_verify() {
  local hook_path="$1" project_dir="$2"
  _hook_trust_resolve "$project_dir"
  local manifest_file="${_HOOK_TRUST_DIR}/hooks.manifest"

  [[ ! -f "$manifest_file" ]] && return 2

  local hooks_dir="${project_dir}/.muster/hooks"
  # Derive key from path: e.g., /path/.muster/hooks/api/deploy.sh → api/deploy.sh
  local key="${hook_path#${hooks_dir}/}"

  if ! has_cmd jq; then
    # Can't verify without jq — allow
    return 0
  fi

  local expected_sha
  expected_sha=$(jq -r --arg k "$key" '.[$k].sha256 // empty' "$manifest_file" 2>/dev/null)

  [[ -z "$expected_sha" ]] && return 2

  local actual_sha
  actual_sha=$(shasum -a 256 "$hook_path" 2>/dev/null | cut -d' ' -f1)

  if [[ "$actual_sha" == "$expected_sha" ]]; then
    return 0
  else
    return 1
  fi
}

# Approve (re-sign) hooks for a service or all services
# Args: project_dir [service]
_hook_manifest_approve() {
  local project_dir="$1"
  local service="${2:-}"
  local hooks_dir="${project_dir}/.muster/hooks"
  _hook_trust_resolve "$project_dir"
  local manifest_file="${_HOOK_TRUST_DIR}/hooks.manifest"

  # No manifest yet, no jq to patch entries, or the signature no longer
  # matches: regenerate everything from what's on disk.
  local _sig_ok=0
  [[ -f "$manifest_file" ]] && { _hook_manifest_verify_sig "$manifest_file"; _sig_ok=$?; }
  if [[ ! -f "$manifest_file" ]] || ! has_cmd jq || [[ "$_sig_ok" == "1" ]]; then
    # No manifest yet — generate fresh
    _hook_manifest_generate "$project_dir"
    return 0
  fi

  [[ ! -d "$hooks_dir" ]] && return 0

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Read existing manifest into tmp, update matching entries
  local tmp="${manifest_file}.tmp.$$"
  cp "$manifest_file" "$tmp"

  local svc_dir
  for svc_dir in "${hooks_dir}"/*/; do
    [[ ! -d "$svc_dir" ]] && continue
    local svc
    svc=$(basename "$svc_dir")
    [[ "$svc" == "logs" || "$svc" == "pids" ]] && continue

    # If service specified, skip non-matching
    [[ -n "$service" && "$svc" != "$service" ]] && continue

    local hook_file
    for hook_file in "${svc_dir}"*.sh "${svc_dir}"justfile; do
      [[ ! -f "$hook_file" ]] && continue
      local hook_name
      hook_name=$(basename "$hook_file")
      local key="${svc}/${hook_name}"

      local sha
      sha=$(shasum -a 256 "$hook_file" 2>/dev/null | cut -d' ' -f1)
      [[ -z "$sha" ]] && continue

      local size
      size=$(wc -c < "$hook_file" | tr -d ' ')

      jq --arg k "$key" --arg sha "$sha" --arg ts "$ts" --argjson sz "$size" \
        '.[$k] = {"sha256": $sha, "generated_at": $ts, "size": $sz}' \
        "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    done
  done

  # Approving all services also approves the current config + .env
  if [[ -z "$service" ]]; then
    local _cfg
    _cfg=$(_hook_config_file "$project_dir")
    local _f _k
    for _f in "$_cfg" "${project_dir}/.env"; do
      [[ -n "$_f" && -f "$_f" ]] || continue
      _k="_config/$(basename "$_f")"
      local _fsha _fsz
      _fsha=$(shasum -a 256 "$_f" 2>/dev/null | cut -d' ' -f1)
      _fsz=$(wc -c < "$_f" | tr -d ' ')
      [[ -z "$_fsha" ]] && continue
      jq --arg k "$_k" --arg sha "$_fsha" --arg ts "$ts" --argjson sz "$_fsz" \
        '.[$k] = {"sha256": $sha, "generated_at": $ts, "size": $sz}' \
        "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    done
  fi

  mv "$tmp" "$manifest_file"
  chmod 600 "$manifest_file"

  # Re-sign the manifest
  _hook_manifest_sign "$manifest_file"

  # Refresh approved copies used for diffs
  _hook_trust_save_all "$project_dir" "$service"
}

# Verify all hooks, output results
# Args: project_dir
# Returns: 0=all ok, 1=issues found
_hook_manifest_verify_all() {
  local project_dir="$1"
  local hooks_dir="${project_dir}/.muster/hooks"
  _hook_trust_resolve "$project_dir"
  local manifest_file="${_HOOK_TRUST_DIR}/hooks.manifest"
  local issues=0

  if [[ ! -f "$manifest_file" ]]; then
    printf '  %b!%b Hooks not approved on this machine. Review them, then run %bmuster hooks approve%b.\n' \
      "${YELLOW}" "${RESET}" "${DIM}" "${RESET}"
    return 1
  fi

  local svc_dir
  for svc_dir in "${hooks_dir}"/*/; do
    [[ ! -d "$svc_dir" ]] && continue
    local svc
    svc=$(basename "$svc_dir")
    [[ "$svc" == "logs" || "$svc" == "pids" ]] && continue

    local hook_file
    for hook_file in "${svc_dir}"*.sh "${svc_dir}"justfile; do
      [[ ! -f "$hook_file" ]] && continue

      _hook_manifest_verify "$hook_file" "$project_dir"
      local rc=$?
      local hook_name
      hook_name=$(basename "$hook_file")
      local key="${svc}/${hook_name}"

      case "$rc" in
        0) printf '  %b✓%b %s\n' "${GREEN}" "${RESET}" "$key" ;;
        1) printf '  %b✗%b %s %b— tampered%b\n' "${RED}" "${RESET}" "$key" "${RED}" "${RESET}"
           issues=$(( issues + 1 )) ;;
        2) printf '  %b!%b %s %b— not in manifest%b\n' "${YELLOW}" "${RESET}" "$key" "${YELLOW}" "${RESET}"
           issues=$(( issues + 1 )) ;;
      esac
    done
  done

  # Also show config file integrity
  _config_integrity_check "$project_dir"
  local cfg_rc=$?
  case "$cfg_rc" in
    0) printf '  %b✓%b config file\n' "${GREEN}" "${RESET}" ;;
    1) printf '  %b✗%b config file %b— tampered%b\n' "${RED}" "${RESET}" "${RED}" "${RESET}"
       issues=$(( issues + 1 )) ;;
    2) printf '  %b!%b config file %b— not tracked%b\n' "${YELLOW}" "${RESET}" "${YELLOW}" "${RESET}" ;;
  esac

  # .env integrity
  if [[ -f "${project_dir}/.env" ]]; then
    _env_integrity_check "$project_dir"
    local env_rc=$?
    case "$env_rc" in
      0) printf '  %b✓%b .env\n' "${GREEN}" "${RESET}" ;;
      1) printf '  %b✗%b .env %b— tampered%b\n' "${RED}" "${RESET}" "${RED}" "${RESET}"
         issues=$(( issues + 1 )) ;;
      2) printf '  %b!%b .env %b— not tracked%b\n' "${YELLOW}" "${RESET}" "${YELLOW}" "${RESET}" ;;
    esac
  fi

  # Manifest signature
  _hook_manifest_verify_sig "$manifest_file"
  local sig_rc=$?
  case "$sig_rc" in
    0) printf '  %b✓%b manifest signature\n' "${GREEN}" "${RESET}" ;;
    1) printf '  %b✗%b manifest signature %b— invalid%b\n' "${RED}" "${RESET}" "${RED}" "${RESET}"
       issues=$(( issues + 1 )) ;;
    2) printf '  %b!%b manifest signature %b— not signed%b\n' "${YELLOW}" "${RESET}" "${YELLOW}" "${RESET}" ;;
  esac

  (( issues > 0 )) && return 1
  return 0
}

# ── Dangerous command scanner ──

# Scan a hook file for dangerous patterns
# Args: hook_path
# Returns: 0=clean, 1=dangerous
_hook_scan_dangerous() {
  local hook_path="$1"

  [[ ! -f "$hook_path" ]] && return 0

  # Allow bypass
  [[ "${MUSTER_HOOK_UNSAFE:-}" == "1" ]] && return 0

  local found=0
  local line_num=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$(( line_num + 1 ))

    # Skip comments
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    local pi=0
    while (( pi < ${#_HOOK_DANGER_PATTERNS[@]} )); do
      local entry="${_HOOK_DANGER_PATTERNS[$pi]}"
      local pattern="${entry%%|*}"
      local desc="${entry#*|}"

      if printf '%s' "$line" | grep -qE "$pattern" 2>/dev/null; then
        if (( found == 0 )); then
          err "Dangerous command detected in $(basename "$hook_path"):"
        fi
        printf '  %bLine %d:%b %s\n' "${RED}" "$line_num" "${RESET}" "$desc"
        printf '  %b%s%b\n' "${DIM}" "$line" "${RESET}"
        found=$(( found + 1 ))
      fi

      pi=$(( pi + 1 ))
    done
  done < "$hook_path"

  (( found > 0 )) && return 1
  return 0
}

# ── Permission lockdown ──

# Lock hooks (read+execute only)
# Args: hook_dir (service hook directory) or project hooks dir
_hook_lock() {
  local target="$1"
  if [[ -d "$target" ]]; then
    local f
    for f in "${target}"/*.sh "${target}"/**//*.sh; do
      [[ -f "$f" ]] && chmod 555 "$f" 2>/dev/null
    done
    # Also lock justfiles
    for f in "${target}"/justfile "${target}"/**/justfile; do
      [[ -f "$f" ]] && chmod 444 "$f" 2>/dev/null
    done
  elif [[ -f "$target" ]]; then
    chmod 555 "$target" 2>/dev/null
  fi
}

# Unlock hooks (owner-writable)
# Args: hook_dir (service hook directory) or project hooks dir
_hook_unlock() {
  local target="$1"
  if [[ -d "$target" ]]; then
    local f
    for f in "${target}"/*.sh "${target}"/**//*.sh; do
      [[ -f "$f" ]] && chmod 755 "$f" 2>/dev/null
    done
    for f in "${target}"/justfile "${target}"/**/justfile; do
      [[ -f "$f" ]] && chmod 644 "$f" 2>/dev/null
    done
  elif [[ -f "$target" ]]; then
    chmod 755 "$target" 2>/dev/null
  fi
}

# ── Config file integrity ──

# Verify config file (deploy.json/muster.json) against manifest
# Args: project_dir
# Returns: 0=ok, 1=tampered, 2=not tracked
_config_integrity_check() {
  local project_dir="$1"
  _hook_trust_resolve "$project_dir"
  local manifest_file="${_HOOK_TRUST_DIR}/hooks.manifest"

  [[ ! -f "$manifest_file" ]] && return 2
  has_cmd jq || return 0

  local config_file=""
  if [[ -f "${project_dir}/muster.json" ]]; then
    config_file="${project_dir}/muster.json"
  elif [[ -f "${project_dir}/deploy.json" ]]; then
    config_file="${project_dir}/deploy.json"
  fi
  [[ -z "$config_file" ]] && return 2

  local cfg_key
  cfg_key="_config/$(basename "$config_file")"
  local expected_sha
  expected_sha=$(jq -r --arg k "$cfg_key" '.[$k].sha256 // empty' "$manifest_file" 2>/dev/null)
  [[ -z "$expected_sha" ]] && return 2

  local actual_sha
  actual_sha=$(shasum -a 256 "$config_file" 2>/dev/null | cut -d' ' -f1)

  if [[ "$actual_sha" == "$expected_sha" ]]; then
    return 0
  else
    return 1
  fi
}

# Verify .env file against manifest
# Args: project_dir
# Returns: 0=ok, 1=tampered, 2=not tracked
_env_integrity_check() {
  local project_dir="$1"
  _hook_trust_resolve "$project_dir"
  local manifest_file="${_HOOK_TRUST_DIR}/hooks.manifest"

  [[ ! -f "$manifest_file" ]] && return 2
  has_cmd jq || return 0

  local expected_sha
  expected_sha=$(jq -r '.["_config/.env"].sha256 // empty' "$manifest_file" 2>/dev/null)
  [[ -z "$expected_sha" ]] && return 2

  # .env was tracked but now deleted
  [[ ! -f "${project_dir}/.env" ]] && return 1

  local actual_sha
  actual_sha=$(shasum -a 256 "${project_dir}/.env" 2>/dev/null | cut -d' ' -f1)

  if [[ "$actual_sha" == "$expected_sha" ]]; then
    return 0
  else
    return 1
  fi
}

# ── Security gate ──

# Single entry point: verify integrity + scan for danger
# Args: hook_path project_dir [silent]
# Returns: 0=safe, 1=blocked
_hook_security_check() {
  local hook_path="$1" project_dir="$2"
  local silent="${3:-}"

  # Check global setting
  local _security_enabled
  _security_enabled=$(global_config_get "hook_security" 2>/dev/null || true)
  if [[ "$_security_enabled" == "off" ]]; then
    return 0
  fi

  # 0. Path traversal check — hook must resolve inside .muster/hooks/
  if ! _hook_validate_path "$hook_path" "$project_dir"; then
    if [[ "$silent" != "silent" ]]; then
      err "Hook path traversal blocked: ${hook_path}"
      printf '  %bHook must be inside .muster/hooks/%b\n' "${DIM}" "${RESET}"
    fi
    return 1
  fi

  # 0b. Manifest signature check — detect manifest tampering
  _hook_trust_resolve "$project_dir"
  local manifest_file="${_HOOK_TRUST_DIR}/hooks.manifest"
  if [[ -f "$manifest_file" ]]; then
    _hook_manifest_verify_sig "$manifest_file"
    local sig_rc=$?
    if [[ "$sig_rc" == "1" ]]; then
      if [[ "$silent" != "silent" ]]; then
        err "Manifest signature invalid — manifest may have been tampered with"
        printf '  %bRun %bmuster hooks approve%b%b to re-sign%b\n' \
          "${DIM}" "${RESET}${WHITE}" "${RESET}" "${DIM}" "${RESET}"
      fi
      return 1
    fi
  fi

  # 1. Integrity check
  _hook_manifest_verify "$hook_path" "$project_dir"
  local rc=$?
  if [[ "$rc" == "1" ]]; then
    local key="${hook_path#${project_dir}/.muster/hooks/}"
    if [[ "$silent" != "silent" ]]; then
      err "Hook tampered: ${key}"
      printf '  %bRun %bmuster hooks approve%b%b to re-sign after intentional edits%b\n' \
        "${DIM}" "${RESET}${WHITE}" "${RESET}" "${DIM}" "${RESET}"
    fi
    return 1
  fi

  # 2. Config file integrity — detect deploy.json tampering
  _config_integrity_check "$project_dir"
  local cfg_rc=$?
  if [[ "$cfg_rc" == "1" ]]; then
    if [[ "$silent" != "silent" ]]; then
      err "Config file tampered — deploy.json or muster.json has been modified"
      printf '  %bRun %bmuster hooks approve%b%b to re-sign after intentional edits%b\n' \
        "${DIM}" "${RESET}${WHITE}" "${RESET}" "${DIM}" "${RESET}"
    fi
    return 1
  fi

  # 3. Dangerous command scan
  if ! _hook_scan_dangerous "$hook_path"; then
    if [[ "$silent" != "silent" ]]; then
      printf '  %bSet MUSTER_HOOK_UNSAFE=1 to bypass this check%b\n' "${DIM}" "${RESET}"
    fi
    return 1
  fi

  return 0
}

# ── Approval gate (run before executing any hook) ──

# Pending entries from the last _hook_trust_pending call: "status|key|path"
# status: changed (differs from approved), new (never approved)
_HOOK_PENDING=()
_HOOK_PENDING_FRESH=false

# Collect hooks (and config) that aren't approved on this machine.
# Args: project_dir service...
# Returns: 0 if something is pending, 1 if everything is approved
_hook_trust_pending() {
  local project_dir="$1"; shift
  _HOOK_PENDING=()
  _HOOK_PENDING_FRESH=false
  _hook_trust_resolve "$project_dir"
  local manifest_file="${_HOOK_TRUST_DIR}/hooks.manifest"

  if [[ ! -f "$manifest_file" ]]; then
    _HOOK_PENDING_FRESH=true
  else
    _hook_manifest_verify_sig "$manifest_file"
    [[ $? -eq 1 ]] && _HOOK_PENDING_FRESH=true
  fi

  local svc f rc
  for svc in "$@"; do
    local svc_dir="${project_dir}/.muster/hooks/${svc}"
    [[ -d "$svc_dir" ]] || continue
    for f in "${svc_dir}"/*.sh "${svc_dir}"/justfile; do
      [[ -f "$f" ]] || continue
      local key
      key="${svc}/$(basename "$f")"
      if [[ "$_HOOK_PENDING_FRESH" == "true" ]]; then
        _HOOK_PENDING[${#_HOOK_PENDING[@]}]="new|${key}|${f}"
        continue
      fi
      _hook_manifest_verify "$f" "$project_dir"
      rc=$?
      case "$rc" in
        1) _HOOK_PENDING[${#_HOOK_PENDING[@]}]="changed|${key}|${f}" ;;
        2) _HOOK_PENDING[${#_HOOK_PENDING[@]}]="new|${key}|${f}" ;;
      esac
    done
  done

  if [[ "$_HOOK_PENDING_FRESH" != "true" ]]; then
    _config_integrity_check "$project_dir"
    if [[ $? -eq 1 ]]; then
      local cfg
      cfg=$(_hook_config_file "$project_dir")
      _HOOK_PENDING[${#_HOOK_PENDING[@]}]="changed|_config/$(basename "$cfg")|${cfg}"
    fi
  fi

  (( ${#_HOOK_PENDING[@]} > 0 ))
}

# Print a unified diff of each pending file against its approved copy
# (or the whole file when there is no approved copy to compare with).
_hook_trust_show_diff() {
  local project_dir="$1"
  local i=0
  while (( i < ${#_HOOK_PENDING[@]} )); do
    local entry="${_HOOK_PENDING[$i]}"
    local rest="${entry#*|}"
    local key="${rest%%|*}" path="${rest#*|}"
    local approved
    approved=$(_hook_approved_copy "$project_dir" "$key")
    echo ""
    if [[ -f "$approved" ]]; then
      printf '  %b%s%b %b(changes since approval)%b\n' "${BOLD}" "$key" "${RESET}" "${DIM}" "${RESET}"
      diff -u --label "approved/${key}" --label "${key}" "$approved" "$path" | while IFS= read -r _dl; do
        case "$_dl" in
          ---*|+++*) printf '  %b%s%b\n' "${BOLD}" "$_dl" "${RESET}" ;;
          @@*) printf '  %b%s%b\n' "${ACCENT}" "$_dl" "${RESET}" ;;
          +*) printf '  %b%s%b\n' "${GREEN}" "$_dl" "${RESET}" ;;
          -*) printf '  %b%s%b\n' "${RED}" "$_dl" "${RESET}" ;;
          *) printf '  %s\n' "$_dl" ;;
        esac
      done
    else
      printf '  %b%s%b %b(no approved copy on this machine — full file)%b\n' "${BOLD}" "$key" "${RESET}" "${DIM}" "${RESET}"
      local _n=0
      while IFS= read -r _fl || [[ -n "$_fl" ]]; do
        _n=$(( _n + 1 ))
        printf '  %b%4d%b  %s\n' "${DIM}" "$_n" "${RESET}" "$_fl"
      done < "$path"
    fi
    i=$(( i + 1 ))
  done
  echo ""
}

# Gate hook execution on per-machine approval.
# Args: project_dir action interactive(true|false) yes(true|false) service...
#   action: verb for the menu, e.g. "deploy" or "rollback"
#   yes:    approve without review (--yes / MUSTER_APPROVE_HOOKS=1)
# Returns: 0 to proceed, 1 to stop
_hook_trust_gate() {
  local project_dir="$1" action="$2" interactive="$3" yes="$4"
  shift 4

  local _security_enabled
  _security_enabled=$(global_config_get "hook_security" 2>/dev/null || true)
  [[ "$_security_enabled" == "off" ]] && return 0

  _hook_trust_pending "$project_dir" "$@" || return 0

  local count=${#_HOOK_PENDING[@]}
  local i entry status key

  if [[ "$yes" == "true" ]]; then
    warn "Approving ${count} unreviewed hook file(s) on this machine (--yes / MUSTER_APPROVE_HOOKS=1)"
    i=0
    while (( i < count )); do
      entry="${_HOOK_PENDING[$i]}"; key="${entry#*|}"; key="${key%%|*}"
      printf '    %s\n' "$key"
      i=$(( i + 1 ))
    done
    _hook_manifest_approve "$project_dir"
    return 0
  fi

  # Describe what's pending
  if [[ "$_HOOK_PENDING_FRESH" == "true" ]]; then
    err "Hooks for this project haven't been approved on this machine:"
    i=0
    while (( i < count )); do
      entry="${_HOOK_PENDING[$i]}"; key="${entry#*|}"; key="${key%%|*}"
      printf '    %s\n' "$key"
      i=$(( i + 1 ))
    done
  elif [[ "$interactive" != "true" && "$count" == "1" ]]; then
    entry="${_HOOK_PENDING[0]}"; status="${entry%%|*}"; key="${entry#*|}"; key="${key%%|*}"
    if [[ "$status" == "changed" ]]; then
      err "${key} changed since it was approved on this machine. Review it, then run: muster hooks approve"
    else
      err "${key} hasn't been approved on this machine. Review it, then run: muster hooks approve"
    fi
    printf '  %bIn CI, pass --yes or set MUSTER_APPROVE_HOOKS=1 to approve and continue.%b\n' "${DIM}" "${RESET}"
    return 1
  else
    i=0
    while (( i < count )); do
      entry="${_HOOK_PENDING[$i]}"; status="${entry%%|*}"; key="${entry#*|}"; key="${key%%|*}"
      if [[ "$status" == "changed" ]]; then
        err "${key} changed since it was approved on this machine"
      else
        err "${key} hasn't been approved on this machine"
      fi
      i=$(( i + 1 ))
    done
  fi

  if [[ "$interactive" != "true" ]]; then
    printf '  Review them, then run: muster hooks approve\n'
    printf '  %bIn CI, pass --yes or set MUSTER_APPROVE_HOOKS=1 to approve and continue.%b\n' "${DIM}" "${RESET}"
    return 1
  fi

  local review_label="Show diff" approve_label="Approve and ${action}"
  if [[ "$_HOOK_PENDING_FRESH" == "true" ]]; then
    review_label="Review"
    approve_label="Approve and continue"
  fi

  while true; do
    echo ""
    menu_select "Approve these hooks on this machine?" "$review_label" "$approve_label" "Abort"
    case "$MENU_RESULT" in
      "$review_label")
        _hook_trust_show_diff "$project_dir"
        ;;
      "$approve_label")
        _hook_manifest_approve "$project_dir"
        ok "Hooks approved on this machine"
        echo ""
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  done
}
