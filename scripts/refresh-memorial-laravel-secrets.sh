#!/bin/sh
set -eu

# Writes the Laravel memorial API's APP_KEY from SSM into the api.env it shares
# with the Express API (aiqiuqi-memorial). APP_KEY is Laravel's encrypter key:
# no session, JWT or cookie of the memorial depends on it, but the Laravel API
# refuses to boot without it. Express ignores the extra line.
#
# A separate script from refresh-memorial-secrets.sh on purpose: that one runs
# on every Express deploy, and a parameter it cannot read aborts it. Only the
# Laravel deploy (scripts/deploy-memorial-api-laravel.sh) runs this one, so the
# Express deploys keep working before and after /aiqiuqi-memorial/preview/APP_KEY
# exists. Never echoes the value.

# shellcheck source=scripts/lib/secret-file-lib.sh source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib/secret-file-lib.sh"

SECRETS_DIR=${SECRETS_DIR:-/opt/secrets/aiqiuqi-memorial}
ENV_FILE="$SECRETS_DIR/api.env"
# The memorial's one parameter path (the old "preview" name stayed when the
# preview environment was deleted; refresh-memorial-secrets.sh reads it too).
PARAM_PREFIX=/aiqiuqi-memorial/preview
PROFILE=${AWS_PROFILE:-memorial-ssm}
# Laravel's AES-256-CBC key: "base64:" + 32 random bytes.
APP_KEY_BYTES=32

fail() { echo "refresh-memorial-laravel-secrets: $*" >&2; exit 1; }

secretlib_refuse_canonical "$ENV_FILE"
test -f "$ENV_FILE" || fail "$ENV_FILE not found"

APP_KEY=$(aws ssm get-parameter --profile "$PROFILE" --with-decryption \
  --name "$PARAM_PREFIX/APP_KEY" --query Parameter.Value --output text 2>/dev/null) \
  || fail "$PARAM_PREFIX/APP_KEY is missing or unreadable; $ENV_FILE not touched"

# Shape only, never the value: "base64:" and a payload that decodes to exactly
# 32 bytes (what `php artisan key:generate --show` prints).
case "$APP_KEY" in
  base64:*) ;;
  *) fail "APP_KEY must start with base64: (generate it with php artisan key:generate --show); $ENV_FILE not touched" ;;
esac
payload=${APP_KEY#base64:}
printf '%s' "$payload" | grep -Eqx '[A-Za-z0-9+/]+={0,2}' \
  || fail "APP_KEY's payload is not base64; $ENV_FILE not touched"
decoded_bytes=$(printf '%s' "$payload" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
[ "$decoded_bytes" = "$APP_KEY_BYTES" ] \
  || fail "APP_KEY must decode to $APP_KEY_BYTES bytes (got $decoded_bytes); $ENV_FILE not touched"

# Unchanged: no rewrite, so the one backup (secret-file-lib) still holds the
# file as it was before the last real change.
if grep -qxF "APP_KEY=$APP_KEY" "$ENV_FILE" && [ "$(grep -c '^APP_KEY=' "$ENV_FILE")" = 1 ]; then
  echo "refresh-memorial-laravel-secrets: APP_KEY unchanged in $ENV_FILE"
  exit 0
fi

ORIG_OWNER=$(secretlib_orig_owner "$ENV_FILE")
BACKUP=$(secretlib_rotate_backup "$ENV_FILE" "$ORIG_OWNER")
TMP=$(mktemp)
grep -v '^APP_KEY=' "$ENV_FILE" > "$TMP" || true
(
  umask 077
  {
    cat "$TMP"
    printf 'APP_KEY=%s\n' "$APP_KEY"
  } > "$ENV_FILE.new"
)
rm -f "$TMP"
secretlib_finalize "$ENV_FILE" "$ORIG_OWNER"

echo "refresh-memorial-laravel-secrets: updated APP_KEY in $ENV_FILE (backup: $BACKUP)"
