#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for the deploy side of "/env is the source of truth"
# (README "Env files from SSM"): both Laravel deploys pull the whole env file
# with scripts/ssm-to-env.sh under their read profile, read-only, before the
# shape check; fail closed with the live file untouched on a read, hash or
# shape failure (the shape is checked on the staged copy); leave an identical
# file alone; keep exactly one .bak; put that .bak back when a failed release
# is rolled back; print versions, never a hash of the file; never call a
# per-key refresh; and only warn (by name) when a per-key mirror differs.
# Stubs and fixtures: tests/lib/env-ssm-stubs.sh. Env-edit: verify-env-edit.sh.
#
# ENVSSM_TEST_SH=dash runs the POSIX scripts called directly here under dash
# (the deploys call ssm-to-env.sh through its #!/bin/sh, dash on Ubuntu).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/env-ssm-stubs.sh
. "$ROOT/tests/lib/env-ssm-stubs.sh"

DEPLOYLOG="$TMP/deploy-output.log"
deploy() { # family|memorial
  local out rc=0
  : >"$LOG"; rm -f "$TMP/aws.calls"
  out=$(cd "$REPO" && run env CALLS="$LOG" STUB_PIN="$PREV" FAMILY_LARAVEL_ENV_FILE="$FAM" FAMILY_DUMP_DIR="$TMP/dumps" \
    MEMORIAL_ENV_FILE="$MEM" MEMORIAL_PREMIGRATE_DIR="$TMP/premigrate" bash "scripts/deploy-$1-api-laravel.sh" "$REL") || rc=$?
  printf '%s\n' "$out" >>"$DEPLOYLOG"
  printf '%s\n' "$out"
  return "$rc"
}
called() { grep -qF -- "$1" "$LOG"; }
line_of() { { grep -nF -- "$1" "$LOG" || true; } | head -1 | cut -d: -f1; }
bak_count() { find "$(dirname "$1")" -maxdepth 1 -name "$(basename "$1").bak-*" | wc -l | tr -d ' '; }
assert_no_refresh() { called refresh- && fail "$1: a per-key refresh ran:\n$(grep refresh- "$LOG")"; return 0; }
assert_untouched() { # what
  called "docker" && fail "$1: docker ran:\n$(cat "$LOG")"
  called "pg_dump" && fail "$1: pg_dump ran"
  called "image-pins.sh promote" && fail "$1: the pin moved"
  return 0
}
envfile_of() { case "$1" in family) echo "$FAM" ;; memorial) echo "$MEM" ;; esac; }
svc_of() { case "$1" in family) echo family-media/api ;; memorial) echo aiqiuqi-memorial/api ;; esac; }
seedfile_of() { case "$1" in family) echo "$TMP/fam-seed.env" ;; memorial) echo "$TMP/mem-seed.env" ;; esac; }

family_env >"$TMP/fam-seed.env"
memorial_env >"$TMP/mem-seed.env"
seed family-media/api "$TMP/fam-seed.env"
seed aiqiuqi-memorial/api "$TMP/mem-seed.env"
put_mirror /family-media/prod/FM_HANDOFF_KEY_ID fakekid-3c
put_mirror /family-media/prod/FM_HANDOFF_PRIVATE_KEY_PEM "$PEM"

# 1. SSM equals the host file, both services: the file is left alone (same
# inode and content, no .bak), the deploy finishes, the log names versions.
for app in family memorial; do
  f=$(envfile_of "$app"); svc=$(svc_of "$app")
  cp "$(seedfile_of "$app")" "$f"; chmod 600 "$f"
  ino_before=$(inode "$f")
  OUT=$(deploy "$app") || fail "$app: deploy with an identical file failed:\n$OUT"
  grep -q "$f unchanged (/env/$svc v1, /env/$svc-pem v1)" <<<"$OUT" || fail "$app: expected the unchanged report with versions:\n$OUT"
  [ "$(inode "$f")" = "$ino_before" ] || fail "$app: an identical file was rewritten"
  cmp -s "$f" "$(seedfile_of "$app")" || fail "$app: an identical file changed"
  [ "$(bak_count "$f")" = 0 ] || fail "$app: an unchanged pull made a .bak"
  called "image-pins.sh promote" || fail "$app: an unchanged pull did not finish the deploy:\n$(cat "$LOG")"
  assert_no_refresh "$app identical"
  assert_tmp_clean "$app identical"
