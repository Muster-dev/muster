#!/usr/bin/env bash
# action/install.sh — put muster on PATH for the rest of the job.
#
# INPUT_VERSION empty: use this action's own checkout (GitHub fetched the ref
# the workflow pinned, e.g. Muster-dev/muster@v0 or @<sha>).
# INPUT_VERSION=X.Y.Z or latest: download the release tarball, verify it
# against the release's checksums.txt (and INPUT_VERSION_SHA256 if given),
# cache it in the runner tool cache. Releases published before the tarball
# asset existed fall back to a shallow git clone of the tag.
set -euo pipefail

ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=action/lib.sh
source "${ACTION_ROOT}/action/lib.sh"

tmp=""
trap '[[ -n "$tmp" ]] && rm -rf "$tmp"' EXIT

for dep in jq curl git openssl; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    if [[ "$dep" == "jq" ]]; then
      echo "Installing jq..."
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq >/dev/null && sudo apt-get install -y -qq jq >/dev/null
      elif command -v brew >/dev/null 2>&1; then
        brew install jq >/dev/null
      fi
    fi
    command -v "$dep" >/dev/null 2>&1 || { _a_err "muster needs ${dep} on the runner"; exit 1; }
  fi
done

ver="${INPUT_VERSION:-}"
ver="${ver#v}"
root=""

if [[ -z "$ver" ]]; then
  root="$ACTION_ROOT"
  echo "Using muster from the action checkout (${GITHUB_ACTION_REF:-local})"
else
  if [[ "$ver" == "latest" ]]; then
    auth=()
    [[ -n "${GH_API_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GH_API_TOKEN}")
    ver=$(_a_curl "${auth[@]+"${auth[@]}"}" "https://api.github.com/repos/${MUSTER_REPO}/releases/latest" \
      | jq -r '.tag_name // empty')
    ver="${ver#v}"
    [[ -n "$ver" ]] || { _a_err "Could not resolve the latest muster release"; exit 1; }
  fi
  _a_valid_version "$ver" || { _a_err "Invalid muster version: ${INPUT_VERSION}"; exit 1; }

  cache="$(_a_cache_root)/muster/${ver}/any"
  root="${cache}/muster"
  if [[ -f "${cache}/.complete" && -x "${root}/bin/muster" ]]; then
    echo "Using cached muster ${ver}"
  else
    rm -rf "$cache"
    mkdir -p "$cache"
    tmp=$(mktemp -d)
    base="https://github.com/${MUSTER_REPO}/releases/download/v${ver}"
    tarball="muster-${ver}.tar.gz"
    echo "Downloading muster ${ver}..."
    if _a_download "${base}/checksums.txt" "${tmp}/checksums.txt" \
      && _a_download "${base}/${tarball}" "${tmp}/${tarball}"; then
      expected=$(_a_checksum_for "${tmp}/checksums.txt" "$tarball")
      actual=$(_a_sha256 "${tmp}/${tarball}")
      if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        _a_err "Checksum mismatch for ${tarball} (expected ${expected:-none}, got ${actual})"
        exit 1
      fi
      if [[ -n "${INPUT_VERSION_SHA256:-}" && "$INPUT_VERSION_SHA256" != "$actual" ]]; then
        _a_err "version-sha256 does not match ${tarball} (got ${actual})"
        exit 1
      fi
      echo "Verified ${tarball} sha256 ${actual}"
      mkdir -p "$root"
      tar -xzf "${tmp}/${tarball}" -C "$root" --strip-components=1
    elif [[ -n "${INPUT_VERSION_SHA256:-}" ]]; then
      # Older release without assets: GitHub's tag archive, pinned by hash
      _a_download "https://github.com/${MUSTER_REPO}/archive/refs/tags/v${ver}.tar.gz" "${tmp}/src.tar.gz" \
        || { _a_err "Could not download the v${ver} source archive"; exit 1; }
      actual=$(_a_sha256 "${tmp}/src.tar.gz")
      if [[ "$INPUT_VERSION_SHA256" != "$actual" ]]; then
        _a_err "version-sha256 does not match the v${ver} source archive (got ${actual})"
        exit 1
      fi
      mkdir -p "$root"
      tar -xzf "${tmp}/src.tar.gz" -C "$root" --strip-components=1
    else
      _a_notice "muster ${ver} has no release tarball/checksums; cloning tag v${ver} (git verifies object hashes)"
      git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v${ver}" \
        "https://github.com/${MUSTER_REPO}.git" "$root" 2>&1 | grep -v 'is not a commit' || true
      [[ -x "${root}/bin/muster" ]] || { _a_err "Could not clone muster v${ver}"; exit 1; }
      rm -rf "${root}/.git"
    fi
    rm -rf "$tmp"
    chmod +x "${root}/bin/muster" "${root}/bin/muster-mcp" 2>/dev/null || true
    # Integrity baseline, like install.sh: later runs detect a modified cache
    ( cd "$root" && MUSTER_ROOT=. bash -c 'source lib/core/app_verify.sh && _app_manifest_generate' ) >/dev/null 2>&1 || true
    touch "${cache}/.complete"
  fi
fi

chmod +x "${root}/bin/muster" 2>/dev/null || true
installed=$("${root}/bin/muster" --version 2>/dev/null) || { _a_err "muster failed to run from ${root}"; exit 1; }
installed="${installed#v}"
if [[ -n "$ver" && "$installed" != "$ver" ]]; then
  _a_err "Installed muster reports ${installed}, expected ${ver}"
  exit 1
fi

echo "${root}/bin" >> "$GITHUB_PATH"
echo "muster-version=${installed}" >> "$GITHUB_OUTPUT"
echo "muster ${installed} ready"
