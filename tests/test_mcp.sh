#!/usr/bin/env bash
# tests/test_mcp.sh — bin/muster-mcp over stdio (JSON-RPC 2.0, MCP)
#
# Drives the server with real JSON-RPC lines against a fixture project.
# docker/kubectl/ssh are fakes (tests/mock_helpers.sh); HOME is a temp dir.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/mock_helpers.sh"
command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
trap '_mock_cleanup; rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MUSTER_NO_VERIFY=true NO_COLOR=1 MUSTER_CLOUD_NO_KEYCHAIN=1
unset MUSTER_TOKEN MUSTER_MCP_ALLOW_ACTIONS MUSTER_PROJECT MUSTER_APPROVE_HOOKS
mkdir -p "$HOME" "$TMP/p" "$TMP/scan/api" "$TMP/elsewhere"
printf 'services:\n  api:\n    build: ./api\n    ports: ["8080:8080"]\n' > "$TMP/scan/docker-compose.yml"
printf 'FROM node\nEXPOSE 8080\n' > "$TMP/scan/api/Dockerfile"
M="$MUSTER_ROOT/bin/muster"
MCP="$MUSTER_ROOT/bin/muster-mcp"

_mock_init
# ssh: "echo ok" for connectivity, run piped scripts locally for push mode
_mock_cmd ssh 'for a in "$@"; do last="$a"; done; case "$last" in "echo ok") echo ok ;; "bash -s") bash -s ;; *) exit 0 ;; esac'

