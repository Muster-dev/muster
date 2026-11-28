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
# URLs (user:pass@host), muster env keys (mstsec1/mstrec1) and ciphertexts,
# literal values from the project's .env file, and literal values of the
# muster env secrets loaded in this process (_MUSTER_ENV_SECRET_LITS, set by
# lib/core/env_store.sh; never exported or written to disk).
#
# Literal values reach jq through a pipe (--rawfile /dev/fd/N), never argv.
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
| gsub("\\bmst(?:sec|rec)1[02-9ac-hj-np-z]{20,}"; mask)
| gsub("ENC\\[muster:v1,[^\\]]+\\]"; mask)
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
  if [[ -n "${_MUSTER_ENV_SECRET_LITS:-}" ]]; then
    lits="${lits}"$'\n'"${_MUSTER_ENV_SECRET_LITS}"
  fi
  # Longest first, so a secret containing another is masked whole
  jq -Rrs --arg keyre "$_REDACT_KEY_RE" --arg mark "$REDACT_MARK" \
    --rawfile lits <(printf '%s\n' "$lits" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-) \
    "$_REDACT_JQ"
}

# Mask the loaded muster env secret values in $1 (pure bash: no subprocess,
# no argv). Result in _REDACTED.
_redact_env_secrets() {
  _REDACTED="$1"
  [[ -n "${_MUSTER_ENV_SECRET_LITS:-}" ]] || return 0
  local lit
  local IFS=$'\n'
  for lit in $_MUSTER_ENV_SECRET_LITS; do
    [[ -n "$lit" ]] && _REDACTED="${_REDACTED//"$lit"/$REDACT_MARK}"
  done
}

# Rewrite one file with the loaded secret values masked (in place).
_redact_scrub_file() {
  local f="$1" tmp line changed=0
  [[ -f "$f" && -n "${_MUSTER_ENV_SECRET_LITS:-}" ]] || return 0
  tmp=$(mktemp "${f}.XXXXXX") || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    _redact_env_secrets "$line"
    [[ "$_REDACTED" != "$line" ]] && changed=1
    printf '%s\n' "$_REDACTED"
  done <"$f" >"$tmp"
  _REDACTED=""
  if ((changed)); then
    chmod "$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null || echo 644)" "$tmp" 2>/dev/null
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

# Mask loaded secret values in every *.log under dir newer than mark.
_redact_scrub_logs() {
  local dir="$1" mark="$2" f
  [[ -d "$dir" && -n "${_MUSTER_ENV_SECRET_LITS:-}" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] && _redact_scrub_file "$f"
  done < <(find "$dir" -type f -name '*.log' -newer "$mark" 2>/dev/null)
  # Same-second writes are not "newer": check files touched this minute too
  while IFS= read -r f; do
    [[ -n "$f" ]] && _redact_scrub_file "$f"
  done < <(find "$dir" -type f -name '*.log' -mmin -1 2>/dev/null)
}

# Redact a string argument (convenience wrapper)
redact_string() {
  printf '%s' "$1" | redact_text "${2:-}"
}
