# Muster Documentation

## Engine API

- [Engine API](ENGINE-API.md) -- Every `--json` command and event shape (the contract for muster-tui and scripts)

## Deploy

- [Deploy](deploy/deploy.md) -- Deploy flow, service selection, dry-run, failure recovery, JSON mode
- [Hooks](deploy/hooks.md) -- Hook types, environment variables, stack templates, security scanning
- [Setup Wizard](deploy/setup-wizard.md) -- Interactive and non-interactive setup, scanning, K8s introspection, re-running safely
- [Troubleshooting](troubleshooting.md) -- Every failure pattern muster recognizes, what it means, and the fix (`muster explain`)

## Fleet

- [Fleet](fleet/fleet.md) -- Multi-machine deployment, transports, strategies, groups

## Assistant

- [Muster Assistant](assistant.md) -- `muster ask`, tools, approvals, redaction, `--json` for muster-tui, `muster cloud connect`
- [Protocol contract](assistant-and-pairing.md) -- Assistant API and machine pairing (shared with server/relay)

## MCP

- [MCP server](mcp.md) -- `muster-mcp` for Claude Code / Desktop, Cursor, VS Code: setup, tools, resources, prompts, security model

## Skills

- [Creating Skills](skills/skills.md) -- Skill authoring: structure, hooks, config, fleet hooks, publishing
- [Marketplace](skills/marketplace.md) -- Browse, search, install skills from the official registry

## Security

- [Fleet Encryption](security/encryption.md) -- RSA-4096 + AES-256-CBC hybrid encryption for fleet reports
