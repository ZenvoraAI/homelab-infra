#!/usr/bin/env bash
set -euo pipefail

# Deploys one release of the Laravel family-media API (ZenvoraAI/family-media-api)
# to family-api-laravel. Installed from family-media-api
# deploy/host/deploy-family-api-laravel.sh (9b023ec); the one change is that the
# handoff secrets are refreshed into the Laravel env file, not Express's .env
# (marked "homelab:" below). Run on the host, from /opt/homelab-infra, only by
# scripts/family-deploy-gate.sh -- the forced command of the family-media-api
# deploy key (README "Family API on Laravel"), which has already checked out
# the homelab-infra commit the deploy was approved for.
# CI holds no database URL and opens no tunnel: the dump and migration run here.
#
#   deploy-family-api-laravel.sh <release sha>
#
# Order: secrets -> env-file shape -> pull -> preflight (config, database,
# handoff key; nothing running is touched yet) -> pre-migration dump ->
# migrate -> swap -> readiness of both FPM pools -> pin as known-good -> prune.
# A failure after the swap restores the previous release (the migration
# stays; the dump is the way back for data). No scheduler container: the
# sweeps run from the host crontab (owner decision D1).

RELEASE_SHA="${1:-}"
API=family-api-laravel
IMAGE_REPO="ghcr.io/${GHCR_OWNER:-zenvoraai}/family-media-api-laravel"
# Its own file: APP_KEY and the rotated JWT_SECRET (owner decision D2) are
# Laravel's alone; the Express file stays as it is until cutover.
ENV_FILE="${FAMILY_LARAVEL_ENV_FILE:-/opt/secrets/family-media/api-laravel.env}"
# Same directory, name pattern and 14-day retention as the Express deploy's
# pre-deploy dumps (family-media deploy-api.yml), so one rule covers both.
DUMP_DIR="${FAMILY_DUMP_DIR:-/opt/backups}"
DUMP_RETENTION_DAYS=14
READY_ATTEMPTS=30
READY_INTERVAL_SECONDS=3
READY_PATH=/api/health/ready
AUTH_SOCKET=/run/family-api-fpm/fpm-auth.sock
AWS_PROFILE_ENV=(AWS_SHARED_CREDENTIALS_FILE=/home/ubuntu/.aws/credentials AWS_CONFIG_FILE=/home/ubuntu/.aws/config)

say() { echo "deploy-family-api-laravel: $*"; }
die() { echo "deploy-family-api-laravel: $*" >&2; exit 1; }
# Anything long and base64-ish in docker/artisan output is withheld: a failure
# must never print key material into the Actions log.
redact() { sed -E 's/[A-Za-z0-9+/=]{40,}/[redacted]/g'; }

printf '%s' "$RELEASE_SHA" | grep -Eqx '[0-9a-f]{40}' || die "usage: $0 <40-hex release sha>"

# --- secrets -------------------------------------------------------------------
# sudo drops the ubuntu user's AWS profiles, so they are passed explicitly.
# homelab: the handoff key goes into the file this service reads; without the
# argument the script refreshes only Express's .env.
sudo env PATH="$PATH" "${AWS_PROFILE_ENV[@]}" scripts/refresh-family-media-secrets.sh "$ENV_FILE"

