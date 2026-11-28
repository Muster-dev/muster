# Muster Assistant — protocol contract (v1)

Paid AI assistant for troubleshooting and actions. Server: `https://cloud.getmuster.dev/api/assist/*` (the Fleet Cloud dashboard, Next.js + TypeScript, Clerk for web users). Model: `claude-opus-5-5` via the official `@anthropic-ai/sdk`, adaptive thinking, streaming. The server owns the agent loop state and the conversation history; tools execute on the user's machine (muster CLI / muster-tui) and results are sent back. The Anthropic API key exists only on the server.

## Auth
- CLI / TUI: `Authorization: Bearer mst_cli_…` (the token from `muster cloud login`). The server validates it by calling the relay admin API `POST /api/v1/tokens/introspect {"token": "mst_cli_…"}` → `200 {"active": true, "token_id", "org_id", "name"}` or `200 {"active": false}` (relay ≥ 0.3.3, admin-auth, never logs the token).
- Web: Clerk session; org_id = `org_<clerkUserId>`.

## Billing / entitlement
- Per org: plan `free` (5 lifetime trial sessions) or `pro` (Stripe subscription; monthly session allowance, configurable, default 100; overage metered or blocked per config).
- A "session" = one conversation (`POST /api/assist/sessions`). Token usage is recorded per turn (input, output, cache read/write) for the usage meter.
- When not entitled: `402 {"error":"payment_required","upgrade_url":"https://cloud.getmuster.dev/billing"}`.

## Endpoints
`POST /api/assist/sessions` body `{"project": "acme-store", "context": {...}}` → `201 {"session_id","plan","remaining_sessions"}`.
  `context` (all optional, already redacted by the client): `{muster_version, os, stack, services:[...], failure: {service, exit_code, log_tail:[...], diagnosis:{...}}}`.
  Remote sessions (`muster ask --server <name>`) send instead `{muster_version, os, surface: "cli", services:[...], remote: {server, transport: "cloud"|"ssh", mode: "muster", muster_version, unavailable_tools:[...]}, note}` — `project` is the server's project name (or the server name). The tools are the same; they run on that server, and `unavailable_tools` (`read_config`, `read_hook`, `muster_doctor`, `propose_hook_edit`) return an error result.

`POST /api/assist/sessions/{id}/turns` (streams `text/event-stream`) body is ONE of:
  - `{"message": "why did api fail?"}` — a user message
  - `{"tool_results": [{"tool_use_id","content": "<string, redacted>","is_error": false}]}` — results for ALL tool calls of the previous turn
  - `{"approval": {"tool_use_id", "approved": true|false}}` is not separate: a declined action is sent as a tool_result with `is_error: true` and content `"The user declined this action."`

  SSE events (each `data:` is JSON, one event per line pair):
  - `{"type":"text","delta":"…"}` — streamed assistant text
  - `{"type":"thinking_summary","delta":"…"}` — optional short progress notes
  - `{"type":"tool_request","tool_use_id","name","input":{…},"kind":"read"|"action","summary":"Roll back api to the previous version"}` — the client must execute (read: immediately; action: only after the user approves) and reply with tool_results
  - `{"type":"turn_end","stop_reason":"end_turn"|"tool_use"|"max_tokens"|"refusal","usage":{"input_tokens","output_tokens","cache_read_input_tokens"}}`
  - `{"type":"error","error":"…"}`

`GET /api/assist/sessions/{id}` → transcript (for the dashboard panel). `GET /api/assist/usage` → plan, allowance, used, period end.

## Tools (defined server-side, executed client-side)
read (auto-run, no approval):
- `muster_status` {} → output of `muster status --json`
- `muster_logs` {service, lines (≤500)} → `muster logs <svc> --tail N` (redacted)
- `muster_history` {service?, limit?} → `muster history --json`
- `muster_doctor` {} → `muster doctor --json`
- `muster_diagnose` {service} → k8s/failure diagnosis JSON for the last failed deploy
- `muster_hooks_status` {} → `muster hooks status --json`
- `read_config` {} → muster.json (credentials sections and env values stripped)
- `read_hook` {service, hook: deploy|health|rollback|logs|cleanup} → hook file contents (redacted)
action (always require explicit user approval in the client; the server never assumes approval):
- `muster_deploy` {services?: [...], dry_run?: bool}  (dry_run=true is classified read)
- `muster_rollback` {service}
- `muster_restart` {service}
- `propose_hook_edit` {service, hook, new_content, reason} → client shows a unified diff; applies only on approval; then the hook needs `muster hooks approve` as usual (client does this only with the same approval)

