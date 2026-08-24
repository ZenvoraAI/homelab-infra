#!/usr/bin/env bash
set -euo pipefail

# admin.valtou.com and dayandyou.conf were the only two vhosts in conf.d/
# with no rate limiting or security headers at all (see the 2026-08-22
# hardening checklist). Pins that gap staying closed.

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

# shellcheck disable=SC2016
require nginx/conf.d/dayandyou.conf 'limit_req_zone $binary_remote_addr zone=dayandyou_general:10m rate=300r/m;'
count="$(grep -c 'limit_req zone=dayandyou_general burst=100 nodelay;' "$ROOT/nginx/conf.d/dayandyou.conf")"
[ "$count" -eq 2 ] || {
  echo "expected 2 rate-limited locations in dayandyou.conf (prod + staging), found $count" >&2
  exit 1
}

for file in nginx/conf.d/admin.valtou.com.conf nginx/conf.d/dayandyou.conf; do
  require "$file" 'add_header X-Content-Type-Options "nosniff" always;'
  require "$file" 'add_header X-Frame-Options "DENY" always;'
  require "$file" 'add_header Referrer-Policy "no-referrer" always;'
done

echo 'PASS: admin.valtou.com and dayandyou.com hardening'
