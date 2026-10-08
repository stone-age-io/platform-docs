---
path: helpdesk/configuration
nav_order: 60
---
# Configuration Reference

The helpdesk has two configuration surfaces, split by when they are needed:

1. **`helpdesk.yaml` plus `HELPDESK_*` environment variables.** Infrastructure
   the process needs before PocketBase is up: the data directory, NATS, and the
   inbound-email webhook.
2. **PocketBase settings** (dashboard at `/_`, then Settings). Operator
   concerns stored in the database: SMTP, the application URL, OAuth2.

The subjects and routes these keys feed are in [Wire Protocol](protocol.md).

---

## 1. The `helpdesk.yaml` File

The helpdesk looks for its config file in this order:

1. **`$HELPDESK_CONFIG`**, an explicit path.
2. **`./helpdesk.yaml`**.
3. **`/etc/helpdesk/helpdesk.yaml`**.

The search is by name, so `helpdesk.yml`, `.json` and `.toml` are found too. A
missing file is fine, since defaults plus env cover containerized deployments.
The exception is an explicit `$HELPDESK_CONFIG` that does not exist, which is a
startup error.

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

---

## 2. Environment Variable Overrides

Every key has an environment override: prefix `HELPDESK_`, uppercase, and
`.` becomes `_`. For example, `nats.creds_file` is `HELPDESK_NATS_CREDS_FILE`.

List-valued keys (`nats.urls`, `inbound.allowed_ips`) take a
**whitespace-separated** value:

```bash
HELPDESK_INBOUND_ALLOWED_IPS="192.0.2.10 198.51.100.0/24"
```

A comma-joined value arrives as one entry. For `nats.urls` that happens to
work, because the URLs are joined again with commas for the NATS client.

::: warning A comma-joined `inbound.allowed_ips` allows every IP
The joined value is one unparseable entry, which is dropped. An allowlist
with nothing parseable left in it **allows every IP**. Separate entries with
spaces.
:::

---

## 3. Section Reference

