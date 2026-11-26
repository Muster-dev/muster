# Muster Assistant (`muster ask`) and `muster cloud connect`

The Muster Assistant is a paid Fleet Cloud feature that helps with troubleshooting. Ask it why a deploy failed and it reads your status, logs, history and hooks on this machine. It explains what went wrong, and it can propose fixes (rollback, redeploy, restart, a hook edit) that run only after you approve each one.

The protocol is in [assistant-and-pairing.md](assistant-and-pairing.md). The server runs the model and keeps the conversation. Tools run locally, inside muster, and only their redacted results leave the machine.

## Quick start

```bash
muster cloud login                 # once per machine
cd my-project
muster ask "why did api fail?"     # or just `muster ask` after a failed deploy
```

The first time you use it in a project, muster asks:

```
Send redacted logs and config from shop to the Muster Assistant? [y/N]
```

Your answer is stored in `.muster/assistant.json`. That file is per person and per machine, and muster adds it to `.gitignore`. In CI, pass `--yes` to give consent.

## A session

```
$ muster ask "why did api fail?"

  Muster Assistant  free plan  · 4 sessions left
  Including the last failed deploy (api) as context

  Let me check the current status first.
  Checking service status…
  Reading api logs…

  The api deploy failed: the database password is wrong.

  ▸ Roll back api to the previous version
  ? Run this? [y/N] y
  Running…
  * Done

  Summary
  • Rolled back api
  • Fix DB_PASSWORD in .env, then redeploy

  Ask a follow-up, or press Enter to finish
  ›
```

- **Read tools** run right away. A dim line shows each one ("Reading api logs…").
- **Action tools** show a summary and ask `Run this? [y/N]`. Without a terminal they are declined, unless you pass `--allow-actions`. A declined action is reported back to the model as `"The user declined this action."`, so it can suggest something else.
- **Hook edits** (`propose_hook_edit`) show a colored unified diff. The edit is written only if you approve it, and that same approval re-approves the hook on this machine (`muster hooks approve <svc>`). If the service has other unreviewed hook changes, muster doesn't approve them for you: it writes the edit and asks you to run `muster hooks approve` yourself.

### Tools

| Tool | Kind | Runs |
|------|------|------|
| `muster_status` | read | `muster status --json` |
| `muster_logs {service, lines≤500}` | read | `muster logs <svc> --tail N`. Before the engine JSON API lands, it falls back to the newest deploy log for the service |
| `muster_history {service?, limit?}` | read | `muster history --json` |
| `muster_doctor` | read | `muster doctor --json` |
| `muster_diagnose {service}` | read | last failed event, deploy log tail, and k8s diagnosis (k8s services) |
| `muster_hooks_status` | read | `muster hooks status --json`. Falls back to `muster hooks verify` |
| `read_config` | read | `muster.json`, with credentials sections removed and env values masked |
| `read_hook {service, hook}` | read | the hook file |
| `muster_deploy {services?, dry_run?}` | action (read when `dry_run`) | `muster deploy [svcs] [--dry-run]` |
| `muster_rollback {service}` | action | `muster rollback <svc>` (`--json` when supported) |
| `muster_restart {service}` | action | `muster restart <svc>`. Returns an error on muster versions without `restart` |
| `propose_hook_edit {service, hook, new_content, reason}` | action | diff, then write and approve |

The client decides read vs action from its own table, not from the server's `kind` field. It rejects unknown tools, services that aren't in `muster.json`, unknown hook names, and string inputs containing shell metacharacters. Tools that need the local JSON API use a local API token, `muster-assistant` (deploy scope). It is created the first time it's needed and stored at `~/.muster/assistant/local-token` (mode 0600).

## Privacy and redaction

Before anything is sent, muster runs `lib/core/redact.sh` on every tool result and on the session context. It replaces the following with `‹redacted›`:

- values of secret-looking keys (`password`, `secret`, `token`, `api_key`, `private_key`, `credential`, `auth`…) in `KEY=VALUE`, JSON, YAML and HTTP headers
- bearer and basic credentials
- `mst_*` tokens, AWS access keys, GitHub tokens, Slack tokens and webhooks, Discord webhooks, JWTs and Stripe-style keys
- PEM blocks
- passwords in URLs (`postgres://user:‹redacted›@host`)
- any value from the project's `.env` that is 6 or more characters long and not a plain number or a common word

