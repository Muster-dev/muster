#!/usr/bin/env bash
# docs/gen-troubleshooting.sh — regenerate docs/troubleshooting.md from the
# rule table in lib/core/hints.sh (run: make docs).
set -eo pipefail

MUSTER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MUSTER_ROOT
# shellcheck disable=SC2034
BOLD="" DIM="" RESET="" YELLOW="" GREEN="" RED=""
has_cmd() { command -v "$1" >/dev/null 2>&1; }
# shellcheck source=/dev/null
source "$MUSTER_ROOT/lib/core/hints.sh"

# One-key fixes muster can offer (only ever run after you confirm)
_fix_desc() {
  case "$1" in
    deploy_timeout) echo "Raise the service's \`deploy_timeout\` in muster.json (doubles it, max 3600s)." ;;
    docker_not_running) echo "Start Docker: \`open -a Docker\` / \`colima start\` on macOS, \`sudo systemctl start docker\` on Linux." ;;
    docker_sock_permission) echo "Linux: \`sudo usermod -aG docker \$USER\` (log out and back in afterwards)." ;;
    disk_full) echo "\`docker system df; docker system prune -f\`." ;;
    registry_rate_limit|registry_pull_denied) echo "\`docker login [registry]\`." ;;
    k8s_namespace) echo "\`kubectl create namespace <ns>\`." ;;
    port_in_use) echo "Stop whatever holds the port: \`docker stop <container>\` or \`kill <pid>\` (found with docker ps / lsof / ss)." ;;
    npm_lockfile) echo "\`npm install --package-lock-only\`." ;;
    go_build) echo "\`go mod tidy\`." ;;
    hook_not_executable) echo "\`chmod +x .muster/hooks/<svc>/*.sh\`." ;;
    command_not_found|tool_missing) echo "Install the tool with your package manager (brew, apt-get, dnf, yum, apk or pacman)." ;;
    conn_refused_dep) echo "Move the dependency before the service in \`deploy_order\`." ;;
    stale_lock) echo "Remove the lock left by a process that no longer exists." ;;
    health_wrong_port) echo "Point \`health.port\` at the port the service is listening on." ;;
    git_behind) echo "\`git pull --ff-only\`." ;;
    ssh_host_key) echo "None, on purpose. muster never bypasses host key checks." ;;
  esac
}

{
  cat <<'EOF'
# Troubleshooting

When a deploy, rollback or health check fails, muster matches the log, the exit
code and your environment against the rules below. It works offline, with no AI.
You see the result as **Likely cause / Try** above the recovery menu. When a rule
has a fix, the menu also gets a **Fix: …** entry. A fix only runs after you pick
it or confirm it.

```bash
muster explain                 # why did the last deploy fail?
muster explain api             # explain api's newest log
muster explain --log build.log # any log file, even outside a project
muster explain --json          # machine-readable (muster-tui, scripts)
muster explain --fix           # explain, then offer the fix
muster explain --rules         # list every rule
```

Many of the same problems are caught **before** a deploy starts. Preflight checks
tools, the Docker daemon, the kube context and namespace, disk space, ports, hook
permissions, env vars, git state, stale locks and SSH reachability. Skip it with
`muster deploy --no-preflight`. `muster doctor --fix` applies the fixes that
are safe to automate.

> This file is generated from `lib/core/hints.sh` by `make docs`. Edit the rule
> table there, not here.

## Rules

| Rule | What it means |
|------|---------------|
EOF
  i=0
  while (( i < ${#_HR_ID[@]} )); do
    printf '| [`%s`](#%s) | %s |\n' "${_HR_ID[$i]}" "${_HR_ID[$i]//_/-}" "${_HR_TITLE[$i]}"
    i=$(( i + 1 ))
  done
  echo ""
  i=0
  while (( i < ${#_HR_ID[@]} )); do
    id="${_HR_ID[$i]}"
    printf '<a id="%s"></a>\n\n### `%s`\n\n' "${id//_/-}" "$id"
    printf '%s\n\n' "${_HR_TITLE[$i]}"
    printf '**Try:** %s\n\n' "${_HR_TRY[$i]}"
    fix=$(_fix_desc "$id")
    [[ -n "$fix" ]] && printf '**Fix:** %s\n\n' "$fix"
    if [[ -n "${_HR_PAT[$i]}" ]]; then
      printf '<sub>Matches: <code>%s</code></sub>\n\n' "$(printf '%s' "${_HR_PAT[$i]}" | sed 's/|/ \&#124; /g; s/</\&lt;/g; s/>/\&gt;/g')"
    else
      case "$id" in
        deploy_timeout) printf '<sub>Matches: exit code 124.</sub>\n\n' ;;
        health_*) printf '<sub>Detected by probing the health check after it fails.</sub>\n\n' ;;
        *) printf '<sub>Detected by preflight / doctor checks.</sub>\n\n' ;;
      esac
    fi
    i=$(( i + 1 ))
  done
} > "$MUSTER_ROOT/docs/troubleshooting.md"

echo "Wrote docs/troubleshooting.md (${#_HR_ID[@]} rules)"
