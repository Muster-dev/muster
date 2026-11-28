#!/usr/bin/env bash
# muster/lib/core/templates.sh — Hook template generation utilities
# Extracted from setup.sh: infra detection, naming, hook copying.

# ── Known infrastructure services (no build step needed) ──
_INFRA_SERVICES="redis postgres postgresql mysql mariadb mongo mongodb meilisearch minio rabbitmq kafka elasticsearch opensearch nginx memcached etcd zookeeper consul vault nats"

# Default images for known infrastructure services
_infra_default_image() {
  case "$1" in
    redis)         echo "redis:7-alpine" ;;
    postgres|postgresql) echo "postgres:16-alpine" ;;
    mysql)         echo "mysql:8" ;;
    mariadb)       echo "mariadb:11" ;;
    mongo|mongodb) echo "mongo:7" ;;
    meilisearch)   echo "getmeili/meilisearch:latest" ;;
    minio)         echo "minio/minio:latest" ;;
    rabbitmq)      echo "rabbitmq:3-management-alpine" ;;
    kafka)         echo "confluentinc/cp-kafka:latest" ;;
    elasticsearch) echo "elasticsearch:8.12.0" ;;
    opensearch)    echo "opensearchproject/opensearch:latest" ;;
    nginx)         echo "nginx:alpine" ;;
    memcached)     echo "memcached:alpine" ;;
    etcd)          echo "quay.io/coreos/etcd:latest" ;;
    zookeeper)     echo "zookeeper:latest" ;;
    consul)        echo "hashicorp/consul:latest" ;;
    vault)         echo "hashicorp/vault:latest" ;;
    nats)          echo "nats:alpine" ;;
    *)             echo "" ;;
  esac
}

# Check if a service name is a known infrastructure service
_is_infra_service() {
  local name="$1"
  local lower
  lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
  local svc
  for svc in $_INFRA_SERVICES; do
    [[ "$lower" == "$svc" ]] && return 0
  done
  return 1
}

# ── Sanitize service name to a config key ──
_svc_to_key() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//'
}

# ── Generate a human-friendly display name from a service key ──
_friendly_name() {
  local raw="$1"

  # Replace hyphens and underscores with spaces
  local spaced
  spaced=$(echo "$raw" | sed 's/[-_]/ /g')

  # Capitalize each word; uppercase known abbreviations
  local result=""
  local word
  for word in $spaced; do
    local lower
    lower=$(echo "$word" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      api|db|mq|ui|io|ci|cd|ssl|tcp|http|dns|ssh|sql|cpu|gpu|cdn|aws|gcp)
        word=$(echo "$lower" | tr '[:lower:]' '[:upper:]')
        ;;
      *)
        # Capitalize first letter
        local first rest
        first=$(echo "$lower" | cut -c1 | tr '[:lower:]' '[:upper:]')
        rest=$(echo "$lower" | cut -c2-)
        word="${first}${rest}"
        ;;
    esac
    if [[ -n "$result" ]]; then
      result="${result} ${word}"
    else
      result="${word}"
    fi
  done

  # Special full-word mappings
  case "$result" in
    "API")           result="API Server" ;;
    "DB"|"Database") result="Database" ;;
    "Redis")         result="Redis" ;;
    "Worker")        result="Worker" ;;
  esac

  echo "$result"
}

# ── Escape a string for use as a sed replacement ──
# Handles: backslash, pipe (our delimiter), ampersand
_escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

# ── Escape a string for embedding inside single quotes ──
# Replaces ' with '\'' (end quote, escaped literal quote, start quote)
_escape_single_quotes() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

