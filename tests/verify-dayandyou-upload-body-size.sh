#!/usr/bin/env bash
set -euo pipefail

# The Day and You admin accepts product images up to 5 MB (the API's
# MAX_SIZE_BYTES). nginx's default client_max_body_size is 1 MB, so without an
# explicit limit every image over 1 MB is refused with 413 before it reaches
# the app (measured on the old Next.js vhost 2026-10-29 and 2026-11-01). Pins a
# limit of at least 6 MB (5 MB file + multipart overhead) on the API origin's
# admin image-upload location, and keeps every other API location small.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$ROOT/nginx/conf.d/dayandyou-api-origin.conf"
MIN_MB=6

awk -v min="$MIN_MB" '
  /^[[:space:]]*#/ { next }
  /location[[:space:]].*\/api\/admin\/products\/.*\/images/ { in_upload = 1; next }
  in_upload && /client_max_body_size/ {
    v = $2; sub(/;$/, "", v)
    limit = (v ~ /^[0-9]+[mM]$/) ? v + 0 : 0
  }
  in_upload && /^[[:space:]]*\}/ { in_upload = 0; found = 1 }
  END {
    if (!found) { print "dayandyou-api-origin.conf: no admin image-upload location" > "/dev/stderr"; exit 1 }
    if (limit < min) { printf "dayandyou-api-origin.conf: the image-upload location needs client_max_body_size >= %dm\n", min > "/dev/stderr"; exit 1 }
  }
' "$CONF"

echo "PASS: the Day and You API origin accepts 5 MB admin image uploads"
