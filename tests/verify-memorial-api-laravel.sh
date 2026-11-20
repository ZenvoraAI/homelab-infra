#!/usr/bin/env bash
# shellcheck disable=SC2016 # nginx variables and stub sources are literal on purpose
set -euo pipefail

# The Laravel memorial API (memorial-api-laravel + its scheduler) next to the
# Express memorial-api. Its PHP-FPM speaks FastCGI, which has no
# authentication: whoever reaches the socket runs code with the JWT secret, the
# database URL and the CloudFront key. So, as for SecureVault
# (verify-securevault-fpm-socket.sh), the memorial-api-fpm volume is the access
# boundary: only the API (rw) and nginx (ro) mount it. And because the app keys
# every throttle on nginx's MEMORIAL_CLIENT_IP, the include must set that from
# $remote_addr and pass no forwarded-for header.
#
# Pure repo test: reads only docker-compose.yml and the nginx config.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
INCLUDE="${MEMORIAL_INCLUDE_UNDER_TEST:-$ROOT/nginx/memorial/fastcgi-memorial-api.conf}"
NGINX_ROOT="${NGINX_ROOT_UNDER_TEST:-$ROOT/nginx}"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# --- compose -------------------------------------------------------------------
# shellcheck disable=SC2016  # Ruby source; #{...} is Ruby interpolation
COMPOSE="$COMPOSE" ruby -ryaml -e '
  doc = YAML.load(File.read(ENV.fetch("COMPOSE")))
  services = doc.fetch("services")
  errors = []
  api, sched = services["memorial-api-laravel"], services["memorial-api-laravel-scheduler"]
  abort "FAIL: memorial-api-laravel and memorial-api-laravel-scheduler must both exist" unless api && sched

  # Only the API (rw) and nginx (ro) mount the socket volume, nobody else names it.
  services.each do |name, svc|
    Array(svc["volumes"]).each do |v|
      text = v.is_a?(Hash) ? v.values.join(" ") : v.to_s
      next unless text.include?("memorial-api-fpm")
      ok = (name == "memorial-api-laravel" && v == "memorial-api-fpm:/run/memorial-api-fpm") ||
           (name == "nginx" && v == "memorial-api-fpm:/run/memorial-api-fpm:ro")
      errors << "#{name} must not mount memorial-api-fpm (#{text})" unless ok
    end
  end
  errors << "nginx must mount memorial-api-fpm read-only" unless Array(services.dig("nginx", "volumes")).include?("memorial-api-fpm:/run/memorial-api-fpm:ro")
  errors << "memorial-api-laravel must mount memorial-api-fpm" unless Array(api["volumes"]).include?("memorial-api-fpm:/run/memorial-api-fpm")
  errors << "the scheduler runs no FPM and mounts nothing" unless Array(sched["volumes"]).empty?
  errors << "top-level volumes: must declare memorial-api-fpm" unless doc.fetch("volumes", {}).key?("memorial-api-fpm")

  # One image, one pin, moved together by the deploy.
  image = api["image"].to_s
  errors << "memorial-api-laravel must run ghcr.io/<owner>/memorial-api pinned by MEMORIAL_API_LARAVEL_TAG" unless image.include?("/memorial-api:${MEMORIAL_API_LARAVEL_TAG:?")
  errors << "the scheduler must run the same image reference as the API" unless sched["image"] == image
  errors << "the scheduler must run memorial-scheduler-entrypoint" unless sched["entrypoint"] == ["memorial-scheduler-entrypoint"]

  [["memorial-api-laravel", api], ["memorial-api-laravel-scheduler", sched]].each do |name, svc|
    errors << "#{name}: network_mode must be host (Postgres on the host, as Express)" unless svc["network_mode"] == "host"
    errors << "#{name}: env_file must be exactly the memorial api.env" unless svc["env_file"] == ["/opt/secrets/aiqiuqi-memorial/api.env"]
    # Literal blanks: Laravel refuses to boot with either set, and api.env may
    # still carry Express'"'"'s loopback TRUSTED_PROXY_ADDRESSES. No bare name
    # (it would forward the deploy shell'"'"'s value) and no other literal.
    env = Array(svc["environment"])
    errors << "#{name}: environment must be exactly TRUSTED_PROXY_ADDRESSES= and TRUSTED_PROXIES=" unless env.sort == ["TRUSTED_PROXIES=", "TRUSTED_PROXY_ADDRESSES="]
    errors << "#{name}: must not publish ports" if svc.key?("ports")
  end
  services.each do |name, svc|
    errors << "#{name}: FPM_LISTEN must not be set (the image socket is the only listen)" if Array(svc["environment"]).any? { |e| e.to_s.start_with?("FPM_LISTEN") }
  end

  unless errors.empty?
    errors.each { |e| warn "FAIL: #{e}" }
    exit 1
  end
'

# --- nginx ---------------------------------------------------------------------
# Every place that picks a pool picks one of the two unix sockets.
sets="$(grep -rhE '^[[:space:]]*set[[:space:]]+\$memorial_api_fpm[[:space:]]' "$NGINX_ROOT" || true)"
if [ -n "$sets" ]; then
  printf '%s\n' "$sets" | grep -vqE '^[[:space:]]*set[[:space:]]+\$memorial_api_fpm[[:space:]]+unix:/run/memorial-api-fpm/fpm(-auth)?\.sock;$' \
    && fail "\$memorial_api_fpm must be unix:/run/memorial-api-fpm/fpm.sock or fpm-auth.sock:\n$sets"
fi
# A location that passes to the memorial FPM without the include would skip
# the client-IP and header rules below.
{ grep -rlE '^[[:space:]]*set[[:space:]]+\$memorial_api_fpm' "$NGINX_ROOT/conf.d" || true; } | while read -r conf; do
  grep -q 'include /etc/nginx/memorial/fastcgi-memorial-api.conf;' "$conf" || fail "${conf#"$ROOT"/} sets \$memorial_api_fpm without the include"
done

need() { grep -qxE "$1" "$INCLUDE" || fail "${INCLUDE#"$ROOT"/} must contain: $2"; }
need 'fastcgi_pass \$memorial_api_fpm;' 'fastcgi_pass $memorial_api_fpm;'
need 'fastcgi_param SCRIPT_FILENAME /var/www/html/public/index\.php;' 'a fixed SCRIPT_FILENAME (nginx serves no file of its own)'
need 'fastcgi_param MEMORIAL_HOST \$host;' 'MEMORIAL_HOST $host (the tenant key)'
need 'fastcgi_param MEMORIAL_CLIENT_IP \$remote_addr;' 'MEMORIAL_CLIENT_IP $remote_addr (every throttle key)'
need 'fastcgi_param HTTP_X_FORWARDED_FOR "";' 'a blanked X-Forwarded-For'
need 'fastcgi_param HTTP_X_REAL_IP "";' 'a blanked X-Real-IP'
need 'fastcgi_param HTTP_PROXY "";' 'a blanked Proxy header (httpoxy)'
for header in X-Content-Type-Options X-Frame-Options Referrer-Policy; do
  need "fastcgi_hide_header $header;" "fastcgi_hide_header $header; (the vhost adds its own)"
done
grep -qE 'MEMORIAL_CLIENT_IP[[:space:]]+\$(http_|proxy_add_x_forwarded_for)' "$INCLUDE" && fail "MEMORIAL_CLIENT_IP must never come from a request header"

echo "PASS: the Laravel memorial API's FPM is reached only over its socket volume (API rw, nginx ro); client IP only from \$remote_addr"
