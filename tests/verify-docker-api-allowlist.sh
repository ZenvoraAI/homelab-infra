#!/usr/bin/env bash
set -euo pipefail

# zenvora-admin is internet-facing (admin.valtou.com) and reads container state
# through docker-socket-proxy. That proxy's CONTAINERS=1 also serves inspect
# (every container's env, i.e. every secret on the host) and archive (any file
# in any container). zenvora-admin only ever calls GET /containers/json, so an
# nginx allow-list sits between the two and the raw proxy is moved onto an
# internal network only the filter shares.
#
# This pins the topology and the filter's allow-list. It is a static check:
# docker and nginx are not available on the workstation, and nothing here may
# touch the host. The runtime check to run on the host after deploying is in
# the README ("docker API allow-list").

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER_CONF="$ROOT/nginx/docker-api-filter/nginx.conf"

# shellcheck disable=SC2016  # Ruby source; #{...} is Ruby interpolation
ruby -ryaml -e '
  compose = YAML.load_file(ARGV[0])
  services = compose.fetch("services")
  networks = compose.fetch("networks", {})
  errors = []

  nets = ->(svc) { n = services.fetch(svc, {})["networks"]; n.is_a?(Hash) ? n : Array(n).to_h { |k| [k, nil] } }
  aliases = ->(svc, net) { (nets.(svc)[net] || {}).fetch("aliases", []) }
  mounts_socket = ->(cfg) { Array(cfg["volumes"]).any? { |v| v.to_s.include?("docker.sock") } }

  %w[docker-socket-proxy docker-api-filter zenvora-admin].each do |svc|
    errors << "service #{svc} is missing" unless services.key?(svc)
  end
  abort errors.join("\n") unless errors.empty?

  # Only the raw proxy holds the socket.
  holders = services.select { |_n, cfg| mounts_socket.(cfg) }.keys
  errors << "docker.sock must be mounted only by docker-socket-proxy, found: #{holders}" unless holders == ["docker-socket-proxy"]

  # The raw proxy: internal network only, reached via a distinct alias.
  errors << "docker-socket-net must be internal: true" unless networks.dig("docker-socket-net", "internal") == true
  errors << "docker-socket-proxy must be on docker-socket-net only, found #{nets.("docker-socket-proxy").keys}" unless nets.("docker-socket-proxy").keys == ["docker-socket-net"]
  errors << "docker-socket-proxy needs alias docker-socket-upstream on docker-socket-net" unless aliases.("docker-socket-proxy", "docker-socket-net").include?("docker-socket-upstream")
  errors << "docker-socket-proxy must not publish ports" if services["docker-socket-proxy"]["ports"]
  errors << "docker-socket-proxy must not use host networking" if services["docker-socket-proxy"]["network_mode"]

  # The filter: bridges the two networks, answers to the old name on zenvora side.
  f = services["docker-api-filter"]
  errors << "docker-api-filter must be on docker-proxy-net and docker-socket-net, found #{nets.("docker-api-filter").keys.sort}" unless nets.("docker-api-filter").keys.sort == %w[docker-proxy-net docker-socket-net]
  errors << "docker-api-filter needs alias docker-socket-proxy on docker-proxy-net" unless aliases.("docker-api-filter", "docker-proxy-net").include?("docker-socket-proxy")
  errors << "docker-api-filter must not carry the docker-socket-upstream alias" if nets.("docker-api-filter").values.compact.any? { |c| Array(c["aliases"]).include?("docker-socket-upstream") }
  errors << "docker-api-filter must mount its allow-list as /etc/nginx/nginx.conf:ro" unless Array(f["volumes"]).include?("./nginx/docker-api-filter/nginx.conf:/etc/nginx/nginx.conf:ro")
  errors << "docker-api-filter must not publish ports" if f["ports"]
  errors << "docker-api-filter must not use host networking" if f["network_mode"]
  errors << "docker-api-filter needs a mem_limit" unless f["mem_limit"]
  # The healthcheck goes through the filter to the raw proxy, so it fails when
  # the upstream is unreachable (nginx answers 502), and zenvora-admin waits
  # on it -- a broken filter makes `docker compose up` fail loudly instead of
  # deploying "healthy" while every docker call errors.
  hc = Array(f.dig("healthcheck", "test")).join(" ")
  errors << "docker-api-filter healthcheck must fetch http://127.0.0.1:2375/containers/json through the filter, found: #{hc.inspect}" unless hc.include?("wget") && hc.include?("http://127.0.0.1:2375/containers/json")

  # zenvora-admin reaches only the filter.
  errors << "zenvora-admin must be on docker-proxy-net only, found #{nets.("zenvora-admin").keys}" unless nets.("zenvora-admin").keys == ["docker-proxy-net"]
  dep = services["zenvora-admin"]["depends_on"]
  errors << "zenvora-admin must depend on docker-api-filter being healthy" unless dep.is_a?(Hash) && dep.dig("docker-api-filter", "condition") == "service_healthy"

  # Nothing else may share either private network.
  others = services.reject { |n, _| %w[docker-socket-proxy docker-api-filter zenvora-admin].include?(n) }
  others.each do |name, _|
    shared = nets.(name).keys & %w[docker-proxy-net docker-socket-net]
    errors << "#{name} must not join #{shared}" unless shared.empty?
  end

  abort errors.join("\n") unless errors.empty?
' "$ROOT/docker-compose.yml"

# The allow-list itself.
fail() { printf "FAIL: %b\n" "$*" >&2; exit 1; }
conf="$(sed 's/#.*//' "$FILTER_CONF")"
locations="$(grep -E '^[[:space:]]*location ' <<<"$conf" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*\{$//')"
[ "$locations" = "$(printf 'location = /containers/json\nlocation /')" ] \
  || fail "filter must have exactly 'location = /containers/json' and a catch-all, found:\n$locations"
# Fixed path AND fixed query: the client's query string is not forwarded, so
# e.g. ?size=true (makes Docker size every container's filesystem -- slow and
# I/O-heavy on this box) cannot be passed through.
# shellcheck disable=SC2016  # nginx variables, matched literally
grep -Fq 'proxy_pass http://$docker_socket_upstream/containers/json?all=true;' <<<"$conf" \
  || fail "proxy_pass must use a fixed upstream path and query (/containers/json?all=true)"
# shellcheck disable=SC2016  # nginx variable names, matched literally
if grep -Eq '\$(args|is_args|query_string|request_uri|arg_[a-z_]+)' <<<"$conf"; then
  fail "the filter must not forward any part of the client's URI or query string"
fi
[ "$(grep -c 'proxy_pass' <<<"$conf")" = 1 ] || fail "filter must have exactly one proxy_pass"
grep -Eq 'limit_except GET[[:space:]]*\{' <<<"$conf" || fail "filter must refuse non-GET methods"
grep -Eq 'return 403;' <<<"$conf" || fail "catch-all must return 403"
# shellcheck disable=SC2016  # nginx variable, matched literally
grep -Eq 'set \$docker_socket_upstream docker-socket-upstream:2375;' <<<"$conf" || fail "filter must target the docker-socket-upstream alias"
grep -Eq 'resolver 127\.0\.0\.11 ' <<<"$conf" || fail "filter must re-resolve the upstream via Docker DNS"

echo "PASS: docker API allow-list (topology + filter)"
