<p align="center">
  <img src="assets/banner.png" alt="muster" width="100%" />
</p>

<p align="center">
  Universal deploy framework with a beautiful TUI. Pure bash, zero dependencies, fully modular.
</p>

<p align="center">
  <a href="https://getmuster.dev">Website</a> · <a href="https://github.com/Muster-dev/muster">GitHub</a> · <a href="https://github.com/Muster-dev/muster/issues">Issues</a>
</p>

---

**muster** gives any project a polished deploy experience — interactive dashboard, health checks, rollback, log streaming — regardless of stack. It doesn't know how to deploy your app. It knows how to run your scripts beautifully and verify everything works.

## Install

```bash
curl -fsSL https://getmuster.dev/install.sh | bash
```

Or clone manually:

```bash
git clone https://github.com/Muster-dev/muster.git ~/.muster/repo
ln -s ~/.muster/repo/bin/muster ~/.local/bin/muster
ln -s ~/.muster/repo/bin/muster-mcp ~/.local/bin/muster-mcp
```

Or add to your shell profile (`.zshrc` / `.bashrc`):

```bash
export PATH="$PATH:/path/to/muster/bin"
```

## Quick Start

```bash
cd your-project
muster setup       # guided wizard — scans project, creates muster.json + hook scripts
muster             # open the dashboard
```

Or skip the wizard entirely with flags:

```bash
muster setup --scan                                     # auto-detect everything
muster setup --stack k8s --services api,redis,worker    # explicit
muster setup --scan --health api=http:/health:3000      # scan + custom health
muster setup --scan --namespace production              # set k8s namespace
muster setup --scan --remote api=deploy@prod:/opt/app   # remote SSH deploy
muster setup --help                                     # see all flags
```

## Commands

| Command | Description |
|---------|-------------|
| `muster` | Dashboard — live health/status view (auto-refreshes every 20s) with action menu + installed skills |
| `muster setup` / `muster init` | Guided setup wizard (`init` is an alias for `setup`), or use flags for non-interactive (`--help`) |
| `muster setup --update` | Re-run on an existing project: add new services, keep your changes and edited hooks |
| `muster setup --force` | Start over (edited hooks are backed up first) |
| `muster deploy` | Deploy all services (respects deploy order) |
| `muster deploy api` | Deploy a specific service |
| `muster deploy svc1 svc2` | Deploy multiple specific services in order |
| `muster deploy --yes` | Approve unreviewed/changed hooks non-interactively (CI) |
| `muster deploy --dry-run` | Preview deploy plan without executing |
| `muster deploy --stop-on-failure` | Stop at the first failed service (resume with `--from <svc>`) |
| `muster deploy --no-preflight` | Skip the pre-deploy checks (tools, cluster, disk, ports, env, git, SSH) |
| `muster explain [svc]` | Explain the last failure in plain words: likely cause, what to try, one-key fix (`--log FILE`, `--json`, `--fix`) |
| `muster status` | Check health of all services |
| `muster logs` | Stream logs (interactive service picker) |
| `muster logs api --tail 200` | Print the last N lines and exit (`--follow`, `--json`) |
| `muster rollback` | Rollback a service |
| `muster hooks approve [svc] [--yes]` | Review and approve hooks on this machine (`~/.muster/trust/`) |
| `muster restart api` | Restart a service without redeploying |
| `muster hooks status` | Show which hooks are approved on this machine |
| `muster doctor` | Run project diagnostics (6 categories) |
| `muster doctor --fix` | Auto-fix what it can (permissions, stale PIDs, old logs, .dockerignore) |
| `muster cleanup` | Clean up stuck processes and old logs |
| `muster settings` | Project settings + global muster preferences |
| `muster settings --global` | View/edit global settings (color, log retention, lock timeout, etc.) |
| `muster uninstall` | Remove muster from project |
| `muster verify` | Verify file integrity of muster installation |
| `muster cloud login` | Sign in to Fleet Cloud via device flow (`--qr` for a QR code; `logout`, `status` also available) |
| `muster cloud connect` | Pair this server with Fleet Cloud: installs muster-agent, shows a code + QR to approve, offers a service |
| `muster ask [question]` | Ask the Muster Assistant why a deploy failed and what to do (Fleet Cloud; actions need your approval) |
| `muster fleet` | Fleet manager — deploy to multiple machines |
| `muster fleet deploy` | Deploy project to fleet machines |
| `muster fleet status` | Check health across fleet |
| `muster fleet rollback` | Rollback across fleet (`--service`, `--parallel`) |
| `muster fleet skill list <fleet>` | Show skills enabled for a fleet |
| `muster fleet skill enable <fleet> <skill>` | Enable a skill for fleet events |
| `muster fleet skill disable <fleet> <skill>` | Disable a fleet skill |
| `muster fleet skill configure <fleet> <skill>` | Set fleet-specific skill config |
| `muster group` | Group orchestration — coordinate multi-project deploys |
| `muster skill add <url>` | Install a skill addon |
| `muster skill list` | List installed skills |
| `muster skill create <name>` | Scaffold a new skill |
| `muster skill configure <name>` | Set API keys, webhooks, etc. |
| `muster skill enable <name>` | Enable auto-run on hooks |
| `muster skill remove <name>` | Remove a skill |

