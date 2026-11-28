#!/usr/bin/env bash
# muster/lib/commands/env.sh — muster env: config, secrets and flags in the repo
#
#   muster env init|set|get|unset|list|diff|edit|history|check|pull|example
#   muster env keygen|recipient|rekey|guard|codegen
#   muster run [--env E] [--override] -- <cmd…>
#
# Store layout and the security model: lib/core/env_store.sh, docs/env.md.

source "$MUSTER_ROOT/lib/core/env_store.sh"

_env_usage() {
  cat <<'EOF'
Usage: muster env <command> [options]

  init [--from .env] [--envs a,b] [--recovery] [--yes]   start using muster env here
  set KEY[=VALUE]… [--env E] [--secret|--config] [--type T] [--stdin] [-m MSG]
                                    omit =VALUE for a hidden prompt (or pipe it)
  get KEY [--env E] [--reveal]      secrets print as ‹secret:fingerprint› unless --reveal
  unset KEY… [--env E] [-m MSG]
  list [--env E] [--show-values] [--json]
  diff <envA> <envB> [--json]       secrets compared without printing them
  edit [--env E]                    edit config + secrets in $EDITOR (temp file, wiped)
  history [KEY] [--env E] [--json]  who changed what (never secret values)
  check [--env E] [--strict] [--no-decrypt] [--fail-on-stale] [--json]   CI gate
  pull [--env E] [--to .env] [--format dotenv|json] [--force]   write a gitignored file
  example [--to .env.example]       generate .env.example from the schema
  codegen ts|py|go|all [--out PATH] typed, zero-dependency readers
  keygen [--ci NAME --envs a,b]     create your key (or a CI key, printed once)
  recipient list|add|remove|sync    who can decrypt which environment
  rekey [--env E]                   new data key, every value re-encrypted
  guard install|check [--staged]    pre-commit hook that blocks plaintext secrets

  muster run [--env E] [--override] -- <cmd…>   run with the env injected (no file written)
  muster flag set|get|list|toggle|reset          feature flags (see: muster flag help)

Environment: MUSTER_ENV selects the env (default: muster.json env.default_env, else local).
CI: set MUSTER_ENV_KEY to a CI key from `muster env keygen --ci NAME`.
EOF
}

_ENV_ROOT=""
_env_cmd_root() {
  has_cmd jq || { err "muster env needs jq (brew install jq / apt install jq)"; return 1; }
  _ENV_ROOT=$(_env_root)
}

_env_need_store() {
  if ! _env_store_present "$_ENV_ROOT"; then
    err "muster env is not set up in $_ENV_ROOT" >&2
    printf '  Run: muster env init\n' >&2
    return 1
  fi
}

# Parse --env, check it, print it.
_env_pick() {
  local env="${1:-}"
  [[ -z "$env" ]] && env=$(_env_default_name "$_ENV_ROOT")
  if ! _env_valid_envname "$env"; then
    err "Invalid environment name: $env (lowercase letters, digits, - and _)" >&2
    return 1
  fi
  printf '%s' "$env"
}

cmd_env() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    init) _env_cmd_init "$@" ;;
    set) _env_cmd_set "$@" ;;
    get) _env_cmd_get "$@" ;;
    unset | rm) _env_cmd_unset "$@" ;;
    list | ls) _env_cmd_list "$@" ;;
    diff) _env_cmd_diff "$@" ;;
    edit) _env_cmd_edit "$@" ;;
    history | log) _env_cmd_history "$@" ;;
    check) _env_cmd_check "$@" ;;
    pull) _env_cmd_pull "$@" ;;
    example) _env_cmd_example "$@" ;;
    keygen) _env_cmd_keygen "$@" ;;
    recipient | recipients) _env_cmd_recipient "$@" ;;
    rekey) _env_cmd_rekey "$@" ;;
    run) cmd_run "$@" ;;
    guard)
      source "$MUSTER_ROOT/lib/commands/env_guard.sh"
      _env_cmd_guard "$@"
      ;;
    codegen)
      source "$MUSTER_ROOT/lib/commands/env_codegen.sh"
      _env_cmd_codegen "$@"
      ;;
    "" | help | --help | -h) _env_usage ;;
    *)
      err "Unknown env command: $sub"
      source "$MUSTER_ROOT/lib/core/suggest.sh"
      _suggest_print "$sub" init set get unset list diff edit history check pull example codegen keygen recipient rekey guard run || true
      printf '  Run: muster env help\n'
      return 1
      ;;
  esac
}

# ── init ──

_env_gitignore_ensure() {
  local root="$1" gi="$1/.gitignore" line added=0
  touch "$gi"
  for line in ".env" ".env.*" "!.env.example" ".muster/runtime/" ".muster/env/local.override.json"; do
    if ! grep -qxF "$line" "$gi" 2>/dev/null; then
      if ((added == 0)); then
        [[ -s "$gi" && -n "$(tail -c1 "$gi")" ]] && printf '\n' >>"$gi"
        printf '# muster env (secrets stay encrypted in .muster/env)\n' >>"$gi"
      fi
      printf '%s\n' "$line" >>"$gi"
      added=$((added + 1))
    fi
  done
  ((added > 0))
}

# Parse a dotenv file into "KEY<TAB>base64(value)" lines (values may hold
# anything). Same rules as _load_env_file.
_env_parse_dotenv() {
  local file="$1" line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#export }"
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      printf '%s\t%s\n' "$key" "$(printf '%s' "$val" | base64 | tr -d '\n')"
    fi
  done <"$file"
}

_env_b64d() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }

