---
path: helpdesk/data-model
nav_order: 20
---
# Data Model & Access Rules

This page lists every collection in the helpdesk, its fields, its access rules
and the unique indexes the app relies on. The schema is Go code in
`migrations/`: `1800000000_init.go` creates the core collections and the
baseline rules, and later timestamped migrations add collections and amend
specific pieces. When two migrations touch the same rule, the later one wins.
The migrations are the source of truth; this page is the readable summary. For
how the pieces fit together, see [Overview](overview.md).

---

## 1. Rule Building Blocks

Tenancy is **plain PocketBase collection rules**, not pb-tenancy. Every rule is
built from three constants in `internal/authz`:

| Constant        | Expands to                                                     |
| --------------- | -------------------------------------------------------------- |
| `StaffRule`     | `@request.auth.collectionName = 'staff'`                       |
| `AdminRule`     | `StaffRule && @request.auth.role = 'admin'`                    |
| `RequesterRule` | `@request.auth.collectionName = 'users'`                       |

The security model comes down to one sentence: **staff see everything; a
requester sees only their own company's non-internal data.**

---

## 2. Identity

Every request comes from one of two auth collections. Rules tell them apart
with `@request.auth.collectionName`.

Both collections set `emailVisibility = true` on create (`internal/authfix`).
PocketBase hides emails by default, which would break the staff roster and the
pickers.

### `staff`

Agents and admins. Staff work across every customer.

| Field    | Notes                                                    |
| -------- | -------------------------------------------------------- |
| `name`   | Self-editable.                                           |
| `role`   | `agent`, `admin` or `field`.                             |
| `active` | Not self-editable.                                       |
| `avatar` | Single image, optional. Self-editable.                   |

Rules:

- **AuthRule:** `active = true`.
- **read:** any staff member can read the roster (the assignee pickers need
  it).
- **create/delete:** admins only.
- **self-update:** a staff member may change profile fields (`name`, `avatar`)
  but not their own `role` or `active`. An `:isset` body guard blocks those.
- **ManageRule:** `AdminRule`, so admin staff can set an account's email and
  password from the SPA without being PocketBase superusers.

::: note `field` is not a permission boundary
A field agent is ordinary staff: cross-customer, subject to every rule an
`agent` is, and still gated out of the admin surfaces by `AdminRule`. The role
only tells the SPA to open the mobile, on-site shell (landing on today's
visits) instead of the desk app. The `staff` / `users` split is a real
boundary, because requesters have a different scope. If `field` ever needs to
be restrictive, that is a rule change, not a role rename.
:::

Migrations: `1802000000` (ManageRule), `1807000000` (`avatar`), `1816000000`
(the `field` role).

### `users`

Requesters. This is the default PocketBase collection, repurposed. Each
requester belongs to one customer.

| Field      | Notes                                                              |
| ---------- | ------------------------------------------------------------------ |
| `customer` | Relation, **required**. Not self-editable.                         |
| `active`   | Not self-editable.                                                 |
| `avatar`   | Single image, optional.                                            |
| `phone`    | The requester's direct line, the number a dispatcher or tech calls. Self-editable in the profile modal. |

Rules:

- **AuthRule:** `active = true && customer != ''`.
- **read:** a requester sees only themselves. Staff see everyone.
- **create/delete:** admins only.
- **self-update:** cannot reassign `customer` or toggle `active`.
- **ManageRule:** `AdminRule`, as on `staff`.

Migrations: `1812000000` (`phone`).

---

## 3. Customers

### `customers`: the company directory

| Field                    | Notes |
| ------------------------ | ----- |
| `name`                   | Unique. |
| `active`                 | |
| `code`                   | Optional, unique when set. The **tenant token of the ecosystem's public namespace** (ADR 0002 in `platform-docs`). Subject token 2 carries it in both directions, and a consumer uses it to join helpdesk events to platform data. |
| `platform_org_id`        | Unique when set. Not the subject token. It answers a different question, "is this customer a platform organization", which matters because a desk's customer list is a **superset** of the control plane's. |
| `webhook_token`          | Hidden. The inbound webhook secret. |
| `email_domain`           | Optional, unique when set. The customer's own mail domain, used to route inbound email from an unregistered sender to this tenant. `internal/customers` normalizes it and blocks shared providers such as gmail.com. |
| `notes`                  | |
| `show_time_to_requester` | Bool, default false. See below. |

