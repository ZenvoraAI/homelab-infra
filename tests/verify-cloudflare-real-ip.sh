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

# Cloudflare currently publishes 15 IPv4 + 7 IPv6 ranges (22 total, counted
# directly from this file as of the pull date in its header comment). Pinning
# the count catches a silently truncated list (a bad copy/paste from
# cloudflare.com/ips-v4 or /ips-v6) that a bare grep -q would miss.
count=$(grep -c 'set_real_ip_from' "$ROOT/$FILE")
[ "$count" -eq 22 ] || {
  echo "expected 22 set_real_ip_from lines in $FILE, found $count" >&2
  exit 1
}

echo 'PASS: Cloudflare real-IP configuration'