# ── Fixture project ──
cd "$TMP/p" || exit 1
"$M" setup --services api,web --stack bare --health api=none --health web=none --name mcpfix --force >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho "api deployed token=supersecretvalue123"\n' > .muster/hooks/api/deploy.sh
printf '#!/usr/bin/env bash\necho "web deployed"\n' > .muster/hooks/web/deploy.sh
printf '#!/usr/bin/env bash\necho "api log line one"\necho "DB_PASSWORD=hunter2hunter2"\n' > .muster/hooks/api/logs.sh
chmod +x .muster/hooks/*/*.sh
printf 'API_SECRET_KEY=literal-env-value-xyz\n' > .env
jq '.services.api.env = {"DATABASE_URL": "postgres://u:pw@db/x"}' muster.json > m.tmp && mv m.tmp muster.json
cat > remotes.json <<'EOF'
{"machines":{"pusher":{"host":"10.0.0.8","user":"deploy","mode":"push","project_dir":"/srv/app"}},
 "groups":{"edge":["pusher"]},"deploy_order":["edge"]}
EOF
cd "$TMP/elsewhere" || exit 1

INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
INITED='{"jsonrpc":"2.0","method":"notifications/initialized"}'

# Run a session: _mcp [server flags…] -- line…  → all stdout lines
_mcp() {
  local flags=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do flags[${#flags[@]}]="$1"; shift; done
  shift
  printf '%s\n' "$@" | "$MCP" ${flags[@]+"${flags[@]}"} 2>>"$TMP/stderr.log"
}
# Response for an id
_resp() { printf '%s\n' "$1" | jq -c --argjson id "$2" 'select(.id == $id)'; }
_call() {
  local a='{}'
  [[ -n "${3:-}" ]] && a="$3"
  printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$a"
}

P=(--project "$TMP/p")

# ── Protocol: legacy handshake ──
echo "  protocol (legacy initialize)"
out=$(_mcp "${P[@]}" -- "$INIT" "$INITED" '{"jsonrpc":"2.0","id":1,"method":"ping"}')
r=$(_resp "$out" 0)
_test_eq "negotiates the requested version" "2025-06-18" "$(printf '%s' "$r" | jq -r .result.protocolVersion)"
_test_eq "serverInfo name" "muster" "$(printf '%s' "$r" | jq -r .result.serverInfo.name)"
_test_eq "capabilities" "completions,logging,prompts,resources,tools" "$(printf '%s' "$r" | jq -r '.result.capabilities | keys | join(",")')"
_test "has instructions" bash -c 'printf "%s" "$1" | jq -e ".result.instructions | length > 20" >/dev/null' _ "$r"
_test_eq "notification gets no response" "2" "$(printf '%s\n' "$out" | grep -c .)"
_test_eq "ping → {}" "{}" "$(_resp "$out" 1 | jq -c .result)"
out=$(_mcp "${P[@]}" -- '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{}}}')
_test_eq "unknown version → latest legacy" "2025-11-25" "$(_resp "$out" 1 | jq -r .result.protocolVersion)"
out=$(_mcp "${P[@]}" -- '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}')
_test_eq "oldest version accepted" "2024-11-05" "$(_resp "$out" 1 | jq -r .result.protocolVersion)"
_test "every stdout line is JSON-RPC" bash -c 'printf "%s\n" "$1" | jq -e -s "all(.jsonrpc == \"2.0\")" >/dev/null' _ "$out"

# ── Protocol: modern (2026-07-28) ──
echo "  protocol (2026-07-28 stateless)"
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
out=$(_mcp "${P[@]}" -- "{\"jsonrpc\":\"2.0\",\"id\":\"d\",\"method\":\"server/discover\",\"params\":{${META}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{${META}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"project_info\",\"arguments\":{},${META}}}" \
  '{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/list"}')
r=$(_resp "$out" '"d"')
_test_eq "discover lists versions" "2026-07-28,2025-11-25,2025-06-18,2025-03-26,2024-11-05" "$(printf '%s' "$r" | jq -r '.result.supportedVersions | join(",")')"
_test_eq "discover resultType" "complete" "$(printf '%s' "$r" | jq -r .result.resultType)"
_test_eq "serverInfo in _meta" "muster" "$(printf '%s' "$r" | jq -r '.result._meta["io.modelcontextprotocol/serverInfo"].name')"
_test "discover has ttlMs/cacheScope" bash -c 'printf "%s" "$1" | jq -e ".result.ttlMs > 0 and .result.cacheScope == \"public\"" >/dev/null' _ "$r"
_test_eq "modern tools/list resultType" "complete" "$(_resp "$out" 2 | jq -r .result.resultType)"
_test_eq "modern tools/call works" "mcpfix" "$(_resp "$out" 3 | jq -r .result.structuredContent.project)"
_test_eq "unsupported version → -32022" "-32022" "$(_resp "$out" 4 | jq -r .error.code)"
_test_eq "error data names versions" "1900-01-01" "$(_resp "$out" 4 | jq -r .error.data.requested)"
_test_eq "no version, no initialize → -32602" "-32602" "$(_resp "$out" 5 | jq -r .error.code)"

# ── JSON-RPC errors ──
echo "  JSON-RPC errors"
out=$(_mcp "${P[@]}" -- "$INIT" 'not json' '{"jsonrpc":"2.0","id":7,"method":"nope/nope"}' '{"id":8,"method":"ping"}' \
  "$(_call 9 no_such_tool)" '{"jsonrpc":"2.0","id":10,"method":"logging/setLevel","params":{"level":"loud"}}' \
  '{"jsonrpc":"2.0","id":11,"method":"logging/setLevel","params":{"level":"warning"}}' \
  '[{"jsonrpc":"2.0","id":12,"method":"ping"},{"jsonrpc":"2.0","id":13,"method":"ping"}]')
_test_eq "parse error" "-32700" "$(printf '%s\n' "$out" | jq -r 'select(.id == null) | .error.code' | head -1)"
_test_eq "method not found" "-32601" "$(_resp "$out" 7 | jq -r .error.code)"
_test_eq "invalid request (no jsonrpc)" "-32600" "$(_resp "$out" 8 | jq -r .error.code)"
_test_eq "unknown tool → -32602" "-32602" "$(_resp "$out" 9 | jq -r .error.code)"
_test_eq "bad log level → -32602" "-32602" "$(_resp "$out" 10 | jq -r .error.code)"
_test_eq "setLevel ok" "{}" "$(_resp "$out" 11 | jq -c .result)"
_test_eq "batch elements answered" "{}|{}" "$(_resp "$out" 12 | jq -c .result)|$(_resp "$out" 13 | jq -c .result)"

# ── tools/list ──
echo "  tools/list"
out=$(_mcp "${P[@]}" -- "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
tools=$(_resp "$out" 1 | jq -c .result.tools)
_test_eq "21 tools" "21" "$(printf '%s' "$tools" | jq length)"
_test_eq "all names" "config_get,deploy,doctor,explain,fleet_deploy,fleet_history,fleet_list,fleet_logs,fleet_restart,fleet_rollback,fleet_status,fleet_test,history,hooks_approve,hooks_status,logs,project_info,restart,rollback,setup_preview,status" \
  "$(printf '%s' "$tools" | jq -r 'map(.name) | sort | join(",")')"
_test "every inputSchema is a closed object schema" bash -c 'printf "%s" "$1" | jq -e "all(.[]; .inputSchema.type == \"object\" and (.inputSchema.properties | type) == \"object\" and .inputSchema.additionalProperties == false and ((.inputSchema.required // []) - (.inputSchema.properties | keys) | length == 0))" >/dev/null' _ "$tools"
_test "every tool has outputSchema of type object" bash -c 'printf "%s" "$1" | jq -e "all(.[]; .outputSchema.type == \"object\")" >/dev/null' _ "$tools"
_test "every tool has all four annotation hints" bash -c 'printf "%s" "$1" | jq -e "all(.[]; .annotations | (.readOnlyHint|type) == \"boolean\" and (.destructiveHint|type) == \"boolean\" and (.idempotentHint|type) == \"boolean\" and (.openWorldHint|type) == \"boolean\")" >/dev/null' _ "$tools"
_test_eq "read-only tools" "config_get,doctor,explain,fleet_history,fleet_list,fleet_logs,fleet_status,fleet_test,history,hooks_status,logs,project_info,setup_preview,status" \
  "$(printf '%s' "$tools" | jq -r '[.[] | select(.annotations.readOnlyHint) | .name] | sort | join(",")')"
_test_eq "destructive tools" "deploy,fleet_deploy,fleet_restart,fleet_rollback,restart,rollback" \
  "$(printf '%s' "$tools" | jq -r '[.[] | select(.annotations.destructiveHint) | .name] | sort | join(",")')"
_test_eq "deploy dry_run defaults to true" "true" "$(printf '%s' "$tools" | jq '.[] | select(.name=="deploy") | .inputSchema.properties.dry_run.default')"
_test_contains "action tools say how to enable" "--allow-actions" "$(printf '%s' "$tools" | jq -r '.[] | select(.name=="rollback") | .description')"
_test "no internal fields leak" bash -c 'printf "%s" "$1" | jq -e "all(.[]; has(\"_action\") | not)" >/dev/null' _ "$tools"
_test "--list-tools prints the same list" bash -c '[[ "$("$1" --list-tools 2>/dev/null | jq length)" == 21 ]]' _ "$MCP"

# ── Read tools ──
echo "  read tools"
out=$(_mcp "${P[@]}" -- "$INIT" "$(_call 1 project_info)" "$(_call 2 status)" "$(_call 3 status '{"services":["api"]}')" \
  "$(_call 4 logs '{"service":"api","tail":5}')" "$(_call 5 history)" "$(_call 6 hooks_status)" "$(_call 7 config_get)" \
  "$(_call 8 doctor)" "$(_call 9 explain)" "$(_call 10 setup_preview "{\"path\":\"$TMP/scan\"}")" "$(_call 11 fleet_list)" \
  "$(_call 12 fleet_test '{"target":"pusher"}')")
r=$(_resp "$out" 1)
_test_eq "project_info services" "api,web" "$(printf '%s' "$r" | jq -r '[.result.structuredContent.services[].key] | join(",")')"
_test_eq "project_info actions disabled" "false" "$(printf '%s' "$r" | jq -r .result.structuredContent.actions_enabled)"
_test_eq "project_info text mirrors structured" "mcpfix" "$(printf '%s' "$r" | jq -r '.result.content[0].text | fromjson | .project')"
_test_eq "status both services" "api,web" "$(_resp "$out" 2 | jq -r '.result.structuredContent.services | keys | join(",")')"
_test_eq "status filter" "api" "$(_resp "$out" 3 | jq -r '.result.structuredContent.services | keys | join(",")')"
r=$(_resp "$out" 4)
_test_eq "logs not an error" "false" "$(printf '%s' "$r" | jq -r .result.isError)"
_test_contains "logs lines" "api log line one" "$(printf '%s' "$r" | jq -r '.result.structuredContent.lines | join("\n")')"
_test_not_contains "logs redacted" "hunter2hunter2" "$r"
_test_eq "history entries array" "array" "$(_resp "$out" 5 | jq -r '.result.structuredContent.entries | type')"
_test_eq "hooks_status shape" "boolean" "$(_resp "$out" 6 | jq -r '.result.structuredContent.approved | type')"
r=$(_resp "$out" 7)
_test_eq "config_get project" "mcpfix" "$(printf '%s' "$r" | jq -r .result.structuredContent.config.project)"
_test_not_contains "config_get hides env values" "pw@db" "$r"
_test_eq "doctor checks" "array" "$(_resp "$out" 8 | jq -r '.result.structuredContent.checks | type')"
_test "explain answers (structured)" bash -c 'printf "%s" "$1" | jq -e ".result.structuredContent | type == \"object\"" >/dev/null' _ "$(_resp "$out" 9)"
_test_eq "setup_preview scans the path" "api" "$(_resp "$out" 10 | jq -r '[.result.structuredContent.services[].key] | join(",")')"
_test_eq "fleet_list machines" "pusher" "$(_resp "$out" 11 | jq -r '[.result.structuredContent.machines[].name] | join(",")')"
_test_eq "fleet_test passes (mock ssh)" "1" "$(_resp "$out" 12 | jq -r .result.structuredContent.passed)"
_test "the scoped token never appears in output" bash -c '! printf "%s" "$1" | grep -qF "$(cat "$2/.muster/mcp/read-token")"' _ "$out" "$HOME"
_test "scoped read token minted 0600" bash -c '[[ -f "$1/.muster/mcp/read-token" && "$(stat -f %Lp "$1/.muster/mcp/read-token" 2>/dev/null || stat -c %a "$1/.muster/mcp/read-token")" == 600 ]]' _ "$HOME"
_test_eq "read token has read scope" "read" "$(jq -r '.tokens[] | select(.name=="muster-mcp-read") | .scope' "$HOME/.muster/tokens/auth.json")"
_test "no deploy token without --allow-actions" bash -c '[[ ! -f "$1/.muster/mcp/deploy-token" ]]' _ "$HOME"

# ── Validation ──
echo "  argument validation"
out=$(_mcp "${P[@]}" -- "$INIT" "$(_call 1 logs '{}')" "$(_call 2 logs '{"service":"nope"}')" \
  "$(_call 3 logs '{"service":"api; rm -rf /"}')" "$(_call 4 logs '{"service":"api","tail":5000}')" \
  "$(_call 5 status '{"bogus":1}')" "$(_call 6 history '{"all":"yes"}')" "$(_call 7 fleet_status '{"target":"nosuch"}')" \
  "$(_call 8 setup_preview '{"path":"/tmp/$(whoami)"}')" "$(_call 9 logs '{"service":["api"]}')")
for i in 1 2 3 4 5 6 7 8 9; do
  _test_eq "bad input $i → isError result" "true" "$(_resp "$out" "$i" | jq -r .result.isError)"
done
_test_contains "missing arg named" "service: required" "$(_resp "$out" 1 | jq -r .result.content[0].text)"
_test_contains "unknown service lists known" "Known services: api, web" "$(_resp "$out" 2 | jq -r .result.content[0].text)"
_test_contains "metacharacters rejected by pattern" "invalid value" "$(_resp "$out" 3 | jq -r .result.content[0].text)"
_test_contains "range checked" "<= 1000" "$(_resp "$out" 4 | jq -r .result.content[0].text)"
_test_contains "unknown argument" "unknown argument" "$(_resp "$out" 5 | jq -r .result.content[0].text)"
_test_contains "type checked" "expected boolean" "$(_resp "$out" 6 | jq -r .result.content[0].text)"
_test_contains "unknown fleet target" "Unknown fleet" "$(_resp "$out" 7 | jq -r .result.content[0].text)"
_test_contains "path metacharacters" "metacharacters" "$(_resp "$out" 8 | jq -r .result.content[0].text)"

# ── Actions refused without --allow-actions ──
echo "  actions (read-only server)"
out=$(_mcp "${P[@]}" -- "$INIT" "$(_call 1 deploy '{"services":["api"]}')" "$(_call 2 rollback '{"service":"api"}')" \
  "$(_call 3 hooks_approve '{"all":true}')" "$(_call 4 fleet_deploy '{"target":"pusher"}')")
for i in 1 2 3 4; do
  _test_eq "action $i refused" "actions_disabled" "$(_resp "$out" "$i" | jq -r .result.structuredContent.error)"
done
_test_contains "explains how to enable" "--allow-actions" "$(_resp "$out" 1 | jq -r .result.content[0].text)"
_test_eq "nothing deployed" "0" "$(grep -c deploy "$TMP/p/.muster/logs/deploy-events.log" 2>/dev/null || echo 0)"
out=$(MUSTER_MCP_ALLOW_ACTIONS=1 _mcp "${P[@]}" --read-only -- "$INIT" "$(_call 1 deploy '{"services":["api"]}')")
_test_eq "--read-only beats the env var" "actions_disabled" "$(_resp "$out" 1 | jq -r .result.structuredContent.error)"

# ── Actions with --allow-actions ──
echo "  actions (--allow-actions)"
A=("${P[@]}" --allow-actions)
out=$(_mcp "${A[@]}" -- "$INIT" "$(_call 1 deploy '{}')" "$(_call 2 deploy '{"services":["api"]}')")
_test_contains "deploy needs explicit services" "Name the services" "$(_resp "$out" 1 | jq -r .result.content[0].text)"
r=$(_resp "$out" 2)
_test_eq "default is a dry run" "dry_run" "$(printf '%s' "$r" | jq -r '[.result.structuredContent.events[].event] | map(select(. == "dry_run")) | first')"
_test_eq "dry run ok" "false" "$(printf '%s' "$r" | jq -r .result.isError)"
_test "deploy-scoped token minted" bash -c '[[ -f "$1/.muster/mcp/deploy-token" ]]' _ "$HOME"
_test_eq "deploy token scope" "deploy" "$(jq -r '.tokens[] | select(.name=="muster-mcp-deploy") | .scope' "$HOME/.muster/tokens/auth.json")"
# Hooks were edited after setup → not approved → real deploy blocked
out=$(_mcp "${A[@]}" -- "$INIT" "$(_call 1 deploy '{"services":["api"],"dry_run":false}')")
r=$(_resp "$out" 1)
_test_eq "unapproved hooks block the deploy" "hooks_not_approved" "$(printf '%s' "$r" | jq -r .result.structuredContent.error.reason)"
_test_eq "blocked deploy is an error" "true" "$(printf '%s' "$r" | jq -r .result.isError)"
_test_contains "points at hooks_approve" "hooks_approve" "$(printf '%s' "$r" | jq -r .result.structuredContent.next_step)"
_test_not_contains "MUSTER_APPROVE_HOOKS in env is ignored" "deployed" "$(MUSTER_APPROVE_HOOKS=1 _mcp "${A[@]}" -- "$INIT" "$(_call 1 deploy '{"services":["api"],"dry_run":false}')" | jq -r '.result.structuredContent.summary.deployed // 0' | grep -v '^0$')"
out=$(_mcp "${A[@]}" -- "$INIT" "$(_call 1 hooks_approve '{}')" "$(_call 2 hooks_approve '{"services":["api","web"]}')")
_test_contains "approve needs explicit services" "Name the services" "$(_resp "$out" 1 | jq -r .result.content[0].text)"
_test_eq "approve named services" "true" "$(_resp "$out" 2 | jq -r .result.structuredContent.ok)"
out=$(_mcp "${A[@]}" -- "$INIT" "$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"deploy","arguments":{"services":["api"],"dry_run":false},"_meta":{"progressToken":"pt-1"}}}')")
r=$(_resp "$out" 1)
_test_eq "real deploy succeeds" "1" "$(printf '%s' "$r" | jq -r .result.structuredContent.summary.deployed)"
_test_contains "log tail returned" "api deployed" "$(printf '%s' "$r" | jq -r '.result.structuredContent.log_tail | join("\n")')"
_test_not_contains "deploy output redacted" "supersecretvalue123" "$r"
prog=$(printf '%s\n' "$out" | jq -c 'select(.method == "notifications/progress") | .params')
_test "progress notifications sent" bash -c '[[ -n "$1" ]]' _ "$prog"
_test_eq "progress carries the token" "pt-1" "$(printf '%s\n' "$prog" | jq -r .progressToken | sort -u)"
_test "progress increases" bash -c 'printf "%s\n" "$1" | jq -s -e "[.[].progress] as \$p | \$p == (\$p | sort) and (\$p | unique | length) == (\$p | length)" >/dev/null' _ "$prog"
_test_eq "history records source mcp" "mcp" "$(tail -1 "$TMP/p/.muster/logs/deploy-events.log" | jq -r .source)"
out=$(_mcp "${A[@]}" -- "$INIT" "$(_call 1 fleet_deploy '{"target":"edge"}')" "$(_call 2 rollback '{"service":"nope"}')")
r=$(_resp "$out" 1)
_test_eq "fleet_deploy defaults to dry run" "true" "$(printf '%s' "$r" | jq -r .result.structuredContent.dry_run)"
_test_contains "fleet dry-run plan" "pusher" "$(printf '%s' "$r" | jq -r '.result.structuredContent.output | join("\n")')"
_test_contains "rollback validates service" "unknown_service" "$(_resp "$out" 2 | jq -r .result.content[1].text)"

# ── Logging notifications ──
echo "  logging"
out=$(_mcp "${A[@]}" -- "$INIT" '{"jsonrpc":"2.0","id":1,"method":"logging/setLevel","params":{"level":"info"}}' "$(_call 2 deploy '{"services":["web"]}')")
_test_contains "notifications/message at info" "deploy web" "$(printf '%s\n' "$out" | jq -r 'select(.method == "notifications/message") | .params.data')"
out=$(_mcp "${A[@]}" -- "$INIT" "$(_call 2 deploy '{"services":["web"]}')")
_test_eq "no log notifications before setLevel" "0" "$(printf '%s\n' "$out" | jq -c 'select(.method == "notifications/message")' | grep -c .)"

# ── Resources ──
echo "  resources"
out=$(_mcp "${P[@]}" -- "$INIT" '{"jsonrpc":"2.0","id":1,"method":"resources/list"}' '{"jsonrpc":"2.0","id":2,"method":"resources/templates/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"muster://project"}}' \
  '{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"muster://config"}}' \
  '{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"muster://services/api"}}' \
  '{"jsonrpc":"2.0","id":6,"method":"resources/read","params":{"uri":"muster://logs/api"}}' \
  '{"jsonrpc":"2.0","id":7,"method":"resources/read","params":{"uri":"muster://history"}}' \
  '{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{"uri":"muster://fleet"}}' \
  '{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{"uri":"muster://services/nope"}}' \
  '{"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"file:///etc/passwd"}}')
_test_contains "list has fixed resources" "muster://project muster://config muster://history muster://fleet" "$(_resp "$out" 1 | jq -r '[.result.resources[].uri] | join(" ")')"
_test_contains "list has per-service resources" "muster://services/api" "$(_resp "$out" 1 | jq -r '[.result.resources[].uri] | join(" ")')"
_test_eq "templates" "muster://services/{name},muster://logs/{service}" "$(_resp "$out" 2 | jq -r '[.result.resourceTemplates[].uriTemplate] | join(",")')"
_test_eq "project resource" "mcpfix" "$(_resp "$out" 3 | jq -r '.result.contents[0].text | fromjson | .project')"
_test_eq "project mime" "application/json" "$(_resp "$out" 3 | jq -r '.result.contents[0].mimeType')"
_test_not_contains "config resource redacted" "pw@db" "$(_resp "$out" 4)"
_test_eq "service resource" "api|string|string" "$(_resp "$out" 5 | jq -r '.result.contents[0].text | fromjson | "\(.service)|\(.status.status | type)|\(.config.name | type)"')"
_test_contains "logs resource text" "api log line one" "$(_resp "$out" 6 | jq -r '.result.contents[0].text')"
_test_eq "logs mime" "text/plain" "$(_resp "$out" 6 | jq -r '.result.contents[0].mimeType')"
_test_not_contains "logs resource redacted" "hunter2hunter2" "$(_resp "$out" 6)"
_test_eq "history resource is an array" "array" "$(_resp "$out" 7 | jq -r '.result.contents[0].text | fromjson | type')"
_test_eq "fleet resource" "pusher" "$(_resp "$out" 8 | jq -r '.result.contents[0].text | fromjson | .machines[0].name')"
_test_eq "unknown service → -32002 (legacy)" "-32002" "$(_resp "$out" 9 | jq -r .error.code)"
_test_eq "foreign uri → not found" "file:///etc/passwd" "$(_resp "$out" 10 | jq -r .error.data.uri)"
out=$(_mcp "${P[@]}" -- "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/read\",\"params\":{\"uri\":\"muster://nope\",${META}}}")
_test_eq "not found → -32602 (2026-07-28)" "-32602" "$(_resp "$out" 1 | jq -r .error.code)"

# ── Prompts / completion ──
echo "  prompts"
out=$(_mcp "${P[@]}" -- "$INIT" '{"jsonrpc":"2.0","id":1,"method":"prompts/list"}' \
  '{"jsonrpc":"2.0","id":2,"method":"prompts/get","params":{"name":"diagnose_failure","arguments":{"service":"api"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"deploy_checklist","arguments":{"services":"api, web"}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"rollback_plan","arguments":{"service":"api"}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"rollback_plan","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"prompts/get","params":{"name":"rollback_plan","arguments":{"service":"nope"}}}' \
  '{"jsonrpc":"2.0","id":7,"method":"prompts/get","params":{"name":"nope"}}' \
  '{"jsonrpc":"2.0","id":8,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"rollback_plan"},"argument":{"name":"service","value":"a"}}}')
_test_eq "three prompts" "deploy_checklist,diagnose_failure,rollback_plan" "$(_resp "$out" 1 | jq -r '[.result.prompts[].name] | sort | join(",")')"
_test_contains "diagnose mentions service" '"api"' "$(_resp "$out" 2 | jq -r '.result.messages[0].content.text')"
_test_eq "messages are user text" "user|text" "$(_resp "$out" 2 | jq -r '.result.messages[0] | "\(.role)|\(.content.type)"')"
_test_contains "checklist uses services" '["api","web"]' "$(_resp "$out" 3 | jq -r '.result.messages[0].content.text')"
_test_contains "rollback plan has history context" "Context from muster" "$(_resp "$out" 4 | jq -r '.result.messages[1].content.text')"
_test_eq "missing required arg → -32602" "-32602" "$(_resp "$out" 5 | jq -r .error.code)"
_test_eq "unknown service arg → -32602" "-32602" "$(_resp "$out" 6 | jq -r .error.code)"
_test_eq "unknown prompt → -32602" "-32602" "$(_resp "$out" 7 | jq -r .error.code)"
_test_eq "completion of service names" "api" "$(_resp "$out" 8 | jq -r '.result.completion.values | join(",")')"

# ── Cancellation ──
echo "  cancellation"
printf '#!/usr/bin/env bash\necho "slow start"\nsleep 8\ntouch "%s/slow-finished"\necho done\n' "$TMP" > "$TMP/p/.muster/hooks/web/deploy.sh"
_mcp "${A[@]}" -- "$INIT" "$(_call 1 hooks_approve '{"services":["web"]}')" >/dev/null
start=$(date +%s)
out=$( {
  printf '%s\n' "$INIT" "$(_call 5 deploy '{"services":["web"],"dry_run":false}')"
  sleep 2
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"reason":"user"}}' '{"jsonrpc":"2.0","id":6,"method":"ping"}'
} | "$MCP" "${A[@]}" 2>>"$TMP/stderr.log")
elapsed=$(( $(date +%s) - start ))
_test_eq "cancelled request gets no response" "" "$(_resp "$out" 5)"
_test_eq "server keeps answering" "{}" "$(_resp "$out" 6 | jq -c .result)"
_test "returns well before the hook would finish" bash -c '(( $1 < 8 ))' _ "$elapsed"
sleep 7
_test "hook process tree was killed" bash -c '[[ ! -f "$1/slow-finished" ]]' _ "$TMP"
_test "deploy lock released" bash -c '[[ ! -e "$1/p/.muster/deploy.lock" ]]' _ "$TMP"

# ── Project from cwd / env ──
echo "  project resolution"
out=$(cd "$TMP/p" && _mcp -- "$INIT" "$(_call 1 project_info)")
_test_eq "cwd project" "mcpfix" "$(_resp "$out" 1 | jq -r .result.structuredContent.project)"
out=$(MUSTER_PROJECT="$TMP/p" _mcp -- "$INIT" "$(_call 1 project_info)")
_test_eq "MUSTER_PROJECT" "mcpfix" "$(_resp "$out" 1 | jq -r .result.structuredContent.project)"
out=$(_mcp -- "$INIT" "$(_call 1 project_info)" "$(_call 2 status)")
_test_eq "no project → found false" "false" "$(_resp "$out" 1 | jq -r .result.structuredContent.found)"
_test_contains "status without project explains" "--project" "$(_resp "$out" 2 | jq -r .result.content[0].text)"

# ── stdout hygiene ──
echo "  stdout hygiene"
_test "nothing but JSON-RPC on stdout (all sessions)" bash -c 'printf "%s\n" "$1" | jq -e -s "all(.jsonrpc == \"2.0\")" >/dev/null' _ "$out"
_test "stderr has the startup line" bash -c 'grep -q "muster-mcp\] started" "$1"' _ "$TMP/stderr.log"

# ── muster mcp (install / doctor) ──
echo "  muster mcp"
cd "$TMP/p" || exit 1
out=$("$M" mcp install claude 2>&1)
_test_contains "claude: claude mcp add" "claude mcp add" "$out"
_test_contains "claude: --project" "--project $TMP/p" "$out"
out=$("$M" mcp install vscode --allow-actions 2>&1)
_test_contains "vscode: servers key" '"servers"' "$out"
_test_contains "vscode: allow-actions arg" '"--allow-actions"' "$out"
out=$("$M" mcp install cursor --write --yes 2>&1)
_test_eq "cursor: written" "muster" "$(jq -r '.mcpServers | keys[0]' "$TMP/p/.cursor/mcp.json")"
_test_eq "cursor: absolute command" "$MCP" "$(jq -r '.mcpServers.muster.command' "$TMP/p/.cursor/mcp.json")"
jq '.mcpServers.other = {"command":"x"}' "$TMP/p/.cursor/mcp.json" > c.tmp && mv c.tmp "$TMP/p/.cursor/mcp.json"
"$M" mcp install cursor --write --yes --allow-actions >/dev/null 2>&1
_test_eq "cursor: merge keeps other servers" "muster,other" "$(jq -r '.mcpServers | keys | join(",")' "$TMP/p/.cursor/mcp.json")"
_test_contains "cursor: updated args" "--allow-actions" "$(jq -r '.mcpServers.muster.args | join(" ")' "$TMP/p/.cursor/mcp.json")"
out=$("$M" mcp install cursor --write </dev/null 2>&1) && rc=0 || rc=$?
_test_eq "write without TTY or --yes refused" "1" "$rc"
export MUSTER_MCP_DESKTOP_CONFIG="$TMP/desktop/claude_desktop_config.json"
"$M" mcp install claude-desktop --write --yes >/dev/null 2>&1
_test_eq "claude-desktop written" "$TMP/p" "$(jq -r '.mcpServers.muster.args[1]' "$MUSTER_MCP_DESKTOP_CONFIG")"
"$M" mcp install claude --write --yes >/dev/null 2>&1
_test_eq "claude --write → .mcp.json" "$MCP" "$(jq -r '.mcpServers.muster.command' "$TMP/p/.mcp.json")"
out=$("$M" mcp install nope 2>&1) && rc=0 || rc=$?
_test_eq "unknown client" "1" "$rc"
out=$("$M" mcp doctor 2>&1) && rc=0 || rc=$?
_test_eq "doctor passes" "0" "$rc"
_test_contains "doctor lists tools" "21 tools" "$out"
out=$("$M" mcp doctor --json 2>/dev/null)
_test_eq "doctor --json ok" "true" "$(printf '%s' "$out" | jq -r .ok)"

_test_summary
