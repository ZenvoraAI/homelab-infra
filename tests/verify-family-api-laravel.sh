#!/usr/bin/env bash
# shellcheck disable=SC2016 # nginx variables are literal on purpose
set -euo pipefail

# The Laravel family-media API (family-api-laravel) next to the Express api.
# Its PHP-FPM speaks FastCGI, which has no authentication: whoever reaches the
# socket runs code with the JWT secret, the database URL and the CloudFront
# key. So, as for the memorial API (verify-memorial-api-laravel.sh), the
# family-api-fpm volume is the access boundary: only the API (rw) and nginx
# (ro) mount it. Because the app keys every throttle and lockout on nginx's
# FAMILY_CLIENT_IP, the include must set that from $family_client_ip only, and
# blank every forwarding header and the CloudFront headers before PHP.
# No scheduler container (owner decision D1): the sweeps run from the host
# crontab, so a second service running the schedule would run them twice.
#
# Pure repo test: reads only docker-compose.yml and the nginx config.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
INCLUDE="${FAMILY_INCLUDE_UNDER_TEST:-$ROOT/nginx/family/fastcgi-family-api.conf}"
NGINX_ROOT="${NGINX_ROOT_UNDER_TEST:-$ROOT/nginx}"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# --- compose -------------------------------------------------------------------
# shellcheck disable=SC2016  # Ruby source; #{...} is Ruby interpolation
COMPOSE="$COMPOSE" ruby -ryaml -e '
  doc = YAML.load(File.read(ENV.fetch("COMPOSE")))
  services = doc.fetch("services")
  errors = []
  api = services["family-api-laravel"]
  abort "FAIL: family-api-laravel must exist" unless api

  # Only the API (rw) and nginx (ro) mount the socket volume; nobody else names it.
  services.each do |name, svc|
    Array(svc["volumes"]).each do |v|
      text = v.is_a?(Hash) ? v.values.join(" ") : v.to_s
      next unless text.include?("family-api-fpm")
      ok = (name == "family-api-laravel" && v == "family-api-fpm:/run/family-api-fpm") ||
           (name == "nginx" && v == "family-api-fpm:/run/family-api-fpm:ro")
      errors << "#{name} must not mount family-api-fpm (#{text})" unless ok
    end
  end
  nginx = Array(services.dig("nginx", "volumes"))
  errors << "nginx must mount family-api-fpm read-only" unless nginx.include?("family-api-fpm:/run/family-api-fpm:ro")
  errors << "nginx must mount the FastCGI include dir read-only" unless nginx.include?("./nginx/family:/etc/nginx/family:ro")
  errors << "the API must mount exactly its socket volume" unless Array(api["volumes"]) == ["family-api-fpm:/run/family-api-fpm"]
  errors << "top-level volumes: must declare family-api-fpm" unless doc.fetch("volumes", {}).key?("family-api-fpm")

  # The origin-secret dir reaches nginx only, read-only, and is not the API env dir
  # (mounting /opt/secrets/family-media would hand nginx every API secret).
  services.each do |name, svc|
    Array(svc["volumes"]).map(&:to_s).each do |m|
      # The origin dir, and any mount of the whole family-media secrets dir.
      next unless m.start_with?("/opt/secrets/family-media-origin") || m.split(":").first.sub(%r{/+$}, "") == "/opt/secrets/family-media"
      ok = name == "nginx" && m == "/opt/secrets/family-media-origin:/etc/nginx/family-secrets:ro"
      errors << "#{name}: #{m} -- only nginx may mount the origin-secret dir, exactly /opt/secrets/family-media-origin:/etc/nginx/family-secrets:ro" unless ok
    end
  end

  # Its own image and pin, distinct from the Express api, so either can be re-pinned alone.
  image = api["image"].to_s
  errors << "family-api-laravel must run ghcr.io/<owner>/family-media-api-laravel pinned by FAMILY_API_LARAVEL_TAG" unless image.include?("/family-media-api-laravel:${FAMILY_API_LARAVEL_TAG:?")
  errors << "the Express api must keep its own image and pin (the rollback)" unless services.dig("api", "image").to_s.include?("/family-media-api:${FAMILY_API_TAG:?")

  # D1: no scheduler, no second service on the Laravel image.
  others = services.select { |n, s| n != "family-api-laravel" && s["image"].to_s.include?("family-media-api-laravel") }
  errors << "no other service may run the Laravel family image (D1: the host cron runs the sweeps): #{others.keys.join(", ")}" unless others.empty?
  errors << "family-api-laravel must not override the image entrypoint (FPM after family:preflight)" if api.key?("entrypoint") || api.key?("command")

  errors << "network_mode must be host (Postgres on the host, as Express)" unless api["network_mode"] == "host"
  errors << "env_file must be exactly /opt/secrets/family-media/api-laravel.env, required: false" unless api["env_file"] == [{ "path" => "/opt/secrets/family-media/api-laravel.env", "required" => false }]
  # Every value comes from the env file; a bare name here would forward the deploy shell.
  errors << "no environment: entries (everything lives in api-laravel.env)" if api.key?("environment")
  errors << "must not publish ports" if api.key?("ports")
  errors << "read_only with a /tmp tmpfs (as the image smoke test runs it)" unless api["read_only"] == true && Array(api["tmpfs"]).any? { |t| t.to_s.start_with?("/tmp:") }
  errors << "must have a mem_limit" unless api["mem_limit"]

  unless errors.empty?
    errors.each { |e| warn "FAIL: #{e}" }
    exit 1
  end
