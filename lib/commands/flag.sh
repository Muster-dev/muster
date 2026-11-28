#!/usr/bin/env bash
# muster/lib/commands/flag.sh — muster flag: simple feature flags (Phase 1)
#
# Flags live in .muster/env/<env>.flags.json in flagd's format, so any
# OpenFeature flagd provider can read them. Apps without an SDK read the
# projected env var MUSTER_FLAG_<NAME> (set by muster run / deploy hooks).
# --local writes .muster/env/local.override.json (gitignored).

source "$MUSTER_ROOT/lib/core/env_store.sh"

_flag_usage() {
  cat <<'EOF'
Usage: muster flag <command> [options]

  list [--env E] [--json]                  flags, values and env var names
  get NAME [--env E] [--json]              current value
  set NAME VALUE [--env E] [--local] [--type bool|string|number|json] [-m MSG]
  toggle NAME [--env E] [--local]          flip a bool flag
  unset NAME [--env E]                     remove a flag from an env
  reset [NAME] --local                     drop your local overrides

VALUE: on/off/true/false for bool flags, a variant name, or any value.
Flags reach your app as MUSTER_FLAG_<NAME> and via MUSTER_FLAGS_FILE (flagd JSON).
EOF
}

cmd_flag() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    list | ls) _flag_cmd_list "$@" ;;
    get) _flag_cmd_get "$@" ;;
    set) _flag_cmd_set "$@" ;;
    toggle) _flag_cmd_toggle "$@" ;;
    unset | rm) _flag_cmd_unset "$@" ;;
    reset) _flag_cmd_reset "$@" ;;
    "" | help | --help | -h) _flag_usage ;;
    *)
      err "Unknown flag command: $sub"
      printf '  Run: muster flag help\n'
      return 1
      ;;
  esac
}

_FLAG_ROOT=""
_flag_root() {
  has_cmd jq || { err "muster flag needs jq"; return 1; }
  _FLAG_ROOT=$(_env_root)
  if ! _env_store_present "$_FLAG_ROOT"; then
    err "muster env is not set up in $_FLAG_ROOT (muster env init)"
    return 1
  fi
}

_flag_valid_name() { [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,63}$ ]]; }

