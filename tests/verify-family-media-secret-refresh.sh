#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for refresh-family-media-secrets.sh's target file. With no
# argument it refreshes the Express API's .env, as it always has; the Laravel
# deploy passes the Laravel API's api-laravel.env. It runs under sudo and
# rewrites the file it is given, so every other path is refused before SSM is
# read or anything is written, and the handoff values are never echoed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/refresh-family-media-secrets.sh"

TMP="$(mktemp -d)"
BIN="$TMP/bin"
SECRETS="$TMP/secrets"
mkdir -p "$BIN" "$SECRETS"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# A fixture, never a real key: the script only checks the BEGIN/PRIVATE KEY/END markers.
PEM='-----BEGIN PRIVATE KEY-----\nNOT-FOR-PRODUCTION\n-----END PRIVATE KEY-----'

printf '#!/usr/bin/env bash\necho "1000:1000"\n' >"$BIN/stat"
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/chown"
cat >"$BIN/aws" <<STUB
#!/usr/bin/env bash
echo "aws \$*" >>"$TMP/aws.log"
case "\$*" in
  *FM_HANDOFF_PRIVATE_KEY_PEM*) printf '%s' '$PEM' ;;
  *FM_HANDOFF_KEY_ID*) printf '%s' 'fm-test-kid' ;;
esac
STUB
chmod +x "$BIN"/*

write_envs() {
  rm -f "$SECRETS"/* "$TMP/aws.log"
  printf 'JWT_SECRET=express\nFM_HANDOFF_KEY_ID=old\n' >"$SECRETS/.env"
  printf 'JWT_SECRET=laravel\nAPP_KEY=base64:x\nFM_HANDOFF_KEY_ID=old\n' >"$SECRETS/api-laravel.env"
  chmod 600 "$SECRETS/.env" "$SECRETS/api-laravel.env"
}
run_refresh() { env PATH="$BIN:$PATH" FAMILY_SECRETS_DIR="$SECRETS" sh "$SCRIPT" "$@" 2>&1; }

# 1. No argument: Express's .env only.
write_envs
OUT="$(run_refresh)" || fail "the default target must work, got:\n$OUT"
grep -qx 'FM_HANDOFF_KEY_ID=fm-test-kid' "$SECRETS/.env" || fail "the Express .env was not refreshed"
grep -qx 'FM_HANDOFF_KEY_ID=old' "$SECRETS/api-laravel.env" || fail "the default run touched api-laravel.env"

# 2. The Laravel file: refreshed, its own lines kept, Express's untouched, nothing echoed.
write_envs
OUT="$(run_refresh "$SECRETS/api-laravel.env")" || fail "the Laravel target must work, got:\n$OUT"
grep -qx 'FM_HANDOFF_KEY_ID=fm-test-kid' "$SECRETS/api-laravel.env" || fail "api-laravel.env was not refreshed"
grep -qx 'FM_HANDOFF_PRIVATE_KEY_PEM=-----BEGIN PRIVATE KEY-----\\nNOT-FOR-PRODUCTION\\n-----END PRIVATE KEY-----' "$SECRETS/api-laravel.env" \
  || fail "the PEM must be written as one line, as fetched:\n$(cat "$SECRETS/api-laravel.env")"
grep -qx 'APP_KEY=base64:x' "$SECRETS/api-laravel.env" || fail "api-laravel.env lost its own lines"
grep -qx 'FM_HANDOFF_KEY_ID=old' "$SECRETS/.env" || fail "the Laravel run touched Express's .env"
grep -q 'NOT-FOR-PRODUCTION' <<<"$OUT" && fail "the private key was echoed"

# 3. Any other path is refused before SSM is read, and nothing is written.
for target in "$TMP/other.env" "$SECRETS/../secrets/api-laravel.env" "$SECRETS/api-laravel.env.bak" "/etc/passwd" "$SECRETS/.env extra"; do
  write_envs
  printf 'X=1\n' >"$TMP/other.env"
  if OUT="$(run_refresh "$target")"; then fail "'$target' must be refused:\n$OUT"; fi
  grep -q usage <<<"$OUT" || fail "expected the usage line for '$target', got:\n$OUT"
  [ ! -e "$TMP/aws.log" ] || fail "'$target': SSM was read before the refusal"
  [ "$(cat "$TMP/other.env")" = "X=1" ] || fail "'$target': a file was written"
done
# Two arguments are not a way around it either.
write_envs
if OUT="$(run_refresh "$SECRETS/api-laravel.env" "$TMP/other.env")"; then :; fi
[ "$(cat "$TMP/other.env")" = "X=1" ] || fail "a second argument was written to"

echo "PASS: refresh-family-media-secrets writes only Express's .env (default) or api-laravel.env, refuses every other path, echoes nothing"