## How It Works

muster is an **orchestrator**, not a deployment tool. Your project provides hook scripts that do the actual work — muster runs them in order, shows beautiful output, and verifies health.

### Smart Setup

`muster setup` scans your project first — detects Dockerfiles, docker-compose configs, Kubernetes manifests, language files, and config references. It checks subdirectories too (`docker/`, `k8s/`, `deploy/`, `infra/`). It identifies your stack (k8s, compose, docker, or bare metal) and discovers services automatically. Infrastructure services (redis, postgres, etc.) get pull-only templates instead of build templates.

**On k8s clusters**, the scanner goes further — it queries `kubectl get deployments` to read real deployment names, container ports, and liveness/readiness probes directly from the cluster. Health checks are auto-configured from probe data (HTTP endpoints, TCP ports, or `kubectl rollout status` for deployments without probes). Deploy order is smart: infra services (redis, postgres, meilisearch) are sorted before app services. Services detected from files but not running as k8s deployments are automatically marked `skip_deploy: true`.

You confirm what it found, set deploy order, configure health checks and credentials per service, and muster generates **real working hook scripts** from stack-specific templates — not empty stubs.

If nothing is detected (empty project), it falls back to a conversational question flow. Re-running setup offers **Update (keep my changes)**, which adds new services without clobbering hooks you edited. Setup is atomic: Ctrl+C never leaves partial files.

### When things go wrong

muster explains failures without any AI, using an offline rules engine:

- **Before deploying**, preflight catches the usual suspects: Docker not running, the wrong kube context, a missing namespace, a full disk, a busy port, a non-executable hook, unset env vars, stale locks, an unreachable SSH host. Blocking problems offer *Fix it / Continue anyway / Abort*.
- **When a deploy fails**, you get **Likely cause / Try** above the recovery menu, plus a **Fix: …** entry when there's a safe one-key fix (stop the container holding the port, raise `deploy_timeout`, move the database earlier in `deploy_order`, …).
- **Later**, run `muster explain` (or `--json`), `muster doctor --fix`, or follow the dashboard's *Next step* line.
- **Typos** get a suggestion: `muster deplyo` → *Did you mean: deploy?*

Every rule is listed in [docs/troubleshooting.md](docs/troubleshooting.md).

### Setup creates this in your project:

```
your-project/
├── muster.json              ← config (generated by setup wizard)
└── .muster/
    └── hooks/
        ├── api/
        │   ├── deploy.sh    ← real deploy commands for your stack
        │   ├── health.sh    ← real health check
        │   ├── rollback.sh  ← real rollback logic
        │   ├── logs.sh      ← log streaming
        │   └── cleanup.sh   ← cleanup stale resources
        └── redis/
            ├── deploy.sh
            ├── health.sh
            └── ...
```

### muster.json

Clean, human-readable config:

