---
path: access-control/configuration
nav_order: 40
---
# Configuration Reference

Both binaries, `accessd` and `access-controller`, share one config schema
([`config/config.go`](https://github.com/stone-age-io/access-control/blob/main/config/config.go)), loaded by Viper. This page lists
every key, its default and its env var. For what the wire-level keys mean
(`subjects.app`, the bucket and stream names), see
[Wire Protocol](protocol.md).

Start from the annotated example configs, then use the tables here to look up a
default or env var:

- [`config/accessd.yaml`](https://github.com/stone-age-io/access-control/blob/main/config/accessd.yaml): the central app.
- [`config/controller.yaml`](https://github.com/stone-age-io/access-control/blob/main/config/controller.yaml): an edge controller.

What each binary does with its config is on its own page:
[Central Service (accessd)](accessd.md) and
[Edge Controller (access-controller)](controller.md).

---

## 1. How Config Loads

- **File path.** `accessd` reads `$SA_CONFIG` (default `config/accessd.yaml`).
  `access-controller` uses its `-config` flag (default
  `config/controller.yaml`). In a checkout those defaults are the annotated
  examples, which name a `credsFile` that must exist (§12), so point
  `SA_CONFIG` or `-config` at your own copy (`config/local*.yaml` is
  gitignored).
- **A missing file is fine.** Defaults and env vars still apply. Nothing has to
  exist on disk.
- **Every key has an `SA_`-prefixed env var.** Take the dotted key, uppercase
  it, and replace dots with underscores: `nats.urls` → `SA_NATS_URLS`,
  `controller.heartbeatInterval` → `SA_CONTROLLER_HEARTBEATINTERVAL`,
  `nats.tls.enable` → `SA_NATS_TLS_ENABLE`. Env wins over the file.
- **Defaults fill only absent keys.** `setDefaults` runs *before* the file is
  decoded, so a key written with a zero or empty value is taken literally:
  `maxReconnects: 0` means never reconnect, `auditRetentionDays: 0` means never
  prune, and `logging.level: ""` fails validation. Omit a key to get its
  default.
- **Parsing.** Durations are Go duration strings (`250ms`, `15s`, `45s`).
  `nats.urls` accepts a comma-separated list through the env var.

The PocketBase HTTP address is **not** a config key. PocketBase's own
`serve --http` flag owns it (default `127.0.0.1:8090`).

---

## 2. NATS Connection

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `nats.urls` | `nats://localhost:4222` | `SA_NATS_URLS` | One or more URLs; comma-separated in the env var. Use the `tls://` scheme for TLS. |
| `nats.maxReconnects` | `-1` (forever) | `SA_NATS_MAXRECONNECTS` | An *absent* key defaults to `-1`. An explicit `0` is passed through (no reconnects). The KV watcher re-arms on every reconnect. |
| `nats.reconnectWait` | `250ms` | `SA_NATS_RECONNECTWAIT` | Backoff between reconnect attempts. |

### Auth (set at most one)

Setting more than one method fails validation. Setting none is allowed (an open
dev box). A `.creds` file is the recommended choice for a backend service.

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `nats.credsFile` | `""` | `SA_NATS_CREDSFILE` | JWT + nkey `.creds` file. **Must exist** if set, unless `platform.url` is set, when the platform writes it ([§2.1](#21-credentials-from-the-platform)). |
| `nats.nkeySeedFile` | `""` | `SA_NATS_NKEYSEEDFILE` | Raw nkey seed file. |
| `nats.token` | `""` | `SA_NATS_TOKEN` | Bearer token. |
| `nats.username` | `""` | `SA_NATS_USERNAME` | Used with `password`. |
| `nats.password` | `""` | `SA_NATS_PASSWORD` | Used with `username`. |

::: warning Never commit credentials
`*.creds` is gitignored. Keep credentials out of any file you commit.
:::

::: note Service discovery needs `$SRV.>`
Both binaries register for NATS service discovery
([Wire Protocol](protocol.md#service-discovery)). Give each binary's
credential subscribe on `$SRV.>` and a way to reply: publish on `_INBOX.>`,
or `allow_responses: true`. Without them, discovery is refused for that
process and nothing else changes. nats.go prints the refusal to stderr.
A controller's [health endpoint](protocol.md#controller-health) also needs
subscribe on `acc.{location}.cmd.ctrl.{code}.health`, with the same way to reply.
:::

### 2.1 Credentials from the platform

Set `platform.url` and the binary keeps `nats.credsFile` current itself, as
its own Thing on the platform (ADR 0009 in platform-docs). It signs in with the
kit's `credskeeper`, writes the creds file, and rewrites it after a Regenerate
or a Revoke. The open connection moves to the new file on its next reconnect,
without a restart. accessd and each controller are separate Things, each with
its own identity and role from [`contract/`](https://github.com/stone-age-io/access-control/blob/main/contract).

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `platform.url` | `""` | `SA_PLATFORM_URL` | The platform's base URL. Empty starts nothing, and `nats.credsFile` is a file you provide. |
| `platform.identity` | `""` | `SA_PLATFORM_IDENTITY` | This binary's Thing login email, printed once when the Thing is provisioned. |
| `platform.password` | `""` | `SA_PLATFORM_PASSWORD` | The Thing's password. Needed only until the first sync has saved a session. Set it by env var, not in the file, and remove it after the first start. |
| `platform.sessionFile` | `""` | `SA_PLATFORM_SESSIONFILE` | Defaults to `platform-session.json` beside `nats.credsFile`. |
| `platform.syncInterval` | `5m` | `SA_PLATFORM_SYNCINTERVAL` | How often the platform is asked for a change. A failed sync is retried after 30s. |
| `platform.allowInsecure` | `false` | `SA_PLATFORM_ALLOWINSECURE` | Lets `platform.url` be `http://`. Development only: the first sync sends the password and receives a private key. |

To set it up:

1. Apply the contract to the organization, as an owner or admin:
   `stone apply --template contract/`.
2. Provision a Thing for accessd on the `accessd` Thing Type and NATS role,
   and one per controller on `access-controller`:
   `stone thing provision --code ctrl-hq-1 --name "HQ controller 1" --type <type id> --nats-mode auto --nats-role <role id>`.
   Record the email and password it prints once.
3. Set `platform.url`, `platform.identity` and `nats.credsFile`, and start
   once with `SA_PLATFORM_PASSWORD`. The binary creates the directory
   (0700), writes the creds file and a session beside it, then connects.

What to know:

- **Keep the files on persistent storage.** The session is what lets the
  password go, and the creds file is what lets a restart connect while the
  platform is down.
- **accessd's files go outside `accessd.dataDir`**, such as `pb_creds/`.
  PocketBase backups archive the whole data directory, and a restored copy
  would give a second host accessd's identity. accessd refuses a path inside
  it.
- **A first start waits for its first file.** accessd waits up to 30s and then
  exits, naming the reason, as it does for NATS. A controller waits as long
  as it takes ([Edge Controller](controller.md#what-stops-it-at-boot)). A
  restart that finds a file goes on at once.
- **accessd's readiness gains `credentials` and `platform`**, and both
  binaries' metrics gain `creds_keeper_*` (last sync, sync errors, credential
  changes).
- **A controller needs the platform's HTTPS as well as NATS.** At a site behind
  a leaf node, that is a second route out.
- **If a host is compromised, deactivate its Thing first. A Revoke alone is
  not enough.** The binary holds the Thing's platform session, so a Revoke
  hands the new credential to whoever copied it. Deactivate the Thing, set a
  new password, reactivate it, Revoke, and start once with the new password
  ([creds-keeper §7](https://github.com/stone-age-io/services/blob/main/docs/creds-keeper.md#7-a-compromised-host)).

### TLS

You do not need this section when the URL is `tls://` and the server presents a
publicly trusted cert. Enable it for mutual TLS or a custom CA. The file and
`insecure` keys take effect **only with `enable: true`**: a `caFile` set without
it is ignored.

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `nats.tls.enable` | `false` | `SA_NATS_TLS_ENABLE` | |
| `nats.tls.caFile` | `""` | `SA_NATS_TLS_CAFILE` | Custom CA to verify the server. |
| `nats.tls.certFile` | `""` | `SA_NATS_TLS_CERTFILE` | Client cert (mutual TLS). Set it **with** `keyFile`. |
| `nats.tls.keyFile` | `""` | `SA_NATS_TLS_KEYFILE` | Set it **with** `certFile`. |
| `nats.tls.insecure` | `false` | `SA_NATS_TLS_INSECURE` | Skip server verification. **Never** in production. |

---

## 3. Logging

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `logging.level` | `info` | `SA_LOGGING_LEVEL` | `debug`, `info`, `warn` or `error`. |
| `logging.encoding` | `json` | `SA_LOGGING_ENCODING` | `json` or `console`. |
| `logging.outputPath` | `stdout` | `SA_LOGGING_OUTPUTPATH` | |

---

## 4. Metrics

A Prometheus endpoint. **accessd** serves `GET /metrics` on its own PocketBase
listener, beside `GET /api/ready`, and ignores `metrics.address` and
`metrics.path`. **The controller** serves it on a side listener at
`metrics.address` (`:2114` in the example config).

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `metrics.enabled` | `false` | `SA_METRICS_ENABLED` | The example configs set `true`. |
| `metrics.address` | `:2113` | `SA_METRICS_ADDRESS` | Controller only. The controller example uses `:2114`. |
| `metrics.path` | `/metrics` | `SA_METRICS_PATH` | Controller only. |
| `metrics.token` | `""` | `SA_METRICS_TOKEN` | accessd only. When set, `GET /metrics` needs it as a Bearer token or a Basic password. |
| `metrics.updateInterval` | `15s` | `SA_METRICS_UPDATEINTERVAL` | Duration string. |

---

## 5. Diagnostics

An **opt-in, read-only** local status page for field install and
troubleshooting. Only `access-controller` serves it; accessd ignores this
section. When enabled, it serves these on `diagnostics.address`:

- `/status`: a self-contained HTML page (inline CSS and a few lines of inline JS
  that refresh it in place, with pause and refresh controls). It loads no
  external assets, so it works with no network.
- `/status.json`.
- `/`, which redirects to `/status`.

What the page shows, the JSON shape and how to read it in the field are in
[Edge Controller §5](controller.md#5-the-local-status-page).

It shows this box's live in-memory state: identity (including `subjects.app`),
NATS and policy-sync health, the portals it bound and their door and posture
state, aux inputs and outputs, fire-input suppression state, recent decisions
(with the decoded credential), and recent alarms.

The page is strictly **read-only**. All control stays on the NATS command
plane. It runs its own server and port, separate from `metrics`, so you can
scrape metrics on a monitoring network while diagnostics stays local.

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `diagnostics.enabled` | `false` | `SA_DIAGNOSTICS_ENABLED` | Controller only. |
| `diagnostics.address` | `127.0.0.1:2115` | `SA_DIAGNOSTICS_ADDRESS` | Keep it local unless you mean to expose it. |

::: warning The page reveals topology
It shows portal codes, locations and reader addresses, so it is disabled by
default and binds localhost by default. Reach it over SSH or a tunnel rather
than binding a public interface.
:::

---

## 6. Resource Names

These name the NATS resources the fleet talks over. See
[Wire Protocol](protocol.md) for what each carries.

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `policy.bucket` | `ACC_POLICY` | `SA_POLICY_BUCKET` | KV bucket: the downward policy mirror. Both binaries read it. |
| `status.bucket` | `ACC_STATUS` | `SA_STATUS_BUCKET` | KV bucket: the upward device shadow. Both binaries read it. |
| `events.stream` | `ACC_EVENTS` | `SA_EVENTS_STREAM` | JetStream audit stream. accessd creates and consumes it. Its subjects come from `subjects.app` and are not set here. |
| `subjects.app` | `acc` | `SA_SUBJECTS_APP` | The app token every subject leads with. Must be a single NATS token (no `.`, `*`, `>` or whitespace). |

::: warning These must match across the fleet
accessd and every controller must use the same values. A mismatch silently
severs the data plane.
:::

---

## 7. accessd

Keys only the central service reads. What it runs with them is in
[Central Service (accessd)](accessd.md).

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `accessd.dataDir` | `./pb_data` | `SA_ACCESSD_DATADIR` | The embedded PocketBase data dir (database and uploads). Created at runtime and gitignored. The UI is `//go:embed`-ed, so there is no `pb_public`. |
| `accessd.code` | `""` | `SA_ACCESSD_CODE` | accessd's Thing code on the platform (ADR 0008). It goes into the NATS service discovery metadata as `code`, which is how the console finds the running process. Empty skips discovery registration. A controller's Thing code is its `controller.code`. |
| `accessd.controllerOfflineAfter` | `45s` | `SA_ACCESSD_CONTROLLEROFFLINEAFTER` | How long a controller can be silent before it shows offline. Keep it a few controller `heartbeatInterval`s, so one dropped heartbeat does not flap a box offline. |
| `accessd.auditRetentionDays` | `365` | `SA_ACCESSD_AUDITRETENTIONDAYS` | How long control-plane audit rows (`audit_logs`, written by `internal/changelog`) are kept before a daily 03:00 prune deletes them. Absent means 365. An explicit `0` or a **negative** value turns off pruning (keep forever). See [Operators & Authorization](operators.md#8-control-plane-audit-log-audit_logs). |
| `accessd.eventRetentionDays` | `0` | `SA_ACCESSD_EVENTRETENTIONDAYS` | How long door-activity rows (`events`, the rebuildable projection of the `ACC_EVENTS` JetStream stream) are kept before a daily 03:00 prune deletes them. **`0` (the default) or any negative value keeps them forever.** Pruning is opt-in, so an upgrade never silently deletes event history. A positive day count trims the projection. JetStream stays the system of record, so a prune only shrinks the read model. |
| `accessd.webhookURL` | `""` | `SA_ACCESSD_WEBHOOKURL` | When set, turns on the outbound webhook sink ([`internal/webhook`](https://github.com/stone-age-io/access-control/blob/main/internal/webhook)): a fourth durable on `ACC_EVENTS` that POSTs every pageable event as JSON to this URL, so an install can feed its own PagerDuty, Slack, ntfy or ITSM instead of relying on email. Empty leaves it inert. See [Notifications](#8-notifications). |

---

## 8. Notifications

The alarm notification sink ([`internal/notify`](https://github.com/stone-age-io/access-control/blob/main/internal/notify)) is a
second, independent durable consumer on `ACC_EVENTS` that emails on `alarm` and
`fire`. **It has no config.** Like the disarm sink, it always starts and is
driven by data, so the "who" and "which" are managed in the UI and changing
them never needs a redeploy. There is no `notify.*` config block and no
`SA_NOTIFY_*` env var.

### Email opt-ins

The sink sends nothing until **two opt-ins** line up: a source flag and at
least one `users.notify` operator. Either one alone sends nothing.

| Opt-in | Where (UI) | Effect |
|---|---|---|
| `users.notify` | Operators → Notify | The operator receives alarm email. |
| `users.notify_locations` | Operators → Notify locations | Scopes the operator to specific locations (empty = all locations). |
| `users.notify_types` | Operators → Notify types | Scopes the operator to specific event kinds (empty = the default set). |
| `portals.notify_on_alarm` | Portal → Area & intrusion → Email on alarm (or bulk-select on the Portals list) | Emails the recipients on this door's forced and held-open (and `no_entry`) alarms. |
| `areas.notify_on_alarm` | Area → Email on intrusion | Emails the recipients on this area's intrusion alarms. |
| `locations.notify_fire` | Location → Email on fire input | Emails the recipients on this location's fire-input alarms. |
| `controllers.notify_offline` | Controller → Notify on offline | Emails the recipients when this box stops reporting. |

**Recipients are scoped by location.** An alarm at a location emails only the
notify operators whose `notify_locations` is empty (all locations) or contains
that location. A multi-site deployment can page site-local operators without a
per-source routing matrix.

**Recipients are also scoped by type** (`users.notify_types`). An empty
selection means the **default set**: `forced`, `held`, `intrusion`, `fire` and
`controller_offline`. It does not mean everything. `no_entry` (a grant nobody
walked through) is diagnostic, so you must select it explicitly. Leave the
selection empty for most operators, because a future urgent type then reaches
them automatically. Selecting types freezes the set to exactly those. The
auto-clear of a held-open door (`held_clear`) is never emailed, and a controller
coming back *online* is not paged.

**Deep links.** Each message links to the exact event
(`{AppURL}/alarms?seq=…`). The base is PocketBase's **Application URL**
(`/_` → Settings → Application), the same value its own password-reset mail
uses, so there is no separate key here. If it is unset, messages carry no link.

**Reminders.** An urgent alarm still unacknowledged after 15 minutes is sent
again, at most twice ([`internal/repage`](https://github.com/stone-age-io/access-control/blob/main/internal/repage)). It uses the
same opt-ins, so a reminder never reaches anyone the original could not, and it
never covers `held` or `no_entry`. No config.

::: note SMTP lives in PocketBase, not here
Set the mail transport (host, port, credentials, sender) in the PocketBase
admin UI at `/_` ("Mail settings"). The sink's `From` is PocketBase's
configured sender. The sink uses `DeliverNew` (it starts from "now" and never
replays historical alarms) with bounded redelivery, so a dead SMTP server
cannot loop forever.
:::

### Webhook sink

`accessd.webhookURL` is the one notification key that *is* config. A fourth
durable POSTs each pageable event as structured JSON to that URL. It shares the
email sink's classification, so email and webhook never disagree about what is
worth forwarding. It **ignores the per-source and per-operator email
opt-ins**: those decide who gets *mail*, and a webhook has one destination
whose purpose is to receive the feed. Setting the URL is the opt-in. Like the
email sink, it is a `DeliverNew` durable (a newly set URL is not flooded with
history), and a failed POST is `Nak`ed for bounded JetStream redelivery.

To customise notifications, use the webhook: send the structured event to a
tool that already routes, escalates and acknowledges. The email body is fixed
and terse, for reading on a phone.

The URL is config and not a UI field because accessd POSTs wherever it points,
from inside the deployment's network (a modest SSRF surface). Deploy-time
config means there is no API to abuse, and it matches how SMTP, the other
outbound transport, is administered. The sink never follows redirects and has a
hard 10s timeout.

### Sinks and routes with no config

- **Entry-disarm.** The disarm sink ([`internal/disarm`](https://github.com/stone-age-io/access-control/blob/main/internal/disarm))
  disarms an area on a valid grant at a `disarm_on_grant` portal. It always
  starts and needs no settings. It is inert unless a portal opts in (set
  `disarm_on_grant` and an `area` on the portal in the UI). Like notify, it is a
  `DeliverNew` durable on `ACC_EVENTS`.
- **The badge tier.** The badge routes ([`internal/badgeapi`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi))
  and the visitor-credential sweep
  ([`internal/badgesweep`](https://github.com/stone-age-io/access-control/blob/main/internal/badgesweep)) always start and need no
  settings. They are inert until an operator ticks **Badge login** on a
  cardholder, and remote unlock also needs a door to opt in through
  `allow_remote_unlock` (default off). The configurable parts live in
  PocketBase settings, not here: SMTP, OAuth2 providers, and the
  [rate limits](#9-rate-limits).

::: note SMTP is optional, but it decides which sign-in methods work
One-time codes and the forgot-password link are both emails. With no mail
server, the only ways into a badge are a **password an operator sets in
person** (on the cardholder form for a staff holder, Cardholder → Badge login,
or in the **Initial password** field on the visitor mint form) or an OAuth2
provider. Neither is ever emailed. So the badge tier, visitors included, works
with no mail server. You lose self-service (a holder cannot recover their own
password) and the invite mail, whose content an operator can say out loud.
The mint screen shows the badge link and a QR of it for that handover. See
[Operators & Authorization](operators.md#sign-in-methods).
:::

---

## 9. Rate Limits

Migrations [`1750000032`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000032_badge_rate_limits.go),
[`1750000039`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000039_remote_area_output.go) and
[`1750000041`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000041_badge_floorplan.go) ship default
PocketBase rate limits for the badge routes. They are the first routes that
someone who is not an operator can reach, and an unconfigured limiter is wide
open. Defaults, per client:

| Rule | Limit | Why that number |
|---|---|---|
| `POST /api/badge/unlock/` | 10/min | It opens a door. |
| `POST /api/badge/areas/` (arm + disarm) | 6/min | Lower, because disarming turns intrusion detection off. |
| `POST /api/badge/outputs/` | 10/min | Momentary, like an unlock. |
| `GET /api/badge/me` | 60/min | A page load. |
| `GET /api/badge/live` | 60/min | A page load, but it walks the whole grant set. |
| `cardholders:requestOTP` | 5/min | Sends an email per call, so it is a mail-bomb *and* an SMTP-quota vector. |
| `cardholders:authWithPassword` | 10/min | Credential stuffing. |
| `cardholders:requestPasswordReset` | 3/min | Also an email per call. |
| `POST /api/badge/password` | 5/min | It checks the current password, so it is an oracle for guessing it from a stolen session. |

Change them in the PocketBase admin under **Settings → Rate limits**.

`1750000032` also switches the limiter on, which brings PocketBase's own
default rules into force for every other route (unless an install has already
changed them): for example `*:auth` at 2 per 3s, `*:create` at 20 per 5s and
`/api/` at 300 per 10s.

`GET /api/badge/preview/{id}` has no rule of its own. It is operator-only
(`enroll`), so it sits behind the same trust boundary as every other operator
route, and like them it falls under only those PocketBase defaults. It is
audited instead. See
[Operators & Authorization](operators.md#seeing-a-holders-badge-apibadgepreview).

::: warning Behind a reverse proxy, set `TrustedProxy`
PocketBase's limiter keys on client IP. Unless the proxy is configured in
**Settings → Application**, every request appears to come from the proxy and
shares one bucket, so one visitor's retries rate-limit the whole building.
The audit log's `request_ip` depends on the same setting.
:::

---

## 10. Branding

accessd only. Point `branding.dir` at a host directory to override the embedded
app name, logo and DaisyUI theme **without rebuilding the binary**. accessd
serves that directory's files under `/branding/*`. The UI's `index.html`
`<link>`s `/branding/theme.css`, and the app fetches `/branding/branding.json`
at boot.

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `branding.dir` | `""` (embedded defaults) | `SA_BRANDING_DIR` | Host directory holding any of `theme.css`, `logo.svg`, `branding.json`. Empty means no overlay; the route still serves an empty `theme.css` and a `{}` `branding.json`, so a stock install never 404s. A path that is missing or not a directory logs a warning and falls back to the same defaults (not a startup error). Path traversal (`..`) is rejected. |

Overlay files (all optional):

| File | Shape | Effect |
|---|---|---|
| `branding.json` | `{ "appName": "...", "logo": "logo.svg" }` | Sets the sidebar and login app name and the browser tab title, and names the logo file (served at `/branding/<logo>`). |
| `theme.css` | DaisyUI `[data-theme=light\|dark]` OKLCH var overrides | Recolors the whole UI. It loads after the bundled CSS, so it wins by cascade order. Override only what you need. |
| the logo (for example `logo.svg`) | an image | Replaces the built-in mark. `.brand-logo-img` is a CSS hook for per-theme logo swaps. |

Copy [`branding.example/`](https://github.com/stone-age-io/access-control/blob/main/branding.example) to the host (for example
`/etc/stone-access/branding/`), add your `logo.svg`, and set `branding.dir`:

```yaml
branding:
  dir: "/etc/stone-access/branding"
```

---

## 11. Controller

A controller's config is only its identity and hardware selection. **Which
portals it drives, and their relay and input bindings, live in policy, not
here**, matched by `controller.code`. What the box does at boot and offline is
in [Edge Controller (access-controller)](controller.md).

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `controller.code` | `""` | `SA_CONTROLLER_CODE` | Matches a `controllers` record. The box arms every portal whose `controller` relation points at this code. |
| `controller.location` | `""` | `SA_CONTROLLER_LOCATION` | Location code. Selects the timezone and scopes the command and fire subscriptions. |
| `controller.heartbeatInterval` | `15s` | `SA_CONTROLLER_HEARTBEATINTERVAL` | Liveness cadence to `acc.{location}.heartbeat.ctrl.{code}`. |
| `controller.driver` | `mock` | `SA_CONTROLLER_DRIVER` | `mock` (simulated, no I/O, no door monitoring) or `gpio` (real relays and DPS/REX; Linux only). Under `gpio`, the `model` picks the physical transport: native GPIO char device or an MCP23017 I2C expander. |
| `controller.model` | `""` | `SA_CONTROLLER_MODEL` | Hardware profile. It maps a portal's logical relay and input indices to physical lines, selects the lock and input transport (native GPIO char device or MCP23017 over I2C), **and** provides the OSDP RS485 serial port: `kincony-server-mini` (CM4, GPIO, `/dev/ttyAMA0`) or `kincony-pi5r8` (CM5, I2C, `/dev/ttyAMA2`). **Required when `driver: gpio`, `reader: osdp` or `reader: both`.** Must match the `controllers` record. |
| `controller.reader` | `nats` | `SA_CONTROLLER_READER` | Credential reader: `nats` (simulated taps published to `acc.{location}.tap.{type}.{thing}`, for dev), `osdp` (a real OSDP reader on the model's RS485 bus, clear-text in v1), or `both` (NATS for every portal **plus** OSDP for portals that have a reader). Independent of `driver`; the lock and door stay on GPIO or I2C. **`osdp` and `both` require `model`.** A portal opts into OSDP through its `reader_address`: `>= 0` means an OSDP reader at that PD address, `-1` means NATS-only. Tap events carry a `source` (`nats` or `osdp`). |

### Offline config cache

Controller only. By default a controller is a stateless projection of NATS KV.
After a reboot it syncs the policy graph from the hub again and boots
**default-deny** until the sync lands. That fails secure, but a box that
reboots while NATS is unreachable (leaf node down, or no network) cannot decide
anything until the link returns. The optional offline cache fixes that: it
saves the last policy graph delivered over KV to a local file and, on boot,
decides from it while the connection is down.

Without the cache the box is not quite stateless: it always writes the
[bindings snapshot](#bindings-snapshot), so it can arm its doors at boot and
hold a maglock locked. That snapshot decides nothing. The cache is still the
only way a box admits anyone before NATS returns.

A controller **never treats a missing NATS at startup as fatal**, with or
without the cache. It connects with retry-on-failed-connect, binds the KV
buckets lazily and retries in the background, comes up default-deny, and
converges when NATS returns. (accessd is the opposite: it fails fast when its
NATS is unreachable.) The cache makes that offline boot useful: the box comes
up on last-known policy instead of default-deny.

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `policy.cache.enabled` | `false` | `SA_POLICY_CACHE_ENABLED` | Opt in to the offline cache. Off means the default-deny-until-sync boot, with portals armed from the bindings snapshot if there is one. |
| `policy.cache.path` | `./data/policy-cache.json` | `SA_POLICY_CACHE_PATH` | Snapshot file. Written `0600` (it holds credential values), parent dir created `0700`, atomic (temp file + rename). |
| `policy.cache.maxAge` | `72h` | `SA_POLICY_CACHE_MAXAGE` | Staleness bound. On boot, a snapshot older than this is **refused** and the box falls back to default-deny, so a credential revoked during a long outage cannot keep working off a stale cache. Set a large value (for example `8760h`) to turn the check off in practice. An explicit `0` refuses every snapshot; omit the key for the default. |

How the cache behaves:

- **Fail-secure.** A missing, unreadable, corrupt or too-old snapshot loads
  nothing. The box behaves as if the cache were disabled.
- **Live KV always wins.** When a sync lands, fresh policy overwrites the
  cache. The snapshot is written only from a completed live sync, never from
  the partial view during boot re-delivery and never while offline.
- **Freshness tracks connectivity.** While connected, the snapshot's timestamp
  is refreshed periodically, so `maxAge` measures staleness from the last time
  the box had contact with the hub, not from the last policy edit.
- **Scope.** Only the decision inputs are cached. Command posture overrides are
  not (a reboot safely reverts them), door state is read again from hardware,
  and the upward status shadow is not published while offline (nothing is
  watching it).

::: note The `/status` page shows a box running on cache
It shows an `OFFLINE · cached config` badge and the snapshot's age, so you
cannot mistake it for a freshly synced box. The staleness bound is checked
**only at boot**: a box already running on cache keeps running until NATS
returns.
:::

### Bindings snapshot

Controller only, and always on. After every live sync the controller writes
this box's portal hardware bindings to a local file: only its own `portal.*`
records, each cut down to `code`, `type`, `location`, `controller`,
`lockRelay`, `lockType`, `dpsInput`, `rexInput`, `dpsContact`, `rexContact`
and `readerAddress`. No posture, schedule, credential, user, group or area.

| Key | Default | Env var | Purpose |
|---|---|---|---|
| `policy.bindings.path` | `./data/bindings.json` | `SA_POLICY_BINDINGS_PATH` | Snapshot file. Written `0600`, parent dir created `0700`, atomic (temp file + rename), and only when the bindings change. |

On a boot where the offline cache is off, missing, corrupt or too old, the box
loads this file before anything arms, and the portal manager arms those
portals. Arming drives each lock relay to idle, so a maglock is **locked** and
a strike unpowered from boot rather than from the first sync. Every tap denies
(`deny_point_disabled`, no posture), and `cmd.posture` and `cmd.grant` are
refused until policy syncs. A fresh offline cache wins: the box loads one or
the other, never both. A missing or corrupt bindings file loads nothing. There
is no `maxAge`, because the file grants nothing. See
[Bindings snapshot](controller.md#34-bindings-snapshot).

---

## 12. What Gets Rejected

`Load` returns an error, and the binary refuses to start, only in these cases.
Everything else falls back to a default:

- The config file exists but cannot be parsed (malformed YAML).
- A value cannot be decoded into its type, for example a duration key like
  `heartbeatInterval: soon` (`failed to unmarshal config`).
- No NATS URL is configured (only possible with an explicit empty `urls` list).
- More than one NATS auth method is set.
- `nats.credsFile` is set but the file does not exist, and `platform.url` is
  not set.
- `platform.url` is set without `nats.credsFile`, or `platform.syncInterval`
  is negative.
- `nats.tls.enable` is true with only one of `certFile` and `keyFile`.
- `logging.level` is not one of `debug`, `info`, `warn`, `error`.
- `metrics.updateInterval` is not a parseable duration.
- `policy.bucket` or `status.bucket` is empty.
- `subjects.app` is empty or not a single NATS token.
- `controller.driver` is not `mock` or `gpio`, or is `gpio` with no
  `controller.model`.
- `controller.reader` is not `nats`, `osdp` or `both`, or is `osdp` or `both`
  with no `controller.model`.

Some values pass `Load` and fail **later, at startup**:

- `logging.encoding` other than `json` or `console`, or a `logging.outputPath`
  that cannot be opened (logger construction).
- An unreadable `nats.nkeySeedFile`, or a TLS `certFile`/`keyFile` pair that
  will not load (NATS options are built at connect).
- `controller.model` naming no known profile when the driver or reader needs
  one (`unknown controller model`, listing the known ones).
- accessd only: NATS unreachable at `serve`. The controller retries instead.
- accessd only: a `nats.credsFile` or `platform.sessionFile` inside
  `accessd.dataDir` while `platform.url` is set, or no creds file from the
  platform within 30s on a first start.
- An invalid `platform` block (an `http://` URL without `allowInsecure`, no
  identity) when the keeper starts.

---

## 13. Which Binary Reads What

- **Both** read `nats`, `platform`, `logging`, `metrics`, `policy`, `status`
  and `subjects`. `platform.identity` differs per binary: each is its own
  Thing. The controller writes the status bucket; accessd watches it.
  `policy.cache` and `policy.bindings` are controller-only.
- **accessd** also reads `events`, `accessd` and `branding`.
- **access-controller** also reads `controller` and `diagnostics`.

Each binary ignores the sections it does not use, so the two can share one file
if you prefer, with env vars to specialize per host.

---

## 14. Where to Go Next

- What the central service runs and owns: [Central Service (accessd)](accessd.md)
- What runs on each box, offline behaviour and its status page: [Edge Controller (access-controller)](controller.md)
- Overview, build and run: [Access Control](../README.md)
- Subjects, KV keys and message shapes: [Wire Protocol](protocol.md)
- Operator permissions, sign-in and the audit log: [Operators & Authorization](operators.md)
- Board profiles, wiring and OSDP readers: [Hardware & Readers](hardware.md)
