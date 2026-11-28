#!/usr/bin/env bash
set -euo pipefail

# scripts/refresh-memorial-laravel-secrets.sh must refuse /opt/secrets/aiqiuqi-memorial/api.env, its only
# target: that file now comes whole from SSM /env/aiqiuqi-memorial/api (README
# "Env files from SSM"), and a per-key write there would make the host differ
# from /env until the next deploy reverted it. Refused before anything is
# fetched, nothing written, no .bak. (Its value checks were tested here until
# the file moved to /env; see git history before this change.)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }
# shellcheck source=tests/lib/refresh-guard.sh
. "$ROOT/tests/lib/refresh-guard.sh"

refresh_guard_test "$ROOT/scripts/refresh-memorial-laravel-secrets.sh" refresh-memorial-laravel-secrets.sh

echo "PASS: refresh-memorial-laravel-secrets.sh refuses the canonical api.env (any root, symlinked dir) before fetching; other files pass the guard"
