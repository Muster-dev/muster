# Fleet — Multi-Machine Deployment

Deploy your project to multiple machines over SSH. Fleet supports two modes:

- **`muster` mode** — Remote has muster installed. SSH in and run `muster deploy` on the remote.
- **`push` mode** — No muster needed on remote. Pipes your hook scripts over SSH.

## Quick Start

```bash
# 1. Initialize fleet config
muster fleet init

# 2. Add machines
muster fleet add prod-1 deploy@10.0.1.10 --mode muster --path /opt/myapp
muster fleet add prod-2 deploy@10.0.1.11 --mode push

# 3. Group machines
muster fleet group web prod-1 prod-2

# 4. Deploy
muster fleet deploy              # all machines (follows deploy_order)
muster fleet deploy web           # deploy to a group
muster fleet deploy prod-1        # deploy to one machine
muster fleet deploy --parallel    # all machines in parallel
muster fleet deploy --dry-run     # preview without executing
```

## Setup (CLI)

All fleet setup is done via CLI flags. Once configured, use the dashboard or `muster fleet` for operations.

### Initialize

```bash
muster fleet init
```

Creates `remotes.json` in your project root (alongside `deploy.json`):

```json
{
  "machines": {},
  "groups": {},
  "deploy_order": []
}
```

### Add a Machine

```bash
muster fleet add <name> user@host [options]
```

| Flag | Description |
|------|-------------|
| `--mode, -m <muster\|push>` | Deploy mode (default: `push`) |
| `--port, -p <N>` | SSH port (default: `22`) |
| `--path <dir>` | Project directory on remote |
| `--key, -k <file>` | SSH identity file |

**Examples:**

```bash
# Muster mode — remote has muster installed
muster fleet add prod-1 deploy@10.0.1.10 --mode muster --path /opt/myapp

# Push mode — pipe hooks via SSH (no muster needed on remote)
muster fleet add prod-2 deploy@10.0.1.11 --mode push

# Custom SSH port and identity file
muster fleet add staging deploy@staging.example.com -p 2222 -k ~/.ssh/staging-key
```

