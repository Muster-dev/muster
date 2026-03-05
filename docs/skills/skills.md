# Creating Muster Skills

Skills are addons that extend muster with new capabilities — notifications, monitoring, automation, anything. A skill is just a folder with a `skill.json` manifest and a `run.sh` script.

Browse official skills: [muster-skills marketplace](https://github.com/Muster-dev/muster-skills)

## Quick Start

```bash
muster skill create my-skill
# Edit ~/.muster/skills/my-skill/skill.json and run.sh
muster skill run my-skill
```

## Structure

```
my-skill/
├── skill.json    ← manifest (required)
├── run.sh        ← entry point (required, executable)
└── lib/          ← optional helper scripts
```

## skill.json

```json
{
  "name": "my-skill",
  "version": "1.0.0",
  "description": "What this skill does in one line",
  "author": "yourname",
  "hooks": ["post-deploy", "post-rollback"],
  "requires": ["curl"],
  "config": [
    {
      "key": "MY_SKILL_API_KEY",
      "label": "API Key",
      "hint": "Where to find this value",
      "secret": true
    },
    {
      "key": "MY_SKILL_URL",
      "label": "Endpoint URL",
      "hint": "e.g. https://example.com/webhook"
    }
  ]
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Short name, used in `muster skill run <name>` |
| `version` | yes | Semver version string |
| `description` | yes | One-line description shown in `muster skill list` and marketplace |
| `author` | no | Who made it |
| `hooks` | no | When to auto-run (see Hooks and Fleet Hooks sections below) |
| `requires` | no | External commands that must be available (muster warns if missing) |
| `config` | no | Array of configuration values the user needs to provide (see below) |

### Config

The `config` array defines values the user must provide for the skill to work (API keys, webhook URLs, etc.). Each entry:

| Field | Required | Description |
|-------|----------|-------------|
| `key` | yes | Environment variable name (e.g. `MY_SKILL_API_KEY`) |
| `label` | no | Human-readable label shown in the configure TUI |
| `hint` | no | Help text (where to find the value, example format) |
| `secret` | no | If `true`, input is hidden and stored value is masked |

Users configure skills with `muster skill configure <name>`, which prompts for each value and saves them to `config.env` in the skill directory. Values are automatically loaded as environment variables before your `run.sh` executes.

## run.sh

Your skill's entry point. It receives context via environment variables:

```bash
#!/usr/bin/env bash
set -eo pipefail

# Environment variables available to your skill:
#
#   MUSTER_SERVICE        — service key (e.g. "api")
#   MUSTER_SERVICE_NAME   — display name (e.g. "API Server")
#   MUSTER_HOOK           — which hook triggered this (e.g. "post-deploy")
#   MUSTER_DEPLOY_STATUS  — outcome: "success", "failed", or "skipped"
#   MUSTER_PROJECT_DIR    — path to the project root
#   MUSTER_CONFIG_FILE    — path to deploy.json
#
# Plus any values from your config[] (loaded from config.env)

# Example: send different notifications based on status
case "${MUSTER_HOOK}:${MUSTER_DEPLOY_STATUS}" in
  post-deploy:success)
    echo "Deploy succeeded for ${MUSTER_SERVICE_NAME}"
    ;;
  post-deploy:failed)
    echo "Deploy FAILED for ${MUSTER_SERVICE_NAME}"
    ;;
  post-deploy:skipped)
    echo "Deploy skipped for ${MUSTER_SERVICE_NAME}"
    ;;
