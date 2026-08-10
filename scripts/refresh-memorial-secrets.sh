#!/bin/sh
set -eu

# Pulls the CloudFront media signing key pair out of SSM Parameter Store and
# writes it into the memorial-api env file, so the private key never has to
# be hand-copied through a terminal again (that's what corrupted it before).
# Never echoes the fetched values.

ENV_FILE=/opt/secrets/aiqiuqi-memorial/api.env
PARAM_PREFIX=/aiqiuqi-memorial/preview
PROFILE=${AWS_PROFILE:-memorial-ssm}

test -f "$ENV_FILE" || { echo "refresh-memorial-secrets: $ENV_FILE not found" >&2; exit 1; }

# Preserve the original owner: this script runs via sudo, and docker compose
# (which reads this file) does not, so a root-owned rewrite would lock
# compose out of a file it could read a moment ago.
ORIG_OWNER=$(stat -c '%u:%g' "$ENV_FILE")

KEY_PAIR_ID=$(aws ssm get-parameter --profile "$PROFILE" \
  --name "$PARAM_PREFIX/CLOUDFRONT_MEDIA_KEY_PAIR_ID" \
  --query Parameter.Value --output text)
PRIVATE_KEY=$(aws ssm get-parameter --profile "$PROFILE" --with-decryption \
  --name "$PARAM_PREFIX/CLOUDFRONT_MEDIA_PRIVATE_KEY" \
  --query Parameter.Value --output text)

test -n "$KEY_PAIR_ID" || { echo "refresh-memorial-secrets: empty CLOUDFRONT_MEDIA_KEY_PAIR_ID from SSM -- aborting" >&2; exit 1; }
case "$PRIVATE_KEY" in
  *"-----BEGIN"*"-----END"*) ;;
  *) echo "refresh-memorial-secrets: fetched private key doesn't look like a PEM (missing BEGIN/END) -- aborting, $ENV_FILE not touched" >&2; exit 1 ;;
esac

BACKUP="$ENV_FILE.bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp "$ENV_FILE" "$BACKUP"
chown "$ORIG_OWNER" "$BACKUP"
chmod 600 "$BACKUP"

TMP=$(mktemp)
# A previously-corrupted private key can span multiple physical lines (a
# hand-copy that picked up hard-wraps), so only the first of those lines
# matches a plain key-prefix filter — the rest would leak through as
# orphaned garbage. Strip the whole span between the key line and its own
# "-----END PRIVATE KEY-----" marker, however many lines it occupies.
awk '
  /^CLOUDFRONT_MEDIA_KEY_PAIR_ID=/ { next }
  /^CLOUDFRONT_MEDIA_PRIVATE_KEY=/ { skipping = 1 }
  skipping { if ($0 ~ /-----END PRIVATE KEY-----/) skipping = 0; next }
  { print }
' "$ENV_FILE" > "$TMP"
{
  cat "$TMP"
  printf 'CLOUDFRONT_MEDIA_KEY_PAIR_ID=%s\n' "$KEY_PAIR_ID"
  printf 'CLOUDFRONT_MEDIA_PRIVATE_KEY=%s\n' "$PRIVATE_KEY"
} > "$ENV_FILE.new"
rm -f "$TMP"
mv "$ENV_FILE.new" "$ENV_FILE"
chown "$ORIG_OWNER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "refresh-memorial-secrets: updated CLOUDFRONT_MEDIA_KEY_PAIR_ID and CLOUDFRONT_MEDIA_PRIVATE_KEY in $ENV_FILE (backup: $BACKUP)"