```json
{
  "project": "myapp",
  "version": "1",
  "services": {
    "api": {
      "name": "API Server",
      "health": {
        "type": "http",
        "endpoint": "/health",
        "port": 8080,
        "timeout": 10,
        "enabled": true
      },
      "credentials": { "mode": "off" },
      "k8s": {
        "deployment": "myapp-api",
        "namespace": "production"
      }
    },
    "redis": {
      "name": "Redis",
      "health": {
        "type": "tcp",
        "port": 6379,
        "timeout": 5,
        "enabled": true
      },
      "k8s": {
        "deployment": "myapp-redis",
        "namespace": "production"
      }
    }
  },
  "deploy_order": ["redis", "api"]
}
```

The `k8s` block is config-driven — change `deployment` or `namespace` in muster.json and all hooks update automatically (hooks read `MUSTER_K8S_*` env vars at runtime). Service keys with underscores are auto-converted to hyphens for k8s names (e.g., `api_v1` → `MUSTER_K8S_SERVICE=api-v1`). `deploy_order` controls sequencing — infra services are auto-sorted first by the scanner.

Operations without hooks are silently skipped — no errors, no empty menu items.

## Dry Run

Preview what a deploy would do — without executing anything:

```bash
muster deploy --dry-run            # all services
muster deploy --dry-run api        # single service
```

Shows the hook script content, credential keys (not values), health check status, remote target, and deploy order. Useful for building confidence before first deploys.

## Remote Deployment (SSH)

Deploy to remote servers via SSH. Hook scripts are piped to the remote host and executed there — output streams back for live display.

```bash
# Setup with remote targets
muster setup --scan --remote api=deploy@prod.example.com:/opt/myapp

# Or configure per-service in muster.json
```

```json
{
  "services": {
    "api": {
      "remote": {
        "enabled": true,
        "host": "prod.example.com",
        "user": "deploy",
        "port": 22,
        "identity_file": "~/.ssh/deploy_key",
        "project_dir": "/opt/myapp"
      }
    }
  }
}
```

Remote services use `ssh user@host "bash -s" < hook.sh` — credentials are exported on the remote side, never sent over the wire as arguments. Health checks and rollbacks also run remotely. Toggle remote on/off in `muster settings`.

## Fleet — Multi-Machine Deployment

Deploy your entire project to multiple machines with a single command. Fleet supports SSH and cloud relay transports with two deploy modes.

```bash
muster fleet init                    # create remotes.json
muster fleet add prod-1 deploy@10.0.1.10 --mode muster --path /opt/myapp
muster fleet add prod-2 deploy@10.0.1.11 --mode push
muster fleet group web prod-1 prod-2 # group machines
muster fleet deploy                  # deploy to all machines
muster fleet deploy web              # deploy to a group
muster fleet deploy --parallel       # all machines in parallel
muster fleet status                  # check health across fleet
muster fleet rollback                # rollback across fleet
```

**Two deploy modes:**
- **`muster` mode** — remote has muster installed, runs `muster deploy` remotely
- **`push` mode** — no muster needed, pipes your hook scripts over SSH

**Two transports:**
- **SSH** (default) — direct connection, works on any reachable host
- **Cloud** — WebSocket relay for machines behind NATs/firewalls, end-to-end encrypted (X25519 + NaCl box). Sign in once with `muster cloud login` (device flow; token stored in OS keychain or `~/.muster/tokens/cloud.json`), check status with `muster cloud status`, or sign out with `muster cloud logout`.

**Security:** Fleet uses RSA-4096 keypairs per fleet for encrypted agent reports (AES-256-CBC session keys wrapped with RSA-4096). Ed25519 payload signing with RSA-2048 fallback for tamper detection. Secrets never leave your machine.

**Agents:** Optional scout daemons on remote machines that push encrypted health reports back to HQ. Install with `muster fleet install-agent`.

Fleet machines are configured in `~/.muster/fleets/<fleet>/` directory structure. The dashboard shows a Fleet panel with live connectivity status. See [FLEET.md](FLEET.md) for the full guide.

