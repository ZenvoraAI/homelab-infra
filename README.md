# homelab-infra

Docker Compose orchestration for the services running on the shared
Lightsail box (`ubuntu@ip-172-26-13-172`). This repo holds only compose
files, nginx config, and deploy-support scripts — application code stays
in each product's own repo.

Checked out on the box at `/opt/homelab-infra`.

See `family-media`'s `docs/superpowers/specs/2026-08-01-homelab-infra-docker-design.md`
for the full design and rollout plan.

## Services

- `nginx` — reverse proxy for all domains on the box, `network_mode: host`.
- `api` (family-media), `securevault-api`, `dayandyou-staging`, and
  `dayandyou-prod` — application containers on the host network.

All application services use explicit memory limits. `api` uses the image
  `ghcr.io/qclawchang/family-media-api`.

## Onboarding a new service

1. Add its service block to `docker-compose.yml` here, commit, push.
2. On the box: `cd /opt/homelab-infra && git pull`.
3. `docker compose pull <service> && docker compose up -d <service>`.

Ordinary deploys of an already-onboarded service only need step 3, run
from that product's own CI.

## Certificate renewal (Certbot webroot)

The host owns Certbot and `/var/lib/homelab-acme`; Docker nginx has a
read-only mount and serves only HTTP-01 challenges from that path. Do not use
`certbot --nginx`: the host nginx service is intentionally stopped.

One-time migration on the Lightsail host:

```bash
sudo install -d -o root -g root -m 0755 /var/lib/homelab-acme
cd /opt/homelab-infra
git pull --ff-only
docker compose run --rm --no-deps nginx nginx -t
docker compose up -d nginx
sudo install -D -o root -g root -m 0755 \
  scripts/reload-nginx-after-cert-renewal.sh \
  /etc/letsencrypt/renewal-hooks/deploy/10-reload-homelab-nginx
```

Reissue each existing lineage once with the webroot authenticator. Confirm the
certificate names first with `sudo certbot certificates`; then run the matching
commands below (replace a name only when `certbot certificates` shows a
different `Certificate Name`):

```bash
sudo certbot certonly --webroot -w /var/lib/homelab-acme --cert-name api.family.valtou.com \
  -d api.family.valtou.com --force-renewal
sudo certbot certonly --webroot -w /var/lib/homelab-acme --cert-name api.valtou.com \
  -d api.valtou.com --force-renewal
sudo certbot certonly --webroot -w /var/lib/homelab-acme --cert-name dayandyou.com \
  -d dayandyou.com -d www.dayandyou.com --force-renewal
sudo certbot certonly --webroot -w /var/lib/homelab-acme --cert-name staging.dayandyou.com \
  -d staging.dayandyou.com --force-renewal
sudo certbot renew --dry-run
```

`--force-renewal` is only for this one-time authenticator migration; do not
repeat it in normal maintenance. A successful dry run must report every
certificate as simulated renewal success. Confirm nginx received the deploy
hook reload with `docker compose logs --since 10m nginx`.
