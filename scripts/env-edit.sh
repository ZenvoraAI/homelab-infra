#!/bin/sh
set -eu

# Edits a canonical env file where it lives: in SSM, /env/<service> and
# /env/<service>-pem (format in lib/env-ssm-lib.sh). The deploy of that
# service pulls the pair into the host file (README "Env files from SSM"), so
# this is the only way the file changes.
#
#   scripts/env-edit.sh --profile env-backup-temp family-media/api            # opens $EDITOR
#   scripts/env-edit.sh --profile env-backup-temp --from-file F aiqiuqi-memorial/api   # scripted
#
# Fetches the latest pair, checks its sha256, opens the plain file in $EDITOR
# (or takes F), validates the result, shows which key NAMES were added,
# removed or changed (never a value), asks for confirmation (not with
# --from-file), writes both parts exactly as env-to-ssm.sh does, reads them
# back and checks the sha256, and prints the new versions. The plaintext only
# exists in a 0700 dir under /dev/shm (else $TMPDIR or /tmp) that is removed
# on every exit. The writer profile must be named with --profile: there is no
# default, AWS_PROFILE is not used, and a service read profile is refused.

NAME=env-edit
# shellcheck source=scripts/lib/env-ssm-lib.sh source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib/env-ssm-lib.sh"

umask 077

KEY_RE='^[A-Za-z_][A-Za-z0-9_]*='

usage() {
  echo "usage: $0 --profile WRITER_PROFILE [--from-file PATH] <service>" >&2
  echo "services: $(printf '%s\n' "$ENVSSM_CANONICAL" | awk 'NF == 2 { printf "%s ", $1 }')" >&2
  exit 2
}

PROFILE_ARG=''
FROM_FILE=''
SERVICE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) [ "$#" -ge 2 ] || usage; PROFILE_ARG=$2; shift 2 ;;
    --from-file) [ "$#" -ge 2 ] || usage; FROM_FILE=$2; shift 2 ;;
    -*) usage ;;
    *) [ -z "$SERVICE" ] || usage; SERVICE=$1; shift ;;
  esac
done
[ -n "$SERVICE" ] || usage
envssm_is_canonical "$SERVICE" || envssm_die "$SERVICE is not edited here: only services whose deploy pulls /env (ENVSSM_CANONICAL) -- refusing"
ROW=$(envssm_service_row "$SERVICE") || usage
SRC_PATH="$ENVSSM_SECRETS_ROOT/${ROW% *}"
PARAM="$ENVSSM_PREFIX/$SERVICE"

# Explicit writer only: AWS_PROFILE is ignored on purpose, so a shell that
# happens to export a read profile (or the writer) never decides this.
[ -n "$PROFILE_ARG" ] || envssm_die "no writer profile: pass --profile NAME (the temporary env-backup-temp user; there is no default and AWS_PROFILE is not used)"
for reader in $ENVSSM_READ_PROFILES; do
  [ "$PROFILE_ARG" != "$reader" ] || envssm_die "$PROFILE_ARG is a service read profile; edits need the writer profile -- refusing"
done
envssm_resolve_profile "$PROFILE_ARG"

if [ -n "$FROM_FILE" ]; then
  [ -f "$FROM_FILE" ] && [ -r "$FROM_FILE" ] || envssm_die "--from-file $FROM_FILE is not a readable file"
fi

envssm_make_workdir
trap 'rm -rf "$ENVSSM_WORK"' EXIT
trap 'exit 130' INT TERM HUP

OLD="$ENVSSM_WORK/old.env"
NEW="$ENVSSM_WORK/edit.env"

# --- fetch the latest pair -------------------------------------------------------
envssm_fetch "$PARAM" "$ENVSSM_WORK/fetched-main" || envssm_die "$SERVICE: reading $PARAM failed"
envssm_fetch "$PARAM-pem" "$ENVSSM_WORK/fetched-pem" || envssm_die "$SERVICE: reading $PARAM-pem failed"
envssm_assemble "$ENVSSM_WORK/fetched-main" "$ENVSSM_WORK/fetched-pem" "$OLD"
[ "$(envssm_sha256 "$OLD")" = "$ENVSSM_HDR_SHA" ] \
  || envssm_die "$SERVICE: the latest pair does not match its recorded sha256 -- fix it first (ssm-to-env.sh --version); nothing written"

# --- edit ------------------------------------------------------------------------
if [ -n "$FROM_FILE" ]; then
  cat -- "$FROM_FILE" >"$NEW"
