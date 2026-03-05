# Muster Agent

> Lightweight fleet monitoring daemon for remote machines.

The muster agent is a standalone bash script that runs on fleet targets to collect health status, system metrics, service logs, and deploy events. It has no dependency on the muster CLI -- it runs independently with only bash and standard Unix tools.

## Overview

| Property | Value |
|----------|-------|
| Script | `lib/agent/muster-agent.sh` |
| Installed to | `~/.muster/agent/muster-agent.sh` (on remote) |
| Config | `~/.muster/agent/agent.json` |
| Data directory | `~/.muster/agent/` |
| Daemon log | `~/.muster/agent/daemon.log` |
| PID file | `~/.muster/agent/agent.pid` |

## Commands

```bash
muster-agent.sh start [--foreground]   # Start the daemon
muster-agent.sh stop                   # Stop the daemon
muster-agent.sh status                 # Show status, health, and metrics
muster-agent.sh run-once               # Collect all data once and exit
muster-agent.sh verify                 # Verify file integrity
```

### start

Starts the agent as a background daemon (default) or in the foreground (`--foreground` for systemd/launchd). Before starting, the agent verifies its own file integrity. If the signature check fails, it refuses to start.

### stop

Sends SIGTERM to the daemon. Waits up to 5 seconds, then SIGKILL if still running.

### status

Displays:
- Agent version and process status (running/stopped)
- Signature verification status
- Service health summary (healthy/unhealthy counts)
- System metrics (CPU, memory, disk)
- Last poll timestamp

### run-once

Runs all collectors once and exits. Used by cron-based installations where a persistent daemon is not needed.

### verify

Runs the full integrity check: verifies the agent script signature and config signature against the installed public key. Reports pass/fail for each file.

## Data Collection

The agent collects four types of data on configurable intervals:

| Collector | Default Interval | Data Directory | Description |
|-----------|-----------------|----------------|-------------|
| Health | 30s | `health/` | Per-service health check results |
| Metrics | 60s | `metrics/` | System CPU, memory, disk, load average |
| Logs | 60s | `logs/` | Tail of each service's log output |
| Events | Every tick (1s) | `events/` | Deploy event log (file offset tracking) |

### Health Collection

For each service in `deploy.json`, the agent runs the service's `health.sh` hook with a configurable timeout (default 10s). Results are written as plain text files:

```
~/.muster/agent/health/api        # contains: "healthy" or "unhealthy"
~/.muster/agent/health/redis      # contains: "healthy" or "unhealthy"
```

Services with `"enabled": false` in their health config get the result `disabled`.

### Metrics Collection

System metrics are collected using OS-native tools:

| Metric | Linux | macOS |
|--------|-------|-------|
| CPU % | `/proc/stat` (1s sample) | `top -l 1` |
| Memory % | `free` | `vm_stat` + `sysctl hw.memsize` |
| Disk % | `df /` | `df /` |
| Load average | `/proc/loadavg` | `sysctl vm.loadavg` |

Output: `~/.muster/agent/metrics/latest.json`

```json
{
  "ts": "2026-03-04T12:00:00Z",
  "cpu": 23.5,
  "mem_pct": 67.2,
  "disk_pct": 45,
  "load": 1.23
}
```

### Log Collection

Runs each service's `logs.sh` hook with a 5-second timeout, captures the last N lines (default 50). Output:

```
~/.muster/agent/logs/api.tail
~/.muster/agent/logs/redis.tail
```

### Event Collection

Tracks the deploy event log (`deploy-events.log`) by file offset. Only new data since the last check is appended to the agent's local copy. This is a lightweight file-size check that runs every second.

## Push Reporting

When push is enabled, the agent periodically sends an encrypted summary to the fleet HQ via SCP.

| Config Key | Default | Description |
|------------|---------|-------------|
| `push_enabled` | `false` | Enable push reporting |
| `push_interval` | `300` | Seconds between pushes |
| `push_host` | -- | Fleet HQ hostname |
| `push_user` | -- | SSH user on fleet HQ |
| `push_port` | `22` | SSH port |
| `push_identity` | -- | SSH identity file (optional) |
| `push_dir` | -- | Remote directory for reports |

The push summary is a JSON object containing:

```json
{
  "ts": "2026-03-04T12:00:00Z",
  "hostname": "prod-1",
  "version": "0.5.55",
  "health": { "api": "healthy", "redis": "healthy" },
  "metrics": { "ts": "...", "cpu": 23.5, "mem_pct": 67.2, "disk_pct": 45, "load": 1.23 }
}
```

If the fleet public key (`fleet.pub`) is present, the summary is encrypted with RSA-4096 + AES-256-CBC before transmission (see [encryption.md](../security/encryption.md)). The encrypted file is sent as `latest.enc`; without encryption it is sent as `latest.json`.

## Signal Handling

| Signal | Behavior |
|--------|----------|
| SIGTERM / SIGINT | Graceful shutdown (completes current collection cycle) |
| SIGHUP | Reload `agent.json` config without restarting |

## Security

The agent includes several security measures:

- **Signature verification** -- Verifies its own script and config signatures before starting (see [signing.md](../security/signing.md))
- **File permission checks** -- Refuses to run if config files are world-writable or owned by another user
- **Input validation** -- All config values are validated for safe characters and correct types
- **JSON escaping** -- Output values are escaped to prevent injection
- **Atomic locking** -- Uses `mkdir` as a portable atomic lock to prevent duplicate instances
- **Encrypted push** -- Reports are encrypted with the fleet public key when available

## Configuration

The agent config file (`~/.muster/agent/agent.json`) is generated and pushed during installation:

```json
{
  "project_dir": "/opt/myapp",
  "poll_interval": 30,
  "metrics_interval": 60,
  "logs_interval": 60,
  "log_tail_lines": 50,
  "push_enabled": false,
  "push_interval": 300,
  "push_host": "",
  "push_user": "",
  "push_port": 22,
  "push_identity": "",
  "push_dir": ""
}
```

## Dependencies

- `bash` (3.2+)
- Standard Unix tools: `date`, `hostname`, `sleep`, `kill`, `mktemp`, `tail`, `wc`
- `openssl` (for signature verification and report encryption)
- `jq` (optional, with grep/sed fallback for JSON parsing)
