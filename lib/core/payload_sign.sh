#!/usr/bin/env bash
# muster/lib/core/payload_sign.sh — Ed25519/RSA payload signing for fleet hooks

# ── Key paths ──

_PAYLOAD_KEY_DIR="$HOME/.muster/fleet/keys"
_PAYLOAD_PRIVKEY="$HOME/.muster/fleet/keys/payload.key.pem"
_PAYLOAD_PUBKEY="$HOME/.muster/fleet/keys/payload.pub.pem"
_PAYLOAD_KEYTYPE_FILE="$HOME/.muster/fleet/keys/keytype"
_PAYLOAD_AUTH_KEYS_DIR="$HOME/.muster/fleet/authorized_keys"

_PAYLOAD_SIGN_ALGO=""

# ── Algorithm detection ──

_payload_sign_detect_algo() {
  if [[ -n "$_PAYLOAD_SIGN_ALGO" ]]; then
    printf '%s' "$_PAYLOAD_SIGN_ALGO"
    return 0
  fi

  # If existing keytype file, use that
  if [[ -f "$_PAYLOAD_KEYTYPE_FILE" ]]; then
    _PAYLOAD_SIGN_ALGO=$(cat "$_PAYLOAD_KEYTYPE_FILE" 2>/dev/null)
    printf '%s' "$_PAYLOAD_SIGN_ALGO"
    return 0
  fi

  # Try ed25519
  local tmp_key="/tmp/.muster_algo_test_$$"
  if openssl genpkey -algorithm ed25519 -out "$tmp_key" 2>/dev/null; then
    rm -f "$tmp_key"
    _PAYLOAD_SIGN_ALGO="ed25519"
  else
    rm -f "$tmp_key"
    _PAYLOAD_SIGN_ALGO="rsa"
  fi

  printf '%s' "$_PAYLOAD_SIGN_ALGO"
}

# ── Keypair management ──

_payload_ensure_keypair() {
  [[ -f "$_PAYLOAD_PRIVKEY" && -f "$_PAYLOAD_PUBKEY" ]] && return 0

  mkdir -p "$_PAYLOAD_KEY_DIR"
  chmod 700 "$_PAYLOAD_KEY_DIR"

  local algo
  algo=$(_payload_sign_detect_algo)

  case "$algo" in
    ed25519)
      openssl genpkey -algorithm ed25519 -out "$_PAYLOAD_PRIVKEY" 2>/dev/null || {
        err "Failed to generate ed25519 keypair"
        return 1
      }
      ;;
    rsa)
      openssl genrsa -out "$_PAYLOAD_PRIVKEY" 2048 2>/dev/null || {
        err "Failed to generate RSA keypair"
        return 1
      }
      ;;
  esac

  openssl pkey -in "$_PAYLOAD_PRIVKEY" -pubout -out "$_PAYLOAD_PUBKEY" 2>/dev/null || {
    err "Failed to extract public key"
    rm -f "$_PAYLOAD_PRIVKEY"
    return 1
  }

  printf '%s' "$algo" > "$_PAYLOAD_KEYTYPE_FILE"
  chmod 600 "$_PAYLOAD_PRIVKEY"
  chmod 644 "$_PAYLOAD_PUBKEY"
  chmod 644 "$_PAYLOAD_KEYTYPE_FILE"
}

# ── Signing ──

# Sign a file → stdout: base64 signature (single line)
payload_sign() {
  local file="$1"

  [[ ! -f "$_PAYLOAD_PRIVKEY" ]] && {
    err "No signing key — run: muster fleet keygen"
    return 1
  }

  openssl pkeyutl -sign -inkey "$_PAYLOAD_PRIVKEY" -in "$file" 2>/dev/null \
    | base64 | tr -d '\n'
}

# Verify a file against a base64 signature using a pubkey file
# Returns: 0=valid, 1=invalid
payload_verify() {
  local file="$1" sig_b64="$2" pubkey_file="$3"

  local tmp_sig="/tmp/.muster_sig_verify_$$"
  printf '%s' "$sig_b64" | base64 -d > "$tmp_sig" 2>/dev/null

  local rc=1
  if openssl pkeyutl -verify -pubin -inkey "$pubkey_file" \
    -in "$file" -sigfile "$tmp_sig" 2>/dev/null; then
    rc=0
  fi

  rm -f "$tmp_sig"
  return $rc
}

# ── Fingerprint ──

