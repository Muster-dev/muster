# Engine API (`--json`)

The machine-readable interface of the `muster` CLI. muster-tui, scripts and
CI drive muster through these commands; this page is the contract. Tests:
`tests/test_engine_api.sh`.

## Conventions

- **stdout is JSON only.** Streaming commands print NDJSON (one object per
  line); everything else prints a single JSON document. Human text
  (warnings, prompts, hook security messages) goes to stderr.
- **Errors before any output** are one document on stderr:
  `{"error":"<code>","message":"…"}` and a non-zero exit. Common codes:
  `auth_required`, `auth_failed`, `forbidden`, `usage`, `unknown_service`,
  `no_project`, `confirmation_required`, `dangerous_hooks`, `no_logs`,
  `unknown_server`, `unpaired`, `remote_failed`.
- **Errors inside a stream** are an event: `{"event":"error","reason":…}`
  followed by a `summary`.
- **Exit codes:** `0` ok, `1` failure, `130` cancelled (Ctrl+C / SIGTERM).
  `status --json` and `cloud status --json` exit 0 even when services are
  unhealthy or you're logged out — they report state.
- **Auth:** every `--json` command needs `MUSTER_TOKEN` (`muster auth create
  <name> --scope read|deploy|admin`). Read-only commands need `read`;
  commands that change something need `deploy`. Commands launched directly
  by muster-agent (Fleet Cloud) may run read-only commands without a token.
- **Strings** are escaped for tabs, quotes, backslashes and control
  characters; ESC is kept as `\u001b`, `\r` is dropped from log lines.
- **Forward compatibility:** new fields may be added at any time; ignore
  fields you don't know. Fields are only removed in a major version.
- Timestamps: `checked_at` is ISO-8601 with zone
  (`2026-11-26T13:40:05-05:00`); history `timestamp`/`ts` and lock
  `started` are local `YYYY-MM-DD HH:MM:SS`; hook `approved_at` is UTC
  ISO-8601 (`…Z`).

## Command index

| Command | Scope | Output |
|---------|-------|--------|
| `setup --scan --dry-run --json [--path P] [--stack S] [--namespace N]` | read | document |
| `status --json` | read | document |
| `history --json [--all] [service]` | read | array |
| `doctor --json` | read | document |
| `hooks --json` / `hooks <svc> --json` / `hooks <svc> <hook> --json` | read | document |
| `hooks status --json` | read | document |
| `hooks approve --yes [service…] --json` | deploy | document |
| `deploy --json [--dry-run] [--stop-on-failure] [--from svc] [--yes] [service…]` | deploy | NDJSON |
| `rollback <service> --json [--yes]` | deploy | NDJSON |
| `restart <service> --json [--yes]` | deploy | NDJSON |
| `logs <service> --json [--tail N] [--follow]` | read | NDJSON |
| `fleet list --json` | read | document |
| `fleet status [target] --json` | read | document |
| `fleet test [target] --json` | read | document |
| `fleet logs <server> <service> --json [--tail N]` | read | NDJSON |
| `fleet restart <server> [service…] --json --yes` | deploy | document |
| `fleet history <server> [service] --json [--all]` | read | array |
| `cloud status --json` | read | document |
| `group list --json`, `group status <group> --json` | read | document |
| `projects --json` | read | document |
| `verify --json` | — | document |

---

## setup --scan --dry-run --json

Runs the real scanner (project files, compose, k8s manifests, the live
cluster for k8s, dev start commands) and reports what `muster setup --scan`
would configure. Writes nothing. Accepts `--path`, `--stack`,
`--namespace`, `--name`, `--force`.

