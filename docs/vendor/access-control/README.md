---
path: access-control
nav_order: 50
access: public
title: Access Control
---
# stone-access

A standalone, NATS-native physical access control (PACS) app that dogfoods the
[Stone-Age.io](https://stone-age.io) platform — RBAC door control with schedules,
deny-override, and edge autonomy, composed from the platform's primitives
(NATS core, KV, JetStream, PocketBase control plane).

The authorization decision is a small **pure function** over an in-memory policy
graph (`internal/policy`), not a rules engine. The central app (`accessd`) is the
system of record (PocketBase) and mirrors policy to NATS KV one key per record;
edge controllers (`access-controller`) watch that keyspace and decide locally.

> v1 status: the reader is selectable per controller (`controller.reader`) — a
> **simulated NATS reader** (`nats`, default; taps arrive over NATS, for dev), a real
> **OSDP reader** on the model's RS485 bus (`osdp`; pure-Go, no cgo, clear-text in
> v1; Secure Channel is a fast-follow), or `both` (NATS for every portal plus OSDP
> for each portal with a `reader_address`). The **lock and door inputs have real
> drivers** alongside the mocks: native GPIO (`internal/drivers/gpio`, KinCony
> Server-Mini / CM4) and MCP23017 over I2C (`internal/drivers/i2c`, KinCony Pi5R8 /
> CM5). Door monitoring (forced / held-open / granted-but-no-entry) and controller
> heartbeat/health are implemented.

## What it does

- **Doors decided at the edge.** user → roles → access groups → portals, areas and
  aux outputs under one schedule (holiday calendars observed); deny-overrides and
  fail-closed. Postures (secure / unlocked / free access / lockdown / disabled),
  standing or scheduled. An optional offline cache lets a controller rebooted with
  NATS down decide on last-known policy.
- **Intrusion-lite areas.** Arm/disarm as separate rights, scheduled auto-arm,
  entry-disarm on a valid badge, and intrusion alarms from motion/tamper inputs or a
  forced member door. A fire-alarm contact is an aux input that can suppress alarm
  noise at its site; hardware owns egress.
- **One event stream.** Every tap, alarm, arm transition, and controller
  online/offline flip is a JetStream event, projected into the console's Events
  timeline and Alarm Console (acknowledge, deep-link).
- **Notifications.** Opt-in alarm/fire/offline email (per source *and* per operator,
  by type and location), a bounded re-page for alarms nobody acknowledges, and a
  webhook that POSTs each pageable event as JSON to PagerDuty, Slack, ntfy or an
  ITSM queue.
- **A badge for the people it is about.** Cardholders and visitors sign in to see
  their own pass and, where an operator opts in, unlock/arm/pulse remotely — always
  authorized by the same decision function as a physical tap.
- **An auditable control plane.** Operator capabilities, a change log of every
  policy edit, and a simulator that answers "would this card open that door".

## Something to look at

A fresh `accessd` has one door and one cardholder, which is enough to prove the
decision function runs and not much else. One command fills it:

```bash
./accessd migrate up
./accessd demo-seed --confirm
```

Northwind Traders across three sites: four controllers spanning both board models,
ten portals (including a maglock on a freezer door and a vehicle gate), four areas
(two arming themselves overnight on a schedule), aux inputs covering the monitor,
intrusion and 24h-tamper point types, a holiday calendar, eight roles, six access
groups, fifteen cardholders (thirteen with badge logins, three of them visitors in
three different pass states), and a backdated event history guaranteed to carry
**eight distinct decision reason codes** plus three unacknowledged alarms.

Every badge login is `demo1234`. Sign in at `/login?as=badge` as
`elena@northwind.example` (warehouse — can arm *and* disarm) and
`priya@northwind.example` (cleaning — can arm, **cannot** disarm) to see why arm
and disarm are two rights rather than one checkbox.

