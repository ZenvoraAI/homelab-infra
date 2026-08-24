# Cloudflare free-plan onboarding — design spec

Date: 2026-08-22
Status: revised after independent 3-agent review (security / architecture / scope
completeness) of the first draft — see "Review history" at bottom

**Rollout status as of 2026-08-25:**

| Zone | Status |
| --- | --- |
| `valtou.com` | ✅ Done — `admin`/`api` proxied and fully verified; `api.family.valtou.com` deliberately kept DNS-only permanently (see note under Rollout order) |
| `aiqiuqi.com` | ✅ Done — `api` proxied and fully verified |
| `dayandyou.com` | ⬜ In progress — nameservers confirmed correct at the `.com` registry (`whois`, updated 2026-08-24T12:21:32Z) but not yet propagated to the resolvers checked; `staging` set to Proxied, not yet live; `dayandyou.com`/`www` still DNS-only per plan |

See per-step notes under "Rollout order" and "Verification" below for what was
actually found at each stage.

## Problem

All five public products on the shared Lightsail box (`dayandyou.com` + staging,
`admin.valtou.com`, `api.valtou.com`, `api.family.valtou.com`, `api.aiqiuqi.com`) have
their DNS pointed directly at the host's public IP. There is no CDN, WAF, or DDoS layer
in front of nginx — confirmed by inspecting `nginx/conf.d/*.conf`, which sets
`X-Real-IP $remote_addr` directly with no upstream proxy to trust. A prior review of
this repo found:

- No fail2ban or any brute-force/intrusion detection on the host.
- No WAF — nginx's own `limit_req_zone` rate limiting on `api.aiqiuqi.com`,
  `api.family.valtou.com`, and the `email_ep` zone covers a few specific paths, not
  general attack traffic (SQLi/XSS-shaped payloads, scanners, bots).
- `admin.valtou.com` and `dayandyou.com` have no nginx-level rate limiting or security
  headers at all, unlike the other three vhosts.
- The origin IP is directly reachable by anyone who resolves the domain — nothing
  hides it or absorbs volumetric traffic before it reaches the box all five products
  share.
- Access logs are shared across all vhosts with no `$host` field, so there is no way to
  see per-domain traffic or flag suspicious activity without SSHing in and grepping.

## Goals

- Put Cloudflare's free tier in front of every public hostname on this host: DDoS
  mitigation, the free managed WAF ruleset, and Bot Fight Mode, at $0/month.
- Get per-domain traffic (PV/UV) and a security events log (what got blocked, from
  where) via Cloudflare's dashboard/API — without touching nginx log format or SSHing
  into the host for it.
- Preserve everything the origin already depends on: real client IPs reaching nginx
  (existing `limit_req_zone` rate limiting, SecureVault's `TRUST_PROXY` chain), valid
  TLS end-to-end, and uninterrupted Let's Encrypt renewal.
- Zero new monthly cost, zero new services on the Lightsail host, zero application code
  changes.

## Non-goals (v1)

- Cloudflare Pro/Business (custom WAF rules beyond the free managed ruleset, advanced
  rate limiting, PCI features) — revisit only if the free ruleset proves insufficient.
- Restricting the Lightsail firewall/security group to Cloudflare's IP ranges only
  (closing off direct-IP access entirely). Real hardening — and, per review, the "locks
  out your own debugging `curl`" reasoning for deferring it doesn't actually hold: a
  firewall rule allowlisting your own IP alongside Cloudflare's ranges isn't
  mutually exclusive with restricting everyone else. Deferred anyway because it's a
  distinct change with its own rollout/testing needs, not because it conflicts with
  this one — tracked as an immediate follow-up once this spec is stable, not a someday
  item. Until it lands, proxied hostnames get DDoS/WAF/Bot-Fight-Mode protection only
  against traffic that goes through Cloudflare; anyone who connects directly to the
  origin IP with a correct `Host:` header bypasses all of it and hits nginx exactly as
  it behaves today — worst for `admin.valtou.com` and `dayandyou.com`, which (confirmed
  in `conf.d/`) have no nginx-level rate limiting or security headers of their own
  either.
- AWS WAF / CloudFront. Doesn't attach to a Lightsail instance directly (needs a
  CloudFront distribution or ALB in front), meaningfully more re-architecture and
  ongoing cost than Cloudflare for this single-box, direct-IP setup.
