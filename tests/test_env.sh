#!/usr/bin/env bash
# tests/test_env.sh — muster env / muster run / muster flag (docs/env.md)
#
# Crypto tests need muster-crypt: $MUSTER_CRYPT_BIN, muster-crypt on PATH, or
# a muster-fleet-cloud checkout next to this repo ($MUSTER_FLEET_CLOUD_DIR)
# plus Go to build it. Without it only config/flag tests run.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_PATH="$PATH"
export HOME="$TMP/home" MUSTER_NO_VERIFY=true NO_COLOR=1 MUSTER_APPROVE_HOOKS=1
unset MUSTER_ENV MUSTER_ENV_KEY MUSTER_FLAGS_FILE MUSTER_ENV_ROOT
mkdir -p "$HOME"
M="$MUSTER_ROOT/bin/muster"

# ── find or build muster-crypt ──
CRYPT=""
if [[ -n "${MUSTER_CRYPT_BIN:-}" && -x "$MUSTER_CRYPT_BIN" ]]; then
  CRYPT="$MUSTER_CRYPT_BIN"
elif command -v muster-crypt >/dev/null 2>&1; then
  CRYPT=$(command -v muster-crypt)
else
  for d in "${MUSTER_FLEET_CLOUD_DIR:-}" "$MUSTER_ROOT/../muster-fleet-cloud"; do
    if [[ -n "$d" && -d "$d/cmd/muster-crypt" ]] && command -v go >/dev/null 2>&1; then
      (cd "$d" && go build -o "$TMP/muster-crypt" ./cmd/muster-crypt) >/dev/null 2>&1 && CRYPT="$TMP/muster-crypt"
      break
    fi
  done
fi
# A path where muster-crypt can't be found, for the "not installed" tests
NOCRYPT_PATH="$TMP/nocrypt-bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$TMP/nocrypt-bin"
for t in jq git awk sed grep; do
  p=$(command -v "$t") && ln -sf "$p" "$TMP/nocrypt-bin/$t"
done

SECRET="S3cr3t-db-pass-$RANDOM-zq"
SECRET2="sk_live_$RANDOM$RANDOM-abcdefgh"

# ════════════════════════════════════════
echo "  Without muster-crypt: config and flags"
# ════════════════════════════════════════
mkdir -p "$TMP/plain" && cd "$TMP/plain" && git init -q
out=$(PATH="$NOCRYPT_PATH" MUSTER_CRYPT_BIN= "$M" env init --no-guard 2>&1) && rc=0 || rc=$?
_test_eq "init works without muster-crypt" "0" "$rc"
_test_contains "init explains how to install muster-crypt" "MUSTER_WITH_CRYPT=1" "$out"
_test_file_exists "schema created" "muster.env.schema.json"
PATH="$NOCRYPT_PATH" MUSTER_CRYPT_BIN= "$M" env set PORT=3000 LOG_LEVEL=info >/dev/null 2>&1
_test_eq "config stored typed" "3000" "$(jq '.values.PORT' .muster/env/local.config.json)"
_test_eq "schema learns number" "number" "$(jq -r '.keys.PORT.type' muster.env.schema.json)"
out=$(printf 'x' | PATH="$NOCRYPT_PATH" MUSTER_CRYPT_BIN= "$M" env set API_TOKEN 2>&1) && rc=0 || rc=$?
_test_eq "secret without muster-crypt fails" "1" "$rc"
_test_contains "and says how to install it" "muster-crypt is needed for secrets" "$out"
_test_eq "nothing stored in plaintext" "null" "$(jq '.values.API_TOKEN' .muster/env/local.config.json)"
_test_contains ".gitignore covers .env" ".env" "$(cat .gitignore)"
_test_contains ".gitignore covers overrides" ".muster/env/local.override.json" "$(cat .gitignore)"

if [[ -z "$CRYPT" ]]; then
  echo "  (muster-crypt not available: skipping secret tests; set MUSTER_CRYPT_BIN)"
  _test_summary
  exit $?
fi
export MUSTER_CRYPT_BIN="$CRYPT"

