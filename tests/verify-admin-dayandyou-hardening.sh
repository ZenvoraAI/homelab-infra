#!/usr/bin/env bash
set -euo pipefail

# admin.valtou.com and dayandyou.conf were the only two vhosts in conf.d/
# with no nginx-level rate limiting (see the 2026-08-22 hardening checklist).
# Pins that gap staying closed.
#
# admin.valtou.com also gets nginx-level security headers, because
# zenvora-admin sets none of its own. dayandyou.com does NOT get them here:
# day-and-you's next.config.ts already sends a more complete set (also
# Permissions-Policy, HSTS, CSP), and nginx's `add_header` only appends to
# upstream headers rather than replacing them -- adding the same ones here
# produced duplicate/conflicting values on the wire (two different
# Referrer-Policy values in one response), confirmed live on
# 2026-08-24 before this file was corrected.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require() {
  local file="$1" pattern="$2"
  grep -Fq -- "$pattern" "$ROOT/$file" || {
    echo "missing in $file: $pattern" >&2
    exit 1
  }
}

# shellcheck disable=SC2016  # $binary_remote_addr is an nginx variable and must be matched literally
require nginx/conf.d/admin.valtou.com.conf 'limit_req_zone $binary_remote_addr zone=admin_general:10m rate=120r/m;'
require nginx/conf.d/admin.valtou.com.conf 'limit_req zone=admin_general burst=40 nodelay;'
require nginx/conf.d/admin.valtou.com.conf 'add_header X-Content-Type-Options "nosniff" always;'
require nginx/conf.d/admin.valtou.com.conf 'add_header X-Frame-Options "DENY" always;'
require nginx/conf.d/admin.valtou.com.conf 'add_header Referrer-Policy "no-referrer" always;'

# shellcheck disable=SC2016
require nginx/conf.d/dayandyou.conf 'limit_req_zone $binary_remote_addr zone=dayandyou_general:10m rate=300r/m;'
count="$(grep -c 'limit_req zone=dayandyou_general burst=100 nodelay;' "$ROOT/nginx/conf.d/dayandyou.conf")"
[ "$count" -eq 2 ] || {
  echo "expected 2 rate-limited locations in dayandyou.conf (prod + staging), found $count" >&2
  exit 1
}
grep -Fq 'add_header' "$ROOT/nginx/conf.d/dayandyou.conf" && {
  echo "dayandyou.conf should not add_header its own security headers -- day-and-you's next.config.ts already sets a more complete set, and nginx add_header only appends rather than replacing, which produces duplicate/conflicting headers on the wire" >&2
  exit 1
}

echo 'PASS: admin.valtou.com and dayandyou.com hardening'
