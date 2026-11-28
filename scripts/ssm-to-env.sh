#!/bin/sh
set -eu

# Restores a service's env file from its two SSM parameters (written by
# env-to-ssm.sh; format in lib/env-ssm-lib.sh). The reassembled file must
# match the sha256 recorded at backup time, or nothing is written. Prints only
# the target path, its size and sha256.
#
#   scripts/ssm-to-env.sh --profile P --target /tmp/drill/api.env family-media/api   # drill
#   scripts/ssm-to-env.sh --profile P --force family-media/api                        # real restore
#
# The target defaults to the service's own path. An existing non-empty target
# is refused unless --force. The new file is written to a 0600 temp file in
# the target's directory and moved over it, so a reader never sees a partial
# file. Owner and mode: those of the replaced file, else --owner/--mode, else
# the invoking user (SUDO_USER under sudo) and 0600. When the target directory
# is not writable, the install steps run with sudo.

NAME=ssm-to-env
# shellcheck source=scripts/lib/env-ssm-lib.sh source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib/env-ssm-lib.sh"

umask 077

usage() {
  echo "usage: $0 [--profile NAME] [--target ABSOLUTE_PATH] [--force] [--owner USER[:GROUP]] [--mode 0600] <service>" >&2
  echo "services: $(envssm_usage_services)" >&2
  exit 2
}

PROFILE_ARG=''
TARGET=''
FORCE=0
OWNER=''
FILE_MODE=''
SERVICE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) [ "$#" -ge 2 ] || usage; PROFILE_ARG=$2; shift 2 ;;
    --target) [ "$#" -ge 2 ] || usage; TARGET=$2; shift 2 ;;
    --owner) [ "$#" -ge 2 ] || usage; OWNER=$2; shift 2 ;;
    --mode) [ "$#" -ge 2 ] || usage; FILE_MODE=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    -*) usage ;;
    *) [ -z "$SERVICE" ] || usage; SERVICE=$1; shift ;;
  esac
done
[ -n "$SERVICE" ] || usage
ROW=$(envssm_service_row "$SERVICE") || usage
[ -n "$TARGET" ] || TARGET="$ENVSSM_SECRETS_ROOT/${ROW% *}"
PARAM="$ENVSSM_PREFIX/$SERVICE"

case "$TARGET" in
  /*) ;;
  *) envssm_die "--target must be an absolute path" ;;
esac
case "$TARGET" in
  */) envssm_die "--target must be a file path, not a directory" ;;
esac
if [ -n "$OWNER" ]; then
  printf '%s\n' "$OWNER" | grep -Eqx '[A-Za-z0-9._-]+(:[A-Za-z0-9._-]+)?' || envssm_die "--owner must be USER or USER:GROUP"
fi
if [ -n "$FILE_MODE" ]; then
  # A secret file is never readable by "other".
  printf '%s\n' "$FILE_MODE" | grep -Eqx '0?[0-7][0-7]0' || envssm_die "--mode must be octal with no permission for others (e.g. 0600, 0640)"
fi
envssm_resolve_profile "$PROFILE_ARG"

TARGET_DIR=$(dirname -- "$TARGET")
SUDO=''
if [ ! -w "$TARGET_DIR" ] || [ ! -x "$TARGET_DIR" ]; then
  SUDO=sudo
fi
$SUDO test -d "$TARGET_DIR" || envssm_die "$TARGET_DIR does not exist"
if $SUDO test -L "$TARGET" || { $SUDO test -e "$TARGET" && ! $SUDO test -f "$TARGET"; }; then
  envssm_die "$TARGET exists and is not a regular file -- refusing"
fi
if $SUDO test -s "$TARGET" && [ "$FORCE" -ne 1 ]; then
  envssm_die "$TARGET exists and is not empty -- refusing to overwrite without --force"
fi

envssm_make_workdir
STAGED=''
cleanup() {
  rm -rf "$ENVSSM_WORK"
  [ -z "$STAGED" ] || $SUDO rm -f "$STAGED"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

envssm_fetch "$PARAM" "$ENVSSM_WORK/main" || envssm_die "$SERVICE: reading $PARAM failed"
envssm_fetch "$PARAM-pem" "$ENVSSM_WORK/pem" || envssm_die "$SERVICE: reading $PARAM-pem failed"
envssm_assemble "$ENVSSM_WORK/main" "$ENVSSM_WORK/pem" "$ENVSSM_WORK/env"
SHA=$(envssm_sha256 "$ENVSSM_WORK/env")
[ "$SHA" = "$ENVSSM_HDR_SHA" ] || envssm_die "$SERVICE: reassembled file does not match the sha256 recorded at backup -- nothing written"

# Owner and mode: kept from the replaced file unless given.
if $SUDO test -e "$TARGET"; then
  current=$($SUDO stat -c '%u:%g %a' "$TARGET" 2>/dev/null || $SUDO stat -f '%u:%g %Lp' "$TARGET")
  [ -n "$OWNER" ] || OWNER=${current% *}
  [ -n "$FILE_MODE" ] || FILE_MODE=${current#* }
fi
if [ -z "$OWNER" ]; then
  invoker=${SUDO_USER:-$(id -un)}
  OWNER="$(id -u "$invoker"):$(id -g "$invoker")"
fi
[ -n "$FILE_MODE" ] || FILE_MODE=600

STAGED=$($SUDO mktemp "$TARGET_DIR/.$(basename -- "$TARGET").ssm-restore.XXXXXX") || envssm_die "cannot create a temp file in $TARGET_DIR"
$SUDO chmod 600 "$STAGED"
$SUDO tee "$STAGED" <"$ENVSSM_WORK/env" >/dev/null || envssm_die "writing the temp file failed"
$SUDO chown "$OWNER" "$STAGED" || envssm_die "chown $OWNER failed -- nothing written"
$SUDO chmod "$FILE_MODE" "$STAGED" || envssm_die "chmod $FILE_MODE failed -- nothing written"
$SUDO mv -f "$STAGED" "$TARGET" || envssm_die "moving the temp file into place failed"
STAGED=''

echo "$NAME: $SERVICE: restored $TARGET $(envssm_bytes "$ENVSSM_WORK/env") bytes, sha256 $SHA (matches backup)"
