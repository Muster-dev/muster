# Fleet Encryption

> Hybrid RSA-4096 + AES-256-CBC encryption for fleet agent reports.

Fleet encryption ensures that agent push reports can only be read by the fleet owner (private key holder). The system uses hybrid encryption: a random AES-256-CBC session key encrypts the data, then the session key is wrapped with the fleet's RSA-4096 public key.

## How It Works

1. A random 32-byte AES-256 session key and 16-byte IV are generated per encryption
2. The plaintext data is encrypted with AES-256-CBC using the session key
3. The session key is encrypted (wrapped) with RSA-4096 using OAEP padding + SHA-256
4. The output is packed as three lines of base64

Only the fleet owner's RSA-4096 private key can unwrap the session key and decrypt the data.

## Pack Format

Encrypted files (`.enc`) contain exactly three lines:

```
<base64-encoded RSA-encrypted AES session key>
<base64-encoded IV>
<base64-encoded AES-256-CBC ciphertext>
```

Each line is a single base64 string with no line breaks. This format is simple to parse and transport via SCP.

## Key Storage

Fleet encryption keys are stored per-fleet:

| File | Permissions | Description |
|------|-------------|-------------|
| `~/.muster/fleets/<fleet>/fleet.key` | `600` | RSA-4096 private key (fleet owner only) |
| `~/.muster/fleets/<fleet>/fleet.pub` | `644` | RSA-4096 public key (distributed to agents) |

The public key is pushed to remote agents during `muster fleet install-agent --push`. Agents use it to encrypt reports before sending them back.

## Keypair Generation

```bash
muster fleet keygen <fleet>
```

Generates an RSA-4096 keypair for the fleet. If keys already exist, the command is a no-op (returns success without overwriting).

Internally calls `fleet_crypto_keygen()`:

1. `openssl genrsa -out fleet.key 4096` -- generate private key
2. `openssl rsa -in fleet.key -pubout -out fleet.pub` -- extract public key
3. Set file permissions (`600` private, `644` public)

## Functions

All functions are defined in `lib/core/fleet_crypto.sh`.

| Function | Description |
|----------|-------------|
| `fleet_crypto_keygen <fleet>` | Generate RSA-4096 keypair for a fleet (no-op if exists) |
| `fleet_crypto_has_keys <fleet>` | Check if a fleet has encryption keys (returns 0/1) |
| `fleet_crypto_pubkey <fleet>` | Print path to fleet public key |
| `fleet_crypto_privkey <fleet>` | Print path to fleet private key |
| `fleet_crypto_encrypt <in> <out> <pubkey>` | Encrypt a file using the public key |
| `fleet_crypto_decrypt <in> <out> <privkey>` | Decrypt a file using the private key |
| `fleet_crypto_report_dir <fleet> <hostname>` | Print path to report cache directory |
| `fleet_crypto_read_report <fleet> <hostname>` | Decrypt and cache a report; sets `_FCR_JSON` and `_FCR_AGE` |

## Report Cache

Decrypted reports are cached locally to avoid repeated decryption:

```
~/.muster/fleets/<fleet>/reports/<hostname>/latest.enc   # encrypted (from agent)
~/.muster/fleets/<fleet>/reports/<hostname>/latest.json  # decrypted cache
```

`fleet_crypto_read_report()` checks for a cached `.json` first. If only `.enc` exists, it decrypts with the fleet private key and caches the result. The function sets two globals:

- `_FCR_JSON` -- path to the decrypted JSON file
- `_FCR_AGE` -- age in seconds since last modification

## Used By

- **Agent push reports** -- The agent encrypts its summary JSON before SCP-ing it to the fleet HQ
- **`muster fleet keygen`** -- Generates the keypair
- **`muster fleet agent-status`** -- Reads and decrypts cached reports
- **`muster fleet install-agent --push`** -- Distributes the public key to remote agents

## Dependencies

- `openssl` (standard on Linux and macOS)
- No external libraries or tools required
