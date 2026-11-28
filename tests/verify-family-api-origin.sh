#!/usr/bin/env bash
# shellcheck disable=SC2016  # nginx variables are matched literally, never expanded
set -euo pipefail

# family-api.valtou.com is the family-media Laravel API's CloudFront origin (README "Family API on
# Laravel"). Its trust chain only holds if:
#   - a request without our distribution's origin secret, or without the CloudFront-Viewer-Address
#     that comes with it, is refused at server level, before any location and before limit_req,
#     so it never reaches PHP or a throttle bucket;
#   - the viewer address is derived only when the secret matched, with the port stripped;
#   - every throttle is keyed on that viewer, not on $remote_addr (a shared CloudFront edge), and
#     the argon2 routes go to the one-worker auth pool;
#   - the old Express entry is closed: no proxy_pass, and anything outside /api/ is a 404;
#   - the secret file reaches nginx only, read-only.
# The FastCGI include and the socket volume are pinned by verify-family-api-laravel.sh.
#
# Pure repo test: reads only docker-compose.yml and the nginx config.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
NGINX_ROOT="${NGINX_ROOT_UNDER_TEST:-$ROOT/nginx}"
VHOST="$NGINX_ROOT/conf.d/family-api.conf"
HTTP_CONF="$NGINX_ROOT/conf.d/00-family-cloudfront.conf"
INCLUDE_PATH=/etc/nginx/family/fastcgi-family-api.conf

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }
code() { sed -e 's/[[:space:]]*#.*$//' "$1"; }

for f in "$VHOST" "$HTTP_CONF"; do
  [ -f "$f" ] || fail "missing ${f#"$ROOT"/}"
done

# --- the 443 server block -------------------------------------------------------
tls_block="$(code "$VHOST" | awk '
  /^server[[:space:]]*\{/ { depth = 1; buf = ""; next }
  depth > 0 {
    buf = buf $0 "\n"
    n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); depth += n - m
    if (depth == 0) { if (buf ~ /listen[[:space:]]+443[[:space:]]+ssl/) printf "%s", buf; buf = "" }
  }
')"
[ -n "$tls_block" ] || fail "family-api.conf has no 'listen 443 ssl' server block"
code "$VHOST" | grep -qE 'proxy_pass' && fail "family-api.conf must not proxy anywhere (the Express entry is closed)"

# The two gates are the first statements that can act on a request: server level (4-space indent),
# before every location, and before any server-level limit_req.
first_location="$(printf '%s\n' "$tls_block" | grep -nE '^[[:space:]]*location[[:space:]]' | head -1 | cut -d: -f1 || true)"
[ -n "$first_location" ] || fail "the 443 block has no location"
for gate in 'if \(\$family_origin_ok != 1\) \{ return 403; \}' 'if \(\$family_client_ip = ""\) \{ return 403; \}'; do
  line="$(printf '%s\n' "$tls_block" | grep -nE "^    $gate\$" | head -1 | cut -d: -f1 || true)"
  [ -n "$line" ] || fail "the 443 block must refuse at server level: $gate"
  [ "$line" -lt "$first_location" ] || fail "the gate '$gate' must come before every location"
done
# Throttled requests must not write their raw request line (query strings) to the error log.
grep -qE '^    error_log /var/log/nginx/error\.log error;$' <<<"$tls_block" || fail "the 443 block must log errors at level error only"
grep -qE '^    limit_req_log_level (warn|notice|info);$' <<<"$tls_block" \
  || fail "limit_req_log_level must be below the error_log level (rejections log the raw request line)"
server_limit="$(printf '%s\n' "$tls_block" | grep -nE '^    limit_req[[:space:]]' | head -1 | cut -d: -f1 || true)"
[ -z "$server_limit" ] || fail "no server-level limit_req (the gates must decide before any throttle)"
printf '%s\n' "$tls_block" | grep -qE '^[[:space:]]*fastcgi_pass[[:space:]]' \
  && fail "family-api.conf must not fastcgi_pass directly (only through $INCLUDE_PATH)"
printf '%s\n' "$tls_block" | grep -E '^[[:space:]]*include[[:space:]]' | grep -vqE "include ($INCLUDE_PATH|/etc/letsencrypt/options-ssl-nginx\\.conf);" \
  && fail "family-api.conf may include only the family FastCGI include (and the TLS options)"

# Per location: its directives joined on one line.
locations="$(printf '%s\n' "$tls_block" | awk '
  /^    location[[:space:]]/ { in_loc = 1; loc = $0; next }
  in_loc && /^    \}/ { print loc; in_loc = 0; next }
  in_loc { loc = loc " " $0 }
')"
fcgi=0
while IFS= read -r loc; do
  sets=0; incs=0
  [[ "$loc" == *'set $family_api_fpm '* ]] && sets=1
  [[ "$loc" == *"include $INCLUDE_PATH;"* ]] && incs=1
  [ "$sets" = "$incs" ] || fail "a location sets the FPM socket without the include (or the reverse):\n$loc"
  if [ "$incs" = 1 ]; then
    fcgi=$((fcgi + 1))
    [[ "$loc" =~ ^\ \ \ \ location\ (~\*\ \^/api/|/api/) ]] || fail "only /api/ locations may reach PHP:\n$loc"
    [[ "$loc" == *'limit_req zone=fam_cf_'* ]] || fail "every FastCGI location must be throttled by a fam_cf_* zone:\n$loc"
  fi
