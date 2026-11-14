#!/bin/sh
set -eu

# Writes SecureVault's (securevault-api, securevault-scheduler) whole runtime
# env file from SSM Parameter Store (/securevault/prod/<KEY>, SecureString),
# so no value is hand-copied through a terminal or passes through GitHub
# Actions. Same contract as refresh-dayandyou-api-secrets.sh: no static
# lines, the file is created on first run, and any problem exits non-zero
# with the existing file byte-identical. Never echoes a fetched value --
# errors name the key and the rule, not the value.
#
#   sudo -n /opt/homelab-infra/scripts/refresh-securevault-secrets.sh
#
# Run by SecureVault's deploy right after its `git pull`, before the image
# pull, the boot preflight, the backup and the migration.
#
# Fetch: one get-parameters-by-path listing of names (catches missing
# required keys and unknown extras), then one get-parameter per key, so each
# value comes back whole and the line-break check below actually sees it (see
# refresh-dayandyou-api-secrets.sh for why not one decrypting by-path call).
#
# File format: KEY='value'. Compose's env_file parser interpolates unquoted
# and double-quoted values ($VAR, ${VAR}) and treats " #" in an unquoted
# value as a comment; single-quoted values are taken literally (verified for
# dayandyou-api, compose v5.7.0). A single quote cannot be escaped inside
# single quotes, so values containing one are refused. Only the compose
# parser is relied on: the deploy's one-off containers use
# `docker compose run --rm`, never `docker run --env-file`.
#
# ALLOWED_EXTENSION_ORIGINS is not a parameter: it is derived here from
# EXTENSION_IDS (chrome-extension://<id> per id), as the deploy used to do,
# so the two can never disagree.

. "$(dirname -- "$0")/lib/secret-file-lib.sh"

# Comma lists are split with an unquoted expansion below; no value may glob.
set -f

NAME=refresh-securevault-secrets
# Each refused by the API's boot checks when missing in production, or set in
# production today and relied on (SMTP_*, EMAIL_FROM).
REQUIRED_KEYS="DATABASE_URL JWT_SECRET INHERITANCE_HINT_SECRET WEBAUTHN_RP_ID WEBAUTHN_ORIGINS ALLOWED_ORIGINS FRONTEND_URL CAPTCHA_SECRET SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_USER SMTP_PASS EMAIL_FROM"
# Unset falls back to the API's default (reCAPTCHA, /<locale>/forgot-password,
# extension sign-in answering 503, photos off).
OPTIONAL_KEYS="CAPTCHA_PROVIDER PASSWORD_RESET_PATH EXTENSION_IDS OBJECT_STORE"
# Google sign-in: all three or none.
GOOGLE_KEYS="GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REDIRECT_URI"
# Required exactly when OBJECT_STORE=s3. The securevault-photos IAM user's key
# (p/* only), never the host's deploy key.
PHOTO_KEYS="PHOTO_S3_BUCKET PHOTO_S3_REGION PHOTO_S3_ACCESS_KEY_ID PHOTO_S3_SECRET_ACCESS_KEY"
# BootChecks MIN_JWT_SECRET_LENGTH / MIN_HINT_SECRET_LENGTH.
MIN_APP_SECRET_LEN=32
MIN_AWS_SECRET_LEN=30

# SECRETS_DIR is the standard override used by tests/verify-*.sh to point
# the script at a scratch directory.
SECRETS_DIR=${SECRETS_DIR:-/opt/secrets/securevault}
ENV_FILE="$SECRETS_DIR/api.env"
PARAM_PREFIX=/securevault/prod
PROFILE=${AWS_PROFILE:-securevault-ssm}

die() { echo "$NAME: $* -- aborting, $ENV_FILE not touched" >&2; exit 1; }

[ "$#" -eq 0 ] || { echo "usage: $NAME (no arguments)" >&2; exit 2; }

KNOWN_KEYS="$REQUIRED_KEYS $OPTIONAL_KEYS $GOOGLE_KEYS $PHOTO_KEYS"

NL='
'
CR=$(printf '\r')

is_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# Compose runs as the sudo user (ubuntu), not root, and reads env files
# client-side: an existing file keeps its owner; a new one belongs to the
# user who invoked sudo.
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

list_names() {
  aws ssm get-parameters-by-path --profile "$PROFILE" --path "$PARAM_PREFIX" \
    --recursive --query 'Parameters[].Name' --output text \
    || die "could not list $PARAM_PREFIX/ in SSM (profile $PROFILE)"
}

