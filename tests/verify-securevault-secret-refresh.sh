#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for refresh-securevault-secrets.sh.
#
# Same properties as verify-dayandyou-api-secret-refresh.sh: realistic values
# (including ones compose would otherwise interpolate) land byte-exact in
# KEY='value' form at 0600 with the right owner; every shape rule refuses
# before anything is written, leaving the old file byte-identical with no
# backup taken; the parameter set is exactly the expected one; and no value
# ever reaches stdout or stderr. Plus SecureVault's own: the derived
# ALLOWED_EXTENSION_ORIGINS, the Google trio, and the OBJECT_STORE/PHOTO_S3_*
# coupling.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/refresh-securevault-secrets.sh"

TMP="$(mktemp -d)"
BIN="$TMP/bin"
SECRETS="$TMP/secrets/securevault"
PARAMS="$TMP/params"
LOGS="$TMP/logs"
mkdir -p "$BIN" "$PARAMS" "$LOGS"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# --- stubs (same shapes as the dayandyou-api test) ---------------------------
cat >"$BIN/stat" <<'STUB'
#!/usr/bin/env bash
echo "$STAT_OWNER"
STUB
cat >"$BIN/chown" <<'STUB'
#!/usr/bin/env bash
echo "$1 ${2##*/}" >>"$LOGS/chown"
STUB
cat >"$BIN/id" <<'STUB'
#!/usr/bin/env bash
[ "$2" = ubuntu ] || exit 1
case "$1" in -u) echo 1000 ;; -g) echo 1001 ;; *) exit 1 ;; esac
STUB
cat >"$BIN/aws" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$LOGS/aws"
[ -e "$LOGS/aws-fail-$2" ] && { echo "An error occurred (AccessDenied)" >&2; exit 255; }
name='' path=''
while [ "$#" -gt 0 ]; do
  case "$1" in --name) name="$2"; shift 2 ;; --path) path="$2"; shift 2 ;; *) shift ;; esac
done
if [ -n "$path" ]; then
  names=()
  for f in "$PARAMS"/*; do [ -e "$f" ] && names+=("$path/${f##*/}"); done
  [ -s "$LOGS/extra-names" ] && while read -r n; do names+=("$n"); done <"$LOGS/extra-names"
  (IFS=$'\t'; echo "${names[*]}")
  exit 0
