#!/usr/bin/env bash
# muster/lib/core/env_store.sh — muster env store: config, secrets and flags
#
# Layout (per project, committed unless noted):
#   muster.env.schema.json            typed schema for keys and flags
#   .muster/env/recipients.json       public keys allowed to decrypt, per env
#   .muster/env/base.config.json      shared non-secret values (optional)
#   .muster/env/<env>.config.json     non-secret values  {"version":1,"env","values":{}}
#   .muster/env/<env>.secrets.json    encrypted values (muster-crypt, docs/env.md)
#   .muster/env/<env>.flags.json      flagd-compatible feature flags
#   .muster/env/local.override.json   personal overrides (gitignored)
#   .muster/env/history.jsonl         change log (no secret values, ever)
#   .muster/runtime/                  generated files, e.g. flags.<env>.json (gitignored)
#
# Secret values only ever travel through pipes and shell variables: never in
# argv (ps), never written to disk outside the encrypted store (except an
# explicit `muster env pull`).

[[ -n "${_MUSTER_ENV_STORE_LOADED:-}" ]] && return 0
_MUSTER_ENV_STORE_LOADED=1

_ENV_CRYPT_OUT=""
_ENV_CRYPT_ERR=""
_ENV_RESOLVED=""
_ENV_LOCKED=""
# Secret values of the last loaded/resolved env, newline-separated, for
# redaction. Never exported.
_MUSTER_ENV_SECRET_LITS="${_MUSTER_ENV_SECRET_LITS:-}"

_ENV_SECRET_NAME_RE='(^|_)(SECRET|TOKEN|PASSWORD|PASSWD|PASS|PWD|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|CREDENTIALS?|AUTH|DSN|SALT)(_|$)|_KEY$'
_ENV_NAME_RE='^[A-Za-z_][A-Za-z0-9_]*$'
_ENV_ENVNAME_RE='^[a-z0-9][a-z0-9_-]{0,31}$'

# Names muster never injects: they change how the shell, the dynamic loader
# or language runtimes behave (same list as muster-agent's blockedEnv), so a
# committed config file must not be able to set them.
_env_name_blocked() {
  case "$1" in
    PATH | IFS | BASH_ENV | ENV | SHELLOPTS | BASHOPTS | PROMPT_COMMAND | PS4 | HOME | \
      LD_* | DYLD_* | BASH_FUNC_* | GCONV_PATH | NODE_OPTIONS | PYTHONPATH | PYTHONSTARTUP | \
      PERL5OPT | RUBYOPT | MUSTER_ENV | MUSTER_ENV_KEY | MUSTER_FLAGS_FILE | MUSTER_TOKEN)
      return 0 ;;
  esac
  return 1
}

# ── Paths ──

# Project root for muster env: nearest dir with muster.env.schema.json,
# .muster/env or muster.json; else the git top level; else $PWD.
_env_root() {
  if [[ -n "${MUSTER_ENV_ROOT:-}" ]]; then
    printf '%s' "$MUSTER_ENV_ROOT"
    return 0
  fi
  local dir="$PWD"
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    if [[ -f "$dir/muster.env.schema.json" || -d "$dir/.muster/env" || -f "$dir/muster.json" ]]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) && [[ -n "$top" ]] && { printf '%s' "$top"; return 0; }
  printf '%s' "$PWD"
}

_env_dir() { printf '%s/.muster/env' "$1"; }
_env_schema_file() { printf '%s/muster.env.schema.json' "$1"; }
# _env_file root kind env   (kind: config|secrets|flags)
_env_file() { printf '%s/.muster/env/%s.%s.json' "$1" "$3" "$2"; }
_env_override_file() { printf '%s/.muster/env/local.override.json' "$1"; }
_env_history_file() { printf '%s/.muster/env/history.jsonl' "$1"; }
_env_recipients_file() { printf '%s/.muster/env/recipients.json' "$1"; }
_env_key_dir() { printf '%s' "${MUSTER_ENV_KEY_DIR:-$HOME/.muster/env-keys}"; }
_env_identity_file() { printf '%s/identity.key' "$(_env_key_dir)"; }

_env_valid_name() { [[ "$1" =~ $_ENV_NAME_RE ]]; }
_env_valid_envname() { [[ "$1" =~ $_ENV_ENVNAME_RE ]]; }

