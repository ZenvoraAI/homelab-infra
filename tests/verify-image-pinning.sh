#!/usr/bin/env bash
set -euo pipefail

# Every service image in docker-compose.yml must be immutable at pull time:
# either a literal digest reference (…@sha256:<64 hex>) or an env-driven ref
# that is REQUIRED (${VAR:?…}) -- never a moving tag (:latest, :release,
# :staging, nginx:1.27-alpine) and never a ${VAR:-default} that silently falls
# back to one when the variable is unset. The values live in the host's
# gitignored .env, written only by scripts/image-pins.sh (see README "Images and
# tags"), which refuses values that are not pinned.
#
# Also cross-checks the service table in scripts/lib/image-pins-lib.sh against
# the compose file, so a service cannot be added to one and not the other (the
# pin script and the pruner would then silently ignore it).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"
LIB="$ROOT/scripts/lib/image-pins-lib.sh"

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

# shellcheck source=scripts/lib/image-pins-lib.sh
. "$LIB"

DIGEST_RE='@sha256:[0-9a-f]{64}$'
count=0
while read -r svc image; do
  count=$((count + 1))
  [ "$image" != "<none>" ] || fail "$svc has no image: line"
  if printf '%s' "$image" | grep -Eq "$DIGEST_RE"; then
    continue  # literal digest: immutable regardless of any env
  fi
  row="$(pins_row "$svc")" || fail "$svc: image '$image' is neither digest-pinned nor listed in image-pins-lib.sh"
  var="$(pins_field "$row" 3)"
  kind="$(pins_field "$row" 4)"
  case "$image" in
    *"\${$var:-"*|*"\${$var-"*|*"\${$var}"*) fail "$svc: image '$image' has a fallback default -- an unset variable must stop compose, not pick a moving tag" ;;
  esac
  printf '%s' "$image" | grep -Eq "\\$\\{$var:\\?[^}]+\\}\$" \
    || fail "$svc: image '$image' must end in a required \${$var:?message}"
  if [ "$kind" = tag ]; then
    expected="ghcr.io/\${GHCR_OWNER:-zenvoraai}/$(pins_field "$row" 5):\${$var:?"
    case "$image" in
      "$expected"*) ;;
      *) fail "$svc: image '$image' does not match the lib's repo (expected prefix $expected)" ;;
    esac
  else
    case "$image" in
      "\${$var:?"*) ;;
      *) fail "$svc: image-kind ref '$image' must be the whole \${$var:?…}" ;;
    esac
  fi
done < <(service_images)

[ "$count" -ge 10 ] || fail "parsed only $count services from $COMPOSE -- parser broke?"

# Reverse direction: every lib row names a real compose service.
while IFS='|' read -r svc _rest; do
  service_images | grep -q "^$svc " || fail "image-pins-lib.sh lists '$svc', which is not a compose service"
done < <(pins_table)

echo "PASS: all $count compose images are digest-pinned or required env refs"
