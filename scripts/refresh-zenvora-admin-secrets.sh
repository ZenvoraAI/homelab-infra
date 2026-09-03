#!/bin/sh
set -eu

# Pulls zenvora-admin's secrets out of SSM Parameter Store into its env file,
# so they never have to be hand-copied through a terminal (that's what
# corrupted the memorial CloudFront key -- same failure mode, same fix).
# Non-secret static values (PORT, DB_PATH, DOCKER_PROXY_URL,
# GITHUB_APP_REDIRECT_URI) are not managed here -- they're set once when the
# env file is first created and don't rotate. Never echoes fetched values.

. "$(dirname -- "$0")/lib/secret-file-lib.sh"

ENV_FILE=/opt/secrets/zenvora-admin/.env
PARAM_PREFIX=/zenvora-admin/prod
PROFILE=${AWS_PROFILE:-zenvora-admin-ssm}
# Below this, a fetched value is almost certainly a truncated copy or
# leftover placeholder text rather than a real secret -- every key here is a
# generated token/key/password, none of which are this short in practice.
MIN_SECRET_LEN=8

test -f "$ENV_FILE" || { echo "refresh-zenvora-admin-secrets: $ENV_FILE not found -- create it with the static vars first" >&2; exit 1; }

# Preserve the original owner: this script runs via sudo, and docker compose
# (which reads this file) does not, so a root-owned rewrite would lock
# compose out of a file it could read a moment ago.
ORIG_OWNER=$(secretlib_orig_owner "$ENV_FILE")

KEYS="TOKEN_ENCRYPTION_KEY WHITELISTED_GITHUB_USER_ID GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET ALERT_CHECK_TOKEN GHCR_READ_TOKEN CLOUDFLARE_API_TOKEN SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_USER SMTP_PASS ALERT_EMAIL_FROM ALERT_EMAIL_TO"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

for key in $KEYS; do
  value=$(aws ssm get-parameter --profile "$PROFILE" --with-decryption \
    --name "$PARAM_PREFIX/$key" --query Parameter.Value --output text)
  test -n "$value" || { echo "refresh-zenvora-admin-secrets: empty $key from SSM -- aborting, $ENV_FILE not touched" >&2; exit 1; }
  value_len=$(printf '%s' "$value" | wc -c)
  [ "$value_len" -ge "$MIN_SECRET_LEN" ] || { echo "refresh-zenvora-admin-secrets: $key from SSM is only $value_len chars (expected >= $MIN_SECRET_LEN) -- looks truncated or a placeholder, aborting, $ENV_FILE not touched" >&2; exit 1; }
  printf '%s\n' "$value" > "$TMPDIR/$key"
done

# Shape check before writing anything -- catches a truncated/garbled fetch
# before it lands in the file the app actually reads.
case "$(cat "$TMPDIR/WHITELISTED_GITHUB_USER_ID")" in
  ''|*[!0-9]*) echo "refresh-zenvora-admin-secrets: WHITELISTED_GITHUB_USER_ID from SSM is not numeric -- aborting, $ENV_FILE not touched" >&2; exit 1 ;;
esac

# An exposed secret must actually stop existing on disk once rotated, not
# just stop being trusted by the app -- keeps exactly one backup.
BACKUP=$(secretlib_rotate_backup "$ENV_FILE" "$ORIG_OWNER")

# Drop any existing line for each managed key, then append the fresh values --
# leaves every static, non-secret line already in the file untouched.
FILTERED="$TMPDIR/filtered"
cp "$ENV_FILE" "$FILTERED"
for key in $KEYS; do
  grep -v "^${key}=" "$FILTERED" > "$FILTERED.next" || true
  mv "$FILTERED.next" "$FILTERED"
done

(
  umask 077
  {
    cat "$FILTERED"
    for key in $KEYS; do
      printf '%s=%s\n' "$key" "$(cat "$TMPDIR/$key")"
    done
  } > "$ENV_FILE.new"
)
secretlib_finalize "$ENV_FILE" "$ORIG_OWNER"

echo "refresh-zenvora-admin-secrets: updated $(printf '%s' "$KEYS" | wc -w) keys in $ENV_FILE (backup: $BACKUP)"
