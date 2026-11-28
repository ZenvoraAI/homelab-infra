#!/bin/sh
set -eu

# Restores a service's env file from its two SSM parameters (written by
# env-to-ssm.sh; format in lib/env-ssm-lib.sh). The reassembled file must
# match the sha256 recorded at backup time, or nothing is written. Prints only
# the target path, its size and the versions read (the file's sha256 only with
# --print-sha, for drills: deploy logs never carry a hash of the file).
#
#   scripts/ssm-to-env.sh --profile P --target /tmp/drill/api.env family-media/api   # drill
#   scripts/ssm-to-env.sh --profile P --force family-media/api                        # real restore
#   scripts/ssm-to-env.sh --profile P --version 3 --pem-version 3 --target ... svc     # older pair
#
# --version N reads <name>:N for the main part and, unless --pem-version says
# otherwise, the -pem part too. The two parts' versions only stay equal while
# every backup wrote both, so env-to-ssm.sh prints each one; a wrong pairing is
# refused by the hash check. This is the way back from a backup that was cut
# off between its two writes.
#
# The target defaults to the service's own path. An existing non-empty target
# is refused unless --force. The new file is written to a 0600 temp file in
# the target's directory and moved over it, so a reader never sees a partial
# file. With --force, the replaced file is first copied to a 0600
# <target>.bak-<UTC timestamp> next to it (same naming as the refresh scripts,
# whose next rotation prunes it). Owner and mode: --owner/--mode, else those of
# the replaced file (with any access for "other" removed), else the invoking
# user (SUDO_USER under sudo) and 0600. When the target directory
# is not writable, the install steps run with sudo.
#
# The deploys of the services whose /env pair is canonical (README "Env files
# from SSM") run it with two more flags:
#   --if-changed       a target that already has the verified content is left
#                      alone: no rewrite, no .bak, owner and mode untouched.
#   --check-shape      the reassembled file must be blank lines, comments and
#                      KEY=value only (envssm_check_shape), or nothing is
#                      written -- checked before the live file is touched.
#   --keep-one-backup  after the replace, every older <target>.bak-<UTC
#                      timestamp> is removed, so exactly one remains (the
#                      refresh scripts' rotation, secretlib_rotate_backup).
#                      Best effort: a failed prune is reported, not fatal,
#                      because the new file is already in place.
# --if-changed compares content only: an identical file whose owner or mode
# drifted is left as it is.
#
# Without --version, the current version of each part is read first (no
# decryption) and exactly those versions are fetched, so the two parts always
# come from one moment and the output can name them.

NAME=ssm-to-env
# shellcheck source=scripts/lib/env-ssm-lib.sh source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib/env-ssm-lib.sh"

umask 077

usage() {
  echo "usage: $0 [--profile NAME] [--target ABSOLUTE_PATH] [--force [--if-changed] [--keep-one-backup]] [--check-shape] [--print-sha] [--owner USER[:GROUP]] [--mode 0600] [--version N [--pem-version M]] <service>" >&2
  echo "services: $(envssm_usage_services)" >&2
  exit 2
}

PROFILE_ARG=''
TARGET=''
FORCE=0
IF_CHANGED=0
KEEP_ONE=0
CHECK_SHAPE=0
PRINT_SHA=0
OWNER=''
FILE_MODE=''
VERSION=''
VERSION_SET=0
PEM_VERSION=''
PEM_VERSION_SET=0
SERVICE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) [ "$#" -ge 2 ] || usage; PROFILE_ARG=$2; shift 2 ;;
    --target) [ "$#" -ge 2 ] || usage; TARGET=$2; shift 2 ;;
    --owner) [ "$#" -ge 2 ] || usage; OWNER=$2; shift 2 ;;
    --mode) [ "$#" -ge 2 ] || usage; FILE_MODE=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; VERSION=$2; VERSION_SET=1; shift 2 ;;
    --pem-version) [ "$#" -ge 2 ] || usage; PEM_VERSION=$2; PEM_VERSION_SET=1; shift 2 ;;
    --force) FORCE=1; shift ;;
    --if-changed) IF_CHANGED=1; shift ;;
    --keep-one-backup) KEEP_ONE=1; shift ;;
    --check-shape) CHECK_SHAPE=1; shift ;;
    --print-sha) PRINT_SHA=1; shift ;;
    -*) usage ;;
    *) [ -z "$SERVICE" ] || usage; SERVICE=$1; shift ;;
  esac
done
[ -n "$SERVICE" ] || usage
[ "$FORCE" -eq 1 ] || [ "$IF_CHANGED$KEEP_ONE" = 00 ] || envssm_die "--if-changed and --keep-one-backup need --force"
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
check_version() {
  case "$1" in
    ''|0*|*[!0-9]*) envssm_die "--version/--pem-version must be a positive integer" ;;
  esac
}
[ "$VERSION_SET" -eq 0 ] || check_version "$VERSION"
[ "$PEM_VERSION_SET" -eq 0 ] || check_version "$PEM_VERSION"
[ -z "$PEM_VERSION" ] || [ -n "$VERSION" ] || envssm_die "--pem-version needs --version"
[ -n "$PEM_VERSION" ] || PEM_VERSION=$VERSION
MAIN_REF=$PARAM${VERSION:+:$VERSION}
PEM_REF=$PARAM-pem${PEM_VERSION:+:$PEM_VERSION}
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

