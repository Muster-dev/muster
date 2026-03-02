#!/usr/bin/env bash
# muster/lib/core/auth.sh — Token-based authentication for JSON API
# Tokens are SHA-256 hashed before storage. Raw tokens shown only once at creation.

MUSTER_TOKENS_FILE="$HOME/.muster/tokens.json"
AUTH_SCOPE=""

# Ensure tokens file exists with secure permissions
_auth_ensure_file() {
  if [[ ! -d "$HOME/.muster" ]]; then
    mkdir -p "$HOME/.muster"
    chmod 700 "$HOME/.muster"
  fi
  # Enforce directory permissions every time
  chmod 700 "$HOME/.muster"
  if [[ ! -f "$MUSTER_TOKENS_FILE" ]]; then
    printf '{"tokens":[]}\n' > "$MUSTER_TOKENS_FILE"
  fi
  chmod 600 "$MUSTER_TOKENS_FILE"
}

# SHA-256 hash a raw token
_auth_hash() {
  printf '%s' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1
}

# Check if any tokens exist (for bootstrap logic)
_auth_has_tokens() {
  _auth_ensure_file
  local count
  count=$(jq '.tokens | length' "$MUSTER_TOKENS_FILE" 2>/dev/null)
  [[ -n "$count" && "$count" -gt 0 ]]
}

# Require admin auth for token management (skip for first-time bootstrap)
_auth_require_admin() {
  if ! _auth_has_tokens; then
    return 0  # First token — no auth required (bootstrap)
  fi
  # Tokens exist — require MUSTER_TOKEN with admin scope
  local raw_token="${MUSTER_TOKEN:-}"
  if [[ -z "$raw_token" ]]; then
    echo "Admin token required. Set MUSTER_TOKEN to an admin token." >&2
    return 1
  fi
  local token_hash
  token_hash=$(_auth_hash "$raw_token")
  local match
  match=$(jq -r --arg h "sha256:${token_hash}" \
    '.tokens[] | select(.token_hash == $h) | .scope' "$MUSTER_TOKENS_FILE" 2>/dev/null)
  if [[ "$match" != "admin" ]]; then
    echo "Forbidden: admin scope required to manage tokens." >&2
    return 1
  fi
  return 0
}

# Generate a new token, print raw token to stdout
# Usage: auth_create_token "my-laptop" "admin"
auth_create_token() {
  local name="$1" scope="$2"
  _auth_ensure_file

  # Require admin auth (unless bootstrapping first token)
  if ! _auth_require_admin; then
    return 1
  fi

  # Validate scope
  case "$scope" in
    read|deploy|admin) ;;
    *)
      echo "Invalid scope: ${scope} (must be read, deploy, or admin)" >&2
      return 1
      ;;
  esac

  # Validate name format — alphanumeric, hyphens, underscores only
  if [[ -z "$name" ]]; then
    echo "Token name cannot be empty" >&2
    return 1
  fi
  if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Token name must be alphanumeric (hyphens and underscores allowed)" >&2
    return 1
  fi

  # Check for duplicate name
  local existing
  existing=$(jq -r --arg n "$name" '.tokens[] | select(.name == $n) | .name' "$MUSTER_TOKENS_FILE" 2>/dev/null)
  if [[ -n "$existing" ]]; then
    echo "Token '${name}' already exists. Revoke it first with: muster auth revoke ${name}" >&2
    return 1
  fi

  # Generate cryptographically random token
  local raw_token
  raw_token=$(openssl rand -hex 32)
  local token_hash
  token_hash=$(_auth_hash "$raw_token")

  local created
  created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Add to tokens file
  local tmp="${MUSTER_TOKENS_FILE}.tmp"
  jq --arg name "$name" \
     --arg hash "sha256:${token_hash}" \
     --arg scope "$scope" \
     --arg created "$created" \
     '.tokens += [{"name":$name,"token_hash":$hash,"scope":$scope,"created":$created,"last_used":""}]' \
     "$MUSTER_TOKENS_FILE" > "$tmp" && mv "$tmp" "$MUSTER_TOKENS_FILE"
  chmod 600 "$MUSTER_TOKENS_FILE"

  # Print the raw token (shown only once)
  printf '%s\n' "$raw_token"
}