**Fleet docs:** [Setup Wizard](docs/fleet/setup-wizard.md) | [Deploy Strategies](docs/fleet/deploy-strategies.md) | [Fleet Skills](docs/fleet/skills.md) | [Cloud Transport](docs/fleet/cloud-transport.md) | [Encryption](docs/security/encryption.md) | [Agents](docs/agent/agent.md)

## Groups — Multi-Project Orchestration

Groups coordinate deploys across multiple projects on multiple machines:

```bash
muster group create production                    # create a group
muster group add production api /opt/api          # add projects
muster group add production frontend /opt/web
muster group deploy production                    # deploy all projects in order
```

| | Fleet | Groups |
|---|---|---|
| **What** | One project → many machines | Many projects → one coordinated deploy |
| **Config** | `remotes.json` (per-project) | `~/.muster/groups.json` (global) |
| **Use case** | Scale horizontally | Monorepo, multi-service orchestration |

## CI/CD — GitHub Actions & GitLab

```yaml
- uses: actions/checkout@v4
- uses: Muster-dev/muster@v0
  with:
    command: deploy          # rollback | restart | status | fleet-deploy | …
    services: api web        # empty = all
```

Grouped logs per service, a job summary table (result, duration, health,
commit) with the **Likely cause / Try** for failures, `::error` annotations
on the failing hook, and outputs (`result`, `deployed`, `failed`,
`summary-json`, `duration`). SSH deploys take `ssh-key` + `known-hosts`
(host keys are always checked); Fleet Cloud takes `cloud-token`.

```bash
muster ci init github --yes   # workflow: PR dry run, deploy on main, environment + concurrency
muster ci init gitlab --yes   # .gitlab-ci.yml
muster ci env                 # secrets/env vars your deploy needs
muster ci run deploy          # the action's engine, for any CI
```

On CI without a TTY muster never waits for input, keeps output plain
(`FORCE_COLOR` to override) and reads credentials from `MUSTER_CRED_<KEY>`.
Guide: [docs/ci.md](docs/ci.md).

## Credentials

Off by default. Three modes per service:

1. **Save always** — stored in macOS Keychain (via `security` command). Persists across sessions.
2. **Once per session** — prompted once, kept in memory for the session.
3. **Every time** — prompted on every deploy/rollback.

**Never** in muster.json. **Never** in your project directory. **Never** in git.

Services with stored credentials are flagged with `! KEY` in the dashboard.

## Settings

`muster settings` has two sections:

### Project Settings

Per-service toggles saved to muster.json:

- **Skip deploy** — health-check only, don't deploy
- **Health check** — enable/disable health verification
- **Credentials** — cycle through Off / Save always / Once per session / Every time
- **Remote** — toggle SSH remote deployment on/off per service

### Global Settings

Muster-wide preferences stored in `~/.muster/settings.json`:

| Setting | Default | Description |
|---------|---------|-------------|
| `color_mode` | `auto` | Color output: `auto`, `always`, `never` |
| `log_color_mode` | `auto` | Streamed deploy log colors: `auto`, `raw`, `none` |
| `log_retention_days` | `7` | Days to keep deploy logs |
| `default_stack` | `bare` | Default stack for new projects (`bare`, `docker`, `compose`, `k8s`) |
| `default_health_timeout` | `10` | Health check timeout (seconds) |
| `scanner_exclude` | `[]` | Patterns to exclude from project scanning |
| `update_check` | `on` | Check for muster updates (`on`, `off`) |
| `update_mode` | `release` | Update channel (`release`, `source`) |
| `tui_mode` | `go` | Dashboard TUI backend (`go` when `muster-tui` is installed, or `bash`) |
| `minimal` | `false` | Always use plain-text minimal mode (`true`, `false`) |
| `machine_role` | `""` | Machine role for setup (`local`, `control`, `target`, `both`) |
| `deploy_name` | `""` | Custom deployer identity for locks/history |
| `service_lock_timeout` | `1800` | Stale timeout in seconds for fleet service locks (`60`–`86400`) |
| `signing` | `off` | Sign pushed fleet hook payloads (`on`, `off`) |
| `require_signing` | `off` | Require signed payloads in relay guard (`on`, `off`) |
| `hook_security` | `on` | Per-machine hook approval & dangerous-command gate (`on`, `off`) |
| `deploy_password_hash` | `""` | SHA-256 hash of optional deploy password (set via `deploy_password`) |
| `assistant` | `on` | Muster Assistant (`muster ask`) on this machine (`on`, `off`) |
| `cloud.*` | `{}` | Fleet Cloud connection settings (`cloud.relay`, `cloud.org_id`, `cloud.token_ref`, `cloud.token_id`, `cloud.name`; set via `muster cloud login`) |

