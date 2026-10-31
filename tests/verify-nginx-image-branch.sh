#!/usr/bin/env bash
set -euo pipefail

# nginx is the single public listener for every site. Only the current stable
# branch (even minor) gets fixes; 1.27 went unpatched once 1.28 was cut, and
# 1.28 in turn when 1.30 was. Pins the NGINX_IMAGE fallback in the lib table
# (which the compose file must match, see verify-image-pinning.sh) to a
# digest-pinned stable branch no older than MIN_STABLE_MINOR. Raise it when a
# new stable branch is cut (April each year) and bump the image with it.
#
# Does not see the host's .env: after `image-pins.sh seed` the host runs
# whatever NGINX_IMAGE pins there, until it is promoted (README "nginx").

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${PINS_LIB_UNDER_TEST:-$ROOT/scripts/lib/image-pins-lib.sh}"
MIN_STABLE_MINOR=30

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# shellcheck source=scripts/lib/image-pins-lib.sh
. "$LIB"
for svc in nginx docker-api-filter; do
  ref="$(pins_field "$(pins_row "$svc")" 6)"
  [[ "$ref" =~ ^nginx:1\.([0-9]+)\.[0-9]+-alpine@sha256:[0-9a-f]{64}$ ]] \
    || fail "$svc: fallback '$ref' must be nginx:1.<minor>.<patch>-alpine@sha256:<digest>"
  minor="${BASH_REMATCH[1]}"
  [ $((minor % 2)) = 0 ] || fail "$svc: nginx 1.$minor is a mainline branch, not stable"
  [ "$minor" -ge "$MIN_STABLE_MINOR" ] || fail "$svc: nginx 1.$minor is an end-of-life stable branch (need >= 1.$MIN_STABLE_MINOR)"
done
echo "PASS: nginx fallback is a digest-pinned stable branch >= 1.$MIN_STABLE_MINOR"
