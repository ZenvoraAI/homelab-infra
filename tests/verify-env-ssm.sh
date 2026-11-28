#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for scripts/env-to-ssm.sh and scripts/ssm-to-env.sh, with
# `aws` stubbed as a tiny Parameter Store (Standard tier: a value over 4096
# bytes is refused, as SSM does). Properties: the split puts every long/PEM
# line in -pem and nothing else; the round trip is byte-exact (comments, blank
# lines, export lines, missing final newline); an oversize part is refused
# before any write; a corrupted read-back fails the backup and the restore;
# no fake value ever reaches stdout, stderr or an aws argv; the temp dirs are
# removed on success and on failure; restore refuses to overwrite without
# --force; dry-run calls nothing; no profile means no run.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP="$ROOT/scripts/env-to-ssm.sh"
RESTORE="$ROOT/scripts/ssm-to-env.sh"

TMP="$(mktemp -d)"
BIN="$TMP/bin"
SECRETS="$TMP/secrets"
STORE="$TMP/store"
SCRATCH="$TMP/scratch"
WORKTMP="$TMP/tmpdir"
OUTLOG="$TMP/all-output.log"
mkdir -p "$BIN" "$SECRETS" "$STORE" "$SCRATCH" "$WORKTMP"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# --- stubs -----------------------------------------------------------------
cat >"$BIN/aws" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$STUB_DIR/aws.argv"
printf '%s\n' "$*" >>"$STUB_DIR/aws.argv.all"
op='' name='' value='' type='' tier='' overwrite=0 decrypt=0 profile=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    ssm) op=$2; shift ;;
    --name|--resource-id) name=$2; shift ;;
    --value) value=$2; shift ;;
    --type) type=$2; shift ;;
    --tier) tier=$2; shift ;;
    --profile) profile=$2; shift ;;
    --overwrite) overwrite=1 ;;
    --with-decryption) decrypt=1 ;;
  esac
  shift
done
[ -n "$profile" ] || { echo "stub: no --profile" >&2; exit 252; }
key=$(printf '%s' "$name" | tr '/' '_')
case "$op" in
  put-parameter)
    case "$value" in file://*) ;; *) echo "stub: value not passed as file://" >&2; exit 252 ;; esac
    [ "$type" = SecureString ] && [ "$tier" = Standard ] || { echo "stub: wrong type/tier" >&2; exit 252; }
    f=${value#file://}
    if [ "$(wc -c <"$f")" -gt 4096 ]; then
      echo "An error occurred (ValidationException) when calling the PutParameter operation: too long" >&2; exit 254
    fi
    if [ -n "${STUB_FAIL_PUT:-}" ] && [ "$name" = "$STUB_FAIL_PUT" ]; then
      # A real error can quote request data; the scripts must not print past the code.
      echo "An error occurred (AccessDeniedException) when calling the PutParameter operation: value $(head -c 200 "$f")" >&2; exit 254
    fi
    if [ -e "$STUB_DIR/store/$key" ] && [ "$overwrite" -ne 1 ]; then
      echo "An error occurred (ParameterAlreadyExists) when calling the PutParameter operation" >&2; exit 254
    fi
    cp "$f" "$STUB_DIR/store/$key"
    v=$(( $(cat "$STUB_DIR/store/$key.version" 2>/dev/null || echo 0) + 1 ))
    echo "$v" >"$STUB_DIR/store/$key.version"
    echo "$v" ;;
  get-parameter)
    [ "$decrypt" -eq 1 ] || { echo "stub: no --with-decryption" >&2; exit 252; }
    [ -f "$STUB_DIR/store/$key" ] || { echo "An error occurred (ParameterNotFound) when calling the GetParameter operation" >&2; exit 254; }
    if [ -n "${STUB_CORRUPT:-}" ] && [ "$name" = "$STUB_CORRUPT" ]; then
      sed 's/fake/FAKE/' "$STUB_DIR/store/$key"
    else
      cat "$STUB_DIR/store/$key"
    fi
    echo ;;  # --output text ends with a newline
  add-tags-to-resource) printf '%s\n' "$name" >>"$STUB_DIR/tagged" ;;
  *) echo "stub: unexpected op $op" >&2; exit 252 ;;
