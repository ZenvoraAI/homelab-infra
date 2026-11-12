# shellcheck shell=sh
# Shared helpers for scripts/image-pins.sh and scripts/docker-prune.sh. Not
# standalone -- sourced.
#
# The host's gitignored project .env (which `docker compose` reads on its own)
# holds one pinned image value per variable below.
#
# PINS_COMPOSE_MODE says how docker-compose.yml treats an unset variable, and
# tests/verify-image-pinning.sh holds the compose file to it:
#   transition : ${VAR:-<fallback>}, the fallback column below -- exactly what
#                the service ran before pinning (a moving tag for the app
#                images, a digest for the third-party ones). An unseeded host
#                keeps working: compose interpolates the WHOLE file for every
#                command, so one required-but-unset variable would break every
#                product's deploy, and zenvora-admin's deploy runs homelab main
#                unattended. `image-pins.sh check` lists what is still falling
#                back.
#   strict     : ${VAR:?…} -- no compose command runs until every variable is
#                pinned. Switch only after `image-pins.sh check` passes on the
#                host (README "Images and tags", rollout).
# A deploy exports the value it just built (the shell beats .env), and writes
# it into .env only once the release is healthy, so .env always names the last
# known-good release. A per-variable history file next to it lists the
# known-good values in order; rollback and pruning both read it.

# shellcheck disable=SC2034  # read by tests/verify-image-pinning.sh
PINS_COMPOSE_MODE=transition

# service|container|VAR|kind|repo|fallback
#   kind=tag   : image is ghcr.io/$GHCR_OWNER/<repo>:${VAR}; the value is a
#                40-hex commit SHA, optionally with @sha256:<digest>, or any
#                tag WITH a digest (e.g. release@sha256:… as seeded).
#   kind=image : the value is a whole third-party ref, which must carry a digest.
#   fallback   : the transition-mode compose default (see above).
# nginx and docker-api-filter deliberately share NGINX_IMAGE: the filter reuses
# the public nginx image so there is no second image to trust.
# securevault-api and securevault-scheduler share SECUREVAULT_API_TAG: one image,
# FPM in the first, the schedule in the second; SecureVault's deploy moves both.
pins_table() {
  cat <<'TABLE'
nginx|homelab-nginx|NGINX_IMAGE|image||nginx:1.30.6-alpine@sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949
api|homelab-family-api|FAMILY_API_TAG|tag|family-media-api|latest
securevault-api|homelab-securevault-api|SECUREVAULT_API_TAG|tag|securevault-api-laravel|latest
securevault-scheduler|homelab-securevault-scheduler|SECUREVAULT_API_TAG|tag|securevault-api-laravel|latest
dayandyou-staging|homelab-dayandyou-staging|DAYANDYOU_STAGING_TAG|tag|dayandyou|staging
dayandyou-prod|homelab-dayandyou-prod|DAYANDYOU_PROD_TAG|tag|dayandyou|release
memorial-api|homelab-memorial-api|MEMORIAL_API_TAG|tag|aiqiuqi-memorial-api|latest
memorial-worker|homelab-memorial-worker|MEMORIAL_WORKER_TAG|tag|aiqiuqi-memorial-worker|latest
docker-socket-proxy|homelab-docker-socket-proxy|DOCKER_SOCKET_PROXY_IMAGE|image||tecnativa/docker-socket-proxy:v0.5.0@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459
docker-api-filter|homelab-docker-api-filter|NGINX_IMAGE|image||nginx:1.30.6-alpine@sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949
zenvora-admin|homelab-zenvora-admin|ZENVORA_ADMIN_TAG|tag|zenvora-admin|latest
TABLE
}

pins_field() { printf '%s\n' "$1" | cut -d'|' -f"$2"; }

pins_row() {
  pins_table | awk -F'|' -v s="$1" '$1 == s { print; found = 1 } END { exit !found }'
}

pins_vars() { pins_table | cut -d'|' -f3 | awk '!seen[$0]++'; }

# First row for a variable (its kind and repo are the same on every row).
pins_row_for_var() {
  pins_table | awk -F'|' -v v="$1" '$3 == v { print; exit }'
}

pins_ghcr_repo() { printf 'ghcr.io/%s/%s\n' "${GHCR_OWNER:-zenvoraai}" "$1"; }

# Validates a value for a variable's kind. Prints the reason and fails if bad.
pins_validate() {
  _kind="$1" _value="$2"
  case "$_value" in
    *[!A-Za-z0-9_.:/@-]*|'') echo "empty or contains characters an image ref cannot" ; return 1 ;;
  esac
  if [ "$_kind" = image ]; then
    printf '%s\n' "$_value" | grep -Eqx '[a-z0-9][A-Za-z0-9._/:-]*@sha256:[0-9a-f]{64}' && return 0
    echo "a third-party image must be pinned by digest (name[:tag]@sha256:<64 hex>)"
    return 1
  fi
  printf '%s\n' "$_value" | grep -Eqx '[0-9a-f]{40}(@sha256:[0-9a-f]{64})?' && return 0
  printf '%s\n' "$_value" | grep -Eqx '[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}@sha256:[0-9a-f]{64}' && return 0
  echo "not pinned: use a 40-hex commit SHA tag, or any tag with @sha256:<digest> (moving tags like latest/release/staging are refused)"
  return 1
}

