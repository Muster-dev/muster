#!/usr/bin/env bash
# muster installer — bash <(curl -fsSL https://getmuster.dev/install.sh)
set -euo pipefail

REPO="Muster-dev/muster"
REPO_OLD="ImJustRicky/muster"
INSTALL_DIR="${MUSTER_INSTALL_DIR:-$HOME/.muster}"
BIN_DIR="${MUSTER_BIN_DIR:-$HOME/.local/bin}"
MANIFEST="${INSTALL_DIR}/install.json"

# ── Colors (inline — installer is standalone) ──
_B='\033[1m'
_D='\033[2m'
_R='\033[0m'
_M='\033[38;5;178m'    # mustard (brand)
_MB='\033[38;5;220m'   # mustard bright
_G='\033[38;5;114m'    # green
_RD='\033[38;5;203m'   # red
_Y='\033[38;5;221m'    # yellow
_GR='\033[38;5;243m'   # gray
_W='\033[38;5;255m'    # white
# Disable colors if not a terminal
if [[ ! -t 1 ]]; then
  _B="" _D="" _R="" _M="" _MB="" _G="" _RD="" _Y="" _GR="" _W=""
fi

# When piped (curl | bash), stdin is the script itself, not the terminal.
# We can't `exec </dev/tty` because bash is still reading the script from fd 0.
# Instead, we redirect individual `read` commands from /dev/tty.
# /dev/tty exists in CI and cloud-init but can't be opened there, so test
# that it actually opens. MUSTER_YES=1 forces a non-interactive install.
_interactive=false
if [[ -z "${MUSTER_YES:-}" ]] && { : </dev/tty; } 2>/dev/null; then
  _interactive=true
fi

# Track what gets installed for summary
_summary_items=()

_hr() {
  printf '  %b%s%b\n' "$_GR" "$(printf '%*s' 38 '' | sed 's/ /─/g')" "$_R"
}

_step() {
  printf '\n  %b[%s]%b %b%s%b\n' "$_M" "$1" "$_R" "$_W" "$2" "$_R"
}

# ── Banner ──
echo ""
printf '  %b┌──────────────────────────────────────┐%b\n' "$_MB" "$_R"
printf '  %b│%b  %b%bmuster%b %b— universal deploy framework %b│%b\n' "$_MB" "$_R" "$_B" "$_W" "$_R" "$_D" "$_MB" "$_R"
printf '  %b└──────────────────────────────────────┘%b\n' "$_MB" "$_R"

# ═══════════════════════════════════════════════
# Preview: show what will be installed and where
# ═══════════════════════════════════════════════
echo ""
printf '  %bThis will install:%b\n' "$_B" "$_R"
echo ""
printf '  %b  Files:%b\n' "$_W" "$_R"
printf '    %b%s/repo/%b         %b← muster source (git clone)%b\n' "$_M" "$INSTALL_DIR" "$_R" "$_D" "$_R"
printf '    %b%s/settings.json%b  %b← global settings%b\n' "$_M" "$INSTALL_DIR" "$_R" "$_D" "$_R"
printf '    %b%s/install.json%b   %b← install manifest%b\n' "$_M" "$INSTALL_DIR" "$_R" "$_D" "$_R"
echo ""
printf '  %b  Binaries:%b\n' "$_W" "$_R"
printf '    %b%s/muster%b         %b← main CLI (symlink)%b\n' "$_M" "$BIN_DIR" "$_R" "$_D" "$_R"
printf '    %b%s/muster-mcp%b     %b← MCP transport (symlink)%b\n' "$_M" "$BIN_DIR" "$_R" "$_D" "$_R"
echo ""
printf '  %b  Optional:%b\n' "$_W" "$_R"
printf '    %b%s/muster-tui%b     %b← TUI frontend (if chosen)%b\n' "$_M" "$BIN_DIR" "$_R" "$_D" "$_R"
printf '    %b%s/muster-tunnel%b  %b← cloud transport (if chosen)%b\n' "$_M" "$BIN_DIR" "$_R" "$_D" "$_R"
printf '    %b%s/muster-agent%b   %b← cloud agent (if chosen)%b\n' "$_M" "$BIN_DIR" "$_R" "$_D" "$_R"
echo ""

