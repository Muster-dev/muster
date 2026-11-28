# MCP server (`muster-mcp`)

`bin/muster-mcp` is a [Model Context Protocol](https://modelcontextprotocol.io)
server. It lets Claude Code, Claude Desktop, Cursor, VS Code and any other MCP
client check, explain, deploy and roll back the services of one muster project
and its fleet. It is pure bash and needs only `jq`, which muster already uses
for every JSON path. It talks over stdio and serves one project.

Tools run muster's engine API (`muster … --json`, [ENGINE-API.md](ENGINE-API.md))
with a scoped local token. Hook approvals, deploy locks, token scopes,
preflight and redaction therefore behave exactly as they do on the command
line. The server never runs a hook script itself.

## Quick start

```bash
cd your-project
muster mcp doctor                      # start the server, check the handshake, list tools
muster mcp install claude              # print the config for a client
muster mcp install cursor --write      # merge it into .cursor/mcp.json (shows the diff first)
muster mcp install claude-desktop --allow-actions --write
```

`muster mcp install <client>` prints the config, and `--write` merges it into
the client's file. With `--write`, muster shows a diff, asks `[y/N]` (pass
`--yes` when there is no TTY), keeps your other servers and saves the previous
file as `<file>.bak`. `--project DIR` points the server at another project. The
default is the project you're in, or the current directory.

Configs use absolute paths for both the server and the project. GUI clients
start servers with a minimal `PATH` and no working directory, so relative
paths don't work there. The server also adds `/opt/homebrew/bin` and
`/usr/local/bin` to its `PATH` so it can find `jq`.

## Client setup

### Claude Code

```bash
# this project only (local scope)
claude mcp add muster -- /path/to/muster/bin/muster-mcp --project /path/to/project
# shared with the repo (.mcp.json, project scope)
claude mcp add --scope project muster -- /path/to/muster/bin/muster-mcp --project /path/to/project
```

`muster mcp install claude --write` writes `.mcp.json` directly:

```json
{
  "mcpServers": {
    "muster": {
      "command": "/path/to/muster/bin/muster-mcp",
      "args": ["--project", "/path/to/project"]
    }
  }
}
```

### Claude Desktop

Claude Desktop reads `~/Library/Application Support/Claude/claude_desktop_config.json`
on macOS, `%APPDATA%\Claude\claude_desktop_config.json` on Windows and
`~/.config/Claude/claude_desktop_config.json` on Linux. It uses the same
`mcpServers` shape as above. Restart Claude Desktop after changing the file.

### Cursor

Cursor reads `.cursor/mcp.json` in the project, or `~/.cursor/mcp.json` for
every project. It uses the same `mcpServers` shape. Turn the server on under
Settings → MCP.

### VS Code

VS Code reads `.vscode/mcp.json`. It uses the `servers` key and needs
`"type": "stdio"`:

```json
{
  "servers": {
    "muster": {
      "type": "stdio",
      "command": "/path/to/muster/bin/muster-mcp",
      "args": ["--project", "/path/to/project"]
    }
  }
}
```

### Any other client

Run `muster-mcp [--project DIR] [--allow-actions]` (or `muster mcp serve …`)
as a stdio server.

## Server flags

| Flag / env | Meaning |
|---|---|
| `--project DIR` / `MUSTER_PROJECT` | Project to serve. If neither is set, the server uses the current directory, walking up to the nearest `muster.json`. |
| `--allow-actions` / `MUSTER_MCP_ALLOW_ACTIONS=1` | Enable the action tools. |
| `--read-only` | Force read-only, even when `MUSTER_MCP_ALLOW_ACTIONS` is set. |
| `--list-tools` | Print the tool definitions as JSON and exit. |
| `MUSTER_TOKEN` | When set, every call uses this token instead of the server's own tokens. muster still enforces its scope. |

Logs go to stderr, prefixed `[muster-mcp]`. Stdout carries only JSON-RPC.

## Protocol

The server supports two eras of the protocol.

| Era | How the client starts | Versions |
|---|---|---|
| Stateless (current) | `server/discover`. Every request carries `_meta["io.modelcontextprotocol/protocolVersion"]`. | **2026-07-28** |
| Handshake | `initialize` (version negotiation) → `notifications/initialized` | 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05 |

The current spec revision is 2026-07-28. It removed the `initialize`
handshake, and clients are adopting it gradually: Anthropic says support is
"rolling out across Claude products". Many clients in use today still open with
`initialize`. That includes Claude Desktop, Claude Code, Cursor and VS Code
releases from before that revision. We have not checked which revision each
client sends today. The server serves both eras, so any of them works:

- **`initialize`**: the server answers with the version the client asked for
  when it supports it, and with `2025-11-25` otherwise. Requests after that
  need no `_meta`.
