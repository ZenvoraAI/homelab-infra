#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require() {
  local file="$1"
  local pattern="$2"
  grep -Fq -- "$pattern" "$ROOT/$file" || {
    echo "missing $pattern in $file" >&2
    exit 1
  }
}

require docker-compose.yml '/var/lib/homelab-acme:/var/www/certbot:ro'
require docker-compose.yml '/opt/secrets/family-media/.env:/app/.env:ro'
require nginx/nginx.conf 'ssl_protocols TLSv1.2 TLSv1.3;'

for file in nginx/conf.d/family-api.conf nginx/conf.d/valtou-api.conf nginx/conf.d/dayandyou.conf; do
  require "$file" 'location ^~ /.well-known/acme-challenge/'
  require "$file" 'root /var/www/certbot;'
  require "$file" 'try_files $uri =404;'
done

require scripts/reload-nginx-after-cert-renewal.sh '/usr/bin/docker compose exec -T nginx nginx -s reload'

echo 'PASS: certbot webroot configuration'
