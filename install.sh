#!/usr/bin/env bash
# muster installer — curl https://raw.githubusercontent.com/ImJustRicky/muster/main/install.sh | bash
set -euo pipefail

REPO="ImJustRicky/muster"
INSTALL_DIR="${MUSTER_INSTALL_DIR:-$HOME/.muster}"
BIN_DIR="${MUSTER_BIN_DIR:-$HOME/.local/bin}"
MANIFEST="${INSTALL_DIR}/install.json"

echo ""
echo "  Installing muster..."
echo ""

# Ensure install dir has secure permissions
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"

# Clone or update
if [[ -d "${INSTALL_DIR}/repo" ]]; then
  echo "  Updating existing installation..."
  (cd "${INSTALL_DIR}/repo" && git pull --quiet)
else
  git clone --quiet "https://github.com/${REPO}.git" "${INSTALL_DIR}/repo"
fi

mkdir -p "$BIN_DIR"

# Link binaries
chmod +x "${INSTALL_DIR}/repo/bin/muster" "${INSTALL_DIR}/repo/bin/muster-mcp"
ln -sf "${INSTALL_DIR}/repo/bin/muster" "${BIN_DIR}/muster"
ln -sf "${INSTALL_DIR}/repo/bin/muster-mcp" "${BIN_DIR}/muster-mcp"

# Smoke test
_ver=""
if "${BIN_DIR}/muster" --version >/dev/null 2>&1; then
  _ver="$("${BIN_DIR}/muster" --version 2>/dev/null || true)"
  echo "  Done! muster ${_ver} installed."
else
  echo "  Warning: muster installed but failed to run."
  echo "  Try: ${BIN_DIR}/muster --version"
fi

# ── Install manifest ──
# Tracks installed components in ~/.muster/install.json
_now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
_write_manifest() {
  # Reads current manifest (or creates empty), updates a component entry
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

# Check if muster is reachable from PATH
_needs_path=false
if ! command -v muster >/dev/null 2>&1; then
  _needs_path=true
fi

if [[ "$_needs_path" = true ]]; then
  echo ""
  echo "  ${BIN_DIR} is not in your PATH."

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

  if [[ -n "$_shell_profile" && -t 0 ]]; then
    printf "  Add to %s? [Y/n] " "$_shell_profile"
    read -r _answer
    case "${_answer:-Y}" in
      [Yy]|"")
        echo "" >> "$_shell_profile"
        echo "# Added by muster installer" >> "$_shell_profile"
        echo "$_export_line" >> "$_shell_profile"
        echo "  Added! Run: source ${_shell_profile}"
        _added=true
        ;;
    esac
  fi

  if [[ "$_added" = false ]]; then
    echo "  Add this to your shell profile:"
    echo ""
    echo "    ${_export_line}"
  fi
fi

# ── TUI Frontend ──
# Offer optional muster-tui (rich TUI frontend built with Go)
TUI_REPO="ImJustRicky/muster-tui"