esac
```

Make sure `run.sh` is executable: `chmod +x run.sh`

Exit codes:
- `0` — success
- Non-zero — failure (muster warns and continues, deploy is not blocked)

## Hooks

Skills that declare hooks in `skill.json` can auto-run during deploy and rollback. The user must **enable** the skill first:

```bash
muster skill configure my-skill   # fill in config values
muster skill enable my-skill      # turn on auto-run
```

| Hook | When it fires |
|------|---------------|
| `pre-deploy` | Before each service deploys |
| `post-deploy` | After each service deploy (success, failed, or skipped) |
| `pre-rollback` | Before a service rollback |
| `post-rollback` | After a service rollback (success or failed) |

Hook execution is **non-fatal** — if a skill fails, muster warns and continues. Deploys are never blocked by skill errors.

### Deploy Status

`post-deploy` and `post-rollback` hooks receive `MUSTER_DEPLOY_STATUS`:

| Status | Meaning |
|--------|---------|
| `success` | Deploy/rollback completed successfully |
| `failed` | Deploy/rollback failed (user chose rollback, skip, or abort) |
| `skipped` | User chose to skip this service |

Use this to send different notifications for success vs failure.

### Enabled vs Manual

- **Enabled** — skill auto-runs on its declared hooks during deploy/rollback
- **Manual** — skill only runs when the user clicks "Run" in the dashboard or uses `muster skill run`

Skills start as manual after install. Users enable them after configuring.

## Fleet Hooks

Skills can also fire during fleet operations (`muster fleet deploy`, `muster fleet rollback`). Fleet hooks run on your local machine (the orchestrator) — secrets never leave your machine.

### Fleet Hook Names

| Hook | When it fires |
|------|---------------|
| `fleet-deploy-start` | Before fleet deploy begins (once per fleet deploy) |
| `fleet-deploy-end` | After fleet deploy finishes (once) |
| `fleet-machine-deploy-start` | Before deploying to each machine |
| `fleet-machine-deploy-end` | After deploying to each machine |
| `fleet-rollback-start` | Before fleet rollback begins |
| `fleet-rollback-end` | After fleet rollback finishes |

### Fleet Environment Variables

Fleet hooks get all the standard env vars plus:

| Variable | Description |
|----------|-------------|
| `MUSTER_FLEET_NAME` | Fleet name (e.g. "production") |
| `MUSTER_FLEET_MACHINE` | Machine identifier (per-machine hooks) |
| `MUSTER_FLEET_HOST` | `user@host` of the machine |
| `MUSTER_FLEET_STRATEGY` | `sequential`, `parallel`, or `rolling` |
| `MUSTER_FLEET_MODE` | `muster` or `push` |
| `MUSTER_DEPLOY_STATUS` | `ok` or `failed` (on `*-end` hooks) |

### Per-Fleet Skill Config

Each fleet can enable specific skills and override their config:

```bash
muster fleet skill enable production discord
muster fleet skill configure production discord
```

This creates `~/.muster/fleets/production/skills.json`:

```json
{
  "enabled": ["discord"],
  "config": {
    "discord": {
      "MUSTER_DISCORD_CHANNEL_ID": "123456789"
    }
  }
}
```

Fleet config values override the skill's base `config.env`. This lets you point the same Discord skill at different channels per fleet (production → `#production-deploys`, staging → `#staging-deploys`).

If no `skills.json` exists for a fleet, the standard global/project skill settings are used.

### Example: Fleet-Aware Discord Skill

```json
{
  "name": "discord",
  "hooks": ["post-deploy", "post-rollback", "fleet-deploy-end", "fleet-machine-deploy-end"],
  "config": [...]
}
```

```bash
#!/usr/bin/env bash
set -eo pipefail

# Detect if this is a fleet event
if [[ -n "${MUSTER_FLEET_NAME:-}" ]]; then
  case "$MUSTER_HOOK" in
    fleet-deploy-end)
      TITLE="Fleet ${MUSTER_FLEET_NAME}: deploy ${MUSTER_DEPLOY_STATUS}"
      ;;
    fleet-machine-deploy-end)
      TITLE="${MUSTER_FLEET_MACHINE}: ${MUSTER_DEPLOY_STATUS}"
      ;;
  esac
else
  # Standard local deploy
  TITLE="${MUSTER_SERVICE}: deploy ${MUSTER_DEPLOY_STATUS}"
fi

# ... send to Discord
```

## Skill Lifecycle

```
Install → Configure → Enable → Auto-runs on deploy/rollback
                              → Or run manually anytime
```