- Building the per-domain traffic / security-events panel into `zenvora-admin`. Once
  Cloudflare is in front, that becomes a follow-up ticket against `zenvora-admin`
  (pull from the Cloudflare API) — this spec only covers getting the data to exist.

## Scope: domains and DNS zones

Cloudflare's free plan is per root domain ("zone"); a zone covers all its subdomains.
The seven public hostnames in `nginx/conf.d/` collapse to three zones:

| Zone (root domain) | Hostnames in scope | Backend port |
| --- | --- | ---: |
| `dayandyou.com` | `dayandyou.com`, `www.dayandyou.com`, `staging.dayandyou.com` | 3003 / 3003 / 3002 |
| `valtou.com` | `admin.valtou.com`, `api.valtou.com`, `api.family.valtou.com` | 3100 / 3000 / 4000 |
| `aiqiuqi.com` | `api.aiqiuqi.com` | 3001 |

Each zone's nameservers move to Cloudflare once; each hostname's DNS record is toggled
"Proxied" (orange cloud) independently after that, which is what actually turns
WAF/DDoS/CDN on for that hostname. This lets the rollout go host-by-host, not
domain-by-domain, after the one-time nameserver cutover per zone.

## Prerequisites

- **Cloudflare account ownership and 2FA.** One Cloudflare account holds DNS, TLS, and
  WAF control for all three production zones — in a setup that already treats TOTP as
  load-bearing at the app layer (SecureVault). 2FA on the Cloudflare account is required
  before nameserver cutover, not optional hardening; a compromised account can
  redirect traffic, disable WAF, or intercept via rogue proxying across every domain at
  once. Confirm 2FA on the relevant registrar account(s) too, since that's what's
  actually being handed control of during cutover.
- **Who does this.** Single-operator setup, so implicitly you — but name it explicitly:
  who creates/owns the Cloudflare account, and who holds registrar/Route53 login for
  each of the three domains. No sign-off process exists elsewhere in this repo for a
  DNS-level change, so none is being invented here — but the nameserver cutover is the
  single highest-blast-radius step in this plan and deserves a deliberate "yes, now" go
  rather than happening as a side effect of testing.
- **No new secrets.** v1 needs zero Cloudflare API credentials — every step here
  (nameserver cutover, DNS record proxy toggle, TLS mode, Configuration Rules) is done
  through the Cloudflare dashboard by hand. Nothing goes through the
  `refresh-*-secrets.sh` / SSM pattern the rest of this repo's secrets follow, because
  there is no secret to store. If a future iteration automates any of this via the
  Cloudflare API, that's the point at which a token would need to join that pattern —
  not before.

## Architecture (after)

```
visitor → Cloudflare edge (DDoS filter, free managed WAF, Bot Fight Mode)
        → nginx on Lightsail (real_ip module restores true visitor IP from CF-Connecting-IP)
        → existing limit_req_zone rate limiting, keyed on the real IP as today
        → app container (unchanged)
```

Nothing changes below nginx. No new container, no new volume, no application code
touched.

## Required nginx change: trust Cloudflare's real IP

This is the one change that is **not optional** — skipping it silently breaks existing
protections rather than failing loudly:

- Every request's `$remote_addr` becomes a Cloudflare edge IP once proxying is on,
  because nginx now sees Cloudflare, not the visitor, as the TCP peer.
- The existing `limit_req_zone $binary_remote_addr` zones (`email_ep`, `mem_general`,
  `mem_auth`, `fam_general`, `fam_auth`) are keyed on that address. With it collapsed to
  a handful of Cloudflare edge IPs, every visitor shares the same bucket — the limiter
  either throttles everyone as one client or, depending on which edge IP lands the
  request, does nothing meaningful for anyone.
- SecureVault's `TRUST_PROXY=1` reads `X-Forwarded-For` at the app layer, which
  Cloudflare does populate correctly — but only nginx's own real-IP handling fixes what
  nginx itself sees and rate-limits on.

**This fix must be deployed and verified working *before* the first DNS record anywhere
is flipped to Proxied — not just before the risky one.** Get the order backwards, even
briefly on the low-risk hostname the rollout starts with, and you reproduce the exact
rate-limiter-collapse / email-relay-abuse exposure this section exists to prevent, on
the very host chosen specifically to be safe to experiment on. Deploy it, run the
`$remote_addr` check from the Verification section below against plain HTTP traffic
(it'll show your own real IP either way pre-cutover — the point is confirming the
config is live and syntactically correct), and only then proceed to Rollout order.

