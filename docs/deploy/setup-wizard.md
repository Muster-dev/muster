# Setup Wizard

Configure a project for muster deployment. Generates `muster.json` and hook scripts in `.muster/hooks/`.

## Quick Start

```bash
muster setup                          # interactive TUI wizard
muster setup --scan                   # non-interactive: auto-detect everything
muster setup --services api,redis     # non-interactive: explicit services
muster setup --force --scan           # overwrite existing config
muster setup --help                   # show all flags
```

## Interactive Mode

Running `muster setup` without flags launches a full-screen TUI wizard. Requires a TTY (errors if stdin is not interactive).

### Wizard Steps

1. **Machine role** -- choose how this machine participates:
   - Just this machine (local deploy)
   - Deploy to others (fleet control)
   - Receive deploys (deploy target)
   - Both (local + fleet control)

2. **Environment** -- sets default health timeout and credential mode:

   | Environment | Health Timeout | Credential Default |
   |-------------|---------------|-------------------|
   | Production | 30s | `session` |
   | Staging | 15s | `session` |
   | Development | 5s | `off` |

3. **Components** -- select what the project runs (web app, workers, database, cache, proxy, other)

4. **Scan project** -- auto-detects stack, services, health probes, git info, and secrets from project files

5. **Confirm scan results** -- review detected stack, services, ports, and health checks. Choose "Yes" to accept or "Let me adjust" to override.

6. **Deploy order** -- drag/reorder services (infrastructure services auto-sorted first)

7. **Per-service config** -- health checks, credentials, remote deploy, git pull

### Scan Results Preview

The wizard shows a summary of what was detected:

```
Stack:      Kubernetes
Services:   api (port 3000), worker, redis (port 6379)
Health:     api -> HTTP /health:3000
            redis -> TCP :6379
Git:        myapp/main
Secrets:    DATABASE_URL, API_KEY (from .env)
```

## Non-Interactive Mode

Any flag triggers non-interactive mode. Outputs plain text (no TUI).

### Flags

| Flag | Description |
|------|-------------|
| `--path, -p <dir>` | Project directory (default: `.`) |
| `--scan` | Auto-detect stack and services from project files |
| `--stack, -s <type>` | Stack type: `k8s`, `compose`, `docker`, `bare`, `dev` |
| `--services <list>` | Comma-separated service names |
| `--order <list>` | Comma-separated deploy order |
| `--health <spec>` | Per-service health (repeatable) |
| `--creds <spec>` | Per-service credential mode (repeatable) |
| `--remote <spec>` | Per-service remote config (repeatable) |
| `--git-pull <spec>` | Per-service git pull config (repeatable) |
| `--namespace <ns>` | Kubernetes namespace (default: `default`) |
| `--name, -n <name>` | Project name (default: directory basename) |
| `--force, -f` | Overwrite existing `muster.json` |

### Health Spec Format

```
--health <service>=<type>[:<args>]
```

| Type | Format | Example |
|------|--------|---------|
| HTTP | `http:<endpoint>:<port>` | `--health api=http:/health:8080` |
| TCP | `tcp:<port>` | `--health redis=tcp:6379` |
| Command | `command:<cmd>` | `--health worker=command:./check.sh` |
| Disabled | `none` | `--health api=none` |

### Credential Modes

```
--creds <service>=<mode>
```

Modes: `off`, `save` (keychain), `session` (memory), `always` (prompt every time).

### Remote Spec Format

```
--remote <service>=<user>@<host>[:<port>][:<path>]
```

Examples:

```bash
--remote api=deploy@prod.example.com
--remote api=deploy@prod.example.com:2222
--remote api=deploy@prod.example.com:/opt/myapp
--remote api=deploy@prod.example.com:2222:/opt/myapp
```

### Git Pull Spec Format

```
--git-pull <service>[=<remote>:<branch>]
```

Defaults to `origin:main` if no remote/branch specified.

```bash
--git-pull api                     # origin/main
--git-pull api=origin:main
--git-pull api=upstream:develop
```

### Examples

```bash
# Auto-detect everything
muster setup --scan

# Explicit services with health checks
muster setup --stack k8s --services api,redis --name myapp \
  --health api=http:/health:3000 \
  --health redis=tcp:6379

# Remote deploy with git pull
muster setup --scan \
  --remote api=deploy@prod.example.com:/opt/app \
  --git-pull api=origin:main

# Full spec
muster setup --path /opt/myapp --stack k8s --services api,worker,redis \
  --order redis,worker,api --namespace production \
  --health api=http:/health:8080 --health redis=tcp:6379 \
  --creds api=session --remote api=deploy@prod:2222:/opt/app \
  --git-pull api --name myapp --force
```

## Stack Auto-Detection

The scanner examines project files to determine the stack:

| Files Found | Detected Stack |
|------------|---------------|
| `k8s/`, `deploy/`, `*-deployment.yaml` | `k8s` |
| `docker-compose.yml`, `compose.yaml` | `compose` |
| `Dockerfile` | `docker` |
| `systemd/`, `.service` files | `bare` |
| (development environment selected) | `dev` |

Scans the project root and common subdirectories: `docker/`, `k8s/`, `deploy/`, `infra/`.

## K8s Live Introspection

When the stack is `k8s`, `scan_k8s_cluster()` queries the live cluster:

```bash
kubectl get deployments -n <namespace> -o json
```

This auto-detects:

- **Deployment names** -- strips common project prefix (e.g., `myapp-api` becomes `api`)
- **Container ports** -- used for health check configuration
- **Liveness/readiness probes** -- auto-configures matching health checks
- **Missing deployments** -- services detected from files but not found as K8s deployments get `skip_deploy: true`

Graceful degradation: if `kubectl` is not installed or the cluster is unreachable, introspection is silently skipped.

## Infrastructure Service Detection

Known infrastructure service names are auto-detected and handled specially:

- redis, postgres, postgresql, mysql, mariadb, mongo, mongodb
- rabbitmq, kafka, elasticsearch, memcached, nginx, caddy, traefik, haproxy

Infrastructure services:
- Are sorted before app services in deploy order
- Get pull-only hook templates (no docker build)
- Use `kubectl rollout restart` for K8s (not `kubectl set image`)

## .musterignore Support

Create a `.musterignore` file in the project root to exclude paths from scanning. Uses the same pattern format as `.gitignore`. Global exclusions can also be set via `scanner_exclude` in `~/.muster/settings.json`.

The scanner automatically skips `archived/`, `deprecated/`, `old/`, and `backup/` directories.

## Generated Files

After setup, the project contains:

```
your-project/
  muster.json                   # project config
  .gitignore                    # updated with .muster/logs/ and .muster/pids/
  .muster/
    hooks/<service>/
      deploy.sh                 # deploy hook
      health.sh                 # health check hook
      rollback.sh               # rollback hook
      logs.sh                   # log streaming hook
      cleanup.sh                # cleanup hook
    logs/                       # deploy logs (gitignored)
    skills/                     # per-project skills
    .hook_manifest              # hook integrity manifest
    .hook_manifest.sig          # manifest signature
```

The project is also registered in the global project registry for the dashboard.