if [[ "$_interactive" = true ]]; then
  printf '  %bProceed with install? [Y/n]%b ' "$_M" "$_R"
  read -r _proceed </dev/tty
  case "${_proceed:-Y}" in
    [Yy]|"")
      ;;
    *)
      printf '\n  %bInstall cancelled.%b\n\n' "$_D" "$_R"
      exit 0
      ;;
  esac
fi

# Ensure install dir has secure permissions
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"

# ═══════════════════════════════════════════════
# Step 1: Install core
# ═══════════════════════════════════════════════
_step "1/4" "Installing muster core"

# Fetch latest release tag
_latest_tag=""
if command -v curl >/dev/null 2>&1; then
  _latest_tag="$(curl -fsSL --max-time 10 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/".*//')"
fi

_fresh_install=true
if [[ -d "${INSTALL_DIR}/repo" ]]; then
  _fresh_install=false
  printf '  %bUpdating existing installation...%b\n' "$_D" "$_R"
  # Migrate remote URL to new org if still pointing to old
  _cur_remote="$(cd "${INSTALL_DIR}/repo" && git remote get-url origin 2>/dev/null || true)"
  if [[ "$_cur_remote" == *"ImJustRicky/muster"* ]]; then
    (cd "${INSTALL_DIR}/repo" && git remote set-url origin "https://github.com/${REPO}.git" 2>/dev/null) || true
  fi
  if [[ -n "$_latest_tag" ]]; then
    printf '  %bUpdating to release %b%s%b%b...%b\n' "$_D" "$_R$_W" "$_latest_tag" "$_R" "$_D" "$_R"
    (cd "${INSTALL_DIR}/repo" && git fetch --quiet --tags origin 2>/dev/null && git checkout --quiet "$_latest_tag" 2>/dev/null)
  else
    printf '  %b!%b Could not determine latest release, pulling latest source.\n' "$_Y" "$_R"
    (cd "${INSTALL_DIR}/repo" && git pull --quiet)
  fi
else
  if [[ -n "$_latest_tag" ]]; then
    printf '  %bDownloading muster %b%s%b%b...%b\n' "$_D" "$_R$_W" "$_latest_tag" "$_R" "$_D" "$_R"
  else
    printf '  %bDownloading muster...%b\n' "$_D" "$_R"
  fi
  if ! git clone --quiet "https://github.com/${REPO}.git" "${INSTALL_DIR}/repo" 2>/dev/null; then
    git clone --quiet "https://github.com/${REPO_OLD}.git" "${INSTALL_DIR}/repo"
  fi
  if [[ -n "$_latest_tag" ]]; then
    (cd "${INSTALL_DIR}/repo" && git fetch --quiet --tags origin 2>/dev/null && git checkout --quiet "$_latest_tag" 2>/dev/null)
  else
    printf '  %b!%b Could not determine latest release, installing from source.\n' "$_Y" "$_R"
  fi
fi

mkdir -p "$BIN_DIR"

# Link binaries
chmod +x "${INSTALL_DIR}/repo/bin/muster" "${INSTALL_DIR}/repo/bin/muster-mcp"
ln -sf "${INSTALL_DIR}/repo/bin/muster" "${BIN_DIR}/muster"
ln -sf "${INSTALL_DIR}/repo/bin/muster-mcp" "${BIN_DIR}/muster-mcp"

# Generate file integrity manifest (snapshot of trusted code from official source)
if [[ -f "${INSTALL_DIR}/repo/lib/core/app_verify.sh" ]]; then
  if (cd "${INSTALL_DIR}/repo" && bash -c 'export MUSTER_ROOT=. && source lib/core/app_verify.sh && _app_manifest_generate') 2>/dev/null; then
    printf '  %b✓%b File integrity manifest generated\n' "$_G" "$_R"
    # Sign if payload keys exist
    if [[ -f "$HOME/.muster/fleet/keys/payload.key.pem" ]]; then
      (cd "${INSTALL_DIR}/repo" && bash -c 'export MUSTER_ROOT=. && source lib/core/colors.sh && source lib/core/logger.sh && source lib/core/payload_sign.sh && source lib/core/app_verify.sh && _app_manifest_sign') 2>/dev/null \
        && printf '  %b✓%b Manifest signed\n' "$_G" "$_R"
    fi
  fi
