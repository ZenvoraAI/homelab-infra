#!/usr/bin/env bash
set -euo pipefail

# Documentation contract test for the cross-product RS256 handoff env vars
# (Plan 2026-09-19 Task 16 + Task 24). The runtime check lives at boot in
# memorial's readEnv() (the all-or-nothing gate over the six MEMORIAL_*
# vars); this file is the *offline* sibling that keeps each repo's
# `.env.example` honest about which handoff vars the deploy actually
# needs. A drift here (someone deletes an entry, or renames it in code
# but not in the example) is exactly the kind of thing that surfaces as
# "POST /accept-handoff returns 503 / 401 on a fresh deploy" with no
# useful log line — the validator catches it on the repo before it
# catches an operator at 2am.
#
# Pure repo test:
#   - never reads /opt/secrets/*,
#   - never talks to AWS / SSM / Docker / the network,
#   - never reads docker-compose.yml,
#   - never prints the value side of any variable.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolved against the homelab-infra checkout — both product repos sit
# as siblings. memorial's example env file lives at the repo root, NOT
# under apps/api (Task 16 confirmed that shared convention); family-
# media's lives under apps/api, matching the existing app layout.
FM_DOC="$ROOT/../family-media/apps/api/.env.example"
MEMORIAL_DOC="$ROOT/../aiqiuqi-memorial/.env.example"

FM_EXPECTED=(
  FM_HANDOFF_PRIVATE_KEY_PEM
  FM_HANDOFF_KEY_ID
  MEMORIAL_HANDOFF_BASE_URL
  MEMORIAL_HANDOFF_AUDIENCE
  MEMORIAL_WEB_ORIGIN
)

MEMORIAL_EXPECTED=(
  MEMORIAL_HANDOFF_PUBLIC_KEYS
  MEMORIAL_HANDOFF_AUDIENCE
  MEMORIAL_WEB_ORIGIN
  MEMORIAL_SSO_FAMILY_ID
  MEMORIAL_HANDOFF_ALLOWED_ORIGIN
  MEMORIAL_SSO_SHARED_MEMBER_USERNAME
)

fail() { echo "FAIL: $*" >&2; exit 1; }

# Anchor both files BEFORE running any grep, so a missing path produces
# a clear FAIL instead of a cascade of grep "No such file" errors that
# don't name the wrong path.
[ -f "$FM_DOC" ] || fail "$FM_DOC not found (family-media .env.example must document the 5 handoff vars)"
[ -f "$MEMORIAL_DOC" ] || fail "$MEMORIAL_DOC not found (memorial .env.example must document the 6 handoff vars)"

# check_vars <file> <var...> — every var must appear at the start of a
# line in <file>. A substring match (grep without ^) would accept e.g.
# a comment that mentions the name; we only count an actual assignment.
check_vars() {
  local file="$1"; shift
  local var
  for var in "$@"; do
    grep -q "^${var}=" "$file" || fail "$file is missing $var"
  done
}

check_vars "$FM_DOC" "${FM_EXPECTED[@]}"
check_vars "$MEMORIAL_DOC" "${MEMORIAL_EXPECTED[@]}"

echo "PASS: handoff env vars documented (5 family-media, 6 memorial)"
