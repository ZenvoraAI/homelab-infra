#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for refresh-memorial-laravel-secrets.sh: it writes the
# Laravel API's APP_KEY from SSM into the api.env it shares with the Express
# API, refuses anything that is not a 32-byte base64 key, never echoes the
# value, and leaves every other line (the multi-line CloudFront PEM included)
# exactly as it was.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/refresh-memorial-laravel-secrets.sh"

TMP="$(mktemp -d)"
BIN="$TMP/bin"
SECRETS="$TMP/secrets"
mkdir -p "$BIN" "$SECRETS" "$TMP/params"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# 32 bytes "NOT-FOR-PRODUCTION-key-32-bytes!" -- a fixture, never a real key.
VALID_KEY='base64:Tk9ULUZPUi1QUk9EVUNUSU9OLWtleS0zMi1ieXRlcyE='

cat >"$BIN/stat" <<'STUB'
#!/usr/bin/env bash
echo "1000:1000"
STUB
cat >"$BIN/chown" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$BIN/aws" <<'STUB'
#!/usr/bin/env bash
name=''
while [ "$#" -gt 0 ]; do
  case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
done
[ -f "$PARAMS/${name##*/}" ] || { echo "ParameterNotFound" >&2; exit 254; }
printf '%s' "$(cat "$PARAMS/${name##*/}")"
STUB
chmod +x "$BIN"/*

write_env() {
  rm -f "$SECRETS"/*.bak-*
  cat >"$SECRETS/api.env" <<ENV
DATABASE_URL=postgresql://example/memorial
APP_KEY=base64:old
CLOUDFRONT_MEDIA_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----
MIIEowIBAAKCAQEAxGD5example+base64
-----END PRIVATE KEY-----
MEDIA_BUCKET=example
ENV
  chmod 600 "$SECRETS/api.env"
}
set_key() { rm -f "$TMP/params"/*; [ "$#" -eq 0 ] || printf '%s' "$1" >"$TMP/params/APP_KEY"; }
run_refresh() { env PATH="$BIN:$PATH" PARAMS="$TMP/params" SECRETS_DIR="$SECRETS" sh "$SCRIPT" 2>&1; }

# 1. A valid key replaces the old line, once, and nothing else moves.
write_env
before="$(grep -v '^APP_KEY=' "$SECRETS/api.env")"
set_key "$VALID_KEY"
OUT="$(run_refresh)" || fail "a valid key must be written, got:\n$OUT"
[ "$(grep -c '^APP_KEY=' "$SECRETS/api.env")" = 1 ] || fail "expected exactly one APP_KEY line"
grep -qxF "APP_KEY=$VALID_KEY" "$SECRETS/api.env" || fail "APP_KEY was not written"
[ "$(grep -v '^APP_KEY=' "$SECRETS/api.env")" = "$before" ] || fail "other lines changed (the PEM must survive)"
grep -qF "${VALID_KEY#base64:}" <<<"$OUT" && fail "the key was echoed"
ls "$SECRETS"/api.env.bak-* >/dev/null 2>&1 || fail "no backup was taken"

# 1b. Running again with the same key rewrites nothing (the one backup keeps
# the file as it was before the last real change).
backup_before="$(ls "$SECRETS"/api.env.bak-*)"
OUT="$(run_refresh)" || fail "an unchanged key must succeed, got:\n$OUT"
grep -q 'unchanged' <<<"$OUT" || fail "expected 'unchanged', got:\n$OUT"
[ "$(ls "$SECRETS"/api.env.bak-*)" = "$backup_before" ] || fail "an unchanged key rotated the backup"

# 2. A file without APP_KEY gains one.
write_env
grep -v '^APP_KEY=' "$SECRETS/api.env" >"$TMP/x" && cat "$TMP/x" >"$SECRETS/api.env"
OUT="$(run_refresh)" || fail "adding APP_KEY must work, got:\n$OUT"
grep -qxF "APP_KEY=$VALID_KEY" "$SECRETS/api.env" || fail "APP_KEY was not added"

# 3. Every bad shape is refused and the file is untouched.
for bad in 'Tk9ULUZPUi1QUk9EVUNUSU9OLWtleS0zMi1ieXRlcyE=' 'base64:c2hvcnQ=' 'base64:!!!notbase64!!!' 'base64:' 'TODO'; do
  write_env
  snapshot="$(cat "$SECRETS/api.env")"
  set_key "$bad"
  if OUT="$(run_refresh)"; then fail "refused nothing for '$bad':\n$OUT"; fi
  grep -q 'APP_KEY' <<<"$OUT" || fail "the refusal should name APP_KEY, got:\n$OUT"
  [ "$(cat "$SECRETS/api.env")" = "$snapshot" ] || fail "api.env changed after refusing '$bad'"
done

# 4. A missing parameter is refused, not written as blank.
write_env
snapshot="$(cat "$SECRETS/api.env")"
set_key
if OUT="$(run_refresh)"; then fail "a missing parameter must be refused:\n$OUT"; fi
[ "$(cat "$SECRETS/api.env")" = "$snapshot" ] || fail "api.env changed although the parameter was missing"

# 5. A missing env file is refused.
rm -f "$SECRETS/api.env"
set_key "$VALID_KEY"
if OUT="$(run_refresh)"; then fail "a missing api.env must be refused:\n$OUT"; fi

echo "PASS: refresh-memorial-laravel-secrets writes only a 32-byte APP_KEY, refuses bad shapes, echoes nothing"
