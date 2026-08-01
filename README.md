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
- `api` (family-media) — pilot service, `network_mode: host`, image from
  `ghcr.io/qclawchang/family-media-api`.

## Onboarding a new service

1. Add its service block to `docker-compose.yml` here, commit, push.
2. On the box: `cd /opt/homelab-infra && git pull`.
3. `docker compose pull <service> && docker compose up -d <service>`.

Ordinary deploys of an already-onboarded service only need step 3, run
from that product's own CI.
