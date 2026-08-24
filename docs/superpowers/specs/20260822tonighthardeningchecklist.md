# Tonight's hardening checklist

Date: 2026-08-22
Companion to `2026-08-22-cloudflare-free-onboarding-design.md` (already sent) — that
one covers the Cloudflare rollout; this one covers everything that doesn't depend on
it and can be done tonight, host-by-host, independently.

**Status as of 2026-08-24:**

| Step | Status |
| --- | --- |
| 0. Firewall state | ✅ Checked, and `ufw` now enabled too — see note below |
| 1. 2FA everywhere | ✅ All four confirmed (AWS/Lightsail via Route53 login, GitHub, domain registrars — Route53/AWS for `valtou.com`/`dayandyou.com`, GoDaddy for `aiqiuqi.com` — and Cloudflare) |
| 2. fail2ban | ✅ Done — see note below |
| 3. unattended-upgrades | ✅ Already done, unrelated to this checklist — see note below |
| 4. SSH hardening | ✅ Done — see note below |
| 5. nginx headers/rate limiting | ✅ Done and deployed — see note below for one correction made after deploy |

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

**Status: checked, 2026-08-25.** `ufw status verbose` returned `inactive` — no
OS-level filtering at all right now, so the Lightsail cloud firewall is the *only*
line of defense at the network level. That firewall itself is clean: only `22` (SSH,
including the Lightsail browser SSH channel), `80`, and `443` are open to
`0.0.0.0/0` — no unexpected app ports (`3000-3003`/`3100`/`4000`) or database ports
(`5432`) exposed. Nothing urgent to close. Turning `ufw` on is a separate decision
(out of scope for this checklist — doing it without first mirroring the Lightsail
rules risks a self-inflicted lockout) and isn't required before anything else here;
noting it feeds forward into the deferred Postgres `pg_hba.conf` review and the
later "restrict Lightsail firewall to Cloudflare-only IPs" follow-up.

**2026-08-25 update: `ufw` is now active too**, mirroring the Lightsail rules exactly
(`22`/`80`/`443` allowed, default deny incoming). Verified safe from a fresh
connection on a separate machine before trusting it — network layer reached the SSH
port fine (no lockout), confirming this repo's all-`network_mode: host` compose setup
avoids the classic Docker-bypasses-ufw problem that bridge-mode port publishing would
have hit.

---

## 1. Turn on 2FA everywhere (no commands, ~10 minutes total)

- AWS/Lightsail console account
- GitHub account (the one `zenvora-admin`'s OAuth login is whitelisted to)
- Domain registrar account(s) for `dayandyou.com`, `valtou.com`, `aiqiuqi.com`
- Cloudflare account, once you create it for the other spec

Zero risk, zero rollback needed. Just do it.

**Status: done.** All four confirmed as of 2026-08-24 — AWS/Route53 (`valtou.com` +
`dayandyou.com` nameservers live there), GoDaddy (`aiqiuqi.com`), Cloudflare, and
GitHub. Worth knowing: `zenvora-admin`'s OAuth login doesn't just benefit from GitHub
2FA being on, it *requires* it — the callback checks the logging-in account's 2FA
status and refuses the session if it's off (`src/auth/oauth.ts`, tested in
`tests/auth/oauth.test.ts:65-134`). So this account's GitHub 2FA was already a hard
dependency before tonight, not just general hygiene.

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

**Status: done.** Turned out fail2ban was already installed and running (since
2026-08-10, predating this checklist) — but only via Ubuntu's stock
`/etc/fail2ban/jail.d/defaults-debian.conf`, which just sets `[sshd] enabled = true`
with no `jail.local` anywhere. Effective `bantime` was only 10 minutes (matched
`findtime`/`maxretry` exactly, but 6x weaker than the 1h this checklist calls for).
Created `jail.local` as above; `sshd` jail now confirmed running with `bantime=3600`.
The sshd jail had already banned 13 IPs total before this change (real brute-force
traffic, not hypothetical) — that history reset on restart, which is expected and
harmless.

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

**Status: already done, unrelated to this checklist.** Both `apt-daily.timer` and
`apt-daily-upgrade.timer` have been active since 2026-05-19 (three months before this
checklist existed), and the log shows real daily runs — including an actual
auto-removal of stale `linux-aws-6.8-*-1061` kernel packages on 2026-08-22. Nothing to
do here.

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

