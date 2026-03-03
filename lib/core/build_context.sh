#!/usr/bin/env bash
# muster/lib/core/build_context.sh — Build context overlap detection

_BUILD_CONTEXT_CACHE="${HOME}/.muster/.build_context_cache"
_BUILD_CONTEXT_ISSUES=()

# Check if the cache is stale (deploy.json or .dockerignore changed since last run)
# Returns 0 if stale (needs refresh), 1 if fresh
_build_context_cache_stale() {
  [[ ! -f "$_BUILD_CONTEXT_CACHE" ]] && return 0

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local cache_mtime config_mtime ignore_mtime
  cache_mtime=$(stat -f %m "$_BUILD_CONTEXT_CACHE" 2>/dev/null || stat -c %Y "$_BUILD_CONTEXT_CACHE" 2>/dev/null || echo 0)
  config_mtime=$(stat -f %m "$CONFIG_FILE" 2>/dev/null || stat -c %Y "$CONFIG_FILE" 2>/dev/null || echo 0)

  # Config changed since cache
  if (( config_mtime > cache_mtime )); then
    return 0
  fi

  # .dockerignore changed since cache
  if [[ -f "${project_dir}/.dockerignore" ]]; then
    ignore_mtime=$(stat -f %m "${project_dir}/.dockerignore" 2>/dev/null || stat -c %Y "${project_dir}/.dockerignore" 2>/dev/null || echo 0)
    if (( ignore_mtime > cache_mtime )); then
      return 0
    fi
  fi

  return 1
}

