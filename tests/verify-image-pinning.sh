#!/usr/bin/env bash
set -euo pipefail

# Every service image in docker-compose.yml must come from a pin variable in
# scripts/lib/image-pins-lib.sh (or be a literal @sha256: digest), in the form
# the lib's PINS_COMPOSE_MODE says:
#   strict     -> ${VAR:?message}: no compose command runs while VAR is unset.
#   transition -> ${VAR:-<fallback>} with the lib table's fallback: an unseeded
#                 host must keep working, because compose interpolates the
#                 whole file for every command -- one required-but-unset
#                 variable breaks every product's deploy (zenvora-admin's
#                 deploy runs homelab main unattended). Third-party fallbacks
#                 must be digest-pinned; app-image fallbacks may only be the
#                 tags those services ran before pinning (latest/release/
#                 staging), never a new moving tag.
# In transition mode it also interpolates every image with an EMPTY
# environment, the way compose would on an unseeded host, and requires each to
# resolve.
#
# Also cross-checks the lib table against the compose file, so a service cannot
# be added to one and not the other (the pin script and the pruner would then
# silently ignore it).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
LIB="${PINS_LIB_UNDER_TEST:-$ROOT/scripts/lib/image-pins-lib.sh}"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

[ -f "$LIB" ] || fail "missing $LIB"

# "<service> <image value>" for every service under the top-level services: key.
service_images() {
  awk '
    /^services:/ { in_services = 1; next }
    /^[^ #]/ { in_services = 0 }
    in_services && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      svc = $1; sub(":", "", svc); seen[svc] = 1; order[++n] = svc; next
    }
    in_services && /^    image:/ { sub(/^    image:[[:space:]]*/, ""); img[svc] = $0 }
    END { for (i = 1; i <= n; i++) print order[i], (order[i] in img ? img[order[i]] : "<none>") }
  ' "$COMPOSE"
}

# Compose-style interpolation with an empty environment: ${X:-d} -> d,
# ${X:?m} -> error. Prints the result or fails.
interpolate_unset() {
  local s="$1" out=""
  while [[ "$s" =~ ^([^\$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-?])([^}]*)\}(.*)$ ]]; do
    local pre="${BASH_REMATCH[1]}" var="${BASH_REMATCH[2]}" op="${BASH_REMATCH[3]}" arg="${BASH_REMATCH[4]}"
    s="${BASH_REMATCH[5]}"
    case "$op" in
      :-|-) out+="$pre$arg" ;;
      *) echo "required variable $var is missing a value"; return 1 ;;
    esac
  done
  [[ "$s" != *'$'* ]] || { echo "unparsed variable in '$s'"; return 1; }
  printf '%s\n' "$out$s"
}

# shellcheck source=scripts/lib/image-pins-lib.sh
. "$LIB"

case "${PINS_COMPOSE_MODE:-}" in
  strict|transition) ;;
  *) fail "image-pins-lib.sh: PINS_COMPOSE_MODE must be strict or transition, got '${PINS_COMPOSE_MODE:-}'" ;;
esac

DIGEST_RE='@sha256:[0-9a-f]{64}$'
count=0
while read -r svc image; do
  count=$((count + 1))
  [ "$image" != "<none>" ] || fail "$svc has no image: line"
  if printf '%s' "$image" | grep -Eq "$DIGEST_RE" && [[ "$image" != *'$'* ]]; then
    continue  # literal digest: immutable regardless of any env
  fi
  row="$(pins_row "$svc")" || fail "$svc: image '$image' is neither digest-pinned nor listed in image-pins-lib.sh"
  var="$(pins_field "$row" 3)"
  kind="$(pins_field "$row" 4)"
  fallback="$(pins_field "$row" 6)"
  prefix=""
  [ "$kind" = image ] || prefix="ghcr.io/\${GHCR_OWNER:-zenvoraai}/$(pins_field "$row" 5):"
  if [ "$PINS_COMPOSE_MODE" = strict ]; then
    case "$image" in
      "$prefix\${$var:?"*"}") [[ "${image#"$prefix"}" =~ ^\$\{$var:\?[^}]+\}$ ]] \
        || fail "$svc: image '$image' must be exactly $prefix\${$var:?message}" ;;
      *) fail "$svc: image '$image' must be exactly $prefix\${$var:?message} (strict mode)" ;;
    esac
  else
    [ -n "$fallback" ] || fail "$svc: the lib table has no transition fallback for $var"
    if [ "$kind" = image ]; then
      why="$(pins_validate image "$fallback")" || fail "$svc: third-party fallback '$fallback' is not digest-pinned: $why"
    else
      case "$fallback" in
        latest|release|staging) ;;
        *) pins_validate tag "$fallback" >/dev/null || fail "$svc: fallback '$fallback' is a new moving tag" ;;
      esac
    fi
    expected="$prefix\${$var:-$fallback}"
    [ "$image" = "$expected" ] || fail "$svc: image '$image' must be exactly $expected (transition mode)"
    resolved="$(interpolate_unset "$image")" || fail "$svc: on an unseeded host compose would fail: $resolved"
  fi
done < <(service_images)

[ "$count" -ge 10 ] || fail "parsed only $count services from $COMPOSE -- parser broke?"

# Reverse direction: every lib row names a real compose service.
while IFS='|' read -r svc _rest; do
  service_images | grep -q "^$svc " || fail "image-pins-lib.sh lists '$svc', which is not a compose service"
done < <(pins_table)

echo "PASS: all $count compose images follow pin mode '$PINS_COMPOSE_MODE'"
