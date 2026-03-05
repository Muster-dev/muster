# Skill Marketplace

Browse, search, and install skills from the official registry.

## Quick Start

```bash
muster skill marketplace              # browse all available skills
muster skill marketplace discord      # search for a specific skill
```

## Browse

```bash
muster skill marketplace
```

Opens the marketplace TUI. Shows all skills in the registry with name, description, and version. Skills already installed are marked `(installed)`. Use the checklist to select skills to install or uninstall.

If run in a TTY, the marketplace prompts for a search query first (press Enter to browse all).

## Search

```bash
muster skill marketplace <query>
```

Searches skill names and descriptions (case-insensitive). If a single result is found, prompts to install/uninstall directly. Multiple results show a checklist for selection.

## Install from Marketplace

When you select a skill from the marketplace, muster:

1. Clones the [muster-skills](https://github.com/Muster-dev/muster-skills) registry repo
2. Copies the selected skill directory to your skills folder
3. Validates `skill.json` exists
4. Reports success

After installing, configure and enable the skill:

```bash
muster skill configure <name>    # set API keys, webhooks, etc.
muster skill enable <name>       # turn on auto-run for deploy/rollback hooks
```

## Install from Git URL

Install skills from any git repository:

```bash
muster skill add https://github.com/yourname/muster-skill-ssl
```

The `muster-skill-` prefix is automatically stripped from the repo name during install. If the skill is already installed, it updates (pulls latest) while preserving your `config.env` and enabled state.

## Install from Local Path

```bash
muster skill add /path/to/my-skill
```

Copies the skill directory. Reads the name from `skill.json` if available, otherwise uses the directory basename.

## Global vs Project Skills

```bash
muster skill marketplace                  # installs to project (.muster/skills/)
muster skill --global marketplace         # installs to ~/.muster/skills/
muster skill add --global <url>           # global install from URL
```

Project skills are scoped to the current project. Global skills are shared across all projects. Both are listed by `muster skill list`.

## Publishing

### Option A: Own Repository

Name your repo `muster-skill-<name>`. Users install with:

```bash
muster skill add https://github.com/yourname/muster-skill-<name>
```

Requirements:
- `skill.json` at the repo root (required)
- `run.sh` at the repo root (required, executable)

### Option B: Official Registry

Add your skill to [muster-skills](https://github.com/Muster-dev/muster-skills):

1. Fork the repo
2. Add your skill folder: `<name>/skill.json` + `<name>/run.sh`
3. Add an entry to `registry.json`
4. Open a PR

Once merged, your skill appears in `muster skill marketplace` for everyone.

## Registry Format

The marketplace fetches `registry.json` from the official skills repo. Format:

```json
{
  "skills": [
    {
      "name": "discord",
      "version": "1.0.0",
      "description": "Send deploy notifications to Discord",
      "author": "muster-dev",
      "hooks": ["post-deploy", "post-rollback"],
      "requires": ["curl"]
    },
    {
      "name": "slack",
      "version": "1.0.0",
      "description": "Send deploy notifications to Slack",
      "author": "muster-dev",
      "hooks": ["post-deploy", "post-rollback"],
      "requires": ["curl"]
    }
  ]
}
```

Each entry mirrors the `skill.json` manifest fields. The `name` field determines the directory name in the registry repo.

## Naming Convention

| Convention | Example |
|-----------|---------|
| Git repo name | `muster-skill-discord` |
| Installed name | `discord` (prefix stripped) |
| skill.json `name` | `discord` |

The `muster-skill-` prefix on repository names is a convention that helps discoverability. Muster automatically strips it during install so users interact with the short name.

## Skill Lifecycle

```
Marketplace/URL/Path  -->  Install  -->  Configure  -->  Enable  -->  Auto-runs
                                                                  -->  Or run manually
```

| Command | Action |
|---------|--------|
| `muster skill marketplace` | Browse and install from registry |
| `muster skill add <url>` | Install from git URL or local path |
| `muster skill configure <name>` | Set API keys, webhooks, etc. |
| `muster skill enable <name>` | Turn on auto-run for declared hooks |
| `muster skill disable <name>` | Turn off auto-run (manual only) |
| `muster skill run <name>` | Run manually |
| `muster skill list` | Show installed skills with status |
| `muster skill remove <name>` | Uninstall |
| `muster skill create <name>` | Scaffold a new skill |
