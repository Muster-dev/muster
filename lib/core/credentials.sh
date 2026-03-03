#!/usr/bin/env bash
# muster/lib/core/credentials.sh — Credential prompting and caching

# Session credential store (parallel arrays for bash 3.2)
_CRED_KEYS=()
_CRED_VALS=()

# Ensure sshpass is installed for password-based SSH auth.
# Offers to install if missing. Returns 0 if available, 1 if not.
_ensure_sshpass() {
  command -v sshpass &>/dev/null && return 0

  echo ""
  warn "sshpass is required for SSH password authentication."

  # Detect install command
  local _install_cmd=""
  if command -v brew &>/dev/null; then
    _install_cmd="brew install esolitos/ipa/sshpass"
  elif command -v apt-get &>/dev/null; then
    _install_cmd="sudo apt-get install -y sshpass"
  elif command -v yum &>/dev/null; then
    _install_cmd="sudo yum install -y sshpass"
  elif command -v pacman &>/dev/null; then
    _install_cmd="sudo pacman -S --noconfirm sshpass"
  fi

  if [[ -n "$_install_cmd" && -t 0 ]]; then
    menu_select "Install sshpass now?" \
      "Yes — run: ${_install_cmd}" \
      "No — I'll install it myself"
    if [[ "$MENU_RESULT" == "Yes"* ]]; then
      echo ""
      if eval "$_install_cmd"; then
        ok "sshpass installed"
        echo ""
        return 0
      else
        err "Installation failed"
        printf '%b\n' "  ${DIM}Run manually: ${_install_cmd}${RESET}"
        echo ""
        return 1
      fi
    fi
  else
    [[ -n "$_install_cmd" ]] && printf '%b\n' "  ${DIM}Install: ${_install_cmd}${RESET}"
  fi

  return 1
}

# Prompt for a password (hidden input)
_cred_prompt_password() {
  local label="$1"
  local password=""

  # Prompt to stderr so $() only captures the password on stdout
  printf '  %b?%b %s %b(hidden)%b: ' "${ACCENT}" "${RESET}" "$label" "${DIM}" "${RESET}" >&2

  # Read with hidden input
  stty -echo 2>/dev/null
  IFS= read -r password || true
  stty echo 2>/dev/null
  printf '\n' >&2

  printf '%s' "$password"
}

# Get a session-cached credential
_cred_session_get() {
  local key="$1"
  local i=0
  while (( i < ${#_CRED_KEYS[@]} )); do
    if [[ "${_CRED_KEYS[$i]}" == "$key" ]]; then
      printf '%s' "${_CRED_VALS[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Store a credential in session cache
_cred_session_set() {
  local key="$1" val="$2"
  # Update if exists
  local i=0
  while (( i < ${#_CRED_KEYS[@]} )); do
    if [[ "${_CRED_KEYS[$i]}" == "$key" ]]; then
      _CRED_VALS[$i]="$val"
      return 0
    fi
    i=$((i + 1))
  done
  # Append
  _CRED_KEYS[${#_CRED_KEYS[@]}]="$key"
  _CRED_VALS[${#_CRED_VALS[@]}]="$val"
}

# Save to system keyring (macOS Keychain, Linux secret-tool, or file fallback)
_cred_keychain_save() {
  local svc="$1" key="$2" val="$3"
  # macOS Keychain
  if command -v security &>/dev/null; then
    security add-generic-password -a "muster-${svc}" -s "muster-${key}" -w "$val" -U 2>/dev/null
    return $?
  fi
  # Linux: secret-tool (GNOME Keyring / D-Bus Secret Service)
  if command -v secret-tool &>/dev/null; then
    printf '%s' "$val" | secret-tool store --label="muster-${key}" service "muster-${svc}" key "$key" 2>/dev/null
    return $?
  fi
  # Fallback: encrypted-ish file store (better than nothing on headless Linux)
  local _store_dir="${HOME}/.muster/.credentials"
  mkdir -p "$_store_dir" 2>/dev/null
  chmod 700 "$_store_dir" 2>/dev/null
  local _store_file="${_store_dir}/${svc}_$(printf '%s' "$key" | tr '/:@' '___')"
  printf '%s' "$val" > "$_store_file" 2>/dev/null
  chmod 600 "$_store_file" 2>/dev/null
  return $?
}

# Read from system keyring (macOS Keychain, Linux secret-tool, or file fallback)
_cred_keychain_get() {
  local svc="$1" key="$2"
  # macOS Keychain
  if command -v security &>/dev/null; then
    security find-generic-password -a "muster-${svc}" -s "muster-${key}" -w 2>/dev/null
    return $?
  fi
  # Linux: secret-tool
  if command -v secret-tool &>/dev/null; then
    secret-tool lookup service "muster-${svc}" key "$key" 2>/dev/null
    return $?
  fi
  # Fallback: file store
  local _store_dir="${HOME}/.muster/.credentials"
  local _store_file="${_store_dir}/${svc}_$(printf '%s' "$key" | tr '/:@' '___')"
  if [[ -f "$_store_file" ]]; then
    cat "$_store_file" 2>/dev/null
    return $?
  fi
  return 1
}

# Get credentials for a service based on its mode, returns env vars as KEY=VAL lines
# Usage: cred_env_for_service "svc_key"
# Outputs: MUSTER_CRED_KEY=value lines (one per required credential)
cred_env_for_service() {
  local svc="$1"
  local mode
  mode=$(config_get ".services.${svc}.credentials.mode")
  local enabled
  enabled=$(config_get ".services.${svc}.credentials.enabled")

  [[ "$enabled" != "true" ]] && return 0

  # Get required credential keys
  local required
  required=$(config_get ".services.${svc}.credentials.required[]" 2>/dev/null)
  [[ -z "$required" || "$required" == "null" ]] && return 0

  local name
  name=$(config_get ".services.${svc}.name")

  while IFS= read -r cred_key; do
    [[ -z "$cred_key" ]] && continue
    local upper_key
    upper_key=$(printf '%s' "$cred_key" | tr '[:lower:]' '[:upper:]')
    local env_name="MUSTER_CRED_${upper_key}"
    local val=""

    case "$mode" in
      save)
        # Try keychain first
        val=$(_cred_keychain_get "$svc" "$cred_key" 2>/dev/null) || true
        if [[ -z "$val" ]]; then
          val=$(_cred_prompt_password "${name} ${cred_key}")
          # Save to keychain
          _cred_keychain_save "$svc" "$cred_key" "$val" 2>/dev/null || true
        fi
        # Also cache in session
        _cred_session_set "${svc}_${cred_key}" "$val"
        ;;
      session)
        # Try session cache first
        val=$(_cred_session_get "${svc}_${cred_key}" 2>/dev/null) || true
        if [[ -z "$val" ]]; then
          val=$(_cred_prompt_password "${name} ${cred_key}")
          _cred_session_set "${svc}_${cred_key}" "$val"
        fi
        ;;
      always)
        # Always prompt
        val=$(_cred_prompt_password "${name} ${cred_key}")
        ;;
      *)
        # Mode off or unknown, skip
        continue
        ;;
    esac

    printf '%s=%s\n' "$env_name" "$val"
  done <<< "$required"
}
