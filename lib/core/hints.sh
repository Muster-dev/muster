#!/usr/bin/env bash
# muster/lib/core/hints.sh — Offline rules engine: plain-English explanations
# for deploy/rollback failures, health check failures and preflight problems.
#
# Deterministic and offline: a table of patterns matched against log lines,
# exit codes and the local environment. Each rule gives:
#   id      stable identifier (docs anchor: docs/troubleshooting.md#<id>)
#   title   one-line plain explanation ("Likely cause")
#   try     suggested fix ("Try")
#   fix     optional runnable fix command + label — only ever run after the
#           user confirms (menu choice, [y/N] prompt or --yes)
#
# Public API:
#   hints_match_file FILE [exit_code] [service]   match a log; sets HINT_*
#   hints_match_text TEXT [exit_code] [service]   same, for a string
#   hints_lookup ID [service] [line]              fill HINT_* for a rule id
#   hints_health SERVICE                          diagnose a failed health check
#   hints_print [prefix]                          "Likely cause / Try" lines
#   hints_show_for_failure SVC LOG RC [action]    match + print + record
#   hints_run_fix [--yes]                         confirm + run HINT_FIX_CMD
#   hints_json                                    current hint as a JSON object
#   hints_list_rules                              id|title|try (for docs)
#
# Globals set by a match:
#   HINT_ID HINT_TITLE HINT_TRY HINT_FIX_CMD HINT_FIX_LABEL HINT_DOCS HINT_LINE
#   _HINT_ALL_IDS[]   every rule that matched, best first

MUSTER_DOCS_URL="${MUSTER_DOCS_URL:-https://getmuster.dev/docs/troubleshooting}"

HINT_ID="" HINT_TITLE="" HINT_TRY="" HINT_FIX_CMD="" HINT_FIX_LABEL=""
HINT_DOCS="" HINT_LINE=""
_HINT_LOG_TEXT=""
_HINT_ALL_IDS=()
_HINT_ALL_LINES=()

# ── Rule table ──
# Order matters: the first matching rule is the "likely cause", so specific
# rules come before generic ones (ssh/k8s before "connection refused", etc.).
# Rules with an empty pattern are context-only (exit codes, health, preflight).
_HR_ID=()
_HR_PAT=()
_HR_TITLE=()
_HR_TRY=()

