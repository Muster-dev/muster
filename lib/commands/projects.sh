#!/usr/bin/env bash
# muster/lib/commands/projects.sh — List and manage registered projects

source "$MUSTER_ROOT/lib/core/registry.sh"

cmd_projects() {
  local _json_mode=false
  local _prune=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: muster projects [flags]"
        echo ""
        echo "List all muster projects registered on this machine."
        echo ""
        echo "Flags:"
        echo "  --json          Output as JSON"
        echo "  --prune         Remove stale entries (missing muster.json)"
        echo "  -h, --help      Show this help"
        return 0
        ;;
      --json) _json_mode=true; shift ;;
      --prune) _prune=true; shift ;;
      --*)
        err "Unknown flag: $1"
        echo "Run 'muster projects --help' for usage."
        return 1
        ;;
      *)
        err "Unknown argument: $1"
        return 1
        ;;
    esac
  done

  # Auth gate: JSON mode requires valid token
  if [[ "$_json_mode" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
  fi

  # Handle prune
  if [[ "$_prune" == "true" ]]; then
    local removed
    removed=$(_registry_prune)
    if [[ "$_json_mode" == "true" ]]; then
      printf '{"pruned":%s}\n' "${removed:-0}"
    else
      if [[ "${removed:-0}" -gt 0 ]]; then
        ok "Pruned ${removed} stale project(s)."
      else
        info "No stale projects found."
      fi
    fi
    return 0
  fi

  _registry_ensure_file

  if ! has_cmd jq; then
    err "jq is required for the projects command."
    return 1
  fi

  # JSON output
  if [[ "$_json_mode" == "true" ]]; then
    jq '.' "$MUSTER_PROJECTS_FILE"
    return 0
  fi

  # TUI output
  local count
  count=$(jq '.projects | length' "$MUSTER_PROJECTS_FILE" 2>/dev/null)
  [[ -z "$count" ]] && count=0

  echo ""
  echo -e "  ${BOLD}${ACCENT_BRIGHT}Registered Projects${RESET}"
  echo ""

  if (( count == 0 )); then
    echo -e "  ${DIM}No projects registered yet.${RESET}"
    echo -e "  ${DIM}Run 'muster setup' or any command in a project directory.${RESET}"
    echo ""
    return 0
  fi

  # Table header
  printf "  ${BOLD}%-20s  %-40s  %-5s  %-20s${RESET}\n" "NAME" "PATH" "SVCS" "LAST ACCESSED"
  printf "  ${DIM}%-20s  %-40s  %-5s  %-20s${RESET}\n" "--------------------" "----------------------------------------" "-----" "--------------------"

  local i=0
  while (( i < count )); do
    local name path svc_count last_accessed
    name=$(jq -r ".projects[$i].name" "$MUSTER_PROJECTS_FILE")
    path=$(jq -r ".projects[$i].path" "$MUSTER_PROJECTS_FILE")
    svc_count=$(jq -r ".projects[$i].service_count" "$MUSTER_PROJECTS_FILE")
    last_accessed=$(jq -r ".projects[$i].last_accessed" "$MUSTER_PROJECTS_FILE")

    # Truncate path if too long
    if (( ${#path} > 40 )); then
      path="...${path: -37}"
    fi

    # Format timestamp (remove T and Z)
    last_accessed="${last_accessed//T/ }"
    last_accessed="${last_accessed//Z/}"

    printf "  %-20s  %-40s  %-5s  ${DIM}%-20s${RESET}\n" "$name" "$path" "$svc_count" "$last_accessed"
    i=$(( i + 1 ))
  done

  echo ""
  echo -e "  ${DIM}${count} project(s) registered. Use --prune to remove stale entries.${RESET}"
  echo ""
}
