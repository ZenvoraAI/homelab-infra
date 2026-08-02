# homelab-infra

Docker Compose orchestration for the shared Lightsail box
(`ubuntu@ip-172-26-13-172`). This public repository contains only Compose,
nginx configuration, and deploy-support scripts. It never contains runtime env
files, certificates, database credentials, or GHCR tokens.

The checkout on the host is `/opt/homelab-infra`. Application source code and
release workflows remain in their own repositories.

## Services and routing

| Compose service | Container | Host port | Public hostnames |
| --- | --- | ---: | --- |
| `nginx` | `homelab-nginx` | 80 / 443 | all hosts below |
| `api` | `homelab-family-api` | 4000 | `api.family.valtou.com` |
| `securevault-api` | `homelab-securevault-api` | 3000 | `api.valtou.com` |
| `dayandyou-prod` | `homelab-dayandyou-prod` | 3003 | `dayandyou.com`, `www.dayandyou.com` |
| `dayandyou-staging` | `homelab-dayandyou-staging` | 3002 | `staging.dayandyou.com` |

Every service uses `network_mode: host`; the application ports must remain
firewalled from the public internet. Docker nginx is the only public reverse
proxy. All app services have explicit memory limits; limits are ceilings, not
reserved memory.

## Normal deployment model

Each product's GitHub Actions workflow builds and pushes its own GHCR image,
runs any required migration, then SSHes to this host to update exactly one named
service:

```bash
cd /opt/homelab-infra
git pull --ff-only
docker compose pull <service>
docker compose up -d <service>
```

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
curl -fsS http://127.0.0.1:3003/         # Day and You production
curl -fsS http://127.0.0.1:3002/         # Day and You staging
```

Use `docker compose config` before applying a Compose or nginx configuration
change. Check nginx syntax without replacing the running container:

```bash
docker compose run --rm --no-deps nginx nginx -t
```

## Secrets and state

- Family Media persists its API env only at
  `/opt/secrets/family-media/.env`; Compose mounts it read-only at `/app/.env`.
  It must be readable by the Compose user and mode `0600`.
- SecureVault and Day and You receive runtime variables from their deployment
  workflows; do not add their values to this repository.
- PostgreSQL runs natively on Lightsail and is backed up separately. It is not
  a Compose service.
- Certbot state lives under `/etc/letsencrypt`; ACME challenge files live at
  `/var/lib/homelab-acme` and are mounted read-only into Docker nginx.

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

1. Add the Compose service, image, memory limit, and any needed nginx server
   block in this repository. Do not put secrets in Compose.
2. Validate locally with `docker compose config` and nginx syntax validation.
3. Merge and pull this repository on the host.
4. Ensure the product repository's workflow builds/pushes its image and starts
   only its named service.
5. Add its hostname to the Certbot webroot procedure and verify a local ACME
   probe before requesting a certificate.