- **2026-07-28 requests**: results carry `resultType: "complete"` and
  `_meta["io.modelcontextprotocol/serverInfo"]`. An unsupported version gets
  error `-32022` with `data: {supported, requested}`. A request with no version
  (and no earlier `initialize`) gets `-32602`.
- **Methods**: `server/discover`, `initialize`, `ping`, `tools/list`,
  `tools/call`, `resources/list`, `resources/templates/list`,
  `resources/read`, `prompts/list`, `prompts/get`, `completion/complete`,
  `logging/setLevel`.
- **Progress**: when a request carries `_meta.progressToken`, the server sends
  `notifications/progress` while the call runs. For deploy, rollback and
  restart there is one notification per `start` / `done` / `health` event,
  with increasing `progress` and a message.
- **Cancellation**: `notifications/cancelled` with `requestId`. The server
  sends SIGTERM to muster's process group. muster stops the hook tree and
  releases deploy and service locks, just as it does on Ctrl+C. The cancelled
  request gets no response. Anything still running after 15 seconds is
  killed.
- **Logging**: in the handshake era, `logging/setLevel` turns on
  `notifications/message`. Before that call, the server sends none. In the
  2026-07-28 era the client sets the level per request with
  `_meta["io.modelcontextprotocol/logLevel"]`.
- **Errors**: `-32700` parse error, `-32600` invalid request, `-32601` unknown
  method, `-32602` unknown tool or prompt and bad prompt arguments, `-32603`
  internal error. A missing resource is `-32002` in the handshake era and
  `-32602` with `data.uri` in 2026-07-28.
- **Tool argument errors**: per spec, invalid tool arguments come back as a
  tool result with `isError: true` and the reason, so the model can correct
  itself.
- **Concurrency**: calls run as background workers, so a slow deploy doesn't
  block `ping`, `status` or a cancel. When stdin closes, the server waits for
  calls in flight to answer, then exits.
- **Batches**: JSON-RPC batches (arrays) are accepted. Each element is
  answered on its own line.

## Tools

Every tool has a closed `inputSchema` (`additionalProperties: false`), an
`outputSchema`, and annotations. Results carry `structuredContent` plus the
same JSON as text. Service and server names must match
`^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$` and must exist in `muster.json` or the
fleet config.

### Read tools

All read tools have `readOnlyHint: true`, `destructiveHint: false` and
`idempotentHint: true`. Open world means the tool reaches services, clusters or
remote servers.

| Tool | Arguments | What it does | Open world |
|---|---|---|---|
| `project_info` | (none) | Project name and root, services (health, stack, remote, hooks present), deploy order, whether a fleet is configured, whether actions are enabled. Returns `found: false` without a project. | no |
| `status` | `services?` | Runs the health checks: `status --json`, optionally limited to the given services. | yes |
| `logs` | `service`, `tail` (1–1000, default 100) | Last N log lines from the service's stack: `logs <svc> --tail N --json`. | yes |
| `history` | `service?`, `all?` | Deploy, rollback and restart events: `history --json`. | no |
| `explain` | `service?` | Likely cause, what to try and a suggested fix from the offline rules engine. The fix is never run. | no |
| `doctor` | (none) | Project diagnostics: `doctor --json`. | yes |
| `hooks_status` | (none) | Approval state of hooks, `muster.json` and `.env`, plus `pending` and `dangerous`. | no |
| `setup_preview` | `path?`, `stack?`, `namespace?` | What `setup --scan` would configure. Writes nothing. | yes |
| `config_get` | (none) | `muster.json` without credentials or env values, redacted. | no |
| `fleet_list` | (none) | Fleet servers and groups. | no |
| `fleet_status` | `target?` | Health per fleet server or group. | yes |
| `fleet_test` | `target?` | SSH and cloud connectivity plus a muster check per server. | yes |
| `fleet_logs` | `server`, `service`, `tail` | Log lines from a service on a fleet server. | yes |
| `fleet_history` | `server`, `service?`, `all?` | History recorded on a muster-mode server. | yes |

### Action tools

These tools are always listed. Without `--allow-actions` they return
`{"error": "actions_disabled"}` with instructions for turning them on.

| Tool | Arguments | Annotations | Notes |
|---|---|---|---|
| `deploy` | `services` **or** `all: true`; `dry_run` (default **true**); `stop_on_failure` (default true) | destructive, not idempotent, open world | Never runs without explicit services or `all: true`. `dry_run: false` deploys for real. If hooks are unapproved, it returns `error.reason: "hooks_not_approved"` with a `next_step`. |
| `rollback` | `service` | destructive, not idempotent, open world | `rollback <svc> --json` |
| `restart` | `service` | destructive, not idempotent, open world | `restart <svc> --json` |
| `hooks_approve` | `services` **or** `all: true` | not destructive, idempotent, closed world | `hooks approve --yes … --json`. muster refuses hooks that contain dangerous patterns. Call it only after a human has reviewed the diff. |
| `fleet_deploy` | `target`; `dry_run` (default **true**) | destructive, not idempotent, open world | `fleet deploy <target> [--dry-run]`. Output is text lines. |
| `fleet_rollback` | `target`, `services?` | destructive, not idempotent, open world | `fleet rollback <target> [--service …]` |
| `fleet_restart` | `server`, `services?` | destructive, not idempotent, open world | `fleet restart <server> … --json --yes`. Restart hooks must be approved on the server. |

