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
| `api` | `homelab-family-api` | none (HTTP on a unix socket, `family-api-sock` volume) | `family-api.valtou.com` | 640m |
| `securevault-api` | `homelab-securevault-api` | none (FastCGI on a unix socket, `securevault-fpm` volume) | `api.valtou.com` | 512m |
| `securevault-scheduler` | `homelab-securevault-scheduler` | — | none (no listener) | 256m |
| `dayandyou-api-staging` | `homelab-dayandyou-api-staging` | none (FastCGI on unix sockets, `dayandyou-api-fpm-staging` volume) | `api-origin-staging.dayandyou.com` (CloudFront origin only) | 320m |
| `dayandyou-api-scheduler-staging` | `homelab-dayandyou-api-scheduler-staging` | — | none (no listener) | 128m |
| `memorial-api-laravel` | `homelab-memorial-api-laravel` | none (FastCGI on unix sockets, `memorial-api-fpm` volume) | `api.aiqiuqi.com` | 256m |
| `memorial-api-laravel-scheduler` | `homelab-memorial-api-laravel-scheduler` | — | none (no listener) | 96m |
| `docker-socket-proxy` | `homelab-docker-socket-proxy` | none (internal network only) | none | 16m |
| `docker-api-filter` | `homelab-docker-api-filter` | none (private network only) | none | 16m |
| `zenvora-admin` | `homelab-zenvora-admin` | none (HTTP on a unix socket, `zenvora-admin-sock` volume) | `admin.valtou.com` | 128m |

Day and You's storefront (`dayandyou.com`, `www.dayandyou.com`,
`staging.dayandyou.com`) is a static site on S3 + CloudFront since 2026-11-14;
those names do not resolve to this host. Only its Laravel API runs here
(staging; a `dayandyou-api-prod` service for `api-origin.dayandyou.com` is to
come). The old Next.js containers `dayandyou-staging` / `dayandyou-prod` and
their `dayandyou.conf` vhosts were removed on 2026-11-15.

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
from all of them, not just its intended caller. `zenvora-admin` publishes
nothing either: nginx (host-network) reaches it over a unix socket in the
`zenvora-admin-sock` volume, as it reaches the family, memorial and SecureVault
APIs. `zenvora-admin`'s `DOCKER_PROXY_URL` stays
`http://docker-socket-proxy:2375`: on `docker-proxy-net` that name is now an
alias of `docker-api-filter`, not a
loopback address. The application ports must remain firewalled from the
public internet. Docker nginx is the only public reverse proxy.

Those limits sum to 2288 MiB on a host measured at 1.9 GiB, so the box is
deliberately oversubscribed by roughly 15%. A `mem_limit` is a ceiling, not a
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
every container together used about 660 MB, and the Express memorial-api sat at
171.9/192 MiB (it has since been retired; the Laravel pair measured 28 and
31 MiB against 256m and 96m limits on 2026-11-22). That supports no reduction,
so none is made here. Native
Postgres shares the same 1.9 GiB and has no ceiling at all, which is what an
oversubscribed OOM puts at risk.

