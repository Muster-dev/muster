#!/usr/bin/env bash
# muster/lib/commands/mcp.sh — MCP server helpers (docs/mcp.md)
#
#   muster mcp install <client> [--allow-actions] [--project DIR] [--write [--yes]]
#   muster mcp doctor [--project DIR] [--json]
#   muster mcp serve [muster-mcp flags]      (runs bin/muster-mcp)
#   muster mcp tools                         (list tool names + annotations)

_mcp_cmd_usage() {
  echo "Usage: muster mcp <command>"
  echo ""
  echo "Commands:"
  echo "  install <client>   Print the MCP config for a client (claude, claude-desktop, cursor, vscode)"
  echo "      --allow-actions  Enable deploy/rollback/restart tools (default: read-only)"
  echo "      --project DIR    Project the server attaches to (default: this project)"
  echo "      --write          Merge it into the client's config file (shows the diff first)"
  echo "      --yes            Write without asking (needed without a TTY)"
  echo "  doctor [--json]    Start the server, check the handshake and list its tools"
  echo "  serve [flags]      Run the MCP server on stdio (same as muster-mcp)"
  echo "  tools              List the tools the server exposes"
  echo ""
  echo "Docs: docs/mcp.md"
}

cmd_mcp() {
  case "${1:-}" in
    install) shift; _mcp_cmd_install "$@" ;;
    doctor) shift; _mcp_cmd_doctor "$@" ;;
    serve) shift; exec "$MUSTER_ROOT/bin/muster-mcp" "$@" ;;
    tools) shift; _mcp_cmd_tools "$@" ;;
    -h | --help | help | "") _mcp_cmd_usage ;;
    *)
      err "Unknown mcp command: $1"
      _mcp_cmd_usage
      return 1
      ;;
  esac
}

# Absolute project dir: --project, else the project muster finds, else cwd
_mcp_cmd_project() {
  local p="$1" cfg
  if [[ -n "$p" ]]; then
    [[ -d "$p" ]] || { err "Not a directory: $p"; return 1; }
    (cd "$p" && pwd)
    return 0
  fi
  if cfg=$(find_config 2>/dev/null); then
    dirname "$cfg"
  else
    pwd
  fi
}

_mcp_cmd_desktop_config() {
  if [[ -n "${MUSTER_MCP_DESKTOP_CONFIG:-}" ]]; then
    printf '%s' "$MUSTER_MCP_DESKTOP_CONFIG"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s' "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  elif [[ -n "${APPDATA:-}" ]]; then
    printf '%s' "$APPDATA/Claude/claude_desktop_config.json"
  else
    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json"
  fi
}