Edit interactively via the TUI, or from the command line:

```bash
muster settings --global                        # dump all settings
muster settings --global color_mode never        # set a value
muster settings --global scanner_exclude add old # add exclude pattern
```

## Hook Approvals, Exit Codes & Cancel Behaviour

### Per-Machine Hook Approvals

Hook approvals live per machine in `~/.muster/trust/<sha256-of-project-path>/` (containing `hooks.manifest`, its HMAC signature, and approved copies for diffs) — never inside your project repository. Fresh clones or edited hooks are blocked from running until reviewed and approved on that machine:

```bash
muster hooks approve          # interactive (TTY): shows pending files/diffs and prompts [y/N]
muster hooks approve --yes    # non-interactive (CI/scripts)
muster deploy --yes           # approve pending hooks and deploy (same as MUSTER_APPROVE_HOOKS=1)
```

### Exit Codes & Ctrl+C Cancel

| Exit Code | Meaning |
|-----------|---------|
| `0` | Success (all selected services deployed/rolled back and healthy) |
| `1` | Failure, abort, invalid config, lock conflict, or unapproved hooks |
| `124` | Hook timed out (exceeded `deploy_timeout`, default 120s) |
| `130` | Cancelled via Ctrl+C (`SIGINT`) or `SIGTERM` |

Pressing **Ctrl+C** (or sending `SIGTERM`) during a deploy immediately terminates the running hook and its child process tree, releases deploy and service locks, records `cancelled` in `.muster/logs/deploy-events.log` (and emits `{"event":"cancelled"}` in `--json` mode), and exits with code `130`.

## Skills

Addons that extend muster — notifications, monitoring, automation, anything. Skills are bash scripts with a `skill.json` manifest that fire on deploy, rollback, and fleet events.

```bash
muster skill create discord          # scaffold from built-in template
muster skill configure discord       # set API keys
muster skill enable discord          # auto-run on deploy/rollback hooks
```

**Built-in templates:** Discord, Slack, and generic Webhook — all support fleet hooks out of the box. Install community skills from git URLs:

```bash
muster skill add https://github.com/someone/muster-skill-ssl
```

### Fleet Skills

Skills fire during fleet operations too. Per-fleet config lets you send production deploys to `#production-deploys` and staging to `#staging-deploys`:

```bash
muster fleet skill enable production discord
muster fleet skill configure production discord    # override channel ID per fleet
```

Fleet hooks: `fleet-deploy-start`, `fleet-deploy-end`, `fleet-machine-deploy-start`, `fleet-machine-deploy-end`, `fleet-rollback-start`, `fleet-rollback-end`. Skills always execute on your machine — secrets never leave the orchestrator.

See [docs/skills/skills.md](docs/skills/skills.md) for the full skill authoring guide.

## MCP Integration

