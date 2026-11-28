# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034 # stub sources are literal; variables are for the sourcing tests
# Shared by tests/verify-env-ssm-deploy.sh and tests/verify-env-edit.sh: a
# stubbed Parameter Store with per-profile rights, stubbed sudo/docker/pg_*,
# fake-value fixtures and helpers. Sourced after ROOT is set; creates $TMP.
#
# Profiles (the policies the CEO applies, README "Env files from SSM"):
#   env-backup-temp  put/get/tag /env/*; sts says user/env-backup-temp
#   family-ssm       get /env/family-media/api(-pem) and /family-media/prod/*
#   memorial-ssm     get /env/aiqiuqi-memorial/api(-pem) and /aiqiuqi-memorial/preview/*
#   anything else    denied; sts says user/<profile name>

umask 077
# Never a real editor: a test that reaches one by mistake fails instead of hanging.
export EDITOR=false
SH="${ENVSSM_TEST_SH:-sh}"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

REL=1111111111111111111111111111111111111111
PREV=2222222222222222222222222222222222222222
REPO="$TMP/repo"; BIN="$TMP/bin"; STORE="$TMP/store"; WORKTMP="$TMP/tmpdir"
SECRETS="$TMP/secrets"; SEED="$TMP/seed"; LOG="$TMP/calls.log"; OUTLOG="$TMP/all-output.log"
mkdir -p "$REPO/scripts/lib" "$BIN" "$STORE" "$WORKTMP" "$SECRETS"/{family-media,aiqiuqi-memorial} \
  "$SEED"/{family-media,aiqiuqi-memorial} "$TMP/dumps" "$TMP/premigrate" "$TMP/seedtool"
for f in deploy-family-api-laravel.sh deploy-memorial-api-laravel.sh ssm-to-env.sh env-to-ssm.sh env-edit.sh \
         env-ssm-mirror-check.sh lib/env-ssm-lib.sh lib/env-handoff-lib.sh; do
  cp "$ROOT/scripts/$f" "$REPO/scripts/$f"
done
# Seeding /env as the one-off backup did: env-to-ssm.sh refuses canonical
# services, so seeding runs a copy with an empty ENVSSM_CANONICAL.
cp -R "$REPO/scripts" "$TMP/seedtool/scripts"
sed "/^ENVSSM_CANONICAL='\$/,/^'\$/c\\
ENVSSM_CANONICAL=''
" "$ROOT/scripts/lib/env-ssm-lib.sh" >"$TMP/seedtool/scripts/lib/env-ssm-lib.sh"
grep -qx "ENVSSM_CANONICAL=''" "$TMP/seedtool/scripts/lib/env-ssm-lib.sh" || fail "could not build the seeding copy"
# The per-key refreshes must never run again for these services: they log.
for s in refresh-family-media-secrets.sh refresh-memorial-secrets.sh refresh-memorial-laravel-secrets.sh \
         refresh-memorial-aws-credentials.sh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n' "$s" >"$REPO/scripts/$s"
done
cat >"$REPO/scripts/image-pins.sh" <<'STUB'
#!/usr/bin/env bash
echo "image-pins.sh $*" >>"$CALLS"
case "$1" in get) echo "$STUB_PIN" ;; esac
STUB

cat >"$BIN/aws" <<'STUB'
#!/usr/bin/env bash
set -u
op='' name='' value='' profile='' query='' decrypt=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    ssm) op=$2; shift ;;
    sts) op=sts-$2; shift ;;
    --name|--resource-id) name=$2; shift ;;
    --value) value=$2; shift ;;
    --profile) profile=$2; shift ;;
    --query) query=$2; shift ;;
    --with-decryption) decrypt=1 ;;
  esac
  shift
