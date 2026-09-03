#!/bin/sh
set -eu

# Pulls the CloudFront media signing key pair out of SSM Parameter Store and
# writes it into the memorial-api env file, so the private key never has to
# be hand-copied through a terminal again (that's what corrupted it before).
# Never echoes the fetched values.

. "$(dirname -- "$0")/lib/secret-file-lib.sh"

ENV_FILE=/opt/secrets/aiqiuqi-memorial/api.env
PARAM_PREFIX=/aiqiuqi-memorial/preview
PROFILE=${AWS_PROFILE:-memorial-ssm}

test -f "$ENV_FILE" || { echo "refresh-memorial-secrets: $ENV_FILE not found" >&2; exit 1; }

# Preserve the original owner: this script runs via sudo, and docker compose
# (which reads this file) does not, so a root-owned rewrite would lock
# compose out of a file it could read a moment ago.
ORIG_OWNER=$(secretlib_orig_owner "$ENV_FILE")

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

# An exposed private key must actually stop existing on disk once rotated,
# not just stop being trusted by CloudFront (that only affects future
# signature validation) -- keeps exactly one backup.
BACKUP=$(secretlib_rotate_backup "$ENV_FILE" "$ORIG_OWNER")

TMP=$(mktemp)
# A previously-corrupted private key can span multiple physical lines (a
# hand-copy that picked up hard-wraps), so only the first of those lines
# matches a plain key-prefix filter — the rest would leak through as
# orphaned garbage. Strip the whole span between the key line and its own
# END marker, however many lines it occupies. The wildcard between END and
# PRIVATE KEY covers both PKCS1 ("END RSA PRIVATE KEY") and PKCS8 ("END
# PRIVATE KEY") -- getting this wrong silently drops every line after it.
awk '
  /^CLOUDFRONT_MEDIA_KEY_PAIR_ID=/ { next }
  /^CLOUDFRONT_MEDIA_PRIVATE_KEY=/ { skipping = 1 }
  skipping { if ($0 ~ /-----END.*PRIVATE KEY-----/) skipping = 0; next }
  { print }
' "$ENV_FILE" > "$TMP"
(
  umask 077
  {
    cat "$TMP"
    printf 'CLOUDFRONT_MEDIA_KEY_PAIR_ID=%s\n' "$KEY_PAIR_ID"
    printf 'CLOUDFRONT_MEDIA_PRIVATE_KEY=%s\n' "$PRIVATE_KEY"
  } > "$ENV_FILE.new"
)
rm -f "$TMP"
secretlib_finalize "$ENV_FILE" "$ORIG_OWNER"

echo "refresh-memorial-secrets: updated CLOUDFRONT_MEDIA_KEY_PAIR_ID and CLOUDFRONT_MEDIA_PRIVATE_KEY in $ENV_FILE (backup: $BACKUP)"
