#!/usr/bin/env bash
# tests/test_redact.sh — lib/core/redact.sh: realistic leaks get masked,
# ordinary log lines are left alone
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
command -v jq >/dev/null 2>&1 || { echo "  (skipped: needs jq)"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

source "$MUSTER_ROOT/lib/core/redact.sh"
R='‹redacted›'

# _leak "desc" input secret: the secret must be gone and the mark present
_leak() {
  local desc="$1" input="$2" secret="$3" out
  out=$(printf '%s\n' "$input" | redact_text)
  TOTAL=$((TOTAL + 1))
  if [[ "$out" != *"$secret"* && "$out" == *"$R"* ]]; then
    PASS=$((PASS + 1))
    printf '  \033[38;5;114m✓\033[0m %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[38;5;203m✗\033[0m %s (got: %s)\n' "$desc" "$out"
  fi
}

# _clean "desc" input: output must be identical
_clean() {
  local out
  out=$(printf '%s\n' "$2" | redact_text)
  _test_eq "$1" "$2" "$out"
}

echo "  Secrets are masked"
_leak "AWS access key id" "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE" "AKIAIOSFODNN7EXAMPLE"
_leak "AWS key inline in a log" "using credentials AKIAIOSFODNN7EXAMPLE for s3" "AKIAIOSFODNN7EXAMPLE"
_leak "AWS secret access key" "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" "wJalrXUtnFEMI"
_leak "GitHub classic token" "remote: https://github.com/x ghp_abcdefghijklmnopqrstuvwxyz0123456789" "ghp_abcdefghij"
_leak "GitHub OAuth token" "token gho_16C7e42F292c6912E7710c838347Ae178B4a" "gho_16C7e42F"
_leak "GitHub fine-grained PAT" "GH=github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz" "github_pat_11ABC"
_leak "JWT" "session eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U" "dozjgNryP4J3"
_leak "Bearer header in curl" 'curl -H "Authorization: Bearer abcdef1234567890xyz" https://api' "abcdef1234567890xyz"
_leak "Authorization header line" "> Authorization: Basic dXNlcjpwYXNzd29yZA==" "dXNlcjpwYXNzd29yZA"
_leak "PEM private key" "$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU\nAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAt\n-----END OPENSSH PRIVATE KEY-----')" "b3BlbnNzaC1rZXkt"
_leak "DATABASE_URL with password" "DATABASE_URL=postgres://app:s3cr3tP4ss@db.internal:5432/app" "s3cr3tP4ss"
_leak "redis URL in an error" "Error: connect to redis://default:Zx9yQ2w@cache:6379 failed" "Zx9yQ2w"
_leak "env password" "DB_PASSWORD=hunter2hunter2" "hunter2hunter2"
_leak "export with quotes" 'export API_KEY="abc123def456"' "abc123def456"
_leak "JSON secret" '{"client_secret": "s3cr3t-value-here", "port": 8080}' "s3cr3t-value-here"
_leak "YAML secret" "  db_password: hunter2hunter2" "hunter2hunter2"
_leak "CLI flag" "docker login --password supersecret registry.io" "supersecret"
_leak "mst_ cli token" "token is mst_cli_9f8e7d6c5b4a3210" "mst_cli_9f8e7d6c"
_leak "mst_ agent token" "MUSTER_JOIN=mst_agent_abcdef123456" "mst_agent_abcdef"
_leak "Slack webhook" "notify https://hooks.slack.com/services/T0000000/B0000000/XXXXXXXXXXXXXXXXXXXXXXXX" "XXXXXXXXXXXXXXXX"
_leak "Slack bot token" "SLACK=xox""b-123456789012-1234567890123-AbCdEfGhIjKlMnOp" "AbCdEfGhIjKl"
_leak "Discord webhook" "posting to https://discord.com/api/webhooks/123456789012345678/abcDEF_ghi-JKL123" "abcDEF_ghi"
_leak "Stripe-style key" "charge failed for sk_""live_51HabcdefGHIJKLmnopQRSTuv" "sk_""live_51Habc"

echo "  .env values are masked anywhere"
printf 'APP_SIGNING_VALUE=zebra-banana-42\nPORT=3000\nNODE_ENV=production\nexport REGION="eu-west-1x"\n' > "$TMP/.env"
out=$(printf 'started with zebra-banana-42 on port 3000 in production (eu-west-1x)\n' | redact_text "$TMP/.env")
_test_not_contains "literal .env value masked" "zebra-banana-42" "$out"
_test_not_contains "quoted .env value masked" "eu-west-1x" "$out"
_test_contains "short numbers kept" "port 3000" "$out"
_test_contains "common words kept" "in production" "$out"

echo "  Ordinary log lines are untouched"
_clean "auth service log" "2024-05-01T10:00:00Z INFO auth service started on :8080"
_clean "token refresh" "[api] token refresh succeeded for user 42"
_clean "password reset" "Password reset email sent to user"
_clean "API path" "GET /api/v1/tokens 200 12ms"
_clean "docker build step" "Step 3/8 : RUN npm ci --production"
_clean "connection refused" "Error: connect ECONNREFUSED 127.0.0.1:5432"
_clean "logfmt" 'level=info msg="request done" status=200 duration=31ms'
_clean "k8s event" "Warning  BackOff  2m  kubelet  Back-off restarting failed container api in pod api-7d9f8-xk2"
_clean "env reference kept" 'password=${DB_PASSWORD} token=$TOKEN enable_auth=true'
_clean "Basic auth prose" "Basic authentication enabled for /admin"
_clean "URL without password" "Fetching https://registry.npmjs.org/express and git@github.com:acme/app.git"
_clean "commit hash" "deployed commit 3f9a1c2b7e4d5f6a8b9c0d1e2f3a4b5c6d7e8f90"
_clean "UUID" "request id 550e8400-e29b-41d4-a716-446655440000 done"
_clean "redacted twice is stable" "API_KEY=‹redacted›"

echo "  muster env"
_leak "muster secret key" "key=mstsec1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0" "mstsec1qpzry9x8gf2tvdw0"
_leak "muster ciphertext" 'value ENC[muster:v1,alg:xchacha20poly1305,iv:AAAA,ct:BBBB] here' "iv:AAAA"
_MUSTER_ENV_SECRET_LITS="plain-looking-value-123"
_leak "loaded env secret literal" "connecting with plain-looking-value-123 now" "plain-looking-value-123"
_redact_env_secrets "x plain-looking-value-123 y"
_test_eq "_redact_env_secrets (pure bash)" "x $R y" "$_REDACTED"
_MUSTER_ENV_SECRET_LITS=""

echo "  Fails closed"
out=$(PATH="/nonexistent" redact_text <<<"API_KEY=abc123def456" 2>/dev/null) && rc=0 || rc=$?
_test_eq "no jq → exit 1" "1" "$rc"
_test_eq "no jq → nothing printed" "" "$out"

_test_summary