Fix, added as a new file `nginx/conf.d/00-cloudflare-realip.conf` — **not**
`nginx/nginx.conf`. `conf.d/*.conf` is included from inside `nginx.conf`'s `http{}`
block, so a top-level directive here has identical global scope to putting it in
`nginx.conf` directly, and `conf.d/` is a directory bind mount the running container
already picks up on `nginx -s reload` — no `--force-recreate`, no outage. (This repo's
`family-api.conf` and `api.aiqiuqi.com.conf` already establish the same pattern with
their own top-level `limit_req_zone` directives — this follows it rather than
introducing a new one.) The `00-` prefix is only to make it sort first when someone
lists the directory; nginx's `include /etc/nginx/conf.d/*.conf` doesn't care about
load order for directives at this scope.

```nginx
# Cloudflare's published IPv4/IPv6 ranges — see "Keeping Cloudflare's IP list current"
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
real_ip_header CF-Connecting-IP;
```

**Keeping Cloudflare's IP list current:** Cloudflare occasionally revises these ranges
(rare, but it happens). Pull them fresh at implementation time from
`https://www.cloudflare.com/ips-v4` and `https://www.cloudflare.com/ips-v6` rather than
trusting the ranges listed above verbatim, and note in the commit where they came from
so a future revision is a known, deliberate re-pull rather than a silent drift.

Validate then reload, same as any other `conf.d/` change:

```bash
docker compose run --rm --no-deps nginx nginx -t
docker compose exec -T nginx nginx -s reload
```

No outage. `nginx/nginx.conf` itself is untouched by this change — that file's own
single-file-mount recreate gotcha (documented in the README) doesn't apply here.

## TLS mode: Full (strict), not Flexible

Every vhost already redirects HTTP → HTTPS at the origin
(`location / { return 301 https://$host$request_uri; }`) and terminates real,
publicly-trusted Let's Encrypt certificates. Cloudflare's SSL/TLS mode must be set to
**Full (strict)** per zone:

- **Flexible** (Cloudflare ↔ browser encrypted, Cloudflare ↔ origin plain HTTP) would
  make Cloudflare send plain HTTP to nginx, which immediately 301s back to HTTPS —
  Cloudflare follows it, gets another 301 — infinite redirect loop. This is the single
  most common Cloudflare misconfiguration for exactly this nginx pattern.
- **Full (strict)** keeps the connection encrypted end-to-end and validates the origin
  certificate against a public CA, which the existing Let's Encrypt certs already
  satisfy — no origin-side change needed beyond what's already there.

**Also set the edge-side minimum TLS version, separately.** "Full (strict)" only
governs the Cloudflare↔origin leg. The browser↔Cloudflare leg is a different dashboard
setting ("Minimum TLS Version" under SSL/TLS → Edge Certificates) that defaults to a
permissive value on a new zone. Set it to **TLS 1.2** per zone to match the origin's own
`ssl_protocols TLSv1.2 TLSv1.3;` — otherwise the origin's protocol restriction is
silently undermined on the public-facing leg, which is the one that actually matters.

## Let's Encrypt renewal through a proxied hostname

The HTTP-01 challenge (`/.well-known/acme-challenge/`, served from the certbot webroot
per the existing migration) must keep resolving over plain HTTP for Certbot to renew.
Two things to verify per zone before relying on it:

1. Cloudflare's **"Always Use HTTPS"** setting, if enabled, redirects that path too by
   default. Add a Configuration Rule (or Page Rule) bypassing "Always Use HTTPS" for
   `*/.well-known/acme-challenge/*`, or leave the zone-wide setting off and keep relying
   on the origin's own 301 for everything else.
2. Run `certbot renew --dry-run` against each domain **after** its DNS record is set to
   Proxied, not just after the nameserver cutover — the two are separate steps and only
   the second one changes how the challenge path is actually reached.

## Bot Fight Mode vs. Stripe webhooks