_hr() {
  local i=${#_HR_ID[@]}
  _HR_ID[$i]="$1"
  _HR_PAT[$i]="$2"
  _HR_TITLE[$i]="$3"
  _HR_TRY[$i]="$4"
}

# Exit-code driven
_hr deploy_timeout '' \
  "The hook ran longer than its deploy_timeout and was stopped (exit 124)." \
  "If the deploy is just slow (large image builds, slow rollouts), raise deploy_timeout for this service in muster.json. If it hangs, check the log for a step waiting on input or a network call."

# SSH (before generic connection errors)
_hr ssh_host_key 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|Offending (ECDSA|RSA|ED25519)? ?key in' \
  "The remote server's SSH host key doesn't match the one you saved before. The server may have been rebuilt — or something may be intercepting the connection." \
  "Confirm the new fingerprint with whoever runs the server, then remove the old key with: ssh-keygen -R <host>. muster never bypasses host key checks for you."
_hr ssh_auth 'Permission denied \(publickey|Permission denied, please try again|Too many authentication failures|no mutual signature algorithm' \
  "SSH reached the server but it refused your credentials." \
  "Check the user and identity_file in the service's remote config, load your key with ssh-add, and test with: ssh -i <key> <user>@<host> true"
_hr ssh_timeout 'ssh: connect to host .*(timed out|No route to host|Network is unreachable|Connection refused)|ssh: Could not resolve hostname|Connection closed by .* port [0-9]+|kex_exchange_identification' \
  "Couldn't open an SSH connection to the remote host (timeout, DNS or network)." \
  "Check the host name and port, that you're on the right network/VPN, and that sshd is running. Test with: ssh -v <user>@<host>"

# Docker daemon / socket
_hr docker_sock_permission 'permission denied.*docker\.sock|Got permission denied while trying to connect to the Docker daemon' \
  "Your user isn't allowed to talk to the Docker daemon." \
  "On Linux, add yourself to the docker group, then log out and back in (or run: newgrp docker). On macOS, restart Docker Desktop."
_hr docker_not_running 'Cannot connect to the Docker daemon|Is the docker daemon running|docker daemon is not running|error during connect:.*(docker|pipe)|failed to connect to the docker API' \
  "Docker is installed but the Docker daemon isn't running." \
  "Start Docker (Docker Desktop, colima or the docker service), wait until 'docker info' works, then retry."

# Disk
_hr disk_full 'no space left on device|ENOSPC|There is not enough space on the disk' \
  "The disk (or Docker's storage) is full." \
  "See what's using space with: docker system df. Removing stopped containers, dangling images and build cache usually frees enough."

# Registry
_hr registry_rate_limit 'toomanyrequests|You have reached your pull rate limit|rate limit exceeded.*(docker|registry)' \
  "Docker Hub's anonymous pull rate limit was hit." \
  "Log in (docker login) to get a higher limit, wait a few hours, or pull from a mirror/your own registry."
_hr registry_manifest_unknown 'manifest unknown|manifest for .* not found|not found: manifest|failed to resolve reference .*: not found' \
  "The image tag doesn't exist in the registry." \
  "Check the image name and tag (typos, a tag that was never pushed, or a build that didn't push). List tags in your registry or push the image first."
_hr registry_pull_denied 'pull access denied|repository does not exist or may require .docker login|unauthorized: authentication required|denied: requested access to the resource is denied|no basic auth credentials' \
  "The registry refused access to the image — it's private, misspelled, or you're not logged in." \
  "Run docker login for that registry, and check the image name. For k8s, make sure an imagePullSecret is set."
_hr registry_tls 'x509:|certificate signed by unknown authority|certificate has expired|tls: failed to verify certificate|SSL certificate problem' \
  "A TLS certificate couldn't be verified (self-signed, expired, or a corporate proxy)." \
  "Install the registry/proxy CA certificate on this machine (and in Docker), or fix the expired certificate. Avoid disabling TLS verification."

# Architecture
_hr exec_format 'exec format error|image.s platform .* does not match the detected host platform|no matching manifest for .*(linux/arm64|linux/amd64)' \
  "The image or binary was built for a different CPU architecture (for example arm64 vs amd64)." \
  "Build for the target platform: docker build --platform linux/amd64 (or linux/arm64), or set DOCKER_DEFAULT_PLATFORM. Use docker buildx for multi-arch images."

# Memory
_hr oom_killed 'OOMKilled|Out of memory|out of memory: Killed process|JavaScript heap out of memory|exit code 137|Killed[[:space:]]*$' \
  "The process ran out of memory and was killed (OOMKilled / exit 137)." \
  "Raise the memory limit (k8s resources.limits.memory, compose mem_limit, docker run --memory) or reduce memory use. For Node, set NODE_OPTIONS=--max-old-space-size."

# Kubernetes
_hr k8s_unauthorized 'You must be logged in to the server|server has asked for the client to provide credentials|error: Unauthorized|Unauthorized\)?$|forbidden: User .* cannot' \
  "kubectl reached the cluster but your credentials were rejected (expired token or missing permissions)." \
  "Refresh your cluster credentials (e.g. aws eks update-kubeconfig, gcloud container clusters get-credentials, az aks get-credentials) and check RBAC for the namespace."
_hr k8s_context 'context .* does not exist|no context exists with the name|current-context is not set|error: no configuration has been provided|The connection to the server localhost:8080 was refused' \
  "kubectl has no usable context — it isn't pointed at any cluster." \
  "List contexts with: kubectl config get-contexts, then pick one: kubectl config use-context <name>"
_hr k8s_namespace 'namespaces? "[^"]+" not found' \
  "The Kubernetes namespace doesn't exist." \
  "Create it (kubectl create namespace <ns>) or fix the namespace in muster.json (services.<svc>.k8s.namespace)."
_hr k8s_unreachable 'Unable to connect to the server|The connection to the server .* was refused|dial tcp .*:6443|net/http: TLS handshake timeout' \
  "The Kubernetes API server can't be reached." \
  "Check your VPN/network, that the cluster is running, and the current context: kubectl config current-context"
_hr k8s_image_pull 'ImagePullBackOff|ErrImagePull|ErrImageNeverPull|InvalidImageName' \
  "Kubernetes can't pull the container image." \
  "Check the image name and tag in the deployment, that it was pushed, and imagePullSecrets for private registries. For local clusters with pullPolicy Never, load the image into the cluster."
_hr k8s_crashloop 'CrashLoopBackOff|Back-off restarting failed container' \
  "The container starts and then keeps crashing." \
  "Read the crash output: kubectl logs <pod> --previous. Common causes: missing env vars, wrong command, or a dependency (DB) that isn't reachable."
_hr k8s_config_error 'CreateContainerConfigError|secrets? "[^"]+" not found|configmaps? "[^"]+" not found|persistentvolumeclaims? "[^"]+" not found' \
  "A Secret, ConfigMap or PVC the pod needs doesn't exist." \
  "Create the missing object in the namespace (kubectl get secret,configmap,pvc -n <ns>) or fix the reference in the manifest."
_hr k8s_unschedulable 'Insufficient (cpu|memory)|0/[0-9]+ nodes are available|FailedScheduling|Unschedulable' \
  "No node has enough free CPU/memory (or matching labels) to run the pod." \
  "Lower resources.requests, add nodes, or check nodeSelector/taints: kubectl describe pod <pod>"

# Ports
_hr port_in_use 'port is already allocated|address already in use|EADDRINUSE|Only one usage of each socket address' \
  "The port this service wants is already taken by another process or container." \
  "Stop whatever holds the port, or change the port the service publishes."

# Build tooling
_hr npm_lockfile 'can only install (packages|with an existing package-lock)|npm ci.*package-lock|package-lock\.json.*(missing|not in sync|out of sync)|ERR_PNPM_OUTDATED_LOCKFILE|ERR_PNPM_NO_LOCKFILE|Your lockfile needs to be updated|lockfile had changes, but lockfile is frozen' \
  "The install step needs a lockfile that's missing or out of date." \
  "Generate/refresh the lockfile locally (npm install, pnpm install or yarn install), commit it, then redeploy."
_hr npm_dependency 'Cannot find module|ERESOLVE unable to resolve dependency tree|npm ERR! code ERESOLVE|Module not found: Error: Can.t resolve|ERR_MODULE_NOT_FOUND' \
  "A JavaScript dependency is missing or the dependency tree can't be resolved." \
  "Make sure the package is in package.json (not just installed locally), then run npm install. For ERESOLVE, fix the conflicting peer versions (or use --legacy-peer-deps as a last resort)."
_hr pip_failure 'No matching distribution found|ModuleNotFoundError: No module named|Could not find a version that satisfies the requirement|error: externally-managed-environment|Failed building wheel for' \
  "A Python dependency couldn't be installed or imported." \
  "Check the package name/version in requirements.txt (or pyproject), install into a virtualenv, and make sure build tools exist for packages that compile."
_hr go_build 'updates to go.mod needed|missing go.sum entry|cannot find module providing package|go: module .* requires go >=|go: inconsistent vendoring' \
  "The Go module files are out of date for this build." \
  "Run go mod tidy, commit go.mod and go.sum, then redeploy. If a newer Go is required, update the toolchain/base image."

# Git
_hr git_conflict 'CONFLICT \(|Automatic merge failed|not possible to fast-forward|divergent branches|fatal: Need to specify how to reconcile' \
  "git pull couldn't merge cleanly — local commits/changes conflict with the remote." \
  "Resolve it by hand: git status, then merge/rebase and commit. muster never discards your local changes."
_hr git_dirty 'Your local changes to the following files would be overwritten|Please commit your changes or stash them|You have unstaged changes|untracked working tree files would be overwritten' \
  "git pull stopped because uncommitted local changes would be overwritten." \
  "Commit or stash them (git stash), pull, then deploy again."

# Environment / permissions
_hr env_missing 'variable is not set\. Defaulting to a blank string|required variable [A-Za-z_][A-Za-z0-9_]* is missing|: unbound variable|environment variable [A-Za-z_][A-Za-z0-9_]* (is )?(not set|required|missing)' \
  "A required environment variable isn't set." \
  "Add it to the project's .env (muster loads it before every deploy) or export it in your shell/CI."
_hr hook_not_executable '\.muster/hooks/[^ ]*: Permission denied|permission denied.*\.muster/hooks' \
  "A hook script isn't executable." \
  "Make it executable: chmod +x .muster/hooks/<service>/*.sh"
_hr command_not_found ': command not found|: not found$|executable file not found in \$PATH' \
  "A command the hook calls isn't installed (or isn't on PATH)." \
  "Install the missing tool, or use its full path in the hook."

# Dependencies between services
_hr conn_refused_dep 'ECONNREFUSED|Connection refused|could not connect to server|connection to server at .* failed|Can.t connect to (MySQL|local MySQL) server|Redis connection .* failed|connect: connection refused' \
  "The service couldn't reach something it depends on (a database, cache or another service)." \
  "Make sure infrastructure deploys first (deploy_order in muster.json) and that hosts/ports in your config are right."

# Locks
_hr stale_lock 'deploy lock|lock held by|Deploy blocked' \
  "Another deploy holds the lock, or a crashed deploy left its lock behind." \
  "If the owning process is gone, remove the lock (muster doctor --fix) or use muster deploy --force."

# Context-only rules (health checks, preflight)
_hr health_wrong_port '' \
  "The health check targets a port nothing is listening on, but the service is listening on another port." \
  "Point the health check at the port the service actually uses (muster settings, or health.port in muster.json)."
_hr health_refused '' \
  "Nothing is listening on the health check port — the service isn't up (yet), or crashed after starting." \
  "Check the service logs (muster logs <svc>); if it is just slow to start, raise health.timeout."
_hr health_timeout '' \
  "The health endpoint didn't answer before the timeout." \
  "The service may still be starting or be overloaded. Raise health.timeout in muster.json, or check the logs."
_hr health_http_5xx '' \
  "The health endpoint answered with a server error (HTTP 5xx) — the service is up but unhealthy." \
  "Check the service logs for the error behind the 5xx (often a database or config problem)."
_hr health_http_4xx '' \
  "The health endpoint answered with HTTP 4xx — the path is probably wrong or needs auth." \
  "Fix health.endpoint in muster.json (for example /health or /healthz), or allow unauthenticated access to it."
_hr prod_context '' \
  "kubectl's current context looks like production, but this project doesn't." \
  "Double-check before deploying: kubectl config current-context. Switch with kubectl config use-context <name>."
_hr git_behind '' \
  "Your branch is behind its upstream — you may be deploying old code." \
  "Pull first (git pull), or deploy anyway if that's intended."
_hr hook_missing '' \
  "A service has no deploy hook, so there is nothing to run." \
  "Re-run muster setup (choose Update to keep your changes) to regenerate missing hooks, or add .muster/hooks/<svc>/deploy.sh yourself."
_hr tool_missing '' \
  "A tool this stack needs isn't installed." \
  "Install it with your package manager (see the suggested command)."

# ── Helpers ──

_hints_reset() {
  HINT_ID="" HINT_TITLE="" HINT_TRY="" HINT_FIX_CMD="" HINT_FIX_LABEL=""
  HINT_DOCS="" HINT_LINE=""
  _HINT_ALL_IDS=()
  _HINT_ALL_LINES=()
}

# Index of a rule id in the table (echo), 1 if unknown
_hints_index() {
  local i=0
  while (( i < ${#_HR_ID[@]} )); do
    if [[ "${_HR_ID[$i]}" == "$1" ]]; then
      printf '%s' "$i"
      return 0
    fi
    i=$(( i + 1 ))
  done
  return 1
}

# Strip ANSI escapes and CRs from stdin
_hints_clean() {
  sed -e $'s/\033\\[[0-9;?]*[A-Za-z]//g' -e $'s/\r$//' 2>/dev/null
}

# Project dir if a config is loaded
_hints_project_dir() {
  if [[ -n "${CONFIG_FILE:-}" && -f "${CONFIG_FILE:-}" ]]; then
    dirname "$CONFIG_FILE"
  else
    pwd
  fi
}

_hints_cfg() {
  [[ -n "${CONFIG_FILE:-}" && -f "${CONFIG_FILE:-}" ]] || return 1
  local v
  v=$(config_get "$1" 2>/dev/null)
  [[ -z "$v" || "$v" == "null" ]] && return 1
  printf '%s' "$v"
}

# Detect the system package manager (echo name)
_hints_pkg_manager() {
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    has_cmd brew && { echo brew; return; }
  fi
  local pm
  for pm in apt-get dnf yum apk pacman brew; do
    has_cmd "$pm" && { echo "$pm"; return; }
  done
  echo ""
}

# Install command for a tool on this machine (echo), empty if unknown
_hints_install_cmd() {
  local tool="$1" pm pkg sudo=""
  pm=$(_hints_pkg_manager)
  [[ -z "$pm" ]] && return 0
  [[ "$pm" != "brew" && "$(id -u 2>/dev/null)" != "0" ]] && sudo="sudo "
  pkg="$tool"
  case "$tool" in
    docker)
      case "$pm" in
        brew) printf 'brew install --cask docker'; return ;;
        apt-get) pkg="docker.io" ;;
        dnf|yum) pkg="docker" ;;
        apk) pkg="docker" ;;
        pacman) pkg="docker" ;;
      esac ;;
    docker-compose|compose)
      case "$pm" in
        brew) pkg="docker-compose" ;;
        apt-get|dnf|yum) pkg="docker-compose-plugin" ;;
        apk) pkg="docker-cli-compose" ;;
        pacman) pkg="docker-compose" ;;
      esac ;;
    kubectl)
      case "$pm" in
        apt-get|dnf|yum) printf '%s' "# kubectl: see https://kubernetes.io/docs/tasks/tools/ (or: snap install kubectl --classic)"; return ;;
        pacman) pkg="kubectl" ;;
      esac ;;
    node|npm|npx)
      case "$pm" in
        brew) pkg="node" ;;
        apt-get) pkg="nodejs npm" ;;
        dnf|yum) pkg="nodejs" ;;
        apk) pkg="nodejs npm" ;;
        pacman) pkg="nodejs npm" ;;
      esac ;;
    python|python3|pip|pip3)
      case "$pm" in
        brew) pkg="python" ;;
        apt-get) pkg="python3 python3-pip" ;;
        dnf|yum) pkg="python3 python3-pip" ;;
        apk) pkg="python3 py3-pip" ;;
        pacman) pkg="python python-pip" ;;
      esac ;;
    go)
      case "$pm" in
        apt-get) pkg="golang-go" ;;
        dnf|yum) pkg="golang" ;;
        brew|apk|pacman) pkg="go" ;;
      esac ;;
    envsubst) pkg="gettext" ;;
    ss) pkg="iproute2" ;;
    lsof|jq|git|curl|helm|just|rsync|sshpass|make) ;;
    *)
      # Only suggest installs for names that look like packages
      [[ "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 0 ;;
  esac
  case "$pm" in
    brew) printf 'brew install %s' "$pkg" ;;
    apt-get) printf '%sapt-get install -y %s' "$sudo" "$pkg" ;;
    dnf) printf '%sdnf install -y %s' "$sudo" "$pkg" ;;
    yum) printf '%syum install -y %s' "$sudo" "$pkg" ;;
    apk) printf '%sapk add %s' "$sudo" "$pkg" ;;
    pacman) printf '%spacman -S --noconfirm %s' "$sudo" "$pkg" ;;
  esac
}

