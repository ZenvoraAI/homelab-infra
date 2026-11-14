#!/usr/bin/env bash
# shellcheck disable=SC2016  # nginx variables are matched literally, never expanded
set -euo pipefail

# api-origin-staging.dayandyou.com is the Day and You API's CloudFront origin
# (README "Day and You API origin"). Its trust chain only holds if:
#   - a request without our distribution's origin secret, or without the
#     CloudFront-Viewer-Address that comes with it, is refused before any
#     location runs, so it never reaches PHP;
#   - PHP gets the viewer's address only as DAY_CLIENT_IP, and never sees the
#     secret, the raw viewer header or a forwarding header;
#   - every throttle is keyed on the viewer, not on $remote_addr (a CloudFront
#     edge shared by many customers);
#   - FastCGI is reachable only through the socket volume, mounted by the API
#     (rw) and nginx (ro), and the secret files reach nginx read-only.
# Staging only: no prod map may be included until the prod secret file exists,
# or nginx refuses to start. The storefront's dayandyou.conf stays as it was.
#
# Pure repo test: reads only docker-compose.yml and the nginx config.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
NGINX_ROOT="${NGINX_ROOT_UNDER_TEST:-$ROOT/nginx}"
VHOST="$NGINX_ROOT/conf.d/dayandyou-api-origin.conf"
HTTP_CONF="$NGINX_ROOT/conf.d/00-dayandyou-cloudfront.conf"
INCLUDE="$NGINX_ROOT/dayandyou/fastcgi-dayandyou-api-cloudfront.conf"
INCLUDE_PATH=/etc/nginx/dayandyou/fastcgi-dayandyou-api-cloudfront.conf
STOREFRONT="$NGINX_ROOT/conf.d/dayandyou.conf"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }
code() { sed -e 's/[[:space:]]*#.*$//' "$1"; }

for f in "$VHOST" "$HTTP_CONF" "$INCLUDE" "$STOREFRONT"; do
  [ -f "$f" ] || fail "missing ${f#"$ROOT"/}"
done

# --- the 443 server block -------------------------------------------------------
# Its depth-1 lines (server level) and, per location, its directives joined on one line.
tls_block="$(code "$VHOST" | awk '
  /^server[[:space:]]*\{/ { depth = 1; buf = ""; next }
  depth > 0 {
    buf = buf $0 "\n"
    n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); depth += n - m
    if (depth == 0) { if (buf ~ /listen[[:space:]]+443[[:space:]]+ssl/) printf "%s", buf; buf = "" }
  }
')"
[ -n "$tls_block" ] || fail "dayandyou-api-origin.conf has no 'listen 443 ssl' server block"

# The two gates must be the first server-level statements that can act on a request:
# before any location, set or include of FastCGI.
first_location="$(printf '%s\n' "$tls_block" | grep -nE '^[[:space:]]*location[[:space:]]' | head -1 | cut -d: -f1 || true)"
[ -n "$first_location" ] || fail "the 443 block has no location"
for gate in 'if \(\$dayandyou_origin_ok_staging != 1\) \{ return 403; \}' 'if \(\$dayandyou_viewer_ip = ""\) \{ return 403; \}'; do
  line="$(printf '%s\n' "$tls_block" | grep -nE "^    $gate\$" | head -1 | cut -d: -f1 || true)"
  [ -n "$line" ] || fail "the 443 block must refuse at server level: $gate"
  [ "$line" -lt "$first_location" ] || fail "the gate '$gate' must come before every location"
done
printf '%s\n' "$tls_block" | grep -qE '^[[:space:]]*fastcgi_pass[[:space:]]' \
  && fail "dayandyou-api-origin.conf must not fastcgi_pass directly (only through $INCLUDE_PATH)"
printf '%s\n' "$tls_block" | grep -qE 'fastcgi-dayandyou-api\.conf|fastcgi_params|fastcgi-securevault' \
  && fail "dayandyou-api-origin.conf may include only the CloudFront FastCGI include"