`docker-compose.yml` sets `STRIPE_WEBHOOK_SECRET` for both `dayandyou-prod` and
`dayandyou-staging` — Stripe posts webhook events server-to-server directly to
`dayandyou.com`/`www.dayandyou.com` (and staging), with no browser involved. Bot Fight
Mode is designed to JS-challenge or block exactly this shape of traffic (automated,
non-browser, no interactive session), and a blocked webhook fails silently from the
storefront's point of view — no customer-visible error, just an order that never
reconciles as paid. Before proxying `dayandyou.com`/`www.dayandyou.com`, add a
Configuration Rule exempting Stripe's webhook path (and `staging.dayandyou.com`'s,
before proxying that) from Bot Fight Mode, or use Cloudflare's IP-range allowlist for
Stripe's published webhook source IPs. Verify by triggering a real test webhook (Stripe
CLI or dashboard "resend") after proxying and confirming it reaches the app — the same
kind of check already planned for SES mail delivery, just for the other outbound-facing
integration this zone has.

## DNS records that must NOT be proxied

Cloudflare's initial DNS scan during zone setup imports existing records, but proxying
only makes sense for the A/AAAA records that terminate at nginx. Before touching
anything:

- Confirm no domain here has MX or SES-verification-related TXT/CNAME records (SPF,
  DKIM, DMARC) that Cloudflare's scan either missed or would proxy incorrectly — mail
  records must stay **DNS only** (grey cloud). `dayandyou.com` sends mail via SES
  (`AWS_SES_*` env vars in `docker-compose.yml`); its sending-domain DNS records need to
  survive the cutover unchanged.
- Treat the post-import DNS record list as something to review, not something to trust
  — diff it against whatever the domain's current registrar/Route53 zone file has before
  switching nameservers.

## Rollout order

Zone-level nameserver moves are the highest-blast-radius step (external, DNS-cached,
affects every hostname in that zone at once) and can't be tested per-hostname before
committing to it. Toggling a hostname's proxy status afterward is fast (seconds to
minutes) and reversible per-hostname, so the plan front-loads risk into the
lowest-consequence hostname of each zone rather than production traffic:

1. **`valtou.com` zone first.** Move nameservers. Set only `admin.valtou.com` to
   Proxied initially — single operator, low traffic, and any breakage is immediately
   visible to you rather than a customer. Verify (see below), then proxy
   `api.family.valtou.com`, then `api.valtou.com` (SecureVault) last within this zone —
   it has the most rate-limiting logic depending on correct real-IP handling, so it goes
   after confidence is established on its siblings.

   **Done, with one deviation found during rollout.** Nameservers moved, `admin` and
   `api` proxied and fully verified (see Verification status below). `api.family.valtou.com`
   was **not** proxied and is not planned to be: it turned out to be a two-level
   subdomain, and Cloudflare's free-tier Universal SSL only covers the root domain plus
   one level of subdomain — proxying it produces an immediate, total TLS handshake
   failure, confirmed live. Worse, `family-media`'s own docs
   (`docs/media-cookie-auth-setup.md`) show this exact two-level shape was a *deliberate*
   prior migration for cookie isolation (`MEDIA_COOKIE_DOMAIN=.family.valtou.com` keeps
   its cookies from reaching sibling services like `admin.valtou.com`/`api.valtou.com`).
   Renaming it to a one-level subdomain to dodge the cert limit would undo that isolation
   — worse trade than just leaving this one host outside Cloudflare's WAF/DDoS layer.
   It keeps its own nginx-level protections regardless (`family-api.conf`'s existing
   `fam_general`/`fam_auth` zones), unaffected by any of this.
2. **`aiqiuqi.com` zone.** Move nameservers, proxy `api.aiqiuqi.com`.

   **Done.** Nameserver propagation took noticeably longer than `valtou.com`'s (GoDaddy
   vs. Route53), otherwise no surprises. `api` proxied and fully verified.
3. **`dayandyou.com` zone last.** Move nameservers. Proxy `staging.dayandyou.com`
   first, verify, then `dayandyou.com` + `www.dayandyou.com`.

   **In progress.** DNS scan was clean on this zone — no surprise records like the
   `portal`/apex-elsewhere ones found in `aiqiuqi.com`'s scan. The Stripe-webhook
   Configuration Rule (see "Bot Fight Mode vs. Stripe webhooks" below) is live,
   scoped to `/api/stripe-webhook`, skipping only Super Bot Fight Mode rules — not
   the managed WAF ruleset. TLS is Full (strict) + minimum TLS 1.2. `staging` is set
   to Proxied per plan; `dayandyou.com`/`www` are still DNS-only, waiting on `staging`
   to actually go live before proxying them. Nameserver change confirmed correct at
   the registry itself (`whois dayandyou.com` shows Cloudflare's nameservers, updated
   2026-08-24T12:21:32Z) but propagation to the resolvers checked here is still
   pending — almost certainly a stale cached NS TTL at those specific resolvers
   (`valtou.com`, also on Route53, propagated within minutes; this one is past a day),
   not a configuration problem.

