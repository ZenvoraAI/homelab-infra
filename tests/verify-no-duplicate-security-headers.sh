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

# FastCGI vhosts (SecureVault's Laravel API): the hides live in the shared
# include, because a location that sets any fastcgi_hide_header -- the include
# does -- inherits none from its server block. A server-level fastcgi_hide_header
# would be silently ignored (found 2026-11-11 by probing the new block).
INCLUDE="$ROOT/nginx/securevault/fastcgi-securevault.conf"
for file in "$ROOT"/nginx/conf.d/*.conf; do
  grep -q 'include /etc/nginx/securevault/fastcgi-securevault.conf;' "$file" || continue
  if grep -Eq '^    fastcgi_hide_header ' "$file"; then
    echo "${file#"$ROOT"/}: server-level fastcgi_hide_header is ignored by the include's locations; hide in ${INCLUDE#"$ROOT"/}" >&2
    status=1
  fi
  for header in X-Content-Type-Options X-Frame-Options Referrer-Policy; do
    if grep -q "add_header $header " "$file" && ! grep -q "^fastcgi_hide_header $header;" "$INCLUDE"; then
      echo "${file#"$ROOT"/}: adds $header but ${INCLUDE#"$ROOT"/} does not hide the API's copy" >&2
      status=1
    fi
  done
  # Every FastCGI location must go through the include, or it skips the hides.
  if grep -Eq '^\s*fastcgi_pass ' "$file"; then
    echo "${file#"$ROOT"/}: fastcgi_pass outside the shared include skips its header hides" >&2
    status=1
  fi
done

exit "$status"
