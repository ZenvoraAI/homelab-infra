# Family-media API cutover to Laravel — runbook

A maintenance window that moves `https://family.valtou.com/api/*` from the Express API to the
Laravel API (ZenvoraAI/family-media-api) and retires Express. Nobody uses the app right now, but
the **database users and the photos are real and must survive**: every step below that touches
data has a check before and after, and nothing destructive runs until those checks are read.
Every host, AWS, Cloudflare and CloudFront action is a person at a shell or console; nothing here
runs on its own.

```
browser ── https://family.valtou.com/api/* ──▶ CloudFront (web distribution, /api/* behaviour, no cache)
        ──▶ Cloudflare (family-api.valtou.com, proxied) ──▶ nginx (conf.d/family-api.conf)
        ──fastcgi──▶ family-api-laravel (PHP-FPM) ──▶ Postgres on the host, database family_media
```

Commits on homelab-infra, merged in this order, each at its step and no earlier: Step A
(service, deploy, gate), the cron docs, the dump fix, Step B (vhost switch), the Express
retirement, this runbook.

Sources: family-media-api 9b023ec (`CLAUDE.md`, `deploy/host/*`, `docs/phase-7-report.md`, code);
family-media `infra/cloudfront/API-BEHAVIOR.md` (a7f421da), `infra/crontab.txt` (37d0bd90),
`docs/superpowers/plans/laravel-migration/` (security-design 1.1–1.3 and 10, deploy-, env-,
jobs-inventory); private aws-infrastructure `docs/lightsail-postgresql-s3-backup.md` (instance
backup). SQL marked *(code reading)* is from family-media-api 9b023ec, per that session's code
reading (not executed).

## Never

- **Never run a seed** in production: `family:seed-e2e`, `family:seed-quality`. They wipe and refill
  a database. The code refuses `APP_ENV=production`, any non-local host and any database name
  outside `family_media_(test|e2e|ci|quality)[_x]` (`ThrowawayDatabase::assert`); keep it that way:
  never set `APP_ENV` in `api-laravel.env` (the image sets `production`), never give the production
  database a throwaway-shaped name.
- **Never restore the whole-instance backup** to roll the family back: the 02:30 backup covers
  every database on the instance (memorial, SecureVault, Day and You, …); replaying it would
  rewind them all. Family restores touch `family_media` only.
- **Never reload nginx without `nginx -t` first.** It is shared: a bad config takes down
  `api.aiqiuqi.com` (memorial), `api.valtou.com` (SecureVault), the Day and You origin and the
  admin panel together. Validate with `docker compose run --rm --no-deps nginx nginx -t` (fresh
  container, current files) before every reload or recreate, and run the memorial check after.

## 0. Preconditions (days before the window)

1. **CloudFront error responses gone first.** The web distribution's 403/404 custom error
   responses would turn every API 403/404 into the SPA's `index.html` with 200. Order (family-media
   `WEB-PATH-REWRITE.md` / `API-BEHAVIOR.md`): publish `family-web-path-rewrite` → set
   CustomErrorResponses to 0 → only then, at step 7, add `/api/*`.
2. **Release image** `ghcr.io/zenvoraai/family-media-api-laravel:<S>`, `<S>` a full 40-hex
   family-media-api commit at or after `9b023ec`, built only by that repo's manual `release.yml`
   (GitHub `ubuntu-latest`, so linux/amd64, smoke-tested before push) — the same path as
   `memorial-api`, which runs on this host. Never push an image built on a workstation (an
   Apple-silicon build is arm64). On the host: `docker image inspect <image> --format
   '{{.Architecture}}'` → `amd64`.
