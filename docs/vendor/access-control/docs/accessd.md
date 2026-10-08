---
path: access-control/accessd
nav_order: 10
---
# Central Service (accessd)

`accessd` is the central half of the system: one binary per deployment that
holds the policy record, publishes it to the edge, and turns what the edge
reports into history, live state and notifications. This page says what it
runs, what it owns and how it behaves when NATS or it goes away. The edge half
is [Edge Controller (access-controller)](controller.md), and the wire between
them is the [Wire Protocol](protocol.md).

---

## 1. What It Is

`accessd` ([`cmd/accessd`](https://github.com/stone-age-io/access-control/blob/main/cmd/accessd/main.go)) is a PocketBase
application. It embeds PocketBase as the system of record for the policy graph,
serves the management console, and runs a set of NATS consumers, sweeps and
HTTP routes inside the same process.

It **never decides a physical credential presentation**. A card read at a door
is decided by the controller that drives that door, with the pure
`policy.Decide`, from its in-memory copy of the policy KV. accessd runs the
same decision functions in three places, all over a snapshot of `ACC_POLICY`
rather than its own database:

- **The badge tier.** A holder's remote unlock, arm, disarm or output pulse is
  authorized by `policy.Decide`, `policy.DecideArea` or `policy.DecideOutput`
  before accessd publishes a command or writes an override. So a remote action
  can never exceed what that badge opens in person.
- **The access simulator** (`POST /api/simulate`). It answers "would this
  credential open this portal at this time?" and changes nothing.
- **The one-shot disarm release.** It resolves an area's base arm-state the way
  a controller does, to decide whether to clear a disarm override (§3).

### Who owns what

This is the canonical split between the two binaries.

| Concern | `accessd` | `access-controller` |
| :--- | :--- | :--- |
| Policy record | Owns it: PocketBase collections, edited in the console or API | Never writes PocketBase |
| Policy KV (`ACC_POLICY`) | Creates the bucket; writes one key per record (the mirror) | Binds it read-only and watches it into memory; may keep an offline cache |
| Access decision at a reader | Never | Decides locally with `policy.Decide` |
| Badge-tier remote actions | Decides (over a KV snapshot) and publishes or writes the result | Executes the resulting `cmd.grant` / `cmd.output` like any other command |
| Hardware (readers, locks, door and aux inputs) | None | Drives all of it |
| Door alarms (`forced`, `held`, `no_entry`), intrusion trips, fire input | Projects, notifies | Detects and publishes |
| Commands (`cmd.grant`, `cmd.posture`, `cmd.output`) | Publishes them from the command routes and badge tier | Subscribes and applies them; posture overrides live only in its memory |
| Events stream (`ACC_EVENTS`) | Creates the stream; consumes it with four durables | Publishes taps, alarms and fire to it |
| `events` collection | Writes it (the audit projection) | Never sees it |
| Status shadow (`ACC_STATUS`) | Creates the bucket; projects it into `point_status` | Writes its own shadow keys |
| Heartbeats and liveness | Subscribes; writes `controllers.last_seen`/`status`; emits liveness events | Publishes a heartbeat |
| Arm-state | Owns the durable `areas.arm_override` (operator, badge and entry-disarm writes, one-shot release); emits arm-transition events | Resolves the effective state (override, schedule, standing) and trips intrusion while armed |
| Notifications and webhook | Sends all email and webhook POSTs | Sends nothing outside NATS |
| Control-plane audit (`audit_logs`) | Writes it | Never sees it |

---

## 2. Running It

`accessd` is driven by PocketBase's CLI. It reads its own config from
`$SA_CONFIG` (default `config/accessd.yaml`) plus `SA_` env overrides, as
described in the [Configuration Reference](configuration.md#1-how-config-loads).

### Commands

| Command | From | Does |
| :--- | :--- | :--- |
| `serve` | PocketBase | Applies pending migrations, then starts the HTTP server and everything in §3. Listens on `127.0.0.1:8090` unless you pass `--http` |
| `migrate` | PocketBase `migratecmd` | `up`, `down [n]`, `create <name>`, `collections`, `history-sync` over the Go migrations in `pbmigrations` |
| `superuser` | PocketBase | `upsert`, `create`, `update`, `delete`, `otp`, `ips` for the break-glass `_superusers` account. For example `./accessd superuser upsert <email> <pass>` |
| `demo-seed` | accessd | Seeds the Northwind Traders demo estate. Refuses to run without `--confirm`; `--events` (default 240) and `--seed` (default 20260831) tune the backdated history |

The PocketBase global flags apply to every command. `--dir` sets the data
directory and defaults to `accessd.dataDir` (`./pb_data`).

`migratecmd` runs with `Automigrate` on, so a collection edit made in the
PocketBase dashboard writes a new Go migration file into `pbmigrations`. Review
those files before committing them.

::: note NATS comes up only on `serve`
`migrate`, `superuser` and `demo-seed` touch only the database. The KV
mirror's hooks are bound on `serve`, so records those commands write reach
`ACC_POLICY` on the next `serve`, when the boot reconciliation publishes the
whole graph.
:::

### What `serve` brings up

Some pieces are registered before PocketBase starts, so they exist for every
command, though their hooks and crons only fire while serving:

- the `audit_logs` change log and its prune cron (`internal/changelog`), which
  also carries the `users.permissions` escalation guard;
- the `cardholders` auth-collection guards (`badgeapi.RegisterGuards`);
- the `events` prune cron (`audit.RegisterPrune`);
- the `demo-seed` command.

On `serve`, in this order:

1. The embedded console at `/` and the branding route at `/branding/*`.
2. The metrics collector, and the metrics server if `metrics.enabled`.
3. The NATS connection. accessd **fails fast**: if no server is reachable, the
   connect returns an error and `serve` exits.
4. `ACC_POLICY`, `ACC_STATUS` and `ACC_EVENTS`, created or updated.
5. The KV mirror's hooks, then a full reconciliation of the policy graph.
6. The four `ACC_EVENTS` durables and the reminder sweep: audit, notify,
   repage, webhook, disarm.
7. The controller health monitor.
8. The HTTP routes: command bridge, models, simulator, badge tier.
9. The one-shot disarm release and the visitor credential sweep.
10. The status projector.

Steps 4 to 6 share a two-minute timeout, and each bucket or stream call has its
own 5-second limit.

An error from steps 3 to 7 or step 10 stops `serve`. Errors inside a step that
is per-record (one key that will not publish, one row that will not project)
are logged and skipped.

### Ports and paths

| What | Where |
| :--- | :--- |
| Management console (embedded Vue SPA) | `/` on the PocketBase listener, `127.0.0.1:8090` by default. Unknown paths without a file extension return `index.html` so client routes resolve |
| PocketBase admin | `/_` |
| PocketBase REST API | `/api/` |
| Branding overlay | `/branding/*` |
| Prometheus metrics | A separate listener, `metrics.address` (`:2113` by default) at `metrics.path` (`/metrics`), only when `metrics.enabled` is true. See [Configuration Reference](configuration.md#4-metrics) |
| Data directory | `accessd.dataDir`, default `./pb_data` (database and uploads) |

The console is compiled into the binary with `//go:embed`, so there is no
`pb_public` directory.

### NATS resources

accessd is the only binary that creates these. Names come from config (see
[Resource Names](configuration.md#6-resource-names)).

| Resource | Default name | accessd | Used for |
| :--- | :--- | :--- | :--- |
| KV bucket | `ACC_POLICY` | Creates or updates; writes | The policy mirror. Controllers bind it read-only |
| KV bucket | `ACC_STATUS` | Creates or updates; watches | The device shadow. Controllers write it |
| JetStream stream | `ACC_EVENTS` | Creates or updates (file storage); consumes | Events, on `acc.*.evt.fire` and `acc.*.*.*.evt.>` |

The stream's subjects are derived from `subjects.app`, so `serve` rewrites them
to match on every boot. accessd sets only the name, subjects and storage, and no
retention limits.

::: warning The controller cannot create these
A controller binds `ACC_POLICY` read-only. Until accessd has served once
against that NATS account, the bind fails with "accessd creates it on first
serve" and the controller keeps retrying. Start accessd first on a new
deployment.
:::

---

## 3. Background Components

Everything below runs inside the `serve` process and stops when it terminates.

| Component | Package | Trigger or schedule | Writes | Config |
| :--- | :--- | :--- | :--- | :--- |
| KV mirror | [`internal/mirror`](https://github.com/stone-age-io/access-control/blob/main/internal/mirror/mirror.go) | After-commit record hooks; full sync at boot | `ACC_POLICY` keys | `policy.bucket` |
| Audit projection | [`internal/audit`](https://github.com/stone-age-io/access-control/blob/main/internal/audit) | Durable `acc-audit` | `events` rows | `events.stream` |
| Events prune | `internal/audit` | Cron, daily 03:00 UTC | Deletes `events` rows | `accessd.eventRetentionDays` (off by default) |
| Status projector | [`internal/status`](https://github.com/stone-age-io/access-control/blob/main/internal/status/projector.go) | KV watch on `ACC_STATUS` | `point_status` rows; `area` `evt.state` events | `status.bucket` |
| Controller health | [`internal/health`](https://github.com/stone-age-io/access-control/blob/main/internal/health/monitor.go) | Heartbeat subscription; staleness sweep every `controllerOfflineAfter / 3` (minimum 1s) | `controllers.last_seen`/`status`; `ctrl` `evt.state` events | `accessd.controllerOfflineAfter` (45s) |
| Notification sink | [`internal/notify`](https://github.com/stone-age-io/access-control/blob/main/internal/notify) | Durable `acc-notify` | Email | None (opt-ins are data) |
| Reminders | [`internal/repage`](https://github.com/stone-age-io/access-control/blob/main/internal/repage) | Every 5 minutes | Email; `events.repage_count` | None |
| Webhook sink | [`internal/webhook`](https://github.com/stone-age-io/access-control/blob/main/internal/webhook) | Durable `acc-webhook` | HTTP POST | `accessd.webhookURL` |
| Entry-disarm sink | [`internal/disarm`](https://github.com/stone-age-io/access-control/blob/main/internal/disarm) | Durable `acc-disarm` | `areas.arm_override`; `audit_logs` row | None (per-portal opt-in) |
| One-shot disarm release | [`internal/armrelease`](https://github.com/stone-age-io/access-control/blob/main/internal/armrelease) | Every minute | Clears `areas.arm_override` | None |
| Visitor credential sweep | [`internal/badgesweep`](https://github.com/stone-age-io/access-control/blob/main/internal/badgesweep) | At start, then hourly | `credentials.status` → `revoked` | None |
| Change log | [`internal/changelog`](https://github.com/stone-age-io/access-control/blob/main/internal/changelog/changelog.go) | PocketBase `*Request` hooks | `audit_logs` rows | None |
| Change-log prune | `internal/changelog` | Cron, daily 03:00 UTC | Deletes `audit_logs` rows, up to 1000 per run | `accessd.auditRetentionDays` (365) |

PocketBase's cron runs in UTC, so both prunes run at 03:00 UTC.

### The four durables

All four are separate consumers on `ACC_EVENTS` with their own delivery
position, so a stalled SMTP server or webhook receiver never holds back the
projection, and a redelivery to one never re-sends through another.

| Durable | Starts from | Filter | Redelivery |
| :--- | :--- | :--- | :--- |
| `acc-audit` | The start of the stream (`DeliverAll`) | `acc.*.evt.fire`, `acc.*.*.*.evt.>` | Backs off 1s → 2min (about six minutes in total), then `Term` after nine deliveries |
| `acc-notify` | New messages (`DeliverNew`) | `acc.*.*.*.evt.alarm`, `acc.*.evt.fire`, `acc.*.ctrl.*.evt.state` | `Nak`; `MaxDeliver` 5, `AckWait` 30s |
| `acc-webhook` | New messages (`DeliverNew`) | Same as notify | `Nak`; `MaxDeliver` 8, `AckWait` 60s, 10s request timeout |
| `acc-disarm` | New messages (`DeliverNew`) | `acc.*.*.*.evt.tap` | `Nak`; `MaxDeliver` 5, `AckWait` 30s |

`DeliverNew` decides only where a durable starts the first time it is created.
After that each durable keeps its position on the NATS server (§5).

### What each one does

- **KV mirror.** One PocketBase record becomes one KV key, for `locations`,
  `schedules`, `controllers`, `portals`, `access_groups`, `roles`,
  `cardholders`, `credentials`, `holidays`, `aux_input`, `aux_output` and
  `areas`. A rename deletes the old key; a delete removes the key; a put whose
  bytes match what KV already holds is skipped, so a no-op edit does not wake
  every controller. At boot, `SyncAll` publishes every record (32 puts in
  parallel) and **prunes any key with no backing record**, which covers
  migration-seeded data and changes made while accessd was down. Key and value
  shapes: [Policy KV](protocol.md#8-policy-kv-acc_policy).
- **Audit projection.** Writes each event as an `events` row, idempotent on
  `stream_seq`. Column mapping and the `source` rules:
  [Audit Projection](protocol.md#11-audit-projection).
- **Status projector.** Watches `ACC_STATUS` into `point_status`. At each
  watch sync it deletes rows whose key no longer exists. When an `area` row's
  state changes it publishes `acc.{location}.area.{code}.evt.state`, one per
  participating controller; a key's first report is not a transition. See
  [Status KV](protocol.md#9-status-kv-acc_status) and
  [Events accessd publishes](protocol.md#events-accessd-publishes).
- **Controller health.** Each heartbeat on `acc.*.ctrl.*.heartbeat` stamps
  `last_seen` and sets `status: online`. A heartbeat from a code with no
  `controllers` record is counted and ignored, never auto-created. The sweep
  marks an `online` controller `offline` once its `last_seen` is older than
  `controllerOfflineAfter`. Each online↔offline flip publishes
  `acc.{location}.ctrl.{code}.evt.state`; heartbeats themselves never reach the
  events stream.
- **Notification sink.** Emails on alarms, fire and controller-offline when
  both a source opt-in and an operator opt-in line up, through PocketBase's
  mail settings. See [Notifications & Webhook](protocol.md#12-notifications-webhook)
  and [Notifications](configuration.md#8-notifications).
- **Reminders.** Re-sends an urgent alarm (`forced`, `intrusion`, `fire`,
  `controller_offline`) still unacknowledged after 15 minutes, at most twice,
  looking back 24 hours. It reads the `events` projection, not the stream, and
  uses the same send path as the sink.
- **Webhook sink.** POSTs each pageable event as JSON. Inert (it acks and skips)
  while `accessd.webhookURL` is empty. Redirects are never followed.
- **Entry-disarm sink.** On an allowed tap that carries a credential, at a
  portal with `disarm_on_grant` and an `area`, it writes
  `arm_override: disarmed` and an `audit_logs` row with
  `actor_email: entry-disarm`. It skips an area that is already overridden to
  disarmed or can never be armed. See
  [Entry-disarm](protocol.md#entry-disarm).
- **One-shot disarm release.** Clears a disarm override on a scheduled area
  once its base arm-state (schedule and standing, override excluded) is
  disarmed, reading the policy KV each minute. An area with no auto schedule
  keeps its override until an operator clears it. See
  [One-shot release](protocol.md#one-shot-release).
- **Visitor credential sweep.** Marks an expired *visitor* credential
  `revoked`. Expiry is already enforced at the edge by `policy.Decide`, so this
  keeps the control plane accurate and does not enforce anything. It never
  deletes a person and leaves staff credentials alone.
- **Change log.** Records API-driven edits to the policy collections and
  operator logins in `audit_logs`. accessd's own `app.Save` writes (heartbeats,
  projections, the mirror) are not API requests and do not appear. See
  [Control-Plane Audit Log](operators.md#8-control-plane-audit-log-audit_logs).

::: note Rate limits are PocketBase settings
The default limits on the badge routes and the `cardholders` auth endpoints
are written by migrations into PocketBase's settings, not enforced by accessd
code. Change them in `/_` under **Settings → Rate limits**. See
[Rate Limits](configuration.md#9-rate-limits).
:::

---

## 4. HTTP Surface

Beyond PocketBase's own collection API (governed by the collection rules in
[Operators & Authorization](operators.md#3-collection-rules)), accessd adds
these routes. Every operator route binds `authz.RequireOperatorAuth()`, which
admits a `users` record or a superuser and nothing else; the capability column
is then checked in the handler.

**Command bridge** ([`internal/commandapi`](https://github.com/stone-age-io/access-control/blob/main/internal/commandapi)):

| Route | Requires | Effect |
| :--- | :--- | :--- |
| `POST /api/portals/{id}/grant` | `command` | Publishes `cmd.grant` |
| `POST /api/portals/{id}/posture` | `command` | Publishes `cmd.posture` |
| `POST /api/aux-outputs/{id}/output` | `command` | Publishes `cmd.output` |
| `POST /api/events/{id}/ack` | `command` | Writes the ack fields on an `events` row |
| `POST /api/areas/{id}/arm` · `/disarm` · `/arm-clear` | `command` | Writes `areas.arm_override` |

**Operator tools:**

| Route | Requires | Effect |
| :--- | :--- | :--- |
| `GET /api/models` | any operator | Hardware-model catalogue for the I/O map ([`internal/modelsapi`](https://github.com/stone-age-io/access-control/blob/main/internal/modelsapi)) |
| `POST /api/simulate` | any operator | Runs `policy.Decide` over a fresh `ACC_POLICY` snapshot; publishes nothing ([`internal/simulateapi`](https://github.com/stone-age-io/access-control/blob/main/internal/simulateapi)) |

**Badge tier** ([`internal/badgeapi`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi)):

| Route | Who |
| :--- | :--- |
| `GET /api/badge/me` | A `cardholders` record, or an operator (resolved through `cardholders.operator`) |
| `POST /api/badge/unlock/{portalId}` | A `cardholders` record |
| `POST /api/badge/areas/{areaId}/arm` · `/disarm` | A `cardholders` record |
| `POST /api/badge/outputs/{outputId}/pulse` | A `cardholders` record |
| `GET /api/badge/live` | A `cardholders` record |
| `POST /api/badge/password` | A `cardholders` record |
| `POST /api/badge/visitors` · `/{id}/revoke` | Operator with `enroll` |
| `POST /api/badge/invite/{id}` | Operator with `enroll` |
| `GET /api/badge/preview/{id}` | Operator with `enroll` |

The holder actions decide over a policy snapshot cached for 3 seconds. What each
route returns and audits is in [Badge routes](operators.md#badge-routes) and
[Badge Actions](protocol.md#5-badge-actions).

**Unauthenticated:**

| Route | Effect |
| :--- | :--- |
| `GET /branding/{path}` | Files from `branding.dir`. With no overlay, `theme.css` is empty and `branding.json` is `{}`; anything else is 404. Paths containing `..` are rejected. See [Branding](configuration.md#10-branding) |
| `GET /{path...}` | The embedded console |
| `GET /api/health` | PocketBase's built-in health check |

The full operator route and capability matrix is in
[Operator Routes](operators.md#4-operator-routes).

---

## 5. Failure and Restart

### When NATS drops

The client reconnects according to `nats.maxReconnects` (forever by default)
and `nats.reconnectWait`. See
[NATS Connection](configuration.md#2-nats-connection).

- **Status projector.** On reconnect accessd stops the `ACC_STATUS` watcher, the
  projector re-creates it, and `WatchAll` re-delivers every key, so
  `point_status` fully re-syncs.
- **Controller health.** No heartbeats arrive, so once `controllerOfflineAfter`
  passes the sweep marks every controller offline, and each comes back online
  on its next heartbeat after the reconnect. The record write does not depend on
  the liveness event; a failed publish is logged and dropped.
- **Durables.** Messages stay on the stream and are delivered after the
  reconnect from each durable's position.
- **Command and badge routes.** They publish over core NATS, fire-and-forget.
  Nothing retries a command.

::: warning Edits made while NATS is down do not reach KV until later
The mirror's KV write runs after the record commits. If it fails, the error is
logged and the record stays saved, but nothing retries it on reconnect. The
key is corrected by the next edit to that record or by the boot `SyncAll`. If
you edited policy during an outage, restart accessd once NATS is back.
:::

### When accessd is down

Controllers do not need accessd to make decisions:

- They keep deciding taps from their in-memory policy, and from their offline
  cache across a reboot if `policy.cache` is on. See
  [Offline config cache](configuration.md#offline-config-cache).
- Their events land in `ACC_EVENTS`, which lives on the NATS server. Nothing is
  lost while accessd is away.
- Their status keys and heartbeats keep publishing; nothing records them until
  accessd returns.

What stops: the console, policy edits, commands, the badge tier, email and
webhook delivery, entry-disarm, liveness tracking and the sweeps.

### What a restart does

| Piece | On the next `serve` |
| :--- | :--- |
| `ACC_POLICY` | `SyncAll` republishes every record and deletes keys with no record |
| `events` | `acc-audit` resumes from its position and projects the backlog; `stream_seq` skips anything already written |
| Email, webhook, entry-disarm | Each durable resumes from its position, so events published during the outage are processed late rather than skipped |
| `point_status` | `WatchAll` re-delivers every key; rows with no key are deleted. An area whose state changed while accessd was down produces one transition per changed key, compared against the last projected row |
| `controllers.status` | Heartbeats set boxes online; the sweep marks any box that stopped meanwhile offline |
| Visitor credentials | The sweep runs once at start |

The notify sink's short-lived duplicate guard is in memory and starts empty.

::: note The projections are rebuildable
`events` and `point_status` are read models of `ACC_EVENTS` and `ACC_STATUS`.
accessd has no rebuild command, but `acc-audit` is created with
`DeliverAll`, so a durable that no longer exists is recreated on the next
`serve` and replays the stream, with `stream_seq` preventing duplicates.
:::

---

## 6. Where to Go Next

- The edge half and its offline behaviour: [Edge Controller (access-controller)](controller.md)
- Subjects, KV shapes and the audit projection: [Wire Protocol](protocol.md)
- Every config key, default and env var: [Configuration Reference](configuration.md)
- Operator capabilities, collection rules and the badge tier: [Operators & Authorization](operators.md)
- Boards, drivers and readers: [Hardware & Readers](hardware.md)
- What the system is and how to build it: [Access Control](../README.md)
