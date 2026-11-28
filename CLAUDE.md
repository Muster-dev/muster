# Muster — LLM Guide

> Universal deploy framework. Pure bash (3.2+), zero dependencies, modular TUI.

## Quick Reference

```bash
muster setup       # interactive setup wizard (creates muster.json + hooks)
muster init        # alias for muster setup
muster setup --scan                  # non-interactive: auto-detect everything
muster setup --services api,redis    # non-interactive: explicit services
muster setup --force --scan          # start over (edited hooks backed up first)
muster setup --update --scan         # re-run: add new services, keep edits
muster setup --help                  # show all setup flags
muster setup --scan --dry-run --json # preview what setup would configure (writes nothing)
muster             # dashboard (live health + action menu + installed skills)
muster deploy      # deploy all (interactive: pick "All" or "Select services")
muster deploy api  # deploy one service
muster deploy svc1 svc2          # deploy multiple specific services
muster deploy --yes [svcs...]    # approve changed/unapproved hooks without prompting (CI)
muster deploy --dry-run        # preview deploy plan without executing
muster deploy --dry-run api    # dry-run a single service
muster deploy --json --stop-on-failure   # stop at first failure, rest reported not_run
muster deploy --from web       # resume from web in deploy order
muster deploy --no-preflight   # skip pre-deploy checks
muster explain                 # explain the last failure (offline rules engine)
muster explain api             # explain a service's newest log
muster explain --log FILE      # explain any log (works outside a project)
muster explain --json          # machine-readable (muster-tui)
muster explain --fix [--yes]   # explain, then run the suggested fix
muster dev         # deploy + watch health every 5s (Ctrl+C to cleanup)
muster status      # health check all services
muster logs <svc>  # stream logs for a service
muster logs <svc> --tail 200   # last N lines and exit (--follow to keep going, --json for events)
muster rollback <svc>  # rollback a service (interactive picker if no arg; --json streams events)
muster hooks approve [svc] [--yes]  # approve hooks on this machine (~/.muster/trust/)
muster restart <svc>   # restart without redeploying (restart.sh / kubectl / compose / docker, else redeploy)
muster hooks status --json     # per-file hook approval state
muster hooks approve --yes [svc] --json  # approve pending hooks without a prompt
muster history     # show deploy/rollback event log
muster history --all           # show full history (not just recent)
muster history api             # show history for one service
muster doctor      # run project diagnostics (6 categories)
muster doctor --fix            # safe fixes auto (permissions, stale PIDs/locks, old logs, .dockerignore); others ask
muster doctor --fix --yes      # run every available fix without asking
muster cleanup     # clean stuck processes + old logs
muster settings    # project settings + global muster settings
muster settings --global                  # dump global settings as JSON
muster settings --global color_mode never # set a global setting
muster uninstall   # remove muster from project
muster verify      # full file integrity check
muster verify --quick          # signature-only check
muster verify --json           # machine-readable output
muster --no-verify             # bypass startup integrity check
muster cloud login             # sign in to Fleet Cloud (device flow)
muster cloud status            # show Fleet Cloud login & relay status
muster cloud logout            # clear Fleet Cloud credentials
muster cloud login --qr        # also print a QR of the login URL (if qrencode is installed)
muster cloud connect           # pair this server: install muster-agent, code + QR, offer a service
muster ask [question]          # Muster Assistant (Fleet Cloud): explain failures, propose approved actions
muster ask --json              # NDJSON events for muster-tui; approvals via stdin
muster ask --server <name> [q] # ask about a fleet server (works anywhere; tools run on that server)
muster fleet init              # create fleet config
muster fleet add <name> user@host  # add machine (--mode, --transport, --port, --path, --key)
muster fleet remove <name>     # remove machine
muster fleet group <name> <machines...>  # create machine group
muster fleet ungroup <name>    # remove group
muster fleet list              # show machines and groups
muster fleet test [target]     # test SSH/cloud connectivity (--json: per-server ok/latency)
muster fleet deploy [target]   # deploy to machines (--parallel, --dry-run, --json)
muster fleet status [target]   # check health across fleet
muster fleet rollback [target] # rollback across fleet (--service, --parallel)
muster fleet logs <server> <svc> [--tail N] [--json]  # last N log lines from a server (no --follow)
muster fleet restart <server> [svcs...] [--yes] [--json]  # restart services on a server
muster fleet history <server> [svc] [--all] [--json]      # deploy history of a muster-mode server
muster fleet sync [target]     # sync project files to fleet
muster fleet pair <name> --token <t>  # manual auth pairing
muster group create <name>     # create project group
muster group add <name> <project> <path>  # add project to group
muster group deploy <name>     # deploy all projects in group
muster mcp install claude|claude-desktop|cursor|vscode [--allow-actions] [--write [--yes]]  # MCP client config
muster mcp doctor [--json]     # start the MCP server, check handshake + tools
muster mcp serve [flags]       # = muster-mcp [--project DIR] [--allow-actions] (stdio MCP server)
muster skill add <url>  # install a skill addon
muster skill list       # list installed skills
muster skill remove <n> # remove a skill
muster --minimal              # plain text dashboard (no TUI, for scripts/CI)
muster --minimal doctor       # PASS/WARN/FAIL plain text output
muster --minimal deploy api   # build context warnings as stderr comments
```

