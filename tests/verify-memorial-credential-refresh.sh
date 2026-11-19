#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for refresh-memorial-aws-credentials.sh.
#
# The script exists because the memorial containers ran with placeholder text
# as their AWS_ACCESS_KEY_ID. So the property under test is not "it can write a
# credential" -- it is "it refuses to write a bad one". Since aiqiuqi-memorial
# Part A removed the media worker, only the API's credentials are managed; a
# leftover worker.env on the host is left exactly as it is.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/refresh-memorial-aws-credentials.sh"

TMP="$(mktemp -d)"
BIN="$TMP/bin"
SECRETS="$TMP/secrets"
mkdir -p "$BIN" "$SECRETS"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

VALID_KEY_A='AKIAIOSFODNN7EXAMPLE'
VALID_KEY_W='AKIAI44QH8DHBEXAMPLE'
VALID_SECRET='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'

# The API env file also carries a multi-line CloudFront private key. Stripping
# the AWS_ lines must not disturb it -- a filter that ate the PEM would leave
# signed media URLs broken while the credentials looked fine.
PEM_MARKER='-----BEGIN RSA PRIVATE KEY-----'

write_env_files() {
  local key_line="${1:-AWS_ACCESS_KEY_ID=old-value}"
  # Clear backups from previous checks, so "no backup was taken" below tests
  # this run rather than the accumulated state of the whole file.
  rm -f "$SECRETS"/*.bak-*
  cat >"$SECRETS/api.env" <<EOF
DATABASE_URL=postgresql://example/memorial
${key_line}
AWS_SECRET_ACCESS_KEY=old-secret
CLOUDFRONT_MEDIA_KEY_PAIR_ID=K123EXAMPLE
CLOUDFRONT_MEDIA_PRIVATE_KEY=${PEM_MARKER}
MIIEowIBAAKCAQEAxGD5example+base64+content/withslashes
-----END RSA PRIVATE KEY-----
PORT=4000
EOF
  cat >"$SECRETS/worker.env" <<EOF
DATABASE_URL=postgresql://example/memorial
${key_line}
AWS_SECRET_ACCESS_KEY=old-secret
CONCURRENCY=2
EOF
  chmod 600 "$SECRETS/api.env" "$SECRETS/worker.env"
}

# --- stubs -----------------------------------------------------------------
# stat -c and chown are Linux/root shapes the host has and this machine does not.
cat >"$BIN/stat" <<'EOF'
#!/usr/bin/env bash
echo "1000:1000"
EOF
cat >"$BIN/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$BIN/aws" <<'EOF'
#!/usr/bin/env bash
name=''
while [ "$#" -gt 0 ]; do
  case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s' "$(cat "$PARAMS/${name##*/}" 2>/dev/null)"
