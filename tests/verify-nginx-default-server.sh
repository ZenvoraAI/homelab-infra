#!/usr/bin/env bash
set -euo pipefail

# Without a default_server, nginx sends a request whose Host/SNI matches no
# server_name to the first server block for that port -- alphabetically
# admin.valtou.com.conf. So https://<origin-ip>/ with any Host reached the
# admin panel, presented the admin.valtou.com certificate (tying the origin IP
# to that hostname for IP-scan indexes) and skipped Cloudflare entirely.
#
# Pins: exactly one catch-all on each of 80 and 443, that it closes the
# connection (444) and rejects the TLS handshake before presenting any
# certificate, and that no real vhost claims default_server instead.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_DIR="${NGINX_CONF_DIR_UNDER_TEST:-$ROOT/nginx/conf.d}"
DEFAULT="$CONF_DIR/00-default-server.conf"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

[ -f "$DEFAULT" ] || fail "missing ${DEFAULT#"$ROOT"/}"

# Strip comments so a commented-out directive does not count.
directives() { sed -e 's/#.*//' "$1"; }

for port in 80 443; do
  n=$(cat "$CONF_DIR"/*.conf | sed -e 's/#.*//' | grep -Ec "^[[:space:]]*listen[[:space:]]+$port([[:space:]]+[a-z_]+)*[[:space:]]+default_server" || true)
  [ "$n" = 1 ] || fail "expected exactly one 'listen $port … default_server' across conf.d, found $n"
  directives "$DEFAULT" | grep -Eq "^[[:space:]]*listen[[:space:]]+$port([[:space:]]+[a-z_]+)*[[:space:]]+default_server" \
    || fail "the $port default_server must be the catch-all in 00-default-server.conf"
done
directives "$DEFAULT" | grep -Eq '^[[:space:]]*listen[[:space:]]+443[[:space:]]+ssl[[:space:]]+default_server;' \
  || fail "443 catch-all must be 'listen 443 ssl default_server;'"
directives "$DEFAULT" | grep -Eq '^[[:space:]]*ssl_reject_handshake[[:space:]]+on;' \
  || fail "443 catch-all must reject the handshake (ssl_reject_handshake on;) instead of presenting a certificate"
directives "$DEFAULT" | grep -q 'ssl_certificate' \
  && fail "the catch-all must not present any certificate"
directives "$DEFAULT" | grep -Eq '^[[:space:]]*return[[:space:]]+444;' \
  || fail "catch-all must close the connection (return 444;)"
directives "$DEFAULT" | grep -Eq 'proxy_pass|root[[:space:]]|location' \
  && fail "the catch-all must not serve or proxy anything"
directives "$DEFAULT" | grep -Eq '^[[:space:]]*server_name[[:space:]]+_;' \
  || fail "catch-all must use server_name _; (never a real hostname)"

echo "PASS: unknown hosts get 444 / a rejected TLS handshake on 80 and 443"
