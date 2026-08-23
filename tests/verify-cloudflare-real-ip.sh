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

FILE=nginx/conf.d/00-cloudflare-realip.conf

[ -f "$ROOT/$FILE" ] || {
  echo "missing $FILE" >&2
  exit 1
}

require "$FILE" 'real_ip_header CF-Connecting-IP;'
grep -Fq 'set_real_ip_from' "$ROOT/$FILE" || {
  echo "missing set_real_ip_from in $FILE" >&2
  exit 1
}

echo 'PASS: Cloudflare real-IP configuration'