# ════════════════════════════════════════
echo ""
echo "  init --from .env"
# ════════════════════════════════════════
P="$TMP/app"
mkdir -p "$P" && cd "$P" && git init -q && git config user.email t@example.com && git config user.name tester
printf 'PORT=3000\nDATABASE_URL=postgres://app:%s@db:5432/app\nDEBUG=false\n' "$SECRET" >.env
out=$("$M" env init --from .env --no-guard 2>&1)
_test_contains "imports config and secrets" "2 config, 1 secret" "$out"
_test_file_exists "key created" "$HOME/.muster/env-keys/identity.key"
_test_eq "key file is 0600" "600" "$(stat -f '%Lp' "$HOME/.muster/env-keys/identity.key" 2>/dev/null || stat -c '%a' "$HOME/.muster/env-keys/identity.key")"
_test_eq "DATABASE_URL detected as secret" "secret" "$(jq -r '.keys.DATABASE_URL.type' muster.env.schema.json)"
_test_eq "secret not in config" "null" "$(jq '.values.DATABASE_URL' .muster/env/local.config.json)"
_test_contains "secret encrypted" "ENC[muster:v1," "$(jq -r '.values.DATABASE_URL' .muster/env/local.secrets.json)"
_test_eq "recipient recorded" "1" "$(jq '.recipients | length' .muster/env/recipients.json)"
rm -f .env

# ════════════════════════════════════════
echo ""
echo "  set / get / list"
# ════════════════════════════════════════
printf '%s' "$SECRET2" | "$M" env set STRIPE_KEY >/dev/null 2>&1
_test_eq "STRIPE_KEY stored as secret" "secret" "$(jq -r '.keys.STRIPE_KEY.type' muster.env.schema.json)"
out=$("$M" env get STRIPE_KEY 2>/dev/null)
_test_contains "get masks secrets" "‹secret:" "$out"
_test_not_contains "get does not print it" "$SECRET2" "$out"
_test_eq "get --reveal prints it" "$SECRET2" "$("$M" env get STRIPE_KEY --reveal)"
_test_eq "get config" "3000" "$("$M" env get PORT)"
out=$("$M" env list 2>&1)
_test_not_contains "list masks secrets" "$SECRET" "$out"
_test_contains "list shows config" "3000" "$out"
_test_eq "list --json masks values" "null" "$("$M" env list --json | jq '.keys[] | select(.key == "STRIPE_KEY") | .value')"
out=$("$M" env set PORT=abc 2>&1) && rc=0 || rc=$?
_test_eq "set validates against schema" "1" "$rc"
_test_contains "with a reason" "must be a number" "$out"
out=$("$M" env set PATH=/tmp 2>&1) && rc=0 || rc=$?
_test_eq "refuses PATH" "1" "$rc"
"$M" env set PORT=3000 >/dev/null 2>&1
_test_eq "same value is a no-op (no history entry)" "0" "$(grep -c '"key":"PORT","kind":"config","op":"update"' .muster/env/history.jsonl || true)"

# ════════════════════════════════════════
echo ""
echo "  muster run"
# ════════════════════════════════════════
out=$("$M" run -- sh -c 'printf "%s|%s|%s|%s" "$PORT" "$DATABASE_URL" "$STRIPE_KEY" "$MUSTER_ENV"')
_test_eq "run injects config + secrets" "3000|postgres://app:${SECRET}@db:5432/app|${SECRET2}|local" "$out"
out=$(PORT=9999 "$M" run -- sh -c 'printf "%s" "$PORT"')
_test_eq "existing env vars win" "9999" "$out"
out=$(PORT=9999 "$M" run --override -- sh -c 'printf "%s" "$PORT"')
_test_eq "--override lets muster win" "3000" "$out"
"$M" run -- sh -c 'exit 7' && rc=0 || rc=$?
_test_eq "exit code preserved" "7" "$rc"
_test_eq "args after -- untouched (-q, --verbose)" "-q --verbose" "$("$M" run -- echo -q --verbose)"
_test_eq "no .env written" "no" "$([[ -f .env ]] && echo yes || echo no)"