Clients must reject unknown tools, and must re-validate every input (service names must exist in muster.json; no shell metacharacters).

## Redaction (client side, before anything leaves the machine; server re-applies)
Mask: values of keys matching /(pass(word)?|secret|token|api[_-]?key|private[_-]?key|credential|auth)/i in env/JSON/YAML/`KEY=VALUE`; bearer tokens; `mst_*` tokens; AWS keys (AKIA…), GitHub tokens (ghp_/gho_/github_pat_), Slack/Discord webhooks, JWTs, PEM blocks, URLs with user:pass@; anything from `.env`. Replace with `‹redacted›`.

## Opt-in
Per project: first use asks "Send redacted logs and config from <project> to the Muster Assistant?" and stores consent in `.muster/assistant.json` (gitignored) — or `muster ask --yes` in CI. Global kill switch: `muster settings --global assistant off`.

---

# Machine pairing with codes + QR (v1)

Goal: connecting a server takes one command and a tap. No copying long tokens.

## Flow
1. On the machine: `muster cloud connect` (bash CLI; installs/updates muster-agent if needed, then runs `muster-agent pair`), or directly `muster-agent pair [--name prod-1] [--project DIR] [--mode muster|push]`.
2. Agent → relay `POST /api/v1/pair/start` (public, rate-limited) body `{"name","hostname","os","arch","project_dir_set":bool,"agent_version"}` → `200 {"pair_code":"KX7-42QP","device_code":"<opaque>","verification_uri":"https://cloud.getmuster.dev/pair","verification_uri_complete":"https://cloud.getmuster.dev/pair?code=KX7-42QP","expires_in":600,"interval":3}`. Same unambiguous alphabet / format as device login codes; separate namespace.
3. Terminal shows the code large, the URL, and a QR code of `verification_uri_complete` (unicode half-block QR, quiet zone, works on dark and light terminals; `--no-qr` to hide; auto-hidden when not a TTY).
4. User opens the URL (QR from a phone works — the page is responsive) → Clerk sign-in → page shows: machine name, hostname, OS/arch, requesting IP (relay-recorded), agent version, requested time, and a warning ("Only approve if you just ran muster cloud connect on this machine"). User can rename the machine and pick Approve / Deny.
5. Dashboard (server-side, admin token) → `GET /api/v1/pair/{code}` (admin) for details; `POST /api/v1/pair/{code}/approve` body `{"org_id","user_id","name"?}` or `/deny`.
6. Agent polls `POST /api/v1/pair/token {"device_code"}` → `authorization_pending` / `slow_down` / `expired_token` / `access_denied`, or `200 {"join_token":"mst_agent_…","org_id","name","relay_url"}` (a fresh one-time join token bound to that org+name, short expiry). The agent then runs the existing enrollment (join token → node credential), saves config 0600, and prints next steps. Exactly-once redemption.
7. `muster cloud connect` then offers to install the agent as a system service (systemd on Linux, launchd on macOS) via `muster-agent install-service` (prints the unit, needs sudo only for the system-wide variant; supports `--user`).

## Also
- Dashboard "Connect a machine" shows, alongside the existing token method: "Easiest: run `muster cloud connect` on the server and scan the code" — plus a `/pair` page with a code entry box.
- `muster cloud login --qr` (laptop login) prints a QR of its verification URL too (bash: use `qrencode -t ansiutf8` if installed, otherwise skip silently — never a hard dependency).
- Relay: new admin endpoint `POST /api/v1/tokens/introspect` (for the assistant server) — see Auth above.
