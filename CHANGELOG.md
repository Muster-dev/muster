# Changelog

All notable changes to muster are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.7.3] - 2026-11-28

### Added
- `muster ask --server <name>`: ask the Muster Assistant about a fleet server from any folder. Status, logs, deploy history and hook approvals are read on that server (SSH or Fleet Cloud) and redacted before they leave this computer; deploy, rollback and restart still need your approval. Consent is asked once per server.
- `muster fleet history <server> [svc] [--all] [--json]`: a server's deploy and rollback history.

## [0.7.2] - 2026-11-28

### Fixed
- `muster restart` (and `fleet restart`, `rollback --json`) waits up to 30 seconds (`MUSTER_HEALTH_WAIT`) for the service to come up before reporting it unhealthy, instead of checking once right after the restart.

## [0.7.1] - 2026-11-28

### Added
- `muster fleet logs <server> <service> [--tail N] [--json]`: read a server's logs over SSH or Fleet Cloud.
- `muster fleet restart <server> [service...] [--yes] [--json]`: restart services on a server (asks first).
- `muster fleet test --json`: per-server connectivity results with latency, for muster-tui and scripts.
- `status --json` and `fleet status --json` report `muster_version`.

### Changed
- Fleet output says "server"/"servers" instead of "machine(s)".
- `muster cloud login` names the login after this computer and its OS, says "Personal account", and lists the next steps; Fleet Cloud wording matches the dashboard (Servers, Access).
- `fleet deploy --dry-run` no longer lists cloud servers as unpaired.

### Fixed
- `muster ask` retries transient network and server errors instead of ending the conversation.
- The `forbidden` scope error in `--json` mode is valid JSON.
- Misaligned borders on fleet list, test, status and results boxes.

## [0.7.0] - 2026-11-26

### Added
- `muster ask`: the Muster Assistant (Fleet Cloud). Reads status, logs, history, doctor and hooks, explains what broke, and proposes actions that only run after you approve them. Everything is redacted on your machine before it's sent (`lib/core/redact.sh`); per-project opt-in in `.muster/assistant.json`; global kill switch `muster settings --global assistant off`; `--json` mode for muster-tui. The deploy failure menu offers "Explain with AI" when you're signed in.
- `muster cloud connect`: pair a server with Fleet Cloud using a code and QR (installs or updates muster-agent, runs `muster-agent pair`, offers to install it as a service). `muster cloud login --qr` prints a QR of the login URL when `qrencode` is installed.
- Offline failure explanations: 42 rules (`lib/core/hints.sh`) turn log lines, exit codes and environment into "Likely cause / Try", with a one-key "Fix: …" entry in the recovery menu when a safe fix exists. `muster explain [service|--last|--log FILE] [--json] [--fix]`. Reference: `docs/troubleshooting.md`.
- Preflight before every deploy: tools, Docker daemon, kube context/namespace, disk, ports, hook permissions, env vars, git state, stale locks, SSH reachability. Fix it / Continue anyway / Abort on a TTY; skip with `--no-preflight`.
- `muster setup --update` re-runs on an existing project, adding new services while keeping your muster.json changes and edited hooks; setup writes atomically (Ctrl+C leaves nothing half-written); health checks are probed before saving.
- "Did you mean…" for mistyped commands, flags and services; a "Next step" line on the dashboard; pickers remember your last choice; `muster doctor` groups output into "Needs attention" and "Fine" and `--fix` covers every fixable rule.
- Engine API for frontends and scripts, documented in `docs/ENGINE-API.md`:
  - `muster setup --scan --dry-run [--json]`: preview what setup would configure (stack, services, health, hook templates, deploy order, warnings) without writing anything
  - `muster hooks status [--json]`: per-file approval state (approved / changed / new / missing), plus muster.json and .env
  - `muster hooks approve --yes [service...] [--json]`: approve pending hooks without a prompt
  - `muster deploy --stop-on-failure` (rest reported as `not_run`) and `--from <service>` to resume
  - `muster rollback <service> --json` with the same events as deploy
  - `muster restart <service> [--json]`: restart.sh hook, `kubectl rollout restart`, `docker compose restart` or `docker restart`, else a clearly announced redeploy
  - `muster logs <service> --tail N [--follow] [--json]`
  - k8s failures in `--json` mode emit a `diagnosis` event (pattern, pod, pod status, hint, events, log tail)
  - richer `status --json` (stack, health target, last deploy, lock holder, k8s replicas, checked_at); `doctor --json` marks checks `fixable`; `history --json` includes `source`
  - `fleet list --json` / `fleet status --json` return one consistent shape for remotes.json and fleet dirs; `cloud status --json`