```json
{
  "dry_run": true,
  "project": "acme-store",
  "root": "/srv/acme-store",
  "stack": "compose",
  "detected_stack": "compose",
  "namespace": null,
  "cluster_scanned": false,
  "found": [{"file": "docker-compose.yml", "description": "Docker Compose config"}],
  "services": [
    {"key": "redis", "name": "Redis", "detected_as": "redis", "role": "infra", "kind": "infra",
     "image": null, "port": 6379,
     "health": {"type": "tcp", "port": 6379, "timeout": 10, "enabled": true},
     "credentials": {"mode": "off"}, "skip_deploy": false,
     "hooks_template": "compose/infra", "source_files": ["docker-compose.yml"]},
    {"key": "api", "name": "API Server", "detected_as": "api", "role": "app", "kind": "build",
     "image": null, "port": 8080,
     "health": {"type": "tcp", "port": 8080, "timeout": 10, "enabled": true},
     "credentials": {"mode": "off"}, "skip_deploy": false,
     "hooks_template": "compose", "source_files": ["docker-compose.yml", "api/Dockerfile"]}
  ],
  "deploy_order": ["redis", "api"],
  "warnings": []
}
```

- `role`: `infra` (known infrastructure: redis, postgres, …) or `app`.
  `kind`: `infra`, `build` (has a Dockerfile) or `app`.
- `health`: `{"enabled":false}` or `{type: http, endpoint, port, timeout,
  enabled}` / `{type: tcp, port, …}` / `{type: command, command, …}`.
- `hooks_template`: template directory under `templates/hooks/`
  (`k8s`, `k8s/infra`, `compose`, `docker/infra`, `dev`, `bare`, …) or
  `stub`.
- `image`: default image the infra template pulls (null for compose, which
  uses the compose file's image, and for app services).
- k8s services add `"k8s": {"deployment", "namespace"}`; dev services add
  `"dev": {"start_cmd", "port"}`. `skip_deploy` is true for services found
  in files but not as a deployment in the scanned cluster.
- `warnings`: scanner messages (cluster unreachable, …), "Config already
  exists" (setup would need `--force`), "No services detected".

## status --json

```json
{
  "project": "acme-store",
  "muster_version": "0.7.1",
  "checked_at": "2026-11-26T13:40:05-05:00",
  "deploying": false,
  "deploy_lock": null,
  "services": {
    "api": {
      "name": "API Server", "status": "unhealthy", "health_type": "http",
      "stack": "k8s",
      "health": {"type": "http", "port": 8080, "endpoint": "/health", "command": null, "timeout": 10, "enabled": true},
      "target": "http://localhost:8080/health",
      "remote": null,
      "last_deploy": {"ts": "2026-11-26 13:38:00", "status": "ok", "commit": "4f2a9c1", "source": "local"},
      "locked_by": null,
      "deploying": false,
      "replicas": {"ready": 2, "desired": 3}
    }
  }
}
```

- `status`: `healthy`, `unhealthy`, `disabled`, `no_health_check`, or
  `blocked` (health hook failed the security check; see `hooks status`).
  Disabled / no-check / blocked entries also carry `detail`.
- `stack`: `k8s`, `compose`, `docker`, `dev` or `bare` (from config + hooks).
- `target`: what the health check aims at (URL, `tcp://host:port`, or the
  command), null when unknown.
- `remote`: `user@host[:port]` for remote services.
- `last_deploy`: latest deploy event from history, or null.
- `locked_by` (`{user, host, source, pid, started}`) / `deploying`: a
  deploy of this service is running (any terminal or machine).
- Top-level `deploying` / `deploy_lock` (`{user, pid, started, services}`):
  a project-wide deploy or rollback holds the lock.
- `muster_version`: the muster that answered (added after 0.7.0; older
  versions omit it).
- `replicas`: k8s only, when kubectl answers within 5s; otherwise null.

## history --json

Array, oldest first (last 20 unless `--all`):

```json
[{"timestamp": "2026-11-26 13:40:05", "service": "api", "action": "deploy", "status": "ok", "commit": "4f2a9c1", "source": "local"}]
```

`action`: `deploy`, `rollback`, `restart`. `status`: `ok`, `failed`,
`cancelled`. `source`: `local` or the fleet/group deployer.

## doctor --json

```json
{"pass": 18, "warnings": 2, "failures": 1, "fixable": 2,
 "checks": [
   {"name": "1 hook scripts not executable (--fix)", "status": "fail", "category": "Configuration",
    "fixable": true, "fix": "chmod +x the hook scripts"},
   {"name": "Docker installed but daemon not running", "status": "warn", "category": "Platform & Tools",
    "fixable": false, "fix": null}
 ]}
```

`status`: `pass`, `warn`, `fail`. `fixable` is true when `muster doctor
--fix` repairs it; `fix` says what it would do. Top-level `fixable` counts
them.

## hooks status --json

Approval state of every hook file on this machine (the trust store under
`~/.muster/trust/`), plus `muster.json` and `.env`.

```json
{
  "approved": false,
  "security_enabled": true,
  "trust_dir": "/Users/me/.muster/trust/362f…",
  "manifest": "/Users/me/.muster/trust/362f…/hooks.manifest",
  "signature": "valid",
  "files": [
    {"service": "api", "file": "deploy.sh", "key": "api/deploy.sh", "path": ".muster/hooks/api/deploy.sh",
     "state": "changed", "approved_at": "2026-11-26T18:02:11Z",
     "approved_copy": "/Users/me/.muster/trust/362f…/approved/api/deploy.sh", "dangerous": []}
  ],
  "config": {"service": null, "file": "muster.json", "key": "_config/muster.json", "path": "muster.json",
             "state": "approved", "approved_at": "…", "approved_copy": "…", "dangerous": []},
  "env": null,
  "pending": ["api/deploy.sh"]
}
```

- `state`: `approved`, `changed` (differs from the approved version), `new`
  (never approved here), `missing` (approved, file gone — not pending).
- `signature`: `valid`, `invalid` (manifest tampered — everything is `new`),
  `unsigned`, `none` (nothing approved yet — everything is `new`).
- `approved_copy`: the approved version, for diffs; null if none.
- `dangerous`: `"line N: description"` for each dangerous pattern found.
- `env`: present when `.env` exists or was approved.
- `pending`: keys a deploy would stop on (`hooks_not_approved`).
- `security_enabled: false` when `hook_security` is `off` globally
  (nothing is enforced then).

## hooks approve --yes [service…] --json

Approves what's pending without a prompt (no sudo; `--yes` is the
confirmation). With services, approves their pending hooks (and a changed
`muster.json`, as `deploy --yes` does); without, approves everything
including `.env`.

