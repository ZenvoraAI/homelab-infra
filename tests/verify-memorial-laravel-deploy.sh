#!/usr/bin/env bash
# shellcheck disable=SC2016 # nginx variables and stub sources are literal on purpose
set -euo pipefail

# Behavioural test for scripts/deploy-memorial-api-laravel.sh with docker,
# sudo and pg_dump stubbed. The properties: nothing running is touched until
# preflight, the pre-migration dump and the migration have all succeeded; a
# release that is not ready is replaced by the previous one (or stopped, on
# the first deploy) and never pinned; the pin moves only after readiness.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

REL=1111111111111111111111111111111111111111
PREV=2222222222222222222222222222222222222222
DIGEST=sha256:$(printf '%064d' 7)

REPO="$TMP/repo"; BIN="$TMP/bin"; LOG="$TMP/calls.log"
mkdir -p "$REPO/scripts" "$BIN" "$TMP/secrets" "$TMP/dumps"
cp "$ROOT/scripts/deploy-memorial-api-laravel.sh" "$REPO/scripts/"
# The env pull and the mirror check log their arguments; their behaviour is
# tested with a stubbed aws in tests/verify-env-ssm-deploy.sh.
for s in ssm-to-env.sh env-ssm-mirror-check.sh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n' "$s" >"$REPO/scripts/$s"
done
# image-pins.sh: `get` prints STUB_PIN (unset: fails, as for an unpinned
# variable); `promote` fails when STUB_PROMOTE_FAIL=1.
cat >"$REPO/scripts/image-pins.sh" <<'STUB'
#!/usr/bin/env bash
echo "image-pins.sh $*" >>"$CALLS"
case "$1" in
  get) [ -n "${STUB_PIN:-}" ] || exit 1; echo "$STUB_PIN" ;;
  promote) [ "${STUB_PROMOTE_FAIL:-}" != 1 ] ;;
