#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for refresh-zenvora-admin-secrets.sh.
#
# The script once applied an 8-char minimum to every key it manages, including
# SMTP_PORT=587, SMTP_SECURE=true and a 7-digit GitHub user id -- so the
# documented rotation path aborted on every run and a leaked token could only
# be rotated by hand-editing the env file. The properties under test: realistic
# values are written; the length floor still guards the real secrets; the
# non-secret settings are checked by shape instead; and a refused run leaves
# the env file untouched.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/refresh-zenvora-admin-secrets.sh"

TMP="$(mktemp -d)"
BIN="$TMP/bin"
SECRETS="$TMP/secrets"
PARAMS="$TMP/params"
mkdir -p "$BIN" "$SECRETS" "$PARAMS"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# --- stubs -----------------------------------------------------------------
# stat -c and chown are Linux/root shapes the host has and this machine does not.
cat >"$BIN/stat" <<'STUB'
#!/usr/bin/env bash
echo "1000:1000"
STUB
cat >"$BIN/chown" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$BIN/aws" <<'STUB'
#!/usr/bin/env bash
name=''
while [ "$#" -gt 0 ]; do
  case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
done
cat "$PARAMS/${name##*/}" 2>/dev/null
STUB
chmod +x "$BIN"/*

SMTP_PASS_VALUE='smtp-app-password-123'

# Realistic production values, including the short non-secret ones.
set_valid_params() {
  rm -f "$PARAMS"/*
  printf '%s' 'q83vEi5fSkd1jVZxW0Hj3d1T9o8bJb2cR2l1d1oQ8pE=' >"$PARAMS/TOKEN_ENCRYPTION_KEY"
  printf '%s' '1234567'                       >"$PARAMS/WHITELISTED_GITHUB_USER_ID"
  printf '%s' 'Iv23liExampleClientId'         >"$PARAMS/GITHUB_APP_CLIENT_ID"
  printf '%s' 'abcdef0123456789abcdef0123456789abcdef01' >"$PARAMS/GITHUB_APP_CLIENT_SECRET"
  printf '%s' 'alert-check-token-0123456789'  >"$PARAMS/ALERT_CHECK_TOKEN"
  printf '%s' 'ghp_exampleReadToken0123456789' >"$PARAMS/GHCR_READ_TOKEN"
  printf '%s' 'cf-api-token-0123456789abcdef' >"$PARAMS/CLOUDFLARE_API_TOKEN"
  printf '%s' 'smtp.example.com'              >"$PARAMS/SMTP_HOST"
  printf '%s' '587'                           >"$PARAMS/SMTP_PORT"
  printf '%s' 'true'                          >"$PARAMS/SMTP_SECURE"
  printf '%s' 'mailer'                        >"$PARAMS/SMTP_USER"
  printf '%s' "$SMTP_PASS_VALUE"              >"$PARAMS/SMTP_PASS"
  printf '%s' 'a@ex.io'                       >"$PARAMS/ALERT_EMAIL_FROM"
  printf '%s' 'b@ex.io'                       >"$PARAMS/ALERT_EMAIL_TO"
}

set_param() { printf '%s' "$2" >"$PARAMS/$1"; }

write_env_file() {
  rm -f "$SECRETS"/.env.bak-*
  cat >"$SECRETS/.env" <<'ENV'
PORT=3100
DB_PATH=/app/data/zenvora.db
DOCKER_PROXY_URL=http://docker-socket-proxy:2375
SMTP_PORT=old-port
SMTP_PASS=old-pass
ENV
  chmod 600 "$SECRETS/.env"
}

run_refresh() {
  env PATH="$BIN:$PATH" PARAMS="$PARAMS" SECRETS_DIR="$SECRETS" sh "$SCRIPT" 2>&1
}

value_of() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2-; }

expect_refusal() {
  local label="$1" pattern="$2" out
  if out="$(run_refresh)"; then
    fail "$label must be refused, got:\n$out"
  fi
  grep -q -- "$pattern" <<<"$out" || fail "$label: expected '$pattern', got:\n$out"
  [ "$(value_of "$SECRETS/.env" SMTP_PASS)" = "old-pass" ] \
    || fail "$label: env file was modified despite the refusal"
  [ -z "$(ls "$SECRETS"/.env.bak-* 2>/dev/null)" ] \
    || fail "$label: a backup was taken before validation completed"
}

# 1. Realistic values (short SMTP_PORT/SMTP_SECURE/user id) are written.
write_env_file
set_valid_params
OUT="$(run_refresh)" || fail "realistic values should be written, got:\n$OUT"
[ "$(value_of "$SECRETS/.env" SMTP_PORT)" = "587" ] || fail "SMTP_PORT not written"
[ "$(value_of "$SECRETS/.env" SMTP_SECURE)" = "true" ] || fail "SMTP_SECURE not written"
[ "$(value_of "$SECRETS/.env" WHITELISTED_GITHUB_USER_ID)" = "1234567" ] || fail "user id not written"
[ "$(value_of "$SECRETS/.env" SMTP_PASS)" = "$SMTP_PASS_VALUE" ] || fail "SMTP_PASS not written"
[ "$(grep -c '^SMTP_PORT=' "$SECRETS/.env")" = 1 ] || fail "duplicate SMTP_PORT lines"
grep -q '^DOCKER_PROXY_URL=http://docker-socket-proxy:2375$' "$SECRETS/.env" \
  || fail "a static line was lost"
grep -q -- "$SMTP_PASS_VALUE" <<<"$OUT" && fail "a secret was echoed to stdout"

# 2. The length floor still guards each real secret.
for key in TOKEN_ENCRYPTION_KEY GITHUB_APP_CLIENT_SECRET ALERT_CHECK_TOKEN \
           GHCR_READ_TOKEN CLOUDFLARE_API_TOKEN SMTP_PASS; do
  write_env_file; set_valid_params; set_param "$key" 'short'
  expect_refusal "a 5-char $key" "$key from SSM is only 5 chars"
done

# 3. Non-secret settings are checked by shape.
write_env_file; set_valid_params; set_param SMTP_PORT 'TODO'
expect_refusal "a non-numeric SMTP_PORT" 'SMTP_PORT from SSM is not a port number'
write_env_file; set_valid_params; set_param SMTP_PORT '70000'
expect_refusal "an out-of-range SMTP_PORT" 'SMTP_PORT from SSM is not a port number'
write_env_file; set_valid_params; set_param SMTP_SECURE 'yes'
expect_refusal "SMTP_SECURE=yes" 'SMTP_SECURE from SSM must be true or false'
write_env_file; set_valid_params; set_param WHITELISTED_GITHUB_USER_ID 'me'
expect_refusal "a non-numeric user id" 'WHITELISTED_GITHUB_USER_ID from SSM is not numeric'

# 4. An empty parameter is refused, not written as blank.
write_env_file; set_valid_params; set_param SMTP_HOST ''
expect_refusal "an empty SMTP_HOST" 'empty SMTP_HOST from SSM'

echo "PASS: zenvora-admin secret refresh (4 groups)"
