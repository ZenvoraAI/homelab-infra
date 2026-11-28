#!/bin/sh
set -eu

# Edits a canonical env file where it lives: in SSM, /env/<service> and
# /env/<service>-pem (format in lib/env-ssm-lib.sh). The deploy of that
# service pulls the pair into the host file (README "Env files from SSM"), so
# this is the only way the file changes.
#
#   scripts/env-edit.sh --profile env-backup-temp family-media/api                 # opens $EDITOR
#   scripts/env-edit.sh --profile env-backup-temp --from-file F --yes aiqiuqi-memorial/api   # scripted
#
# Confirms the profile is the IAM user env-backup-temp, fetches the latest
# pair at its current versions and checks its sha256, opens the plain file in
# $EDITOR (or takes F, which must not be readable by group or others),
# validates the result, shows which key NAMES were added, removed or changed
# (never a value), checks the handoff key pair across both services when it is
# touched, asks for confirmation (--yes skips that, with --from-file only),
# refuses if either part's version moved since the fetch, writes both parts
# exactly as env-to-ssm.sh does, reads them back, checks the sha256, and
# prints the new versions.
#
# The plaintext only exists in a 0700 dir under /dev/shm (else $TMPDIR, else
# /tmp), removed on every exit the shell sees -- not on SIGKILL or a power
# loss, which leave it until the next reboot (/dev/shm) or tmp cleanup. The
# editor runs with HOME and the XDG state/data/cache dirs inside that dir, and
# vi/vim/nvim with no swap, viminfo/shada, undo or backup files. The writer
# must be named with --profile: there is no default, AWS_PROFILE is not used,
# and a service read profile is refused.

NAME=env-edit
# shellcheck source=scripts/lib/env-ssm-lib.sh source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib/env-ssm-lib.sh"
# shellcheck source=scripts/lib/env-handoff-lib.sh source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib/env-handoff-lib.sh"

umask 077

KEY_RE='^[A-Za-z_][A-Za-z0-9_]*='

usage() {
  echo "usage: $0 --profile WRITER_PROFILE [--from-file PATH [--yes]] [--allow-handoff-mismatch] <service>" >&2
  echo "services: $(printf '%s\n' "$ENVSSM_CANONICAL" | awk 'NF == 2 { printf "%s ", $1 }')" >&2
  exit 2
}

PROFILE_ARG=''
FROM_FILE=''
ASSUME_YES=0
ALLOW_HANDOFF_MISMATCH=0
SERVICE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) [ "$#" -ge 2 ] || usage; PROFILE_ARG=$2; shift 2 ;;
    --from-file) [ "$#" -ge 2 ] || usage; FROM_FILE=$2; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --allow-handoff-mismatch) ALLOW_HANDOFF_MISMATCH=1; shift ;;
    -*) usage ;;
    *) [ -z "$SERVICE" ] || usage; SERVICE=$1; shift ;;
  esac
done
[ -n "$SERVICE" ] || usage
[ "$ASSUME_YES" -eq 0 ] || [ -n "$FROM_FILE" ] || envssm_die "--yes is only for --from-file (an editor session always asks)"
envssm_is_canonical "$SERVICE" || envssm_die "$SERVICE is not edited here: only services whose deploy pulls /env (ENVSSM_CANONICAL) -- refusing"
ROW=$(envssm_service_row "$SERVICE") || usage
SRC_PATH="$ENVSSM_SECRETS_ROOT/${ROW% *}"
PARAM="$ENVSSM_PREFIX/$SERVICE"

# Explicit writer only: AWS_PROFILE is ignored on purpose, so a shell that
# happens to export a read profile (or the writer) never decides this.
[ -n "$PROFILE_ARG" ] || envssm_die "no writer profile: pass --profile NAME (the temporary $ENVSSM_WRITER_USER user; there is no default and AWS_PROFILE is not used)"
for reader in $ENVSSM_READ_PROFILES; do
  [ "$PROFILE_ARG" != "$reader" ] || envssm_die "$PROFILE_ARG is a service read profile; edits need the writer profile -- refusing"
done
envssm_resolve_profile "$PROFILE_ARG"

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
if [ -n "$FROM_FILE" ]; then
  [ -f "$FROM_FILE" ] && [ -r "$FROM_FILE" ] || envssm_die "--from-file $FROM_FILE is not a readable file"
  mode=$(file_mode "$FROM_FILE")
  [ $((0$mode & 077)) -eq 0 ] || envssm_die "--from-file $FROM_FILE is mode $mode: readable by group or others -- chmod 600 it (or write it under /dev/shm with umask 077); nothing written"
fi

envssm_make_workdir prefer-shm
trap 'rm -rf "$ENVSSM_WORK"' EXIT
trap 'exit 130' INT TERM HUP

OLD="$ENVSSM_WORK/old.env"
NEW="$ENVSSM_WORK/edit.env"

envssm_check_writer

# --- fetch the latest pair -------------------------------------------------------
envssm_fetch_pair "$SERVICE" "$OLD"
FETCHED_V=$ENVSSM_PAIR_V
FETCHED_PEM_V=$ENVSSM_PAIR_PEM_V