# A malformed line makes compose abort with the offending line's content in its
# error -- how a private key once reached a public log. Line numbers only.
test -f "$ENV_FILE" || die "missing env file: $ENV_FILE"
awk -v f="$ENV_FILE" '
  /^[[:space:]]*($|#)/ { next }
  !/^[A-Za-z_][A-Za-z0-9_]*=/ { print f ": line " NR ": not KEY=VALUE"; bad = 1 }
  END { exit bad }
' "$ENV_FILE" || die "env file shape invalid (line numbers above; content withheld)"

# The database name only (never the URL, which carries the password), checked
# to be a plain identifier before it reaches pg_dump.
DATABASE_NAME="$(sed -nE 's#^DATABASE_URL=[^/]*//[^/]*/([^?]*).*#\1#p' "$ENV_FILE" | tail -1)"
printf '%s' "$DATABASE_NAME" | grep -Eqx '[A-Za-z0-9_]+' || die "DATABASE_URL in $ENV_FILE has no plain database name"

# --- image ---------------------------------------------------------------------
# Only this shell sees the new tag; .env keeps the last known-good one until
# the readiness gate below has passed.
export FAMILY_API_LARAVEL_TAG="$RELEASE_SHA"
docker compose pull "$API" 2>&1 | redact

# Config (BootGuard), database reachability and the handoff key, in a one-off
# container of the new image, before anything running is touched. Pending
# migrations are expected here; the entrypoint refuses them after the swap.
docker compose run --rm --no-deps -T --entrypoint php "$API" artisan family:preflight --allow-pending 2>&1 | redact \
  || die "preflight refused release $RELEASE_SHA; nothing was changed"

# --- pre-migration dump ----------------------------------------------------------
# Fail closed: no dump, no migration. Chained with &&: errexit does not apply
# inside a `( ) || die` subshell, and a pg_dump that dies half-way still leaves
# a non-empty file.
dump="$DUMP_DIR/family-media-pre-deploy-$(date -u +%Y%m%dT%H%M%SZ)-${RELEASE_SHA:0:12}.dump"
(
  sudo -n -u postgres pg_dump --format=custom --no-owner --no-privileges "$DATABASE_NAME" \
    | sudo -n tee "$dump.partial" >/dev/null &&
  sudo -n test -s "$dump.partial" &&
  # homelab: a dump pg_restore cannot read is no way back (the Express deploy checked the same).
  sudo -n pg_restore --list "$dump.partial" >/dev/null &&
  sudo -n chmod 0600 "$dump.partial" &&
  sudo -n mv "$dump.partial" "$dump"
) || die "pre-migration dump failed; not migrating"
sudo -n find "$DUMP_DIR" -maxdepth 1 -type f -name 'family-media-pre-deploy-*.dump' -mtime +"$DUMP_RETENTION_DAYS" -delete \
  || say "old dump cleanup failed; dumps retained"
say "pre-migration dump: $dump"

docker compose run --rm --no-deps -T --entrypoint php "$API" artisan migrate --force --no-interaction 2>&1 | redact \
  || die "migration failed; the running service was not changed (restore: $dump)"

# --- swap ------------------------------------------------------------------------
# What a failed gate returns to: the last release that passed it (the pin), not
# whatever container happens to run now. No pin, or the pin is this release:
# nothing to return to.
PREV_TAG="$(scripts/image-pins.sh get "$API" 2>/dev/null | sed -nE 's/^([0-9a-f]{40})(@sha256:[0-9a-f]{64})?$/\1/p' || true)"
[ "$PREV_TAG" != "$RELEASE_SHA" ] || PREV_TAG=""

docker compose up -d "$API" 2>&1 | redact

rollback() {
  if [ -z "$PREV_TAG" ]; then
    # Only the first deploy has no previous release: stop, do not serve.
    echo "no previous release; stopping the new service" >&2
    docker compose stop "$API" 2>&1 | redact || echo "stop failed; check the host now" >&2
    return 0
  fi
  echo "rolling back to $PREV_TAG" >&2
  FAMILY_API_LARAVEL_TAG="$PREV_TAG" docker compose up -d "$API" 2>&1 | redact \
    || echo "rollback failed; check the host now" >&2
}
fail_after_swap() {
  echo "deploy-family-api-laravel: $1" >&2
  docker compose logs --tail=50 "$API" 2>&1 | redact || true
  rollback
  exit 1
}

ready() {
  docker compose exec -T "$API" fcgi-probe.sh "$READY_PATH" >/dev/null 2>&1 \
    && docker compose exec -T "$API" fcgi-probe.sh "$READY_PATH" "$AUTH_SOCKET" >/dev/null 2>&1
}
is_ready=""
for _ in $(seq 1 "$READY_ATTEMPTS"); do
  if ready; then is_ready=1; break; fi
  sleep "$READY_INTERVAL_SECONDS"
done
[ -n "$is_ready" ] || fail_after_swap "release $RELEASE_SHA is not ready (both FPM pools $READY_PATH)"
say "release $RELEASE_SHA ready (database reachable on both pools)"

# --- record ----------------------------------------------------------------------
# Serving already, so a failure here fails the job without a rollback.
scripts/image-pins.sh promote "$API" "$RELEASE_SHA" \
  || die "$RELEASE_SHA is serving but its pin was not recorded; run: cd /opt/homelab-infra && scripts/image-pins.sh promote $API $RELEASE_SHA"

# Best-effort: keep this release and the one it replaced (a hand rollback
# needs no pull). `image rm` without -f refuses an image a container uses.
docker images --filter dangling=false --format '{{.Repository}}:{{.Tag}}' "$IMAGE_REPO" \
  | { grep -vx -e "$IMAGE_REPO:$RELEASE_SHA" -e "$IMAGE_REPO:${PREV_TAG:-none}" || true; } \
  | xargs -r docker image rm >/dev/null 2>&1 || say "image cleanup failed; stale images retained"

say "deployed $RELEASE_SHA"