Commands:

```bash
muster skill marketplace          # browse and install from official registry
muster skill add <url-or-path>    # install from git URL or local path
muster skill configure <name>     # set API keys, webhooks, etc.
muster skill enable <name>        # turn on auto-run for hooks
muster skill disable <name>       # turn off auto-run (manual only)
muster skill run <name>           # run manually
muster skill list                 # show installed skills with status
muster skill remove <name>        # uninstall
muster skill create <name>        # scaffold a new skill
```

## Publishing Your Skill

### Option A: Own repo

Name your repo `muster-skill-<name>`. The `muster-skill-` prefix is auto-stripped during install.

```bash
# Users install with:
muster skill add https://github.com/yourname/muster-skill-ssl
```

### Option B: Submit to the official marketplace

Add your skill to [muster-skills](https://github.com/Muster-dev/muster-skills):

1. Fork the repo
2. Add your skill folder (`my-skill/skill.json` + `my-skill/run.sh`)
3. Add an entry to `registry.json`
4. Open a PR

Once merged, your skill appears in `muster skill marketplace` for everyone.

## Built-in Skill Templates

muster ships with ready-to-use skill templates for common integrations. Install them with `muster skill create`:

| Skill | Description |
|-------|-------------|
| `discord` | Discord bot notifications (embeds with color-coded status) |
| `slack` | Slack incoming webhook notifications (attachments with mrkdwn) |
| `webhook` | Generic JSON webhook (works with any HTTP endpoint) |

All three support both local deploy hooks and fleet hooks out of the box.

## Example: Discord Notifications

A complete skill that sends context-aware deploy and fleet notifications:

**skill.json:**

```json
{
  "name": "discord",
  "version": "1.1.0",
  "description": "Send deploy and fleet notifications to Discord",
  "hooks": [
    "post-deploy", "post-rollback",
    "fleet-deploy-start", "fleet-deploy-end",
    "fleet-machine-deploy-start", "fleet-machine-deploy-end",
    "fleet-rollback-start", "fleet-rollback-end"
  ],
  "requires": ["curl"],
  "config": [
    {
      "key": "MUSTER_DISCORD_BOT_TOKEN",
      "label": "Discord Bot Token",
      "hint": "discord.com/developers/applications > Bot > Token",
      "secret": true
    },
    {
      "key": "MUSTER_DISCORD_CHANNEL_ID",
      "label": "Channel ID",
      "hint": "Right-click channel > Copy Channel ID"
    }
  ]
}
```

**run.sh:**

```bash
#!/usr/bin/env bash
set -eo pipefail

[[ -z "${MUSTER_DISCORD_BOT_TOKEN:-}" ]] && exit 0
[[ -z "${MUSTER_DISCORD_CHANNEL_ID:-}" ]] && exit 0

HOOK="${MUSTER_HOOK:-unknown}"
STATUS="${MUSTER_DEPLOY_STATUS:-unknown}"
SERVICE="${MUSTER_SERVICE_NAME:-${MUSTER_SERVICE:-}}"
FLEET="${MUSTER_FLEET_NAME:-}"
MACHINE="${MUSTER_FLEET_MACHINE:-}"
HOST="${MUSTER_FLEET_HOST:-}"
STRATEGY="${MUSTER_FLEET_STRATEGY:-}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

COLOR_GREEN=3066993; COLOR_RED=15158332
COLOR_ORANGE=15105570; COLOR_BLUE=3447003; COLOR_GREY=9807270
COLOR=$COLOR_GREY; TITLE=""; DESC=""

case "$HOOK" in
  fleet-deploy-start)
    COLOR=$COLOR_BLUE; TITLE="Fleet deploy started: ${FLEET}"; DESC="Strategy: ${STRATEGY}" ;;
  fleet-deploy-end)
    [[ "$STATUS" == "ok" ]] && { COLOR=$COLOR_GREEN; TITLE="Fleet deploy complete: ${FLEET}"; } \
                             || { COLOR=$COLOR_RED;   TITLE="Fleet deploy FAILED: ${FLEET}"; }
    DESC="Strategy: ${STRATEGY}" ;;
  fleet-machine-deploy-start)
    COLOR=$COLOR_BLUE; TITLE="Deploying to ${MACHINE}"; DESC="Host: ${HOST}" ;;
  fleet-machine-deploy-end)
    [[ "$STATUS" == "ok" ]] && { COLOR=$COLOR_GREEN; TITLE="Deployed to ${MACHINE}"; } \
                             || { COLOR=$COLOR_RED;   TITLE="Deploy FAILED: ${MACHINE}"; }
    DESC="Host: ${HOST}" ;;
  fleet-rollback-start)
    COLOR=$COLOR_ORANGE; TITLE="Fleet rollback started: ${FLEET}" ;;
  fleet-rollback-end)
    [[ "$STATUS" == "ok" ]] && { COLOR=$COLOR_GREEN; TITLE="Fleet rollback complete: ${FLEET}"; } \
                             || { COLOR=$COLOR_RED;   TITLE="Fleet rollback FAILED: ${FLEET}"; } ;;
  post-deploy)
    case "$STATUS" in
      success) COLOR=$COLOR_GREEN; TITLE="Deployed ${SERVICE}" ;;
      failed)  COLOR=$COLOR_RED;   TITLE="Deploy FAILED: ${SERVICE}" ;;
      skipped) COLOR=$COLOR_GREY;  TITLE="Deploy skipped: ${SERVICE}" ;;
    esac ;;
  post-rollback)
    case "$STATUS" in
      success) COLOR=$COLOR_GREEN;  TITLE="Rolled back ${SERVICE}" ;;
      failed)  COLOR=$COLOR_RED;    TITLE="Rollback FAILED: ${SERVICE}" ;;
      *)       COLOR=$COLOR_ORANGE; TITLE="Rollback ${STATUS}: ${SERVICE}" ;;
    esac ;;
  *) TITLE="${HOOK}: ${SERVICE:-fleet}" ;;
esac

TITLE="${TITLE//\"/\\\"}"; DESC="${DESC//\"/\\\"}"
EMBED="{\"title\":\"${TITLE}\",\"color\":${COLOR},\"timestamp\":\"${TIMESTAMP}\""
[[ -n "$DESC" ]]  && EMBED="${EMBED},\"description\":\"${DESC}\""
[[ -n "$FLEET" ]] && EMBED="${EMBED},\"footer\":{\"text\":\"Fleet: ${FLEET}\"}"
EMBED="${EMBED}}"

curl -sf -X POST \
  "https://discord.com/api/v10/channels/${MUSTER_DISCORD_CHANNEL_ID}/messages" \
  -H "Authorization: Bot ${MUSTER_DISCORD_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"embeds\":[${EMBED}]}" \
  > /dev/null 2>&1 || true

exit 0
```

### Per-fleet Discord channels

Use fleet skill config to send production deploys to `#production-deploys` and staging to `#staging-deploys`:

```bash
muster fleet skill enable production discord
muster fleet skill configure production discord
# Set MUSTER_DISCORD_CHANNEL_ID to the production channel

muster fleet skill enable staging discord
muster fleet skill configure staging discord
# Set MUSTER_DISCORD_CHANNEL_ID to the staging channel
```

## Testing Your Skill

```bash
# Scaffold and edit
muster skill create my-skill

# Test manually
muster skill run my-skill

# Test with deploy context
MUSTER_SERVICE=api MUSTER_SERVICE_NAME="API Server" \
  MUSTER_HOOK=post-deploy MUSTER_DEPLOY_STATUS=success \
  ~/.muster/skills/my-skill/run.sh

# Test failure notification
MUSTER_SERVICE=api MUSTER_SERVICE_NAME="API Server" \
  MUSTER_HOOK=post-deploy MUSTER_DEPLOY_STATUS=failed \
  ~/.muster/skills/my-skill/run.sh

# Check it shows up
muster skill list
```