## Project Structure

```
muster/
├── bin/muster                     ← entry point (routes commands, startup integrity check)
├── bin/muster-mcp                 ← MCP server (stdio; 2026-07-28 + initialize-era; tools call `muster … --json`)
├── lib/core/                      ← config, colors, logger, platform, utils, engine (JSON helpers), scanner, credentials, remote, k8s_diag, updater, build_context, fleet, cloud, groups, app_verify, payload_sign, trust, hook_security, relay_guard, redact, assistant, hints, preflight, suggest, nextstep, setup_txn
├── lib/tui/                       ← menu, checklist, spinner, progress, streambox, dashboard, order
├── lib/commands/                  ← mcp (install/doctor/serve), setup (+setup_scan), deploy, dev, status, logs (+logs_api), rollback (+rollback_json), restart, history, doctor, cleanup, settings, uninstall, fleet, fleet_deploy, fleet_sync, fleet_agent, fleet_remote (test --json/logs/restart/history), group, verify, auth, trust, hooks (+hooks_api), diff, addon, projects, ask, cloud, explain
├── lib/agent/muster-agent.sh     ← standalone fleet monitoring daemon (no lib dependencies)
├── lib/skills/manager.sh          ← skill lifecycle (reads name from skill.json)
├── templates/deploy.example.json  ← example config
├── templates/hooks/               ← stack-specific hook templates (k8s, compose, docker, bare, dev)
│   ├── {k8s,compose,docker}/infra/ ← infrastructure service variants (pull-only, no build)
│   └── dev/                       ← local dev stack (PID-managed processes, docker compose infra)
├── docs/mcp.md                    ← MCP server: client setup, tools/resources/prompts, security model
├── docs/ENGINE-API.md             ← --json contract (every command/event shape; muster-tui relies on it)
├── docs/troubleshooting.md        ← generated from the rule table (make docs)
├── docs/fleet/fleet.md            ← fleet deployment guide
├── docs/skills/skills.md          ← skill authoring guide
├── FLEET.md                       ← fleet & cloud overview
└── install.sh                     ← installer (fetches from releases, generates integrity manifest)
```

## Per-Project Structure (generated by setup)

```
your-project/
├── muster.json        ← config: services, health checks, deploy order
├── .env               ← (optional) auto-loaded env vars for deploys
├── .musterignore      ← (optional) patterns to exclude from scanning
└── .muster/
    ├── hooks/<svc>/   ← deploy.sh, health.sh, rollback.sh, logs.sh, cleanup.sh
    ├── logs/          ← deploy logs (gitignored); .last_failure feeds explain/Next step
    ├── .template_hashes ← checksums of generated hooks (edit detection on re-run)
    ├── .menu_state    ← remembered picker choices
    └── pids/          ← PID files for dev stack (gitignored)
```