muster includes an MCP (Model Context Protocol) tool so LLMs can deploy, check status, rollback, and manage your services directly. Pure bash, runs locally over stdio.

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "muster": {
      "command": "muster-mcp"
    }
  }
}
```

### Claude Code

Add to `.claude/settings.json`:

```json
{
  "mcpServers": {
    "muster": {
      "command": "muster-mcp"
    }
  }
}
```

### Available tools

| Tool | Description |
|------|-------------|
| `muster_scan_project` | Detect project files and suggest services |
| `muster_init_project` | Create muster.json and hook directories |
| `muster_write_hook` | Write a hook script (deploy, health, rollback, etc.) |
| `muster_read_hook` | Read an existing hook script |
| `muster_status` | Health check all services |
| `muster_deploy` | Deploy all or a specific service |
| `muster_rollback` | Rollback a service |
| `muster_logs` | Get recent deploy logs |
| `muster_cleanup` | Clean up old logs and run cleanup hooks |
| `muster_list_services` | List services with hook availability |
| `muster_config` | Get the full muster.json |

An LLM can scan your project, create the config, write all the hook scripts, then deploy — all through conversation. Requires `jq`.

## Supported Platforms

| Platform | Status | Notes |
|----------|--------|-------|
| **macOS** (Intel & Apple Silicon) | Fully supported | Primary development platform. Uses built-in bash 3.2. Keychain integration via `security` command. |
| **Linux** (x86_64, arm64, armv7) | Fully supported | Any distro with bash 3.2+. Keychain via `secret-tool` or `pass`. |
| **FreeBSD** | Supported | Requires bash 3.2+ installed. |
| **Windows (WSL)** | Fully supported | Runs natively in WSL1/WSL2 — same as Linux. |
| **Windows (Git Bash / MSYS2)** | Partial | Core commands work. TUI features (menu, checklist, spinners) may render incorrectly. No keychain. |
| **Windows (native)** | Not supported | Requires a Unix shell — use WSL instead. |

### Requirements

- **bash 3.2+** — no newer features required (works with macOS default bash)
- **jq** or **python3** — for reading muster.json (jq preferred, python3 as fallback)
- **curl** — for HTTP health checks and skill installs

Optional tools (detected automatically, features degrade gracefully without them):

| Tool | Used for |
|------|----------|
| `docker` | Docker/Compose stack deploys, dev stack infra services |
| `kubectl` | Kubernetes deploys, health checks, diagnostics |
| `ssh` | Remote deployment over SSH |
| `jq` | Config read/write (required for `muster settings --global` writes) |
| `security` (macOS) | Keychain credential storage |
| `secret-tool` / `pass` (Linux) | Keychain credential storage |

### Tested shells

muster runs in bash but is invoked from any shell — `zsh`, `fish`, `dash`, etc. The entry point (`bin/muster`) has a bash shebang and does not depend on the user's login shell.

## Dev Stack

For local development. App services run as PID-managed background processes, infra services run via docker compose.

```bash
muster setup --stack dev --scan   # detect dev commands from project files
muster dev                        # deploy all + watch health every 5s (Ctrl+C to cleanup)
```

The scanner detects start commands from project files: `package.json` → `npm start`, `go.mod` → `go run .`, `requirements.txt` → Django/FastAPI/Flask detection, etc.

## Deploy Failure Recovery

When a deploy fails, muster doesn't just abort — it shows interactive recovery options:

1. **Retry** — run the same deploy again (fresh log file)
2. **Rollback** — run the service's rollback hook
3. **Rollback & restart** — undo k8s image change + restart pods (k8s update mode only)
4. **Explain with AI** — ask the Muster Assistant what went wrong (when logged in to Fleet Cloud), then back to this menu
5. **Skip and continue** — move on to the next service
6. **Abort** — stop everything

Non-interactive failures end with a `Get help: muster ask` hint. See [Muster Assistant](docs/assistant.md).

On k8s services, muster auto-diagnoses failures before showing the menu — inspecting pod events, logs, and matching 11 known error patterns (ImagePullBackOff, ErrImagePull, ErrImageNeverPull, InvalidImageName, OOMKilled, CrashLoopBackOff, CreateContainerConfigError, RunContainerError, Unschedulable, missing secrets/PVCs, version mismatch). K8s deploy hooks also detect terminal errors early (within ~10s) instead of waiting for the full rollout timeout, and show rolling progress (`"2/3 pods ready"`).

Skills with `post-deploy` hooks (like Discord notifications) fire immediately when a deploy fails — before the recovery menu appears — so your team gets alerted right away. Fleet skills fire on fleet events too — `fleet-deploy-end` notifies your team when a multi-machine deploy completes or fails.

## Doctor

Run diagnostics on your project:

```bash
muster doctor              # check everything
muster doctor --fix        # auto-fix what it can
muster --minimal doctor    # plain text output (PASS/WARN/FAIL lines)
```

Checks across 6 categories (platform & tools, configuration, stack readiness, connectivity, health & runtime, storage & maintenance): muster.json validity, hook existence and permissions, health check status, tool availability, stale PID files, .env presence, old logs, k8s cluster reachability, fleet connectivity, **build context overlap detection**, and more.

### Build Context Overlap Detection

In monorepos, one service's Docker build context (usually `.`) can contain another service's directory. This causes cache invalidation from unrelated changes, bloated build contexts, and potential secret leakage. muster detects this automatically:

- **Dashboard** — warning banner + "Doctor !" badge on the menu item when issues are found
- **Deploy** — yellow warning line before build starts
- **Setup** — detection runs after hook generation with fix suggestions
- **Doctor** — detailed diagnostics with `--fix` to auto-add directories to `.dockerignore`

Results are cached at `~/.muster/.build_context_cache` and refreshed when `muster.json` or `.dockerignore` changes.

## History

```bash
muster history              # recent deploy/rollback events
muster history --all        # full log
muster history api          # filter by service
```

## Minimal Mode

For scripts and CI pipelines that don't need the TUI:

```bash
muster --minimal              # plain text service status, no interactive dashboard
muster --minimal doctor       # PASS/WARN/FAIL lines, no color or boxes
muster --minimal deploy api   # build context warnings to stderr as comments
```

Minimal mode outputs plain text to stdout and warnings as `# comment`-style lines to stderr, making it easy to pipe and parse.