_env_cmd_init() {
  local from="" envs="local" yes=false recovery=false guard="ask"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --from=*) from="${1#*=}"; shift ;;
      --envs) envs="${2:-}"; shift 2 ;;
      --envs=*) envs="${1#*=}"; shift ;;
      --yes | -y) yes=true; shift ;;
      --recovery) recovery=true; shift ;;
      --no-guard) guard="no"; shift ;;
      --guard) guard="yes"; shift ;;
      -h | --help) _env_usage; return 0 ;;
      *) err "Unknown option: $1"; return 1 ;;
    esac
  done
  _env_cmd_root || return 1
  local root="$_ENV_ROOT" e first_env=""
  local schema
  schema=$(_env_schema_file "$root")

  printf '\n  %bmuster env%b — %s\n\n' "$BOLD" "$RESET" "$root"
  mkdir -p "$(_env_dir "$root")"

  # Schema + environments
  [[ -f "$schema" ]] || _env_schema_default | jq . | _env_write_atomic "$schema"
  local IFS_OLD="$IFS"
  IFS=','
  for e in $envs; do
    IFS="$IFS_OLD"
    e=$(printf '%s' "$e" | tr -d ' ')
    [[ -z "$e" ]] && continue
    _env_valid_envname "$e" || { err "Invalid environment name: $e"; return 1; }
    [[ -z "$first_env" ]] && first_env="$e"
    _env_schema_add_env "$root" "$e"
    [[ -f "$(_env_file "$root" config "$e")" ]] || _env_config_default "$e" | jq . | _env_write_atomic "$(_env_file "$root" config "$e")"
    [[ -f "$(_env_file "$root" flags "$e")" ]] || _env_flags_default "$e" | jq . | _env_write_atomic "$(_env_file "$root" flags "$e")"
  done
  IFS="$IFS_OLD"
  ok "Schema: muster.env.schema.json (environments: $(jq -r '.environments | join(", ")' "$schema"))"

  # Keys
  local rfile pub id
  rfile=$(_env_recipients_file "$root")
  [[ -f "$rfile" ]] || printf '{"version":1,"recipients":[]}\n' | jq . | _env_write_atomic "$rfile"
  if _env_crypt_bin >/dev/null; then
    if [[ ! -f "$(_env_identity_file)" && -z "${MUSTER_ENV_KEY:-}" ]]; then
      _env_ensure_identity || return 1
      ok "Created your key: $(_env_identity_file) (0600, never committed)"
    fi
    pub=$(_env_my_pubkey)
    if [[ -n "$pub" ]]; then
      id="dev:$(_env_actor | tr -c 'A-Za-z0-9._@-' '-' | sed 's/-*$//' | cut -c1-60)"
      if ! jq -e --arg p "$pub" '.recipients[]? | select(.public == $p)' "$rfile" >/dev/null; then
        _env_jq_update "$rfile" '{"version":1,"recipients":[]}' \
          '.recipients += [{id: $id, public: $p, envs: ["*"], added_at: $t}]' \
          --arg id "$id" --arg p "$pub" --arg t "$(_env_now)"
        ok "Added you as a recipient for every environment ($id)"
      fi
    fi
    if [[ "$recovery" == "true" ]]; then
      _env_init_recovery "$root" || return 1
    fi
  else
    warn "muster-crypt is not installed: config and flags work, secrets need it"
    _env_crypt_install_hint | sed 's/^/    /'
  fi

  # Import an existing .env
  if [[ -n "$from" ]]; then
    [[ -f "$from" ]] || { err "No such file: $from"; return 1; }
    _env_import_dotenv "$root" "$from" "$first_env" || return 1
  fi

  if _env_gitignore_ensure "$root"; then
    ok "Updated .gitignore (.env, .muster/runtime/, local overrides)"
  fi
  _env_write_example "$root" "$root/.env.example" >/dev/null && ok "Wrote .env.example"

  # Pre-commit guard
  if [[ -d "$root/.git" || -f "$root/.git" ]]; then
    local do_guard=false
    case "$guard" in
      yes) do_guard=true ;;
      no) ;;
      ask)
        if [[ "$yes" == "true" ]]; then
          do_guard=true
        elif [[ -t 0 ]]; then
          printf '  Install a pre-commit hook that blocks plaintext secrets? [Y/n] '
          local a=""
          IFS= read -r a || true
          [[ "$a" =~ ^[Nn] ]] || do_guard=true
        fi
        ;;
    esac
    if [[ "$do_guard" == "true" ]]; then
      source "$MUSTER_ROOT/lib/commands/env_guard.sh"
      _env_guard_install "$root" && ok "Installed the pre-commit guard"
    else
      info "Pre-commit guard not installed (muster env guard install)"
    fi
  fi

  _env_history_append "$root" <<<"$(jq -nc --arg e "$envs" '{action: "init", envs: ($e | split(","))}')"

  printf '\n  Next:\n'
  printf '    muster env set DATABASE_URL          %b# hidden prompt, stored encrypted%b\n' "$DIM" "$RESET"
  printf '    muster env set PORT=3000             %b# plain config%b\n' "$DIM" "$RESET"
  printf '    muster run -- npm run dev            %b# run with it injected%b\n' "$DIM" "$RESET"
  printf '    muster env check                     %b# in CI%b\n' "$DIM" "$RESET"
  printf '    muster env codegen ts                %b# typed reader for your app%b\n\n' "$DIM" "$RESET"
}

_env_init_recovery() {
  local root="$1" rfile out pub sec name
  rfile=$(_env_recipients_file "$root")
  if jq -e '.recipients[]? | select(.id | startswith("recovery:"))' "$rfile" >/dev/null; then
    info "A recovery key is already a recipient"
    return 0
  fi
  _env_crypt keygen --kind recovery --print-secret || { err "Could not create a recovery key: $_ENV_CRYPT_ERR"; return 1; }
  out="$_ENV_CRYPT_OUT"
  pub=$(printf '%s' "$out" | jq -r .public)
  sec=$(printf '%s' "$out" | jq -r .secret)
  out=""
  name="recovery:$(basename "$root" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//' | cut -c1-60)"
  _env_jq_update "$rfile" '{"version":1,"recipients":[]}' \
    '.recipients += [{id: $id, public: $p, envs: ["*"], added_at: $t}]' \
    --arg id "$name" --arg p "$pub" --arg t "$(_env_now)"
  printf '\n  %bRecovery key%b — shown once. Store it offline (password manager, safe).\n' "$BOLD" "$RESET"
  printf '  It opens every environment if all developer keys are lost.\n\n'
  printf '  %s\n\n' "$sec"
  sec=""
  ok "Recovery key added as recipient $name"
}

_env_import_dotenv() {
  local root="$1" file="$2" env="$3" key b64 val type n_cfg=0 n_sec=0 secret_json="{}"
  while IFS=$'\t' read -r key b64; do
    [[ -z "$key" ]] && continue
    val=$(_env_b64d "$b64")
    type=$(jq -r --arg k "$key" '.keys[$k].type // empty' "$(_env_schema_file "$root")")
    if [[ -z "$type" ]]; then
      type=$(_env_infer_type "$key" "$val")
      if [[ "$type" == "number" && "$val" =~ ^-?[0-9]+$ ]]; then
        _env_schema_add_key "$root" "$key" "$type" '{"integer":true}'
      else
        _env_schema_add_key "$root" "$key" "$type"
      fi
    fi
    if [[ "$type" == "secret" ]]; then
      secret_json=$(printf '%s' "$secret_json" | jq -c --arg k "$key" --rawfile v <(printf '%s' "$val") '.[$k] = $v')
      n_sec=$((n_sec + 1))
    else
      _env_jq_update "$(_env_file "$root" config "$env")" "$(_env_config_default "$env")" \
        '.values[$k] = $v' --arg k "$key" --argjson v "$(_env_typed_json "$type" "$val")"
      n_cfg=$((n_cfg + 1))
    fi
  done < <(_env_parse_dotenv "$file")
  val=""
  if ((n_sec > 0)); then
    _env_secrets_init "$root" "$env" || return 1
    _env_crypt set --file "$(_env_file "$root" secrets "$env")" < <(printf '%s' "$secret_json" | jq -c --arg a "$(_env_actor)" '{set: ., actor: $a}') || {
      err "Could not store secrets: $_ENV_CRYPT_ERR"
      return 1
    }
  fi
  secret_json=""
  ok "Imported $file into '$env': $n_cfg config, $n_sec secret (encrypted)"
  _env_history_append "$root" <<<"$(jq -nc --arg e "$env" --arg f "$(basename "$file")" --argjson c "$n_cfg" --argjson s "$n_sec" \
    '{action: "import", env: $e, from: $f, config: $c, secrets: $s}')"
  if [[ "$(basename "$file")" == ".env" ]]; then
    info "Your .env is still there. Once 'muster run' works, delete it: rm $file"
  fi
}

# ── set ──

# Store one secret (value in $3) and record history.
_env_store_secret() {
  local root="$1" env="$2" key="$3" val="$4" msg="${5:-}" file out fp
  _env_require_crypt || return 1
  _env_secrets_init "$root" "$env" || return 1
  file=$(_env_file "$root" secrets "$env")
  local before
  before=$(jq -r --arg k "$key" '._meta.key_fingerprints[$k] // empty' "$file")
  _env_crypt set --file "$file" < <(jq -nc --arg k "$key" --arg a "$(_env_actor)" --rawfile v <(printf '%s' "$val") '{set: {($k): $v}, actor: $a}') || {
    err "Could not set $key: $_ENV_CRYPT_ERR"
    return 1
  }
  out="$_ENV_CRYPT_OUT"
  if [[ "$(printf '%s' "$out" | jq -r '.changed | length')" == "0" ]]; then
    info "$key unchanged in $env"
    return 0
  fi
  fp=$(printf '%s' "$out" | jq -r --arg k "$key" '.fingerprints[$k] // empty')
  _env_history_append "$root" <<<"$(jq -nc --arg e "$env" --arg k "$key" --arg b "$before" --arg f "$fp" --arg m "$msg" \
    '{action: "set", env: $e, message: (if $m == "" then null else $m end), changes: [{key: $k, kind: "secret", op: (if $b == "" then "add" else "update" end),
      before: (if $b == "" then null else {fp: $b} end), after: {fp: $f}}]} | del(..|nulls)')"
  ok "$key set in $env (encrypted, ${fp})"
}