_mcp_cmd_install() {
  local client="" allow=false write=false yes=false project="" name="muster"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-actions) allow=true; shift ;;
      --write) write=true; shift ;;
      --yes | -y) yes=true; shift ;;
      --project | -p)
        [[ -z "${2:-}" ]] && { err "--project needs a directory"; return 1; }
        project="$2"; shift 2 ;;
      --name)
        [[ "${2:-}" =~ ^[A-Za-z0-9_-]+$ ]] || { err "--name must be letters, digits, - or _"; return 1; }
        name="$2"; shift 2 ;;
      -h | --help) _mcp_cmd_usage; return 0 ;;
      -*) err "Unknown flag: $1"; return 1 ;;
      *)
        [[ -n "$client" ]] && { err "One client at a time"; return 1; }
        client="$1"; shift ;;
    esac
  done
  case "$client" in
    claude | claude-code | claude-desktop | cursor | vscode | code) ;;
    "") err "Which client? muster mcp install claude|claude-desktop|cursor|vscode"; return 1 ;;
    *) err "Unknown client: ${client} (claude, claude-desktop, cursor, vscode)"; return 1 ;;
  esac
  [[ "$client" == "claude-code" ]] && client="claude"
  [[ "$client" == "code" ]] && client="vscode"
  has_cmd jq || { err "jq is required (brew install jq / apt install jq)"; return 1; }

  project=$(_mcp_cmd_project "$project") || return 1
  local cmd="$MUSTER_ROOT/bin/muster-mcp"
  local args_json
  args_json=$(jq -cn --arg p "$project" --argjson a "$allow" '["--project", $p] + (if $a then ["--allow-actions"] else [] end)')

  local file="" key="mcpServers" entry
  entry=$(jq -cn --arg c "$cmd" --argjson a "$args_json" '{command: $c, args: $a}')
  case "$client" in
    claude) file="$project/.mcp.json" ;;
    claude-desktop) file=$(_mcp_cmd_desktop_config) ;;
    cursor) file="$project/.cursor/mcp.json" ;;
    vscode)
      file="$project/.vscode/mcp.json"
      key="servers"
      entry=$(jq -cn --arg c "$cmd" --argjson a "$args_json" '{type: "stdio", command: $c, args: $a}')
      ;;
  esac
  local snippet
  snippet=$(jq -n --arg k "$key" --arg n "$name" --argjson e "$entry" '{($k): {($n): $e}}')

  if [[ "$write" != "true" ]]; then
    local cmdline a
    cmdline=$(printf '%q' "$cmd")
    while IFS= read -r a; do
      cmdline="${cmdline} $(printf '%q' "$a")"
    done < <(printf '%s' "$args_json" | jq -r '.[]')
    echo ""
    case "$client" in
      claude)
        printf '  %bClaude Code%b — add the server (local scope, this project only):\n\n' "$BOLD" "$RESET"
        printf '    claude mcp add %s -- %s\n\n' "$name" "$cmdline"
        printf '  %bOr share it with the repo (project scope, writes %s):%b\n\n' "$DIM" ".mcp.json" "$RESET"
        printf '    claude mcp add --scope project %s -- %s\n' "$name" "$cmdline"
        printf '\n  %bor run: muster mcp install claude --write%b\n\n' "$DIM" "$RESET"
        printf '  .mcp.json:\n\n'
        ;;
      claude-desktop) printf '  %bClaude Desktop%b — add to %s:\n\n' "$BOLD" "$RESET" "$file" ;;
      cursor) printf '  %bCursor%b — add to %s (or ~/.cursor/mcp.json for every project):\n\n' "$BOLD" "$RESET" "$file" ;;
      vscode) printf '  %bVS Code%b — add to %s:\n\n' "$BOLD" "$RESET" "$file" ;;
    esac
    printf '%s\n' "$snippet" | sed 's/^/    /'
    echo ""
    if [[ "$allow" == "true" ]]; then
      printf '  %bActions enabled:%b the client can deploy, roll back and restart (hook approvals still apply).\n' "$YELLOW" "$RESET"
    else
      printf '  %bRead-only.%b Add --allow-actions to enable deploy/rollback/restart tools.\n' "$DIM" "$RESET"
    fi
    printf '  %bWrite it for you: muster mcp install %s%s --write%b\n\n' "$DIM" "$client" "$([[ "$allow" == "true" ]] && echo " --allow-actions")" "$RESET"
    return 0
  fi

  # ── --write: merge into the client's file ──
  local old='{}'
  if [[ -f "$file" ]]; then
    if ! old=$(jq -c . "$file" 2>/dev/null) || [[ -z "$old" ]]; then
      if [[ -s "$file" ]]; then
        err "${file} is not valid JSON; fix it or add the snippet by hand (muster mcp install ${client})"
        return 1
      fi
      old='{}'
    fi
  fi
  local new
  new=$(printf '%s' "$old" | jq --arg k "$key" --arg n "$name" --argjson e "$entry" '.[$k] = ((.[$k] // {}) + {($n): $e})') || {
    err "Could not merge the config"
    return 1
  }
  if [[ "$(printf '%s' "$old" | jq -S .)" == "$(printf '%s' "$new" | jq -S .)" ]]; then
    ok "${file} already has this configuration"
    return 0
  fi
  local tmp_new
  tmp_new=$(mktemp "${TMPDIR:-/tmp}/muster-mcp-cfg.XXXXXX")
  printf '%s\n' "$new" >"$tmp_new"
  echo ""
  printf '  %b%s%b\n\n' "$BOLD" "$file" "$RESET"
  local src="$file"
  [[ -f "$src" ]] || src=/dev/null
  diff -u "$src" "$tmp_new" 2>/dev/null | sed "1s|.*|--- ${file}|; 2s|.*|+++ ${file} (new)|" | while IFS= read -r line; do
    case "$line" in
      '+++'* | '---'*) printf '  %b%s%b\n' "$BOLD" "$line" "$RESET" ;;
      '+'*) printf '  %b%s%b\n' "$GREEN" "$line" "$RESET" ;;
      '-'*) printf '  %b%s%b\n' "$RED" "$line" "$RESET" ;;
      *) printf '  %s\n' "$line" ;;
    esac
  done
  echo ""
  if [[ "$yes" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      rm -f "$tmp_new"
      err "Not writing without confirmation: pass --yes (no TTY)"
      return 1
    fi
    local ans=""
    printf '  Write this? [y/N] '
    IFS= read -r ans || ans=""
    case "$ans" in
      y | Y | yes | YES) ;;
      *) rm -f "$tmp_new"; info "Nothing written"; return 0 ;;
    esac
  fi
  mkdir -p "$(dirname "$file")" || { rm -f "$tmp_new"; err "Cannot create $(dirname "$file")"; return 1; }
  if [[ -f "$file" ]]; then
    cp -p "$file" "${file}.bak" 2>/dev/null || true
    cat "$tmp_new" >"$file" || { rm -f "$tmp_new"; err "Cannot write ${file}"; return 1; }
  else
    mv "$tmp_new" "$file" || { rm -f "$tmp_new"; err "Cannot write ${file}"; return 1; }
  fi
  rm -f "$tmp_new"
  ok "Wrote ${file}$([[ -f "${file}.bak" ]] && printf ' (previous version: %s.bak)' "$file")"
  case "$client" in
    claude-desktop) info "Restart Claude Desktop to load it" ;;
    claude) info "Claude Code asks to approve project servers from .mcp.json on next start" ;;
    cursor) info "Enable it in Cursor → Settings → MCP" ;;
    vscode) info "Start it from the MCP view (or 'MCP: List Servers') in VS Code" ;;
  esac
  return 0
}

