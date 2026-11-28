#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub sources are literal on purpose
set -euo pipefail

# Behavioural test for scripts/env-edit.sh (README "Env files from SSM"):
# writer identity (explicit --profile, not a read profile, sts says
# user/env-backup-temp); round trip through the real env-ssm format; key-name
# only diff; refusals (CR, reserved prefix, shape, new duplicate, size, empty);
# --from-file must be owner-only and needs --yes to skip the prompt; version
# race refused; read-back mismatch refused; the handoff key pair checked across
# family and memorial; the editor runs with HOME/XDG inside the work dir and
# vim without swap/viminfo/undo/backup; /dev/shm preferred; cleanup on every
# exit, an interrupt included; no value ever printed.
# Stubs and fixtures: tests/lib/env-ssm-stubs.sh. Needs openssl (the handoff
# check derives a public key; the host has it).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/env-ssm-stubs.sh
. "$ROOT/tests/lib/env-ssm-stubs.sh"
command -v openssl >/dev/null || fail "openssl is required for the handoff checks"

edit() { run "$SH" "$REPO/scripts/env-edit.sh" "$@"; }
restore_to() { run "$SH" "$REPO/scripts/ssm-to-env.sh" --profile env-backup-temp --target "$2" "$1" >/dev/null; }

family_env >"$TMP/fam-seed.env"
memorial_env >"$TMP/mem-seed.env"
seed family-media/api "$TMP/fam-seed.env"
seed aiqiuqi-memorial/api "$TMP/mem-seed.env"

# 1. Refused before any value is read: no --profile (AWS_PROFILE is ignored),
# a read profile, a non-canonical service, --yes without --from-file, and a
# profile that is not the IAM user env-backup-temp (only sts is called).
rm -f "$TMP/aws.calls"
if OUT=$(AWS_PROFILE=env-backup-temp edit --from-file "$TMP/fam-seed.env" --yes family-media/api); then fail "env-edit ran without --profile"; fi
grep -q 'no writer profile' <<<"$OUT" || fail "expected the no-writer refusal:\n$OUT"
if OUT=$(edit --profile family-ssm --from-file "$TMP/fam-seed.env" --yes family-media/api); then fail "env-edit ran with a read profile"; fi
grep -q 'is a service read profile' <<<"$OUT" || fail "expected the read-profile refusal:\n$OUT"
if OUT=$(edit --profile env-backup-temp --from-file "$TMP/fam-seed.env" --yes securevault/api); then fail "env-edit edited a non-canonical service"; fi
grep -q 'not edited here' <<<"$OUT" || fail "expected the service refusal:\n$OUT"
if OUT=$(edit --profile env-backup-temp --yes family-media/api); then fail "--yes without --from-file must be refused"; fi
grep -q -- '--yes is only for --from-file' <<<"$OUT" || fail "expected the --yes refusal:\n$OUT"
[ ! -e "$TMP/aws.calls" ] || fail "a refused env-edit called aws:\n$(cat "$TMP/aws.calls")"
if OUT=$(edit --profile someone-else --from-file "$TMP/fam-seed.env" --yes family-media/api); then fail "a non-writer identity must be refused"; fi
grep -q 'is not the IAM user env-backup-temp' <<<"$OUT" || fail "expected the identity refusal:\n$OUT"
[ "$(awk '{print $2}' "$TMP/aws.calls" | sort -u)" = sts-get-caller-identity ] || fail "a non-writer identity read more than sts:\n$(cat "$TMP/aws.calls")"
assert_tmp_clean "refusals"

# 2. Round trip (--from-file --yes): names-only diff, new versions, exact content.
v_main=$(version_of /env/aiqiuqi-memorial/api); v_pem=$(version_of /env/aiqiuqi-memorial/api-pem)
{ grep -v '^AWS_ACCESS_KEY_ID=' "$TMP/mem-seed.env" | sed 's/fakememkey-5e/fakenewval-8h/'; printf 'NEW_KEY=fakenewval-8h\n'; } >"$TMP/mem-new.env"
rm -f "$TMP/aws.calls"
OUT=$(edit --profile env-backup-temp --from-file "$TMP/mem-new.env" --yes aiqiuqi-memorial/api) || fail "env-edit round trip failed:\n$OUT"
grep -qx '  added   NEW_KEY' <<<"$OUT" || fail "NEW_KEY not listed as added:\n$OUT"
grep -qx '  removed AWS_ACCESS_KEY_ID' <<<"$OUT" || fail "AWS_ACCESS_KEY_ID not listed as removed:\n$OUT"
grep -qx '  changed APP_KEY' <<<"$OUT" || fail "APP_KEY not listed as changed:\n$OUT"
grep -q 'changed DUP\|changed DATABASE_URL\|CLOUDFRONT' <<<"$OUT" && fail "an unchanged key was listed:\n$OUT"
[ "$(version_of /env/aiqiuqi-memorial/api)" = $((v_main + 1)) ] && [ "$(version_of /env/aiqiuqi-memorial/api-pem)" = $((v_pem + 1)) ] \
  || fail "both parts must get a new version"
