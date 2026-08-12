#!/bin/sh
set -eu

# Docker never cleans up old images on its own, and this host pins deploys to
# exact commit-SHA tags (not :latest), so every deploy across every project
# leaves a new, explicitly-tagged image behind forever. Left unchecked this
# fills the disk (happened for real on 2026-08-12). Only removes images not
# referenced by any container, and only ones older than 30 days, so a recent
# rollback target is never at risk.
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) docker-prune: starting"
docker image prune -a -f --filter "until=720h"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) docker-prune: done"
df -h /
