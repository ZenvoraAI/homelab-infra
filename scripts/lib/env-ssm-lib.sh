# shellcheck shell=sh
# Shared helpers for scripts/env-to-ssm.sh (backup) and scripts/ssm-to-env.sh
# (restore). Not standalone -- sourced with
# `. "$(dirname -- "$0")/lib/env-ssm-lib.sh"` after the caller sets NAME.
#
# Each env file is stored whole, as two SecureString parameters (default
# aws/ssm key, Standard tier, so each value is at most 4096 bytes):
#
#   /env/<service>       every line except the long ones, in file order; each
#                        long line is replaced by a marker `#env-ssm:pem KEY`
#   /env/<service>-pem   the long lines (a value over ENVSSM_PEM_THRESHOLD
#                        characters), in file order. Length only: routing
#                        every -----BEGIN value (short public keys too) here
#                        left too little of -pem's 4096 bytes for two private
#                        keys.
#
# Both values are framed so the round trip is byte-exact, whatever the CLI or
# SSM does with a trailing newline:
#
#   #env-ssm v1 sha256=<file sha256> final-newline=<0|1> pem-lines=<n>
#   ...lines...
#   #env-ssm end
#
#   #env-ssm-pem v1 lines=<n>
#   ...lines...
#   #env-ssm end
#
# Comments, blank lines and anything that is not KEY=value are ordinary lines:
# kept verbatim, in place. A file containing a CR byte is refused: the AWS CLI
# reads `--value file://` in text mode and turns \r\n and a lone \r into \n,
# so such a file could never verify (checked against aws-cli 2.36.19). A file that already has a line starting with
# `#env-ssm` is refused, so a marker can never be confused with content. The
# -pem parameter is always written, with zero lines when nothing is long, so a
# key removed from the file never lingers in SSM as a stale secret.

ENVSSM_SECRETS_ROOT=${ENVSSM_SECRETS_ROOT:-/opt/secrets}
ENVSSM_REGION=${AWS_REGION:-ap-southeast-2}
# shellcheck disable=SC2034  # used by the scripts that source this
ENVSSM_PREFIX=/env
ENVSSM_MAX_BYTES=4096
ENVSSM_PEM_THRESHOLD=512
ENVSSM_TRAILER='#env-ssm end'

# <service> <file under ENVSSM_SECRETS_ROOT> <required|optional>. The service
# is also the parameter name under /env/. Optional files are skipped by `all`
# when absent (the legacy Express env, only while its rollback window is open).
ENVSSM_SERVICES='
family-media/api            family-media/api-laravel.env           required
aiqiuqi-memorial/api        aiqiuqi-memorial/api.env               required
securevault/api             securevault/api.env                    required
dayandyou-api/staging       dayandyou-api/staging.env              required
zenvora-admin/app           zenvora-admin/.env                     required
family-media/origin-secret  family-media-origin/origin-secret.map  required
family-media/express-legacy family-media/.env                      optional
'

# Services whose /env pair is the source of truth: their deploy pulls the
# whole file from it, and scripts/env-edit.sh is how the file is changed.
# Each name: the read profile its deploy uses (GetParameter on exactly this
# pair, nothing else under /env). Every other service's pair is a backup only.
ENVSSM_CANONICAL='
family-media/api      family-ssm
aiqiuqi-memorial/api  memorial-ssm
'

# The read-only profiles of every service. env-edit refuses them as its
# writer: a read profile that could write would defeat the split.
# shellcheck disable=SC2034  # used by env-edit.sh
ENVSSM_READ_PROFILES='family-ssm memorial-ssm securevault-ssm dayandyou-api-ssm zenvora-admin-ssm'