# --- edit ------------------------------------------------------------------------
run_editor() { # file
  target=$1
  mkdir -p "$ENVSSM_WORK/home/state" "$ENVSSM_WORK/home/data" "$ENVSSM_WORK/home/cache"
  # EDITOR may carry arguments (e.g. "code --wait"), so it is split, unglobbed.
  set -f
  # shellcheck disable=SC2086
  set -- ${EDITOR:-vi}
  set +f
  case "${1##*/}" in
    # No swap file, no viminfo/shada, no undo or backup copy of the plaintext.
    vi|vim|nvim|vim.basic|vim.tiny) set -- "$@" -n -i NONE '+set noundofile nobackup nowritebackup' ;;
  esac
  HOME="$ENVSSM_WORK/home" XDG_STATE_HOME="$ENVSSM_WORK/home/state" XDG_DATA_HOME="$ENVSSM_WORK/home/data" \
    XDG_CACHE_HOME="$ENVSSM_WORK/home/cache" "$@" "$target"
}
if [ -n "$FROM_FILE" ]; then
  cat -- "$FROM_FILE" >"$NEW"
  echo "$NAME: note: $FROM_FILE holds the whole env in plain text -- delete it when this is done"
else
  cp "$OLD" "$NEW"
  run_editor "$NEW" || envssm_die "the editor exited non-zero; nothing written"
fi
if cmp -s "$OLD" "$NEW"; then
  echo "$NAME: $SERVICE: no change; nothing written"
  exit 0
fi

# --- validate (line numbers and key names only) -----------------------------------
envssm_check_source "$NEW" "$SERVICE"
bad_lines=$(envssm_check_shape "$NEW") \
  || envssm_die "$SERVICE: line(s) $bad_lines are not KEY=value (content withheld) -- nothing written"
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
touched() { grep -Eq " ($1)\$" "$ENVSSM_WORK/diff"; }

# --- handoff key pair ------------------------------------------------------------
# The writer can read both pairs, so a family key memorial does not accept (or
# a memorial key list without family's key) is caught here, not by users.
HANDOFF_FAMILY='' HANDOFF_MEMORIAL=''
case "$SERVICE" in
  family-media/api) touched 'FM_HANDOFF_KEY_ID|FM_HANDOFF_PRIVATE_KEY_PEM' && HANDOFF_FAMILY=$NEW && HANDOFF_MEMORIAL=other ;;
  aiqiuqi-memorial/api) touched 'MEMORIAL_HANDOFF_PUBLIC_KEYS' && HANDOFF_MEMORIAL=$NEW && HANDOFF_FAMILY=other ;;
esac
if [ -n "$HANDOFF_FAMILY" ]; then
  if [ "$HANDOFF_FAMILY" = other ]; then
    envssm_fetch_pair family-media/api "$ENVSSM_WORK/other.env"; HANDOFF_FAMILY="$ENVSSM_WORK/other.env"
  else
    envssm_fetch_pair aiqiuqi-memorial/api "$ENVSSM_WORK/other.env"; HANDOFF_MEMORIAL="$ENVSSM_WORK/other.env"
  fi
  if reason=$(envhandoff_check "$HANDOFF_FAMILY" "$HANDOFF_MEMORIAL" "$ENVSSM_WORK"); then
    echo "$NAME: handoff: family's key and kid are listed in memorial's MEMORIAL_HANDOFF_PUBLIC_KEYS"
  elif [ "$ALLOW_HANDOFF_MISMATCH" -eq 1 ]; then
    echo "$NAME: WARNING: handoff mismatch allowed (--allow-handoff-mismatch): $reason"
  else
    envssm_die "handoff: $reason -- refusing (the 3-step rotation in README \"Per-key parameters\" never needs a mismatch; --allow-handoff-mismatch overrides); nothing written"
  fi
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  printf '%s' "$NAME: write this to $PARAM and $PARAM-pem? [y/N] " >&2
  read -r answer || answer=''
  case "$answer" in
    y|Y|yes) ;;
    *) echo "$NAME: $SERVICE: not confirmed; nothing written"; exit 1 ;;
  esac
fi

# --- write -----------------------------------------------------------------------
# Someone else's edit since the fetch would be silently undone: refuse when
# either part's version moved. SSM has no conditional put, so a write landing
# between this check and the put below (well under a second) is not caught;
# the next deploy's log and the versions printed below show it.
now_v=$(envssm_version "$PARAM") || envssm_die "$SERVICE: re-reading the version of $PARAM failed; nothing written"
now_pem_v=$(envssm_version "$PARAM-pem") || envssm_die "$SERVICE: re-reading the version of $PARAM-pem failed; nothing written"
[ "$now_v" = "$FETCHED_V" ] && [ "$now_pem_v" = "$FETCHED_PEM_V" ] \
  || envssm_die "$SERVICE: $PARAM changed since it was fetched (v$FETCHED_V/v$FETCHED_PEM_V, now v$now_v/v$now_pem_v) -- rerun to edit the new version; nothing written"

envssm_write_pair "$SERVICE" "$PARAM" "$SRC_PATH" "$ENVSSM_WORK/main" "$ENVSSM_WORK/pem"
envssm_read_back "$SERVICE" "$PARAM" "$NEW_SHA" "the edited file"
echo "$NAME: $SERVICE: wrote $PARAM version $ENVSSM_MAIN_VERSION and $PARAM-pem version $ENVSSM_PEM_VERSION (read back, hash verified)"

# Keys whose per-key parameter is kept for other readers: that copy is now stale.
envssm_mirrors "$SERVICE" | while read -r key param; do
  if grep -q " $key\$" "$ENVSSM_WORK/diff"; then
    echo "$NAME: note: $key is also kept in $param (README \"Per-key parameters\"); update it too, or the next deploy warns"
  fi
done
echo "$NAME: $SERVICE: the host file changes at the next deploy (or apply now: README \"Env files from SSM\")"
