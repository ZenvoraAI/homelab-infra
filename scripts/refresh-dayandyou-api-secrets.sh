#!/bin/sh
set -eu

# Writes the Day and You Laravel API's whole runtime env file from SSM
# Parameter Store (/dayandyou-api/<env>/<KEY>, SecureString), so no value is
# ever hand-copied through a terminal or exported by a deploy shell. Unlike
# zenvora-admin there are no static lines: every key comes from SSM and the
# file is created on first run. Never echoes a fetched value -- errors name
# the key and the rule, not the value.
#
#   sudo -n /opt/homelab-infra/scripts/refresh-dayandyou-api-secrets.sh staging
#
# Run by the API's deploy before it starts any container; any problem exits
# non-zero and leaves the existing env file byte-identical.
#
# Fetch: one get-parameters-by-path listing of names (catches missing
# required keys and unknown extras, which per-key fetches alone cannot see),
# then one get-parameter per key. A single by-path call with decryption would
# return every value in one response, but with aws-cli v1's text output a
# value's newline is indistinguishable from the record separator, and parsing
# its JSON output would need a JSON parser this script does not otherwise
# depend on. Per-key text output hands each value back whole, so the newline
# check below actually sees it. ~20 calls, a few seconds, once per deploy.
#
# File format: KEY='value'. Compose's env_file parser (v2.24+, so v5 on the
# host) interpolates unquoted and double-quoted values ($VAR, ${VAR}) and
# treats " #" in an unquoted value as a comment; single-quoted values are
# taken literally. Verified 2026-11-14 with compose v5.7.0: an env_file of
# A='p$a#s"s w=rd', B='abc${HOME}', 'back\slash\n', '$$double', 'x=y=z',
# '#leading', ' with # hash  ' printed byte-identical from inside the
# container via `docker compose run --rm`, while the unquoted and
# double-quoted forms lost "$a" and expanded ${HOME}. A file written by this
# script (stubbed aws, 22 keys incl. '$', '$$', ' lead and trail ', '\n'
# literal) also came through `docker compose run --rm` of
# dayandyou-api-staging byte-exact. A single quote cannot
# be escaped inside single quotes, so values containing one are refused.
# Only the compose parser is relied on: the API deploy's one-off containers
# use `docker compose run --rm` (same parser), never `docker run --env-file`,
# which keeps the quotes as part of the value.

. "$(dirname -- "$0")/lib/secret-file-lib.sh"

NAME=refresh-dayandyou-api-secrets
# DAYANDYOU_ROOT_SECRET is the storefront's NEXTAUTH_SECRET value (stored TOTP
# secrets, checkout-token key): not rotatable without a re-encryption migration.
REQUIRED_KEYS="DATABASE_URL DAYANDYOU_ROOT_SECRET APP_KEY APP_URL STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET SITE_MODE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_S3_BUCKET ASSET_BASE_URL AWS_SES_REGION AWS_SES_ACCESS_KEY_ID AWS_SES_SECRET_ACCESS_KEY AWS_SES_FROM ADMIN_EMAIL"
# The API treats any set SITE_PASSWORD as the staging Basic-auth gate; unset on
# staging it serves ungated (the staging deploy stops the service if its probe
# gets through without credentials).
STAGING_ONLY_KEYS="SITE_PASSWORD"
# Static-storefront rebuild after product edits (the scheduler sends the
# debounced dispatch): the API enables it only with all four set.
OPTIONAL_GROUP_KEYS="FRONTEND_REBUILD_TOKEN FRONTEND_REBUILD_REPO FRONTEND_REBUILD_WORKFLOW FRONTEND_REBUILD_REF"
# Below these, a value is almost certainly truncated or a placeholder.
MIN_ROOT_SECRET_LEN=32
MIN_SITE_PASSWORD_LEN=12
MIN_AWS_SECRET_LEN=30
# base64 of 32 random bytes: 43 characters plus one '=' pad.
APP_KEY_B64_LEN=44

die() { echo "$NAME: $* -- aborting, $ENV_FILE not touched" >&2; exit 1; }

usage() { echo "usage: $NAME <staging|prod>" >&2; exit 2; }