esac
STUB
# sudo is only used for files the caller cannot read; the stub makes the file
# readable again (owner can chmod) and runs the command.
cat >"$BIN/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/sudo.log"
for a in "$@"; do [ -f "$a" ] && chmod u+r "$a"; done
exec "$@"
STUB
cat >"$BIN/chown" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/chown.log"
[ -z "${STUB_FAIL_CHOWN:-}" ] || exit 1
STUB
chmod +x "$BIN"/*

# --- fixtures: fake values only, each with a unique searchable token -------
FAKES=(fakedbpass-91c3 fakeappkey-5d2e FAKEPEMBODY-a7 fakelongtoken-e4 fakemapsecret-0b fakememorial-6f fakevault-22 fakezen-81 fakepubkey-3c)
PEM1="-----BEGIN PRIVATE KEY-----\\n$(printf 'FAKEPEMBODY-a7%.0s' $(seq 1 40))\\n-----END PRIVATE KEY-----"
LONG="$(printf 'fakelongtoken-e4%.0s' $(seq 1 40))"
PUB="-----BEGIN PUBLIC KEY-----\\nfakepubkey-3c\\n-----END PUBLIC KEY-----"

write_fixtures() {
  rm -rf "${SECRETS:?}"/*
  mkdir -p "$SECRETS"/{family-media,aiqiuqi-memorial,securevault,dayandyou-api,zenvora-admin,family-media-origin}
  {
    printf '# family api, laravel\n'
    printf 'APP_KEY=base64:fakeappkey-5d2e\n'
    printf '\n'
    printf 'CLOUDFRONT_PRIVATE_KEY=%s\n' "$PEM1"
    printf 'DB_PASSWORD=fakedbpass-91c3 with = and  spaces\n'
    printf 'export LONG_TOKEN=%s\n' "$LONG"
    printf '   # indented comment\n'
    printf 'FM_HANDOFF_PUBLIC_KEY_PEM=%s\n' "$PUB"
    printf 'not a key value line\n'
    printf 'LAST=1\n'
  } >"$SECRETS/family-media/api-laravel.env"
  # No final newline.
  printf "APP_KEY='fakememorial-6f'\nOTHER=x" >"$SECRETS/aiqiuqi-memorial/api.env"
  # Ends with a blank line.
  printf "JWT_SECRET='fakevault-22'\n\n" >"$SECRETS/securevault/api.env"
  printf 'A=1\r\nB=fakeappkey-5d2e\n' >"$SECRETS/dayandyou-api/staging.env"
  printf 'TOKEN=fakezen-81\n' >"$SECRETS/zenvora-admin/.env"
  printf '"fakemapsecret-0b" 1;\n' >"$SECRETS/family-media-origin/origin-secret.map"
  chmod 600 "$SECRETS"/*/* "$SECRETS"/zenvora-admin/.env
}

