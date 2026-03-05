# Fleet Setup Wizard

> Interactive 6-step wizard for creating and configuring fleets.

Run `muster fleet setup` to launch the wizard. Requires a TTY (interactive terminal). For non-interactive machine setup, use `muster fleet add` instead.

The wizard creates a fleet directory at `~/.muster/fleets/<name>/` with fleet config, encryption keys, and per-machine hook directories.

## Step 1: Name Your Fleet

Choose an existing fleet to reinforce (add machines to), or create a new one.

```
Fleet name (production): staging
```

- Default name: `production`
- Name is sanitized: lowercased, spaces replaced with hyphens
- If existing fleets are detected, the wizard shows them with machine counts and offers "Reinforce an existing fleet, or raise a new one"
- New fleets get a `default` group automatically

## Step 2: Recruit Machines

Add machines to your fleet. The wizard offers three paths:

| Method | Description |
|--------|-------------|
| Import from SSH config | Auto-scans `~/.ssh/config` for Host entries (skips wildcards and multi-host entries) |
| Enter manually | Prompt for callsign, user@host, port, and SSH key |
| Done recruiting | Finish adding machines |

**SSH config import** parses `~/.ssh/config` for: Host alias, HostName, User, IdentityFile, and Port. Already-enlisted machines are filtered out.

**Manual entry** prompts for:
- Callsign (machine name)
- Host in `user@hostname` format
- Port (default: 22)
- SSH key (auto-detects keys in `~/.ssh/`: `id_ed25519`, `id_rsa`, `deploy-key`, `deploy`)

Each machine is tested for SSH connectivity on add. Machines that fail the test are still enlisted -- fix connectivity before deploy.

```
> Callsign (name for this machine): prod-api-1
> Host (user@ip): deploy@10.0.1.10
> Port (22):
```

Machines must provide at least one to proceed (unless reinforcing an existing fleet).

## Step 3: Brief Each Machine

For each new machine, the wizard SSHes in to auto-detect the remote environment:

**Recon report:**
- SSH connectivity status
- Whether muster is installed on the remote
- Container runtime: Docker Compose, Kubernetes, Docker, or bare metal
- Project directories (checks `~/*/`, `/opt/*/`, `/srv/*/`, `/var/www/*/` for `deploy.json` or `docker-compose.yml`)

**Deploy mode selection:**

| Mode | Description |
|------|-------------|
| Sync (default) | Muster writes deploy/health/rollback scripts locally and pushes them to the machine over SSH |
| Manual | Muster is already installed on the remote -- SSH in and tell it to deploy |

If muster is detected on the remote, Manual mode is recommended. Otherwise, Sync mode is recommended.

**Sync mode** additionally prompts for:
- Services to deploy (Web app/API, Background workers, Database, Cache/Redis, Reverse proxy)
- Deploy stack (Docker Compose, Docker, Kubernetes, Bare metal) -- pre-selected from detection
- Deploy target path on the remote

Hook scripts are generated from stack templates into `~/.muster/fleets/<fleet>/default/<machine>/hooks/`.

**Manual mode** only prompts for the remote project path.

## Step 4: Choose Formation (Deploy Strategy)

Select how machines receive updates during fleet deploy.

| Strategy | Behavior |
|----------|----------|
| Sequential (default) | One machine at a time. Halt on failure before it spreads. |
| Parallel | All at once. Fastest, but failures affect everything. |
| Rolling | Deploy to one, verify health, then advance to the next. Safest for production. |

Single-machine fleets skip this step and default to sequential.

The chosen strategy is saved in `fleet.json` and used as the default for `muster fleet deploy`. Override at deploy time with `--parallel`, `--sequential`, or `--rolling`.

## Step 5: Deploy Scouts

Scouts are lightweight monitoring agents that collect:
- Service health (every 30s)
- System metrics: CPU, memory, disk (every 60s)
- Deploy events (real-time)
- Service log tails (every 60s)

**Encryption keypair:** The wizard generates an RSA-4096 keypair for the fleet:
- Private key: `~/.muster/fleets/<fleet>/fleet.key` (mode 600)
- Public key: `~/.muster/fleets/<fleet>/fleet.pub` (mode 644)

Reports are encrypted with hybrid RSA-4096 + AES-256 encryption:

1. Each report is encrypted with a random AES-256 session key
2. The session key is wrapped with the fleet's RSA-4096 public key
3. Only the private key holder can decrypt reports

Scouts receive only the public key -- they can encrypt but never decrypt reports from other machines.

If `openssl` is not available, encryption is skipped and reports are sent as plaintext over SSH.

**Scout installation options:**
- Install on all new machines
- Select specific machines
- Skip for now (install later with `muster fleet install-agent <machine> --push`)

## Step 6: Summary

The wizard displays the final fleet roster with:
- All machines and their deploy modes (sync/manual)
- Scout deployment status per machine
- Deploy strategy
- Encryption status (RSA-4096 + AES-256 or disabled)
- Config path (`~/.muster/fleets/<fleet>/`)

**Next steps offered:**

```bash
muster fleet deploy         # Send the fleet
muster fleet status         # Check all positions
muster fleet agent-status   # Scout reports (health + metrics)
muster fleet sync           # Push battle plans
muster fleet                # Command center
```

The wizard offers a dry-run test deploy before dismissing.