# Validate MUSTER_TOKEN env var. Sets AUTH_SCOPE on success.
# Returns 0 if valid, 1 if invalid.
auth_validate_token() {
  local raw_token="${MUSTER_TOKEN:-}"
  if [[ -z "$raw_token" ]]; then
    printf '{"error":"auth_required","message":"MUSTER_TOKEN not set"}\n' >&2
    return 1
  fi

  _auth_ensure_file

  local token_hash
  token_hash=$(_auth_hash "$raw_token")
  local match
  match=$(jq -r --arg h "sha256:${token_hash}" \
    '.tokens[] | select(.token_hash == $h) | .scope' "$MUSTER_TOKENS_FILE" 2>/dev/null)

  if [[ -z "$match" ]]; then
    printf '{"error":"auth_failed","message":"Invalid token"}\n' >&2
    return 1
  fi

  AUTH_SCOPE="$match"

  # Update last_used timestamp
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local tmp="${MUSTER_TOKENS_FILE}.tmp"
  jq --arg h "sha256:${token_hash}" --arg now "$now" \
    '(.tokens[] | select(.token_hash == $h)).last_used = $now' \
    "$MUSTER_TOKENS_FILE" > "$tmp" && mv "$tmp" "$MUSTER_TOKENS_FILE"
  chmod 600 "$MUSTER_TOKENS_FILE"

  return 0
}

# Check if a scope allows a required permission level.
# Usage: auth_check_scope "$AUTH_SCOPE" "deploy"
auth_check_scope() {
  local scope="$1" required="$2"
  case "$required" in
    read)
      return 0
      ;;
    deploy)
      case "$scope" in
        deploy|admin) return 0 ;;
      esac
      return 1
      ;;
    admin)
      [[ "$scope" == "admin" ]] && return 0
      return 1
      ;;
  esac
  return 1
}

# Convenience: validate token + check scope, emit JSON error on failure.
# Usage: _json_auth_gate "read"
_json_auth_gate() {
  local required_scope="$1"
  if ! auth_validate_token; then
    return 1
  fi
  if ! auth_check_scope "$AUTH_SCOPE" "$required_scope"; then
    printf '{"error":"forbidden","message":"Token scope \"%s\" cannot access this command (requires \"%s\")"}\n' \
      "$AUTH_SCOPE" "$required_scope" >&2
    return 1
  fi
  return 0
}

# List all tokens (names + scopes, never raw tokens)
auth_list_tokens() {
  _auth_ensure_file

  local count
  count=$(jq '.tokens | length' "$MUSTER_TOKENS_FILE" 2>/dev/null)
  if [[ "$count" == "0" || -z "$count" ]]; then
    info "No tokens configured. Create one with: muster auth create <name> --scope <scope>"
    return 0
  fi

  echo ""
  printf '  %b%-20s  %-8s  %-22s  %-22s%b\n' "${BOLD}" "NAME" "SCOPE" "CREATED" "LAST USED" "${RESET}"
  printf '  %b%-20s  %-8s  %-22s  %-22s%b\n' "${DIM}" "--------------------" "--------" "----------------------" "----------------------" "${RESET}"

  local i=0
  while (( i < count )); do
    local name scope created last_used
    name=$(jq -r ".tokens[$i].name" "$MUSTER_TOKENS_FILE")
    scope=$(jq -r ".tokens[$i].scope" "$MUSTER_TOKENS_FILE")
    created=$(jq -r ".tokens[$i].created" "$MUSTER_TOKENS_FILE")
    last_used=$(jq -r ".tokens[$i].last_used" "$MUSTER_TOKENS_FILE")
    [[ "$last_used" == "" || "$last_used" == "null" ]] && last_used="never"

    local scope_color="$RESET"
    case "$scope" in
      admin)  scope_color="$RED" ;;
      deploy) scope_color="$YELLOW" ;;
      read)   scope_color="$GREEN" ;;
    esac

    printf '  %-20s  %b%-8s%b  %b%-22s%b  %b%-22s%b\n' \
      "$name" "$scope_color" "$scope" "$RESET" "$DIM" "$created" "$RESET" "$DIM" "$last_used" "$RESET"
    i=$(( i + 1 ))
  done
  echo ""
}

# Revoke a token by name
auth_revoke_token() {
  local name="$1"
  _auth_ensure_file

  # Require admin auth to revoke tokens
  if ! _auth_require_admin; then
    return 1
  fi

  local existing
  existing=$(jq -r --arg n "$name" '.tokens[] | select(.name == $n) | .name' "$MUSTER_TOKENS_FILE" 2>/dev/null)
  if [[ -z "$existing" ]]; then
    err "No token found with name '${name}'"
    return 1
  fi

  local tmp="${MUSTER_TOKENS_FILE}.tmp"
  jq --arg n "$name" '.tokens = [.tokens[] | select(.name != $n)]' \
    "$MUSTER_TOKENS_FILE" > "$tmp" && mv "$tmp" "$MUSTER_TOKENS_FILE"
  chmod 600 "$MUSTER_TOKENS_FILE"

  ok "Token '${name}' revoked"
}
