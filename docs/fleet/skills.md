# Fleet Skills

> Per-fleet skill configuration: control which skills fire during fleet operations and override their config per-fleet.

Fleet skills build on muster's existing skill system. When no fleet skills are configured, fleet operations use global/project skill settings. Fleet skills let you scope skill behavior to specific fleets -- enable only certain skills for production, configure different webhook URLs per fleet, etc.

## skills.json

Each fleet has an optional `skills.json` at `~/.muster/fleets/<fleet>/skills.json`:

```json
{
  "enabled": ["discord-notify", "slack-notify"],
  "config": {
    "discord-notify": {
      "DISCORD_WEBHOOK_URL": "https://discord.com/api/webhooks/...",
      "DISCORD_USERNAME": "Fleet: production"
    }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | `string[]` | Skills that fire during fleet operations. Only these skills run when the file exists. |
| `config` | `object` | Per-skill config overrides. Keys are skill names, values are key-value config maps. |

When `skills.json` exists, **only** listed skills run during fleet hooks. Skills not in the `enabled` array are skipped, even if they are installed and enabled globally. When `skills.json` does not exist, all globally/project-enabled skills run as normal.

Config overrides in `skills.json` are merged on top of the skill's base config (from `skill.json` defaults and `config.json` user values). Fleet config takes precedence.

## Fleet Hook Names

Fleet operations fire these skill hooks:

| Hook Name | When | Scope |
|-----------|------|-------|
| `fleet-deploy-start` | Before deploying to the first machine | Fleet-level |
| `fleet-deploy-end` | After deploying to all machines (or on abort) | Fleet-level |
| `fleet-machine-deploy-start` | Before deploying to a specific machine | Per-machine |
| `fleet-machine-deploy-end` | After deploying to a specific machine | Per-machine |
| `fleet-rollback-start` | Before rolling back the fleet | Fleet-level |
| `fleet-rollback-end` | After rolling back the fleet | Fleet-level |

Skills detect fleet context by checking for `MUSTER_FLEET_NAME` in their environment. A skill's `run.sh` can inspect `MUSTER_HOOK` to determine which hook fired.

## Environment Variables

These environment variables are exported during fleet skill hook execution:

| Variable | Description | Available In |
|----------|-------------|--------------|
| `MUSTER_FLEET_NAME` | Fleet name (e.g., `production`) | All fleet hooks |
| `MUSTER_FLEET_MACHINE` | Machine name (e.g., `prod-1`) | Per-machine hooks |
| `MUSTER_FLEET_HOST` | `user@host` for the machine | Per-machine hooks |
| `MUSTER_FLEET_STRATEGY` | Deploy strategy: `sequential`, `parallel`, or `rolling` | All deploy hooks |
| `MUSTER_FLEET_MODE` | Machine deploy mode: `muster` or `push` | Per-machine hooks |
| `MUSTER_DEPLOY_STATUS` | `ok` or `failed` | End hooks only |
| `MUSTER_HOOK` | The hook name (e.g., `fleet-deploy-end`) | All hooks |

## Commands

### List enabled skills

```bash
muster fleet skill list [fleet]
```

Shows which skills are enabled for a fleet and whether they have fleet-specific config overrides. If no fleet is specified, uses the first available fleet.

### Enable a skill

```bash
muster fleet skill enable <fleet> <skill>
```

Adds a skill to the fleet's `enabled` array. Creates `skills.json` if it does not exist. The skill must be installed globally (`~/.muster/skills/`) or per-project (`.muster/skills/`).

### Disable a skill

```bash
muster fleet skill disable <fleet> <skill>
```

Removes a skill from the fleet's `enabled` array.

### Configure fleet overrides

```bash
muster fleet skill configure <fleet> <skill>
```

Interactive prompt to set fleet-specific config values for a skill. Reads the skill's config schema from its `skill.json` and prompts for each configurable key. Values override the skill's base config during fleet operations. Secret values are masked in the display.

## Example: Discord Notifications

Install the Discord skill globally, then enable it for a fleet with a fleet-specific webhook URL:

```bash
# Install the skill
muster skill add https://github.com/example/muster-discord-notify

# Enable for the production fleet
muster fleet skill enable production discord-notify

# Set fleet-specific config
muster fleet skill configure production discord-notify
# Prompts for:
#   Webhook URL: https://discord.com/api/webhooks/...
#   Username: Fleet: production
```

In the skill's `run.sh`, detect fleet context:

```bash
#!/usr/bin/env bash
# run.sh -- Discord notification skill

# Detect fleet vs regular deploy
if [[ -n "${MUSTER_FLEET_NAME:-}" ]]; then
  case "$MUSTER_HOOK" in
    fleet-deploy-start)
      _msg="Fleet **${MUSTER_FLEET_NAME}** deploy started (${MUSTER_FLEET_STRATEGY})"
      ;;
    fleet-machine-deploy-end)
      if [[ "$MUSTER_DEPLOY_STATUS" == "ok" ]]; then
        _msg="**${MUSTER_FLEET_MACHINE}** deployed successfully"
      else
        _msg="**${MUSTER_FLEET_MACHINE}** deploy FAILED"
      fi
      ;;
    fleet-deploy-end)
      if [[ "$MUSTER_DEPLOY_STATUS" == "ok" ]]; then
        _msg="Fleet **${MUSTER_FLEET_NAME}** deploy complete"
      else
        _msg="Fleet **${MUSTER_FLEET_NAME}** deploy finished with failures"
      fi
      ;;
    *) return 0 ;;
  esac
else
  # Regular (non-fleet) deploy hooks
  _msg="Service **${MUSTER_SERVICE}** ${MUSTER_DEPLOY_STATUS}"
fi

# Send to Discord
curl -s -H "Content-Type: application/json" \
  -d "{\"username\":\"${DISCORD_USERNAME:-muster}\",\"content\":\"${_msg}\"}" \
  "$DISCORD_WEBHOOK_URL"
```

The skill fires on both fleet and regular deploys, adapting its message based on context.