# Merged flags with each flag's value, env var and where it came from.
_flag_table() {
  local root="$1" env="$2" schema="null" merged own override="null"
  [[ -f "$(_env_schema_file "$root")" ]] && schema=$(cat "$(_env_schema_file "$root")")
  merged=$(_env_flags_merged "$root" "$env")
  own=$(_env_cat_or "$(_env_file "$root" flags "$env")" 'null')
  [[ "$env" == "local" ]] && override=$(_env_cat_or "$(_env_override_file "$root")" 'null')
  printf '{"m":%s,"s":%s,"own":%s,"o":%s}' "$merged" "$schema" "$own" "$override" | jq -c '
    (.s.flags // {}) as $sf | (.o.flags // {}) as $o | (.own.flags // {}) as $own
    | [.m.flags | to_entries[] | .key as $n | .value as $f
       | {name: $n, state: ($f.state // "ENABLED"), variant: $f.defaultVariant,
          value: $f.variants[$f.defaultVariant], variants: $f.variants,
          type: ($sf[$n].value_type // ($f.variants[$f.defaultVariant] | if type == "boolean" then "bool" elif type == "number" then "number" elif type == "string" then "string" else "json" end)),
          env_var: ($sf[$n].env_var // ("MUSTER_FLAG_" + ($n | ascii_upcase | gsub("[^A-Z0-9]"; "_")))),
          source: (if $o[$n] then "local override" elif $own[$n] then "env" else "base" end),
          description: ($sf[$n].description // null)}]
    | sort_by(.name)'
}

_flag_cmd_list() {
  local env="" json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --json) json=true; shift ;;
      *) err "Unknown option: $1"; return 1 ;;
    esac
  done
  _flag_root || return 1
  [[ -z "$env" ]] && env=$(_env_default_name "$_FLAG_ROOT")
  _env_valid_envname "$env" || { err "Invalid environment name: $env"; return 1; }
  local t
  t=$(_flag_table "$_FLAG_ROOT" "$env")
  if [[ "$json" == "true" ]]; then
    printf '%s' "$t" | jq -c --arg e "$env" '{env: $e, flags: .}'
    return 0
  fi
  printf '\n  %bflags%b — %s\n\n' "$BOLD" "$RESET" "$env"
  if [[ "$(printf '%s' "$t" | jq length)" == "0" ]]; then
    printf '  (none — muster flag set NAME on)\n\n'
    return 0
  fi
  printf '%s' "$t" | jq -r '.[] | [.name, (if .state == "DISABLED" then "disabled" else (.value | if type == "string" then . else tojson end) end), .env_var, .source] | @tsv' |
    while IFS=$'\t' read -r n v e s; do
      printf '  %-28s %-14s %b%-32s %s%b\n' "$n" "$v" "$DIM" "$e" "$s" "$RESET"
    done
  printf '\n'
}

_flag_cmd_get() {
  local env="" name="" json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --json) json=true; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) name="$1"; shift ;;
    esac
  done
  [[ -z "$name" ]] && { err "Usage: muster flag get NAME [--env E]"; return 1; }
  _flag_root || return 1
  [[ -z "$env" ]] && env=$(_env_default_name "$_FLAG_ROOT")
  _env_valid_envname "$env" || { err "Invalid environment name: $env"; return 1; }
  local row
  row=$(_flag_table "$_FLAG_ROOT" "$env" | jq -c --arg n "$name" '.[] | select(.name == $n)')
  [[ -z "$row" ]] && { err "No flag $name in $env"; return 1; }
  if [[ "$json" == "true" ]]; then
    printf '%s\n' "$row"
  else
    printf '%s' "$row" | jq -r '.value | if type == "string" then . else tojson end'
  fi
}

# Work out {variant, value, variants} for setting a flag to raw input.
# _flag_resolve_value current_flag_json raw type → JSON
_flag_resolve_value() {
  local cur="$1" raw="$2" type="$3"
  printf '%s' "$raw" | jq -Rsc --argjson cur "$cur" --arg t "$type" '
    . as $raw
    | ($cur.variants // {}) as $vs
    | def booly: if test("^(on|true|yes|1|enable|enabled)$"; "i") then true
                 elif test("^(off|false|no|0|disable|disabled)$"; "i") then false else null end;
    if $t == "bool" or ($t == "" and ($raw | booly) != null and (($vs | length) == 0 or ($vs | to_entries | all(.value | type == "boolean")))) then
      ($raw | booly) as $b
      | if $b == null then error("not a boolean: use on/off")
        else {variant: (if $b then "on" else "off" end), value: $b, variants: ({on: true, off: false} + $vs)} end
    elif $vs | has($raw) then {variant: $raw, value: $vs[$raw], variants: $vs}
    elif ([$vs | to_entries[] | select((.value | tostring) == $raw)] | length) > 0 then
      ([$vs | to_entries[] | select((.value | tostring) == $raw)][0]) as $e | {variant: $e.key, value: $e.value, variants: $vs}
    else
      (if $t == "number" or ($t == "" and ($raw | test("^-?[0-9]+(\\.[0-9]+)?$"))) then ($raw | tonumber)
       elif $t == "json" then ($raw | fromjson)
       else $raw end) as $v
      | {variant: ($raw | gsub("[^A-Za-z0-9_.-]"; "_") | .[0:40]), value: $v, variants: ($vs + {($raw | gsub("[^A-Za-z0-9_.-]"; "_") | .[0:40]): $v})}
    end' 2>&1
}

_flag_cmd_set() {
  local env="" local_only=false type="" msg="" name="" value="" have_value=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --local) local_only=true; shift ;;
      --type) type="${2:-}"; shift 2 ;;
      --type=*) type="${1#*=}"; shift ;;
      -m | --message) msg="${2:-}"; shift 2 ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *)
        if [[ -z "$name" ]]; then name="$1"; else value="$1"; have_value=true; fi
        shift
        ;;
    esac
  done
  [[ -z "$name" || "$have_value" == "false" ]] && { err "Usage: muster flag set NAME VALUE [--env E] [--local]"; return 1; }
  _flag_valid_name "$name" || { err "Invalid flag name: $name (letters, digits, _ . -)"; return 1; }
  case "$type" in "" | bool | string | number | json) ;; *) err "--type must be bool, string, number or json"; return 1 ;; esac
  _flag_root || return 1
  local root="$_FLAG_ROOT"
  [[ -z "$env" ]] && env=$(_env_default_name "$root")
  [[ "$local_only" == "true" ]] && env="local"
  _env_valid_envname "$env" || { err "Invalid environment name: $env"; return 1; }
  [[ -z "$type" ]] && type=$(jq -r --arg n "$name" '.flags[$n].value_type // empty' "$(_env_schema_file "$root")" 2>/dev/null)

  local file cur res before
  file=$(_env_file "$root" flags "$env")
  cur=$(_env_flags_merged "$root" "$env" | jq -c --arg n "$name" '.flags[$n] // {}')
  res=$(_flag_resolve_value "$cur" "$value" "$type") || { err "$name: $(printf '%s' "$res" | sed 's/^jq: error[^:]*: //')"; return 1; }
  before=$(printf '%s' "$cur" | jq -c 'if .defaultVariant then .variants[.defaultVariant] else null end')

  if [[ "$local_only" == "true" ]]; then
    _env_jq_update "$(_env_override_file "$root")" '{"flags":{},"values":{}}' \
      '.flags[$n] = {variant: $r.variant, value: $r.value}' --arg n "$name" --argjson r "$res" || return 1
    ok "$name = $(printf '%s' "$res" | jq -c .value) (local override, not committed)"
  else
    _env_jq_update "$file" "$(_env_flags_default "$env")" '
      .flags[$n] = ((.flags[$n] // {state: "ENABLED"}) + {state: "ENABLED", variants: $r.variants, defaultVariant: $r.variant})
      | .flags |= (to_entries | sort_by(.key) | from_entries)
      | .metadata = ((.metadata // {}) + {muster_env: $e, revision: ((.metadata.revision // 0) + 1), updated_at: $t, updated_by: $a})' \
      --arg n "$name" --argjson r "$res" --arg e "$env" --arg t "$(_env_now)" --arg a "$(_env_actor)" || return 1
    # Declare it in the schema
    if [[ -f "$(_env_schema_file "$root")" ]] && ! jq -e --arg n "$name" '.flags[$n]' "$(_env_schema_file "$root")" >/dev/null 2>&1; then
      local vt
      vt=$(printf '%s' "$res" | jq -r '.value | if type == "boolean" then "bool" elif type == "number" then "number" elif type == "string" then "string" else "json" end')
      _env_jq_update "$(_env_schema_file "$root")" "$(_env_schema_default)" \
        '.flags[$n] = {type: "flag", value_type: $vt} | .flags |= (to_entries | sort_by(.key) | from_entries)' --arg n "$name" --arg vt "$vt"
    fi
    jq -nc --arg e "$env" --arg n "$name" --argjson b "$before" --argjson r "$res" --arg m "$msg" \
      '{action: "flag_set", env: $e, message: (if $m == "" then null else $m end), changes: [{key: $n, kind: "flag", op: "update", before: $b, after: $r.value}]} | if .message == null then del(.message) else . end' |
      _env_history_append "$root"
    ok "$name = $(printf '%s' "$res" | jq -c .value) in $env"
  fi
  # Keep a running `muster run` in sync (it watches MUSTER_FLAGS_FILE)
  [[ -f "$root/.muster/runtime/flags.${env}.json" ]] && _env_write_runtime_flags "$root" "$env" >/dev/null
  return 0
}

_flag_cmd_toggle() {
  local env="" local_only=false name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      --local) local_only=true; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) name="$1"; shift ;;
    esac
  done
  [[ -z "$name" ]] && { err "Usage: muster flag toggle NAME [--env E] [--local]"; return 1; }
  _flag_root || return 1
  [[ -z "$env" ]] && env=$(_env_default_name "$_FLAG_ROOT")
  [[ "$local_only" == "true" ]] && env="local"
  local cur
  cur=$(_env_flags_merged "$_FLAG_ROOT" "$env" | jq -r --arg n "$name" '.flags[$n] | if . == null then "missing" else (.variants[.defaultVariant] | tostring) end')
  case "$cur" in
    true) set -- "$name" off ;;
    false | missing) set -- "$name" on ;;
    *) err "$name is not a bool flag (value: $cur)"; return 1 ;;
  esac
  if [[ "$local_only" == "true" ]]; then
    _flag_cmd_set "$@" --local
  else
    _flag_cmd_set "$@" --env "$env" --type bool
  fi
}