# Per-key parameters that still hold a copy of a key in a canonical env file.
# The copy is kept because something other than this host reads it or rotates
# into it (README "Per-key parameters"). /env wins: the deploy only compares
# and warns (scripts/env-ssm-mirror-check.sh), env-edit reminds.
# <service> <env key> <per-key parameter>
ENVSSM_MIRRORS='
family-media/api      FM_HANDOFF_KEY_ID                    /family-media/prod/FM_HANDOFF_KEY_ID
family-media/api      FM_HANDOFF_PRIVATE_KEY_PEM           /family-media/prod/FM_HANDOFF_PRIVATE_KEY_PEM
aiqiuqi-memorial/api  APP_KEY                              /aiqiuqi-memorial/preview/APP_KEY
aiqiuqi-memorial/api  CLOUDFRONT_MEDIA_KEY_PAIR_ID         /aiqiuqi-memorial/preview/CLOUDFRONT_MEDIA_KEY_PAIR_ID
aiqiuqi-memorial/api  CLOUDFRONT_MEDIA_PRIVATE_KEY         /aiqiuqi-memorial/preview/CLOUDFRONT_MEDIA_PRIVATE_KEY
aiqiuqi-memorial/api  MEMORIAL_HANDOFF_PUBLIC_KEYS         /aiqiuqi-memorial/preview/MEMORIAL_HANDOFF_PUBLIC_KEYS
aiqiuqi-memorial/api  MEMORIAL_HANDOFF_AUDIENCE            /aiqiuqi-memorial/preview/MEMORIAL_HANDOFF_AUDIENCE
aiqiuqi-memorial/api  MEMORIAL_WEB_ORIGIN                  /aiqiuqi-memorial/preview/MEMORIAL_WEB_ORIGIN
aiqiuqi-memorial/api  MEMORIAL_SSO_FAMILY_ID               /aiqiuqi-memorial/preview/MEMORIAL_SSO_FAMILY_ID
aiqiuqi-memorial/api  MEMORIAL_HANDOFF_ALLOWED_ORIGIN      /aiqiuqi-memorial/preview/MEMORIAL_HANDOFF_ALLOWED_ORIGIN
aiqiuqi-memorial/api  MEMORIAL_SSO_SHARED_MEMBER_USERNAME  /aiqiuqi-memorial/preview/MEMORIAL_SSO_SHARED_MEMBER_USERNAME
aiqiuqi-memorial/api  AWS_ACCESS_KEY_ID                    /aiqiuqi-memorial/preview/API_AWS_ACCESS_KEY_ID
aiqiuqi-memorial/api  AWS_SECRET_ACCESS_KEY                /aiqiuqi-memorial/preview/API_AWS_SECRET_ACCESS_KEY
'

envssm_die() { echo "$NAME: $*" >&2; exit 1; }

envssm_service_names() {
  printf '%s\n' "$ENVSSM_SERVICES" | awk 'NF == 3 { print $1 }'
}

# Prints "<relative path> <required|optional>" for a service, or fails.
envssm_service_row() {
  row=$(printf '%s\n' "$ENVSSM_SERVICES" | awk -v s="$1" 'NF == 3 && $1 == s { print $2, $3 }')
  [ -n "$row" ] || return 1
  printf '%s\n' "$row"
}

envssm_usage_services() {
  envssm_service_names | tr '\n' ' '
}

# The writer profile is temporary and powerful: it must be chosen explicitly.
envssm_resolve_profile() {
  ENVSSM_PROFILE=${1:-${AWS_PROFILE:-}}
  [ -n "$ENVSSM_PROFILE" ] || envssm_die "no AWS profile: pass --profile NAME or set AWS_PROFILE (there is no default)"
  case "$ENVSSM_PROFILE" in
    *[!A-Za-z0-9._-]*) envssm_die "profile name has unexpected characters" ;;
  esac
}

envssm_is_canonical() {
  printf '%s\n' "$ENVSSM_CANONICAL" | awk -v s="$1" 'NF == 2 && $1 == s { f = 1 } END { exit !f }'
}

# Prints "<env key> <parameter>" for each mirror of a service.
envssm_mirrors() {
  printf '%s\n' "$ENVSSM_MIRRORS" | awk -v s="$1" 'NF == 3 && $1 == s { print $2, $3 }'
}

envssm_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

envssm_bytes() { wc -c <"$1" | tr -d ' '; }

# RAM-backed when the host has it, so the plaintext copy never reaches a disk
# block. An explicit TMPDIR wins (the tests use it).
ENVSSM_SHM_DIR=${ENVSSM_SHM_DIR:-/dev/shm}

envssm_make_workdir() {
  base=${TMPDIR:-}
  if [ -z "$base" ] && [ -d "$ENVSSM_SHM_DIR" ] && [ -w "$ENVSSM_SHM_DIR" ]; then
    base=$ENVSSM_SHM_DIR
  fi
  ENVSSM_WORK=$(mktemp -d "${base:-/tmp}/env-ssm.XXXXXX") || envssm_die "cannot create a temp dir"
  chmod 700 "$ENVSSM_WORK"
}

# Runs aws with the chosen profile and region. stdout passes through. stderr
# is captured and only a whitelisted summary is printed: an AWS error message
# can quote request data, and the request data here is a secret.
envssm_aws() {
  [ -n "${ENVSSM_PROFILE:-}" ] || envssm_die "internal error: AWS call without a resolved profile"
  if aws --profile "$ENVSSM_PROFILE" --region "$ENVSSM_REGION" "$@" 2>"$ENVSSM_WORK/aws.err"; then
    return 0
  fi
  summary=$(grep -oE 'An error occurred \([A-Za-z]+\) when calling the [A-Za-z]+ operation|The config profile \([A-Za-z0-9._-]*\) could not be found|Unable to locate credentials|Could not connect to the endpoint URL' \
    "$ENVSSM_WORK/aws.err" | head -n 1 || true)
  echo "$NAME: aws $1 $2 failed: ${summary:-details suppressed (they can quote parameter data)}" >&2
  return 1
}