else
  cp "$OLD" "$NEW"
  # EDITOR may carry arguments (e.g. "vim -n -i NONE"), so it is split.
  # shellcheck disable=SC2086
  ${EDITOR:-vi} "$NEW" || envssm_die "the editor exited non-zero; nothing written"
fi
if cmp -s "$OLD" "$NEW"; then
  echo "$NAME: $SERVICE: no change; nothing written"
  exit 0
fi

# --- validate (line numbers and key names only) -----------------------------------
envssm_check_source "$NEW" "$SERVICE"
# The deploy's shape check: blank lines, comments and KEY=value only.
bad_lines=$(LC_ALL=C awk -v re="$KEY_RE" '
  /^[ \t]*$/ || /^[ \t]*#/ { next }
  $0 !~ re { printf "%s%d", sep, NR; sep = "," }
' "$NEW")
[ -z "$bad_lines" ] || envssm_die "$SERVICE: line(s) $bad_lines are not KEY=value (content withheld) -- nothing written"
# A key may repeat only as often as it already did: a new duplicate is a
# mistake (Compose takes the last one, silently).
dups=$(LC_ALL=C awk -v re="$KEY_RE" '
  match($0, re) { k = substr($0, 1, RLENGTH - 1); if (FNR == NR) o[k]++; else n[k]++ }
  END { for (k in n) if (n[k] > 1 && n[k] > o[k]) { printf "%s%s", sep, k; sep = " " } }
' "$OLD" "$NEW")
[ -z "$dups" ] || envssm_die "$SERVICE: duplicate key(s): $dups -- nothing written"

envssm_build_values "$NEW" "$ENVSSM_WORK/main" "$ENVSSM_WORK/pem" "$SERVICE"
NEW_SHA=$ENVSSM_SRC_SHA
envssm_check_size "$SERVICE: $PARAM" "$ENVSSM_WORK/main"
envssm_check_size "$SERVICE: $PARAM-pem" "$ENVSSM_WORK/pem"

# --- names-only diff -------------------------------------------------------------
# Values stay inside awk; only the key and what happened to it are printed.
LC_ALL=C awk -v re="$KEY_RE" '
  match($0, re) {
    k = substr($0, 1, RLENGTH - 1)
    if (FNR == NR) o[k] = o[k] "\n" $0; else n[k] = n[k] "\n" $0
  }
  END {
    for (k in n) if (!(k in o)) print "  added   " k
    for (k in o) if (!(k in n)) print "  removed " k
    for (k in n) if ((k in o) && o[k] != n[k]) print "  changed " k
  }
' "$OLD" "$NEW" | sort -k2 >"$ENVSSM_WORK/diff"
echo "$NAME: $SERVICE: changes to $PARAM (key names only):"
if [ -s "$ENVSSM_WORK/diff" ]; then
  cat "$ENVSSM_WORK/diff"
else
  echo "  (no key changed: only comments, blank lines or order)"
fi

if [ -z "$FROM_FILE" ]; then
  printf '%s' "$NAME: write this to $PARAM and $PARAM-pem? [y/N] " >&2
  read -r answer || answer=''
  case "$answer" in
    y|Y|yes) ;;
    *) echo "$NAME: $SERVICE: not confirmed; nothing written"; exit 1 ;;
  esac
fi

# --- write -----------------------------------------------------------------------
# Someone else's edit since the fetch would be silently undone: refuse instead.
envssm_fetch "$PARAM" "$ENVSSM_WORK/recheck-main" || envssm_die "$SERVICE: re-reading $PARAM failed; nothing written"
cmp -s "$ENVSSM_WORK/fetched-main" "$ENVSSM_WORK/recheck-main" \
  || envssm_die "$SERVICE: $PARAM changed since it was fetched -- rerun to edit the new version; nothing written"

envssm_write_pair "$SERVICE" "$PARAM" "$SRC_PATH" "$ENVSSM_WORK/main" "$ENVSSM_WORK/pem"
envssm_read_back "$SERVICE" "$PARAM" "$NEW_SHA" "the edited file"
echo "$NAME: $SERVICE: wrote $PARAM version $ENVSSM_MAIN_VERSION and $PARAM-pem version $ENVSSM_PEM_VERSION, sha256 $NEW_SHA match"

# Keys whose per-key parameter is kept for other readers: that copy is now stale.
envssm_mirrors "$SERVICE" | while read -r key param; do
  if grep -q " $key\$" "$ENVSSM_WORK/diff"; then
    echo "$NAME: note: $key is also kept in $param (README \"Per-key parameters\"); update it too, or the next deploy warns"
  fi
done
echo "$NAME: $SERVICE: the host file changes at the next deploy (or apply now: README \"Env files from SSM\")"