# Command that starts the Docker daemon on this machine (echo), may be empty
_hints_docker_start_cmd() {
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      if [[ -d "/Applications/Docker.app" || -d "$HOME/Applications/Docker.app" ]]; then
        printf 'open -a Docker'
      elif [[ -d "/Applications/OrbStack.app" ]]; then
        printf 'open -a OrbStack'
      elif has_cmd colima; then
        printf 'colima start'
      elif has_cmd orb; then
        printf 'orb start'
      fi
      ;;
    Linux)
      if has_cmd systemctl; then
        printf 'sudo systemctl start docker'
      elif has_cmd service; then
        printf 'sudo service docker start'
      elif has_cmd rc-service; then
        printf 'sudo rc-service docker start'
      fi
      ;;
  esac
}

# Extract a port number from a log line (echo), empty if none
_hints_port_from_line() {
  local line="$1" p=""
  p=$(printf '%s' "$line" | grep -Eo ':[0-9]{2,5}([^0-9]|$)' | tail -1 | tr -cd '0-9') || true
  if [[ -z "$p" ]]; then
    p=$(printf '%s' "$line" | grep -Eio 'port [0-9]{2,5}' | tail -1 | tr -cd '0-9') || true
  fi
  printf '%s' "$p"
}

# Who holds a TCP port? Sets _HPO_KIND (container|process|""), _HPO_NAME, _HPO_PID
_hints_port_owner() {
  local port="$1"
  _HPO_KIND="" _HPO_NAME="" _HPO_PID=""
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  if has_cmd docker; then
    local cname
    cname=$(_run_with_timeout 5 docker ps --filter "publish=${port}" --format '{{.Names}}' 2>/dev/null | head -1)
    if [[ -n "$cname" && "$cname" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
      _HPO_KIND="container" _HPO_NAME="$cname"
      return 0
    fi
  fi
  local pid=""
  if has_cmd lsof; then
    pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
  elif has_cmd ss; then
    pid=$(ss -ltnpH "sport = :${port}" 2>/dev/null | grep -Eo 'pid=[0-9]+' | head -1 | tr -cd '0-9') || true
  fi
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    _HPO_KIND="process" _HPO_PID="$pid"
    _HPO_NAME=$(ps -o comm= -p "$pid" 2>/dev/null | head -1)
    _HPO_NAME="${_HPO_NAME##*/}"
    [[ -z "$_HPO_NAME" ]] && _HPO_NAME="process"
    return 0
  fi
  return 1
}

# Is anything listening on a TCP port locally?
_hints_port_listening() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  if has_cmd lsof; then
    [[ -n "$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)" ]]
    return $?
  elif has_cmd ss; then
    [[ -n "$(ss -ltnH "sport = :${port}" 2>/dev/null | head -1)" ]]
    return $?
  elif has_cmd nc; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# TCP ports a PID (and its children) listens on (echo, space-separated)
_hints_listening_ports_for_pid() {
  local pid="$1" pids ports=""
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  pids="$pid $(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')"
  local p
  for p in $pids; do
    if has_cmd lsof; then
      ports="${ports} $(lsof -nP -a -p "$p" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{n=split($9,a,":"); print a[n]}' | tr '\n' ' ')"
    fi
  done
  printf '%s' "$ports" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' '
}

# Map a well-known port to an infra service name
_hints_port_infra() {
  case "$1" in
    5432) echo postgres ;; 3306) echo mysql ;; 6379) echo redis ;;
    27017) echo mongo ;; 5672) echo rabbitmq ;; 9200) echo elasticsearch ;;
    11211) echo memcached ;; 9092) echo kafka ;; 2181) echo zookeeper ;;
    4222) echo nats ;; 8500) echo consul ;;
  esac
}

