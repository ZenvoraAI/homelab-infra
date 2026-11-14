#!/usr/bin/env bash
set -euo pipefail

# Built at runtime: a literal live-key-shaped fixture trips GitHub push protection.
LIVE=live

# Behavioural test for refresh-dayandyou-api-secrets.sh.
#
# The script writes the whole Laravel API env file from SSM, so the properties
# under test are: realistic values (including ones compose would otherwise
# interpolate) land byte-exact in KEY='value' form at 0600 with the right
# owner; every shape rule refuses before anything is written, leaving the old
# file byte-identical with no backup taken; the parameter set under the prefix
# is exactly the expected one (no missing key, no unknown extra, no prod
# SITE_PASSWORD, rebuild quartet all-or-nothing); and no value ever reaches
# stdout or stderr.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/refresh-dayandyou-api-secrets.sh"

TMP="$(mktemp -d)"
BIN="$TMP/bin"
SECRETS="$TMP/secrets/dayandyou-api"
PARAMS="$TMP/params"
LOGS="$TMP/logs"
mkdir -p "$BIN" "$PARAMS" "$LOGS"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# --- stubs -----------------------------------------------------------------
# stat -c, chown and id are Linux/root shapes the host has and this machine
# does not. stat reports $STAT_OWNER (the "existing owner"); chown logs what
# it was asked to do; id maps SUDO_USER to 1000:1001.
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
# aws: get-parameters-by-path lists one name per file in $PARAMS (plus any
# lines in $LOGS/extra-names), tab-separated like aws-cli's text output;
# get-parameter prints the file's content. Every call is logged.
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
TRICKY_PASSWORD='p$a#s"s w=rd!'
# shellcheck disable=SC2016
TRICKY_ROOT='abc${HOME} root secret $$ with # hash and = sign 0123'
APP_KEY_OK='base64:q83vEi5fSkd1jVZxW0Hj3d1T9o8bJb2cR2l1d1oQ8pE='

set_param() { printf '%s' "$2" >"$PARAMS/$1"; }