```json
{"ok": true, "count": 2,
 "approved": [{"key": "api/deploy.sh", "was": "changed"}, {"key": "_config/muster.json", "was": "changed"}],
 "services": ["api"], "trust_dir": "/Users/me/.muster/trust/362f…"}
```

Errors (stderr, exit 1): `confirmation_required` (no `--yes`),
`unknown_service`, `no_project`, and

```json
{"error": "dangerous_hooks", "message": "…", "files": [{"key": "web/deploy.sh", "issue": "line 4: Remote code execution (curl pipe bash)"}]}
```

## hooks --json (inventory)

- `hooks --json`: `{"services":[{"name","hooks":[{"name","exists","executable","lines"}]}]}`
- `hooks <svc> --json`: `{"service","hooks":[…]}`
- `hooks <svc> <hook> --json`: `{"service","hook","exists","executable","lines","path","content"}`

## deploy --json

NDJSON, in order:

| Event | Fields |
|-------|--------|
| `error` | `reason`, `message`, `services` (+ `files` for `hooks_not_approved`); then `summary` |
| `dry_run` | `service`, `name`, `index`, `total`, `hook`, `hook_lines` (with `--dry-run`) |
| `skipped` | `service`, `reason` (`no_hook`, `locked`) |
| `start` | `service`, `name`, `index`, `total`, `log_file` |
| `git_pull` | `service`, `status` (`pulling`/`done`/`failed`), `remote`, `branch`, `exit_code` |
| `log` | `service`, `line` |
| `done` | `service`, `status` (`success`/`failed`/`timeout`/`blocked`), `exit_code`, `timeout` |
| `verify_warning` | `service`, `message` |
| `diagnosis` | after a failed k8s `done`, see below |
| `hint` | after a failed `done` when the offline rules engine matches, see below |
| `health` | `service`, `status` (`checking`/`healthy`/`unhealthy`) |
| `stopped` | `reason: "failure"`, `after`, `remaining` (`--stop-on-failure`) |
| `cancelled` | `service`, `exit_code: 130` |
| `complete` | `total`, `dry_run` |
| `summary` | see below (not for `--dry-run`) |

