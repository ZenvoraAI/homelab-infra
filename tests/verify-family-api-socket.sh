#!/usr/bin/env bash
set -euo pipefail

# family-media's API runs with network_mode: host, where 127.0.0.1 is shared by
# every host-network service. A co-tenant that reaches the API directly skips
# nginx's limit_req and can forge X-Forwarded-For / CF-Connecting-IP, the
# client address behind the per-IP login lockout. So the API serves HTTP only
# on a unix socket in the family-api-sock volume, and that volume is the access
# boundary: only api (rw) and nginx (ro) may mount it. The generic escapes
# (volumes_from, pid: host, privileged, binds of /run or /var/lib/docker) are
# refused for every service by verify-securevault-fpm-socket.sh.
#
# Pure repo test: reads only docker-compose.yml and the nginx config.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
NGINX="${NGINX_CONF_UNDER_TEST:-$ROOT/nginx/conf.d/family-api.conf}"
SOCKET_DIR=/run/family-api
SOCKET="$SOCKET_DIR/http.sock"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

code="$(sed -e 's/[[:space:]]*#.*$//' "$COMPOSE")"

# "<service> <line>" for every line under services.* naming the volume or the socket env.
lines="$(printf '%s\n' "$code" | awk '
  /^services:/ { in_services = 1; next }
  /^[A-Za-z]/ { in_services = 0 }
  in_services && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); next }
  in_services && /family-api-sock|LISTEN_SOCKET/ { line = $0; sub(/^[[:space:]]+/, "", line); print svc " " line }
')"

expected="api - LISTEN_SOCKET=$SOCKET
api - family-api-sock:$SOCKET_DIR
nginx - family-api-sock:$SOCKET_DIR:ro"
[ "$(printf '%s\n' "$lines" | sort)" = "$(printf '%s\n' "$expected" | sort)" ] \
  || fail "only api (rw, LISTEN_SOCKET=$SOCKET) and nginx (:ro) may use family-api-sock; found:\n$lines"

grep -q '^  family-api-sock: {}$' "$COMPOSE" || fail "top-level volumes: must declare family-api-sock"

proxies="$(grep -E '^[[:space:]]*(location .*)?proxy_pass[[:space:]]|[[:space:]]proxy_pass[[:space:]]' "$NGINX" \
  | sed -e 's/[[:space:]]*#.*$//' | grep -oE 'proxy_pass[[:space:]]+[^;]+;' || true)"
[ -n "$proxies" ] || fail "family-api.conf has no proxy_pass"
printf '%s\n' "$proxies" | grep -vqxE "proxy_pass[[:space:]]+http://unix:$SOCKET:;" \
  && fail "family-api.conf proxies somewhere other than unix:$SOCKET:\n$proxies"

grep -rnE '127\.0\.0\.1:4000|localhost:4000|\[::1\]:4000' "$ROOT/nginx" \
  && fail "an nginx config still proxies to the family API's old TCP port"

echo "PASS: the family API is reached only over its unix socket; only api and nginx mount it"
