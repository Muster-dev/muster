#!/usr/bin/env bash
# muster/lib/commands/cloud.sh — Fleet Cloud account: login, logout, status
#
# Login uses the device authorization flow: the CLI asks the relay for a
# short code, you approve it in the browser at cloud.getmuster.dev/device,
# and the relay hands back a CLI token scoped to your org. The token is
# stored in the system keychain (file fallback, 0600) and never written to
# a project or printed.

source "$MUSTER_ROOT/lib/core/cloud.sh"
source "$MUSTER_ROOT/lib/core/credentials.sh"

MUSTER_CLOUD_DEFAULT_RELAY="${MUSTER_CLOUD_RELAY:-https://relay.getmuster.dev}"

# Relay base URL as https://… for REST calls (accepts wss://, ws://, http(s)://)
_cloud_http_base() {
  local url="${1%/}"
  url="${url%/v1/tunnel}"
  case "$url" in
    wss://*) url="https://${url#wss://}" ;;
    ws://*) url="http://${url#ws://}" ;;
    http://* | https://*) ;;
    *) url="https://${url}" ;;
  esac
  printf '%s' "$url"
}

# Relay URL as wss://… for the tunnel
_cloud_ws_url() {
  local base
  base=$(_cloud_http_base "$1")
  case "$base" in
    https://*) printf 'wss://%s' "${base#https://}" ;;
    http://*) printf 'ws://%s' "${base#http://}" ;;
  esac
}

# Read a top-level string field from a JSON document on stdin
_cloud_json_field() {
  local field="$1"
  if has_cmd jq; then
    jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
  elif has_cmd python3; then
    python3 -c 'import json,sys
try:
    v = json.load(sys.stdin).get(sys.argv[1], "")
    print("" if v is None else v)
except Exception:
    pass' "$field"
  fi
}

# POST JSON. Sets _CLOUD_HTTP_STATUS and _CLOUD_HTTP_BODY in the current
# shell (call it directly, not inside $(...), or the values are lost).
_CLOUD_HTTP_STATUS=""
_CLOUD_HTTP_BODY=""
_cloud_post() {
  local url="$1" body="$2" out
  if ! out=$(curl -sS --max-time 15 -w '\n%{http_code}' \
    -H 'Content-Type: application/json' \
    -H "User-Agent: muster/${MUSTER_VERSION:-dev}" \
    -X POST --data "$body" "$url" 2>/dev/null); then
    _CLOUD_HTTP_STATUS="000"
    _CLOUD_HTTP_BODY=""
    return 1
  fi
  _CLOUD_HTTP_STATUS="${out##*$'\n'}"
  _CLOUD_HTTP_BODY="${out%$'\n'*}"
}

_cloud_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_cloud_open_browser() {
  local url="$1"
  [[ -n "${MUSTER_NO_BROWSER:-}" ]] && return 1
  if [[ "$MUSTER_OS" == "macos" ]] && has_cmd open; then
    open "$url" >/dev/null 2>&1 && return 0
  fi
  if has_cmd xdg-open && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    xdg-open "$url" >/dev/null 2>&1 && return 0
  fi
  return 1
}

cmd_cloud() {
  local sub="${1:-status}"
  shift 2>/dev/null || true
  case "$sub" in
    login) _cloud_login "$@" ;;
    logout) _cloud_logout "$@" ;;
    status | whoami) _cloud_status "$@" ;;
    -h | --help | help) _cloud_help ;;
    *)
      err "Unknown cloud command: ${sub}"
      _cloud_help
      return 1
      ;;
  esac
}

_cloud_help() {
  echo "Usage: muster cloud <command>"
  echo ""
  echo "Connect this machine to your Fleet Cloud account."
  echo ""
  echo "Commands:"
  echo "  login [--relay <url>]   Sign in through the browser (device code)"
  echo "  logout                  Forget the stored token on this machine"
  echo "  status [--json]         Show account, relay and connection status"
  echo ""
  echo "Environment:"
  echo "  MUSTER_CLOUD_RELAY      Relay URL (default: https://relay.getmuster.dev)"
  echo "  MUSTER_NO_BROWSER=1     Don't try to open a browser"
}