EOF
chmod +x "$BIN"/*

set_params() {
  mkdir -p "$TMP/params"
  rm -f "$TMP/params"/*
  printf '%s' "$1" >"$TMP/params/API_AWS_ACCESS_KEY_ID"
  printf '%s' "$2" >"$TMP/params/API_AWS_SECRET_ACCESS_KEY"
  printf '%s' "$3" >"$TMP/params/WORKER_AWS_ACCESS_KEY_ID"
  printf '%s' "$4" >"$TMP/params/WORKER_AWS_SECRET_ACCESS_KEY"
}

run_refresh() {
  env PATH="$BIN:$PATH" PARAMS="$TMP/params" SECRETS_DIR="$SECRETS" \
      sh "$SCRIPT" 2>&1
}

value_of() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2-; }

# ---------------------------------------------------------------------------
# 1. Valid credentials are written to api.env; worker.env is left alone
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_A" "$VALID_SECRET" "$VALID_KEY_W" "$VALID_SECRET"
OUT="$(run_refresh)" || fail "valid credentials should be written, got:\n$OUT"
[ "$(value_of "$SECRETS/api.env" AWS_ACCESS_KEY_ID)" = "$VALID_KEY_A" ] \
  || fail "api.env did not receive its key"
[ "$(value_of "$SECRETS/worker.env" AWS_ACCESS_KEY_ID)" = "old-value" ] \
  || fail "worker.env was modified, but the worker no longer exists"
[ "$(value_of "$SECRETS/api.env" AWS_SECRET_ACCESS_KEY)" = "$VALID_SECRET" ] \
  || fail "api.env did not receive its secret"

# Each file gets exactly one of each key line, not an appended duplicate.
[ "$(grep -c '^AWS_ACCESS_KEY_ID=' "$SECRETS/api.env")" = 1 ] \
  || fail "api.env has duplicate AWS_ACCESS_KEY_ID lines"

# ---------------------------------------------------------------------------
# 2. The multi-line CloudFront private key survives
# ---------------------------------------------------------------------------
grep -q -- "$PEM_MARKER" "$SECRETS/api.env" || fail "the PEM was stripped from api.env"
grep -q -- '-----END RSA PRIVATE KEY-----' "$SECRETS/api.env" || fail "the PEM END line was stripped"
grep -q '^MIIEowIBAAKCAQEAxGD5example' "$SECRETS/api.env" || fail "the PEM body was stripped"
grep -q '^PORT=4000' "$SECRETS/api.env" || fail "content after the PEM was lost"

# ---------------------------------------------------------------------------
# 3. Secrets never appear in the output
# ---------------------------------------------------------------------------
grep -q "$VALID_SECRET" <<<"$OUT" && fail "the secret was echoed to stdout"

# ---------------------------------------------------------------------------
# 4. A placeholder key id is refused -- the original failure, verbatim
# ---------------------------------------------------------------------------
write_env_files
set_params '换成qiuqi-api的access-key-id' "$VALID_SECRET" "$VALID_KEY_W" "$VALID_SECRET"
if OUT="$(run_refresh)"; then
  fail "a placeholder access key id must be refused, got:\n$OUT"
fi
grep -q 'not an AWS access key id' <<<"$OUT" || fail "expected a shape complaint, got:\n$OUT"

# ---------------------------------------------------------------------------
# 5. A truncated secret is refused
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_A" 'wJalrXUtnFEMI/K7MDENG' "$VALID_KEY_W" "$VALID_SECRET"
if OUT="$(run_refresh)"; then
  fail "a truncated secret must be refused, got:\n$OUT"
fi
grep -q '40-character' <<<"$OUT" || fail "expected a length complaint, got:\n$OUT"

# ---------------------------------------------------------------------------
# 6. The retired WORKER parameters are no longer read
#
# The media worker was removed (aiqiuqi-memorial Part A). Its SSM parameters may
# still exist, possibly stale; they must neither block the API's refresh nor be
# written anywhere.
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_A" "$VALID_SECRET" 'TODO-fill-me-in' "$VALID_SECRET"
OUT="$(run_refresh)" || fail "a stale worker parameter must not block the API refresh, got:\n$OUT"
[ "$(value_of "$SECRETS/api.env" AWS_ACCESS_KEY_ID)" = "$VALID_KEY_A" ] \
  || fail "api.env did not receive its key"
grep -q 'TODO-fill-me-in' "$SECRETS/worker.env" "$SECRETS/api.env" \
  && fail "the retired worker parameter was written somewhere"

# ---------------------------------------------------------------------------
# 7. An empty or unreadable parameter is refused, not written as blank
# ---------------------------------------------------------------------------
write_env_files
set_params '' "$VALID_SECRET" "$VALID_KEY_W" "$VALID_SECRET"
if OUT="$(run_refresh)"; then
  fail "an empty parameter must be refused, got:\n$OUT"
fi
grep -q 'empty or unreadable' <<<"$OUT" || fail "expected an empty-parameter complaint, got:\n$OUT"
[ "$(value_of "$SECRETS/api.env" AWS_ACCESS_KEY_ID)" = "old-value" ] \
  || fail "api.env was modified despite an empty parameter"

echo "PASS: memorial credential refresh (7 checks)"
