# Tonight's hardening checklist

Date: 2026-08-22
Companion to `2026-08-22-cloudflare-free-onboarding-design.md` (already sent) — that
one covers the Cloudflare rollout; this one covers everything that doesn't depend on
it and can be done tonight, host-by-host, independently.

Everything below is a command you run yourself on the Lightsail box (`ubuntu@<host>`)
or in an account's web settings — I don't have SSH or console access to run any of
this. Where a step touches `homelab-infra`'s nginx config, the exact diff is included
so you can paste it straight into the repo.

**Do the steps in this order.** Later ones (SSH hardening) assume earlier ones (fail2ban,
firewall check) are already in place, so you have a safety net before touching anything
that could lock you out.

---

## 0. Confirm the firewall state (read-only, do this first)

Don't change anything yet — just know what you're starting from.

```bash
sudo ufw status verbose
```

If `ufw` is inactive or shows a permissive default, note that — it feeds into step 5.

Also check the **Lightsail console → your instance → Networking tab → Firewall
rules** (this is a UI action, no command for it). Confirm which ports are open to
`0.0.0.0/0` right now — expect at least 22 (SSH), 80, 443. If anything else is open to
the world (e.g. 5432 for Postgres, or any of the app ports 3000-3003/3100/4000), that's
the single most urgent thing to close, ahead of everything else on this list.

---

## 1. Turn on 2FA everywhere (no commands, ~10 minutes total)

- AWS/Lightsail console account
- GitHub account (the one `zenvora-admin`'s OAuth login is whitelisted to)
- Domain registrar account(s) for `dayandyou.com`, `valtou.com`, `aiqiuqi.com`
- Cloudflare account, once you create it for the other spec

Zero risk, zero rollback needed. Just do it.

---

## 2. fail2ban

```bash
sudo apt update
sudo apt install -y fail2ban

sudo tee /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
EOF

sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

The last command should print the `sshd` jail's status (currently-banned count,
total banned, etc.) — that confirms it's actually watching. Isolated to SSH auth
logs; doesn't touch nginx, doesn't touch any container, nothing to break here.

**Later, once you're comfortable:** fail2ban can also watch nginx's `error.log` for
repeated 401/403/404 bursts from one IP and ban those too, but that needs a custom
filter written against this repo's actual log format — worth doing as a follow-up,
not tonight.

---

## 3. unattended-upgrades

```bash
sudo apt update
sudo apt install -y unattended-upgrades apt-listchanges
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

That last command opens a prompt — "Automatically download and install stable
updates?" — answer **Yes**. Verify it took:

```bash
cat /etc/apt/apt.conf.d/20auto-upgrades
```

Expect:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

---

## 4. SSH hardening — read this whole section before running anything

This is the one step that can lock you out if done wrong. The safety net:

- **Keep your current SSH session open the entire time.** Don't close it until you've
  confirmed a *new* connection still works.
- Test in a **second, separate terminal/session** before trusting the change.
- If you do get locked out anyway, Lightsail's browser-based SSH console (Lightsail
  console → your instance → "Connect using SSH", the in-browser terminal) connects
  independently of the sshd config changes below and can get you back in to revert.

Confirm key-based login works right now, from a fresh terminal, before changing
anything:

```bash
ssh -o PreferredAuthentications=publickey ubuntu@<host> "echo key auth confirmed"
```

Only once that prints successfully, apply the hardening as a drop-in override file
(not editing `sshd_config` directly, so a future package update can't silently
clobber it):

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF

sudo sshd -t   # validates syntax — must print nothing / no error before reloading
sudo systemctl reload sshd
```

Then, **from a second terminal**, confirm you can still connect:

```bash
ssh ubuntu@<host> "echo still in"
```

If that works, you're done. If it doesn't, your original session (still open) can
revert:

```bash
sudo rm /etc/ssh/sshd_config.d/99-hardening.conf
sudo systemctl reload sshd
```

---

## 5. nginx: security headers + rate limiting on `admin.valtou.com` and `dayandyou.com`

These two are the only vhosts in `homelab-infra` without either. Everything below
mirrors the pattern `api.aiqiuqi.com.conf` and `family-api.conf` already use — no new
pattern introduced.

**`nginx/conf.d/admin.valtou.com.conf`** — add a rate-limit zone at the top of the
file (outside any `server{}` block, same reason as the Cloudflare real-IP fix: this
file is `include`d inside `nginx.conf`'s `http{}` block, so a top-level directive here
has http-level scope):

```nginx
limit_req_zone $binary_remote_addr zone=admin_general:10m rate=120r/m;
```

Then inside the existing `443 ssl` server block, add headers and wrap the location:

```nginx
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "no-referrer" always;

location / {
    limit_req zone=admin_general burst=40 nodelay;
    proxy_pass http://127.0.0.1:3100;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_cache_bypass $http_upgrade;
}
```

120 requests/min is generous for a single-operator dashboard (matches roughly what a
person clicking around actually generates); tighten later if you want.

**`nginx/conf.d/dayandyou.conf`** — same idea, but this is a storefront serving pages
+ static assets, so the rate needs headroom for a real pageview (HTML + JS + CSS +
images all counting as separate requests). Add at the top:

```nginx
limit_req_zone $binary_remote_addr zone=dayandyou_general:10m rate=300r/m;
```

Then in **both** the `dayandyou.com`/`www.dayandyou.com` server block and the
`staging.dayandyou.com` server block, add the headers and wrap `location /` the same
way (adjust `proxy_pass` port per block — 3003 for prod, 3002 for staging, matching
what's already there). Treat 300r/m as a starting point — watch `access.log` for a few
days after and tighten or loosen based on what real traffic looks like; there's no way
to get this number exactly right without observing actual load.

**Deploy for both files** (directory mount, hot-reloadable, no outage — same mechanic
as the Cloudflare real-IP fix):

```bash
cd /opt/homelab-infra
git pull --ff-only
docker compose run --rm --no-deps nginx nginx -t
docker compose exec -T nginx nginx -s reload
```

Verify:

```bash
curl -sI https://admin.valtou.com | grep -i x-frame-options
curl -sI https://dayandyou.com | grep -i x-frame-options
```

Both should show `X-Frame-Options: DENY`.

---

## What's deliberately not in tonight's list

- **Postgres `pg_hba.conf` review** — depends on knowing the firewall result from step
  0 first (if the firewall already blocks 5432 from the world, this is lower urgency);
  do it as a quick follow-up once step 0's answer is in hand, not blindly tonight.
- **Cloudflare rollout** — separate spec, separate night; don't rush it alongside SSH
  hardening in the same session, since both have their own "don't lock yourself out"
  failure modes and you want a clear head for each.
- **Restricting the Lightsail firewall to Cloudflare-only IPs** — explicitly has to
  come *after* Cloudflare is live and stable, not before. Doing it tonight, before
  Cloudflare exists, would just cut off all your own traffic.