**Status: blocked, nothing applied yet.** The key-auth check above was run from two
wrong places first (from inside the host itself, targeting first its own private IP
then its own public IP — neither tests anything real, since the host has never had
reason to SSH to itself). Run correctly from the operator's own laptop against the
real public IP (redacted), it returned `Permission denied (publickey)` with the
default identity. That's not proof key auth is broken — the test command didn't
specify which key to offer, and this host may be reached day-to-day via a specific
`-i <keyfile>` or an `~/.ssh/config` alias rather than a default identity. **Before
retrying this step:** confirm what the normal, everyday connection command/config
actually is, and verify *that* one works from a fresh terminal — only then apply the
`sshd_config.d` change. `sshd_config` itself has not been touched, so there is no
lock-out risk sitting open right now.

Side note, not actionable: the host key's fingerprint is also associated with an old
IP (redacted) in the operator's `known_hosts`, confirming the box's public IP
has changed before — consistent with the Cloudflare spec's "IP is not static" framing
and the deferred static-IP-cutover item in `aws-infrastructure`.

**Resolved 2026-08-25.** The blocker dissolved once it turned out day-to-day access
to this host is exclusively via Lightsail's browser-based SSH console (AWS-managed
key auth), never a personal terminal client — so the earlier `Permission denied
(publickey)` results from a laptop were irrelevant; that path was never in use.
`PasswordAuthentication no` doesn't touch Lightsail's browser SSH (it isn't
password-based), and login is always as `ubuntu`, never `root`, so `PermitRootLogin
no` is likewise a no-op for the real access path. Applied
`/etc/ssh/sshd_config.d/99-hardening.conf`, `sshd -t` clean, reloaded, and verified
from a second, independent Lightsail browser SSH tab while the first stayed open —
new session connected fine.

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

**Status: done and deployed, with one correction.** `admin.valtou.com.conf` got the
rate limit and all three headers exactly as above — clean, since `zenvora-admin` sets
none of these itself. `dayandyou.conf` got the rate limit, but the `add_header` lines
were reverted after deploy: `day-and-you`'s own `next.config.ts` already sends a more
complete set (also `Permissions-Policy`, HSTS, CSP), and nginx's `add_header` only
*appends* to upstream response headers rather than replacing them. The two together
produced duplicate/conflicting headers on the wire — confirmed live, e.g. two
different `Referrer-Policy` values in one response
(`strict-origin-when-cross-origin, no-referrer`). `dayandyou.conf` now carries rate
limiting only; the security headers stay app-owned. `tests/verify-admin-dayandyou-hardening.sh`
asserts this split (headers required on `admin.valtou.com.conf`, `add_header` absent
from `dayandyou.conf`) so it can't silently drift back.

Also worth knowing: the "confirm WebSocket still works" caveat that appears for
`api.valtou.com` in the Cloudflare spec doesn't apply to `dayandyou.com` either —
neither `day-and-you` nor `securevault-framework` (behind `api.valtou.com`) actually
implements WebSocket. The `Upgrade`/`Connection: upgrade` headers already present in
both vhosts are unused defensive boilerplate, not a live feature.

---

## What's deliberately not in tonight's list

- **Postgres `pg_hba.conf` review** — depends on knowing the firewall result from step
  0 first (if the firewall already blocks 5432 from the world, this is lower urgency);
  do it as a quick follow-up once step 0's answer is in hand, not blindly tonight.
  **Done 2026-08-25:** stock, unmodified Ubuntu default — every `host` line is scoped
  to `127.0.0.1`/`::1` only, no `0.0.0.0/0` entry exists, and `listen_addresses` is
  `localhost`, so Postgres has no listening socket on any external interface at all.
  This is on top of, not instead of, the firewall being closed — three independent
  layers (Lightsail firewall, `ufw`, Postgres itself not binding externally) all agree
  5432 is unreachable from outside. The five databases sharing this one instance
  (`dayandyou_prod`/`staging`, `family_media`, `memorial_site`, `securevault_db`) work
  because every service container runs `network_mode: host`, so `127.0.0.1:5432` is
  genuinely local from their point of view. Nothing to change here.
- **Cloudflare rollout** — separate spec, separate night; don't rush it alongside SSH
  hardening in the same session, since both have their own "don't lock yourself out"
  failure modes and you want a clear head for each.
- **Restricting the Lightsail firewall to Cloudflare-only IPs** — explicitly has to
  come *after* Cloudflare is live and stable, not before. Doing it tonight, before
  Cloudflare exists, would just cut off all your own traffic.