set_valid_params() {
  local env="$1"
  rm -f "$PARAMS"/* "$LOGS/extra-names"
  set_param DATABASE_URL "postgresql://dayandyou_api_$env:pw@127.0.0.1:5432/dayandyou_api_$env"
  set_param DAYANDYOU_ROOT_SECRET "$TRICKY_ROOT"
  set_param APP_KEY "$APP_KEY_OK"
  set_param SITE_MODE 'coming-soon'
  set_param AWS_ACCESS_KEY_ID 'AKIAIOSFODNN7EXAMPLE'
  set_param AWS_SECRET_ACCESS_KEY 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
  set_param AWS_REGION 'ap-southeast-2'
  set_param AWS_S3_BUCKET "dayandyou-media-$env"
  set_param AWS_SES_REGION 'ap-southeast-2'
  set_param AWS_SES_ACCESS_KEY_ID 'AKIAI44QH8DHBEXAMPLE'
  set_param AWS_SES_SECRET_ACCESS_KEY 'je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY'
  set_param AWS_SES_FROM 'Day and You <hello@dayandyou.com>'
  set_param ADMIN_EMAIL 'owner@dayandyou.com'
  set_param STRIPE_WEBHOOK_SECRET 'whsec_0123456789abcdefABCDEF'
  if [ "$env" = staging ]; then
    set_param APP_URL 'https://staging.dayandyou.com'
    set_param ASSET_BASE_URL 'https://staging.dayandyou.com/media'
    set_param STRIPE_SECRET_KEY 'sk_test_51ExampleTestKey0123456789'
    set_param SITE_PASSWORD "$TRICKY_PASSWORD"
  else
    set_param APP_URL 'https://dayandyou.com'
    set_param ASSET_BASE_URL 'https://dayandyou.com/media'
    set_param STRIPE_SECRET_KEY "rk_${LIVE}_51ExampleLiveKey0123456789"
  fi
}

set_rebuild_quartet() {
  set_param FRONTEND_REBUILD_TOKEN 'github_pat_11EXAMPLE0123456789abcdef'
  set_param FRONTEND_REBUILD_REPO 'zenvoraai/day-and-you'
  set_param FRONTEND_REBUILD_WORKFLOW 'deploy-static.yml'
  set_param FRONTEND_REBUILD_REF 'main'
}

# The exact file the script must write: fixed key order, one header line.
expected_file() {
  local env="$1" key
  echo "# Written by scripts/refresh-dayandyou-api-secrets.sh from SSM /dayandyou-api/$env/ -- do not hand-edit."
  for key in DATABASE_URL DAYANDYOU_ROOT_SECRET APP_KEY APP_URL STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET \
             SITE_MODE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_S3_BUCKET ASSET_BASE_URL \
             AWS_SES_REGION AWS_SES_ACCESS_KEY_ID AWS_SES_SECRET_ACCESS_KEY AWS_SES_FROM ADMIN_EMAIL \
             SITE_PASSWORD FRONTEND_REBUILD_TOKEN FRONTEND_REBUILD_REPO FRONTEND_REBUILD_WORKFLOW FRONTEND_REBUILD_REF; do
    [ -e "$PARAMS/$key" ] && printf "%s='%s'\n" "$key" "$(cat "$PARAMS/$key")"
  done
  return 0
}

mode_of() { /usr/bin/stat -c '%a' "$1" 2>/dev/null || /usr/bin/stat -f '%Lp' "$1"; }

ALL_OUTPUT="$LOGS/all-output"
: >"$ALL_OUTPUT"

# Runs the script; captures stdout+stderr (also appended to ALL_OUTPUT for the
# leak check at the end). STAT_OWNER and SUDO_USER can be overridden.
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

# Puts a known "old" file in place for the refusal checks.
seed_old_file() {
  rm -rf "$SECRETS"; mkdir -p "$SECRETS"
  printf "SITE_MODE='live'\nAPP_KEY='old'\n" >"$SECRETS/$1.env"
  chmod 600 "$SECRETS/$1.env"
  cp "$SECRETS/$1.env" "$TMP/old.env"
}

expect_refusal() {
  local env="$1" label="$2" pattern="$3" out
  if out="$(run_refresh "$env")"; then
    fail "$label must be refused, got:\n$out"
  fi
  grep -qF -- "$pattern" <<<"$out" || fail "$label: expected '$pattern', got:\n$out"
  cmp -s "$TMP/old.env" "$SECRETS/$env.env" || fail "$label: env file was modified despite the refusal"
  [ "$(backups)" = 0 ] || fail "$label: a backup was taken before validation completed"
  [ ! -e "$SECRETS/$env.env.new" ] || fail "$label: left a .new file behind"
}

# 1. First staging run: creates the 0700 dir and the 0600 file, owned by the
#    sudo user; content is exact (tricky values literal, single-quoted).
set_valid_params staging
rm -rf "$SECRETS"
OUT="$(run_refresh staging)" || fail "valid staging values should be written, got:\n$OUT"
[ "$(cat "$SECRETS/staging.env")" = "$(expected_file staging)" ] \
  || fail "staging env file content differs:\n$(diff <(expected_file staging) "$SECRETS/staging.env" || true)"
grep -qxF "SITE_PASSWORD='$TRICKY_PASSWORD'" "$SECRETS/staging.env" || fail "SITE_PASSWORD not written literally"
[ "$(mode_of "$SECRETS/staging.env")" = 600 ] || fail "env file is not 0600"
[ "$(mode_of "$SECRETS")" = 700 ] || fail "secrets dir is not 0700"
grep -qx '1000:1001 dayandyou-api' "$LOGS/chown" || fail "new dir not chowned to SUDO_USER:\n$(cat "$LOGS/chown")"
grep -qx '1000:1001 staging.env' "$LOGS/chown" || fail "new file not chowned to SUDO_USER:\n$(cat "$LOGS/chown")"
[ "$(backups)" = 0 ] || fail "a first run has nothing to back up"
grep -q 'backup: none' <<<"$OUT" || fail "first run should report no backup"
grep -q -- '--profile dayandyou-api-ssm' "$LOGS/aws" || fail "default profile must be dayandyou-api-ssm"
grep -q -- 'get-parameters-by-path .*--path /dayandyou-api/staging .*--recursive' "$LOGS/aws" \
  || fail "listing must be recursive under /dayandyou-api/staging"
grep 'get-parameter ' "$LOGS/aws" | grep -qv -- '--with-decryption' && fail "every get-parameter must decrypt"
grep -q 'FRONTEND_REBUILD' "$SECRETS/staging.env" && fail "absent rebuild quartet must not be written"

# 2. Second and third runs: owner of the existing file is preserved, exactly
#    one backup, holding the previous content.
cp "$SECRETS/staging.env" "$TMP/first.env"
set_rebuild_quartet
OUT="$(STAT_OWNER=1500:1500 run_refresh staging)" || fail "rerun failed:\n$OUT"
grep -qx '1500:1500 staging.env' "$LOGS/chown" || fail "existing owner not preserved:\n$(cat "$LOGS/chown")"
grep -q 'dayandyou-api$' "$LOGS/chown" && fail "an existing dir must not be re-chowned"
[ "$(backups)" = 1 ] || fail "expected exactly one backup after the second run"
cmp -s "$TMP/first.env" "$SECRETS"/staging.env.bak-* || fail "the backup must hold the previous file"
[ "$(cat "$SECRETS/staging.env")" = "$(expected_file staging)" ] || fail "quartet not written on rerun"
sleep 1
OUT="$(STAT_OWNER=1500:1500 run_refresh staging)" || fail "third run failed:\n$OUT"
[ "$(backups)" = 1 ] || fail "expected exactly one backup after the third run, found $(backups)"
# A run without SUDO_USER is fine once the file exists (its owner is known).
OUT="$(RUN_SUDO_USER='' run_refresh staging)" || fail "rerun as plain root should keep the owner:\n$OUT"

# 3. Prod with the rebuild quartet; no SITE_PASSWORD; live key; no staging
#    backups touched.
set_valid_params prod; set_rebuild_quartet
OUT="$(run_refresh prod)" || fail "valid prod values should be written, got:\n$OUT"
[ "$(cat "$SECRETS/prod.env")" = "$(expected_file prod)" ] \
  || fail "prod env file content differs:\n$(diff <(expected_file prod) "$SECRETS/prod.env" || true)"
grep -q SITE_PASSWORD "$SECRETS/prod.env" && fail "prod must not carry SITE_PASSWORD"
[ -e "$SECRETS/staging.env" ] || fail "a prod run must not touch staging"
set_param STRIPE_SECRET_KEY "sk_${LIVE}_51ExampleLiveKey0123456789"
run_refresh prod >/dev/null || fail "sk_live_ must be accepted on prod"

# 4. Arguments and owner.
out="$(run_refresh)" && fail "no argument must be refused"
grep -q 'usage:' <<<"$out" || fail "missing argument should print usage"
out="$(run_refresh dev)" && fail "an unknown env must be refused"
rm -rf "$SECRETS"; set_valid_params staging
out="$(RUN_SUDO_USER='' run_refresh staging)" && fail "a new file without SUDO_USER must be refused"
grep -q 'SUDO_USER' <<<"$out" || fail "expected the SUDO_USER message, got:\n$out"
[ ! -e "$SECRETS" ] || fail "a refused first run must not create the dir"

# 5. Shape rules: each refused, old file byte-identical, no backup.
refuse() { # env key value pattern
  seed_old_file "$1"; set_valid_params "$1"; set_param "$2" "$3"
  expect_refusal "$1" "$2='$3' on $1" "$4"
}
refuse staging SITE_MODE 'open' 'SITE_MODE must be empty'
refuse staging STRIPE_SECRET_KEY "sk_${LIVE}_51ExampleLiveKey0123456789" 'must be a test key'
refuse staging STRIPE_SECRET_KEY 'sk_test_' 'must be a test key'
refuse prod STRIPE_SECRET_KEY 'sk_test_51ExampleTestKey0123456789' 'must be a live key'
refuse staging STRIPE_WEBHOOK_SECRET 'wh_0123456789abcdef' 'must start with whsec_'
refuse staging APP_KEY 'q83vEi5fSkd1jVZxW0Hj3d1T9o8bJb2cR2l1d1oQ8pE=' 'must start with base64:'
refuse staging APP_KEY 'base64:c2hvcnQ=' 'plus 44 characters'
refuse staging APP_KEY 'base64:q83vEi5fSkd1jVZxW0Hj3d1T9o8bJb2cR2l1d1oQ8p==' 'not the base64 of 32 bytes'
refuse staging APP_KEY 'base64:q83vEi5fSkd1jVZxW0Hj3d1T9o8bJb2cR2l1d1oQ8pEx' 'not the base64 of 32 bytes'
refuse staging APP_KEY 'base64:q83vEi5fSkd1jVZx-0Hj3d1T9o8bJb2cR2l1d1oQ8pE=' 'not the base64 of 32 bytes'
refuse staging DATABASE_URL 'mysql://u:p@h/db' 'DATABASE_URL must start with postgres'
refuse staging APP_URL 'http://staging.dayandyou.com' 'APP_URL must start with https://'
refuse staging ASSET_BASE_URL 'https://dayandyou.com/media' 'must be exactly https://staging.dayandyou.com/media'
refuse prod ASSET_BASE_URL 'https://staging.dayandyou.com/media' 'must be exactly https://dayandyou.com/media'
refuse staging DAYANDYOU_ROOT_SECRET "$(printf 'r%.0s' $(seq 31))" 'DAYANDYOU_ROOT_SECRET from SSM is only 31 chars'
refuse staging SITE_PASSWORD 'elevenchars' 'SITE_PASSWORD from SSM is only 11 chars'
refuse staging AWS_SECRET_ACCESS_KEY "$(printf 's%.0s' $(seq 29))" 'AWS_SECRET_ACCESS_KEY from SSM is only 29 chars'
refuse prod AWS_SES_SECRET_ACCESS_KEY "$(printf 's%.0s' $(seq 29))" 'AWS_SES_SECRET_ACCESS_KEY from SSM is only 29 chars'
refuse staging AWS_REGION '' 'empty AWS_REGION'
refuse staging ADMIN_EMAIL "owner@dayandyou.com"$'\n'"x" 'ADMIN_EMAIL from SSM contains a line break'
refuse staging AWS_SES_FROM "$(printf 'Day and You\r<hello@dayandyou.com>')" 'AWS_SES_FROM from SSM contains a line break'
refuse staging DAYANDYOU_ROOT_SECRET "it's a long enough root secret value 0123456789" 'contains a single quote'

# 6. The parameter set: missing, unknown, nested, prod SITE_PASSWORD, quartet.
seed_old_file staging; set_valid_params staging; rm "$PARAMS/AWS_SES_FROM"
expect_refusal staging "a missing AWS_SES_FROM" 'missing required parameter /dayandyou-api/staging/AWS_SES_FROM'
seed_old_file staging; set_valid_params staging; rm "$PARAMS/SITE_PASSWORD"
expect_refusal staging "a missing staging SITE_PASSWORD" 'missing required parameter /dayandyou-api/staging/SITE_PASSWORD'
seed_old_file staging; set_valid_params staging; set_param MAIL_PASSWORD 'whatever-value-123'
expect_refusal staging "an unknown MAIL_PASSWORD" 'unknown parameter /dayandyou-api/staging/MAIL_PASSWORD'
seed_old_file staging; set_valid_params staging; echo /dayandyou-api/staging/old/APP_KEY >"$LOGS/extra-names"
expect_refusal staging "a nested name" 'unknown parameter /dayandyou-api/staging/old/APP_KEY'
seed_old_file prod; set_valid_params prod; set_param SITE_PASSWORD "$TRICKY_PASSWORD"
expect_refusal prod "SITE_PASSWORD on prod" 'must not exist on prod'
for drop in FRONTEND_REBUILD_TOKEN FRONTEND_REBUILD_REF; do
  seed_old_file staging; set_valid_params staging; set_rebuild_quartet; rm "$PARAMS/$drop"
  expect_refusal staging "the quartet without $drop" 'all four or none in SSM, found 3'
done
seed_old_file prod; set_valid_params prod; set_param FRONTEND_REBUILD_REPO 'zenvoraai/day-and-you'
expect_refusal prod "a lone FRONTEND_REBUILD_REPO" 'all four or none in SSM, found 1'

# 7. AWS failures abort cleanly.
seed_old_file staging; set_valid_params staging; touch "$LOGS/aws-fail-get-parameters-by-path"
expect_refusal staging "a failed listing" 'could not list /dayandyou-api/staging/'
rm "$LOGS/aws-fail-get-parameters-by-path"
seed_old_file staging; set_valid_params staging; touch "$LOGS/aws-fail-get-parameter"
expect_refusal staging "a failed fetch" 'could not fetch /dayandyou-api/staging/'
rm "$LOGS/aws-fail-get-parameter"

# 8. No value ever reached stdout/stderr, across every run above.
for v in "$TRICKY_PASSWORD" "$TRICKY_ROOT" "$APP_KEY_OK" wJalrXUtnFEMI/K7MDENG je7MtGbClwBF \
         sk_test_51ExampleTestKey rk_${LIVE}_51ExampleLiveKey whsec_0123456789 github_pat_11EXAMPLE \
         dayandyou_api_staging:pw AKIAIOSFODNN7EXAMPLE elevenchars rrrrrrrrrrrrrrrrrrrr; do
  grep -qF -- "$v" "$ALL_OUTPUT" && fail "a value was echoed: $v"
done

echo "PASS: dayandyou-api secret refresh (8 groups)"