## Verification (per hostname, after proxying it)

- `curl -I https://<host>` — response should carry a `cf-ray` header, confirming it
  passed through Cloudflare.
  **Done for `admin.valtou.com` and `api.aiqiuqi.com`** — both confirmed.
- Re-run the existing host-side health checks from `README.md`
  (`curl -fsS http://127.0.0.1:<port>/...`) — unaffected by any of this, but confirms
  the container side wasn't disturbed by the nginx reload.
- Tail `access.log` for a request made from a known IP (e.g. your own) and confirm
  `$remote_addr` shows that real IP, not a `173.245.`/`104.16.`-style Cloudflare range —
  confirms `real_ip_header` is working.
  **Done for `admin.valtou.com` and `api.valtou.com`** — both confirmed via a live
  request's IPv6 address, which matched neither host, correctly ruling out every
  Cloudflare-published range.
- Trigger the existing rate limiter deliberately (e.g. hit `/api/auth/password-reset`
  more than 5×/min from one IP) and confirm it still fires at the same threshold as
  before, from a single real IP — confirms rate limiting wasn't silently broken by the
  real-IP fix being wrong or absent.
  **Done 2026-08-25 for all three proxied hosts, plus `dayandyou.com` ahead of its own
  cutover:** `admin.valtou.com` (`admin_general`, burst 40 — 41 through, 19 rejected
  `503`), `dayandyou.com` (`dayandyou_general`, burst 100 — 101 through, 29 rejected
  `503`), `api.aiqiuqi.com` `/auth/` (`mem_auth`, burst 20 — 21 through, 14 rejected
  `503`), `api.valtou.com` `/api/auth/password-reset` (`email_ep`, burst 3 — 4 through,
  6 rejected with the custom `429` status, not the default `503`, confirming
  `limit_req_status` is wired up too). All four fired exactly at their configured
  burst thresholds.
- `certbot renew --dry-run` for that hostname's certificate.
  **Done for `admin.valtou.com`** (ran across all six domains at once, all succeeded).
  Not yet re-run for `api.aiqiuqi.com` specifically since it went live.
