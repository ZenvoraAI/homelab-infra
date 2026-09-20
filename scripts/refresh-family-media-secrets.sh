#!/bin/sh
set -eu

# Pulls the cross-product RS256 handoff material out of SSM Parameter Store
# and writes it into the family-media API env file, so the private key never
# has to be hand-copied through a terminal again (that's what corrupted it
# before). Never echoes the fetched values.

. "$(dirname -- "$0")/lib/secret-file-lib.sh"

ENV_FILE=/opt/secrets/family-media/.env
PARAM_PREFIX=/family-media/prod
PROFILE=${AWS_PROFILE:-family-ssm}

test -f "$ENV_FILE" || { echo "refresh-family-media-secrets: $ENV_FILE not found" >&2; exit 1; }

# Preserve the original owner: this script runs via sudo, and docker compose
# (which reads this file) does not, so a root-owned rewrite would lock
# compose out of a file it could read a moment ago.
ORIG_OWNER=$(secretlib_orig_owner "$ENV_FILE")

FM_HANDOFF_PRIVATE_KEY_PEM=$(aws ssm get-parameter --profile "$PROFILE" --with-decryption \
  --name "$PARAM_PREFIX/FM_HANDOFF_PRIVATE_KEY_PEM" \
  --query Parameter.Value --output text)
FM_HANDOFF_KEY_ID=$(aws ssm get-parameter --profile "$PROFILE" \
  --name "$PARAM_PREFIX/FM_HANDOFF_KEY_ID" \
  --query Parameter.Value --output text)

# --- Strict validation: any failure exits 1, writes no secret material,
# and leaves $ENV_FILE untouched (we haven't created .new yet).
test -n "$FM_HANDOFF_KEY_ID" || { echo "refresh-family-media-secrets: empty FM_HANDOFF_KEY_ID from SSM -- aborting, $ENV_FILE not touched" >&2; exit 1; }

case "$FM_HANDOFF_PRIVATE_KEY_PEM" in
  *"-----BEGIN"*"PRIVATE KEY"*"-----END"*) ;;
  *) echo "refresh-family-media-secrets: fetched FM_HANDOFF_PRIVATE_KEY_PEM doesn't look like a PEM (missing BEGIN/PRIVATE KEY/END) -- aborting, $ENV_FILE not touched" >&2; exit 1 ;;
esac

# An exposed private key must actually stop existing on disk once rotated,
# not just stop being trusted by memorial (that only affects future
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
  /^FM_HANDOFF_PRIVATE_KEY_PEM=/ { skipping = 1 }
  skipping { if ($0 ~ /-----END.*PRIVATE KEY-----/) skipping = 0; next }
  /^FM_HANDOFF_KEY_ID=/ { next }
  # Retired single-site vars: the API no longer reads them (the handoff target
  # and audience come from the MemorialPerson row). Strip any leftover lines so
  # a stale value cannot linger in the env file; nothing writes them back.
  /^MEMORIAL_HANDOFF_BASE_URL=/ { next }
  /^MEMORIAL_HANDOFF_AUDIENCE=/ { next }
  /^MEMORIAL_WEB_ORIGIN=/ { next }
  { print }
' "$ENV_FILE" > "$TMP"
(
  umask 077
  {
    cat "$TMP"
    printf 'FM_HANDOFF_KEY_ID=%s\n' "$FM_HANDOFF_KEY_ID"
    printf 'FM_HANDOFF_PRIVATE_KEY_PEM=%s\n' "$FM_HANDOFF_PRIVATE_KEY_PEM"
  } > "$ENV_FILE.new"
)
rm -f "$TMP"
secretlib_finalize "$ENV_FILE" "$ORIG_OWNER"

echo "refresh-family-media-secrets: updated 2 handoff vars in $ENV_FILE (backup: $BACKUP)"
