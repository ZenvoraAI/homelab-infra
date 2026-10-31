#!/usr/bin/env bash
set -euo pipefail

# Confinement per service, applied only where it was verified against the
# product's Dockerfile and runtime code (README "Container hardening" lists the
# evidence and what is deliberately left out):
#   - every service: security_opt no-new-privileges:true. Blocks gaining
#     privilege through a setuid/file-capability exec; nothing here relies on
#     one (nginx's master drops to its workers with setuid(), not exec).
#   - the non-root app images (each Dockerfile ends in USER node/bun and runs
#     its CMD directly): cap_drop [ALL] and no cap_add. A non-root process has
#     no effective capabilities anyway, so this only removes what a privilege
#     escalation could pick up (NET_RAW on the host's interfaces, with host
#     networking).
#   - memorial-api: read_only root filesystem plus a small /tmp tmpfs -- its
#     runtime code reads files only and its migrations run outside the
#     container.
# nginx, docker-api-filter and docker-socket-proxy start as root and keep
# their default capabilities: not verifiable without running those images.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE_UNDER_TEST:-$ROOT/docker-compose.yml}"

# shellcheck disable=SC2016  # Ruby source; #{...} is Ruby interpolation
COMPOSE="$COMPOSE" ruby -ryaml -e '
  doc = YAML.load(File.read(ENV.fetch("COMPOSE")))  # system ruby 2.6: aliases allowed by default
  services = doc.fetch("services")
  errors = []
  non_root_apps = %w[api securevault-api dayandyou-staging dayandyou-prod memorial-api memorial-worker zenvora-admin]
  read_only = { "memorial-api" => "/tmp" }

  errors << "parsed only #{services.size} services" if services.size < 10
  services.each do |name, svc|
    errors << "#{name}: security_opt must include no-new-privileges:true" unless Array(svc["security_opt"]).include?("no-new-privileges:true")
  end
  non_root_apps.each do |name|
    svc = services[name] or (errors << "#{name}: missing service"; next)
    errors << "#{name}: cap_drop must be [ALL]" unless svc["cap_drop"] == ["ALL"]
    errors << "#{name}: must not cap_add anything (runs as a non-root user)" if svc.key?("cap_add")
  end
  services.each do |name, svc|
    if read_only.key?(name)
      errors << "#{name}: read_only must be true" unless svc["read_only"] == true
      tmp = Array(svc["tmpfs"]).find { |t| t.split(":").first == read_only[name] }
      if tmp.nil?
        errors << "#{name}: needs a tmpfs at #{read_only[name]}"
      elsif tmp !~ /size=\d+[km]/
        errors << "#{name}: tmpfs #{tmp} must be size-capped (it counts against mem_limit)"
      end
    elsif svc.key?("read_only")
      errors << "#{name}: read_only is not verified for this service; add it to this test with its evidence first"
    end
  end
  if errors.empty?
    puts "PASS: containers confined where verified (#{services.size} services)"
  else
    errors.each { |e| warn "FAIL: #{e}" }
    exit 1
  end
'