grep -qE '^[[:space:]]*set \$dayandyou_api_sock_dir /run/dayandyou-api-fpm-staging;' <<<"$tls_block" \
  || fail "the 443 block must set \$dayandyou_api_sock_dir /run/dayandyou-api-fpm-staging"

# Every location that sets an FPM socket includes the CloudFront include, and vice versa.
locations="$(printf '%s\n' "$tls_block" | awk '
  /^    location[[:space:]]/ { in_loc = 1; loc = $0; next }
  in_loc && /^    \}/ { print loc; in_loc = 0; next }
  in_loc { loc = loc " " $0 }
')"
fcgi=0
while IFS= read -r loc; do
  sets=0; incs=0
  [[ "$loc" == *'set $dayandyou_api_fpm '* ]] && sets=1
  [[ "$loc" == *"include $INCLUDE_PATH;"* ]] && incs=1
  [ "$sets" = "$incs" ] || fail "a location sets the FPM socket without the CloudFront include (or the reverse):\n$loc"
  fcgi=$((fcgi + incs))
done <<<"$locations"
[ "$fcgi" -ge 6 ] || fail "expected the API's 6 FastCGI locations in the 443 block, found $fcgi"

# Throttles: only the viewer-keyed zones, and those keyed on the viewer.
limits="$(printf '%s\n' "$tls_block" | grep -E '^[[:space:]]*limit_(req|conn)[[:space:]]' || true)"
[ -n "$limits" ] || fail "the 443 block has no limit_req/limit_conn"
printf '%s\n' "$limits" | grep -vqE '^[[:space:]]*limit_(req[[:space:]]+zone=|conn[[:space:]]+)dayandyou_cf_[a-z_]+[[:space:]]' \
  && fail "every throttle in the 443 block must use a dayandyou_cf_* zone:\n$limits"
zones="$(code "$HTTP_CONF" | grep -E '^[[:space:]]*limit_(req|conn)_zone' || true)"
[ "$(printf '%s\n' "$zones" | grep -c 'zone=dayandyou_cf_')" = 4 ] || fail "expected four dayandyou_cf_* zones:\n$zones"
printf '%s\n' "$zones" | grep -vqE '^[[:space:]]*limit_(req|conn)_zone[[:space:]]+\$dayandyou_viewer_ip[[:space:]]' \
  && fail "the dayandyou_cf_* zones must be keyed on \$dayandyou_viewer_ip:\n$zones"

# --- the FastCGI include --------------------------------------------------------
inc="$(code "$INCLUDE")"
for param in 'DAY_CLIENT_IP \$dayandyou_viewer_ip' 'HTTP_X_DAYANDYOU_ORIGIN_SECRET ""' \
             'HTTP_CLOUDFRONT_VIEWER_ADDRESS ""' 'HTTP_X_FORWARDED_FOR ""' 'HTTP_X_REAL_IP ""'; do
  [ "$(grep -cE "^fastcgi_param $param;\$" <<<"$inc")" = 1 ] || fail "the include must set exactly once: fastcgi_param $param;"
done
[ "$(grep -cE '^fastcgi_param DAY_CLIENT_IP ' <<<"$inc")" = 1 ] || fail "DAY_CLIENT_IP must be set exactly once"
grep -qE '^fastcgi_pass \$dayandyou_api_fpm;$' <<<"$inc" || fail "the include must fastcgi_pass \$dayandyou_api_fpm"
grep -qE '^include fastcgi_params;$' <<<"$inc" || fail "the include must load fastcgi_params (its params are then overridden)"
# fastcgi_params comes first, so the blanks above override anything it sets.
[ "$(grep -n '^include fastcgi_params;' <<<"$inc" | cut -d: -f1)" -lt "$(grep -n '^fastcgi_param DAY_CLIENT_IP' <<<"$inc" | cut -d: -f1)" ] \
  || fail "include fastcgi_params must come before the overriding fastcgi_param lines"

# --- secrets: staging only, read-only ------------------------------------------
grep -rEn 'origin-secret-prod|dayandyou_origin_ok_prod' "$NGINX_ROOT" | grep -vE ':[0-9]+:[[:space:]]*#' \
  && fail "no prod origin-secret map may be referenced until its file and vhost exist"