done <<<"$locations"
[ "$fcgi" -ge 4 ] || fail "expected the API's 4 FastCGI locations in the 443 block, found $fcgi"

# The argon2 routes: auth pool and auth zone; nothing else uses the auth pool.
auth="$(grep -E '^    location ~\* \^/api/auth/\(login\|change-password\)/\*\$ \{' <<<"$locations" || true)"
[ -n "$auth" ] || fail "missing 'location ~* ^/api/auth/(login|change-password)/*\$' for the argon2 routes"
[[ "$auth" == *'set $family_api_fpm unix:/run/family-api-fpm/fpm-auth.sock;'* ]] || fail "the argon2 routes must run in the auth pool:\n$auth"
[[ "$auth" == *'limit_req zone=fam_cf_auth '* ]] || fail "the argon2 routes must use fam_cf_auth:\n$auth"
[ "$(grep -c 'fpm-auth.sock' <<<"$locations")" = 1 ] || fail "only the argon2 location may use the auth pool"
grep -E '^    location /api/auth/ \{' <<<"$locations" | grep -q 'limit_req zone=fam_cf_auth ' || fail "location /api/auth/ must use fam_cf_auth"

# Closed: metrics, the front controller and everything outside /api/.
for loc in '^    location \^~ /api/metrics \{.*return 404' '^    location ~\* /index\\\.php \{.*return 404' '^    location / \{.*return 404'; do
  grep -qE "$loc" <<<"$locations" || fail "the 443 block needs a 404 location matching: $loc"
done

# Throttle zones: keyed on the viewer only.
zones="$(code "$HTTP_CONF" | grep -E '^[[:space:]]*limit_(req|conn)_zone' || true)"
[ "$(printf '%s\n' "$zones" | grep -c 'zone=fam_cf_')" = 2 ] || fail "expected two fam_cf_* zones:\n$zones"
printf '%s\n' "$zones" | grep -vqE '^[[:space:]]*limit_req_zone[[:space:]]+\$family_client_ip[[:space:]]' \
  && fail "the fam_cf_* zones must be keyed on \$family_client_ip:\n$zones"
grep -rhE '^[[:space:]]*limit_req_zone[^#]*zone=fam_cf_' "$NGINX_ROOT" | grep -vq '\$family_client_ip' \
  && fail "a fam_cf_* zone is keyed on something other than \$family_client_ip"

# The viewer map: secret first, port stripped, empty otherwise.
http="$(code "$HTTP_CONF")"
grep -qE '^map "\$family_origin_ok\|\$http_cloudfront_viewer_address" \$family_client_ip \{$' <<<"$http" \
  || fail "\$family_client_ip must be mapped from the secret result AND the viewer address"
[ "$(awk '/^map "\$family_origin_ok/,/^}/' <<<"$http" | grep -cE '"~\^1\\\|')" = 2 ] \
  || fail "both viewer-address patterns must require the secret (^1|)"
awk '/^map "\$family_origin_ok/,/^}/' <<<"$http" | grep -qE '^[[:space:]]*default[[:space:]]+"";' \
  || fail "the viewer map must default to \"\" (refused by the vhost)"
grep -qE '^[[:space:]]*include /etc/nginx/family-secrets/origin-secret\.map;' <<<"$http" \
  || fail "00-family-cloudfront.conf must include the origin-secret map"
grep -qE '^map \$http_x_family_origin_secret \$family_origin_ok \{$' <<<"$http" \
  || fail "the origin secret is the X-Family-Origin-Secret header (the name the include blanks)"
grep -qE '^[[:space:]]*map_hash_bucket_size[[:space:]]+(128|256);' <<<"$(code "$NGINX_ROOT/nginx.conf")" \
  || fail "nginx.conf must set map_hash_bucket_size 128 for the origin-secret map"

# --- compose: the secret dir reaches nginx only, read-only ----------------------
COMPOSE="$COMPOSE" ruby -ryaml -e '
  services = YAML.load(File.read(ENV.fetch("COMPOSE"))).fetch("services")
  mounts = Array(services.dig("nginx", "volumes")).map(&:to_s)
  abort "FAIL: nginx must mount /opt/secrets/family-media-origin:/etc/nginx/family-secrets:ro" unless mounts.include?("/opt/secrets/family-media-origin:/etc/nginx/family-secrets:ro")
  abort "FAIL: nginx must mount the family FastCGI include dir read-only" unless mounts.include?("./nginx/family:/etc/nginx/family:ro")
'

echo "PASS: family-api.valtou.com refuses requests without the origin secret / viewer address before any throttle, passes PHP only the viewer IP, throttles per viewer, serves nothing but /api/"