| Key | Type | Default | Purpose |
| :--- | :--- | :--- | :--- |
| `data_dir` | string | `"pb_data"` | PocketBase data directory (SQLite database, uploads). |
| `branding.dir` | string | `""` | Host directory of `theme.css`, `logo.svg` and `branding.json` overrides. Empty uses the embedded defaults. See [Branding overlay](#branding-overlay). |
| `auto_close_resolved_days` | int | `7` | Days a ticket stays `resolved` before a daily cron closes it. Measured from `resolved_at`, so an unrelated edit while resolved does not reset the clock. The window is the grace period in which a requester reply reopens the ticket. `0` disables it, and tickets then close only when staff close them by hand. |
| `nats.urls` | string list | `[]` | The platform operator's hub, e.g. `["nats://hub.example.com:4222"]`. Empty runs without NATS, and tickets then arrive only via portal, agent or webhook. |
| `nats.creds_file` | string | `""` | The hub-account `.creds` file. Required when `nats.urls` is set. See [NATS credentials](#nats-credentials). |
| `nats.stream` | string | `"HELPDESK_EVENTS"` | The helpdesk-owned inbox stream in the hub account. |
| `nats.durable` | string | `"helpdesk-ingest"` | Durable consumer name. Stable across restarts. |
| `nats.notify_stream` | string | `"HELPDESK_NOTIFICATIONS"` | The helpdesk-owned outbound event stream. |
| `inbound.secret` | string | `""` | Basic-auth password for the email webhook. Empty disables inbound email, and mail then arrives only via portal, agent, webhook or NATS. See [Inbound email](#inbound-email). |
| `inbound.allowed_ips` | string list | `[]` | Optional. Restricts the email webhook to the provider's egress ranges (IPs or CIDRs). |
| `inbound.reply_to` | string | `""` | Reserved. Read but **not** wired in v1. Replies thread via the PocketBase sender address. |

### Branding overlay

Point `branding.dir` (env `HELPDESK_BRANDING_DIR`) at a host directory to
override the app name, logo and DaisyUI theme **without rebuilding**. The
helpdesk serves that directory's files under `/branding/*`. `index.html` links
`/branding/theme.css`, and the SPA fetches `/branding/branding.json` at boot.
Empty or unset means the embedded defaults, and the route still serves a silent
empty `theme.css` and `{}` `branding.json`, so a stock install never returns
404. Path traversal is rejected.

| File | Shape | Effect |
| :--- | :--- | :--- |
| `branding.json` | `{ "appName": "...", "logo": "logo.svg" }` | App name, and the logo file, served at `/branding/<logo>`. |
| `theme.css` | DaisyUI `[data-theme=light\|dark]` OKLCH var overrides | Recolors the UI. Loaded after the bundled CSS. Override only what you need; the rest keeps the built-in theme. |
| the logo (e.g. `logo.svg`) | an image | Replaces the built-in mark. `.brand-logo-img` is a CSS hook for per-theme swaps. |

To set it up, copy [`branding.example/`](https://github.com/stone-age-io/helpdesk/blob/main/branding.example) to the host (e.g.
`/etc/helpdesk/branding/`), add your `logo.svg`, set `appName`, and set
`branding.dir`. Its `branding.json` ships `"appName": "Service Desk"`, and any
`appName` counts as an operator choice. Left as it is, it also replaces the
portal's stock "Support".

**Where `appName` lands.** Each shell has its own stock wordmark: the staff and
field apps say "Service Desk", and the requester portal says "Support". An
`appName` **replaces** all of them, so a branded install never shows the
operator's logo next to the stock name. It also sets the browser tab title and
the sign-in card, the first screen anyone sees. Long names truncate rather than
overflow the card. The `<title>` in `index.html` is only the pre-JavaScript
fallback; the SPA overwrites it before mount.

Two things are not brandable: the PWA manifest (a static file, so an overlay
cannot rename the installed app) and outbound email templates (edit those in
the SPA under **Notifications**).

### NATS credentials

The helpdesk authenticates to the hub account with a **platform-minted
`nats_user`** scoped to `sub helpdesk.>`, exported as a `.creds` file:

1. In the platform, create a hub-account `nats_user` with subscribe permission
   on `helpdesk.>`. To also emit outbound notification events, grant
   `pub helpdesk.>` and stream management for `HELPDESK_NOTIFICATIONS`. The
   helpdesk is otherwise unaware of the grant.
2. Export its creds file, and point `nats.creds_file` at it.
3. Start the helpdesk. On first serve it creates `HELPDESK_EVENTS` (subjects
   `helpdesk.*.tickets.>`) and begins consuming. If publish is granted, it also
   creates `HELPDESK_NOTIFICATIONS` (subjects `helpdesk.*.events.>`) for the
   outbound channel. If not, that setup fails softly and email still sends.

Setting `nats.urls` without `nats.creds_file` is a startup error. A broker that
is down at boot is **not** an error: the app logs, serves, and the durable
consumer resumes when connectivity returns.

**Per-customer mapping.** Set `customers.code` (SPA, customer detail) to the
customer's platform organization **code**. It is the tenant token on subject
token 2 (ADR 0002; migration `1828000000`). `platform_org_id` is not consulted
for routing. Events for unmapped codes are logged and dropped (acked). The same
code names the customer on outbound notification subjects, and a customer
without one has its NATS notification events skipped (see
[Notifications](notifications.md)).

### Inbound email

An email-parsing provider (Postmark to start) receives mail, parses the MIME,
and posts clean JSON to `POST /api/helpdesk/inbound/email/postmark`. The route
is registered only when `inbound.secret` is set.

- **Authentication.** The provider sends that secret with HTTP Basic auth on
  the webhook URL. The password is checked; the username is ignored.
- **IP allowlist.** `inbound.allowed_ips` can also pin the caller to the
  provider's published egress ranges, as bare IPs or CIDRs. It is checked
  before the secret, against PocketBase's resolved client IP.
- **No mailbox credentials.** The helpdesk holds only this webhook secret.

::: warning Behind a reverse proxy, set PocketBase's trusted-proxy headers
Otherwise every request appears to come from the proxy, and the allowlist
matches the proxy's IP instead of the provider's. See
[PocketBase Settings](#4-pocketbase-settings).
:::

[Email Ingestion](email-ingestion.md) covers routing and threading in full. The
operator essentials:

- **Forward** your public address (e.g. `support@…`) into the provider's
  inbound address. For customers who email from their own domain, set
  `customers.email_domain` (Directory, then customer) so cold senders resolve
  to the right tenant. A sender the helpdesk cannot attribute to a known
  customer is rejected (acked, not queued). There is no catch-all.
- **Threading** uses the `[#N]` token already in every notification subject.
  So the PocketBase **sender address must be that same forwarded intake
  mailbox**. A reply then returns there and lands on ticket N as a comment.

---

## 4. PocketBase Settings

Set these in the dashboard (`/_`, then Settings):

| Setting | What it does |
| :--- | :--- |
| **Application URL** | Builds the ticket deep links (`{appURL}/t/{id}`) in notification emails. Unset or localhost means emails render without working links. |
| **Mail settings (SMTP)** | Outbound email transport, plus the sender name and address stamped on notifications. With SMTP unconfigured, PocketBase falls back to `sendmail`, and without that binary sends fail. Failures are recorded per recipient in the send log (SPA, Notifications) and never affect the originating write. When inbound email is enabled, set the **sender address to the forwarded intake mailbox** so requester replies thread back onto the ticket ([Inbound email](#inbound-email)). |
| **OAuth2** | Optional Microsoft or Google login for the `users` (requester) collection. Password auth works out of the box. |
| **Trusted proxy headers** | When the helpdesk sits behind a reverse proxy, name the proxy's client-IP header (e.g. `X-Forwarded-For`) so PocketBase resolves the real caller. `inbound.allowed_ips` is checked against that resolved IP. |

---

## 5. First Boot

The initial migration seeds one staff admin:

```
email:    admin@helpdesk.local
password: (printed to stdout exactly once)
```

Sign in to the SPA with it and change the password, or create a real admin and
deactivate the bootstrap account. Then create customers, staff and requester
accounts.

::: note The PocketBase dashboard has its own superuser
On first visit, `/_` asks you to create a superuser. That account is for
schema and settings administration, separate from staff.
:::

---

## 6. Scheduled Jobs

Three daily crons, all wired in `cmd/helpdesk/main.go` and staggered inside the
03:xx window:

| Time | Job | What it does | Config |
| :--- | :--- | :--- | :--- |
| 03:15 | `notifications_retention` | Prunes `notification_send_log` and `notification_dedupe` at 90 days (`sendLogRetentionDays`). | none |
| 03:30 | `auto_close_resolved` | Promotes tickets left `resolved` past the horizon to `closed`. | `auto_close_resolved_days` (`0` disables) |
| 03:45 | `maintenance_generate` | Opens a `planned` ticket for every maintenance plan that has come due. | none; see below |

::: note The cron is process-local
If the app is down at fire time, that night's run does not happen. The next
live tick picks up from wherever things stand.
:::

Generation runs *after* auto-close, so a completion-anchored plan whose ticket
was auto-closed at 03:30 restarts its clock the same night rather than waiting
a day.

`maintenance_generate` has **no config key**. An install with no plans has
nothing to generate, and you pause a single plan with one toggle in the UI, so
a flag would be a second way to disable the same thing. To catch up after
downtime, or to watch a plan work without waiting for 03:45:

```bash
./helpdesk maintenance-run
```

It runs the same sweep once. It is safe to re-run or to overlap with the cron:
the ticket dedupe key ensures each plan occurrence produces at most one ticket.

---

## 7. Where to Go Next

- Subjects, payloads and webhook routes these keys feed: [Wire Protocol](protocol.md)
- Notification templates, recipients and the send log: [Notifications](notifications.md)
- Forwarding, threading and sender resolution: [Email Ingestion](email-ingestion.md)
- Collections, roles and maintenance plans: [Data Model & Access Rules](data-model.md)
- How the pieces fit together: [Overview](overview.md)
