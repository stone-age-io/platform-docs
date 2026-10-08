---
path: helpdesk/configuration
nav_order: 60
---
# Configuration

Two configuration surfaces, deliberately split:

1. **`helpdesk.yaml` + `HELPDESK_*` env** — infrastructure the process
   needs before PocketBase is up (data dir, NATS, inbound-email webhook).
2. **PocketBase settings** (dashboard at `/_`, → Settings) — operator
   concerns stored in the database: SMTP, application URL, OAuth2.

## helpdesk.yaml

Search order: `$HELPDESK_CONFIG` (explicit path) → `./helpdesk.yaml` →
`/etc/helpdesk/helpdesk.yaml` (the search is by name, so `helpdesk.yml` /
`.json` / `.toml` are found too). A missing file is fine — defaults + env
cover containerized deployments — **except** an explicit `$HELPDESK_CONFIG`
that doesn't exist, which is a startup error. Every key has an env override
with the `HELPDESK_` prefix and `.` → `_` (e.g. `nats.creds_file` →
`HELPDESK_NATS_CREDS_FILE`).

List-valued keys (`nats.urls`, `inbound.allowed_ips`) take a
**whitespace-separated** env value: `HELPDESK_INBOUND_ALLOWED_IPS="192.0.2.10
198.51.100.0/24"`. A comma-joined value arrives as one entry. For `nats.urls`
that happens to work (the URLs are re-joined with commas for the NATS client),
but for `inbound.allowed_ips` it is an unparseable entry, which is dropped —
and an allowlist with nothing parseable left in it **allows every IP**.

```yaml
# PocketBase data directory (SQLite database, uploads).
data_dir: pb_data

# Optional operator branding overlay (see "Branding overlay" below).
branding:
  dir: ""                        # host dir of theme.css / logo.svg / branding.json

# Auto-close tickets left `resolved` this many days, via a daily cron. Measured
# from `resolved_at`, so an unrelated edit while resolved doesn't reset the
# clock. 0 disables it (tickets then close only when staff close them by hand).
# The window is the grace period in which a requester reply reopens the ticket.
auto_close_resolved_days: 7      # env HELPDESK_AUTO_CLOSE_RESOLVED_DAYS

# NATS connection to the platform operator's hub account. Leave urls empty
# to run without NATS (tickets then arrive only via portal/agent/webhook).
nats:
  urls: []                       # e.g. ["nats://hub.example.com:4222"]
  creds_file: ""                 # required when urls is set
  stream: HELPDESK_EVENTS        # helpdesk-owned inbox stream (hub account)
  durable: helpdesk-ingest       # durable consumer name; stable across restarts
  notify_stream: HELPDESK_NOTIFICATIONS  # helpdesk-owned OUTBOUND event stream

# Inbound email via an email-parsing provider (Postmark). Leave secret empty
# to disable — mail then arrives only via portal/agent/webhook/NATS.
inbound:
  secret: ""                     # webhook Basic-auth password; empty ⇒ disabled
  allowed_ips: []                # optional: restrict to the provider's egress ranges (IPs or CIDRs)
  # reply_to: ""                 # reserved: read but NOT wired in v1 — replies thread via the PB sender address
```

### Branding overlay

Point `branding.dir` (env `HELPDESK_BRANDING_DIR`) at a host directory to
override the app name, logo, and DaisyUI theme **without rebuilding**. The
helpdesk serves that directory's files under `/branding/*`; `index.html`
`<link>`s `/branding/theme.css` and the SPA fetches `/branding/branding.json`
at boot. Empty/unset = embedded defaults, and the route still serves a silent
empty `theme.css` / `{}` `branding.json` so a stock install never 404s
(path traversal is rejected).

| File | Shape | Effect |
|---|---|---|
| `branding.json` | `{ "appName": "...", "logo": "logo.svg" }` | app name and logo file, served at `/branding/<logo>`. |
| `theme.css` | DaisyUI `[data-theme=light\|dark]` OKLCH var overrides | recolors the UI; loaded after the bundled CSS. Override only what you need — the rest keeps the built-in theme. |
| the logo (e.g. `logo.svg`) | an image | replaces the built-in mark; `.brand-logo-img` is a CSS hook for per-theme swaps. |

Copy [`branding.example/`](https://github.com/stone-age-io/helpdesk/blob/main/branding.example) to the host (e.g.
`/etc/helpdesk/branding/`), add your `logo.svg`, set `appName`, and set
`branding.dir`. Its `branding.json` ships `"appName": "Service Desk"`, and any
`appName` counts as an operator choice — left as-is it replaces the portal's
stock "Support" too (see below).

**Where `appName` lands.** Each shell has its own stock wordmark — the staff and
field apps say "Service Desk", the requester portal says "Support" — because on
an unbranded install those read better than one name repeated everywhere. An
`appName` **replaces** all of them, so a branded install never shows the
operator's logo next to our stock name. It also sets the browser tab title and
the sign-in card, which is the first screen anyone sees and therefore the one
that most needs to look like the operator's. Long names truncate rather than
overflow the card. The `<title>` in `index.html` is only the pre-JavaScript
fallback; the SPA overwrites it before mount.

Not brandable: the PWA manifest (a static file — an operator overlay can't
rename the installed app) and outbound email templates (those are edited in the
SPA under **Notifications**, not here).

### NATS credentials

The helpdesk authenticates to the hub account with a **platform-minted
`nats_user`** scoped to `sub helpdesk.>`, exported as a `.creds` file:

