#!/usr/bin/env bash
set -euo pipefail

# The forced command of the memorial-api deploy key (README "Memorial API
# deploy key"). Installed outside the checkout -- root-owned
# /usr/local/sbin/memorial-deploy-gate -- because it is what decides which
# checkout runs: a script inside the checkout could be replaced by the very
# commit it is about to check out.
#
# The key can do exactly one thing: deploy-memorial-api-laravel <release sha>
# <homelab sha>. Its authorized_keys line carries `restrict` (no shell, no
# tunnel, no agent or X11 forwarding). The homelab sha is the commit of
# homelab-infra the deploy was approved for in GitHub's production
# environment; it must be the tip of origin/main right now, so a push to
# homelab-infra after the approval does not run under it.

REPO="${MEMORIAL_GATE_REPO:-/opt/homelab-infra}"
LOCK="${MEMORIAL_GATE_LOCK:-/run/lock/memorial-deploy.lock}"
LOCK_WAIT_SECONDS=600

refuse() { echo "memorial-deploy-gate: $*" >&2; exit 1; }
is_sha() { printf '%s' "$1" | grep -Eqx '[0-9a-f]{40}'; }

# No word splitting or globbing of client input: exactly three fields.
read -r -a words <<<"${SSH_ORIGINAL_COMMAND:-}"
[ "${#words[@]}" -eq 3 ] && [ "${words[0]}" = deploy-memorial-api-laravel ] \
  || refuse "only 'deploy-memorial-api-laravel <release sha> <homelab sha>' is allowed"
release_sha="${words[1]}"
homelab_sha="${words[2]}"
is_sha "$release_sha" || refuse "release sha must be 40 lowercase hex"
is_sha "$homelab_sha" || refuse "homelab sha must be 40 lowercase hex"

# One memorial deploy at a time on this host (a second waits, then gives up).
exec 9>"$LOCK"
flock -w "$LOCK_WAIT_SECONDS" 9 || refuse "another memorial deploy held the lock for ${LOCK_WAIT_SECONDS}s"

cd "$REPO"
[ "$(git symbolic-ref -q --short HEAD || true)" = main ] || refuse "$REPO is not on main"
[ -z "$(git status --porcelain --untracked-files=no)" ] || refuse "$REPO has local changes to tracked files"
git fetch --quiet origin main
remote_main="$(git rev-parse origin/main)"
[ "$remote_main" = "$homelab_sha" ] \
  || refuse "homelab-infra main is $remote_main, but this deploy was approved for $homelab_sha; re-run with the current commit after reviewing it"
git merge --ff-only --quiet "$homelab_sha"
[ "$(git rev-parse HEAD)" = "$homelab_sha" ] || refuse "checkout is not at $homelab_sha after the fast-forward"

exec bash "$REPO/scripts/deploy-memorial-api-laravel.sh" "$release_sha"