esac
STUB
chmod +x "$REPO/scripts"/*.sh

# sudo: `sudo env ... cmd` and `sudo -u postgres cmd` both just run the command.
cat >"$BIN/sudo" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = -u ]; then shift 2; fi
exec "$@"
STUB
cat >"$BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$BIN/pg_dump" <<'STUB'
#!/usr/bin/env bash
echo "pg_dump $*" >>"$CALLS"
printf 'PGDMP-partial'
[ "${STUB_DUMP_FAIL:-}" = 1 ] && exit 1
printf -- '-complete'
STUB
# docker: logs every call; behaviour from STUB_* variables.
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $* [tag=${MEMORIAL_API_LARAVEL_TAG:-}]" >>"$CALLS"
case "$*" in
  *"artisan memorial:preflight"*)
    [ "${STUB_PREFLIGHT_SECRET:-}" = 1 ] && echo "DSN key=QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9w"
    [ "${STUB_PREFLIGHT_FAIL:-}" = 1 ] && { echo "AUTH_JWT_SECRET is required"; exit 1; }; exit 0 ;;
  *"artisan migrate"*) [ "${STUB_MIGRATE_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
  "compose ps -q --status running"*) [ "${STUB_READY:-1}" = 1 ] && echo sched-id; exit 0 ;;
  *"fcgi-probe.sh"*) [ "${STUB_READY:-1}" = 1 ]; exit ;;
  images*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN"/*

valid_env() {
  printf 'DATABASE_URL=postgresql://x@127.0.0.1/memorial_site\nAPP_KEY=base64:x\n' >"$TMP/secrets/api.env"
}
run_deploy() {
  : >"$LOG"
  (cd "$REPO" && env PATH="$BIN:$PATH" CALLS="$LOG" MEMORIAL_ENV_FILE="$TMP/secrets/api.env" \
    MEMORIAL_PREMIGRATE_DIR="$TMP/dumps" bash scripts/deploy-memorial-api-laravel.sh "$@" 2>&1)
}
called() { grep -qF -- "$1" "$LOG"; }
line_of() { grep -nF -- "$1" "$LOG" | head -1 | cut -d: -f1; }

# 1. A bad sha is refused before anything runs.
valid_env
if OUT="$(run_deploy main)"; then fail "a non-sha release must be refused:\n$OUT"; fi
[ ! -s "$LOG" ] || fail "a refused sha still ran:\n$(cat "$LOG")"

# 2. Happy path, upgrade from PREV: every step, in order, pin last.
valid_env
OUT="$(STUB_PIN="$PREV@$DIGEST" run_deploy "$REL")" || fail "happy path failed:\n$OUT\n$(cat "$LOG")"
order=("ssm-to-env.sh --profile memorial-ssm --target $TMP/secrets/api.env --force --if-changed --keep-one-backup --check-shape aiqiuqi-memorial/api"
  "env-ssm-mirror-check.sh --profile memorial-ssm aiqiuqi-memorial/api $TMP/secrets/api.env" "compose pull" "artisan memorial:preflight"
  "pg_dump --format=custom" "artisan migrate --force" "compose up -d memorial-api-laravel memorial-api-laravel-scheduler"
  "fpm-auth.sock" "image-pins.sh promote memorial-api-laravel $REL")
last=0
for step in "${order[@]}"; do
  n="$(line_of "$step")"; [ -n "$n" ] || fail "step '$step' never ran:\n$(cat "$LOG")"
  [ "$n" -gt "$last" ] || fail "step '$step' ran out of order:\n$(cat "$LOG")"
  last="$n"
done
grep -F "compose up -d" "$LOG" | grep -qF "[tag=$REL]" || fail "up did not run the new release's tag"
grep -F "compose pull" "$LOG" | grep -qF "[tag=$REL]" || fail "pull did not use the new release's tag"
ls "$TMP"/dumps/memorial_site-*-111111111111.dump >/dev/null 2>&1 || fail "no pre-migration dump was kept"
[ "$(cat "$TMP"/dumps/*.dump)" = "PGDMP-partial-complete" ] || fail "the dump content is wrong"

# 3. Dumps beyond five are pruned, newest kept.
for i in 1 2 3 4 5 6; do touch -t "20260101000$i" "$TMP/dumps/memorial_site-old$i.dump"; done
valid_env
STUB_PIN="$PREV" run_deploy "$REL" >/dev/null || fail "second deploy failed"
[ "$(find "$TMP/dumps" -name '*.dump' | wc -l | tr -d ' ')" = 5 ] || fail "expected 5 dumps kept:\n$(ls "$TMP/dumps")"

touched_nothing() {
  called "compose up" && fail "$1: the running services were touched:\n$(cat "$LOG")"
  called "promote" && fail "$1: the pin moved:\n$(cat "$LOG")"
  return 0
}

# 4. Preflight refuses: no dump, no migration, no swap.
valid_env
if OUT="$(STUB_PREFLIGHT_FAIL=1 run_deploy "$REL")"; then fail "a failed preflight must fail the deploy"; fi
called pg_dump && fail "dumped after a failed preflight"
called "artisan migrate" && fail "migrated after a failed preflight"
touched_nothing preflight

# 5. A dump that dies half-way: no migration, no swap, no .dump left behind.
rm -f "$TMP"/dumps/*
valid_env
if OUT="$(STUB_DUMP_FAIL=1 run_deploy "$REL")"; then fail "a failed dump must fail the deploy:\n$OUT"; fi
called "artisan migrate" && fail "migrated without a complete dump"
ls "$TMP"/dumps/*.dump >/dev/null 2>&1 && fail "a half dump was kept as a .dump"
touched_nothing dump

# 6. Migration fails: no swap.
valid_env
if OUT="$(STUB_MIGRATE_FAIL=1 run_deploy "$REL")"; then fail "a failed migration must fail the deploy"; fi
touched_nothing migrate

# 7. Not ready after the swap, with a previous release: back to it, no pin.
valid_env
if OUT="$(STUB_READY=0 STUB_PIN="$PREV@$DIGEST" run_deploy "$REL")"; then
  fail "an unready release must fail the deploy"
fi
grep -F "compose up -d" "$LOG" | grep -qF "[tag=$PREV]" || fail "did not roll back to $PREV:\n$(cat "$LOG")"
called promote && fail "an unready release was pinned"

# 7b. The pin is the release itself (the seeded first deploy): nothing to go
# back to, so the unready release is stopped rather than "restored".
valid_env
if OUT="$(STUB_READY=0 STUB_PIN="$REL@$DIGEST" run_deploy "$REL")"; then fail "an unready seeded release must fail"; fi
called "compose stop memorial-api-laravel memorial-api-laravel-scheduler" || fail "the seeded unready release was left running:\n$(cat "$LOG")"
[ "$(grep -c "compose up -d" "$LOG")" = 1 ] || fail "a seeded pin must not be 'rolled back' to:\n$(cat "$LOG")"

# 7c. A failed promote fails the job but does not roll back a healthy release.
valid_env
if OUT="$(STUB_PROMOTE_FAIL=1 STUB_PIN="$PREV" run_deploy "$REL")"; then fail "a failed promote must fail the job"; fi
grep -q "image-pins.sh promote memorial-api-laravel $REL" <<<"$OUT" || fail "expected the manual promote command, got:\n$OUT"
[ "$(grep -c "compose up -d" "$LOG")" = 1 ] || fail "a healthy release was rolled back over a failed promote:\n$(cat "$LOG")"

# 7d. Docker output is redacted: a long base64 run never reaches the log.
valid_env
if OUT="$(STUB_PREFLIGHT_SECRET=1 STUB_PREFLIGHT_FAIL=1 run_deploy "$REL")"; then fail "preflight must fail"; fi
grep -q 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9w' <<<"$OUT" && fail "a base64 secret reached the output"
grep -q '\[redacted\]' <<<"$OUT" || fail "expected [redacted] in:\n$OUT"

# 8. Not ready on the first deploy: the new services are stopped, no pin.
valid_env
if OUT="$(STUB_READY=0 run_deploy "$REL")"; then fail "an unready first release must fail the deploy"; fi
called "compose stop memorial-api-laravel memorial-api-laravel-scheduler" || fail "the first unready release was left running:\n$(cat "$LOG")"
called promote && fail "an unready first release was pinned"

# 9. A malformed env file stops the deploy before compose reads it, without its content.
printf 'GOOD=1\n-----BEGIN PRIVATE KEY-----secretmaterial\n' >"$TMP/secrets/api.env"
if OUT="$(run_deploy "$REL")"; then fail "a malformed env file must be refused"; fi
grep -q 'line 2' <<<"$OUT" || fail "expected the line number, got:\n$OUT"
grep -q secretmaterial <<<"$OUT" && fail "the env file's content was printed"
called "compose pull" && fail "compose ran on a malformed env file"

echo "PASS: deploy-memorial-api-laravel touches nothing before preflight+dump+migrate, rolls back an unready release, pins only after readiness"