1. In the platform, create a hub-account `nats_user` with subscribe
   permission on `helpdesk.>`. To also emit outbound notification events, grant
   `pub helpdesk.>` (and stream-management for `HELPDESK_NOTIFICATIONS`); the
   helpdesk is otherwise blind to the grant.
2. Export its creds file; point `nats.creds_file` at it.
3. Start the helpdesk — it creates `HELPDESK_EVENTS` (subjects
   `helpdesk.*.tickets.>`) on first serve and begins consuming. If publish is
   granted, it also creates `HELPDESK_NOTIFICATIONS` (subjects
   `helpdesk.*.events.>`) for the outbound channel; if not, that setup fails
   softly and email still sends.

Setting `nats.urls` without `nats.creds_file` is a startup error. A broker
that is down at boot is **not** an error: the app logs, serves, and the
durable consumer resumes when connectivity returns.

Per-customer mapping: set `customers.code` (SPA → customer detail) to the
customer's platform organization **code** — the tenant token on subject token 2
(ADR 0002; migration `1828000000`). `platform_org_id` is no longer consulted for
routing. Events for unmapped codes are logged and dropped (acked). The same
code names the customer on outbound notification subjects, and a customer
without one has its NATS notification events skipped (see
[`docs/notifications.md`](notifications.md)).

### Inbound email

An email-parsing provider (Postmark to start) receives mail, parses the MIME,
and `POST`s clean JSON to `POST /api/helpdesk/inbound/email/postmark`; the route
is registered only when `inbound.secret` is set. The provider authenticates with
that secret via HTTP Basic auth on the webhook URL (the password is checked;
the username is ignored); `inbound.allowed_ips` can additionally pin the caller
to the provider's published egress ranges — bare IPs or CIDRs, checked before
the secret. The allowlist matches PocketBase's resolved client IP, so behind a
reverse proxy set PocketBase's trusted-proxy headers (below) or every request
appears to come from the proxy. The helpdesk holds **no mailbox credentials** —
only this webhook secret.

Routing and threading are covered in full by
[`docs/email-ingestion.md`](email-ingestion.md); the operator-facing essentials:

- **Forward** your public address (e.g. `support@…`) into the provider's inbound
  address, and set `customers.email_domain` (Directory → customer) for customers
  who email from their own domain so cold senders resolve to the right tenant. A
  sender the helpdesk can't attribute to a known customer is rejected (acked, not
  queued) — there is no catch-all.
- **Threading** is by the `[#N]` token already in every notification subject, so
  the PocketBase **sender address (below) must be that same forwarded intake
  mailbox** — a reply then returns there and lands on ticket N as a comment.

## PocketBase settings (dashboard → Settings)

- **Application URL** — used to build the ticket deep links
  (`{appURL}/t/{id}`) in notification emails. Unset/localhost means emails
  render without working links.
- **Mail settings (SMTP)** — outbound email transport, plus the sender
  name/address stamped on notifications. With SMTP unconfigured PocketBase
  falls back to `sendmail`, and without that binary sends fail — failures
  are recorded per-recipient in the send log (SPA → Notifications) and
  never affect the originating write. When inbound email is enabled, set the
  **sender address to the forwarded intake mailbox** so requester replies thread
  back onto the ticket (see Inbound email above).
- **OAuth2** — optional Microsoft/Google login for the `users` (requester)
  collection; password auth works out of the box.
- **Trusted proxy headers** — when the helpdesk sits behind a reverse proxy,
  name the proxy's client-IP header (e.g. `X-Forwarded-For`) so PocketBase
  resolves the real caller. `inbound.allowed_ips` is checked against that
  resolved IP.

## First boot

The initial migration seeds one staff admin:

```
email:    admin@helpdesk.local
password: (printed to stdout exactly once)
```

Log into the SPA with it, change the password (or create a real admin and
deactivate the bootstrap account), then create customers, staff, and
requester accounts. The PocketBase dashboard (`/_`) additionally asks for
its own superuser on first visit — that account is for schema/settings
administration, separate from staff.

## Scheduled jobs

Three daily crons, all wired in `cmd/helpdesk/main.go` and staggered inside the
03:xx window. PocketBase's cron is **process-local**: if the app is down at fire
time, that night simply doesn't happen, and the next live tick picks up from
wherever things stand.

| Time | Job | What it does | Config |
|---|---|---|---|
| 03:15 | `notifications_retention` | prunes `notification_send_log` + `notification_dedupe` at 90 days (`sendLogRetentionDays`) | none |
| 03:30 | `auto_close_resolved` | promotes tickets left `resolved` past the horizon to `closed` | `auto_close_resolved_days` (`0` disables) |
| 03:45 | `maintenance_generate` | opens a `planned` ticket for every maintenance plan that has come due | none — see below |

The order is deliberate: generation runs *after* auto-close, so a
completion-anchored plan whose ticket was auto-closed at 03:30 restarts its
clock the same night rather than waiting a day.

`maintenance_generate` has **no config knob** on purpose. An install with no
plans has nothing to generate, and a single plan is paused with one toggle in
the UI — a flag would be a second way to disable the same thing. To catch up
after downtime (or to watch a plan work without waiting for 03:45):

```bash
./helpdesk maintenance-run
```

It runs the identical sweep, once, and is safe to re-run or to overlap with the
cron: each plan occurrence can only ever produce one ticket, guarded by the
ticket dedupe key.
