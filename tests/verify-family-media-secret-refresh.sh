#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for refresh-family-media-secrets.sh's target file. With no
# argument it refreshes the Express API's .env, as it always has. The Laravel
# API's api-laravel.env now comes whole from SSM /env/family-media/api (README
# "Env files from SSM"), so it is refused, as is any other name for that file
# (secretlib_refuse_canonical). It runs under sudo and rewrites the file it is
# given, so every other path is refused before SSM is read or anything is
# written, and the handoff values are never echoed.

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
run_refresh() { env PATH="$BIN:$PATH" FAMILY_SECRETS_DIR="$SECRETS" ENVSSM_SECRETS_ROOT="$TMP/root" sh "$SCRIPT" "$@" 2>&1; }

# 1. No argument: Express's .env only.
write_envs
OUT="$(run_refresh)" || fail "the default target must work, got:\n$OUT"
grep -qx 'FM_HANDOFF_KEY_ID=fm-test-kid' "$SECRETS/.env" || fail "the Express .env was not refreshed"
grep -qx 'FM_HANDOFF_KEY_ID=old' "$SECRETS/api-laravel.env" || fail "the default run touched api-laravel.env"

# 2. The Laravel file is refused before SSM is read; nothing is written.
write_envs
cp "$SECRETS/api-laravel.env" "$TMP/laravel-orig"
if OUT="$(run_refresh "$SECRETS/api-laravel.env")"; then fail "api-laravel.env must be refused:\n$OUT"; fi
grep -q 'api-laravel.env comes from SSM /env' <<<"$OUT" || fail "expected the refusal naming /env, got:\n$OUT"
[ ! -e "$TMP/aws.log" ] || fail "SSM was read before refusing api-laravel.env"
cmp -s "$SECRETS/api-laravel.env" "$TMP/laravel-orig" || fail "api-laravel.env was changed"
grep -qx 'FM_HANDOFF_KEY_ID=old' "$SECRETS/.env" || fail "refusing api-laravel.env touched Express's .env"

# 2b. The Express .env as another name for the canonical file (a symlink to
# <root>/family-media/api-laravel.env) is refused by the guard, before SSM.
write_envs
mkdir -p "$TMP/root/family-media"
printf 'APP_KEY=base64:canonical\n' >"$TMP/root/family-media/api-laravel.env"
rm "$SECRETS/.env"; ln -s "$TMP/root/family-media/api-laravel.env" "$SECRETS/.env"
if OUT="$(run_refresh)"; then fail "a .env that is the canonical file must be refused:\n$OUT"; fi
grep -q 'comes from SSM /env' <<<"$OUT" || fail "expected the canonical refusal, got:\n$OUT"
[ ! -e "$TMP/aws.log" ] || fail "SSM was read before refusing the symlinked .env"
[ "$(cat "$TMP/root/family-media/api-laravel.env")" = "APP_KEY=base64:canonical" ] || fail "the canonical file was changed"
rm "$SECRETS/.env"

# 3. Any other path is refused before SSM is read, and nothing is written.
for target in "$TMP/other.env" "$SECRETS/api-laravel.env" "$SECRETS/../secrets/api-laravel.env" "$SECRETS/api-laravel.env.bak" "/etc/passwd" "$SECRETS/.env extra"; do
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

echo "PASS: refresh-family-media-secrets writes only Express's .env, refuses api-laravel.env (it comes from /env) and every other path, echoes nothing"
