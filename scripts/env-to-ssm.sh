#!/bin/sh
set -eu

# Backs up a service's whole env file into SSM Parameter Store as two
# SecureString parameters, /env/<service> and /env/<service>-pem (format and
# service table in lib/env-ssm-lib.sh), then reads both back, reassembles them
# and compares the sha256 with the file. Never prints a value: only parameter
# names, byte sizes, versions and the hash result.
#
#   scripts/env-to-ssm.sh --profile env-backup-temp all
#   scripts/env-to-ssm.sh --profile env-backup-temp family-media/api
#   scripts/env-to-ssm.sh --dry-run all            # sizes and names, no AWS call
#   scripts/env-to-ssm.sh --profile P --verify-only all   # SSM still matches the file?
#
# Run as the deploy user; a file it cannot read is read with `sudo cat` into a
# 0700 temp dir that is removed on every exit. Values go to the CLI as
# file://, never on the command line (where ps would show them).

NAME=env-to-ssm
# shellcheck source=scripts/lib/env-ssm-lib.sh source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib/env-ssm-lib.sh"

umask 077

usage() {
  echo "usage: $0 [--profile NAME] [--dry-run|--verify-only] <service|all>" >&2
  echo "services: $(envssm_usage_services)" >&2
  exit 2
}

PROFILE_ARG=''
MODE=backup
SERVICE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) [ "$#" -ge 2 ] || usage; PROFILE_ARG=$2; shift 2 ;;
    --dry-run) MODE=dry-run; shift ;;
    --verify-only) MODE=verify-only; shift ;;
    -*) usage ;;
    *) [ -z "$SERVICE" ] || usage; SERVICE=$1; shift ;;
  esac
done
[ -n "$SERVICE" ] || usage

pass_args() {
  [ -z "$PROFILE_ARG" ] || printf -- '--profile\n%s\n' "$PROFILE_ARG"
  [ "$MODE" = backup ] || printf -- '--%s\n' "$MODE"
}

# `all` runs one child per service, so set -e and the cleanup trap apply to
# each one in full, and one failure does not hide the others.
if [ "$SERVICE" = all ]; then
  [ "$MODE" = dry-run ] || envssm_resolve_profile "$PROFILE_ARG"
  failed=''
  for svc in $(envssm_service_names); do
    row=$(envssm_service_row "$svc")
    path="$ENVSSM_SECRETS_ROOT/${row% *}"
    if [ "${row#* }" = optional ] && [ -x "$(dirname -- "$path")" ] && [ ! -e "$path" ]; then
      echo "$NAME: $svc: optional, $path absent -- skipped"
      continue
    fi
    # shellcheck disable=SC2046  # pass_args prints one argument per line, none with spaces
    sh "$0" $(pass_args) "$svc" || failed="$failed $svc"
  done
  [ -z "$failed" ] || envssm_die "FAILED:$failed"
  echo "$NAME: all services OK ($MODE)"
  exit 0
fi

ROW=$(envssm_service_row "$SERVICE") || usage
SRC_PATH="$ENVSSM_SECRETS_ROOT/${ROW% *}"
PARAM="$ENVSSM_PREFIX/$SERVICE"
PEM_PARAM="$PARAM-pem"
[ "$MODE" = dry-run ] || envssm_resolve_profile "$PROFILE_ARG"

envssm_make_workdir
trap 'rm -rf "$ENVSSM_WORK"' EXIT
trap 'exit 130' INT TERM HUP

read_source() { # path out
  if [ -r "$1" ]; then
    cat -- "$1" >"$2"
    return
  fi
  if [ -x "$(dirname -- "$1")" ] && [ ! -e "$1" ]; then
    envssm_die "$SERVICE: $1 not found"
  fi
  # The redirect runs as the caller on purpose: the copy lands in the
  # caller's 0700 temp dir, never as a root-owned file elsewhere.
  # shellcheck disable=SC2024
  sudo cat -- "$1" >"$2" || envssm_die "$SERVICE: cannot read $1 (even with sudo)"
}

put_part() { # param value_file part
  envssm_aws ssm put-parameter --name "$1" --type SecureString --tier Standard \
    --overwrite --value "file://$2" \
    --description "env-ssm backup ($3 part) of $SRC_PATH" \
    --query Version --output text
}

tag_part() { # param part
  envssm_aws ssm add-tags-to-resource --resource-type Parameter --resource-id "$1" \
    --tags "Key=env-ssm-source,Value=$SRC_PATH" "Key=env-ssm-sha256,Value=$SRC_SHA" "Key=env-ssm-part,Value=$2" \
    >/dev/null
}

SRC="$ENVSSM_WORK/source"
MAIN="$ENVSSM_WORK/main"
PEM="$ENVSSM_WORK/pem"
read_source "$SRC_PATH" "$SRC"
envssm_build_values "$SRC" "$MAIN" "$PEM"
SRC_SHA=$ENVSSM_SRC_SHA
envssm_check_size "$SERVICE: $PARAM" "$MAIN"
envssm_check_size "$SERVICE: $PEM_PARAM" "$PEM"

echo "$NAME: $SERVICE: $SRC_PATH $(envssm_bytes "$SRC") bytes"
if [ "$MODE" = dry-run ]; then
  echo "$NAME: $SERVICE: would write $PARAM $(envssm_bytes "$MAIN") bytes"
  echo "$NAME: $SERVICE: would write $PEM_PARAM $(envssm_bytes "$PEM") bytes ($ENVSSM_PEM_LINES long lines)"
  exit 0
fi

if [ "$MODE" = backup ]; then
  # -pem first: a run that dies between the two leaves the old main part,
  # whose header hash then no longer matches -- the restore refuses it.
  PEM_VERSION=$(put_part "$PEM_PARAM" "$PEM" pem) || envssm_die "$SERVICE: writing $PEM_PARAM failed"
  MAIN_VERSION=$(put_part "$PARAM" "$MAIN" main) || envssm_die "$SERVICE: writing $PARAM failed"
  tag_part "$PEM_PARAM" pem || envssm_die "$SERVICE: tagging $PEM_PARAM failed"
  tag_part "$PARAM" main || envssm_die "$SERVICE: tagging $PARAM failed"
  echo "$NAME: $SERVICE: wrote $PARAM $(envssm_bytes "$MAIN") bytes, version $MAIN_VERSION"
  echo "$NAME: $SERVICE: wrote $PEM_PARAM $(envssm_bytes "$PEM") bytes ($ENVSSM_PEM_LINES long lines), version $PEM_VERSION"
fi

# Verify: what SSM returns must rebuild the file byte for byte.
envssm_fetch "$PARAM" "$ENVSSM_WORK/got-main" || envssm_die "$SERVICE: reading back $PARAM failed"
envssm_fetch "$PEM_PARAM" "$ENVSSM_WORK/got-pem" || envssm_die "$SERVICE: reading back $PEM_PARAM failed"
envssm_assemble "$ENVSSM_WORK/got-main" "$ENVSSM_WORK/got-pem" "$ENVSSM_WORK/rebuilt"
GOT_SHA=$(envssm_sha256 "$ENVSSM_WORK/rebuilt")
if [ "$GOT_SHA" != "$SRC_SHA" ] || [ "$ENVSSM_HDR_SHA" != "$SRC_SHA" ]; then
  envssm_die "$SERVICE: sha256 MISMATCH between $SRC_PATH and SSM -- the backup is not usable"
fi
echo "$NAME: $SERVICE: sha256 $SRC_SHA match"