grep -q "wrote /env/aiqiuqi-memorial/api version $((v_main + 1)) and /env/aiqiuqi-memorial/api-pem version $((v_pem + 1))" <<<"$OUT" \
  || fail "the new versions were not printed:\n$OUT"
grep -q 'note: APP_KEY is also kept in /aiqiuqi-memorial/preview/APP_KEY' <<<"$OUT" || fail "no mirror reminder for APP_KEY:\n$OUT"
grep -q "note: $TMP/mem-new.env holds the whole env in plain text -- delete it" <<<"$OUT" || fail "no reminder to delete the source file:\n$OUT"
awk '{print $1}' "$TMP/aws.calls" | sort -u | grep -qvx env-backup-temp && fail "env-edit used a profile other than the writer"
restore_to aiqiuqi-memorial/api "$TMP/rt.env" || fail "restoring the edited pair failed"
cmp -s "$TMP/rt.env" "$TMP/mem-new.env" || fail "the edited pair does not restore to the edited file"
head -n 1 "$(stored /env/aiqiuqi-memorial/api)" | grep -q '^#env-ssm v1 sha256=' || fail "env-edit did not write the env-ssm v1 format"
assert_tmp_clean "round trip"
# The long PEM goes to -pem exactly as env-to-ssm.sh would put it.
{ cat "$TMP/fam-seed.env"; printf 'EXTRA=1\n'; } >"$TMP/fam-new.env"
OUT=$(edit --profile env-backup-temp --from-file "$TMP/fam-new.env" --yes family-media/api) || fail "family edit failed:\n$OUT"
head -n 1 "$(stored /env/family-media/api-pem)" | grep -qx '#env-ssm-pem v1 lines=1' || fail "the PEM line did not go to -pem"
{ restore_to family-media/api "$TMP/rt2.env" && cmp -s "$TMP/rt2.env" "$TMP/fam-new.env"; } || fail "family round trip differs"
# No change: nothing written.
v=$(version_of /env/family-media/api)
OUT=$(edit --profile env-backup-temp --from-file "$TMP/fam-new.env" --yes family-media/api) || fail "a no-op edit must pass"
{ grep -q 'no change; nothing written' <<<"$OUT" && [ "$(version_of /env/family-media/api)" = "$v" ]; } || fail "a no-op edit wrote:\n$OUT"

# 3. --from-file: group/other-readable is refused; without --yes it asks.
cp "$TMP/fam-new.env" "$TMP/open.env"; printf 'OPEN=1\n' >>"$TMP/open.env"; chmod 644 "$TMP/open.env"
rm -f "$TMP/aws.calls"
if OUT=$(edit --profile env-backup-temp --from-file "$TMP/open.env" --yes family-media/api); then fail "a 0644 source must be refused"; fi
grep -q 'is mode 644: readable by group or others' <<<"$OUT" || fail "expected the mode refusal:\n$OUT"
[ ! -e "$TMP/aws.calls" ] || fail "a refused source still called aws"
chmod 600 "$TMP/open.env"
v=$(version_of /env/family-media/api)
if OUT=$(printf 'n\n' | edit --profile env-backup-temp --from-file "$TMP/open.env" family-media/api); then fail "without --yes, 'n' must not write"; fi
if OUT=$(edit --profile env-backup-temp --from-file "$TMP/open.env" family-media/api </dev/null); then fail "without --yes and no answer, nothing may be written"; fi
{ grep -q 'not confirmed; nothing written' <<<"$OUT" && [ "$(version_of /env/family-media/api)" = "$v" ]; } || fail "an unconfirmed --from-file wrote:\n$OUT"
OUT=$(printf 'y\n' | edit --profile env-backup-temp --from-file "$TMP/open.env" family-media/api) || fail "a confirmed --from-file failed:\n$OUT"
[ "$(version_of /env/family-media/api)" = $((v + 1)) ] || fail "a confirmed --from-file did not write"

