#!/bin/sh
set -eu

# Pulls the CloudFront media signing key pair AND the cross-product
# RS256 handoff env block out of SSM Parameter Store and writes them
# into the memorial-api env file, so secrets and handoff config never
# have to be hand-copied through a terminal again (that's what
# corrupted them before). Never echoes the fetched values.
#
# Two groups are written here, on purpose, in one script:
#   - CloudFront: CLOUDFRONT_MEDIA_KEY_PAIR_ID + CLOUDFRONT_MEDIA_PRIVATE_KEY
#     (private key is multi-line; the awk span filter handles that).
#   - Handoff env: the six MEMORIAL_* variables the memorial readEnv()
#     treats as an all-or-nothing block (any one set ⇒ all six must
#     be present and well-formed at boot). Source of truth for which
#     six is apps/api/src/env.ts; if a future handoff variable is
#     added there it must also be added here AND the verify-handoff-env
#     doc test (tests/verify-handoff-env.sh) updated to match.

. "$(dirname -- "$0")/lib/secret-file-lib.sh"

# SECRETS_DIR is the standard override used by tests/verify-*.sh to point
# the script at a tmp checkout rather than the production secrets path;
# default is the same one refresh-memorial-aws-credentials.sh uses.
SECRETS_DIR=${SECRETS_DIR:-/opt/secrets/aiqiuqi-memorial}
ENV_FILE="$SECRETS_DIR/api.env"
PARAM_PREFIX=/aiqiuqi-memorial/preview
PROFILE=${AWS_PROFILE:-memorial-ssm}

test -f "$ENV_FILE" || { echo "refresh-memorial-secrets: $ENV_FILE not found" >&2; exit 1; }

# Preserve the original owner: this script runs via sudo, and docker compose
# (which reads this file) does not, so a root-owned rewrite would lock
# compose out of a file it could read a moment ago.
ORIG_OWNER=$(secretlib_orig_owner "$ENV_FILE")

# --- CloudFront media signing ------------------------------------------------
KEY_PAIR_ID=$(aws ssm get-parameter --profile "$PROFILE" \
  --name "$PARAM_PREFIX/CLOUDFRONT_MEDIA_KEY_PAIR_ID" \
  --query Parameter.Value --output text)
PRIVATE_KEY=$(aws ssm get-parameter --profile "$PROFILE" --with-decryption \
  --name "$PARAM_PREFIX/CLOUDFRONT_MEDIA_PRIVATE_KEY" \
  --query Parameter.Value --output text)

test -n "$KEY_PAIR_ID" || { echo "refresh-memorial-secrets: empty CLOUDFRONT_MEDIA_KEY_PAIR_ID from SSM -- aborting, $ENV_FILE not touched" >&2; exit 1; }
case "$PRIVATE_KEY" in
  *"-----BEGIN"*"-----END"*) ;;
  *) echo "refresh-memorial-secrets: fetched private key doesn't look like a PEM (missing BEGIN/END) -- aborting, $ENV_FILE not touched" >&2; exit 1 ;;
esac

# --- Handoff env block (memorial readEnv all-or-nothing gate) ----------------
MEMORIAL_HANDOFF_PUBLIC_KEYS=$(aws ssm get-parameter --profile "$PROFILE" --with-decryption \
  --name "$PARAM_PREFIX/MEMORIAL_HANDOFF_PUBLIC_KEYS" \
  --query Parameter.Value --output text)
MEMORIAL_HANDOFF_AUDIENCE=$(aws ssm get-parameter --profile "$PROFILE" \
  --name "$PARAM_PREFIX/MEMORIAL_HANDOFF_AUDIENCE" \
  --query Parameter.Value --output text)
MEMORIAL_WEB_ORIGIN=$(aws ssm get-parameter --profile "$PROFILE" \
  --name "$PARAM_PREFIX/MEMORIAL_WEB_ORIGIN" \
  --query Parameter.Value --output text)
MEMORIAL_SSO_FAMILY_ID=$(aws ssm get-parameter --profile "$PROFILE" \
  --name "$PARAM_PREFIX/MEMORIAL_SSO_FAMILY_ID" \
  --query Parameter.Value --output text)
MEMORIAL_HANDOFF_ALLOWED_ORIGIN=$(aws ssm get-parameter --profile "$PROFILE" \
  --name "$PARAM_PREFIX/MEMORIAL_HANDOFF_ALLOWED_ORIGIN" \
  --query Parameter.Value --output text)
MEMORIAL_SSO_SHARED_MEMBER_USERNAME=$(aws ssm get-parameter --profile "$PROFILE" \
  --name "$PARAM_PREFIX/MEMORIAL_SSO_SHARED_MEMBER_USERNAME" \
  --query Parameter.Value --output text)

