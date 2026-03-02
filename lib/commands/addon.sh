#!/usr/bin/env bash
# muster/lib/commands/addon.sh — Addon management (fleet-cloud, tui)

ADDON_MANIFEST="${HOME}/.muster/install.json"
ADDON_BIN_DIR="${HOME}/.muster/bin"
ADDON_LOCAL_BIN="${HOME}/.local/bin"

# ── Addon registry ──
# Each addon: <name>|<repo>|<binaries (comma-sep)>|<dest-dir>|<description>
_ADDON_REGISTRY=(
  "fleet-cloud|Muster-dev/muster-fleet-cloud|muster-tunnel,muster-agent|${ADDON_LOCAL_BIN}|Cloud fleet deployment (tunnel + agent)"
  "tui|ImJustRicky/muster-tui|muster-tui|${ADDON_LOCAL_BIN}|Rich TUI frontend"
)

_addon_field() {
  local entry="$1" idx="$2"
  echo "$entry" | cut -d'|' -f"$idx"
}

_addon_find() {
  local name="$1"
  local entry
  for entry in "${_ADDON_REGISTRY[@]}"; do
    if [[ "$(_addon_field "$entry" 1)" == "$name" ]]; then
      echo "$entry"
      return 0
    fi
  done
  return 1
}

_addon_write_manifest() {
  local component="$1" version="$2" bin_path="$3"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  mkdir -p "$(dirname "$ADDON_MANIFEST")"
  chmod 700 "$(dirname "$ADDON_MANIFEST")"

  if [[ -f "$ADDON_MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
    local tmp="${ADDON_MANIFEST}.tmp"
    jq --arg c "$component" --arg v "$version" --arg b "$bin_path" --arg t "$now" \
      '.components[$c] = {"version":$v,"bin":$b,"installed":$t}' \
      "$ADDON_MANIFEST" > "$tmp" && mv "$tmp" "$ADDON_MANIFEST"
  elif command -v jq >/dev/null 2>&1; then
    printf '{"components":{"%s":{"version":"%s","bin":"%s","installed":"%s"}}}\n' \
      "$component" "$version" "$bin_path" "$now" > "$ADDON_MANIFEST"
  else
    warn "jq not found — cannot update install manifest"
    return 1
  fi
  [[ -f "$ADDON_MANIFEST" ]] && chmod 600 "$ADDON_MANIFEST"
}

_addon_remove_manifest() {
  local component="$1"
  if [[ -f "$ADDON_MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
    local tmp="${ADDON_MANIFEST}.tmp"
    jq --arg c "$component" 'del(.components[$c])' \
      "$ADDON_MANIFEST" > "$tmp" && mv "$tmp" "$ADDON_MANIFEST"
    chmod 600 "$ADDON_MANIFEST"
  fi
}

_addon_is_installed() {
  local name="$1"
  if [[ -f "$ADDON_MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
    local ver
    ver="$(jq -r --arg c "$name" '.components[$c].version // empty' "$ADDON_MANIFEST" 2>/dev/null)"
    [[ -n "$ver" ]] && return 0
  fi

  # Fallback: check if binaries exist
  local entry
  entry="$(_addon_find "$name")" || return 1
  local bins dest first_bin
  bins="$(_addon_field "$entry" 3)"
  dest="$(_addon_field "$entry" 4)"
  first_bin="$(echo "$bins" | cut -d',' -f1)"
  [[ -x "${dest}/${first_bin}" ]]
}

_addon_installed_version() {
  local name="$1"
  if [[ -f "$ADDON_MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
    jq -r --arg c "$name" '.components[$c].version // empty' "$ADDON_MANIFEST" 2>/dev/null
  fi
}

# ── Commands ──

cmd_addon() {
  case "${1:-}" in
    --help|-h)
      echo "Usage: muster addon <command> [args]"
      echo ""
      echo "Manage addons."
      echo ""
      echo "Commands:"
      echo "  add <name>       Install an addon"
      echo "  remove <name>    Remove an addon"
      echo "  list             List available and installed addons"
      echo ""
      echo "Available addons:"
      echo "  fleet-cloud      Cloud fleet deployment (muster-tunnel + muster-agent)"
      echo "  tui              Rich TUI frontend (muster-tui)"
      return 0
      ;;
  esac

  local action="${1:-list}"
  shift 2>/dev/null || true

  case "$action" in
    add|install)
      addon_add "$@"
      ;;
    remove|uninstall)
      addon_remove "$@"
      ;;
    list|ls)
      addon_list
      ;;
    *)
      err "Unknown addon command: ${action}"
      echo "Usage: muster addon [add|remove|list]"
      return 1
      ;;
  esac
}

addon_add() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    err "Usage: muster addon add <name>"
    echo ""
    echo "Available addons: fleet-cloud, tui"
    return 1
  fi

  # Validate addon name
  local entry
  entry="$(_addon_find "$name")" || {
    err "Unknown addon: ${name}"
    echo ""
    echo "Available addons:"
    local e
    for e in "${_ADDON_REGISTRY[@]}"; do
      printf '  %-14s %s\n' "$(_addon_field "$e" 1)" "$(_addon_field "$e" 5)"
    done
    return 1
  }

  # Check dependencies
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is required to download addons"
    return 1
  fi

  local repo bins dest desc
  repo="$(_addon_field "$entry" 2)"
  bins="$(_addon_field "$entry" 3)"
  dest="$(_addon_field "$entry" 4)"
  desc="$(_addon_field "$entry" 5)"

  # Check if already installed
  local existing_ver=""
  existing_ver="$(_addon_installed_version "$name")"
  if [[ -n "$existing_ver" ]]; then
    info "  ${name} is already installed (${existing_ver})"
    printf '  Reinstall? [y/N] '
    read -r _answer
    case "${_answer:-N}" in
      [Yy]) ;;
      *) return 0 ;;
    esac
  fi

  # Detect platform
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64)        arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
  esac

  # Fetch latest version
  info "  Fetching latest ${name} release..."
  local version
  version="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')"

  if [[ -z "$version" ]]; then
    err "Could not determine latest version for ${name}"
    echo "  Check: https://github.com/${repo}/releases"
    return 1
  fi

  info "  Installing ${name} v${version} (${os}/${arch})..."
  mkdir -p "$dest"

  local base_url="https://github.com/${repo}/releases/download/v${version}"
  local ok=true
  local bin_name first_bin=""

  # Split bins on comma and download each
  local IFS=','
  for bin_name in $bins; do
    IFS=' '
    local url="${base_url}/${bin_name}-${os}-${arch}"
    printf '  Downloading %s...\n' "$bin_name"
    if curl -fsSL "$url" -o "${dest}/${bin_name}" 2>/dev/null; then
      chmod 755 "${dest}/${bin_name}"
    else
      warn "Failed to download ${bin_name}"
      ok=false
    fi
    [[ -z "$first_bin" ]] && first_bin="$bin_name"
  done
  IFS=' '

  if [[ "$ok" = true ]]; then
    ok_msg "${name} v${version} installed"
    _addon_write_manifest "$name" "$version" "${dest}/${first_bin}"

    # Addon-specific post-install
    case "$name" in
      tui)
        # Auto-create auth token if auth.sh is available
        if [[ -f "$MUSTER_ROOT/lib/core/auth.sh" ]]; then
          source "$MUSTER_ROOT/lib/core/auth.sh"
          local _has_tui_token=false
          if [[ -f "${MUSTER_TOKENS_FILE:-}" ]] && command -v jq >/dev/null 2>&1; then
            local _existing
            _existing="$(jq -r '.tokens[] | select(.name == "muster-tui") | .name' "$MUSTER_TOKENS_FILE" 2>/dev/null)"
            [[ -n "$_existing" ]] && _has_tui_token=true
          fi
          if [[ "$_has_tui_token" = false ]]; then
            local _tui_token=""
            if _tui_token=$(_auth_create_token_internal "muster-tui" "admin" 2>/dev/null) && [[ -n "$_tui_token" ]]; then
              if "${dest}/${first_bin}" --set-token "$_tui_token" >/dev/null 2>&1; then
                ok_msg "Auth token created and linked"
              fi
            fi
          fi
        fi
        ;;
      fleet-cloud)
        # Check PATH for ~/.muster/bin
        if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$dest"; then
          echo ""
          warn "${dest} is not in your PATH"
          echo "  Add it with:"
          echo "    export PATH=\"\$HOME/.muster/bin:\$PATH\""
        fi
        ;;
    esac

    echo ""
    echo "  Next steps:"
    local IFS=','
    for bin_name in $bins; do
      IFS=' '
      printf '    %s --help\n' "$bin_name"
    done
    IFS=' '
  else
    err "Some binaries failed to download (${os}/${arch})"
    echo "  Check: https://github.com/${repo}/releases"
    return 1
  fi
}

