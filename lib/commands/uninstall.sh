#!/usr/bin/env bash
# muster/lib/commands/uninstall.sh — Remove muster from a project or the system

source "$MUSTER_ROOT/lib/tui/menu.sh"

cmd_uninstall() {
  case "${1:-}" in
    --help|-h)
      echo "Usage: muster uninstall [--system]"
      echo ""
      echo "Remove muster configuration from the current project."
      echo "Deletes muster.json (or deploy.json) and .muster/ directory."
      echo ""
      echo "Flags:"
      echo "  --system    Uninstall muster itself from this machine"
      echo "  -h, --help  Show this help"
      return 0
      ;;
    --system)
      _uninstall_system
      return $?
      ;;
    --*)
      err "Unknown flag: $1"
      echo "Run 'muster uninstall --help' for usage."
      return 1
      ;;
  esac

  # Check if we're inside a project
  local _cfg
  _cfg=$(find_config 2>/dev/null) || true
  if [[ -z "$_cfg" ]]; then
    echo ""
    echo "  Not inside a muster project."
    echo ""
    echo "  To uninstall muster from this machine:"
    echo "    muster uninstall --system"
    echo ""
    return 1
  fi

  muster_tui_fullscreen
  load_config

  local project_dir
  project_dir="$(dirname "$CONFIG_FILE")"
  local project
  project=$(config_get '.project')
  local muster_dir="${project_dir}/.muster"

  echo ""
  printf '%b\n' "  ${BOLD}Uninstall muster from ${project}${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}This will remove:${RESET}"
  printf '    %b•%b %s\n' "${RED}" "${RESET}" "${CONFIG_FILE}"
  [[ -d "$muster_dir" ]] && printf '    %b•%b %s\n' "${RED}" "${RESET}" "${muster_dir}/"
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
  printf '%b\n' "  ${DIM}Run 'muster setup' to set up again${RESET}"
  echo ""
}

# Remove muster PATH entries from shell profiles
_uninstall_clean_path() {
  local bin_dir="$1"
  local _profile _tmp _cleaned

  for _profile in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [[ -f "$_profile" ]] || continue
    if grep -q "$bin_dir" "$_profile" 2>/dev/null; then
      _tmp="${_profile}.muster-tmp"
      # Remove the PATH export line and the comment above it
      grep -v "# Added by muster installer" "$_profile" \
        | grep -v "# Muster Fleet Cloud" \
        | grep -v "$bin_dir" > "$_tmp"
      mv "$_tmp" "$_profile"
      ok "Cleaned PATH from ${_profile}"
    fi
  done
}

# Remove from PATH only — keep all files
_uninstall_path_only() {
  local bin_dir="$1"
  _uninstall_clean_path "$bin_dir"
  echo ""
  ok "Removed muster from PATH."
  printf '%b\n' "  ${DIM}Files kept in ${MUSTER_INSTALL_DIR:-$HOME/.muster}/${RESET}"
  printf '%b\n' "  ${DIM}Binaries kept in ${bin_dir}/${RESET}"
  printf '%b\n' "  ${DIM}To fully remove: muster uninstall --system${RESET}"
  echo ""
}

_uninstall_system() {
  muster_tui_fullscreen
  local install_dir="${MUSTER_INSTALL_DIR:-$HOME/.muster}"
  local bin_dir="${MUSTER_BIN_DIR:-$HOME/.local/bin}"

  echo ""
  printf '%b\n' "  ${BOLD}${RED}Uninstall muster from this machine${RESET}"
  echo ""
  printf '%b\n' "  ${DIM}This will remove:${RESET}"
  [[ -d "$install_dir" ]] && printf '    %b•%b %s\n' "${RED}" "${RESET}" "${install_dir}/  (repo, settings, tokens, skills)"
  [[ -L "${bin_dir}/muster" || -f "${bin_dir}/muster" ]] && printf '    %b•%b %s\n' "${RED}" "${RESET}" "${bin_dir}/muster"
  [[ -L "${bin_dir}/muster-mcp" || -f "${bin_dir}/muster-mcp" ]] && printf '    %b•%b %s\n' "${RED}" "${RESET}" "${bin_dir}/muster-mcp"
  [[ -L "${bin_dir}/muster-tui" || -f "${bin_dir}/muster-tui" ]] && printf '    %b•%b %s\n' "${RED}" "${RESET}" "${bin_dir}/muster-tui"
  [[ -f "${bin_dir}/muster-tunnel" ]] && printf '    %b•%b %s\n' "${RED}" "${RESET}" "${bin_dir}/muster-tunnel"
  [[ -f "${bin_dir}/muster-agent" ]] && printf '    %b•%b %s\n' "${RED}" "${RESET}" "${bin_dir}/muster-agent"
  [[ -f "${bin_dir}/muster-cloud" ]] && printf '    %b•%b %s\n' "${RED}" "${RESET}" "${bin_dir}/muster-cloud"
  echo ""
  printf '%b\n' "  ${DIM}Project configs (.muster/ in your projects) will NOT be removed.${RESET}"
  echo ""

  menu_select "What would you like to do?" \
    "Cancel — keep everything" \
    "Remove from PATH only — keep files for later" \
    "Remove everything — delete all muster files"

  case "$MENU_RESULT" in
    *"Cancel"*)
      info "Cancelled"
      echo ""
      return 0
      ;;
    *"Remove from PATH only"*)
      _uninstall_path_only "$bin_dir"
      ;;
    *"Remove everything"*)
      # Remove binaries/symlinks
      rm -f "${bin_dir}/muster" "${bin_dir}/muster-mcp" "${bin_dir}/muster-tui" \
        "${bin_dir}/muster-tunnel" "${bin_dir}/muster-agent" "${bin_dir}/muster-cloud" 2>/dev/null
      ok "Removed binaries"

      # Remove install directory
      if [[ -d "$install_dir" ]]; then
        rm -rf "$install_dir"
        ok "Removed ${install_dir}/"
      fi

      # Clean PATH from shell profiles
      _uninstall_clean_path "$bin_dir"

      echo ""
      ok "muster has been uninstalled."
      printf '%b\n' "  ${DIM}To reinstall: curl -fsSL https://getmuster.dev/install.sh | bash${RESET}"
      echo ""
      ;;
  esac
}
