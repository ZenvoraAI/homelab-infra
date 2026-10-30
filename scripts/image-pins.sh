#!/bin/sh
set -eu

# Keeps every compose service on an explicit, immutable image ref. See
# scripts/lib/image-pins-lib.sh for the model and README "Images and tags" for
# how deploys use it.
#
#   image-pins.sh seed              one-off: pin every unset variable to the
#                                   digest of the image its container runs now
#   image-pins.sh check             every variable set and pinned? (exit 1 if not)
#   image-pins.sh get <service>     the pinned value (what a rollback restores)
#   image-pins.sh promote <service> <value>
#                                   record a release as known-good, after its
#                                   health check passed: resolves the pulled
#                                   image's digest, writes .env, appends history
#   image-pins.sh rollback <service>
#                                   the pinned release is bad: re-pin the previous
#                                   known-good one and forget the bad one. Changes
#                                   state only -- run the service's deploy (or
#                                   `docker compose up -d <service>` WITH its env)
#                                   afterwards; dayandyou/securevault take their
#                                   secrets from the deploy shell.

. "$(dirname -- "$0")/lib/image-pins-lib.sh"

die() { echo "image-pins: $*" >&2; exit 1; }

var_for_service() {
  _r="$(pins_row "$1")" || die "unknown service '$1' (see pins_table in scripts/lib/image-pins-lib.sh)"
  pins_field "$_r" 3
}

kind_for_var() { pins_field "$(pins_row_for_var "$1")" 4; }

# The registry digest docker recorded for a local image, or nothing.
local_digest() {
  _repo="$(pins_ref_repo "$1")"
  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$(pins_lookup_ref "$1")" 2>/dev/null \
    | sed -n "s|^$_repo@\(sha256:[0-9a-f]\{64\}\)\$|\1|p" | head -n 1
}

# Adds the pulled image's digest to a tag-only value, so .env never relies on a
# registry tag continuing to point where it did.
with_digest() {
  case "$2" in *@sha256:*) printf '%s\n' "$2"; return 0 ;; esac
  _d="$(local_digest "$(pins_full_ref "$1" "$2")")"
  if [ -n "$_d" ]; then printf '%s@%s\n' "$2" "$_d"; else printf '%s\n' "$2"; fi
}

cmd_get() {
  _v="$(pins_env_get "$(var_for_service "$1")")"
  [ -n "$_v" ] || die "$1 has no pinned image in $PINS_ENV_FILE (run: image-pins.sh seed)"
  printf '%s\n' "$_v"
}

cmd_promote() {
  _var="$(var_for_service "$1")"
  _kind="$(kind_for_var "$_var")"
  _why="$(pins_validate "$_kind" "$2")" || die "refusing $_var=$2: $_why"
  _value="$(with_digest "$_var" "$2")"
  pins_validate "$_kind" "$_value" >/dev/null || die "refusing $_var=$_value"
  pins_lock
  pins_env_set "$_var" "$_value"
  pins_history_append "$_var" "$_value"
  echo "image-pins: $_var=$_value (known-good)"
}

cmd_rollback() {
  _var="$(var_for_service "$1")"
  pins_lock
  _bad="$(pins_env_get "$_var")"
  [ -n "$_bad" ] || die "$_var is not pinned; nothing to roll back from"
  _target="$(pins_history "$_var" | grep -vxF -- "$_bad" | tail -n 1)" || true
  [ -n "$_target" ] || die "no earlier known-good $_var in $(pins_history_file "$_var"); left at $_bad"
  pins_env_set "$_var" "$_target"
  pins_history_drop "$_var" "$_bad"
  echo "image-pins: $_var rolled back $_bad -> $_target"
}

# One container's running image as a pinned value for its variable.
seed_value() {
  _var="$1" _container="$2"
  _info="$(docker inspect --format '{{.Config.Image}}|{{.Image}}' "$_container" 2>/dev/null)" \
    || { echo "container $_container not found" >&2; return 1; }
  _ref="${_info%%|*}"
  _repo="$(pins_ref_repo "$_ref")"
  _row="$(pins_row_for_var "$_var")"
  if [ "$(pins_field "$_row" 4)" = tag ] && [ "$_repo" != "$(pins_ghcr_repo "$(pins_field "$_row" 5)")" ]; then
    echo "$_container runs $_ref, not from $(pins_ghcr_repo "$(pins_field "$_row" 5)"); pin it by hand" >&2
    return 1
  fi
  _d="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${_info#*|}" \
    | sed -n "s|^$_repo@\(sha256:[0-9a-f]\{64\}\)\$|\1|p" | head -n 1)"
  [ -n "$_d" ] || { echo "$_container: image has no registry digest for $_repo" >&2; return 1; }
  _name="${_ref%@*}"
  case "${_name##*/}" in *:*) _tag="${_name##*:}" ;; *) echo "$_container: $_ref has no tag" >&2; return 1 ;; esac
  if [ "$(pins_field "$_row" 4)" = tag ]; then printf '%s@%s\n' "$_tag" "$_d"; else printf '%s@%s\n' "$_name" "$_d"; fi
}

cmd_seed() {
  pins_lock
  _failed=0
  for _svc in $(pins_table | cut -d'|' -f1); do
    _row="$(pins_row "$_svc")"
    _var="$(pins_field "$_row" 3)"
    if [ -n "$(pins_env_get "$_var")" ]; then echo "image-pins: $_var already pinned; kept"; continue; fi
    if _value="$(seed_value "$_var" "$(pins_field "$_row" 2)")"; then
      pins_env_set "$_var" "$_value"
      pins_history_append "$_var" "$_value"
      echo "image-pins: $_var=$_value (seeded from $(pins_field "$_row" 2))"
    else
      _failed=1
    fi
  done
  [ "$_failed" = 0 ] || die "some variables could not be seeded; set them with: image-pins.sh promote <service> <pinned value>"
}

cmd_check() {
  _bad=0
  for _var in $(pins_vars); do
    _v="$(pins_env_get "$_var")"
    if [ -z "$_v" ]; then echo "UNSET $_var" >&2; _bad=1; continue; fi
    _why="$(pins_validate "$(kind_for_var "$_var")" "$_v")" || { echo "BAD   $_var=$_v: $_why" >&2; _bad=1; continue; }
    echo "ok    $_var=$_v"
  done
  [ "$_bad" = 0 ] || die "not every image is pinned in $PINS_ENV_FILE"
}

pins_init
case "${1:-}" in
  seed) cmd_seed ;;
  check) cmd_check ;;
  get) [ $# -eq 2 ] || die "usage: get <service>"; cmd_get "$2" ;;
  promote) [ $# -eq 3 ] || die "usage: promote <service> <value>"; cmd_promote "$2" "$3" ;;
  rollback) [ $# -eq 2 ] || die "usage: rollback <service>"; cmd_rollback "$2" ;;
  *) die "usage: image-pins.sh seed|check|get <service>|promote <service> <value>|rollback <service>" ;;
esac