`error` reasons: `hooks_not_approved` (`files: [{key, state}]`, fix with
`hooks approve --yes`), `preflight_failed` (`message`: missing/unreachable
docker, compose or kubectl), `unknown_service` (`--from` target not in the
deploy).

```json
{"event":"error","reason":"hooks_not_approved","message":"Hooks changed or not approved on this machine (muster hooks status --json)",
 "files":[{"key":"api/deploy.sh","state":"changed"}],"services":["api","web"]}
```

```json
{"event":"summary","total":3,"deployed":1,"failed":1,"skipped":0,"not_run":1,"rolled_back":0,
 "duration":42,"exit_code":1,"stopped_early":true,
 "services":[
   {"service":"api","name":"API Server","result":"deployed","duration":30,"health":"healthy","log_file":"…/api-deploy-20261126-134005.log"},
   {"service":"web","name":"Web","result":"failed","duration":12,"health":"-","log_file":"…"},
   {"service":"worker","name":"Worker","result":"not_run","duration":0,"health":"-","log_file":""}]}
```

`result`: `deployed`, `failed`, `skipped`, `not_run`, `rolled back`.
`health`: `healthy`, `unhealthy`, `disabled`, `-`.

Flags:

- `--stop-on-failure`: end after the first service that fails (deploy
  failed, timed out, blocked, unhealthy, or locked); the rest are
  `not_run`. Without it, JSON mode records the failure and continues.
- `--from <svc>`: start at that service in deploy order (after
  `deploy_phases`), e.g. to resume after a fix. Combine with service names
  to resume inside a selection.
- `--yes` / `MUSTER_APPROVE_HOOKS=1`: approve pending hooks first.

### hint

```json
{"event":"hint","service":"api","hint":{"id":"port_in_use",
 "title":"Port 8080 is already in use by Python (PID 77066).",
 "try":"Stop it (kill 77066) if it's a leftover, or change the port this service uses.",
 "fix":{"label":"Stop Python (PID 77066) on port 8080","command":"kill 77066","internal":false},
 "docs":"https://getmuster.dev/docs/troubleshooting#port-in-use","line":"…matched log line…"}}
```

Emitted by `deploy --json` (and rollback) after a failed `done` when a rule in
`lib/core/hints.sh` matches. `fix` is `null` when there's no safe fix;
`internal: true` means a built-in muster.json edit. Never run `fix.command`
yourself: ask the user, then run `muster explain <service> --fix --yes`, which
re-derives and validates the command. `muster explain --json` returns the same
object under `hint`, next to `service`, `action`, `exit_code`, `log` and `matched`.

### diagnosis

```json
{"event":"diagnosis","service":"api","kind":"k8s","pattern":"ImagePullBackOff",
 "summary":"Can't pull container image","hint":"Check registry auth, image name, and tag",
 "patterns":[{"pattern":"ImagePullBackOff","summary":"…","hint":"…"}],
 "deployment":"acme-api","namespace":"acme","pod":"acme-api-7d9c-xk2","pod_status":"0/1 ImagePullBackOff",
 "details":["Events:","  Warning  Failed  …"],"log_tail":["…"],"logs":["…"]}
```

Only for k8s services with kubectl. `pattern` is the first match of
`ErrImageNeverPull`, `ImagePullBackOff`, `InvalidImageName`, `OOMKilled`,
`CrashLoopBackOff`, `CreateContainerConfigError`, `RunContainerError`,
`Unschedulable`, `SecretNotFound`, `PVCNotFound`, `VersionMismatch`, or
`unknown` (then `hint` names the `kubectl describe` to run). `patterns`
lists every match. `details`: the pod's Events section (last 15 lines).
`log_tail` (alias `logs`): current + previous container logs (last 30).
Also emitted by `rollback --json` and `restart --json`.

## rollback \<service\> --json

Same events as deploy for one service: `start` (with `"action":"rollback"`),
`log`, `done`, `diagnosis`, `health`, then

```json
{"event":"summary","action":"rollback","total":1,"rolled_back":1,"failed":0,"duration":8,"exit_code":0,
 "services":[{"service":"api","name":"API Server","result":"rolled back","duration":8,"health":"healthy","log_file":"…"}]}
```