# ════════════════════════════════════════
echo ""
echo "  Secret values never land on disk"
# ════════════════════════════════════════
leaks=$(grep -rlF "$SECRET" "$P" "$HOME" 2>/dev/null || true)
_test_eq "no file contains secret 1" "" "$leaks"
leaks=$(grep -rlF "$SECRET2" "$P" "$HOME" 2>/dev/null || true)
_test_eq "no file contains secret 2" "" "$leaks"
_test_not_contains "history has fingerprints, not values" "$SECRET2" "$(cat .muster/env/history.jsonl)"
_test_contains "history records the secret change" '"kind":"secret"' "$(cat .muster/env/history.jsonl)"

# ════════════════════════════════════════
echo ""
echo "  diff / history"
# ════════════════════════════════════════
"$M" env set PORT=8080 --env production >/dev/null 2>&1
printf 'postgres://prod:other@db/x' | "$M" env set DATABASE_URL --env production >/dev/null 2>&1
d=$("$M" env diff local production --json)
_test_eq "diff: changed config" "changed" "$(printf '%s' "$d" | jq -r '.keys[] | select(.key == "PORT") | .status')"
_test_eq "diff: secret differs, value hidden" "changed|null" "$(printf '%s' "$d" | jq -r '.keys[] | select(.key == "DATABASE_URL") | "\(.status)|\(.a)"')"
_test_eq "diff: removed" "removed" "$(printf '%s' "$d" | jq -r '.keys[] | select(.key == "STRIPE_KEY") | .status')"
_test_not_contains "diff never prints secrets" "$SECRET" "$("$M" env diff local production 2>&1)"
h=$("$M" env history PORT --json)
_test_eq "history filters by key" "true" "$(printf '%s' "$h" | jq 'length > 0 and all(.[].changes[]?; .key == "PORT")')"
_test_eq "history has config before/after" "8080" "$(printf '%s' "$h" | jq -r '[.[] | select(.env == "production")][-1].changes[0].after')"

# ════════════════════════════════════════
echo ""
echo "  check (CI gate)"
# ════════════════════════════════════════
_test_eq "local passes" "0" "$("$M" env check >/dev/null 2>&1 && echo 0 || echo 1)"
jq '.keys.SENTRY_DSN = {type: "secret", required: ["production"]} | .keys.PORT += {min: 1, max: 65535}' muster.env.schema.json >s.tmp && mv s.tmp muster.env.schema.json
j=$("$M" env check --env production --json) && rc=0 || rc=$?
_test_eq "missing required key fails" "1" "$rc"
_test_eq "reports it" "missing:SENTRY_DSN" "$(printf '%s' "$j" | jq -r '.errors[] | "\(.code):\(.key)"')"
_test_eq "decrypted + MAC verified" "true" "$(printf '%s' "$j" | jq '.decrypted')"
_test_eq "local still passes (required only in production)" "0" "$("$M" env check >/dev/null 2>&1 && echo 0 || echo 1)"
jq '.values.EXTRA = "x"' .muster/env/local.config.json >c.tmp && mv c.tmp .muster/env/local.config.json
_test_eq "--strict flags undeclared keys" "undeclared:EXTRA" "$("$M" env check --strict --json | jq -r '.errors[] | "\(.code):\(.key)"')"
jq 'del(.values.EXTRA) | .values.STRIPE_KEY = "plain"' .muster/env/local.config.json >c.tmp && mv c.tmp .muster/env/local.config.json
_test_contains "secret in plaintext config is an error" "plaintext_secret" "$("$M" env check --json | jq -r '.errors[].code')"
jq 'del(.values.STRIPE_KEY)' .muster/env/local.config.json >c.tmp && mv c.tmp .muster/env/local.config.json
cp .muster/env/local.secrets.json "$TMP/secrets.bak"
jq '.values.STRIPE_KEY = .values.DATABASE_URL' .muster/env/local.secrets.json >c.tmp && mv c.tmp .muster/env/local.secrets.json
j=$("$M" env check --json) && rc=0 || rc=$?
_test_eq "tampered secrets file fails" "1:integrity" "$rc:$(printf '%s' "$j" | jq -r '.errors[0].code')"
cp "$TMP/secrets.bak" .muster/env/local.secrets.json
j=$(HOME="$TMP/stranger" "$M" env check --json) && rc=0 || rc=$?
_test_eq "no key: still checks presence, warns" "0:no_key" "$rc:$(printf '%s' "$j" | jq -r '.warnings[0].code')"
j=$(HOME="$TMP/stranger" "$M" env check --env production --json) && rc=0 || rc=$?
_test_eq "no key: missing required still fails" "1" "$rc"

