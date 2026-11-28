#!/usr/bin/env bash
# action/lib.sh — shared helpers for the GitHub Action scripts (bash 3.2+)

# shellcheck disable=SC2034  # used by the scripts that source this
MUSTER_REPO="Muster-dev/muster"
# shellcheck disable=SC2034
TUNNEL_REPO="Muster-dev/muster-fleet-cloud"

_a_err() { printf '::error title=muster action::%s\n' "$*"; }
_a_notice() { printf '::notice title=muster action::%s\n' "$*"; }

_a_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Expected hash for FILE from a sha256sum-style checksums.txt
_a_checksum_for() {
  local sums="$1" name="$2"
  awk -v f="$name" '$2 == f || $2 == "*" f {print $1; exit}' "$sums"
}

_a_curl() {
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "$@"
}

# Download URL to DEST. Checks the file, not just curl's exit code: some curl
# builds (8.14 on macOS) exit 0 after a 404 when --retry is set.
_a_download() {
  local url="$1" dest="$2"
  rm -f "$dest"
  _a_curl -o "$dest" "$url" 2>/dev/null || true
  [[ -s "$dest" ]]
}

_a_valid_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ]]
}

_a_os() { uname -s | tr '[:upper:]' '[:lower:]'; }

_a_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) uname -m ;;
  esac
}

_a_cache_root() {
  printf '%s' "${RUNNER_TOOL_CACHE:-${HOME}/.cache/muster-action}"
}

_a_truthy() {
  case "${1:-}" in 1|true|TRUE|True|yes|on) return 0 ;; esac
  return 1
}