_flag_cmd_unset() {
  local env="" name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env | -e) env="${2:-}"; shift 2 ;;
      --env=*) env="${1#*=}"; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) name="$1"; shift ;;
    esac
  done
  [[ -z "$name" ]] && { err "Usage: muster flag unset NAME [--env E]"; return 1; }
  _flag_root || return 1
  [[ -z "$env" ]] && env=$(_env_default_name "$_FLAG_ROOT")
  local file
  file=$(_env_file "$_FLAG_ROOT" flags "$env")
  if [[ ! -f "$file" ]] || ! jq -e --arg n "$name" '.flags | has($n)' "$file" >/dev/null; then
    err "No flag $name in $env"
    return 1
  fi
  _env_jq_update "$file" '{}' 'del(.flags[$n]) | .metadata.revision = ((.metadata.revision // 0) + 1)' --arg n "$name" || return 1
  jq -nc --arg e "$env" --arg n "$name" '{action: "flag_unset", env: $e, changes: [{key: $n, kind: "flag", op: "remove"}]}' | _env_history_append "$_FLAG_ROOT"
  ok "Removed flag $name from $env"
}

_flag_cmd_reset() {
  local name="" local_only=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local) local_only=true; shift ;;
      -*) err "Unknown option: $1"; return 1 ;;
      *) name="$1"; shift ;;
    esac
  done
  [[ "$local_only" == "true" ]] || { err "Only local overrides can be reset: muster flag reset [NAME] --local"; return 1; }
  _flag_root || return 1
  local f
  f=$(_env_override_file "$_FLAG_ROOT")
  [[ -f "$f" ]] || { info "No local overrides"; return 0; }
  if [[ -n "$name" ]]; then
    _env_jq_update "$f" '{}' 'del(.flags[$n])' --arg n "$name"
    ok "Dropped local override for $name"
  else
    _env_jq_update "$f" '{}' '.flags = {}'
    ok "Dropped all local flag overrides"
  fi
  [[ -f "$_FLAG_ROOT/.muster/runtime/flags.local.json" ]] && _env_write_runtime_flags "$_FLAG_ROOT" local >/dev/null
  return 0
}