# ════════════════════════════════════════
echo ""
echo "  CI key, recipients, rotation"
# ════════════════════════════════════════
out=$("$M" env keygen --ci gha --envs production 2>&1)
CIKEY=$(printf '%s' "$out" | grep -Eo 'mstsec1[0-9a-z]+' | head -1)
_test_contains "CI key printed once" "mstsec1" "$CIKEY"
_test_eq "CI recipient scoped to production" '["production"]' "$(jq -c '.recipients[] | select(.id == "ci:gha") | .envs' .muster/env/recipients.json)"
out=$(HOME="$TMP/ci" MUSTER_ENV_KEY="$CIKEY" "$M" run --env production -- sh -c 'printf "%s" "$DATABASE_URL"')
_test_eq "CI decrypts production via MUSTER_ENV_KEY" "postgres://prod:other@db/x" "$out"
HOME="$TMP/ci" MUSTER_ENV_KEY="$CIKEY" "$M" run --env local -- true >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "CI cannot decrypt local" "1" "$rc"
CT_BEFORE=$(jq -r '.values.DATABASE_URL' .muster/env/production.secrets.json)
out=$("$M" env recipient remove ci:gha 2>&1)
_test_contains "removal rotates the data key" "new data key" "$out"
_test_contains "and lists secrets to rotate" "DATABASE_URL" "$out"
_test_eq "values re-encrypted" "no" "$([[ "$(jq -r '.values.DATABASE_URL' .muster/env/production.secrets.json)" == "$CT_BEFORE" ]] && echo yes || echo no)"
HOME="$TMP/ci" MUSTER_ENV_KEY="$CIKEY" "$M" run --env production -- true >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "removed CI key can't decrypt" "1" "$rc"
_test_eq "owner still can" "postgres://prod:other@db/x" "$("$M" env get DATABASE_URL --env production --reveal)"

# ════════════════════════════════════════
echo ""
echo "  pull / example / edit"
# ════════════════════════════════════════
"$M" env pull >/dev/null 2>&1
_test_eq "pull writes .env 0600" "600" "$(stat -f '%Lp' .env 2>/dev/null || stat -c '%a' .env)"
_test_contains "pull has secrets" "$SECRET2" "$(cat .env)"
rm -f .env
"$M" env pull --to notignored.env >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "pull refuses a non-gitignored path" "1" "$rc"
"$M" env example >/dev/null
_test_contains "example lists keys" "DATABASE_URL=" "$(cat .env.example)"
_test_contains "example marks secrets" "# secret" "$(cat .env.example)"
_test_not_contains "example has no secret values" "$SECRET" "$(cat .env.example)"
cat >"$TMP/editor.sh" <<'EOF'
#!/usr/bin/env bash
cp "$1" "$(dirname "$0")/edit-copy.txt"
stat -f '%Lp' "$1" >"$(dirname "$0")/edit-mode.txt" 2>/dev/null || stat -c '%a' "$1" >"$(dirname "$0")/edit-mode.txt"
sed -e 's/^PORT=.*/PORT=4000/' -e '/^DEBUG=/d' "$1" >"$1.new" && mv "$1.new" "$1"
printf 'EDIT_TOKEN=tok-from-editor-123\n' >>"$1"
EOF
chmod +x "$TMP/editor.sh"
EDITOR="$TMP/editor.sh" "$M" env edit </dev/null >/dev/null 2>&1
_test_eq "edit: temp file was 0600" "600" "$(cat "$TMP/edit-mode.txt")"
_test_eq "edit: config changed" "4000" "$("$M" env get PORT)"
_test_eq "edit: deleted line unsets" "null" "$(jq '.values.DEBUG' .muster/env/local.config.json)"
_test_eq "edit: new key under secrets is encrypted" "tok-from-editor-123" "$("$M" env get EDIT_TOKEN --reveal)"
_test_eq "edit: temp dir wiped" "" "$(ls -d "${TMPDIR:-/tmp}"/muster-env.* 2>/dev/null || true)"
rm -f "$TMP/edit-copy.txt"

