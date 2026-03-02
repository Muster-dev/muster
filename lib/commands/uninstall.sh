#!/usr/bin/env bash
# muster/lib/commands/uninstall.sh — Remove muster from a project

source "$MUSTER_ROOT/lib/tui/menu.sh"

cmd_uninstall() {
  case "${1:-}" in
    --help|-h)
      echo "Usage: muster uninstall"
      echo ""
      echo "Remove muster configuration from the current project."
      echo "Deletes muster.json (or deploy.json) and .muster/ directory."
      return 0
      ;;
    --*)
      err "Unknown flag: $1"
      echo "Run 'muster uninstall --help' for usage."
      return 1
      ;;
  esac

  load_config

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local project
  project=$(config_get '.project')
  local muster_dir="${project_dir}/.muster"

  echo ""
  echo -e "  ${BOLD}Uninstall muster from ${project}${RESET}"
  echo ""
  echo -e "  ${DIM}This will remove:${RESET}"
  echo -e "    ${RED}*${RESET} ${CONFIG_FILE}"
  [[ -d "$muster_dir" ]] && echo -e "    ${RED}*${RESET} ${muster_dir}/"
  echo ""

  menu_select "Are you sure?" "No, keep everything" "Yes, remove muster from this project"

  if [[ "$MENU_RESULT" != "Yes, remove muster from this project" ]]; then
    info "Cancelled"
    echo ""
    return 0
  fi

  # Remove deploy.json
  if [[ -f "$CONFIG_FILE" ]]; then
    rm -f "$CONFIG_FILE"
    ok "Removed ${CONFIG_FILE}"
  fi

  # Remove .muster directory
  if [[ -d "$muster_dir" ]]; then
    rm -rf "$muster_dir"
    ok "Removed ${muster_dir}/"
  fi

  # Clean .gitignore entry
  local gitignore="${project_dir}/.gitignore"
  if [[ -f "$gitignore" ]] && grep -q '.muster/logs' "$gitignore"; then
    local tmp
    tmp=$(grep -v '.muster/logs' "$gitignore")
    if [[ -n "$tmp" ]]; then
      echo "$tmp" > "$gitignore"
    else
      rm -f "$gitignore"
    fi
    ok "Cleaned .gitignore"
  fi

  echo ""
  ok "muster removed from ${project_dir}"
  echo -e "  ${DIM}Run 'muster setup' to set up again${RESET}"
  echo ""
}