reset_store() { rm -rf "${STORE:?}"/* "$TMP/aws.argv" "$TMP/tagged" "$TMP/sudo.log" "$TMP/chown.log"; }

# Runs a script with the stubs; records all output for the leak check.
run() {
  local out rc=0
  out=$(env PATH="$BIN:$PATH" STUB_DIR="$TMP" TMPDIR="$WORKTMP" ENVSSM_SECRETS_ROOT="$SECRETS" "$@" 2>&1) || rc=$?
  printf '%s\n' "$out" >>"$OUTLOG"
  printf '%s\n' "$out"
  return "$rc"
}
backup() { run "${ENVSSM_TEST_SH:-sh}" "$BACKUP" "$@"; }
restore() { run "${ENVSSM_TEST_SH:-sh}" "$RESTORE" "$@"; }

assert_tmp_clean() {
  [ -z "$(ls -A "$WORKTMP")" ] || fail "$1: temp files left behind: $(ls -A "$WORKTMP")"
  [ -z "$(find "$SCRATCH" "$SECRETS" -name '.*ssm-restore*')" ] || fail "$1: restore temp file left in the target directory"
}
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
stored() { printf '%s/%s' "$STORE" "$(printf '%s' "$1" | tr '/' '_')"; }

write_fixtures
reset_store

# 1. No profile, no run.
if OUT=$(AWS_PROFILE='' backup family-media/api); then fail "a backup without a profile must be refused:\n$OUT"; fi
grep -q 'no AWS profile' <<<"$OUT" || fail "expected the no-profile refusal, got:\n$OUT"
[ ! -e "$TMP/aws.argv" ] || fail "aws was called without a profile"
if OUT=$(AWS_PROFILE='' restore --target "$SCRATCH/x.env" family-media/api); then fail "a restore without a profile must be refused:\n$OUT"; fi
[ ! -e "$TMP/aws.argv" ] || fail "aws was called by a restore without a profile"

# 2. Dry run: names and sizes, no aws call, nothing stored.
OUT=$(backup --profile env-backup-temp --dry-run all) || fail "dry-run all must pass:\n$OUT"
grep -q 'would write /env/family-media/api ' <<<"$OUT" || fail "dry-run did not name /env/family-media/api:\n$OUT"
grep -q 'would write /env/family-media/api-pem .*(3 long lines)' <<<"$OUT" || fail "dry-run did not count 3 long lines:\n$OUT"
grep -q 'family-media/express-legacy: optional, .* absent -- skipped' <<<"$OUT" || fail "absent optional file was not skipped:\n$OUT"
[ ! -e "$TMP/aws.argv" ] || fail "dry-run called aws"
[ -z "$(ls -A "$STORE")" ] || fail "dry-run stored something"
assert_tmp_clean "dry-run"

# 3. Backup of every service: verified, split as specified.
OUT=$(backup --profile env-backup-temp all) || fail "backup all must pass:\n$OUT"
[ "$(grep -c 'sha256 [0-9a-f]\{64\} match' <<<"$OUT")" -eq 6 ] || fail "expected 6 verified services:\n$OUT"
MAIN=$(stored /env/family-media/api)
PEMV=$(stored /env/family-media/api-pem)
grep -q 'FAKEPEMBODY\|fakelongtoken\|fakepubkey' "$MAIN" && fail "a long value stayed in the main part"
grep -q 'fakedbpass\|fakeappkey' "$PEMV" && fail "a short value went to the -pem part"
[ "$(grep -c '^#env-ssm:pem ' "$MAIN")" -eq 3 ] || fail "expected 3 markers in the main part:\n$(sed 's/=.*/=<redacted>/' "$MAIN")"
sed -n '2,$p' "$PEMV" | grep -q '^export LONG_TOKEN=' || fail "the >512-char value is not in -pem"
head -n 1 "$PEMV" | grep -qx '#env-ssm-pem v1 lines=3' || fail "-pem header wrong"
grep -qx '#env-ssm:pem LONG_TOKEN' "$MAIN" || fail "export line marker missing"
head -n 1 "$(stored /env/family-media/origin-secret-pem)" | grep -qx '#env-ssm-pem v1 lines=0' \
  || fail "a file with no long values must still write an empty -pem part"
for p in /env/family-media/api /env/family-media/api-pem; do
  grep -qx "$p" "$TMP/tagged" || fail "$p was not tagged"
done
SRC_SHA=$(sha256 "$SECRETS/family-media/api-laravel.env")
grep -q "Key=env-ssm-sha256,Value=$SRC_SHA" "$TMP/aws.argv" || fail "the source sha256 tag is missing"
assert_tmp_clean "backup all"

# 4. Exact round trip through restore, for every file shape.
for row in "family-media/api family-media/api-laravel.env" "aiqiuqi-memorial/api aiqiuqi-memorial/api.env" \
           "securevault/api securevault/api.env" "dayandyou-api/staging dayandyou-api/staging.env" \
           "zenvora-admin/app zenvora-admin/.env" "family-media/origin-secret family-media-origin/origin-secret.map"; do
  svc=${row% *}; rel=${row#* }
  target="$SCRATCH/$(printf '%s' "$svc" | tr '/' '_').env"
  OUT=$(restore --profile env-backup-temp --target "$target" "$svc") || fail "restore $svc must pass:\n$OUT"
  cmp -s "$target" "$SECRETS/$rel" || fail "$svc: restored file differs from the source"
  sha=$(sha256 "$target")
  grep -q "sha256 $sha" <<<"$OUT" || fail "$svc: restore did not print the file's sha256:\n$OUT"
done
T="$SCRATCH/family-media_api.env"
[ "$(file_mode "$T")" = 600 ] || fail "a new restored file must be 0600"
grep -q "^$(id -u):$(id -g) " "$TMP/chown.log" || fail "a new restored file must be owned by the invoking user"
assert_tmp_clean "restore"

# 5. Restore refuses an existing non-empty file without --force; --force keeps its mode.
printf 'KEEP=me\n' >"$T"; chmod 640 "$T"
if OUT=$(restore --profile env-backup-temp --target "$T" family-media/api); then fail "overwrite without --force must be refused:\n$OUT"; fi
grep -q 'without --force' <<<"$OUT" || fail "expected the --force refusal, got:\n$OUT"
[ "$(cat "$T")" = 'KEEP=me' ] || fail "the refused restore changed the file"
OUT=$(restore --profile env-backup-temp --force --target "$T" family-media/api) || fail "restore --force must pass:\n$OUT"
cmp -s "$T" "$SECRETS/family-media/api-laravel.env" || fail "--force did not restore the file"
[ "$(file_mode "$T")" = 640 ] || fail "--force must keep the replaced file's mode"
if OUT=$(restore --profile env-backup-temp --target "$SCRATCH/m.env" --mode 0644 family-media/api); then fail "a world-readable --mode must be refused"; fi
if OUT=$(restore --profile env-backup-temp --target relative.env family-media/api); then fail "a relative --target must be refused"; fi

# 6. A failed restore (chown) leaves no temp file and no target.
if OUT=$(STUB_FAIL_CHOWN=1 restore --profile env-backup-temp --target "$SCRATCH/chownfail.env" family-media/api); then fail "a failing chown must fail the restore"; fi
[ ! -e "$SCRATCH/chownfail.env" ] || fail "a failed restore created the target"
assert_tmp_clean "failed restore"

# 7. Corrupted SSM content: the backup's verify fails, the restore refuses.
reset_store
if OUT=$(STUB_CORRUPT=/env/family-media/api backup --profile env-backup-temp family-media/api); then fail "a corrupted read-back must fail the backup:\n$OUT"; fi
grep -q 'MISMATCH' <<<"$OUT" || fail "expected MISMATCH, got:\n$OUT"
assert_tmp_clean "mismatch"
if OUT=$(STUB_CORRUPT=/env/family-media/api restore --profile env-backup-temp --target "$SCRATCH/corrupt.env" family-media/api); then fail "a corrupted parameter must not be restored:\n$OUT"; fi
[ ! -e "$SCRATCH/corrupt.env" ] || fail "a corrupted parameter was written to the target"
assert_tmp_clean "corrupt restore"
# Reordering the PEM lines (markers no longer match) is refused too.
reset_store
backup --profile env-backup-temp family-media/api >/dev/null
PEMV=$(stored /env/family-media/api-pem)
{ sed -n 1p "$PEMV"; sed -n 3p "$PEMV"; sed -n 2p "$PEMV"; sed -n '4,$p' "$PEMV"; } >"$PEMV.x" && mv "$PEMV.x" "$PEMV"
if OUT=$(restore --profile env-backup-temp --target "$SCRATCH/reorder.env" family-media/api); then fail "reordered PEM lines must be refused"; fi
grep -q 'pem line order does not match the markers' <<<"$OUT" || fail "expected the marker-order refusal, got:\n$OUT"
[ ! -e "$SCRATCH/reorder.env" ] || fail "reordered PEM lines were written"

# 8. A failed write: non-zero, no secret in the output, temp dir removed.
reset_store
if OUT=$(STUB_FAIL_PUT=/env/family-media/api backup --profile env-backup-temp family-media/api); then fail "a failed put must fail the backup"; fi
grep -q 'AccessDeniedException' <<<"$OUT" || fail "the AWS error code should be reported:\n$OUT"
assert_tmp_clean "failed put"

# 9. Oversize: main part (many short lines) and -pem part (four long lines).
reset_store
for i in $(seq 1 300); do printf 'KEY_%03d=0123456789\n' "$i"; done >"$SECRETS/zenvora-admin/.env"
if OUT=$(backup --profile env-backup-temp zenvora-admin/app); then fail "a >4096-byte main part must be refused:\n$OUT"; fi
grep -q '/env/zenvora-admin/app would be [0-9]* bytes, over the 4096-byte' <<<"$OUT" || fail "expected the size refusal, got:\n$OUT"
for i in 1 2 3 4; do printf 'KEY_%s=%s\n' "$i" "$PEM1$PEM1"; done >"$SECRETS/zenvora-admin/.env"
if OUT=$(backup --profile env-backup-temp zenvora-admin/app); then fail "a >4096-byte -pem part must be refused:\n$OUT"; fi
grep -q 'app-pem would be' <<<"$OUT" || fail "expected the -pem size refusal, got:\n$OUT"
if OUT=$(backup --dry-run zenvora-admin/app); then fail "dry-run must also refuse an oversize part"; fi
[ ! -e "$TMP/aws.argv" ] || fail "aws was called for an oversize file"
assert_tmp_clean "oversize"

# 10. A line using the reserved prefix is refused; so is an unknown service.
printf '#env-ssm end\nA=1\n' >"$SECRETS/zenvora-admin/.env"
if OUT=$(backup --profile env-backup-temp zenvora-admin/app); then fail "a reserved #env-ssm line must be refused"; fi
grep -q 'reserves' <<<"$OUT" || fail "expected the reserved-prefix refusal, got:\n$OUT"
if OUT=$(backup --profile env-backup-temp nosuch/svc); then fail "an unknown service must be refused"; fi
if OUT=$(restore --profile env-backup-temp nosuch/svc); then fail "an unknown service must be refused by restore"; fi

# 11. all: a missing required file fails the run; others still run.
write_fixtures; reset_store
rm "$SECRETS/securevault/api.env"
if OUT=$(backup --profile env-backup-temp all); then fail "a missing required file must fail 'all'"; fi
grep -q 'FAILED: securevault/api' <<<"$OUT" || fail "expected securevault/api reported as failed:\n$OUT"
[ -f "$(stored /env/zenvora-admin/app)" ] || fail "one failure stopped the other services"

# 12. An unreadable file is read through sudo.
write_fixtures; reset_store
chmod 000 "$SECRETS/zenvora-admin/.env"
OUT=$(backup --profile env-backup-temp zenvora-admin/app) || fail "an unreadable file must be read with sudo:\n$OUT"
grep -q '^cat -- .*zenvora-admin/.env$' "$TMP/sudo.log" || fail "sudo cat was not used"

# 13. No fake value anywhere: outputs of every run above, and every aws argv.
for v in "${FAKES[@]}"; do
  grep -qi -- "$v" "$OUTLOG" && fail "the fake value $v appeared in script output"
  grep -qi -- "$v" "$TMP/aws.argv.all" && fail "the fake value $v appeared on an aws command line"
done
assert_tmp_clean "end"

echo "PASS: env-to-ssm/ssm-to-env split long lines into -pem, round-trip byte-exactly, refuse oversize/corrupt/overwrite, never print a value, clean up temp files"