Rules: read `StaffRule`; create/update/delete `AdminRule`. `webhook_token` is a
hidden field, so it never leaves the server through the record API. Staff
reveal or rotate it with `POST /api/helpdesk/customers/{id}/webhook-token`.

**Showing time to requesters.** `show_time_to_requester` is a per-customer
opt-in (default off). It lets the portal show the **aggregate** time logged on
that customer's tickets, never the per-entry rows. It is off by default because
exposing hours is an MSP billing-model choice and hard to walk back. It gates
two routes:

- `GET /api/helpdesk/tickets/{id}/time-total` (`internal/timeentries`). Staff
  always get the full total. A requester gets it only for their own customer's
  ticket and only when the flag is on, and the requester's figure is
  **billable-only** (entries flagged `non_billable` are excluded), so it
  matches what the customer is invoiced.
- `GET /api/helpdesk/reports/time-by-ticket?from=&to=`, the batch companion
  that backs the portal's Service Summary. It returns
  `{enabled, minutes: {ticketId: N}}` under the same policy
  (`ResolveTimeScope`), so it exposes nothing a caller could not get by calling
  `time-total` once per ticket; it saves the round trips. An opted-out
  requester gets `enabled: false` and an empty map, not a 403, and the portal
  hides its hours section instead of showing a misleading zero. Customer scope
  is a relation hop to the ticket, since `time_entries` has no customer of its
  own. Results are keyed by ticket id, not pre-grouped, so the grouping lives
  in one place: the page, which has the tickets expanded.

Migrations: `1810000000` (`show_time_to_requester`), `1823000000`
(`email_domain`), `1828000000` (`code`).

---

## 4. Tickets

### `tickets`: the unit of work

| Field                | Notes |
| -------------------- | ----- |
| `number`             | Unique int, assigned by the create hook. |
| `customer`           | Required. |
| `title`              | Required. |
| `body`               | |
| `status`             | `open`, `in_progress`, `waiting`, `resolved` or `closed`. Default `open`. |
| `priority`           | `low`, `normal`, `high` or `urgent`. Default `normal`. |
| `assignee`           | → staff. |
| `requester`          | → users, optional. Machine tickets have none. |
| `source`             | `portal`, `agent`, `nats`, `webhook`, `email` or `maintenance`. Default `agent`. `maintenance` marks a ticket opened by the preventive-maintenance scheduler. |
| `origin_subject`     | The full hub-side NATS subject. Provenance for machine tickets. |
| `dedupe_key`         | Unique per customer when set. Ingestion idempotency; also carries the inbound email `Message-ID`. |
| `attachments`        | Up to 6 files, 10 MB each. |
| `category`           | → ticket_categories, optional. |
| `type`               | `reactive` or `planned`. Default `reactive`. |
| `project`            | → projects, optional. Groups planned and reactive work. |
| `location`           | → locations, optional. The structured place, and a reporting axis. |
| `location_note`      | Free text. Dispatch hints, or the unmatched-code fallback from machine intake. |
| `thing`              | → things, optional. The structured thing, the second reporting axis. |
| `thing_note`         | Free text. A scratch description, or the unmatched-code fallback. |
| `estimated_minutes`  | Int ≥ 1, optional. The staff effort estimate. Compared against the logged `time_entries` total per ticket and summed per project at read time (see `projects`). Not the same as `visits.duration_minutes`, which is a *calendar block*, not an *effort estimate*. |
| `awaiting_requester` | Bool. See below. |
| `resolved_at`        | Datetime, optional. Nil unless the ticket is currently resolved. See below. |
| `due_at`             | Date, optional. The target date. See below. |
| `maintenance_plan`   | → maintenance_plans, optional. Set only on a generated ticket. |

The `internal/tickets` create hook sets the defaults above when a field is
empty.

- **`awaiting_requester`** is a queryable flag that `internal/tickets`
  maintains. It backs the portal's "needs your reply" prompt, list chip and
  dashboard tile. Only staff set it, explicitly: it is set when a public staff
  comment ticks *Request a reply* (`ticket_comments.requests_reply`), and
  cleared on a requester reply or on resolve or close. `planned` tickets are
  excluded. It is not a source of truth.
- **`resolved_at`** is stamped by the `internal/tickets` guard when the ticket
  enters `resolved` and cleared when it leaves, like `completed_at` on visits.
  It gives the auto-close cron a trustworthy age.