The three site codes — `KC-DC1`, `KC-OFFICE`, `SGF-XD2` — are the ones the
[Stone Age platform](https://github.com/stone-age-io/platform)'s own `demo-seed`
writes for its Northwind organization, and every controller and portal code above
is also a Thing in that platform's inventory. Seed both and the two apps describe
one company: a door here and a Thing there are the same door, and its QR label
resolves in either.

Idempotent, so re-running tops up rather than duplicating. `--confirm` is
required and is the whole safety mechanism — this ships in the binary you run in
production, and it creates people holding working credentials on real doors.

### Making it move

[`demo/rules/`](https://github.com/stone-age-io/access-control/blob/main/demo/rules) holds [rule-router](https://github.com/skeeeon/rule-router)
scheduler rules that keep the estate busy: badge taps at all ten portals,
operator door-pops, a nightly gate lockdown, yard lighting, alarms and a fire
drill. They publish to the **reader** subject, so running controllers decide each
one for real — the reason codes on the Events screen are the ones
`policy.Decide` produced, and editing an access group changes what the next tap
returns.

## Docs

- [`docs/protocol.md`](docs/protocol.md) — the NATS wire contract: subjects, KV
  shapes (`ACC_POLICY` + `ACC_STATUS`), decision reason codes, audit projection.
- [`docs/configuration.md`](docs/configuration.md) — every config key, default,
  and `SA_` env override for both binaries.
- [`docs/operators.md`](docs/operators.md) — the control-plane access model: operator
  sign-in, capabilities, collection-rule matrix, and the `audit_logs` change log.
- [`docs/hardware.md`](docs/hardware.md) — physical I/O: supported boards, pin
  maps, relay/input polarity, transports, and how to add a board.
- [`docs/plan-events.md`](docs/plan-events.md) — the design record for the event,
  notification, webhook, and fire-input work: why it was scoped the way it was.
- [`demo/README.md`](demo/README.md) — dev/demo tooling around `accessd demo-seed`:
  rule-router rules that keep the event feed live, a Telegraf config for long-term
  event storage, and the older PowerShell seed + simulator.

## Layout

```
cmd/accessd/            central: PocketBase + KV mirror + audit consumer + health monitor + notification/disarm/webhook sinks
cmd/access-controller/  edge: policy watcher + pure decision + drivers + door monitoring + heartbeat + optional /status page
internal/policy/        the pure core: Policy types, Decide() + DecideArea()/DecideOutput(), windowOpen()
internal/controller/    PolicyStore (KV watch → maps) + offline policy cache, tap loop, door state machine,
                        portal/aux/area managers, commands, heartbeat
internal/drivers/       ReaderDriver / LockDriver / DoorInput interfaces + mocks (MockHardware)
internal/drivers/hardware/  per-model hardware Profile: logical relay/input index → physical line + transport
internal/drivers/gpio/  native GPIO lock + door-input backend (go-gpiocdev, no cgo; Linux only)
internal/drivers/i2c/   MCP23017 lock + door-input backend over I2C (periph.io, no cgo; polled inputs)
internal/drivers/osdp/  OSDP reader: RS485 CP engine (pure-Go, no cgo) + wire codec (osdp/wire); controller.reader: osdp
internal/diag/          opt-in, read-only local /status page of an access-controller's live state (field troubleshooting)
internal/health/        accessd-side heartbeat subscriber → controllers.last_seen/status + online/offline events
internal/authz/         operator auth + capability checks for accessd's custom HTTP routes
internal/commandapi/    UI→NATS command bridge (grant/posture/aux output), gated by the `command` capability
internal/modelsapi/     GET /api/models — enum/options metadata for the UI
internal/simulateapi/   POST /api/simulate — the access simulator; a decision oracle, so operator-only
internal/badgeapi/      the badge tier: a holder's own badge + remote unlock/arm/pulse, and the operator
                        routes that mint a visit and read a holder's badge for troubleshooting
internal/badgesweep/    marks expired visitor credentials revoked — hygiene, not enforcement
internal/policysnapshot/ point-in-time snapshot of ACC_POLICY, shared by the simulator and the badge tier
internal/mirror/        PocketBase record hooks → one ACC_POLICY KV key per record (+ boot reconcile/prune)
internal/policykv/      the wire contract: KV key scheme + JSON shapes shared by mirror and PolicyStore
internal/subjects/      every NATS subject is built and parsed here — never hand-formatted elsewhere
internal/notify/        alarm/fire/offline email sink (a second ACC_EVENTS durable); inert until opted into
internal/repage/        re-sends an urgent alarm still unacknowledged after 15 min, at most twice
internal/webhook/       POSTs each pageable event as JSON to `accessd.webhookURL` (another ACC_EVENTS durable)
internal/disarm/        entry-disarm sink: a valid grant at a `disarm_on_grant` portal disarms its area
internal/armrelease/    releases a one-shot disarm override once a scheduled area's base state is disarmed
internal/statuskv/      the upward wire contract: ACC_STATUS key scheme + JSON shapes (the reverse of policykv)
internal/status/        upward device shadow: ACC_STATUS → point_status projection (+ area arm-transition events)
internal/changelog/     control-plane audit log: API-driven policy edits + logins → audit_logs collection
internal/audit/         JetStream consumer → PocketBase events collection
internal/natsx/         NATS connection + KV helpers
internal/demoseed/      `accessd demo-seed`: the Northwind Traders demo estate, in-process
internal/logger/        zap wrapper
internal/metrics/       Prometheus instrumentation (accessd :2113, controller :2114)
internal/webui/         the compiled management UI, //go:embed-ed into accessd
pbmigrations/           PocketBase collections (schema-in-code)
ui/                     Vue 3 + Vite management UI source (PocketBase-backed CRUD)
demo/                   dev-only: rules/ (rule-router activity for demo-seed), telegraf/ (event → VictoriaMetrics),
                        and the older seed.ps1 + access-demo.yaml
```

## Web UI

`accessd` serves a Vue 3 management console (an overview, locations + a location map,
schedules + holiday calendars, portals + printable door placards, controllers, areas, aux
I/O, access groups, roles, cardholders (visitors included), credentials, CSV import, an
events timeline, an alarm console, reports including the access simulator, a live
operational monitor, operator management, and the control-plane audit log) at `/`. It is
compiled into `internal/webui/public` and **`//go:embed`-ed into the accessd
binary** — there is no `pb_public` directory to ship; the binary is
self-contained.

Operators sign in against the built-in `users` auth collection; their abilities are
an orthogonal set of capabilities (`enroll`/`policy`/`topology`/`command`/`operators`)
that gate writes and commands while reads stay open to any authenticated operator —
see [`docs/operators.md`](docs/operators.md). A PocketBase **superuser**
(`accessd superuser upsert <email> <pass>`) is the break-glass account and also
signs into the admin UI at `/_`.

There is a **second, much smaller surface for the people the system is about**: a
cardholder or visitor signs in at `/login?as=badge` and sees their badge (photo, QR,
validity) and what it grants. Where an operator has opted the door, area, or
relay in, they can also open it, arm/disarm it, or pulse it from their phone; every such
action is authorized by the same pure decision function the edge runs, so a badge can
never do remotely what it could not do in person. `cardholders` is itself the auth
collection for this tier — one person is one record whether or not they ever sign in — and
`docs/operators.md` covers the boundary between the two tiers.

It is built as a **phone screen, not a document**: a fixed-height shell with one scroll
region, a bottom navigation bar whose screens (badge, plan, portals, areas, controls, on
site) appear only when the holder has something in them, a light/dark toggle and an account
menu in the header, and 44px-minimum tap targets throughout. The whole UI is an
**installable PWA** (`ui/public/manifest.json`), which matters most here — a badge you tap
an icon for beats one you find a bookmark for. Its service worker caches **nothing** on
purpose: this app's job is to say what a badge opens *right now*, and offline resilience
belongs at the edge, where the controller decides locally.

For the operator side of the same tier, a visitor is a cardholder: **New Visitor Pass**
(`/visitors/new`) mints a time-bound pass, the visitor's Cardholder page reissues or
revokes it, and
`GET /api/badge/preview/{id}` renders *what a holder's own badge says* — the fastest answer
to "my pass doesn't work", since it reuses the holder's exact payload and the badge's own
components. It is read-only and mints no session: a badge action is recorded as the
**holder's**, so acting through a borrowed badge session would be indistinguishable from
them in the audit trail.

The console is **rebrandable at runtime without a rebuild**: point `branding.dir`
(env `SA_BRANDING_DIR`) at a host directory of `theme.css` / `logo.svg` /
`branding.json` to override the app name, logo, and DaisyUI theme. See
[`docs/configuration.md`](docs/configuration.md#branding-accessd-only) and the
[`branding.example/`](https://github.com/stone-age-io/access-control/blob/main/branding.example) template.

### Build order (the embed happens at Go compile time)

```
cd ui && npm install        # once
npm run build               # → internal/webui/public  (commit this)
cd .. && go build ./cmd/accessd
./accessd serve             # UI at http://127.0.0.1:8090/  · admin at /_
```

Always build the UI **before** the binary; the committed `internal/webui/public`
means a fresh checkout embeds a working UI without needing npm.

### UI development

```
npm --prefix ui run dev     # http://localhost:5174, proxies /api + /_ to :8090
```

Requires Node 20.19+ / 22.12+ (Vite 8).

## Test

```
go test ./...
```