# ── Copy template hooks for a service, replacing placeholders ──
# Args: stack svc_key svc_name hook_dir [compose_file] [dockerfile] [k8s_dir] [namespace] [port] [k8s_deploy_name] [start_cmd] [strategy]
# strategy (rolling|blue-green|canary) picks templates/hooks/<stack>/<strategy>/ when it exists.
_setup_copy_hooks() {
  local stack="$1" svc_key="$2" svc_name="$3" hook_dir="$4"
  local compose_path="${5:-docker-compose.yml}"
  local dockerfile_path="${6:-Dockerfile}"
  local k8s_path="${7:-k8s/${svc_name}/}"
  local namespace="${8:-default}"
  local port="${9:-8080}"
  local k8s_deploy_name="${10:-${svc_name}}"
  local start_cmd="${11:-}"
  local strategy="${12:-rolling}"
  local template_dir="${MUSTER_ROOT}/templates/hooks/${stack}"

  # Use infrastructure templates for known infra services (skip build steps)
  local svc_image=""
  if _is_infra_service "$svc_name" && [[ -d "${template_dir}/infra" ]]; then
    template_dir="${template_dir}/infra"
    svc_image=$(_infra_default_image "$svc_name")
  elif [[ "$strategy" != "rolling" && -d "${template_dir}/${strategy}" ]]; then
    template_dir="${template_dir}/${strategy}"
  fi

  if [[ ! -d "$template_dir" ]]; then
    # No templates for this stack, write stub hooks
    _setup_write_stub_hooks "$hook_dir"
    return
  fi

  # Escape all substitution values for safe sed replacement
  local esc_svc_name esc_k8s_deploy esc_svc_image esc_namespace
  local esc_port esc_compose esc_dockerfile esc_k8s_path esc_start_cmd
  esc_svc_name=$(_escape_sed_replacement "$svc_name")
  esc_k8s_deploy=$(_escape_sed_replacement "$k8s_deploy_name")
  esc_svc_image=$(_escape_sed_replacement "$svc_image")
  esc_namespace=$(_escape_sed_replacement "$namespace")
  esc_port=$(_escape_sed_replacement "$port")
  esc_compose=$(_escape_sed_replacement "$compose_path")
  esc_dockerfile=$(_escape_sed_replacement "$dockerfile_path")
  esc_k8s_path=$(_escape_sed_replacement "$k8s_path")
  # START_CMD is embedded in single quotes in templates, so escape single quotes first
  local sq_start_cmd
  sq_start_cmd=$(_escape_single_quotes "$start_cmd")
  esc_start_cmd=$(_escape_sed_replacement "$sq_start_cmd")

  local f
  for f in "${template_dir}"/*.sh; do
    [[ ! -f "$f" ]] && continue
    local basename
    basename=$(basename "$f")
    # Hooks from older versions were locked read-only (555); make them
    # writable again so regeneration doesn't fail with "Permission denied".
    [[ -f "${hook_dir}/${basename}" && ! -w "${hook_dir}/${basename}" ]] && \
      chmod u+w "${hook_dir}/${basename}" 2>/dev/null
    sed \
      -e "s|{{SERVICE_NAME}}|${esc_svc_name}|g" \
      -e "s|{{K8S_DEPLOY_NAME}}|${esc_k8s_deploy}|g" \
      -e "s|{{SERVICE_IMAGE}}|${esc_svc_image}|g" \
      -e "s|{{NAMESPACE}}|${esc_namespace}|g" \
      -e "s|{{PORT}}|${esc_port}|g" \
      -e "s|{{COMPOSE_FILE}}|${esc_compose}|g" \
      -e "s|{{DOCKERFILE}}|${esc_dockerfile}|g" \
      -e "s|{{K8S_DIR}}|${esc_k8s_path}|g" \
      -e "s|{{START_CMD}}|${esc_start_cmd}|g" \
      -e "s|{{STRATEGY}}|${strategy}|g" \
      "$f" > "${hook_dir}/${basename}"
    # Owner-writable so users can edit their own hooks. Edits are caught by
    # the per-machine approval check; `muster hooks lock` makes them read-only.
    chmod 755 "${hook_dir}/${basename}"
  done
}

# ── Copy justfile template for a service, replacing placeholders ──
# Args: svc_key svc_name hook_dir port
_setup_copy_justfile() {
  # shellcheck disable=SC2034
  local svc_key="$1" svc_name="$2" hook_dir="$3" port="${4:-8080}"
  local template="${MUSTER_ROOT}/templates/hooks/just/justfile"

  if [[ ! -f "$template" ]]; then
    # Fallback to stub hooks if template missing
    _setup_write_stub_hooks "$hook_dir"
    return
  fi

  local esc_svc_name esc_port
  esc_svc_name=$(_escape_sed_replacement "$svc_name")
  esc_port=$(_escape_sed_replacement "$port")

  sed \
    -e "s|{{SERVICE_NAME}}|${esc_svc_name}|g" \
    -e "s|{{PORT}}|${esc_port}|g" \
    "$template" > "${hook_dir}/justfile"
}

_setup_write_stub_hooks() {
  local hook_dir="$1"

  cat > "${hook_dir}/deploy.sh" << 'HOOK'
#!/usr/bin/env bash
# Deploy hook — add your deploy commands here
echo "TODO: Add deploy commands"
exit 0
HOOK
  chmod +x "${hook_dir}/deploy.sh"

  cat > "${hook_dir}/health.sh" << 'HOOK'
#!/usr/bin/env bash
# Health check hook — exit 0 if healthy, exit 1 if not
echo "TODO: Add health check"
exit 0
HOOK
  chmod +x "${hook_dir}/health.sh"

  cat > "${hook_dir}/rollback.sh" << 'HOOK'
#!/usr/bin/env bash
# Rollback hook — add your rollback commands here
echo "TODO: Add rollback commands"
exit 0
HOOK
  chmod +x "${hook_dir}/rollback.sh"

  cat > "${hook_dir}/logs.sh" << 'HOOK'
#!/usr/bin/env bash
# Logs hook — stream logs for this service
echo "TODO: Add log streaming"
exit 0
HOOK
  chmod +x "${hook_dir}/logs.sh"

  cat > "${hook_dir}/cleanup.sh" << 'HOOK'
#!/usr/bin/env bash
# Cleanup hook — remove stale resources
echo "TODO: Add cleanup commands"
exit 0
HOOK
  chmod +x "${hook_dir}/cleanup.sh"
}