done
grep -q 'mirrors: 2 match, 0 differ, 0 unreadable' "$DEPLOYLOG" || fail "expected both family mirrors to match"

# 2. SSM differs: the pull runs before compose, under family-ssm, read-only,
# values only at the versions read; the file becomes the SSM content; the
# replaced file is the one .bak; an older timestamped .bak is pruned; a
# non-timestamp .bak is not ours and stays.
printf 'OLD=1\n' >"$FAM"
printf 'old\n' >"$FAM.bak-20200101T000000Z"
printf 'mine\n' >"$FAM.bak-manual"
OUT=$(deploy family) || fail "deploy with a changed file failed:\n$OUT"
grep -q "changed: installed $FAM from /env/family-media/api v1, /env/family-media/api-pem v1, [0-9]* bytes (hash verified)" <<<"$OUT" \
  || fail "expected the changed report with versions:\n$OUT"
cmp -s "$FAM" "$TMP/fam-seed.env" || fail "the deploy did not install the SSM content"
n_get=$(line_of "aws family-ssm get-parameter /env/family-media/api:1"); n_pull=$(line_of "compose pull")
[ -n "$n_get" ] && [ -n "$n_pull" ] && [ "$n_get" -lt "$n_pull" ] || fail "the SSM read must come before compose pull:\n$(cat "$LOG")"
grep 'get-parameter /env/' "$TMP/aws.calls" | grep -v 'Parameter.Version' | grep -qv ':[0-9]* ' \
  && fail "a value was read without pinning the version just read:\n$(cat "$TMP/aws.calls")"
awk '{print $1}' "$TMP/aws.calls" | sort -u | grep -qvx family-ssm && fail "the family deploy used a profile other than family-ssm:\n$(cat "$TMP/aws.calls")"
awk '{print $2}' "$TMP/aws.calls" | sort -u | grep -qvx get-parameter && fail "the deploy did more than read:\n$(cat "$TMP/aws.calls")"
[ "$(bak_count "$FAM")" = 2 ] || fail "expected the new .bak plus the foreign .bak-manual:\n$(ls "$SECRETS/family-media")"
[ ! -e "$FAM.bak-20200101T000000Z" ] || fail "an older .bak was not pruned"
[ -e "$FAM.bak-manual" ] || fail "a .bak that is not ours was deleted"
[ "$(cat "$FAM".bak-2026*)" = OLD=1 ] || fail "the .bak does not hold the replaced file"
assert_no_refresh "changed"
rm -f "$FAM".bak-*

# 3. A malformed stored file is refused on the staged copy, both services:
# the live file is unchanged, no .bak, nothing downstream runs, line numbers only.
printf 'GOOD=1\nnot a key value fakesecond-9i\n' >"$TMP/bad.env"
for app in family memorial; do
  f=$(envfile_of "$app"); svc=$(svc_of "$app")
  seed "$svc" "$TMP/bad.env"
  cp "$(seedfile_of "$app")" "$f"; cp "$f" "$TMP/host-copy"
  if OUT=$(deploy "$app"); then fail "$app: a malformed pulled file must stop the deploy"; fi
  grep -q 'line(s) 2 are not KEY=value (content withheld) -- nothing written' <<<"$OUT" || fail "$app: the staged shape check did not refuse:\n$OUT"
  grep -q 'nothing was changed' <<<"$OUT" || fail "$app: expected 'nothing was changed':\n$OUT"
  cmp -s "$f" "$TMP/host-copy" || fail "$app: a malformed pull replaced the live file"
  [ "$(bak_count "$f")" = 0 ] || fail "$app: a refused pull made a .bak"
  assert_untouched "$app malformed pull"
  seed "$svc" "$(seedfile_of "$app")"