# ── Rule enrichers: refine title/try and attach a fix command ──
# Each receives: service line exit_code. They may override HINT_TITLE/HINT_TRY
# and set HINT_FIX_CMD/HINT_FIX_LABEL. Fix commands are built only from
# validated values (numeric ports/PIDs, safe container/tool names).

_hint_enrich_deploy_timeout() {
  local svc="$1" cur
  [[ -z "$svc" ]] && return 0
  cur=$(_hints_cfg ".services.${svc}.deploy_timeout")
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=120
  local next=$(( cur * 2 ))
  (( next > 3600 )) && next=3600
  HINT_TITLE="The ${svc} hook ran longer than its ${cur}s deploy_timeout and was stopped (exit 124)."
  if [[ -n "${CONFIG_FILE:-}" ]] && has_cmd jq && [[ "$svc" =~ ^[A-Za-z0-9_-]+$ ]]; then
    HINT_FIX_CMD="_hints_fix_timeout ${svc} ${next}"
    HINT_FIX_LABEL="Raise ${svc} deploy_timeout to ${next}s"
  fi
}

_hint_enrich_port_in_use() {
  local line="$2" port
  port=$(_hints_port_from_line "$line")
  [[ -z "$port" ]] && port=$(_hints_cfg ".services.${1}.health.port")
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  if _hints_port_owner "$port"; then
    if [[ "$_HPO_KIND" == "container" ]]; then
      HINT_TITLE="Port ${port} is already in use by the container '${_HPO_NAME}'."
      HINT_TRY="Stop that container (docker stop ${_HPO_NAME}), or change the port this service publishes."
      HINT_FIX_CMD="docker stop ${_HPO_NAME}"
      HINT_FIX_LABEL="Stop container ${_HPO_NAME} (frees port ${port})"
    else
      HINT_TITLE="Port ${port} is already in use by ${_HPO_NAME} (PID ${_HPO_PID})."
      HINT_TRY="Stop it (kill ${_HPO_PID}) if it's a leftover, or change the port this service uses."
      HINT_FIX_CMD="kill ${_HPO_PID}"
      HINT_FIX_LABEL="Stop ${_HPO_NAME} (PID ${_HPO_PID}) on port ${port}"
    fi
  else
    HINT_TITLE="Port ${port} is already in use by another process or container."
    HINT_TRY="Find the owner with: lsof -nP -iTCP:${port} -sTCP:LISTEN (or docker ps). Stop it, or change the service's port."
  fi
}

_hint_enrich_docker_not_running() {
  local cmd
  cmd=$(_hints_docker_start_cmd)
  case "$cmd" in
    "open -a Docker") HINT_TRY="Start Docker Desktop (open -a Docker), wait for the whale icon to settle, then retry." ;;
    "colima start") HINT_TRY="Start colima (colima start), then retry." ;;
    *systemctl*|*service*) HINT_TRY="Start the Docker service (${cmd}). To start it at boot: sudo systemctl enable docker" ;;
  esac
  if [[ -n "$cmd" ]]; then
    HINT_FIX_CMD="$cmd"
    HINT_FIX_LABEL="Start Docker"
  fi
}

