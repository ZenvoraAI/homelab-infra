#!/usr/bin/env bash
set -euo pipefail

# Behavioural test for the handoff-env block of refresh-memorial-secrets.sh.
#
# The script was originally written only for the CloudFront media signing
# pair (Task 16's later addition wired the six MEMORIAL_* handoff vars
# into the same refresh). The property under test here is the one that
# matters for the RUNBOOK: a successful refresh writes all six handoff
# vars to /opt/secrets/aiqiuqi-memorial/api.env, and a malformed SSM
# value aborts BEFORE the file is touched -- not on the next boot.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/refresh-memorial-secrets.sh"

TMP="$(mktemp -d)"
BIN="$TMP/bin"
SECRETS="$TMP/secrets"
mkdir -p "$BIN" "$SECRETS"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# CloudFront private key shape: anything containing BEGIN/END pair so the
# PEM-shape check passes; this test never exercises that branch on its
# own (the handoff-block check runs AFTER the CloudFront validation
# succeeds), but a malformed PEM still aborts early and we need at
# least one valid value to reach the handoff code.
PEM_MARKER='-----BEGIN RSA PRIVATE KEY-----'
PEM_BODY='MIIEowIBAAKCAQEAxGD5example+base64+content/withslashes'
PEM_END='-----END RSA PRIVATE KEY-----'
VALID_KEY_ID='K123EXAMPLE'
VALID_PUBLIC_KEYS='[{"kid":"fm-2026-09-v1","pem":"-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCg=\n-----END PUBLIC KEY-----"}]'
VALID_AUDIENCE='memorial'
VALID_WEB_ORIGIN='https://aiqiuqi.com'
VALID_FAMILY_ID='fam-1'
VALID_ALLOWED_ORIGIN='https://family.valtou.com'
VALID_SHARED_USER='shared.member'