if [[ -t 0 ]]; then
  # Check if muster-tui is already installed
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

  if [[ "$_tui_installed" = true ]]; then
    echo ""
    echo "  muster-tui already installed (${_tui_existing_ver:-unknown version})."
    echo ""
    echo "  1) Keep current installation"
    echo "  2) Reinstall / update muster-tui"
    echo ""
    printf "  Choose [1/2]: "
    read -r _tui_choice
    # Map "keep" to skip
    [[ "${_tui_choice:-1}" == "1" ]] && _tui_choice="skip"
    [[ "${_tui_choice:-}" == "2" ]] && _tui_choice="install"
  else
    echo ""
    echo "  muster-tui is an optional rich TUI frontend with a"
    echo "  full-screen dashboard, streaming deploy logs, and"
    echo "  scrollable log viewer."
    echo ""
    echo "  1) Skip — use the built-in bash TUI (no extra install)"
    echo "  2) Install muster-tui (downloads a pre-built binary)"
    echo ""
    printf "  Choose [1/2]: "
    read -r _tui_choice
    [[ "${_tui_choice:-1}" == "1" ]] && _tui_choice="skip"
    [[ "${_tui_choice:-}" == "2" ]] && _tui_choice="install"
  fi

  case "${_tui_choice}" in
    install)
      echo ""
      echo "  Installing muster-tui..."

      # Detect OS and arch
      _os="$(uname -s | tr '[:upper:]' '[:lower:]')"
      _arch="$(uname -m)"
      case "$_arch" in
        x86_64)  _arch="amd64" ;;
        aarch64|arm64) _arch="arm64" ;;
      esac

      _tui_url="https://github.com/${TUI_REPO}/releases/latest/download/muster-tui-${_os}-${_arch}"

      _tui_ok=false
      if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$_tui_url" -o "${BIN_DIR}/muster-tui" 2>/dev/null; then
          chmod +x "${BIN_DIR}/muster-tui"
          _tui_ok=true
        fi
      elif command -v wget >/dev/null 2>&1; then
        if wget -q "$_tui_url" -O "${BIN_DIR}/muster-tui" 2>/dev/null; then
          chmod +x "${BIN_DIR}/muster-tui"
          _tui_ok=true
        fi
      fi

      if [[ "$_tui_ok" = true ]]; then
        _tui_ver="$("${BIN_DIR}/muster-tui" --version 2>/dev/null || echo "unknown")"
        echo "  muster-tui installed! (${_tui_ver})"

        # Record in install manifest
        _write_manifest "muster-tui" "$_tui_ver" "${BIN_DIR}/muster-tui"

        # Auto-create auth token and connect the protocol
        # Only if no muster-tui token already exists
        echo ""
        echo "  Setting up secure connection..."
        source "${INSTALL_DIR}/repo/lib/core/auth.sh"

        _has_tui_token=false
        if [[ -f "$MUSTER_TOKENS_FILE" ]] && command -v jq >/dev/null 2>&1; then
          _existing_tui=$(jq -r '.tokens[] | select(.name == "muster-tui") | .name' "$MUSTER_TOKENS_FILE" 2>/dev/null)
          [[ -n "$_existing_tui" ]] && _has_tui_token=true
        fi

        if [[ "$_has_tui_token" = true ]]; then
          echo "  Auth token 'muster-tui' already exists — skipping."
          echo ""
          echo "  If you need a new token, revoke and recreate:"
          echo "    MUSTER_TOKEN=<admin-token> muster auth revoke muster-tui"
          echo "    MUSTER_TOKEN=<admin-token> muster auth create muster-tui --scope admin"
          echo "    muster-tui --set-token <new-token>"
        else
          _tui_token=""
          if _tui_token=$(auth_create_token "muster-tui" "admin" 2>/dev/null) && [[ -n "$_tui_token" ]]; then
            if "${BIN_DIR}/muster-tui" --set-token "$_tui_token" >/dev/null 2>&1; then
              echo "  Auth token created and linked automatically."
              echo ""
              echo "  You're all set! Run muster-tui from any muster project:"
              echo "    cd your-project"
              echo "    muster-tui"
            else
              echo "  Token created but could not save to muster-tui config."
              echo "  Connect manually:"
              echo "    muster-tui --set-token ${_tui_token}"
            fi
          else
            echo "  Could not auto-create token (jq may be missing)."
            echo "  Connect manually:"
            echo "    muster auth create muster-tui --scope admin"
            echo "    muster-tui --set-token <token>"
          fi
        fi
      else
        echo "  Could not download muster-tui binary."
        echo "  No pre-built release found for ${_os}/${_arch}."
        echo ""
        echo "  You can build from source instead:"
        echo "    go install github.com/${TUI_REPO}@latest"
      fi
      ;;
    *)
      echo ""
      echo "  Skipped. You can install muster-tui later:"
      echo "    go install github.com/${TUI_REPO}@latest"
      ;;
  esac
fi
echo ""