# 4. Interactive: $EDITOR edits the plain file under a private HOME/XDG; vim
# gets no swap/viminfo/undo/backup; /dev/shm is preferred over TMPDIR.
cat >"$BIN/fake-editor" <<'STUB'
#!/bin/sh
printf 'HOME=%s\nSTATE=%s\nDATA=%s\nCACHE=%s\nDIR=%s\nARGS=%s\n' "$HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" \
  "$XDG_CACHE_HOME" "$(dirname "$(eval "printf %s \"\${$#}\"")")" "$*" >"$STUB_DIR/editor.env"
f=$(eval "printf %s \"\${$#}\"")
sed 's/^EXTRA=1$/EXTRA=fakesecond-9i/' "$f" >"$f.x" && mv "$f.x" "$f"
STUB
chmod +x "$BIN/fake-editor"
ln -sf fake-editor "$BIN/vim"
mkdir -p "$TMP/shm"
v=$(version_of /env/family-media/api)
if OUT=$(printf 'n\n' | EDITOR=fake-editor edit --profile env-backup-temp family-media/api); then fail "an unconfirmed edit must exit non-zero"; fi
{ grep -q 'not confirmed; nothing written' <<<"$OUT" && [ "$(version_of /env/family-media/api)" = "$v" ]; } || fail "an unconfirmed edit wrote:\n$OUT"
OUT=$(printf 'y\n' | RUN_SHM="$TMP/shm" EDITOR='vim --extra-arg' edit --profile env-backup-temp family-media/api) || fail "a confirmed edit failed:\n$OUT"
grep -qx '  changed EXTRA' <<<"$OUT" || fail "the editor's change was not listed:\n$OUT"
[ "$(version_of /env/family-media/api)" = $((v + 1)) ] || fail "a confirmed edit did not write"
{ restore_to family-media/api "$TMP/rt3.env" && grep -qx 'EXTRA=fakesecond-9i' "$TMP/rt3.env"; } || fail "the editor's change is not in SSM"
WD=$(sed -n 's/^DIR=//p' "$TMP/editor.env")
case "$WD" in "$TMP/shm/env-ssm."*) ;; *) fail "the work dir was not under /dev/shm (preferred over TMPDIR): $WD" ;; esac
for v in HOME STATE DATA CACHE; do
  case "$(sed -n "s/^$v=//p" "$TMP/editor.env")" in "$WD/"*) ;; *) fail "the editor's $v is not inside the work dir:\n$(cat "$TMP/editor.env")" ;; esac
done
grep -qx "ARGS=--extra-arg -n -i NONE +set noundofile nobackup nowritebackup $WD/edit.env" "$TMP/editor.env" \
  || fail "vim must get -n -i NONE and +set noundofile nobackup nowritebackup:\n$(cat "$TMP/editor.env")"
[ -z "$(ls -A "$TMP/shm")" ] || fail "the /dev/shm work dir was not removed"
OUT=$(printf 'y\n' | EDITOR=fake-editor edit --profile env-backup-temp family-media/api) || true
grep -q '^ARGS=/' "$TMP/editor.env" || fail "a non-vi editor must not get vim flags:\n$(cat "$TMP/editor.env")"
assert_tmp_clean "interactive"

# 5. An interrupt while the editor is open: exit 130, nothing written, cleaned.
printf '#!/bin/sh\nprintf "X=1\\n" >>"$1"\nkill -TERM "$PPID"\n' >"$BIN/killing-editor"; chmod +x "$BIN/killing-editor"
v=$(version_of /env/family-media/api); rc=0
OUT=$(printf 'y\n' | EDITOR=killing-editor edit --profile env-backup-temp family-media/api) || rc=$?
[ "$rc" = 130 ] || fail "an interrupted edit must exit 130, got $rc:\n$OUT"
[ "$(version_of /env/family-media/api)" = "$v" ] || fail "an interrupted edit wrote"
assert_tmp_clean "interrupt"

