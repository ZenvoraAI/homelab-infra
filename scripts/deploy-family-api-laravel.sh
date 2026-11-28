#!/usr/bin/env bash
set -euo pipefail

# Deploys one release of the Laravel family-media API (ZenvoraAI/family-media-api)
# to family-api-laravel. Installed from family-media-api
# deploy/host/deploy-family-api-laravel.sh (9b023ec); the one change is that the
# whole env file is pulled from SSM /env/family-media/api first (marked
# "homelab:" below). Run on the host, from /opt/homelab-infra, only by
# scripts/family-deploy-gate.sh -- the forced command of the family-media-api
# deploy key (README "Family API on Laravel"), which has already checked out
# the homelab-infra commit the deploy was approved for.
# CI holds no database URL and opens no tunnel: the dump and migration run here.
#
#   deploy-family-api-laravel.sh <release sha>
#
# Order: env file from SSM -> env-file shape -> pull -> preflight (config, database,
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
# Root 0700, its own directory under /opt/backups (whose mode other backup
# tooling may rely on): the dumps are the family's whole database. Same name
# pattern and 14-day retention as the Express deploy's pre-deploy dumps.
DUMP_DIR="${FAMILY_DUMP_DIR:-/opt/backups/family-media-premigrate}"
DUMP_RETENTION_DAYS=14
# A .partial older than this is a leftover of a killed run (no other writer here).
STALE_PARTIAL_MINUTES=60
READY_ATTEMPTS=30
READY_INTERVAL_SECONDS=3
READY_PATH=/api/health/ready
AUTH_SOCKET=/run/family-api-fpm/fpm-auth.sock
AWS_PROFILE_ENV=(AWS_SHARED_CREDENTIALS_FILE=/home/ubuntu/.aws/credentials AWS_CONFIG_FILE=/home/ubuntu/.aws/config)
# The env file's source of truth (README "Env files from SSM") and the read
# profile that may read exactly that pair. Edits: scripts/env-edit.sh.
ENV_SSM_SERVICE=family-media/api
ENV_SSM_PROFILE=family-ssm

say() { echo "deploy-family-api-laravel: $*"; }
die() { echo "deploy-family-api-laravel: $*" >&2; exit 1; }
# Anything long and base64-ish in docker/artisan output is withheld: a failure
# must never print key material into the Actions log.
redact() { sed -E 's/[A-Za-z0-9+/=]{40,}/[redacted]/g'; }

printf '%s' "$RELEASE_SHA" | grep -Eqx '[0-9a-f]{40}' || die "usage: $0 <40-hex release sha>"

# --- env file from SSM ------------------------------------------------------------
# homelab: the whole file comes from /env, the handoff keys included. The
# per-key refresh (refresh-family-media-secrets.sh) no longer runs here: it
# would make the file differ from /env, and the next deploy would revert it.
# Fail closed: a failed read or hash check leaves the file as it was and stops
# here. An identical file is not touched; a replaced one is kept as the one
# .bak. sudo drops the ubuntu user's AWS profiles, so they are passed explicitly.
sudo env PATH="$PATH" "${AWS_PROFILE_ENV[@]}" scripts/ssm-to-env.sh --profile "$ENV_SSM_PROFILE" \
  --target "$ENV_FILE" --force --if-changed --keep-one-backup "$ENV_SSM_SERVICE" \
  || die "pulling $ENV_FILE from SSM /env/$ENV_SSM_SERVICE failed; nothing was changed"
# Advisory, never fails the deploy: per-key copies kept for the handoff partner and rotations.
env "${AWS_PROFILE_ENV[@]}" scripts/env-ssm-mirror-check.sh --profile "$ENV_SSM_PROFILE" "$ENV_SSM_SERVICE" "$ENV_FILE" \
  || say "mirror check did not run; continuing (/env is the source of truth)"

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
# homelab: owner-only before a byte is written -- the directory 0700 and the
# .partial created 0600 first (tee then truncates it, keeping the mode), never
# chmod-ed afterwards -- and no .partial outlives a failed run.
(
  umask 077 &&
  sudo -n install -d -o root -g root -m 0700 "$DUMP_DIR" &&
  sudo -n find "$DUMP_DIR" -maxdepth 1 -type f -name 'family-media-pre-deploy-*.dump.partial' -mmin +"$STALE_PARTIAL_MINUTES" -delete &&
  sudo -n install -o root -g root -m 0600 /dev/null "$dump.partial" &&
  sudo -n -u postgres pg_dump --format=custom --no-owner --no-privileges "$DATABASE_NAME" \
    | sudo -n tee "$dump.partial" >/dev/null &&
  sudo -n test -s "$dump.partial" &&
  # homelab: a dump pg_restore cannot read is no way back (the Express deploy checked the same).
  sudo -n pg_restore --list "$dump.partial" >/dev/null &&
  sudo -n mv "$dump.partial" "$dump"
) || { sudo -n rm -f -- "$dump.partial" || true; die "pre-migration dump failed; not migrating"; }
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