# --- Validation: every failure exits 1 with no secret material echoed, and
# $ENV_FILE is NOT touched (we haven't created .new yet). The rules mirror
# memorial's readEnv() (apps/api/src/env.ts) so an SSM value that would
# fail the boot gate is rejected here, before the deploy ever rolls.

# MEMORIAL_HANDOFF_PUBLIC_KEYS must be a non-empty JSON array of {kid, pem}
# objects, each PEM containing a "BEGIN PUBLIC KEY" marker. Without this
# check, an SSM value like "TBD" or "[]" would silently write through and
# only surface at boot (memorial would fail-fast there) — better to fail
# at the refresh step with the exact name in the error.
case "$MEMORIAL_HANDOFF_PUBLIC_KEYS" in
  '') echo "refresh-memorial-secrets: empty MEMORIAL_HANDOFF_PUBLIC_KEYS from SSM -- aborting, $ENV_FILE not touched" >&2; exit 1 ;;
  *'BEGIN PUBLIC KEY'*) ;;
  *) echo "refresh-memorial-secrets: MEMORIAL_HANDOFF_PUBLIC_KEYS doesn't contain a PEM (missing BEGIN PUBLIC KEY) -- aborting, $ENV_FILE not touched" >&2; exit 1 ;;
esac
# JSON-shape sanity: an unparseable value or a non-array must not be
# written through. parseHandoffPublicKeys() would catch this at boot,
# but we want a clear refresh-time error instead of an opaque one.
# The portable sniff: the value must start with '[' and end with ']'
# after stripping surrounding whitespace. This is shape-only — the
# array-of-{kid,pem} rule is enforced by parseHandoffPublicKeys() at
# memorial boot.
trimmed=$(printf '%s' "$MEMORIAL_HANDOFF_PUBLIC_KEYS" | tr -d '[:space:]')
case "$trimmed" in
  '['*']') ;;
  *) echo "refresh-memorial-secrets: MEMORIAL_HANDOFF_PUBLIC_KEYS must be a JSON array (got shape that doesn't start with [ and end with ]) -- aborting, $ENV_FILE not touched" >&2; exit 1 ;;
esac

test -n "$MEMORIAL_HANDOFF_AUDIENCE" || { echo "refresh-memorial-secrets: empty MEMORIAL_HANDOFF_AUDIENCE from SSM -- aborting, $ENV_FILE not touched" >&2; exit 1; }
test -n "$MEMORIAL_SSO_FAMILY_ID" || { echo "refresh-memorial-secrets: empty MEMORIAL_SSO_FAMILY_ID from SSM -- aborting, $ENV_FILE not touched" >&2; exit 1; }
test -n "$MEMORIAL_SSO_SHARED_MEMBER_USERNAME" || { echo "refresh-memorial-secrets: empty MEMORIAL_SSO_SHARED_MEMBER_USERNAME from SSM -- aborting, $ENV_FILE not touched" >&2; exit 1; }
# Empty URL would not be caught by the http(s) case below — '' matches
# neither 'https://*' nor 'http://*' but only AFTER reaching that case;
# checking here gives a clearer name in the error.
test -n "$MEMORIAL_WEB_ORIGIN" || { echo "refresh-memorial-secrets: empty MEMORIAL_WEB_ORIGIN from SSM -- aborting, $ENV_FILE not touched" >&2; exit 1; }
test -n "$MEMORIAL_HANDOFF_ALLOWED_ORIGIN" || { echo "refresh-memorial-secrets: empty MEMORIAL_HANDOFF_ALLOWED_ORIGIN from SSM -- aborting, $ENV_FILE not touched" >&2; exit 1; }

# Both URLs must be http(s) — anything else (javascript:, file://, data:,
# plain garbage) would either break the bootstrap POST or the in-cluster
# callback. memorial's readEnv() rejects anything that isn't http(s) too.
case "$MEMORIAL_WEB_ORIGIN" in
  https://*|http://*) ;;
  *) echo "refresh-memorial-secrets: MEMORIAL_WEB_ORIGIN must start with https:// or http:// -- aborting, $ENV_FILE not touched" >&2; exit 1 ;;
esac

