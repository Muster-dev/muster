# Fleet & Cloud — Multi-Machine Deployment

Deploy your project to multiple machines from a single command. Fleet handles SSH connections, auth tokens, health checks, and failure recovery across your entire infrastructure.

## Overview

Fleet has two transports and two deploy modes:

| | SSH (default) | Cloud |
|---|---|---|
| **How** | Direct SSH connection | WebSocket relay (end-to-end encrypted) |
| **When** | Machines are reachable via SSH | Behind NATs, firewalls, or different LANs |
| **Requires** | SSH key access | `muster-tunnel` (local) + `muster-agent` (remote) |

| | Muster Mode | Push Mode |
|---|---|---|
| **How** | Runs `muster deploy` on remote | Pipes hook scripts over SSH |
| **Requires** | muster installed on remote | Only bash on remote |
| **Best for** | Production servers with muster | Simple targets, CI runners |

## Quick Start

```bash
# 1. Initialize fleet in your project
muster fleet init

# 2. Add machines
muster fleet add prod-1 deploy@10.0.1.10 --mode muster --path /opt/myapp
muster fleet add prod-2 deploy@10.0.1.11 --mode push

# 3. Group them
muster fleet group web prod-1 prod-2

# 4. Deploy
muster fleet deploy              # all machines, sequential
muster fleet deploy web           # deploy to a group
muster fleet deploy --parallel    # all in parallel (max 10 concurrent)
muster fleet deploy --dry-run     # preview without executing
```

## Commands

| Command | Description |
|---------|-------------|
| `muster fleet init` | Create `remotes.json` in project root |
| `muster fleet add <name> user@host` | Add a machine |
| `muster fleet remove <name>` | Remove a machine |
| `muster fleet group <name> <machines...>` | Create a machine group |
| `muster fleet ungroup <name>` | Remove a group |
| `muster fleet list` | Show all machines and groups |
| `muster fleet test [target]` | Test SSH connectivity |
| `muster fleet deploy [target]` | Deploy to machines |
| `muster fleet status [target]` | Check health across fleet |
| `muster fleet rollback [target]` | Rollback across fleet |
| `muster fleet pair <name> --token <t>` | Manually pair a muster-mode machine |

### Add Flags

```bash
muster fleet add <name> user@host [flags]
```

| Flag | Description |
|------|-------------|
| `--mode, -m <muster\|push>` | Deploy mode (default: `push`) |
| `--port, -p <N>` | SSH port (default: `22`) |
| `--path <dir>` | Project directory on remote |
| `--key, -k <file>` | SSH identity file |
| `--transport <ssh\|cloud>` | Transport type (default: `ssh`) |

### Deploy Flags

| Flag | Description |
|------|-------------|
| `--parallel` | Deploy concurrently (max 10 SSH connections) |
| `--dry-run` | Preview plan without executing |
| `--json` | Output as NDJSON events |

## Configuration

Fleet config lives in `remotes.json` alongside your `deploy.json`:

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
    "web": ["prod-1", "prod-2"]
  },
  "deploy_order": ["web"]
}
```

### Machine Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `host` | yes | -- | IP address or hostname |
| `user` | yes | -- | SSH user |
| `port` | no | `22` | SSH port |
| `identity_file` | no | -- | Path to SSH private key |
| `project_dir` | no | -- | Project path on remote |
| `mode` | no | `push` | `muster` or `push` |
| `transport` | no | `ssh` | `ssh` or `cloud` |

## Auth Pairing (Muster Mode)

Machines in `muster` mode need an auth token so fleet can run `muster deploy` on the remote.

**Auto-pair** happens when you `muster fleet add` with `--mode muster`:
1. Tests SSH connectivity
2. Checks remote has muster installed
3. Creates a deploy-scoped token on the remote
4. Stores the token locally at `~/.muster/fleet-tokens.json` (600 permissions)

**Manual pair** if auto-pair fails:

```bash
# On the remote:
muster auth create fleet-main --scope deploy
# Copy the token

# On your machine:
muster fleet pair prod-1 --token <token>
```

Tokens are keyed by `user@host:port` and reused across projects. Push mode doesn't need tokens.

## SSH Setup

Fleet uses `BatchMode=yes` — SSH must be configured for passwordless key-based access.

```bash
# Generate a deploy key
ssh-keygen -t ed25519 -f ~/.ssh/deploy-key -N "" -C "muster-fleet"

