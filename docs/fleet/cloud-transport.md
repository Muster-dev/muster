# Cloud Transport

> Route fleet commands through a WebSocket relay. Works across LANs, NATs, and firewalls without direct SSH access.

Cloud transport is an alternative to SSH for fleet machines that are not directly reachable. Cloud and SSH machines can coexist in the same fleet -- each machine uses its own configured transport.

## Architecture

```
Your machine                    Relay                    Remote machine
+--------------+    WSS     +----------+    WSS     +----------------+
| muster-tunnel| ---------> |  muster  | <--------- | muster-agent   |
| (CLI helper) |  encrypted |  cloud   |  outbound  | (daemon)       |
+--------------+            +----------+             +----------------+
                                                     | muster (CLI)   |
                                                     +----------------+
```

| Component | Where | Purpose |
|-----------|-------|---------|
| `muster-tunnel` | Your laptop | CLI helper that connects to the relay and sends encrypted commands |
| `muster-cloud` | Relay server | WebSocket relay that routes messages between tunnel and agents |
| `muster-agent` | Remote machines | Daemon that connects outbound to the relay, receives and executes commands locally |

The agent connects **outbound** to the relay, so the remote machine needs no open inbound ports.

## Encryption

All commands are end-to-end encrypted using X25519 key exchange + NaCl box (XSalsa20-Poly1305). The relay cannot read command payloads -- it only routes encrypted messages between tunnel and agent.

## Requirements

| Component | Required On |
|-----------|-------------|
| `muster-tunnel` | Your machine (installed to `~/.muster/bin/` or PATH) |
| `muster-agent` | Each remote machine |
| `muster` CLI | Each remote machine (for muster-mode deploys) |
| Relay server | A running `muster-cloud` relay (self-hosted or managed) |

## Install

```bash
# Install muster-tunnel on your laptop
curl -fsSL https://raw.githubusercontent.com/Muster-dev/muster-fleet-cloud/main/install.sh \
  | bash -s -- --tunnel

# Install muster-agent on each remote
curl -fsSL https://raw.githubusercontent.com/Muster-dev/muster-fleet-cloud/main/install.sh \
  | bash -s -- --agent
```

## Setup

### On the remote machine

Register the agent with your relay and start the daemon:

```bash
# Register agent
muster-agent join \
  --relay wss://relay.example.com \
  --token mst_agent_<join-token> \
  --org myorg \
  --name prod-east \
  --project /opt/myapp

# Start the agent daemon (or install as systemd service)
muster-agent run
```

### On your laptop

Configure global cloud settings and add a cloud machine to your fleet:

```bash
# Set cloud connection details
muster settings --global cloud.relay '"wss://relay.example.com"'
muster settings --global cloud.org_id '"myorg"'
muster settings --global cloud.token '"mst_cli_<your-token>"'

# Add a cloud-transport machine
muster fleet add prod-east deploy@prod-east \
  --transport cloud --path /opt/myapp
```

## Cloud Settings

Cloud config is stored in `~/.muster/settings.json` under the `cloud` key:

```json
{
  "cloud": {
    "relay": "wss://relay.example.com",
    "org_id": "myorg",
    "token": "mst_cli_<token>"
  }
}
```

| Field | Description |
|-------|-------------|
| `cloud.relay` | WebSocket URL of the relay server |
| `cloud.org_id` | Organization identifier |
| `cloud.token` | CLI access token (prefixed `mst_cli_`) |

Set via `muster settings --global` or edit the JSON file directly.

### Token references

Instead of storing the token directly in settings, use `cloud.token_ref` to reference a named token from the credential system:

```json
{
  "cloud": {
    "relay": "wss://relay.example.com",
    "org_id": "myorg",
    "token_ref": "cloud-prod"
  }
}
```

The referenced token is resolved from `~/.muster/tokens/cloud.json` (mode 600).

## Transport Functions

The cloud transport layer (`lib/core/cloud.sh`) provides three operations that mirror SSH transport:

| Function | Operation | SSH Equivalent |
|----------|-----------|----------------|
| `_fleet_cloud_exec` | Execute a command on a remote agent | `ssh user@host "command"` |
| `_fleet_cloud_push` | Push a hook script to a remote agent | Piping script via `ssh user@host "bash -s"` |
| `_fleet_cloud_check` | Ping an agent to check connectivity | `ssh user@host "echo ok"` |

Fleet commands (`fleet_exec`, `fleet_push_hook`, `fleet_check`) automatically dispatch to the correct transport based on the machine's `transport` setting in `remotes.json` or `fleet.json`.

## Mixed Fleets

A single fleet can contain both SSH and cloud machines. The transport is set per-machine:

```json
{
  "machines": {
    "prod-1": {
      "host": "10.0.1.10",
      "user": "deploy",
      "transport": "ssh"
    },
    "prod-2": {
      "host": "prod-east",
      "user": "deploy",
      "transport": "cloud"
    }
  }
}
```

All fleet operations (deploy, status, rollback, test) work transparently across transports.