_env_store_config() {
  local root="$1" env="$2" key="$3" val="$4" type="$5" msg="${6:-}" file before typed
  file=$(_env_file "$root" config "$env")
  before=$(jq -c --arg k "$key" '.values[$k] // empty' "$file" 2>/dev/null)
  typed=$(_env_typed_json "$type" "$val")
  if [[ -n "$before" && "$before" == "$typed" ]]; then
    info "$key unchanged in $env"
    return 0
  fi
  _env_jq_update "$file" "$(_env_config_default "$env")" \
    '.values[$k] = $v | .values |= (to_entries | sort_by(.key) | from_entries)' --arg k "$key" --argjson v "$typed" || return 1
  _env_history_append "$root" <<<"$(jq -nc --arg e "$env" --arg k "$key" --arg b "$before" --argjson a "$typed" --arg m "$msg" \
    '{action: "set", env: $e, message: (if $m == "" then null else $m end), changes: [{key: $k, kind: "config", op: (if $b == "" then "add" else "update" end),
      before: (if $b == "" then null else ($b | fromjson) end), after: $a}]} | del(..|nulls)')"
  ok "$key=$(printf '%s' "$typed" | jq -r 'if type == "string" then . else tojson end') in $env"
}

# Remove KEY from the other store when it changes kind.
_env_remove_from() {
  local root="$1" env="$2" kind="$3" key="$4" file
  file=$(_env_file "$root" "$kind" "$env")
  [[ -f "$file" ]] || return 0
  if [[ "$kind" == "config" ]]; then
    jq -e --arg k "$key" '.values | has($k)' "$file" >/dev/null 2>&1 || return 0
    _env_jq_update "$file" '{}' 'del(.values[$k])' --arg k "$key"
  else
    jq -e --arg k "$key" '.values | has($k)' "$file" >/dev/null 2>&1 || return 0
    _env_crypt set --file "$file" >/dev/null < <(jq -nc --arg k "$key" --arg a "$(_env_actor)" '{unset: [$k], actor: $a}') || return 1
  fi
}

_env_cmd_set() {
  local env="" kind="" type="" from_stdin=false msg="" no_schema=false force=false
  local pairs=() a
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --secret) kind="secret"; shift ;;
      --config | --plain) kind="config"; shift ;;
      --type) type="${2:-}"; shift 2 ;;
      --type=*) type="${1#*=}"; shift ;;
      --stdin) from_stdin=true; shift ;;
      -m | --message) msg="${2:-}"; shift 2 ;;
      --no-schema) no_schema=true; shift ;;
      --force | -f) force=true; shift ;;
      -h | --help) _env_usage; return 0 ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) pairs[${#pairs[@]}]="$1"; shift ;;
    esac
  done
  if [[ ${#pairs[@]} -eq 0 ]]; then
    err "Usage: muster env set KEY[=VALUE] [--env E] [--secret]"
    return 1
  fi
  if [[ -n "$type" ]]; then
    case "$type" in string | secret | bool | number | json) ;; *) err "--type must be string, secret, bool, number or json"; return 1 ;; esac
  fi
  _env_cmd_root || return 1
  _env_need_store || return 1
  env=$(_env_pick "$env") || return 1
  local root="$_ENV_ROOT" key val has_val def k_type k_kind problems rc=0
  _env_schema_add_env "$root" "$env"

  for a in "${pairs[@]}"; do
    has_val=false
    if [[ "$a" == *=* ]]; then
      key="${a%%=*}"
      val="${a#*=}"
      has_val=true
    else
      key="$a"
      val=""
    fi
    if ! _env_valid_name "$key"; then
      err "Invalid key name: $key (letters, digits and _, not starting with a digit)"
      rc=1
      continue
    fi
    if _env_name_blocked "$key"; then
      err "$key can't be managed by muster env (it changes how programs run)"
      rc=1
      continue
    fi

    def=$(_env_schema_key "$root" "$key")
    k_type="$type"
    [[ -z "$k_type" && "$def" != "null" ]] && k_type=$(printf '%s' "$def" | jq -r '.type // "string"')
    # Kind: flag > schema > name heuristic
    if [[ -n "$kind" ]]; then
      k_kind="$kind"
    elif [[ "$k_type" == "secret" ]] || printf '%s' "$def" | jq -e '.sensitive == true' >/dev/null 2>&1; then
      k_kind="secret"
    elif [[ -n "$k_type" ]]; then
      k_kind="config"
    else
      local upper
      upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
      if [[ "$upper" =~ $_ENV_SECRET_NAME_RE ]]; then k_kind="secret"; else k_kind="config"; fi
    fi
    [[ "$k_kind" == "secret" && -z "$k_type" ]] && k_type="secret"
    [[ "$k_kind" == "secret" && "$k_type" != "secret" && "$def" == "null" ]] && k_type="secret"

    if [[ "$has_val" == "false" ]]; then
      if [[ "$from_stdin" == "true" || ! -t 0 ]]; then
        val=$(cat)
      elif [[ "$k_kind" == "secret" ]]; then
        val=$(_env_read_secret "$key ($env)") || { rc=1; continue; }
      else
        printf '  %s (%s): ' "$key" "$env"
        IFS= read -r val || true
      fi
    elif [[ "$k_kind" == "secret" ]]; then
      warn "The value of $key was passed on the command line (shell history, ps). Next time: muster env set $key"
    fi

    [[ -z "$k_type" ]] && k_type=$(_env_infer_type "$key" "$val")
    [[ "$k_type" == "secret" && "$k_kind" != "secret" ]] && k_kind="secret"

    if [[ "$def" != "null" ]]; then
      problems=$(_env_validate_value "$def" "$val")
      if [[ -n "$problems" && "$force" != "true" ]]; then
        err "$key $(printf '%s' "$problems" | head -1) (use --force to store it anyway)"
        rc=1
        continue
      fi
    elif [[ "$no_schema" != "true" ]]; then
      if [[ "$k_type" == "number" && "$val" =~ ^-?[0-9]+$ ]]; then
        _env_schema_add_key "$root" "$key" "$k_type" '{"integer":true}'
      else
        _env_schema_add_key "$root" "$key" "$k_type"
      fi
      info "Added $key to muster.env.schema.json as $k_type"
    fi

    if [[ "$k_kind" == "secret" ]]; then
      _env_store_secret "$root" "$env" "$key" "$val" "$msg" || { rc=1; continue; }
      _env_remove_from "$root" "$env" config "$key"
    else
      [[ "$k_type" == "secret" ]] && k_type="string"
      _env_store_config "$root" "$env" "$key" "$val" "$k_type" "$msg" || { rc=1; continue; }
      _env_remove_from "$root" "$env" secrets "$key"
    fi
  done
  val=""
  return "$rc"
}

# ── get ──

_env_cmd_get() {
  local env="" reveal=false key="" json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --reveal | --raw) reveal=true; shift ;;
      --json) json=true; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) key="$1"; shift ;;
    esac
  done
  [[ -z "$key" ]] && { err "Usage: muster env get KEY [--env E] [--reveal]"; return 1; }
  _env_cmd_root || return 1
  _env_need_store || return 1
  env=$(_env_pick "$env") || return 1
  local root="$_ENV_ROOT" mode=optional entry fp
  [[ "$reveal" == "true" ]] && mode=required
  if ! _env_resolve "$root" "$env" "$mode"; then
    err "Can't decrypt '$env': $_ENV_LOCKED" >&2
    return 1
  fi
  entry=$(printf '%s' "$_ENV_RESOLVED" | jq -c --arg k "$key" '.[$k] // empty')
  if [[ -z "$entry" ]]; then
    err "$key is not set in $env" >&2
    return 1
  fi
  if printf '%s' "$entry" | jq -e '.secret' >/dev/null && [[ "$reveal" != "true" ]]; then
    fp=$(jq -r --arg k "$key" '._meta.key_fingerprints[$k] // "?"' "$(_env_file "$root" secrets "$env")" 2>/dev/null)
    if [[ "$json" == "true" ]]; then
      jq -nc --arg k "$key" --arg f "$fp" --arg e "$env" '{key: $k, env: $e, secret: true, fingerprint: $f}'
    else
      printf '‹secret:%s›\n' "${fp#hmac:}"
      [[ -t 1 ]] && printf '  %b(muster env get %s --reveal to print it)%b\n' "$DIM" "$key" "$RESET" >&2
    fi
    return 0
  fi
  if [[ "$json" == "true" ]]; then
    printf '%s' "$entry" | jq -c --arg k "$key" --arg e "$env" '{key: $k, env: $e, value, type, source, secret}'
  else
    printf '%s' "$entry" | jq -r '.value'
  fi
}

