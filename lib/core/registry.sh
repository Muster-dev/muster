#!/usr/bin/env bash
# muster/lib/core/registry.sh — Centralized project registry
# Tracks all muster projects on the machine in ~/.muster/projects.json

MUSTER_PROJECTS_FILE="$HOME/.muster/projects.json"

# Ensure projects file exists
_registry_ensure_file() {
  if [[ ! -d "$HOME/.muster" ]]; then
    mkdir -p "$HOME/.muster"
    chmod 700 "$HOME/.muster"
  fi
  if [[ ! -f "$MUSTER_PROJECTS_FILE" ]]; then
    printf '{"projects":[]}\n' > "$MUSTER_PROJECTS_FILE"
  fi
}

# Register or update a project in the registry.
# Called automatically by load_config and setup.
# Usage: _registry_touch "/path/to/project"
_registry_touch() {
  local project_path="$1"
  _registry_ensure_file

  # Require jq
  has_cmd jq || return 0

  # Resolve to absolute path
  local abs_path
  abs_path="$(cd "$project_path" 2>/dev/null && pwd)" || return 0

  # Find config file
  local config_file=""
  [[ -f "${abs_path}/muster.json" ]] && config_file="${abs_path}/muster.json"
  [[ -z "$config_file" && -f "${abs_path}/deploy.json" ]] && config_file="${abs_path}/deploy.json"
  [[ -z "$config_file" ]] && return 0

  # Read project metadata
  local project_name service_count
  project_name=$(jq -r '.project // ""' "$config_file" 2>/dev/null)
  service_count=$(jq '.services | length' "$config_file" 2>/dev/null)
  [[ -z "$service_count" ]] && service_count=0

  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Upsert: update if path exists, insert if new
  local tmp="${MUSTER_PROJECTS_FILE}.tmp"
  jq --arg p "$abs_path" --arg n "$project_name" \
     --argjson sc "$service_count" --arg ts "$now" '
    if (.projects | map(.path) | index($p)) then
      .projects = [.projects[] | if .path == $p then
        .name = $n | .service_count = $sc | .last_accessed = $ts
      else . end]
    else
      .projects += [{"path":$p,"name":$n,"service_count":$sc,"last_accessed":$ts}]
    end
  ' "$MUSTER_PROJECTS_FILE" > "$tmp" && mv "$tmp" "$MUSTER_PROJECTS_FILE"
}

# Remove entries where muster.json/deploy.json no longer exists
_registry_prune() {
  _registry_ensure_file
  has_cmd jq || return 0

  local count
  count=$(jq '.projects | length' "$MUSTER_PROJECTS_FILE" 2>/dev/null)
  [[ -z "$count" || "$count" == "0" ]] && return 0

  local kept="[]"
  local removed=0
  local i=0
  while (( i < count )); do
    local p
    p=$(jq -r ".projects[$i].path" "$MUSTER_PROJECTS_FILE")
    if [[ -f "${p}/muster.json" || -f "${p}/deploy.json" ]]; then
      local entry
      entry=$(jq -c ".projects[$i]" "$MUSTER_PROJECTS_FILE")
      kept=$(printf '%s' "$kept" | jq --argjson e "$entry" '. + [$e]')
    else
      removed=$(( removed + 1 ))
    fi
    i=$(( i + 1 ))
  done

  if (( removed > 0 )); then
    local tmp="${MUSTER_PROJECTS_FILE}.tmp"
    printf '{"projects":%s}\n' "$kept" > "$tmp" && mv "$tmp" "$MUSTER_PROJECTS_FILE"
  fi

  echo "$removed"
}

# List projects as formatted lines (for internal use)
_registry_list() {
  _registry_ensure_file
  has_cmd jq || return 0
  jq -r '.projects[] | "\(.path)\t\(.name)\t\(.service_count)\t\(.last_accessed)"' \
    "$MUSTER_PROJECTS_FILE" 2>/dev/null
}