# Copy to remote
ssh-copy-id -i ~/.ssh/deploy-key deploy@10.0.1.10

# Add to fleet
muster fleet add prod-1 deploy@10.0.1.10 --key ~/.ssh/deploy-key --mode muster --path /opt/myapp
```

SSH options used by fleet:

| Option | Value | Purpose |
|--------|-------|---------|
| `ConnectTimeout` | `10` | Fail fast on unreachable hosts |
| `StrictHostKeyChecking` | `accept-new` | Auto-accept new keys, reject changed ones |
| `BatchMode` | `yes` | No interactive prompts |

## Deploy Behavior

**Sequential (default):** One machine at a time. On failure: shows logs, recovery menu (Retry / Skip / Abort).

**Parallel (`--parallel`):** Concurrent deploys (max 10). Shows progress spinner, then results summary. On failures: Retry failed / View logs / Continue.

Deploy order follows `deploy_order` in `remotes.json`. Groups deploy in array order. Machines not in any group deploy last.

## Cloud Transport

Cloud transport routes commands through an encrypted WebSocket relay. Machines don't need direct SSH access — useful for NATs, firewalls, and cross-network deployments.

### Architecture

```
Your Machine                    Relay Server                 Remote Machine
muster fleet deploy  -->  muster-cloud relay  <--  muster-agent (daemon)
(muster-tunnel)           (routes encrypted         (connects outbound,
                           packets, can't            runs muster commands)
                           read them)
```

All commands are end-to-end encrypted with X25519 key exchange + NaCl box. The relay routes packets but cannot decrypt them.

### Setup

**Install components:**

```bash
# On your machine — install muster-tunnel
curl -fsSL https://getmuster.dev/install.sh | bash
# Choose "muster-tunnel" during install

# On each remote — install muster-agent
curl -fsSL https://getmuster.dev/install.sh | bash
# Choose "muster-agent" during install
```

**Configure the remote agent:**

```bash
# On the remote: register with relay
muster-agent join --relay wss://relay.example.com \
  --token mst_agent_<join-token> --org myorg --name prod-east \
  --project /opt/myapp

# Start the daemon
muster-agent run
```

**Configure your machine:**

```bash
# Set cloud credentials
muster settings --global cloud.relay '"wss://relay.example.com"'
muster settings --global cloud.org_id '"myorg"'
muster settings --global cloud.token '"mst_cli_<your-token>"'

# Add a cloud machine to fleet
muster fleet add prod-east deploy@prod-east --transport cloud --path /opt/myapp
```

### Cloud Settings

Stored in `~/.muster/settings.json`:

```json
{
  "cloud": {
    "relay": "wss://relay.example.com",
    "org_id": "myorg",
    "token": "mst_cli_<token>"
  }
}
```

Cloud and SSH machines can coexist in the same fleet. Each machine uses its configured transport independently.

## Fleet Sync (Beta)

Synchronize project files to fleet machines before deploying. Useful when remotes don't have git access.

```bash
muster fleet sync              # sync to all machines
muster fleet sync prod-1       # sync to one machine
```

## Dashboard Integration

When `remotes.json` exists, the dashboard shows a **Fleet** panel with live connectivity status per machine (green/red dots). The Fleet action in the dashboard opens the fleet manager for deploy, status, test, and rollback operations.

`muster doctor` includes a fleet connectivity check when `remotes.json` exists.

## Fleet vs Per-Service Remote

These are different features that don't conflict:

| | Fleet | Per-Service Remote |
|---|---|---|
| **Scope** | Entire project to multiple machines | One service to one host |
| **Config** | `remotes.json` | `deploy.json` per-service `remote` block |
| **Use case** | Horizontal scaling | Service-specific remote targets |

## Groups — Multi-Project Orchestration

Groups coordinate deploys across multiple projects. While fleet deploys one project to many machines, groups deploy many projects together.

```bash
muster group create production
muster group add production api /opt/api
muster group add production frontend /opt/web
muster group deploy production
```

| | Fleet | Groups |
|---|---|---|
| **What** | One project -> many machines | Many projects -> one coordinated deploy |
| **Config** | `remotes.json` (per-project) | `~/.muster/groups.json` (global) |
| **Use case** | Scale horizontally | Monorepo, multi-service orchestration |

Both support SSH and cloud transports. A single deploy can mix transport types.