| Service | Limit now | Known usage | Proposal |
| --- | ---: | --- | --- |
| api (family-media) | 640m | not measured | measure peak during an upload/video poster run; set ~1.5x peak |
| securevault-api | 512m | 302 MiB peak (Laravel/FPM load test, 6 workers) | keep; FPM's own ceiling (6 x 192M) is above it by design |
| securevault-scheduler | 256m | not measured | measure after the cutover |
| dayandyou-api-staging | 320m | not measured (main pool 2 + payments pool 1-2) | re-measure once the API's argon2 gate lands |
| dayandyou-api-scheduler-staging | 128m | 93 MiB peak, measured locally | keep |
| nginx / filter / proxy / zenvora-admin | 64m / 16m / 16m / 128m | small | keep |
| **Total** | **2288 MiB** (compose limits, 2026-11-19, after the memorial worker's 512 MiB left) | ~660 MB measured | target: total of measured peaks x 1.5, well under 1.9 GiB minus Postgres |

To gather the evidence (host, read-only, run over a normal week including a
deploy and a photo upload):

```bash
# every 5 minutes; keep the max per container
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' >> /var/log/homelab-mem.log
free -m; ps -o rss=,cmd= -C postgres | awk '{s+=$1} END {print s/1024 " MiB postgres"}'
```

Until then, an OOM-ordering safety net is worth considering (not applied):
`oom_score_adj: 500` on the staging API services, so the
kernel kills those before Postgres or a production API.

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

- **transition** (before rollout): `${VAR:-<fallback>}`. An unset variable falls back to
  exactly what that service ran before pinning: `:latest`/`:release`/`:staging`
  for the app images (moving, as before) and a digest-pinned
  `nginx:1.30.6-alpine` / `tecnativa/docker-socket-proxy:v0.5.0` for the
  third-party ones (nginx moved off the end-of-life 1.27 branch; see "nginx
  version" below). `image-pins.sh check` lists what is still falling back.
- **strict** (now): `${VAR:?…}`. With any variable unset, every
  `docker compose` command fails rather than pulling a moving tag.

Strict mode is on: every variable must be pinned in `.env` (check with
`scripts/image-pins.sh check`) before any `docker compose` command runs here.
It was introduced in transition mode first because Compose interpolates the
*whole* file for every command, so one unset required variable fails every
product's deploy, and zenvora-admin's deploy pulls homelab `main` unattended.
To add a service, pin its variable on the host before merging.

| Variable | Service(s) | Value |
| --- | --- | --- |
| `GHCR_OWNER` | GHCR services | namespace, default `zenvoraai` |
| `NGINX_IMAGE` | `nginx`, `docker-api-filter` | `nginx:<tag>@sha256:<digest>` |
| `DOCKER_SOCKET_PROXY_IMAGE` | `docker-socket-proxy` | `tecnativa/docker-socket-proxy:<tag>@sha256:<digest>` |
| `FAMILY_API_TAG` | `api` | tag of `family-media-api` |
| `SECUREVAULT_API_TAG` | `securevault-api`, `securevault-scheduler` | tag of `securevault-api-laravel` |
| `DAYANDYOU_API_STAGING_TAG` | `dayandyou-api-staging`, `dayandyou-api-scheduler-staging` | tag of `dayandyou-api` |
| `MEMORIAL_API_LARAVEL_TAG` | `memorial-api-laravel`, `memorial-api-laravel-scheduler` | tag of `memorial-api` |
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
  holds the good release) cannot step back past a good one. It changes state only. Then recreate the service (re-run that product's
  deploy, or `docker compose up -d --no-deps <service>`).
- A manual or recovery `docker compose pull`/`up` gets exactly the pinned
  digest.

`scripts/image-pins.sh check` lists every value. `scripts/image-pins.sh seed`
pins each unset variable to the digest its container runs now (one-off, at
rollout; it never overwrites).

### Rollout (done before strict mode was merged; kept for a rebuilt host)

Not every product workflow calls `promote`/`docker-prune.sh` yet. Until each
product's patch lands, its deploys keep working because of the transition
fallback and because their exported `*_TAG` beats `.env`. (The original step 1,
making the Next.js day-and-you deploys export their tag variables, went away
with those services on 2026-11-15.)

1. Merge this (transition mode) into homelab `main`. Nothing changes on the
   host until something runs compose; then the fallbacks give today's images,
   except that the third-party fallbacks are digests, so the next recreate of
   `docker-socket-proxy`/`docker-api-filter` (a zenvora deploy recreates them
   as dependencies) may pull a newer build of the same tag.
2. On the host: `scripts/image-pins.sh seed`, then `promote zenvora-admin
   <running sha>` by hand if seed refuses it (pre-transfer namespace), then
   `scripts/image-pins.sh check` until it exits 0.
3. Land the product patches (promote after health, `docker-prune.sh` instead
   of the 48h prune), one product at a time.
4. Strict mode was merged on 2026-11-15, once `check` passed on the host. On a
   rebuilt host, seed and `check` before the first deploy, or nothing will start.

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
docker compose exec -T api node dist/probe.js  # family API (unix socket; /health/ready)
docker compose exec -T securevault-api /usr/local/share/securevault/docker/fcgi-probe.sh /readyz  # SecureVault API (FastCGI only)
docker compose exec -T memorial-api-laravel fcgi-probe.sh /health/ready  # memorial API (FastCGI socket)
docker compose exec -T zenvora-admin bun src/probe.ts  # zenvora-admin (unix socket; /healthz)
docker compose exec -T dayandyou-api-staging fcgi-probe.sh /api/health  # Day and You API staging (FastCGI only)
```

After deploying the socket change, confirm no app still answers on TCP, from a
host-network container (each line must print `refused`):

```bash
ADMIN_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' homelab-zenvora-admin | awk '{print $1}')"
for target in 127.0.0.1:4000 127.0.0.1:3001 127.0.0.1:3100 "$ADMIN_IP:3100"; do
  docker run --rm --network host busybox:1.37 nc -z -w 2 "${target%:*}" "${target##*:}" && echo "OPEN $target" || echo "refused $target"
done
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
- The memorial API reads `/opt/secrets/aiqiuqi-memorial/api.env` through
  `env_file`. Do not hand-edit it — see `scripts/` below. (The media worker and
  its `worker.env` were retired on 2026-11-19 by aiqiuqi-memorial Part A; a
  leftover `worker.env` and `MEMORIAL_WORKER_TAG` line in `.env` are unused and
  may be deleted.)
- The Day and You storefront is static (S3 + CloudFront) and has no runtime
  or secrets on this host.
- SecureVault (`securevault-api` and its scheduler) reads everything from
  `/opt/secrets/securevault/api.env` through `env_file` (`required: false`),
  `ubuntu` `0600` in an `ubuntu` `0700` directory; written only by
  `scripts/refresh-securevault-secrets.sh` from SSM `/securevault/prod/*`
  (see "SecureVault env file"). Do not hand-edit it.
- The Day and You API (`dayandyou-api-staging` and its scheduler) reads
  everything from `/opt/secrets/dayandyou-api/staging.env` through `env_file`
  (`required: false`, so a missing file breaks only those two services, never
  `docker compose config` for the others). `ubuntu` `0600` in an `ubuntu`
  `0700` directory; written only by `scripts/refresh-dayandyou-api-secrets.sh`
  from SSM `/dayandyou-api/<env>/*`. Do not hand-edit it.
- The Day and You CloudFront origin secret lives in
  `/opt/secrets/dayandyou/origin-secret-staging.map` (see "Day and You API
  origin"), mounted read-only into nginx only.
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
| `refresh-dayandyou-api-secrets.sh <staging\|prod>` | Writes the Day and You Laravel API's whole env file, `/opt/secrets/dayandyou-api/<env>.env`, from SSM `/dayandyou-api/<env>/*` (profile `dayandyou-api-ssm`). Refuses a missing required key, an unknown extra one, a prod `SITE_PASSWORD`, a partial `FRONTEND_REBUILD_*` set, or a value of the wrong shape (test vs live Stripe key, `APP_KEY`, URLs, minimum lengths, line breaks or single quotes). Values are written `KEY='value'`, which Compose's `env_file` takes literally. Run by the API deploy on every staging deploy (`sudo -n`), creates the file on first run. |
| `refresh-memorial-aws-credentials.sh` | Pulls the memorial API's AWS credentials from SSM Parameter Store into its env file (the media worker was retired). |
| `refresh-securevault-secrets.sh` | Writes SecureVault's whole env file, `/opt/secrets/securevault/api.env`, from SSM `/securevault/prod/*` (profile `securevault-ssm`), deriving `ALLOWED_EXTENSION_ORIGINS` from `EXTENSION_IDS`. Refuses a missing required key, an unknown extra one, a partial `GOOGLE_*` set, `PHOTO_S3_*` without `OBJECT_STORE`, or a value of the wrong shape (secret lengths, WebAuthn RP ID and origins, URLs, SMTP port, extension ids, line breaks or single quotes). Written `KEY='value'`. Run by SecureVault's deploy on every backend deploy (`sudo -n`); creates the file on first run. |
| `refresh-memorial-secrets.sh` | Pulls the CloudFront media signing key pair and the family-media handoff settings from SSM into the memorial API env file, and writes the constant `MEMORIAL_HANDOFF_TENANT=aiqiuqi`. |
| `refresh-memorial-laravel-secrets.sh` | Writes the Laravel memorial API's `APP_KEY` (SSM `/aiqiuqi-memorial/preview/APP_KEY`) into the same api.env; refuses anything but `base64:` + 32 bytes. Run only by the Laravel deploy, so the Express deploys never depend on that parameter. |
| `memorial-deploy-gate.sh` | The forced command of the memorial-api deploy key, installed as `/usr/local/sbin/memorial-deploy-gate` (see "Memorial API on Laravel"). Allows only `deploy-memorial-api-laravel <release sha> <homelab sha>`, and only when the homelab sha is origin/main's tip; fast-forwards to it and hands over to the next script. |
| `deploy-memorial-api-laravel.sh` | The Laravel memorial deploy on the host: secrets, env-file shape, pull, preflight, pre-migration dump, migration, swap of both services, readiness of both FPM pools, pin, prune. Rolls an unready release back to the previous one. |
| `refresh-zenvora-admin-secrets.sh` | Pulls zenvora-admin's 14 secrets from SSM into its env file: GitHub App credentials, SES SMTP credentials, token-encryption key, whitelisted user ID, plus three tokens for external read-only APIs (a fine-grained GitHub alert-check PAT covering all ZenvoraAI-owned tracked repos, a classic PAT for GHCR package listing since neither GitHub Apps nor fine-grained PATs expose an org-level Packages permission, and a Cloudflare API token scoped to the three onboarded zones for the traffic/security-events panel). Same pattern as the memorial scripts, for the same reason. |
| `reload-nginx-after-cert-renewal.sh` | Certbot deploy hook; reloads the `nginx` container after a renewal. |

The refresh scripts exist because hand-copying a secret through a
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
bash tests/verify-memorial-laravel-secret-refresh.sh  # only a 32-byte APP_KEY is written, nothing echoed
bash tests/verify-memorial-api-laravel.sh    # Laravel memorial FPM only over its socket volume; client IP only from $remote_addr
bash tests/verify-memorial-laravel-deploy.sh  # nothing swapped before preflight+dump+migrate; unready release rolled back, never pinned
bash tests/verify-memorial-deploy-gate.sh    # the deploy key runs one command, from the approved homelab main tip only
bash tests/verify-zenvora-admin-secret-refresh.sh  # rotation accepts short non-secrets, still refuses short secrets
bash tests/verify-dayandyou-api-secret-refresh.sh  # exact KEY='value' file, every shape rule refuses, no value echoed
bash tests/verify-securevault-secret-refresh.sh  # same for SecureVault, plus derived extension origins
bash tests/verify-secret-backup-rotation.sh  # a rotation leaves exactly one .bak copy
bash tests/verify-nginx-server-tokens.sh    # nginx does not advertise its version
bash tests/verify-docker-api-allowlist.sh   # zenvora-admin reaches only GET /containers/json
bash tests/verify-cloudflare-real-ip.sh      # the Cloudflare real-IP config exists and is well-formed
bash tests/verify-admin-hardening.sh        # admin.valtou.com carries rate limits + security headers
bash tests/verify-image-pinning.sh           # every image is digest-pinned or a required env ref
bash tests/verify-image-pins-script.sh       # pin/rollback/prune behaviour, stubbed docker
bash tests/verify-nginx-image-branch.sh      # nginx fallback is a digest-pinned, supported stable branch
bash tests/verify-nginx-default-server.sh    # unknown Host/SNI: 444 / handshake rejected, never the admin vhost
bash tests/verify-container-hardening.sh     # no-new-privileges / cap_drop / read_only where verified
bash tests/verify-securevault-api-env.sh     # API + scheduler read only securevault/api.env, no forwarded names
bash tests/verify-securevault-fpm-socket.sh  # FastCGI only over unix sockets; only the API and nginx mount them
bash tests/verify-dayandyou-api-origin.sh    # api-origin-staging: secret/viewer gate, viewer-keyed throttles, include
bash tests/verify-dayandyou-api-env.sh       # API services read only staging.env (required: false), no forwarded names
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

## Day and You API origin

The Day and You storefront is a static site on S3 + CloudFront; CloudFront
sends `/api/*` to `api-origin-staging.dayandyou.com` (Cloudflare proxied), which
`nginx/conf.d/dayandyou-api-origin.conf` serves from `dayandyou-api-staging`'s
PHP-FPM sockets. Browsers never use that name. Staging only for now. The
Next.js storefront's `dayandyou.conf` vhosts, once the rollback path, were
removed on 2026-11-15 together with its containers.
Runbook: private `aws-infrastructure` repo, `docs/dayandyou-static-frontend.md`.

**Trust chain.** The firewall admits only Cloudflare, and
`00-cloudflare-realip.conf` turns `$remote_addr` into the CloudFront edge that
called -- shared by many customers, so useless as a client key. CloudFront adds
a secret header, `X-Dayandyou-Origin-Secret`; only a request carrying it is
believed about `CloudFront-Viewer-Address` (set by CloudFront, not the viewer).
The 443 block returns 403 at server level, before any location, when either is
missing, so such a request never reaches PHP. PHP gets the viewer only as
`DAY_CLIENT_IP` (`nginx/dayandyou/fastcgi-dayandyou-api-cloudfront.conf`), never
the secret, the raw viewer header or a forwarding header, and every throttle
there (`dayandyou_cf_*`, `00-dayandyou-cloudfront.conf`) is keyed on the viewer.
`tests/verify-dayandyou-api-origin.sh` pins all of it.

**The secret file.** `/opt/secrets/dayandyou/origin-secret-staging.map`, root
`0600` in a root `0700` directory mounted read-only into nginx only, one line:
`"<48 hex chars>" 1;` (`openssl rand -hex 24`; hex only -- a key starting with
`~` would be a regex). nginx includes it at http level, so **a missing file
stops nginx from starting**; a prod map is added with the prod vhost, not
before. A 48-character key needs `map_hash_bucket_size 128` (nginx.conf). The
same value goes into the distribution's origin custom header (aws-infrastructure).
To rotate: add the new value as a second line, `docker compose exec -T nginx
nginx -s reload`, switch CloudFront's header and wait for its deploy, then delete
the old line and reload again.

**Certificate first.** nginx refuses a config naming a missing certificate, so
this went in two commits: the port-80 ACME vhost alone, then the 443 block and
everything above. Apply in that order, each validated before it goes live:

```bash
cd /opt/homelab-infra
# 1. Port-80 vhost (conf.d only: a reload is enough). Needs the proxied A record.
git pull --ff-only                                   # the ACME-only commit
docker compose run --rm --no-deps nginx nginx -t
docker compose exec -T nginx nginx -s reload
echo ok | sudo tee /var/lib/homelab-acme/.well-known/acme-challenge/probe >/dev/null
curl -s -H 'Host: api-origin-staging.dayandyou.com' http://127.0.0.1/.well-known/acme-challenge/probe   # ok
sudo rm /var/lib/homelab-acme/.well-known/acme-challenge/probe
sudo certbot certonly --webroot -w /var/lib/homelab-acme -d api-origin-staging.dayandyou.com
# 2. This change: new nginx mounts and a changed nginx.conf, so recreate, not reload.
#    Pull and recreate in one sitting: until then a restart of the old container
#    would fail on the new conf.d (secret dir not mounted), taking every site down.
sudo test -s /opt/secrets/dayandyou/origin-secret-staging.map && echo secret present
git pull --ff-only
docker compose run --rm --no-deps nginx nginx -t     # fresh container: the new mounts and files
docker compose up -d --no-deps --force-recreate nginx   # brief outage for every site
curl -s -o /dev/null -w '%{http_code}\n' https://api-origin-staging.dayandyou.com/api/health   # 403
```

Until the API's first deploy, a request with the secret and a viewer address
gets `503 {"error":"Service unavailable"}` (no FPM socket yet).

**The API's env file (one-time setup, before its first deploy).** The API's
settings and secrets live in SSM as SecureStrings under
`/dayandyou-api/staging/<KEY>`; the deploy runs
`sudo -n /opt/homelab-infra/scripts/refresh-dayandyou-api-secrets.sh staging`
before it starts any container, and on any refusal it stops with the old file
untouched. The key list and rules are in the script header.

1. In aws-infrastructure: IAM user `dayandyou-api-ssm`, read-only on
   `/dayandyou-api/*` (`ssm:GetParameter`, `ssm:GetParametersByPath`, plus
   `kms:Decrypt` if the parameters use a customer-managed key).
2. On the host, its access key as root's profile (the script runs under sudo
   and defaults `AWS_PROFILE` to it):

   ```bash
   sudo aws configure --profile dayandyou-api-ssm   # region ap-southeast-2, output text
   ```

3. Put every parameter in SSM, then write the file once by hand to see it pass:

   ```bash
   cd /opt/homelab-infra && git pull --ff-only
   sudo scripts/refresh-dayandyou-api-secrets.sh staging   # as ubuntu: the new file is ubuntu 0600
   sudo ls -l /opt/secrets/dayandyou-api/                   # staging.env, never cat it
   docker compose config -q && echo compose ok
   ```

To change a value: update SSM, then redeploy the API (or rerun step 3 and
`docker compose up -d --no-deps --force-recreate dayandyou-api-staging
dayandyou-api-scheduler-staging`). The one previous file is kept as
`staging.env.bak-<timestamp>`.

## SecureVault env file

SecureVault's settings and secrets live in SSM as SecureStrings under
`/securevault/prod/<KEY>`; SecureVault's backend deploy runs
`sudo -n /opt/homelab-infra/scripts/refresh-securevault-secrets.sh` right
after its `git pull`, and on any refusal stops before the image pull, the
preflight, the backup and the migration, with the old file untouched. The key
list and rules are in the script header. No app secret passes through GitHub
Actions.

One-time setup, done **before the host pulls the homelab-infra change that
switches these services to `env_file:`**: compose treats the file as optional,
so any `compose up` of them (another product's deploy included) without it
starts the API with no config, and it refuses to boot.

The sudo rule lets the deploy user run a script in a checkout it owns, so it
is root-equivalent for that user; so is its membership of the `docker` group,
which it already needs to run compose. Same trust boundary as the other
refresh scripts here.

1. In aws-infrastructure: IAM user `securevault-ssm`, read-only on
   `/securevault/prod/*` (`ssm:GetParameter`, `ssm:GetParametersByPath`,
   plus `kms:Decrypt` for the SecureStrings' key). Nothing else.
2. On the host, its access key as root's profile (the script runs under sudo
   and defaults `AWS_PROFILE` to it; never the deploy key's profile):

   ```bash
   sudo aws configure --profile securevault-ssm   # region ap-southeast-2, output text
   ```

3. Let the deploy user run exactly this script, nothing else:

   ```bash
   echo 'ubuntu ALL=(root) NOPASSWD: /opt/homelab-infra/scripts/refresh-securevault-secrets.sh' \
     | sudo tee /etc/sudoers.d/securevault-secrets >/dev/null
   sudo chmod 440 /etc/sudoers.d/securevault-secrets && sudo visudo -c
   ```

4. Put every parameter in SSM, then write the file once by hand to see it pass:

   ```bash
   cd /opt/homelab-infra && git pull --ff-only
   sudo -n scripts/refresh-securevault-secrets.sh   # as ubuntu: the new file is ubuntu 0600
   sudo ls -l /opt/secrets/securevault/              # api.env, never cat it
   docker compose config -q && echo compose ok
   ```

To change a value: update SSM, then redeploy the backend (or rerun step 4 and
`docker compose up -d --no-deps --force-recreate securevault-api
securevault-scheduler`). The one previous file is kept as
`api.env.bak-<timestamp>`. Never change `WEBAUTHN_RP_ID` or `JWT_SECRET` by
accident: the first kills every registered passkey, the second signs every
user out.

## Memorial API on Laravel

`memorial-api-laravel` (PHP-FPM) and `memorial-api-laravel-scheduler` run the
memorial API ported to Laravel (ZenvoraAI/memorial-api), and nginx serves
`api.aiqiuqi.com` from them over FastCGI. The Express API that ran here
before was switched over on 2026-11-22 and retired the same day; the plan and
the order of every step is memorial-api
`docs/laravel-migration/phase-4-plan.md`.

**Deploys** come only from memorial-api's `deploy.yml`, through a deploy key
that can do one thing. CI holds no database URL and opens no tunnel; the
pre-migration dump (`sudo -u postgres pg_dump`) and `php artisan migrate` run
here, in `scripts/deploy-memorial-api-laravel.sh`.

The key's `authorized_keys` line for `ubuntu` (the user installs it; the
public key is the one whose private half is memorial-api's
`MEMORIAL_DEPLOY_SSH_KEY` secret):

```
restrict,command="/usr/local/sbin/memorial-deploy-gate" ssh-ed25519 AAAA… memorial-api-deploy
```

and the gate itself, from a reviewed commit of this repository:

```bash
sudo install -o root -g root -m 0755 scripts/memorial-deploy-gate.sh /usr/local/sbin/memorial-deploy-gate
```

`restrict` turns off port forwarding, the pty and agent/X11 forwarding; the
gate refuses every command but `deploy-memorial-api-laravel <release sha>
<homelab sha>`, and runs it only when `<homelab sha>` is the tip of this
repository's `main` (the commit named in the deploy run's `homelab_sha` input,
which a dispatcher typed), after a fast-forward to it. Re-install the gate whenever
`scripts/memorial-deploy-gate.sh` changes; the copy in the checkout is never
run.

GitHub settings this relies on (the user sets them): memorial-api's
`production` environment holds the three deploy secrets and allows only `main`;
this repository's `main` is protected (pull requests only, no force push).
Required reviewers are not among them: GitHub refuses that rule on a private
repository on the Free plan, so the deploy's approval is the manual dispatch of
the two SHAs, not a second person.

**First deploy.** `MEMORIAL_API_LARAVEL_TAG` must be pinned before the commit
that adds these services reaches `main` (strict pins: an unset variable stops
every compose command, for every product). From a temporary worktree of the
reviewed branch commit, with the first release `<S>` already built:

```bash
cd /opt/homelab-infra
docker pull ghcr.io/zenvoraai/memorial-api:<S>
git fetch origin <branch> && git worktree add --detach /tmp/homelab-pin <branch sha>
IMAGE_PINS_ENV_FILE=/opt/homelab-infra/.env IMAGE_PINS_STATE_DIR=/opt/homelab-infra/.image-pins \
  /tmp/homelab-pin/scripts/image-pins.sh promote memorial-api-laravel <S>
git worktree remove /tmp/homelab-pin
```

Then merge, then dispatch the deploy with `<S>` and the new `main` sha. A first
deploy that fails readiness stops both services (no previous release to return
to); nginx does not depend on them yet.

**Detached run.** The gate starts the deploy in its own session with its output
in `~ubuntu/memorial-deploy-logs/` (newest 20 kept) and streams that log back.
A runner that times out or drops its connection ends only the stream; the
deploy still finishes or rolls back. Read the log on the host when that happens.

**Limits of the gate (review 2026-11-20; decisions for the user):**

- The Express deploy's key (aiqiuqi-memorial `DEPLOY_SSH_KEY`) opens a full
  shell as `ubuntu`, who has passwordless sudo. Retiring Express removes it
  (2026-11-22); until that key is deleted from the repository's secrets, a
  stolen one is still the host.
- The Express deploy ran `git pull --ff-only` in this checkout without the
  gate's lock, so it could move the checkout after the gate had checked it.
  Retiring it removes that race.
- The host trusts the `production` environment to have verified the release
  (on main, CI green); the key holder can name any published image. Keep that
  environment limited to `main`, its secrets in it only, and remember that no
  second person reviews the dispatch on this plan.
- From the seed until the first deploy passes, `.env` names a release that has
  not passed readiness. Nothing starts it unless someone runs an unscoped
  `docker compose up -d` (never do that here, see "Normal deployment model").

**nginx** mounts `memorial-api-fpm` and `nginx/memorial/` read-only. A running
nginx sees neither until it is recreated (`docker compose up -d --no-deps
nginx`, a second of downtime for every site). It was recreated on 2026-11-22,
when nginx was switched to the Laravel API,
not before the first deploy.

## Container hardening

Applied only where the product's Dockerfile and runtime code (origin/main,
2026-10-31) show it is safe; `tests/verify-container-hardening.sh` pins it.

