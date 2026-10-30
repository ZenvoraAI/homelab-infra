#!/bin/sh
set -eu

# Docker never cleans up old images on its own, and every deploy pins a new
# exact image, so each release leaves one behind for ever. Left unchecked this
# fills the disk (happened for real on 2026-08-12).
#
# Retention is by release, not by age: for every pinned service
# (scripts/lib/image-pins-lib.sh) this keeps the image .env pins now plus the
# newest IMAGE_KEEP_GOOD (default 3) known-good releases from its history, and
# removes every other image of that service's repositories. That is the
# rollback window `image-pins.sh rollback` relies on. An age filter cannot
# give that guarantee: the previous release of a rarely-deployed service is
# often the oldest image on the box, and the old `prune -a --filter until=…`
# in each product's deploy deleted it after 48h.
#
# Never touches images of repositories it does not manage, beyond dangling
# layers; `docker image rm` without -f also refuses any image a container
# (running or stopped) still uses. DRY_RUN=1 prints what it would remove.
#
# Refuses to remove anything if any variable is unpinned: an empty keep set
# would otherwise mean "remove every image of that service".

. "$(dirname -- "$0")/lib/image-pins-lib.sh"

KEEP="${IMAGE_KEEP_GOOD:-3}"
case "$KEEP" in ''|*[!0-9]*|0) echo "docker-prune: IMAGE_KEEP_GOOD must be a positive integer, got '$KEEP'" >&2; exit 1 ;; esac

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) docker-prune: $*"; }

# "<full ref>" for every image to keep, across all variables.
keep_refs() {
  for _var in $(pins_vars); do
    pins_keep_values "$_var" "$KEEP" | while IFS= read -r _value; do
      pins_full_ref "$_var" "$_value"
    done
  done
}

keep_ids() {
  keep_refs | while IFS= read -r _ref; do
    docker image inspect --format '{{.Id}}' "$(pins_lookup_ref "$_ref")" 2>/dev/null || true
  done | sort -u
}

# "<id> <removable ref>" for every local image of one repository.
repo_images() {
  docker images --no-trunc --digests --format '{{.ID}} {{.Repository}} {{.Tag}} {{.Digest}}' "$1" \
    | awk '{ ref = ($3 == "<none>") ? $2 "@" $4 : $2 ":" $3; if ($3 != "<none>" || $4 != "<none>") print $1, ref }'
}

remove_unkept() {
  _ids="$1"
  keep_refs | while IFS= read -r _ref; do pins_ref_repo "$_ref"; done | sort -u | while IFS= read -r _repo; do
    repo_images "$_repo" | while read -r _id _ref; do
      printf '%s\n' "$_ids" | grep -qxF -- "$_id" && continue
      if [ "${DRY_RUN:-0}" = 1 ]; then echo "would remove $_ref"; continue; fi
      docker image rm "$_ref" >/dev/null 2>&1 && echo "removed $_ref" || echo "kept $_ref (in use or already gone)"
    done
  done
}

pins_init
log "starting (keeping the pinned image + $KEEP known-good per service)"
if ! "$(dirname -- "$0")/image-pins.sh" check >/dev/null; then
  log "not every service is pinned; removing nothing (run image-pins.sh check)" >&2
  exit 1
fi
[ "${DRY_RUN:-0}" = 1 ] || docker image prune -f >/dev/null
remove_unkept "$(keep_ids)"
log "done"
df -h / || true
