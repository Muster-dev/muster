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
| [`deploy_timeout`](#deploy-timeout) | The hook ran longer than its deploy_timeout and was stopped (exit 124). |
| [`ssh_host_key`](#ssh-host-key) | The remote server's SSH host key doesn't match the one you saved before. The server may have been rebuilt — or something may be intercepting the connection. |
| [`ssh_auth`](#ssh-auth) | SSH reached the server but it refused your credentials. |
| [`ssh_timeout`](#ssh-timeout) | Couldn't open an SSH connection to the remote host (timeout, DNS or network). |
| [`docker_sock_permission`](#docker-sock-permission) | Your user isn't allowed to talk to the Docker daemon. |
| [`docker_not_running`](#docker-not-running) | Docker is installed but the Docker daemon isn't running. |
| [`disk_full`](#disk-full) | The disk (or Docker's storage) is full. |
| [`registry_rate_limit`](#registry-rate-limit) | Docker Hub's anonymous pull rate limit was hit. |
| [`registry_manifest_unknown`](#registry-manifest-unknown) | The image tag doesn't exist in the registry. |
| [`registry_pull_denied`](#registry-pull-denied) | The registry refused access to the image — it's private, misspelled, or you're not logged in. |
| [`registry_tls`](#registry-tls) | A TLS certificate couldn't be verified (self-signed, expired, or a corporate proxy). |
| [`exec_format`](#exec-format) | The image or binary was built for a different CPU architecture (for example arm64 vs amd64). |
| [`oom_killed`](#oom-killed) | The process ran out of memory and was killed (OOMKilled / exit 137). |
| [`k8s_unauthorized`](#k8s-unauthorized) | kubectl reached the cluster but your credentials were rejected (expired token or missing permissions). |
| [`k8s_context`](#k8s-context) | kubectl has no usable context — it isn't pointed at any cluster. |
| [`k8s_namespace`](#k8s-namespace) | The Kubernetes namespace doesn't exist. |
| [`k8s_unreachable`](#k8s-unreachable) | The Kubernetes API server can't be reached. |
| [`k8s_image_pull`](#k8s-image-pull) | Kubernetes can't pull the container image. |
| [`k8s_crashloop`](#k8s-crashloop) | The container starts and then keeps crashing. |
| [`k8s_config_error`](#k8s-config-error) | A Secret, ConfigMap or PVC the pod needs doesn't exist. |
| [`k8s_unschedulable`](#k8s-unschedulable) | No node has enough free CPU/memory (or matching labels) to run the pod. |
| [`port_in_use`](#port-in-use) | The port this service wants is already taken by another process or container. |
| [`npm_lockfile`](#npm-lockfile) | The install step needs a lockfile that's missing or out of date. |
| [`npm_dependency`](#npm-dependency) | A JavaScript dependency is missing or the dependency tree can't be resolved. |
| [`pip_failure`](#pip-failure) | A Python dependency couldn't be installed or imported. |
| [`go_build`](#go-build) | The Go module files are out of date for this build. |
| [`git_conflict`](#git-conflict) | git pull couldn't merge cleanly — local commits/changes conflict with the remote. |
| [`git_dirty`](#git-dirty) | git pull stopped because uncommitted local changes would be overwritten. |
| [`env_missing`](#env-missing) | A required environment variable isn't set. |
| [`hook_not_executable`](#hook-not-executable) | A hook script isn't executable. |
| [`command_not_found`](#command-not-found) | A command the hook calls isn't installed (or isn't on PATH). |
| [`conn_refused_dep`](#conn-refused-dep) | The service couldn't reach something it depends on (a database, cache or another service). |
| [`stale_lock`](#stale-lock) | Another deploy holds the lock, or a crashed deploy left its lock behind. |
| [`health_wrong_port`](#health-wrong-port) | The health check targets a port nothing is listening on, but the service is listening on another port. |
| [`health_refused`](#health-refused) | Nothing is listening on the health check port — the service isn't up (yet), or crashed after starting. |
| [`health_timeout`](#health-timeout) | The health endpoint didn't answer before the timeout. |
| [`health_http_5xx`](#health-http-5xx) | The health endpoint answered with a server error (HTTP 5xx) — the service is up but unhealthy. |
| [`health_http_4xx`](#health-http-4xx) | The health endpoint answered with HTTP 4xx — the path is probably wrong or needs auth. |
| [`prod_context`](#prod-context) | kubectl's current context looks like production, but this project doesn't. |
| [`git_behind`](#git-behind) | Your branch is behind its upstream — you may be deploying old code. |
| [`hook_missing`](#hook-missing) | A service has no deploy hook, so there is nothing to run. |
| [`tool_missing`](#tool-missing) | A tool this stack needs isn't installed. |

<a id="deploy-timeout"></a>

### `deploy_timeout`

The hook ran longer than its deploy_timeout and was stopped (exit 124).

**Try:** If the deploy is just slow (large image builds, slow rollouts), raise deploy_timeout for this service in muster.json. If it hangs, check the log for a step waiting on input or a network call.

**Fix:** Raise the service's `deploy_timeout` in muster.json (doubles it, max 3600s).

<sub>Matches: exit code 124.</sub>

<a id="ssh-host-key"></a>

### `ssh_host_key`

The remote server's SSH host key doesn't match the one you saved before. The server may have been rebuilt — or something may be intercepting the connection.

**Try:** Confirm the new fingerprint with whoever runs the server, then remove the old key with: ssh-keygen -R <host>. muster never bypasses host key checks for you.

**Fix:** None, on purpose. muster never bypasses host key checks.

<sub>Matches: <code>REMOTE HOST IDENTIFICATION HAS CHANGED &#124; Host key verification failed &#124; Offending (ECDSA &#124; RSA &#124; ED25519)? ?key in</code></sub>

<a id="ssh-auth"></a>

### `ssh_auth`

SSH reached the server but it refused your credentials.

**Try:** Check the user and identity_file in the service's remote config, load your key with ssh-add, and test with: ssh -i <key> <user>@<host> true

<sub>Matches: <code>Permission denied \(publickey &#124; Permission denied, please try again &#124; Too many authentication failures &#124; no mutual signature algorithm</code></sub>

<a id="ssh-timeout"></a>

### `ssh_timeout`

Couldn't open an SSH connection to the remote host (timeout, DNS or network).

**Try:** Check the host name and port, that you're on the right network/VPN, and that sshd is running. Test with: ssh -v <user>@<host>

<sub>Matches: <code>ssh: connect to host .*(timed out &#124; No route to host &#124; Network is unreachable &#124; Connection refused) &#124; ssh: Could not resolve hostname &#124; Connection closed by .* port [0-9]+ &#124; kex_exchange_identification</code></sub>

<a id="docker-sock-permission"></a>

### `docker_sock_permission`

Your user isn't allowed to talk to the Docker daemon.

**Try:** On Linux, add yourself to the docker group, then log out and back in (or run: newgrp docker). On macOS, restart Docker Desktop.

**Fix:** Linux: `sudo usermod -aG docker $USER` (log out and back in afterwards).

<sub>Matches: <code>permission denied.*docker\.sock &#124; Got permission denied while trying to connect to the Docker daemon</code></sub>

<a id="docker-not-running"></a>

### `docker_not_running`

Docker is installed but the Docker daemon isn't running.

**Try:** Start Docker (Docker Desktop, colima or the docker service), wait until 'docker info' works, then retry.

**Fix:** Start Docker: `open -a Docker` / `colima start` on macOS, `sudo systemctl start docker` on Linux.

<sub>Matches: <code>Cannot connect to the Docker daemon &#124; Is the docker daemon running &#124; docker daemon is not running &#124; error during connect:.*(docker &#124; pipe) &#124; failed to connect to the docker API</code></sub>

<a id="disk-full"></a>

### `disk_full`

The disk (or Docker's storage) is full.

**Try:** See what's using space with: docker system df. Removing stopped containers, dangling images and build cache usually frees enough.

**Fix:** `docker system df; docker system prune -f`.

<sub>Matches: <code>no space left on device &#124; ENOSPC &#124; There is not enough space on the disk</code></sub>

<a id="registry-rate-limit"></a>

### `registry_rate_limit`

Docker Hub's anonymous pull rate limit was hit.

**Try:** Log in (docker login) to get a higher limit, wait a few hours, or pull from a mirror/your own registry.

**Fix:** `docker login [registry]`.

<sub>Matches: <code>toomanyrequests &#124; You have reached your pull rate limit &#124; rate limit exceeded.*(docker &#124; registry)</code></sub>

<a id="registry-manifest-unknown"></a>

### `registry_manifest_unknown`

The image tag doesn't exist in the registry.

**Try:** Check the image name and tag (typos, a tag that was never pushed, or a build that didn't push). List tags in your registry or push the image first.

<sub>Matches: <code>manifest unknown &#124; manifest for .* not found &#124; not found: manifest &#124; failed to resolve reference .*: not found</code></sub>

<a id="registry-pull-denied"></a>

### `registry_pull_denied`

The registry refused access to the image — it's private, misspelled, or you're not logged in.

**Try:** Run docker login for that registry, and check the image name. For k8s, make sure an imagePullSecret is set.

**Fix:** `docker login [registry]`.

<sub>Matches: <code>pull access denied &#124; repository does not exist or may require .docker login &#124; unauthorized: authentication required &#124; denied: requested access to the resource is denied &#124; no basic auth credentials</code></sub>

<a id="registry-tls"></a>

### `registry_tls`

A TLS certificate couldn't be verified (self-signed, expired, or a corporate proxy).

**Try:** Install the registry/proxy CA certificate on this machine (and in Docker), or fix the expired certificate. Avoid disabling TLS verification.

<sub>Matches: <code>x509: &#124; certificate signed by unknown authority &#124; certificate has expired &#124; tls: failed to verify certificate &#124; SSL certificate problem</code></sub>

<a id="exec-format"></a>

### `exec_format`

The image or binary was built for a different CPU architecture (for example arm64 vs amd64).

**Try:** Build for the target platform: docker build --platform linux/amd64 (or linux/arm64), or set DOCKER_DEFAULT_PLATFORM. Use docker buildx for multi-arch images.

<sub>Matches: <code>exec format error &#124; image.s platform .* does not match the detected host platform &#124; no matching manifest for .*(linux/arm64 &#124; linux/amd64)</code></sub>

<a id="oom-killed"></a>

### `oom_killed`

The process ran out of memory and was killed (OOMKilled / exit 137).

**Try:** Raise the memory limit (k8s resources.limits.memory, compose mem_limit, docker run --memory) or reduce memory use. For Node, set NODE_OPTIONS=--max-old-space-size.

<sub>Matches: <code>OOMKilled &#124; Out of memory &#124; out of memory: Killed process &#124; JavaScript heap out of memory &#124; exit code 137 &#124; Killed[[:space:]]*$</code></sub>

<a id="k8s-unauthorized"></a>

### `k8s_unauthorized`

kubectl reached the cluster but your credentials were rejected (expired token or missing permissions).

**Try:** Refresh your cluster credentials (e.g. aws eks update-kubeconfig, gcloud container clusters get-credentials, az aks get-credentials) and check RBAC for the namespace.

<sub>Matches: <code>You must be logged in to the server &#124; server has asked for the client to provide credentials &#124; error: Unauthorized &#124; Unauthorized\)?$ &#124; forbidden: User .* cannot</code></sub>

<a id="k8s-context"></a>

### `k8s_context`

kubectl has no usable context — it isn't pointed at any cluster.

**Try:** List contexts with: kubectl config get-contexts, then pick one: kubectl config use-context <name>

<sub>Matches: <code>context .* does not exist &#124; no context exists with the name &#124; current-context is not set &#124; error: no configuration has been provided &#124; The connection to the server localhost:8080 was refused</code></sub>

<a id="k8s-namespace"></a>

### `k8s_namespace`

The Kubernetes namespace doesn't exist.

**Try:** Create it (kubectl create namespace <ns>) or fix the namespace in muster.json (services.<svc>.k8s.namespace).

**Fix:** `kubectl create namespace <ns>`.

<sub>Matches: <code>namespaces? "[^"]+" not found</code></sub>

<a id="k8s-unreachable"></a>

### `k8s_unreachable`

The Kubernetes API server can't be reached.

**Try:** Check your VPN/network, that the cluster is running, and the current context: kubectl config current-context

<sub>Matches: <code>Unable to connect to the server &#124; The connection to the server .* was refused &#124; dial tcp .*:6443 &#124; net/http: TLS handshake timeout</code></sub>

<a id="k8s-image-pull"></a>

### `k8s_image_pull`

Kubernetes can't pull the container image.

**Try:** Check the image name and tag in the deployment, that it was pushed, and imagePullSecrets for private registries. For local clusters with pullPolicy Never, load the image into the cluster.

<sub>Matches: <code>ImagePullBackOff &#124; ErrImagePull &#124; ErrImageNeverPull &#124; InvalidImageName</code></sub>

<a id="k8s-crashloop"></a>

### `k8s_crashloop`

The container starts and then keeps crashing.

**Try:** Read the crash output: kubectl logs <pod> --previous. Common causes: missing env vars, wrong command, or a dependency (DB) that isn't reachable.

<sub>Matches: <code>CrashLoopBackOff &#124; Back-off restarting failed container</code></sub>

<a id="k8s-config-error"></a>

### `k8s_config_error`

A Secret, ConfigMap or PVC the pod needs doesn't exist.

**Try:** Create the missing object in the namespace (kubectl get secret,configmap,pvc -n <ns>) or fix the reference in the manifest.

<sub>Matches: <code>CreateContainerConfigError &#124; secrets? "[^"]+" not found &#124; configmaps? "[^"]+" not found &#124; persistentvolumeclaims? "[^"]+" not found</code></sub>

<a id="k8s-unschedulable"></a>

### `k8s_unschedulable`

No node has enough free CPU/memory (or matching labels) to run the pod.

**Try:** Lower resources.requests, add nodes, or check nodeSelector/taints: kubectl describe pod <pod>

<sub>Matches: <code>Insufficient (cpu &#124; memory) &#124; 0/[0-9]+ nodes are available &#124; FailedScheduling &#124; Unschedulable</code></sub>

<a id="port-in-use"></a>

### `port_in_use`

The port this service wants is already taken by another process or container.

**Try:** Stop whatever holds the port, or change the port the service publishes.

**Fix:** Stop whatever holds the port: `docker stop <container>` or `kill <pid>` (found with docker ps / lsof / ss).

<sub>Matches: <code>port is already allocated &#124; address already in use &#124; EADDRINUSE &#124; Only one usage of each socket address</code></sub>

<a id="npm-lockfile"></a>

### `npm_lockfile`

The install step needs a lockfile that's missing or out of date.

**Try:** Generate/refresh the lockfile locally (npm install, pnpm install or yarn install), commit it, then redeploy.

**Fix:** `npm install --package-lock-only`.

<sub>Matches: <code>can only install (packages &#124; with an existing package-lock) &#124; npm ci.*package-lock &#124; package-lock\.json.*(missing &#124; not in sync &#124; out of sync) &#124; ERR_PNPM_OUTDATED_LOCKFILE &#124; ERR_PNPM_NO_LOCKFILE &#124; Your lockfile needs to be updated &#124; lockfile had changes, but lockfile is frozen</code></sub>

<a id="npm-dependency"></a>

### `npm_dependency`

A JavaScript dependency is missing or the dependency tree can't be resolved.

**Try:** Make sure the package is in package.json (not just installed locally), then run npm install. For ERESOLVE, fix the conflicting peer versions (or use --legacy-peer-deps as a last resort).

<sub>Matches: <code>Cannot find module &#124; ERESOLVE unable to resolve dependency tree &#124; npm ERR! code ERESOLVE &#124; Module not found: Error: Can.t resolve &#124; ERR_MODULE_NOT_FOUND</code></sub>

<a id="pip-failure"></a>

### `pip_failure`

A Python dependency couldn't be installed or imported.

**Try:** Check the package name/version in requirements.txt (or pyproject), install into a virtualenv, and make sure build tools exist for packages that compile.

<sub>Matches: <code>No matching distribution found &#124; ModuleNotFoundError: No module named &#124; Could not find a version that satisfies the requirement &#124; error: externally-managed-environment &#124; Failed building wheel for</code></sub>

<a id="go-build"></a>

### `go_build`

The Go module files are out of date for this build.

**Try:** Run go mod tidy, commit go.mod and go.sum, then redeploy. If a newer Go is required, update the toolchain/base image.

**Fix:** `go mod tidy`.

<sub>Matches: <code>updates to go.mod needed &#124; missing go.sum entry &#124; cannot find module providing package &#124; go: module .* requires go &gt;= &#124; go: inconsistent vendoring</code></sub>

<a id="git-conflict"></a>

### `git_conflict`

git pull couldn't merge cleanly — local commits/changes conflict with the remote.

**Try:** Resolve it by hand: git status, then merge/rebase and commit. muster never discards your local changes.

<sub>Matches: <code>CONFLICT \( &#124; Automatic merge failed &#124; not possible to fast-forward &#124; divergent branches &#124; fatal: Need to specify how to reconcile</code></sub>

<a id="git-dirty"></a>

### `git_dirty`

git pull stopped because uncommitted local changes would be overwritten.

**Try:** Commit or stash them (git stash), pull, then deploy again.

<sub>Matches: <code>Your local changes to the following files would be overwritten &#124; Please commit your changes or stash them &#124; You have unstaged changes &#124; untracked working tree files would be overwritten</code></sub>

<a id="env-missing"></a>

### `env_missing`

A required environment variable isn't set.

**Try:** Add it to the project's .env (muster loads it before every deploy) or export it in your shell/CI.

<sub>Matches: <code>variable is not set\. Defaulting to a blank string &#124; required variable [A-Za-z_][A-Za-z0-9_]* is missing &#124; : unbound variable &#124; environment variable [A-Za-z_][A-Za-z0-9_]* (is )?(not set &#124; required &#124; missing)</code></sub>

<a id="hook-not-executable"></a>

### `hook_not_executable`

A hook script isn't executable.

**Try:** Make it executable: chmod +x .muster/hooks/<service>/*.sh

**Fix:** `chmod +x .muster/hooks/<svc>/*.sh`.

<sub>Matches: <code>\.muster/hooks/[^ ]*: Permission denied &#124; permission denied.*\.muster/hooks</code></sub>

<a id="command-not-found"></a>

### `command_not_found`

A command the hook calls isn't installed (or isn't on PATH).

**Try:** Install the missing tool, or use its full path in the hook.

**Fix:** Install the tool with your package manager (brew, apt-get, dnf, yum, apk or pacman).

<sub>Matches: <code>: command not found &#124; : not found$ &#124; executable file not found in \$PATH</code></sub>

<a id="conn-refused-dep"></a>

### `conn_refused_dep`

The service couldn't reach something it depends on (a database, cache or another service).

**Try:** Make sure infrastructure deploys first (deploy_order in muster.json) and that hosts/ports in your config are right.

**Fix:** Move the dependency before the service in `deploy_order`.

<sub>Matches: <code>ECONNREFUSED &#124; Connection refused &#124; could not connect to server &#124; connection to server at .* failed &#124; Can.t connect to (MySQL &#124; local MySQL) server &#124; Redis connection .* failed &#124; connect: connection refused</code></sub>

<a id="stale-lock"></a>

### `stale_lock`

Another deploy holds the lock, or a crashed deploy left its lock behind.

**Try:** If the owning process is gone, remove the lock (muster doctor --fix) or use muster deploy --force.

**Fix:** Remove the lock left by a process that no longer exists.

<sub>Matches: <code>deploy lock &#124; lock held by &#124; Deploy blocked</code></sub>

<a id="health-wrong-port"></a>

### `health_wrong_port`

The health check targets a port nothing is listening on, but the service is listening on another port.

**Try:** Point the health check at the port the service actually uses (muster settings, or health.port in muster.json).

**Fix:** Point `health.port` at the port the service is listening on.

<sub>Detected by probing the health check after it fails.</sub>

<a id="health-refused"></a>

### `health_refused`

Nothing is listening on the health check port — the service isn't up (yet), or crashed after starting.

**Try:** Check the service logs (muster logs <svc>); if it is just slow to start, raise health.timeout.

<sub>Detected by probing the health check after it fails.</sub>

<a id="health-timeout"></a>

### `health_timeout`

The health endpoint didn't answer before the timeout.

**Try:** The service may still be starting or be overloaded. Raise health.timeout in muster.json, or check the logs.

<sub>Detected by probing the health check after it fails.</sub>

<a id="health-http-5xx"></a>

### `health_http_5xx`

The health endpoint answered with a server error (HTTP 5xx) — the service is up but unhealthy.

**Try:** Check the service logs for the error behind the 5xx (often a database or config problem).

<sub>Detected by probing the health check after it fails.</sub>

<a id="health-http-4xx"></a>

### `health_http_4xx`

The health endpoint answered with HTTP 4xx — the path is probably wrong or needs auth.

**Try:** Fix health.endpoint in muster.json (for example /health or /healthz), or allow unauthenticated access to it.

<sub>Detected by probing the health check after it fails.</sub>

<a id="prod-context"></a>

### `prod_context`

kubectl's current context looks like production, but this project doesn't.

**Try:** Double-check before deploying: kubectl config current-context. Switch with kubectl config use-context <name>.

<sub>Detected by preflight / doctor checks.</sub>

<a id="git-behind"></a>

### `git_behind`

Your branch is behind its upstream — you may be deploying old code.

**Try:** Pull first (git pull), or deploy anyway if that's intended.

**Fix:** `git pull --ff-only`.

<sub>Detected by preflight / doctor checks.</sub>

<a id="hook-missing"></a>

### `hook_missing`

A service has no deploy hook, so there is nothing to run.

**Try:** Re-run muster setup (choose Update to keep your changes) to regenerate missing hooks, or add .muster/hooks/<svc>/deploy.sh yourself.

<sub>Detected by preflight / doctor checks.</sub>

<a id="tool-missing"></a>

### `tool_missing`

A tool this stack needs isn't installed.

**Try:** Install it with your package manager (see the suggested command).

**Fix:** Install the tool with your package manager (brew, apt-get, dnf, yum, apk or pacman).

<sub>Detected by preflight / doctor checks.</sub>