| Service | no-new-privileges | cap_drop ALL | read_only | Evidence / why not |
| --- | --- | --- | --- | --- |
| api (family-media) | yes | yes | no | `USER node`, CMD `node`. Writes local storage (`lib/storage/local.ts`) and `os.tmpdir()` (video posters); which paths are live in prod is in the host env file, not verifiable here |
| securevault-api, securevault-scheduler | yes | yes | no | `USER www-data`. Not verified on a read-only root: the deploy runs artisan one-offs (preflight, migrate) in this service's config, and Laravel writes `storage/` and `bootstrap/cache` |
| dayandyou-api-staging, dayandyou-api-scheduler-staging | yes | yes | no | `USER www-data` (day-and-you-api Dockerfile), as securevault-api. Laravel writes `storage/` and `bootstrap/cache`; a read-only root with tmpfs is not verified yet |
| memorial-api | yes | yes | **yes**, `/tmp` tmpfs 16m | `USER node`; `apps/api/src` only reads files; migrations run outside the container; Prisma 7 has no engine binary |
| zenvora-admin | yes | yes | no | `USER bun`; writes only `/app/data` (volume), but Bun's runtime cache behaviour on a read-only root was not verified |
| nginx, docker-api-filter, docker-socket-proxy | yes | no | no | start as root (worker user switch, socket access); capability needs not verifiable without running the images |

A non-root process has no effective capabilities, so `cap_drop: [ALL]` changes
nothing for the app itself; it removes what a privilege escalation could pick up
(NET_RAW on the host interfaces, with host networking). Applies on each
service's next recreate. Next steps, each needing a host test: `read_only` for
zenvora-admin and securevault-api (with tmpfs for Laravel's `storage/` and `bootstrap/cache`), and
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

The `dayandyou.com` (with `www`) and `staging.dayandyou.com` certificates
served only the Next.js vhosts removed on 2026-11-15. Those names now resolve
to CloudFront, so their HTTP-01 renewals can no longer reach this webroot and
fail. Once nginx runs without `dayandyou.conf`, delete those lineages
(`sudo certbot certificates` to confirm the names, then
`sudo certbot delete --cert-name <name>`). `api-origin-staging.dayandyou.com`
is a separate lineage and stays.

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