grep -qE '^[[:space:]]*include /etc/nginx/dayandyou-secrets/origin-secret-staging\.map;' <<<"$(code "$HTTP_CONF")" \
  || fail "00-dayandyou-cloudfront.conf must include the staging origin-secret map"
# A 48-character map key needs a 128-byte bucket, set before the first map
# (conf.d is included after it); the default 64 makes nginx refuse to start.
grep -qE '^[[:space:]]*map_hash_bucket_size[[:space:]]+(128|256);' <<<"$(code "$NGINX_ROOT/nginx.conf")" \
  || fail "nginx.conf must set map_hash_bucket_size 128 for the origin-secret map"

# shellcheck disable=SC2016  # Ruby source
COMPOSE="$COMPOSE" ruby -ryaml -e '
  services = YAML.load(File.read(ENV.fetch("COMPOSE"))).fetch("services")
  errors = []
  mounts = ->(name) { Array(services.dig(name, "volumes")).map(&:to_s) }
  services.each do |name, _|
    mounts.(name).each do |m|
      if m.start_with?("/opt/secrets/dayandyou")
        errors << "#{name}: only nginx may mount /opt/secrets/dayandyou" unless name == "nginx"
        errors << "#{name}: #{m} must be exactly /opt/secrets/dayandyou:/etc/nginx/dayandyou-secrets:ro" unless m == "/opt/secrets/dayandyou:/etc/nginx/dayandyou-secrets:ro"
      end
      next unless m.split(":").first == "dayandyou-api-fpm-staging"
      allowed = { "nginx" => "dayandyou-api-fpm-staging:/run/dayandyou-api-fpm-staging:ro",
                  "dayandyou-api-staging" => "dayandyou-api-fpm-staging:/run/dayandyou-api-fpm" }
      errors << "#{name}: may not mount dayandyou-api-fpm-staging as #{m}" unless allowed[name] == m
    end
  end
  errors << "nginx must mount the secret dir read-only" unless mounts.("nginx").include?("/opt/secrets/dayandyou:/etc/nginx/dayandyou-secrets:ro")
  errors << "nginx must mount the FastCGI include dir read-only" unless mounts.("nginx").include?("./nginx/dayandyou:/etc/nginx/dayandyou:ro")
  errors << "nginx must mount the API socket volume read-only" unless mounts.("nginx").include?("dayandyou-api-fpm-staging:/run/dayandyou-api-fpm-staging:ro")
  errors << "dayandyou-api-staging must mount its socket volume" unless mounts.("dayandyou-api-staging").include?("dayandyou-api-fpm-staging:/run/dayandyou-api-fpm")
  errors << "dayandyou-api-scheduler-staging runs no FPM and mounts no volume" unless mounts.("dayandyou-api-scheduler-staging").empty?
  %w[dayandyou-api-staging dayandyou-api-scheduler-staging].each do |name|
    svc = services[name] or (errors << "missing service #{name}"; next)
    errors << "#{name}: must not publish a port (FastCGI has no authentication)" if svc.key?("ports")
    errors << "#{name}: must use network_mode: host like the other apps" unless svc["network_mode"] == "host"
  end
  if errors.empty?
    puts "compose ok"
  else
    errors.each { |e| warn "FAIL: #{e}" }
    exit 1
  end
' >/dev/null
grep -q '^  dayandyou-api-fpm-staging: {}$' "$COMPOSE" || fail "top-level volumes: must declare dayandyou-api-fpm-staging"

# --- the storefront vhosts stay as they were (rollback path) --------------------
code "$STOREFRONT" | grep -nE 'fastcgi|dayandyou_api|dayandyou_cf_|dayandyou_viewer_ip|dayandyou_origin_ok|location[^{]*/api' \
  && fail "dayandyou.conf must stay unchanged: the API is served only on api-origin*"

echo "PASS: api-origin-staging refuses requests without the origin secret / viewer address, passes PHP only the viewer IP, throttles per viewer"
