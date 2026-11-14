#!/usr/bin/env bash
set -euo pipefail

# Pins the two layers that keep an anonymous loop from turning a public form
# into a free mail relay, and from locking that form for everybody else.
#
# Both were found broken on 2026-08-13:
#   - nginx had no rate limit on any email-sending endpoint
#   - TRUST_PROXY was exported by SecureVault's deploy workflow but never
#     declared in this repository's compose file, so it never reached the
#     container. The API then saw 127.0.0.1 for every request and every one of
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
# /api/auth/password-reset is an unanchored-suffix regex so it covers /request
# and /confirm; both are case-insensitive (`~*`) because the Laravel API routes
# /API/auth/password-reset too, so a case-sensitive location would be bypassed
# by changing case. Regexes, not `^~` prefixes: every SecureVault location is
# a regex now, matched in file order, and these two come before the others.
#
# /api/contact must be the anchored regex, NOT `= /api/contact`: POST
# /api/contact/ reaches the same handler, so an exact-match location is
# bypassed by appending one slash. Asserted here so the weaker form cannot
# come back.
require nginx/conf.d/valtou-api.conf 'location ~* ^/api/auth/password-reset {'
require nginx/conf.d/valtou-api.conf 'location ~* ^/api/contact/?$ {'
grep -Eq 'location (=|\^~|~) /?\^?/api/(contact|auth/password-reset)' "$ROOT/nginx/conf.d/valtou-api.conf" && {
  echo 'valtou-api.conf has a case-sensitive, prefix or exact-match email location, which a case change or slash bypasses' >&2
  exit 1
}

# Those two must be the first SecureVault regexes after the /index.php guard:
# nginx uses the first matching regex, so a broader one above them would take
# the request without the rate limit.
first_two="$(grep -E '^    location ~' "$ROOT/nginx/conf.d/valtou-api.conf" | sed -n '2,3p')"
printf '%s\n' "$first_two" | grep -q 'password-reset' && printf '%s\n' "$first_two" | grep -q 'contact' || {
  echo 'the rate-limited email locations must be the first regexes after /index.php' >&2
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

# What makes SecureVault's own limiters per-IP. Now a literal in the compose
# `environment:` list, so no deploy shell can drop or blank it.
require docker-compose.yml '- TRUST_PROXY=1'

echo 'PASS: email endpoint rate limiting'
