#!/bin/sh
set -eu

# Compares the per-key parameters that still mirror keys of a canonical env
# file (ENVSSM_MIRRORS in lib/env-ssm-lib.sh) with the file the deploy has
# just pulled from /env. Read-only and advisory: /env is the source of truth,
# so a difference is reported by key and parameter NAME and never changes the
# file or fails the deploy. A difference means a rotation updated only one
# side (README "Per-key parameters"). Never prints a value.
#
#   scripts/env-ssm-mirror-check.sh --profile memorial-ssm aiqiuqi-memorial/api /opt/secrets/aiqiuqi-memorial/api.env
#
# Exit 0 whatever it finds (2 on a usage error), so a deploy can run it plainly.

NAME=env-ssm-mirror-check
# shellcheck source=scripts/lib/env-ssm-lib.sh source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib/env-ssm-lib.sh"

umask 077

usage() {
  echo "usage: $0 --profile NAME <service> <env file>" >&2
  exit 2
}

[ "${1:-}" = --profile ] && [ "$#" -eq 4 ] || usage
PROFILE_ARG=$2
SERVICE=$3
ENV_FILE=$4
envssm_is_canonical "$SERVICE" || usage
[ -r "$ENV_FILE" ] || { echo "$NAME: WARNING: cannot read $ENV_FILE -- mirrors not compared" >&2; exit 0; }
envssm_resolve_profile "$PROFILE_ARG"

envssm_make_workdir
trap 'rm -rf "$ENVSSM_WORK"' EXIT
trap 'exit 130' INT TERM HUP

# The value of the last KEY= line (what Compose uses), or failure if none.
env_value() { # key
  LC_ALL=C awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); f = 1 } END { if (f) printf "%s", v; exit !f }' "$ENV_FILE"
}

same=0 differ=0 unread=0
for row in $(envssm_mirrors "$SERVICE" | tr ' ' ':'); do
  key=${row%%:*}
  param=${row#*:}
  if ! envssm_fetch "$param" "$ENVSSM_WORK/mirror"; then
    echo "$NAME: WARNING: could not read $param -- $key not compared" >&2
    unread=$((unread + 1))
    continue
  fi
  want=$(cat "$ENVSSM_WORK/mirror")
  if have=$(env_value "$key") && [ "$have" = "$want" ]; then
    same=$((same + 1))
  else
    echo "$NAME: WARNING: $key in $ENV_FILE (from /env/$SERVICE) differs from $param; /env wins -- update the stale side (README \"Per-key parameters\")" >&2
    differ=$((differ + 1))
  fi
done
echo "$NAME: $SERVICE: mirrors: $same match, $differ differ, $unread unreadable"