fi

# Smoke test
_ver=""
if "${BIN_DIR}/muster" --version >/dev/null 2>&1; then
  _ver="$("${BIN_DIR}/muster" --version 2>/dev/null || true)"
  printf '  %b✓%b muster %b%s%b\n' "$_G" "$_R" "$_D" "$_ver" "$_R"
  _summary_items[${#_summary_items[@]}]="muster ${_ver}"
else
  printf '  %b!%b muster installed but failed to run.%b\n' "$_Y" "$_R" "$_R"
  printf '  %bTry: %s/muster --version%b\n' "$_D" "$BIN_DIR" "$_R"
  _summary_items[${#_summary_items[@]}]="muster (failed smoke test)"
fi

# ── Install manifest ──
_now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
_write_manifest() {
  local component="$1" version="$2" bin_path="$3"
  if [[ -f "$MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
    local tmp="${MANIFEST}.tmp"
    jq --arg c "$component" --arg v "$version" --arg b "$bin_path" --arg t "$_now" \
      '.components[$c] = {"version":$v,"bin":$b,"installed":$t}' \
      "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
  elif command -v jq >/dev/null 2>&1; then
    printf '{"components":{"%s":{"version":"%s","bin":"%s","installed":"%s"}}}\n' \
      "$component" "$version" "$bin_path" "$_now" > "$MANIFEST"
  fi
  [[ -f "$MANIFEST" ]] && chmod 600 "$MANIFEST"
}

_write_manifest "muster" "${_ver:-unknown}" "${BIN_DIR}/muster"

# Set update_mode to release so future updates use the release channel
_settings_file="${INSTALL_DIR}/settings.json"
if command -v jq >/dev/null 2>&1; then
  if [[ -f "$_settings_file" ]]; then
    _tmp="${_settings_file}.tmp"
    jq '.update_mode = "release"' "$_settings_file" > "$_tmp" 2>/dev/null && mv "$_tmp" "$_settings_file"
  else
    printf '{"update_mode":"release","update_check":"on","color_mode":"auto"}\n' > "$_settings_file"
  fi
fi

# ═══════════════════════════════════════════════
# Step 2: PATH
# ═══════════════════════════════════════════════
_needs_path=false
if ! command -v muster >/dev/null 2>&1; then
  _needs_path=true
fi

if [[ "$_needs_path" = true ]]; then
  _step "2/4" "Configuring PATH"
  printf '  %b%s is not in your PATH.%b\n' "$_D" "$BIN_DIR" "$_R"

  _shell_profile=""
  case "${SHELL:-}" in
    */zsh)  _shell_profile="$HOME/.zshrc" ;;
    */bash) _shell_profile="$HOME/.bashrc" ;;
  esac
  if [[ -z "$_shell_profile" ]]; then
    if [[ -f "$HOME/.zshrc" ]]; then
      _shell_profile="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
      _shell_profile="$HOME/.bashrc"
    elif [[ -f "$HOME/.profile" ]]; then
      _shell_profile="$HOME/.profile"
    fi
  fi

  _export_line="export PATH=\"\$HOME/.local/bin:\$PATH\""
  _added=false

  if [[ -n "$_shell_profile" && "$_interactive" = true ]]; then
    printf '  Add to %b%s%b? [Y/n] ' "$_W" "$_shell_profile" "$_R"
    read -r _answer </dev/tty
    case "${_answer:-Y}" in
      [Yy]|"")
        echo "" >> "$_shell_profile"
        echo "# Added by muster installer" >> "$_shell_profile"
        echo "$_export_line" >> "$_shell_profile"
        printf '  %b✓%b Added. Run: %bsource %s%b\n' "$_G" "$_R" "$_D" "$_shell_profile" "$_R"
        _added=true
        ;;
    esac
  fi

  if [[ "$_added" = false ]]; then
    printf '  Add this to your shell profile:\n'
    printf '    %s\n' "$_export_line"
  fi
fi

# ═══════════════════════════════════════════════
# Step 3: Optional components
# ═══════════════════════════════════════════════
if [[ "$_interactive" = true ]]; then
  _step "3/4" "Optional components"

  # ── TUI Frontend ──
  TUI_REPO="Muster-dev/muster-tui"
  TUI_REPO_OLD="ImJustRicky/muster-tui"

  _tui_installed=false
  _tui_existing_ver=""
  if command -v muster-tui >/dev/null 2>&1; then
    _tui_installed=true
    _tui_existing_ver="$(muster-tui --version 2>/dev/null || true)"
  elif [[ -x "${BIN_DIR}/muster-tui" ]]; then
    _tui_installed=true
    _tui_existing_ver="$("${BIN_DIR}/muster-tui" --version 2>/dev/null || true)"
  elif [[ -f "$MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
    _tui_manifest_ver="$(jq -r '.components["muster-tui"].version // empty' "$MANIFEST" 2>/dev/null)"
    if [[ -n "$_tui_manifest_ver" ]]; then
      _tui_installed=true
      _tui_existing_ver="$_tui_manifest_ver"
    fi
  fi

  _tui_choice="skip"
  if [[ "$_tui_installed" = true ]]; then
    echo ""
    printf '  %b%bmuster-tui%b already installed %b(%s)%b\n' "$_B" "$_M" "$_R" "$_D" "${_tui_existing_ver:-unknown}" "$_R"
    printf '  %b1)%b Update %b(recommended)%b    %b2)%b Keep current\n' "$_M" "$_R" "$_G" "$_R" "$_M" "$_R"
    printf '  %bChoose [1/2]:%b ' "$_M" "$_R"
    read -r _tui_choice </dev/tty
    [[ "${_tui_choice:-1}" == "1" ]] && _tui_choice="install"
    [[ "${_tui_choice:-}" == "2" ]] && _tui_choice="skip"
    if [[ "$_tui_choice" == "skip" ]]; then
      _summary_items[${#_summary_items[@]}]="muster-tui ${_tui_existing_ver:-unknown} (kept)"
    fi
  else
    echo ""
    printf '  %b%bmuster-tui%b %b— the full-screen app you get when you type muster:%b\n' "$_B" "$_M" "$_R" "$_D" "$_R"
    printf '  %bcommand prompt, live deploys, logs, Docker and servers in one place.%b\n' "$_D" "$_R"
    echo ""
    printf '  %b1)%b Install %b(recommended)%b    %b2)%b Skip\n' "$_M" "$_R" "$_G" "$_R" "$_M" "$_R"
    printf '  %bChoose [1/2]:%b ' "$_M" "$_R"
    read -r _tui_choice </dev/tty
    [[ "${_tui_choice:-1}" == "1" ]] && _tui_choice="install"
    [[ "${_tui_choice:-}" == "2" ]] && _tui_choice="skip"
  fi

  case "${_tui_choice}" in
    install)
      printf '  %bInstalling muster-tui...%b\n' "$_D" "$_R"

      _os="$(uname -s | tr '[:upper:]' '[:lower:]')"
      _arch="$(uname -m)"
      case "$_arch" in
        x86_64)  _arch="amd64" ;;
        aarch64|arm64) _arch="arm64" ;;
      esac

      _tui_url="https://github.com/${TUI_REPO}/releases/latest/download/muster-tui-${_os}-${_arch}"
      _tui_url_old="https://github.com/${TUI_REPO_OLD}/releases/latest/download/muster-tui-${_os}-${_arch}"

      _tui_ok=false
      if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$_tui_url" -o "${BIN_DIR}/muster-tui" 2>/dev/null \
            || curl -fsSL "$_tui_url_old" -o "${BIN_DIR}/muster-tui" 2>/dev/null; then
          chmod +x "${BIN_DIR}/muster-tui"
          _tui_ok=true
        fi
      elif command -v wget >/dev/null 2>&1; then
        if wget -q "$_tui_url" -O "${BIN_DIR}/muster-tui" 2>/dev/null \
            || wget -q "$_tui_url_old" -O "${BIN_DIR}/muster-tui" 2>/dev/null; then
          chmod +x "${BIN_DIR}/muster-tui"
          _tui_ok=true
        fi
      fi

      if [[ "$_tui_ok" = true ]]; then
        _tui_ver="$("${BIN_DIR}/muster-tui" --version 2>/dev/null || echo "unknown")"
        _tui_ver="${_tui_ver#muster-tui }"
        printf '  %b✓%b muster-tui %b(%s)%b\n' "$_G" "$_R" "$_D" "$_tui_ver" "$_R"
        _summary_items[${#_summary_items[@]}]="muster-tui ${_tui_ver}"

        _write_manifest "muster-tui" "$_tui_ver" "${BIN_DIR}/muster-tui"

        # Auto-create auth token and connect
        # Pair muster-tui with the CLI. Use the installed CLI itself (the
        # library can't be sourced standalone here). If a token can't be made
        # now, the muster launcher pairs automatically on first run.
        _tui_token=$(MUSTER_NO_VERIFY=true "${BIN_DIR}/muster" auth create muster-tui --scope admin 2>/dev/null \
          | awk '/Token:/ {print $2; exit}') || _tui_token=""
        if [[ -n "$_tui_token" ]] && "${BIN_DIR}/muster-tui" --set-token "$_tui_token" >/dev/null 2>&1; then
          printf '  %b✓%b Connected to the muster CLI\n' "$_G" "$_R"
        else
          printf '  %bIt connects to the CLI the first time you run muster.%b\n' "$_D" "$_R"
        fi
      else
        printf '  %b!%b Could not download muster-tui binary.\n' "$_Y" "$_R"
        printf '  %bNo pre-built release for %s/%s.%b\n' "$_D" "$_os" "$_arch" "$_R"
        printf '  %bBuild from source: go install github.com/%s@latest%b\n' "$_D" "$TUI_REPO" "$_R"
      fi
      ;;
    *)
      ;;
  esac

  # ── Fleet Cloud ──
  _hr
  FLEET_REPO="Muster-dev/muster-fleet-cloud"

  _fc_installed=false
  _fc_existing_ver=""
  if command -v muster-tunnel >/dev/null 2>&1; then
    _fc_installed=true
    _fc_existing_ver="$(muster-tunnel --version 2>/dev/null || true)"
  elif [[ -x "${INSTALL_DIR}/bin/muster-tunnel" ]]; then
    _fc_installed=true
    _fc_existing_ver="$("${INSTALL_DIR}/bin/muster-tunnel" --version 2>/dev/null || true)"
  elif [[ -f "$MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
    _fc_manifest_ver="$(jq -r '.components["fleet-cloud"].version // empty' "$MANIFEST" 2>/dev/null)"
    if [[ -n "$_fc_manifest_ver" ]]; then
      _fc_installed=true
      _fc_existing_ver="$_fc_manifest_ver"
    fi
  fi

  _fc_choice="skip"
  if [[ "$_fc_installed" = true ]]; then
    echo ""
    printf '  %b%bfleet cloud%b already installed %b(%s)%b\n' "$_B" "$_M" "$_R" "$_D" "${_fc_existing_ver:-unknown}" "$_R"
    printf '  %b1)%b Keep current    %b2)%b Reinstall / update\n' "$_M" "$_R" "$_M" "$_R"
    printf '  %bChoose [1/2]:%b ' "$_M" "$_R"
    read -r _fc_choice </dev/tty
    [[ "${_fc_choice:-1}" == "1" ]] && _fc_choice="skip"
    [[ "${_fc_choice:-}" == "2" ]] && _fc_choice="install"
    if [[ "$_fc_choice" == "skip" ]]; then
      _summary_items[${#_summary_items[@]}]="fleet cloud ${_fc_existing_ver:-unknown} (kept)"
    fi
  else
    echo ""
    printf '  %b%bfleet cloud%b %b— cloud-based fleet deployment addon.%b\n' "$_B" "$_M" "$_R" "$_D" "$_R"
    printf '  %bInstalls muster-tunnel + muster-agent for NAT-traversal deploys.%b\n' "$_D" "$_R"
    echo ""
    printf '  %b1)%b Skip — SSH-only fleet    %b2)%b Install\n' "$_M" "$_R" "$_M" "$_R"
    printf '  %bChoose [1/2]:%b ' "$_M" "$_R"
    read -r _fc_choice </dev/tty
    [[ "${_fc_choice:-1}" == "1" ]] && _fc_choice="skip"
    [[ "${_fc_choice:-}" == "2" ]] && _fc_choice="install"
  fi

  case "${_fc_choice}" in
    install)
      printf '  %bInstalling fleet cloud...%b\n' "$_D" "$_R"

      _fc_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
      _fc_arch="$(uname -m)"
      case "$_fc_arch" in
        x86_64)  _fc_arch="amd64" ;;
        aarch64|arm64) _fc_arch="arm64" ;;
      esac

      _fc_ver=""
      if command -v curl >/dev/null 2>&1; then
        _fc_ver="$(curl -fsSL "https://api.github.com/repos/${FLEET_REPO}/releases/latest" 2>/dev/null \
          | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')"
      fi
      if [[ -z "$_fc_ver" ]]; then
        printf '  %b!%b Could not determine latest fleet cloud version.\n' "$_Y" "$_R"
        printf '  %bInstall manually: https://github.com/%s%b\n' "$_D" "$FLEET_REPO" "$_R"
      else
        _fc_base="https://github.com/${FLEET_REPO}/releases/download/v${_fc_ver}"
        _fc_prefix="$BIN_DIR"

        _fc_ok=true
        for _fc_bin in muster-tunnel muster-agent; do
          _fc_url="${_fc_base}/${_fc_bin}-${_fc_os}-${_fc_arch}"
          printf '  %bDownloading %s...%b\n' "$_D" "$_fc_bin" "$_R"
          if curl -fsSL "$_fc_url" -o "${_fc_prefix}/${_fc_bin}" 2>/dev/null; then
            chmod 755 "${_fc_prefix}/${_fc_bin}"
          else
            printf '  %b!%b Failed to download %s.\n' "$_Y" "$_R" "$_fc_bin"
            _fc_ok=false
          fi
        done

        if [[ "$_fc_ok" = true ]]; then
          printf '  %b✓%b fleet cloud %b(v%s)%b\n' "$_G" "$_R" "$_D" "$_fc_ver" "$_R"
          _summary_items[${#_summary_items[@]}]="fleet cloud v${_fc_ver}"

          _write_manifest "fleet-cloud" "$_fc_ver" "${_fc_prefix}/muster-tunnel"
        else
          printf '  %b!%b Some fleet cloud binaries failed to download.\n' "$_Y" "$_R"
          printf '  %bNo pre-built release for %s/%s.%b\n' "$_D" "$_fc_os" "$_fc_arch" "$_R"
          printf '  %bInstall manually: https://github.com/%s%b\n' "$_D" "$FLEET_REPO" "$_R"
        fi
      fi
      ;;
    *)
      ;;
  esac
fi

# ═══════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════
echo ""
_hr
if [[ ${#_summary_items[@]} -gt 0 ]]; then
  printf '  %bInstalled:%b\n' "$_B" "$_R"
  for _item in "${_summary_items[@]}"; do
    printf '    %b✓%b %s\n' "$_G" "$_R" "$_item"
  done
else
  printf '  %bNo changes made.%b\n' "$_D" "$_R"
fi
_hr

# ═══════════════════════════════════════════════
# Step 4: First project setup
# ═══════════════════════════════════════════════
if [[ "$_fresh_install" = true && "$_interactive" = true ]]; then
  _step "4/4" "First project setup"
  printf '  Run %b%bmuster setup%b now? [Y/n] ' "$_B" "$_M" "$_R"
  read -r _setup_answer </dev/tty
  case "${_setup_answer:-Y}" in
    [Yy]|"")
      echo ""
      export PATH="${BIN_DIR}:${PATH}"
      "${BIN_DIR}/muster" setup </dev/tty
      ;;
    *)
      printf '  No problem! Run %b%bmuster setup%b when you'\''re ready.\n' "$_B" "$_M" "$_R"
      ;;
  esac
fi
echo ""
