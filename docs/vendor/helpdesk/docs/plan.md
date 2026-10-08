---
path: helpdesk/plan
nav_order: 70
---
# Helpdesk v1 — Implementation Plan

Status: **implemented, and since superseded in scope.** This is the original v1
plan and is kept as the record of *why* the foundations are shaped the way they
are — the standalone-sibling decision, subject-based provenance, no pb-tenancy.
It is **not** a description of the app as it stands.

Reality has moved past it in several places; where they disagree, the current
docs win:

- The app grew a **service-delivery layer** — projects, locations, things and
  their types — planned separately in
  [service-delivery-plan.md](service-delivery-plan.md) and described in
  [data-model.md](data-model.md).
- "Native SMTP inbound out of scope" still holds literally, but **email
  ingestion shipped** via a parsing provider's webhook — see
  [email-ingestion.md](email-ingestion.md).
- Notifications gained an eighth event and a **second channel** (NATS publish)
  — see [notifications.md](notifications.md) and
  [nats-notifications-plan.md](nats-notifications-plan.md).
- Tickets gained a two-stage `resolved` → `closed` lifecycle with auto-close, a
  billable/non-billable time ledger, start/stop timers, effort estimates, and
  an `awaiting_requester` nudge.
- **Subject token 2 is no longer the platform org id.** Everywhere below that
  says `helpdesk.{platformOrgId}.>` or resolves against
  `customers.platform_org_id`, read `customers.code` instead (migration
  `1828000000`, ADR 0002 in `platform-docs`) — the same token now names the
  tenant in *both* directions. `platform_org_id` survives, but only to record
  that a customer is a platform organization. See [protocol.md](protocol.md).
- Locations and things grew **printable QR labels and an in-app scanner**, whose
  payload is the bare `code`; the field shell reaches both plus the scanner
  behind its **More** tab.
- **Preventive maintenance** shipped (`maintenance_plans` + a nightly cron), and
  tickets gained a `due_at`. The "SLA timers out of scope" line below still
  holds exactly as written: `due_at` is an inert date with no clock, no breach
  state and no escalation. A fifth `source`, `maintenance`, marks the tickets
  the scheduler opens. See [data-model.md](data-model.md).