Deploy, rollback and restart return `{events, log_tail, summary, error,
exit_code}`. `events` holds the NDJSON events without `log` lines, and
`log_tail` holds the last 60 log lines. A non-zero exit sets `isError: true`
and keeps the structured result.

## Resources

| URI | Type | Content |
|---|---|---|
| `muster://project` | application/json | Same as `project_info` |
| `muster://config` | application/json | Redacted `muster.json` |
| `muster://history` | application/json | Last 20 history events |
| `muster://fleet` | application/json | `fleet list --json` |
| `muster://services/{name}` | application/json | `{service, status, checked_at, config}` |
| `muster://logs/{service}` | text/plain | Last 100 log lines |

`resources/list` returns the four fixed resources plus `services/<svc>` and
`logs/<svc>` for every service. `resources/templates/list` returns the two
templates. `completion/complete` completes service names for prompt arguments
and template variables.

## Prompts

| Prompt | Arguments | Gives the model |
|---|---|---|
| `diagnose_failure` | `service?` | Steps (explain, logs, history, status, hooks_status) and the current `explain` output. The prompt says to ask the user before any action. |
| `deploy_checklist` | `services?` (comma-separated) | Checklist: hook approvals, health, doctor, dry-run deploy, then ask before deploying for real. Includes the current hook approval state. |
| `rollback_plan` | `service` (required) | The service's last 10 history events, whether it has a rollback hook, and the steps to decide on a rollback and verify it. |

## Security model

- **Scoped tokens.** The server runs its tools with tokens it creates itself.
  They work like the one `muster ask` uses:
  - `muster-mcp-read` (read scope) is stored in `~/.muster/mcp/read-token`
    (0600). The server creates it on the first tool call.
  - `muster-mcp-deploy` (deploy scope) is stored in
    `~/.muster/mcp/deploy-token`. The server creates it only when it runs with
    `--allow-actions` and an action tool is called.
  - muster checks the scope on every `--json` command, so a read-only server
    cannot deploy even if the gate below were bypassed. Revoke a token with
    `muster auth revoke muster-mcp-read` (or `-deploy`). The server re-creates
    it on next use.
- **Read-only by default.** Action tools need `--allow-actions` or
  `MUSTER_MCP_ALLOW_ACTIONS=1`, which the user sets in the client config. A
  model cannot turn them on.
- **Hook approvals still apply.** The server never passes `--yes` to `deploy`
  or `rollback`, and it drops any `MUSTER_APPROVE_HOOKS` it inherits.
  Unapproved or changed hooks block the action until a human approves them,
  either in a terminal (`muster hooks approve`) or through `hooks_approve`,
  which needs `--allow-actions`. muster refuses to approve hooks that contain
  dangerous patterns.
- **Dry run first.** `deploy` and `fleet_deploy` default to `dry_run: true`.
  `deploy` and `hooks_approve` refuse to act without explicit services or
  `all: true`. The destructive annotations make clients ask the user before
  calling these tools.
- **Validation.** The server checks every argument against the tool's
  `inputSchema` (types, ranges, patterns, unknown keys), then checks that the
  named services or servers exist. Values are passed to muster as argv. The
  server never builds a shell string from them. `setup_preview` paths with
  shell metacharacters or control characters are refused.
- **Redaction.** Every tool result, resource and prompt goes through
  `lib/core/redact.sh` before it reaches the client. That masks secret-looking
  keys, tokens, URL passwords, PEM blocks and literal values from the
  project's `.env`. `config_get` also removes `credentials` and `env` values.
  If redaction can't run, the output is withheld.
- **Attribution.** Deploys started over MCP are recorded with
  `"source": "mcp"` in history.
- **Removed tools.** muster 0.7.3 and earlier had tools that wrote hooks and stored
  credentials, and it ran hooks without approval. Those tools are gone. To
  create a project, use `setup_preview` and then `muster setup` in a terminal.

## Troubleshooting

- Run `muster mcp doctor` (or `--json`). It starts the server, runs both
  handshakes, lists tools, resources and prompts, and checks the project.
- If `project_info` returns `found: false`, the client started the server
  outside the project. Add `--project /abs/path` to the args.
- To see what the server is doing, check the client's MCP log for the
  `[muster-mcp]` lines on stderr.
- `actions_disabled` means the server runs read-only. Re-run
  `muster mcp install <client> --allow-actions --write` and restart the
  client.
- `hooks_not_approved` means the hooks changed since they were approved on
  this machine. Review them with `muster hooks approve` in a terminal.