[ "$#" -eq 1 ] || usage
APP_ENV=$1
case "$APP_ENV" in
  staging) EXPECTED_ASSET_BASE_URL=https://staging.dayandyou.com/media ;;
  prod) EXPECTED_ASSET_BASE_URL=https://dayandyou.com/media ;;
  *) usage ;;
esac

# SECRETS_DIR is the standard override used by tests/verify-*.sh to point
# the script at a scratch directory.
SECRETS_DIR=${SECRETS_DIR:-/opt/secrets/dayandyou-api}
ENV_FILE="$SECRETS_DIR/$APP_ENV.env"
PARAM_PREFIX="/dayandyou-api/$APP_ENV"
PROFILE=${AWS_PROFILE:-dayandyou-api-ssm}

KNOWN_KEYS="$REQUIRED_KEYS $OPTIONAL_GROUP_KEYS"
[ "$APP_ENV" = staging ] && KNOWN_KEYS="$REQUIRED_KEYS $STAGING_ONLY_KEYS $OPTIONAL_GROUP_KEYS"

NL='
'
CR=$(printf '\r')

is_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# Compose runs as the sudo user (ubuntu), not root, and reads env files
# client-side: an existing file keeps its owner; a new one belongs to the
# user who invoked sudo. Without that user there is nobody to hand it to.
resolve_owner() {
  if [ -e "$ENV_FILE" ]; then
    secretlib_orig_owner "$ENV_FILE"
    return
  fi
  case "${SUDO_USER:-}" in
    ''|root) die "$ENV_FILE does not exist yet and SUDO_USER is unset or root -- run it with sudo as the user docker compose runs as" ;;
  esac
  uid=$(id -u "$SUDO_USER") || die "cannot resolve uid of SUDO_USER"
  gid=$(id -g "$SUDO_USER") || die "cannot resolve gid of SUDO_USER"
  printf '%s:%s\n' "$uid" "$gid"
}

# Names only (no decryption): parameter names cannot contain whitespace, so
# splitting aws-cli's tab/newline-separated text output is safe. --recursive
# so a nested name (a typo'd extra path level) shows up as unknown too.
list_names() {
  aws ssm get-parameters-by-path --profile "$PROFILE" --path "$PARAM_PREFIX" \
    --recursive --query 'Parameters[].Name' --output text \
    || die "could not list $PARAM_PREFIX/ in SSM (profile $PROFILE)"
}

check_names() {
  present=''
  for name in $1; do
    [ "$name" = None ] && continue
    key=${name#"$PARAM_PREFIX"/}
    [ "$key" != "$name" ] || die "SSM listing returned a name outside $PARAM_PREFIX/"
    is_in "$key" "$KNOWN_KEYS" || {
      if [ "$APP_ENV" = prod ] && is_in "$key" "$STAGING_ONLY_KEYS"; then
        die "$PARAM_PREFIX/$key must not exist on prod (a set SITE_PASSWORD turns on the staging gate)"
      fi
      die "unknown parameter $PARAM_PREFIX/$key -- add it to this script or delete it from SSM"
    }
    present="$present $key"
  done
  required=$REQUIRED_KEYS
  [ "$APP_ENV" = staging ] && required="$REQUIRED_KEYS $STAGING_ONLY_KEYS"
  for key in $required; do
    is_in "$key" "$present" || die "missing required parameter $PARAM_PREFIX/$key"
  done
  group_count=0
  for key in $OPTIONAL_GROUP_KEYS; do
    is_in "$key" "$present" && group_count=$((group_count + 1))
  done
  case "$group_count" in
    0|4) ;;
    *) die "FRONTEND_REBUILD_* is all four or none in SSM, found $group_count" ;;
  esac
  printf '%s\n' "$present"
}

fetch() {
  value=$(aws ssm get-parameter --profile "$PROFILE" --with-decryption \
    --name "$PARAM_PREFIX/$1" --query Parameter.Value --output text) \
    || die "could not fetch $PARAM_PREFIX/$1 from SSM"
  case "$value" in
    *"$NL"*|*"$CR"*) die "$1 from SSM contains a line break" ;;
    *"'"*) die "$1 from SSM contains a single quote, which the env file format cannot carry" ;;
  esac
  printf '%s' "$value" >"$WORK_DIR/$1"
}

val() { cat "$WORK_DIR/$1"; }