## Global Settings (~/.muster/settings.json)

| Setting | Default | Description |
|---------|---------|-------------|
| `color_mode` | `auto` | Color output: `auto`/`always`/`never` |
| `log_color_mode` | `auto` | Streamed deploy log colors: `auto`/`raw`/`none` |
| `log_retention_days` | `7` | Days to keep deploy logs |
| `default_stack` | `bare` | Default stack for setup (`bare`/`docker`/`compose`/`k8s`) |
| `default_health_timeout` | `10` | Health check timeout (seconds) |
| `scanner_exclude` | `[]` | Global patterns to exclude from scanning |
| `update_check` | `on` | Check for updates (`on`/`off`) |
| `update_mode` | `release` | Update channel: `release` or `source` (main branch) |
| `tui_mode` | `go` | Dashboard TUI backend: `go` (uses `muster-tui` if installed) or `bash` |
| `minimal` | `false` | Always use plain-text minimal mode (`true`/`false`) |
| `machine_role` | `""` | Machine role chosen during setup (`local`/`control`/`target`/`both`) |
| `deploy_name` | `""` | Custom deployer identity for locks/history (falls back to git `user.name` / `whoami`) |
| `service_lock_timeout` | `1800` | Stale timeout in seconds for fleet service locks (`60`–`86400`) |
| `signing` | `off` | Sign pushed fleet hook payloads (`on`/`off`) |
| `require_signing` | `off` | Require signed payloads in relay guard (`on`/`off`) |
| `hook_security` | `on` | Per-machine hook approval & dangerous-command gate (`on`/`off`) |
| `deploy_password_hash` | `""` | SHA-256 hash of optional deploy password (set via `muster settings --global deploy_password <pw\|off>`) |
| `assistant` | `on` | Muster Assistant on this machine (`on`/`off`, kill switch for `muster ask`) |
| `cloud.*` | `{}` | Fleet Cloud metadata (`cloud.relay`, `cloud.org_id`, `cloud.token_ref`, `cloud.token_id`, `cloud.name`); managed by `muster cloud login` / `logout` (token stored in OS keychain or `~/.muster/tokens/cloud.json`) |

Edit via `muster settings` (TUI) or `muster settings --global <key> <value>` (scripted).

## Hook Approvals, Exit Codes & Cancel Behaviour

**Per-machine hook approvals (`~/.muster/trust/`):** Hook approvals are stored per machine under `~/.muster/trust/<sha256-of-project-path>/` (`hooks.manifest`, HMAC signature `hooks.manifest.sig`, and approved file copies for diffs) — never committed to the repo. Before running deploy or rollback hooks, muster verifies the manifest signature and file hashes. Unapproved or modified hooks block execution until approved:
- Interactive (TTY): `muster deploy` / `muster rollback` offers to inspect the diff and approve, or run `muster hooks approve [service]` (shows pending files/diffs and prompts `[y/N]`).
- Non-interactive (CI/scripts): pass `--yes` (`muster hooks approve --yes`, `muster deploy --yes`, `muster rollback --yes`) or set `MUSTER_APPROVE_HOOKS=1`.

**Exit codes:**
- `0` — success (all selected services deployed/rolled back and passed health checks)
- `1` — failure, abort, missing/invalid config, lock conflict, or unapproved hooks
- `124` — hook exceeded `deploy_timeout` (default 120s)
- `130` — cancelled via Ctrl+C (`SIGINT`) or `SIGTERM`

**Ctrl+C / Cancel behaviour:** Pressing Ctrl+C (or sending `SIGTERM`) during `muster deploy` stops the active hook and its entire child process tree (including when wrapped by GNU `timeout`/`gtimeout`), releases both the project deploy lock and any per-service locks, logs a `cancelled` event in `.muster/logs/deploy-events.log`, emits `{"event":"cancelled"}` in `--json` mode, and exits `130`.