# 6. Refusals: nothing written, temp dir removed, line numbers / names only.
refuse() { # label expected-message file
  local v0 out
  v0=$(version_of /env/aiqiuqi-memorial/api)
  chmod 600 "$3"
  if out=$(edit --profile env-backup-temp --from-file "$3" --yes aiqiuqi-memorial/api); then fail "$1 must be refused:\n$out"; fi
  grep -q -- "$2" <<<"$out" || fail "$1: expected '$2', got:\n$out"
  [ "$(version_of /env/aiqiuqi-memorial/api)" = "$v0" ] || fail "$1: something was written"
  assert_tmp_clean "$1"
}
printf 'A=1\nB=fakecrval-1k\r\n' >"$TMP/cr.env";            refuse CR 'CR byte on line(s) 2' "$TMP/cr.env"
printf 'A=1\n#env-ssm end\n' >"$TMP/res.env";               refuse reserved 'reserves' "$TMP/res.env"
printf 'A=1\nexport B=2\nfakecrval-1k\n  \n\t# c\n' >"$TMP/shape.env"; refuse shape 'line(s) 2,3 are not KEY=value' "$TMP/shape.env"
printf 'A=1\nA=fakedupval-0j\n' >"$TMP/dup.env";            refuse "new duplicate" 'duplicate key(s): A' "$TMP/dup.env"
{ cat "$TMP/mem-new.env"; printf 'DUP=fakedupval-0j-c\n'; } >"$TMP/dup3.env"; refuse "more duplicates" 'duplicate key(s): DUP' "$TMP/dup3.env"
for i in $(seq 1 300); do printf 'KEY_%03d=0123456789\n' "$i"; done >"$TMP/big.env"; refuse "oversize main" 'over the 4096-byte' "$TMP/big.env"
for i in 1 2 3 4 5 6 7; do printf 'K%s=%s\n' "$i" "$PEM"; done >"$TMP/bigpem.env"; refuse "oversize -pem" 'api-pem would be' "$TMP/bigpem.env"
: >"$TMP/empty.env";                                        refuse empty 'empty' "$TMP/empty.env"
# An existing duplicate may stay (DUP twice in the current pair), its value changed.
sed 's/fakedupval-0j-b/fakedupval-0j-z/' "$TMP/mem-new.env" >"$TMP/dup-ok.env"
OUT=$(edit --profile env-backup-temp --from-file "$TMP/dup-ok.env" --yes aiqiuqi-memorial/api) || fail "an existing duplicate must be allowed:\n$OUT"
grep -qx '  changed DUP' <<<"$OUT" || fail "the existing duplicate's change was not listed"

# 7. A corrupted latest pair, a concurrent write, and a bad read-back are refused.
if OUT=$(STUB_CORRUPT=/env/aiqiuqi-memorial/api edit --profile env-backup-temp --from-file "$TMP/mem-new.env" --yes aiqiuqi-memorial/api); then
  fail "a corrupted latest pair must be refused"
fi
grep -q 'nothing written\|do not reassemble' <<<"$OUT" || fail "expected a refusal for the corrupted pair:\n$OUT"
cat >"$BIN/racing-editor" <<'STUB'
#!/bin/sh
printf 'RACE=1\n' >>"$1"
# Someone else's edit lands (a real put: new version) while this one is open.
cp "$STUB_DIR/store/_env_family-media_api" "$STUB_DIR/race"
aws --profile env-backup-temp ssm put-parameter --name /env/family-media/api --value "file://$STUB_DIR/race" >/dev/null
STUB
chmod +x "$BIN/racing-editor"
v=$(version_of /env/family-media/api)
if OUT=$(printf 'y\n' | EDITOR=racing-editor edit --profile env-backup-temp family-media/api); then fail "a concurrent change must be refused"; fi
grep -q "changed since it was fetched (v$v/v[0-9]*, now v$((v + 1))/v[0-9]*)" <<<"$OUT" || fail "expected the version-race refusal:\n$OUT"
[ "$(version_of /env/family-media/api)" = $((v + 1)) ] || fail "the concurrent write was overwritten"
assert_tmp_clean "concurrent"
rm -f "$TMP/put.done"
{ cat "$TMP/fam-new.env"; printf 'READBACK=1\n'; } >"$TMP/rb.env"
if OUT=$(STUB_CORRUPT_AFTER_PUT=/env/family-media/api edit --profile env-backup-temp --from-file "$TMP/rb.env" --yes family-media/api); then
  fail "a read-back that does not match must fail env-edit:\n$OUT"
fi
grep -q 'sha256 MISMATCH between the edited file and SSM' <<<"$OUT" || fail "expected the read-back mismatch:\n$OUT"
rm -f "$TMP/put.done"
assert_tmp_clean "read-back"