# SHA256 fingerprint of the public key (short form for display)
payload_fingerprint() {
  local pubkey="${1:-$_PAYLOAD_PUBKEY}"
  [[ ! -f "$pubkey" ]] && return 1

  local hash
  hash=$(openssl pkey -pubin -in "$pubkey" -outform DER 2>/dev/null \
    | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')

  [[ -z "$hash" ]] && return 1
  # Short form: first 16 hex chars
  printf 'mst:%s' "${hash:0:16}"
}

# ── Authorized keys (target-side) ──

_payload_auth_keys_file() {
  local fp="$1"
  printf '%s/%s.json' "$_PAYLOAD_AUTH_KEYS_DIR" "$fp"
}

_payload_ensure_auth_dir() {
  if [[ ! -d "$_PAYLOAD_AUTH_KEYS_DIR" ]]; then
    mkdir -p "$_PAYLOAD_AUTH_KEYS_DIR"
    chmod 700 "$_PAYLOAD_AUTH_KEYS_DIR"
  fi
}

# Add a public key to the authorized keys for a project
payload_trust_key() {
  local pubkey_file="$1" label="$2" fingerprint="$3"

  _payload_ensure_auth_dir

  local auth_file
  auth_file=$(_payload_auth_keys_file "$fingerprint")

  # Create if missing
  if [[ ! -f "$auth_file" ]]; then
    printf '{"keys":[]}\n' > "$auth_file"
    chmod 600 "$auth_file"
  fi

  local pubkey_content
  pubkey_content=$(cat "$pubkey_file" 2>/dev/null)
  [[ -z "$pubkey_content" ]] && return 1

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Check if key already exists (by label)
  local existing
  existing=$(jq -r --arg l "$label" '.keys[] | select(.label == $l) | .label' "$auth_file" 2>/dev/null)
  if [[ -n "$existing" ]]; then
    # Update existing
    local tmp="${auth_file}.tmp"
    jq --arg l "$label" --arg pk "$pubkey_content" --arg ts "$ts" \
      '.keys = [.keys[] | if .label == $l then .pubkey = $pk | .added = $ts else . end]' \
      "$auth_file" > "$tmp" && mv "$tmp" "$auth_file"
  else
    # Append new
    local tmp="${auth_file}.tmp"
    jq --arg l "$label" --arg pk "$pubkey_content" --arg ts "$ts" \
      '.keys += [{"label": $l, "pubkey": $pk, "added": $ts}]' \
      "$auth_file" > "$tmp" && mv "$tmp" "$auth_file"
  fi

  chmod 600 "$auth_file"
}

# List authorized keys for a project fingerprint
payload_list_keys() {
  local fingerprint="$1"

  local auth_file
  auth_file=$(_payload_auth_keys_file "$fingerprint")

  [[ ! -f "$auth_file" ]] && return 0

  local count
  count=$(jq '.keys | length' "$auth_file" 2>/dev/null || echo 0)

  local i=0
  while (( i < count )); do
    local label added
    label=$(jq -r --argjson i "$i" '.keys[$i].label' "$auth_file" 2>/dev/null)
    added=$(jq -r --argjson i "$i" '.keys[$i].added' "$auth_file" 2>/dev/null)

    # Get fingerprint of this key
    local tmp_pub="/tmp/.muster_list_pub_$$"
    jq -r --argjson i "$i" '.keys[$i].pubkey' "$auth_file" 2>/dev/null > "$tmp_pub"
    local kfp
    kfp=$(payload_fingerprint "$tmp_pub" 2>/dev/null || echo "unknown")
    rm -f "$tmp_pub"

    printf '  %s  %b%s%b  %b%s%b\n' "$label" "${DIM}" "$kfp" "${RESET}" "${DIM}" "$added" "${RESET}"
    i=$(( i + 1 ))
  done
}

# Revoke an authorized key by label
payload_revoke_key() {
  local label="$1" fingerprint="$2"

  local auth_file
  auth_file=$(_payload_auth_keys_file "$fingerprint")

  [[ ! -f "$auth_file" ]] && return 1

  local tmp="${auth_file}.tmp"
  jq --arg l "$label" '.keys = [.keys[] | select(.label != $l)]' \
    "$auth_file" > "$tmp" && mv "$tmp" "$auth_file"
  chmod 600 "$auth_file"
}

# Read the public key PEM content
payload_read_pubkey() {
  [[ ! -f "$_PAYLOAD_PUBKEY" ]] && return 1
  cat "$_PAYLOAD_PUBKEY"
}