After adding, muster tests SSH connectivity. For `muster` mode machines, it also attempts **auto-pairing** (see [Auth Pairing](#auth-pairing) below).

### Remove a Machine

```bash
muster fleet remove <name>
```

Removes the machine from `remotes.json`, all groups, deploy order, and deletes the stored token.

### Create Groups

```bash
muster fleet group <name> <machine1> [machine2 ...]
```

Groups let you target a set of machines. All listed machines must exist in `remotes.json`.

```bash
muster fleet group web prod-1 prod-2
muster fleet group staging staging-1
```

### Remove a Group

```bash
muster fleet ungroup <name>
```

### Deploy Order

Edit `remotes.json` directly to set `deploy_order`. Groups are deployed in this order; machines within a group follow array order.

```json
{
  "deploy_order": ["staging", "web"]
}
```

With this config, `muster fleet deploy` deploys to all `staging` group machines first, then all `web` group machines. Machines not in any ordered group deploy last.

## Operations (TUI + CLI)

These commands work both from the CLI and from the interactive fleet manager (dashboard > Fleet, or bare `muster fleet`).

### List

```bash
muster fleet list           # TUI box view
muster fleet list --json    # raw JSON
```

### Test Connectivity

```bash
muster fleet test               # test all machines
muster fleet test prod-1        # test one machine
muster fleet test web           # test a group
```

Tests SSH connectivity and token validation (for `muster` mode machines).

### Deploy

```bash
muster fleet deploy [target] [--parallel] [--dry-run] [--json]
```

| Flag | Description |
|------|-------------|
| `--parallel` | Deploy to all target machines concurrently (max 10 SSH connections) |
| `--dry-run` | Preview deploy plan without executing |
| `--json` | Output as NDJSON events |

**Sequential deploy (default):** Deploys to each machine one at a time. On failure, shows last log lines and a recovery menu: Retry / Skip and continue / Abort.

**Parallel deploy:** Spawns background processes per machine (capped at 10 concurrent SSH connections). Shows a live progress spinner, then a results summary. On failures, offers: Retry failed / View logs / Continue.

### Status

```bash
muster fleet status [target] [--json]
```

For `muster` mode machines with tokens, queries remote `muster status --json` to show per-service health counts (e.g., `3/3 healthy`).

### Rollback

```bash
muster fleet rollback [target] [--parallel]
```

Same mechanics as deploy — rolls back each machine sequentially or in parallel.

## Config: `remotes.json`

Lives in your project root alongside `deploy.json`. Example:

```json
{
  "machines": {
    "prod-1": {
      "host": "10.0.1.10",
      "user": "deploy",
      "port": 22,
      "identity_file": "~/.ssh/prod-key",
      "project_dir": "/opt/myapp",
      "mode": "muster"
    },
    "prod-2": {
      "host": "10.0.1.11",
      "user": "deploy",
      "port": 2222,
      "mode": "push"
    }
  },
  "groups": {
    "web": ["prod-1", "prod-2"],
    "staging": ["staging-1"]
  },
  "deploy_order": ["staging", "web"]
}
```

### Machine Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `host` | yes | — | IP address or hostname |
| `user` | yes | — | SSH user |
| `port` | no | `22` | SSH port |
| `identity_file` | no | — | Path to SSH private key |
| `project_dir` | no | — | Project path on remote (for `cd` before deploy) |
| `mode` | no | `push` | `muster` or `push` |
| `transport` | no | `ssh` | Transport layer (`ssh` now, `cloud` in future) |

## Auth Pairing

Machines in `muster` mode need an auth token to run `muster deploy` on the remote. Tokens are stored locally in `~/.muster/fleet-tokens.json` (600 permissions, never in git).

### Auto-Pair

When you `muster fleet add` a machine with `--mode muster`, auto-pairing is attempted:

1. SSH connectivity test
2. Check if remote has `muster` installed
3. Check if remote already has tokens (can only bootstrap if 0 tokens exist)
4. SSH in and create token: `muster auth create fleet-<hostname> --scope deploy`
5. Store token locally
6. Verify token works

If auto-pair fails (no muster on remote, remote already has tokens, etc.), it prints manual instructions.

### Manual Pair

```bash
# On the remote machine:
muster auth create fleet-main --scope deploy
# Copy the raw token output

# On your local machine:
muster fleet pair prod-1 --token <raw-token>
```

### Token Storage

Tokens are stored at `~/.muster/fleet-tokens.json`:

```json
{
  "tokens": {
    "deploy@10.0.1.10:22": "abc123...",
    "deploy@staging.example.com:2222": "def456..."
  }
}
```

Keyed by `user@host:port` so the same remote reuses its token across projects.

### How Tokens Are Used

During fleet deploy, muster passes the token as an environment variable in the SSH command:

```
ssh deploy@10.0.1.10 "MUSTER_TOKEN=<token> muster deploy"
```

The remote muster instance validates the token via its auth system. Push mode doesn't need tokens — hooks run directly via SSH.

## SSH Setup

Fleet uses SSH with `BatchMode=yes` (no interactive prompts). Your SSH must be configured for passwordless access.

### SSH Key Setup

```bash
# Generate a deploy key (if you don't have one)
ssh-keygen -t ed25519 -f ~/.ssh/deploy-key -N "" -C "muster-fleet"

# Copy to remote
ssh-copy-id -i ~/.ssh/deploy-key deploy@10.0.1.10

# Test
ssh -i ~/.ssh/deploy-key deploy@10.0.1.10 "echo ok"

# Add to fleet
muster fleet add prod-1 deploy@10.0.1.10 --key ~/.ssh/deploy-key --mode push
```

### SSH Config (Recommended)

For cleaner setups, configure `~/.ssh/config`:

```
Host prod-1
    HostName 10.0.1.10
    User deploy
    Port 22
    IdentityFile ~/.ssh/deploy-key
    StrictHostKeyChecking accept-new

Host staging-*
    User deploy
    IdentityFile ~/.ssh/staging-key
    Port 2222
```

Then add machines using the SSH config alias:

```bash
muster fleet add prod-1 deploy@10.0.1.10 --key ~/.ssh/deploy-key
```

### SSH Options

Fleet uses these SSH options by default:

| Option | Value | Purpose |
|--------|-------|---------|
| `ConnectTimeout` | `10` | Fail fast on unreachable hosts |
| `StrictHostKeyChecking` | `accept-new` | Auto-accept new host keys, reject changed ones |
| `BatchMode` | `yes` | No interactive password prompts |

### Firewall / Network

- Ensure SSH port (default 22) is open between your machine and fleet targets
- For `muster` mode, the remote must have `muster` installed and a project set up at `project_dir`
- For `push` mode, the remote only needs `bash` — hooks are piped via stdin

### Troubleshooting SSH

```bash
# Test connectivity
muster fleet test prod-1

# Verbose SSH debug (manual)
ssh -v -o BatchMode=yes deploy@10.0.1.10 "echo ok"

# Common issues:
# - "Permission denied" → SSH key not authorized on remote
# - "Connection timed out" → Firewall blocking SSH port
# - "Host key verification failed" → Remote host key changed
# - "No route to host" → Network/DNS issue
```

## Dashboard Integration

When `remotes.json` exists, the dashboard shows a **Fleet** panel with live connectivity status (green/red dots per machine). The "Fleet" action in the dashboard opens the fleet manager where you can deploy, check status, test connections, and rollback.

Fleet setup (init, add, remove, group, ungroup, pair) is CLI-only.

## Doctor Integration

`muster doctor` includes a fleet connectivity check when `remotes.json` exists. It tests SSH access to each machine and reports pass/warn/fail.

## Fleet vs Per-Service Remote

The existing per-service `remote` config in `deploy.json` deploys _one service_ to _one host_. Fleet deploys the _entire project_ to _multiple machines_. They don't conflict:

- Fleet `muster` mode: the remote muster instance handles its own service routing
- Fleet `push` mode: iterates your local project's services and pushes each hook
- Per-service remote: deploys a single service to its configured remote host