fi
[ -e "$PARAMS/${name##*/}" ] || { echo "An error occurred (ParameterNotFound)" >&2; exit 255; }
cat "$PARAMS/${name##*/}"; echo
STUB
chmod +x "$BIN"/*

# Values compose would mangle if they were not single-quoted.
# shellcheck disable=SC2016  # literal $ and ${...} are the point
TRICKY_JWT='jwt$secret${HOME} with # hash and = sign 0123456789'
# shellcheck disable=SC2016
TRICKY_SMTP_PASS='p$a#s"s w=rd!'
HINT='hint-secret-0123456789abcdefghijklmnop'
EXT_A=abcdefghijklmnopabcdefghijklmnop
EXT_B=ponmlkjihgfedcbaponmlkjihgfedcba

set_param() { printf '%s' "$2" >"$PARAMS/$1"; }

set_valid_params() {
  rm -f "$PARAMS"/* "$LOGS/extra-names"
  set_param DATABASE_URL 'postgresql://securevault:dbpw@127.0.0.1:5432/securevault'
  set_param JWT_SECRET "$TRICKY_JWT"
  set_param INHERITANCE_HINT_SECRET "$HINT"
  set_param WEBAUTHN_RP_ID 'valtou.com'
  set_param WEBAUTHN_ORIGINS 'https://portal.valtou.com'
  set_param ALLOWED_ORIGINS 'https://portal.valtou.com, https://valtou.com'
  set_param FRONTEND_URL 'https://portal.valtou.com'
  set_param CAPTCHA_SECRET 'captcha-secret-value-123'
  set_param SMTP_HOST 'email-smtp.ap-southeast-2.amazonaws.com'
  set_param SMTP_PORT '465'
  set_param SMTP_SECURE 'true'
  set_param SMTP_USER 'AKIAI44QH8DHBEXAMPLE'
  set_param SMTP_PASS "$TRICKY_SMTP_PASS"
  set_param EMAIL_FROM '"Valtou" <no-reply@valtou.com>'
}

set_full_optionals() {
  set_param CAPTCHA_PROVIDER 'recaptcha'
  set_param PASSWORD_RESET_PATH '/en/forgot-password'
  set_param EXTENSION_IDS "$EXT_A, $EXT_B"
  set_param GOOGLE_CLIENT_ID 'google-client-id.apps.googleusercontent.com'
  set_param GOOGLE_CLIENT_SECRET 'GOCSPX-google-secret'
  set_param GOOGLE_REDIRECT_URI 'https://api.valtou.com/api/auth/google/callback'
  set_param OBJECT_STORE 's3'
  set_param PHOTO_S3_BUCKET 'valtou-vault-photos-prod'
  set_param PHOTO_S3_REGION 'ap-southeast-2'
  set_param PHOTO_S3_ACCESS_KEY_ID 'AKIAIOSFODNN7EXAMPLE'
  set_param PHOTO_S3_SECRET_ACCESS_KEY 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
}

# The exact file the script must write: fixed key order, one header line.
expected_file() {
  local key
  echo "# Written by scripts/refresh-securevault-secrets.sh from SSM /securevault/prod/ -- do not hand-edit."
  for key in DATABASE_URL JWT_SECRET INHERITANCE_HINT_SECRET WEBAUTHN_RP_ID WEBAUTHN_ORIGINS ALLOWED_ORIGINS \
             FRONTEND_URL CAPTCHA_SECRET SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_USER SMTP_PASS EMAIL_FROM \
             CAPTCHA_PROVIDER PASSWORD_RESET_PATH EXTENSION_IDS OBJECT_STORE \
             GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REDIRECT_URI \
             PHOTO_S3_BUCKET PHOTO_S3_REGION PHOTO_S3_ACCESS_KEY_ID PHOTO_S3_SECRET_ACCESS_KEY; do
    [ -e "$PARAMS/$key" ] && printf "%s='%s'\n" "$key" "$(cat "$PARAMS/$key")"
  done
  [ -e "$PARAMS/EXTENSION_IDS" ] && printf "ALLOWED_EXTENSION_ORIGINS='chrome-extension://%s,chrome-extension://%s'\n" "$EXT_A" "$EXT_B"
  return 0
}

mode_of() { /usr/bin/stat -c '%a' "$1" 2>/dev/null || /usr/bin/stat -f '%Lp' "$1"; }

ALL_OUTPUT="$LOGS/all-output"
: >"$ALL_OUTPUT"

run_refresh() {
  local out rc=0
  : >"$LOGS/chown"; : >"$LOGS/aws"
  out="$(env -u AWS_PROFILE PATH="$BIN:$PATH" LOGS="$LOGS" PARAMS="$PARAMS" SECRETS_DIR="$SECRETS" \
    STAT_OWNER="${STAT_OWNER:-2000:2000}" SUDO_USER="${RUN_SUDO_USER-ubuntu}" \
    sh "$SCRIPT" "$@" 2>&1)" || rc=$?
  printf '%s\n' "$out" >>"$ALL_OUTPUT"
  printf '%s\n' "$out"
  return "$rc"
}

backups() { find "$SECRETS" -name '*.bak-*' 2>/dev/null | wc -l | tr -d ' '; }

seed_old_file() {
  rm -rf "$SECRETS"; mkdir -p "$SECRETS"
  printf "JWT_SECRET='old'\n" >"$SECRETS/api.env"
  chmod 600 "$SECRETS/api.env"
  cp "$SECRETS/api.env" "$TMP/old.env"
}

expect_refusal() {
  local label="$1" pattern="$2" out
  if out="$(run_refresh)"; then
    fail "$label must be refused, got:\n$out"
  fi
  grep -qF -- "$pattern" <<<"$out" || fail "$label: expected '$pattern', got:\n$out"
  cmp -s "$TMP/old.env" "$SECRETS/api.env" || fail "$label: env file was modified despite the refusal"
  [ "$(backups)" = 0 ] || fail "$label: a backup was taken before validation completed"
  [ ! -e "$SECRETS/api.env.new" ] || fail "$label: left a .new file behind"
}

# 1. First run, required keys only: 0700 dir, 0600 file owned by the sudo
#    user, exact content, no derived extension origins.
set_valid_params
rm -rf "$SECRETS"
OUT="$(run_refresh)" || fail "valid values should be written, got:\n$OUT"
[ "$(cat "$SECRETS/api.env")" = "$(expected_file)" ] \
  || fail "env file content differs:\n$(diff <(expected_file) "$SECRETS/api.env" || true)"
grep -qxF "JWT_SECRET='$TRICKY_JWT'" "$SECRETS/api.env" || fail "JWT_SECRET not written literally"
grep -q ALLOWED_EXTENSION_ORIGINS "$SECRETS/api.env" && fail "no EXTENSION_IDS must mean no ALLOWED_EXTENSION_ORIGINS"
[ "$(mode_of "$SECRETS/api.env")" = 600 ] || fail "env file is not 0600"
[ "$(mode_of "$SECRETS")" = 700 ] || fail "secrets dir is not 0700"
grep -qx '1000:1001 securevault' "$LOGS/chown" || fail "new dir not chowned to SUDO_USER:\n$(cat "$LOGS/chown")"
grep -qx '1000:1001 api.env' "$LOGS/chown" || fail "new file not chowned to SUDO_USER:\n$(cat "$LOGS/chown")"
grep -q 'backup: none' <<<"$OUT" || fail "first run should report no backup"
grep -q -- '--profile securevault-ssm' "$LOGS/aws" || fail "default profile must be securevault-ssm"
grep -q -- 'get-parameters-by-path .*--path /securevault/prod .*--recursive' "$LOGS/aws" \
  || fail "listing must be recursive under /securevault/prod"
grep 'get-parameter ' "$LOGS/aws" | grep -qv -- '--with-decryption' && fail "every get-parameter must decrypt"

# 2. Rerun with every optional key: owner preserved, one backup holding the
#    previous file, extension origins derived from the trimmed ids.
cp "$SECRETS/api.env" "$TMP/first.env"
set_full_optionals
OUT="$(STAT_OWNER=1500:1500 run_refresh)" || fail "rerun failed:\n$OUT"
grep -qx '1500:1500 api.env' "$LOGS/chown" || fail "existing owner not preserved:\n$(cat "$LOGS/chown")"
[ "$(backups)" = 1 ] || fail "expected exactly one backup after the second run"
cmp -s "$TMP/first.env" "$SECRETS"/api.env.bak-* || fail "the backup must hold the previous file"
[ "$(cat "$SECRETS/api.env")" = "$(expected_file)" ] \
  || fail "full env file content differs:\n$(diff <(expected_file) "$SECRETS/api.env" || true)"
# Unchanged values (every deploy): nothing rewritten, the backup still holds
# the value before the last real rotation.
sleep 1
OUT="$(RUN_SUDO_USER='' STAT_OWNER=1500:1500 run_refresh)" || fail "third run (plain root, file exists) failed:\n$OUT"
grep -q 'unchanged' <<<"$OUT" || fail "an unchanged run should say so, got:\n$OUT"
[ "$(backups)" = 1 ] || fail "expected exactly one backup after the third run, found $(backups)"
cmp -s "$TMP/first.env" "$SECRETS"/api.env.bak-* || fail "an unchanged run must keep the backup of the previous values"
[ ! -e "$SECRETS/api.env.new" ] || fail "an unchanged run left a .new file behind"

# The RP ID itself and a port are fine as WebAuthn origins.
set_param WEBAUTHN_ORIGINS 'https://valtou.com, https://portal.valtou.com:8443'
run_refresh >/dev/null || fail "apex and ported subdomain origins must be accepted"

# OBJECT_STORE=off may keep staged PHOTO_S3_* values.
set_param OBJECT_STORE off
run_refresh >/dev/null || fail "OBJECT_STORE=off with PHOTO_S3_* staged must be accepted"

# 3. Arguments and owner.
out="$(run_refresh prod)" && fail "an argument must be refused"
grep -q 'usage:' <<<"$out" || fail "an argument should print usage"
rm -rf "$SECRETS"; set_valid_params
out="$(RUN_SUDO_USER='' run_refresh)" && fail "a new file without SUDO_USER must be refused"
grep -q 'SUDO_USER' <<<"$out" || fail "expected the SUDO_USER message, got:\n$out"
[ ! -e "$SECRETS" ] || fail "a refused first run must not create the dir"

# 4. Shape rules: each refused, old file byte-identical, no backup.
refuse() { # key value pattern
  seed_old_file; set_valid_params; set_param "$1" "$2"
  expect_refusal "$1='$2'" "$3"
}
refuse DATABASE_URL 'mysql://u:p@h/db' 'DATABASE_URL must start with postgres'
refuse JWT_SECRET "$(printf 'j%.0s' $(seq 31))" 'JWT_SECRET from SSM is only 31 chars'
refuse INHERITANCE_HINT_SECRET 'short' 'INHERITANCE_HINT_SECRET from SSM is only 5 chars'
refuse WEBAUTHN_RP_ID 'https://valtou.com' 'WEBAUTHN_RP_ID must be a bare lowercase domain'
refuse WEBAUTHN_RP_ID 'valtou.com:443' 'WEBAUTHN_RP_ID must be a bare lowercase domain'
refuse WEBAUTHN_RP_ID 'Valtou.com' 'WEBAUTHN_RP_ID must be a bare lowercase domain'
refuse WEBAUTHN_RP_ID 'localhost' 'WEBAUTHN_RP_ID must be a bare lowercase domain'
refuse WEBAUTHN_ORIGINS 'https://portal.valtou.com/' 'WEBAUTHN_ORIGINS entry 0 is not a bare https origin'
refuse WEBAUTHN_ORIGINS 'portal.valtou.com' 'WEBAUTHN_ORIGINS entry 0 is not a bare https origin'
refuse WEBAUTHN_ORIGINS 'http://portal.valtou.com' 'WEBAUTHN_ORIGINS entry 0 is not a bare https origin'
refuse WEBAUTHN_ORIGINS 'https://Portal.valtou.com' 'WEBAUTHN_ORIGINS entry 0 is not a bare https origin'
refuse WEBAUTHN_ORIGINS 'https://portal.valtou.com:443' 'WEBAUTHN_ORIGINS entry 0 is not a bare https origin'
refuse WEBAUTHN_ORIGINS 'https://*' 'WEBAUTHN_ORIGINS entry 0 is not a bare https origin'
refuse WEBAUTHN_ORIGINS 'https://portal.example.com' 'neither WEBAUTHN_RP_ID nor a subdomain of it'
refuse WEBAUTHN_ORIGINS 'https://portal.valtou.com,https://evilvaltou.com' 'neither WEBAUTHN_RP_ID nor a subdomain of it'
refuse WEBAUTHN_ORIGINS ' , ' 'WEBAUTHN_ORIGINS from SSM lists no origin'
refuse ALLOWED_ORIGINS 'https://portal.valtou.com,https://valtou.com/app' 'ALLOWED_ORIGINS entry 1 is not a bare https origin'
refuse ALLOWED_ORIGINS 'http://localhost:3000' 'ALLOWED_ORIGINS entry 0 is not a bare https origin'
refuse FRONTEND_URL 'http://portal.valtou.com' 'FRONTEND_URL must start with https://'
refuse SMTP_PORT 'smtp' 'SMTP_PORT must be a port number'
refuse SMTP_PORT '70000' 'SMTP_PORT must be a port number'
refuse SMTP_SECURE 'yes' 'SMTP_SECURE must be true or false'
refuse CAPTCHA_PROVIDER 'recapcha' 'CAPTCHA_PROVIDER must be recaptcha, turnstile or hcaptcha'
refuse PASSWORD_RESET_PATH 'en/forgot-password' 'PASSWORD_RESET_PATH must start with /'
refuse EXTENSION_IDS "$EXT_A,not-an-id" 'EXTENSION_IDS entries must be 32 letters a-p'
refuse EXTENSION_IDS "${EXT_A}q" 'EXTENSION_IDS entries must be 32 letters a-p'
refuse OBJECT_STORE 'local-fs' 'OBJECT_STORE must be s3 or off'
refuse OBJECT_STORE 's3' 'OBJECT_STORE=s3 needs /securevault/prod/PHOTO_S3_BUCKET'
refuse PHOTO_S3_BUCKET 'valtou-vault-photos-prod' 'PHOTO_S3_* is set but OBJECT_STORE is not'
refuse SMTP_HOST '' 'empty SMTP_HOST'
refuse EMAIL_FROM "a@b.c"$'\n'"x" 'EMAIL_FROM from SSM contains a line break'
refuse SMTP_USER "$(printf 'user\rname')" 'SMTP_USER from SSM contains a line break'
refuse SMTP_PASS "it's a password" 'contains a single quote'

seed_old_file; set_valid_params; set_full_optionals; set_param PHOTO_S3_SECRET_ACCESS_KEY 'short'
expect_refusal "a short photo secret" 'PHOTO_S3_SECRET_ACCESS_KEY from SSM is only 5 chars'

# 5. The parameter set: missing, unknown (incl. the derived name), nested,
#    Google trio all-or-nothing.
seed_old_file; set_valid_params; rm "$PARAMS/WEBAUTHN_RP_ID"
expect_refusal "a missing WEBAUTHN_RP_ID" 'missing required parameter /securevault/prod/WEBAUTHN_RP_ID'
seed_old_file; set_valid_params; set_param VAULT_KEK 'escrow-is-gone-0123456789'
expect_refusal "an unknown VAULT_KEK" 'unknown parameter /securevault/prod/VAULT_KEK'
seed_old_file; set_valid_params; set_param ALLOWED_EXTENSION_ORIGINS "chrome-extension://$EXT_A"
expect_refusal "a stored ALLOWED_EXTENSION_ORIGINS" 'unknown parameter /securevault/prod/ALLOWED_EXTENSION_ORIGINS'
seed_old_file; set_valid_params; echo /securevault/prod/old/JWT_SECRET >"$LOGS/extra-names"
expect_refusal "a nested name" 'unknown parameter /securevault/prod/old/JWT_SECRET'
seed_old_file; set_valid_params; set_param GOOGLE_CLIENT_ID 'id.apps.googleusercontent.com'
expect_refusal "a lone GOOGLE_CLIENT_ID" 'all three or none in SSM, found 1'

# 6. AWS failures abort cleanly.
seed_old_file; set_valid_params; touch "$LOGS/aws-fail-get-parameters-by-path"
expect_refusal "a failed listing" 'could not list /securevault/prod/'
rm "$LOGS/aws-fail-get-parameters-by-path"
seed_old_file; set_valid_params; touch "$LOGS/aws-fail-get-parameter"
expect_refusal "a failed fetch" 'could not fetch /securevault/prod/'
rm "$LOGS/aws-fail-get-parameter"

# 7. No value ever reached stdout/stderr, across every run above.
for v in "$TRICKY_JWT" "$TRICKY_SMTP_PASS" "$HINT" securevault:dbpw captcha-secret-value GOCSPX-google \
         wJalrXUtnFEMI/K7MDENG AKIAI44QH8DHBEXAMPLE "$EXT_A" escrow-is-gone jjjjjjjjjjjjjjjjjjjj not-an-id; do
  grep -qF -- "$v" "$ALL_OUTPUT" && fail "a value was echoed: $v"
done

echo "PASS: securevault secret refresh (7 groups)"
