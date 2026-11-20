#!/usr/bin/env bash
set -euo pipefail

# Deploys one release of the Laravel memorial API (ZenvoraAI/memorial-api) to
# memorial-api-laravel and memorial-api-laravel-scheduler. Run on the host,
# from /opt/homelab-infra, only by scripts/memorial-deploy-gate.sh -- the
# forced command of the memorial-api deploy key, which has already checked out
# the homelab-infra commit the deploy was approved for. CI holds no database
# URL and opens no tunnel: the dump and the migration run here.
#
#   deploy-memorial-api-laravel.sh <release sha>
#
# Order: secrets -> env-file shape -> pull -> preflight (config, database,
# argon2; nothing running is touched yet) -> pre-migration dump -> migrate ->
# swap both services -> readiness of both FPM pools and the scheduler ->
# pin as known-good -> prune. A failure after the swap restores the previous
# release (the migration stays; the dump is the way back for data).

RELEASE_SHA="${1:-}"
SERVICES=(memorial-api-laravel memorial-api-laravel-scheduler)
API=memorial-api-laravel
SCHEDULER=memorial-api-laravel-scheduler
IMAGE_REPO="ghcr.io/${GHCR_OWNER:-zenvoraai}/memorial-api"
ENV_FILE="${MEMORIAL_ENV_FILE:-/opt/secrets/aiqiuqi-memorial/api.env}"
# Shared with the Express deploy's pre-migration dumps (aiqiuqi-memorial
# infra/backup/memorial-site.md#pre-migration-dumps), so one retention covers both.
PREMIGRATE_DIR="${MEMORIAL_PREMIGRATE_DIR:-/home/ubuntu/aiqiuqi-memorial-premigrate}"
PREMIGRATE_DUMPS_KEPT=5
DATABASE_NAME=memorial_site
READY_ATTEMPTS=30
READY_INTERVAL_SECONDS=3
AUTH_SOCKET=/run/memorial-api-fpm/fpm-auth.sock
AWS_PROFILE_ENV=(AWS_SHARED_CREDENTIALS_FILE=/home/ubuntu/.aws/credentials AWS_CONFIG_FILE=/home/ubuntu/.aws/config)

say() { echo "deploy-memorial-api-laravel: $*"; }
die() { echo "deploy-memorial-api-laravel: $*" >&2; exit 1; }
# Anything long and base64-ish in docker/artisan output is withheld: a failure
# must never print key material into the Actions log.
redact() { sed -E 's/[A-Za-z0-9+/=]{40,}/[redacted]/g'; }

printf '%s' "$RELEASE_SHA" | grep -Eqx '[0-9a-f]{40}' || die "usage: $0 <40-hex release sha>"

# --- secrets -------------------------------------------------------------------
# The memorial's shared block first (the Express deploy runs the same script),
# then APP_KEY. Both run under sudo; sudo drops the ubuntu user's AWS profiles.
sudo env PATH="$PATH" "${AWS_PROFILE_ENV[@]}" scripts/refresh-memorial-secrets.sh
sudo env PATH="$PATH" "${AWS_PROFILE_ENV[@]}" scripts/refresh-memorial-laravel-secrets.sh

