# Fleet Deploy Strategies

> Three strategies for deploying across fleet machines.

```bash
muster fleet deploy [target] [--sequential] [--parallel] [--rolling] [--dry-run] [--sync] [--json]
```

The default strategy is set during `muster fleet setup` (Step 4) and stored in `fleet.json`. Override per-deploy with CLI flags.

## Sequential (Default)

Deploy to one machine at a time, in deploy order.

```bash
muster fleet deploy              # uses configured strategy
muster fleet deploy --sequential # force sequential
```

**Flow:**

1. Load deploy order (groups first, then ungrouped machines)
2. For each machine:
   a. Fire `fleet-machine-deploy-start` skill hook
   b. Auto-sync hooks if machine is in sync mode
   c. Deploy via muster mode (remote `muster deploy`) or push mode (pipe hooks via SSH)
   d. On success: log event, fire `fleet-machine-deploy-end` with `MUSTER_DEPLOY_STATUS=ok`
   e. On failure: show last 5 log lines, present recovery menu

**Failure recovery menu:**

| Option | Behavior |
|--------|----------|
| Retry | Re-run deploy on the same machine with a fresh log file |
| Skip and continue | Mark as failed, move to next machine |
| Abort | Stop the entire fleet deploy |

## Parallel

Deploy to all target machines concurrently. Capped at 10 simultaneous SSH connections per batch.

```bash
muster fleet deploy --parallel
```

**Flow:**

1. Spawn background subshells per machine (batches of 10)
2. Each subshell:
   a. Fires `fleet-machine-deploy-start` skill hook
   b. Auto-syncs hooks if needed
   c. Deploys and writes exit code + duration to a status file
   d. Fires `fleet-machine-deploy-end` with appropriate status
3. Live progress spinner shows completion count
4. After each batch completes, display a results box with per-machine status and duration

**Results box example:**

```
+- Results --------------------------------+
|  * prod-1                           12s  |
|  * prod-2                            8s  |
|  * prod-3               failed (15s)     |
+-----------------------------------------+
```

**Failure recovery after parallel deploy:**

| Option | Behavior |
|--------|----------|
| Retry failed | Re-run sequential deploy on failed machines only |
| View logs | Show last 10 lines from each failed machine's log |
| Continue | Accept failures and move on |

## Rolling

Deploy to one machine, verify health, then advance to the next. Safest for production.

```bash
muster fleet deploy --rolling
```

**Flow:**

1. For each machine:
   a. Fire `fleet-machine-deploy-start` skill hook
   b. Sync hooks if needed
   c. Deploy to the machine
   d. On success: fire `fleet-machine-deploy-end` with `MUSTER_DEPLOY_STATUS=ok`
   e. **Verify health** before proceeding to the next machine
   f. On deploy failure: present recovery menu

**Health verification** (between machines):
- **Muster mode:** Runs `muster status --minimal` on the remote and checks the exit code
- **Push mode:** Verifies SSH connectivity is still alive

**Deploy failure menu (rolling):**

| Option | Behavior |
|--------|----------|
| Retry | Re-deploy to the same machine |
| Skip and continue | Move to next machine |
| Abort | Stop the fleet deploy |

**Health failure menu (rolling):**

| Option | Behavior |
|--------|----------|
| Continue anyway | Proceed to next machine despite unhealthy status |
| Rollback <machine> | Run `muster rollback` on the failed machine, then continue |
| Abort | Stop the fleet deploy |

## Skill Hooks During Deploy

All three strategies fire the same skill hooks at the same lifecycle points:

| Hook | When | Scope |
|------|------|-------|
| `fleet-deploy-start` | Before first machine | Fleet-level |
| `fleet-machine-deploy-start` | Before each machine | Per-machine |
| `fleet-machine-deploy-end` | After each machine | Per-machine |
| `fleet-deploy-end` | After all machines | Fleet-level |

**Environment variables available in hooks:**

| Variable | Value |
|----------|-------|
| `MUSTER_FLEET_NAME` | Fleet name |
| `MUSTER_FLEET_STRATEGY` | `sequential`, `parallel`, or `rolling` |
| `MUSTER_FLEET_MACHINE` | Machine name (per-machine hooks only) |
| `MUSTER_FLEET_HOST` | `user@host` (per-machine hooks only) |
| `MUSTER_FLEET_MODE` | `muster` or `push` (per-machine hooks only) |
| `MUSTER_DEPLOY_STATUS` | `ok` or `failed` (end hooks only) |

See [Fleet Skills](skills.md) for details on configuring per-fleet skill behavior.

## Dry Run

Preview the deploy plan without executing:

```bash
muster fleet deploy --dry-run
```

Shows a box with each machine, its host, mode (muster/push), and pairing status. No connections are made and no hooks are run.

## Auto-Sync Before Deploy

Machines with `hook_mode: "sync"` automatically sync hook scripts to the remote before deploying. Force sync on any machine with the `--sync` flag:

```bash
muster fleet deploy --sync
```