# The full image reference a value resolves to, exactly as compose builds it.
pins_full_ref() {
  _row="$(pins_row_for_var "$1")"
  if [ "$(pins_field "$_row" 4)" = image ]; then
    printf '%s\n' "$2"
  else
    printf '%s:%s\n' "$(pins_ghcr_repo "$(pins_field "$_row" 5)")" "$2"
  fi
}

# Repository part of a full ref: drops @digest, then a :tag on the last path
# component only (a registry host:port must survive).
pins_ref_repo() {
  _name="${1%@*}"
  case "${_name##*/}" in
    *:*) printf '%s\n' "${_name%:*}" ;;
    *) printf '%s\n' "$_name" ;;
  esac
}

# A ref docker can look up locally: repo@digest when there is a digest (a
# tag+digest ref is pullable but not every engine resolves it on inspect).
pins_lookup_ref() {
  case "$1" in
    *@sha256:*) printf '%s@%s\n' "$(pins_ref_repo "$1")" "${1##*@}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

pins_env_get() {
  [ -f "$PINS_ENV_FILE" ] || return 0
  sed -n "s/^\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" "$PINS_ENV_FILE" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# Rewrites .env atomically, keeping every other line (GHCR_OWNER, anything an
# operator added) and the file's mode: mktemp's 0600 would otherwise replace
# it, and a compose run as another user could no longer read .env.
pins_env_set() {
  _tmp="$(mktemp "$PINS_ENV_FILE.XXXXXX")"
  if [ -f "$PINS_ENV_FILE" ]; then
    cp -p "$PINS_ENV_FILE" "$_tmp"
    grep -Ev "^(export[[:space:]]+)?$1=" "$PINS_ENV_FILE" >"$_tmp" || true
  fi
  printf '%s=%s\n' "$1" "$2" >>"$_tmp"
  mv "$_tmp" "$PINS_ENV_FILE"
}

pins_history_file() { printf '%s/%s.history\n' "$PINS_STATE_DIR" "$1"; }

# Known-good values, oldest first.
pins_history() {
  _f="$(pins_history_file "$1")"
  [ -f "$_f" ] && cat "$_f"
  return 0
}

# Writes the history from stdin, de-duplicated (last occurrence wins, so a
# re-promoted value moves to the end) and capped at PINS_HISTORY_MAX.
pins_history_replace() {
  _f="$(pins_history_file "$1")"
  _tmp="$(mktemp "$_f.XXXXXX")"
  awk 'NF { line[++n] = $0 } END { for (i = n; i >= 1; i--) if (!seen[line[i]]++) keep[++k] = line[i]; for (i = k; i >= 1; i--) print keep[i] }' \
    | tail -n "${PINS_HISTORY_MAX:-10}" >"$_tmp"
  mv "$_tmp" "$_f"
}

pins_history_append() {
  { pins_history "$1"; printf '%s\n' "$2"; } | pins_history_replace "$1"
}

pins_history_drop() {
  pins_history "$1" | grep -vxF -- "$2" | pins_history_replace "$1"
}

# What pruning must keep for a variable: its current value plus the newest
# $2 known-good values.
pins_keep_values() {
  { pins_env_get "$1"; pins_history "$1" | tail -n "$2"; } | awk 'NF && !seen[$0]++'
}

# mkdir is atomic, so the directory is the lock. The holder's PID inside it
# lets a later run clear a lock left by a killed process (SIGKILL, reboot)
# instead of failing every deploy's promote until someone removes it by hand.
# `ps -p` rather than `kill -0`: the holder may be another user (root vs the
# deploy user), and kill -0 then fails with EPERM although it is alive.
pins_lock() {
  _tries=0
  until mkdir "$PINS_STATE_DIR/.lock" 2>/dev/null; do
    _holder="$(cat "$PINS_STATE_DIR/.lock/pid" 2>/dev/null || true)"
    if [ -n "$_holder" ] && ! ps -p "$_holder" >/dev/null 2>&1 \
      && [ "$(cat "$PINS_STATE_DIR/.lock/pid" 2>/dev/null || true)" = "$_holder" ]; then
      echo "image-pins: clearing a stale lock left by exited process $_holder" >&2
      rm -rf "$PINS_STATE_DIR/.lock"
      continue
    fi
    # No PID: the holder died between mkdir and writing it. A live holder
    # writes it immediately, so an empty lock older than a minute is stale.
    if [ -z "$_holder" ] && [ -n "$(find "$PINS_STATE_DIR/.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      echo "image-pins: clearing a stale lock with no holder PID" >&2
      rm -rf "$PINS_STATE_DIR/.lock"
      continue
    fi
    _tries=$((_tries + 1))
    [ "$_tries" -lt "${PINS_LOCK_TRIES:-60}" ] || { echo "image-pins: could not take $PINS_STATE_DIR/.lock" >&2; return 1; }
    sleep 1
  done
  echo "$$" >"$PINS_STATE_DIR/.lock/pid"
  trap pins_unlock EXIT
  # A signal must also stop the script: a trap that only released the lock
  # would let it carry on writing .env unlocked.
  trap 'pins_unlock; exit 130' INT
  trap 'pins_unlock; exit 143' TERM
}

pins_unlock() { rm -rf "$PINS_STATE_DIR/.lock"; }

pins_init() {
  _root="$(cd "$(dirname -- "$0")/.." && pwd)"
  PINS_ENV_FILE="${IMAGE_PINS_ENV_FILE:-$_root/.env}"
  PINS_STATE_DIR="${IMAGE_PINS_STATE_DIR:-$_root/.image-pins}"
  mkdir -p "$PINS_STATE_DIR"
}