_hint_enrich_docker_sock_permission() {
  if [[ "$(uname -s 2>/dev/null)" == "Linux" ]]; then
    HINT_FIX_CMD='sudo usermod -aG docker "$USER"'
    HINT_FIX_LABEL="Add $(id -un 2>/dev/null || echo you) to the docker group (re-login after)"
  fi
}

_hint_enrich_disk_full() {
  if has_cmd docker; then
    HINT_FIX_CMD="docker system df; docker system prune -f"
    HINT_FIX_LABEL="Prune stopped containers, dangling images and build cache"
  fi
}

_hint_enrich_registry_rate_limit() {
  has_cmd docker || return 0
  HINT_FIX_CMD="docker login"
  HINT_FIX_LABEL="Log in to Docker Hub"
}

_hint_enrich_registry_pull_denied() {
  local line="$2" img="" reg=""
  img=$(printf '%s' "$line" | grep -Eo 'for [A-Za-z0-9./_:-]+' | head -1 | sed 's/^for //') || true
  [[ -n "$img" ]] && HINT_TITLE="The registry refused access to '${img%,}' — it's private, misspelled, or you're not logged in."
  case "$img" in
    */*) reg="${img%%/*}"; [[ "$reg" == *.* || "$reg" == *:* ]] || reg="" ;;
  esac
  has_cmd docker || return 0
  if [[ -n "$reg" && "$reg" =~ ^[A-Za-z0-9.:-]+$ ]]; then
    HINT_FIX_CMD="docker login ${reg}"
    HINT_FIX_LABEL="Log in to ${reg}"
  else
    HINT_FIX_CMD="docker login"
    HINT_FIX_LABEL="Log in to the registry"
  fi
}

_hint_enrich_exec_format() {
  local arch
  arch=$(uname -m 2>/dev/null)
  case "$arch" in
    arm64|aarch64) HINT_TRY="This machine is arm64. ${HINT_TRY}" ;;
    x86_64|amd64)  HINT_TRY="This machine is amd64. ${HINT_TRY}" ;;
  esac
}

_hint_enrich_oom_killed() {
  local svc="$1" ns dep
  ns=$(_hints_cfg ".services.${svc}.k8s.namespace")
  dep=$(_hints_cfg ".services.${svc}.k8s.deployment")
  if [[ -n "$dep" ]]; then
    HINT_TRY="Raise resources.limits.memory for deployment/${dep} (kubectl -n ${ns:-default} get deploy ${dep} -o jsonpath='{..resources}' shows the current limit), or reduce memory use. For Node, set NODE_OPTIONS=--max-old-space-size."
  fi
}

_hint_enrich_k8s_namespace() {
  local ns
  ns=$(printf '%s' "$2" | grep -Eo 'namespaces? "[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"/\1/')
  if [[ "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    HINT_TITLE="The Kubernetes namespace '${ns}' doesn't exist."
    HINT_FIX_CMD="kubectl create namespace ${ns}"
    HINT_FIX_LABEL="Create namespace ${ns}"
  fi
}

_hint_enrich_k8s_context() {
  local ctx
  ctx=$(kubectl config get-contexts -o name 2>/dev/null | head -5 | tr '\n' ' ')
  [[ -n "$ctx" ]] && HINT_TRY="${HINT_TRY} Available: ${ctx}"
}

_hint_enrich_npm_lockfile() {
  local dir
  dir=$(_hints_project_dir)
  if has_cmd npm && [[ -f "${dir}/package.json" && ! -f "${dir}/pnpm-lock.yaml" && ! -f "${dir}/yarn.lock" ]]; then
    HINT_FIX_CMD="npm install --package-lock-only"
    HINT_FIX_LABEL="Generate package-lock.json"
  fi
}

_hint_enrich_go_build() {
  local dir
  dir=$(_hints_project_dir)
  if has_cmd go && [[ -f "${dir}/go.mod" ]]; then
    HINT_FIX_CMD="go mod tidy"
    HINT_FIX_LABEL="Run go mod tidy"
  fi
}

_hint_enrich_git_dirty() {
  HINT_TRY="${HINT_TRY} See what changed with: git status"
}

_hint_enrich_env_missing() {
  local line="$2" var=""
  var=$(printf '%s' "$line" | sed -nE 's/.*The "([A-Za-z_][A-Za-z0-9_]*)" variable is not set.*/\1/p')
  [[ -z "$var" ]] && var=$(printf '%s' "$line" | sed -nE 's/.*[^A-Za-z0-9_]([A-Za-z_][A-Za-z0-9_]*): unbound variable.*/\1/p')
  [[ -z "$var" ]] && var=$(printf '%s' "$line" | sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*): unbound variable.*/\1/p')
  [[ -z "$var" ]] && var=$(printf '%s' "$line" | sed -nE 's/.*required variable ([A-Za-z_][A-Za-z0-9_]*) is missing.*/\1/p')
  [[ -z "$var" ]] && var=$(printf '%s' "$line" | sed -nE 's/.*environment variable ([A-Za-z_][A-Za-z0-9_]*) .*/\1/p')
  if [[ -n "$var" ]]; then
    HINT_TITLE="The environment variable ${var} isn't set."
    HINT_TRY="Add ${var}=<value> to the project's .env (muster loads it before every deploy) or export it in your shell/CI."
  fi
}

