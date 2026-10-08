---
path: helpdesk
nav_order: 40
access: public
---
# Helpdesk

Service-desk application for the [Stone-Age.io](https://stone-age.io)
ecosystem, run by the ecosystem's **operator** — the MSP that operates the
platform and supports the customer organizations on it. It handles reactive
support tickets **and** proactive project / installation / field work. One Go
binary embedding PocketBase (system of record, REST API, auth) and a Vue 3 SPA
(staff app + requester portal).

The `helpdesk` name is kept as the technical identifier — notably the
operator-signed `helpdesk.>` NATS contract — even though the product's scope has
grown past a help desk.

The differentiating capability is **machine-generated tickets**: things and
rule-router publish events inside a customer org's NATS account on
`helpdesk.>`, the platform's managed-org export delivers them into the
operator hub account as `helpdesk.{orgCode}.>` with unforgeable
subject-based provenance, and the helpdesk's durable JetStream consumer
turns them into tickets. Humans use the portal, staff app, or the
authenticated webhook.

Token 2 is the **organization code** — the ecosystem's one globally unique
identifier, and the same handle locations, things and outbound events all name a
tenant by (ADR 0002 in `platform-docs`).

**New here?** [docs/overview.md](docs/overview.md) is the map — the handful of
ideas the app is built on, what each role actually does day to day, and a
five-minute tour on seeded demo data. The rest of `docs/` is reference.

## Features

- **Two identity classes**: `staff` (cross-customer; `agent` / `admin` /
  `field`, where `field` steers the UI to a mobile on-site shell and is *not* a
  permission boundary) and requesters (`users`, scoped to one customer). One
  login page; the router shows the right shell.
- **Staff workspace**: a dashboard landing (status/urgent/unassigned tiles over
  your own active tickets, with backlog age, due dates and weekly inflow in a
  rail — each tile and age/due count opens the queue pre-filtered to it); a
  ticket queue with search, status/priority/assignee/customer/category/
  location/thing/type/due/backlog-age filters, saved views, bulk
  assign/status, and CSV export;
  a Dispatch board and a mobile-first field-work view; a directory of customers,
  locations, things and projects; a reports view (time & visits by
  tech/customer/location/thing/thing-type, billable vs. written-off, ticket
  volume by category and source, scopeable to one customer, location or thing);
  and admin for requesters, staff, categories, record types, and notification
  templates.
- **Field shell**: the same `/staff/*` routes in phone-shaped chrome —
  `Today · Schedule · Tickets · Time · More`, where **More** holds the scanner,
  Locations and Things, plus Projects and Maintenance. Locations and Things
  offer a *My scheduled locations* narrowing that only appears for staff who
  actually have scheduled visits, so it can never leave a dispatcher staring
  at an empty roster.
- **Requester portal**: a company dashboard, a searchable list of their own
  tickets, threaded ticket detail with attachments, a new-ticket form that can
  name the location and thing, Locations and Things catalog pages each with a
  read-only detail view (the record's `metadata` in full; our internal `notes`
  withheld), filters over both axes that ride the URL, a Service Summary
  report (tickets, visits and — where the customer has opted in — billable
  hours, by location, thing and category), plus read-only visit and project
  views. The MSP roster is never shown.
- **Ticketing core**: sequential ticket numbers, status/priority/assignee, an
  admin-managed category, a structured location (`location`) and thing (`thing`)
  each with a free-text fallback, an optional effort estimate, comment threads
  with staff-only internal notes, time entries, on-site visits.
- **Two-stage lifecycle**: `resolved` is a grace window a requester reply
  auto-reopens; `closed` is final (a reply there opens a new ticket). A daily
  cron promotes tickets left resolved past `auto_close_resolved_days`. A
  separate `awaiting_requester` flag — set only when an agent ticks *Request a
  reply* — powers the portal's "needs your reply" prompt.
- **Service delivery**: `projects` group installation / field work across
  tickets at a `location` over a target window. Crew and total time are derived
  at read time from the ticket ledger, never stored — the grouping layer sits
  *above* ticket → visit → time without changing it. See
  [docs/service-delivery-plan.md](docs/service-delivery-plan.md).
- **Preventive maintenance**: `maintenance_plans` turn "every N days" into
  ordinary `planned` tickets on a nightly cron (or on demand with
  `./helpdesk maintenance-run`). A plan repeats either from the **calendar** or
  from **last completion** — in the second case it parks itself while its ticket
  is open, so it can never stack up work — and can open the ticket a few days
  early. Another grouping layer above the ledger: its only output is a ticket,
  so visits, time, reports and the portal needed no changes. Tickets also gained
  a `due_at` target date, with a queue filter and dashboard counts. It is a
  date, not an SLA clock: nothing measures it and nothing escalates.
- **Things & locations**: a curated local catalog joined to the platform by
  `(customer, code)`, with `thing_types` / `location_types` carrying a
  `metadata_schema` so `metadata` doesn't drift into a bag of key spellings.
  Deliberately a **superset** — it covers gear the platform never onboarded —
  and deliberately not live-synced: the platform publishes no event stream for
  things, and the only alternatives are a control-plane credential (forbidden
  here) or an edge KV mirror.
- **QR labels and scanning**: print an operator-branded label for any location or
  thing that has a code, sized in millimetres to real stock (2″ × 1″ and
  4″ × 2″, both reserving the centred RFID inlay keep-out so one layout prints
  on plain or RFID media). Scan it back at `/staff/scan`. The payload is the
  **bare code** — no host, no customer, no kind token — so a forged sticker
  can't send a person to arbitrary content, and codes resolve *globally* with a
  picker on collision rather than inside a sticky customer context. Every label
  prints its code in readable text, and typing it is a first-class path.
  Rationale: ADR 0002 in `platform-docs`.
- **Time & billing inputs**: minutes logged by hand or via a start/stop timer
  (one open session per agent, DB-enforced), each entry flagged billable or not
  so reports can show a write-off rate. Minutes only — billing math stays in
  accounting.
- **Activity & files**: workflow and classification changes recorded to a
  staff-only audit timeline with relation values resolved to labels at write
  time; file attachments on tickets and comments.
- **Lite dispatch**: promote a ticket to on-site work with a `requested`
  visit (no tech/time yet), schedule it from the staff Dispatch view
  (needs-scheduling bucket + day-grouped list), and work it from a mobile-first
  visit view (Arrive → live timer → Complete). Requesters see their visits
  read-only in the portal.
- **Customers directory**: a `code` — the ecosystem's tenant token, carried by
  the NATS subject in **both** directions and the handle a consumer joins
  helpdesk events to platform data on — plus per-customer webhook tokens (admin
  reveal/rotate), a mail domain for email intake, and a per-customer toggle for
  showing logged time to requesters. (`platform_org_id` remains, but only to
  record that a customer *is* a platform organization; it stopped being the
  routing key with ADR 0002.)
- **Outbound notifications, two channels**: eight events (ticket created /
  assigned / commented / status changed, visit scheduled / rescheduled /
  canceled / completed) fired from record hooks. **Email** uses DB-stored
  templates (Go `text/template`, editable in the SPA) with per-event recipient
  specs, a send log, and day-keyed dedupe. **NATS** publishes a fixed, versioned
  JSON envelope, toggled per event. Each channel is independently a clean no-op
  when unconfigured. See [docs/notifications.md](docs/notifications.md).
- **Inbound tickets, three paths**: a NATS durable consumer, an authenticated
  webhook (`POST /api/helpdesk/inbound/{token}`), and **email** via a parsing
  provider's webhook — a reply carrying the `[#N]` subject token becomes a
  comment, anything else a new ticket. All idempotent. The helpdesk holds no
  mailbox credentials. See [docs/protocol.md](docs/protocol.md) and
  [docs/email-ingestion.md](docs/email-ingestion.md). (Beside these and the
  human `portal` / `agent`, a sixth `source`, `maintenance`, is written by the
  scheduler above rather than arriving from outside.)
- **Demo seeding**: `./helpdesk seed-demo --confirm` fills a showcase instance
  with a backdated, idempotent ticket history. In-process Go rather than an HTTP
  script because PocketBase's autodate overwrites `created` on save — no
  external client can produce a demo whose ages look real.
- **Throughout the SPA**: live updates (PocketBase realtime subscriptions),
  light/dark themes, keyboard shortcuts, responsive table-to-card layouts,
  filters that live in the URL on every filtered board (staff queue, Reports,
  Dispatch; portal tickets, visits, projects, things, Summary), and
  self-service profile edits + forgot-password reset.

## Build & run

The SPA is `//go:embed`-ed at compile time; the committed
`internal/webui/public` means a fresh checkout builds without npm — but
**rebuild and re-commit it whenever `ui/` changes**.

```bash
cd ui && npm ci                 # once
npm run build                   # vue-tsc + vite → ../internal/webui/public (commit the output)
cd .. && go build ./cmd/helpdesk
./helpdesk serve                # UI at http://127.0.0.1:8090/ · PocketBase admin at /_
```

First start seeds a bootstrap staff admin (`admin@helpdesk.local`) and
prints its password **once**. Configuration is `helpdesk.yaml` +
`HELPDESK_*` env overrides — see
[docs/configuration.md](docs/configuration.md). SMTP (outbound email) and
the application URL (ticket links in emails) are configured in the
PocketBase dashboard, not the YAML.

The UI is **rebrandable at runtime without a rebuild**: point `branding.dir`
(env `HELPDESK_BRANDING_DIR`) at a host directory of `theme.css` / `logo.svg` /
`branding.json` to override the app name, logo, and theme — see
[docs/configuration.md](docs/configuration.md#branding-overlay) and the
[`branding.example/`](https://github.com/stone-age-io/helpdesk/blob/main/branding.example) template. It also installs as a PWA
(the service worker is deliberately a **no-op** — an app whose job is live
ticket state must not serve yesterday's queue).

To fill a showcase instance with realistic, backdated demo data:

```bash
./helpdesk seed-demo --confirm
```

`--confirm` is required because the subcommand ships in the production binary.
It is idempotent and suppresses all notification mail, so re-running it can't
duplicate records or email a few dozen fictional people. `--tickets N` sets the
ticket count to converge on (default 150).

```bash
go test ./...
```

## Repo layout

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

## Architecture notes

- Standalone sibling app (kiosk / access-control pattern), deliberately
  **not** a platform feature: helpdesk agents never hold control-plane
  credentials, and the tenancy axes differ (platform tenant = customer org;
  helpdesk tenant = the MSP).
- Tenancy is plain collection rules — `customers` + `users.customer` +
  staff roles (`internal/authz`). No pb-tenancy. See
  [docs/data-model.md](docs/data-model.md).
- NATS is best-effort: the app boots and serves portal/webhook traffic
  without a broker; the durable consumer resumes where it left off.
- The org id in a machine ticket comes from the **subject** (rewritten by
  the operator-signed platform import), never the payload.
- The helpdesk also **owns an outbound stream** (`HELPDESK_NOTIFICATIONS`,
  subjects `helpdesk.*.events.>`), disjoint from the ingest stream at token 3
  (`events` vs `tickets`) so an emitted event can't loop back through ingest.
- `things` and `locations` **join** the platform by `(customer, code)`; they are
  not synced and cannot be. Bulk loading is an operator-run export → seed, which
  is why both shapes stay a faithful subset of the platform's.
- Collection rules are the security boundary, so the portal-facing ones are
  tested by **executing** them over HTTP, not by asserting on the rule string —
  see `migrations/1825000000_portal_site_device_test.go`.
