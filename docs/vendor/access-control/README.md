---
path: access-control
nav_order: 50
access: public
---
# Access Control

`stone-access` is a standalone, NATS-native physical access control (PACS) app
built on the [Stone-Age.io](https://stone-age.io) platform. It does RBAC door
control with schedules, deny-override and edge autonomy, using the platform's
primitives: NATS core, KV, JetStream and a PocketBase control plane.

The authorization decision is a small **pure function** over an in-memory
policy graph (`internal/policy`), not a rules engine. The central app
(`accessd`) is the system of record (PocketBase) and mirrors policy to NATS KV,
one key per record. Edge controllers (`access-controller`) watch that keyspace
and decide locally. The wire contract is in [Wire Protocol](docs/protocol.md).

::: note v1 status
The reader is selectable per controller (`controller.reader`): a
**simulated NATS reader** (`nats`, the default; taps arrive over NATS, for
dev), a real **OSDP reader** on the model's RS485 bus (`osdp`; pure Go, no
cgo, clear text in v1, with Secure Channel to follow), or `both` (NATS for
every portal plus OSDP for each portal with a `reader_address`). The **lock
and door inputs have real drivers** beside the mocks: native GPIO
(`internal/drivers/gpio`, KinCony Server-Mini / CM4) and MCP23017 over I2C
(`internal/drivers/i2c`, KinCony Pi5R8 / CM5). Door monitoring (forced,
held-open, granted-but-no-entry) and controller heartbeat and health are
implemented.
:::

---

## What It Does

- **Doors decided at the edge.** User → roles → access groups → portals, areas
  and aux outputs under one schedule, with holiday calendars observed. Deny
  overrides, and anything unknown fails closed. Postures (secure, unlocked,
  free access, lockdown, disabled) are standing or scheduled. An optional
  offline cache lets a controller rebooted with NATS down decide on last-known
  policy.
- **Intrusion-lite areas.** Arm and disarm are separate rights. Areas support
  scheduled auto-arm, entry-disarm on a valid badge, and intrusion alarms from
  motion or tamper inputs or a forced member door. A fire-alarm contact is an
  aux input that can suppress alarm noise at its site. Hardware owns egress.
- **One event stream.** Every tap, alarm, arm transition and controller
  online/offline flip is a JetStream event. The console projects them into its
  Events timeline and Alarm Console (acknowledge, deep-link).
- **Notifications.** Opt-in alarm, fire and offline email (per source *and* per
  operator, by type and location), a bounded re-page for alarms nobody
  acknowledges, and a webhook that POSTs each pageable event as JSON to
  PagerDuty, Slack, ntfy or an ITSM queue.
- **A badge for the people it is about.** Cardholders and visitors sign in to
  see their own pass. Where an operator opts in, they can unlock, arm or pulse
  remotely. The same decision function as a physical tap authorizes every
  remote action.
- **An auditable control plane.** Operator capabilities, a change log of every
  policy edit, and a simulator that answers "would this card open that door".

---

## Try the Demo

A fresh `accessd` has one door and one cardholder. That proves the decision
function runs and not much else. One command fills it:

```bash
./accessd migrate up
./accessd demo-seed --confirm
```

You get Northwind Traders across three sites: four controllers spanning both
board models, ten portals (including a maglock on a freezer door and a vehicle
gate), four areas (two arm themselves overnight on a schedule), aux inputs
covering the monitor, intrusion and 24h-tamper point types, a holiday calendar,
eight roles, six access groups, fifteen cardholders (thirteen with badge logins,
three of them visitors in three different pass states), and a backdated event
history that always carries **eight distinct decision reason codes** plus three
unacknowledged alarms.

Every badge login is `demo1234`. Sign in at `/login?as=badge` as
`elena@northwind.example` (warehouse: can arm *and* disarm) and
`priya@northwind.example` (cleaning: can arm, **cannot** disarm) to see why arm
and disarm are two rights rather than one checkbox.