- For `dayandyou.com`/`www.dayandyou.com`/`staging.dayandyou.com` specifically: confirm
  SES mail sending (e.g. a real password-reset or order-confirmation email) still
  delivers, and send a real Stripe test webhook and confirm it reaches the app (see "Bot
  Fight Mode vs. Stripe webhooks" above) — do this before considering `dayandyou.com`
  done, not as an afterthought.
  **Not done yet** — blocked on `staging.dayandyou.com` actually going live (nameserver
  propagation still pending).
- For `api.valtou.com` specifically: confirm WebSocket connectivity still works —
  `valtou-api.conf` hoists the same `Upgrade`/`Connection` header pattern
  `dayandyou.conf` uses, so it needs the same explicit post-cutover check, not just
  Day and You.
  **Turned out not applicable, for either host.** Checked both `securevault-framework`
  (behind `api.valtou.com`) and `day-and-you` (behind `dayandyou.com`) — neither has a
  `ws`/`socket.io` dependency or any hand-rolled `.on('upgrade')` handler. Both vhosts'
  `Upgrade`/`Connection: upgrade` headers are unused defensive boilerplate, not a live
  feature. Nothing to verify here for either hostname.

## Rollback

- **Per-hostname, fast:** flip the DNS record back to "DNS only" (grey cloud) in the
  Cloudflare dashboard. Traffic goes back to hitting the origin directly within
  seconds/minutes, no nameserver change needed. This is the rollback for "this one
  hostname broke."
- **Per-zone, slow:** revert nameservers at the registrar back to whatever they were
  before (Route53 or the registrar's own DNS, per zone). DNS TTL and resolver caching
  mean this can take hours to fully propagate. Only needed if Cloudflare itself is
  unreachable/misbehaving at the platform level, not for an nginx-side misconfiguration
  — those are fixed by editing the relevant `conf.d/` file and reloading (or, for an
  actual `nginx.conf` edit, recreating the container), not by rolling back DNS.

## Testing

This repo's own convention (see `tests/`) is a regression test per meaningful config
property, not just a manual verification pass. This change should follow it:

- **Add `tests/verify-cloudflare-real-ip.sh`**, parallel to
  `tests/verify-certbot-webroot.sh` — assert `nginx/conf.d/00-cloudflare-realip.conf`
  exists, contains `real_ip_header CF-Connecting-IP;`, and contains at least one
  `set_real_ip_from` line, so a future edit that accidentally deletes or misplaces the
  file fails CI instead of silently reintroducing the rate-limiter-collapse risk this
  spec exists to prevent.
- **Check whether `tests/verify-email-rate-limits.sh` needs updating.** It already
  asserts nginx limits + `TRUST_PROXY` reach the container; confirm it doesn't assert
  anything about the trusted-client-IP source that would need to change now that it
  moves from the raw TCP peer to `CF-Connecting-IP`. If it doesn't reference that at
  all, no change needed — but check rather than assume.
- Run `bash tests/verify-container-log-limits.sh` and the other existing tests
  unchanged, as a matter of course — nothing here should affect them, and that's worth
  confirming rather than assuming.

## Cost

$0/month. Cloudflare Free requires only an email signup, no payment method. The three
zones (`dayandyou.com`, `valtou.com`, `aiqiuqi.com`) are three free zones on one free
account.

## Open risks / things to verify during implementation

- Exact current DNS records per domain (TTLs, any records besides the app's A/AAAA)
  aren't visible from this repo — must be pulled from the live registrar/Route53 config
  before starting, not assumed from `nginx/conf.d/`.
- Whether `ALLOWED_ORIGINS` / CORS config for SecureVault or the family API references
  the origin IP anywhere instead of the hostname (would be unaffected by this change
  either way, but worth a quick grep of those apps' own repos since they're out of
  scope here).
- The Lightsail-firewall-restriction follow-up (see revised Non-goals entry above) is
  the natural, fairly urgent next step once this spec is stable — until it lands, every
  proxied hostname's WAF/DDoS/Bot-Fight-Mode protection is bypassable by anyone who
  connects to the origin IP directly with a correct `Host:` header. No spoofing or
  header-forgery needed for that bypass; `set_real_ip_from` only trusts
  `CF-Connecting-IP` from a TCP peer that's actually in Cloudflare's ranges, so a direct
  connection doesn't get to claim a fake IP through this mechanism — it just doesn't get
  filtered at all.

## Review history

Revised after an independent 3-agent review (security / architecture / scope
completeness) of the first draft.

The security and architecture agents converged from different angles on the same
weak point — the real-IP fix — without seeing each other's findings: architecture
flagged that the fix belonged in `conf.d/` instead of `nginx.conf` to avoid an
unnecessary full-site outage; security flagged that the spec never stated the fix must
be deployed and *verified* before the first hostname goes Proxied. Both are reflected
above (new file location, hard precondition). Being independently caught from two
angles is why this was treated as the highest-priority fix in this revision, ahead of
everything else found.

The security agent's first-pass finding also self-corrected mid-review: its initial
framing described the residual risk as IP-spoofing / rate-limiter-poisoning via a
forged `CF-Connecting-IP` header, then, on rereading its own proposed mechanism,
determined that `set_real_ip_from` only substitutes the header when the TCP peer is
actually in Cloudflare's ranges — so a direct connection can't forge its way past it.
The corrected, narrower finding (direct-to-origin traffic gets a full WAF/DDoS/bypass,
not a spoofed identity) is what's reflected in this revision. Recorded here so the
false initial framing doesn't get treated as established fact later — the corrected
version is real and is reflected in Non-goals and Open Risks above.

Other changes from this revision: the seven-vs-six hostname count error (scope agent);
the Stripe-webhook-vs-Bot-Fight-Mode interaction, which no agent's assigned lens
technically owned but the scope agent surfaced anyway by reading `docker-compose.yml`
closely (probably the single most concretely damaging finding of the three reviews —
silent payment-webhook failure has no visible symptom until someone notices unpaid
orders); the missing `api.valtou.com` WebSocket check (architecture agent, caught
because the security review only grounded itself in `dayandyou.conf` for that point);
the edge-side minimum TLS version setting (security agent); the Cloudflare-account 2FA
requirement and who/when ownership gaps (security and scope agents respectively); and
the `tests/` entry this repo's own convention calls for (scope agent, checked directly
against the certbot migration plan as a rigor baseline).