count_present() { # keys present
  n=0
  for key in $1; do is_in "$key" "$2" && n=$((n + 1)); done
  echo "$n"
}

check_names() {
  present=''
  for name in $1; do
    [ "$name" = None ] && continue
    key=${name#"$PARAM_PREFIX"/}
    [ "$key" != "$name" ] || die "SSM listing returned a name outside $PARAM_PREFIX/"
    is_in "$key" "$KNOWN_KEYS" || die "unknown parameter $PARAM_PREFIX/$key -- add it to this script or delete it from SSM"
    present="$present $key"
  done
  for key in $REQUIRED_KEYS; do
    is_in "$key" "$present" || die "missing required parameter $PARAM_PREFIX/$key"
  done
  case "$(count_present "$GOOGLE_KEYS" "$present")" in
    0|3) ;;
    *) die "GOOGLE_* is all three or none in SSM, found $(count_present "$GOOGLE_KEYS" "$present")" ;;
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

# A bare https origin: lowercase host, optional non-default port (the parsed
# origin drops :443, so the API refuses it); no path, no trailing slash (BootChecks::webauthn compares entries to their parsed origin, which
# is lowercase). Production serves https only.
is_origin() {
  case "$1" in https://*) ;; *) return 1 ;; esac
  rest=${1#https://}
  case "$rest" in
    ''|*/*|*[!a-z0-9.:-]*|:*|*:443) return 1 ;;
  esac
  return 0
}

# WebAuthn refuses a ceremony whose origin host is neither the RP ID nor a
# subdomain of it, and a passkey registered under a wrong RP ID is dead for
# good, so a mismatch is refused here rather than discovered at sign-in.
check_rp_id_covers_origins() {
  rp=$(val WEBAUTHN_RP_ID)
  old_ifs=$IFS
  IFS=,
  for entry in $(val WEBAUTHN_ORIGINS); do
    entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$entry" ] && continue
    host=${entry#https://}
    host=${host%%:*}
    case "$host" in
      "$rp"|*."$rp") ;;
      *) IFS=$old_ifs; die "WEBAUTHN_ORIGINS has a host that is neither WEBAUTHN_RP_ID nor a subdomain of it" ;;
    esac
  done
  IFS=$old_ifs
}

# Comma-separated, entries trimmed like the API's list parser.
check_origin_list() {
  v=$(val "$1")
  found=0
  old_ifs=$IFS
  IFS=,
  for entry in $v; do
    entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$entry" ] && continue
    is_origin "$entry" || { IFS=$old_ifs; die "$1 entry $found is not a bare https origin (https://host[:port], lowercase, no path or trailing slash)"; }
    found=$((found + 1))
  done
  IFS=$old_ifs
  [ "$found" -ge 1 ] || die "$1 from SSM lists no origin"
}

check_https_url() {
  case "$(val "$1")" in https://?*) ;; *) die "$1 must start with https://" ;; esac
}

# WebAuthn binds the RP ID into every credential at registration: a bare
# lowercase domain, never a URL.
check_rp_id() {
  case "$(val WEBAUTHN_RP_ID)" in
    *[!a-z0-9.-]*|.*|*.|'') die "WEBAUTHN_RP_ID must be a bare lowercase domain (no scheme, port or path)" ;;
    *.*) ;;
    *) die "WEBAUTHN_RP_ID must be a bare lowercase domain (no scheme, port or path)" ;;
  esac
}

check_smtp() {
  case "$(val SMTP_PORT)" in
    ''|*[!0-9]*) die "SMTP_PORT must be a port number" ;;
  esac
  port=$(val SMTP_PORT)
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "SMTP_PORT must be a port number"
  case "$(val SMTP_SECURE)" in true|false) ;; *) die "SMTP_SECURE must be true or false" ;; esac
}

# Every id must be valid: the API silently drops an invalid one, which would
# leave sign-in off with no error.
check_extension_ids() {
  old_ifs=$IFS
  IFS=,
  for entry in $(val EXTENSION_IDS); do
    entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$entry" in
      *[!a-p]*|'') IFS=$old_ifs; die "EXTENSION_IDS entries must be 32 letters a-p (Chrome extension ids)" ;;
    esac
    [ "${#entry}" -eq 32 ] || { IFS=$old_ifs; die "EXTENSION_IDS entries must be 32 letters a-p (Chrome extension ids)"; }
  done
  IFS=$old_ifs
}

check_object_store() { # present
  mode=''
  is_in OBJECT_STORE "$1" && mode=$(val OBJECT_STORE)
  case "$mode" in
    s3)
      for key in $PHOTO_KEYS; do
        is_in "$key" "$1" || die "OBJECT_STORE=s3 needs $PARAM_PREFIX/$key"
      done
      min_len PHOTO_S3_SECRET_ACCESS_KEY "$MIN_AWS_SECRET_LEN" ;;
    off|'')
      [ "$(count_present "$PHOTO_KEYS" "$1")" -eq 0 ] || is_in OBJECT_STORE "$1" \
        || die "PHOTO_S3_* is set but OBJECT_STORE is not -- set OBJECT_STORE (s3 or off) or delete them" ;;
    *) die "OBJECT_STORE must be s3 or off (local-fs is development only)" ;;
  esac
}

validate() { # present
  for key in $1; do
    [ -s "$WORK_DIR/$key" ] || die "empty $key from SSM"
  done
  case "$(val DATABASE_URL)" in postgres://?*|postgresql://?*) ;; *) die "DATABASE_URL must start with postgres:// or postgresql://" ;; esac
  min_len JWT_SECRET "$MIN_APP_SECRET_LEN"
  min_len INHERITANCE_HINT_SECRET "$MIN_APP_SECRET_LEN"
  check_rp_id
  check_origin_list WEBAUTHN_ORIGINS
  check_origin_list ALLOWED_ORIGINS
  check_rp_id_covers_origins
  check_https_url FRONTEND_URL
  check_smtp
  if is_in CAPTCHA_PROVIDER "$1"; then
    case "$(val CAPTCHA_PROVIDER)" in recaptcha|turnstile|hcaptcha) ;; *) die "CAPTCHA_PROVIDER must be recaptcha, turnstile or hcaptcha" ;; esac
  fi
  if is_in PASSWORD_RESET_PATH "$1"; then
    case "$(val PASSWORD_RESET_PATH)" in /?*) ;; *) die "PASSWORD_RESET_PATH must start with /" ;; esac
  fi
  is_in GOOGLE_REDIRECT_URI "$1" && check_https_url GOOGLE_REDIRECT_URI
  is_in EXTENSION_IDS "$1" && check_extension_ids
  check_object_store "$1"
  return 0
}

extension_origins() {
  old_ifs=$IFS
  IFS=,
  out=''
  for entry in $(val EXTENSION_IDS); do
    entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    out="${out:+$out,}chrome-extension://$entry"
  done
  IFS=$old_ifs
  printf '%s' "$out"
}

ensure_dir() {
  [ -d "$SECRETS_DIR" ] && return
  (umask 077; mkdir -p "$SECRETS_DIR")
  chown "$1" "$SECRETS_DIR"
}

write_file() { # present
  (
    umask 077
    {
      echo "# Written by scripts/refresh-securevault-secrets.sh from SSM $PARAM_PREFIX/ -- do not hand-edit."
      for key in $KNOWN_KEYS; do
        is_in "$key" "$1" || continue
        printf "%s='%s'\n" "$key" "$(val "$key")"
      done
      if is_in EXTENSION_IDS "$1"; then
        printf "ALLOWED_EXTENSION_ORIGINS='%s'\n" "$(extension_origins)"
      fi
    } >"$ENV_FILE.new"
  )
}

ORIG_OWNER=$(resolve_owner)

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR" "$ENV_FILE.new"' EXIT
# The work dir holds plaintext values: a signal must not leave it behind.
trap 'exit 1' INT TERM HUP

NAMES=$(list_names)
PRESENT=$(check_names "$NAMES")
for key in $PRESENT; do
  fetch "$key"
done
validate "$PRESENT"

ensure_dir "$ORIG_OWNER"
write_file "$PRESENT"
# Runs on every deploy: when nothing changed, keep the existing file and its
# one backup, which then still holds the value before the last real rotation.
if [ -e "$ENV_FILE" ] && cmp -s "$ENV_FILE.new" "$ENV_FILE"; then
  rm -f "$ENV_FILE.new"
  echo "$NAME: $ENV_FILE unchanged ($(printf '%s' "$PRESENT" | wc -w | tr -d ' ') keys)"
  exit 0
fi
BACKUP=none
if [ -e "$ENV_FILE" ]; then
  BACKUP=$(secretlib_rotate_backup "$ENV_FILE" "$ORIG_OWNER")
fi
secretlib_finalize "$ENV_FILE" "$ORIG_OWNER"

echo "$NAME: wrote $(printf '%s' "$PRESENT" | wc -w | tr -d ' ') keys to $ENV_FILE (backup: $BACKUP)"