# Fetches one decrypted parameter value into a file.
envssm_fetch() { # name outfile
  envssm_aws ssm get-parameter --name "$1" --with-decryption \
    --query Parameter.Value --output text >"$2"
}

# Splits an env file into main and pem bodies (newline-terminated lines).
# Prints the number of pem lines.
envssm_split() { # src main_body pem_body
  : >"$2"
  : >"$3"
  LC_ALL=C awk -v main="$2" -v pem="$3" -v thr="$ENVSSM_PEM_THRESHOLD" '
    BEGIN { n = 0 }
    {
      if (match($0, /^(export )?[A-Za-z_][A-Za-z0-9_]*=/)) {
        key = substr($0, 1, RLENGTH - 1)
        sub(/^export /, "", key)
        val = substr($0, RLENGTH + 1)
        if (length(val) > thr) {
          print $0 > pem
          print "#env-ssm:pem " key > main
          n++
          next
        }
      }
      print $0 > main
    }
    END { print n }
  ' "$1"
}

# Writes both framed parameter values for a source file. Sets ENVSSM_SRC_SHA,
# ENVSSM_PEM_LINES.
# The content rules every stored file obeys (backup and env-edit alike).
envssm_check_source() { # src label
  [ -s "$1" ] || envssm_die "$2: source file is empty -- nothing to back up"
  cr_lines=$(LC_ALL=C awk '/\r/ { printf "%s%d", sep, NR; sep = "," }' "$1")
  [ -z "$cr_lines" ] || envssm_die "$2: source has a CR byte on line(s) $cr_lines, which the AWS CLI rewrites to LF -- convert the file to LF line endings first; refusing"
  if LC_ALL=C grep -q '^#env-ssm' "$1"; then
    envssm_die "$2: source has a line starting with #env-ssm, which this format reserves -- refusing"
  fi
}

envssm_build_values() { # src main_value pem_value service
  envssm_check_source "$1" "$4"
  ENVSSM_SRC_SHA=$(envssm_sha256 "$1")
  final_newline=1
  [ -z "$(tail -c 1 "$1")" ] || final_newline=0
  ENVSSM_PEM_LINES=$(envssm_split "$1" "$2.body" "$3.body")
  {
    printf '#env-ssm v1 sha256=%s final-newline=%s pem-lines=%s\n' "$ENVSSM_SRC_SHA" "$final_newline" "$ENVSSM_PEM_LINES"
    cat "$2.body"
    printf '%s' "$ENVSSM_TRAILER"
  } >"$2"
  {
    printf '#env-ssm-pem v1 lines=%s\n' "$ENVSSM_PEM_LINES"
    cat "$3.body"
    printf '%s' "$ENVSSM_TRAILER"
  } >"$3"
  rm -f "$2.body" "$3.body"
}

# Fails loudly when a value would not fit a Standard parameter (no silent
# upgrade to Advanced tier).
envssm_headroom() { # file -> bytes left under the Standard-tier limit
  echo $((ENVSSM_MAX_BYTES - $(envssm_bytes "$1")))
}

envssm_check_size() { # label file
  size=$(envssm_bytes "$2")
  [ "$size" -le "$ENVSSM_MAX_BYTES" ] || envssm_die "$1 would be $size bytes, over the $ENVSSM_MAX_BYTES-byte Standard-tier limit -- refusing (not using Advanced tier)"
}

# Parses the main value's header. Sets ENVSSM_HDR_SHA, ENVSSM_HDR_NEWLINE.
envssm_parse_header() { # main_value
  header=$(head -n 1 "$1")
  ENVSSM_HDR_SHA=$(printf '%s\n' "$header" | sed -n 's/^#env-ssm v1 sha256=\([0-9a-f]\{64\}\) final-newline=[01] pem-lines=[0-9][0-9]*$/\1/p')
  ENVSSM_HDR_NEWLINE=$(printf '%s\n' "$header" | sed -n 's/^#env-ssm v1 sha256=[0-9a-f]\{64\} final-newline=\([01]\) pem-lines=[0-9][0-9]*$/\1/p')
  [ -n "$ENVSSM_HDR_SHA" ] && [ -n "$ENVSSM_HDR_NEWLINE" ] || envssm_die "main parameter has no valid env-ssm v1 header"
}