- **`due_at`** is the date somebody agreed to, and **not an SLA clock**:
  nothing measures it and nothing escalates off it. Only a human writes it, or
  the maintenance generator copying its plan's `next_due`. SLA timers and
  escalation are out of scope. It is audited like the other workflow fields.
- **`maintenance_plan`** is the "is the last one still open" guard, the
  completion hook's way back to the plan, and the source of the
  generated-ticket history on the plan detail view.

**Two-stage terminal.** `resolved` and `closed` are not synonyms:

- `resolved` is a grace window. A requester comment reopens it.
- `closed` is final. Requesters cannot comment (see
  [`ticket_comments`](#ticket_comments-the-thread)), and a reply never reopens
  it.

A daily cron (`tickets.AutoCloseResolved`, wired in `cmd/helpdesk`) moves
tickets left `resolved` past `auto_close_resolved_days` (config, default 7; `0`
disables) to `closed`, and sends no mail. Both statuses count as inactive in
every "active" query (`status != 'resolved' && status != 'closed'`), so the
queues treat them the same. `waiting` is an agent-set "blocked on a third
party" status, separate from `awaiting_requester`.

Rules:

- **read:** `StaffRule || (RequesterRule && customer = @request.auth.customer)`.
  A requester sees only their own company's tickets.
- **create:** staff freely. A requester only for their own customer, with
  `requester` = themselves, no `assignee`, `source = 'portal'`, and none of
  `category`, `type`, `project`, `estimated_minutes`, `due_at` or
  `maintenance_plan`. The create rule pins these so the portal cannot forge
  them: classification, grouping and the effort estimate are triage, which is
  a staff action; a target date is a commitment staff make; and attaching a
  ticket to a service schedule is not a requester's call.

  `location` and `thing` are the exception. A requester **may** set both,
  because they are facts about where the work is and what it is on, and at
  intake the requester is the only one who knows them. Each is guarded by a
  tenant hop instead of an `:isset` ban:

  ```
  @request.body.location = '' || @request.body.location.customer = @request.auth.customer
  ```

  The `_note` fallbacks are **unguarded**. They are harmless free text, and
  they are how a requester names a location or thing that is not in the
  catalog, which is most of them.
- **update:** `StaffRule`. Requesters never edit ticket fields; they act
  through comments.
- **delete:** `AdminRule`.

::: warning Both halves of the location and thing guard are needed
PocketBase checks that a relation id *exists*, not that it is yours. Without
the tenant hop, a requester could attach another customer's location to
their ticket, and the ticket detail would expand and show it back to them.
The `= ''` term must also be present, and must come first. `:isset` means
"the key was submitted", so an untouched picker sending `location: ""` fails
an `:isset = false` guard, which would reject every ticket filed without a
location. `= ''` covers the absent case too, which is why the clause has two
terms, not three. `1825000000_portal_site_device_test.go` tests all of it
over real HTTP.
:::

Migrations: `1812000000` (adds or changes `type`, `project`, `location`,
`location_note`), `1815000000` (`estimated_minutes`), `1818000000`
(`awaiting_requester`), `1821000000` (`resolved_at`), `1823000000` (`email`
source), `1824000000` (`thing` and `thing_note`, replacing the free-text
`asset`), `1825000000` (requester may set `location` and `thing`), `1826000000`
(`type` values, formerly `issue` and `install`), `1829000000` (`maintenance`
source, `due_at`, `maintenance_plan`, and the requester ban on both),
`1830000000` (`dedupe_key` unique per customer).

### `ticket_categories`: classification

An admin-managed list of what tickets are about.

| Field        | Notes |
| ------------ | ----- |
| `name`       | Unique. |
| `key`        | Unique slug. The stable handle in queue filters and machine payloads, so renaming `name` never breaks them. |
| `active`     | Retire a category without deleting history. |
| `sort_order` | |
| `color`      | Hex, shown as a soft badge. |

It is a managed collection plus a relation, not a `select` field, because
admins manage it from the SPA. They add and retire categories with no code
deploy, and a rename touches one row (a select copies the value onto every
ticket). It also matches the app's grain. `thing_types` and
`location_types` follow the same pattern.

The ticket's two "what is this about" fields, `location` and `thing`, are
relations for the same reason. Free text cannot answer "every ticket for this
thing" or "which things burn the most hours". `things` is not an authored CMDB
that someone must keep true by hand. It is a curated **mirror** of the
platform's `things`, joined by `(customer, code)`, and its source of truth is
upstream.

Rules: read `StaffRule || RequesterRule`; create/update/delete `AdminRule`.
Staff read it for the picker. Requesters read it so a ticket's category
**badge** resolves in the portal; the taxonomy is non-sensitive labels.

Migrations: `1806000000` (collection), `1808000000` (requester read).

### `ticket_comments`: the thread

| Field                                | Notes |
| ------------------------------------ | ----- |
| `ticket`                             | Required, cascade delete. |
| `author_staff` **or** `author_user`  | Exactly one, matching the author's class. |
| `body`                               | Required. |
| `internal`                           | Bool. Staff-only working notes. |
| `attachments`                        | Up to 6 files, 10 MB each. |
| `requests_reply`                     | Bool. Staff tick *Request a reply*. Only a public comment by a staff author sets `tickets.awaiting_requester`, so the flag does nothing on a requester's comment. |
| `source_message_id`                  | Hidden text, unique when set. The inbound email `Message-ID`, so a redelivered reply cannot post a duplicate comment. Empty for UI and portal comments. |

Rules:

- **read:** `StaffRule || (RequesterRule && ticket.customer =
  @request.auth.customer && internal = false)`. Internal notes never reach the
  portal, and neither do their attachments (PocketBase gates file access by
  the record's view rule).
- **create:** staff set `author_staff` = themselves. A requester sets
  `author_user` = themselves, on their own company's ticket, and cannot set
  `internal` (guarded with `:isset`). A requester also **cannot comment on a
  `closed` ticket** (`@request.body.ticket.status != 'closed'`): closed is
  final, and a follow-up is a new ticket. Staff can still comment on closed
  tickets (their branch is unguarded).
- **update/delete:** `AdminRule`.

Migrations: `1819000000` (`requests_reply`), `1822000000` (the closed-ticket
guard), `1823000000` (`source_message_id`).

### `ticket_events`: the audit trail

One row per workflow-field change, written by `internal/activity`.

| Field                         | Notes |
| ----------------------------- | ----- |
| `ticket`                      | Cascade delete. |
| `field`                       | The field that changed. |
| `old_value` / `new_value`     | Stored already human-readable. |
| `actor_staff` / `actor_user`  | Who made the change. |
| `created`                     | |

Audited fields: `status`, `priority`, `assignee`, the classification and
grouping fields `category`, `type`, `project`, `location` and `thing`, and the
target date `due_at`. Relation values resolve to a label at write time
(category, location or thing name; project `#N Title`).

Rules:

- **read:** `StaffRule || (RequesterRule && field = 'status' &&
  ticket.customer = @request.auth.customer)`. Staff see the whole trail.
  Requesters see only **status** transitions on their own tickets, for the
  portal progress timeline. Every other event never matches for a requester:
  priority and assignee (staff names, the roster the portal hides), and
  category, type, project, location, thing and due_at. The actor relations stay
  staff-gated, so an actor expand is dropped for a requester.
- **create/update/delete:** no API rule. Only the server hooks write here, via
  `app.Save`, which bypasses collection rules, so the trail cannot be forged
  through the API.

Migrations: `1805000000` (collection), `1808000000` (requester status read).

---

## 5. Labor & Dispatch

### `time_entries`: the labor log

| Field          | Notes |
| -------------- | ----- |
| `ticket`       | Required, cascade delete. |
| `staff`        | Required. |
| `minutes`      | Required, int ≥ 1. |
| `work_date`    | Required. |
| `note`         | |
| `visit`        | → visits, optional. No cascade. |
| `non_billable` | Bool, default false. |

The ticket is the **canonical labor ledger**. `ticket` is required, so a
ticket's total is always `sum(minutes)` filtered by ticket. `visit` is an
optional *dimension* on an entry: when set, the entry is on-site (field) time,
which gives per-visit and field-vs-desk subtotals with no rollup machinery.
The visit relation does not cascade. Deleting a visit never deletes labor; the
entry keeps its ticket, and the dangling visit reference resolves to nothing.

`non_billable` marks labor that is not invoiced (rework, goodwill).
Billability belongs to the *labor*, not the *ticket*: one ticket often mixes
billable work with non-billable rework. Reports split on it (billable = total −
non_billable, plus a write-off rate), and the customer-facing time total (see
[Customers](#3-customers)) excludes it.

::: note Bools store the exception
A PocketBase bool has no unset state, so its zero value is false. Naming the
field `non_billable` makes the default mean *billable*, with no backfill, no
defaulting hook and no per-writer discipline; every writer, including a raw
API create, is safe. `things.retired` and `maintenance_plans.paused` follow
the same pattern.
:::

Rules: read `StaffRule` (staff only, for all operations). Create requires
`staff` = self. Update and delete are own entry or admin. Requesters never see
time entries.

Migrations: `1809000000` (`visit`), `1820000000` (`non_billable`).

### `time_sessions`: the running timer

| Field        | Notes |
| ------------ | ----- |
| `staff`      | Required. Unique: at most **one running timer per agent**. |
| `ticket`     | Required, cascade delete. |
| `visit`      | → visits, optional, no cascade. |
| `started_at` | Required. Server-stamped. |
| `note`       | |

A row means "this agent has a timer running". Stopping or canceling **deletes**
the row. The durable record is the `time_entries` row that `internal/timers`
creates from it on stop. So this is a front end to the labor log, *not* a
second ledger: it holds only the open interval's start and never keeps history.

The `internal/timers` create hook stamps `started_at` and ignores any client
value, so elapsed time is trustworthy. The stop route
`POST /api/helpdesk/timers/{id}/stop` turns the timer into a `time_entries` row
and deletes the session in one transaction. It rounds elapsed time to the
nearest 5 minutes, or uses a caller-supplied `minutes` override. With
`complete_visit` it also sets the attached visit to `completed` in the same
transaction (the `internal/visits` guard then stamps `completed_at`). Minute
precision is loose on purpose; the feature is about ergonomics, not the clock.

Rules: the same as `time_entries`. Read `StaffRule`, create requires `staff` =
self, update and delete own or admin. Requesters never see it.

Migrations: `1811000000` (collection).

### `visits`: lite dispatch

| Field              | Notes |
| ------------------ | ----- |
| `ticket`           | Required, cascade delete. |
| `assignee`         | → staff, optional. |
| `scheduled_at`     | Optional. |
| `status`           | `requested`, `scheduled`, `completed` or `canceled`. An empty status becomes `scheduled` if a time is set, else `requested`. |
| `location`         | Free text: dispatch directions. The structured location comes from the ticket's `location` relation. |
| `completed_at`     | Stamped by the guard when the visit enters `completed`, cleared if it leaves. A supplied value is kept, so it can be back-dated. |
| `notes`            | |
| `duration_minutes` | Int, optional. The **scheduled** block length. |

`duration_minutes` is planned time. With `scheduled_at` it makes a visit a
calendar block rather than a point in time. **Actual** labor lives in
`time_entries`, tagged with the visit.

`assignee` and `scheduled_at` are optional in the schema, so a `requested`
visit can exist before a tech or time is known. The one invariant, that a
`scheduled` visit has **both**, is enforced by the `internal/visits` guard
hook, not the schema.

Rules: read `StaffRule || (RequesterRule && ticket.customer =
@request.auth.customer)`. A requester sees visits on their own tickets
(someone has to unlock the door for the tech), but the portal never expands
`assignee`, so the MSP roster stays hidden. All writes are `StaffRule`.

Migrations: `1803000000` (relaxed), `1804000000`
(extended), `1809000000` (`duration_minutes`).

---

## 6. Places & Things

### `locations`: customer places

| Field                  | Notes |
| ---------------------- | ----- |
| `customer`             | Required. |
| `code`                 | Optional. The platform Location join key. Unique per customer when set. |
| `name`                 | Required. |
| `address`              | |
| `notes`                | Gate codes, access directions. |
| `contact`              | |
| `contact_phone`        | |
| `lat` / `lng`          | Optional coordinates, set from the map picker in the Locations detail view. |
| `type`                 | → location_types. |
| `parent`               | Self-relation, no cascade delete. |
| `metadata`             | |

Machine intakes resolve a payload `location_code` by `(customer, code)` and set
the ticket's `location` relation. An unmatched code falls back to
`location_note`, with no auto-created stub ([Wire Protocol](protocol.md)).
`lat`/`lng` back a maps "Navigate" deep link on the ticket; coordinates are
preferred, with `address` as the fallback. `type`, `parent` and `metadata`
match the platform's `locations`, so an export seeds without translation.

`parent` exists because the seeder writes it, not because the UI needs it.
Dispatch is per location, and a ticket naming a `thing` already has the
precision a room-level hierarchy would give. PocketBase has no cycle detection
for self-relations, so the parent picker excludes the record *and its whole
subtree*, and any code that walks the chain carries a visited set and a depth
cap. A dangling `parent` (a deleted location) shows blank, like
`tickets.category`.

A location is a relation, not free text, because a project revisits the same
place over weeks, so places recur. It is still **not** a CMDB: it is a place
with an address and access notes, not an asset catalog.

Rules:

- **read:** `StaffRule || (RequesterRule && customer = @request.auth.customer)`.
  A requester sees their own company's locations.
- **create/update:** `StaffRule`. Any agent manages locations day to day from
  the Directory.
- **delete:** `AdminRule`, the one destructive operation against a location
  that tickets, projects and visits reference.

Migrations: `1812000000` (collection), `1813000000` (`lat`/`lng`, staff
update), `1824000000` (`type`, `parent`, `metadata`).

### `things`: the thing catalog

| Field      | Notes |
| ---------- | ----- |
| `customer` | Required. |
| `code`     | Optional. The platform Thing join key. Unique per customer when set. |
| `name`     | Required. |
| `type`     | → thing_types. |
| `location` | → locations. |
| `notes`    | |
| `retired`  | Bool. |
| `metadata` | JSON. |

This mirrors a subset of the platform's `things`, without its whole identity
half (`password`, `tokenKey`, `email`, `nats_user`, `nebula_host`). Those are
control-plane fields and the helpdesk must never hold them.

Machine intakes resolve a payload `thing_code` by `(customer, code)` and set
the ticket's `thing`. An unmatched code falls back to `thing_note`, with no
auto-created stub ([Wire Protocol](protocol.md)). This is the same contract as
`location_code`, and the two resolve independently: a resolved thing does
**not** fill in the ticket's location, even though the thing has one.

**Codes are QR labels.** `code` on both `things` and `locations` is also the
**entire payload of the printed QR label** (ADR 0002: no host, no customer, no
kind token), and so it is what `/staff/scan` resolves. A record with no code
gets no label button, because the payload *is* the code. Codes are resolved
**globally, then disambiguated**, never within a customer context: `staff`
have no `customer` field, so there is no ambient tenant, and `DOOR-1` is a code
every customer invents on its own. The `(customer, code)` indexes on the two
collections are separate, so one customer may hold both a location and a thing
with the same code. The scanner searches both and shows a picker rather than a
confident wrong answer.

**A superset of the platform's catalog.** `code` is nullable because MSP work
covers printers, door strikes and customer switches that were never onboarded
to the control plane. There is no live sync, and there cannot be one: the
platform publishes no event stream for things, and the only read paths are a
control-plane credential or an edge KV mirror. Bulk loading is an operator-run
export then seed, which is why the shape stays faithful.

`retired`, not the platform's `active`, because a Go bool's zero value is
`false`: an `active` field would make every hand-created row arrive inactive
and be skipped by any `active = true` filter. A seeder maps
`retired = !active`.

Rules: read `StaffRule || (RequesterRule && customer = @request.auth.customer)`;
create/update `StaffRule` (any agent curates inventory, and the ticket form
creates things inline); delete `AdminRule` (tickets reference things, and
retiring is almost always the better move).

Migrations: `1824000000` (collection).

### `thing_types` and `location_types`: classifiers and metadata schemas

The two collections have the same shape:

| Field             | Notes |
| ----------------- | ----- |
| `customer`        | Required. |
| `code`            | Join key, unique per customer when set. |
| `name`            | Required. |
| `description`     | |
| `metadata_schema` | JSON. |

The platform's versions differ only in fields that are pure NATS contract
(`capabilities`, `subject_prefix`, `operations`, `nats_role`), and none of
those cross the boundary. They stay two collections because that is the
platform's shape, which keeps an export then seed a 1:1 map.

`metadata_schema` is why they exist. It is a JSON Schema naming the keys that
records of that type track, so `metadata` does not turn into a bag of drifting
key spellings (`serial` / `Serial` / `sn`). A type with a schema gives its
records a typed metadata form. A type without one falls back to free-form
key/value rows, which is why a schema with no properties is stored as `null`
rather than `{type:'object',properties:{}}`. Schemas are **authored upstream**
in the platform console and edited here as raw JSON, parse-validated before
save.

Rules: read `StaffRule || (RequesterRule && customer = @request.auth.customer)`,
because a requester's ticket may show a typed metadata field, so the schema
must be readable; create/update/delete `AdminRule`, like `ticket_categories`.

Migrations: `1824000000` (both collections).

---

## 7. Planning

### `maintenance_plans`: preventive-maintenance schedules

The ticket this plan opens, the triage it stamps on each one, and the schedule:

| Field               | Notes |
| ------------------- | ----- |
| `customer`          | Required. |
| `title`             | Required. The generated ticket's title. |
| `body`              | The generated ticket's body. |
| `category`          | Optional. |
| `assignee`          | Optional. |
| `priority`          | Optional. Ticket values; default `normal`. |
| `estimated_minutes` | Optional, int ≥ 1. |
| `thing`             | Optional, no cascade delete. |
| `location`          | Optional, no cascade delete. |
| `project`           | Optional, no cascade delete. |
| `interval_days`     | Required, int ≥ 1. |
| `anchor`            | `schedule` or `completion`. Default `schedule`. |
| `lead_time_days`    | Int ≥ 0. Generate this many days before `next_due`; `0` means on the day. |
| `next_due`          | Date. |
| `paused`            | Bool. |

The `internal/maintenance` create hook sets both defaults (`priority` and
`anchor`). The relations do not cascade, so retiring a thing never deletes the
schedule that services it.

Like `projects`, this is a planning layer **above** the ticket → visit → time
ledger. Its only output is an ordinary ticket, and you could drop the
collection without breaking anything already recorded; only future generation
would stop.

**The two anchors.** `anchor` picks the behaviour. Each anchor has exactly
**one writer** of `next_due`:

- `schedule`: the cron owns `next_due`, and advances it by whole
  `interval_days` at generation until it is in the future. "Quarterly" stays
  quarterly however late the visit ran. A plan dormant for a year yields one
  ticket on the next real slot, not a year of backlog.
- `completion`: the cron **parks** the plan (clears `next_due`), and the
  `internal/maintenance` ticket hook sets it to `resolved_at + interval_days`
  when the generated ticket resolves. "Every 90 days after last service."

An empty `next_due` therefore means *parked*, not "no date". The generator's
`next_due != ''` filter means a completion-anchored plan cannot stack up work.
The skip-if-still-open guard therefore only runs on `schedule` plans, and those
still advance when they skip: one missed inspection must not become four open
tickets, and a plan that never advances falls permanently behind its calendar.

`paused`, not `active`, for the same reason as `things.retired`: a Go bool's
zero value is `false`, so an `active` field would make every hand-created and
seeded plan arrive inactive and be skipped silently.

**Generation** runs from a daily cron (`maintenance_generate`, 03:45, after
`auto_close_resolved` so a plan whose ticket was auto-closed at 03:30 restarts
the same night) and on demand with `helpdesk maintenance-run`, the catch-up
path for an install that was down when the cron should have fired. It is
idempotent per occurrence through `tickets.dedupe_key` (see
[Uniqueness Indexes](#9-uniqueness-indexes)). It does **not** suppress
notifications: a new preventive ticket is real news, unlike the administrative
auto-close.

Rules: list/view/create/update `StaffRule`, delete `AdminRule`. This is the
same split `locations` has, because the person who learns that a location
needs quarterly service is usually the tech standing in it. Read is staff-only:
the generated tickets already give requesters everything that matters, and a
plan carries `assignee`, the MSP roster the portal's visit and project views
hide.

Migrations: `1829000000` (collection).

### `projects`: installation and field-work container

| Field                         | Notes |
| ----------------------------- | ----- |
| `number`                      | Unique int, assigned by the `internal/projects` create hook. |
| `customer`                    | Required. |
| `location`                    | → locations, optional. |
| `title`                       | Required. |
| `description`                 | |
| `status`                      | `pending`, `active`, `completed` or `canceled`. Default `pending`. |
| `start_date` / `target_date`  | The target window. |
| `lead`                        | → staff, optional. Accountable for the whole rollout, separate from the per-ticket assignees. |

The status is `pending`, not `planned`, so it does not collide with a ticket's
`type: planned`, which means something else and appears on the same project
detail screen.

A project is a planning and grouping layer **above** the ticket → visit → time
ledger. It groups 1..N tickets (often one `planned` ticket per trade, plus any
reactive tickets) and stores none of their execution data. Crew (lead ∪ ticket
and visit assignees), total logged time, and total estimated effort
(`sum(ticket.estimated_minutes)`, shown as an estimated-vs-logged bar) are all
**derived** at read time through relation-hop queries on `ticket.project`,
never stored. You could drop the collection and the helpdesk would still work.

Rules: read `StaffRule || (RequesterRule && customer = @request.auth.customer)`.
A requester sees their own company's projects; the portal shows the tickets and
visits but never the `lead` or crew. create/update `StaffRule`; delete
`AdminRule`.

Migrations: `1812000000` (collection), `1827000000` (`status` value `pending`,
formerly `planned`).

---

## 8. Notification Collections

`notification_templates`, `notification_dedupe` and `notification_send_log`
come from the kiosk notifier. See [Notifications](notifications.md).

Each template has two channels:

- `enabled`: email.
- `publish_nats`: publish a JSON envelope to
  `helpdesk.{customerCode}.events.{event_type}`. Token 2 is `customers.code`; a
  customer without a code is skipped, not published under a fallback.

`notification_send_log.channel` (`email` or `nats`) records which path each row
is for.

Rules:

- `notification_templates`: list/view/update `AdminRule`. No create or delete
  API rule; migrations seed the rows, and new event types ship as code.
- `notification_dedupe` and `notification_send_log`: read-only `AdminRule`.
  Only the notifier writes them (via `app.Save`), and the retention cron prunes
  them.

Migrations: `1814000000` (`publish_nats`), `1828000000` (token 2 is
`customers.code`).

---

## 9. Uniqueness Indexes

These unique indexes enforce behaviour; they are not just for performance.

- `tickets.number`: the collision backstop for the sequential-number hook.
- `tickets(customer, dedupe_key)` (partial, `!= ''`): absorbs NATS
  redelivery and webhook retries. A duplicate key is acked or answered without
  a second ticket. It is per customer because publishers choose keys
  independently, so a key means "the same ticket" only within one customer; a
  global index would let one tenant's key swallow another's event
  (`1830000000`). It also carries preventive-maintenance occurrences, as
  `pm:{planId}:{YYYY-MM-DD}` (`1829000000`). That is what makes the daily cron
  and a hand-run `helpdesk maintenance-run` safe to overlap: one plan
  occurrence can only produce one ticket.
- `customers.code` (partial, `!= ''`): the tenant token resolves to exactly
  one customer. Partial because a customer the platform never onboarded has no
  code until an operator assigns one, and SQLite treats `''` as a value.
- `customers.platform_org_id` (partial): one customer per platform org.
- `customers.webhook_token` (partial): a token selects exactly one customer.
- `customers.email_domain` (partial, `!= ''`): a mail domain maps to one
  tenant.
- `ticket_comments.source_message_id` (partial, `!= ''`): an inbound email
  `Message-ID` posts at most one comment (redelivery idempotency).
- `ticket_categories.name` / `.key`: categories are distinct; `key` is the
  stable filter and payload handle.
- `locations` (customer, code), `things` (customer, code), and
  `thing_types` / `location_types` (customer, code): all partial on
  `code != ''`. A code is unique **within a customer**, since it is the
  machine-intake and export-then-seed join key; two tenants both calling a
  reader `RDR-01` is correct. The partial predicate keeps a blank code legal,
  and blanks must stay legal: SQLite treats `''` as a value rather than NULL,
  and the catalog is a superset of the platform's, covering gear that was
  never onboarded and so has no code.
- `time_sessions.staff`: one running timer per agent, enforced by the database
  rather than by the stop route. This is what makes "start a timer" idempotent.
- `projects.number`: the collision backstop for the project-number hook.
- `notification_dedupe` (event, ref, UTC day): one send per event, ref and
  day.
- `notification_templates.event_type` and `customers.name`: one row per event,
  one company per name.

---

## 10. Where to Go Next

- How the pieces fit together: [Overview](overview.md)
- Machine intake payloads and subjects: [Wire Protocol](protocol.md)
- Templates, channels and the outbound envelope: [Notifications](notifications.md)
- Inbound mail and `email_domain` routing: [Email Ingestion](email-ingestion.md)
- Config keys such as `auto_close_resolved_days`: [Configuration Reference](configuration.md)
