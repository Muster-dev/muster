#!/usr/bin/env bash
# muster/lib/core/fleet_crypto.sh — Fleet-level RSA-4096 encryption for agent reports
# Hybrid encryption: AES-256-CBC session key + RSA-4096 key wrapping
# Only the fleet owner (private key holder) can decrypt agent reports.

# ── Key paths ──
# Fleet keys live inside the fleet directory:
#   ~/.muster/fleets/<fleet>/fleet.key  (private, 600)
#   ~/.muster/fleets/<fleet>/fleet.pub  (public, 644)
# Reports cache:
#   ~/.muster/fleets/<fleet>/reports/<hostname>/latest.enc  (encrypted)
#   ~/.muster/fleets/<fleet>/reports/<hostname>/latest.json (decrypted cache)

# ── Keypair generation ──

# Generate RSA-4096 keypair for a fleet
# Usage: fleet_crypto_keygen <fleet_name>
fleet_crypto_keygen() {
  local fleet="$1"

  if ! command -v openssl >/dev/null 2>&1; then
    err "openssl required for fleet encryption"
    return 1
  fi

  local fdir
  fdir="$(fleet_dir "$fleet")"
  if [[ ! -d "$fdir" ]]; then
    err "Fleet '${fleet}' not found"
    return 1
  fi

  local privkey="${fdir}/fleet.key"
  local pubkey="${fdir}/fleet.pub"

  if [[ -f "$privkey" ]]; then
    return 0
  fi

  # Generate RSA-4096 private key
  openssl genrsa -out "$privkey" 4096 2>/dev/null || {
    err "Failed to generate RSA-4096 keypair"
    rm -f "$privkey"
    return 1
  }

  # Extract public key
  openssl rsa -in "$privkey" -pubout -out "$pubkey" 2>/dev/null || {
    err "Failed to extract public key"
    rm -f "$privkey" "$pubkey"
    return 1
  }

  chmod 600 "$privkey"
  chmod 644 "$pubkey"
  return 0
}

# Check if a fleet has encryption keys
fleet_crypto_has_keys() {
  local fleet="$1"
  local fdir
  fdir="$(fleet_dir "$fleet")"
  [[ -f "${fdir}/fleet.key" && -f "${fdir}/fleet.pub" ]]
}

# Get fleet public key path
fleet_crypto_pubkey() {
  local fleet="$1"
  printf '%s/fleet.pub' "$(fleet_dir "$fleet")"
}

# Get fleet private key path
fleet_crypto_privkey() {
  local fleet="$1"
  printf '%s/fleet.key' "$(fleet_dir "$fleet")"
}

# ── Encryption (used by agent push, or for local encryption) ──

# Encrypt a file using fleet public key (hybrid RSA+AES)
# Writes: <output_file>.enc (contains: key_len(4 bytes) + encrypted_aes_key + iv + ciphertext)
# Usage: fleet_crypto_encrypt <input_file> <output_file> <pubkey_file>
fleet_crypto_encrypt() {
  local input="$1" output="$2" pubkey="$3"

  [[ ! -f "$input" ]] && return 1
  [[ ! -f "$pubkey" ]] && return 1

  local tmpdir
  tmpdir=$(mktemp -d) || return 1

  # Generate random AES-256 session key + IV
  openssl rand 32 > "${tmpdir}/aes.key" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }
  openssl rand 16 > "${tmpdir}/aes.iv" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }

  # Encrypt the session key with RSA public key (OAEP padding)
  openssl pkeyutl -encrypt -pubin -inkey "$pubkey" \
    -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 \
    -in "${tmpdir}/aes.key" -out "${tmpdir}/aes.key.enc" 2>/dev/null || {
    rm -rf "$tmpdir"
    return 1
  }

  # Encrypt the data with AES-256-CBC
  local iv_hex
  iv_hex=$(xxd -p < "${tmpdir}/aes.iv" | tr -d '\n')
  local key_hex
  key_hex=$(xxd -p < "${tmpdir}/aes.key" | tr -d '\n')

  openssl enc -aes-256-cbc -in "$input" -out "${tmpdir}/data.enc" \
    -K "$key_hex" -iv "$iv_hex" 2>/dev/null || {
    rm -rf "$tmpdir"
    return 1
  }

  # Pack: base64(encrypted_key) + newline + base64(iv) + newline + base64(ciphertext)
  {
    base64 < "${tmpdir}/aes.key.enc" | tr -d '\n'
    echo ""
    base64 < "${tmpdir}/aes.iv" | tr -d '\n'
    echo ""
    base64 < "${tmpdir}/data.enc" | tr -d '\n'
    echo ""
  } > "$output"

  rm -rf "$tmpdir"
  return 0
}

