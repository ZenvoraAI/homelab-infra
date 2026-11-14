#!/usr/bin/env bash
set -euo pipefail

# admin.valtou.com was one of the two vhosts in conf.d/ with no nginx-level
# rate limiting (see the 2026-08-22 hardening checklist; the other, the Day
# and You Next.js storefront's dayandyou.conf, was removed on 2026-11-15 when
# the storefront moved to S3 + CloudFront). Pins that gap staying closed.
#
# admin.valtou.com also gets nginx-level security headers, because
# zenvora-admin sets none of its own.

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

echo 'PASS: admin.valtou.com hardening'
