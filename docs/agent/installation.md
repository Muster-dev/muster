# Agent Installation and Management

> Install, monitor, and remove the muster agent on fleet machines.

## Install Agent

```bash
muster fleet install-agent <machine> [options]
```

| Flag | Description |
|------|-------------|
| `--poll-interval <N>` | Health check interval in seconds (default: 30) |
| `--push` | Enable push-reporting back to this machine |
| `--force` | Overwrite existing agent installation |

### What Gets Installed

The install process pushes these files to `~/.muster/agent/` on the remote machine:

| File | Description |
|------|-------------|
| `muster-agent.sh` | Agent daemon script (mode 700) |
| `agent.json` | Agent configuration (mode 600) |
| `agent.sig` | Signature of agent script (mode 600) |
| `agent.pub.pem` | Public key for signature verification (mode 644) |
| `agent.json.sig` | Signature of agent config (mode 600) |
| `fleet.pub` | Fleet encryption public key (mode 644, only with `--push`) |

Directories created: `health/`, `metrics/`, `events/`, `logs/` (all under `~/.muster/agent/`). The base directory is set to mode 700.

### Installation Steps

1. **Detect remote OS** via SSH (`uname -s`)
2. **Create directories** with secure permissions
3. **Push agent script** via SCP
4. **Sign agent files** -- signs the agent script and generates a signature file; pushes the signature and public key to the remote
5. **Generate and push config** -- builds `agent.json` locally (using jq if available), pushes via SCP; signs the config too
6. **Push fleet encryption key** (if `--push` and fleet has keys) -- copies `fleet.pub` to the remote for report encryption
7. **Detect init system** and install appropriate service
8. **Verify agent is running**
9. **Update fleet config** -- sets `agent_installed: true` on the machine

### Init System Detection

The installer detects and configures the appropriate service manager:

| Init System | Service Type | Behavior |
|-------------|-------------|----------|
| systemd | User service (`~/.config/systemd/user/muster-agent.service`) | `Type=simple`, auto-restart on failure, enabled at boot |
| launchd | User agent (`~/Library/LaunchAgents/dev.getmuster.agent.plist`) | `RunAtLoad`, `KeepAlive` |
| cron | Crontab entry | Runs `muster-agent.sh run-once` every minute |
| none | Manual | User must start manually |

### Example

```bash
# Basic install
muster fleet install-agent prod-1

# Install with push reporting and custom poll interval
muster fleet install-agent prod-1 --push --poll-interval 15

# Reinstall (overwrite existing)
muster fleet install-agent prod-1 --force --push
```

## Agent Status

```bash
muster fleet agent-status [machine]
```

Shows health, metrics, and status for fleet agents. With no argument, shows all machines with agents installed.

### Data Sources

Agent status uses a two-tier data retrieval strategy:

| Priority | Source | When Used |
|----------|--------|-----------|
| 1 | Local cache (push reports) | If the machine has push-reporting enabled and a report exists in `~/.muster/fleets/<fleet>/reports/<hostname>/` |
| 2 | SSH fallback | Direct SSH queries to read agent data files on the remote |

### Local Cache (Push Reports)

When push-reporting is enabled, the agent sends encrypted summaries to the fleet HQ. The `agent-status` command checks for these cached reports first:

- Encrypted reports (`.enc`) are decrypted using the fleet private key
- Decrypted JSON is cached alongside the encrypted file
- Report age is displayed (e.g., "2m ago", "1h ago")

### SSH Fallback

When no local cache is available, status is retrieved via SSH:

- PID file check (running/stopped)
- Health directory scan (per-service status)
- Metrics JSON (`latest.json`)
- Recent deploy events (last 5 lines)

### Output

For each machine:

```
  prod-1  deploy@10.0.1.10
  Status: push-reporting  2m ago (encrypted)
  Services:
    api                  healthy
    redis                healthy
    worker               unhealthy
  Metrics: CPU 23.5%  Mem 67.2%  Disk 45%
  Last report: 2026-03-04T12:00:00Z
```

## Remove Agent

```bash
muster fleet remove-agent <machine>
```

Removes the agent from a fleet machine:

1. **Stop the agent** -- stops systemd service, unloads launchd agent, removes cron entry, kills via PID
2. **Prompt about data** -- asks whether to keep collected data (health, metrics, logs, events) or remove everything
3. **Clean up files** -- removes agent script, config, signatures, keys (and optionally data directories)
4. **Update fleet config** -- sets `agent_installed: false` on the machine

### Keeping Data

When prompted "Keep collected data? [y/N]":

- **Yes** -- removes only the agent executable, config, PID file, daemon log, and signature files; keeps `health/`, `metrics/`, `events/`, `logs/` directories
- **No** (default) -- removes the entire `~/.muster/agent/` directory

## TUI Menu

The agent features are also available through the fleet TUI dashboard:

```bash
muster fleet
# Navigate to: Agent
```

The menu shows all fleet machines with agent status indicators:

- Green dot -- agent installed
- Dim dot -- no agent

Actions available: Install agent on..., Agent status, Remove agent from..., Back.
