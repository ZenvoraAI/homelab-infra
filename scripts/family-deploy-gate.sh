#!/usr/bin/env bash
set -euo pipefail

# The forced command of the family-media-api deploy key (README "Family API on
# Laravel"). Installed from family-media-api deploy/host/family-deploy-gate.sh
# (9b023ec), unchanged but for this header. Installed outside the checkout -- root-owned
# /usr/local/sbin/family-deploy-gate -- because it is what decides which
# checkout runs: a script inside the checkout could be replaced by the very
# commit it is about to check out.
#
# The key can do exactly one thing: deploy-family-api-laravel <release sha>
# <homelab sha>. Its authorized_keys line carries `restrict` (no shell, no
# tunnel, no agent or X11 forwarding). The homelab sha is the commit of
# homelab-infra the deploy was approved for in GitHub's production
# environment; it must be the tip of origin/main right now, so a push to
# homelab-infra after the approval does not run under it.

REPO="${FAMILY_GATE_REPO:-/opt/homelab-infra}"
LOCK="${FAMILY_GATE_LOCK:-/run/lock/family-deploy.lock}"
LOCK_WAIT_SECONDS=600
# The deploy outlives this SSH session (see the end); its full output stays here.
LOG_DIR="${FAMILY_GATE_LOG_DIR:-$HOME/family-deploy-logs}"
LOGS_KEPT=20

refuse() { echo "family-deploy-gate: $*" >&2; exit 1; }
is_sha() { printf '%s' "$1" | grep -Eqx '[0-9a-f]{40}'; }

# One line only (read would silently drop the rest), then no word splitting or
# globbing of client input: exactly three fields.
case "${SSH_ORIGINAL_COMMAND:-}" in
  *$'\n'*|*$'\r'*) refuse "only one line is allowed" ;;
esac
read -r -a words <<<"${SSH_ORIGINAL_COMMAND:-}"
[ "${#words[@]}" -eq 3 ] && [ "${words[0]}" = deploy-family-api-laravel ] \
  || refuse "only 'deploy-family-api-laravel <release sha> <homelab sha>' is allowed"
release_sha="${words[1]}"
homelab_sha="${words[2]}"
is_sha "$release_sha" || refuse "release sha must be 40 lowercase hex"
is_sha "$homelab_sha" || refuse "homelab sha must be 40 lowercase hex"

# One family-media deploy at a time on this host (a second waits, then gives up).
exec 9>"$LOCK"
flock -w "$LOCK_WAIT_SECONDS" 9 || refuse "another family-media deploy held the lock for ${LOCK_WAIT_SECONDS}s"

cd "$REPO"
[ "$(git symbolic-ref -q --short HEAD || true)" = main ] || refuse "$REPO is not on main"
[ -z "$(git status --porcelain --untracked-files=no)" ] || refuse "$REPO has local changes to tracked files"
git fetch --quiet origin main
remote_main="$(git rev-parse origin/main)"
[ "$remote_main" = "$homelab_sha" ] \
  || refuse "homelab-infra main is $remote_main, but this deploy was approved for $homelab_sha; re-run with the current commit after reviewing it"
git merge --ff-only --quiet "$homelab_sha"
[ "$(git rev-parse HEAD)" = "$homelab_sha" ] || refuse "checkout is not at $homelab_sha after the fast-forward"

# The deploy runs detached from this session: a runner that times out, is
# cancelled or loses its network must not kill it between the migration and
# the readiness gate (where only it can roll back). Its own session, no stdin,
# output to a log that is streamed back while it runs; it inherits the lock.
umask 077
mkdir -p "$LOG_DIR"
log="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-${release_sha:0:12}.log"
setsid bash "$REPO/scripts/deploy-family-api-laravel.sh" "$release_sha" </dev/null >"$log" 2>&1 &
deploy_pid=$!
tail -n +1 -f "$log" &
tail_pid=$!
rc=0
wait "$deploy_pid" || rc=$?
sleep 1
kill "$tail_pid" 2>/dev/null || true
# shellcheck disable=SC2012 # names are ours: <UTC stamp>-<sha>.log
ls -1t -- "$LOG_DIR"/*.log | tail -n +$((LOGS_KEPT + 1)) | xargs -r rm --
echo "family-deploy-gate: deploy exited $rc (log on the host: $log)"
exit "$rc"
