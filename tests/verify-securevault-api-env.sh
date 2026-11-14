#!/usr/bin/env bash
set -euo pipefail

# SecureVault's settings and secrets reach securevault-api and
# securevault-scheduler only through /opt/secrets/securevault/api.env, which
# scripts/refresh-securevault-secrets.sh writes from SSM. Pinned here:
#   - both services read exactly that file, with required: false: a
#     hard-required env_file that is missing fails `docker compose config` for
#     every service, and every product's deploy runs compose on this file
#   - their environment: holds only the two literals NODE_ENV=production and
#     TRUST_PROXY=1; a bare app key name there would override the file with
#     the deploy shell's value (blank when unset), which is how TRUST_PROXY
#     and WEBAUTHN_* were once lost
#   - no AWS_* name anywhere in either list (the host's AWS CLI keys must
#     never reach the API), no PORT (FPM has no HTTP port), and
#     EXTENSION_SIGNIN_REQUIRED stays out (the deploy passes it to the
#     preflight only, with `docker compose run -e`)
#   - no other service reads or mounts /opt/secrets/securevault
# The key list is taken from the refresh script, so a key added there is
# covered here without a second edit.
#
# Pure repo test: reads docker-compose.yml and the script, never any value.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
SCRIPT="$ROOT/scripts/refresh-securevault-secrets.sh"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

keys="$(sed -nE 's/^(REQUIRED_KEYS|OPTIONAL_KEYS|GOOGLE_KEYS|PHOTO_KEYS)="([^"]*)"$/\2/p' "$SCRIPT" | tr '\n' ' ') ALLOWED_EXTENSION_ORIGINS"
[ "$(wc -w <<<"$keys" | tr -d ' ')" -ge 26 ] || fail "parsed only '$keys' from the refresh script -- parser broke?"

# shellcheck disable=SC2016  # Ruby source
COMPOSE="$COMPOSE" KEYS="$keys" ruby -ryaml -e '
  src = File.read(ENV.fetch("COMPOSE"))
  doc = YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(src) : YAML.load(src)
  services = doc.fetch("services")
  keys = ENV.fetch("KEYS").split
  file = "/opt/secrets/securevault/api.env"
  api = %w[securevault-api securevault-scheduler]
  errors = []
  api.each do |name|
    svc = services[name] or (errors << "missing service #{name}"; next)
    want = [{ "path" => file, "required" => false }]
    errors << "#{name}: env_file must be exactly #{want.inspect}, got #{svc["env_file"].inspect}" unless svc["env_file"] == want
    env = Array(svc["environment"]).map(&:to_s)
    errors << "#{name}: environment must be exactly the literals, got #{env.inspect}" unless env == %w[NODE_ENV=production TRUST_PROXY=1]
    env.each do |e|
      n = e.split("=").first
      errors << "#{name}: environment must not name #{n} (it would override the env file)" if keys.include?(n)
      errors << "#{name}: environment must not name #{n}" if n.start_with?("AWS_") || %w[PORT EXTENSION_SIGNIN_REQUIRED FPM_LISTEN].include?(n)
    end
  end
  services.each do |name, svc|
    next if api.include?(name)
    refs = Array(svc["env_file"]).map { |e| e.is_a?(Hash) ? e["path"].to_s : e.to_s } + Array(svc["volumes"]).map(&:to_s)
    errors << "#{name}: must not read /opt/secrets/securevault" if refs.any? { |r| r.start_with?("/opt/secrets/securevault") }
  end
  if errors.empty?
    puts "ok"
  else
    errors.each { |e| warn "FAIL: #{e}" }
    exit 1
  end
' >/dev/null

# No AWS_* key may ever be written into the API's file.
grep -E '^(REQUIRED_KEYS|OPTIONAL_KEYS|GOOGLE_KEYS|PHOTO_KEYS)=' "$SCRIPT" | grep -qE '(^|[" ])AWS_' \
  && fail "refresh-securevault-secrets.sh must not manage any AWS_* key"

# Anchors keep the scheduler from drifting from the API service.
grep -q '^    env_file: &securevault-api-env-file$' "$COMPOSE" || fail "securevault-api env_file: must carry the &securevault-api-env-file anchor"
grep -q '^    environment: &securevault-api-env$' "$COMPOSE" || fail "securevault-api environment: must carry the &securevault-api-env anchor"
sched="$(awk '
  /^  securevault-scheduler:[[:space:]]*$/ { in_svc = 1; next }
  in_svc && /^  [A-Za-z0-9_-]+:/ { in_svc = 0 }
  in_svc && /^    (env_file|environment):/ { print }
' "$COMPOSE")"
[ "$sched" = "$(printf '    env_file: *securevault-api-env-file\n    environment: *securevault-api-env')" ] \
  || fail "securevault-scheduler must reuse the API's env_file and environment anchors, got:\n$sched"

echo "PASS: securevault services read only securevault/api.env (required: false); environment: holds only NODE_ENV/TRUST_PROXY literals"
