#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub sources are literal on purpose
set -euo pipefail

# Behavioural test for "/env is the source of truth" (README "Env files from
# SSM"): both Laravel deploys pull the whole env file with scripts/ssm-to-env.sh
# under their read profile before the shape check, fail closed with nothing
# touched, leave an identical file alone, keep exactly one .bak, never call a
# per-key refresh, and only warn (by name) when a per-key mirror differs;
# scripts/env-edit.sh round-trips through the real format, shows key names
# only, refuses CR / reserved / malformed / new-duplicate / oversize content,
# refuses a concurrent change, needs an explicit writer profile that is not a
# read profile, and cleans up. `aws` is a stubbed Parameter Store with
# per-profile permissions; docker, sudo and pg_* are stubbed. Fake values only.
#
# ENVSSM_TEST_SH=dash runs the POSIX scripts called directly here under dash.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="${ENVSSM_TEST_SH:-sh}"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

REL=1111111111111111111111111111111111111111
PREV=2222222222222222222222222222222222222222
REPO="$TMP/repo"; BIN="$TMP/bin"; STORE="$TMP/store"; WORKTMP="$TMP/tmpdir"
SECRETS="$TMP/secrets"; SEED="$TMP/seed"; LOG="$TMP/calls.log"; OUTLOG="$TMP/all-output.log"
mkdir -p "$REPO/scripts/lib" "$BIN" "$STORE" "$WORKTMP" "$SECRETS"/{family-media,aiqiuqi-memorial} \
  "$SEED"/{family-media,aiqiuqi-memorial} "$TMP/dumps" "$TMP/premigrate"
for f in deploy-family-api-laravel.sh deploy-memorial-api-laravel.sh ssm-to-env.sh env-to-ssm.sh env-edit.sh \
         env-ssm-mirror-check.sh lib/env-ssm-lib.sh; do
  cp "$ROOT/scripts/$f" "$REPO/scripts/$f"
done
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

# --- aws: a Parameter Store with per-profile rights ------------------------------
# env-backup-temp: put/get/tag /env/*. family-ssm / memorial-ssm: get only their
# own /env pair and their own per-key prefix (the policy the CEO applies).
cat >"$BIN/aws" <<'STUB'
#!/usr/bin/env bash
set -u
op='' name='' value='' profile=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    ssm) op=$2; shift ;;
    --name|--resource-id) name=$2; shift ;;
    --value) value=$2; shift ;;
    --profile) profile=$2; shift ;;
  esac
  shift
done
printf '%s %s %s\n' "$profile" "$op" "$name" >>"$STUB_DIR/aws.calls"
[ -z "${CALLS:-}" ] || echo "aws $profile $op $name" >>"$CALLS"
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
    src="$STUB_DIR/store/$key${version:+.v$version}"
    [ -f "$src" ] || { echo "An error occurred (ParameterNotFound) when calling the GetParameter operation" >&2; exit 254; }
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
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/chown"
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
echo "docker $*" >>"$CALLS"
case "$*" in "compose ps -q --status running"*) echo sched-id ;; esac
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

