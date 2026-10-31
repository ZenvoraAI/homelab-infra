# homelab-infra

Docker Compose orchestration for the shared Lightsail box. This public repository contains only Compose,
nginx configuration, and deploy-support scripts. It never contains runtime env
files, certificates, database credentials, or GHCR tokens.

The checkout on the host is `/opt/homelab-infra`. Application source code and
release workflows remain in their own repositories.

## Services and routing

| Compose service | Container | Host port | Public hostnames | `mem_limit` |
| --- | --- | ---: | --- | ---: |
| `nginx` | `homelab-nginx` | 80 / 443 | all hosts below | 64m |
| `api` | `homelab-family-api` | 4000 | `family-api.valtou.com` | 640m |
| `securevault-api` | `homelab-securevault-api` | 3000 | `api.valtou.com` | 256m |
| `dayandyou-prod` | `homelab-dayandyou-prod` | 3003 | `dayandyou.com`, `www.dayandyou.com` | 400m |
| `dayandyou-staging` | `homelab-dayandyou-staging` | 3002 | `staging.dayandyou.com` | 350m |
| `memorial-api` | `homelab-memorial-api` | 3001 | `api.aiqiuqi.com` | 192m |
| `memorial-worker` | `homelab-memorial-worker` | — | none (no listener) | 512m |
| `docker-socket-proxy` | `homelab-docker-socket-proxy` | none (internal network only) | none | 16m |
| `docker-api-filter` | `homelab-docker-api-filter` | none (private network only) | none | 16m |
| `zenvora-admin` | `homelab-zenvora-admin` | 3100 (loopback) | `admin.valtou.com` | 128m |

Every service uses `network_mode: host` except `docker-socket-proxy`,
`docker-api-filter` and `zenvora-admin`, which sit on two private bridge
networks instead:

- `docker-socket-net` (`internal: true`) holds only `docker-socket-proxy` and
  `docker-api-filter`. The proxy's `CONTAINERS=1` cannot be narrowed further
  and also serves inspect (every container's env vars, i.e. every secret on the
  host) and archive (any file in any container), so zenvora-admin no longer
  shares a network with it. This does not stop the host-network services from
  reaching the proxy's container IP directly; see "docker API allow-list".
- `docker-proxy-net` holds `docker-api-filter` and `zenvora-admin`. The filter
  forwards only `GET /containers/json` (the one call zenvora-admin makes) and
  returns 403 for everything else; see "docker API allow-list" below.

Neither is published to the host: every other service here being on
`network_mode: host` means a port merely bound to `127.0.0.1` is reachable
from all of them, not just its intended caller. `zenvora-admin` still
publishes `127.0.0.1:3100` so nginx (host-network) can reach it exactly as
before. `zenvora-admin`'s `DOCKER_PROXY_URL` stays
`http://docker-socket-proxy:2375`: on `docker-proxy-net` that name is now an
alias of `docker-api-filter`, not a
loopback address. The application ports must remain firewalled from the
public internet. Docker nginx is the only public reverse proxy.
`memorial-worker` is the one service with no port and no vhost — it processes
media out of band.

Those limits sum to 2574 MiB on a host measured at 1.9 GiB, so the box is
deliberately oversubscribed by roughly 32%. A `mem_limit` is a ceiling, not a
reservation, and no service sits near its own ceiling — but the arithmetic means
several services peaking together is an OOM, not a slowdown. Check
`docker stats --no-stream` before raising any limit, and treat the total as the
budget being spent rather than headroom being claimed.

