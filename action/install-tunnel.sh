#!/usr/bin/env bash
# action/install-tunnel.sh — install a pinned muster-tunnel (Fleet Cloud),
# verified against the release's checksums.txt, cached in the tool cache.
set -euo pipefail

ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=action/lib.sh
source "${ACTION_ROOT}/action/lib.sh"

tmp=""
trap '[[ -n "$tmp" ]] && rm -rf "$tmp"' EXIT

ver="${INPUT_TUNNEL_VERSION:-}"
ver="${ver#v}"
_a_valid_version "$ver" || { _a_err "Invalid tunnel-version: ${INPUT_TUNNEL_VERSION:-}"; exit 1; }

os=$(_a_os)
arch=$(_a_arch)
asset="muster-tunnel-${os}-${arch}"
dir="$(_a_cache_root)/muster-tunnel/${ver}/${os}-${arch}"

if [[ -f "${dir}/.complete" && -x "${dir}/muster-tunnel" ]]; then
  echo "Using cached muster-tunnel ${ver}"
else
  rm -rf "$dir"
  mkdir -p "$dir"
  tmp=$(mktemp -d)
  base="https://github.com/${TUNNEL_REPO}/releases/download/v${ver}"
  echo "Downloading ${asset} ${ver}..."
  _a_download "${base}/checksums.txt" "${tmp}/checksums.txt" \
    || { _a_err "No checksums.txt in ${TUNNEL_REPO} v${ver}"; exit 1; }
  _a_download "${base}/${asset}" "${tmp}/${asset}" \
    || { _a_err "No ${asset} in ${TUNNEL_REPO} v${ver}"; exit 1; }
  expected=$(_a_checksum_for "${tmp}/checksums.txt" "$asset")
  actual=$(_a_sha256 "${tmp}/${asset}")
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    _a_err "Checksum mismatch for ${asset} (expected ${expected:-none}, got ${actual})"
    exit 1
  fi
  echo "Verified ${asset} sha256 ${actual}"
  install -m 755 "${tmp}/${asset}" "${dir}/muster-tunnel"
  rm -rf "$tmp"
  touch "${dir}/.complete"
fi

echo "$dir" >> "$GITHUB_PATH"
"${dir}/muster-tunnel" --version 2>/dev/null || true
