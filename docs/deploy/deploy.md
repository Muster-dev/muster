# Deploy

Deploy services defined in `muster.json`. Executes hooks, runs health checks, and provides interactive failure recovery.

## Quick Start

```bash
muster deploy              # interactive: pick all or select services
muster deploy api          # deploy one service
muster deploy --dry-run    # preview deploy plan without executing
muster deploy --json       # stream deploy events as NDJSON
muster deploy --force      # override an existing deploy lock
```

## Deploy Flow

1. **Load config** -- reads `muster.json` and auto-loads `.env` from the project root
2. **Acquire deploy lock** -- prevents concurrent deploys (skip with `--force`)
3. **Deploy password gate** -- if configured, prompts for deploy password
4. **Resolve services** -- reads `deploy_order` from config, filters out `skip_deploy: true` services
5. **Interactive selection** -- if >1 service in a TTY, prompts "All services" or "Select services"
6. **Pre-authenticate SSH** -- collects SSH passwords for remote services up front
7. **For each service:**
   - Run `pre-deploy` skill hooks
   - Auto `git pull` (if configured)
   - Security check on the hook script
   - Execute `deploy.sh` hook (or justfile `deploy` recipe)
   - Verify deploy output (warnings for empty logs, <1s deploys, missing success markers)
   - Run `post-deploy` skill hooks
   - Execute `health.sh` hook
8. **Release deploy lock**

## Interactive Service Selection

When deploying all services in a TTY with more than one service configured, muster shows a menu:

| Option | Behavior |
|--------|----------|
| All services | Deploy every service in `deploy_order` |
| Select services | Opens a checklist to pick specific services |
| Back | Cancel and return to dashboard |

In non-interactive mode (CI, scripts, `--json`), all services deploy without prompting.

## Deploy Order

Services deploy in the order specified by `deploy_order` in `muster.json`. If `deploy_phases` is configured, services are reordered to match phase ordering. Infrastructure services (redis, postgres, etc.) are auto-sorted before app services during setup.

## Dry-Run Mode

```bash
muster deploy --dry-run
muster deploy --dry-run api
```

Previews the deploy plan without executing anything. For each service, shows:

- Hook file path and first 10 lines of the script
- Credential key names (without fetching values)
- Health check status (enabled/disabled)
- Remote deploy target (if configured)
- Git pull config (if configured)

## Deploy Failure Recovery

When a deploy hook exits non-zero, muster shows the last 5 log lines, runs K8s diagnostics (if applicable), fires `post-deploy` skill hooks with `MUSTER_DEPLOY_STATUS=failed`, then presents an interactive menu:

| Option | Behavior |
|--------|----------|
| Retry | Re-run the same service's deploy hook with a fresh log file |
| Rollback & restart | (K8s update deploys only) `kubectl rollout undo` + `kubectl rollout restart` |
| Rollback \<name\> | Execute the service's `rollback.sh` hook |
| Skip and continue | Mark as skipped, continue to the next service |
| Abort | Stop the entire deploy |

The entire deploy execution for each service is wrapped in a `while true` retry loop, so "Retry" seamlessly loops back.

In non-interactive mode, deploy aborts immediately on failure (exit code 1).

## Timeout

Deploy hooks are subject to a configurable timeout. The default is 120 seconds, overridable per-service via `deploy_timeout` in `muster.json`:

```json
{
  "services": {
    "api": {
      "deploy_timeout": 300
    }
  }
}
```

The timeout value is exported as `MUSTER_DEPLOY_TIMEOUT` for hooks to read. If a deploy exceeds the timeout, it exits with code 124.

## Health Checks

After a successful deploy, muster runs the service's `health.sh` hook (if health is enabled and the hook exists). If the health check fails, an interactive menu offers:

| Option | Behavior |
|--------|----------|
| Continue anyway | Proceed to the next service |
| Rollback \<name\> | Run the rollback hook |
| Abort | Stop the deploy |