# ── unset ──

_env_cmd_unset() {
  local env="" msg="" keys=() k
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      -m | --message) msg="${2:-}"; shift 2 ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) keys[${#keys[@]}]="$1"; shift ;;
    esac
  done
  [[ ${#keys[@]} -eq 0 ]] && { err "Usage: muster env unset KEY… [--env E]"; return 1; }
  _env_cmd_root || return 1
  _env_need_store || return 1
  env=$(_env_pick "$env") || return 1
  local root="$_ENV_ROOT" cfg sec found rc=0 req
  cfg=$(_env_file "$root" config "$env")
  sec=$(_env_file "$root" secrets "$env")
  for k in "${keys[@]}"; do
    found=false
    if [[ -f "$cfg" ]] && jq -e --arg k "$k" '.values | has($k)' "$cfg" >/dev/null 2>&1; then
      _env_jq_update "$cfg" '{}' 'del(.values[$k])' --arg k "$k"
      found=config
    fi
    if [[ -f "$sec" ]] && jq -e --arg k "$k" '.values | has($k)' "$sec" >/dev/null 2>&1; then
      _env_require_crypt || return 1
      _env_crypt set --file "$sec" < <(jq -nc --arg k "$k" --arg a "$(_env_actor)" '{unset: [$k], actor: $a}') || {
        err "Could not unset $k: $_ENV_CRYPT_ERR"
        rc=1
        continue
      }
      found=secret
    fi
    if [[ "$found" == "false" ]]; then
      warn "$k is not set in $env"
      continue
    fi
    req=$(_env_schema_key "$root" "$k" | jq -r --arg e "$env" 'if .required == true or ((.required | type) == "array" and (.required | index($e))) then "yes" else "" end' 2>/dev/null)
    [[ -n "$req" ]] && warn "$k is required in $env by the schema; muster env check will fail until it is set"
    _env_history_append "$root" <<<"$(jq -nc --arg e "$env" --arg k "$k" --arg kind "$found" --arg m "$msg" \
      '{action: "unset", env: $e, message: (if $m == "" then null else $m end), changes: [{key: $k, kind: $kind, op: "remove"}]} | del(..|nulls)')"
    ok "$k removed from $env"
  done
  return "$rc"
}

# ── list ──

_env_cmd_list() {
  local env="" show=false json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --show-values | --reveal) show=true; shift ;;
      --json) json=true; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) env="$1"; shift ;;
    esac
  done
  _env_cmd_root || return 1
  _env_need_store || return 1
  env=$(_env_pick "$env") || return 1
  local root="$_ENV_ROOT" mode=optional fps="{}"
  [[ "$show" == "true" ]] && mode=required
  if [[ "$show" == "false" ]]; then mode=none; fi
  if ! _env_resolve "$root" "$env" "$mode"; then
    err "Can't decrypt '$env': $_ENV_LOCKED"
    return 1
  fi
  [[ -f "$(_env_file "$root" secrets "$env")" ]] && fps=$(jq -c '._meta.key_fingerprints // {}' "$(_env_file "$root" secrets "$env")")
  local schema="null"
  [[ -f "$(_env_schema_file "$root")" ]] && schema=$(cat "$(_env_schema_file "$root")")
  local rows
  rows=$(printf '{"r":%s,"fps":%s,"schema":%s}' "$_ENV_RESOLVED" "$fps" "$schema" | jq -c --argjson show "$show" '
    .fps as $fps | (.schema.keys // {}) as $k
    | [.r | to_entries[] | {key, type: .value.type, source: .value.source, secret: .value.secret,
        value: (if .value.secret and ($show | not) then null else .value.value end),
        fingerprint: (if .value.secret then $fps[.key] else null end),
        description: ($k[.key].description // null)}]
    + [($k | to_entries[] | select(.value.type == "secret" or .value.required != null)) as $e
       | select(.r[$e.key] == null) | {key: $e.key, type: ($e.value.type // "string"), source: "(not set)", secret: ($e.value.type == "secret"), value: null, fingerprint: null, description: ($e.value.description // null)}]
    | sort_by(.key)')
  if [[ "$json" == "true" ]]; then
    printf '%s' "$rows" | jq -c --arg e "$env" '{env: $e, keys: .}'
    return 0
  fi
  printf '\n  %b%s%b  %b%s%b\n\n' "$BOLD" "$env" "$RESET" "$DIM" "$root" "$RESET"
  if [[ "$(printf '%s' "$rows" | jq 'length')" == "0" ]]; then
    printf '  (empty — muster env set KEY=VALUE)\n\n'
    return 0
  fi
  printf '%s' "$rows" | jq -r '.[] | [.key, .type, .source,
      (if .secret then (if .value != null then .value else "‹secret:" + ((.fingerprint // "?") | ltrimstr("hmac:")) + "›" end)
       elif .value == null then "—" else .value end)] | @tsv' |
    while IFS=$'\t' read -r k t s v; do
      [[ ${#v} -gt 48 ]] && v="${v:0:45}..."
      printf '  %-28s %-7s %-26s %s\n' "$k" "$t" "$s" "$v"
    done
  [[ -n "$_ENV_LOCKED" && "$show" == "true" ]] && warn "secrets locked: $_ENV_LOCKED"
  printf '\n'
}

# ── diff ──

_env_cmd_diff() {
  local a="" b="" json=false reveal=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=true; shift ;;
      --reveal) reveal=true; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) if [[ -z "$a" ]]; then a="$1"; else b="$1"; fi; shift ;;
    esac
  done
  [[ -z "$a" || -z "$b" ]] && { err "Usage: muster env diff <envA> <envB> [--json]"; return 1; }
  _env_cmd_root || return 1
  _env_need_store || return 1
  _env_valid_envname "$a" && _env_valid_envname "$b" || { err "Invalid environment name"; return 1; }
  local root="$_ENV_ROOT" ra rb la lb
  _env_resolve "$root" "$a" optional || return 1
  ra="$_ENV_RESOLVED"
  la="$_ENV_LOCKED"
  _env_resolve "$root" "$b" optional || return 1
  rb="$_ENV_RESOLVED"
  lb="$_ENV_LOCKED"
  local d
  d=$(printf '{"a":%s,"b":%s}' "$ra" "$rb" | jq -c --argjson reveal "$reveal" '
    def show($e): if $e == null then null elif $e.secret and ($reveal | not) then null else $e.value end;
    .a as $a | .b as $b
    | [(($a | keys) + ($b | keys) | unique)[] as $k
       | {key: $k, a: $a[$k], b: $b[$k]}
       | . + {status:
           (if .a == null then "added" elif .b == null then "removed"
            elif (.a.locked // false) or (.b.locked // false) then "unknown"
            elif .a.value == .b.value then "same" else "changed" end),
           secret: ((.a.secret // false) or (.b.secret // false))}
       | {key, status, secret, a: show(.a), b: show(.b)}]')
  ra=""
  rb=""
  if [[ "$json" == "true" ]]; then
    printf '%s' "$d" | jq -c --arg a "$a" --arg b "$b" --arg la "$la" --arg lb "$lb" \
      '{a: $a, b: $b, locked: ([$la, $lb] | map(select(. != ""))), keys: .}'
    return 0
  fi
  printf '\n  %b%s → %s%b\n\n' "$BOLD" "$a" "$b" "$RESET"
  printf '%s' "$d" | jq -r '.[] | select(.status != "same") | [.status, .key, (if .secret then "secret" else "-" end), (.a // "" | tostring), (.b // "" | tostring)] | join("\u001f")' |
    while IFS=$'\x1f' read -r st k sec va vb; do
      [[ "$sec" == "-" ]] && sec=""
      case "$st" in
        added) printf '  %b+%b %-28s %s\n' "$GREEN" "$RESET" "$k" "$([[ -n "$sec" ]] && echo "(secret)" || echo "$vb")" ;;
        removed) printf '  %b-%b %-28s %s\n' "$RED" "$RESET" "$k" "$([[ -n "$sec" ]] && echo "(secret)" || echo "$va")" ;;
        changed) if [[ -n "$sec" && -z "$va$vb" ]]; then printf '  %b~%b %-28s (secret differs)\n' "$YELLOW" "$RESET" "$k"; else printf '  %b~%b %-28s %s → %s\n' "$YELLOW" "$RESET" "$k" "$va" "$vb"; fi ;;
        unknown) printf '  %b?%b %-28s (secret, locked: no key)\n' "$DIM" "$RESET" "$k" ;;
      esac
    done
  local same
  same=$(printf '%s' "$d" | jq '[.[] | select(.status == "same")] | length')
  printf '\n  %b%s identical%b\n\n' "$DIM" "$same" "$RESET"
}

# ── edit ──

_env_edit_cleanup() {
  local dir="$1" f
  [[ -n "$dir" && -d "$dir" ]] || return 0
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    # Overwrite before unlinking (best effort; FileVault/LUKS still advised)
    dd if=/dev/zero of="$f" bs=1 count="$(wc -c <"$f" | tr -d ' ')" conv=notrunc 2>/dev/null
    rm -f "$f"
  done
  rmdir "$dir" 2>/dev/null
}

_env_cmd_edit() {
  local env=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) env="$1"; shift ;;
    esac
  done
  _env_cmd_root || return 1
  _env_need_store || return 1
  env=$(_env_pick "$env") || return 1
  local root="$_ENV_ROOT" cfg_vals sec_vals="{}" editor
  editor="${VISUAL:-${EDITOR:-vi}}"
  if [[ -f "$(_env_file "$root" secrets "$env")" ]]; then
    _env_require_crypt || return 1
    _env_decrypt "$root" "$env" || { err "Can't decrypt '$env': $_ENV_CRYPT_ERR"; return 1; }
    sec_vals="$_ENV_DECRYPTED"
    _ENV_DECRYPTED=""
  fi
  cfg_vals=$(jq -c '.values // {}' "$(_env_file "$root" config "$env")" 2>/dev/null)
  [[ -z "$cfg_vals" ]] && cfg_vals="{}"

  local tmpbase dir file
  tmpbase="${XDG_RUNTIME_DIR:-}"
  [[ -z "$tmpbase" && -d /dev/shm && -w /dev/shm ]] && tmpbase=/dev/shm
  [[ -z "$tmpbase" ]] && tmpbase="${TMPDIR:-/tmp}"
  dir=$(umask 077 && mktemp -d "${tmpbase%/}/muster-env.XXXXXX") || return 1
  # shellcheck disable=SC2064  # expand $dir now, on purpose
  trap "_env_edit_cleanup '$dir'" EXIT
  # shellcheck disable=SC2064
  trap "_env_edit_cleanup '$dir'; exit 130" INT TERM
  file="$dir/${env}.env"
  (
    umask 077
    {
      printf '# muster env edit — environment: %s\n' "$env"
      printf '# KEY=VALUE, one per line, value taken literally (no quotes). Delete a line to unset.\n'
      printf '# Keys keep their kind; new keys go where you put them. This file is wiped on exit.\n'
      printf '# --- config ---\n'
      printf '%s' "$cfg_vals" | jq -r 'to_entries[] | "\(.key)=\(.value | if type == "string" then . else tojson end)"'
      printf '# --- secrets (encrypted on save) ---\n'
      printf '%s' "$sec_vals" | jq -r 'to_entries[] | select(.value | contains("\n") | not) | "\(.key)=\(.value)"'
    } >"$file"
  )
  local multi
  multi=$(printf '%s' "$sec_vals" | jq -r 'to_entries[] | select(.value | contains("\n")) | .key')
  [[ -n "$multi" ]] && warn "Multi-line secrets are not shown (edit with muster env set): $(printf '%s' "$multi" | tr '\n' ' ')"

  local before_sum after_sum
  before_sum=$(shasum -a 256 "$file" | cut -d' ' -f1)
  local erc=0
  if { : </dev/tty; } 2>/dev/null; then
    $editor "$file" </dev/tty >/dev/tty || erc=$?
  else
    $editor "$file" || erc=$?
  fi
  if ((erc != 0)); then
    err "Editor exited with an error; nothing changed"
    _env_edit_cleanup "$dir"
    trap - EXIT INT TERM
    return 1
  fi
  after_sum=$(shasum -a 256 "$file" | cut -d' ' -f1)
  if [[ "$before_sum" == "$after_sum" ]]; then
    info "No changes"
    _env_edit_cleanup "$dir"
    trap - EXIT INT TERM
    return 0
  fi

  # Parse the edited file → {config:{}, secrets:{}}
  local section="config" line key val edited='{"config":{},"secrets":{}}' n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    case "$line" in
      "# --- config"*) section=config; continue ;;
      "# --- secrets"*) section=secrets; continue ;;
      "#"* | "") continue ;;
    esac
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      edited=$(printf '%s' "$edited" | jq -c --arg s "$section" --arg k "$key" --rawfile v <(printf '%s' "$val") '.[$s][$k] = $v')
    else
      err "Line $n is not KEY=VALUE; nothing was saved"
      _env_edit_cleanup "$dir"
      trap - EXIT INT TERM
      return 1
    fi
  done <"$file"
  _env_edit_cleanup "$dir"
  trap - EXIT INT TERM
  val=""

  # Existing keys keep their kind; compute the change set
  local plan
  plan=$(printf '{"c":%s,"s":%s,"e":%s,"multi":%s}' "$cfg_vals" "$sec_vals" "$edited" "$(printf '%s' "$multi" | jq -Rsc 'split("\n") | map(select(length > 0))')" | jq -c '
    .c as $c | .s as $s | .multi as $m
    | (.e.config + .e.secrets) as $all
    | (.e.secrets | with_entries(select($c[.key] == null))) as $newsec
    | (.e.config | with_entries(select($s[.key] != null))) as $movedsec
    | ($newsec + $movedsec) as $sec
    | ($all | with_entries(select($sec[.key] == null))) as $cfg
    | {set_config: ($cfg | with_entries(select(($c[.key] | if type == "string" then . elif . == null then null else tojson end) != .value))),
       set_secrets: ($sec | with_entries(select($s[.key] != .value))),
       unset_config: [$c | keys[] | select($all[.] == null)],
       unset_secrets: [$s | keys[] | select($all[.] == null and ($m | index(.) | not))]}')
  sec_vals=""
  edited=""
  local k changed=0 type
  while IFS=$'\t' read -r k; do
    [[ -z "$k" ]] && continue
    _env_valid_name "$k" && ! _env_name_blocked "$k" || { warn "Skipped $k (not a manageable name)"; continue; }
    type=$(_env_schema_key "$root" "$k" | jq -r '.type // empty')
    [[ -z "$type" || "$type" == "secret" ]] && type=$(_env_infer_type "$k" "$(printf '%s' "$plan" | jq -r --arg k "$k" '.set_config[$k]')")
    [[ "$type" == "secret" ]] && type=string
    _env_store_config "$root" "$env" "$k" "$(printf '%s' "$plan" | jq -r --arg k "$k" '.set_config[$k]')" "$type" "edit" && changed=$((changed + 1))
  done < <(printf '%s' "$plan" | jq -r '.set_config | keys[]')
  if [[ "$(printf '%s' "$plan" | jq '.set_secrets | length + (.unset_secrets | length)')" != "0" ]]; then
    _env_require_crypt || return 1
    _env_secrets_init "$root" "$env" || return 1
    local sfile before_fps
    sfile=$(_env_file "$root" secrets "$env")
    before_fps=$(jq -c '._meta.key_fingerprints // {}' "$sfile")
    _env_crypt set --file "$sfile" < <(printf '%s' "$plan" | jq -c --arg a "$(_env_actor)" '{set: .set_secrets, unset: .unset_secrets, actor: $a}') || { err "Could not save secrets: $_ENV_CRYPT_ERR"; return 1; }
    printf '%s' "$_ENV_CRYPT_OUT" | jq -c --arg e "$env" --argjson b "$before_fps" '
      {action: "edit", env: $e, changes: ([.changed[] as $k | {key: $k, kind: "secret", op: (if $b[$k] then "update" else "add" end), after: {fp: .fingerprints[$k]}} + (if $b[$k] then {before: {fp: $b[$k]}} else {} end)]
        + [.removed[] | {key: ., kind: "secret", op: "remove"}])}' | _env_history_append "$root"
    changed=$((changed + $(printf '%s' "$_ENV_CRYPT_OUT" | jq '.changed + .removed | length')))
    # A key that became secret leaves config
    while IFS= read -r k; do [[ -n "$k" ]] && _env_remove_from "$root" "$env" config "$k"; done < <(printf '%s' "$plan" | jq -r '.set_secrets | keys[]')
  fi
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    _env_jq_update "$(_env_file "$root" config "$env")" '{}' 'del(.values[$k])' --arg k "$k"
    jq -nc --arg e "$env" --arg k "$k" '{action: "edit", env: $e, changes: [{key: $k, kind: "config", op: "remove"}]}' | _env_history_append "$root"
    changed=$((changed + 1))
  done < <(printf '%s' "$plan" | jq -r '.unset_config[]')
  plan=""
  ok "Saved $changed change(s) to $env"
}

# ── history ──

_env_cmd_history() {
  local env="" key="" json=false all=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --json) json=true; shift ;;
      --all) all=true; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) key="$1"; shift ;;
    esac
  done
  _env_cmd_root || return 1
  local file
  file=$(_env_history_file "$_ENV_ROOT")
  [[ -f "$file" ]] || { [[ "$json" == "true" ]] && echo '[]' || info "No env history yet"; return 0; }
  local events
  events=$(jq -sc --arg e "$env" --arg k "$key" '
    map(select(($e == "" or .env == $e or .env == null))
        | select($k == "" or ((.changes // []) | any(.key == $k))))' "$file")
  if [[ "$json" == "true" ]]; then
    printf '%s\n' "$events"
    return 0
  fi
  local lim=20
  [[ "$all" == "true" ]] && lim=100000
  printf '%s' "$events" | jq -r --argjson n "$lim" '.[-$n:] | reverse[] |
    "\(.ts)\t\(.actor)\t\(.env // "-")\t\(.action)\t" +
    ((.changes // []) | map(.key + (if .kind == "secret" then
        (if .op == "remove" then " removed" elif .before then " " + .before.fp + "→" + .after.fp else " " + (.after.fp // "") end)
      elif .kind == "flag" then " → " + (.after | tostring)
      elif .op == "remove" then " removed"
      else " " + ((.before // "∅") | tostring) + "→" + ((.after // "") | tostring) end)) | join(", "))
    + (if .message then "  \"" + .message + "\"" else "" end)' |
    while IFS=$'\t' read -r ts who e act what; do
      printf '  %b%s%b  %-12s %-10s %-7s %s\n' "$DIM" "$ts" "$RESET" "$who" "$e" "$act" "$what"
    done
}

# ── check ──

_env_cmd_check() {
  local env="" strict=false json=false no_decrypt=false fail_stale=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --strict) strict=true; shift ;;
      --json) json=true; shift ;;
      --no-decrypt) no_decrypt=true; shift ;;
      --fail-on-stale) fail_stale=true; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) env="$1"; shift ;;
    esac
  done
  _env_cmd_root || return 1
  local root="$_ENV_ROOT"
  if ! _env_store_present "$root"; then
    if [[ "$json" == "true" ]]; then
      printf '{"ok":false,"errors":[{"code":"not_initialized","message":"muster env is not set up"}]}\n'
    else
      err "muster env is not set up here (muster env init)"
    fi
    return 1
  fi
  env=$(_env_pick "$env") || return 1
  local errors="[]" warnings="[]" decrypted=false sfile mode=optional
  sfile=$(_env_file "$root" secrets "$env")
  [[ "$no_decrypt" == "true" ]] && mode=none

  # Secrets file integrity
  if [[ -f "$sfile" ]]; then
    if ! _env_crypt_bin >/dev/null; then
      warnings=$(printf '%s' "$warnings" | jq -c '. + [{code: "no_crypt", message: "muster-crypt not installed: secret values and the file MAC were not checked"}]')
      mode=none
    elif [[ "$no_decrypt" == "true" ]]; then
      if ! _env_crypt verify --file "$sfile" --no-decrypt; then
        errors=$(printf '%s' "$errors" | jq -c --arg m "$_ENV_CRYPT_ERR" '. + [{code: "secrets_invalid", message: $m}]')
      fi
    else
      local vrc=0
      _env_crypt verify --file "$sfile" || vrc=$?
      case "$vrc" in
        0) decrypted=true ;;
        3)
          warnings=$(printf '%s' "$warnings" | jq -c --arg m "$_ENV_CRYPT_ERR" '. + [{code: "no_key", message: ("secrets not decrypted: " + $m)}]')
          mode=none
          _env_crypt verify --file "$sfile" --no-decrypt || errors=$(printf '%s' "$errors" | jq -c --arg m "$_ENV_CRYPT_ERR" '. + [{code: "secrets_invalid", message: $m}]')
          ;;
        *)
          errors=$(printf '%s' "$errors" | jq -c --arg m "$_ENV_CRYPT_ERR" '. + [{code: "integrity", message: $m}]')
          mode=none
          ;;
      esac
    fi
  fi

  if ! _env_resolve "$root" "$env" "$mode"; then
    mode=none
    _env_resolve "$root" "$env" none || return 1
  fi
  local schema="null" cfg="null"
  [[ -f "$(_env_schema_file "$root")" ]] && schema=$(cat "$(_env_schema_file "$root")")
  [[ -f "$(_env_file "$root" config "$env")" ]] && cfg=$(cat "$(_env_file "$root" config "$env")")
  local base="null"
  [[ -f "$(_env_file "$root" config base)" ]] && base=$(cat "$(_env_file "$root" config base)")

  local result
  result=$(printf '{"r":%s,"schema":%s,"cfg":%s,"base":%s}' "$_ENV_RESOLVED" "$schema" "$cfg" "$base" | jq -c \
    --arg env "$env" --argjson strict "$strict" --arg today "$(date -u +%Y-%m-%d)" "
    $_ENV_VALIDATE_JQ
    def check(\$v; \$d): {value: \$v, def: \$d} | problems;
    .r as \$r | (.schema.keys // {}) as \$k | (.schema.flags // {}) as \$f
    | [
        (\$k | to_entries[] | .key as \$key | .value as \$d
          | (\$d.required == true or ((\$d.required | type) == \"array\" and (\$d.required | index(\$env)))) as \$req
          | \$r[\$key] as \$e
          | if \$e == null or (\$e.value == \"\" and (\$e.locked | not)) then
              (if \$req then {code: \"missing\", key: \$key, message: \"\(\$key) is required in \(\$env) but not set\"} else empty end)
            elif (\$e.locked // false) then empty
            else (check(\$e.value; \$d)[] | {code: \"invalid\", key: \$key, message: \"\(\$key) \(.)\"})
            end),
        ((.cfg.values // {}) + (.base.values // {}) | keys[] as \$key
          | select(\$k[\$key].type == \"secret\" or \$k[\$key].sensitive == true)
          | {code: \"plaintext_secret\", key: \$key, message: \"\(\$key) is a secret but stored in plaintext config (move it: muster env set \(\$key) --secret)\"}),
        (if \$strict then (\$r | to_entries[] | select(.value.flag == null) | select(\$k[.key] == null)
          | {code: \"undeclared\", key: .key, message: \"\(.key) is not declared in muster.env.schema.json\"}) else empty end)
      ] as \$errors
    | [ (\$f | to_entries[] | select(.value.stale_after != null and .value.stale_after < \$today)
          | {code: \"stale_flag\", key: .key, message: \"flag \(.key) is past its stale_after date (\(.value.stale_after))\"}) ] as \$warn
    | {errors: \$errors, warnings: \$warn}")
  _ENV_RESOLVED=""
  errors=$(printf '{"a":%s,"b":%s}' "$errors" "$result" | jq -c '.a + .b.errors')
  warnings=$(printf '{"a":%s,"b":%s}' "$warnings" "$result" | jq -c '.a + .b.warnings')
  if [[ "$fail_stale" == "true" ]]; then
    errors=$(printf '{"a":%s,"b":%s}' "$errors" "$warnings" | jq -c '.a + [.b[] | select(.code == "stale_flag")]')
    warnings=$(printf '%s' "$warnings" | jq -c '[.[] | select(.code != "stale_flag")]')
  fi
  local n_err
  n_err=$(printf '%s' "$errors" | jq 'length')
  if [[ "$json" == "true" ]]; then
    jq -nc --arg env "$env" --argjson e "$errors" --argjson w "$warnings" --argjson d "$decrypted" \
      '{ok: ($e | length == 0), env: $env, decrypted: $d, errors: $e, warnings: $w}'
  else
    printf '\n  %bmuster env check%b — %s\n\n' "$BOLD" "$RESET" "$env"
    printf '%s' "$errors" | jq -r '.[].message' | while IFS= read -r m; do printf '  %b✗%b %s\n' "$RED" "$RESET" "$m"; done
    printf '%s' "$warnings" | jq -r '.[].message' | while IFS= read -r m; do printf '  %b!%b %s\n' "$YELLOW" "$RESET" "$m"; done
    if [[ "$n_err" == "0" ]]; then
      printf '  %b✓%b %s is valid%s\n' "$GREEN" "$RESET" "$env" "$([[ "$decrypted" == "true" ]] && echo " (secrets decrypted, MAC verified)")"
    fi
    printf '\n'
  fi
  [[ "$n_err" == "0" ]]
}

# ── pull ──

_env_cmd_pull() {
  local env="" to="" format="dotenv" force=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --to | -o) to="${2:-}"; shift 2 ;;
      --to=*) to="${1#*=}"; shift ;;
      --format) format="${2:-}"; shift 2 ;;
      --format=*) format="${1#*=}"; shift ;;
      --force | -f) force=true; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) env="$1"; shift ;;
    esac
  done
  case "$format" in dotenv | json) ;; *) err "--format must be dotenv or json"; return 1 ;; esac
  _env_cmd_root || return 1
  _env_need_store || return 1
  env=$(_env_pick "$env") || return 1
  local root="$_ENV_ROOT"
  [[ -z "$to" ]] && to="$root/.env"
  [[ "$to" != /* ]] && to="$PWD/$to"
  if [[ "$force" != "true" && "$to" == "$root"/* ]] && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if ! git -C "$root" check-ignore -q "$to" 2>/dev/null; then
      err "$to is not gitignored; refusing to write secrets there (add it to .gitignore, or --force)"
      return 1
    fi
  fi
  if ! _env_resolve "$root" "$env" required; then
    err "Can't decrypt '$env': $_ENV_LOCKED"
    return 1
  fi
  (
    umask 077
    : >"$to" && chmod 600 "$to"
    if [[ "$format" == "json" ]]; then
      printf '%s' "$_ENV_RESOLVED" | jq 'with_entries(select(.value.value != null) | .value = .value.value)' >"$to"
    else
      {
        printf '# Generated by muster env pull (%s) — do not commit. Source of truth: .muster/env\n' "$env"
        printf '%s' "$_ENV_RESOLVED" | jq -r '
          to_entries[] | select(.value.value != null) | .key as $k | .value.value
          | if test("^[A-Za-z0-9_./:@%+,=-]*$") then "\($k)=\(.)"
            else "\($k)=\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\\$"; "\\$")) + "\"" end'
      } >"$to"
    fi
  )
  _ENV_RESOLVED=""
  chmod 600 "$to"
  ok "Wrote $env to $to (0600)"
}

# ── example ──

_env_write_example() {
  local root="$1" out="$2" schema
  schema=$(_env_schema_file "$root")
  [[ -f "$schema" ]] || return 1
  jq -r '
    def str: if type == "string" then . else tojson end;
    "# Generated by `muster env example` from muster.env.schema.json — do not edit by hand.",
    "# Real values live in .muster/env (secrets encrypted). Run your app with: muster run -- <cmd>",
    "",
    ((.keys // {}) | to_entries | group_by(.value.services // [] | join(",")) | .[] |
      (if (.[0].value.services // []) | length > 0 then "# ── " + (.[0].value.services | join(", ")) + " ──" else empty end),
      (.[] | .key as $k | .value as $d |
        ((if $d.description then "# " + ($d.description | gsub("\n"; " ")) else empty end),
         ("# " + ([($d.type // "string"),
                   (if $d.required == true then "required" elif ($d.required | type) == "array" then "required in " + ($d.required | join(", ")) else "optional" end),
                   (if $d.enum then "one of: " + ($d.enum | map(tostring) | join("|")) else empty end),
                   (if $d.format then "format: " + $d.format else empty end)] | join(" — "))),
         (if $d.type == "secret" then "\($k)=" else "\($k)=\($d.default // "" | str)" end),
         ""))),
    (if ((.flags // {}) | length) > 0 then
       "# ── feature flags ──",
       ((.flags // {}) | to_entries[] |
         "# flag \(.key)" + (if .value.description then ": " + .value.description else "" end),
         "\(.value.env_var // ("MUSTER_FLAG_" + (.key | ascii_upcase | gsub("[^A-Z0-9]"; "_"))))=")
     else empty end)
  ' "$schema" >"$out"
}

_env_cmd_example() {
  local to=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to | -o) to="${2:-}"; shift 2 ;;
      --to=*) to="${1#*=}"; shift ;;
      --stdout) to="/dev/stdout"; shift ;;
      *) err "Unknown option: $1"; return 1 ;;
    esac
  done
  _env_cmd_root || return 1
  _env_need_store || return 1
  [[ -z "$to" ]] && to="$_ENV_ROOT/.env.example"
  _env_write_example "$_ENV_ROOT" "$to" || { err "No schema (muster env init)"; return 1; }
  [[ "$to" == "/dev/stdout" ]] || ok "Wrote $to"
}

# ── keys and recipients ──

_env_cmd_keygen() {
  local ci="" envs=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ci) ci="${2:-}"; shift 2 ;;
      --ci=*) ci="${1#*=}"; shift ;;
      --envs) envs="${2:-}"; shift 2 ;;
      --envs=*) envs="${1#*=}"; shift ;;
      *) err "Unknown option: $1"; return 1 ;;
    esac
  done
  has_cmd jq || { err "muster env needs jq"; return 1; }
  _env_require_crypt || return 1
  if [[ -z "$ci" ]]; then
    local existed=true
    [[ -f "$(_env_identity_file)" ]] || existed=false
    _env_ensure_identity || return 1
    local pub
    pub=$(_env_my_pubkey) || { err "Could not read your key: $_ENV_CRYPT_ERR"; return 1; }
    [[ "$existed" == "false" ]] && ok "Created $(_env_identity_file) (0600)"
    printf '\n  Your public key (safe to share):\n\n  %s\n\n' "$pub"
    printf '  A teammate with access adds you with:\n    muster env recipient add dev:%s --pubkey %s… --envs local\n\n' "$(_env_actor | tr -c 'A-Za-z0-9._@-' '-' | sed 's/-*$//')" "${pub:0:20}"
    return 0
  fi
  [[ "$ci" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$ ]] || { err "Invalid CI key name: $ci"; return 1; }
  [[ -z "$envs" ]] && { err "Say which environments CI may decrypt: --envs staging,production"; return 1; }
  _env_cmd_root || return 1
  _env_need_store || return 1
  _env_crypt keygen --kind ci --print-secret || { err "$_ENV_CRYPT_ERR"; return 1; }
  local out="$_ENV_CRYPT_OUT" pub sec
  pub=$(printf '%s' "$out" | jq -r .public)
  sec=$(printf '%s' "$out" | jq -r .secret)
  out=""
  _env_recipient_add "$_ENV_ROOT" "ci:$ci" "$pub" "$envs" || return 1
  printf '\n  %bCI key for %s%b — shown once. Store it as a CI secret named MUSTER_ENV_KEY:\n\n' "$BOLD" "$ci" "$RESET"
  printf '  %s\n\n' "$sec"
  sec=""
  printf '  It can decrypt: %s. Commit .muster/env/ so CI sees the new recipient.\n\n' "$envs"
}

# Rewrap every secrets file to match recipients.json.
_env_recipients_sync() {
  local root="$1" rotate="${2:-false}" only_env="${3:-}" f env recips rc=0 out
  for f in "$(_env_dir "$root")"/*.secrets.json; do
    [[ -f "$f" ]] || continue
    env=$(basename "$f")
    env="${env%.secrets.json}"
    [[ -n "$only_env" && "$env" != "$only_env" ]] && continue
    recips=$(_env_recipients_for "$root" "$env")
    if [[ "$recips" == "[]" ]]; then
      err "No recipients left for '$env'; refusing to lock everyone out"
      rc=1
      continue
    fi
    _env_crypt recipients --file "$f" < <(jq -nc --argjson r "$recips" --argjson rot "$rotate" --arg a "$(_env_actor)" '{recipients: $r, rotate: $rot, actor: $a}') || {
      err "$env: $_ENV_CRYPT_ERR"
      rc=1
      continue
    }
    out="$_ENV_CRYPT_OUT"
    local added removed rotated
    added=$(printf '%s' "$out" | jq -r '.added | join(", ")')
    removed=$(printf '%s' "$out" | jq -r '.removed | join(", ")')
    rotated=$(printf '%s' "$out" | jq -r '.rotated')
    if [[ -n "$added$removed" || "$rotated" == "true" ]]; then
      ok "$env: ${added:+added $added }${removed:+removed $removed }$([[ "$rotated" == "true" ]] && echo "(new data key, values re-encrypted)")"
      printf '%s' "$out" | jq -c --arg e "$env" '{action: "recipients", env: $e, added, removed, rotated}' | _env_history_append "$root"
      if [[ -n "$removed" ]]; then
        printf '  %bRotate these at their source%b (%s could read them before):\n' "$YELLOW" "$RESET" "$removed"
        jq -r '.values | keys[]' "$f" | sed 's/^/    - /'
      fi
    fi
  done
  return "$rc"
}

_env_recipient_add() {
  local root="$1" id="$2" pub="$3" envs="$4" rfile fp
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9:._@-]{0,127}$ ]] || { err "Invalid recipient id: $id"; return 1; }
  _env_crypt inspect-key < <(jq -nc --arg p "$pub" '{public: $p}') || { err "Not a valid public key: $_ENV_CRYPT_ERR"; return 1; }
  fp=$(printf '%s' "$_ENV_CRYPT_OUT" | jq -r .fingerprint)
  rfile=$(_env_recipients_file "$root")
  _env_jq_update "$rfile" '{"version":1,"recipients":[]}' \
    '.recipients = ([.recipients[]? | select(.id != $id)] + [{id: $id, public: $p, envs: ($e | split(",") | map(gsub(" "; "")) | map(select(length > 0))), added_at: $t}])' \
    --arg id "$id" --arg p "$pub" --arg e "$envs" --arg t "$(_env_now)" || return 1
  ok "Recipient $id ($fp) may open: $envs"
  _env_recipients_sync "$root"
}

_env_cmd_recipient() {
  local sub="${1:-list}"
  [[ $# -gt 0 ]] && shift
  _env_cmd_root || return 1
  _env_need_store || return 1
  local root="$_ENV_ROOT" rfile
  rfile=$(_env_recipients_file "$root")
  case "$sub" in
    list | ls)
      [[ -f "$rfile" ]] || { info "No recipients"; return 0; }
      if [[ "${1:-}" == "--json" ]]; then
        jq -c '[.recipients[] | {id, envs, added_at}]' "$rfile"
        return 0
      fi
      jq -r '.recipients[] | "\(.id)\t\((.envs // ["*"]) | join(","))\t\(.public[0:24])…"' "$rfile" |
        while IFS=$'\t' read -r i e p; do printf '  %-32s %-24s %b%s%b\n' "$i" "$e" "$DIM" "$p" "$RESET"; done
      ;;
    add)
      local id="" pub="" envs=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --pubkey | --public) pub="${2:-}"; shift 2 ;;
          --pubkey=*) pub="${1#*=}"; shift ;;
          --envs) envs="${2:-}"; shift 2 ;;
          --envs=*) envs="${1#*=}"; shift ;;
          -*) err "Unknown option: $1"; return 1 ;;
          *) id="$1"; shift ;;
        esac
      done
      [[ -z "$id" || -z "$pub" || -z "$envs" ]] && { err "Usage: muster env recipient add <id> --pubkey mstpub1… --envs local,staging (or '*')"; return 1; }
      _env_require_crypt || return 1
      _env_recipient_add "$root" "$id" "$pub" "$envs"
      ;;
    remove | rm)
      local id="${1:-}"
      [[ -z "$id" ]] && { err "Usage: muster env recipient remove <id>"; return 1; }
      jq -e --arg id "$id" '.recipients[]? | select(.id == $id)' "$rfile" >/dev/null 2>&1 || { err "No recipient $id"; return 1; }
      _env_require_crypt || return 1
      _env_jq_update "$rfile" '{}' '.recipients = [.recipients[] | select(.id != $id)]' --arg id "$id" || return 1
      ok "Removed $id from recipients.json"
      _env_recipients_sync "$root"
      ;;
    sync)
      _env_require_crypt || return 1
      _env_recipients_sync "$root"
      ;;
    *) err "Usage: muster env recipient list|add|remove|sync"; return 1 ;;
  esac
}

_env_cmd_rekey() {
  local env=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      *) err "Unknown option: $1"; return 1 ;;
    esac
  done
  _env_cmd_root || return 1
  _env_need_store || return 1
  _env_require_crypt || return 1
  [[ -n "$env" ]] && { _env_valid_envname "$env" || { err "Invalid environment name"; return 1; }; }
  _env_recipients_sync "$_ENV_ROOT" true "$env"
}

# ── run ──

cmd_run() {
  local env="" override=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --override) override=true; shift ;;
      --) shift; break ;;
      -h | --help)
        printf 'Usage: muster run [--env E] [--override] -- <command…>\n'
        printf '  Runs the command with config, decrypted secrets and MUSTER_FLAG_* in its\n'
        printf '  environment. Nothing is written to disk. Existing env vars win unless --override.\n'
        return 0
        ;;
      -*) err "Unknown option: $1 (put the command after --)"; return 1 ;;
      *) break ;;
    esac
  done
  [[ $# -eq 0 ]] && { err "Usage: muster run [--env E] -- <command…>"; return 1; }
  _env_cmd_root || return 1
  _env_need_store || return 1
  env=$(_env_pick "$env") || return 1
  local root="$_ENV_ROOT"
  if ! _env_resolve "$root" "$env" required; then
    err "Can't decrypt '$env': $_ENV_LOCKED" >&2
    [[ "$_ENV_LOCKED" == *"not installed"* ]] && _env_crypt_install_hint | sed 's/^/  /' >&2
    return 1
  fi
  local script flags
  script=$(_env_export_script) || return 1
  _ENV_RESOLVED=""
  _MUSTER_ENV_VARS=()
  [[ "$override" == "true" ]] && _ENV_EXPORT_OVERRIDE=1
  eval "$script"
  script=""
  export MUSTER_ENV="$env"
  if flags=$(_env_write_runtime_flags "$root" "$env" 2>/dev/null); then
    export MUSTER_FLAGS_FILE="$flags"
  fi
  # exec: signals go straight to the command and its exit code is ours
  exec "$@"
}