# ════════════════════════════════════════
echo ""
echo "  Flags"
# ════════════════════════════════════════
"$M" flag set new_checkout on >/dev/null 2>&1
"$M" flag set ranking hybrid-v2 >/dev/null 2>&1
F=.muster/env/local.flags.json
_test_eq "flagd \$schema" "https://flagd.dev/schema/v0/flags.json" "$(jq -r '."$schema"' "$F")"
_test_eq "bool flag shape" '{"state":"ENABLED","variants":{"on":true,"off":false},"defaultVariant":"on"}' "$(jq -c '.flags.new_checkout' "$F")"
_test_eq "every defaultVariant is a variant" "true" "$(jq '[.flags[] | . as $f | $f.variants | has($f.defaultVariant)] | all' "$F")"
_test_eq "string flag value" "hybrid-v2" "$("$M" flag get ranking)"
_test_eq "flag declared in schema" "bool" "$(jq -r '.flags.new_checkout.value_type' muster.env.schema.json)"
_test_eq "projected as MUSTER_FLAG_*" "true|hybrid-v2" "$("$M" run -- sh -c 'printf "%s|%s" "$MUSTER_FLAG_NEW_CHECKOUT" "$MUSTER_FLAG_RANKING"')"
FF=$("$M" run -- sh -c 'printf "%s" "$MUSTER_FLAGS_FILE"')
_test_eq "MUSTER_FLAGS_FILE is flagd JSON" "on" "$(jq -r '.flags.new_checkout.defaultVariant' "$FF")"
"$M" flag toggle new_checkout >/dev/null 2>&1
_test_eq "toggle" "false" "$("$M" flag get new_checkout)"
"$M" flag set new_checkout on --local >/dev/null 2>&1
_test_eq "--local override wins locally" "true" "$("$M" flag get new_checkout)"
_test_eq "--local doesn't touch the committed file" "off" "$(jq -r '.flags.new_checkout.defaultVariant' "$F")"
_test_eq "running app's flags file updated" "on" "$(jq -r '.flags.new_checkout.defaultVariant' "$FF")"
"$M" flag reset --local >/dev/null 2>&1
_test_eq "reset --local" "false" "$("$M" flag get new_checkout)"
_test_eq "flag list --json" "2" "$("$M" flag list --json | jq '.flags | length')"
_test_contains "flag changes in history" "flag_set" "$(cat .muster/env/history.jsonl)"

# ════════════════════════════════════════
echo ""
echo "  Codegen"
# ════════════════════════════════════════
jq '.keys.LOG_LEVEL = {type: "string", enum: ["debug", "info"], default: "info", description: "Log verbosity"}' muster.env.schema.json >s.tmp && mv s.tmp muster.env.schema.json
"$M" env codegen ts >/dev/null 2>&1
"$M" env codegen py >/dev/null 2>&1
"$M" env codegen go >/dev/null 2>&1
_test_file_exists "ts generated" "env.generated.ts"
_test_file_exists "py generated" "muster_env.py"
_test_file_exists "go generated" "config/env_gen.go"
_test_contains "ts wraps secrets" "readonly DATABASE_URL?: Secret;" "$(cat env.generated.ts)"
_test_contains "py wraps secrets" "DATABASE_URL: Optional[SecretStr]" "$(cat muster_env.py)"
_test_contains "go wraps secrets" "DatabaseURL Secret" "$(cat config/env_gen.go)"
_test_contains "ts has flags" "readonly newCheckout: boolean;" "$(cat env.generated.ts)"
_test_eq "codegen --check passes when fresh" "0" "$("$M" env codegen all --check >/dev/null 2>&1 && echo 0 || echo 1)"
_test_not_contains "generated code has no secret values" "$SECRET" "$(cat env.generated.ts muster_env.py config/env_gen.go)"

