# muster env — config, secrets and feature flags in your repo

`muster env` keeps an app's configuration next to its code:

- **Config:** plain values in cleartext JSON. A change shows up in the PR diff.
- **Secrets:** encrypted one value at a time, to the people and machines allowed to read them.
  Key names stay readable, so a diff still shows *which* secret changed.
- **Feature flags:** in [flagd](https://flagd.dev)'s JSON format, so any OpenFeature flagd provider can read them.
  Without an SDK, an app reads each flag as an env var (`MUSTER_FLAG_<NAME>`).
- **Schema:** `muster.env.schema.json` declares every key, its type and where it is required.
  It drives `muster env check` (CI), `.env.example` and typed readers for TypeScript, Python and Go.

It works offline, needs no account, and the same files feed `muster deploy`.

> Status: Phase 1 (local, repo and CI). Pushing to servers, the dashboard and targeting rules are on the [roadmap](#roadmap-phase-2-and-3).

## Quickstart (Node app)

```bash
cd my-app                         # any repo; muster.json is optional
muster env init --from .env       # schema + .muster/env, imports your .env (secrets encrypted)
rm .env                           # values now live in .muster/env

muster env set STRIPE_KEY         # hidden prompt → stored encrypted
muster env set PORT=3000          # plain config
muster flag set new_checkout on   # feature flag

muster run -- npm run dev         # app gets PORT, STRIPE_KEY, MUSTER_FLAG_NEW_CHECKOUT…
```

Nothing is written to disk by `muster run`. The values go straight into the process environment.

**In CI**, check that every required key is set and valid:

```bash
muster env keygen --ci github --envs staging,production   # prints MUSTER_ENV_KEY once
```

Store the printed key as the CI secret `MUSTER_ENV_KEY`, commit `.muster/env/`, then add this to the workflow:

```yaml
- run: muster env check --env production        # exit 1 on missing/invalid keys
- run: muster run --env production -- npm test  # if tests need the values
```

`muster env check` runs without a key too. It then checks that each required key is present
(secret names are not encrypted) and warns that it couldn't verify secret values or the file MAC.

**Typed access in code** (zero dependencies):

```bash
muster env codegen ts             # → src/env.generated.ts (or env.generated.ts)
```

```ts
import { env } from "./env.generated";

app.listen(env.PORT);                  // number
stripe(env.STRIPE_KEY.reveal());       // secrets are a Secret: printing shows [REDACTED]
if (env.flags.newCheckout) { … }       // boolean, from MUSTER_FLAG_NEW_CHECKOUT
```

The module validates every key when it loads, and one error lists all the problems:
`DATABASE_URL is required in production; PORT must be a number`.
Python (`codegen py`, a `SecretStr` wrapper) and Go (`codegen go`, a `Secret` type) work the same way.

## Files

| Path | Committed | What |
|---|---|---|
| `muster.env.schema.json` | yes | keys (type, required, default, enum, pattern, format, min/max, description), flags, environments, codegen paths |
| `.muster/env/<env>.config.json` | yes | non-secret values `{"version":1,"env":"local","values":{…}}` |
| `.muster/env/base.config.json` | yes (optional) | values shared by every env |
| `.muster/env/<env>.secrets.json` | yes | encrypted values ([format](#security-model)) |
| `.muster/env/<env>.flags.json` | yes | flagd JSON |
| `.muster/env/recipients.json` | yes | public keys and the environments each may decrypt |
| `.muster/env/history.jsonl` | yes | who changed what (secrets as fingerprints only) |
| `.muster/env/local.override.json` | **no** | your personal overrides (`muster flag set --local`) |
| `.muster/runtime/flags.<env>.json` | **no** | merged flags for a running app (`MUSTER_FLAGS_FILE`) |
| `~/.muster/env-keys/identity.key` | never | your private key (0600) |

`muster env init` adds the uncommitted paths and `.env`/`.env.*` to `.gitignore`.

Values resolve from lowest to highest precedence:

1. schema defaults (never for secrets)
2. `base.config.json`
3. `<env>.config.json`
4. `<env>.secrets.json`
5. flags (as `MUSTER_FLAG_*`)
6. `local.override.json` (env `local` only)
7. variables already set in your shell. These win unless you pass `muster run --override`.

The environment is chosen by `--env`, then `$MUSTER_ENV`, then `env.default_env` in muster.json, then `local`.

## Commands

| Command | |
|---|---|
| `muster env init [--from .env] [--envs local,staging,production] [--recovery] [--guard\|--no-guard] [--yes]` | Sets up the store, creates your key and adds you as a recipient. Imports a dotenv file, inferring types: names like `*_SECRET`, `*_TOKEN`, `*_KEY`, `*PASSWORD*`, a URL with a password, or a known token format count as secrets. |
| `muster env set KEY[=VALUE]… [--env E] [--secret\|--config] [--type T] [--stdin] [-m MSG] [--force] [--no-schema]` | Leave out `=VALUE` for a hidden prompt, or pipe the value in. New keys are added to the schema with an inferred type. Values are validated against the schema. |
| `muster env get KEY [--env E] [--reveal] [--json]` | Secrets print as `‹secret:fingerprint›` unless you pass `--reveal`. |
| `muster env unset KEY… [--env E]` | Warns if the schema requires the key. |
| `muster env list [--env E] [--show-values] [--json]` | Lists keys with type and source. Secrets stay masked unless `--show-values`. |
| `muster env diff <a> <b> [--json] [--reveal]` | Secrets are reported as `same`/`changed`, never printed. |
| `muster env edit [--env E]` | Opens config and secrets in `$EDITOR` as a 0600 temp file in a 0700 dir (`/dev/shm` or `$XDG_RUNTIME_DIR` when available). The file is overwritten and removed on exit or Ctrl+C. Only changed secrets are re-encrypted. |
| `muster env history [KEY] [--env E] [--json] [--all]` | Shows the change log. |
| `muster env check [--env E] [--strict] [--no-decrypt] [--fail-on-stale] [--json]` | The CI gate. Errors: required keys missing; types, enum, pattern, format or min/max wrong; a secret stored in plaintext config; file MAC or value authentication failed; with `--strict`, undeclared keys. Warnings: no key, or a flag past its `stale_after` date. |
| `muster env pull [--env E] [--to .env] [--format dotenv\|json] [--force]` | Writes a 0600 file. Refuses unless the target is gitignored (or outside the repo). |
| `muster env example [--to FILE \| --stdout]` | Writes `.env.example` from the schema. |
| `muster env codegen ts\|py\|go\|all [--out PATH] [--package NAME] [--check]` | `--check` fails when the generated file is stale (for CI). |
| `muster env keygen [--ci NAME --envs a,b]` | Prints your public key, or creates a CI key (printed once) and adds it as a recipient. |
| `muster env recipient list\|add <id> --pubkey mstpub1… --envs a,b\|remove <id>\|sync` | Adding wraps the data key to the new key. Removing rotates the data key and lists the secrets to rotate at their source. |
| `muster env rekey [--env E]` | New data key, with every value re-encrypted. |
| `muster env guard install\|uninstall\|check [--staged]` | Pre-commit hook ([below](#pre-commit-guard)). |
| `muster run [--env E] [--override] -- <cmd…>` | Runs `cmd` with the env injected via `exec`, so signals and the exit code pass straight through. Also sets `MUSTER_ENV` and `MUSTER_FLAGS_FILE`. |
| `muster flag list\|get\|set\|toggle\|unset\|reset` | `set NAME VALUE [--env E] [--local] [--type bool\|string\|number\|json]`. VALUE is `on`/`off`, a variant name, or any value. `--local` changes only your own `local.override.json`. |

Add `--json` to `env list|get|diff|history|check` and `flag list|get` for machine-readable output ([ENGINE-API.md](ENGINE-API.md#env-and-flags)).

## Deploys

`muster deploy` (including `--json`), `rollback`, `restart`, `fleet deploy` and skill hooks call `_load_env_file`, which now also reads the store:

| muster.json | Result |
|---|---|
| `"env": {"source": "muster"}` | store, then `.env` |
| `.env` present (default) | `.env` only (behaviour unchanged) |
| no `.env`, `.muster/env` present | store |
| `"env": {"source": "dotenv"}` | `.env` only |

Set `"env": {"default_env": "production"}` or `MUSTER_ENV=production muster deploy` to pick the environment.

- **In memory only:** values are decrypted with `muster-crypt` and exported to the deploy process, so hooks see them.
  Nothing is written to disk, and existing variables win.
- **No key:** if secrets can't be decrypted on this machine, deploy prints a warning and continues with config only.
- **Logs:** hook output in `--json` mode is masked line by line before it reaches the log or stdout. Logs written
  while the env was loaded are scrubbed of every secret value when it is unloaded.
  The interactive stream box still shows the live output on your own terminal.
- **Remote services:** services with `remote.enabled` (hooks piped over SSH) still get only the variables muster forwards today (credentials, k8s). Delivering the env to servers is Phase 2.
- **Blocked names:** these are never injected, whatever the config says: `PATH`, `IFS`, `BASH_ENV`, `ENV`,
  `SHELLOPTS`, `PS4`, `HOME`, `LD_*`, `DYLD_*`, `BASH_FUNC_*`, `NODE_OPTIONS`, `PYTHONPATH`, `PERL5OPT`,
  `RUBYOPT` (the same list as muster-agent), plus muster's own `MUSTER_ENV*`/`MUSTER_TOKEN`.
  Without that, a committed config change could take over hook execution without going through hook approval.

`muster ask` also learns the loaded secret values (in memory), so redaction masks them even when there is no `.env`.

## Security model

All encryption happens in **`muster-crypt`**, a small static Go binary from
[muster-fleet-cloud](https://github.com/Muster-dev/muster-fleet-cloud) (`cmd/muster-crypt`, `pkg/envcrypt`;
protocol in its `docs/ENVCRYPT.md`). Bash 3.2 and macOS LibreSSL can't do XChaCha20 or ML-KEM safely.

- **Per value:** XChaCha20-Poly1305 under a per-file data key, with a random 24-byte nonce.
  The AAD binds `env|key`, so a ciphertext copied to another key or environment fails to decrypt.
- **Per file:** an HMAC-SHA256 (key derived from the data key with HKDF) over the version, env, revision and every
  key, ciphertext and fingerprint. Adding, removing or swapping entries outside muster fails the check.
- **Per recipient:** the data key is wrapped with hybrid **X25519 + ML-KEM-768**: HKDF-SHA256 over both shared
  secrets and a transcript hash, then ChaCha20-Poly1305. That's the same construction family as Fleet Cloud's
  E2E v2, under a separate domain label. An attacker would need to break both X25519 and ML-KEM to unwrap,
  which covers "harvest now, decrypt later" for secrets committed today.
- **Keys:** `mstpub1…` (public), `mstsec1…` (secret) and `mstrec1…` (recovery) are Bech32-encoded. Key files are 0600,
  and `muster-crypt` refuses to read one that group or others can read. CI uses `MUSTER_ENV_KEY`.
- **Fingerprints:** `hmac:xxxxxxxx` is a keyed HMAC of the value, so it can't be brute-forced without the data key.
  History and diffs use fingerprints. They change when the data key rotates.
- **Revoking:** `recipient remove` generates a new data key and re-encrypts every value, so the removed key can't read
  anything written afterwards. Anything they could read before must be rotated where it was issued; muster lists those keys.
- **No secrets in argv:** the bash side passes secrets to `muster-crypt` and `jq` only through pipes
  (`--rawfile /dev/fd/N`), never as arguments (`ps`) and never through here-strings
  (bash 3.2 writes those to temp files). `muster env set KEY=VALUE` with a secret warns about shell history.

What it does **not** protect against: someone who can read your private key, or a machine where the app runs and
prints its own environment. Plaintext `.env` files you create with `muster env pull` are your responsibility
(0600 and gitignored by default).

### Pre-commit guard

`muster env guard install` adds a `pre-commit` hook. An existing hook is kept and still runs after the guard.
The guard blocks a commit that stages any of:

- a `.env` or `.env.*` file (`.env.example`, `.sample` and `.template` are allowed)
- a muster secret key (`mstsec1`/`mstrec1`)
- a `*.secrets.json` with a value that is not encrypted
- a schema-secret key inside a `*.config.json`
- `local.override.json` or `.muster/runtime/*`
- **any file containing the value of a secret you can decrypt** (it reports the key name, never the value)

Without muster on the machine, the hook falls back to the first two checks. Bypass it once with `git commit --no-verify`.

## How it compares

Only properties that matter for this use case are listed. Check each vendor's current docs for pricing and plans.

| | muster env | dotenvx | SOPS + age | Doppler / Infisical (cloud) | 1Password `op run` | OpenFeature + flagd |
|---|---|---|---|---|---|---|
| Lives in the repo, works offline | ✓ | ✓ | ✓ | – (cached fallback) | – | ✓ (flags only) |
| Server can't read secrets | ✓ (no server) | ✓ (no server) | ✓ with age | – (provider decrypts) | ✓ (E2E vault) | n/a |
| Per-person recipients (revoke one) | ✓ | – (one key per env) | ✓ | ✓ (access control) | ✓ | n/a |
| Post-quantum key wrapping | ✓ (X25519+ML-KEM-768) | – | – | – | – | n/a |
| `run -- cmd` injection | ✓ | ✓ | `exec-env` | ✓ | ✓ | n/a |
| Schema, CI check, `.env.example` | ✓ | – | – | partial | – | – |
| Typed codegen (TS/Py/Go) | ✓ | – | – | – | – | – |
| Feature flags in the same tool | ✓ (simple; targeting is Phase 3) | – | – | – | – | ✓ (targeting, rollouts) |
| Deploy-aware (hooks get the env) | ✓ | – | – | integrations | – | – |
| Push to servers end-to-end encrypted | Phase 2 | – | – | ✓ (via provider) | Connect server | – |

## Deviations from the design spec

The spec (`muster-env-spec.md`) was a draft. Phase 1 differs from it where the real code or safety called for it:

- **Key storage.** Keys live in `~/.muster/env-keys/` (0600), not `env_keys/` or the OS keychain.
  Passphrase-protected key files and keychain storage are not done.
- **Recipient kinds.** Only `hybrid-x25519-mlkem768`. The classical `x25519` kind (age or ssh-ed25519 keys) and the git
  merge driver are not in v1.
- **MAC encoding.** It uses length-prefixed fields instead of canonical JSON, and it also covers the revision and the
  fingerprints. The recipient list is outside the MAC; see `docs/ENVCRYPT.md` in muster-fleet-cloud.
- **Flags file.** `muster run` writes merged flags to `.muster/runtime/flags.<env>.json` (gitignored; flags aren't
  secret) rather than a temp file. `exec` leaves nothing to clean up a temp file, and
  `muster flag set --local` rewrites the file so a running app can hot-reload.
- **Schema changes.** `env set` adds unknown keys to the schema automatically (`--no-schema` to skip) instead of asking.
- **Recovery key.** It is opt-in (`env init --recovery`) instead of automatic, so no secret is printed into CI logs by default.
- **Codegen.** It writes a single `.ts` file (types and loader together, no separate `env.d.ts`). The TS uses only
  erasable syntax, so Node can run it with type stripping. Numbers are `int` in Python and Go only when the schema says
  `"integer": true` (`init` sets that for whole-number values).
- **Trust manifest.** Env files are not part of the hook trust manifest. Instead, dangerous variable names are refused
  at injection time, so `muster env set` doesn't force a hook re-approval on every change.
- **Not done:** `env rollback`, `doctor` and `preflight` integration, MCP tools and an Engine-API token gate for the
  `env` commands. These are listed in the roadmap.

## Roadmap (Phase 2 and 3)

**Phase 2 — servers, history and visibility**

- `muster-fleet-cloud`: add a size-limited `CommandRequest.Stdin`, `muster-tunnel exec --stdin-file`, and agent allowlist
  entries `muster env apply|status|history|rollback` and `muster flag apply`. Payloads arrive on stdin, never in argv.
- `muster env recipient add --server <name>`: build a server recipient from the agent's already-pinned identity keys
  (`cloud_known_agents.json`; the X25519 and ML-KEM keys exist). Needs a converter from the agent's raw keys to `mstpub1`.
- `muster env push` / `muster flag push`: diff the remote state, ask for approval, then apply on the server, either
  writing `.env` (0600, atomic) or in `hooks_only` mode (stays encrypted on the server, decrypted per hook).
  The `_config/.env` trust manifest entry is updated, affected services restarted per `restart_policy`, health checked,
  and a rollback offered.
- `muster env rollback <rev>`, a server-side audit log, and `muster history` integration.
- Engine API token gates (`_json_auth_gate`) for the `env --json` commands, plus muster-tui's Env & Flags screen.
- Fleet Cloud dashboard: inventory and drift (metadata only), and flag toggles.
  Opt-in zero-knowledge sync uploads ciphertext only.
- `muster doctor` (Environment & Secrets category) and preflight `env check` before deploys.

**Phase 3 — OpenFeature, targeting, canaries, assistant**

- Targeting rules and percentage rollouts in the flagd format (`muster flag rollout|rule|kill|eval`), with
  MurmurHash3 bucketing shared with flagd's test vectors.
- Thin OpenFeature providers with hot reload (Node, Python, Go) and typed flag codegen.
- Canary and blue-green track-scoped flags (`--track`, `MUSTER_ROLLOUT_TRACK`) tied to promote/abort.
- Assistant tools (`muster_env_status`, `muster_flag_list`, `propose_flag_change`, …) and MCP tools.
  None of them can read secret values.
- Classical `x25519` recipients, a merge driver for `*.secrets.json`, and keychain storage for keys.
