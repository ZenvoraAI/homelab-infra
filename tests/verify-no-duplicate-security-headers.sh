#!/usr/bin/env bash
set -euo pipefail

# nginx's add_header only appends to the upstream's headers. Every API behind
# these vhosts runs helmet, which already sends X-Content-Type-Options,
# X-Frame-Options (SAMEORIGIN) and Referrer-Policy, so each response carried
# two copies, two conflicting X-Frame-Options among them (securityheaders.com
# flagged api.valtou.com on 2026-10-30). Every server block that adds them must
# hide the upstream's copies.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

for file in "$ROOT"/nginx/conf.d/*.conf; do
  for header in X-Content-Type-Options X-Frame-Options Referrer-Policy; do
    added=$(grep -c "add_header $header " "$file" || true)
    hidden=$(grep -c "proxy_hide_header $header;" "$file" || true)
    if [ "$added" -gt 0 ] && [ "$added" != "$hidden" ] && grep -q proxy_pass "$file"; then
      echo "${file#"$ROOT"/}: $added add_header $header but $hidden proxy_hide_header" >&2
      status=1
    fi
  done
done

exit "$status"
