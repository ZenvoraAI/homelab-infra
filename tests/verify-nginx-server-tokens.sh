#!/usr/bin/env bash
set -euo pipefail

# nginx is the single public listener for every site on the host. With
# server_tokens on (nginx's default), every response's Server header and every
# nginx error page names the exact version, telling scanners which branch to
# target. Pins `server_tokens off;` at http level and that no vhost turns it
# back on.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -Eq '^[[:space:]]*server_tokens[[:space:]]+off;' "$ROOT/nginx/nginx.conf" || {
  echo "missing in nginx/nginx.conf: server_tokens off;" >&2
  exit 1
}
if grep -rEn '^[[:space:]]*server_tokens[[:space:]]+(on|build)' "$ROOT/nginx"; then
  echo "a config re-enables server_tokens" >&2
  exit 1
fi

echo "PASS: nginx hides its version"