## Skill Hooks

Skills can hook into the deploy lifecycle. Hooks fire per-service:

| Hook | When | MUSTER_DEPLOY_STATUS |
|------|------|----------------------|
| `pre-deploy` | Before the deploy hook runs | (not set) |
| `post-deploy` | After deploy completes or fails | `success`, `failed`, or `skipped` |

Skill hook failures are non-fatal -- muster warns and continues. On deploy failure, `post-deploy` fires immediately (before the user responds to the recovery menu), so notifications go out in real time.

## MUSTER_DEPLOY_STATUS

Set after each service's deploy attempt and exported for skill hooks:

| Value | Meaning |
|-------|---------|
| `success` | Deploy hook exited 0 |
| `failed` | Deploy hook exited non-zero or timed out |
| `skipped` | User chose "Skip and continue" in the failure menu |

## Remote Deployment

Services with `remote` configured in `muster.json` deploy via SSH:

```json
{
  "services": {
    "api": {
      "remote": {
        "enabled": true,
        "host": "prod.example.com",
        "user": "deploy",
        "port": 22,
        "project_dir": "/opt/app"
      }
    }
  }
}
```

Remote deploys pipe the hook script to the target via `ssh user@host "bash -s"`. Credential and K8s environment variables are exported on the remote side. SSH passwords for password-authenticated hosts are collected up front (before the deploy loop) to avoid repeated prompting.

## Git Pull Before Deploy

Per-service `git_pull` config runs `git pull` automatically before the deploy hook:

```json
{
  "services": {
    "api": {
      "git_pull": {
        "enabled": true,
        "remote": "origin",
        "branch": "main"
      }
    }
  }
}
```

For remote deploys, git pull runs via SSH on the target machine. If git pull fails, an interactive menu offers Retry, Skip, or Abort. In non-interactive mode, git pull failures are skipped with a warning.

## K8s Smart Rollout Wait

K8s deploy templates use `_k8s_smart_wait()` instead of bare `kubectl rollout status --timeout`. This function:

1. Starts the rollout in the background
2. Polls pod status every 5 seconds
3. Prints progress (`"2/3 pods ready (15s)"`)
4. Detects terminal errors immediately: `ErrImageNeverPull`, `ImagePullBackOff`, `CrashLoopBackOff`, `OOMKilled`, `CreateContainerConfigError`, `RunContainerError`, `InvalidImageName`
5. On terminal error: prints the error, shows pod events/logs, kills the rollout wait, exits non-zero

## JSON Mode

```bash
muster deploy --json
```

Streams NDJSON (one JSON object per line) for programmatic consumption. Events:

| Event | Fields |
|-------|--------|
| `start` | `service`, `name`, `index`, `total`, `log_file` |
| `git_pull` | `service`, `remote`, `branch`, `status` |
| `log` | `service`, `line` |
| `done` | `service`, `status` (`success`/`failed`/`timeout`), `exit_code` |
| `health` | `service`, `status` (`checking`/`healthy`/`unhealthy`) |
| `verify_warning` | `service`, `message` |
| `dry_run` | `service`, `name`, `index`, `total`, `hook`, `hook_lines` |
| `complete` | `total`, `dry_run` |

## Deploy Lock

Muster acquires a lock before deploying to prevent concurrent deploys. The lock is released when the deploy completes or the process exits. Use `--force` to override an existing lock.

Fleet deploys and group deploys also block local deploys via separate lock files (`.muster/.fleet_deploying` and `~/.muster/.group_deploying`).

## Deploy Verification

After each successful deploy, muster runs three non-blocking checks:

1. **Empty log** -- warns if the deploy produced no output
2. **Suspiciously fast** -- warns if the deploy completed in less than 1 second
3. **Success markers** -- warns if the log output contains no recognized success keywords (deployed, started, built, running, etc.)

These are warnings only and never block the deploy.
