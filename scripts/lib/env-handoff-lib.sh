# shellcheck shell=sh
# The family-media -> memorial handoff, checked across the two canonical env
# files by scripts/env-edit.sh: family signs with FM_HANDOFF_PRIVATE_KEY_PEM
# under kid FM_HANDOFF_KEY_ID, memorial accepts the public keys listed in
# MEMORIAL_HANDOFF_PUBLIC_KEYS ([{"kid": ..., "pem": ...}]). The pair is
# consistent when the public key derived from family's private key, and
# family's kid, both appear in memorial's list. Sourced after env-ssm-lib.sh.
# Never prints a value: reasons name keys and services only.

# Env values as the refresh scripts wrote them are bare; a value wrapped in
# one pair of matching quotes is unwrapped.
envhandoff_unquote() {
  case "$1" in
    \'*\'|\"*\") v=${1#?}; printf '%s' "${v%?}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Returns 0 when consistent; otherwise prints the reason (names only) and 1.
envhandoff_check() { # family_env memorial_env workdir
  priv=$(envssm_env_value "$1" FM_HANDOFF_PRIVATE_KEY_PEM) || { echo "FM_HANDOFF_PRIVATE_KEY_PEM is missing from family-media/api"; return 1; }
  kid=$(envssm_env_value "$1" FM_HANDOFF_KEY_ID) || { echo "FM_HANDOFF_KEY_ID is missing from family-media/api"; return 1; }
  keys=$(envssm_env_value "$2" MEMORIAL_HANDOFF_PUBLIC_KEYS) || { echo "MEMORIAL_HANDOFF_PUBLIC_KEYS is missing from aiqiuqi-memorial/api"; return 1; }
  command -v openssl >/dev/null 2>&1 || { echo "openssl is not installed, so FM_HANDOFF_PRIVATE_KEY_PEM cannot be checked against MEMORIAL_HANDOFF_PUBLIC_KEYS"; return 1; }
  # The PEM is one line with literal \n (README "Family API on Laravel").
  envhandoff_unquote "$priv" | LC_ALL=C awk '{ gsub(/\\n/, "\n"); print }' >"$3/handoff-priv.pem"
  openssl pkey -in "$3/handoff-priv.pem" -pubout -out "$3/handoff-pub.pem" 2>/dev/null \
    || { echo "FM_HANDOFF_PRIVATE_KEY_PEM in family-media/api is not a readable private key"; return 1; }
  body=$(grep -v -- '-----' "$3/handoff-pub.pem" | tr -d '\r\n ')
  # JSON escapes: \n inside the pem strings, and possibly \/ for /.
  list=$(printf '%s' "$keys" | sed 's/\\n//g; s/\\\//\//g' | tr -d ' \t\r\n')
  kid=$(envhandoff_unquote "$kid")
  printf '%s' "$list" | LC_ALL=C awk -v b="$body" 'index($0, b) { f = 1 } END { exit !f }' \
    || { echo "the public key of FM_HANDOFF_PRIVATE_KEY_PEM (family-media/api) is not in MEMORIAL_HANDOFF_PUBLIC_KEYS (aiqiuqi-memorial/api)"; return 1; }
  printf '%s' "$list" | LC_ALL=C awk -v k="\"kid\":\"$kid\"" 'index($0, k) { f = 1 } END { exit !f }' \
    || { echo "FM_HANDOFF_KEY_ID (family-media/api) is not a kid in MEMORIAL_HANDOFF_PUBLIC_KEYS (aiqiuqi-memorial/api)"; return 1; }
}
