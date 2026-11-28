#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub sources are literal on purpose
set -euo pipefail

# Behavioural test for scripts/deploy-family-api-laravel.sh with docker, sudo
# and pg_dump stubbed (the sibling of verify-memorial-laravel-deploy.sh). The
# properties: the whole env file is pulled from SSM first (read profile);
# nothing running is touched until preflight, the pre-migration dump and the
# migration have all succeeded; a release that is not ready on both FPM pools is
# replaced by the previous one (or stopped, on the first deploy) and never
# pinned; the pin moves only after readiness; no secret reaches the output.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

REL=1111111111111111111111111111111111111111
PREV=2222222222222222222222222222222222222222
DIGEST=sha256:$(printf '%064d' 7)

REPO="$TMP/repo"; BIN="$TMP/bin"; LOG="$TMP/calls.log"
mkdir -p "$REPO/scripts" "$BIN" "$TMP/secrets" "$TMP/dumps"
cp "$ROOT/scripts/deploy-family-api-laravel.sh" "$REPO/scripts/"
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

# sudo: `sudo [-n] [-u user] cmd` and `sudo env ... cmd` just run the command.
cat >"$BIN/sudo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -n ] && shift
if [ "$1" = -u ]; then shift 2; fi
exec "$@"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/sleep"
cat >"$BIN/pg_dump" <<'STUB'
#!/usr/bin/env bash
echo "pg_dump $*" >>"$CALLS"
printf 'PGDMP-partial'
[ "${STUB_DUMP_FAIL:-}" = 1 ] && exit 1
printf -- '-complete'
STUB
# install: the real one without -o/-g (not root here). tee: records its target's
# mode when it opens it, i.e. before any dump data is written.
cat >"$BIN/install" <<'STUB'
#!/usr/bin/env bash
args=(); while [ "$#" -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
exec /usr/bin/install "${args[@]}"
STUB
cat >"$BIN/tee" <<'STUB'
#!/usr/bin/env bash
mode="$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo missing)"
echo "tee-target-mode $mode" >>"$CALLS"
exec /usr/bin/tee "$@"
STUB
# pg_restore --list: reads the dump; fails on a truncated one (STUB_RESTORE_FAIL=1).
cat >"$BIN/pg_restore" <<'STUB'
#!/usr/bin/env bash
echo "pg_restore $*" >>"$CALLS"
[ "${STUB_RESTORE_FAIL:-}" = 1 ] && exit 1
grep -q -- '-complete' "${@: -1}"
STUB
# docker: logs every call; behaviour from STUB_* variables.
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $* [tag=${FAMILY_API_LARAVEL_TAG:-}]" >>"$CALLS"
case "$*" in
  *"artisan family:preflight"*)
    [ "${STUB_PREFLIGHT_SECRET:-}" = 1 ] && echo "DSN key=QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9w"
    [ "${STUB_PREFLIGHT_FAIL:-}" = 1 ] && { echo "preflight: JWT_SECRET must be a string"; exit 1; }; exit 0 ;;
  *"artisan migrate"*) [ "${STUB_MIGRATE_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
  *"fcgi-probe.sh"*"fpm-auth.sock"*) [ "${STUB_AUTH_READY:-${STUB_READY:-1}}" = 1 ]; exit ;;
  *"fcgi-probe.sh"*) [ "${STUB_READY:-1}" = 1 ]; exit ;;
  images*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN"/*

ENV="$TMP/secrets/api-laravel.env"
valid_env() {
  printf 'NODE_ENV=production\nDATABASE_URL=postgresql://fm:pw@127.0.0.1:5432/family_media?sslmode=disable\nAPP_KEY=base64:x\n' >"$ENV"
}
run_deploy() {
  : >"$LOG"
  (cd "$REPO" && env PATH="$BIN:$PATH" CALLS="$LOG" FAMILY_LARAVEL_ENV_FILE="$ENV" \
    FAMILY_DUMP_DIR="$TMP/dumps" bash scripts/deploy-family-api-laravel.sh "$@" 2>&1)
}
called() { grep -qF -- "$1" "$LOG"; }
line_of() { { grep -nF -- "$1" "$LOG" || true; } | head -1 | cut -d: -f1; }

# 1. A bad sha is refused before anything runs.
valid_env
if OUT="$(run_deploy main)"; then fail "a non-sha release must be refused:\n$OUT"; fi
[ ! -s "$LOG" ] || fail "a refused sha still ran:\n$(cat "$LOG")"

