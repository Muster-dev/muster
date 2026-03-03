#!/usr/bin/env bash
# muster/lib/commands/diff.sh — Show what changed since last deploy

cmd_diff() {
  load_config

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"

  if ! _git_is_repo; then
    err "Not a git repository — diffs require git"
    return 1
  fi

  local target="${1:-all}"
  local current_sha
  current_sha=$(_git_current_sha)

  if [[ "$target" != "all" ]]; then
    # Single service
    local prev_sha
    prev_sha=$(_git_prev_deploy_sha "$target")
    local name
    name=$(config_get ".services.${target}.name")
    [[ -z "$name" || "$name" == "null" ]] && name="$target"

    if [[ -z "$prev_sha" ]]; then
      echo ""
      printf '%b\n' "  ${BOLD}${name}${RESET}  ${DIM}no previous deploy recorded${RESET}"
      echo ""
    else
      echo ""
      printf '%b\n' "  ${BOLD}${name}${RESET}  ${DIM}${prev_sha} → ${current_sha}${RESET}"
      _git_deploy_diff "$prev_sha" "$current_sha"
      echo ""
    fi
    return 0
  fi

  # All services
  local services=""
  services=$(config_get '.deploy_order[]' 2>/dev/null || config_services)
  local found=false

  echo ""
  printf '%b\n' "  ${BOLD}${ACCENT_BRIGHT}Deploy diffs${RESET}  ${DIM}(HEAD: ${current_sha})${RESET}"
  echo ""

  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local skip
    skip=$(config_get ".services.${svc}.skip_deploy")
    [[ "$skip" == "true" ]] && continue

    local prev_sha
    prev_sha=$(_git_prev_deploy_sha "$svc")
    local name
    name=$(config_get ".services.${svc}.name")
    [[ -z "$name" || "$name" == "null" ]] && name="$svc"

    if [[ -z "$prev_sha" ]]; then
      printf '%b\n' "  ${BOLD}${name}${RESET}  ${DIM}no previous deploy${RESET}"
    elif [[ "$prev_sha" == "$current_sha" ]]; then
      printf '%b\n' "  ${BOLD}${name}${RESET}  ${GREEN}up to date${RESET}"
    else
      printf '%b\n' "  ${BOLD}${name}${RESET}  ${DIM}${prev_sha} → ${current_sha}${RESET}"
      _git_deploy_diff "$prev_sha" "$current_sha"
      found=true
    fi
    echo ""
  done <<< "$services"

  if [[ "$found" == "false" ]]; then
    printf '%b\n' "  ${DIM}All services are up to date (or no previous deploys recorded).${RESET}"
    echo ""
  fi
}
