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
    connect) _cloud_connect "$@" ;;
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
  echo "  login [--relay <url>] [--qr]"
  echo "                          Sign in through the browser (device code);"
  echo "                          --qr also prints a QR code (needs qrencode)"
  echo "  logout                  Forget the stored token on this machine"
  echo "  status [--json]         Show account, relay and connection status"
  echo "  connect                 Pair this server with Fleet Cloud (installs"
  echo "                          muster-agent, shows a code + QR to approve)"
  echo "                          Flags: --name <n> --project <dir> --relay <url>"
  echo "                                 --service | --no-service  --yes"
  echo ""
  echo "Environment:"
  echo "  MUSTER_CLOUD_RELAY      Relay URL (default: https://relay.getmuster.dev)"
  echo "  MUSTER_NO_BROWSER=1     Don't try to open a browser"
}

_cloud_login() {
  local relay="" qr=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --qr)
        qr=true
        shift
        ;;
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
  # "(macOS)" lets the dashboard show which kind of computer signed in.
  local os_label
  case "$(uname -s 2>/dev/null)" in
    Darwin) os_label="macOS" ;;
    Linux) os_label="Linux" ;;
    *) os_label="" ;;
  esac
  client_name="muster-cli on ${host}${os_label:+ (${os_label})}"

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
  [[ "$qr" == "true" ]] && _cloud_print_qr "$verify_complete"
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
  printf '  %bAccount:%b  %s\n' "$DIM" "$RESET" "$(_cloud_org_label "$org_id")"
  echo ""
  printf '  %bNext%b\n' "$BOLD" "$RESET"
  printf '    %bmuster cloud connect%b   on a server, to add it to your fleet\n' "$ACCENT" "$RESET"
  printf '    %bmuster ask%b             ask the assistant why a deploy failed\n' "$ACCENT" "$RESET"
  printf '    %b%s%b\n' "$DIM" "${verify_uri%/device}" "$RESET"
}

# Clerk personal accounts have org IDs like org_user_…; say so instead of
# showing the raw ID.
_cloud_org_label() {
  case "$1" in
    org_user_*) printf 'Personal account' ;;
    "") printf '(unknown)' ;;
    *) printf 'Team (%s)' "$1" ;;
  esac
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
    printf '  %bTo sign it out everywhere, use Access at cloud.getmuster.dev.%b\n' "$DIM" "$RESET"
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
    printf '  %bAccount:%b %s\n' "$DIM" "$RESET" "$(_cloud_org_label "$org")"
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

# Print a QR code of a URL when qrencode is installed and stdout is a
# terminal. Never a hard dependency: silently does nothing otherwise.
_cloud_print_qr() {
  local url="$1"
  [[ -t 1 || -n "${MUSTER_FORCE_QR:-}" ]] || return 0
  has_cmd qrencode || return 0
  echo ""
  qrencode -t ansiutf8 -m 2 "$url" 2>/dev/null | sed 's/^/  /' || true
  echo ""
}

# ── muster cloud connect: pair this machine as a Fleet Cloud server ──

MUSTER_AGENT_INSTALL_URL="${MUSTER_AGENT_INSTALL_URL:-https://getmuster.dev/fleet-cloud/install.sh}"

# Path of the muster-agent binary, or nothing
_cloud_agent_bin() {
  if command -v muster-agent >/dev/null 2>&1; then
    command -v muster-agent
  elif [[ -x "$HOME/.muster/bin/muster-agent" ]]; then
    printf '%s' "$HOME/.muster/bin/muster-agent"
  fi
}

_cloud_confirm() {
  local prompt="$1" default="$2" ans=""
  if [[ "$default" == "y" ]]; then
    printf '  %s [Y/n] ' "$prompt"
  else
    printf '  %s [y/N] ' "$prompt"
  fi
  IFS= read -r ans || ans=""
  [[ -z "$ans" ]] && ans="$default"
  case "$ans" in
    y | Y | yes | YES | Yes) return 0 ;;
  esac
  return 1
}