# Reassembles the original file from the two fetched values. Every framing
# rule is checked; any violation fails without writing a partial file.
envssm_assemble() { # main_value pem_value out
  envssm_parse_header "$1"
  LC_ALL=C awk -v fnl="$ENVSSM_HDR_NEWLINE" -v trailer="$ENVSSM_TRAILER" -v pemfile="$2" '
    function bad(msg) { print "env-ssm: " msg > "/dev/stderr"; failed = 1; exit 1 }
    BEGIN {
      np = 0; pend = 0
      if ((getline line < pemfile) <= 0) bad("pem parameter is empty")
      if (line !~ /^#env-ssm-pem v1 lines=[0-9]+$/) bad("pem parameter has no valid header")
      pexp = substr(line, index(line, "=") + 1) + 0
      while ((getline line < pemfile) > 0) {
        if (pend) bad("pem parameter has data after its trailer")
        if (line == trailer) { pend = 1; continue }
        p[++np] = line
      }
      if (!pend) bad("pem parameter is truncated (no trailer)")
      if (np != pexp) bad("pem parameter line count does not match its header")
      used = 0; nb = 0; mend = 0
    }
    FNR == 1 {
      split($0, h, "pem-lines=")
      mexp = h[2] + 0
      next
    }
    {
      if (mend) bad("main parameter has data after its trailer")
      if ($0 == trailer) { mend = 1; next }
      if (substr($0, 1, 13) == "#env-ssm:pem ") {
        key = substr($0, 14)
        if (++used > np) bad("main parameter has more markers than pem lines")
        l = p[used]
        if (index(l, key "=") != 1 && index(l, "export " key "=") != 1) bad("pem line order does not match the markers")
        b[++nb] = l
        next
      }
      b[++nb] = $0
    }
    END {
      if (failed) exit 1
      if (!mend) bad("main parameter is truncated (no trailer)")
      if (used != np || mexp != np) bad("marker count does not match the pem parameter")
      for (i = 1; i < nb; i++) printf "%s\n", b[i]
      if (nb > 0) { printf "%s", b[nb]; if (fnl == 1) printf "\n" }
    }
  ' "$1" >"$3" || envssm_die "the two parameters do not reassemble into an env file"
}

# --- writing a pair (env-to-ssm.sh and env-edit.sh) ------------------------
# Values go to the CLI as file://, never on the command line (where ps would
# show them).
envssm_put_part() { # param value_file part src_path -> prints the version
  envssm_aws ssm put-parameter --name "$1" --type SecureString --tier Standard \
    --overwrite --value "file://$2" \
    --description "env-ssm backup ($3 part) of $4" \
    --query Version --output text
}

# No hash tag: tags are readable without decrypt rights, and a sha256 of the
# file would fingerprint it for anyone who can list tags.
envssm_tag_part() { # param part src_path
  envssm_aws ssm add-tags-to-resource --resource-type Parameter --resource-id "$1" \
    --tags "Key=env-ssm-source,Value=$3" "Key=env-ssm-part,Value=$2" "Key=env-ssm-format,Value=1" \
    >/dev/null
}

# Writes both built values. -pem first: a run that dies between the two leaves
# the old main part, whose header hash then no longer matches -- a restore
# refuses it. Sets ENVSSM_MAIN_VERSION, ENVSSM_PEM_VERSION.
# shellcheck disable=SC2034  # read by the callers
envssm_write_pair() { # service param src_path main_value pem_value
  ENVSSM_PEM_VERSION=$(envssm_put_part "$2-pem" "$5" pem "$3") || envssm_die "$1: writing $2-pem failed"
  ENVSSM_MAIN_VERSION=$(envssm_put_part "$2" "$4" main "$3") || envssm_die "$1: writing $2 failed"
  envssm_tag_part "$2-pem" pem "$3" || envssm_die "$1: tagging $2-pem failed"
  envssm_tag_part "$2" main "$3" || envssm_die "$1: tagging $2 failed"
}

# What SSM returns must rebuild the file byte for byte. Dies otherwise.
envssm_read_back() { # service param expected_sha what
  envssm_fetch "$2" "$ENVSSM_WORK/got-main" || envssm_die "$1: reading back $2 failed"
  envssm_fetch "$2-pem" "$ENVSSM_WORK/got-pem" || envssm_die "$1: reading back $2-pem failed"
  envssm_assemble "$ENVSSM_WORK/got-main" "$ENVSSM_WORK/got-pem" "$ENVSSM_WORK/rebuilt"
  got_sha=$(envssm_sha256 "$ENVSSM_WORK/rebuilt")
  if [ "$got_sha" != "$3" ] || [ "$ENVSSM_HDR_SHA" != "$3" ]; then
    envssm_die "$1: sha256 MISMATCH between $4 and SSM -- the backup is not usable"
  fi
}