done

# 4. Fail closed, both services: a read failure or a hash mismatch stops before
# pull, migrate and swap, says "nothing was changed", and the file is byte for
# byte as it was. A valid host file, so without the stop the deploy would go on.
for app in family memorial; do
  f=$(envfile_of "$app"); svc=$(svc_of "$app")
  { cat "$(seedfile_of "$app")"; printf 'HOST=1\n'; } >"$f"; cp "$f" "$TMP/host-copy"
  for failure in "STUB_FAIL_GET=/env/$svc-pem" "STUB_CORRUPT=/env/$svc"; do
    if OUT=$(export "${failure?}"; deploy "$app"); then fail "$app $failure: the deploy must fail"; fi
    grep -q 'nothing was changed' <<<"$OUT" || fail "$app $failure: expected 'nothing was changed':\n$OUT"
    cmp -s "$f" "$TMP/host-copy" || fail "$app $failure: the env file changed"
    [ "$(bak_count "$f")" = 0 ] || fail "$app $failure: a .bak was made"
    assert_untouched "$app $failure"
    assert_tmp_clean "$app $failure"
  done
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

# 6. Memorial: its own read profile, which cannot read family's pair.
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
rm -f "$MEM".bak-*

# 7. Rollback after the swap, both services: the release that is rolled back
# to gets the env file the pull replaced (0600, same owner), with a warning.
for app in family memorial; do
  f=$(envfile_of "$app")
  { cat "$(seedfile_of "$app")"; printf 'PREVIOUS=1\n'; } >"$f"; chmod 640 "$f"; cp "$f" "$TMP/host-copy"
  rm -f "$TMP/chown.log"
  if OUT=$(STUB_READY=0 deploy "$app"); then fail "$app: an unready release must fail the deploy"; fi
  grep -F "compose up -d" "$LOG" | grep -qF "[tag=$PREV]" || fail "$app: did not roll back to $PREV:\n$(cat "$LOG")"
  cmp -s "$f" "$TMP/host-copy" || fail "$app: the rollback did not restore the previous env file"
  [ "$(file_mode "$f")" = 600 ] || fail "$app: the restored env file must be 0600, got $(file_mode "$f")"
  grep -q "chown [0-9]*:[0-9]* $f.rollback." "$TMP/chown.log" || fail "$app: the restored file was not chowned to the owner:\n$(cat "$TMP/chown.log" 2>/dev/null)"
  grep -q "WARNING: restored $f from $f.bak-.* now differs from /env/" <<<"$OUT" || fail "$app: expected the differs-from-/env warning:\n$OUT"
  n_restore=$(grep -n "restored $f" <<<"$OUT" | head -1 | cut -d: -f1)
  [ -n "$n_restore" ] || fail "$app: no restore line"
  ls "$f".rollback.* >/dev/null 2>&1 && fail "$app: a rollback temp file was left"
  rm -f "$f".bak-*
done
# A rollback with nothing pulled (identical file) leaves the file alone.
cp "$TMP/fam-seed.env" "$FAM"
if OUT=$(STUB_READY=0 deploy family); then fail "an unready release must fail"; fi
grep -q 'restored ' <<<"$OUT" && fail "nothing was pulled, yet the rollback restored a file:\n$OUT"
cmp -s "$FAM" "$TMP/fam-seed.env" || fail "the identical file changed in a rollback"

# 8. No fake value, and no hash of an env file, ever reached a deploy log.
# shellcheck disable=SC2119 # no extra tokens here
assert_no_fakes
grep -Eq '[0-9a-f]{64}' "$DEPLOYLOG" && fail "a sha256 reached the deploy output:\n$(grep -E '[0-9a-f]{64}' "$DEPLOYLOG")"

echo "PASS: deploys pull the whole env from /env (read profile, pinned versions, before the shape check, staged shape check, fail closed, identical file untouched, one .bak restored on rollback, no hash in the log, no per-key refresh, mirrors only warned)"
