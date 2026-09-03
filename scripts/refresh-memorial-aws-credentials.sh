#!/bin/sh
set -eu

# Pulls the memorial API and worker AWS credentials out of SSM Parameter Store
# and writes them into their env files. Never echoes the fetched values.
#
# Why this exists: both containers ran for weeks with the literal placeholder
# text from the setup notes as their AWS_ACCESS_KEY_ID. Every media upload
# failed, and nothing said so -- the admin UI had no upload entry point at the
# time, so no one exercised the path. Hand-filled secrets are the failure mode;
# this removes the hand.
#
# The validation below is the actual guard. Fetching from SSM only moves where
# the value is typed; refusing to write a value that is not shaped like an AWS
# key is what makes the placeholder impossible to install a second time. It runs
# BEFORE anything is written, so a bad parameter leaves both env files untouched.
#
# The API and the worker deliberately use different IAM users -- qiuqi-api can
# reach memorial/staging and memorial/originals, the worker memorial/originals
# and memorial/derived -- so each has its own pair of parameters.
#
# Usage, on the host:
#   sudo AWS_PROFILE=memorial-ssm ./refresh-memorial-aws-credentials.sh
#   cd /opt/homelab-infra && sudo docker compose up -d --force-recreate memorial-api memorial-worker
#
# The recreate is not optional: docker compose reads env_file at container
# creation, so an updated file changes nothing until the container is replaced.

. "$(dirname -- "$0")/lib/secret-file-lib.sh"

SECRETS_DIR=${SECRETS_DIR:-/opt/secrets/aiqiuqi-memorial}
PARAM_PREFIX=${PARAM_PREFIX:-/aiqiuqi-memorial/preview}
PROFILE=${AWS_PROFILE:-memorial-ssm}

# service:env-file:ssm-parameter-prefix
TARGETS="api:${SECRETS_DIR}/api.env:API worker:${SECRETS_DIR}/worker.env:WORKER"

fail() { echo "refresh-memorial-aws-credentials: $*" >&2; exit 1; }

command -v aws >/dev/null || fail "aws CLI not found"

# The usage line above says sudo, because writing the 0600 env files requires it.
# But sudo also replaces HOME with root's, and the aws CLI resolves ~/.aws from
# HOME -- so the profile fails with "could not be found", which reads like a
# missing profile rather than a lost search path and sends you looking in the
# wrong place. Point it back at the invoking user's files. Explicit values still
# win, so either can be overridden.
if [ -n "${SUDO_USER:-}" ]; then
  sudo_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
  [ -n "$sudo_home" ] || sudo_home="/home/$SUDO_USER"
  : "${AWS_SHARED_CREDENTIALS_FILE:=$sudo_home/.aws/credentials}"
  : "${AWS_CONFIG_FILE:=$sudo_home/.aws/config}"
  export AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
fi

ssm_get() {
  aws ssm get-parameter --profile "$PROFILE" --with-decryption \
    --name "$PARAM_PREFIX/$1" --query Parameter.Value --output text 2>/dev/null || true
}

# An AWS access key id is AKIA followed by 16 uppercase alphanumerics. The
# placeholder was Chinese text; so would be "changeme", "TODO", or a truncated
# paste. All of them fail this.
valid_key_id() {
  printf '%s' "$1" | grep -Eq '^AKIA[0-9A-Z]{16}$'
}

# Secret access keys are 40 characters of base64 alphabet. Length alone catches
# a truncated copy, which is the failure that produces the most confusing
# symptom: a signature error rather than an obviously absent credential.
valid_secret() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9/+=]{40}$'
}

# ---------------------------------------------------------------------------
# Fetch and validate everything before writing anything.
# ---------------------------------------------------------------------------
for target in $TARGETS; do
  service=${target%%:*}
  rest=${target#*:}
  env_file=${rest%%:*}
  param=${rest#*:}

  test -f "$env_file" || fail "$env_file not found (service: $service)"

  key_id=$(ssm_get "${param}_AWS_ACCESS_KEY_ID")
  secret=$(ssm_get "${param}_AWS_SECRET_ACCESS_KEY")

  test -n "$key_id" || fail "$PARAM_PREFIX/${param}_AWS_ACCESS_KEY_ID is empty or unreadable"
  test -n "$secret" || fail "$PARAM_PREFIX/${param}_AWS_SECRET_ACCESS_KEY is empty or unreadable"

  # Report the shape, never the value.
  valid_key_id "$key_id" || fail "${param}_AWS_ACCESS_KEY_ID is not an AWS access key id (expected AKIA + 16 uppercase alphanumerics, got ${#key_id} characters). Nothing written."
  valid_secret "$secret" || fail "${param}_AWS_SECRET_ACCESS_KEY is not a 40-character AWS secret (got ${#secret} characters). Nothing written."

  eval "KEY_ID_${service}=\$key_id"
  eval "SECRET_${service}=\$secret"
done

# ---------------------------------------------------------------------------
# Write.
# ---------------------------------------------------------------------------
for target in $TARGETS; do
  service=${target%%:*}
  rest=${target#*:}
  env_file=${rest%%:*}

  eval "key_id=\$KEY_ID_${service}"
  eval "secret=\$SECRET_${service}"

  # This script runs under sudo; docker compose, which reads the file, does not.
  # A root-owned rewrite would lock compose out of a file it could read a moment
  # ago -- the same trap refresh-memorial-secrets.sh documents.
  orig_owner=$(secretlib_orig_owner "$env_file")

  # A rotated credential should stop existing on disk, not accumulate in
  # backups next to the file that replaced it -- keeps exactly one.
  backup=$(secretlib_rotate_backup "$env_file" "$orig_owner")

  tmp=$(mktemp)
  grep -v -E '^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)=' "$env_file" > "$tmp" || true
  (
    umask 077
    {
      cat "$tmp"
      printf 'AWS_ACCESS_KEY_ID=%s\n' "$key_id"
      printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$secret"
    } > "$env_file.new"
  )
  rm -f "$tmp"
  secretlib_finalize "$env_file" "$orig_owner"

  echo "refresh-memorial-aws-credentials: $env_file updated (key ...${key_id#????????????????}, backup: $backup)"
done

echo
echo "Recreate the containers -- an updated env_file does nothing until they are replaced:"
echo "  cd /opt/homelab-infra && sudo docker compose up -d --force-recreate memorial-api memorial-worker"