# ── Decryption (fleet owner only) ──

# Decrypt an encrypted report using fleet private key
# Usage: fleet_crypto_decrypt <encrypted_file> <output_file> <privkey_file>
fleet_crypto_decrypt() {
  local input="$1" output="$2" privkey="$3"

  [[ ! -f "$input" ]] && return 1
  [[ ! -f "$privkey" ]] && return 1

  local tmpdir
  tmpdir=$(mktemp -d) || return 1

  # Unpack: line 1 = encrypted key, line 2 = iv, line 3 = ciphertext
  local enc_key_b64 iv_b64 data_b64
  enc_key_b64=$(sed -n '1p' "$input")
  iv_b64=$(sed -n '2p' "$input")
  data_b64=$(sed -n '3p' "$input")

  [[ -z "$enc_key_b64" || -z "$iv_b64" || -z "$data_b64" ]] && {
    rm -rf "$tmpdir"
    return 1
  }

  # Decode components
  printf '%s' "$enc_key_b64" | base64 -d > "${tmpdir}/aes.key.enc" 2>/dev/null
  printf '%s' "$iv_b64" | base64 -d > "${tmpdir}/aes.iv" 2>/dev/null
  printf '%s' "$data_b64" | base64 -d > "${tmpdir}/data.enc" 2>/dev/null

  # Decrypt session key with RSA private key
  openssl pkeyutl -decrypt -inkey "$privkey" \
    -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 \
    -in "${tmpdir}/aes.key.enc" -out "${tmpdir}/aes.key" 2>/dev/null || {
    rm -rf "$tmpdir"
    return 1
  }

  # Decrypt data with AES-256-CBC
  local iv_hex
  iv_hex=$(xxd -p < "${tmpdir}/aes.iv" | tr -d '\n')
  local key_hex
  key_hex=$(xxd -p < "${tmpdir}/aes.key" | tr -d '\n')

  openssl enc -aes-256-cbc -d -in "${tmpdir}/data.enc" -out "$output" \
    -K "$key_hex" -iv "$iv_hex" 2>/dev/null || {
    rm -rf "$tmpdir"
    return 1
  }

  rm -rf "$tmpdir"
  return 0
}

# ── Report cache ──

# Get local report cache directory for a fleet machine
fleet_crypto_report_dir() {
  local fleet="$1" hostname="$2"
  printf '%s/reports/%s' "$(fleet_dir "$fleet")" "$hostname"
}

# Decrypt and cache a report, return path to decrypted JSON
# Usage: fleet_crypto_read_report <fleet> <hostname>
# Sets: _FCR_JSON (path to decrypted json), _FCR_AGE (seconds since last update)
_FCR_JSON="" _FCR_AGE=0

fleet_crypto_read_report() {
  local fleet="$1" hostname="$2"

  _FCR_JSON=""
  _FCR_AGE=999999

  local rdir
  rdir="$(fleet_crypto_report_dir "$fleet" "$hostname")"

  # Check for cached decrypted report
  if [[ -f "${rdir}/latest.json" ]]; then
    _FCR_JSON="${rdir}/latest.json"
    # Calculate age
    local mtime now
    if [[ "$(uname -s)" == "Darwin" ]]; then
      mtime=$(stat -f '%m' "${rdir}/latest.json" 2>/dev/null || echo 0)
    else
      mtime=$(stat -c '%Y' "${rdir}/latest.json" 2>/dev/null || echo 0)
    fi
    now=$(date +%s)
    _FCR_AGE=$(( now - mtime ))
    return 0
  fi

  # Try to decrypt encrypted report
  if [[ -f "${rdir}/latest.enc" ]]; then
    local privkey
    privkey="$(fleet_crypto_privkey "$fleet")"
    if [[ -f "$privkey" ]]; then
      if fleet_crypto_decrypt "${rdir}/latest.enc" "${rdir}/latest.json" "$privkey"; then
        chmod 600 "${rdir}/latest.json"
        _FCR_JSON="${rdir}/latest.json"
        _FCR_AGE=0
        return 0
      fi
    fi
  fi

  return 1
}
