#!/usr/bin/env bash
# muster/lib/commands/env_guard.sh — muster env guard: keep plaintext secrets
# out of git.
#
#   muster env guard install    add a pre-commit hook (keeps an existing one)
#   muster env guard check      scan tracked files (--staged: the index only)
#
# Blocks: .env files, muster secret keys (mstsec1/mstrec1), secrets files
# with a plaintext value, override files, schema-secret keys in plaintext
# config, and any file containing the value of a secret you can decrypt.

_ENV_GUARD_MARK="# muster-env-guard"

_env_cmd_guard() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  has_cmd jq || { err "muster env guard needs jq"; return 1; }
  local root
  root=$(_env_root)
  case "$sub" in
    install)
      _env_guard_install "$root" "$@" && ok "Pre-commit guard installed: commits with plaintext secrets are blocked"
      ;;
    uninstall)
      _env_guard_uninstall "$root"
      ;;
    check)
      local staged=false
      [[ "${1:-}" == "--staged" ]] && staged=true
      _env_guard_check "$root" "$staged"
      ;;
    *)
      printf 'Usage: muster env guard install|uninstall|check [--staged]\n'
      [[ -z "$sub" ]] && return 0
      return 1
      ;;
  esac
}

_env_guard_hooks_dir() {
  local root="$1" d
  d=$(git -C "$root" rev-parse --git-path hooks 2>/dev/null) || return 1
  [[ "$d" != /* ]] && d="$root/$d"
  printf '%s' "$d"
}

_env_guard_install() {
  local root="$1" dir hook prev
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { err "$root is not a git repository"; return 1; }
  dir=$(_env_guard_hooks_dir "$root") || return 1
  mkdir -p "$dir"
  hook="$dir/pre-commit"
  prev="$dir/pre-commit.muster-prev"
  if [[ -f "$hook" ]] && ! grep -qF "$_ENV_GUARD_MARK" "$hook"; then
    if [[ -e "$prev" ]]; then
      err "$hook exists and $prev too; merge them by hand"
      return 1
    fi
    mv "$hook" "$prev"
    info "Kept your existing pre-commit hook (it still runs after the guard)"
  fi
  cat >"$hook" <<EOF
#!/usr/bin/env bash
$_ENV_GUARD_MARK — installed by \`muster env guard install\`; remove with \`muster env guard uninstall\`.
# Blocks commits that would add plaintext secrets. Bypass once: git commit --no-verify
# Prefer the muster that installed this hook (it knows \`env guard\`), then PATH
muster_bin="$MUSTER_ROOT/bin/muster"
[ -x "\$muster_bin" ] || muster_bin="\$(command -v muster 2>/dev/null)"
if [ -n "\$muster_bin" ]; then
  MUSTER_NO_VERIFY=true "\$muster_bin" env guard check --staged || exit 1
else
  # muster not installed: basic checks only
  bad=0
  while IFS= read -r f; do
    case "\$(basename "\$f")" in
      .env.example|.env.sample|.env.template) ;;
      .env|.env.*) echo "muster env guard: \$f is a dotenv file; don't commit it" >&2; bad=1 ;;
    esac
    if git show ":\$f" 2>/dev/null | grep -Eq 'mst(sec|rec)1[0-9a-z]{20,}'; then
      echo "muster env guard: \$f contains a muster secret key" >&2; bad=1
    fi
  done <<LIST
\$(git diff --cached --name-only --diff-filter=ACMR)
LIST
  [ "\$bad" = 0 ] || exit 1
fi
hook_dir="\$(cd "\$(dirname "\$0")" && pwd)"
if [ -x "\$hook_dir/pre-commit.muster-prev" ]; then
  exec "\$hook_dir/pre-commit.muster-prev" "\$@"
fi
exit 0
EOF
  chmod 755 "$hook"
}

_env_guard_uninstall() {
  local root="$1" dir hook
  dir=$(_env_guard_hooks_dir "$root") || { err "Not a git repository"; return 1; }
  hook="$dir/pre-commit"
  if [[ -f "$hook" ]] && grep -qF "$_ENV_GUARD_MARK" "$hook"; then
    rm -f "$hook"
    [[ -f "$dir/pre-commit.muster-prev" ]] && mv "$dir/pre-commit.muster-prev" "$hook"
    ok "Removed the pre-commit guard"
  else
    info "The guard is not installed"
  fi
}

# Secret literals worth searching for: every env we can decrypt.
# Prints "ENV<TAB>KEY<TAB>base64(value)" lines (in memory only).
_env_guard_literals() {
  local root="$1" env vals
  _env_crypt_bin >/dev/null || return 0
  while IFS= read -r env; do
    [[ -z "$env" ]] && continue
    [[ -f "$(_env_file "$root" secrets "$env")" ]] || continue
    _env_decrypt "$root" "$env" 2>/dev/null || continue
    vals="$_ENV_DECRYPTED"
    _ENV_DECRYPTED=""
    printf '%s' "$vals" | jq -r --arg e "$env" '
      to_entries[] | select(.value | length >= 8) | select(.value | test("^[0-9.]+$") | not)
      | "\($e)\t\(.key)\t\(.value | @base64)"'
  done < <(_env_list_envs "$root")
  vals=""
}

_env_guard_check() {
  local root="$1" staged="$2" files f base content problems=0 secret_keys lits
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { err "Not a git repository"; return 1; }
  if [[ "$staged" == "true" ]]; then
    files=$(git -C "$root" diff --cached --name-only --diff-filter=ACMR)
  else
    files=$(git -C "$root" ls-files)
  fi
  [[ -z "$files" ]] && return 0
  secret_keys="[]"
  [[ -f "$(_env_schema_file "$root")" ]] &&
    secret_keys=$(jq -c '[(.keys // {}) | to_entries[] | select(.value.type == "secret" or .value.sensitive == true) | .key]' "$(_env_schema_file "$root")")
  lits=$(_env_guard_literals "$root")

  _guard_fail() {
    printf '  %b✗%b %s\n' "$RED" "$RESET" "$1" >&2
    problems=$((problems + 1))
  }
  _guard_read() {
    if [[ "$staged" == "true" ]]; then git -C "$root" show ":$1" 2>/dev/null; else cat "$root/$1" 2>/dev/null; fi
  }

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    base=$(basename "$f")
    case "$base" in
      .env.example | .env.sample | .env.template) ;;
      .env | .env.*) _guard_fail "$f: dotenv file (secrets live encrypted in .muster/env; muster run injects them)"; continue ;;
    esac
    case "$f" in
      .muster/env/local.override.json) _guard_fail "$f: personal overrides (gitignored by muster env init)"; continue ;;
      .muster/runtime/*) _guard_fail "$f: generated runtime file"; continue ;;
    esac
    # Skip big files
    local size
    if [[ "$staged" == "true" ]]; then
      size=$(git -C "$root" cat-file -s ":$f" 2>/dev/null || echo 0)
    else
      size=$(wc -c <"$root/$f" 2>/dev/null | tr -d ' ')
    fi
    [[ "${size:-0}" -gt 2097152 ]] && continue
    content=$(_guard_read "$f" | tr -d '\000')
    [[ -z "$content" ]] && continue

    if [[ "$content" =~ mst(sec|rec)1[0-9a-z]{20,} ]]; then
      _guard_fail "$f: contains a muster secret key (mstsec1/mstrec1)"
    fi
    case "$f" in
      .muster/env/*.secrets.json)
        if ! printf '%s' "$content" | jq -e '(.values // {}) | to_entries | all(.value | type == "string" and startswith("ENC[muster:v1,"))' >/dev/null 2>&1; then
          _guard_fail "$f: has a value that is not encrypted"
        fi
        ;;
      .muster/env/*.config.json)
        local leaked
        leaked=$(printf '%s' "$content" | jq -r --argjson s "$secret_keys" '(.values // {}) | keys[] | select(. as $k | $s | index($k))' 2>/dev/null)
        [[ -n "$leaked" ]] && _guard_fail "$f: secret key(s) in plaintext config: $(printf '%s' "$leaked" | tr '\n' ' ')"
        ;;
    esac
    # Values of secrets we can decrypt
    if [[ -n "$lits" ]]; then
      local e k b v
      while IFS=$'\t' read -r e k b; do
        [[ -z "$b" ]] && continue
        v=$(_env_b64d_guard "$b")
        if [[ -n "$v" && "$content" == *"$v"* ]]; then
          _guard_fail "$f: contains the value of secret $k ($e)"
        fi
      done < <(printf '%s\n' "$lits")
      v=""
    fi
  done <<<"$files"
  lits=""
  content=""
  unset -f _guard_fail _guard_read
  if ((problems > 0)); then
    printf '\n  muster env guard blocked this: %d problem(s). Fix them, or bypass once with git commit --no-verify\n' "$problems" >&2
    return 1
  fi
  [[ "$staged" == "true" ]] || ok "No plaintext secrets in tracked files"
  return 0
}

_env_b64d_guard() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