done
printf '%s %s %s %s\n' "$profile" "$op" "$name" "$query" >>"$STUB_DIR/aws.calls"
[ -z "${CALLS:-}" ] || echo "aws $profile $op $name $query" >>"$CALLS"
if [ "$op" = sts-get-caller-identity ]; then echo "arn:aws:iam::198075950569:user/$profile"; exit 0; fi
base=${name%%:[0-9]*}
version=''; [ "$base" = "$name" ] || version=${name##*:}
deny() { echo "An error occurred (AccessDeniedException) when calling the $1 operation: User: arn:aws:iam::0:user/$profile is not authorized" >&2; exit 254; }
case "$profile:$op:$base" in
  env-backup-temp:*:/env/*) ;;
  family-ssm:get-parameter:/env/family-media/api|family-ssm:get-parameter:/env/family-media/api-pem) ;;
  family-ssm:get-parameter:/family-media/prod/*) ;;
  memorial-ssm:get-parameter:/env/aiqiuqi-memorial/api|memorial-ssm:get-parameter:/env/aiqiuqi-memorial/api-pem) ;;
  memorial-ssm:get-parameter:/aiqiuqi-memorial/preview/*) ;;
  *:put-parameter:*) deny PutParameter ;;
  *:add-tags-to-resource:*) deny AddTagsToResource ;;
  *) deny GetParameter ;;
esac
key=$(printf '%s' "$base" | tr '/' '_')
notfound() { echo "An error occurred (ParameterNotFound) when calling the GetParameter operation" >&2; exit 254; }
case "$op" in
  put-parameter)
    f=${value#file://}
    [ "$(wc -c <"$f")" -le 4096 ] || { echo "An error occurred (ValidationException) when calling the PutParameter operation" >&2; exit 254; }
    cp "$f" "$STUB_DIR/store/$key"
    v=$(( $(cat "$STUB_DIR/store/$key.version" 2>/dev/null || echo 0) + 1 ))
    echo "$v" >"$STUB_DIR/store/$key.version"
    cp "$f" "$STUB_DIR/store/$key.v$v"
    [ "$base" != "${STUB_CORRUPT_AFTER_PUT:-}" ] || : >"$STUB_DIR/put.done"
    echo "$v" ;;
  get-parameter)
    if [ -n "${STUB_FAIL_GET:-}" ] && [ "$base" = "$STUB_FAIL_GET" ]; then
      echo "An error occurred (ThrottlingException) when calling the GetParameter operation" >&2; exit 254
    fi
    if [ "$query" = Parameter.Version ]; then
      [ -f "$STUB_DIR/store/$key.version" ] || notfound
      cat "$STUB_DIR/store/$key.version"; exit 0
    fi
    [ "$decrypt" = 1 ] || { echo "stub: value read without --with-decryption" >&2; exit 252; }
    src="$STUB_DIR/store/$key${version:+.v$version}"
    [ -f "$src" ] || notfound
    corrupt=0
    [ -z "${STUB_CORRUPT:-}" ] || [ "$base" != "$STUB_CORRUPT" ] || corrupt=1
    [ ! -e "$STUB_DIR/put.done" ] || [ "$base" != "${STUB_CORRUPT_AFTER_PUT:-}" ] || corrupt=1
    if [ "$corrupt" = 1 ]; then sed 's/fake/FAKE/' "$src"; else cat "$src"; fi
    echo ;;
  add-tags-to-resource) ;;
  *) echo "stub: unexpected op $op" >&2; exit 252 ;;
esac
STUB
cat >"$BIN/sudo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -n ] && shift
if [ "$1" = -u ]; then shift 2; fi
exec "$@"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/sleep"
printf '#!/usr/bin/env bash\necho "chown $*" >>"$STUB_DIR/chown.log"\n' >"$BIN/chown"
cat >"$BIN/install" <<'STUB'
#!/usr/bin/env bash
args=(); while [ "$#" -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
exec /usr/bin/install "${args[@]}"
STUB
# date: a distinct stamp per call for the .bak/dump names (two deploys in one
# second are normal here); anything else is the real date.
cat >"$BIN/date" <<'STUB'
#!/usr/bin/env bash
if [ "${*: -1}" = "+%Y%m%dT%H%M%SZ" ]; then
  n=$(( $(cat "$STUB_DIR/date.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STUB_DIR/date.n"
  printf '20261128T%06dZ\n' "$n"; exit 0
fi
exec /bin/date "$@"
STUB
printf '#!/usr/bin/env bash\necho "pg_dump $*" >>"$CALLS"\nprintf PGDMP-complete\n' >"$BIN/pg_dump"
printf '#!/usr/bin/env bash\ngrep -q complete "${@: -1}"\n' >"$BIN/pg_restore"
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $* [tag=${FAMILY_API_LARAVEL_TAG:-}${MEMORIAL_API_LARAVEL_TAG:-}]" >>"$CALLS"
case "$*" in
  "compose up -d"*)
    # STUB_UP_FAIL_TAG: bringing up that tag fails (a failed swap).
    [ -z "${STUB_UP_FAIL_TAG:-}" ] || [ "${FAMILY_API_LARAVEL_TAG:-}${MEMORIAL_API_LARAVEL_TAG:-}" != "$STUB_UP_FAIL_TAG" ] || exit 1 ;;
  "compose ps -q --status running"*) [ "${STUB_READY:-1}" = 1 ] && echo sched-id ;;
  *fcgi-probe.sh*) [ "${STUB_READY:-1}" = 1 ]; exit ;;
esac
exit 0
STUB
chmod +x "$BIN"/* "$REPO/scripts"/*.sh

# --- fixtures: each fake value carries a searchable token ------------------------
FAKES=(fakefamkey-1a fakedbpw-2b fakekid-3c fakepem-4d fakememkey-5e fakecf-6f fakeaws-7g fakenewval-8h fakesecond-9i fakedupval-0j fakecrval-1k)
PEM="-----BEGIN PRIVATE KEY-----\\n$(printf 'fakepem-4d%.0s' $(seq 1 60))\\n-----END PRIVATE KEY-----"
family_env() {
  printf '# family laravel\n'
  printf 'APP_KEY=base64:fakefamkey-1a\n'
  printf 'DATABASE_URL=postgresql://fm:fakedbpw-2b@127.0.0.1:5432/family_media?sslmode=disable\n'
  printf 'FM_HANDOFF_KEY_ID=fakekid-3c\n'
  printf 'FM_HANDOFF_PRIVATE_KEY_PEM=%s\n' "$PEM"
}
memorial_env() {
  printf 'DATABASE_URL=postgresql://x@127.0.0.1/memorial_site\n'
  printf 'APP_KEY=base64:fakememkey-5e\n'
  printf 'CLOUDFRONT_MEDIA_KEY_PAIR_ID=fakecf-6f\n'
  printf 'AWS_ACCESS_KEY_ID=fakeaws-7g\n'
  printf 'DUP=fakedupval-0j-a\nDUP=fakedupval-0j-b\n'
}
FAM="$SECRETS/family-media/api-laravel.env"
MEM="$SECRETS/aiqiuqi-memorial/api.env"
stored() { printf '%s/%s' "$STORE" "$(printf '%s' "$1" | tr '/' '_')"; }
version_of() { cat "$(stored "$1").version"; }
put_mirror() { printf '%s' "$2" >"$(stored "$1")"; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }

run() { # records every output for the leak check
  local out rc=0
  out=$(env PATH="$BIN:$PATH" STUB_DIR="$TMP" TMPDIR="${RUN_TMPDIR-$WORKTMP}" ENVSSM_SHM_DIR="${RUN_SHM-$TMP/no-shm}" \
    ENVSSM_SECRETS_ROOT="$SEED" "$@" 2>&1) || rc=$?
  printf '%s\n' "$out" >>"$OUTLOG"
  printf '%s\n' "$out"
  return "$rc"
}
seed() { # service file: writes /env/<service> from a file, as the backup did
  local rel
  case "$1" in
    family-media/api) rel=family-media/api-laravel.env ;;
    aiqiuqi-memorial/api) rel=aiqiuqi-memorial/api.env ;;
    *) fail "seed: unknown $1" ;;
  esac
  cp "$2" "$SEED/$rel"
  run "$SH" "$TMP/seedtool/scripts/env-to-ssm.sh" --profile env-backup-temp "$1" >/dev/null || fail "seeding $1 failed"
}
assert_tmp_clean() { [ -z "$(ls -A "$WORKTMP")" ] || fail "$1: temp files left behind: $(ls -A "$WORKTMP")"; }
assert_no_fakes() {
  local f
  for f in "${FAKES[@]}" "$@"; do
    grep -qi -- "$f" "$OUTLOG" && fail "the fake value $f appeared in output"
  done
  return 0
}