## Config (muster.json)

`muster setup` writes `muster.json`; an existing `deploy.json` is still read as a legacy fallback (`find_config` in lib/core/utils.sh).

Service keys map to hook directories. Health types: `http`, `tcp`, `command`; disabled via `"enabled": false`. `deploy_order` controls sequencing (infra services auto-sorted first when no explicit `--order`). `skip_deploy: true` excludes a service from `muster deploy` (auto-set for file-detected services not found as k8s deployments). Credential modes: `off`, `save` (keychain), `session` (memory), `always` (prompt every time) — never stored in config or git. Service keys with hyphens work (jq bracket notation via `_jq_quote()`).

K8s config: per-service `"k8s": {"deployment": "waity-api", "namespace": "waity"}`. Hooks read `MUSTER_K8S_DEPLOYMENT`, `MUSTER_K8S_NAMESPACE`, `MUSTER_K8S_SERVICE` env vars at runtime (exported by deploy/status/rollback commands from muster.json). `MUSTER_K8S_SERVICE` auto-converts underscores to hyphens (e.g., service key `api_v1` → `MUSTER_K8S_SERVICE=api-v1`) since k8s doesn't allow underscores in resource names. Change deployment name in config, all hooks update automatically. Optional `"deploy_timeout": 300` per-service (default 120) → exported as `MUSTER_DEPLOY_TIMEOUT`, used in k8s templates. Optional `"deploy_mode"` per-service → exported as `MUSTER_DEPLOY_MODE`.

K8s infra services use `kubectl rollout restart` (not `kubectl set image`) — they deploy whatever image version is in the YAML manifest, avoiding accidental `:latest` pulls.

Remote deployment: per-service `"remote": {"enabled": true, "host": "...", "user": "...", "port": 22, "identity_file": "~/.ssh/key", "project_dir": "/opt/app"}`. Hooks are piped via `ssh user@host "bash -s"` with credential + k8s env vars exported remotely.

Git pull: per-service `"git_pull": {"enabled": true, "remote": "origin", "branch": "main"}`. Runs `git pull <remote> <branch>` automatically before the deploy hook. For remote deploys, runs via SSH on the target machine. Defaults: remote=origin, branch=main. Configurable via `muster setup --git-pull svc[=remote:branch]` or `muster settings`.

.env auto-loading: `_load_env_file` in `lib/core/utils.sh` reads `.env` from the project root before deploy/rollback/dev. Exports `KEY=VALUE` pairs without overriding existing env vars. `_unload_env_file` cleans up after.

## Setup Wizard

**Interactive (no flags):** Scan-first TUI wizard. Detects project files (including subdirectories: `docker/`, `k8s/`, `deploy/`, `infra/`), identifies stack and services. User confirms/overrides, sets deploy order, configures health + credentials per service. Falls back to manual questions if nothing detected. Warns if muster.json already exists. Requires a TTY — errors cleanly if stdin is not interactive.

**Non-interactive (flags):** `muster setup --scan` or `muster setup --services api,redis --stack k8s`. Flags: `--path/-p`, `--scan`, `--stack/-s`, `--services`, `--order`, `--health` (repeatable), `--creds` (repeatable), `--remote` (repeatable, `svc=user@host[:port][:path]`), `--git-pull` (repeatable, `svc[=remote:branch]`), `--namespace`, `--name/-n`, `--force/-f` (overwrite existing config). See `muster setup --help`.

Both modes generate real hooks from stack templates. Infrastructure services (redis, postgres, etc.) get pull-only templates (no docker build). Scanner uses `.musterignore` and auto-skips `archived/deprecated/old/backup` directories.