For what the app actually does today, start at [`CLAUDE.md`](https://github.com/stone-age-io/helpdesk/blob/main/CLAUDE.md) and
[data-model.md](data-model.md).

## Context

A helpdesk/service-ticket application for the stone-age.io ecosystem, run by the platform operator (an MSP) to support the customer organizations on it. The unique capability is **machine-generated tickets**: things/rule-router publish events inside a customer org's NATS account on `helpdesk.>`, and the platform's managed-org export/import (shipped in platform commit `45ca1e3`) delivers them into the operator hub account as `helpdesk.{platformOrgId}.>` with unforgeable subject-based provenance. The helpdesk consumes that stream and turns events into work: tickets, comments, assignment, time entries, site visits, and outbound email.

**Architecture decisions (settled in discussion):**
- **Separate standalone PocketBase app** (sibling to kiosk/access-control), NOT a platform feature — helpdesk agents must never hold control-plane credentials, and the tenancy axes differ (platform tenant = customer org; helpdesk tenant = the MSP).
- **Simple sibling-style tenancy, no pb-tenancy**: `customers` data collection + requester `users.customer` relation + staff roles. Matches kiosk/access-control (neither uses pb-tenancy).
- **Requester portal login in v1** (password + optional OAuth2), plus agent/admin staff UI.
- **Time entries and site visits in v1** (minimal UI on ticket detail).
- **Repo**: `C:\Users\Brian\Documents\helpdesk`, module `github.com/stone-age-io/helpdesk`, single binary `cmd/helpdesk`. App subject token: `helpdesk` (owns `helpdesk.>`, matching the platform export).
- **v1 inbound**: NATS + authenticated webhook (the webhook is also the future email-provider integration point). Native SMTP inbound, SLA timers, KB, CSAT, magic links: out of scope.

**Proven patterns to follow/lift (from exploration):**
- App skeleton: access-control — `pocketbase.NewWithConfig` bootstrap, Go schema-as-code migrations with `migratecmd` Automigrate (`access-control/cmd/accessd/main.go:73-96`), embedded Vue UI via `//go:embed all:public` with committed dist (`access-control/internal/webui/embed.go`), NATS setup in `OnServe` / teardown in `OnTerminate`.
- NATS helper: copy/trim `access-control/internal/natsx/natsx.go` (Connect + EnsureStream; creds-file auth) and the `internal/subjects` single-value pattern (`access-control/internal/subjects/subjects.go`).
- Ingestion: kiosk controller's durable JetStream consumer projecting events into PB records (`kiosk/cmd/controller/main.go`).
- Email: lift kiosk's notifier subsystem nearly whole — DB-stored templates + Go text/template, Recipients JSON spec, dedupe collection w/ unique index, send log, retention cron, nil-notifier no-op (`kiosk/internal/notifications/{notifier,defaults,funcs}.go`). Swap its three domain touchpoints: admins-collection lookup, FuncMap verbs, event-type registry.
- Testing: kiosk's `setupApp(t)` harness — real PB against `t.TempDir()`, full migration set, injected NATS publisher fakes (`kiosk/internal/controller/consumer_test.go:16-35`).
- Config: viper struct + `HELPDESK_` env prefix, single-auth-method validation (pattern: `access-control/config/config.go`).

## Repo layout

```
helpdesk/
├── cmd/helpdesk/main.go        # PB bootstrap, OnServe wiring, embedded UI
├── config/                     # viper Config struct + helpdesk.yaml example
├── migrations/                 # Go schema-as-code, timestamp-prefixed, idempotent
├── internal/
│   ├── subjects/               # app token `helpdesk`; hub-side parse of {orgId}
│   ├── natsx/                  # copied/trimmed from access-control
│   ├── ingest/                 # durable consumer + payload→ticket projection
│   ├── inbound/                # webhook route handler
│   ├── notifications/          # lifted kiosk notifier (templates/dedupe/sendlog)
│   ├── tickets/                # ticket number assignment, status transitions, hooks
│   ├── authz/                  # staffRule/adminRule constants + route guards
│   └── webui/                  # //go:embed all:public (committed dist)
├── ui/                         # Vue 3 + Vite + Pinia + Tailwind + daisyUI + PB SDK
└── docs/protocol.md            # wire contract: subjects, payload shapes, webhook API
```

## Data model (Go migrations)

**Auth collections** (two, distinguished in rules by `@request.auth.collectionName`):
- `staff` — agents/admins. Fields: `name`, `role` (select: `agent`|`admin`), `active`. SPA staff login; OAuth2 optional. Bootstrap migration seeds one admin, password printed once (kiosk `1779000000_init.go` pattern).
- `users` — requesters. Fields: `name`, `customer` (relation→customers, required), `active`. `AuthRule: active = true && customer != ''`. Password + OAuth2 (Microsoft/Google) via PB settings.

**Data collections:**
- `customers` — `name`, `active`, `platform_org_id` (text, optional, unique when set — maps the NATS subject org token), `webhook_token` (text, autogenerated, unique — inbound webhook auth), `notes`.
- `tickets` — `number` (int, unique; assigned by create hook), `customer` (relation, required), `title`, `body`, `status` (select: `open`|`in_progress`|`waiting`|`resolved`|`closed`, default open), `priority` (select: `low`|`normal`|`high`|`urgent`, default normal), `assignee` (relation→staff), `requester` (relation→users, optional — machine tickets have none), `source` (select: `portal`|`agent`|`nats`|`webhook`), `origin_subject` (text — full NATS subject for machine tickets), `dedupe_key` (text; unique partial index when non-empty — ingestion idempotency).
- `ticket_comments` — `ticket` (relation, cascade), `author_staff` / `author_user` (exactly one set), `body`, `internal` (bool — staff-only notes).
- `time_entries` — `ticket`, `staff`, `minutes` (int >0), `work_date` (date), `note`.
- `visits` — `ticket`, `assignee` (relation→staff), `scheduled_at` (datetime), `status` (select: `scheduled`|`completed`|`canceled`), `notes`.
- `notification_templates`, `notification_dedupe`, `notification_send_log` — from kiosk notifier migrations (`1781000000`, `1783000000`).

**Access rules** (constants in `internal/authz`; `staffRule = "@request.auth.collectionName = 'staff'"`, `adminRule = staffRule + " && @request.auth.role = 'admin'"`):
- `tickets`: list/view `staffRule || (users && customer = @request.auth.customer)`; create `staffRule || (users && @request.body.customer = @request.auth.customer)`; update `staffRule` (requesters interact via comments); delete `adminRule`.
- `ticket_comments`: list/view `staffRule || (users && ticket.customer = @request.auth.customer && internal = false)`; create same shape (requesters can't set `internal`, guarded with `:isset`); update/delete `adminRule`.
- `time_entries`, `visits`: staff-only (all ops); requesters see outcomes via comments/status.
- `customers`: list/view `staffRule`; write `adminRule`. `webhook_token` hidden field.
- `users` (requesters): self view/update-own-profile; management `adminRule`.

## NATS ingestion (`internal/ingest`)

- Connect in `OnServe` via `natsx.Connect` with a creds file — a hub-account `nats_user` provisioned in the platform, permissions scoped to `sub helpdesk.>`. Config: `nats.urls`, `nats.creds_file`. Connection is best-effort (kiosk style): helpdesk boots and serves without NATS; ingestion resumes on reconnect.
- `EnsureStream("HELPDESK_EVENTS", ["helpdesk.*.tickets.>"])` in the hub account — the helpdesk owns its inbox stream (deliberately not the platform's job).
- **Wire contract** (documented in `docs/protocol.md`): customer-side apps publish `helpdesk.tickets.create` (hub sees `helpdesk.{orgId}.tickets.create`) with JSON `{title, body, priority?, dedupe_key?, thing?, location?}`. v1 supports the `create` verb only; the subject grammar leaves room for `comment`/`resolve` later.
- Durable consumer projects messages → tickets: parse `{orgId}` from subject token 2 (**never** from payload — provenance is the signed subject), look up `customers.platform_org_id`; unknown org → log warning + ack (operator maps the customer, later events flow). `dedupe_key` collision → ack + skip. `source = nats`, `origin_subject` recorded.

## Webhook inbound (`internal/inbound`)

`POST /api/helpdesk/inbound/{token}` — resolves customer by `webhook_token`; body `{title, body, priority?, requester_email?, dedupe_key?}`. Matches `requester_email` to an existing requester if present. Creates ticket with `source = webhook`. Rate-limit friendly, JSON errors. This route is the future email-provider (Postmark/Mailgun) integration point.

## Outbound email (`internal/notifications`)

Lift kiosk notifier core. Adaptations:
- Recipients spec becomes `{requester bool, assignee bool, all_staff bool, extras []string}`; resolver reads `staff` collection instead of kiosk's `admins`.
- v1 event types + defaults: `ticket.created` (requester + all_staff), `ticket.assigned` (assignee), `ticket.commented` (requester on public staff comment; assignee on requester comment), `ticket.status_changed` (requester), `visit.scheduled` (requester + assignee).
- Fired from record hooks (`OnRecordAfterCreateSuccess` on tickets/comments/visits; update hook diffing status/assignee). Nil notifier = no-op so the app runs without SMTP (configured via PB settings UI, as in kiosk).
- Keep dedupe, send log, retention cron as-is. Template editor UI ported from kiosk's SPA affordance.

## UI (Vue 3 + Vite + Pinia + Tailwind + daisyUI, platform conventions incl. Pattern A list views)

- **Login**: single page; attempts `staff` auth, falls back to `users` (requester). OAuth2 buttons when configured.
- **Staff views**: ticket queue (filter by status/assignee/customer/priority + search), ticket detail (comment thread w/ internal-note toggle, status/priority/assignee controls, time entry list+quick-add, visit list+schedule form), customers list/detail (webhook token reveal/regenerate), requester account management, notification template editor, simple dashboard (open-ticket counts by status/priority).
- **Requester views**: my company's tickets, ticket detail (public thread + comment box), new ticket form.
- Routing guards by auth collection: staff routes vs portal routes.

## Implementation phases

1. **Scaffold**: repo, go.mod, config package, PB bootstrap (`cmd/helpdesk/main.go`), migrations registry with all collections + rules + seed admin, embedded UI skeleton serving a login page. Kiosk-style test harness in place.
2. **Core ticketing UI**: login (both collections), staff queue + detail + comments, requester portal, customers admin.
3. **Email**: port notifier + templates + hooks + editor UI.
4. **NATS + webhook**: subjects/natsx/ingest packages, stream + durable consumer, customer mapping, webhook route. `docs/protocol.md`.
5. **Time + visits UI** on ticket detail.
6. **Docs**: README, CLAUDE.md (architecture narrative, access-control style), configuration doc.

Each phase compiles, passes tests, and is committable on its own.

## Verification

- **Per-package**: kiosk-style Go tests — migrations-backed `setupApp(t)` integration tests for rules (requester cannot read another customer's tickets / internal comments; staff can), ticket-number assignment, ingest projection with a fake publisher, notifier rendering + recipient resolution.
- **End-to-end with the platform** (the real proof, on the dev box):
  1. nats-server with the platform operator resolver; platform `serve`; managed customer org (from the shipped platform work) + its `platform_org_id` noted.
  2. In the platform, mint a hub-account `nats_user` scoped to `helpdesk.>`; export creds for the helpdesk.
  3. Run helpdesk; confirm `HELPDESK_EVENTS` stream created in hub account.
  4. `nats pub helpdesk.tickets.create '{"title":"pump fault",...}'` with the customer org's creds → ticket appears in the queue with correct customer + `origin_subject`; duplicate `dedupe_key` publish → no second ticket.
  5. Webhook curl with a customer's token → ticket; bad token → 404.
  6. Requester login: sees only own-company tickets (curl negative tests as in the platform verification).
  7. Email: point PB SMTP at a local Mailpit; verify ticket.created / commented / assigned mails render and log to `notification_send_log`.

## Out of scope (v1, deliberate)

Native SMTP inbound (use provider→webhook later), request/reply NATS service (ticket-ack), SLA timers/escalation, knowledge base, canned responses, CSAT, ticket merge/split, magic links, multi-MSP hosting (one helpdesk instance per MSP; pb-tenancy revisit only if hosted-SKU demand appears), calendar sync for visits.
