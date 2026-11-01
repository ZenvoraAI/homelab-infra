#!/usr/bin/env bash
set -euo pipefail

# day-and-you accepts product images up to 5 MB
# (day-and-you/app/api/admin/products/[id]/images/route.ts). nginx's default
# client_max_body_size is 1 MB, so without an explicit limit every image over
# 1 MB is refused with 413 before it reaches the app (measured 2026-10-29 and
# 2026-11-01). Pins a limit of at least 6 MB (5 MB file + multipart overhead)
# in every dayandyou server block that proxies to the app.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$ROOT/nginx/conf.d/dayandyou.conf"
MIN_MB=6

awk -v min="$MIN_MB" '
  /^server[[:space:]]*\{/ { in_block = 1; name = ""; proxies = 0; limit = -1; next }
  in_block && /server_name/ { name = $2; sub(/;$/, "", name) }
  in_block && /proxy_pass/ { proxies = 1 }
  in_block && /client_max_body_size/ {
    v = $2; sub(/;$/, "", v)
    if (v ~ /^[0-9]+[mM]$/) { limit = v + 0 } else { limit = 0 }
  }
  in_block && /^\}/ {
    in_block = 0
    if (!proxies) next
    checked++
    if (limit < min) { printf "dayandyou.conf: server %s needs client_max_body_size >= %dm\n", name, min > "/dev/stderr"; bad = 1 }
  }
  END {
    if (checked < 2) { print "dayandyou.conf: expected prod and staging proxy blocks" > "/dev/stderr"; exit 1 }
    exit bad
  }
' "$CONF"

echo "PASS: dayandyou proxy blocks accept 5 MB image uploads"