# Is the project using muster env at all?
_env_store_present() {
  local root="$1"
  [[ -f "$(_env_schema_file "$root")" || -d "$(_env_dir "$root")" ]]
}

# Selected env: $MUSTER_ENV, muster.json env.default_env, "local".
_env_default_name() {
  local root="$1" cfg="$1/muster.json" name=""
  [[ -n "${MUSTER_ENV:-}" ]] && { printf '%s' "$MUSTER_ENV"; return 0; }
  if [[ -f "$cfg" ]] && has_cmd jq; then
    name=$(jq -r '.env.default_env // empty' "$cfg" 2>/dev/null)
  fi
  printf '%s' "${name:-local}"
}

# Known environments: schema list ∪ envs that have any file.
_env_list_envs() {
  local root="$1" schema f b
  schema=$(_env_schema_file "$root")
  {
    [[ -f "$schema" ]] && jq -r '.environments[]? // empty' "$schema" 2>/dev/null
    for f in "$(_env_dir "$root")"/*.config.json "$(_env_dir "$root")"/*.secrets.json "$(_env_dir "$root")"/*.flags.json; do
      [[ -f "$f" ]] || continue
      b=$(basename "$f")
      b="${b%%.*}"
      [[ "$b" == "base" ]] && continue
      printf '%s\n' "$b"
    done
  } | awk 'NF && !seen[$0]++'
}

# ── Actor, time ──

_env_actor() {
  local who=""
  if type _deploy_identity &>/dev/null; then
    who=$(_deploy_identity 2>/dev/null)
  fi
  [[ -z "$who" ]] && who=$(git config user.name 2>/dev/null)
  [[ -z "$who" ]] && who=$(whoami 2>/dev/null)
  printf '%s' "${who:-unknown}"
}

_env_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_env_git_sha() { git -C "$1" rev-parse --short HEAD 2>/dev/null || true; }

# ── muster-crypt ──

_env_crypt_bin() {
  local c
  for c in "${MUSTER_CRYPT_BIN:-}" "$(command -v muster-crypt 2>/dev/null)" \
    "$HOME/.muster/bin/muster-crypt" "$HOME/.local/bin/muster-crypt"; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

_env_crypt_install_hint() {
  printf '%s\n' "muster-crypt is needed for secrets (it does the encryption; muster itself is pure bash)." \
    "  Install:  MUSTER_WITH_CRYPT=1 bash <(curl -fsSL https://getmuster.dev/install.sh)" \
    "  or build: git clone https://github.com/Muster-dev/muster-fleet-cloud && cd muster-fleet-cloud && make crypt" \
    "            then put muster-crypt on your PATH (or set MUSTER_CRYPT_BIN)." \
    "Config and flags work without it."
}

# Fail with install instructions when muster-crypt is missing.
_env_require_crypt() {
  _env_crypt_bin >/dev/null && return 0
  err "muster-crypt is not installed" >&2
  _env_crypt_install_hint | sed 's/^/  /' >&2
  return 1
}

# _env_crypt args...   (stdin passed through)
# Sets _ENV_CRYPT_OUT (stdout JSON) and _ENV_CRYPT_ERR (error message).
# Returns muster-crypt's exit code (3 = no key, 4 = integrity).
_env_crypt() {
  local bin rc=0
  _ENV_CRYPT_OUT=""
  _ENV_CRYPT_ERR=""
  bin=$(_env_crypt_bin) || { _ENV_CRYPT_ERR="muster-crypt is not installed"; return 127; }
  _ENV_CRYPT_OUT=$("$bin" "$@" 2>/dev/null) || rc=$?
  if ((rc != 0)); then
    _ENV_CRYPT_ERR=$(printf '%s' "$_ENV_CRYPT_OUT" | jq -r '.error // empty' 2>/dev/null)
    [[ -z "$_ENV_CRYPT_ERR" ]] && _ENV_CRYPT_ERR="muster-crypt failed (exit $rc)"
  fi
  return "$rc"
}

# Public key of this machine's identity (empty if none).
_env_my_pubkey() {
  local id
  id=$(_env_identity_file)
  [[ -f "$id" ]] || { [[ -n "${MUSTER_ENV_KEY:-}" ]] || return 1; }
  _env_crypt pubkey || return 1
  printf '%s' "$_ENV_CRYPT_OUT" | jq -r '.public // empty'
}

# Create this machine's identity if missing. Prints nothing on success.
_env_ensure_identity() {
  local id
  id=$(_env_identity_file)
  [[ -f "$id" ]] && return 0
  _env_require_crypt || return 1
  mkdir -p "$(_env_key_dir)" && chmod 700 "$(_env_key_dir)" 2>/dev/null
  _env_crypt keygen --out "$id" --comment "$(_env_actor)@$(hostname 2>/dev/null || echo host)" || {
    err "Could not create your muster env key: $_ENV_CRYPT_ERR" >&2
    return 1
  }
  return 0
}

# ── Recipients ──

# Recipients (id/public) that may open env, as a JSON array.
_env_recipients_for() {
  local root="$1" env="$2" f
  f=$(_env_recipients_file "$root")
  [[ -f "$f" ]] || { printf '[]'; return 0; }
  jq -c --arg e "$env" '[.recipients[]? | select((.envs // ["*"]) | index("*") or index($e)) | {id, public}]' "$f"
}

# Create the secrets file for env if it does not exist yet.
_env_secrets_init() {
  local root="$1" env="$2" file recips
  file=$(_env_file "$root" secrets "$env")
  [[ -f "$file" ]] && return 0
  _env_require_crypt || return 1
  recips=$(_env_recipients_for "$root" "$env")
  if [[ "$recips" == "[]" ]]; then
    err "No recipients can open '$env' (none listed for it in .muster/env/recipients.json)" >&2
    printf '  Run: muster env recipient add <id> --pubkey mstpub1… --envs %s\n' "$env" >&2
    return 1
  fi
  mkdir -p "$(dirname "$file")"
  _env_crypt init --file "$file" < <(jq -n --arg env "$env" --arg actor "$(_env_actor)" --argjson r "$recips" \
    '{env: $env, actor: $actor, recipients: $r}') || {
    err "Could not create $file: $_ENV_CRYPT_ERR" >&2
    return 1
  }
}

# ── Decryption ──

# _env_decrypt root env → sets _ENV_DECRYPTED to {"KEY":"value"} ({} when
# there is no secrets file). Call it directly, not in $(…), so the error
# (_ENV_CRYPT_ERR) survives. Returns 3 when no key opens it, 4 on integrity
# failure, 127 without muster-crypt.
_ENV_DECRYPTED=""
_env_decrypt() {
  local root="$1" env="$2" file rc=0
  _ENV_DECRYPTED="{}"
  file=$(_env_file "$root" secrets "$env")
  [[ -f "$file" ]] || return 0
  _env_crypt decrypt --file "$file" || return $?
  _ENV_DECRYPTED=$(printf '%s' "$_ENV_CRYPT_OUT" | jq -c '.values') || rc=1
  _ENV_CRYPT_OUT=""
  return "$rc"
}

# Key names in a secrets file (no key needed: names are not encrypted).
_env_secret_names() {
  local file
  file=$(_env_file "$1" secrets "$2")
  [[ -f "$file" ]] || return 0
  jq -r '.values // {} | keys[]' "$file" 2>/dev/null
}

# ── Writing config / flags ──

# Write stdin to file atomically (same dir temp + mv).
_env_write_atomic() {
  local file="$1" tmp
  mkdir -p "$(dirname "$file")"
  tmp=$(mktemp "$(dirname "$file")/.$(basename "$file").XXXXXX") || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 644 "$tmp" 2>/dev/null
  mv -f "$tmp" "$file"
}

# _env_jq_update file default_json jq_filter [jq args...]
_env_jq_update() {
  local file="$1" def="$2" filter="$3" cur out
  shift 3
  if [[ -f "$file" ]]; then cur=$(cat "$file"); else cur="$def"; fi
  out=$(printf '%s' "$cur" | jq "$@" "$filter") || return 1
  printf '%s\n' "$out" | _env_write_atomic "$file"
}

_env_config_default() { printf '{"version":1,"env":"%s","values":{}}' "$1"; }

_env_flags_default() {
  printf '{"$schema":"https://flagd.dev/schema/v0/flags.json","metadata":{"muster_env":"%s","revision":0},"flags":{}}' "$1"
}

_env_schema_default() {
  printf '{"version":1,"environments":["local"],"keys":{},"flags":{}}'
}

# Coerce a string to the JSON stored in config for a schema type.
# _env_typed_json type value  → JSON on stdout (value via stdin to jq)
_env_typed_json() {
  local type="$1" val="$2"
  printf '%s' "$val" | jq -Rs --arg t "$type" '
    if $t == "number" then (tonumber? // .)
    elif $t == "bool" then (if test("^(true|1|yes|on)$"; "i") then true elif test("^(false|0|no|off)$"; "i") then false else . end)
    elif $t == "json" then (fromjson? // .)
    else . end'
}

# Append one history event (JSON object on stdin, fields merged with
# ts/actor/git_sha). Never pass secret values here.
_env_history_append() {
  local root="$1" file
  file=$(_env_history_file "$root")
  mkdir -p "$(dirname "$file")"
  jq -c --arg ts "$(_env_now)" --arg actor "$(_env_actor)" --arg sha "$(_env_git_sha "$root")" \
    '{ts: $ts, actor: $actor, source: "cli"} + . + (if $sha != "" then {git_sha: $sha} else {} end)' >>"$file"
}

# ── Resolution ──

# jq: merge every layer into {KEY: {value, source, type, secret}}.
# Input on stdin: {schema, base, config, secrets, locked, flags, override, env}
# shellcheck disable=SC2016
_ENV_RESOLVE_JQ='
def str: if type == "string" then . elif type == "boolean" or type == "number" then tostring else tojson end;
def flagvar($name; $def): ($def.env_var // ("MUSTER_FLAG_" + ($name | ascii_upcase | gsub("[^A-Z0-9]"; "_"))));
.env as $env
| (.schema // {}) as $s
| ($s.keys // {}) as $k
| (.override // {}) as $o
| [
    ($k | to_entries[] | select(.value.default != null and .value.type != "secret")
       | {key, value: {value: (.value.default | str), source: "schema default"}}),
    ((.base.values // {}) | to_entries[] | {key, value: {value: (.value | str), source: "base"}}),
    ((.config.values // {}) | to_entries[] | {key, value: {value: (.value | str), source: $env}}),
    ((.secrets // {}) | to_entries[] | {key, value: {value: .value, source: ($env + " (encrypted)"), secret: true}}),
    (.lockednote as $ln | (.locked // []) | .[] | {key: ., value: {value: null, source: ($env + " (encrypted" + $ln + ")"), secret: true, locked: true}}),
    ((.flags.flags // {}) | to_entries[] | select((.value.state // "ENABLED") == "ENABLED")
       | .key as $n | .value as $f
       | {key: flagvar($n; ($s.flags[$n] // {})),
          value: {value: ($f.variants[$f.defaultVariant] | str), source: ("flag " + $n), flag: $n}}),
    (if $env == "local" then (($o.values // {}) | to_entries[] | {key, value: {value: (.value | str), source: "local override"}}) else empty end)
  ]
| reduce .[] as $e ({}; .[$e.key] = ((.[$e.key] // {}) * $e.value))
| with_entries(.value += {
    type: ($k[.key].type // (if .value.secret then "secret" else "string" end)),
    secret: ((.value.secret // false) or ($k[.key].type == "secret") or ($k[.key].sensitive == true))
  })
'

# Merged flagd document for env (base.flags + env.flags + local overrides).
# shellcheck disable=SC2016
_ENV_FLAGS_MERGE_JQ='
.env as $env
| (.override.flags // {}) as $o
| {"$schema": "https://flagd.dev/schema/v0/flags.json",
   metadata: ((.flags.metadata // {}) + {muster_env: $env}),
   flags: ((.base.flags // {}) * (.flags.flags // {}))}
| if $env == "local" then
    reduce ($o | to_entries[]) as $e (.;
      .flags[$e.key] = ((.flags[$e.key] // {state: "ENABLED", variants: {}})
        | .variants[$e.value.variant] = $e.value.value
        | .defaultVariant = $e.value.variant
        | .state = "ENABLED"))
  else . end
'

_env_cat_or() { if [[ -f "$1" ]]; then cat "$1"; else printf '%s' "$2"; fi; }

# Build the resolve input document on stdout. Secrets JSON on $1 (via
# printf, a builtin: never argv of a child process).
_env_layers() {
  local root="$1" env="$2" secrets="$3" locked="$4"
  printf '{"env":'
  printf '%s' "$env" | jq -Rs .
  printf ',"schema":'
  _env_cat_or "$(_env_schema_file "$root")" 'null'
  printf ',"base":'
  _env_cat_or "$(_env_file "$root" config base)" 'null'
  printf ',"config":'
  _env_cat_or "$(_env_file "$root" config "$env")" 'null'
  printf ',"flags":'
  _env_flags_merged "$root" "$env"
  printf ',"override":'
  _env_cat_or "$(_env_override_file "$root")" 'null'
  [[ -z "$secrets" ]] && secrets='{}'
  [[ -z "$locked" ]] && locked='[]'
  printf ',"lockednote":"%s","locked":%s,"secrets":' "${_ENV_LOCKED:+, locked}" "$locked"
  printf '%s' "$secrets"
  printf '}'
}

_env_flags_merged() {
  local root="$1" env="$2"
  {
    printf '{"env":'
    printf '%s' "$env" | jq -Rs .
    printf ',"base":'
    _env_cat_or "$(_env_file "$root" flags base)" 'null'
    printf ',"flags":'
    _env_cat_or "$(_env_file "$root" flags "$env")" 'null'
    printf ',"override":'
    _env_cat_or "$(_env_override_file "$root")" 'null'
    printf '}'
  } | jq -c "$_ENV_FLAGS_MERGE_JQ"
}

# _env_resolve root env [secrets_mode]
#   secrets_mode: required (default) | optional | none
# Sets _ENV_RESOLVED (JSON) and _ENV_LOCKED (why secrets are missing, if
# they are). Returns non-zero when secrets are required but cannot be read.
_env_resolve() {
  local root="$1" env="$2" mode="${3:-required}" secrets="{}" locked="[]" rc=0
  _ENV_RESOLVED=""
  _ENV_LOCKED=""
  if [[ -f "$(_env_file "$root" secrets "$env")" && "$mode" != "none" ]]; then
    if ! _env_crypt_bin >/dev/null; then
      _ENV_LOCKED="muster-crypt is not installed"
      rc=127
    else
      if _env_decrypt "$root" "$env"; then
        secrets="$_ENV_DECRYPTED"
      else
        rc=$?
        _ENV_LOCKED="${_ENV_CRYPT_ERR:-could not decrypt}"
        secrets="{}"
      fi
      _ENV_DECRYPTED=""
    fi
    if [[ -n "$_ENV_LOCKED" ]]; then
      [[ "$mode" == "required" ]] && return "$rc"
      locked=$(_env_secret_names "$root" "$env" | jq -Rsc 'split("\n") | map(select(length > 0))')
    fi
  elif [[ "$mode" == "none" ]]; then
    locked=$(_env_secret_names "$root" "$env" | jq -Rsc 'split("\n") | map(select(length > 0))')
  fi
  _ENV_RESOLVED=$(_env_layers "$root" "$env" "$secrets" "$locked" | jq -c "$_ENV_RESOLVE_JQ") || return 1
  _env_note_secret_literals
  return 0
}

# Record secret values of _ENV_RESOLVED for redaction (same filter as
# lib/core/redact.sh: ≥6 chars, not numbers or booleans).
_env_note_secret_literals() {
  local lits
  lits=$(printf '%s' "$_ENV_RESOLVED" | jq -r '
    to_entries[] | select(.value.secret and .value.value != null) | .value.value
    | select(length >= 6) | select(test("^[0-9.]+$") | not)
    | select(ascii_downcase | IN("true", "false", "production", "development", "staging", "localhost") | not)
    | split("\n")[] | select(length >= 6)' 2>/dev/null)
  [[ -z "$lits" ]] && return 0
  if [[ -n "$_MUSTER_ENV_SECRET_LITS" ]]; then
    _MUSTER_ENV_SECRET_LITS="${_MUSTER_ENV_SECRET_LITS}"$'\n'"${lits}"
  else
    _MUSTER_ENV_SECRET_LITS="$lits"
  fi
}

# Print `_env_export_one NAME 'value'` lines for _ENV_RESOLVED, for eval.
# jq's @sh quoting makes every value a single literal word.
_env_export_script() {
  printf '%s' "$_ENV_RESOLVED" | jq -r '
    to_entries[] | select(.value.value != null)
    | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
    | "_env_export_one \(.key | @sh) \(.value.value | @sh)"'
}

# Export NAME=value unless blocked; respects existing vars unless
# _ENV_EXPORT_OVERRIDE=1. Records names in _MUSTER_ENV_VARS for unloading.
_env_export_one() {
  local name="$1" val="$2"
  if _env_name_blocked "$name"; then
    printf '  %b!%b muster env: not setting %s (it changes how programs run)\n' "$YELLOW" "$RESET" "$name" >&2
    return 0
  fi
  if [[ "${_ENV_EXPORT_OVERRIDE:-0}" != "1" && -n "${!name+set}" ]]; then
    return 0
  fi
  export "$name=$val"
  _MUSTER_ENV_VARS[${#_MUSTER_ENV_VARS[@]}]="$name"
}

# Write the merged flags for env to .muster/runtime/flags.<env>.json and
# print its path. Flags are not secret; the file is gitignored.
_env_write_runtime_flags() {
  local root="$1" env="$2" file
  file="$root/.muster/runtime/flags.${env}.json"
  mkdir -p "$root/.muster/runtime"
  _env_flags_merged "$root" "$env" | jq . | _env_write_atomic "$file" || return 1
  printf '%s' "$file"
}

# Load the store into the current shell (deploy hooks). Values never touch
# disk. Existing env vars win. Missing secrets warn and continue.
# _env_load_into_shell root [env]
_env_load_into_shell() {
  local root="$1" env="${2:-}" script
  [[ -z "$env" ]] && env=$(_env_default_name "$root")
  _env_valid_envname "$env" || { warn "muster env: invalid environment name '$env'" >&2; return 1; }
  if ! _env_resolve "$root" "$env" optional; then
    warn "muster env: could not resolve '$env'" >&2
    return 1
  fi
  if [[ -n "$_ENV_LOCKED" ]]; then
    printf '  %b!%b muster env: secrets for %s not loaded: %s\n' "$YELLOW" "$RESET" "$env" "$_ENV_LOCKED" >&2
  fi
  script=$(_env_export_script) || return 1
  eval "$script"
  if [[ -z "${MUSTER_ENV+set}" ]]; then
    export MUSTER_ENV="$env"
    _MUSTER_ENV_VARS[${#_MUSTER_ENV_VARS[@]}]="MUSTER_ENV"
  fi
  local flags
  if [[ -z "${MUSTER_FLAGS_FILE+set}" ]] && flags=$(_env_write_runtime_flags "$root" "$env" 2>/dev/null); then
    export MUSTER_FLAGS_FILE="$flags"
    _MUSTER_ENV_VARS[${#_MUSTER_ENV_VARS[@]}]="MUSTER_FLAGS_FILE"
  fi
  return 0
}

# ── Validation (shared by set and check) ──

# jq: validate {value (string|null), def (schema entry)} → array of problems
# shellcheck disable=SC2016
_ENV_VALIDATE_JQ='
def problems:
  .value as $v | .def as $d | ($d.type // "string") as $t
  | if $v == null then []
    else
      [ (if $t == "number" then
           (($v | tonumber?) // null) as $n
           | if $n == null then "must be a number"
             elif ($d.integer == true and ($n | floor) != $n) then "must be an integer"
             elif ($d.min != null and $n < $d.min) then "must be ≥ \($d.min)"
             elif ($d.max != null and $n > $d.max) then "must be ≤ \($d.max)"
             else empty end
         elif $t == "bool" then
           (if ($v | test("^(true|false|1|0)$"; "i")) then empty else "must be true or false" end)
         elif $t == "json" then
           (if (($v | fromjson?) // "\u0000bad") == "\u0000bad" then "must be valid JSON" else empty end)
         else empty end),
        (if $d.enum != null and (($d.enum | map(tostring)) | index($v)) == null
           then "must be one of: \($d.enum | map(tostring) | join(", "))" else empty end),
        (if $d.pattern != null and (($v | test($d.pattern)?) // false) == false
           then "does not match pattern \($d.pattern)" else empty end),
        (if $d.format == "url" and ($v | test("^[A-Za-z][A-Za-z0-9+.-]*://[^\\s]+$") | not) then "must be a URL"
         elif $d.format == "email" and ($v | test("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$") | not) then "must be an email address"
         elif $d.format == "uuid" and ($v | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") | not) then "must be a UUID"
         elif $d.format == "host" and ($v | test("^[A-Za-z0-9.-]+(:[0-9]+)?$") | not) then "must be a host name"
         elif $d.format == "duration" and ($v | test("^[0-9]+(ms|s|m|h|d)$") | not) then "must be a duration like 30s or 5m"
         else empty end)
      ]
    end;
'

# Schema entry for KEY (or null).
_env_schema_key() {
  local root="$1" key="$2" schema
  schema=$(_env_schema_file "$root")
  [[ -f "$schema" ]] || { printf 'null'; return 0; }
  jq -c --arg k "$key" '.keys[$k] // null' "$schema"
}

# Validate one value against its schema entry. Prints problems (one per
# line, never containing the value). Value via a pipe.
_env_validate_value() {
  local def="$1" val="$2"
  printf '%s' "$val" | jq -Rrs --argjson d "$def" "$_ENV_VALIDATE_JQ"' {value: ., def: $d} | problems | .[]'
}

# Infer a schema type from a key name and value.
_env_infer_type() {
  local key="$1" val="$2" upper
  upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
  local url_pw_re='^[A-Za-z][A-Za-z0-9+.-]*://[^/:@[:space:]]+:[^/@[:space:]]+@'
  local token_re='^(sk|rk|pk)_(live|test)_|^gh[pousr]_|^github_pat_|^xox[abposr]-|^AKIA|^eyJ[A-Za-z0-9_-]+\.|^whsec_|^mst_|-----BEGIN'
  if [[ "$upper" =~ $_ENV_SECRET_NAME_RE || "$val" =~ $url_pw_re || "$val" =~ $token_re ]]; then
    printf 'secret'
  elif [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ && "$upper" != *VERSION* && "$upper" != *ZIP* ]]; then
    printf 'number'
  elif [[ "$val" =~ ^(true|false|TRUE|FALSE|True|False)$ ]]; then
    printf 'bool'
  else
    printf 'string'
  fi
}

# Add KEY to the schema (if missing) with a type. Returns 0 when added.
_env_schema_add_key() {
  local root="$1" key="$2" type="$3" extra="${4:-}" schema
  [[ -z "$extra" ]] && extra='{}'
  schema=$(_env_schema_file "$root")
  if [[ -f "$schema" ]] && jq -e --arg k "$key" '.keys[$k] != null' "$schema" >/dev/null 2>&1; then
    return 1
  fi
  _env_jq_update "$schema" "$(_env_schema_default)" \
    '.keys[$k] = ({type: $t} + $x) | .keys |= (to_entries | sort_by(.key) | from_entries)' \
    --arg k "$key" --arg t "$type" --argjson x "$extra"
}

# Ensure env is in schema.environments.
_env_schema_add_env() {
  local root="$1" env="$2"
  _env_jq_update "$(_env_schema_file "$root")" "$(_env_schema_default)" \
    '.environments = ((.environments // []) + [$e] | unique)' --arg e "$env"
}

# Read a value without echoing it (TTY), or from stdin.
# _env_read_secret prompt → value on stdout
_env_read_secret() {
  local prompt="$1" v="" v2=""
  if [[ -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
    printf '  %s: ' "$prompt" >/dev/tty
    IFS= read -rs v </dev/tty
    printf '\n' >/dev/tty
    printf '  Again to confirm: ' >/dev/tty
    IFS= read -rs v2 </dev/tty
    printf '\n' >/dev/tty
    if [[ "$v" != "$v2" ]]; then
      err "Values did not match" >&2
      return 1
    fi
  else
    v=$(cat)
  fi
  printf '%s' "$v"
}