run() { # records every output for the leak check at the end
  local out rc=0
  out=$(env PATH="$BIN:$PATH" STUB_DIR="$TMP" TMPDIR="$WORKTMP" ENVSSM_SHM_DIR="$TMP/no-shm" \
    ENVSSM_SECRETS_ROOT="$SEED" "$@" 2>&1) || rc=$?
  printf '%s\n' "$out" >>"$OUTLOG"
  printf '%s\n' "$out"
  return "$rc"
}
# Seeds /env/<svc> from a file, as the backup did (the real env-to-ssm.sh).
seed() { # service file
  local rel; rel=$(awk -v s="$1" '$1 == s { print $2 }' <<<"family-media/api family-media/api-laravel.env
aiqiuqi-memorial/api aiqiuqi-memorial/api.env")
  cp "$2" "$SEED/$rel"
  run "$SH" "$REPO/scripts/env-to-ssm.sh" --profile env-backup-temp "$1" >/dev/null || fail "seeding $1 failed"
}
edit() { run "$SH" "$REPO/scripts/env-edit.sh" "$@"; }
restore_to() { run "$SH" "$REPO/scripts/ssm-to-env.sh" --profile env-backup-temp --target "$2" "$1" >/dev/null; }
deploy() { # family|memorial
  : >"$LOG"; rm -f "$TMP/aws.calls"
  (cd "$REPO" && run env CALLS="$LOG" STUB_PIN="$PREV" FAMILY_LARAVEL_ENV_FILE="$FAM" FAMILY_DUMP_DIR="$TMP/dumps" \
    MEMORIAL_ENV_FILE="$MEM" MEMORIAL_PREMIGRATE_DIR="$TMP/premigrate" bash "scripts/deploy-$1-api-laravel.sh" "$REL")
}
called() { grep -qF -- "$1" "$LOG"; }
line_of() { { grep -nF -- "$1" "$LOG" || true; } | head -1 | cut -d: -f1; }
bak_count() { find "$(dirname "$1")" -maxdepth 1 -name "$(basename "$1").bak-*" | wc -l | tr -d ' '; }
assert_tmp_clean() { [ -z "$(ls -A "$WORKTMP")" ] || fail "$1: temp files left behind: $(ls -A "$WORKTMP")"; }
assert_no_refresh() { called refresh- && fail "$1: a per-key refresh ran:\n$(grep refresh- "$LOG")"; return 0; }
assert_untouched() { # what
  called "docker" && fail "$1: docker ran:\n$(cat "$LOG")"
  called "pg_dump" && fail "$1: pg_dump ran"
  called "image-pins.sh promote" && fail "$1: the pin moved"
  return 0
}

family_env >"$TMP/fam-seed.env"
memorial_env >"$TMP/mem-seed.env"
seed family-media/api "$TMP/fam-seed.env"
seed aiqiuqi-memorial/api "$TMP/mem-seed.env"
put_mirror /family-media/prod/FM_HANDOFF_KEY_ID fakekid-3c
put_mirror /family-media/prod/FM_HANDOFF_PRIVATE_KEY_PEM "$PEM"

# 1. SSM equals the host file: the deploy leaves it alone (same inode and
# content, no .bak), runs every later step, calls no refresh.
cp "$TMP/fam-seed.env" "$FAM"; chmod 600 "$FAM"
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
ino_before=$(inode "$FAM")
OUT=$(deploy family) || fail "deploy with an identical file failed:\n$OUT"
grep -q 'already matches /env/family-media/api .* unchanged' <<<"$OUT" || fail "expected the unchanged report:\n$OUT"
[ "$(inode "$FAM")" = "$ino_before" ] || fail "an identical file was rewritten"
cmp -s "$FAM" "$TMP/fam-seed.env" || fail "an identical file changed"
[ "$(bak_count "$FAM")" = 0 ] || fail "an unchanged pull made a .bak"
called "image-pins.sh promote family-api-laravel $REL" || fail "an unchanged pull did not finish the deploy:\n$(cat "$LOG")"
assert_no_refresh "identical"
grep -q 'mirrors: 2 match, 0 differ, 0 unreadable' <<<"$OUT" || fail "expected both family mirrors to match:\n$OUT"
assert_tmp_clean "identical deploy"

# 2. SSM differs: the pull runs before compose, under family-ssm, read-only;
# the file becomes the SSM content; the replaced file is the one .bak and an
# older refresh-style .bak is pruned; a non-timestamp .bak is not ours, kept.
printf 'OLD=1\n' >"$FAM"
printf 'old\n' >"$FAM.bak-20200101T000000Z"
printf 'mine\n' >"$FAM.bak-manual"
OUT=$(deploy family) || fail "deploy with a changed file failed:\n$OUT"
cmp -s "$FAM" "$TMP/fam-seed.env" || fail "the deploy did not install the SSM content"
n_get=$(line_of "aws family-ssm get-parameter /env/family-media/api"); n_pull=$(line_of "compose pull")
[ -n "$n_get" ] && [ -n "$n_pull" ] && [ "$n_get" -lt "$n_pull" ] || fail "the SSM read must come before compose pull:\n$(cat "$LOG")"
awk '{print $1}' "$TMP/aws.calls" | sort -u | grep -qvx family-ssm && fail "the family deploy used a profile other than family-ssm:\n$(cat "$TMP/aws.calls")"
awk '{print $2}' "$TMP/aws.calls" | sort -u | grep -qvx get-parameter && fail "the deploy did more than read:\n$(cat "$TMP/aws.calls")"
[ "$(bak_count "$FAM")" = 2 ] || fail "expected the new .bak plus the foreign .bak-manual:\n$(ls "$SECRETS/family-media")"
[ ! -e "$FAM.bak-20200101T000000Z" ] || fail "an older .bak was not pruned"
[ -e "$FAM.bak-manual" ] || fail "a .bak that is not ours was deleted"
[ "$(cat "$FAM".bak-2026*)" = OLD=1 ] || fail "the .bak does not hold the replaced file"
assert_no_refresh "changed"
rm -f "$FAM.bak-manual"

# 3. The pull comes BEFORE the shape check: a malformed SSM file (a valid host
# file before) is what the shape check refuses, and compose never runs.
printf 'GOOD=1\nnot a key value line\n' >"$TMP/bad.env"
seed family-media/api "$TMP/bad.env"
cp "$TMP/fam-seed.env" "$FAM"
if OUT=$(deploy family); then fail "a malformed pulled file must stop the deploy"; fi
grep -q 'line 2: not KEY=VALUE' <<<"$OUT" || fail "the shape check did not see the pulled file:\n$OUT"
assert_untouched "malformed pull"
seed family-media/api "$TMP/fam-seed.env"
rm -f "$FAM".bak-*

# 4. Fail closed: a read failure or a hash mismatch stops before pull, migrate
# and swap, says "nothing was changed", and the file is byte-for-byte as it was.
# A valid host file: without the stop, the deploy would go on to docker.
{ cat "$TMP/fam-seed.env"; printf 'HOST=1\n'; } >"$FAM"; cp "$FAM" "$TMP/host-copy"
for failure in "STUB_FAIL_GET=/env/family-media/api-pem" "STUB_CORRUPT=/env/family-media/api"; do
  if OUT=$(export "${failure?}"; deploy family); then
    fail "$failure: the deploy must fail"
  fi
  grep -q 'nothing was changed' <<<"$OUT" || fail "$failure: expected 'nothing was changed':\n$OUT"
  cmp -s "$FAM" "$TMP/host-copy" || fail "$failure: the env file changed"
  [ "$(bak_count "$FAM")" = 0 ] || fail "$failure: a .bak was made"
  assert_untouched "$failure"
  assert_tmp_clean "$failure"
done

# 5. A stale per-key mirror: /env wins, the deploy warns by NAME and succeeds.
put_mirror /family-media/prod/FM_HANDOFF_PRIVATE_KEY_PEM "-----BEGIN PRIVATE KEY-----\\nfakesecond-9i\\n-----END PRIVATE KEY-----"
cp "$TMP/fam-seed.env" "$FAM"
OUT=$(deploy family) || fail "a stale mirror must not fail the deploy:\n$OUT"
grep -q 'WARNING: FM_HANDOFF_PRIVATE_KEY_PEM .* differs from /family-media/prod/FM_HANDOFF_PRIVATE_KEY_PEM' <<<"$OUT" \
  || fail "expected the mirror warning for the PEM:\n$OUT"
grep -q 'FM_HANDOFF_KEY_ID .*differs' <<<"$OUT" && fail "a matching mirror was reported"
grep -q 'mirrors: 1 match, 1 differ' <<<"$OUT" || fail "expected 1 match, 1 differ:\n$OUT"
cmp -s "$FAM" "$TMP/fam-seed.env" || fail "the mirror's value reached the file (/env must win)"
put_mirror /family-media/prod/FM_HANDOFF_PRIVATE_KEY_PEM "$PEM"

# 6. Memorial: same model, its own read profile, which cannot read family's pair.
printf 'APP_KEY=base64:stale\n' >"$MEM"
OUT=$(deploy memorial) || fail "memorial deploy failed:\n$OUT"
cmp -s "$MEM" "$TMP/mem-seed.env" || fail "the memorial deploy did not install /env/aiqiuqi-memorial/api"
awk '{print $1}' "$TMP/aws.calls" | sort -u | grep -qvx memorial-ssm && fail "the memorial deploy used another profile"
assert_no_refresh "memorial"
grep -q 'could not read /aiqiuqi-memorial/preview/APP_KEY -- APP_KEY not compared' <<<"$OUT" || fail "an absent mirror must be reported, not fatal:\n$OUT"
called "image-pins.sh promote memorial-api-laravel $REL" || fail "the memorial deploy did not finish"
if OUT=$(run "$SH" "$REPO/scripts/ssm-to-env.sh" --profile family-ssm --target "$TMP/x.env" aiqiuqi-memorial/api); then
  fail "family-ssm must not read the memorial pair"
fi
grep -q AccessDenied <<<"$OUT" || fail "expected AccessDenied for the other service's pair:\n$OUT"

# 7. env-edit refuses without an explicit writer, with a read profile, and for
# a service whose deploy does not pull /env -- before any AWS call.
rm -f "$TMP/aws.calls"
if OUT=$(AWS_PROFILE=env-backup-temp edit --from-file "$TMP/fam-seed.env" family-media/api); then fail "env-edit ran without --profile"; fi
grep -q 'no writer profile' <<<"$OUT" || fail "expected the no-writer refusal:\n$OUT"
if OUT=$(edit --profile family-ssm --from-file "$TMP/fam-seed.env" family-media/api); then fail "env-edit ran with a read profile"; fi
grep -q 'is a service read profile' <<<"$OUT" || fail "expected the read-profile refusal:\n$OUT"
if OUT=$(edit --profile env-backup-temp --from-file "$TMP/fam-seed.env" securevault/api); then fail "env-edit edited a non-canonical service"; fi
grep -q 'not edited here' <<<"$OUT" || fail "expected the service refusal:\n$OUT"
[ ! -e "$TMP/aws.calls" ] || fail "a refused env-edit called aws:\n$(cat "$TMP/aws.calls")"

# 8. Round trip (--from-file): names-only diff, new versions, exact content.
v_main=$(version_of /env/aiqiuqi-memorial/api); v_pem=$(version_of /env/aiqiuqi-memorial/api-pem)
{ grep -v '^AWS_ACCESS_KEY_ID=' "$TMP/mem-seed.env" | sed 's/fakememkey-5e/fakenewval-8h/'; printf 'NEW_KEY=fakenewval-8h\n'; } >"$TMP/mem-new.env"
rm -f "$TMP/aws.calls"
OUT=$(edit --profile env-backup-temp --from-file "$TMP/mem-new.env" aiqiuqi-memorial/api) || fail "env-edit round trip failed:\n$OUT"
grep -qx '  added   NEW_KEY' <<<"$OUT" || fail "NEW_KEY not listed as added:\n$OUT"
grep -qx '  removed AWS_ACCESS_KEY_ID' <<<"$OUT" || fail "AWS_ACCESS_KEY_ID not listed as removed:\n$OUT"
grep -qx '  changed APP_KEY' <<<"$OUT" || fail "APP_KEY not listed as changed:\n$OUT"
grep -q 'changed DUP\|changed DATABASE_URL\|CLOUDFRONT' <<<"$OUT" && fail "an unchanged key was listed:\n$OUT"
[ "$(version_of /env/aiqiuqi-memorial/api)" = $((v_main + 1)) ] && [ "$(version_of /env/aiqiuqi-memorial/api-pem)" = $((v_pem + 1)) ] \
  || fail "both parts must get a new version"
grep -q "wrote /env/aiqiuqi-memorial/api version $((v_main + 1)) and /env/aiqiuqi-memorial/api-pem version $((v_pem + 1))" <<<"$OUT" \
  || fail "the new versions were not printed:\n$OUT"
grep -q 'note: APP_KEY is also kept in /aiqiuqi-memorial/preview/APP_KEY' <<<"$OUT" || fail "no mirror reminder for APP_KEY:\n$OUT"
awk '{print $1}' "$TMP/aws.calls" | sort -u | grep -qvx env-backup-temp && fail "env-edit used a profile other than the writer"
restore_to aiqiuqi-memorial/api "$TMP/rt.env" || fail "restoring the edited pair failed"
cmp -s "$TMP/rt.env" "$TMP/mem-new.env" || fail "the edited pair does not restore to the edited file"
head -n 1 "$(stored /env/aiqiuqi-memorial/api)" | grep -q '^#env-ssm v1 sha256=' || fail "env-edit did not write the env-ssm v1 format"
assert_tmp_clean "round trip"
# The long PEM goes to -pem exactly as env-to-ssm.sh would put it.
{ cat "$TMP/fam-seed.env"; printf 'EXTRA=1\n'; } >"$TMP/fam-new.env"
OUT=$(edit --profile env-backup-temp --from-file "$TMP/fam-new.env" family-media/api) || fail "family edit failed:\n$OUT"
head -n 1 "$(stored /env/family-media/api-pem)" | grep -qx '#env-ssm-pem v1 lines=1' || fail "the PEM line did not go to -pem"
{ restore_to family-media/api "$TMP/rt2.env" && cmp -s "$TMP/rt2.env" "$TMP/fam-new.env"; } || fail "family round trip differs"
# No change: nothing written.
v=$(version_of /env/family-media/api)
OUT=$(edit --profile env-backup-temp --from-file "$TMP/fam-new.env" family-media/api) || fail "a no-op edit must pass"
grep -q 'no change; nothing written' <<<"$OUT" && [ "$(version_of /env/family-media/api)" = "$v" ] || fail "a no-op edit wrote:\n$OUT"

# 9. Interactive: $EDITOR edits the plain file; "n" writes nothing, "y" writes.
cat >"$BIN/fake-editor" <<'STUB'
#!/bin/sh
sed 's/^EXTRA=1$/EXTRA=fakesecond-9i/' "$1" >"$1.x" && mv "$1.x" "$1"
STUB
chmod +x "$BIN/fake-editor"
v=$(version_of /env/family-media/api)
if OUT=$(printf 'n\n' | EDITOR=fake-editor edit --profile env-backup-temp family-media/api); then fail "an unconfirmed edit must exit non-zero"; fi
grep -q 'not confirmed; nothing written' <<<"$OUT" && [ "$(version_of /env/family-media/api)" = "$v" ] || fail "an unconfirmed edit wrote:\n$OUT"
OUT=$(printf 'y\n' | EDITOR=fake-editor edit --profile env-backup-temp family-media/api) || fail "a confirmed edit failed:\n$OUT"
grep -qx '  changed EXTRA' <<<"$OUT" || fail "the editor's change was not listed:\n$OUT"
[ "$(version_of /env/family-media/api)" = $((v + 1)) ] || fail "a confirmed edit did not write"
{ restore_to family-media/api "$TMP/rt3.env" && grep -qx 'EXTRA=fakesecond-9i' "$TMP/rt3.env"; } || fail "the editor's change is not in SSM"
assert_tmp_clean "interactive"

# 10. Refusals: nothing written, temp dir removed, line numbers / names only.
refuse() { # label expected-message file
  local v0 out
  v0=$(version_of /env/aiqiuqi-memorial/api)
  if out=$(edit --profile env-backup-temp --from-file "$3" aiqiuqi-memorial/api); then fail "$1 must be refused:\n$out"; fi
  grep -q -- "$2" <<<"$out" || fail "$1: expected '$2', got:\n$out"
  [ "$(version_of /env/aiqiuqi-memorial/api)" = "$v0" ] || fail "$1: something was written"
  assert_tmp_clean "$1"
}
printf 'A=1\nB=fakecrval-1k\r\n' >"$TMP/cr.env";            refuse CR 'CR byte on line(s) 2' "$TMP/cr.env"
printf 'A=1\n#env-ssm end\n' >"$TMP/res.env";               refuse reserved 'reserves' "$TMP/res.env"
printf 'A=1\nexport B=2\nfakecrval-1k\n' >"$TMP/shape.env"; refuse shape 'line(s) 2,3 are not KEY=value' "$TMP/shape.env"
printf 'A=1\nA=fakedupval-0j\n' >"$TMP/dup.env";            refuse "new duplicate" 'duplicate key(s): A' "$TMP/dup.env"
{ cat "$TMP/mem-new.env"; printf 'DUP=fakedupval-0j-c\n'; } >"$TMP/dup3.env"; refuse "more duplicates" 'duplicate key(s): DUP' "$TMP/dup3.env"
for i in $(seq 1 300); do printf 'KEY_%03d=0123456789\n' "$i"; done >"$TMP/big.env"; refuse "oversize main" 'over the 4096-byte' "$TMP/big.env"
for i in 1 2 3 4 5 6 7; do printf 'K%s=%s\n' "$i" "$PEM"; done >"$TMP/bigpem.env"; refuse "oversize -pem" 'api-pem would be' "$TMP/bigpem.env"
: >"$TMP/empty.env";                                        refuse empty 'empty' "$TMP/empty.env"
# An existing duplicate may stay (DUP twice in the current pair), its value changed.
sed 's/fakedupval-0j-b/fakedupval-0j-z/' "$TMP/mem-new.env" >"$TMP/dup-ok.env"
OUT=$(edit --profile env-backup-temp --from-file "$TMP/dup-ok.env" aiqiuqi-memorial/api) || fail "an existing duplicate must be allowed:\n$OUT"
grep -qx '  changed DUP' <<<"$OUT" || fail "the existing duplicate's change was not listed"

# 11. A corrupted latest pair, and a concurrent edit, are refused.
if OUT=$(STUB_CORRUPT=/env/aiqiuqi-memorial/api edit --profile env-backup-temp --from-file "$TMP/mem-new.env" aiqiuqi-memorial/api); then
  fail "a corrupted latest pair must be refused"
fi
grep -q 'nothing written\|do not reassemble' <<<"$OUT" || fail "expected a refusal for the corrupted pair:\n$OUT"
cat >"$BIN/racing-editor" <<'STUB'
#!/bin/sh
printf 'RACE=1\n' >>"$1"
# Someone else's edit lands while this one is open.
printf 'changed' >>"$STUB_DIR/store/_env_family-media_api"
STUB
chmod +x "$BIN/racing-editor"
v=$(version_of /env/family-media/api)
if OUT=$(printf 'y\n' | EDITOR=racing-editor edit --profile env-backup-temp family-media/api); then fail "a concurrent change must be refused"; fi
grep -q 'changed since it was fetched' <<<"$OUT" || fail "expected the concurrency refusal:\n$OUT"
[ "$(version_of /env/family-media/api)" = "$v" ] || fail "a concurrent change was overwritten"
assert_tmp_clean "concurrent"

# 11b. What SSM returns after the write must rebuild the edited file.
cp "$(stored /env/family-media/api).v$v" "$(stored /env/family-media/api)"   # undo the race of 11
rm -f "$TMP/put.done"
{ cat "$TMP/fam-new.env"; printf 'READBACK=1\n'; } >"$TMP/rb.env"
if OUT=$(STUB_CORRUPT_AFTER_PUT=/env/family-media/api edit --profile env-backup-temp --from-file "$TMP/rb.env" family-media/api); then
  fail "a read-back that does not match must fail env-edit:\n$OUT"
fi
grep -q 'sha256 MISMATCH between the edited file and SSM' <<<"$OUT" || fail "expected the read-back mismatch:\n$OUT"
rm -f "$TMP/put.done"
assert_tmp_clean "read-back"

# 12. No fake value ever reached any output.
for f in "${FAKES[@]}"; do
  grep -qi -- "$f" "$OUTLOG" && fail "the fake value $f appeared in output"
done

echo "PASS: deploys pull the whole env from /env (read profile, before the shape check, fail closed, identical file untouched, one .bak, no per-key refresh, mirrors only warned); env-edit round-trips with a names-only diff, refuses bad content, needs an explicit writer"
