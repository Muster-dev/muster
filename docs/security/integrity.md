# App File Integrity

> SHA-256 manifest verification for muster's own source files.

The integrity system detects unauthorized modifications to muster's source files. It generates a SHA-256 manifest of all tracked files, optionally signs it, and verifies on demand.

## How It Works

1. After install or update, a manifest (`.muster.manifest`) is generated containing SHA-256 hashes of all source files
2. The manifest is optionally signed with the payload signing key (`.muster.manifest.sig`)
3. `muster verify` re-hashes files and compares against the manifest
4. Tampered or missing files are flagged

## Tracked Files

The manifest covers all muster source files:

| Pattern | Description |
|---------|-------------|
| `bin/muster`, `bin/muster-mcp` | Entry points |
| `lib/core/*.sh` | Core libraries |
| `lib/commands/*.sh` | Command modules |
| `lib/tui/*.sh` | TUI components |
| `lib/skills/*.sh` | Skill manager |
| `lib/agent/*.sh` | Agent daemon |
| `templates/hooks/**/*.sh` | Hook templates (two levels deep) |
| `install.sh` | Installer |

## Manifest Format

The manifest is a JSON file at `<MUSTER_ROOT>/.muster.manifest`:

```json
{
  "version": "0.5.51",
  "generated_at": "2026-03-04T12:00:00Z",
  "file_count": 42,
  "files": {
    "bin/muster": { "sha256": "abc123...", "size": 4096 },
    "lib/core/utils.sh": { "sha256": "def456...", "size": 2048 }
  }
}
```

## Verification Modes

### Quick Verify (`--quick`)

Checks only the manifest signature, not individual file hashes. Fast but only confirms the manifest itself has not been tampered with.

```bash
muster verify --quick
```

Logic:
- No manifest file: pass (dev install)
- Manifest exists but no signature: fail
- No public key configured: pass (signing not set up)
- Signature valid: pass
- Signature invalid: fail

### Full Verify (default)

Re-hashes every tracked file and compares against the manifest. Also checks for extra files not in the manifest.

```bash
muster verify
```

Each file gets one of four results:

| Result | Meaning |
|--------|---------|
| `pass` | SHA-256 matches manifest |
| `tampered` | SHA-256 does not match |
| `missing` | File listed in manifest but not on disk |
| `extra` | File on disk but not in manifest |

### JSON Output

```bash
muster verify --json
```

Outputs structured verification results for scripting and CI.

### Skip Verification

```bash
muster --no-verify <command>
```

Skips the integrity check for a single invocation.

## Tamper Detection

When verification fails, muster reports which files are tampered or missing with a summary:

```
  FAIL -- 40 passed, 1 tampered, 1 missing
```

The interactive repair flow guides the user to reinstall or restore affected files.

## Manifest Generation

The manifest is regenerated automatically:

- After `install.sh` completes
- After `muster` self-updates

The signing step (`_app_manifest_sign`) uses `payload_sign()` from the payload signing system. If no signing key exists, the manifest is unsigned.

## Functions

All functions are defined in `lib/core/app_verify.sh`.

| Function | Description |
|----------|-------------|
| `_app_tracked_files` | List all tracked file paths (relative to MUSTER_ROOT) |
| `_app_manifest_generate` | Generate `.muster.manifest` with SHA-256 hashes |
| `_app_manifest_sign` | Sign the manifest using `payload_sign()` |
| `_app_verify_quick` | Signature-only verification |
| `_app_verify_full` | Full re-hash verification of all files |
| `_app_verify_report` | Print human-readable verification results |

### Result Globals (set by `_app_verify_full`)

| Variable | Description |
|----------|-------------|
| `_APP_VERIFY_PASS` | Count of files that matched |
| `_APP_VERIFY_TAMPERED` | Count of files with hash mismatch |
| `_APP_VERIFY_MISSING` | Count of files missing from disk |
| `_APP_VERIFY_EXTRA` | Count of files not in manifest |
| `_APP_VERIFY_VERSION` | Version string from manifest |
| `_APP_VERIFY_FILES[]` | Array of file paths checked |
| `_APP_VERIFY_RESULTS[]` | Parallel array of per-file results |

## Dependencies

- `shasum` (standard on macOS and Linux)
- `openssl` (for signature verification, optional)
- `jq` (preferred for JSON parsing, with grep/sed fallback)
