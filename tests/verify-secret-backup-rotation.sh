#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for secretlib_rotate_backup in scripts/lib/secret-file-lib.sh.
#
# The stated intent is "keeps exactly one backup": an exposed secret must stop
# existing on disk once it has been rotated out. The helper used to prune all
# but the newest *existing* backup and then add another, so after two
# rotations the value rotated out twice was still sitting in a .bak file.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/secret-file-lib.sh"

TMP="$(mktemp -d)"
BIN="$TMP/bin"
mkdir -p "$BIN"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

# chown is a root shape this machine does not have. date is stubbed to a
# counter so three rotations in the same second still get distinct names.
cat >"$BIN/chown" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$BIN/date" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$COUNTER"); echo $((n + 1)) >"$COUNTER"; echo "2026010${n}T000000Z"
STUB
chmod +x "$BIN"/*
echo 1 >"$TMP/counter"

ENV_FILE="$TMP/.env"

rotate_to() {
  # Back up the current file, then replace it with the next version -- the
  # same order the refresh scripts use.
  env PATH="$BIN:$PATH" COUNTER="$TMP/counter" ENV_FILE="$ENV_FILE" LIB="$LIB" \
    sh -c '. "$LIB"; secretlib_rotate_backup "$ENV_FILE" 1000:1000 >/dev/null'
  printf 'SECRET=%s\n' "$1" >"$ENV_FILE"
}

printf 'SECRET=v1\n' >"$ENV_FILE"
rotate_to v2
rotate_to v3
rotate_to v4

backups=$(ls "$ENV_FILE".bak-* 2>/dev/null | wc -l | tr -d ' ')
[ "$backups" = 1 ] || fail "expected exactly one backup, found $backups:\n$(grep -H . "$ENV_FILE".bak-*)"
grep -q '^SECRET=v3$' "$ENV_FILE".bak-* || fail "the one backup should hold v3 (the previous value)"
grep -l -e '^SECRET=v1$' -e '^SECRET=v2$' "$ENV_FILE".bak-* 2>/dev/null \
  && fail "a value rotated out more than once is still on disk"
[ "$(stat -f '%Lp' "$ENV_FILE".bak-* 2>/dev/null || stat -c '%a' "$ENV_FILE".bak-*)" = 600 ] \
  || fail "the backup is not mode 0600"

echo "PASS: secret backup rotation keeps exactly one backup"
