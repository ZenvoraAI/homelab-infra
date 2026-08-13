#!/usr/bin/env bash
set -euo pipefail

# Pins the two layers that keep an anonymous loop from turning a public form
# into a free mail relay, and from locking that form for everybody else.
#
# Both were found broken on 2026-08-13:
#   - nginx had no rate limit on any email-sending endpoint
#   - TRUST_PROXY was exported by SecureVault's deploy workflow but never
#     declared in this repository's compose file, so it never reached the
#     container. express then saw 127.0.0.1 for every request and every one of
#     SecureVault's rate limiters bucketed all users together.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require() {
  local file="$1" pattern="$2"
  grep -Fq -- "$pattern" "$ROOT/$file" || {
    echo "missing in $file: $pattern" >&2
    exit 1
  }
}

# The shared zone must be declared in the http block, not a server block.
# shellcheck disable=SC2016  # $binary_remote_addr is an nginx variable and must be matched literally
require nginx/nginx.conf 'limit_req_zone $binary_remote_addr zone=email_ep:10m rate=5r/m;'

# SecureVault's two endpoints that send email without requiring a login.
# /api/auth/password-reset is a prefix match so it covers /request and /confirm.
#
# /api/contact must be the anchored regex, NOT `= /api/contact`: express runs
# with strict routing off, so POST /api/contact/ reaches the same handler and an
# exact-match location is bypassed by appending one slash. Verified against
# production before the fix: both spellings returned 400, i.e. both reached the
# app. Asserted here so the weaker form cannot come back.
require nginx/conf.d/valtou-api.conf 'location ^~ /api/auth/password-reset {'
require nginx/conf.d/valtou-api.conf 'location ~ ^/api/contact/?$ {'
grep -Fq 'location = /api/contact' "$ROOT/nginx/conf.d/valtou-api.conf" && {
  echo 'valtou-api.conf uses an exact-match /api/contact location, which /api/contact/ bypasses' >&2
  exit 1
}

count="$(grep -c 'limit_req zone=email_ep burst=3 nodelay;' "$ROOT/nginx/conf.d/valtou-api.conf")"
[ "$count" -eq 2 ] || {
  echo "expected 2 rate-limited locations in valtou-api.conf, found $count" >&2
  exit 1
}

# Without this the client sees nginx's default 503, which reads as an outage
# rather than "you are going too fast".
require nginx/conf.d/valtou-api.conf 'limit_req_status 429;'

# The passthrough that makes SecureVault's own limiters per-IP. A bare name in
# a compose `environment:` list forwards the value from the deploy shell; if
# the name is absent the variable is silently dropped.
require docker-compose.yml '- TRUST_PROXY'

echo 'PASS: email endpoint rate limiting'