**Public ports (Lightsail firewall, instance `Ubuntu-1`).** 22 is open as
before. 80 and 443 accept only Cloudflare's published ranges
(https://www.cloudflare.com/ips-v4, https://www.cloudflare.com/ips-v6), so the
origin cannot be reached around Cloudflare's WAF and rate limits. Every public
hostname is proxied (orange cloud); the last DNS-only one,
`api.family.valtou.com`, was retired on 2026-11-01. Certbot's HTTP-01
challenge still works because Let's Encrypt reaches the webroot through
Cloudflare. A new hostname must be proxied before it can work, and the ranges
should be re-checked now and then (Cloudflare announces changes in advance):

```bash
v4=$(curl -fsS https://www.cloudflare.com/ips-v4 | jq -Rsc 'split("\n")|map(select(length>0))')
v6=$(curl -fsS https://www.cloudflare.com/ips-v6 | jq -Rsc 'split("\n")|map(select(length>0))')
aws lightsail put-instance-public-ports --instance-name Ubuntu-1 --port-infos \
  "[{\"fromPort\":22,\"toPort\":22,\"protocol\":\"tcp\",\"cidrs\":[\"0.0.0.0/0\"],\"ipv6Cidrs\":[\"::/0\"]},
    {\"fromPort\":80,\"toPort\":80,\"protocol\":\"tcp\",\"cidrs\":$v4,\"ipv6Cidrs\":$v6},
    {\"fromPort\":443,\"toPort\":443,\"protocol\":\"tcp\",\"cidrs\":$v4,\"ipv6Cidrs\":$v6}]"
```

### Memory budget (proposal, 2026-10-31; no limit changed)

The only measurement on record is 2026-08-16 (`docs/superpowers/specs/2026-08-16-zenvora-admin-design.md`):
every container together used about 660 MB, and memorial-api sat at
171.9/192 MiB. That supports no reduction, so none is made here. Native
Postgres shares the same 1.9 GiB and has no ceiling at all, which is what an
oversubscribed OOM puts at risk.

| Service | Limit now | Known usage | Proposal |
| --- | ---: | --- | --- |
| api (family-media) | 640m | not measured | measure peak during an upload/video poster run; set ~1.5x peak |
| securevault-api | 256m | not measured | branch `fix/securevault-api-memory` raises it to 384m (argon2, 2 x 64 MiB) |
| dayandyou-prod | 400m | not measured | measure; Next.js `next start` baseline is typically 150-250 MB |
| dayandyou-staging | 350m | not measured | first candidate for a cut (staging traffic); measure, then ~1.5x peak |
| memorial-api | 192m | 171.9 MiB (89.5%) | keep or raise slightly; it is the one near its ceiling |
| memorial-worker | 512m | not measured (raised for 50 MP photos, d864df6) | keep |
| nginx / filter / proxy / zenvora-admin | 64m / 16m / 16m / 128m | small | keep |
| **Total** | **2574 MiB** (2702 with the securevault branch) | ~660 MB measured | target: total of measured peaks x 1.5, well under 1.9 GiB minus Postgres |

To gather the evidence (host, read-only, run over a normal week including a
deploy and a photo upload):

```bash
# every 5 minutes; keep the max per container
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' >> /var/log/homelab-mem.log
free -m; ps -o rss=,cmd= -C postgres | awk '{s+=$1} END {print s/1024 " MiB postgres"}'
```

Until then, an OOM-ordering safety net is worth considering (not applied):
`oom_score_adj: 500` on dayandyou-staging and memorial-worker, so the kernel
kills those before Postgres or a production API.

## Images and tags

Images come from GHCR under the `zenvoraai` namespace. The application
repositories moved from the `qclawchang` personal account to the `ZenvoraAI`
organization on 2026-08-15, and **GHCR packages do not follow a repository
transfer** — the old `ghcr.io/qclawchang/*` packages still exist but nothing
pushes to them any more, so pinning to one would pull a frozen image for ever
with no error to notice.

The organization is spelled `ZenvoraAI`, but every image reference here says
`zenvoraai`: a Docker image reference must be lower case or the client rejects
it outright with `repository name must be lowercase`, before the request ever
reaches the registry.

Every service image is named through a pin variable, in one of two modes
(`PINS_COMPOSE_MODE` in `scripts/lib/image-pins-lib.sh`;
`tests/verify-image-pinning.sh` holds the compose file to it):

- **transition** (now): `${VAR:-<fallback>}`. An unset variable falls back to
  exactly what that service ran before pinning: `:latest`/`:release`/`:staging`
  for the app images (moving, as before) and a digest-pinned
  `nginx:1.30.6-alpine` / `tecnativa/docker-socket-proxy:0.3` for the
  third-party ones (nginx moved off the end-of-life 1.27 branch; see "nginx
  version" below). `image-pins.sh check` lists what is still falling back.
- **strict** (after rollout): `${VAR:?…}`. With any variable unset, every
  `docker compose` command fails rather than pulling a moving tag.

Why not strict straight away: Compose interpolates the *whole* file for every
command, so one unset required variable fails every product's deploy (even
`docker compose pull <other-service>`), and zenvora-admin's deploy pulls
homelab `main` and runs compose unattended on every zenvora push. Strict mode
is a one-line flip plus the compose lines, kept on its own branch
(`fix/image-pinning-strict-2026-10-31`) to merge only after the rollout below.

| Variable | Service(s) | Value |
| --- | --- | --- |
| `GHCR_OWNER` | GHCR services | namespace, default `zenvoraai` |
| `NGINX_IMAGE` | `nginx`, `docker-api-filter` | `nginx:<tag>@sha256:<digest>` |
| `DOCKER_SOCKET_PROXY_IMAGE` | `docker-socket-proxy` | `tecnativa/docker-socket-proxy:<tag>@sha256:<digest>` |
| `FAMILY_API_TAG` | `api` | tag of `family-media-api` |
| `SECUREVAULT_API_TAG` | `securevault-api` | tag of `securevault-api` |
| `DAYANDYOU_STAGING_TAG` | `dayandyou-staging` | tag of `dayandyou` |
| `DAYANDYOU_PROD_TAG` | `dayandyou-prod` | tag of `dayandyou` |
| `MEMORIAL_API_TAG` | `memorial-api` | tag of `aiqiuqi-memorial-api` |
| `MEMORIAL_WORKER_TAG` | `memorial-worker` | tag of `aiqiuqi-memorial-worker` |
| `ZENVORA_ADMIN_TAG` | `zenvora-admin` | tag of `zenvora-admin` |

A `*_TAG` value is a 40-hex commit SHA, optionally followed by
`@sha256:<digest>`, or any tag *with* a digest (`release@sha256:…`). A
third-party `*_IMAGE` value must carry a digest. `scripts/image-pins.sh`
refuses anything else.

Where the values live: the gitignored project `.env` in `/opt/homelab-infra`,
which Compose reads on its own, plus one known-good history file per variable
under `.image-pins/`. Only `scripts/image-pins.sh` writes either. A deploy
exports the value it just built; the shell beats `.env`. **Only after the
health check passes** does it run `image-pins.sh promote <service> <sha>`,
which pins the pulled image's digest into `.env` and appends it to the history.
So `.env` always names the last known-good release:

- A failed deploy rolls back by exporting `$(scripts/image-pins.sh get
  <service>)` (or unsetting its variable) and running `up` again. It never
  retags `:release` locally, which would last only until the next pull.
- A release that went bad after it passed: `scripts/image-pins.sh rollback
  <service> <bad sha>` re-pins the previous known-good value and drops the bad
  one from the history. It refuses unless `.env` currently pins `<bad sha>`, so
  running it after a deploy that failed *before* promote (when `.env` still
  holds the good release) cannot step back past a good one. It changes state only. Then recreate the service with its
  environment. dayandyou and securevault get their secrets from their deploy
  shell, so re-run that product's deploy, or `up` from a shell that has them.
- A manual or recovery `docker compose pull`/`up` gets exactly the pinned
  digest.

`scripts/image-pins.sh check` lists every value. `scripts/image-pins.sh seed`
pins each unset variable to the digest its container runs now (one-off, at
rollout; it never overwrites).

### Rollout (in this order)

The product workflows do **not** call `promote`/`docker-prune.sh` yet, and
day-and-you exports only `IMAGE_TAG`, which compose does not read for
`dayandyou-*`. Until each product's patch lands, its deploys keep working
because of the transition fallback (and, for the others, because their
exported `*_TAG` beats `.env`).

1. day-and-you first: export `DAYANDYOU_PROD_TAG="$IMAGE_TAG"` in
   deploy-prod.yml and `DAYANDYOU_STAGING_TAG="$IMAGE_TAG"` in
   staging-deploy.yml (inert against the old compose). **Do not seed before
   this lands**: a seeded `DAYANDYOU_*_TAG` with nobody exporting it pins
   dayandyou to the seeded release for ever, while its deploy runs migrations
   and reports success.
2. Merge this (transition mode) into homelab `main`. Nothing changes on the
   host until something runs compose; then the fallbacks give today's images,
   except that the third-party fallbacks are digests, so the next recreate of
   `docker-socket-proxy`/`docker-api-filter` (a zenvora deploy recreates them
   as dependencies) may pull a newer build of the same tag.
3. On the host: `scripts/image-pins.sh seed`, then `promote zenvora-admin
   <running sha>` by hand if seed refuses it (pre-transfer namespace), then
   `scripts/image-pins.sh check` until it exits 0.
4. Land the product patches (promote after health, `docker-prune.sh` instead
   of the 48h prune, dayandyou rollback via `get`), one product at a time.
5. Only then merge the strict branch.

### nginx version

The fallback is `nginx:1.30.6-alpine@sha256:0e52bd05…` (1.30 is the current
stable branch; 1.27 and 1.28 no longer get fixes).
`tests/verify-nginx-image-branch.sh` refuses a mainline or end-of-life
branch. Config checked with nginx 1.30.6 built from nginx.org source: `nginx -t`
passes for `nginx/nginx.conf` + `conf.d` and for the docker-api-filter config.

On a host where `seed` already pinned `NGINX_IMAGE` (the running 1.27), the
fallback is not used; move it explicitly. **Recreating `nginx` restarts the
only public listener: every site drops for a few seconds**, so pick a quiet
moment and keep the old ref to hand:

```bash
cd /opt/homelab-infra
NEW='nginx:1.30.6-alpine@sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949'
docker pull "$NEW"
docker run --rm -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$PWD/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v /etc/letsencrypt:/etc/letsencrypt:ro "$NEW" nginx -t
docker run --rm -v "$PWD/nginx/docker-api-filter/nginx.conf:/etc/nginx/nginx.conf:ro" "$NEW" nginx -t
OLD="$(scripts/image-pins.sh get nginx)"; echo "rollback target: $OLD"
scripts/image-pins.sh promote nginx "$NEW"
docker compose up -d --no-deps nginx docker-api-filter
curl -sI https://admin.valtou.com/healthz | head -1     # and each public site
# if anything is wrong: scripts/image-pins.sh rollback nginx "$NEW" && docker compose up -d --no-deps nginx docker-api-filter
```

## Normal deployment model

Each product's GitHub Actions workflow builds and pushes its own GHCR image,
runs any required migration, then SSHes to this host to update exactly one named
service:

```bash
cd /opt/homelab-infra
git pull --ff-only
export FAMILY_API_TAG=<the sha this run built>   # or the service's own tag var
docker compose pull <service>
docker compose up -d <service>
# after the health check passes:
scripts/image-pins.sh promote <service> "$FAMILY_API_TAG"
scripts/docker-prune.sh || true    # best-effort, see scripts/ below
```

Pass the tag the run just built. Do not promote before the health check: a
failed release must never become the value `.env` falls back to.

For an existing service, never run an unqualified `docker compose up -d` during
a product deploy. It risks restarting unrelated sites. The application workflow
is responsible for migrations; this repository is responsible for runtime
orchestration only.

## Day-to-day operations

```bash
cd /opt/homelab-infra
docker compose ps
docker compose logs --tail=100 <service>
docker compose restart <service>
docker stats --no-stream
```

Health checks on the host:

```bash
curl -fsS http://127.0.0.1:4000/health  # family API
curl -fsS http://127.0.0.1:3000/health  # SecureVault API
curl -fsS http://127.0.0.1:3001/health  # memorial API
curl -fsS http://127.0.0.1:3003/         # Day and You production
curl -fsS http://127.0.0.1:3002/         # Day and You staging
```

`memorial-worker` has no listener, so there is nothing to curl. Check it through
Compose instead:

```bash
docker compose ps memorial-worker
docker compose logs --tail=50 memorial-worker
```

Use `docker compose config` before applying a Compose or nginx configuration
change. Check nginx syntax without replacing the running container:

```bash
docker compose run --rm --no-deps nginx nginx -t
```

`run` matters here, not `exec`. It creates a fresh container, so the bind mounts
resolve to the files currently on disk; `exec` reuses the running container's
mounts, which can be stale — see below.

### Changing `nginx/nginx.conf` needs a recreate, not a reload

`nginx/conf.d` is a **directory** mount, so edits inside it are visible to the
running container and `nginx -s reload` picks them up.

`nginx/nginx.conf` is a **single-file** mount, and `git pull` replaces files
rather than editing them in place. The container keeps pointing at the old
inode, so no amount of reloading will ever load a new `nginx.conf`:

```bash
docker compose up -d --force-recreate nginx   # brief outage for every site
```

This bites in a confusing way: `conf.d` (directory mount, fresh) can reference
a zone that `nginx.conf` (single-file mount, stale) hasn't defined yet, so
`nginx -t` fails with a shared-memory-zone error even though the file on disk
is correct — the mount is what's stale. `docker compose run` validates
against the current files and will catch this before `exec` would. (Full
incident writeup: private `aws-infrastructure` repo,
`docs/homelab-infra-incidents.md`.)

The running nginx keeps its loaded config until a reload succeeds, so an invalid
file on disk breaks nothing. Validate, then recreate.

## Secrets and state

- Family Media persists its API env only at
  `/opt/secrets/family-media/.env`; Compose mounts it read-only at `/app/.env`.
  It must be readable by the Compose user and mode `0600`.
- The memorial services read `/opt/secrets/aiqiuqi-memorial/api.env` and
  `/opt/secrets/aiqiuqi-memorial/worker.env` through `env_file`. Do not
  hand-edit either one — see `scripts/` below.
- SecureVault and Day and You receive runtime variables from their deployment
  workflows; do not add their values to this repository.
- PostgreSQL runs natively on Lightsail. Its backup, archival, and restore
  tooling lives in the private `aws-infrastructure` repository, not here, and
  it is not a Compose service.
- Certbot state lives under `/etc/letsencrypt`; ACME challenge files live at
  `/var/lib/homelab-acme` and are mounted read-only into Docker nginx.

## `scripts/` — host tooling

| Script | What it does |
| --- | --- |
| `docker-prune.sh` | Keeps, per service, the image `.env` pins plus the newest `IMAGE_KEEP_GOOD` (default 3) known-good releases from `.image-pins/`. Removes every other image of the repositories it manages, plus dangling layers. That is the rollback window. It removes nothing while any service is unpinned or any current pin does not resolve to a local image, runs under the pins lock, never touches other repositories, exits non-zero if a repository cannot be listed, and `DRY_RUN=1` previews. Meant to replace each product's age-based `docker image prune -af --filter until=48h`, which deletes other products' previous releases; no product calls it yet (Rollout step 4). |
| `image-pins.sh` | `seed`, `check`, `get`, `promote`, `rollback <svc> <bad sha>`: the only writer of the pinned image values (see Images and tags). A lock left by a killed run is cleared automatically. |
| `refresh-memorial-aws-credentials.sh` | Pulls the memorial API and worker AWS credentials from SSM Parameter Store into their env files. |
| `refresh-memorial-secrets.sh` | Pulls the CloudFront media signing key pair from SSM into the memorial API env file. |
| `refresh-zenvora-admin-secrets.sh` | Pulls zenvora-admin's 14 secrets from SSM into its env file: GitHub App credentials, SES SMTP credentials, token-encryption key, whitelisted user ID, plus three tokens for external read-only APIs (a fine-grained GitHub alert-check PAT covering all ZenvoraAI-owned tracked repos, a classic PAT for GHCR package listing since neither GitHub Apps nor fine-grained PATs expose an org-level Packages permission, and a Cloudflare API token scoped to the three onboarded zones for the traffic/security-events panel). Same pattern as the memorial scripts, for the same reason. |
| `reload-nginx-after-cert-renewal.sh` | Certbot deploy hook; reloads the `nginx` container after a renewal. |

The two refresh scripts exist because hand-copying a secret through a
terminal is a failure mode that can sit silently broken for a long time
before anything notices — see the private `aws-infrastructure` repo,
`docs/homelab-infra-incidents.md`, for what that cost once. The scripts
remove the hand.

Fetching from SSM only moves *where* a value is typed. The validation is the
actual guard: each script refuses to write a value that is not shaped like the
credential it claims to be, and it validates **both** files before writing
either. A per-file check as it goes would leave the API holding a fresh key and
the worker holding a placeholder — harder to notice than either file being
plainly wrong.

Both run under `sudo` while Compose does not, so they restore the original
owner after rewriting; a root-owned env file would lock Compose out of a file it
could read a moment earlier.

## `tests/`

These run on a workstation or on the host and assert properties of this
repository, not of a live deployment:

```bash
bash tests/verify-container-log-limits.sh    # every service bounds its log
bash tests/verify-email-rate-limits.sh       # nginx limits + TRUST_PROXY reaches the container
bash tests/verify-certbot-webroot.sh         # the webroot renewal path is intact
bash tests/verify-memorial-credential-refresh.sh  # the refresh script refuses a bad value
bash tests/verify-zenvora-admin-secret-refresh.sh  # rotation accepts short non-secrets, still refuses short secrets
bash tests/verify-secret-backup-rotation.sh  # a rotation leaves exactly one .bak copy
bash tests/verify-nginx-server-tokens.sh    # nginx does not advertise its version
bash tests/verify-docker-api-allowlist.sh   # zenvora-admin reaches only GET /containers/json
bash tests/verify-cloudflare-real-ip.sh      # the Cloudflare real-IP config exists and is well-formed
bash tests/verify-admin-dayandyou-hardening.sh  # admin.valtou.com and dayandyou.com carry rate limits + security headers
bash tests/verify-image-pinning.sh           # every image is digest-pinned or a required env ref
bash tests/verify-image-pins-script.sh       # pin/rollback/prune behaviour, stubbed docker
bash tests/verify-nginx-image-branch.sh      # nginx fallback is a digest-pinned, supported stable branch
bash tests/verify-nginx-default-server.sh    # unknown Host/SNI: 444 / handshake rejected, never the admin vhost
bash tests/verify-container-hardening.sh     # no-new-privileges / cap_drop / read_only where verified
bash tests/verify-securevault-api-env.sh     # securevault-api receives the extension sign-in vars
```

`verify-container-log-limits.sh` asserts per service rather than grepping for
the `x-logging` anchor, so a service added later without a `logging:` key fails
the test instead of quietly growing an unbounded log.

## docker API allow-list

`docker-api-filter` (nginx, config in `nginx/docker-api-filter/nginx.conf`)
sits between `zenvora-admin` and `docker-socket-proxy`. It forwards
`GET /containers/json` to a fixed upstream request,
`/containers/json?all=true` (the client's query string is dropped, so e.g.
`?size=true` cannot make Docker size every container's filesystem), and
returns 403 for every other path or method. If zenvora-admin ever needs another
Docker endpoint, add that exact path to the filter -- never widen it to a
prefix, and never put `zenvora-admin` back on `docker-socket-net`.

`zenvora-admin` waits for the filter's healthcheck (a request through the
filter to the raw proxy), so a broken filter or unreachable proxy fails
`docker compose up` instead of deploying: zenvora-admin's own `/healthz` does
not cover Docker access and would call a broken filter healthy.

**The first zenvora-admin deploy after this lands applies the change
unattended.** Its CI deploy runs `git pull` + `docker compose up -d
zenvora-admin`, which creates `docker-api-filter` and recreates
`docker-socket-proxy` on its new network. Do not leave that to the next
zenvora push: right after merging, run the rollout and probes below by hand.

```bash
cd /opt/homelab-infra && git pull --ff-only
# 1. Syntax-check the filter config before anything is recreated.
docker run --rm -v "$PWD/nginx/docker-api-filter/nginx.conf:/etc/nginx/nginx.conf:ro" \
  "$(docker compose config --images docker-api-filter)" nginx -t
# 2. Recreate all three together, so no old container keeps the
#    docker-socket-proxy name on docker-proxy-net.
docker compose up -d --force-recreate docker-socket-proxy docker-api-filter zenvora-admin
docker inspect -f '{{.State.Health.Status}}' homelab-docker-api-filter   # expect: healthy
# 3. From zenvora-admin (oven/bun slim has no curl/wget, so probe with bun).
#    Expect 200 for the first path, 403 for every other one.
for path in '/containers/json?all=true' /containers/homelab-nginx/json \
            '/containers/homelab-nginx/archive?path=/etc/hostname' \
            '/containers/x/..%2F..%2Fcontainers/homelab-nginx/json' /info; do
  docker exec -e P="$path" homelab-zenvora-admin \
    bun -e 'const r = await fetch("http://docker-socket-proxy:2375" + process.env.P); console.log(r.status, process.env.P)'
done
# 4. From the host itself -- i.e. what any network_mode: host container can do.
#    Bypasses the filter and talks to the raw proxy's container IP.
PROXY_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' homelab-docker-socket-proxy | awk '{print $1}')
curl -s -o /dev/null -m 5 -w '%{http_code}\n' "http://$PROXY_IP:2375/containers/homelab-nginx/json"
#    Anything other than 200 (000 = unreachable) means the host path is closed.
# 5. The admin panel's Deployment Drift section should still list containers.
```

If step 4 prints `200`, the host-network services can bypass the filter (this
was already true before the filter, when the proxy sat on docker-proxy-net).
Candidate mitigations, none applied because none can be verified off-host:

- **Take the raw proxy off TCP.** Drop tecnativa and have the filter talk to the
  Docker socket itself (`proxy_pass http://unix:/var/run/docker.sock:`), with
  the socket mounted only into the filter. Needs the nginx workers to be able
  to open the socket (root:docker 0660), e.g. `user nginx docker;` with the
  host's docker GID -- the allow-list then becomes the only guard, so it needs
  the same probes.
- **Host firewall.** An iptables rule in `DOCKER-USER` does not see host ->
  container traffic; it needs an `OUTPUT` rule, e.g.
  `iptables -I OUTPUT -d <docker-socket-net subnet> -p tcp --dport 2375 -j REJECT`
  (pin the subnet in compose with `ipam` so the rule stays valid), persisted
  with the host's firewall tooling. Container-to-container traffic from the
  filter goes through the bridge, not OUTPUT, so it is unaffected -- verify
  with steps 3 and 4.

The list response still carries each container's name, image, state, labels,
mounts and command line -- not env or files. Nothing here passes secrets on a
command line.

## Container hardening

Applied only where the product's Dockerfile and runtime code (origin/main,
2026-10-31) show it is safe; `tests/verify-container-hardening.sh` pins it.

