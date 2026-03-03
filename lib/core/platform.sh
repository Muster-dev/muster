#!/usr/bin/env bash
# muster/lib/core/platform.sh — Platform detection

MUSTER_OS=""
MUSTER_ARCH=""
MUSTER_HAS_KEYCHAIN=false
MUSTER_HAS_DOCKER=false
MUSTER_HAS_KUBECTL=false
MUSTER_HAS_JQ=false
MUSTER_HAS_PYTHON=false

detect_platform() {
  # OS
  case "$(uname -s)" in
    Darwin*)  MUSTER_OS="macos" ;;
    Linux*)   MUSTER_OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*) MUSTER_OS="windows" ;;
    FreeBSD*) MUSTER_OS="freebsd" ;;
    *)        MUSTER_OS="unknown" ;;
  esac

  # Architecture
  case "$(uname -m)" in
    x86_64|amd64) MUSTER_ARCH="x64" ;;
    arm64|aarch64) MUSTER_ARCH="arm64" ;;
    armv7*)        MUSTER_ARCH="armv7" ;;
    *)             MUSTER_ARCH="$(uname -m)" ;;
  esac

  # Keychain support
  if [[ "$MUSTER_OS" == "macos" ]]; then
    has_cmd security && MUSTER_HAS_KEYCHAIN=true
  elif [[ "$MUSTER_OS" == "linux" ]]; then
    (has_cmd secret-tool || has_cmd pass) && MUSTER_HAS_KEYCHAIN=true
  fi

  # Tools
  has_cmd docker && MUSTER_HAS_DOCKER=true
  has_cmd kubectl && MUSTER_HAS_KUBECTL=true
  has_cmd jq && MUSTER_HAS_JQ=true
  has_cmd python3 && MUSTER_HAS_PYTHON=true
}

print_platform() {
  printf '%b\n' "  ${DIM}${MUSTER_OS} ${MUSTER_ARCH}${RESET}"

  local tools=""
  [[ "$MUSTER_HAS_DOCKER" == "true" ]] && tools+="docker "
  [[ "$MUSTER_HAS_KUBECTL" == "true" ]] && tools+="kubectl "
  [[ "$MUSTER_HAS_JQ" == "true" ]] && tools+="jq "
  [[ "$MUSTER_HAS_PYTHON" == "true" ]] && tools+="python3 "

  if [[ -n "$tools" ]]; then
    printf '%b\n' "  ${DIM}tools: ${tools}${RESET}"
  fi

  if [[ "$MUSTER_HAS_KEYCHAIN" == "true" ]]; then
    printf '%b\n' "  ${DIM}keychain: available${RESET}"
  else
    printf '%b\n' "  ${DIM}keychain: not available (will use encrypted vault)${RESET}"
  fi
}

detect_platform