3. **This branch reviewed**; nothing merged yet.
4. **Prisma migration state** of production *(code reading)* — read-only:

   ```bash
   sudo -u postgres psql -d family_media -Atc "SELECT migration_name FROM \"_prisma_migrations\" WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL ORDER BY 1;" | tee /tmp/prisma-migrations.txt | wc -l   # 74
   tail -1 /tmp/prisma-migrations.txt                                                     # 20261124090000_refresh_token_live_chain_index
   grep -c 20261123120000_drop_removed_feature_tables /tmp/prisma-migrations.txt          # 1
   ```

   Laravel's baseline migrations only record themselves on a Prisma-migrated database and refuse
   any other list (nothing is changed then; the deploy stops after its dump). **If
   `20261123120000_drop_removed_feature_tables` is not applied, STOP and ask the CEO**: applying it
   drops the Story/Moment/Agent/GeneralChat/MediaAiTag/AiFeatureUsage/SmartSearchQueryCache tables,
   whose contents must be exported first if any hold data. The only new DDL in 9b023ec is additive
   (`login_attempts`, `rate_limit_buckets`, Laravel's `migrations`); review the migrations of any
   later `<S>` (`git diff 9b023ec <S> -- '*Migrations*'`) and accept only additive ones.
5. **Capacity.** The host has 2 GB. Compose `mem_limit`s sum to 2448 MiB today (Express `api` 640m
   included) and to 2320 MiB after this change (Express retired, `family-api-laravel` 512m), with
   Postgres outside any limit. Baseline now and keep the output:

   ```bash
   free -m; swapon --show                          # swap must exist; if none, add a swap file before the window
   docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'
   sudo dmesg -T | grep -ci 'out of memory\|oom-kill'   # baseline count
   ```

   Consider `docker compose stop dayandyou-api-staging dayandyou-api-scheduler-staging` for the
   window (448m of limits, staging only); start them again at the end.

## 1. Host files (no traffic change)

```bash
# 1a. Laravel's env file: ubuntu 0600 (Express's .env stays untouched).
sudo install -o ubuntu -g ubuntu -m 0600 /dev/null /opt/secrets/family-media/api-laravel.env
sudoedit /opt/secrets/family-media/api-laravel.env      # never cat it
```

| Key | Value |
| --- | --- |
| `NODE_ENV` | `production` |
| `APP_KEY` | new, `base64:` + 32 bytes |
| `JWT_SECRET` | **new** random, ≥ 32 chars (sessions reset once) |
| `DATABASE_URL` | the Express value: `postgresql://<role>:…@127.0.0.1:5432/family_media` |
| `RECOVERY_CODE_PEPPER`, `TOTP_ENC_KEY`, `MEDIA_KEY_ROTATION_SECRET` | **the Express values** (recovery codes, TOTP secrets and media keys depend on them) |
| `WEB_ORIGIN`, `API_PUBLIC_URL` | `https://family.valtou.com` |
| `COOKIE_DOMAIN` | absent (host-only cookies, `Path=/api` and `/api/auth`) |
| `STORAGE_DRIVER` | `s3` |
| `AWS_REGION`, `MEDIA_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `CLOUDFRONT_MEDIA_DOMAIN`, `CLOUDFRONT_MEDIA_DISTRIBUTION_ID`, `CLOUDFRONT_KEY_PAIR_ID`, `CLOUDFRONT_PRIVATE_KEY` | the Express values (PEMs on one line, literal `\n`) |
| `OFFSITE_BACKUP_URI` *or* `OFFSITE_BACKUP_DISABLED=true` | exactly one |
| `FM_HANDOFF_KEY_ID`, `FM_HANDOFF_PRIVATE_KEY_PEM` | written by the deploy from SSM |

Leave out `APP_ENV`, `PORT`, `LISTEN_SOCKET`, `CLIENT_IP_HEADER`, `E2E_DISABLE_RATE_LIMIT`,
`VIDEO_UPLOAD_ENABLED=true`, and any `replace-with…` placeholder (all refused or unused).

```bash
# 1b. The CloudFront origin secret (hex only, 48 chars); kept for step 7, never committed or logged.
sudo install -d -o root -g root -m 0700 /opt/secrets/family-media-origin
secret="$(openssl rand -hex 24)"
printf '"%s" 1;\n' "$secret" | sudo tee /opt/secrets/family-media-origin/origin-secret.map >/dev/null
sudo chmod 0600 /opt/secrets/family-media-origin/origin-secret.map
```

Rollback: delete both files.

## 2. Pin, gate, merge Step A (no traffic change)

Pin `<S>` before Step A reaches `main` (README "Memorial API on Laravel", First deploy, with
`family-api-laravel` / `family-media-api-laravel:<S>`), install `/usr/local/sbin/family-deploy-gate`
and the deploy key's `authorized_keys` line (README "Family API on Laravel"). Merge Step A, the
two cron/dump commits, then on the host:

```bash
cd /opt/homelab-infra && git pull --ff-only
docker compose config -q && echo compose ok
docker compose run --rm --no-deps nginx nginx -t
docker compose up -d --no-deps --force-recreate nginx     # new mounts: ~1 s outage for every site
docker compose exec -T memorial-api-laravel fcgi-probe.sh /health/ready && echo memorial ok
```

Rollback: revert the merged commits, pull, `nginx -t`, recreate nginx.

## 3. Maintenance window: data baseline (Express stopped)

```bash
cd /opt/homelab-infra && docker compose stop api          # nothing writes family_media from here
```

**3a. A verified dump of `family_media` only**, taken now (consistent, nothing writing), off the box:

```bash
d=/opt/backups/family-media-premigrate; sudo install -d -o root -g root -m 0700 $d
f=$d/family_media-window-$(date -u +%Y%m%dT%H%M%SZ).dump
sudo install -o root -g root -m 0600 /dev/null $f
sudo -u postgres pg_dump --format=custom --no-owner --no-privileges family_media | sudo tee $f >/dev/null
sudo pg_restore --list $f | wc -l                         # many entries, no error
sudo ls -l $f                                             # size in line with the 02:30 backup of family_media
# Off the box (from a workstation): scp ubuntu@<host>:<copy> ./ via a 0600 copy in ~ubuntu, then
# delete that copy; or aws s3 cp to the private backup bucket under a separate prefix.
```

The deploy (step 4) takes its own `family_media` dump again right before migrating; the daily
02:30 instance backup can be 24 h old and is no substitute for either.

**3b. Row and object counts** (keep the output; compare at 4, 6 and 9):

```bash
for t in User Family FamilyMember Media Album Person FaceEmbedding UploadIntent AuditEvent RefreshToken; do
  printf '%s ' "$t"; sudo -u postgres psql -d family_media -Atc "SELECT count(*) FROM \"$t\";"
done
```

From a workstation with the owner's AWS credentials (bucket name from `api-laravel.env`):

```bash
aws s3api get-bucket-versioning --bucket "$MEDIA_BUCKET"      # Enabled; if not, confirm the offsite copy exists before step 9
aws s3 ls "s3://$MEDIA_BUCKET/"                               # top-level prefixes
for p in <each prefix>; do echo "$p $(aws s3 ls "s3://$MEDIA_BUCKET/$p" --recursive --summarize | tail -2 | tr '\n' ' ')"; done
```

**3c. Rehearsal (recommended)** in a throwaway database, never on `family_media`:

```bash
role=<the DATABASE_URL user>
sudo -u postgres createdb -O "$role" family_media_test_cutover
sudo -u postgres pg_restore --no-owner --role="$role" -d family_media_test_cutover $f
export FAMILY_API_LARAVEL_TAG=<S>
# The production URL with only the database name swapped, never typed or echoed:
rehearse() { docker compose run --rm --no-deps -T -e DATABASE_URL="$(sed -n 's#^DATABASE_URL=\(.*\)/family_media\([?].*\)\{0,1\}$#\1/family_media_test_cutover\2#p' /opt/secrets/family-media/api-laravel.env)" --entrypoint php family-api-laravel artisan "$@"; }
rehearse migrate --pretend          # read the SQL: only CREATEs (the baseline files only record themselves)
rehearse migrate --force
rehearse family:preflight           # preflight: ok
# Step 9's prechecks against family_media_test_cutover; then:
sudo -u postgres dropdb family_media_test_cutover
```

## 4. Deploy Laravel (migrations)

Dispatch family-media-api `deploy.yml` with `<S>` and homelab `main`'s sha. Through the gate,
`deploy-family-api-laravel.sh` refreshes the handoff secrets, checks the env file, pulls, runs
`family:preflight --allow-pending`, dumps **`family_media` only** (root `0700`
`/opt/backups/family-media-premigrate`, file `0600` from creation, `pg_restore --list` checked, kept
14 days) and only then migrates, starts the service and pins it after both pools answer
`/api/health/ready`. Note the dump path it prints.

```bash
docker compose exec -T family-api-laravel fcgi-probe.sh /api/health/ready && echo main ready
docker compose exec -T family-api-laravel fcgi-probe.sh /api/health/ready /run/family-api-fpm/fpm-auth.sock && echo auth ready
docker compose exec -T family-api-laravel printenv APP_ENV                  # production
free -m; docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'; sudo dmesg -T | grep -ci 'out of memory\|oom-kill'   # count unchanged
```

Row counts (3b) unchanged. Rollback: see "Rollback".

## 5. CloudFront `/api/*` behaviour

Apply family-media `infra/cloudfront/API-BEHAVIOR.md` (a7f421da) with: origin
`family-api.valtou.com`, HTTPS only; custom header `X-Family-Origin-Secret: <$secret>`; viewer
headers **without `Host`** plus `CloudFront-Viewer-Address` (Cloudflare routes by Host; forwarding
`family.valtou.com` would loop back to CloudFront).

**Cloudflare in the middle.** The Lightsail firewall admits 80/443 from Cloudflare only, so
CloudFront reaches the origin through Cloudflare, as the Day and You origin does. Cloudflare passes
both headers through, but its WAF, Bot Fight Mode, managed challenges and any IP-keyed rate rule
see all visitors as a few CloudFront IPs and would answer with HTML: add a rule for
`family-api.valtou.com` that skips them for requests carrying `X-Family-Origin-Secret` (nginx's
throttles key on the real viewer). Recommended follow-up: a **grey-clouded origin hostname**
(e.g. `family-api-origin.valtou.com`), which needs the firewall to admit CloudFront's
origin-facing ranges on 443, a certificate (port-80 ACME vhost first) and a `server_name`; not
done now because `family-api.valtou.com` already has DNS, a certificate and a vhost.

## 6. Step B: nginx serves `/api/` from Laravel

```bash
cd /opt/homelab-infra && git pull --ff-only                # the Step B commit
sudo test -s /opt/secrets/family-media-origin/origin-secret.map && echo secret present   # else nginx refuses the config
docker compose run --rm --no-deps nginx nginx -t
docker compose exec -T nginx nginx -s reload               # conf.d only
docker compose exec -T memorial-api-laravel fcgi-probe.sh /health/ready && echo memorial ok
```

Checks:

```bash
curl -fsS https://family.valtou.com/api/health/ready | jq -e '.data.ok == true and .error == null'   # true
curl -sS -i https://family.valtou.com/api/does-not-exist | sed -n '1p;$p'   # 404 … {"data":null,"error":"Not found"}
curl -sSI https://family.valtou.com/api/health | grep -i -E 'x-cache|cache-control'   # Miss from cloudfront / no-store
curl -sS -o /dev/null -w '%{http_code}\n' https://family-api.valtou.com/api/health    # 403 (no origin secret)
curl -sS -o /dev/null -w '%{http_code}\n' https://family-api.valtou.com/auth/login   # 403 (old Express path)
docker compose logs --tail=20 nginx | grep '/api/'          # first field: the real viewer IP, not a CloudFront edge
```

Then the web: merge family-media `port/7-frontend` and deploy it (its guard checks
`/api/health/ready` on the web origin first). Log in, open a photo, upload one, open People; the
row counts change only by what you did.

## 7. Retire Express

```bash
cd /opt/homelab-infra && git pull --ff-only                # the retirement commit
docker compose run --rm --no-deps nginx nginx -t
docker compose up -d --no-deps --force-recreate nginx      # drops the family-api-sock mount
docker compose exec -T memorial-api-laravel fcgi-probe.sh /health/ready && echo memorial ok
docker rm homelab-family-api                               # stopped at step 3; compose no longer knows it
```

Keep: the Express image (`docker image ls ghcr.io/zenvoraai/family-media-api`), the
`FAMILY_API_TAG=` line in `.env`, `/opt/secrets/family-media/.env`. They are the rollback; delete
them only when the rollback window is closed. The database, the bucket and the env files are not
touched by this step.

## 8. Capacity after

`free -m`, `docker stats --no-stream`, the OOM count again; watch `dmesg` for a day. Start the Day
and You staging services again if stopped.

## 9. Sweeps (last, data-destructive)

The sweeps have never run against this data. `family:sweep` has no dry-run and **permanently**
deletes: S3 objects of stale upload intents, trash past each family's retention (S3, offsite copy
and row), audit rows past retention, expired refresh tokens, queued offsite deletes (README
"Family sweeps (host cron)" has the table). Before the first run:

1. Today's 02:30 instance backup succeeded and is non-empty (workstation; bucket and prefix in
   aws-infrastructure `docs/lightsail-postgresql-s3-backup.md`):
   `aws s3 ls s3://<backup bucket>/postgres/family-media/production/ | tail -1` → today's date, size > 0.
2. Prechecks on `family_media` *(code reading)*:

   ```sql
   -- Trash the first run will purge (S3 + offsite + row), per family. Review the number; if large, decide first.
   SELECT m."familyId", count(*) FROM "Media" m JOIN "Family" f ON f.id = m."familyId"
    WHERE m."deletedAt" < now() - make_interval(days => f."trashRetentionDays") AND m."purgeAttempts" < 5 GROUP BY 1;
   -- Orphan-intent safety: must be 0 (an intent whose object a live Media row still uses).
   SELECT count(*) FROM "UploadIntent" ui
    WHERE ((ui.status = 'PENDING' AND ui."expiresAt" < now()) OR ui.status IN ('PROCESSING','FAILED'))
      AND EXISTS (SELECT 1 FROM "Media" m WHERE m."s3Key" IN (ui."s3Key", ui."finalKey")
                  OR m."thumbnailKey" = ui."thumbnailKey" OR m."displayKey" = ui."displayKey");
   -- Face re-scan safety: must be 0.
   SELECT count(*) FROM "Media" m WHERE m."facesScannedAt" IS NULL
      AND EXISTS (SELECT 1 FROM "FaceEmbedding" f WHERE f."mediaId" = m.id);
   ```

   Any non-zero safety count: stop and ask. Sweeps never list the bucket, and clustering skips
   locked or hand-assigned faces *(code reading)*.
3. Counts (3b) before, one run by hand, counts after; every difference must match its summary line:

   ```bash
   cd /opt/homelab-infra && docker compose exec -T family-api-laravel php artisan family:sweep; echo "exit $?"
   ```

4. Only then install the crontab (README "Family sweeps (host cron)"). The first scheduled run
   (04:00, 12:00 or 20:00) must come after a successful 02:30 backup on that day.

## Rollback

Order, per family-media `infra/cloudfront/API-BEHAVIOR.md` "Rollback" (a7f421da): **(1)** this
runbook's host steps below, **(2)** redeploy the last pre-Phase-7 web build, **(3)** delete the
`/api/*` behaviour, **(4)** never re-add the 403/404 custom error responses while `/api/*` exists.
CloudFront details live only in that document.

Before step 4 (no migration yet): start Express (`docker compose start api`) and revert what was
merged; no data step is needed.

After step 4, Express may no longer match the schema, so the real rollback is the pre-migration
dump plus Express. **Restoring it discards everything written to `family_media` after the dump**
(uploads, logins, edits); their S3 objects stay in the bucket, unreferenced.

```bash
cd /opt/homelab-infra
crontab -e                                                  # delete the three family sweep lines
docker compose stop family-api-laravel
# Restore family_media ONLY, from the deploy's dump (path printed by the deploy; or the step-3a dump),
# into a new database, then swap names (the migrated database is kept for inspection):
role=<the DATABASE_URL user>; dump=/opt/backups/family-media-premigrate/<file>.dump
sudo pg_restore --list "$dump" >/dev/null && echo dump readable
sudo -u postgres createdb -O "$role" family_media_rollback
sudo cat "$dump" | sudo -u postgres pg_restore --no-owner --role="$role" -d family_media_rollback
sudo -u postgres psql -c "SELECT pid FROM pg_stat_activity WHERE datname = 'family_media';"   # must be empty
sudo -u postgres psql -c 'ALTER DATABASE family_media RENAME TO family_media_laravel_'"$(date -u +%Y%m%d)"';'
sudo -u postgres psql -c 'ALTER DATABASE family_media_rollback RENAME TO family_media;'
# Bring Express back: revert (git revert on main, then pull) the retirement commit and the Step B commit.
git pull --ff-only
docker compose config -q && docker compose run --rm --no-deps nginx nginx -t
docker compose up -d --no-deps --force-recreate nginx       # the family-api-sock mount returns
docker compose up -d api                                    # the pinned FAMILY_API_TAG from .env
docker compose exec -T api node dist/probe.js && echo express ready
docker compose exec -T memorial-api-laravel fcgi-probe.sh /health/ready && echo memorial ok
```

Fallback only, when the per-database dumps are unusable: the 02:30 instance backup, **the
`family_media` object only** (aws-infrastructure doc: one custom-format dump per database under
`postgres/family-media/production/`; restore it the same way, into `family_media_rollback`). Never
the other prefixes, never the globals, and if a backup ever turns out to be a `pg_dumpall` cluster
file, extract the `family_media` section; never replay the whole file.
