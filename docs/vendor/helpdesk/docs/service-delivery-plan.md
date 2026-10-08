---
path: helpdesk/service-delivery-plan
nav_order: 80
---
# Service-delivery expansion plan

Status: **implemented** (migrations `1812000000`–`1815000000`). This document
plans the expansion of `helpdesk` from a reactive service-ticket app into a
**service-delivery** app that also handles proactive project / installation /
field work. It backs the implementation the way `docs/plan.md` backed the
original build, and is kept for its rationale — especially the "grouping layer
above the ledger" decision and the tripwire for splitting projects into their
own sibling app.

One non-goal below has since been **partly reversed**: "CMDB / asset catalog".
Migration `1824000000` added `things`, `thing_types` and `location_types`. The
objection recorded here was to an *authored* catalog someone would have to keep
true by hand; what shipped is a curated **mirror** of the platform's `things`,
joined by `(customer, code)`, whose source of truth lives upstream. The rest of
that list still stands. See [data-model.md](data-model.md).

Recurrence was never on that list, and migration `1829000000` added it —
`maintenance_plans`, plus a `due_at` on tickets. It is worth reading here rather
than as a departure, because it is the **same decision this document argues
for, applied a second time**: a plan stores no execution data and its only
output is an ordinary `planned` ticket, so visits, the time ledger, the audit
trail, the portal and every report needed no changes at all. The "grouping layer
above the ledger" pattern held. See [data-model.md](data-model.md).

## Why grow helpdesk instead of a new app

An MSP / system-integrator's operational suite (control plane, access-control,
kiosk/timeclock, helpdesk) was missing installation / project / field-work
management. Three options were weighed:

1. **Grow helpdesk — chosen.** Helpdesk already owns most of the spine:
   visits, the dispatch board, the mobile work view, and the `time_entries`
   ledger, plus customers, both auth classes, the portal, the notifier, and
   the audit trail. Building a second app that reduplicates all of that to
   gain three collections would be *less* grug, not more.
2. Separate sibling app — rejected for now. It would reduplicate the shared
   infrastructure and needs a platform change (generalize the managed-export
   to a second named subtree) it doesn't yet warrant.
3. Evolve the kiosk timeclock — rejected. It's an append-only punch ledger
   with a free-text `job_code`; no data-model headroom for stateful,
   assignment-centric project work.

## Design decisions (the "light path")

- **Projects and locations are a planning + grouping layer *above* the
  existing ticket → visit → time execution ledger.** Visits and time stay
  parented to tickets; the "one canonical ledger" invariant is untouched.
  You could delete the `projects` collection and still have a working
  helpdesk.
- **A ticket is the unit of work.** No separate "task" noun. A `type`
  (`reactive | planned`) discriminator distinguishes reactive from planned work.
  A project is **1..N tickets** — e.g. one `planned` ticket per trade (access
  control, video, intrusion) plus any reactive tickets that arise on the job.
- **Derived crew.** No change to the ticket assignee model. The crew is the
  ticket lead ∪ its visits' assignees; each **visit is one person's scheduled
  block** (lead scheduled all day, others come later). Multi-person labor is
  already captured per-staff in `time_entries`.
- **Derived estimate rollup.** A single optional `tickets.estimated_minutes`
  (staff-set effort estimate, migration `1815000000`) is compared against the
  logged `time_entries` total per ticket and **summed per project** at read
  time — one nullable column, no baselines or re-estimate history. It is an
  *effort* estimate, distinct from `visits.duration_minutes` (a *calendar
  block* entered at dispatch).
- **`locations` carries a `code`** = the join key to the platform's Location
  concept, payload-sourced on NATS/webhook intake and resolved per
  `(customer, code)`. This turns location into a queryable dimension
  (tickets / installs / visits / time **by location**) and reserves the
  platform-integration seam without building any sync now.
- **Project `lead`** (single staff) is real accountability and is *not*
  captured by per-ticket assignees — in a multi-trade project none of the
  trade assignees is the rollout owner.
- **Keep the `helpdesk` technical name.** The `helpdesk.>` NATS subject is an
  operator-signed, cross-repo contract; the Go module, binary, `HELPDESK_*`
  prefix are churn. Evolve only the UI/product display name and re-scope the
  docs.

### The tripwire (when to reconsider a split)

The light path holds as long as there is **one canonical execution ledger**.
The signal to reconsider a separate app is the project side needing its own
portal semantics, tenancy axis, or NATS ingestion — **not** merely
re-parenting a visit. We are far from that line.

## Data model delta

**New `locations`** — `customer` (rel, req), `code` (text, join key,
unique per customer where set), `name` (req), `address`, `notes`, `contact`,
`contact_phone`. Read: staff + requester-own-customer. Create: staff (enables
inline create). Edit/delete: admin (curated roster).

**New `projects`** — `number` (sequential, hook-assigned), `customer`
(rel, req), `location` (rel), `title` (req), `description`, `status`
(`pending | active | completed | canceled`), `start_date`, `target_date`,
`lead` (rel → staff). Read: staff + requester-own-customer. Create/update:
staff. Delete: admin.

**`tickets` amendments** — add `project` (rel), `type`
(`reactive | planned`, default `reactive` via hook), `location` (rel → locations);
**rename** the existing free-text `location` → `location_note` (the
unmatched-code fallback); `requester` was already optional. The requester
(portal) create rule gains `project`/`type`/`location` `:isset = false`
guards so those stay staff-classified.

**`users`** — add `phone` (the requester's direct line). The on-site contact
lives on the `location` (`contact` / `contact_phone`).

**No schema change** to `visits`, `ticket_comments`, `time_entries`, or the
audit trail — per-person visits, the update ledger (comments), and labor
rollups all already work through the ticket.

## Phases

- **Phase 1 — Schema foundation (this change).** Migration
  `1812000000_service_delivery.go` (locations, projects, ticket fields,
  `users.phone`); `internal/projects` number/status hook; `tickets` gains a
  `type=issue` default; ingest/inbound write the renamed `location_note`;
  Go tests for schema shape, wiring, and number assignment.
- **Phase 2 — Intake: location-code resolution.** Add `location_code` to the
  wire contract (`docs/protocol.md`); resolve `(customer, code) → locations`
  in `internal/ingest`, falling back to `location_note` + warn/ack on a miss
  (no auto-stub). Tests via `ingest.(*Consumer).Project` directly.
- **Phase 3 — Staff UI.** Locations admin roster + inline quick-create;
  projects list/detail (derived crew + time-total); ticket form gains
  project/type/location. **Rewires the ticket form's location field**, which
  is temporarily out of sync after Phase 1's rename until this lands.
- **Phase 4 — Dispatch + Reports by location.** Group/filter visits by
  project and location; reports by location; visits derive their hard address
  from `ticket.location.address`.
- **Phase 5 — Portal + contact.** Read-only portal project view (never shows
  `lead`/crew — the MSP roster stays hidden); requester `phone` in the
  profile.
- **Phase 6 — Notifications + docs/re-scope.** Install tickets reuse the
  existing ticket events (no new event types in v1); re-scope `CLAUDE.md` +
  `docs/data-model.md`; swap the UI display name.

## Out of scope (deliberate)

CMDB / asset catalog, budget / materials / cost estimating, estimate baselines
or re-estimate history, task dependencies / Gantt, resource leveling, customer
sign-off, calendar sync. (A single lightweight *effort* estimate per ticket,
rolled up per project, is in — see above; the full estimating/budgeting
machinery is not.) Ship the spine; let real pain argue features back in.
