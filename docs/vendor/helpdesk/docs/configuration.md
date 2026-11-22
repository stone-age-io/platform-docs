---
path: helpdesk/configuration
nav_order: 60
---
# Configuration Reference

The helpdesk has two configuration surfaces, split by when they are needed:

1. **`helpdesk.yaml` plus `HELPDESK_*` environment variables.** Infrastructure
   the process needs before PocketBase is up: the data directory, NATS and its
   credentials from the platform, and the inbound-email webhook.
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

# Keep nats.creds_file current from the platform, as the helpdesk's Thing.
# Leave url empty to provide the creds file yourself. See "NATS credentials".
platform:
  url: ""                        # e.g. https://platform.example.com
  identity: ""                   # the Thing's login email
  # password: set HELPDESK_PLATFORM_PASSWORD for the first start only
  # session_file: ""             # default: platform-session.json beside the creds file
  sync_interval: 5m
  allow_insecure: false          # development only: allows an http:// url

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
| `nats.code` | string | `""` | This helpdesk's Thing code on the platform (ADR 0008). It goes into the NATS service discovery metadata as `code`. Empty skips discovery registration and changes nothing else. |
| `platform.url` | string | `""` | The platform's base URL. Set, the helpdesk keeps `nats.creds_file` current as its Thing, and `nats.creds_file` must be outside `data_dir`. Empty means you provide the creds file. See [NATS credentials](#nats-credentials). |
| `platform.identity` | string | `""` | The helpdesk Thing's login email, shown once when the Thing is provisioned. |
| `platform.password` | string | `""` | The Thing's password. Needed only until the first sync has saved a session. Set it as `HELPDESK_PLATFORM_PASSWORD`, not in the file, and remove it after the first start. |
| `platform.session_file` | string | `""` | Where the platform session is kept. Defaults to `platform-session.json` beside `nats.creds_file`. Must be outside `data_dir`. |
| `platform.sync_interval` | duration | `"5m"` | How often the platform is asked whether the credential changed. A failed sync is retried after 30s. |
| `platform.allow_insecure` | bool | `false` | Lets `platform.url` be `http://`. Development only: the first sync sends the password and receives a private key. |
| `inbound.secret` | string | `""` | Basic-auth password for the email webhook. Empty disables inbound email, and mail then arrives only via portal, agent, webhook or NATS. See [Inbound email](#inbound-email). |
| `inbound.allowed_ips` | string list | `[]` | Optional. Restricts the email webhook to the provider's egress ranges (IPs or CIDRs). |
| `inbound.reply_to` | string | `""` | Reserved. Read but **not** wired in v1. Replies thread via the PocketBase sender address. |
| `readiness.interval_seconds` | int | `30` | How often the background prober runs the readiness checks. The endpoint serves the last result, so this is how stale an answer may be, not what a probe costs. |
| `readiness.timeout_seconds` | int | `10` | Bounds one probe. The checks run concurrently, so a slow dependency cannot stall the loop or hold up the others. |
| `metrics.enabled` | bool | `true` | Registers `GET /metrics`. `false` removes the route rather than serving one that 401s. |
| `metrics.token` | string | `""` | Required as `Authorization: Bearer <token>`, or as the **password** half of Basic auth (the username is ignored). Empty leaves the endpoint open. |

### Health and metrics

`GET /api/ready` is **always on**: readiness is a contract with whatever
orchestrates this process, so there is no key to disable it. Only `/metrics`
follows `metrics.enabled`.

Both are unauthenticated by default and are deliberately *not* under
`/api/helpdesk` like this app's other routes — the ecosystem's convention is
that every binary answers at the same two paths, so a probe written for one can
be pointed at another. Restrict them with a reverse proxy, or set
`metrics.token`.

Readiness returns `503` only when a check **fails**. A `warn` is `200` on
purpose: a probe can only restart the process or take it out of rotation, and
neither of those fixes a misconfiguration. An all-`skipped` report is not
healthy either, because `skipped` means there was no answer.

The checks are `database`, `schema`, `schema_version` (which looks for a
*downgrade* — pb_data written by a newer binary — not for pending migrations),
`staff_admin`, `smtp`, `application_url`, `nats_ingest` and `inbound_email`.
The last two report `skipped` when the feature is not configured, and
`nats_ingest` warns rather than fails when the broker is unreachable, because
the portal, webhook and email intakes are all still serving. With
`platform.url` set there are two more, from the kit's keeper: `credentials`
fails until the creds file exists, and `platform` warns when the last sync
failed and never fails, since the file already held still works.

`/metrics` publishes the same readiness report as a state set
(`helpdesk_check_state{name,state}`), plus `helpdesk_ready`,
`helpdesk_build_info`, row counts per collection, tickets by status, and the
database size, and with `platform.url` set the `creds_keeper_*` series
(last sync time, sync errors, credential changes). **No series carries a customer label**, because the endpoint is
open unless a token is set and a tenant's name must not appear beside a ticket
count. Alert on `helpdesk_check_timestamp_seconds` going stale: it is the only
series that shows the prober itself is wedged, since the others keep their last
values.

::: note PocketBase's `/api/health` is a different question
It reports that the HTTP server is listening, and it is listening through
every failure the checks above look for.
:::

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

The helpdesk authenticates to the hub account as a **Thing in the operator
organization**, whose NATS identity has the `helpdesk` role from
[`contract/`](https://github.com/stone-age-io/helpdesk/blob/main/contract). The platform can keep its creds file current, or
you can provide the file.

**From the platform** (`platform.url` set). This is the way to run it: a
Regenerate or a Revoke on the platform reaches the helpdesk within one
`platform.sync_interval`, and the open connection moves to the new credential
without a restart.

1. Apply the contract to the operator organization, as an owner or admin:
   `stone apply --template contract/`. It creates the `helpdesk` Thing Type and
   NATS role.
2. Provision the helpdesk's Thing with a NATS identity on that role:
   `stone thing provision --code hd-01 --name Helpdesk --type <helpdesk type id>
   --nats-mode auto --nats-role <helpdesk role id>`. Record the email and
   password it prints once.
3. Set `platform.url`, `platform.identity` to that email, and
   `nats.creds_file` to a path **outside `data_dir`**, such as
   `pb_creds/helpdesk.creds` (`/creds/helpdesk.creds` in the container, which
   has a `/creds` volume for it). Set `nats.code` to the Thing's code.
4. Start it once with `HELPDESK_PLATFORM_PASSWORD` set. The helpdesk creates
   the directory (0700), signs in, and writes the creds file and a session
   beside it before it connects. Then remove the password: the session is
   enough from then on, and it renews itself.

Things to know:

- **A first start waits up to 30s for its first creds file.** If the platform
  is unreachable for longer, the helpdesk serves without NATS, the
  `credentials` check fails, and a restart after the platform is back
  connects. A restart that finds a creds file connects at once, even while
  the platform is down.
- **The credential directory is not in `data_dir`**, because PocketBase
  backups archive all of `data_dir`. A backup would carry the session and the
  creds file, and a restored copy would give a second host the helpdesk's
  identity. The helpdesk refuses a `nats.creds_file` or
  `platform.session_file` inside it.
- **If the host is compromised, deactivate the Thing first. A Revoke alone is
  not enough.** The helpdesk holds the Thing's platform session, so a Revoke
  hands the new credential to whoever copied it. Deactivate the Thing, set a
  new password, reactivate it, Revoke, and start once with the new password
  ([creds-keeper §7](https://github.com/stone-age-io/services/blob/main/docs/creds-keeper.md#7-a-compromised-host)).

**A file you provide** (`platform.url` empty). Export the NATS identity's
creds file from the platform and point `nats.creds_file` at it. A Regenerate
or a Revoke then means copying the new file and restarting.

Either way, on first serve the helpdesk creates `HELPDESK_EVENTS` (subjects
`helpdesk.*.cmd.tickets.>`) and begins consuming. If publish is granted, it
also creates `HELPDESK_NOTIFICATIONS` (subjects `helpdesk.*.evt.>`) for the
outbound channel. If not, that setup fails softly and email still sends. What
the role grants, and why, is in [Wire Protocol](protocol.md#1-the-whole-surface).

Setting `nats.urls` without `nats.creds_file` is a startup error, and so is
`platform.url` without `nats.urls`. A broker that is down at boot is **not**
an error: the app logs, serves, and the durable consumer resumes when
connectivity returns.

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
