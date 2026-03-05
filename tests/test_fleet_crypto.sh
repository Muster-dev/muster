#!/usr/bin/env bash
# tests/test_fleet_crypto.sh — Tests for fleet encryption (RSA-4096 + AES-256-CBC)
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"

# Check openssl is available
if ! command -v openssl >/dev/null 2>&1; then
  echo "  SKIP: openssl not available"
  exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

source "$MUSTER_ROOT/lib/core/fleet_config.sh"
source "$MUSTER_ROOT/lib/core/fleet_crypto.sh"

# Override after sourcing
FLEETS_BASE_DIR="${TMPDIR}/fleets"
mkdir -p "$FLEETS_BASE_DIR"

# ────────────────────────────────────────
echo "  Fleet crypto — key generation"
# ────────────────────────────────────────

# Create fleet dir first (keygen requires existing fleet dir)
mkdir -p "${FLEETS_BASE_DIR}/test-fleet"

# Generate keypair for test fleet
fleet_crypto_keygen "test-fleet" 2>/dev/null
_test_file_exists "private key generated" "${FLEETS_BASE_DIR}/test-fleet/fleet.key"
_test_file_exists "public key generated" "${FLEETS_BASE_DIR}/test-fleet/fleet.pub"

# Verify key is RSA-4096
_key_info=$(openssl rsa -in "${FLEETS_BASE_DIR}/test-fleet/fleet.key" -text -noout 2>/dev/null | head -1)
_test_contains "key is RSA-4096" "4096" "$_key_info"

# Verify permissions (should be 600)
_perms=$(stat -f "%Lp" "${FLEETS_BASE_DIR}/test-fleet/fleet.key" 2>/dev/null || stat -c "%a" "${FLEETS_BASE_DIR}/test-fleet/fleet.key" 2>/dev/null)
_test_eq "private key has 600 permissions" "600" "$_perms"

# ────────────────────────────────────────
echo ""
echo "  Fleet crypto — encrypt/decrypt roundtrip"
# ────────────────────────────────────────

# Create test data
echo "Hello from fleet agent! Service health: OK. CPU: 42%." > "${TMPDIR}/plaintext.txt"

# Encrypt (takes: input_file, output_file, pubkey_file)
_pubkey="${FLEETS_BASE_DIR}/test-fleet/fleet.pub"
_privkey="${FLEETS_BASE_DIR}/test-fleet/fleet.key"

fleet_crypto_encrypt "${TMPDIR}/plaintext.txt" "${TMPDIR}/encrypted.bin" "$_pubkey" 2>/dev/null
_test_file_exists "encrypted file created" "${TMPDIR}/encrypted.bin"

# Encrypted file should not contain plaintext
_enc_content=$(cat "${TMPDIR}/encrypted.bin" 2>/dev/null)
_test_not_contains "encrypted file is not plaintext" "Hello from fleet agent" "$_enc_content"

# Decrypt (takes: encrypted_file, output_file, privkey_file)
fleet_crypto_decrypt "${TMPDIR}/encrypted.bin" "${TMPDIR}/decrypted.txt" "$_privkey" 2>/dev/null
_test_file_exists "decrypted file created" "${TMPDIR}/decrypted.txt"

# Compare
_original=$(cat "${TMPDIR}/plaintext.txt")
_decrypted=$(cat "${TMPDIR}/decrypted.txt")
_test_eq "decrypt matches original" "$_original" "$_decrypted"

# ────────────────────────────────────────
echo ""
echo "  Fleet crypto — different data sizes"
# ────────────────────────────────────────

# Empty file
echo -n "" > "${TMPDIR}/empty.txt"
fleet_crypto_encrypt "${TMPDIR}/empty.txt" "${TMPDIR}/empty.enc" "$_pubkey" 2>/dev/null
fleet_crypto_decrypt "${TMPDIR}/empty.enc" "${TMPDIR}/empty.dec" "$_privkey" 2>/dev/null
_orig=$(cat "${TMPDIR}/empty.txt")
_dec=$(cat "${TMPDIR}/empty.dec")
_test_eq "empty file roundtrip" "$_orig" "$_dec"

# Larger data (JSON report)
cat > "${TMPDIR}/report.json" << 'EOF'
{
  "hostname": "prod-east-1",
  "timestamp": 1709596800,
  "services": {
    "api": {"status": "running", "pid": 12345, "cpu": 23.5, "memory_mb": 512},
    "redis": {"status": "running", "pid": 12346, "cpu": 1.2, "memory_mb": 128},
    "worker": {"status": "running", "pid": 12347, "cpu": 45.0, "memory_mb": 1024}
  },
  "disk": {"total_gb": 100, "used_gb": 67, "pct": 67},
  "load": [2.1, 1.8, 1.5]
}
EOF

fleet_crypto_encrypt "${TMPDIR}/report.json" "${TMPDIR}/report.enc" "$_pubkey" 2>/dev/null
fleet_crypto_decrypt "${TMPDIR}/report.enc" "${TMPDIR}/report.dec" "$_privkey" 2>/dev/null
_orig=$(cat "${TMPDIR}/report.json")
_dec=$(cat "${TMPDIR}/report.dec")
_test_eq "JSON report roundtrip" "$_orig" "$_dec"

# ────────────────────────────────────────
echo ""
echo "  Fleet crypto — wrong key fails"
# ────────────────────────────────────────

# Generate a second keypair
mkdir -p "${FLEETS_BASE_DIR}/other-fleet"
fleet_crypto_keygen "other-fleet" 2>/dev/null

# Try to decrypt with wrong key — should fail
_other_privkey="${FLEETS_BASE_DIR}/other-fleet/fleet.key"
_decrypt_result=0
fleet_crypto_decrypt "${TMPDIR}/encrypted.bin" "${TMPDIR}/wrong.txt" "$_other_privkey" 2>/dev/null || _decrypt_result=$?
_test "decrypt with wrong key fails" test "$_decrypt_result" -ne 0

_test_summary
