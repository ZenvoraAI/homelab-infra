# Certbot Webroot Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Renew all Lightsail certificates through a host-managed Certbot webroot while Docker nginx serves the HTTP-01 challenge and reloads after a successful renewal.

**Architecture:** `/var/lib/homelab-acme` remains writable only to Certbot on the host and is bind-mounted read-only into nginx as `/var/www/certbot`. Each port-80 virtual host serves only `/.well-known/acme-challenge/` from that mount and redirects all other requests to HTTPS. A Certbot deploy hook invokes a versioned repository script that reloads the running nginx container.

**Tech Stack:** Docker Compose, nginx 1.27 Alpine, Certbot webroot authenticator, POSIX shell.

---

### Task 1: Add a configuration regression check

**Files:**
- Create: `tests/verify-certbot-webroot.sh`

- [x] **Step 1: Write the failing test**

Create a POSIX shell script that requires the Compose bind mount, the ACME challenge location in all three nginx config files, TLS 1.2/1.3-only policy, and the deploy-hook script. Make the script exit non-zero when any required string is absent.

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/verify-certbot-webroot.sh`

Expected: non-zero because no ACME webroot mount, challenge locations, or hook exist yet.

### Task 2: Make nginx serve HTTP-01 challenges

**Files:**
- Modify: `docker-compose.yml`
- Modify: `nginx/nginx.conf`
- Modify: `nginx/conf.d/family-api.conf`
- Modify: `nginx/conf.d/valtou-api.conf`
- Modify: `nginx/conf.d/dayandyou.conf`

- [x] **Step 1: Bind mount the host webroot read-only**

Add `/var/lib/homelab-acme:/var/www/certbot:ro` to the nginx service.

- [x] **Step 2: Rewrite every port-80 server**

For every certificate hostname, serve `^~ /.well-known/acme-challenge/` using `root /var/www/certbot; try_files $uri =404;`, and move the HTTPS redirect into a separate `location /` so the challenge is not intercepted by a server-level `return`.

- [x] **Step 3: Remove legacy TLS protocols**

Set `ssl_protocols TLSv1.2 TLSv1.3;`.

- [x] **Step 4: Run the regression test and Compose validation**

Run: `bash tests/verify-certbot-webroot.sh && docker compose config --quiet`

Expected: exit 0.

### Task 3: Provide the renewal hook and operational runbook

**Files:**
- Create: `scripts/reload-nginx-after-cert-renewal.sh`
- Modify: `README.md`

- [x] **Step 1: Add a safe, repository-owned reload script**

The script changes to `/opt/homelab-infra` and runs `/usr/bin/docker compose exec -T nginx nginx -s reload` with `set -eu`.

- [x] **Step 2: Document one-time migration and dry-run verification**

Document the exact host commands to create the root-owned webroot, install the deploy hook, reissue each existing certificate as a Certbot `certonly --webroot` lineage, run `certbot renew --dry-run`, and verify the hook via nginx container logs.

- [x] **Step 3: Run the regression test again**

Run: `bash tests/verify-certbot-webroot.sh && docker compose config --quiet`

Expected: exit 0.
