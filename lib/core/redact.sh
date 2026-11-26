#!/usr/bin/env bash
# muster/lib/core/redact.sh — Mask secrets before anything leaves the machine
#
# Used by `muster ask` on every tool result and on the session context
# (docs/assistant-and-pairing.md, "Redaction"). The server re-applies its own
# redaction, but the client must never rely on that.
#
#   redact_text [env_file]   stdin → stdout, secrets replaced with ‹redacted›
#
# Masks: values of secret-looking keys (KEY=VALUE, JSON, YAML, HTTP headers),
# bearer/basic credentials, mst_* tokens, AWS access keys, GitHub tokens,
# Slack tokens and webhooks, Discord webhooks, JWTs, PEM blocks, passwords in
# URLs (user:pass@host), and literal values from the project's .env file.
#
# Fails closed: without jq it prints nothing and returns 1, so callers
# never send unredacted text by accident.

REDACT_MARK="‹redacted›"

# Secret-looking key names (matched case-insensitively, anywhere in the key)
_REDACT_KEY_RE='pass(word)?|secret|token|api[_-]?key|private[_-]?key|credential|auth'

# jq program. $lits: newline-separated literal values to mask (from .env).
# shellcheck disable=SC2016
_REDACT_JQ='
def keyre: "[A-Za-z0-9_.-]*(?:" + $keyre + ")[A-Za-z0-9_.-]*";
def benign: test("^(?:true|false|null|none|yes|no|on|off|[0-9]{1,5}|\\$.*|\\{\\{.*|<[^>]*>|\\*+)$"; "i");
def mask: $mark;
.
# PEM blocks (private keys, certificates)
| gsub("-----BEGIN [A-Z0-9 ]+-----[\\s\\S]*?-----END [A-Z0-9 ]+-----"; mask)
# Passwords in URLs: scheme://user:pass@host
| gsub("(?<a>[A-Za-z][A-Za-z0-9+.-]*://[^/\\s:@\"'"'"']+):(?<p>[^/\\s@\"'"'"']+)@"; "\(.a):\(mask)@")
# Webhooks
| gsub("https://hooks\\.slack\\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_-]+"; mask)
| gsub("https://(?:canary\\.|ptb\\.)?discord(?:app)?\\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"; mask)
# Well-known token formats
| gsub("\\bmst_[A-Za-z0-9_]{6,}"; mask)
| gsub("\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b"; mask)
| gsub("\\bgh[pousr]_[A-Za-z0-9]{20,}"; mask)
| gsub("\\bgithub_pat_[A-Za-z0-9_]{20,}"; mask)
| gsub("\\bxox[abposr]-[A-Za-z0-9-]{10,}"; mask)
| gsub("\\beyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}"; mask)
| gsub("\\b(?:sk|rk)[-_](?:ant-|proj-|live_|test_)?[A-Za-z0-9_-]{20,}"; mask)
# Authorization schemes
| gsub("(?<s>\\bBearer\\s+)(?<v>[A-Za-z0-9._~+/=-]{8,})"; "\(.s)\(mask)"; "i")
| gsub("(?<s>\\bBasic\\s+)(?<v>(?=[A-Za-z+/]*[0-9+/=])[A-Za-z0-9+/]{8,}={0,2})"; "\(.s)\(mask)"; "i")
# JSON: "secret_key": "value" / "token": 123
| gsub("(?<k>\"" + keyre + "\"\\s*:\\s*)(?<v>\"(?:[^\"\\\\]|\\\\.)*\"|[A-Za-z0-9_.+-]+)";
       if (.v | ltrimstr("\"") | rtrimstr("\"") | (benign or . == "" or . == $mark)) then .k + .v
       else .k + "\"" + mask + "\"" end; "i")
# KEY=VALUE (env files, shell, logfmt, CLI flags --token=…)
| gsub("(?<k>" + keyre + ")(?<s>\\s*=\\s*)(?<v>\"[^\"\\n]*\"|'"'"'[^'"'"'\\n]*'"'"'|[^\\s\"'"'"',;&]+)";
       if (.v | ltrimstr("\"") | rtrimstr("\"") | ltrimstr("'"'"'") | rtrimstr("'"'"'") | (benign or . == "" or . == $mark)) then .k + .s + .v
       else .k + .s + mask end; "i")
# YAML / HTTP headers at line start: "  db_password: hunter2", "> Authorization: …"
| gsub("(?<k>(?:^|\\n)[\\t >*-]*" + keyre + "\\s*:[ \\t]+)(?<v>[^\\n]+)";
       if (.v | gsub("^[\"'"'"']|[\"'"'"']\\s*$"; "") | (benign or . == "" or startswith($mark) or test("^[|>]-?$"))) then .k + .v
       else .k + mask end; "i")
# CLI flags: --password hunter2, -p is too ambiguous to guess
| gsub("(?<k>--" + keyre + ")(?<s>\\s+)(?<v>[^\\s-][^\\s]*)";
       if (.v | benign or startswith($mark)) then .k + .s + .v else .k + .s + mask end; "i")
# Literal values from .env
| reduce ($lits | split("\n")[] | select(length > 0)) as $l (.; split($l) | join(mask))
'

# Print .env values worth masking literally (one per line). Values under 6
# characters, numbers and booleans are skipped: masking every "3000" or
# "true" in a log would destroy it without protecting anything; their
# KEY=VALUE lines are still masked by key name when the key looks secret.
_redact_env_literals() {
  local env_file="$1" line key val
  [[ -n "$env_file" && -f "$env_file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # Strip matching quotes
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    (( ${#val} >= 6 )) || continue
    [[ "$val" =~ ^[0-9.]+$ ]] && continue
    case "$val" in
      true | false | TRUE | FALSE | production | development | staging | localhost) continue ;;
    esac
    printf '%s\n' "$val"
  done < "$env_file"
}

# Redact stdin. Optional arg: path to a .env file whose values are masked.
redact_text() {
  local env_file="${1:-}"
  if ! command -v jq >/dev/null 2>&1; then
    cat >/dev/null
    return 1
  fi
  local lits
  lits=$(_redact_env_literals "$env_file")
  jq -Rrs --arg keyre "$_REDACT_KEY_RE" --arg mark "$REDACT_MARK" --arg lits "$lits" \
    "$_REDACT_JQ"
}

# Redact a string argument (convenience wrapper)
redact_string() {
  printf '%s' "$1" | redact_text "${2:-}"
}