| Service | no-new-privileges | cap_drop ALL | read_only | Evidence / why not |
| --- | --- | --- | --- | --- |
| api (family-media) | yes | yes | no | `USER node`, CMD `node`. Writes local storage (`lib/storage/local.ts`) and `os.tmpdir()` (video posters); which paths are live in prod is in the host env file, not verifiable here |
| securevault-api | yes | yes | no | `USER node`. The deploy runs `npm run db:sync` in this service's config, and npm writes `~/.npm` |
| dayandyou-staging/prod | yes | yes | no | `USER node`, `next start` writes `.next` at runtime (image cache, ISR) |
| memorial-api | yes | yes | **yes**, `/tmp` tmpfs 16m | `USER node`; `apps/api/src` only reads files; migrations run outside the container; Prisma 7 has no engine binary |
| memorial-worker | yes | yes | no | `USER node`; ffmpeg/HEIF processing of 50 MP photos needs scratch space too large for a RAM tmpfs |
| zenvora-admin | yes | yes | no | `USER bun`; writes only `/app/data` (volume), but Bun's runtime cache behaviour on a read-only root was not verified |
| nginx, docker-api-filter, docker-socket-proxy | yes | no | no | start as root (worker user switch, socket access); capability needs not verifiable without running the images |

A non-root process has no effective capabilities, so `cap_drop: [ALL]` changes
nothing for the app itself; it removes what a privilege escalation could pick up
(NET_RAW on the host interfaces, with host networking). Applies on each
service's next recreate. Next steps, each needing a host test: `read_only` for
zenvora-admin and securevault-api (with a `/home/node` tmpfs for npm), and
`cap_drop: [ALL]` + `cap_add: [CHOWN, SETUID, SETGID, NET_BIND_SERVICE]` for
nginx (`docker compose up -d --no-deps nginx` and probe every site).