if [ -z "$VERSION" ]; then
  VERSION=$(envssm_version "$PARAM") || envssm_die "$SERVICE: reading the version of $PARAM failed"
  PEM_VERSION=$(envssm_version "$PARAM-pem") || envssm_die "$SERVICE: reading the version of $PARAM-pem failed"
  check_version "$VERSION"
  check_version "$PEM_VERSION"
  MAIN_REF=$PARAM:$VERSION
  PEM_REF=$PARAM-pem:$PEM_VERSION
fi
VERSIONS="$PARAM v$VERSION, $PARAM-pem v$PEM_VERSION"
sha_note() { [ "$PRINT_SHA" -eq 0 ] || printf ', sha256 %s' "$SHA"; }

envssm_fetch "$MAIN_REF" "$ENVSSM_WORK/main" || envssm_die "$SERVICE: reading $MAIN_REF failed"
envssm_fetch "$PEM_REF" "$ENVSSM_WORK/pem" || envssm_die "$SERVICE: reading $PEM_REF failed"
envssm_assemble "$ENVSSM_WORK/main" "$ENVSSM_WORK/pem" "$ENVSSM_WORK/env"
SHA=$(envssm_sha256 "$ENVSSM_WORK/env")
[ "$SHA" = "$ENVSSM_HDR_SHA" ] || envssm_die "$SERVICE: reassembled file does not match the sha256 recorded at backup -- nothing written"
if [ "$CHECK_SHAPE" -eq 1 ]; then
  bad=$(envssm_check_shape "$ENVSSM_WORK/env") \
    || envssm_die "$SERVICE: $VERSIONS: line(s) $bad are not KEY=value (content withheld) -- nothing written"
fi

if [ "$IF_CHANGED" -eq 1 ] && $SUDO test -f "$TARGET"; then
  # shellcheck disable=SC2024  # the copy lands in the caller's 0700 work dir
  $SUDO cat -- "$TARGET" >"$ENVSSM_WORK/current" || envssm_die "cannot read $TARGET -- nothing written"
  if [ "$(envssm_sha256 "$ENVSSM_WORK/current")" = "$SHA" ]; then
    echo "$NAME: $SERVICE: $TARGET unchanged ($VERSIONS$(sha_note))"
    exit 0
  fi
fi

# Owner and mode: kept from the replaced file unless given. An inherited mode
# loses any access for "other" and any special bit, like --mode is checked.
EXISTING_OWNER=''
if $SUDO test -e "$TARGET"; then
  current=$($SUDO stat -c '%u:%g %a' "$TARGET" 2>/dev/null || $SUDO stat -f '%u:%g %Lp' "$TARGET")
  EXISTING_OWNER=${current% *}
  [ -n "$OWNER" ] || OWNER=$EXISTING_OWNER
  if [ -z "$FILE_MODE" ]; then
    FILE_MODE=$(printf '%o' $(( 0${current#* } & 0770 )))
    [ "$FILE_MODE" = "${current#* }" ] || echo "$NAME: $TARGET was mode ${current#* }; the restored file gets $FILE_MODE (no access for others)"
  fi
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
BACKUP=''
if [ -n "$EXISTING_OWNER" ]; then
  # Same steps as secretlib_rotate_backup: created 0600 directly, never a
  # window at the umask's default mode. No pruning here: the file being
  # replaced may be the only copy of something.
  BACKUP="$TARGET.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  ! $SUDO test -e "$BACKUP" || envssm_die "$BACKUP already exists -- wait a second and rerun; nothing written"
  $SUDO install -m 600 "$TARGET" "$BACKUP" || envssm_die "backing up $TARGET failed -- nothing written"
  $SUDO chown "$EXISTING_OWNER" "$BACKUP" || envssm_die "chown of $BACKUP failed -- nothing written"
fi
$SUDO mv -f "$STAGED" "$TARGET" || envssm_die "moving the temp file into place failed"
STAGED=''
[ -z "$BACKUP" ] || echo "$NAME: $SERVICE: previous file kept as $BACKUP"

# Only names this script and the refresh scripts create: <target>.bak-<stamp>.
prune_backups() {
  $SUDO find "$TARGET_DIR" -maxdepth 1 -type f -name '*.bak-*' | while IFS= read -r old; do
    case "$old" in
      "$BACKUP") ;;
      "$TARGET".bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
        $SUDO rm -f -- "$old" || return 1
        echo "$NAME: $SERVICE: removed older backup $old" ;;
    esac
  done
}
if [ "$KEEP_ONE" -eq 1 ] && [ -n "$BACKUP" ]; then
  prune_backups || echo "$NAME: $SERVICE: WARNING: pruning older backups of $TARGET failed; remove them by hand" >&2
fi

echo "$NAME: $SERVICE: changed: installed $TARGET from $VERSIONS, $(envssm_bytes "$ENVSSM_WORK/env") bytes (hash verified$(sha_note))"