## App Integrity Verification

muster verifies its own source files haven't been tampered with. On every launch, it checks a SHA256 manifest of all tracked files against what's on disk.

```bash
muster verify              # full file-by-file integrity check
muster verify --quick      # signature-only (fast)
muster verify --json       # machine-readable output
muster --no-verify ...     # bypass startup check
```

The manifest is generated automatically during install and updates. If tampering is detected, muster shows which files changed and offers to repair via `git checkout`.

The startup check uses an inline bootstrap trust chain — it verifies the integrity libraries themselves (via raw `openssl` + `shasum`) before sourcing them, so no muster code runs unchecked.

## Documentation

| Topic | Guide |
|-------|-------|
| **Deploy** | [Deploy Flow](docs/deploy/deploy.md) · [Hooks](docs/deploy/hooks.md) · [Setup Wizard](docs/deploy/setup-wizard.md) |
| **Fleet** | [Fleet Guide](docs/fleet/fleet.md) · [Setup Wizard](docs/fleet/setup-wizard.md) · [Deploy Strategies](docs/fleet/deploy-strategies.md) · [Cloud Transport](docs/fleet/cloud-transport.md) |
| **Skills** | [Authoring Guide](docs/skills/skills.md) · [Marketplace](docs/skills/marketplace.md) · [Fleet Skills](docs/fleet/skills.md) |
| **Security** | [Encryption](docs/security/encryption.md) · [Signing](docs/security/signing.md) · [Integrity](docs/security/integrity.md) |
| **Agents** | [Agent Guide](docs/agent/agent.md) · [Installation](docs/agent/installation.md) |
| **Assistant** | [muster ask & cloud connect](docs/assistant.md) · [Protocol](docs/assistant-and-pairing.md) |
| **CI/CD** | [GitHub Actions, GitLab, generic CI](docs/ci.md) · [Engine API (`--json`)](docs/ENGINE-API.md) |

See [docs/docs-index.md](docs/docs-index.md) for the full index.

## Philosophy

- **Pure bash** — zero runtime dependencies, runs anywhere bash runs
- **Modular** — each file does one thing
- **Your scripts, your way** — muster orchestrates, you decide how things deploy
- **Stack agnostic** — Docker, k8s, bare metal, cloud — if you can script it, muster can run it
- **Beautiful by default** — spinners, progress bars, live log boxes, color-coded everything
- **Graceful degradation** — missing tools disable features, never crash

## Contributing

PRs welcome. The codebase is modular by design — each file in `lib/` is self-contained.

### Running tests

```bash
make test
```

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.

Copyright 2026 Ricky Eipper. You must retain copyright and attribution notices in any copy or derivative work.