write_env_files() {
  rm -f "$SECRETS"/*.bak-*
  cat >"$SECRETS/api.env" <<EOF
DATABASE_URL=postgresql://example/memorial
PORT=4000
CLOUDFRONT_MEDIA_KEY_PAIR_ID=old-key-id
CLOUDFRONT_MEDIA_PRIVATE_KEY=${PEM_MARKER}
${PEM_BODY}
${PEM_END}
EOF
  chmod 600 "$SECRETS/api.env"
}

# --- stubs -----------------------------------------------------------------
# stat -c and chown are Linux/root shapes the host has and this machine
# does not. Mirror verify-memorial-credential-refresh.sh's stubs.
cat >"$BIN/stat" <<'EOF'
#!/usr/bin/env bash
echo "1000:1000"
EOF
cat >"$BIN/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# aws ssm get-parameter stub: prints the value of the matching file from
# $PARAMS/<parameter name>. Keeps the test hermetic and lets every check
# set up exactly the values it wants.
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
  cat >"$TMP/params/CLOUDFRONT_MEDIA_KEY_PAIR_ID" <<<"$1"
  cat >"$TMP/params/CLOUDFRONT_MEDIA_PRIVATE_KEY" <<<"$2"
  cat >"$TMP/params/MEMORIAL_HANDOFF_PUBLIC_KEYS" <<<"$3"
  cat >"$TMP/params/MEMORIAL_HANDOFF_AUDIENCE" <<<"$4"
  cat >"$TMP/params/MEMORIAL_WEB_ORIGIN" <<<"$5"
  cat >"$TMP/params/MEMORIAL_SSO_FAMILY_ID" <<<"$6"
  cat >"$TMP/params/MEMORIAL_HANDOFF_ALLOWED_ORIGIN" <<<"$7"
  cat >"$TMP/params/MEMORIAL_SSO_SHARED_MEMBER_USERNAME" <<<"$8"
}

run_refresh() {
  env PATH="$BIN:$PATH" PARAMS="$TMP/params" SECRETS_DIR="$SECRETS" \
      sh "$SCRIPT" 2>&1
}

value_of() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2-; }

# ---------------------------------------------------------------------------
# 1. Valid handoff env writes all six MEMORIAL_* vars to api.env
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "$VALID_PUBLIC_KEYS" "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "$VALID_ALLOWED_ORIGIN" "$VALID_SHARED_USER"
OUT="$(run_refresh)" || fail "valid handoff env should be written, got:\n$OUT"
echo "$OUT" | grep -q 'updated.*CLOUDFRONT_MEDIA_KEY_PAIR_ID, CLOUDFRONT_MEDIA_PRIVATE_KEY, and 6 MEMORIAL_\* handoff vars' \
  || fail "expected 6-vars-updated message, got:\n$OUT"

[ "$(value_of "$SECRETS/api.env" MEMORIAL_HANDOFF_PUBLIC_KEYS)" = "$VALID_PUBLIC_KEYS" ] \
  || fail "MEMORIAL_HANDOFF_PUBLIC_KEYS was not written"
[ "$(value_of "$SECRETS/api.env" MEMORIAL_HANDOFF_AUDIENCE)" = "$VALID_AUDIENCE" ] \
  || fail "MEMORIAL_HANDOFF_AUDIENCE was not written"
[ "$(value_of "$SECRETS/api.env" MEMORIAL_WEB_ORIGIN)" = "$VALID_WEB_ORIGIN" ] \
  || fail "MEMORIAL_WEB_ORIGIN was not written"
[ "$(value_of "$SECRETS/api.env" MEMORIAL_SSO_FAMILY_ID)" = "$VALID_FAMILY_ID" ] \
  || fail "MEMORIAL_SSO_FAMILY_ID was not written"
[ "$(value_of "$SECRETS/api.env" MEMORIAL_HANDOFF_ALLOWED_ORIGIN)" = "$VALID_ALLOWED_ORIGIN" ] \
  || fail "MEMORIAL_HANDOFF_ALLOWED_ORIGIN was not written"
[ "$(value_of "$SECRETS/api.env" MEMORIAL_SSO_SHARED_MEMBER_USERNAME)" = "$VALID_SHARED_USER" ] \
  || fail "MEMORIAL_SSO_SHARED_MEMBER_USERNAME was not written"

# CloudFront vars still written (regression check: extending the script
# must not have broken the original behaviour).
[ "$(value_of "$SECRETS/api.env" CLOUDFRONT_MEDIA_KEY_PAIR_ID)" = "$VALID_KEY_ID" ] \
  || fail "CLOUDFRONT_MEDIA_KEY_PAIR_ID was not written"

# Exactly one line per handoff var, not appended duplicates.
for v in MEMORIAL_HANDOFF_PUBLIC_KEYS MEMORIAL_HANDOFF_AUDIENCE MEMORIAL_WEB_ORIGIN \
         MEMORIAL_SSO_FAMILY_ID MEMORIAL_HANDOFF_ALLOWED_ORIGIN MEMORIAL_SSO_SHARED_MEMBER_USERNAME; do
  [ "$(grep -c "^$v=" "$SECRETS/api.env")" = 1 ] \
    || fail "api.env has duplicate $v lines"
done

# ---------------------------------------------------------------------------
# 2. The multi-line CloudFront private key still survives the rewrite
#    (the new awk block adds six new prefix filters; getting any one
#    wrong would silently drop the PEM body or the lines after it.)
# ---------------------------------------------------------------------------
grep -q -- "$PEM_MARKER" "$SECRETS/api.env" || fail "the PEM was stripped from api.env"
grep -q -- "$PEM_END" "$SECRETS/api.env" || fail "the PEM END line was stripped"
grep -q '^MIIEowIBAAKCAQEAxGD5example' "$SECRETS/api.env" || fail "the PEM body was stripped"
grep -q '^PORT=4000' "$SECRETS/api.env" || fail "content after the PEM was lost"

# ---------------------------------------------------------------------------
# 3. Secrets never appear in stdout
# ---------------------------------------------------------------------------
# The PEM body is the most likely leak surface (it's base64 with /+=
# and looks like normal text). If it ends up in the script output, the
# shell is being too chatty.
grep -q "$PEM_BODY" <<<"$OUT" && fail "the private-key body was echoed to stdout"
grep -q "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCg=" <<<"$OUT" \
  && fail "the public-key body was echoed to stdout"

# ---------------------------------------------------------------------------
# 4. An empty MEMORIAL_HANDOFF_AUDIENCE is refused BEFORE the file is
#    touched. The all-or-nothing handoff gate is the property under
#    test: a partially-written handoff block would let memorial boot
#    in a half-configured state.
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "$VALID_PUBLIC_KEYS" "" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "$VALID_ALLOWED_ORIGIN" "$VALID_SHARED_USER"
if OUT="$(run_refresh)"; then
  fail "an empty MEMORIAL_HANDOFF_AUDIENCE must abort the run, got:\n$OUT"
fi
grep -q 'empty MEMORIAL_HANDOFF_AUDIENCE' <<<"$OUT" \
  || fail "expected empty-audience complaint, got:\n$OUT"
[ -z "$(ls "$SECRETS"/*.bak-* 2>/dev/null)" ] \
  || fail "a backup was taken before validation completed"
[ "$(value_of "$SECRETS/api.env" MEMORIAL_HANDOFF_AUDIENCE)" = "" ] \
  || fail "MEMORIAL_HANDOFF_AUDIENCE was written despite empty SSM value"

# ---------------------------------------------------------------------------
# 5. A MEMORIAL_HANDOFF_PUBLIC_KEYS without a PEM marker is refused
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "TODO-fill-me-in" "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "$VALID_ALLOWED_ORIGIN" "$VALID_SHARED_USER"
if OUT="$(run_refresh)"; then
  fail "a malformed public-key JSON must abort the run, got:\n$OUT"
fi
grep -q 'MEMORIAL_HANDOFF_PUBLIC_KEYS' <<<"$OUT" \
  || fail "expected MEMORIAL_HANDOFF_PUBLIC_KEYS complaint, got:\n$OUT"
[ -z "$(ls "$SECRETS"/*.bak-* 2>/dev/null)" ] \
  || fail "a backup was taken before validation completed"

# ---------------------------------------------------------------------------
# 6. MEMORIAL_HANDOFF_ALLOWED_ORIGIN with a path is refused
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "$VALID_PUBLIC_KEYS" "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "https://app.family.valtou.com/some/path" "$VALID_SHARED_USER"
if OUT="$(run_refresh)"; then
  fail "an allowed origin with a path must abort the run, got:\n$OUT"
fi
grep -q 'MEMORIAL_HANDOFF_ALLOWED_ORIGIN' <<<"$OUT" \
  || fail "expected allowed-origin complaint, got:\n$OUT"
[ -z "$(ls "$SECRETS"/*.bak-* 2>/dev/null)" ] \
  || fail "a backup was taken before validation completed"

# ---------------------------------------------------------------------------
# 7. MEMORIAL_HANDOFF_PUBLIC_KEYS with wrong JSON shape is refused.
#    The value still contains the PEM marker (so the shape-check is the
#    one that fires, not the PEM-marker check above).
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  '{"kid":"x","pem":"-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----"}' \
  "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "$VALID_ALLOWED_ORIGIN" "$VALID_SHARED_USER"
if OUT="$(run_refresh)"; then
  fail "a non-array public-key JSON must abort the run, got:\n$OUT"
fi
grep -q 'must be a JSON array' <<<"$OUT" \
  || fail "expected JSON-array complaint, got:\n$OUT"

# ---------------------------------------------------------------------------
# 8. MEMORIAL_HANDOFF_ALLOWED_ORIGIN with a query string and NO trailing
#    '/' is refused. This is the case the previous awk split missed
#    (the '/'-based authority delimiter never fired, so query slipped
#    through). The original env file must be byte-for-byte unchanged:
#    no .new, no backup, no chmod / chown side-effect.
# ---------------------------------------------------------------------------
write_env_files
ORIG_BYTES=$(wc -c <"$SECRETS/api.env")
ORIG_HASH=$(shasum -a 256 "$SECRETS/api.env" | awk '{print $1}')
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "$VALID_PUBLIC_KEYS" "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "https://app.family.valtou.com?x=1" "$VALID_SHARED_USER"
if OUT="$(run_refresh)"; then
  fail "an allowed origin with a query (no trailing /) must abort the run, got:\n$OUT"
fi
grep -q 'MEMORIAL_HANDOFF_ALLOWED_ORIGIN' <<<"$OUT" \
  || fail "expected allowed-origin complaint, got:\n$OUT"
[ ! -e "$SECRETS/api.env.new" ] || fail ".new was created despite invalid allowed origin"
[ -z "$(ls "$SECRETS"/*.bak-* 2>/dev/null)" ] \
  || fail "a backup was taken before validation completed"
[ "$(wc -c <"$SECRETS/api.env")" = "$ORIG_BYTES" ] \
  || fail "api.env size changed despite invalid allowed origin"
[ "$(shasum -a 256 "$SECRETS/api.env" | awk '{print $1}')" = "$ORIG_HASH" ] \
  || fail "api.env bytes changed despite invalid allowed origin"

# ---------------------------------------------------------------------------
# 9. MEMORIAL_HANDOFF_ALLOWED_ORIGIN with userinfo (no trailing /) is
#    refused. Same root cause as the query case: the old split looked
#    for '@' before the first '/', but no '/' means the check never
#    fired.
# ---------------------------------------------------------------------------
write_env_files
ORIG_HASH=$(shasum -a 256 "$SECRETS/api.env" | awk '{print $1}')
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "$VALID_PUBLIC_KEYS" "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "https://user@app.family.valtou.com" "$VALID_SHARED_USER"
if OUT="$(run_refresh)"; then
  fail "an allowed origin with userinfo (no trailing /) must abort the run, got:\n$OUT"
fi
grep -q 'MEMORIAL_HANDOFF_ALLOWED_ORIGIN' <<<"$OUT" \
  || fail "expected allowed-origin complaint, got:\n$OUT"
[ ! -e "$SECRETS/api.env.new" ] || fail ".new was created despite userinfo in allowed origin"
[ -z "$(ls "$SECRETS"/*.bak-* 2>/dev/null)" ] \
  || fail "a backup was taken before validation completed"
[ "$(shasum -a 256 "$SECRETS/api.env" | awk '{print $1}')" = "$ORIG_HASH" ] \
  || fail "api.env bytes changed despite userinfo in allowed origin"

# ---------------------------------------------------------------------------
# 10. MEMORIAL_HANDOFF_ALLOWED_ORIGIN with a fragment (no trailing /) is
#     also refused — same root cause, symmetric case.
# ---------------------------------------------------------------------------
write_env_files
ORIG_HASH=$(shasum -a 256 "$SECRETS/api.env" | awk '{print $1}')
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "$VALID_PUBLIC_KEYS" "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "https://app.family.valtou.com#frag" "$VALID_SHARED_USER"
if OUT="$(run_refresh)"; then
  fail "an allowed origin with a fragment (no trailing /) must abort the run, got:\n$OUT"
fi
grep -q 'MEMORIAL_HANDOFF_ALLOWED_ORIGIN' <<<"$OUT" \
  || fail "expected allowed-origin complaint, got:\n$OUT"
[ ! -e "$SECRETS/api.env.new" ] || fail ".new was created despite fragment in allowed origin"
[ -z "$(ls "$SECRETS"/*.bak-* 2>/dev/null)" ] \
  || fail "a backup was taken before validation completed"

# ---------------------------------------------------------------------------
# 11. http:// scheme is refused (memorial readEnv() requires https for the
#     cross-product POST origin).
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "$VALID_PUBLIC_KEYS" "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "http://app.family.valtou.com" "$VALID_SHARED_USER"
if OUT="$(run_refresh)"; then
  fail "an http:// allowed origin must abort the run, got:\n$OUT"
fi
grep -q 'MEMORIAL_HANDOFF_ALLOWED_ORIGIN' <<<"$OUT" \
  || fail "expected allowed-origin complaint, got:\n$OUT"

# ---------------------------------------------------------------------------
# 12. Allowed origin with a port (e.g. :443) is refused.
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "$VALID_PUBLIC_KEYS" "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "https://app.family.valtou.com:443" "$VALID_SHARED_USER"
if OUT="$(run_refresh)"; then
  fail "an allowed origin with a port must abort the run, got:\n$OUT"
fi
grep -q 'MEMORIAL_HANDOFF_ALLOWED_ORIGIN' <<<"$OUT" \
  || fail "expected allowed-origin complaint, got:\n$OUT"

# ---------------------------------------------------------------------------
# 13. The two legal forms still succeed end-to-end (regression for the
#     fixed validator).
# ---------------------------------------------------------------------------
write_env_files
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "$VALID_PUBLIC_KEYS" "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "https://app.family.valtou.com" "$VALID_SHARED_USER"
OUT="$(run_refresh)" || fail "bare-origin allowed origin should succeed, got:\n$OUT"
echo "$OUT" | grep -q 'updated.*6 MEMORIAL_\* handoff vars' \
  || fail "expected 6-vars-updated message, got:\n$OUT"

write_env_files
set_params "$VALID_KEY_ID" "${PEM_MARKER}
${PEM_BODY}
${PEM_END}" \
  "$VALID_PUBLIC_KEYS" "$VALID_AUDIENCE" "$VALID_WEB_ORIGIN" \
  "$VALID_FAMILY_ID" "https://app.family.valtou.com/" "$VALID_SHARED_USER"
OUT="$(run_refresh)" || fail "origin-with-slash allowed origin should succeed, got:\n$OUT"
echo "$OUT" | grep -q 'updated.*6 MEMORIAL_\* handoff vars' \
  || fail "expected 6-vars-updated message, got:\n$OUT"

echo "PASS: memorial handoff env refresh (13 checks)"