Redaction fails closed: if `jq` is missing, nothing is sent. Your Fleet Cloud token goes only in the `Authorization` header. It is never placed on a command line or in a request body.

Turn the assistant off on a machine:

```bash
muster settings --global assistant off   # on to re-enable
```

## Flags

| Flag | Effect |
|------|--------|
| `--yes`, `-y` | Consent for this project without a prompt |
| `--allow-actions` | Without a terminal, approve action tools automatically |
| `--read-only` | Decline every action tool (used by the deploy failure menu) |
| `--json` | NDJSON on stdout, for muster-tui (below) |

## Errors

| Situation | What you see |
|-----------|--------------|
| Not logged in, or token revoked (401/403) | `Sign in with: muster cloud login` |
| Out of sessions (402) | `Upgrade to keep going: <upgrade_url>` |
| Network problem | `Can't reach the Muster Assistant at …` |
| Stream cut off | `The connection dropped before the answer finished.` |
| Ctrl+C | `Cancelled.`, exit 130 |

Override the server with `MUSTER_ASSIST_URL` (or the global setting `cloud.assist_url`). The default is `https://cloud.getmuster.dev`.

## Deploy integration

- When an interactive deploy fails, the recovery menu gains an **Explain with AI** option, shown only if you're logged in to Fleet Cloud and the assistant is not turned off. It runs `muster ask --read-only` with the failed service, exit code and log as context, then returns to the same menu so you can Retry or Roll back.
- When a deploy fails without a terminal, muster prints `Get help: muster ask`.
- Run `muster ask` with no question after a failed deploy and it asks "Why did the <svc> deploy fail, and how do I fix it?", using the last failed deploy as context.

## `--json` mode (muster-tui)

Every stdout line is a JSON object.

- **Server events are passed through unchanged:** `text`, `thinking_summary`, `tool_request`, `turn_end`, `error`.
- **Local events:**
  - `{"type":"session","session_id","plan","remaining_sessions"}`
  - `{"type":"tool_running","tool_use_id","name","kind","summary"}`
  - `{"type":"approval_needed","tool_use_id","name","summary","input","diff"?}` (`diff` is included for hook edits)
  - `{"type":"tool_result","tool_use_id","name","is_error","content"}`: the redacted content as sent to the server
  - `{"type":"awaiting_input"}`: the answer is finished
  - `{"type":"done","session_id","ok"}`
  - `{"type":"cancelled"}`
  - `{"type":"error","error":"payment_required"|"unauthorized"|"network_error"|…,"message","upgrade_url"?}`
- **Stdin**, one JSON object per line:
  - `{"approve":"<tool_use_id>"}` or `{"decline":"<tool_use_id>"}` answers an `approval_needed`. Answers may arrive early, and EOF declines.
  - `{"message":"…"}` after `awaiting_input` sends a follow-up. `{"end":true}` or EOF finishes the session.

## `muster cloud connect`

Run this on a server to pair it with your Fleet Cloud org. You don't need to copy any tokens.

```bash
muster cloud connect                          # interactive
muster cloud connect --name prod-1 --project /opt/shop --service --yes
```

1. It installs muster-agent if it's missing, or updates it if it's too old to pair (older than v0.4.0). The installer is `curl -fsSL https://getmuster.dev/fleet-cloud/install.sh | bash -s -- --agent --yes`. On a TTY it asks first; without one, pass `--yes`.
2. It picks the project directory: `--project`, or the current directory if it has a `muster.json`. Otherwise it asks on a TTY, or pairs with no project.
3. It runs `muster-agent pair [--name] [--project] [--relay]`. The agent prints a short code and a QR code. Approve at `cloud.getmuster.dev/pair`, for example by scanning the QR with your phone.
4. It offers to install the agent as a background service: `sudo muster-agent install-service` (systemd or launchd), or `--user-service` for a per-user service without sudo. Use `--no-service` to skip it.
5. If a service was installed, it checks the connection with `muster-agent status --connected` for up to 15 seconds.

`muster cloud login --qr` also prints a QR code of the login URL when `qrencode` is installed. `qrencode` is optional: without it, muster skips the QR.