addon_remove() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    err "Usage: muster addon remove <name>"
    return 1
  fi

  local entry
  entry="$(_addon_find "$name")" || {
    err "Unknown addon: ${name}"
    return 1
  }

  if ! _addon_is_installed "$name"; then
    info "  ${name} is not installed"
    return 0
  fi

  local bins dest
  bins="$(_addon_field "$entry" 3)"
  dest="$(_addon_field "$entry" 4)"

  printf '  Remove %s? [y/N] ' "$name"
  read -r _answer
  case "${_answer:-N}" in
    [Yy]) ;;
    *) return 0 ;;
  esac

  local bin_name
  local IFS=','
  for bin_name in $bins; do
    IFS=' '
    if [[ -f "${dest}/${bin_name}" ]]; then
      rm -f "${dest}/${bin_name}"
      info "  Removed ${dest}/${bin_name}"
    fi
  done
  IFS=' '

  _addon_remove_manifest "$name"
  ok_msg "${name} removed"
}

addon_list() {
  echo ""
  printf '  %b%bAddons%b\n' "$BOLD" "$MUSTARD" "$RESET"
  echo ""

  local entry name desc installed ver
  for entry in "${_ADDON_REGISTRY[@]}"; do
    name="$(_addon_field "$entry" 1)"
    desc="$(_addon_field "$entry" 5)"
    ver="$(_addon_installed_version "$name")"
    if [[ -n "$ver" ]]; then
      printf '  %b%-14s%b %b%s%b  %b(%s)%b\n' "$BOLD" "$name" "$RESET" "$DIM" "$desc" "$RESET" "$GREEN" "$ver" "$RESET"
    else
      printf '  %b%-14s%b %b%s%b  %b(not installed)%b\n' "$BOLD" "$name" "$RESET" "$DIM" "$desc" "$RESET" "$DIM" "$RESET"
    fi
  done

  echo ""
  printf '  %bInstall with: muster addon add <name>%b\n' "$DIM" "$RESET"
  echo ""
}
