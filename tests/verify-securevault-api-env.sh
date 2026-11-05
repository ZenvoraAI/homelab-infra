#!/usr/bin/env bash
set -euo pipefail

# Compose forwards to securevault-api only the names in its `environment:`
# list; an export in SecureVault's deploy.yml that is missing here never
# reaches the container (TRUST_PROXY and WEBAUTHN_* were each lost this way).
# Browser-extension sign-in needs two:
#   EXTENSION_IDS             -- without it /api/auth/extension/* answer 503
#   ALLOWED_EXTENSION_ORIGINS -- without it CORS refuses the extension's
#                                chrome-extension://<id> token exchange
# SecureVault's deploy exports both (the second derived from the first).
# Place photos (client-encrypted, stored in S3) need five more:
#   OBJECT_STORE                       -- s3 turns photos on; unset or off keeps them off
#   PHOTO_S3_BUCKET, PHOTO_S3_REGION   -- where the photos live
#   PHOTO_S3_ACCESS_KEY_ID/SECRET_...  -- the securevault-photos IAM user (p/* only)
# No AWS_* name may be forwarded: the host's AWS CLI runs on the deploy key,
# which the API must never hold.
# EXTENSION_SIGNIN_REQUIRED is deliberately absent: deploy.yml passes it only
# to the preflight with `docker compose run -e`.
#
# Pure repo test: reads only docker-compose.yml, never any value.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
REQUIRED="EXTENSION_IDS ALLOWED_EXTENSION_ORIGINS OBJECT_STORE PHOTO_S3_BUCKET PHOTO_S3_REGION PHOTO_S3_ACCESS_KEY_ID PHOTO_S3_SECRET_ACCESS_KEY"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# Bare names under services.securevault-api.environment (list form).
env_names() {
  awk '
    /^  securevault-api:[[:space:]]*$/ { in_svc = 1; next }
    in_svc && /^  [A-Za-z0-9_-]+:/ { in_svc = 0 }
    in_svc && /^    environment:/ { in_env = 1; next }
    in_env && /^    [A-Za-z_]/ { in_env = 0 }
    in_env && /^      - / { sub(/^      - /, ""); sub(/[[:space:]]*(#.*)?$/, ""); print }
  ' "$COMPOSE"
}

names="$(env_names)"
[ "$(printf '%s\n' "$names" | grep -c .)" -ge 20 ] || fail "parsed only $(printf '%s\n' "$names" | grep -c .) securevault-api env names -- parser broke?"
for name in $REQUIRED; do
  printf '%s\n' "$names" | grep -qx "$name" \
    || fail "securevault-api environment: is missing '- $name' (bare pass-through from the deploy shell)"
done
printf '%s\n' "$names" | grep -q '=' && fail "securevault-api environment: must stay bare pass-through names, no values"
printf '%s\n' "$names" | grep -q '^AWS_' && fail "securevault-api environment: must not forward any AWS_* name (deploy key stays on the host)"
printf '%s\n' "$names" | grep -qx EXTENSION_SIGNIN_REQUIRED && fail "EXTENSION_SIGNIN_REQUIRED belongs to the preflight run only"

echo "PASS: securevault-api receives $REQUIRED"