_hint_enrich_hook_not_executable() {
  local svc="$1" line="$2" path=""
  path=$(printf '%s' "$line" | grep -Eo '[^ :]*\.muster/hooks/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | head -1) || true
  if [[ -n "$path" && "$path" =~ ^[A-Za-z0-9_./-]+$ ]]; then
    HINT_FIX_CMD="chmod +x ${path}"
    HINT_FIX_LABEL="Make ${path##*/.muster/hooks/} executable"
  elif [[ -n "$svc" && "$svc" =~ ^[A-Za-z0-9_-]+$ ]]; then
    HINT_FIX_CMD="chmod +x .muster/hooks/${svc}/*.sh"
    HINT_FIX_LABEL="Make ${svc} hooks executable"
  fi
}

_hint_enrich_command_not_found() {
  local line="$2" tool="" cmd
  tool=$(printf '%s' "$line" | sed -nE 's/.*[: ]([A-Za-z0-9_.+-]+): command not found.*/\1/p')
  [[ -z "$tool" ]] && tool=$(printf '%s' "$line" | sed -nE 's/.*: ([A-Za-z0-9_.+-]+): not found$/\1/p')
  [[ -z "$tool" ]] && tool=$(printf '%s' "$line" | sed -nE 's/.*exec: "([A-Za-z0-9_.+-]+)": executable file not found.*/\1/p')
  [[ -z "$tool" ]] && tool=$(printf '%s' "$line" | sed -nE 's/^([A-Za-z0-9_.+-]+): command not found.*/\1/p')
  [[ -z "$tool" ]] && return 0
  HINT_TITLE="The hook calls '${tool}', which isn't installed (or isn't on PATH)."
  cmd=$(_hints_install_cmd "$tool")
  if [[ -n "$cmd" && "$cmd" != \#* ]]; then
    HINT_TRY="Install it (${cmd}), or use its full path in the hook."
    HINT_FIX_CMD="$cmd"
    HINT_FIX_LABEL="Install ${tool}"
  elif [[ -n "$cmd" ]]; then
    HINT_TRY="Install it — ${cmd#\# }"
  fi
}

_hint_enrich_conn_refused_dep() {
  local svc="$1" line="$2" port infra="" dep_svc=""
  port=$(_hints_port_from_line "$line")
  [[ -n "$port" ]] && infra=$(_hints_port_infra "$port")
  [[ -z "${CONFIG_FILE:-}" || ! -f "${CONFIG_FILE:-}" ]] && {
    [[ -n "$infra" ]] && HINT_TITLE="Couldn't connect to ${infra} (port ${port}) — it isn't running or isn't reachable."
    return 0
  }
  # Find a configured service that matches the port or infra name
  local s
  while IFS= read -r s; do
    [[ -z "$s" || "$s" == "$svc" ]] && continue
    local hp
    hp=$(_hints_cfg ".services.${s}.health.port")
    if [[ -n "$port" && "$hp" == "$port" ]]; then dep_svc="$s"; break; fi
    if [[ -n "$infra" && "$s" == *"$infra"* ]]; then dep_svc="$s"; break; fi
  done < <(config_services 2>/dev/null)
  local what="${dep_svc:-${infra:-a dependency}}"
  [[ -n "$port" ]] && what="${what} (port ${port})"
  HINT_TITLE="${svc:-The service} couldn't connect to ${what} — it isn't running or isn't reachable."
  [[ -z "$dep_svc" ]] && return 0
  # Is the dependency ordered after this service?
  local order pos_svc=-1 pos_dep=-1 i=0 o
  order=$(config_get '.deploy_order[]?' 2>/dev/null)
  while IFS= read -r o; do
    [[ "$o" == "$svc" ]] && pos_svc=$i
    [[ "$o" == "$dep_svc" ]] && pos_dep=$i
    i=$(( i + 1 ))
  done <<< "$order"
  if (( pos_svc >= 0 && pos_dep > pos_svc )); then
    HINT_TITLE="${svc} couldn't connect to ${what} — ${dep_svc} deploys after ${svc} in deploy_order."
    HINT_TRY="Deploy ${dep_svc} first: move it before ${svc} in deploy_order (muster.json)."
    if has_cmd jq && [[ "$svc" =~ ^[A-Za-z0-9_-]+$ && "$dep_svc" =~ ^[A-Za-z0-9_-]+$ ]]; then
      HINT_FIX_CMD="_hints_fix_order_before ${dep_svc} ${svc}"
      HINT_FIX_LABEL="Move ${dep_svc} before ${svc} in deploy_order"
    fi
  else
    HINT_TRY="Check that ${dep_svc} is running and healthy (muster status ${dep_svc}) and that ${svc} uses the right host/port."
  fi
}

_hint_enrich_ssh_host_key() {
  local host
  host=$(printf '%s\n%s\n' "$2" "$_HINT_LOG_TEXT" | sed -nE 's/.*Host key for ([^ ]+) has changed.*/\1/p' | head -1)
  if [[ -n "$host" && "$host" =~ ^[A-Za-z0-9.:_-]+$ ]]; then
    HINT_TRY="Confirm the new fingerprint with whoever runs ${host}, then remove the old key: ssh-keygen -R ${host}. muster never bypasses host key checks."
  fi
  # Deliberately no fix command: removing a host key must be a human decision.
  HINT_FIX_CMD="" HINT_FIX_LABEL=""
}

_hint_enrich_stale_lock() {
  local dir lock pid user started
  dir=$(_hints_project_dir)
  lock="${dir}/.muster/deploy.lock"
  [[ -f "$lock" ]] || return 0
  _deploy_lock_read "$lock" 2>/dev/null
  pid="${_LOCK_PID:-}" user="${_LOCK_USER:-unknown}" started="${_LOCK_STARTED:-unknown}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    HINT_TITLE="A deploy by ${user} (PID ${pid}, started ${started}) is still running."
    HINT_TRY="Wait for it to finish. Only use muster deploy --force if you're sure it's stuck."
  else
    HINT_TITLE="A deploy lock from ${user} (PID ${pid:-?}, started ${started}) was left behind — that process is gone."
    HINT_FIX_CMD="rm -f .muster/deploy.lock"
    HINT_FIX_LABEL="Remove the stale deploy lock"
  fi
}

# ── Fix helpers (run only after confirmation) ──

# Raise .services.<svc>.deploy_timeout in muster.json
_hints_fix_timeout() {
  local svc="$1" secs="$2" tmp
  [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]] || { err "No muster.json loaded"; return 1; }
  tmp="${CONFIG_FILE}.tmp.$$"
  jq --arg s "$svc" --argjson t "$secs" '.services[$s].deploy_timeout = $t' "$CONFIG_FILE" > "$tmp" \
    && mv "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 1; }
  ok "Set ${svc} deploy_timeout to ${secs}s in $(basename "$CONFIG_FILE")"
}

# Move service A right before service B in deploy_order
_hints_fix_order_before() {
  local a="$1" b="$2" tmp
  [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]] || { err "No muster.json loaded"; return 1; }
  tmp="${CONFIG_FILE}.tmp.$$"
  jq --arg a "$a" --arg b "$b" '
    .deploy_order = ((.deploy_order // []) | map(select(. != $a))
      | (index($b) // 0) as $i | .[:$i] + [$a] + .[$i:])' "$CONFIG_FILE" > "$tmp" \
    && mv "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 1; }
  ok "deploy_order: ${a} now deploys before ${b}"
}

# ── Matching ──

# Fill HINT_* for a rule id (with enrichment). Args: id [service] [line] [rc]
hints_lookup() {
  local id="$1" svc="${2:-}" line="${3:-}" rc="${4:-}" idx
  idx=$(_hints_index "$id") || return 1
  HINT_ID="$id"
  HINT_TITLE="${_HR_TITLE[$idx]}"
  HINT_TRY="${_HR_TRY[$idx]}"
  HINT_FIX_CMD="" HINT_FIX_LABEL=""
  HINT_LINE="$line"
  HINT_DOCS="${MUSTER_DOCS_URL}#${id//_/-}"
  if declare -F "_hint_enrich_${id}" >/dev/null 2>&1; then
    "_hint_enrich_${id}" "$svc" "$line" "$rc"
  fi
  return 0
}

# Match a log file. Args: file [exit_code] [service]
# Returns 0 and sets HINT_* when a rule matched; 1 otherwise.
hints_match_file() {
  local file="$1" rc="${2:-}" svc="${3:-}"
  _hints_reset
  local tmp=""
  if [[ -n "$file" && -f "$file" ]]; then
    tmp=$(mktemp 2>/dev/null || echo "/tmp/.muster_hints_$$")
    tail -n 300 "$file" 2>/dev/null | _hints_clean > "$tmp"
  fi

  # Exit-code rules that trump log text
  if [[ "$rc" == "124" ]]; then
    _HINT_ALL_IDS[${#_HINT_ALL_IDS[@]}]="deploy_timeout"
    _HINT_ALL_LINES[${#_HINT_ALL_LINES[@]}]=""
  fi

  if [[ -n "$tmp" && -s "$tmp" ]]; then
    local i=0 pat line
    while (( i < ${#_HR_ID[@]} )); do
      pat="${_HR_PAT[$i]}"
      if [[ -n "$pat" ]]; then
        # Last matching line is usually closest to the real failure
        line=$(grep -Ei -- "$pat" "$tmp" 2>/dev/null | tail -1) || true
        if [[ -n "$line" ]]; then
          _HINT_ALL_IDS[${#_HINT_ALL_IDS[@]}]="${_HR_ID[$i]}"
          _HINT_ALL_LINES[${#_HINT_ALL_LINES[@]}]="$line"
        fi
      fi
      i=$(( i + 1 ))
    done
  fi
  _HINT_LOG_TEXT=""
  [[ -n "$tmp" && -s "$tmp" ]] && _HINT_LOG_TEXT=$(cat "$tmp")
  [[ -n "$tmp" ]] && rm -f "$tmp"

  # Exit-code fallbacks when the log said nothing recognisable
  if (( ${#_HINT_ALL_IDS[@]} == 0 )); then
    case "$rc" in
      126) _HINT_ALL_IDS[0]="hook_not_executable"; _HINT_ALL_LINES[0]="" ;;
      127) _HINT_ALL_IDS[0]="command_not_found"; _HINT_ALL_LINES[0]="" ;;
      137) _HINT_ALL_IDS[0]="oom_killed"; _HINT_ALL_LINES[0]="" ;;
    esac
  fi

  (( ${#_HINT_ALL_IDS[@]} == 0 )) && return 1
  local _ids_keep=("${_HINT_ALL_IDS[@]}") _lines_keep=("${_HINT_ALL_LINES[@]}")
  hints_lookup "${_ids_keep[0]}" "$svc" "${_lines_keep[0]}" "$rc"
  _HINT_ALL_IDS=("${_ids_keep[@]}")
  _HINT_ALL_LINES=("${_lines_keep[@]}")
  return 0
}

# Match a string. Args: text [exit_code] [service]
hints_match_text() {
  local tmp rc=0
  tmp=$(mktemp 2>/dev/null || echo "/tmp/.muster_hintt_$$")
  printf '%s\n' "$1" > "$tmp"
  hints_match_file "$tmp" "${2:-}" "${3:-}" || rc=1
  rm -f "$tmp"
  return $rc
}

# Diagnose a failed health check for a service. Sets HINT_*; returns 0 if a
# specific cause was found.
hints_health() {
  local svc="$1"
  _hints_reset
  local htype port endpoint timeout
  htype=$(_hints_cfg ".services.${svc}.health.type") || htype=""
  port=$(_hints_cfg ".services.${svc}.health.port") || port=""
  endpoint=$(_hints_cfg ".services.${svc}.health.endpoint") || endpoint="/health"
  timeout=$(_hints_cfg ".services.${svc}.health.timeout") || timeout=10
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=10
  [[ "$htype" == "http" || "$htype" == "tcp" ]] || return 1
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  # Remote services: we can't inspect their ports from here
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    local remote
    remote=$(_hints_cfg ".services.${svc}.remote.enabled") || remote=""
    [[ "$remote" == "true" ]] && return 1
  fi

  if ! _hints_port_listening "$port"; then
    # Is the service listening somewhere else? (dev/bare stacks record a PID)
    local dir pidf pid other=""
    dir=$(_hints_project_dir)
    pidf="${dir}/.muster/pids/${svc}.pid"
    if [[ -f "$pidf" ]]; then
      pid=$(tr -cd '0-9' < "$pidf")
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        other=$(_hints_listening_ports_for_pid "$pid" | awk '{print $1}')
      fi
    fi
    if [[ -n "$other" && "$other" != "$port" ]]; then
      hints_lookup health_wrong_port "$svc"
      HINT_TITLE="The health check for ${svc} targets port ${port}, but ${svc} is listening on port ${other}."
      HINT_TRY="Point the health check at port ${other} (health.port in muster.json, or muster settings)."
      if has_cmd jq && [[ -n "${CONFIG_FILE:-}" && "$svc" =~ ^[A-Za-z0-9_-]+$ ]]; then
        HINT_FIX_CMD="_hints_fix_health_port ${svc} ${other}"
        HINT_FIX_LABEL="Use port ${other} for the ${svc} health check"
      fi
      return 0
    fi
    hints_lookup health_refused "$svc"
    HINT_TITLE="Nothing is listening on port ${port} — ${svc} isn't up (yet), or crashed after starting."
    return 0
  fi

  [[ "$htype" == "http" ]] || return 1
  has_cmd curl || return 1
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" "http://127.0.0.1:${port}${endpoint}" 2>/dev/null)
  case "$code" in
    000)
      hints_lookup health_timeout "$svc"
      HINT_TITLE="${svc} is listening on port ${port} but ${endpoint} didn't answer within ${timeout}s."
      return 0 ;;
    5??)
      hints_lookup health_http_5xx "$svc"
      HINT_TITLE="${svc} answered ${endpoint} with HTTP ${code} — it's up but reporting an error."
      return 0 ;;
    4??)
      hints_lookup health_http_4xx "$svc"
      HINT_TITLE="${svc} answered ${endpoint} with HTTP ${code} — the path is probably wrong or needs auth."
      return 0 ;;
  esac
  return 1
}

_hints_fix_health_port() {
  local svc="$1" port="$2" tmp
  [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]] || return 1
  tmp="${CONFIG_FILE}.tmp.$$"
  jq --arg s "$svc" --argjson p "$port" '.services[$s].health.port = $p' "$CONFIG_FILE" > "$tmp" \
    && mv "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 1; }
  ok "Health check for ${svc} now uses port ${port}"
  # Regenerated-style health hooks read the port from the hook itself
  local hook
  hook="$(dirname "$CONFIG_FILE")/.muster/hooks/${svc}/health.sh"
  if [[ -f "$hook" ]] && grep -q 'localhost:[0-9]\+\|127\.0\.0\.1:[0-9]\+' "$hook" 2>/dev/null; then
    printf '  %bNote: %s hardcodes a port — update it too (then muster hooks approve).%b\n' "${DIM}" "${hook##*/.muster/}" "${RESET}"
  fi
}

# ── Output ──

# Print the current hint. Args: [indent]
hints_print() {
  [[ -z "$HINT_ID" ]] && return 1
  local ind="${1:-  }"
  if [[ "${MUSTER_MINIMAL:-false}" == "true" ]]; then
    printf '%sLikely cause: %s\n' "$ind" "$HINT_TITLE"
    printf '%sTry: %s\n' "$ind" "$HINT_TRY"
    [[ -n "$HINT_FIX_CMD" ]] && printf '%sFix: %s (%s)\n' "$ind" "$HINT_FIX_LABEL" "$(_hints_fix_display)"
    return 0
  fi
  printf '%b%bLikely cause:%b %s\n' "$ind" "${BOLD}${YELLOW}" "${RESET}" "$HINT_TITLE"
  printf '%b%bTry:%b %s\n' "$ind" "${BOLD}" "${RESET}" "$HINT_TRY"
  if [[ -n "$HINT_FIX_CMD" ]]; then
    printf '%b%bFix available:%b %s %b(%s)%b\n' "$ind" "${BOLD}" "${RESET}" "$HINT_FIX_LABEL" "${DIM}" "$(_hints_fix_display)" "${RESET}"
  fi
  printf '%b%bMore: %s%b\n' "$ind" "${DIM}" "$HINT_DOCS" "${RESET}"
}

# How to show a fix command: built-in fixes edit muster.json, so describe
# them instead of printing an internal function name.
_hints_fix_display() {
  case "$HINT_FIX_CMD" in
    _hints_fix_*) printf 'edits muster.json' ;;
    *) printf '%s' "$HINT_FIX_CMD" ;;
  esac
}

# Record the last failure for `muster explain --last` and the dashboard.
# Args: service action rc log
hints_record_failure() {
  local svc="$1" action="$2" rc="$3" log="$4" dir
  dir=$(_hints_project_dir)
  [[ -d "${dir}/.muster" ]] || return 0
  mkdir -p "${dir}/.muster/logs" 2>/dev/null
  printf '%s|%s|%s|%s|%s|%s\n' "$(date +%s)" "$svc" "$action" "$rc" "$log" "${HINT_ID:-}" \
    > "${dir}/.muster/logs/.last_failure" 2>/dev/null
}

# Match a failed hook's log, print "Likely cause / Try" and record it.
# Args: service log_file exit_code [action]
# Leaves HINT_* set (HINT_FIX_CMD drives the "Fix:" menu entry).
hints_show_for_failure() {
  local svc="$1" log="$2" rc="$3" action="${4:-deploy}"
  if hints_match_file "$log" "$rc" "$svc"; then
    hints_print "  "
    echo ""
  fi
  hints_record_failure "$svc" "$action" "$rc" "$log"
  declare -f _ci_annotate_failure >/dev/null 2>&1 && _ci_annotate_failure "$svc" "$action" "$rc"
  return 0
}

# Ask before running HINT_FIX_CMD, then run it from the project dir.
# Args: [--yes]  (skip the [y/N] prompt — the caller already confirmed)
hints_run_fix() {
  [[ -z "$HINT_FIX_CMD" ]] && return 1
  local yes=false
  [[ "${1:-}" == "--yes" ]] && yes=true
  if [[ "$yes" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      printf '  %bFix (not run — no terminal):%b %s\n' "${DIM}" "${RESET}" "$(_hints_fix_display)"
      return 1
    fi
    case "$HINT_FIX_CMD" in
      _hints_fix_*) printf '  This will: %b%s%b (edits muster.json)\n' "${BOLD}" "$HINT_FIX_LABEL" "${RESET}" ;;
      *) printf '  This will run: %b%s%b\n' "${BOLD}" "$HINT_FIX_CMD" "${RESET}" ;;
    esac
    printf '  Run it? [y/N] '
    local ans=""
    IFS= read -r ans || true
    case "$ans" in y|Y|yes|YES) ;; *) printf '  %bSkipped.%b\n' "${DIM}" "${RESET}"; return 1 ;; esac
  else
    printf '  %bRunning:%b %s\n' "${DIM}" "${RESET}" "$(_hints_fix_display)"
  fi
  local dir rc=0
  dir=$(_hints_project_dir)
  ( cd "$dir" 2>/dev/null || true; eval "$HINT_FIX_CMD" ) || rc=$?
  if (( rc == 0 )); then
    ok "Fix applied: ${HINT_FIX_LABEL}"
  else
    err "Fix command failed (exit ${rc})"
  fi
  return $rc
}

# Current hint as a JSON object
hints_json() {
  local fix="null"
  if [[ -n "$HINT_FIX_CMD" ]]; then
    local internal=false
    [[ "$HINT_FIX_CMD" == _hints_fix_* ]] && internal=true
    fix="{\"label\":\"$(_json_escape "$HINT_FIX_LABEL")\",\"command\":\"$(_json_escape "$HINT_FIX_CMD")\",\"internal\":${internal}}"
  fi
  printf '{"id":"%s","title":"%s","try":"%s","fix":%s,"docs":"%s","line":"%s"}' \
    "$(_json_escape "$HINT_ID")" "$(_json_escape "$HINT_TITLE")" "$(_json_escape "$HINT_TRY")" \
    "$fix" "$(_json_escape "$HINT_DOCS")" "$(_json_escape "$HINT_LINE")"
}

# id|title|try for every rule (docs generation, tests)
hints_list_rules() {
  local i=0
  while (( i < ${#_HR_ID[@]} )); do
    printf '%s|%s|%s\n' "${_HR_ID[$i]}" "${_HR_TITLE[$i]}" "${_HR_TRY[$i]}"
    i=$(( i + 1 ))
  done
}