'

# --- nginx ---------------------------------------------------------------------
# Every place that picks a pool picks one of the two unix sockets.
sets="$(grep -rhE '^[[:space:]]*set[[:space:]]+\$family_api_fpm[[:space:]]' "$NGINX_ROOT" || true)"
if [ -n "$sets" ]; then
  printf '%s\n' "$sets" | grep -vqE '^[[:space:]]*set[[:space:]]+\$family_api_fpm[[:space:]]+unix:/run/family-api-fpm/fpm(-auth)?\.sock;$' \
    && fail "\$family_api_fpm must be unix:/run/family-api-fpm/fpm.sock or fpm-auth.sock:\n$sets"
fi
# A file that picks the family FPM without the include would skip the client-IP and header rules.
{ grep -rlE '^[[:space:]]*set[[:space:]]+\$family_api_fpm' "$NGINX_ROOT/conf.d" || true; } | while read -r conf; do
  grep -q 'include /etc/nginx/family/fastcgi-family-api.conf;' "$conf" || fail "${conf#"$ROOT"/} sets \$family_api_fpm without the include"
done

inc="$(sed -e 's/[[:space:]]*#.*$//' "$INCLUDE")"
need() { [ "$(grep -cxE "$1" <<<"$inc")" = 1 ] || fail "${INCLUDE#"$ROOT"/} must contain exactly once: $2"; }
need 'fastcgi_pass \$family_api_fpm;' 'fastcgi_pass $family_api_fpm;'
need 'include fastcgi_params;' 'include fastcgi_params; (its params are then overridden)'
need 'fastcgi_param SCRIPT_FILENAME /var/www/html/public/index\.php;' 'a fixed SCRIPT_FILENAME (nginx serves no file of its own)'
need 'fastcgi_param FAMILY_CLIENT_IP \$family_client_ip;' 'FAMILY_CLIENT_IP $family_client_ip (every throttle and lockout key)'
for header in X_FORWARDED_FOR X_REAL_IP CF_CONNECTING_IP CLOUDFRONT_VIEWER_ADDRESS X_FAMILY_ORIGIN_SECRET PROXY; do
  need "fastcgi_param HTTP_$header \"\";" "a blanked HTTP_$header"
done
for header in X-Powered-By X-Content-Type-Options X-Frame-Options Referrer-Policy; do
  need "fastcgi_hide_header $header;" "fastcgi_hide_header $header; (the vhost adds its own copies)"
done
[ "$(grep -n '^include fastcgi_params;' <<<"$inc" | cut -d: -f1)" -lt "$(grep -n '^fastcgi_param FAMILY_CLIENT_IP' <<<"$inc" | cut -d: -f1)" ] \
  || fail "include fastcgi_params must come before the overriding fastcgi_param lines"
grep -qE 'FAMILY_CLIENT_IP[[:space:]]+\$(http_|proxy_add_x_forwarded_for|remote_addr|binary_remote_addr)' <<<"$inc" \
  && fail "FAMILY_CLIENT_IP must never come from a request header or \$remote_addr (a shared CloudFront edge)"

echo "PASS: the Laravel family API's FPM is reached only over its socket volume (API rw, nginx ro); no scheduler; client IP only from \$family_client_ip, forwarding/CloudFront headers blanked"
