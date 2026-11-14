#!/usr/bin/env bash
set -euo pipefail

# The Day and You API's settings and secrets reach its containers only through
# /opt/secrets/dayandyou-api/staging.env, which
# scripts/refresh-dayandyou-api-secrets.sh writes from SSM. Pinned here:
#   - both staging services read exactly that file, with required: false: a
#     hard-required env_file that is missing fails `docker compose config` for
#     every service, and every product's deploy runs compose on this file
#   - their environment: holds only the two FPM literals; a bare app key name
#     there would override the file with the deploy shell's value (blank when
#     unset), which is how settings used to be lost
#   - no other service reads or mounts /opt/secrets/dayandyou-api (a prod file
#     will get its own services; staging never reads it)
# The key list is taken from the refresh script, so a key added there is
# covered here without a second edit.
#
# Pure repo test: reads docker-compose.yml and the script, never any value.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"
SCRIPT="$ROOT/scripts/refresh-dayandyou-api-secrets.sh"

fail() { printf 'FAIL: %b\n' "$*" >&2; exit 1; }

keys="$(sed -nE 's/^(REQUIRED_KEYS|STAGING_ONLY_KEYS|OPTIONAL_GROUP_KEYS)="([^"]*)"$/\2/p' "$SCRIPT" | tr '\n' ' ')"
[ "$(wc -w <<<"$keys" | tr -d ' ')" -ge 22 ] || fail "parsed only '$keys' from the refresh script -- parser broke?"

# shellcheck disable=SC2016  # Ruby source
COMPOSE="$COMPOSE" KEYS="$keys" ruby -ryaml -e '
  src = File.read(ENV.fetch("COMPOSE"))
  doc = YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(src) : YAML.load(src)
  services = doc.fetch("services")
  keys = ENV.fetch("KEYS").split
  file = "/opt/secrets/dayandyou-api/staging.env"
  api = %w[dayandyou-api-staging dayandyou-api-scheduler-staging]
  errors = []
  api.each do |name|
    svc = services[name] or (errors << "missing service #{name}"; next)
    want = [{ "path" => file, "required" => false }]
    errors << "#{name}: env_file must be exactly #{want.inspect}, got #{svc["env_file"].inspect}" unless svc["env_file"] == want
    env = Array(svc["environment"]).map(&:to_s)
    errors << "#{name}: environment must be exactly the FPM literals, got #{env.inspect}" unless env == %w[FPM_MAX_CHILDREN=2 FPM_PAYMENTS_PM=dynamic]
    env.each do |e|
      errors << "#{name}: environment must not name #{e.split("=").first} (it would override the env file)" if keys.include?(e.split("=").first)
    end
  end
  services.each do |name, svc|
    next if api.include?(name)
    refs = Array(svc["env_file"]).map { |e| e.is_a?(Hash) ? e["path"].to_s : e.to_s } + Array(svc["volumes"]).map(&:to_s)
    errors << "#{name}: must not read /opt/secrets/dayandyou-api" if refs.any? { |r| r.start_with?("/opt/secrets/dayandyou-api") }
  end
  if errors.empty?
    puts "ok"
  else
    errors.each { |e| warn "FAIL: #{e}" }
    exit 1
  end
' >/dev/null

# Anchors keep the scheduler from drifting from the API service.
grep -q '^    env_file: &dayandyou-api-staging-env-file$' "$COMPOSE" || fail "dayandyou-api-staging env_file: must carry the &dayandyou-api-staging-env-file anchor"
sched="$(awk '
  /^  dayandyou-api-scheduler-staging:[[:space:]]*$/ { in_svc = 1; next }
  in_svc && /^  [A-Za-z0-9_-]+:/ { in_svc = 0 }
  in_svc && /^    (env_file|environment):/ { print }
' "$COMPOSE")"
[ "$sched" = "$(printf '    env_file: *dayandyou-api-staging-env-file\n    environment: *dayandyou-api-staging-env')" ] \
  || fail "dayandyou-api-scheduler-staging must reuse the API's env_file and environment anchors, got:\n$sched"

echo "PASS: dayandyou-api staging services read only dayandyou-api/staging.env (required: false); environment: holds only the FPM literals"
