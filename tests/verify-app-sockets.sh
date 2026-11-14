#!/usr/bin/env bash
set -euo pipefail

# Every host-network service shares 127.0.0.1, and a port published on
# 127.0.0.1 is reachable from all of them too. A co-tenant that reaches an app
# directly skips nginx's limit_req and forges the client-IP headers behind its
# login lockouts. So each app below serves HTTP only on a unix socket in its
# own volume, and that volume is the access boundary: only the app (rw, with
# LISTEN_SOCKET pointing into it) and nginx (ro) may mount it, and its vhost
# proxies only to the socket. The generic escapes (volumes_from, pid: host,
# privileged, binds of /run or /var/lib/docker) are refused for every service
# by verify-securevault-fpm-socket.sh. The PHP-FPM apps (FastCGI, socket path
# fixed by their image, no LISTEN_SOCKET) have their own tests:
# verify-securevault-fpm-socket.sh and verify-dayandyou-api-origin.sh.
#
# Pure repo test: reads only docker-compose.yml and the nginx config.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
# Every directory compose mounts into nginx lives under nginx/; the old-port
# search covers all of it, the vhosts are read from conf.d.
NGINX_ROOT="${NGINX_ROOT_UNDER_TEST:-$ROOT/nginx}"
NGINX_DIR="$NGINX_ROOT/conf.d"

# service volume socket-dir vhost old-port
APPS="api family-api-sock /run/family-api family-api.conf 4000
memorial-api memorial-api-sock /run/memorial-api api.aiqiuqi.com.conf 3001
zenvora-admin zenvora-admin-sock /run/zenvora-admin admin.valtou.com.conf 3100
dayandyou-staging dayandyou-staging-sock /run/dayandyou-staging dayandyou.conf 3002
dayandyou-prod dayandyou-prod-sock /run/dayandyou-prod dayandyou.conf 3003"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

code="$(sed -e 's/[[:space:]]*#.*$//' "$COMPOSE")"

# "<service> <line>" for every line under services.* naming a socket volume or LISTEN_SOCKET.
volumes_re="$(printf '%s\n' "$APPS" | awk '{ printf "%s%s", sep, $2; sep = "|" }')"
lines="$(printf '%s\n' "$code" | awk -v re="($volumes_re)|LISTEN_SOCKET" '
  /^services:/ { in_services = 1; next }
  /^[A-Za-z]/ { in_services = 0 }
  in_services && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); next }
  in_services && $0 ~ re { line = $0; sub(/^[[:space:]]+/, "", line); print svc " " line }
')"

expected=""
while read -r service volume dir vhost port; do
  expected="$expected$service - LISTEN_SOCKET=$dir/http.sock
$service - $volume:$dir
nginx - $volume:$dir:ro
"
  grep -q "^  $volume: {}\$" "$COMPOSE" || fail "top-level volumes: must declare $volume"

  conf="$NGINX_DIR/$vhost"
  proxies="$(sed -e 's/[[:space:]]*#.*$//' "$conf" | grep -oE 'proxy_pass[[:space:]]+[^;]+;' || true)"
  [ -n "$proxies" ] || fail "$vhost has no proxy_pass"
  # A vhost may serve several apps (dayandyou.conf: prod and staging); each of
  # its proxy_passes must go to the socket of one of them, and this app's
  # socket must be among them.
  vhost_sockets="$(printf '%s\n' "$APPS" | awk -v v="$vhost" '$4 == v { printf "%s%s", sep, $3; sep = "|" }')"
  printf '%s\n' "$proxies" | grep -vqxE "proxy_pass[[:space:]]+http://unix:($vhost_sockets)/http\\.sock:;" \
    && fail "$vhost proxies somewhere other than its apps' sockets ($vhost_sockets):\n$proxies"
  printf '%s\n' "$proxies" | grep -qxE "proxy_pass[[:space:]]+http://unix:$dir/http\\.sock:;" \
    || fail "$vhost never proxies to $service's socket unix:$dir/http.sock:"
  grep -rnE "(127\\.0\\.0\\.1|localhost|\\[::1\\]):$port([^0-9]|\$)" "$NGINX_ROOT" \
    && fail "an nginx config still proxies to $service's old TCP port $port"
  printf '%s\n' "$code" | awk -v svc="$service" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { cur = $1; sub(/:$/, "", cur); next }
    cur == svc && /^    ports:/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' && fail "$service must not publish a port (nginx reaches it over its socket)"
done <<< "$APPS"

[ "$(printf '%s\n' "$lines" | sort)" = "$(printf '%s' "$expected" | sort)" ] \
  || fail "only each app (rw, LISTEN_SOCKET=<dir>/http.sock) and nginx (:ro) may use its socket volume; found:\n$lines"

# family-media may key its login lockout on CF-Connecting-IP (CLIENT_IP_HEADER);
# a client-sent copy reaches nginx from any loopback co-tenant.
grep -qE '^[[:space:]]*proxy_set_header[[:space:]]+CF-Connecting-IP[[:space:]]+\$remote_addr;' "$NGINX_DIR/family-api.conf" \
  || fail "family-api.conf must overwrite CF-Connecting-IP with \$remote_addr"

echo "PASS: the family, memorial, admin and dayandyou apps are reached only over their unix sockets; only each app and nginx mount them"