`result`: `rolled back`, `failed`, `skipped` (didn't run). Pre-run
problems are `error` events with `reason` `no_hook`, `locked`,
`hooks_not_approved` (with `files`), followed by the summary. No service
name: `{"error":"usage"}` on stderr. Exit 0 only when rolled back and not
unhealthy.

## restart \<service\> --json

```json
{"event":"start","service":"api","name":"API Server","action":"restart","method":"k8s","stack":"k8s","index":1,"total":1,"log_file":"…"}
```

then `log`, `done`, `diagnosis`, `health`, and a `summary` like rollback's
with `"action":"restart"`, `"restarted": 0|1` and `result` `restarted` /
`failed` / `skipped`. `method`: `hook` (restart.sh / justfile recipe),
`k8s` (`kubectl rollout restart` + `rollout status`), `compose`
(`docker compose restart`), `docker` (`docker restart`). When none applies
(bare, dev) the first line is

```json
{"event":"restart","service":"api","method":"redeploy","stack":"bare","message":"No restart hook and no built-in restart for bare services — redeploying api instead (no rollback)"}
```

followed by a normal `deploy --json` stream for that service.

## logs \<service\> --json [--tail N] [--follow]

```json
{"event":"log","service":"api","source":"kubectl","line":"GET /health 200"}
{"event":"end","service":"api","source":"kubectl","exit_code":0}
```

- `--tail N`: last N lines, then `end`. Uses the stack's log command:
  `source` `kubectl`, `docker compose`, `docker`, `file` (dev), otherwise
  `hook` (the logs hook, stopped after 5s, `MUSTER_LOGS_TAIL` set) or
  `deploy_log` (latest deploy log).
- `--tail N --follow`: last N lines, then keeps streaming until killed.
- `--json` alone: follows the usual source (logs hook / just recipe /
  latest deploy log) until killed.
- No source: `{"error":"no_logs"}` on stderr, exit 1.

Without `--json`, `muster logs <svc> --tail N` prints the raw lines.

## fleet list --json

Same shape for `remotes.json` and fleet directories:

```json
{"source": "fleet_dirs",
 "machines": [{"name": "prod-1", "host": "10.0.0.5", "user": "deploy", "port": 22, "transport": "ssh",
               "mode": "muster", "hook_mode": "manual", "project_dir": "/opt/acme", "identity_file": null,
               "fleet": "default", "group": "prod", "paired": true}],
 "groups": [{"name": "prod", "fleet": "default", "machines": ["prod-1"]}]}
```

`source`: `remotes.json`, `fleet_dirs`, `none`. `transport`: `ssh`/`cloud`.
`mode`: `muster` (remote runs muster) / `push` (hooks piped over SSH).
`paired`: ready to run muster commands without SSH pairing: a muster-mode SSH
server has an auth token. Always true for push servers (no muster there) and
cloud servers (the Fleet Cloud relay authenticates; there is no pairing
token). It is read from config only; use `fleet test --json` to check the
agent is actually reachable. `fleet deploy --dry-run` uses the same rule.
`fleet` is `""` and `group` may be null for `remotes.json` machines.

## fleet status [target] --json

```json
{"status": [
  {"machine": "prod-1", "host": "10.0.0.5", "user": "deploy", "port": 22, "transport": "ssh", "mode": "muster",
   "reachable": true, "healthy": 2, "total": 3, "error": null, "muster_version": "",
   "services": [{"service": "api", "name": "API Server", "status": "healthy", "health_type": "http"}]}
]}
```

`services` is that machine's own `status --json` services as an array
(null when unavailable). `error`: `unreachable`, `unpaired`, `no status`,
`no status from agent`, or null. `muster_version`: from the server's own
`status --json` (no extra round trip); `""` when unknown, which includes
every server running muster 0.7.0 or older.

## fleet test [target] --json

```json
{"servers": [
  {"name": "byricky", "transport": "cloud", "mode": "muster", "ok": true,
   "connect": "ok", "muster": "ok", "latency_ms": 276, "error": ""}
 ], "passed": 1, "failed": 0}
```

Exit 0 when every server passed, else 1. `target`: a server, a group, or
omitted for all servers.

- `connect`: `ok`/`fail` — SSH `echo ok`, or the relay ping for cloud.
- `muster`: `ok`/`fail`, or `skip` for push servers and when `connect`
  failed (not checked). Muster mode checks `status --json` on the agent
  (cloud) or that the stored token works (SSH); an unpaired SSH server is
  `fail`.
- `latency_ms`: integer ms for the connectivity check only. Resolution
  depends on the machine running the command: `$EPOCHREALTIME` (bash 5),
  GNU `date +%s%N`, perl `Time::HiRes`, or whole seconds × 1000 when none
  of those exist.
- `error`: short reason when `ok` is false (`SSH connection failed`,
  `cloud agent is not connected to the relay`, `muster-tunnel is not
  installed on this computer`, `muster did not answer on the agent`,
  `unpaired: run muster fleet pair …`, `not in the fleet config`), else `""`.

## fleet logs \<server\> \<service\> --json [--tail N]

Runs `muster logs <service> --tail N --json` on the server and passes its
NDJSON through unchanged (see `logs --json`); non-JSON output goes to
stderr. `N` defaults to 100, max 1000 (larger values are capped). No
`--follow`.

- Cloud servers: sent as plain argv through the relay; read-only commands
  run on the agent without a `MUSTER_TOKEN`.
- SSH muster-mode servers: `MUSTER_TOKEN=<paired token> muster logs …` in
  the server's project dir (`unpaired` error without a token).
- Push servers (no muster there): runs this project's
  `.muster/hooks/<service>/logs.sh` on the server for at most 5s with
  `MUSTER_LOGS_TAIL=N` and wraps each line as
  `{"event":"log","service":…,"source":"hook","line":…}`, then `end`.

Errors: `usage` (missing args, service not `^[A-Za-z0-9_.-]+$`, bad
`--tail`, `--follow`), `unknown_server`, `unpaired`, `no_logs`. A remote
`{"error":…}` document (e.g. `unknown_service`) is forwarded as is; other
remote failures are `remote_failed`. Exit code is the remote one.

## fleet restart \<server\> [service…] --json --yes

```json
{"server": "byricky", "results": [{"service": "web", "ok": true, "error": ""}]}
```

Runs `muster restart <service>` on the server for each service (default:
this project's deploy order, skipping `skip_deploy`). Exit 0 when all
succeeded. Needs `--yes` without a TTY (`confirmation_required`).
`error`: short reason when `ok` is false, e.g. hooks not approved on the
server, the cloud agent's allowlist refusing `muster restart`, or
`push mode needs a restart hook`. Push servers run this project's
`.muster/hooks/<service>/restart.sh` remotely. Restart hooks must be
approved on the server itself (`muster hooks approve` there).

## fleet history \<server\> [service] --json [--all]

Runs `muster history [--all] --json [service]` on a muster-mode server and
prints its array unchanged (same shape as `history --json`); other output
goes to stderr. Cloud servers: plain argv through the relay, no token. SSH
servers: with the paired token as `MUSTER_TOKEN`.

Errors: `usage`, `no_fleet`, `unknown_server`, `push_mode` (history lives on
the machine that deploys a push server), `remote_failed`. A remote
`{"error":…}` document is passed through on stdout.

## cloud status --json

```json
{"logged_in": true, "name": "Ricky's MacBook", "org_id": "org_1", "org": "org_1",
 "relay": "https://relay.getmuster.dev", "relay_reachable": true,
 "tunnel_installed": true, "tunnel_path": "/usr/local/bin/muster-tunnel"}
```

## Other documents

- `group list --json`: `{"<group>": {"name", "project_count"}}`
- `group status <group> --json`: `{"group", "projects": [{"name", "type", "status"}]}`
- `projects --json`: registered projects; `projects --prune --json`: `{"pruned": N}`
- `verify --json`: `{"result": "pass"|"fail"|"no_manifest", "mode": "quick"|"full", …}`

## Not in the API yet

Tracked in muster-tui's `docs/ENGINE-GAPS.md`: per-service image/version in
history and the deploy summary, health latency and error detail in
`status`, `machine` on `fleet deploy --json` events,
`cloud agents --json`, `doctor --fix --json` change reports, settings /
config validation as JSON, and a TUI pairing command.