# 8. The handoff key pair across both services (real throwaway keys).
gen_key() { openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1" 2>/dev/null; }
one_line() { awk '{ printf "%s\\n", $0 }' | sed 's/\\n$//'; }   # PEM -> one line, literal \n
gen_key "$TMP/a.key"; gen_key "$TMP/b.key"
priv_line() { one_line <"$1"; }
pub_entry() { printf '{"kid":"%s","pem":"%s"}' "$1" "$(openssl pkey -in "$2" -pubout 2>/dev/null | one_line)"; }
family_with() { # kid key
  printf 'DATABASE_URL=postgresql://fm:fakedbpw-2b@127.0.0.1:5432/family_media\nFM_HANDOFF_KEY_ID=%s\nFM_HANDOFF_PRIVATE_KEY_PEM=%s\n' "$1" "$(priv_line "$2")"
}
memorial_with() { # json list
  printf 'APP_KEY=base64:fakememkey-5e\nMEMORIAL_HANDOFF_PUBLIC_KEYS=%s\n' "$1"
}
KEY_TOKENS=("$(sed -n 5p "$TMP/a.key")" "$(sed -n 5p "$TMP/b.key")")
family_with ka "$TMP/a.key" >"$TMP/h-fam.env"; seed family-media/api "$TMP/h-fam.env"
memorial_with "[$(pub_entry ka "$TMP/a.key")]" >"$TMP/h-mem.env"; seed aiqiuqi-memorial/api "$TMP/h-mem.env"
h_edit() { local f="$TMP/h-in.env"; cat >"$f"; chmod 600 "$f"; edit --profile env-backup-temp --from-file "$f" --yes "$@"; }
# Family switches to a key memorial does not list: refused, names only.
v=$(version_of /env/family-media/api)
if OUT=$(family_with kb "$TMP/b.key" | h_edit family-media/api); then fail "a family key memorial does not accept must be refused"; fi
grep -q 'handoff: the public key of FM_HANDOFF_PRIVATE_KEY_PEM (family-media/api) is not in MEMORIAL_HANDOFF_PUBLIC_KEYS' <<<"$OUT" || fail "expected the handoff refusal:\n$OUT"
[ "$(version_of /env/family-media/api)" = "$v" ] || fail "a handoff mismatch was written"
# The documented rotation never needs the override: add B to memorial, switch
# family to B, remove A from memorial.
OUT=$(memorial_with "[$(pub_entry ka "$TMP/a.key"),$(pub_entry kb "$TMP/b.key")]" | h_edit aiqiuqi-memorial/api) || fail "rotation step 1 failed:\n$OUT"
grep -q "handoff: family's key and kid are listed" <<<"$OUT" || fail "step 1 did not run the handoff check:\n$OUT"
OUT=$(family_with kb "$TMP/b.key" | h_edit family-media/api) || fail "rotation step 2 failed:\n$OUT"
OUT=$(memorial_with "[$(pub_entry kb "$TMP/b.key")]" | h_edit aiqiuqi-memorial/api) || fail "rotation step 3 failed:\n$OUT"
# Memorial dropping family's key, or family using a kid memorial does not list: refused.
v=$(version_of /env/aiqiuqi-memorial/api)
if OUT=$(memorial_with "[$(pub_entry ka "$TMP/a.key")]" | h_edit aiqiuqi-memorial/api); then fail "memorial dropping family's key must be refused"; fi
[ "$(version_of /env/aiqiuqi-memorial/api)" = "$v" ] || fail "memorial dropping family's key was written"
if OUT=$(family_with kz "$TMP/b.key" | h_edit family-media/api); then fail "a kid memorial does not list must be refused"; fi
grep -q 'FM_HANDOFF_KEY_ID (family-media/api) is not a kid in MEMORIAL_HANDOFF_PUBLIC_KEYS' <<<"$OUT" || fail "expected the kid refusal:\n$OUT"
# The explicit override writes, with a warning.
v=$(version_of /env/family-media/api)
OUT=$(family_with kz "$TMP/b.key" | h_edit --allow-handoff-mismatch family-media/api) || fail "--allow-handoff-mismatch must write:\n$OUT"
grep -q 'WARNING: handoff mismatch allowed' <<<"$OUT" && [ "$(version_of /env/family-media/api)" = $((v + 1)) ] || fail "the override did not write with a warning:\n$OUT"
# Keys the check does not watch do not trigger it.
OUT=$( { family_with kz "$TMP/b.key"; printf 'OTHER=1\n'; } | h_edit family-media/api) || fail "an unrelated family edit must pass:\n$OUT"
grep -q 'handoff' <<<"$OUT" && fail "an unrelated edit ran the handoff check:\n$OUT"
assert_tmp_clean "handoff"

# 9. No fake value or key material ever reached any output.
assert_no_fakes "${KEY_TOKENS[@]}"

echo "PASS: env-edit needs the env-backup-temp identity, round-trips with a names-only diff, refuses bad content, open sources, races and bad read-backs, checks the handoff pair across services, keeps the editor's state in the work dir, cleans up on every exit"