if command -v node >/dev/null 2>&1 && node --experimental-strip-types --no-warnings -e '' 2>/dev/null; then
  cat >t.ts <<'EOF'
import { env, loadEnv } from "./env.generated.ts";
const p = (() => { try { loadEnv({ MUSTER_ENV: "production", PORT: "x" }); return []; } catch (e: any) { return e.problems; } })();
console.log([env.PORT, env.LOG_LEVEL, String(env.STRIPE_KEY), JSON.stringify({ s: env.STRIPE_KEY }), env.STRIPE_KEY!.reveal().length > 0, env.flags.newCheckout, p.join(";")].join("|"));
EOF
  out=$("$M" run -- node --experimental-strip-types --no-warnings t.ts 2>&1)
  _test_eq "ts runs: types, redaction, all problems at once" \
    "4000|info|[REDACTED]|{\"s\":\"[REDACTED]\"}|true|false|PORT must be a number;SENTRY_DSN is required in production" "$out"
else
  _test_contains "ts structural: loadEnv exported" "export function loadEnv" "$(cat env.generated.ts)"
fi
if command -v python3 >/dev/null 2>&1; then
  _test_eq "py compiles" "0" "$(python3 -m py_compile muster_env.py && echo 0 || echo 1)"
  out=$("$M" run -- python3 -c 'from muster_env import load_env; e = load_env(); print(e.PORT, repr(e.STRIPE_KEY), e.STRIPE_KEY.get_secret_value() != "", e.flags.new_checkout)')
  _test_eq "py runs with redaction" "4000 SecretStr('**********') True False" "$out"
else
  _test_contains "py structural" "def load_env" "$(cat muster_env.py)"
fi
if command -v go >/dev/null 2>&1; then
  _test_eq "go is gofmt-clean" "" "$(gofmt -l config/env_gen.go)"
  mkdir -p "$TMP/gomod/config"
  cp config/env_gen.go "$TMP/gomod/config/"
  printf 'module example.com/t\n\ngo 1.21\n' >"$TMP/gomod/go.mod"
  cat >"$TMP/gomod/main.go" <<'EOF'
package main

import (
	"encoding/json"
	"fmt"

	"example.com/t/config"
)

func main() {
	c, err := config.Load()
	if err != nil {
		fmt.Println(err)
		return
	}
	b, _ := json.Marshal(c.StripeKey)
	fmt.Printf("%d %v %s %v\n", c.Port, c.StripeKey, b, c.Flags.NewCheckout)
}
EOF
  out=$(MUSTER_ENV_ROOT="$P" GOCACHE="$TMP/gocache" "$M" run -- sh -c "cd '$TMP/gomod' && go run ." 2>&1)
  _test_eq "go builds and redacts" '4000 [REDACTED] "[REDACTED]" false' "$out"
else
  _test_contains "go structural" "func Load() (Config, error)" "$(cat config/env_gen.go)"
fi
rm -f t.ts
rm -rf __pycache__

# ════════════════════════════════════════
echo ""
echo "  Pre-commit guard"
# ════════════════════════════════════════
"$M" env guard install >/dev/null 2>&1
_test_contains "hook installed" "muster-env-guard" "$(cat .git/hooks/pre-commit)"
git add -A >/dev/null 2>&1
git commit -qm "muster env" >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "clean commit allowed" "0" "$rc"
printf 'const db = "%s";\n' "$SECRET2" >leak.js
git add leak.js
out=$(git commit -qm leak 2>&1) && rc=0 || rc=$?
_test_eq "commit with a secret value blocked" "1" "$rc"
_test_contains "names the secret, not the value" "contains the value of secret STRIPE_KEY" "$out"
_test_not_contains "doesn't print the value" "$SECRET2" "$out"
git reset -q leak.js && rm -f leak.js
printf 'X=1\n' >.env.production
git add -f .env.production
git commit -qm env >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "dotenv file blocked" "1" "$rc"
git reset -q .env.production && rm -f .env.production
printf 'key: %s\n' "$CIKEY" >notes.txt
git add notes.txt
git commit -qm key >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "muster secret key blocked" "1" "$rc"
git reset -q notes.txt && rm -f notes.txt
jq '.values.STRIPE_KEY = "plaintext"' .muster/env/local.secrets.json >c.tmp && cp c.tmp .muster/env/local.secrets.json && rm -f c.tmp
git add .muster/env/local.secrets.json
git commit -qm plain >/dev/null 2>&1 && rc=0 || rc=$?
_test_eq "unencrypted secrets file blocked" "1" "$rc"
git checkout -q -- .muster/env/local.secrets.json 2>/dev/null || git reset -q --hard