min_len() {
  v=$(val "$1")
  [ "${#v}" -ge "$2" ] || die "$1 from SSM is only ${#v} chars (expected >= $2) -- looks truncated or a placeholder"
}

check_app_key() {
  v=$(val APP_KEY)
  case "$v" in base64:*) ;; *) die "APP_KEY must start with base64:" ;; esac
  b64=${v#base64:}
  [ "${#b64}" -eq "$APP_KEY_B64_LEN" ] || die "APP_KEY must be base64: plus $APP_KEY_B64_LEN characters (32 bytes), got ${#b64}"
  case "$b64" in
    *[!A-Za-z0-9+/=]*|*=?*) die "APP_KEY is not the base64 of 32 bytes" ;;
    *=) ;;
    *) die "APP_KEY is not the base64 of 32 bytes" ;;
  esac
}

check_stripe() {
  if [ "$APP_ENV" = staging ]; then
    case "$(val STRIPE_SECRET_KEY)" in sk_test_?*) ;; *) die "STRIPE_SECRET_KEY on staging must be a test key (sk_test_)" ;; esac
  else
    case "$(val STRIPE_SECRET_KEY)" in sk_live_?*|rk_live_?*) ;; *) die "STRIPE_SECRET_KEY on prod must be a live key (sk_live_ or rk_live_)" ;; esac
  fi
  case "$(val STRIPE_WEBHOOK_SECRET)" in whsec_?*) ;; *) die "STRIPE_WEBHOOK_SECRET must start with whsec_" ;; esac
}

validate() {
  for key in $1; do
    [ "$key" = SITE_MODE ] && continue
    [ -s "$WORK_DIR/$key" ] || die "empty $key from SSM"
  done
  case "$(val SITE_MODE)" in
    ''|live|coming-soon|maintenance) ;;
    *) die "SITE_MODE must be empty, live, coming-soon or maintenance" ;;
  esac
  check_stripe
  check_app_key
  case "$(val DATABASE_URL)" in postgres://?*|postgresql://?*) ;; *) die "DATABASE_URL must start with postgres:// or postgresql://" ;; esac
  case "$(val APP_URL)" in https://?*) ;; *) die "APP_URL must start with https://" ;; esac
  [ "$(val ASSET_BASE_URL)" = "$EXPECTED_ASSET_BASE_URL" ] || die "ASSET_BASE_URL on $APP_ENV must be exactly $EXPECTED_ASSET_BASE_URL"
  min_len DAYANDYOU_ROOT_SECRET "$MIN_ROOT_SECRET_LEN"
  min_len AWS_SECRET_ACCESS_KEY "$MIN_AWS_SECRET_LEN"
  min_len AWS_SES_SECRET_ACCESS_KEY "$MIN_AWS_SECRET_LEN"
  [ "$APP_ENV" = staging ] && min_len SITE_PASSWORD "$MIN_SITE_PASSWORD_LEN"
  return 0
}

# Same parent-dir rule as the file: 0700, owned by the compose user.
ensure_dir() {
  [ -d "$SECRETS_DIR" ] && return
  (umask 077; mkdir -p "$SECRETS_DIR")
  chown "$1" "$SECRETS_DIR"
}

write_file() {
  (
    umask 077
    {
      echo "# Written by scripts/refresh-dayandyou-api-secrets.sh from SSM $PARAM_PREFIX/ -- do not hand-edit."
      for key in $KNOWN_KEYS; do
        is_in "$key" "$1" || continue
        printf "%s='%s'\n" "$key" "$(val "$key")"
      done
    } >"$ENV_FILE.new"
  )
}

ORIG_OWNER=$(resolve_owner)

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR" "$ENV_FILE.new"' EXIT

NAMES=$(list_names)
PRESENT=$(check_names "$NAMES")
for key in $PRESENT; do
  fetch "$key"
done
validate "$PRESENT"

ensure_dir "$ORIG_OWNER"
BACKUP=none
if [ -e "$ENV_FILE" ]; then
  BACKUP=$(secretlib_rotate_backup "$ENV_FILE" "$ORIG_OWNER")
fi
write_file "$PRESENT"
secretlib_finalize "$ENV_FILE" "$ORIG_OWNER"

echo "$NAME: wrote $(printf '%s' "$PRESENT" | wc -w | tr -d ' ') keys to $ENV_FILE (backup: $BACKUP)"
