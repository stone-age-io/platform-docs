---
path: access-control/configuration
nav_order: 20
---
# stone-access configuration reference

Both binaries — `accessd` and `access-controller` — share one config schema
([`config/config.go`](https://github.com/stone-age-io/access-control/blob/main/config/config.go)), loaded by Viper. This page is the
full key reference. For the *meaning* of the wire-level keys (`subjects.app`,
the bucket/stream names), see [`protocol.md`](protocol.md).

The annotated, copy-pasteable starting points are the example configs — read
those first, then use the tables here to look up a default or env var:

- [`config/accessd.yaml`](https://github.com/stone-age-io/access-control/blob/main/config/accessd.yaml) — the central app
- [`config/controller.yaml`](https://github.com/stone-age-io/access-control/blob/main/config/controller.yaml) — an edge controller

## Contents

- [How config loads](#how-config-loads) — file path, env overrides, parsing
- [NATS connection](#nats-connection) · [auth](#nats-auth-set-at-most-one) · [TLS](#nats-tls)
- [Logging](#logging) · [Metrics](#metrics) · [Diagnostics](#diagnostics-controller-only)
- [Resource names](#resource-names-shared) — buckets, stream, app token (must match across the fleet)
- [accessd](#accessd) · [Notifications](#notifications-accessd-only) · [Rate limits](#rate-limits-and-trustedproxy-accessd) · [Branding](#branding-accessd-only)
- [controller](#controller) · [Offline config cache](#offline-config-cache-controller-only)
- [What gets rejected](#what-gets-rejected) — every way `Load` fails
- [Which binary reads what](#which-binary-reads-what)

## How config loads

- **File path.** `accessd` reads `$SA_CONFIG` (default `config/accessd.yaml`).
  `access-controller` uses its `-config` flag (default `config/controller.yaml`).
- **A missing file is fine** — defaults plus env vars still apply. Nothing is
  required to exist on disk.
- **Every key is overridable by an `SA_`-prefixed env var.** Take the dotted key,
  uppercase it, replace dots with underscores: `nats.urls` → `SA_NATS_URLS`,
  `controller.heartbeatInterval` → `SA_CONTROLLER_HEARTBEATINTERVAL`,
  `nats.tls.enable` → `SA_NATS_TLS_ENABLE`. Env wins over the file.
- **Defaults fill only absent keys.** `setDefaults` runs *before* the file is
  decoded, so a key written with a zero/empty value is taken literally:
  `maxReconnects: 0` means never reconnect, `auditRetentionDays: 0` means never
  prune, `logging.level: ""` fails validation. Omit a key to get its default.
- **Parsing.** Durations are Go duration strings (`250ms`, `15s`, `45s`).
  `nats.urls` accepts a comma-separated list via the env var.

The PocketBase HTTP address is **not** a config key — it is owned by PocketBase's
own `serve --http` flag (default `127.0.0.1:8090`).

## NATS connection

| Key | Default | Env var | Notes |
|---|---|---|---|
| `nats.urls` | `nats://localhost:4222` | `SA_NATS_URLS` | one or more; comma-separated via env. Use the `tls://` scheme for TLS. |
| `nats.maxReconnects` | `-1` (forever) | `SA_NATS_MAXRECONNECTS` | an *absent* key defaults to `-1`; an explicit `0` is passed through (no reconnects). The KV watcher re-arms on every reconnect. |
| `nats.reconnectWait` | `250ms` | `SA_NATS_RECONNECTWAIT` | backoff between reconnect attempts. |

### NATS auth (set at most one)

Setting more than one method fails validation. None is allowed (an open dev box).
A `.creds` file is the recommended path for a backend service; `*.creds` is
gitignored — never commit credentials.

| Key | Default | Env var | Notes |
|---|---|---|---|
| `nats.credsFile` | `""` | `SA_NATS_CREDSFILE` | JWT + nkey `.creds` file. **Must exist** if set. |
| `nats.nkeySeedFile` | `""` | `SA_NATS_NKEYSEEDFILE` | raw nkey seed file. |
| `nats.token` | `""` | `SA_NATS_TOKEN` | bearer token. |
| `nats.username` | `""` | `SA_NATS_USERNAME` | with `password`. |
| `nats.password` | `""` | `SA_NATS_PASSWORD` | with `username`. |

### NATS TLS

Not needed when the URL is `tls://` and the server presents a publicly-trusted
cert. Enable for mutual TLS or a custom CA. The file and `insecure` keys take
effect **only with `enable: true`** — a `caFile` set without it is ignored.

| Key | Default | Env var | Notes |
|---|---|---|---|
| `nats.tls.enable` | `false` | `SA_NATS_TLS_ENABLE` | |
| `nats.tls.caFile` | `""` | `SA_NATS_TLS_CAFILE` | custom CA to verify the server. |
| `nats.tls.certFile` | `""` | `SA_NATS_TLS_CERTFILE` | client cert (mutual TLS) — set **with** `keyFile`. |
| `nats.tls.keyFile` | `""` | `SA_NATS_TLS_KEYFILE` | set **with** `certFile`. |
| `nats.tls.insecure` | `false` | `SA_NATS_TLS_INSECURE` | skip server verification — **never** in production. |

## Logging

| Key | Default | Env var | Notes |
|---|---|---|---|
| `logging.level` | `info` | `SA_LOGGING_LEVEL` | `debug` · `info` · `warn` · `error`. |
| `logging.encoding` | `json` | `SA_LOGGING_ENCODING` | `json` · `console`. |
| `logging.outputPath` | `stdout` | `SA_LOGGING_OUTPUTPATH` | |

## Metrics

Prometheus endpoint on a side port. The example configs enable it and put the
two binaries on **different ports** so both can run on one host: accessd `:2113`,
controller `:2114`.

| Key | Default | Env var | Notes |
|---|---|---|---|
| `metrics.enabled` | `false` | `SA_METRICS_ENABLED` | example configs set `true`. |
| `metrics.address` | `:2113` | `SA_METRICS_ADDRESS` | controller example uses `:2114`. |
| `metrics.path` | `/metrics` | `SA_METRICS_PATH` | |
| `metrics.updateInterval` | `15s` | `SA_METRICS_UPDATEINTERVAL` | duration string. |

## Diagnostics (controller-only)

An **opt-in, read-only** local status page for field install and troubleshooting,
served by `access-controller` only (accessd ignores this section). When enabled it
serves `/status` (a self-contained HTML page — inline CSS and a few lines of inline
JS that refresh it in place, with pause/refresh controls; no external assets, so it
works with no network), `/status.json`, and `/` (redirects to `/status`) on
`diagnostics.address`. It renders this box's live in-memory state: identity (incl.
`subjects.app`), NATS/policy-sync health, the portals it bound and their door/posture
state, aux inputs/outputs, fire-input suppression state, recent decisions (with the
decoded credential), and recent alarms.

It is strictly **read-only** — all control stays on the NATS command plane. It is
**disabled by default**, and because the page reveals topology (portal codes,
locations, reader addresses) it binds **localhost by default**; reach it over SSH /
a tunnel rather than binding a public interface. Hosting it is independent of
`metrics` (its own server/port), so metrics can be scraped on a monitoring network
while diagnostics stays local.

| Key | Default | Env var | Notes |
|---|---|---|---|
| `diagnostics.enabled` | `false` | `SA_DIAGNOSTICS_ENABLED` | controller only. |
| `diagnostics.address` | `127.0.0.1:2115` | `SA_DIAGNOSTICS_ADDRESS` | keep local unless deliberately exposed. |

## Resource names (shared)

These name the NATS resources the fleet talks over. **accessd and every
controller must agree on them** — a mismatch silently severs the data plane.
See [`protocol.md`](protocol.md) for what each carries.

| Key | Default | Env var | Notes |
|---|---|---|---|
| `policy.bucket` | `ACC_POLICY` | `SA_POLICY_BUCKET` | KV bucket: the downward policy mirror. Read by both. |
| `status.bucket` | `ACC_STATUS` | `SA_STATUS_BUCKET` | KV bucket: the upward device shadow. Read by both. |
| `events.stream` | `ACC_EVENTS` | `SA_EVENTS_STREAM` | JetStream audit stream. accessd creates/consumes it; its subjects are derived from `subjects.app`, not set here. |
| `subjects.app` | `acc` | `SA_SUBJECTS_APP` | the app token every subject leads with. Must be a single NATS token (no `.`, `*`, `>`, or whitespace). |

## accessd

| Key | Default | Env var | Notes |
|---|---|---|---|
| `accessd.dataDir` | `./pb_data` | `SA_ACCESSD_DATADIR` | embedded PocketBase data dir (db + uploads). Created at runtime, gitignored. The UI is `//go:embed`-ed, so there is no `pb_public`. |
| `accessd.controllerOfflineAfter` | `45s` | `SA_ACCESSD_CONTROLLEROFFLINEAFTER` | silence before a controller shows offline. Keep it a few controller `heartbeatInterval`s so one dropped heartbeat does not flap a box offline. |
| `accessd.auditRetentionDays` | `365` | `SA_ACCESSD_AUDITRETENTIONDAYS` | how long control-plane audit rows (`audit_logs`, written by `internal/changelog`) are kept before a daily 03:00 prune deletes them. Absent = 365; an explicit `0` or a **negative** value disables pruning (keep forever). See [`operators.md`](operators.md#control-plane-audit-log-audit_logs). |
| `accessd.eventRetentionDays` | `0` | `SA_ACCESSD_EVENTRETENTIONDAYS` | how long door-activity rows (`events`, the rebuildable projection of the `ACC_EVENTS` JetStream stream) are kept before a daily 03:00 prune deletes them. **`0` (the default) — or any negative value — keeps them forever**: pruning is opt-in, so an upgrade never silently deletes event history. A positive day count trims the projection; JetStream stays the system of record, so a prune only shrinks the read model. |
| `accessd.webhookURL` | `""` | `SA_ACCESSD_WEBHOOKURL` | when set, enables the outbound webhook sink ([`internal/webhook`](https://github.com/stone-age-io/access-control/blob/main/internal/webhook)): a fourth durable on `ACC_EVENTS` that POSTs every pageable event as JSON here, so an install can feed its own PagerDuty/Slack/ntfy/ITSM instead of relying on email. Empty leaves it inert. See [Notifications](#notifications-accessd-only). |

### Notifications (accessd-only)

The alarm notification sink ([`internal/notify`](https://github.com/stone-age-io/access-control/blob/main/internal/notify)) is a second,
independent durable consumer on `ACC_EVENTS` that emails on `alarm`/`fire`. **It has
no config** — like the disarm sink it is always started and purely data-driven, so
the "who" and "which" are UI-managed and changing them never requires a redeploy.
It is inert until **two opt-ins** line up:

| Opt-in | Where (UI) | Effect |
|---|---|---|
| `users.notify` | Operators → Notify | the operator is a recipient of alarm email |
| `users.notify_locations` | Operators → Notify locations | scope the operator to specific locations (empty = all locations) |
| `users.notify_types` | Operators → Notify types | scope the operator to specific event kinds (empty = the default set) |
| `portals.notify_on_alarm` | Portal → Area & intrusion → Email on alarm (or bulk-select on the Portals list) | email the recipients on this door's forced/held-open (and `no_entry`) alarms |
| `areas.notify_on_alarm` | Area → Email on intrusion | email the recipients on this area's intrusion alarms |
| `locations.notify_fire` | Location → Email on fire input | email the recipients on this location's fire-input alarms |
| `controllers.notify_offline` | Controller → Notify on offline | email the recipients when this box stops reporting |

A source flag without any `users.notify` operator (or vice-versa) sends nothing.
**Recipients are scoped by location:** an alarm at a location emails only the
notify operators whose `notify_locations` is empty (= all locations) or contains
that location — so a multi-site deployment can page site-local operators without a
per-source routing matrix.

**Recipients are also scoped by severity** (`users.notify_types`). An empty
selection means the **default set** — `forced`, `held`, `intrusion`, `fire`,
`controller_offline` — not literally everything: `no_entry` (a grant nobody walked
through) is diagnostic and must be selected explicitly. Leaving the selection empty
is therefore the right choice for most operators, because a future urgent type will
reach them automatically; selecting types freezes the set to exactly those. The
auto-clear of a held-open door (`held_clear`) is never emailed at all, and a
controller coming back *online* is not paged. There is no `notify.*` config block
and no `SA_NOTIFY_*` env var.

**Deep links.** Each message links to the exact event
(`{AppURL}/alarms?seq=…`). The base comes from PocketBase's **Application URL**
(`/_` → Settings → Application), which is the same value its own password-reset mail
uses — so there is no separate key here. Unset means messages simply carry no link.

**Reminders.** An urgent alarm still unacknowledged after 15 minutes is re-sent, at
most twice ([`internal/repage`](https://github.com/stone-age-io/access-control/blob/main/internal/repage)). It reuses the same opt-ins, so
a reminder never reaches anyone the original could not, and never covers
`held`/`no_entry`. No config.

> **SMTP lives in PocketBase, not here.** The mail transport (host/port/
> credentials/sender) is configured in the PocketBase admin UI at `/_` ("Mail
> settings"); the sink's `From` is PocketBase's configured sender. The sink uses
> `DeliverNew` (it starts from "now", never replaying historical alarms) with
> bounded redelivery, so a dead SMTP server can't loop forever.

**Webhook sink** (`accessd.webhookURL`, the one notification key that *is* config).
A fourth durable POSTs each pageable event as structured JSON to that URL. It shares
the classification above — so email and webhook never disagree about what is worth
forwarding — but deliberately **ignores the per-source and per-operator email
opt-ins**: those decide who gets *mail*, while a webhook has one destination whose
whole purpose is to receive the feed. Configuring the URL is the opt-in. Like the
email sink it is a `DeliverNew` durable (a freshly set URL is not flooded with
history), and a failed POST is `Nak`ed for JetStream redelivery, bounded.

> This is the answer to "let us customise the notification templates". Shipping the
> structured event to a tool that already knows how to route, escalate, and
> acknowledge beats any template engine we could ship, and the email body stays
> fixed and terse — which is what it should be for something read on a phone at 3am.

> **Why config and not a UI field.** accessd POSTs wherever this points, from inside
> the deployment's network — a modest SSRF surface. Deploy-time config means there is
> no API to abuse at all, and it matches how the other outbound transport (SMTP) is
> administered. The sink additionally never follows redirects and has a hard 10s timeout.

> **Entry-disarm has no config either.** The disarm sink ([`internal/disarm`](https://github.com/stone-age-io/access-control/blob/main/internal/disarm)),
> which disarms an area on a valid grant at a `disarm_on_grant` portal, is **always
> started** and needs no settings — it is inert unless a portal opts in (set
> `disarm_on_grant` + an `area` on the portal in the UI). Like notify it is a
> `DeliverNew` durable on `ACC_EVENTS`.

> **The badge tier has no config either.** The badge routes
> ([`internal/badgeapi`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi)) and the visitor-credential sweep
> ([`internal/badgesweep`](https://github.com/stone-age-io/access-control/blob/main/internal/badgesweep)) are **always started** and need no
> settings — they are inert until an operator ticks **Badge login** on a cardholder, and
> remote unlock additionally needs a door to opt in via `allow_remote_unlock`
> (default off). What *is* configurable lives in PocketBase settings rather than
> here: SMTP, OAuth2 providers, and the rate limits below.

> **SMTP is optional, but it decides which sign-in methods work.** One-time codes and
> the forgot-password link are both emails. With no mail server configured, the only
> way into a badge is a **password an operator sets in person** — on the cardholder form
> for a staff holder (Cardholder → Badge login), or in the **Initial password** field on
> the visitor mint form — or an OAuth2 provider. Neither is ever emailed. So the badge
> tier, visitors included, works with no mail server at all; what is lost is
> self-service (a holder cannot recover their own password) and the invite mail, whose
> content an operator can simply say out loud. The mint screen shows the badge link and a
> QR of it for exactly that handover. See [operators.md](operators.md#sign-in-methods).

### Rate limits and `TrustedProxy` (accessd)

Migrations [`1750000032`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000032_badge_rate_limits.go),
[`1750000039`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000039_remote_area_output.go) and
[`1750000041`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000041_badge_floorplan.go) ship default PocketBase rate
limits for the badge routes — they are the first routes reachable by someone who is not an
operator, and an unconfigured limiter is wide open. Defaults, per client:

| Rule | Limit | Why that number |
|---|---|---|
| `POST /api/badge/unlock/` | 10/min | it opens a door |
| `POST /api/badge/areas/` (arm + disarm) | 6/min | lower: disarming turns intrusion detection off |
| `POST /api/badge/outputs/` | 10/min | momentary, like an unlock |
| `GET /api/badge/me` | 60/min | a page load |
| `GET /api/badge/live` | 60/min | a page load, but it walks the whole grant set |
| `cardholders:requestOTP` | 5/min | sends an email per call — a mail-bomb *and* an SMTP-quota vector |
| `cardholders:authWithPassword` | 10/min | credential stuffing |
| `cardholders:requestPasswordReset` | 3/min | also an email per call |
| `POST /api/badge/password` | 5/min | it checks the current password, so it is an oracle for guessing it from a stolen session |

Adjust them in the PocketBase admin under **Settings → Rate limits**.

`GET /api/badge/preview/{id}` is deliberately absent: it is operator-only (`enroll`), so it
sits behind the same trust boundary as every other operator route and none of those are
limited. It is audited instead — see [operators.md](operators.md#seeing-a-holders-badge-apibadgepreview).

> **Behind a reverse proxy, set `TrustedProxy`.** PocketBase's limiter keys on client
> IP. Without the proxy configured in **Settings → Application**, every request appears
> to come from the proxy and shares a single bucket — so one visitor's retries would
> rate-limit the whole building. This is the same setting the audit log's `request_ip`
> depends on.

## Branding (accessd-only)

Point `branding.dir` at a host directory to override the embedded app name, logo,
and DaisyUI theme **without rebuilding the binary**. accessd serves that
directory's files under `/branding/*`; the UI's `index.html` `<link>`s
`/branding/theme.css` and the app fetches `/branding/branding.json` at boot.

| Key | Default | Env var | Notes |
|---|---|---|---|
| `branding.dir` | `""` (embedded defaults) | `SA_BRANDING_DIR` | host directory holding any of `theme.css`, `logo.svg`, `branding.json`. Empty = no overlay; the route still serves a silent empty `theme.css`/`{}` `branding.json`, so a stock install never 404s. A path that is missing or not a directory logs a warning and falls back to the same defaults (not a startup error). Path traversal (`..`) is rejected. |

Overlay files (all optional):

| File | Shape | Effect |
|---|---|---|
| `branding.json` | `{ "appName": "...", "logo": "logo.svg" }` | sets the sidebar/login app name + browser tab title, and names the logo file (served at `/branding/<logo>`). |
| `theme.css` | DaisyUI `[data-theme=light\|dark]` OKLCH var overrides | recolors the whole UI. Loaded after the bundled CSS, so it wins by cascade order — override only what you need. |
| the logo (e.g. `logo.svg`) | an image | replaces the built-in mark; `.brand-logo-img` is a CSS hook for per-theme logo swaps. |

Copy [`branding.example/`](https://github.com/stone-age-io/access-control/blob/main/branding.example) to the host (e.g.
`/etc/stone-access/branding/`), add your `logo.svg`, and set `branding.dir`:

```yaml
branding:
  dir: "/etc/stone-access/branding"
```

## controller

A controller's config is just its identity and hardware selection — **which
portals it drives, and their relay/input bindings, live in policy, not here**
(matched by `controller.code`).

| Key | Default | Env var | Notes |
|---|---|---|---|
| `controller.code` | `""` | `SA_CONTROLLER_CODE` | matches a `controllers` record; the box arms every portal whose `controller` relation points at this code. |
| `controller.location` | `""` | `SA_CONTROLLER_LOCATION` | location code: selects the timezone and scopes the command/fire subscriptions. |
| `controller.heartbeatInterval` | `15s` | `SA_CONTROLLER_HEARTBEATINTERVAL` | liveness cadence to `acc.{location}.ctrl.{code}.heartbeat`. |
| `controller.driver` | `mock` | `SA_CONTROLLER_DRIVER` | `mock` (simulated, no I/O, no door monitoring) or `gpio` (real relays + DPS/REX; Linux only). Under `gpio` the `model` picks the physical transport: native GPIO char device or an MCP23017 I2C expander. |
| `controller.model` | `""` | `SA_CONTROLLER_MODEL` | hardware profile — maps a portal's logical relay/input indices to physical lines, selects the lock/input transport (native GPIO char device or MCP23017 over I2C), **and** provides the OSDP RS485 serial port: `kincony-server-mini` (CM4, GPIO, `/dev/ttyAMA0`) · `kincony-pi5r8` (CM5, I2C, `/dev/ttyAMA2`). **Required when `driver: gpio`, `reader: osdp`, or `reader: both`.** Must match the `controllers` record. |
| `controller.reader` | `nats` | `SA_CONTROLLER_READER` | credential reader: `nats` (simulated taps published to `acc.{location}.{type}.{thing}.tap`, for dev), `osdp` (a real OSDP reader on the model's RS485 bus, clear-text in v1), or `both` (NATS for every portal **plus** OSDP for portals that have a reader). Independent of `driver` — the lock/door stay on GPIO/I2C. **`osdp` and `both` require `model`.** A portal opts into OSDP via its `reader_address`: `>= 0` = OSDP reader at that PD address, `-1` = NATS-only. Emitted tap events carry a `source` (`nats`/`osdp`). |

### Offline config cache (controller-only)

By default a controller is a stateless projection of NATS KV: reboot and it
re-syncs the policy graph from the hub, booting **default-deny** until the sync
lands. That is fail-secure, but it means a box that reboots while NATS is
unreachable (leaf node down, or no network) can't decide anything until the link
returns. The optional offline cache closes that gap: it persists the last policy
graph delivered over KV to a local file and, on boot, decides from it while the
connection is down.

A controller **never treats a missing NATS at startup as fatal**, cache or no
cache — it connects with retry-on-failed-connect, binds the KV buckets lazily and
retries in the background, coming up default-deny and converging when NATS
returns. (accessd is the opposite: it fails fast when its NATS is unreachable.) The
cache is what makes that offline boot *useful*: it comes up on last-known policy
instead of default-deny.

| Key | Default | Env var | Notes |
|---|---|---|---|
| `policy.cache.enabled` | `false` | `SA_POLICY_CACHE_ENABLED` | opt in to the offline cache. Off = today's stateless, default-deny-until-sync boot. |
| `policy.cache.path` | `./data/policy-cache.json` | `SA_POLICY_CACHE_PATH` | snapshot file. Written `0600` (it holds credential values), parent dir created `0700`; atomic (temp + rename). |
| `policy.cache.maxAge` | `72h` | `SA_POLICY_CACHE_MAXAGE` | staleness bound. On boot, a snapshot older than this is **refused** and the box falls back to default-deny, so a credential revoked during a long outage can't keep working indefinitely off a stale cache. Set a large value (e.g. `8760h`) to effectively disable the check. |

Behavior and guarantees:

- **Fail-secure.** A missing, unreadable, corrupt, or too-old snapshot loads
  nothing — the box behaves exactly as if the cache were disabled.
- **Live KV always wins.** The moment a sync lands, fresh policy overwrites the
  cache; the snapshot is only ever written from a completed live sync (never from
  the partial view during boot re-delivery, and never while offline).
- **Freshness tracks connectivity.** While connected, the snapshot's timestamp is
  refreshed periodically, so `maxAge` measures staleness from the last moment the
  box actually had contact with the hub — not merely the last policy edit.
- **Scope.** Only the decision inputs are cached. Transient command posture
  overrides are not (a reboot safely reverts them), door state is re-read from
  hardware, and the upward status shadow simply isn't published while offline
  (nothing is watching it).
- **The `/status` page shows the degraded state** — an `OFFLINE · cached config`
  badge and the snapshot's age — so a running-on-cache box is never mistaken for a
  freshly-synced one. The staleness bound is checked **only at boot**; a box
  already running on cache keeps running until NATS returns.

## What gets rejected

`Load` returns an error (the binary refuses to start) only in these cases —
everything else falls back to a default:

- the config file exists but can't be parsed (malformed YAML)
- a value can't be decoded into its type — e.g. a duration key like
  `heartbeatInterval: soon` (`failed to unmarshal config`)
- no NATS URL configured (only possible with an explicit empty `urls` list)
- more than one NATS auth method set
- `nats.credsFile` set but the file does not exist
- `nats.tls.enable` true with only one of `certFile` / `keyFile`
- `logging.level` not one of `debug`/`info`/`warn`/`error`
- `metrics.updateInterval` not a parseable duration
- `policy.bucket` or `status.bucket` empty
- `subjects.app` empty or not a single NATS token
- `controller.driver` not `mock`/`gpio`, or `gpio` with no `controller.model`
- `controller.reader` not `nats`/`osdp`/`both`, or `osdp`/`both` with no `controller.model`

Some values pass `Load` and fail **later, at startup** instead:

- `logging.encoding` other than `json`/`console`, or an unopenable
  `logging.outputPath` (logger construction)
- an unreadable `nats.nkeySeedFile`, or a TLS `certFile`/`keyFile` pair that won't
  load (NATS options are built at connect)
- `controller.model` naming no known profile, when the driver or reader needs one
  (`unknown controller model`, listing the known ones)
- accessd only: NATS unreachable at `serve` (the controller retries instead)

## Which binary reads what

- **Both** read `nats`, `logging`, `metrics`, `policy`, `status`, `subjects`
  (the controller writes the status bucket; accessd watches it). `policy.cache` is
  controller-only.
- **accessd** also reads `events`, `accessd`, and `branding`.
- **access-controller** also reads `controller` and `diagnostics`.

Unused sections are simply ignored, so the two binaries can share one file if you
prefer (env vars then specialize per host).