# 2. Happy path, upgrade from PREV: every step, in order, pin last.
valid_env
OUT="$(STUB_PIN="$PREV@$DIGEST" run_deploy "$REL")" || fail "happy path failed:\n$OUT\n$(cat "$LOG")"
order=("ssm-to-env.sh --profile family-ssm --target $ENV --force --if-changed --keep-one-backup --check-shape family-media/api"
  "env-ssm-mirror-check.sh --profile family-ssm family-media/api $ENV" "compose pull family-api-laravel" "artisan family:preflight --allow-pending"
  "pg_dump --format=custom --no-owner --no-privileges family_media" "pg_restore --list" "artisan migrate --force"
  "compose up -d family-api-laravel" "fpm-auth.sock" "image-pins.sh promote family-api-laravel $REL")
last=0
for step in "${order[@]}"; do
  n="$(line_of "$step")"; [ -n "$n" ] || fail "step '$step' never ran:\n$(cat "$LOG")"
  [ "$n" -gt "$last" ] || fail "step '$step' ran out of order:\n$(cat "$LOG")"
  last="$n"
done
grep -F "compose up -d" "$LOG" | grep -qF "[tag=$REL]" || fail "up did not run the new release's tag"
grep -F "compose pull" "$LOG" | grep -qF "[tag=$REL]" || fail "pull did not use the new release's tag"
grep -F "fcgi-probe.sh" "$LOG" | grep -qF "/api/health/ready" || fail "readiness must probe /api/health/ready"
ls "$TMP"/dumps/family-media-pre-deploy-*-111111111111.dump >/dev/null 2>&1 || fail "no pre-migration dump was kept"
[ "$(cat "$TMP"/dumps/*.dump)" = "PGDMP-partial-complete" ] || fail "the dump content is wrong"
grep -qx 'tee-target-mode 600' "$LOG" || fail "the .partial must exist 0600 before dump data is written:\n$(grep tee-target "$LOG")"
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
[ "$(mode_of "$TMP"/dumps/*.dump)" = 600 ] || fail "the dump must be 0600, got $(mode_of "$TMP"/dumps/*.dump)"
[ "$(mode_of "$TMP/dumps")" = 700 ] || fail "the dump directory must be 0700, got $(mode_of "$TMP/dumps")"
grep -q 'pw@' <<<"$OUT" && fail "the database password reached the output"