## Container logs are bounded in two places

Docker's `json-file` driver has no size limit by default, and a full disk takes
down every site at once because they all share one box. `scripts/docker-prune.sh`
handles the image-accumulation half of that; unbounded logs are the same
failure by another route.

| Where | Covers | Takes effect |
| --- | --- | --- |
| `x-logging` anchor in `docker-compose.yml` | every service here | when a container is next recreated, which every deploy does |
| `/etc/docker/daemon.json` on the host | anything started outside Compose | when the Docker daemon next restarts |

Both say `max-size: 10m`, `max-file: 3` — 30 MB per container, ~210 MB in total
against a 58 GB disk. An explicit setting in Compose wins over the daemon
default, and they agree anyway.

Neither was applied by restarting the Docker daemon. A daemon restart bounces
every container, and log settings are baked in at container creation, so a
restart would have caused an outage *and* still left the existing containers
unbounded until each was recreated. Letting each service pick the limit up on
its next deploy costs nothing.

Validate a `daemon.json` edit before it can break anything — a malformed file
stops Docker from starting at all:

```bash
sudo dockerd --validate --config-file=/etc/docker/daemon.json
```

Check what a running container actually got:

```bash
docker inspect <container> --format '{{.HostConfig.LogConfig}}'
```

## Certificate renewal (Certbot webroot)

