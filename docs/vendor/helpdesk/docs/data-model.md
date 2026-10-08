---
path: helpdesk/data-model
nav_order: 20
---
# Data model & access rules

The schema is Go-as-code in `migrations/`. `1800000000_init.go` creates the
core collections and sets the baseline access rules; later timestamped
migrations add collections and amend specific pieces (the latest one to touch a
rule wins). This doc is the human-readable summary — the
migrations are the source of truth.

Tenancy is **plain PocketBase collection rules**, not pb-tenancy. Every rule
is built from three constants in `internal/authz`:

| Constant        | Expands to                                                     |
| --------------- | -------------------------------------------------------------- |
| `StaffRule`     | `@request.auth.collectionName = 'staff'`                       |
| `AdminRule`     | `StaffRule && @request.auth.role = 'admin'`                    |
| `RequesterRule` | `@request.auth.collectionName = 'users'`                       |

The whole security model reduces to: **staff see everything; a requester sees
only their own company's non-internal data.**

## Identity: two auth collections

Requests are attributed to one of two auth collections, distinguished in
rules by `@request.auth.collectionName`.

- **`staff`** — agents and admins, cross-customer. Fields: `name`, `role`
  (`agent` | `admin` | `field` — the third value added by `1816000000`),
  `active`, `avatar` (single image, optional —
  migration `1807000000`). `AuthRule: active = true`. Any staff member
  can read the roster (needed for assignee pickers); only admins
  create/delete. A staff member may self-update profile fields (`name`,
  `avatar`) but cannot change their own `role` or `active` (blocked by an
  `:isset` body guard). `ManageRule: AdminRule` (`1802000000`), so admin staff
  can set an account's email/password from the SPA without being PB superusers.

  `field` is **not a permission boundary** — a field agent is ordinary staff,
  cross-customer, subject to every rule an `agent` is, and `AdminRule` still
  gates the admin surfaces. It exists only so the SPA can pick a mobile,
  on-site shell (landing on today's visits) instead of the desk app. Contrast
  the `staff` / `users` split, which is a real boundary because requesters have
  a fundamentally different scope. If a future need makes `field` restrictive,
  that's a rule change, not a role rename.
- **`users`** — requesters (the repurposed default PB collection), scoped to
  one customer. Fields: `customer` (relation, **required**), `active`,
  `avatar` (single image, optional). `AuthRule: active = true && customer != ''`.
  A requester sees only themselves in the collection (staff see all); only admins
  create/delete; self-update cannot reassign `customer` or toggle `active`.
  `ManageRule: AdminRule`, as on `staff`.
  Also carries `phone` (added `1812000000`) — the requester's direct line,
  self-editable in the profile modal; the number a dispatcher/tech calls.

Both collections stamp `emailVisibility = true` on create
(`internal/authfix`) — PB hides emails by default, which would break the
staff roster and pickers.

## Data collections

### `customers` — the company directory

`name` (unique), `active`, `code` (optional, unique when set, added
`1828000000` — the **tenant token of the ecosystem's public namespace**, ADR
0002 in `platform-docs`: what subject token 2 carries in both directions, and
the handle a consumer joins helpdesk events to platform data on),
`platform_org_id` (unique when set — no longer the subject token; it answers
the different question "is this customer actually a platform organization",
which stays real for a desk whose customer list is a **superset** of the
control plane's), `webhook_token` (hidden; the inbound
webhook secret), `email_domain` (optional, unique when set, added `1823000000` —
the customer's own mail domain, used to route inbound email from an unregistered
sender to this tenant; normalized and blocked from shared providers like
gmail.com by `internal/customers`), `notes`, `show_time_to_requester` (bool,
default false — added `1810000000`).

Rules: read `StaffRule`; create/update/delete `AdminRule`. `webhook_token` is
a hidden field — it never leaves the server via the record API; staff reveal
or rotate it through `POST /api/helpdesk/customers/{id}/webhook-token`.

`show_time_to_requester` is a per-customer opt-in (default off) that lets the
portal show the **aggregate** time logged on that customer's tickets — never
the per-entry rows. It gates the `GET /api/helpdesk/tickets/{id}/time-total`
route (`internal/timeentries`): staff always get the full total, a requester
only for their own customer's ticket and only when the flag is on — and the
requester's figure is **billable-only** (entries flagged `non_billable` are
excluded), so what the customer sees matches what they'd be invoiced. Off by
default because exposing hours is an MSP billing-model choice and hard to walk
back.