### Changed
- **Breaking for JSON consumers:** `fleet list --json` returns `machines` and `groups` as arrays of objects, and `fleet status --json` returns `{"status":[…]}` instead of a bare array. muster-tui needs an update to read the new shape.

### Fixed
- JSON output escapes tabs and control characters (log lines with tabs or ANSI colors produced invalid JSON)
- Remote deploys/rollbacks failed with exit 127 when GNU `timeout` was installed (it can't run shell functions)
- The curl/wget-pipe-to-shell dangerous-command patterns never matched
- `setup --scan` no longer turns an image name in docker-compose.yml (e.g. `nginx:alpine` on a `web` service) into an extra service
- `status --json` no longer prints prose into the JSON when a health hook is blocked
- `fleet status` counted healthy services from a field `status --json` never had

## [0.6.2] - 2026-11-26

### Fixed
- One Ctrl+C (or SIGTERM, e.g. cancelling in muster-tui) now cancels a running deploy: the hook and everything it started are stopped, locks released, history records "cancelled", exit code 130. Previously the hook kept running, the lock stayed, and the deploy could be recorded as "ok"
- Per-service `deploy_timeout` is honored for every stack (it only applied to k8s services) in deploy and rollback
- A muster.json that isn't valid JSON gets a clear parse error with line/column
- The live log box's bottom border was one column too wide, leaving stray characters

## [0.6.1] - 2026-11-26

### Fixed
- Installer: pairing muster-tui always failed with a misleading "jq may be missing" warning; it now pairs through the installed CLI (or says it connects on first run), and the version line no longer repeats the name
- `muster doctor` no longer warns about a missing `.env` (it's optional)
- Tests check file modes with GNU `stat` first, so the Linux CI job passes

## [0.6.0] - 2026-11-26

### Added
- `muster cloud login | logout | status`: sign in to Fleet Cloud with a browser device code; the CLI token is stored in the system keychain (0600 file fallback) and fleet/group cloud transport uses it automatically
- Cloud transport speaks to hardened Fleet Cloud agents (v0.3.0+) with plain `muster …` commands: fleet add/test/status/deploy/rollback and group deploy/status work end to end through the relay
- `muster init` alias for `muster setup`
- Setup infers health checks from compose ports, Dockerfile `EXPOSE`, k8s manifests and well-known infra ports
- One-screen quick setup: scan → summary → "Create it" (1 prompt instead of 8 for a typical compose app); per-service questions only under "Customize"
- Deploy summary table (service, result, time, health) and a final `{"event":"summary"}` line in `--json` mode
- Preflight checks before any hook runs: Docker/Compose running, Kubernetes context reachable
- Hook approval prompt (show diff / approve and deploy / abort); `--yes` / `MUSTER_APPROVE_HOOKS=1` for CI
- `muster deploy api web` deploys several services in the order given; flags may come anywhere
- `muster fleet add` creates the fleet config on first use
- muster-tui (the full-screen app) is the recommended default in the installer

### Changed
- Hook approvals live in a per-user trust store (`~/.muster/trust/`) instead of the repo, so teammates no longer see each other's hooks as "tampered"; old in-repo manifests are imported automatically
- Generated hooks are owner-writable (`755`); `muster hooks lock` is opt-in
- Generated `muster.json` no longer contains an absolute `root` path; service names default to their keys
- `muster deploy` / `rollback` exit 1 when any service fails, is blocked, or fails its health check (also in `--json` and CI)
- No ANSI escape codes or spinner frames when output is piped, `NO_COLOR` is set, or `color_mode=never`
- The installer only prompts when a terminal can actually be opened (CI / cloud-init installs work); `MUSTER_YES=1` forces non-interactive
- The token is passed to `muster-tunnel` via `MUSTER_CLOUD_TOKEN`, never on the command line
- Docs: `muster doctor` described as 6 diagnostic categories (not "13 checks"); fixed stale doc paths in CLAUDE.md/llms.txt; hook template counts now include the `dev` stack

### Fixed
- Concurrent `--json` calls could wipe every API token (shared temp file, no lock)
- Editing your own hook made `muster deploy` silently skip the service, print "Deploy complete" and exit 0
- `muster setup --scan` printed a raw `jq: error`
- `--minimal` reported disabled health checks as "unhealthy" (stale shared cache)
- `muster` inside an already configured project started first-run onboarding
- Cloud setup wizard stored the CLI token in plaintext in `~/.muster/settings.json`
- Remote `group add` saved a broken project (jq syntax error); rolling fleet deploy called missing functions; a failed fleet/group deploy retried forever without a TTY
- Tests could write skills and tokens into the real `~/.muster`
- Group deploy service picker matched selections by display name, so picking `api` in one project also selected every other project's `api`; selections are now mapped by item index
- Group deploy service picker deployed *all* services of a project when none of its services were selected; such projects are now skipped (and the progress total reflects the filtered selection)
- Scanner `_scan_hint` ran `grep` with no file arguments when no hint files existed, so it read stdin — hanging `muster setup --scan` (and the test suite) whenever stdin was an open pipe, or detecting services from piped input
- Group remote deploy broke when the deploy identity (e.g. git `user.name`) contained a single quote
- ShellCheck warnings (`--severity=warning`) across `lib/` so `make lint` passes in CI
- `make lint` ran ShellCheck over every file in one process, which was OOM-killed (and CI's ubuntu job cancelled); it now runs one file per invocation

## [0.5.60] - 2026-03-05

### Added
- Per-service deploy locks with team identity (`deploy_name` > git `user.name` > `whoami`); `--force` override; fleet-aware remote locks; dashboard shows `[locked by <name>]`
- Global settings `deploy_name` and `service_lock_timeout`
- First-run onboarding flow (splash → welcome → setup offer) and setup wizard step indicators
- LED dot-matrix splash animation (`lib/tui/matrix.sh`)
- Group deploy service picker: choose "All services" or select individual services per project (`checklist_grouped_select`)
- Group remote deploys auto-detect the remote project directory when none is configured, and forward the host's deploy identity via `MUSTER_DEPLOY_USER`
- New test files: `test_tui.sh`, `test_onboarding.sh`

### Changed
- Group projects are loaded from fleet-dir `project.json` configs
- Hooks are invoked as `bash "$hook"` (deploy, rollback, status, logs, cleanup, dev)
- Remote group/trust commands run with `MUSTER_NO_VERIFY=true`; sync-mode projects skip the remote trust gate
- `muster deploy` refreshes the build-context overlap cache when stale instead of only reading it

### Fixed
- Deploy lock `terminal` field recorded "not a tty" in non-interactive sessions

## [0.5.59] - 2026-03-05

### Added
- 7 new test files: deploy pipeline, rollback, status, doctor, build context, fleet deploy, dev stack (76+ new assertions)
- All 19 test files now pass (272 total assertions)
- CI: ShellCheck installation in GitHub Actions workflow
- CI: macOS compatibility job for bash 3.2 testing

## [0.5.58] - 2026-03-05

### Added
- Comprehensive test suite: fleet skills, fleet config, fleet crypto, skill lifecycle, skill templates, scanner, integrity (7 new test files, 120+ new tests)
- All 12 test files now pass (196 total assertions)

### Fixed
- `config_services()` null byte case pattern bug — `$'\0'` in case expands to empty string matching all keys, silently skipping every service
- Pre-existing `test_config.sh` failures (config_services lists api/redis)

## [0.5.57] - 2026-03-04

### Added
- Built-in skill templates: Discord, Slack, Webhook — all with fleet hook support
- `muster skill create discord/slack/webhook` copies from built-in templates instead of blank stub
- Skill create output now lists available built-in templates

### Changed
- Updated README.md: fleet skills section, fleet encryption/agents, documentation table, expanded commands table
- Updated FLEET.md: fleet skills section, fleet encryption, fleet skill/agent commands
- Updated docs/skills/skills.md: full fleet-aware Discord example, built-in templates section
- Reorganized docs into feature subfolders (deploy, fleet, skills, security, agent)

## [0.5.56] - 2026-03-04

### Added
- Fleet skill hooks: skills now fire during fleet deploy/rollback operations
- New fleet hooks: `fleet-deploy-start`, `fleet-deploy-end`, `fleet-machine-deploy-start`, `fleet-machine-deploy-end`, `fleet-rollback-start`, `fleet-rollback-end`
- Per-fleet skill configuration via `skills.json` (enable/disable skills per fleet, override config)
- Fleet env vars for skills: `MUSTER_FLEET_NAME`, `MUSTER_FLEET_MACHINE`, `MUSTER_FLEET_HOST`, `MUSTER_FLEET_STRATEGY`, `MUSTER_FLEET_MODE`
- `muster fleet skill list/enable/disable/configure` commands
- `run_fleet_skill_hooks()` in `lib/skills/manager.sh` — fleet-aware skill runner with config overlay

## [0.5.55] - 2026-03-04

### Added
- Fleet encryption: RSA-4096 keypair per fleet for encrypted agent reports
- Hybrid encryption: AES-256-CBC session keys wrapped with RSA-4096 (openssl)
- New `lib/core/fleet_crypto.sh` — fleet keygen, encrypt, decrypt, report cache
- Agent report encryption: scouts encrypt reports before pushing to HQ
- Setup Step 5 "Deploy scouts" — agent install integrated into fleet setup wizard
- Push + pull fallback: `fleet agent-status` reads local cache, falls back to SSH

### Changed
- `muster fleet keygen` now generates both signing and fleet encryption keys
- Agent push reports land in `~/.muster/fleets/<fleet>/reports/<host>/`
- Agent status displays encryption indicator and report age

## [0.5.54] - 2026-03-04

### Changed
- Fleet setup wizard: SSH config import, remote auto-detection, existing fleet selection
- Stack picker no longer shows duplicate entries when auto-detecting remote stack

## [0.5.53] - 2026-03-04

### Added
- Fleet directory-based config at `~/.muster/fleets/<fleet>/<group>/<project>/`
- New `lib/core/fleet_config.sh` — foundation API for fleet/group/project CRUD
- Auto-migration from legacy `groups.json` and `remotes.json` to fleet dirs
- Polished fleet setup wizard with streamlined 5-step flow

### Changed
- Fleet commands now read/write from directory structure instead of flat JSON
- Dashboard fleet panel uses fleet dirs with legacy fallback
- Doctor, deploy, sync, and agent commands support fleet dirs
- `groups.sh` delegates to `fleet_config.sh` (function signatures preserved)
- `fleet.sh` config CRUD replaced with shim mapping `_FP_*` to `_FM_*`

## [0.5.51] - 2026-03-04

### Fixed
- Installer now says "Downloading" instead of "Cloning" for fresh installs
- Minor bug fixes

## [0.5.50] - 2026-03-04

### Added
- App file integrity system — SHA256 manifest of all source files, verified on every launch
- `muster verify` command — full file-by-file integrity check (`--quick` for signature only, `--json` for machine output)
- `--no-verify` flag to bypass startup integrity check
- Inline bootstrap trust chain — verifies integrity libs themselves before sourcing (zero-dependency openssl + shasum)
- Tamper detection with interactive repair — shows which files changed, offers `git checkout` + manifest regeneration
- Doctor integration — `muster doctor` now checks app file integrity
- Post-install manifest generation — fresh installs get integrity tracking automatically
- Post-update manifest regeneration — updater regenerates manifest after pulling trusted code
- Makefile targets: `make manifest`, `make manifest-sign`, `make manifest-verify`
- Installer now shows version number during clone/update

## [0.5.47] - 2026-03-04

- Updated updater and minor bug fixes
- Installer now installs from official releases (not source)
- Downgrade protection when switching from source to release channel
- Source mode warnings for non-production use
- Updates panel in settings with changelog viewer
- Fleet Sync (beta)

## [0.5.45] - 2026-03-04

First official release on the Releases channel.

Please report bugs and issues at https://github.com/Muster-dev/muster/issues