# ════════════════════════════════════════
echo ""
echo "  Deploy hooks get the env (in memory) and logs stay clean"
# ════════════════════════════════════════
D="$TMP/deploy"
mkdir -p "$D" && cd "$D"
"$M" setup --services api --stack bare --health api=none --name envdeploy --force >/dev/null 2>&1
mkdir -p .muster/hooks/api
cat >.muster/hooks/api/deploy.sh <<'EOF'
#!/usr/bin/env bash
echo "deploying on port $PORT with $API_SECRET (env $MUSTER_ENV)"
printf '%s' "$API_SECRET" | shasum -a 256 | cut -c1-16 > "$HOOK_OUT"
echo "PATH-ok=$([[ "$PATH" != /evil* ]] && echo yes || echo no)"
echo "deployed"
EOF
chmod +x .muster/hooks/api/deploy.sh
"$M" env init --no-guard >/dev/null 2>&1
"$M" env set PORT=7070 >/dev/null 2>&1
DSECRET="deploy-secret-$RANDOM-xyz"
printf '%s' "$DSECRET" | "$M" env set API_SECRET --secret >/dev/null 2>&1
jq '.values.PATH = "/evil/bin"' .muster/env/local.config.json >c.tmp && mv c.tmp .muster/env/local.config.json
T=$("$M" auth create t --scope admin 2>/dev/null | awk '/Token:/{print $2}')
export HOOK_OUT="$TMP/hook-out.txt"
out=$(MUSTER_TOKEN="$T" "$M" deploy --json --no-preflight 2>"$TMP/deploy-err.txt") || true
want=$(printf '%s' "$DSECRET" | shasum -a 256 | cut -c1-16)
_test_eq "hook saw the decrypted secret" "$want" "$(cat "$HOOK_OUT" 2>/dev/null)"
_test_contains "hook saw config" "port 7070" "$out"
_test_contains "blocked names are not injected" "PATH-ok=yes" "$out"
_test_not_contains "NDJSON output has no secret value" "$DSECRET" "$out"
_test_contains "it is masked" "‹redacted›" "$out"
logs=$(cat .muster/logs/*.log 2>/dev/null)
_test_contains "deploy log written" "deploying on port 7070" "$logs"
_test_not_contains "deploy log has no secret value" "$DSECRET" "$logs"
_test_eq "no .env written by deploy" "no" "$([[ -f .env ]] && echo yes || echo no)"
_test_eq "nothing on disk holds the secret" "" "$(grep -rlF "$DSECRET" "$D" "$HOME" 2>/dev/null || true)"

# ════════════════════════════════════════
echo ""
echo "  Redaction knows the loaded secrets"
# ════════════════════════════════════════
(
  cd "$D"
  GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT=""
  MUSTER_QUIET=true MUSTER_VERBOSE=false
  source "$MUSTER_ROOT/lib/core/logger.sh"
  source "$MUSTER_ROOT/lib/core/utils.sh"
  source "$MUSTER_ROOT/lib/core/redact.sh"
  source "$MUSTER_ROOT/lib/core/env_store.sh"
  _env_resolve "$D" local required
  r=$(printf 'app crashed: token %s in request\nkey mstsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqq\n' "$DSECRET" | redact_text)
  [[ "$r" != *"$DSECRET"* && "$r" == *"‹redacted›"* && "$r" != *"mstsec1qqqq"* ]] && echo PASS || echo "FAIL: $r"
) >"$TMP/redact.out" 2>&1
_test_eq "redact_text masks store secrets and muster keys" "PASS" "$(tail -1 "$TMP/redact.out")"

cd "$TMP"
_test_summary
