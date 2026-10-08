---
path: helpdesk
nav_order: 40
access: public
---
# Helpdesk

Helpdesk is the service-desk application of the
[Stone-Age.io](https://stone-age.io) ecosystem. The ecosystem's **operator**
runs it: the MSP that operates the platform and supports the customer
organizations on it. It handles reactive support tickets **and** proactive
project, installation and field work. It is one Go binary that embeds
PocketBase (system of record, REST API, auth) and a Vue 3 SPA (staff app and
requester portal).

The `helpdesk` name stays as the technical identifier, most visibly in the
operator-signed `helpdesk.>` NATS contract, although the product does more than
a help desk.

The feature that sets it apart is **machine-generated tickets**. Things and
rule-router publish events on `helpdesk.>` inside a customer org's NATS
account. The platform's managed-org export delivers them into the operator hub
account as `helpdesk.{orgCode}.>`, with unforgeable subject-based provenance,
and the helpdesk's durable JetStream consumer turns them into tickets. Humans
use the portal, the staff app or the authenticated webhook.

Token 2 is the **organization code**: the ecosystem's one globally unique
identifier, and the handle that locations, things and outbound events all use
to name a tenant (ADR 0002 in `platform-docs`).

**New here?** Start with the [Overview](docs/overview.md): the ideas the app is
built on, what each role does day to day, and a five-minute tour on seeded demo
data. The rest of `docs/` is reference.

---

## Features

- **Two identity classes**: `staff` (cross-customer; `agent`, `admin` or
  `field`) and requesters (`users`, scoped to one customer). `field` steers the
  UI to a mobile on-site shell and is *not* a permission boundary. There is one
  login page, and the router shows the right shell.
- **Staff workspace**:
  - A dashboard landing: status, urgent and unassigned tiles over your own
    active tickets, with backlog age, due dates and weekly inflow in a rail.
    Each tile and each age or due count opens the queue pre-filtered to it.
  - A ticket queue with search; filters on status, priority, assignee,
    customer, category, location, thing, type, due date and backlog age; saved
    views; bulk assign and status; and CSV export.
  - A Dispatch board and a mobile-first field-work view.
  - A directory of customers, locations, things and projects.
  - A reports view: time and visits by tech, customer, location, thing or
    thing type; billable vs. written-off; ticket volume by category and source.
    It can be scoped to one customer, location or thing.
  - Admin for requesters, staff, categories, record types and notification
    templates.
- **Field shell**: the same `/staff/*` routes in phone-shaped chrome,
  `Today · Schedule · Tickets · Time · More`. **More** holds the scanner,
  Locations and Things, plus Projects and Maintenance. Locations and Things
  offer a *My scheduled locations* narrowing that appears only for staff who
  have scheduled visits, so a dispatcher never sees it filter to an empty
  roster.
- **Requester portal**: a company dashboard; a searchable list of their own
  tickets; threaded ticket detail with attachments; a new-ticket form that can
  name the location and thing; Locations and Things catalog pages, each with a
  read-only detail view (the record's `metadata` in full, our internal `notes`
  withheld); filters over both axes that ride the URL; a Service Summary report
  (tickets, visits and, where the customer has opted in, billable hours, by
  location, thing and category); and read-only visit and project views. The
  MSP roster is never shown.
- **Ticketing core**: sequential ticket numbers, status, priority, assignee, an
  admin-managed category, a structured location (`location`) and thing
  (`thing`) each with a free-text fallback, an optional effort estimate,
  comment threads with staff-only internal notes, time entries and on-site
  visits.
- **Two-stage lifecycle**: `resolved` is a grace window that a requester reply
  reopens automatically. `closed` is final, and a reply there opens a new
  ticket. A daily cron promotes tickets left resolved past
  `auto_close_resolved_days`. A separate `awaiting_requester` flag, set only
  when an agent ticks *Request a reply*, drives the portal's "needs your reply"
  prompt.
- **Service delivery**: `projects` group installation and field work across
  tickets at a `location` over a target window. Crew and total time are
  derived at read time from the ticket ledger and never stored. The grouping
  layer sits *above* ticket → visit → time and does not change it.
- **Preventive maintenance**: `maintenance_plans` turn "every N days" into
  ordinary `planned` tickets on a nightly cron, or on demand with
  `./helpdesk maintenance-run`. A plan repeats from the **calendar** or from
  **last completion**. In the second case it parks itself while its ticket is
  open, so work never stacks up. A plan can open its ticket a few days early.
  Its only output is a ticket, so visits, time, reports and the portal need no
  special handling. Tickets carry a `due_at` target date, with a queue filter
  and dashboard counts. It is a date, not an SLA clock: nothing measures it and
  nothing escalates.
- **Things and locations**: a curated local catalog joined to the platform by
  `(customer, code)`. `thing_types` and `location_types` carry a
  `metadata_schema`, so `metadata` does not drift into a bag of key spellings.
  The catalog is a **superset**: it covers gear the platform never onboarded.
  It is not live-synced, because the platform publishes no event stream for
  things, and the only alternatives are a control-plane credential (forbidden
  here) or an edge KV mirror.
- **QR labels and scanning**: print an operator-branded label for any location
  or thing that has a code. Labels are sized in millimetres to real stock
  (2″ × 1″ and 4″ × 2″), and both sizes reserve the centred RFID inlay
  keep-out, so one layout prints on plain or RFID media. Scan a label at
  `/staff/scan`. The payload is the **bare code** (no host, no customer, no
  kind token), so a forged sticker cannot send a person to arbitrary content.
  Codes resolve *globally*, with a picker on collision, not inside a sticky
  customer context. Every label prints its code as readable text, and typing it
  is a first-class path. Rationale: ADR 0002 in `platform-docs`.
- **Time and billing inputs**: minutes logged by hand or with a start/stop
  timer (one open session per agent, enforced in the database). Each entry is
  flagged billable or not, so reports can show a write-off rate. Minutes only:
  billing math stays in accounting.
- **Activity and files**: workflow and classification changes are recorded to a
  staff-only audit timeline, with relation values resolved to labels at write
  time. Tickets and comments take file attachments.
- **Lite dispatch**: promote a ticket to on-site work with a `requested` visit
  (no tech or time yet). Schedule it from the staff Dispatch view (a
  needs-scheduling bucket and a day-grouped list), and work it from a
  mobile-first visit view (Arrive → live timer → Complete). Requesters see
  their visits read-only in the portal.
- **Customers directory**: each customer has a `code`, the ecosystem's tenant
  token. The NATS subject carries it in **both** directions, and a consumer
  joins helpdesk events to platform data on it. Each customer also has webhook
  tokens (admin reveal and rotate), a mail domain for email intake, and a
  toggle for showing logged time to requesters. `platform_org_id` only records
  that a customer *is* a platform organization; it is not the routing key
  (ADR 0002).
- **Outbound notifications, two channels**: eight events (ticket created,
  assigned, commented or status changed; visit scheduled, rescheduled, canceled
  or completed) fire from record hooks. **Email** uses templates stored in the
  database (Go `text/template`, editable in the SPA) with per-event recipient
  specs, a send log and day-keyed dedupe. **NATS** publishes a fixed, versioned
  JSON envelope, toggled per event. Each channel is a clean no-op when
  unconfigured. See [Notifications](docs/notifications.md).
- **Inbound tickets, three paths**: a NATS durable consumer, an authenticated
  webhook (`POST /api/helpdesk/inbound/{token}`), and **email** through a
  parsing provider's webhook. An email reply carrying the `[#N]` subject token
  becomes a comment; anything else becomes a new ticket. All three are
  idempotent, and the helpdesk holds no mailbox credentials. See
  [Wire Protocol](docs/protocol.md) and [Email Ingestion](docs/email-ingestion.md).
  Beside these and the human `portal` and `agent` sources, a sixth `source`,
  `maintenance`, is written by the scheduler, not by anything outside.
- **Demo seeding**: `./helpdesk seed-demo --confirm` fills a showcase instance
  with a backdated, idempotent ticket history. It runs in-process in Go, not as
  an HTTP script, because PocketBase's autodate overwrites `created` on save,
  so no external client can produce a demo whose ages look real.
- **Throughout the SPA**: live updates (PocketBase realtime subscriptions),
  light and dark themes, keyboard shortcuts, responsive table-to-card layouts,
  filters in the URL on every filtered board (staff queue, Reports, Dispatch;
  portal tickets, visits, projects, things, Summary), self-service profile
  edits and forgot-password reset.

---

## Build & Run

The SPA is embedded with `//go:embed` at compile time. Because
`internal/webui/public` is committed, a fresh checkout builds without npm.

::: warning Rebuild and re-commit the SPA
Whenever `ui/` changes, run `npm run build` and commit
`internal/webui/public`. Otherwise the binary serves the old UI.
:::

```bash
cd ui && npm ci                 # once
npm run build                   # vue-tsc + vite → ../internal/webui/public (commit the output)
cd .. && go build ./cmd/helpdesk
./helpdesk serve                # UI at http://127.0.0.1:8090/ · PocketBase admin at /_
```

The first start seeds a bootstrap staff admin (`admin@helpdesk.local`) and
prints its password **once**. Configuration is `helpdesk.yaml` plus
`HELPDESK_*` env overrides; see the
[Configuration Reference](docs/configuration.md). SMTP (outbound email) and the
application URL (ticket links in emails) are set in the PocketBase dashboard,
not in the YAML.

You can rebrand the UI at runtime with no rebuild. Point `branding.dir` (env
`HELPDESK_BRANDING_DIR`) at a host directory of `theme.css`, `logo.svg` and
`branding.json` to override the app name, logo and theme. See
[Configuration Reference](docs/configuration.md#branding-overlay) and the
[`branding.example/`](https://github.com/stone-age-io/helpdesk/blob/main/branding.example) template. The UI also installs as a
PWA. Its service worker is a **no-op**, because an app that shows live ticket
state must not serve yesterday's queue.

To fill a showcase instance with realistic, backdated demo data:

```bash
./helpdesk seed-demo --confirm
```

`--confirm` is required because the subcommand ships in the production binary.
The command is idempotent and suppresses all notification mail, so re-running
it cannot duplicate records or email a few dozen fictional people.
`--tickets N` sets the ticket count to converge on (default 150).

To run the tests:

```bash
go test ./...
```

---

## Repo Layout

```
cmd/helpdesk/        PB bootstrap, OnServe wiring, SPA + /branding/* routes,
                     crons (retention, auto-close, maintenance)
config/              viper Config (HELPDESK_ env prefix)
migrations/          Go schema-as-code (collections, rules, seeds)
internal/
  authz/             access-rule vocabulary shared by migrations + routes
  tickets/           ticket-number assignment + field defaults, auto-reopen,
                     awaiting-requester, resolved_at, auto-close cron
  visits/            visit status defaulting + scheduled-visit invariant
  projects/          project numbering + derived crew / rolled-up time
  maintenance/       preventive-maintenance recurrence: the generation sweep,
                     the completion-anchor hook, and `maintenance-run`
  timeentries/       labor ledger + time-total / time-by-ticket routes
  timers/            start/stop timer → time entry (one open session per agent)
  activity/          ticket_events audit trail (workflow + classification)
  authfix/           auth-default fixups (email visibility on create)
  customers/         email-domain validation (never a public provider)
  notifications/     notifier core, templates, lifecycle hooks, NATS publish,
                     editor API
  subjects/          NATS subject grammar (helpdesk.{org}.tickets.{verb})
  natsx/             NATS connect (creds file) + inbox stream helper
  ingest/            durable consumer → ticket projection
  inbound/           webhook route, webhook-token reveal/rotate, email intake
                     (provider-agnostic core + Postmark adapter)
  demoseed/          `seed-demo` subcommand (backdated, idempotent showcase data)
  webui/             //go:embed all:public (committed SPA dist)
  testutil/          real-PB-against-t.TempDir() harness + HTTP rule harness
ui/                  Vue 3 + Vite + Pinia + Tailwind + daisyUI SPA (also a PWA)
branding.example/    template for the runtime branding overlay
docs/                overview guide, data model, wire protocol, notifications,
                     config, and the (historical) implementation plans
```

---

## Architecture Notes

- **A standalone sibling app**, following the kiosk and access-control pattern,
  not a platform feature. Helpdesk agents never hold control-plane
  credentials, and the tenancy axes differ: the platform tenant is the customer
  org, and the helpdesk tenant is the MSP.
- **Tenancy is plain collection rules**: `customers`, `users.customer` and
  staff roles (`internal/authz`). There is no pb-tenancy. See
  [Data Model & Access Rules](docs/data-model.md).
- **NATS is best-effort.** The app boots and serves portal and webhook traffic
  with no broker, and the durable consumer resumes where it left off.
- **The org in a machine ticket comes from the subject**, which the
  operator-signed platform import rewrites, never from the payload.
- **The helpdesk owns an outbound stream** (`HELPDESK_NOTIFICATIONS`, subjects
  `helpdesk.*.events.>`). It is disjoint from the ingest stream at token 3
  (`events` vs `tickets`), so an emitted event cannot loop back through ingest.
- **`things` and `locations` join the platform** by `(customer, code)`. They
  are not synced and cannot be. Bulk loading is an operator-run export and
  seed, so both shapes stay a faithful subset of the platform's.
- **Collection rules are the security boundary**, so the portal-facing ones are
  tested by **executing** them over HTTP, not by asserting on the rule string.
  See `migrations/1825000000_portal_site_device_test.go`.

---

## Documentation

- [Overview](docs/overview.md): the ideas, the roles and a five-minute tour.
  Start here.
- [Data Model & Access Rules](docs/data-model.md): collections, fields and
  access rules.
- [Wire Protocol](docs/protocol.md): NATS subjects and payloads, the inbound
  webhook and email intake.
- [Notifications](docs/notifications.md): who gets emailed or published to,
  and when.
- [Email Ingestion](docs/email-ingestion.md): inbound email setup and
  threading.
- [Configuration Reference](docs/configuration.md): config files, env vars,
  PocketBase settings and scheduled jobs.

Design records, kept in the repo for their reasoning. Each carries a banner
saying where the app has moved past it, so do not read them as descriptions of
the current app:

- [`docs/plan.md`](https://github.com/stone-age-io/helpdesk/blob/main/docs/plan.md): the original implementation plan.
- [`docs/service-delivery-plan.md`](https://github.com/stone-age-io/helpdesk/blob/main/docs/service-delivery-plan.md): projects
  and the service-delivery layer.
- [`docs/nats-notifications-plan.md`](https://github.com/stone-age-io/helpdesk/blob/main/docs/nats-notifications-plan.md): the
  NATS notification channel.