**K8s live introspection:** When stack is k8s, `scan_k8s_cluster()` queries `kubectl get deployments -n <ns> -o json` to auto-detect real deployment names, container ports, and liveness/readiness probes. Strips common project prefix from names (e.g., `waity-api` → `api`). Deployments with probes get auto-configured health checks. Deployments with no probe and no port get `kubectl rollout status` as health fallback. Services detected from files but not found as k8s deployments get `skip_deploy: true`. Deploy order auto-sorts infra services (redis, postgres, etc.) before app services. Graceful degradation: no kubectl → skip, cluster unreachable → warn and skip.

## Deploy Failure Handling

Deploy and rollback failures show interactive recovery menus instead of aborting:

**Deploy failure:** Shows last 5 log lines → k8s diagnostics (if applicable) → fires skill hooks immediately with `MUSTER_DEPLOY_STATUS=failed` (so notifications like Discord go out before the user responds) → menu: Retry / Rollback / Skip and continue / Abort. Retry loops the same service with a fresh log file. The entire deploy execution is wrapped in a `while true` retry loop in `lib/commands/deploy.sh`.

**Rollback failure:** Same pattern → menu: Retry / Force cleanup and retry / Abort. "Force cleanup" runs the cleanup hook first, then retries rollback.

**K8s diagnostics** (`lib/core/k8s_diag.sh`): Auto-runs after deploy/rollback failure for k8s services. Inspects deployment → finds new ReplicaSet → finds failing pod → describes pod + gets logs. Matches 11 known error patterns (ImagePullBackOff, ErrImagePull, ErrImageNeverPull, InvalidImageName, OOMKilled, CrashLoopBackOff, CreateContainerConfigError, RunContainerError, Unschedulable, missing secrets, missing PVCs, version mismatch). Shows pod status line after diagnostics. Handles both local and remote kubectl via `_diag_run_kubectl`. Silently skips for non-k8s services.

**K8s smart rollout wait** (`_k8s_smart_wait()` in k8s deploy templates): Replaces bare `kubectl rollout status --timeout`. Starts rollout in background, polls pod status every 5s, prints progress (`"2/3 pods ready (15s)"`), and detects terminal errors immediately (ErrImageNeverPull, ImagePullBackOff, CrashLoopBackOff, OOMKilled, CreateContainerConfigError, RunContainerError, InvalidImageName). On terminal error: prints error, shows pod events/logs, kills rollout wait, exits non-zero. Uses deployment's label selector for pod matching.

**Dashboard** (`lib/tui/dashboard.sh`): Services panel auto-refreshes every 20s via `MENU_TIMEOUT=20` in menu.sh. Health check results are cached persistently in `~/.muster/.health_cache/` (not temp dir) so status survives across renders. Build context overlap detection runs on each refresh (cache-based — only re-scans when muster.json or .dockerignore changes). Shows warning banner and badges the Doctor menu item with `!` when issues found. `--minimal` mode outputs plain text service status and exits.

**Interactive service selection:** `muster deploy` with >1 service in a TTY shows "All services" / "Select services" menu. "Select services" opens a checklist (`lib/tui/checklist.sh`). Non-interactive (scripts, CI) deploys all as before.

## Rules Engine, Preflight & Explain

`lib/core/hints.sh` is an offline, deterministic table of failure rules (`_hr id 'ERE' 'title' 'try'`). Rules are matched against the last 300 log lines, the exit code (124 → `deploy_timeout`; with no log clue, 126/127/137) and the environment. The first match is the "likely cause", so specific rules come before generic ones. An optional `_hint_enrich_<id>` function refines the text and can attach `HINT_FIX_CMD`/`HINT_FIX_LABEL`. Fix commands are built only from validated values, and they run only after confirmation (`hints_run_fix`). Built-in fixes are `_hints_fix_*` functions that edit muster.json. `ssh_host_key` never gets a fix.