# Read cached issues into _BUILD_CONTEXT_ISSUES array
# Returns 0 if issues found, 1 if clean or no cache
_build_context_read_cache() {
  _BUILD_CONTEXT_ISSUES=()
  [[ ! -f "$_BUILD_CONTEXT_CACHE" ]] && return 1

  local _line
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _BUILD_CONTEXT_ISSUES[${#_BUILD_CONTEXT_ISSUES[@]}]="$_line"
  done < "$_BUILD_CONTEXT_CACHE"

  (( ${#_BUILD_CONTEXT_ISSUES[@]} > 0 )) && return 0
  return 1
}

# Extract build context path from a deploy hook script
# Looks for: docker build ... <context_path> (last arg on the docker build line)
_build_context_from_hook() {
  local hook_file="$1"
  [[ ! -f "$hook_file" ]] && return

  # Look for docker build commands
  local _line
  while IFS= read -r _line; do
    # Match lines with "docker build" (skip comments)
    case "$_line" in
      \#*) continue ;;
      *docker\ build*)
        # Extract the last argument (build context) — handle line continuations
        # Simple case: docker build -t ... -f ... <context>
        local _ctx
        _ctx=$(printf '%s' "$_line" | sed 's/\\$//' | awk '{print $NF}')
        # Skip if it looks like a flag value
        case "$_ctx" in
          -*) _ctx="." ;;
        esac
        printf '%s' "$_ctx"
        return
        ;;
    esac
  done < "$hook_file"
}

# Check if a directory is excluded in .dockerignore
# Args: $1 = project_dir, $2 = relative directory to check
_build_context_in_dockerignore() {
  local project_dir="$1" check_dir="$2"
  local ignore_file="${project_dir}/.dockerignore"
  [[ ! -f "$ignore_file" ]] && return 1

  # Strip trailing slash for matching
  check_dir="${check_dir%/}"

  local _pattern
  while IFS= read -r _pattern; do
    [[ -z "$_pattern" ]] && continue
    # Skip comments
    case "$_pattern" in
      \#*) continue ;;
    esac
    # Strip trailing slash from pattern too
    _pattern="${_pattern%/}"
    # Direct match: "dashboard" matches "dashboard"
    if [[ "$check_dir" == "$_pattern" ]]; then
      return 0
    fi
    # Wildcard prefix match: "**/dashboard" or "dashboard/**"
    case "$check_dir" in
      $_pattern) return 0 ;;
    esac
  done < "$ignore_file"

  return 1
}

# Main detection: find overlapping build contexts
# Writes results to cache file. Each line: parent_svc|child_svc|parent_context|child_dir
_build_context_detect() {
  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local hooks_dir="${project_dir}/.muster/hooks"

  mkdir -p "$(dirname "$_BUILD_CONTEXT_CACHE")"
  : > "$_BUILD_CONTEXT_CACHE"
  _BUILD_CONTEXT_ISSUES=()

  [[ ! -d "$hooks_dir" ]] && return

  # Collect services that use docker build and their contexts
  local _svc_keys=()
  local _svc_contexts=()
  local _svc_dockerfiles=()
  local services
  services=$(config_services)

  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local deploy_hook="${hooks_dir}/${svc}/deploy.sh"
    [[ ! -f "$deploy_hook" ]] && continue

    # Only check services that run docker build
    if ! grep -q 'docker build' "$deploy_hook" 2>/dev/null; then
      continue
    fi

    local ctx
    ctx=$(_build_context_from_hook "$deploy_hook")
    [[ -z "$ctx" ]] && ctx="."

    # Resolve to absolute path
    local abs_ctx
    if [[ "$ctx" == /* ]]; then
      abs_ctx="$ctx"
    else
      abs_ctx="${project_dir}/${ctx}"
    fi
    # Normalize (remove trailing slash, resolve . and ..)
    abs_ctx=$(cd "$abs_ctx" 2>/dev/null && pwd || echo "$abs_ctx")

    # Extract dockerfile path from hook to infer service source dir
    local _df_path=""
    _df_path=$(grep -o '\-f "[^"]*"' "$deploy_hook" 2>/dev/null | head -1 | sed 's/-f "//;s/"$//')
    if [[ -z "$_df_path" ]]; then
      _df_path=$(grep -o "\-f '[^']*'" "$deploy_hook" 2>/dev/null | head -1 | sed "s/-f '//;s/'$//")
    fi
    if [[ -z "$_df_path" ]]; then
      _df_path=$(grep 'docker build' "$deploy_hook" 2>/dev/null | grep -o '\-f [^ ]*' | head -1 | sed 's/-f //')
    fi

    _svc_keys[${#_svc_keys[@]}]="$svc"
    _svc_contexts[${#_svc_contexts[@]}]="$abs_ctx"
    _svc_dockerfiles[${#_svc_dockerfiles[@]}]="${_df_path:-Dockerfile}"
  done <<< "$services"

  local count=${#_svc_keys[@]}
  (( count < 2 )) && return

  # For each pair, check if one context contains the other service's inferred directory
  local _i=0
  while (( _i < count )); do
    local _j=0
    while (( _j < count )); do
      if (( _i != _j )); then
        local parent_ctx="${_svc_contexts[$_i]}"
        local child_svc="${_svc_keys[$_j]}"
        local child_df="${_svc_dockerfiles[$_j]}"

        # Infer child's source directory from its Dockerfile path
        local child_dir=""
        local child_df_dir
        child_df_dir=$(dirname "$child_df")
        if [[ "$child_df_dir" != "." ]]; then
          child_dir="$child_df_dir"
        else
          # If Dockerfile is like Dockerfile.api (at root), no separate dir
          # Check if a directory named after the service exists
          if [[ -d "${project_dir}/${child_svc}" ]]; then
            child_dir="$child_svc"
          fi
        fi

        # Skip if no distinct child directory to check
        [[ -z "$child_dir" ]] && continue

        local abs_child
        abs_child="${project_dir}/${child_dir}"
        abs_child=$(cd "$abs_child" 2>/dev/null && pwd || echo "$abs_child")

        # Check containment: parent context contains child directory
        case "$abs_child" in
          "${parent_ctx}"|"${parent_ctx}"/*)
            # It's contained — check .dockerignore
            local rel_child="${child_dir}"
            if ! _build_context_in_dockerignore "$project_dir" "$rel_child"; then
              local rel_ctx="${parent_ctx#$project_dir}"
              [[ -z "$rel_ctx" ]] && rel_ctx="."
              rel_ctx="${rel_ctx#/}"
              [[ -z "$rel_ctx" ]] && rel_ctx="."

              local issue_line="${_svc_keys[$_i]}|${child_svc}|${rel_ctx}|${child_dir}"
              _BUILD_CONTEXT_ISSUES[${#_BUILD_CONTEXT_ISSUES[@]}]="$issue_line"
              printf '%s\n' "$issue_line" >> "$_BUILD_CONTEXT_CACHE"
            fi
            ;;
        esac
      fi
      _j=$(( _j + 1 ))
    done
    _i=$(( _i + 1 ))
  done
}

# Print a human-readable warning for cached issues
# Used by deploy and --minimal mode
_build_context_warn() {
  if _build_context_read_cache; then
    local count=${#_BUILD_CONTEXT_ISSUES[@]}
    printf '%b\n' "  ${YELLOW}!${RESET} Build context overlap detected — ${count} issue$( (( count > 1 )) && echo s)"
    printf '%b\n' "    ${DIM}Run 'muster doctor' for details${RESET}"
  fi
}

# Print minimal-mode warning to stderr (comment-style)
_build_context_warn_minimal() {
  if _build_context_read_cache; then
    local _issue
    local _i=0
    while (( _i < ${#_BUILD_CONTEXT_ISSUES[@]} )); do
      _issue="${_BUILD_CONTEXT_ISSUES[$_i]}"
      local _parent _child _ctx _dir
      IFS='|' read -r _parent _child _ctx _dir <<< "$_issue"
      printf '# warning: build context overlap — %s context (%s) contains %s directory (%s)\n' \
        "$_parent" "$_ctx" "$_child" "$_dir" >&2
      _i=$(( _i + 1 ))
    done
    printf '# warning: run '\''muster doctor'\'' for details\n' >&2
  fi
}