# MEMORIAL_HANDOFF_ALLOWED_ORIGIN has a stricter rule in memorial: it must
# be an exact https origin (pathname '/' or '', no query / fragment /
# userinfo). Refresh-time check uses awk to do a portable parse + the
# shape assertions, since `case` can't introspect URL components.
#
# Splitting strategy: the string MUST contain a '/' (it's the scheme/
# authority delimiter — without it, "https://app.family.valtou.com?x=1"
# would have nowhere to split authority from query, and would silently
# pass). We split on the FIRST '/' after the scheme into:
#   authority = <host-or-userinfo-or-port>,
#   rest      = <path> possibly followed by '?' or '#'.
# Anything after the first '?' or '#' is rejected outright; everything
# in `rest` between the leading '/' and that marker must be empty or
# exactly '/'. The authority must not contain '@' (userinfo), nor ':'
# (a port — origins have no port).
allowed_ok=$(printf '%s' "$MEMORIAL_HANDOFF_ALLOWED_ORIGIN" | awk '
  BEGIN { ok = 1 }
  !/^https:\/\// { ok = 0 }
  {
    u = $0
    # strip scheme
    sub(/^https:\/\//, "", u)

    # A bare "https://" with nothing after the scheme is illegal.
    if (u == "") { ok = 0 }

    # Reject userinfo / port inside the authority: any '@' anywhere in
    # the part BEFORE the first '/' (or in the whole string if there is
    # no '/') is userinfo; any ':' in that authority part is a port.
    # Use the first '/' as the authority delimiter.
    slash = index(u, "/")
    if (slash == 0) {
      authority = u
      rest = ""
    } else {
      authority = substr(u, 1, slash - 1)
      rest = substr(u, slash + 1)
    }
    if (index(authority, "@") > 0) ok = 0
    if (index(authority, ":") > 0) ok = 0

    # Reject query / fragment anywhere — including inside `rest`.
    if (index(u, "?") > 0) ok = 0
    if (index(u, "#") > 0) ok = 0

    # Reject path beyond '/'. `rest` is the part after the first '/',
    # already free of any '?' or '#' by the two checks above.
    if (rest != "" && rest != "/") ok = 0
  }
  END { print ok }
')
[ "$allowed_ok" = "1" ] || {
  echo "refresh-memorial-secrets: MEMORIAL_HANDOFF_ALLOWED_ORIGIN must be an exact https origin (no path beyond '/', no query, no fragment, no userinfo, no port) -- aborting, $ENV_FILE not touched" >&2
  exit 1
}

# --- Atomic rotate-and-write -------------------------------------------------

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
# The handoff block is plain single-line key=value, so a plain prefix
# filter is enough for those.
awk '
  /^CLOUDFRONT_MEDIA_KEY_PAIR_ID=/ { next }
  /^CLOUDFRONT_MEDIA_PRIVATE_KEY=/ { skipping = 1 }
  skipping { if ($0 ~ /-----END.*PRIVATE KEY-----/) skipping = 0; next }
  /^MEMORIAL_HANDOFF_PUBLIC_KEYS=/ { next }
  /^MEMORIAL_HANDOFF_AUDIENCE=/ { next }
  /^MEMORIAL_WEB_ORIGIN=/ { next }
  /^MEMORIAL_SSO_FAMILY_ID=/ { next }
  /^MEMORIAL_HANDOFF_ALLOWED_ORIGIN=/ { next }
  /^MEMORIAL_SSO_SHARED_MEMBER_USERNAME=/ { next }
  { print }
' "$ENV_FILE" > "$TMP"
(
  umask 077
  {
    cat "$TMP"
    printf 'CLOUDFRONT_MEDIA_KEY_PAIR_ID=%s\n' "$KEY_PAIR_ID"
    printf 'CLOUDFRONT_MEDIA_PRIVATE_KEY=%s\n' "$PRIVATE_KEY"
    printf 'MEMORIAL_HANDOFF_PUBLIC_KEYS=%s\n' "$MEMORIAL_HANDOFF_PUBLIC_KEYS"
    printf 'MEMORIAL_HANDOFF_AUDIENCE=%s\n' "$MEMORIAL_HANDOFF_AUDIENCE"
    printf 'MEMORIAL_WEB_ORIGIN=%s\n' "$MEMORIAL_WEB_ORIGIN"
    printf 'MEMORIAL_SSO_FAMILY_ID=%s\n' "$MEMORIAL_SSO_FAMILY_ID"
    printf 'MEMORIAL_HANDOFF_ALLOWED_ORIGIN=%s\n' "$MEMORIAL_HANDOFF_ALLOWED_ORIGIN"
    printf 'MEMORIAL_SSO_SHARED_MEMBER_USERNAME=%s\n' "$MEMORIAL_SSO_SHARED_MEMBER_USERNAME"
  } > "$ENV_FILE.new"
)
rm -f "$TMP"
secretlib_finalize "$ENV_FILE" "$ORIG_OWNER"

echo "refresh-memorial-secrets: updated CLOUDFRONT_MEDIA_KEY_PAIR_ID, CLOUDFRONT_MEDIA_PRIVATE_KEY, and 6 MEMORIAL_* handoff vars in $ENV_FILE (backup: $BACKUP)"