_cloud_login() {
  local relay=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --relay)
        relay="${2:-}"
        shift 2
        ;;
      --relay=*)
        relay="${1#--relay=}"
        shift
        ;;
      *)
        err "Unknown flag: $1"
        return 1
        ;;
    esac
  done
  [[ -z "$relay" ]] && relay=$(global_config_get "cloud.relay" 2>/dev/null)
  [[ -z "$relay" || "$relay" == "null" ]] && relay="$MUSTER_CLOUD_DEFAULT_RELAY"

  if ! has_cmd curl; then
    err "curl is required for muster cloud login"
    return 1
  fi
  if ! has_cmd jq && ! has_cmd python3; then
    err "jq (or python3) is required for muster cloud login"
    return 1
  fi

  local base host client_name body resp
  base=$(_cloud_http_base "$relay")
  host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "this machine")
  client_name="muster-cli on ${host}"

  body="{\"client_name\":\"$(_cloud_json_escape "$client_name")\"}"
  _cloud_post "${base}/api/v1/device/code" "$body" || true
  resp="$_CLOUD_HTTP_BODY"
  if [[ "$_CLOUD_HTTP_STATUS" != "200" ]]; then
    if [[ "$_CLOUD_HTTP_STATUS" == "000" ]]; then
      err "Can't reach the relay at ${base}"
      printf '%b\n' "  ${DIM}Check your connection, or pass --relay <url> for a self-hosted relay.${RESET}"
    else
      err "The relay refused the login request (HTTP ${_CLOUD_HTTP_STATUS})"
    fi
    return 1
  fi

  local device_code user_code verify_uri verify_complete interval expires_in
  device_code=$(printf '%s' "$resp" | _cloud_json_field device_code)
  user_code=$(printf '%s' "$resp" | _cloud_json_field user_code)
  verify_uri=$(printf '%s' "$resp" | _cloud_json_field verification_uri)
  verify_complete=$(printf '%s' "$resp" | _cloud_json_field verification_uri_complete)
  interval=$(printf '%s' "$resp" | _cloud_json_field interval)
  expires_in=$(printf '%s' "$resp" | _cloud_json_field expires_in)
  [[ -z "$verify_complete" ]] && verify_complete="${verify_uri}?code=${user_code}"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=5
  [[ "$expires_in" =~ ^[0-9]+$ ]] || expires_in=600

  if [[ -z "$device_code" || -z "$user_code" ]]; then
    err "Unexpected response from the relay"
    return 1
  fi

  echo ""
  printf '  %bYour code:%b  %b%s%b\n' "$DIM" "$RESET" "${BOLD}${ACCENT_BRIGHT}" "$user_code" "$RESET"
  echo ""
  if _cloud_open_browser "$verify_complete"; then
    printf '  Opened %b%s%b in your browser.\n' "$WHITE" "$verify_uri" "$RESET"
  else
    printf '  Open %b%s%b and enter the code.\n' "$WHITE" "$verify_complete" "$RESET"
  fi
  printf '  %bWaiting for approval… (Ctrl+C to cancel)%b\n' "$DIM" "$RESET"

  local waited=0 err_code token org_id name token_id relay_url
  while ((waited < expires_in)); do
    sleep "$interval"
    waited=$((waited + interval))
    _cloud_post "${base}/api/v1/device/token" "{\"device_code\":\"$(_cloud_json_escape "$device_code")\"}" || true
    resp="$_CLOUD_HTTP_BODY"
    if [[ "$_CLOUD_HTTP_STATUS" == "200" ]]; then
      token=$(printf '%s' "$resp" | _cloud_json_field token)
      org_id=$(printf '%s' "$resp" | _cloud_json_field org_id)
      name=$(printf '%s' "$resp" | _cloud_json_field name)
      token_id=$(printf '%s' "$resp" | _cloud_json_field token_id)
      relay_url=$(printf '%s' "$resp" | _cloud_json_field relay_url)
      break
    fi
    err_code=$(printf '%s' "$resp" | _cloud_json_field error)
    case "$err_code" in
      authorization_pending) ;;
      slow_down) interval=$((interval + 5)) ;;
      access_denied)
        echo ""
        err "Login was denied in the browser."
        return 1
        ;;
      expired_token)
        echo ""
        err "The code expired. Run muster cloud login again."
        return 1
        ;;
      *)
        [[ "$_CLOUD_HTTP_STATUS" == "000" ]] && continue
        echo ""
        err "Login failed (HTTP ${_CLOUD_HTTP_STATUS}${err_code:+, ${err_code}})"
        return 1
        ;;
    esac
  done

  if [[ -z "${token:-}" ]]; then
    echo ""
    err "Timed out waiting for approval. Run muster cloud login again."
    return 1
  fi
  case "$token" in
    mst_cli_*) ;;
    *)
      err "The relay returned an unexpected credential type; not saving it."
      return 1
      ;;
  esac

  [[ -z "$relay_url" ]] && relay_url=$(_cloud_ws_url "$base")
  _fleet_cloud_token_set "default" "$token" || {
    err "Couldn't store the token securely"
    return 1
  }
  global_config_set "cloud.relay" "\"$(_cloud_json_escape "$relay_url")\"" >/dev/null 2>&1
  global_config_set "cloud.org_id" "\"$(_cloud_json_escape "$org_id")\"" >/dev/null 2>&1
  global_config_set "cloud.token_ref" '"default"' >/dev/null 2>&1
  global_config_set "cloud.token_id" "\"$(_cloud_json_escape "$token_id")\"" >/dev/null 2>&1
  global_config_set "cloud.name" "\"$(_cloud_json_escape "$name")\"" >/dev/null 2>&1

  echo ""
  ok "Logged in to Fleet Cloud"
  printf '  %bOrg:%b    %s\n' "$DIM" "$RESET" "$org_id"
  printf '  %bRelay:%b  %s\n' "$DIM" "$RESET" "$relay_url"
  echo ""
  printf '  %bNext: connect a machine at %s, then%b\n' "$DIM" "${verify_uri%/device}" "$RESET"
  printf '  %b      muster fleet add <name> --transport cloud%b\n' "$DIM" "$RESET"
}