The Certbot webroot migration completed on 2026-08-02. Docker nginx serves
HTTP-01 challenges from `/var/lib/homelab-acme` and the Certbot deploy hook
reloads the `nginx` container after renewal.

Normal verification:

```bash
sudo certbot renew --dry-run
cd /opt/homelab-infra
docker compose logs --since 10m nginx
```

Do not use `certbot --nginx`: the host nginx service is intentionally stopped.
Do not repeat the migration's `certbot certonly --force-renewal` commands during
normal maintenance.

## Onboarding a new service

1. Add the Compose service, an image ref in the current pin mode
   (`${NEW_TAG:?…}` in strict, `${NEW_TAG:-<fallback>}` in transition) plus its
   row in `pins_table` (scripts/lib/image-pins-lib.sh), `mem_limit`, `logging: *default-logging`,
   and any needed nginx server block in this repository. Do not put secrets in
   Compose. Subtract the new limit from the memory budget above before choosing
   it — the host is already oversubscribed.
2. Validate locally with `docker compose config`, nginx syntax validation, and
   `bash tests/verify-container-log-limits.sh`, which fails on a service added
   without a `logging:` key.
3. Merge and pull this repository on the host.
4. Ensure the product repository's workflow builds/pushes its image under
   `ghcr.io/zenvoraai/`, passes the built SHA as the service's tag variable,
   runs `scripts/image-pins.sh promote` after its health check, then
   `scripts/image-pins.sh promote`/`seed` once on the host before anything else
   pulls this repository (an unset variable stops every compose command), and
   starts only its named service.
5. Add its hostname to the Certbot webroot procedure and verify a local ACME
   probe before requesting a certificate.
