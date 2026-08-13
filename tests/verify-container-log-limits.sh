#!/usr/bin/env bash
set -euo pipefail

# Every service must bound its log. Docker's json-file driver is unbounded by
# default, and a full disk takes down every site at once because they all share
# one box. The disk already filled once, on 2026-08-12, from image accumulation;
# unbounded logs are the same failure by another route.
#
# Asserted per service rather than by grepping for the anchor, so a service
# added later without `logging:` fails this test instead of quietly growing.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ruby -ryaml -e '
  compose = YAML.load_file(ARGV[0])
  services = compose.fetch("services")
  abort "no services found in docker-compose.yml" if services.empty?

  missing = services.reject do |_name, cfg|
    log = cfg["logging"]
    log &&
      log["driver"] == "json-file" &&
      log.fetch("options", {})["max-size"] &&
      log.fetch("options", {})["max-file"]
  end

  unless missing.empty?
    warn "services without a bounded json-file log: #{missing.keys.join(", ")}"
    exit 1
  end

  puts "PASS: container log limits (#{services.length} services)"
' "$ROOT/docker-compose.yml"