- Deploy/rollback failure: `hints_show_for_failure svc log rc` prints **Likely cause / Try** after `k8s_diagnose_failure` and records `.muster/logs/.last_failure`. The menu gets `Fix: <label>` when `HINT_FIX_CMD` is set. `--json` emits `{"event":"hint"}`.
- Health failure: `hints_health svc` probes the check (wrong port via the service's PID file, refused, timeout, 5xx, 4xx).
- `muster explain` (`lib/commands/explain.sh`) and `muster status` use the same engine.
- Preflight (`lib/core/preflight.sh`, `_preflight [--no-prompt] dir svc...`) runs these checks: tools/daemon, kube context/namespace/prod-context, disk, ports (dev/bare), hooks, env refs, git, stale locks, SSH. Blocking problems get Fix it / Continue anyway / Abort in a TTY, and exit 1 without one. `--no-preflight` skips them. Clean results are cached `MUSTER_PREFLIGHT_TTL` (60s) in `.muster/.preflight_ok`.
- Doctor reuses the preflight checks (Deploy Readiness) and groups its output as **Needs attention / Fine**. `--fix` applies safe fixes and asks before the rest.
- Adding a rule: add `_hr …` in the right priority spot and a fixture `tests/fixtures/hints/<id>__<name>.log`, then run `make docs`. `tests/test_hints.sh` checks every rule has a docs section.

## CLI Ergonomics

- Did-you-mean (`lib/core/suggest.sh`) uses edit distance or a unique prefix. It covers commands (read from bin/muster's router, so new commands are picked up automatically), deploy/setup/explain flags, and service names.
- Dashboard **Next step** (`lib/core/nextstep.sh`, `_next_step dir`) picks one suggestion: a recent unfixed failure (Explain), hooks needing approval, a stale lock (Doctor --fix), no deploys yet (Deploy), or an available update. Its action goes first in the menu, so Enter runs it.
- `menu_select` reads optional `MENU_REMEMBER=<key>` (per-project `.muster/.menu_state`) and `MENU_NONTTY_HINT`. It shows an empty state for zero options and truncates labels to the terminal width.
- Rollback from the picker and `muster cleanup` (`--yes` skips it) confirm first and say what will run.

## Setup Transactions

`lib/core/setup_txn.sh`: `_setup_txn_begin` creates `.muster-setup.XXXXXX` inside the project, and generation writes to `$_SETUP_TXN_CONFIG`/`$_SETUP_TXN_MUSTER`. `_setup_txn_commit` then merges everything into place. `_SETUP_TXN_MODE=update` merges muster.json (existing entries win) and keeps edited hooks. `fresh` backs edited hooks up. Ctrl+C before the commit removes the staging dir and exits 130. `MUSTER_TEST_SETUP_INTERRUPT=<checkpoint>` simulates that in tests. `_setup_dedupe_services` sanitizes keys and resolves collisions. `_setup_check_tools`, `_setup_verify_health` and `_setup_read_port` handle the "smart" prompts.

## Build Context Overlap Detection

`lib/core/build_context.sh` detects when one service's Docker build context (usually `.`) contains another service's directory in a monorepo. This causes cache invalidation, bloated contexts, and potential secret leakage.

**Detection flow:** Scan deploy hooks for `docker build` commands → extract context paths → compare pairwise for containment → check `.dockerignore` for exclusions → write results to cache.

**Cache:** `~/.muster/.build_context_cache`. Format: `parent_svc|child_svc|parent_context|child_dir` (one line per issue). Invalidated when muster.json or .dockerignore mtime changes.

**Integration points:**

| Where | Behavior |
|-------|----------|
| Dashboard (every refresh) | Run detection if cache stale, show warning banner + Doctor `!` badge |
| Deploy (before first build) | Read cache, show yellow warning line |
| Doctor (Storage & Maintenance) | Run fresh detection, show detailed diagnostics, `--fix` adds to .dockerignore |
| Setup (after hook generation) | Run detection, show fix suggestions |
| `--minimal` mode | Output `# warning:` comments to stderr |

## Dev Stack

Stack type `dev` for local development. App services use PID-managed background processes (`.muster/pids/`), infra services use docker compose. Templates in `templates/hooks/dev/` and `dev/infra/`. Scanner detects dev commands from project files (package.json → npm, go.mod → go run, requirements.txt → Django/FastAPI/Flask, etc.) via `_scan_detect_dev_cmds()` in `lib/core/scanner.sh`. `muster dev` (`lib/commands/dev.sh`) deploys all services then enters a health-watch loop (5s interval), with Ctrl+C triggering cleanup of all services.

## Fleet

Multi-machine deployment via `muster fleet`. Config in `remotes.json` (per-project). Two transports: SSH (direct) and Cloud (WebSocket relay via `muster-tunnel`/`muster-agent`). Two deploy modes: `muster` (remote has muster installed) and `push` (pipe hooks via SSH). Auth tokens stored at `~/.muster/fleet-tokens.json` (600 perms). Auto-pairing for muster mode machines. Sequential or parallel deploy (max 10 concurrent). Dashboard integration shows fleet connectivity. Doctor checks fleet SSH access.

Key files: `lib/core/fleet.sh` (config reader, SSH primitives, token storage), `lib/core/cloud.sh` (cloud transport helpers), `lib/core/groups.sh` (global fleet groups CRUD), `lib/commands/fleet.sh` (CLI handler), `lib/commands/fleet_deploy.sh` (deploy execution), `lib/commands/fleet_sync.sh` (file sync), `lib/commands/fleet_agent.sh` (agent monitoring), `lib/commands/fleet_remote.sh` (`fleet test --json`, `fleet logs`, `fleet restart`, `fleet history`, `_fleet_remote_muster`), `lib/agent/muster-agent.sh` (standalone daemon).

## Muster Assistant

`muster ask` (`lib/commands/ask.sh`) is the client for the paid assistant (protocol: `docs/assistant-and-pairing.md`, guide: `docs/assistant.md`). It requires a Fleet Cloud login (token from `_fleet_cloud_token_get default`), per-project consent stored in `.muster/assistant.json` (gitignored; `--yes` gives consent without a prompt), and it obeys the global kill switch `assistant off`. It streams SSE with `curl -N` through a single `jq` filter, renders markdown in bash, and runs the server-requested tools locally. Read tools run immediately. Action tools need `Run this? [y/N]` (TTY), `--allow-actions` (no TTY) or a stdin `{"approve":id}` (`--json`). The client classifies read vs action itself, and it validates every input: known tool, service exists, no shell metacharacters. Every result and the context go through `lib/core/redact.sh` (`redact_text`, jq-based, fails closed). JSON tool backends run `bin/muster` with a local `muster-assistant` API token (`~/.muster/assistant/local-token`). `_ask_supports` checks for engine-API commands (`logs --tail`, `hooks status`, `rollback --json`, `restart`) and falls back gracefully when they're missing. The deploy failure menu adds "Explain with AI" via `lib/core/assistant.sh` `_assistant_available`.

Remote mode (`muster ask --server <name>`): no project needed; the server must be muster-mode (cloud or SSH). Consent per server in `~/.muster/assistant/servers.json` (0600). Status is fetched first (`server_unreachable` before any session). Tools map to `_fleet_remote_muster` (lib/commands/fleet_remote.sh: status/history/hooks status/deploy/rollback), `muster fleet logs` and `muster fleet restart`; `read_config`/`read_hook`/`muster_doctor`/`propose_hook_edit` return "not available for remote servers yet". Context carries `surface: "cli"` + `remote: {server, transport, …}`.

`muster cloud connect` (`lib/commands/cloud.sh`) installs or updates muster-agent (≥ 0.4.0 for `pair`), runs `muster-agent pair`, offers `install-service` (sudo, or `--user-service`), then polls `muster-agent status --connected`.

## MCP Server

`bin/muster-mcp` (docs/mcp.md) is a dual-era stdio server: MCP 2026-07-28 (`server/discover`, per-request `_meta` version, `resultType`, `-32022`) plus the `initialize` handshake (2025-11-25 … 2024-11-05). Tools are thin wrappers over `muster … --json`, run with scoped local tokens (`muster-mcp-read` in `~/.muster/mcp/read-token`, `muster-mcp-deploy` only with `--allow-actions`/`MUSTER_MCP_ALLOW_ACTIONS=1`). It never runs hooks directly, never passes `--yes` to deploy/rollback and unsets `MUSTER_APPROVE_HOOKS`. Arguments are validated against each tool's `inputSchema` by a jq validator (`_MCP_VALIDATE_JQ`), then for service/fleet-name existence. Output goes through `redact_text`. Calls run as background workers (`_mcp_spawn`). Protocol output is on fd 3 behind a mkdir lock, `notifications/cancelled` SIGTERMs muster's process group (`muster.pids`), and `progressToken` streams NDJSON events as `notifications/progress`. Adding a tool: define it in `_MCP_TOOLS_JQ` (schema, outputSchema, annotations), write `tool_<name>` (print JSON, return 1 for a tool error), document it in docs/mcp.md and cover it in tests/test_mcp.sh. `muster mcp install|doctor|serve|tools` lives in lib/commands/mcp.sh.

## Groups

Multi-project orchestration via `muster group`. Config in `~/.muster/groups.json` (global). Groups coordinate deploys across multiple projects. Fleet = one project → many machines. Groups = many projects → one coordinated deploy. Both support SSH and cloud transports.

## App Integrity

File integrity verification via SHA256 manifest (`.muster.manifest`) + optional Ed25519/RSA signature (`.muster.manifest.sig`). Both are local-only artifacts (`.gitignore`d), generated at install/update time. Startup check in `bin/muster` uses inline bootstrap trust chain — verifies manifest signature with raw `openssl`, then hash-checks `app_verify.sh` and `payload_sign.sh` with `shasum` before sourcing. `--no-verify` flag or `MUSTER_NO_VERIFY=true` to bypass. Tamper detection shows which files changed, offers `git checkout` repair + manifest regeneration. `muster verify` command for on-demand checking. Doctor includes integrity check.

Key files: `lib/core/app_verify.sh` (manifest gen/verify), `lib/core/payload_sign.sh` (signing), `lib/commands/verify.sh` (verify command).

## JSON API

Every `--json` command prints only JSON on stdout (NDJSON for streams), human text on stderr, honours the `MUSTER_TOKEN` gate (`_json_auth_gate read|deploy`), and exits non-zero on failure. Escape strings with `_json_str` / `_json_esc` from `lib/core/engine.sh` (never hand-rolled sed). `err`/`warn`/`info` print to stdout — redirect them to stderr in JSON paths. Document shape changes in `docs/ENGINE-API.md` and cover them in `tests/test_engine_api.sh`.

## Bash 3.2 Rules

- No `local -a`, no namerefs, no fractional `read -t`
- Use `printf '%b'` not `echo -e` for ANSI
- Use `printf '%*s'` for padding (not `printf "%-Ns"` with ANSI)
- Use `#`/`-` for progress bars (not `█`/`░`)
- `tput cuu1` + `tput ed` for redraws (no `tput sc/rc`)
- SIGWINCH does not interrupt `read -rsn1` on macOS bash 3.2
- Resolve symlinks in entry points (no `readlink -f` on macOS — use a while loop)

## Editing Guidelines

- All TUI box widths: `W = TERM_COLS - 4`, max 50 (or 56 for banner), min 10
- Colors via variables from `lib/core/colors.sh` (never hardcode escapes)
- Array append: `arr[${#arr[@]}]=value` (not `arr+=()`)
- Test with `bash -n file.sh` for syntax validation
- Tests that touch docker/kubectl/lsof/ssh source `tests/mock_helpers.sh` (fake binaries on PATH); interactive flows use `tests/pty_drive.py` (`"expect=>send"` steps, `--minimal` numbered menus)