# 3. Dumps older than the retention are pruned; recent ones are kept.
touch -t 202601010000 "$TMP/dumps/family-media-pre-deploy-old.dump"
touch "$TMP/dumps/family-media-pre-deploy-recent.dump"
valid_env
STUB_PIN="$PREV" run_deploy "$REL" >/dev/null || fail "second deploy failed"
[ ! -e "$TMP/dumps/family-media-pre-deploy-old.dump" ] || fail "a dump past retention was kept"
[ -e "$TMP/dumps/family-media-pre-deploy-recent.dump" ] || fail "a recent dump was pruned"
rm -f "$TMP"/dumps/*

# 3b. A stale .partial from a killed run is removed; a fresh one is left alone.
touch -t 202601010000 "$TMP/dumps/family-media-pre-deploy-stale.dump.partial"
touch "$TMP/dumps/family-media-pre-deploy-fresh.dump.partial"
valid_env
STUB_PIN="$PREV" run_deploy "$REL" >/dev/null || fail "deploy with leftovers failed"
[ ! -e "$TMP/dumps/family-media-pre-deploy-stale.dump.partial" ] || fail "a stale .partial was kept"
[ -e "$TMP/dumps/family-media-pre-deploy-fresh.dump.partial" ] || fail "a fresh .partial was removed"
rm -f "$TMP"/dumps/*

touched_nothing() {
  called "compose up" && fail "$1: the running service was touched:\n$(cat "$LOG")"
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
valid_env
if OUT="$(STUB_DUMP_FAIL=1 run_deploy "$REL")"; then fail "a failed dump must fail the deploy:\n$OUT"; fi
called "artisan migrate" && fail "migrated without a complete dump"
ls "$TMP"/dumps/*.dump >/dev/null 2>&1 && fail "a half dump was kept as a .dump"
ls "$TMP"/dumps/*.partial >/dev/null 2>&1 && fail "a failed dump left its .partial behind"
touched_nothing dump
rm -f "$TMP"/dumps/*

# 5b. A dump pg_restore cannot read: no migration, no swap, no .dump left behind.
valid_env
if OUT="$(STUB_RESTORE_FAIL=1 run_deploy "$REL")"; then fail "an unreadable dump must fail the deploy:\n$OUT"; fi
called "artisan migrate" && fail "migrated after an unreadable dump"
ls "$TMP"/dumps/*.dump >/dev/null 2>&1 && fail "an unreadable dump was kept as a .dump"
ls "$TMP"/dumps/*.partial >/dev/null 2>&1 && fail "an unreadable dump left its .partial behind"
touched_nothing restore
rm -f "$TMP"/dumps/*

# 6. Migration fails: no swap.
valid_env
if OUT="$(STUB_MIGRATE_FAIL=1 run_deploy "$REL")"; then fail "a failed migration must fail the deploy"; fi
touched_nothing migrate

# 7. The auth pool alone not ready, with a previous release: back to it, no pin.
valid_env
if OUT="$(STUB_AUTH_READY=0 STUB_PIN="$PREV@$DIGEST" run_deploy "$REL")"; then
  fail "a release whose auth pool is not ready must fail the deploy"
fi
grep -F "compose up -d" "$LOG" | grep -qF "[tag=$PREV]" || fail "did not roll back to $PREV:\n$(cat "$LOG")"
called promote && fail "an unready release was pinned"

# 7b. The pin is the release itself (the seeded first deploy): stopped, not "restored".
valid_env
if OUT="$(STUB_READY=0 STUB_PIN="$REL@$DIGEST" run_deploy "$REL")"; then fail "an unready seeded release must fail"; fi
called "compose stop family-api-laravel" || fail "the seeded unready release was left running:\n$(cat "$LOG")"
[ "$(grep -c "compose up -d" "$LOG")" = 1 ] || fail "a seeded pin must not be 'rolled back' to:\n$(cat "$LOG")"

# 7c. A failed promote fails the job but does not roll back a healthy release.
valid_env
if OUT="$(STUB_PROMOTE_FAIL=1 STUB_PIN="$PREV" run_deploy "$REL")"; then fail "a failed promote must fail the job"; fi
grep -q "image-pins.sh promote family-api-laravel $REL" <<<"$OUT" || fail "expected the manual promote command, got:\n$OUT"
[ "$(grep -c "compose up -d" "$LOG")" = 1 ] || fail "a healthy release was rolled back over a failed promote:\n$(cat "$LOG")"

# 7d. Docker output is redacted: a long base64 run never reaches the log.
valid_env
if OUT="$(STUB_PREFLIGHT_SECRET=1 STUB_PREFLIGHT_FAIL=1 run_deploy "$REL")"; then fail "preflight must fail"; fi
grep -q 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9w' <<<"$OUT" && fail "a base64 secret reached the output"
grep -q '\[redacted\]' <<<"$OUT" || fail "expected [redacted] in:\n$OUT"

# 8. Not ready on the first deploy (no pin): the new service is stopped, no pin.
valid_env
if OUT="$(STUB_READY=0 run_deploy "$REL")"; then fail "an unready first release must fail the deploy"; fi
called "compose stop family-api-laravel" || fail "the first unready release was left running:\n$(cat "$LOG")"
called promote && fail "an unready first release was pinned"

# 9. A malformed env file stops the deploy before compose reads it, without its content.
printf 'GOOD=1\n-----BEGIN PRIVATE KEY-----secretmaterial\n' >"$ENV"
if OUT="$(run_deploy "$REL")"; then fail "a malformed env file must be refused"; fi
grep -q 'line 2' <<<"$OUT" || fail "expected the line number, got:\n$OUT"
grep -q secretmaterial <<<"$OUT" && fail "the env file's content was printed"
called "compose pull" && fail "compose ran on a malformed env file"

# 10. A DATABASE_URL without a plain database name never reaches pg_dump.
printf 'DATABASE_URL=postgresql://fm:pw@127.0.0.1/x;rm\n' >"$ENV"
if OUT="$(run_deploy "$REL")"; then fail "a non-identifier database name must be refused"; fi
called "compose pull" && fail "compose ran with an unusable DATABASE_URL"
grep -q 'pw@' <<<"$OUT" && fail "the database URL reached the output"

echo "PASS: deploy-family-api-laravel pulls the env file from SSM first, touches nothing before preflight+dump+migrate, rolls back an unready release, pins only after readiness"
