#!/usr/bin/env bash
set -euo pipefail

# SecureVault's PHP-FPM speaks FastCGI, which has no authentication: whoever can
# connect sets PHP_VALUE / SCRIPT_FILENAME and runs code in the API container,
# with its JWT secret, database URL and S3 key. Every app here runs with
# network_mode: host, so 127.0.0.1 is shared by all of them: FPM must never be
# reached over TCP. It listens on a unix socket in the securevault-fpm volume,
# and that volume is the access boundary: only securevault-api (rw) and nginx
# (ro) may mount it.
#
# Pure repo test: reads only docker-compose.yml and the nginx config.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
NGINX="${NGINX_CONF_UNDER_TEST:-$ROOT/nginx/conf.d/valtou-api.conf}"
SOCKET_DIR=/run/securevault-fpm

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# "<service> <volume line>" for every services.*.volumes entry naming securevault-fpm.
mounts="$(awk '
  /^services:/ { in_services = 1; next }
  /^[A-Za-z]/ { in_services = 0 }
  in_services && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); next }
  in_services && /securevault-fpm/ && /^      - / { line = $0; sub(/^      - /, "", line); print svc " " line }
' "$COMPOSE")"

expected="nginx securevault-fpm:$SOCKET_DIR:ro
securevault-api securevault-fpm:$SOCKET_DIR"
[ "$(printf '%s\n' "$mounts" | sort)" = "$(printf '%s\n' "$expected" | sort)" ] \
  || fail "only securevault-api (rw) and nginx (:ro) may mount securevault-fpm at $SOCKET_DIR; found:\n$mounts"

grep -q '^  securevault-fpm: {}$' "$COMPOSE" || fail "top-level volumes: must declare securevault-fpm"

# Every other way to reach the volume or the socket. Comments are ignored; any
# other line naming the volume (long-form `source: securevault-fpm`, a second
# short-form mount, ...) must be one of the three lines checked above.
code="$(sed -e 's/[[:space:]]*#.*$//' "$COMPOSE")"
others="$(printf '%s\n' "$code" | grep 'securevault-fpm' \
  | grep -vxE "      - securevault-fpm:$SOCKET_DIR(:ro)?|  securevault-fpm: \{\}" || true)"
[ -z "$others" ] || fail "securevault-fpm appears outside the two allowed mounts:\n$others"
printf '%s\n' "$code" | grep -qE '^[[:space:]]+volumes_from:' && fail "volumes_from would hand a service the API's socket volume"
printf '%s\n' "$code" | grep -qE '^[[:space:]]+pid:[[:space:]]*"?host' && fail "pid: host exposes /proc/<pid>/root, and with it the socket"
printf '%s\n' "$code" | grep -qE '^[[:space:]]+privileged:[[:space:]]*true' && fail "a privileged service can reach every volume"
printf '%s\n' "$code" | grep -qE '(^|[[:space:]"])/(var/lib/docker|run)(/|:|"|$)' && fail "a bind of /var/lib/docker or /run reaches the volume's host path or the socket"
printf '%s\n' "$code" | grep -q 'FPM_LISTEN' && fail "no service may set or forward FPM_LISTEN (the image's socket is the only production listen)"

grep -qE '^[[:space:]]*set \$securevault_fpm unix:/run/securevault-fpm/fpm\.sock;' "$NGINX" \
  || fail "valtou-api.conf must point \$securevault_fpm at unix:$SOCKET_DIR/fpm.sock"
grep -E '^[[:space:]]*set \$securevault_fpm ' "$NGINX" | grep -vq 'unix:' \
  && fail "valtou-api.conf sets \$securevault_fpm to a TCP address"
# The include passes $securevault_fpm; any other fastcgi_pass target (localhost:9000,
# [::1]:9000, an upstream name) would be TCP.
grep -rhE '^[[:space:]]*fastcgi_pass[[:space:]]' "$ROOT/nginx" | grep -vqE '^[[:space:]]*fastcgi_pass[[:space:]]+(\$securevault_fpm|unix:/run/securevault-fpm/fpm\.sock);' \
  && fail "a fastcgi_pass points somewhere other than \$securevault_fpm (the unix socket)"

echo "PASS: FPM is reached only over its unix socket; only securevault-api and nginx mount it"