The three site codes (`KC-DC1`, `KC-OFFICE`, `SGF-XD2`) are the ones the
[Stone Age platform](https://github.com/stone-age-io/platform)'s own
`demo-seed` writes for its Northwind organization, and every controller and
portal code above is also a Thing in that platform's inventory. Seed both and
the two apps describe one company: a door here and a Thing there are the same
door, and its QR label resolves in either.

The seed is idempotent, so a re-run tops up rather than duplicating.

::: warning `--confirm` is the only safety mechanism
`demo-seed` ships in the binary you run in production, and it creates people
holding working credentials on real doors.
:::

### Making It Move

[`demo/rules/`](https://github.com/stone-age-io/access-control/blob/main/demo/rules) holds
[rule-router](https://github.com/skeeeon/rule-router) scheduler rules that keep
the estate busy: badge taps at all ten portals, operator door-pops, a nightly
gate lockdown, yard lighting, alarms and a fire drill. They publish to the
**reader** subject, so running controllers decide each one for real. The reason
codes on the Events screen are the ones `policy.Decide` produced, and editing an
access group changes what the next tap returns. See [Demo Data](demo/README.md).

---

## Build and Run

The UI is `//go:embed`-ed into `accessd` at Go compile time, so build the UI
**before** the binary:

```
cd ui && npm install        # once
npm run build               # → internal/webui/public  (commit this)
cd .. && go build ./cmd/accessd
./accessd serve             # UI at http://127.0.0.1:8090/  · admin at /_
```

The committed `internal/webui/public` means a fresh checkout embeds a working UI
without npm. Rebuild and commit it whenever the frontend changes.

Create the admin login (a PocketBase superuser) with
`./accessd superuser upsert <email> <pass>`.

Build and run an edge controller:

```
go build ./cmd/access-controller
./access-controller -config config/controller.yaml
```

### UI Development

```
npm --prefix ui run dev     # http://localhost:5174, proxies /api + /_ to :8090
```

Requires Node 20.19+ / 22.12+ (Vite 8).

### Test

```
go test ./...
```

---

## Web UI

`accessd` serves a Vue 3 management console at `/`. It covers an overview,
locations and a location map, schedules and holiday calendars, portals and
printable door placards, controllers, areas, aux I/O, access groups, roles,
cardholders (visitors included), credentials, CSV import, an events timeline, an
alarm console, reports including the access simulator, a live operational
monitor, operator management, and the control-plane audit log. The UI is
compiled into `internal/webui/public` and **`//go:embed`-ed into the accessd
binary**. There is no `pb_public` directory to ship; the binary is
self-contained.

### Operators

Operators sign in against the built-in `users` auth collection. Their abilities
are an orthogonal set of capabilities (`enroll`, `policy`, `topology`,
`command`, `operators`) that gate writes and commands. Reads stay open to any
authenticated operator. A PocketBase **superuser**
(`accessd superuser upsert <email> <pass>`) is the break-glass account and also
signs into the admin UI at `/_`. See
[Operators & Authorization](docs/operators.md).

### The Badge

Cardholders and visitors have a second, much smaller surface. A holder signs in
at `/login?as=badge` and sees their badge (photo, QR, validity) and what it
grants. Where an operator has opted a door, area or relay in, the holder can
open it, arm or disarm it, or pulse it from their phone. The same pure decision
function the edge runs authorizes each action, so a badge can never do remotely
what it could not do in person. `cardholders` is itself the auth collection for
this tier: one person is one record, whether or not they ever sign in.
[Operators & Authorization](docs/operators.md) covers the boundary between the
two tiers.

The badge is a phone screen: a fixed-height shell with one scroll region, a
bottom navigation bar whose screens (badge, plan, portals, areas, controls, on
site) appear only when the holder has something in them, a light/dark toggle
and an account menu in the header, and 44px-minimum tap targets.

The whole UI is an **installable PWA** (`ui/public/manifest.json`). Its service
worker caches **nothing**, because the app must say what a badge opens *right
now*. Offline resilience belongs at the edge, where the controller decides
locally.

### Visitors

A visitor is a cardholder. **New Visitor Pass** (`/visitors/new`) mints a
time-bound pass, and the visitor's Cardholder page reissues or revokes it.

`GET /api/badge/preview/{id}` shows an operator what a holder's own badge says.
It reuses the holder's exact payload and the badge's own components, so it is
the fastest answer to "my pass doesn't work". It is read-only and mints no
session: a badge action is recorded as the **holder's**, so acting through a
borrowed badge session would look the same as the holder in the audit trail.

### Branding

You can rebrand the console at runtime without a rebuild. Point `branding.dir`
(env `SA_BRANDING_DIR`) at a host directory of `theme.css`, `logo.svg` and
`branding.json` to override the app name, logo and DaisyUI theme. See
[Configuration Reference](docs/configuration.md#10-branding) and the
[`branding.example/`](https://github.com/stone-age-io/access-control/blob/main/branding.example) template.

---

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

---

## Docs

- **[Wire Protocol](docs/protocol.md)**: the NATS wire contract. Subjects, KV
  shapes (`ACC_POLICY` and `ACC_STATUS`), decision reason codes and the audit
  projection.
- **[Configuration Reference](docs/configuration.md)**: every config key,
  default and `SA_` env override for both binaries.
- **[Operators & Authorization](docs/operators.md)**: the control-plane access
  model. Operator sign-in, capabilities, the collection-rule matrix and the
  `audit_logs` change log.
- **[Hardware & Readers](docs/hardware.md)**: physical I/O. Supported boards,
  pin maps, relay and input polarity, transports, and how to add a board.
- **[Demo Data](demo/README.md)**: dev and demo tooling around
  `accessd demo-seed`. rule-router rules that keep the event feed live, a
  Telegraf config for long-term event storage, and the older PowerShell seed and
  simulator.

Design record (in the repo, not on the wiki):

- [`docs/plan-events.md`](https://github.com/stone-age-io/access-control/blob/main/docs/plan-events.md): the design record for the event,
  notification, webhook and fire-input work, and why it was scoped that way.