# A malformed line makes compose abort with the offending line's content in its
# error -- how a private key once reached a public log. Line numbers only.
test -f "$ENV_FILE" || die "missing env file: $ENV_FILE"
awk -v f="$ENV_FILE" '
  /^[[:space:]]*($|#)/ { next }
  !/^[A-Za-z_][A-Za-z0-9_]*=/ { print f ": line " NR ": not KEY=VALUE"; bad = 1 }
  END { exit bad }
' "$ENV_FILE" || die "env file shape invalid (line numbers above; content withheld)"

# --- image ---------------------------------------------------------------------
# Only this shell sees the new tag; .env keeps the last known-good one until
# the readiness gate below has passed.
export MEMORIAL_API_LARAVEL_TAG="$RELEASE_SHA"
docker compose pull "${SERVICES[@]}" 2>&1 | redact

# Config, database reachability and the argon2 self-test, in a one-off
# container of the new image, before anything running is touched.
docker compose run --rm --no-deps -T --entrypoint php "$API" artisan memorial:preflight 2>&1 | redact \
  || die "preflight refused release $RELEASE_SHA; nothing was changed"

# --- pre-migration dump ----------------------------------------------------------
# The newest scheduled dump can be almost a day old; take one now so a bad
# migration can be undone to the minute. Fail closed: no dump, no migration.
dump_name="$DATABASE_NAME-$(date -u +%Y%m%dT%H%M%SZ)-${RELEASE_SHA:0:12}.dump"
# Chained with &&: errexit does not apply inside a `( ) || die` subshell, and a
# pg_dump that dies half-way still leaves a non-empty file. The dump is written
# by this (ubuntu) shell, not by postgres, so it lands owner-only in our dir.
# shellcheck disable=SC2024 # the redirect is meant to run as the caller
(
  umask 077 &&
  mkdir -p "$PREMIGRATE_DIR" &&
  rm -f -- "$PREMIGRATE_DIR"/*.partial &&
  sudo -u postgres pg_dump --format=custom --no-owner --no-privileges "$DATABASE_NAME" \
    >"$PREMIGRATE_DIR/$dump_name.partial" &&
  test -s "$PREMIGRATE_DIR/$dump_name.partial" &&
  mv "$PREMIGRATE_DIR/$dump_name.partial" "$PREMIGRATE_DIR/$dump_name"
) || die "pre-migration dump failed; not migrating"
# shellcheck disable=SC2012 # names are ours: <db>-<UTC stamp>-<sha>.dump
ls -1t -- "$PREMIGRATE_DIR"/*.dump | tail -n +$((PREMIGRATE_DUMPS_KEPT + 1)) | xargs -r rm --
say "pre-migration dump: $PREMIGRATE_DIR/$dump_name"

docker compose run --rm --no-deps -T --entrypoint php "$API" artisan migrate --force --no-interaction 2>&1 | redact \
  || die "migration failed; the running services were not changed (restore: $PREMIGRATE_DIR/$dump_name)"

# --- swap ------------------------------------------------------------------------
# The release a service runs now: what a failed gate returns to. Only a full
# SHA tag counts (a container recreated from the pinned .env carries
# <sha>@sha256:<digest>).
running_release_tag() {
  local id
  id="$(docker compose ps -q "$1")"
  test -n "$id" || return 0
  { docker inspect -f '{{.Config.Image}}' "$id" || true; } | sed -nE 's/.*:([0-9a-f]{40})(@sha256:[0-9a-f]{64})?$/\1/p'
}
PREV_TAG="$(running_release_tag "$API")"

docker compose up -d "${SERVICES[@]}" 2>&1 | redact

rollback() {
  if [ -z "$PREV_TAG" ]; then
    # Only the first deploy has no previous release, and nginx cannot be
    # serving from a release that never passed this gate: stop, do not serve.
    echo "no previous release; stopping the new services" >&2
    docker compose stop "${SERVICES[@]}" 2>&1 | redact || echo "stop failed; check the host now" >&2
    return 0
  fi
  echo "rolling back to $PREV_TAG" >&2
  MEMORIAL_API_LARAVEL_TAG="$PREV_TAG" docker compose up -d "${SERVICES[@]}" 2>&1 | redact \
    || echo "rollback failed; check the host now" >&2
}
fail_after_swap() {
  echo "deploy-memorial-api-laravel: $1" >&2
  docker compose logs --tail=50 "${SERVICES[@]}" 2>&1 | redact || true
  rollback
  exit 1
}

ready() {
  docker compose exec -T "$API" fcgi-probe.sh /health/ready >/dev/null 2>&1 \
    && docker compose exec -T "$API" fcgi-probe.sh /health/ready "$AUTH_SOCKET" >/dev/null 2>&1 \
    && [ -n "$(docker compose ps -q --status running "$SCHEDULER")" ]
}
is_ready=""
for _ in $(seq 1 "$READY_ATTEMPTS"); do
  if ready; then is_ready=1; break; fi
  sleep "$READY_INTERVAL_SECONDS"
done
[ -n "$is_ready" ] || fail_after_swap "release $RELEASE_SHA is not ready (both FPM pools /health/ready, scheduler running)"
say "release $RELEASE_SHA ready (database reachable on both pools, scheduler running)"

# --- record ----------------------------------------------------------------------
# Serving already, so a failure here fails the job without a rollback.
scripts/image-pins.sh promote "$API" "$RELEASE_SHA" \
  || die "$RELEASE_SHA is serving but its pin was not recorded; run: cd /opt/homelab-infra && scripts/image-pins.sh promote $API $RELEASE_SHA"

# Best-effort, never fails a healthy deploy: keep this release and the one it
# replaced (a hand rollback needs no pull). `image rm` without -f refuses an
# image a container still uses.
docker images --filter dangling=false --format '{{.Repository}}:{{.Tag}}' "$IMAGE_REPO" \
  | { grep -vx -e "$IMAGE_REPO:$RELEASE_SHA" -e "$IMAGE_REPO:${PREV_TAG:-none}" || true; } \
  | xargs -r docker image rm >/dev/null 2>&1 || say "image cleanup failed; stale images retained"

say "deployed $RELEASE_SHA"