_cloud_connect() {
  local name="" project="" relay="" service="" yes=false update=false user_service=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 ;;
      --name=*) name="${1#--name=}"; shift ;;
      --project) project="${2:-}"; shift 2 ;;
      --project=*) project="${1#--project=}"; shift ;;
      --relay) relay="${2:-}"; shift 2 ;;
      --relay=*) relay="${1#--relay=}"; shift ;;
      --service) service="yes"; shift ;;
      --no-service) service="no"; shift ;;
      --user-service) service="yes"; user_service=true; shift ;;
      --update) update=true; shift ;;
      -y | --yes) yes=true; shift ;;
      -h | --help)
        echo "Usage: muster cloud connect [flags]"
        echo ""
        echo "Pair this server with your Fleet Cloud account. Installs muster-agent if"
        echo "needed, prints a short code and QR to approve at cloud.getmuster.dev/pair,"
        echo "then offers to run the agent as a background service."
        echo ""
        echo "Flags:"
        echo "  --name <name>      Machine name shown in Fleet Cloud (default: hostname)"
        echo "  --project <dir>    Project directory the agent deploys (default: current"
        echo "                     directory when it has a muster.json)"
        echo "  --relay <url>      Relay URL (self-hosted relays)"
        echo "  --service          Install the system service (systemd/launchd; uses sudo)"
        echo "  --user-service     Install a per-user service instead (no sudo)"
        echo "  --no-service       Don't install a service"
        echo "  --update           Reinstall muster-agent even if it is installed"
        echo "  --yes, -y          Don't ask before installing muster-agent"
        return 0
        ;;
      *)
        err "Unknown flag: $1"
        echo "Run 'muster cloud connect --help' for usage."
        return 1
        ;;
    esac
  done

  local tty=false
  [[ -t 0 && -t 1 ]] && tty=true

  # 1. muster-agent
  local agent
  agent=$(_cloud_agent_bin)
  # Agents before v0.4.0 have no `pair` command ("unknown command: pair")
  local probe=""
  [[ -n "$agent" && "$update" != "true" ]] && probe=$("$agent" pair --help 2>&1 </dev/null)
  if [[ "$probe" == *"nknown command"* ]]; then
    info "This muster-agent is too old to pair with a code (needs v0.4.0 or newer)."
    update=true
  fi
  if [[ -z "$agent" || "$update" == "true" ]]; then
    if [[ -z "$agent" ]]; then
      info "muster-agent is not installed on this machine."
    fi
    if [[ "$yes" != "true" ]]; then
      if [[ "$tty" == "true" ]]; then
        _cloud_confirm "Install the latest muster-agent now (from ${MUSTER_AGENT_INSTALL_URL})?" y || {
          info "Cancelled. Install it yourself with:"
          printf '    curl -fsSL %s | bash -s -- --agent\n' "$MUSTER_AGENT_INSTALL_URL"
          return 1
        }
      else
        err "muster-agent is required. Re-run with --yes to install it, or install it with:"
        printf '    curl -fsSL %s | bash -s -- --agent --yes\n' "$MUSTER_AGENT_INSTALL_URL"
        return 1
      fi
    fi
    if ! has_cmd curl; then
      err "curl is required to install muster-agent"
      return 1
    fi
    info "Installing muster-agent..."
    local ilog rc=0
    ilog=$(curl -fsSL "$MUSTER_AGENT_INSTALL_URL" 2>&1 | bash -s -- --agent --yes 2>&1) || rc=$?
    agent=$(_cloud_agent_bin)
    if ((rc != 0)) || [[ -z "$agent" ]]; then
      err "Installing muster-agent failed"
      printf '%s\n' "$ilog" | tail -5 | while IFS= read -r l; do printf '    %b%s%b\n' "$DIM" "$l" "$RESET"; done
      return 1
    fi
    ok "muster-agent installed (${agent})"
  fi

  # 2. Project directory
  if [[ -z "$project" ]]; then
    if [[ -f "$PWD/muster.json" || -f "$PWD/deploy.json" ]]; then
      project="$PWD"
    elif [[ "$tty" == "true" ]]; then
      printf '  Project directory on this machine %b(Enter to skip)%b: ' "$DIM" "$RESET"
      IFS= read -r project || project=""
    fi
  fi
  if [[ -n "$project" ]]; then
    project="${project/#\~/$HOME}"
    if [[ ! -d "$project" ]]; then
      err "Project directory not found: ${project}"
      return 1
    fi
    project="$(cd "$project" && pwd)"
    if [[ ! -f "$project/muster.json" && ! -f "$project/deploy.json" ]]; then
      warn "No muster.json in ${project} (run muster setup there before deploying)"
    fi
  fi

  # 3. Pair (the agent prints the code + QR and waits for approval)
  local pair_args=()
  [[ -n "$name" ]] && pair_args[${#pair_args[@]}]="--name" && pair_args[${#pair_args[@]}]="$name"
  [[ -n "$project" ]] && pair_args[${#pair_args[@]}]="--project" && pair_args[${#pair_args[@]}]="$project"
  [[ -n "$relay" ]] && pair_args[${#pair_args[@]}]="--relay" && pair_args[${#pair_args[@]}]="$relay"
  echo ""
  local prc=0
  "$agent" pair "${pair_args[@]+"${pair_args[@]}"}" || prc=$?
  if ((prc == 130)); then
    echo ""
    info "Cancelled."
    return 130
  fi
  if ((prc != 0)); then
    echo ""
    err "Pairing did not complete (muster-agent exit code ${prc})"
    printf '  %bRun muster cloud connect again to get a new code.%b\n' "$DIM" "$RESET"
    return 1
  fi
  echo ""
  ok "Paired with Fleet Cloud"

  # 4. Background service
  if [[ -z "$service" ]]; then
    if [[ "$tty" == "true" ]]; then
      if _cloud_confirm "Run muster-agent as a background service (starts at boot)?" y; then
        service="yes"
      else
        service="no"
      fi
    else
      service="no"
    fi
  fi
  local service_ok=false
  if [[ "$service" == "yes" ]]; then
    local src=0
    if [[ "$user_service" == "true" ]]; then
      "$agent" install-service --user || src=$?
    elif [[ "$(id -u 2>/dev/null)" == "0" ]]; then
      "$agent" install-service || src=$?
    elif has_cmd sudo; then
      info "Installing the system service (needs sudo)"
      sudo "$agent" install-service || src=$?
    else
      "$agent" install-service --user || src=$?
    fi
    if ((src == 0)); then
      service_ok=true
      ok "muster-agent service installed"
    else
      warn "Service install failed. Try: muster-agent install-service --user"
    fi
  else
    printf '  %bStart the agent with: muster-agent run   (or muster-agent install-service)%b\n' "$DIM" "$RESET"
  fi

  # 5. Verify the agent connects (only meaningful when it is running)
  if [[ "$service_ok" == "true" ]]; then
    local waited=0 vrc=1
    while ((waited < ${MUSTER_CONNECT_WAIT:-15})); do
      vrc=0
      "$agent" status --connected >/dev/null 2>&1 || vrc=$?
      ((vrc == 0 || vrc == 2)) && break
      sleep 1
      waited=$((waited + 1))
    done
    if ((vrc == 0)); then
      ok "Agent connected to Fleet Cloud"
    elif ((vrc == 2)); then
      info "Couldn't check the connection with this muster-agent version (muster-agent status)."
    else
      warn "The agent hasn't connected yet. Check: muster-agent status"
    fi
  fi
  echo ""
  printf '  %bThis server now shows up under Servers at cloud.getmuster.dev.%b\n' "$DIM" "$RESET"
  echo ""
}