_mcp_cmd_tools() {
  has_cmd jq || { err "jq is required"; return 1; }
  "$MUSTER_ROOT/bin/muster-mcp" --list-tools 2>/dev/null | jq -r '.[] |
    "\(.name)\t\(if .annotations.readOnlyHint then "read" elif .annotations.destructiveHint then "action, destructive" else "action" end)\t\(.title)"' |
    while IFS=$'\t' read -r n k t; do
      printf '  %-16s %-22s %s\n' "$n" "$k" "$t"
    done
}

# Start the server, send a handshake, and check the answers
_mcp_cmd_doctor() {
  local json=false project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=true; shift ;;
      --project | -p) project="${2:-}"; shift 2 ;;
      -h | --help) _mcp_cmd_usage; return 0 ;;
      *) err "Unknown flag: $1"; return 1 ;;
    esac
  done
  local checks="" failures=0
  _mcp_doc_check() { # name status detail
    checks="${checks}$(jq -cn --arg n "$1" --arg s "$2" --arg d "$3" '{name: $n, status: $s, detail: $d}')"$'\n'
    [[ "$2" == "fail" ]] && failures=$((failures + 1))
    return 0
  }
  if ! has_cmd jq; then
    if [[ "$json" == "true" ]]; then
      printf '{"ok":false,"checks":[{"name":"jq","status":"fail","detail":"jq is not installed"}]}\n'
    else
      err "jq is not installed (brew install jq / apt install jq): muster-mcp needs it"
    fi
    return 1
  fi
  _mcp_doc_check "jq" pass "$(jq --version 2>/dev/null)"
  local srv="$MUSTER_ROOT/bin/muster-mcp"
  if [[ -x "$srv" ]] && bash -n "$srv" 2>/dev/null; then
    _mcp_doc_check "server script" pass "$srv"
  else
    _mcp_doc_check "server script" fail "$srv is missing, not executable or has a syntax error"
  fi
  project=$(_mcp_cmd_project "$project") || return 1

  local out tmp in_f spid wdog
  tmp=$(mktemp "${TMPDIR:-/tmp}/muster-mcp-doctor.XXXXXX")
  in_f="${tmp}.in"
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"muster-mcp-doctor","version":"1"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"resources/list"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"prompts/list"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"project_info","arguments":{}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
  } >"$in_f"
  "$srv" --project "$project" <"$in_f" >"$tmp" 2>/dev/null &
  spid=$!
  ( sleep 60; kill -TERM "$spid" 2>/dev/null ) >/dev/null 2>&1 &
  wdog=$!
  wait "$spid" 2>/dev/null
  _kill_tree "$wdog" 2>/dev/null
  wait "$wdog" 2>/dev/null
  out=$(cat "$tmp")
  rm -f "$tmp" "$in_f"
  local r
  _mcp_doc_r() { printf '%s\n' "$out" | jq -c --argjson id "$1" 'select(.id == $id)' 2>/dev/null | head -1; }
  if ! printf '%s\n' "$out" | jq -e -s 'length > 0 and all(.jsonrpc == "2.0")' >/dev/null 2>&1; then
    _mcp_doc_check "stdout is JSON-RPC" fail "the server printed something that is not JSON-RPC"
  else
    _mcp_doc_check "stdout is JSON-RPC" pass "$(printf '%s\n' "$out" | grep -c .) messages"
  fi
  r=$(_mcp_doc_r 1)
  if [[ -n "$r" ]] && printf '%s' "$r" | jq -e '.result.protocolVersion' >/dev/null 2>&1; then
    _mcp_doc_check "initialize" pass "protocol $(printf '%s' "$r" | jq -r .result.protocolVersion), $(printf '%s' "$r" | jq -r '.result.serverInfo | "\(.name) \(.version)"')"
  else
    _mcp_doc_check "initialize" fail "no initialize result"
  fi
  r=$(_mcp_doc_r 6)
  if printf '%s' "$r" | jq -e '.result.supportedVersions | index("2026-07-28")' >/dev/null 2>&1; then
    _mcp_doc_check "server/discover" pass "supports $(printf '%s' "$r" | jq -r '.result.supportedVersions | join(", ")')"
  else
    _mcp_doc_check "server/discover" fail "no server/discover result"
  fi
  local ntools nres nprompts
  ntools=$(_mcp_doc_r 2 | jq -r '.result.tools | length' 2>/dev/null)
  nres=$(_mcp_doc_r 3 | jq -r '.result.resources | length' 2>/dev/null)
  nprompts=$(_mcp_doc_r 4 | jq -r '.result.prompts | length' 2>/dev/null)
  if [[ "${ntools:-0}" =~ ^[0-9]+$ ]] && ((ntools > 0)); then
    _mcp_doc_check "tools/list" pass "${ntools} tools: $(_mcp_doc_r 2 | jq -r '[.result.tools[].name] | join(", ")')"
  else
    _mcp_doc_check "tools/list" fail "no tools"
  fi
  _mcp_doc_check "resources/list" "$([[ "${nres:-0}" =~ ^[1-9] ]] && echo pass || echo fail)" "${nres:-0} resources"
  _mcp_doc_check "prompts/list" "$([[ "${nprompts:-0}" =~ ^[1-9] ]] && echo pass || echo fail)" "${nprompts:-0} prompts"
  r=$(_mcp_doc_r 5)
  if printf '%s' "$r" | jq -e '.result.structuredContent.found == true' >/dev/null 2>&1; then
    _mcp_doc_check "project" pass "$(printf '%s' "$r" | jq -r '.result.structuredContent | "\(.project) (\(.services | length) services) at \(.root)"')"
  elif printf '%s' "$r" | jq -e '.result.structuredContent.found == false' >/dev/null 2>&1; then
    _mcp_doc_check "project" warn "no muster.json in ${project}: pass --project <dir> in the client config"
  else
    _mcp_doc_check "project" fail "project_info call failed"
  fi

  if [[ "$json" == "true" ]]; then
    printf '%s' "$checks" | jq -sc --argjson f "$failures" --argjson n "${ntools:-0}" '{ok: ($f == 0), tools: $n, checks: .}'
  else
    echo ""
    printf '  %bMCP server%b\n\n' "$BOLD" "$RESET"
    printf '%s' "$checks" | jq -r '"\(.status)\t\(.name)\t\(.detail)"' | while IFS=$'\t' read -r s n d; do
      case "$s" in
        pass) printf '  %b✓%b %s %b%s%b\n' "$GREEN" "$RESET" "$n" "$DIM" "$d" "$RESET" ;;
        warn) printf '  %b!%b %s %b%s%b\n' "$YELLOW" "$RESET" "$n" "$DIM" "$d" "$RESET" ;;
        *) printf '  %bx%b %s %b%s%b\n' "$RED" "$RESET" "$n" "$DIM" "$d" "$RESET" ;;
      esac
    done
    echo ""
    if ((failures == 0)); then
      ok "Server works. Configure a client: muster mcp install claude|claude-desktop|cursor|vscode"
    else
      err "${failures} check(s) failed"
    fi
    echo ""
  fi
  ((failures == 0))
}