The same flag gates `GET /api/helpdesk/reports/time-by-ticket?from=&to=`, the
batch companion that backs the portal's Service Summary. It returns
`{enabled, minutes: {ticketId: N}}` under identical policy (`ResolveTimeScope`),
so it exposes nothing a caller couldn't already get by hitting `time-total`
once per ticket — it just saves the round trips. An opted-out requester gets
`enabled: false` and an empty map rather than a 403: the honest answer is "no
hours for you", and the portal hides its hours section instead of rendering a
misleading zero. Customer scope is a relation hop to the ticket, since
`time_entries` carries no customer of its own. Keyed by ticket id rather than
pre-grouped, so the grouping logic lives in the one place that has the tickets
expanded — the page — and this route never grows a second copy of it.

### `tickets` — the unit of work

`number` (unique int, assigned by the create hook), `customer` (required),
`title` (required), `body`, `status` (`open` | `in_progress` | `waiting` |
`resolved` | `closed`, default `open`), `priority` (`low` | `normal` | `high` |
`urgent`, default `normal`), `assignee` (→ staff), `requester` (→ users,
optional — machine tickets have none), `source` (`portal` | `agent` | `nats` |
`webhook` | `email` | `maintenance`, default `agent`;
`email` added `1823000000`, `maintenance` — the preventive-maintenance
scheduler — added `1829000000`, since none of the others honestly described a
ticket the cron opened), `origin_subject` (the full hub-side NATS subject,
provenance for machine tickets), `dedupe_key` (unique when set — ingestion idempotency, also
carries the inbound email `Message-ID`), `attachments` (≤6 files, 10 MB each),
`category` (→ ticket_categories, optional — see below), `type` (`reactive` |
`planned`, default `reactive`; renamed from `issue` | `install` in
`1826000000`), `project` (→ projects, optional — groups planned/reactive work),
`location` (→ locations, optional — the structured place, and the reporting
axis), `location_note` (free text — dispatch hints, or the unmatched-code
fallback from machine intake). `type`, `project`, `location` and
`location_note` were added/changed in `1812000000`; the defaults above are set
by the `internal/tickets` create hook when a field is empty.
`thing` (→ things, optional — the structured thing, the second reporting axis)
and `thing_note` (free text — a scratch description, or the unmatched-code
fallback), which replaced the free-text `asset` in `1824000000`.
`estimated_minutes` (int ≥ 1, optional — staff effort estimate, added
`1815000000`; compared against the logged `time_entries` total per ticket and
summed per project at read time — see `projects`). Distinct from
`visits.duration_minutes` (a *calendar block*, not an *effort estimate*).
`awaiting_requester` (bool, added `1818000000`) — a queryable flag maintained by
`internal/tickets` backing the portal's "needs your reply" prompt / list chip /
dashboard tile. Staff-explicit: set only when a public staff comment ticks
*Request a reply* (`ticket_comments.requests_reply`, `1819000000`), cleared on a
requester reply or on resolve/close. `planned` tickets are excluded. Not a
source of truth. `resolved_at` (datetime, optional, added `1821000000`) — stamped
by the `internal/tickets` guard when the ticket enters `resolved`, cleared when
it leaves (mirrors visits' `completed_at`); it gives the auto-close cron a
trustworthy age. Nil unless currently resolved.
`due_at` (date, optional, added `1829000000`) — the target date, and pointedly
**not an SLA clock**: nothing measures it, nothing escalates off it, and only a
human writes it (or the maintenance generator, copying its plan's `next_due`).
SLA timers and escalation remain out of scope; this is the plain date somebody
agreed to. Audited like the other workflow fields. `maintenance_plan`
(→ maintenance_plans, optional, same migration) — set only on a generated
ticket. It is the "is the last one still open" guard, the completion hook's way
back to the plan, and the generated-ticket history on the plan detail view.

**Two-stage terminal.** `resolved` and `closed` are *not* synonyms: `resolved`
is a grace window (a requester comment reopens it), `closed` is final (requesters
can't comment — see `ticket_comments` below — and a reply never reopens). A daily
cron (`tickets.AutoCloseResolved`, wired in `cmd/helpdesk`) promotes tickets left
`resolved` past `auto_close_resolved_days` (config, default 7; `0` disables) to
`closed`, suppressing the mail. Both still read as inactive in every "active"
query (`status != 'resolved' && status != 'closed'`), so the split left the
queues untouched. `waiting` remains an agent-set "blocked on a third party"
status, orthogonal to `awaiting_requester`.

Rules:

- **read** — `StaffRule || (RequesterRule && customer = @request.auth.customer)`.
  A requester sees only their own company's tickets.
- **create** — staff freely; a requester only for their own customer, with
  `requester` = themselves, no `assignee`, `source = 'portal'`, and none of
  `category` / `type` / `project` / `estimated_minutes` (all pinned in the create
  rule so the portal can't forge them — classification, the grouping fields, and
  the effort estimate are triage, i.e. staff actions). `1829000000` adds
  `due_at` and `maintenance_plan` to that list: a target date is a commitment
  staff make, and attaching a ticket to a service schedule is not a requester's
  call.

  `location` and `thing` are the exception, since `1825000000`: a requester
  **may** set both, because they are not judgements about the work but facts
  about where it is and what it is on, and at intake the requester is the only
  one who knows them. Each is guarded by a tenant hop instead of an `:isset`
  ban:

  ```
  @request.body.location = '' || @request.body.location.customer = @request.auth.customer
  ```

  Both halves are load-bearing. PocketBase validates that a relation id
  *exists*, not that it is yours, so without the hop a requester could attach
  another customer's location to their ticket — and the ticket detail expands and
  renders it straight back. And the `= ''` term must be there (and must come
  first): `:isset` means "the key was submitted", so an untouched picker sending
  `location: ""` fails an `:isset = false` guard, which would reject every ticket
  filed without a location. `= ''` covers the absent case too, which is why the
  clause has two terms and not three. `1825000000_portal_site_device_test.go`
  pins all of it behaviourally, over real HTTP.

  The `_note` fallbacks stay **unguarded**: they're harmless free text, and
  they're how a requester names a location or thing that isn't in the catalog —
  which is most of them.
- **update** — `StaffRule`. Requesters never edit ticket fields; they act
  through comments.
- **delete** — `AdminRule`.

### `ticket_categories` — classification (added `1806000000`)

Admin-managed list of what tickets are about: `name` (unique), `key` (unique
slug — the stable handle used in queue filters and machine payloads, so
renaming `name` never breaks them), `active` (retire without deleting
history), `sort_order`, `color` (hex, rendered as a soft badge).

A managed collection + relation rather than a `select` field because it is
staff/admin-managed from the SPA: admins add/retire categories with no code
deploy, renames touch one row (a select denormalizes the value onto every
ticket), and it matches the app's grain. The same reasoning later produced
`thing_types` / `location_types` (`1824000000`).

Both of the ticket's "what is this about" fields have since followed the same
path from free text to relation: `location` in `1812000000`, once projects made
physical places recur, and `asset` in `1824000000`, which replaced it with
`thing` (→ `things`) plus a `thing_note` fallback. The earlier "**not** a CMDB —
no thing catalog" objection recorded here applied to an *authored* catalog
someone would have to keep true by hand. `things` isn't one: it is a curated
**mirror** of the platform's `things`, joined by `(customer, code)`, whose source
of truth lives upstream. What it buys is the pair of questions free text could
never answer — every ticket for this thing, and which things burn the most
hours.

Rules: read `StaffRule || RequesterRule` (staff use it for the picker;
requesters read it so a ticket's category **badge** resolves portal-side —
opened by `1808000000`; the taxonomy is non-sensitive labels);
create/update/delete `AdminRule`.

### `ticket_comments` — the thread

`ticket` (required, cascade-delete), `author_staff` **or** `author_user`
(exactly one, matching the author's class), `body` (required), `internal`
(bool — staff-only working notes), `attachments` (≤6 files, 10 MB each),
`requests_reply` (bool, added `1819000000` — staff tick *Request a reply*; only
a public comment by a staff author sets `tickets.awaiting_requester`, so the
flag is inert on a requester's comment), `source_message_id`
(hidden text, unique when set, added `1823000000` — the inbound email
`Message-ID`, so a redelivered reply can't post a duplicate comment; empty for
UI/portal comments).

Rules:

- **read** — `StaffRule || (RequesterRule && ticket.customer =
  @request.auth.customer && internal = false)`. Internal notes never reach
  the portal, and attachments on them inherit that (PB gates file access by
  the record's view rule).
- **create** — staff set `author_staff` = themselves; a requester sets
  `author_user` = themselves, on their own company's ticket, and cannot set
  `internal` (guarded with `:isset`). A requester also **can't comment on a
  `closed` ticket** (`@request.body.ticket.status != 'closed'`, amended by
  `1822000000`) — closed is final, a follow-up is a new ticket. Staff can still
  comment on closed tickets (their branch is unguarded).
- **update/delete** — `AdminRule`.

### `ticket_events` — the audit trail (added `1805000000`)

One row per workflow-field change: `ticket` (cascade), `field`, `old_value`,
`new_value` (stored already human-readable), `actor_staff` / `actor_user`,
`created`. Written by `internal/activity`. Audited fields: `status`,
`priority`, `assignee` plus the classification/grouping fields `category`,
`type`, `project`, `location`, `thing`, and the target date `due_at` — relation
values resolve to a label at write time (category/location/thing name, project
`#N Title`).

Rules: read `StaffRule || (RequesterRule && field = 'status' &&
ticket.customer = @request.auth.customer)` — staff see the whole trail;
requesters see only **status** transitions on their own tickets, for the
portal progress timeline (amended by `1808000000`). All other events —
priority/assignee (staff names — the roster we hide) and the newer
category/type/project/location/thing/due_at — never match, and the
actor relations stay staff-gated so an actor expand is dropped for a
requester. No create/update/delete API rule — only the server hooks write
here, via `app.Save`, which bypasses collection rules, so the trail can't be
forged through the API.

### `time_entries` — labor log

`ticket` (required, cascade), `staff` (required), `minutes` (required,
int ≥ 1), `work_date` (required), `note`, `visit` (→ visits, optional — added
`1809000000`), `non_billable` (bool, default false — added `1820000000`).

The ticket is the **canonical labor ledger**: `ticket` is required, so the
ticket total is always `sum(minutes)` filtered by ticket. `visit` is an
optional *dimension* on an entry — presence marks it as on-site/field time and
enables per-visit and field-vs-desk subtotals with no rollup machinery. No
cascade on the visit FK: deleting a visit never deletes labor (the entry keeps
its ticket; the dangling visit ref resolves to nothing).

`non_billable` marks labor not to be invoiced (rework, goodwill). It is stored
as the **exception** rather than a `billable` flag on purpose: a PocketBase bool
has no unset state, so its zero value is false — naming it `non_billable` makes
the default (unset) mean *billable*, which needs no backfill, no defaulting
hook, and no per-writer discipline (every writer, including a raw API create, is
safe by construction). Billability is a property of the *labor*, not the
*ticket* — one ticket routinely mixes billable work with non-billable rework.
Reports split on it (billable = total − non_billable, plus a write-off rate) and
the customer-facing time total (below) excludes it.

Rules: read `StaffRule` (staff-only, all ops). Create requires `staff` =
self; update/delete is own-entry-or-admin. Requesters never see time entries.

### `time_sessions` — running timer (added `1811000000`)

`staff` (required), `ticket` (required, cascade), `visit` (→ visits, optional,
no cascade), `started_at` (required), `note`. A row's existence means "this
agent has a timer running" — at most **one per agent**, enforced by a unique index on
`staff`. Stopping or canceling **deletes** the row; the durable record is the
`time_entries` row that `internal/timers` mints from it on stop. So this is the
ergonomic front-end to the labor log, *not* a second ledger — it holds only the
open interval's start and never accumulates history.

`started_at` is server-stamped by the `internal/timers` create hook (any client
value is ignored), so elapsed time is trustworthy. The stop route `POST
/api/helpdesk/timers/{id}/stop` resolves the timer into a `time_entries` row —
rounding elapsed to the nearest 5 min, or taking a caller-supplied `minutes`
override — and deletes the session atomically; with `complete_visit` it also
flips the attached visit to `completed` in the same transaction (the
`internal/visits` guard then stamps `completed_at`). Minute precision is
deliberately loose — the feature is about ergonomics, not the clock.

Rules: mirror `time_entries` — read `StaffRule`, create requires `staff` =
self, update/delete own-or-admin. Requesters never see it.

### `visits` — lite dispatch (relaxed `1803000000`, extended `1804000000`)

`ticket` (required, cascade), `assignee` (→ staff, optional), `scheduled_at`
(optional), `status` (`requested` | `scheduled` | `completed` | `canceled`; an
empty status defaults to `scheduled` if a time is set, else `requested`),
`location` (free text — dispatch directions; the structured location comes from
the ticket's `location` relation), `completed_at` (stamped by the guard when the
visit enters `completed` — a supplied value is kept, so it can be back-dated —
and cleared if it leaves), `notes`, `duration_minutes` (int, optional — added
`1809000000`).

`duration_minutes` is the **scheduled** block length (planned), paired with
`scheduled_at` to make a visit a real calendar block rather than a point in
time. It is deliberately distinct from **actual** labor, which lives in
`time_entries` tagged with the visit.

`assignee` and `scheduled_at` are optional at the schema level so a
`requested` visit can exist before a tech or time is known. The one invariant
— a `scheduled` visit must have **both** — is enforced by the
`internal/visits` guard hook, not the schema.

Rules: read `StaffRule || (RequesterRule && ticket.customer =
@request.auth.customer)` — a requester sees visits on their own tickets
(someone unlocks the door for the tech), but the portal never expands
`assignee`, so the MSP roster stays hidden. All writes are `StaffRule`.

### `locations` — customer places (added `1812000000`)

`customer` (required), `code` (the platform Location join key, optional —
unique per customer when set), `name` (required), `address`, `notes` (gate
codes / access directions), `contact`, `contact_phone`, `lat` / `lng`
(optional coordinates, added `1813000000`). Machine intakes resolve a payload
`location_code` per `(customer, code)` and set the ticket's `location`
relation; an unmatched code falls back to `location_note`, no auto-stub
(`docs/protocol.md`). `lat`/`lng` are set from the map picker in the Locations
detail view and back a maps "Navigate" deep link on the ticket (coordinates
preferred, `address` as fallback). `1824000000` added `type` (→ location_types),
`parent` (self-relation, no cascade delete) and `metadata`, closing the shape gap
with the platform's `locations` so an export seeds without translation.

`parent` exists because the seeder writes it, not because the UI needs it —
dispatch is location-level, and a ticket naming a `thing` already carries the
precision a room-level hierarchy would provide. PocketBase has no cycle detection
for self-relations, so the parent picker excludes the record *and its whole
subtree*, and any code that walks the chain carries a visited set and a depth cap.
A dangling `parent` (deleted location) renders blank, like `tickets.category`.

A location earns a relation where a one-off ticket visit's free-text location
did not: a project revisits the same location over weeks, so the place recurs. It
is still deliberately **not** a CMDB — a place with an address and access
notes, not an asset catalog.

Rules: read `StaffRule || (RequesterRule && customer = @request.auth.customer)`
(a requester sees their own company's locations); **create** and **update**
`StaffRule` (any agent manages locations day-to-day from the Directory — update
opened in `1813000000`); **delete** `AdminRule` (the one destructive op against
a location referenced by tickets/projects/visits).

### `things` — the thing catalog (added `1824000000`)

`customer` (required), `code` (the platform Thing join key, optional — unique per
customer when set), `name` (required), `type` (→ thing_types), `location`
(→ locations), `notes`, `retired` (bool), `metadata` (json). A subset mirror of
the platform's `things` minus its entire identity half (`password`, `tokenKey`,
`email`, `nats_user`, `nebula_host`) — those are control-plane and the helpdesk
must never hold them.

Machine intakes resolve a payload `thing_code` per `(customer, code)` and set the
ticket's `thing`; an unmatched code falls back to `thing_note`, no auto-stub
(`docs/protocol.md`). Same contract as `location_code`, and the two resolve
independently — a resolved thing does **not** backfill the ticket's location,
even though it has one.

`code` on both `things` and `locations` has a third job beyond the intake join:
it is the **entire payload of the printed QR label** (ADR 0002 — no host, no
customer, no kind token) and therefore what `/staff/scan` resolves. A record
with no code gets no label button, because the payload *is* the code. Codes are
resolved **globally and then disambiguated**, never within a customer context:
`staff` carry no `customer` field, so there is no ambient tenant, and `DOOR-1`
is exactly the code every customer independently invents. The separate
`(customer, code)` indexes on the two collections mean one customer may
legitimately hold both a location and a thing under one code; the scanner searches
both and shows a picker rather than a confident wrong answer.

Deliberately a **superset** of the platform's catalog: `code` is nullable because
MSP work covers printers, door strikes and customer switches that were never
onboarded to the control plane. There is no live sync and there cannot be one —
the platform publishes no event stream for things, and the only read paths are a
control-plane credential or an edge KV mirror. Bulk-loading is an operator-run
export→seed, which is why the shape stays faithful.

`retired` rather than the platform's `active` because a Go bool's zero value is
`false`: an `active` field would make every hand-created row arrive *inactive*
and be skipped by any `active = true` filter. Storing the exception is the
`time_entries.non_billable` idiom. A seeder maps `retired = !active`.

Rules: read `StaffRule || (RequesterRule && customer = @request.auth.customer)`;
create/update `StaffRule` (any agent curates inventory, and the ticket form
inline-creates); delete `AdminRule` (things are referenced by tickets, and
retiring is almost always the right move instead).

### `thing_types` / `location_types` — classifiers + metadata schemas (added `1824000000`)

`customer` (required), `code` (join key, unique per customer when set), `name`
(required), `description`, `metadata_schema` (json). Identical shape — the
platform's versions differ only in fields that are pure NATS contract
(`capabilities`, `subject_prefix`, `operations`, `nats_role`), none of which
crosses the boundary. They stay two collections because that is the platform's
shape and it keeps an export→seed a 1:1 map.

`metadata_schema` is the reason they exist: a JSON Schema naming the keys records
of that type track, so `metadata` doesn't degenerate into a bag of drifting key
spellings (`serial` / `Serial` / `sn`). A type with a schema gives its records a
typed metadata form; one without falls back to free-form key/value rows, which is
why a property-less schema is stored as `null` rather than
`{type:'object',properties:{}}`. Schemas are **authored upstream** in the platform
console and edited here as raw JSON, parse-validated before save.

Rules: read `StaffRule || (RequesterRule && customer = @request.auth.customer)` —
a requester's ticket may render a typed metadata field, so the schema has to be
readable; create/update/delete `AdminRule`, matching `ticket_categories`.

### `maintenance_plans` — preventive-maintenance schedules (added `1829000000`)

`customer` (required), `title` (required) and `body` — the ticket this plan will
open — plus the triage it stamps on every one: `category`, `assignee`,
`priority`, `estimated_minutes`, and the `thing` / `location` / `project` it is
about (all optional; no cascade delete, so retiring a thing never deletes the
schedule that services it). `priority` uses the ticket values and defaults to
`normal`; `estimated_minutes` is int ≥ 1. The schedule itself is
`interval_days` (required, int ≥ 1), `anchor` (`schedule` | `completion`,
default `schedule` — both defaults set by the `internal/maintenance` create
hook), `lead_time_days` (int ≥ 0 — generate this many days before `next_due`;
`0` = on the day), `next_due` (date) and `paused` (bool).

Like `projects`, this is a planning layer **above** the ticket → visit → time
ledger: its only output is an ordinary ticket, and the collection could be
dropped without breaking anything already recorded — only future generation
would stop.

**The two anchors.** `anchor` picks the behaviour, and each stays simple because
each has exactly **one writer** of `next_due`:

- `schedule` — the cron owns it, advancing by whole `interval_days` at
  generation until it lands in the future. "Quarterly" stays quarterly however
  late the visit ran. A plan dormant for a year yields one ticket on the next
  real slot, not a year of backlog.
- `completion` — the cron **parks** the plan (clears `next_due`), and the
  `internal/maintenance` ticket hook sets it to `resolved_at + interval_days`
  when the generated ticket resolves. "Every 90 days after last service."

An empty `next_due` therefore means *parked*, not "no date", and the generator's
`next_due != ''` filter is what makes a completion-anchored plan **structurally
unable** to stack up work. The skip-if-still-open guard consequently only ever
runs on `schedule` plans, which still advance when they skip — one inspection
nobody did must not become four open tickets, and a plan that never advances
falls permanently behind the calendar it tracks.

`paused` rather than `active`, the `things.retired` / `time_entries.non_billable`
idiom: a Go bool's zero value is `false`, so an `active` field would make every
hand-created and seeded plan arrive inactive and be skipped silently.

Generation runs from a daily cron (`maintenance_generate`, 03:45 — after
`auto_close_resolved` so a plan whose ticket was auto-closed at 03:30 restarts
the same night) and on demand via `helpdesk maintenance-run`, the
catch-up path for an install that was down at fire time. It is idempotent per
occurrence through `tickets.dedupe_key` (see below), and deliberately does
**not** suppress notifications — a new preventive ticket is real news, unlike
the administrative auto-close.

Rules: list/view/create/update `StaffRule`, delete `AdminRule` — the split
`1813000000` gave locations, because the person who learns a location needs
quarterly service is usually the tech standing in it. Read is staff-only: the
generated tickets already give requesters everything that matters, and a plan
carries `assignee`, the MSP roster the portal visit and project views hide.

### `projects` — installation / field-work container (added `1812000000`)

`number` (unique int, assigned by the `internal/projects` create hook),
`customer` (required), `location` (→ locations, optional), `title` (required),
`description`, `status` (`pending` | `active` | `completed` | `canceled`,
default `pending` — renamed from `planned` in `1827000000` so it stops
colliding with a ticket's `type: planned`, which means something else and
shares the project detail screen with it), `start_date` / `target_date` (the
target window), `lead`
(→ staff, optional — whole-rollout accountability, distinct from the
per-ticket assignees).

A project is a planning-and-grouping layer **above** the ticket → visit → time
ledger: it groups 1..N tickets (often one `planned` ticket per trade, plus any
reactive tickets) and stores none of their execution data. Crew (lead ∪
ticket/visit assignees), total logged time, and total estimated effort
(`sum(ticket.estimated_minutes)`, shown as an estimated-vs-logged bar) are all
**derived** at read time via relation-hop queries on `ticket.project`, never
stored — so the project collection could be dropped and the helpdesk would
still work.

Rules: read `StaffRule || (RequesterRule && customer = @request.auth.customer)`
— a requester sees their own company's projects (the portal shows the tickets
and visits but never the `lead`/crew). create/update `StaffRule`; delete
`AdminRule`.

### Notification collections

`notification_templates`, `notification_dedupe`, `notification_send_log` —
lifted from the kiosk notifier. See `docs/notifications.md`. Two channels per
template: `enabled` (email) and `publish_nats` (publish a JSON envelope to
`helpdesk.{customerCode}.events.{event_type}`, migration `1814000000`; token 2
became `customers.code` in `1828000000`, and a customer without one is skipped
rather than published under a fallback);
`notification_send_log.channel` (`email` | `nats`) records which path each row
is for.

Rules: `notification_templates` list/view/update `AdminRule`, with no
create/delete API rule (rows are seeded by migrations; new event types ship as
code). `notification_dedupe` and `notification_send_log` are read-only
`AdminRule` — only the notifier writes them (via `app.Save`) and the retention
cron prunes them.

## Idempotency & uniqueness indexes

These unique indexes are load-bearing, not just performance:

- `tickets.number` — the collision backstop for the sequential-number hook.
- `tickets.dedupe_key` (partial, `!= ''`) — absorbs NATS redelivery and
  webhook retries; a duplicate key is acked/answered without a second ticket.
  It carries preventive-maintenance occurrences too, as
  `pm:{planId}:{YYYY-MM-DD}` (`1829000000`), which is what makes the daily cron
  and a hand-run `helpdesk maintenance-run` safe to overlap: the same plan
  occurrence can only ever produce one ticket.
- `customers.code` (partial, `!= ''`) — the tenant token resolves to exactly one
  customer. Partial because a customer the platform never onboarded has no code
  until an operator assigns one, and SQLite treats `''` as a value.
- `customers.platform_org_id` (partial) — one customer per platform org.
- `customers.webhook_token` (partial) — token uniquely selects a customer.
- `customers.email_domain` (partial, `!= ''`) — a mail domain maps to one tenant.
- `ticket_comments.source_message_id` (partial, `!= ''`) — an inbound email
  `Message-ID` posts at most one comment (redelivery idempotency).
- `ticket_categories.name` / `.key` — categories are distinct; `key` is the
  stable filter/payload handle.
- `locations` (customer, code), `things` (customer, code), and
  `thing_types` / `location_types` (customer, code) — all partial on
  `code != ''`. A code is unique **within a customer** (it's the machine-intake
  and export→seed join key); two tenants both calling a reader `RDR-01` is
  correct. The partial predicate is what keeps a blank code legal, and blanks
  must stay legal: SQLite treats `''` as a value rather than NULL, and the
  catalog is deliberately a superset of the platform's — it covers gear that
  was never onboarded and therefore has no code.
- `time_sessions.staff` — one running timer per agent, enforced by the DB
  rather than by the stop route. This is what makes "start a timer" idempotent.
- `projects.number` — the collision backstop for the project-number hook.
- `notification_dedupe` (event, ref, UTC-day) — one send per event/ref/day.
- `notification_templates.event_type` and `customers.name` — one row per event,
  one company per name.
