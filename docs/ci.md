# CI/CD with muster

Run the same deploys you run from your laptop in GitHub Actions, GitLab CI
or any other CI system. The hooks in `.muster/hooks/` and `muster.json` are
committed to the repo, reviewed in pull requests, and executed by the
runner.

- [GitHub Actions quickstart](#github-actions-quickstart)
- [Action reference](#action-reference)
- [Secrets](#secrets)
- [SSH vs Fleet Cloud](#ssh-vs-fleet-cloud)
- [Environments, approvals and concurrency](#environments-approvals-and-concurrency)
- [GitLab CI](#gitlab-ci)
- [Any other CI (`muster ci run`, `--json`)](#any-other-ci)
- [How muster behaves on CI](#how-muster-behaves-on-ci)

## GitHub Actions quickstart

```bash
muster ci init github        # shows .github/workflows/muster-deploy.yml
muster ci init github --yes  # writes it
muster ci env                # which secrets to add
```

The generated workflow:

- runs a **dry run** on every pull request (no secrets needed),
- **deploys** on push to `main` and from the **Run workflow** button
  (`workflow_dispatch`, with a `services` input),
- deploys inside the `production` **environment** (add required reviewers
  there to get an approval gate),
- uses a **concurrency group** so two deploys never overlap; a newer push
  waits instead of cancelling a deploy that's running.

Or write the step yourself:

```yaml
- uses: actions/checkout@v4
- uses: Muster-dev/muster@v0
  with:
    command: deploy
    services: api web          # empty = everything in deploy_order
```

Each service gets its own collapsible log group. The job summary shows a
table (service, result, duration, health, commit) and, when something
fails, muster's **Likely cause / Try** for it. Failed services become
`::error` annotations pointing at their hook file.

## Action reference

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `command` | `deploy` | `deploy`, `rollback`, `restart`, `status`, `fleet-deploy`, `fleet-rollback`, `fleet-restart`, `fleet-status` |
| `services` | `""` | Space- or comma-separated services. Empty = all (deploy/status). Required for rollback/restart |
| `server` | `""` | Fleet server; `deploy`/`rollback`/`restart`/`status` become `fleet-*` |
| `group` | `""` | Fleet group, same mapping as `server` |
| `dry-run` | `false` | Plan only (deploy, fleet-deploy) |
| `stop-on-failure` | `true` | Stop at the first failed service; the rest are reported `not_run` |
| `from` | `""` | Resume from this service in deploy order |
| `working-directory` | `.` | Directory with `muster.json` |
| `version` | `""` | muster to install: empty = this action's ref, `X.Y.Z`, or `latest` |
| `version-sha256` | `""` | Extra pin: SHA-256 of the release tarball |
| `approve-hooks` | `true` | Approve the repo's hooks on the runner (`--yes`). The repo is the reviewed source |
| `explain-on-failure` | `true` | Run `muster explain --json` for the first failure |
| `cloud-token` | `""` | Fleet Cloud CLI token → `MUSTER_CLOUD_TOKEN`; installs muster-tunnel |
| `cloud-relay` | `""` | Relay URL (default `https://relay.getmuster.dev`) |
| `tunnel-version` | `0.5.0` | muster-tunnel release to install |
| `ssh-key` | `""` | Private key for SSH deploys/fleets, loaded into `ssh-agent` |
| `known-hosts` | `""` | `known_hosts` lines; **required** with `ssh-key` |
| `args` | `""` | Extra arguments for the muster command |
| `github-token` | `github.token` | Used to resolve `version: latest` |

### Outputs

| Output | Example | Description |
|--------|---------|-------------|
| `result` | `success` | `success` or `failure` |
| `deployed` | `["api","web"]` | Services that deployed (or rolled back / restarted) |
| `failed` | `["worker"]` | Services that failed or are unhealthy |
| `summary-json` | `{…}` | Everything: per-service rows, hints, errors, explain, commit, version |
| `duration` | `42` | Seconds |
| `exit-code` | `1` | muster's exit code (0, 1, 124 timeout, 130 cancelled) |
| `explain-json` | `{…}` / `null` | `muster explain --json` for the first failure |
| `muster-version` | `0.7.4` | Installed muster |

```yaml
- uses: Muster-dev/muster@v0
  id: muster
  continue-on-error: true
- if: steps.muster.outputs.result == 'failure'
  run: echo "Failed: ${{ steps.muster.outputs.failed }}"
```

### How muster is installed

- No `version`: the action runs the muster in its own checkout, i.e. the
  ref you pinned (`@v0`, `@v0.7.4`, or a commit SHA for maximum pinning).
- `version: X.Y.Z` / `latest`: downloads `muster-X.Y.Z.tar.gz` from the
  GitHub release and checks it against the release's `checksums.txt`
  (and `version-sha256` if you set it), then caches it in the runner tool
  cache. Releases from before the tarball existed are cloned from the tag
  instead.
- `cloud-token` set: downloads the pinned `muster-tunnel` for the runner's
  OS/arch from the muster-fleet-cloud release and verifies it against that
  release's `checksums.txt`.

Linux and macOS runners (x64 and arm64) are supported.

## Secrets

`muster ci env` lists what your project needs (`--json` for scripts):

| Secret | When | Passed as |
|--------|------|-----------|
| `MUSTER_CRED_<KEY>` | a service has `credentials.required` | `env:` on the step. muster reads `MUSTER_CRED_<KEY>` from the environment instead of prompting |
| `MUSTER_SSH_KEY`, `MUSTER_KNOWN_HOSTS` | remote services or SSH fleet servers | `ssh-key`, `known-hosts` |
| `MUSTER_CLOUD_TOKEN` | Fleet Cloud servers | `cloud-token` |
| `KUBECONFIG` | Kubernetes services | written to `~/.kube/config` by a step |
| anything your hooks read | `$VAR` in a hook, not in a committed `.env` | `env:` on the step |

Secrets passed to the action are masked in the log; the one-off API token
`muster ci run` creates for the `--json` API is masked and revoked when the
run ends. Never commit `.env` files that hold secrets.

## SSH vs Fleet Cloud

**SSH** (`remote` services in muster.json, or SSH servers in `remotes.json`):

```yaml
- uses: Muster-dev/muster@v0
  with:
    ssh-key: ${{ secrets.MUSTER_SSH_KEY }}
    known-hosts: ${{ secrets.MUSTER_KNOWN_HOSTS }}   # ssh-keyscan -H your.host
```

The key goes into an `ssh-agent` (its temporary 0600 file is deleted right
away) and the agent is stopped when the action ends. Host keys are always
checked: on CI muster uses `StrictHostKeyChecking=yes`, so an unknown or
changed host key fails the deploy instead of being trusted.

**Fleet Cloud** (servers behind NAT running `muster-agent`):

```yaml
- uses: Muster-dev/muster@v0
  with:
    command: fleet-deploy
    server: prod-1            # or group: production
    cloud-token: ${{ secrets.MUSTER_CLOUD_TOKEN }}
```

No inbound ports or SSH keys; the runner talks to the relay with the CLI
token (create one in Fleet Cloud). Fleet servers must be defined in the
repo's `remotes.json` (or the action runs `muster fleet` commands you set up
in an earlier step). Fleet commands report one row per target and use the
exit code for the result.

## Environments, approvals and concurrency

- Put the deploy job in an [environment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment)
  (`environment: production`) and add required reviewers to make every
  deploy wait for an approval. Environment secrets keep production
  credentials away from other jobs.
- `concurrency: { group: muster-deploy-production, cancel-in-progress: false }`
  queues deploys instead of running two at once. muster's own deploy lock
  still protects against a deploy started from a laptop at the same time.
- One environment per stage: `muster ci init github --environment staging
  --branch develop` writes a staging variant.

## GitLab CI

```bash
muster ci init gitlab --yes   # writes .gitlab-ci.yml
```

The pipeline installs muster at a pinned version (`MUSTER_VERSION`), runs a
dry run on merge requests and deploys on the default branch with
`environment:` and a `resource_group` (one deploy at a time). Add secrets
as masked CI/CD variables; `MUSTER_SSH_KEY` should be a *file* variable.
The step summary is printed to the log and saved as `muster-summary.md`
with the raw events (`muster-events.ndjson`) as artifacts.

## Any other CI

`muster ci run` is the engine behind the GitHub Action and works anywhere
bash, git, jq and curl exist:

```bash
export MUSTER_APPROVE_HOOKS=1
muster ci run deploy --services "api web" --stop-on-failure --explain-on-failure \
  --events muster-events.ndjson
```

It creates a one-off API token, runs `muster deploy --json`, prints
readable logs (`==> deploy api` headers outside GitHub), and finishes with
a markdown summary. It exits with muster's exit code. On GitHub it also
writes `$GITHUB_OUTPUT`, `$GITHUB_STEP_SUMMARY` and annotations.

To build your own integration, use the `--json` API directly
([ENGINE-API.md](ENGINE-API.md)): every `--json` command prints only JSON on
stdout, needs `MUSTER_TOKEN` (`muster auth create ci --scope deploy`), and
exits non-zero on failure.

```bash
export MUSTER_TOKEN=$(muster auth create ci --scope deploy | awk '/Token:/{print $2}')
muster deploy --json --yes --stop-on-failure | tee events.ndjson \
  | jq -r 'select(.event=="summary") | "\(.deployed) deployed, \(.failed) failed"'
```

## How muster behaves on CI

When `CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, `BUILDKITE`, `CIRCLECI` or
`JENKINS_URL` is set and there's no TTY:

- **Nothing waits for input.** Prompts are skipped (they need a TTY) and
  print the flag or env var to use instead; credential prompts read
  `MUSTER_CRED_<KEY>` from the environment; hooks get `/dev/null` as stdin;
  git never asks for credentials (`GIT_TERMINAL_PROMPT=0`).
- **Plain output.** Colours are off unless `FORCE_COLOR` is set
  (`NO_COLOR` always wins).
- **Annotations** (GitHub): a failed deploy/rollback/restart hook prints an
  `::error` pointing at the hook file with the likely cause; a failed health
  check prints a `::warning`. Set `MUSTER_GITHUB_ANNOTATIONS=off` to turn
  them off.
- **Strict host keys**: `MUSTER_SSH_HOSTKEY_CHECK=yes` (set it to
  `accept-new` to opt out).
- Unapproved hooks still stop the deploy; pass `--yes` or set
  `MUSTER_APPROVE_HOOKS=1` (the action's `approve-hooks: true`).

| Variable | Effect |
|----------|--------|
| `MUSTER_APPROVE_HOOKS=1` | approve the repo's hooks on this machine |
| `MUSTER_GITHUB_ANNOTATIONS=off` | no `::error`/`::warning` lines |
| `MUSTER_NONINTERACTIVE=1` | treat any non-TTY run as CI |
| `MUSTER_SSH_HOSTKEY_CHECK` | `yes` (CI default) or `accept-new` |
| `MUSTER_CRED_<KEY>` | credential values for services |
| `MUSTER_CLOUD_TOKEN` / `MUSTER_CLOUD_RELAY` / `MUSTER_CLOUD_ORG` | Fleet Cloud without `muster cloud login` |
| `FORCE_COLOR` | colours on in CI logs |
