#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for scripts/memorial-deploy-gate.sh, the forced command of
# the memorial-api deploy key, against real git repositories. The key must be
# able to run exactly one command, and only with the homelab-infra commit the
# deploy was approved for -- which must still be the tip of origin/main.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/memorial-deploy-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

REL=1111111111111111111111111111111111111111
BIN="$TMP/bin"; mkdir -p "$BIN"
# flock is util-linux (the host has it; macOS does not).
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/flock"; chmod +x "$BIN/flock"

g() { git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main "$@"; }
g init -q --bare "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/seed" 2>/dev/null
mkdir -p "$TMP/seed/scripts"
# The deploy script the gate hands over to: records what it was given and from which commit.
cat >"$TMP/seed/scripts/deploy-memorial-api-laravel.sh" <<'STUB'
echo "deployed $1 from $(git rev-parse HEAD)" >"$GATE_OUT"
STUB
g -C "$TMP/seed" add -A && g -C "$TMP/seed" commit -qm one && g -C "$TMP/seed" push -q origin main
g clone -q "$TMP/origin.git" "$TMP/host"
advance() {  # a new commit on origin/main, printed
  echo "$1" >"$TMP/seed/f" && g -C "$TMP/seed" add -A && g -C "$TMP/seed" commit -qm "$1" && g -C "$TMP/seed" push -q origin main
  g -C "$TMP/seed" rev-parse HEAD
}
run_gate() {
  rm -f "$TMP/out"
  env PATH="$BIN:$PATH" SSH_ORIGINAL_COMMAND="$1" MEMORIAL_GATE_REPO="$TMP/host" \
    MEMORIAL_GATE_LOCK="$TMP/lock" GATE_OUT="$TMP/out" bash "$GATE" 2>&1
}

TIP="$(advance two)"

# 1. Anything but the one command shape is refused, and nothing runs.
for cmd in "" "bash" "deploy-memorial-api-laravel $REL" "deploy-memorial-api-laravel $REL $TIP extra" \
  "deploy-memorial-api-laravel main $TIP" "deploy-memorial-api-laravel $REL ${TIP:0:12}" \
  "deploy-memorial-api-laravel $REL;id $TIP" "deploy-memorial-api-laravel ABCDEF1111111111111111111111111111111111 $TIP" \
  "other-command $REL $TIP" "deploy-memorial-api-laravel \$(id) $TIP"; do
  if OUT="$(run_gate "$cmd")"; then fail "refused nothing for '$cmd':\n$OUT"; fi
  [ ! -e "$TMP/out" ] || fail "'$cmd' reached the deploy"
done

# 2. An approved commit that is no longer main's tip is refused.
OLD="$TIP"; TIP="$(advance three)"
if OUT="$(run_gate "deploy-memorial-api-laravel $REL $OLD")"; then fail "a stale homelab sha must be refused:\n$OUT"; fi
grep -q 'approved for' <<<"$OUT" || fail "expected the approved-for explanation, got:\n$OUT"
[ ! -e "$TMP/out" ] || fail "a stale approval reached the deploy"

# 3. The approved tip: the checkout fast-forwards to it and the deploy runs from it.
OUT="$(run_gate "deploy-memorial-api-laravel $REL $TIP")" || fail "the approved tip was refused:\n$OUT"
[ "$(cat "$TMP/out")" = "deployed $REL from $TIP" ] || fail "unexpected hand-over: $(cat "$TMP/out")"

# 4. A checkout with local changes to tracked files is refused.
TIP="$(advance four)"
echo tampered >>"$TMP/host/scripts/deploy-memorial-api-laravel.sh"
if OUT="$(run_gate "deploy-memorial-api-laravel $REL $TIP")"; then fail "a dirty checkout must be refused:\n$OUT"; fi
[ ! -e "$TMP/out" ] || fail "a dirty checkout reached the deploy"
g -C "$TMP/host" checkout -q -- scripts/deploy-memorial-api-laravel.sh

# 5. A checkout off main is refused.
g -C "$TMP/host" checkout -q -b elsewhere
if OUT="$(run_gate "deploy-memorial-api-laravel $REL $TIP")"; then fail "a checkout off main must be refused:\n$OUT"; fi
[ ! -e "$TMP/out" ] || fail "a checkout off main reached the deploy"

echo "PASS: memorial-deploy-gate runs only 'deploy-memorial-api-laravel <sha> <sha>', only from the approved tip of homelab main"