_cloud_logout() {
  local had=""
  if [[ -n "$(_fleet_cloud_token_get default 2>/dev/null)" ]]; then
    had="yes"
  fi
  _fleet_cloud_token_delete "default" >/dev/null 2>&1
  local key
  for key in token_ref token_id org_id name; do
    global_config_set "cloud.${key}" 'null' >/dev/null 2>&1
  done
  if [[ -n "$had" ]]; then
    ok "Logged out. The token was removed from this machine."
    printf '  %bTo revoke it everywhere, remove it under Access at cloud.getmuster.dev.%b\n' "$DIM" "$RESET"
  else
    info "Not logged in."
  fi
}

_cloud_status() {
  local json=false
  [[ "${1:-}" == "--json" ]] && json=true
  if [[ "$json" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/engine.sh"
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
  fi
  local relay org name token base health_code
  relay=$(global_config_get "cloud.relay" 2>/dev/null)
  org=$(global_config_get "cloud.org_id" 2>/dev/null)
  name=$(global_config_get "cloud.name" 2>/dev/null)
  [[ "$relay" == "null" ]] && relay=""
  [[ "$org" == "null" ]] && org=""
  [[ "$name" == "null" ]] && name=""
  token=$(_fleet_cloud_token_get default 2>/dev/null)

  if [[ "$json" == "true" ]]; then
    local logged_in=false reachable=false tunnel=false tunnel_path=""
    [[ -n "$token" && -n "$org" ]] && logged_in=true
    [[ -z "$relay" ]] && relay="$MUSTER_CLOUD_DEFAULT_RELAY"
    base=$(_cloud_http_base "$relay")
    health_code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "${base}/healthz" 2>/dev/null)
    [[ "$health_code" == "200" ]] && reachable=true
    if _fleet_cloud_available; then
      tunnel=true
      tunnel_path=$(_fleet_cloud_bin)
    fi
    printf '{"logged_in":%s,"name":%s,"org_id":%s,"org":%s,"relay":%s,"relay_reachable":%s,"tunnel_installed":%s,"tunnel_path":%s}\n' \
      "$logged_in" "$(_json_str_or_null "$name")" "$(_json_str_or_null "$org")" "$(_json_str_or_null "$org")" \
      "$(_json_str "$base")" "$reachable" "$tunnel" "$(_json_str_or_null "$tunnel_path")"
    return 0
  fi

  echo ""
  if [[ -n "$token" && -n "$org" ]]; then
    printf '  %b●%b Logged in  %b%s%b\n' "$GREEN" "$RESET" "$DIM" "${name:-}" "$RESET"
    printf '  %bOrg:%b     %s\n' "$DIM" "$RESET" "$org"
  else
    printf '  %b○%b Not logged in  %b(run muster cloud login)%b\n' "$DIM" "$RESET" "$DIM" "$RESET"
  fi

  [[ -z "$relay" ]] && relay="$MUSTER_CLOUD_DEFAULT_RELAY"
  base=$(_cloud_http_base "$relay")
  health_code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "${base}/healthz" 2>/dev/null)
  if [[ "$health_code" == "200" ]]; then
    printf '  %bRelay:%b   %s %b(reachable)%b\n' "$DIM" "$RESET" "$base" "$GREEN" "$RESET"
  else
    printf '  %bRelay:%b   %s %b(unreachable)%b\n' "$DIM" "$RESET" "$base" "$RED" "$RESET"
  fi

  if _fleet_cloud_available; then
    printf '  %bTunnel:%b  %s\n' "$DIM" "$RESET" "$(_fleet_cloud_bin)"
  else
    printf '  %bTunnel:%b  %bnot installed%b %b(curl -fsSL https://getmuster.dev/fleet-cloud/install.sh | bash -s -- --tunnel)%b\n' \
      "$DIM" "$RESET" "$YELLOW" "$RESET" "$DIM" "$RESET"
  fi
  echo ""
  [[ -n "$token" && -n "$org" ]]
}
