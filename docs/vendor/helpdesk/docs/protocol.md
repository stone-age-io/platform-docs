---
path: helpdesk/protocol
nav_order: 30
---
# Helpdesk wire contract

How tickets reach the helpdesk from outside the SPA (NATS machine events and
the authenticated HTTP webhook), and how the helpdesk emits its own events
back onto NATS (outbound notifications).

## NATS ticket events

### Subjects

Customer-side apps (things, rule-router) publish inside their own org's
NATS account:

```
helpdesk.tickets.create
```

The platform's managed-org export/import (platform commit `45ca1e3`)
delivers those into the operator hub account with the org id injected as
token 2:

```
helpdesk.{orgCode}.tickets.create
```

The injection is the provenance mechanism: the subject rewrite is signed by
the operator import, so a customer cannot spoof another org's id. Ingestion
therefore parses the org id **from the subject only** — an org id in the
payload is ignored.

v1 consumes only the `create` verb. The `{verb}` position deliberately
leaves room for `comment` / `resolve` later without a subject migration.

### Payload (`helpdesk.tickets.create`)

```json
{
  "title": "pump fault on line 3",          // required
  "body": "vibration sensor overcurrent",   // optional
  "priority": "high",                       // optional: low|normal|high|urgent (else normal)
  "dedupe_key": "pump-7-overcurrent",       // optional: idempotency key, unique per customer
  "thing": "pump-7",                        // optional: free-text, stored as thing_note
  "thing_code": "PUMP-7",                   // optional: resolves to a things row (this customer)
  "location": "line-3",                     // optional: free-text, stored as location_note
  "location_code": "BLDG-C",                // optional: resolves to a locations row (this customer)
  "category": "iot-device"                  // optional: a ticket_categories key
}
```

Behavior:

- **Unknown org** (no customer row with that `code`): the event
  is logged (`ingest: no customer mapped for organization code`) and acked. Map
  the customer in the SPA and later events flow; the missed event is not
  replayed.
- **`dedupe_key`**: if a ticket with the same key exists, the event is
  acked without creating a second ticket. Publishers should stamp a stable
  key for retry loops and flapping sources. The key is unique **per customer**
  (`(customer, dedupe_key)`, migration `1830000000`), so publishers in different
  tenants can't collide; within one customer the key space is shared with that
  customer's webhook calls and email `Message-ID`s.
- **`thing`** and **`location`** are free text, stored as `thing_note` and
  `location_note`. **`thing_code`** and **`location_code`** are the platform
  join keys: each resolves against this customer's `things` / `locations` rows
  (matched on `code`) and sets the corresponding relation — the queryable
  reporting axes. An unresolved code is logged and, when the payload's matching
  free-text field is empty, kept as a breadcrumb in the note field (supplied
  `thing` / `location` text wins over the code). No row is auto-created, so the
  operator can add the missing row and later events resolve.

  The two resolve independently: a resolved `thing` does **not** backfill the
  ticket's `location`, even though the thing record has one. One payload field
  maps to one ticket field; inference belongs in the UI, not the projection.

  Both codes are `(customer, code)`-scoped, so a code can never resolve across
  tenants. Note that the platform does **not** freeze `things.code` or
  `locations.code` — renaming one upstream means later events stop resolving and
  fall back to free text until the helpdesk row is updated to match.
- **`category`** is matched against a `ticket_categories` `key`; an unknown
  or inactive key is ignored (the ticket is still created, unclassified) —
  the same graceful-degradation stance as an unmapped org.
- The full hub-side subject is recorded on the ticket as `origin_subject`;
  `source` is `nats`. The ticket lands as `type = reactive`, status `open`.
  The staff triage fields (`type`, `project`, `due_at`, `estimated_minutes`,
  assignee) are not part of this contract; unknown payload fields are ignored.
- Malformed payloads (including a missing/blank `title`) and unsupported verbs
  are logged and acked (terminal — redelivery cannot fix them). A transient DB
  failure is the only case that NAKs for redelivery.

### Stream / consumer (helpdesk-owned)

The helpdesk creates and owns its inbox stream in the hub account:

- Stream `HELPDESK_EVENTS` (configurable: `nats.stream`), subjects
  `helpdesk.*.tickets.>`, file storage, 7-day age limit.
- Durable consumer `helpdesk-ingest` (configurable: `nats.durable`),
  explicit ack — restarts resume from the last-acked sequence.

The helpdesk's NATS identity is a hub-account `nats_user` minted by the
platform, scoped to `sub helpdesk.>` (plus `pub helpdesk.>` once outbound
notifications are enabled — see below), delivered as a `.creds` file
(`nats.creds_file`).

## NATS notification events (outbound)

The mirror of ingestion: when a notification template has `publish_nats`
enabled, the helpdesk publishes a fixed JSON envelope for that event onto the
hub account — for MSP-internal consumers (Slack/Teams bridges, on-call/paging,
metrics), **never** customers. This is a second delivery channel alongside
email; the two are configured and gated independently per template.

### Subjects

```
helpdesk.{customerCode}.events.{event_type}
```

- `{customerCode}` is `customers.code` — the ecosystem's tenant token, the same
  handle token 2 carries on the way **in**, and the same one the platform stamps
  on its operator-signed subject rewrite (ADR 0002 in `platform-docs`). Both
  directions of the boundary name a tenant the same way, so a consumer can join
  helpdesk events to platform data without a mapping table.
- A customer with **no code is not published for**. The event is skipped and the
  reason recorded on its `notification_send_log` row. There is deliberately no
  fallback to the customer's record id: a token that is sometimes a shared code
  and sometimes one app's local primary key is not a token, because a consumer
  cannot tell which it is holding. Set `customers.code` to turn the channel on
  for that tenant.
- `platform_org_id` is **not** in the subject — it is optional, so it would leave
  a hole; it rides the payload instead when known.
- `{event_type}` is the notification event (`ticket.created`,
  `ticket.status_changed`, `visit.scheduled`, …); its embedded dot supplies the
  trailing `domain.verb` tokens.

> **Changed.** Token 2 was the ticket's `customer` relation id until ADR 0002.
> That was always present and token-safe, but it put this app's own primary key
> in a subject crossing to other applications — so any consumer joining these
> events to anything else needed a mapping table only this database could
> produce.

Token 3 is the literal `events`, which is what keeps this stream disjoint from
the ingest stream (`helpdesk.*.tickets.>`): `events` ≠ `tickets`, so JetStream
accepts both, and an outbound event can never be re-ingested as a ticket.

### Envelope (`schema: helpdesk.event`, `version: 1`)

```json
{
  "schema": "helpdesk.event",
  "version": 1,
  "event_type": "ticket.status_changed",
  "occurred_at": "2026-07-15T14:02:11Z",
  "customer": { "id": "cust123", "name": "Acme Corp", "platform_org_id": "org_..." },
  "ticket": {
    "id": "rec123", "number": 42, "title": "Pump fault on line 3",
    "status": "in_progress", "priority": "high", "type": "reactive",
    "source": "nats", "url": "https://helpdesk.example.com/t/rec123",
    "assignee": { "name": "Sam Staff", "email": "sam@msp.example" }
  },
  "change": { "field": "status", "from": "open", "to": "in_progress" }
}
```

- `customer.platform_org_id` is omitted when the customer isn't mapped.
  `customer.id` is the helpdesk record id; the tenant code is in the subject,
  not the payload.
- Optional blocks are **omitted**, never `null`: `change` is present only for
  `ticket.status_changed`; `comment` (`author_name`, `body`, `by_staff`) only
  for `ticket.commented`; `visit` only for the `visit.*` events
  (`visit.scheduled`, `visit.rescheduled`, `visit.canceled`, `visit.completed`).
  Likewise `ticket.type`, `ticket.url` (empty when the PocketBase application
  URL isn't set) and `ticket.assignee` drop out when empty.
- On `visit.*` events `ticket.assignee` is the visit's **technician**, not the
  ticket's assignee (when the visit has one).
- The full event set is the eight notification types: `ticket.created`,
  `ticket.assigned`, `ticket.commented`, `ticket.status_changed`, and the four
  `visit.*` above. Internal (staff-only) comments emit no `ticket.commented`.
- The `visit` block carries `scheduled_at`, `assignee_name`, `location`, `notes`
  as available, plus `old_scheduled_at` (only on `visit.rescheduled`) and
  `completed_at` (only on `visit.completed`). Empty fields are omitted.
- `visit.completed` is **NATS-only** — it publishes on this channel but is
  email-disabled by default (see `docs/notifications.md`). It is the machine
  signal that on-site work finished; the other visit events also email.
- The consumer is MSP-internal, so staff identity (assignee) is included — the
  portal's roster-hiding does not apply here.
- The per-recipient email rules (don't mail a comment's author) do not touch
  this channel, but a **silenced save** does: a ticket update sent with
  `X-Helpdesk-Quiet: 1`, and server-side changes marked with
  `notifications.Suppress` (the requester-reply auto-reopen, the
  `auto_close_resolved` cron, demo seeding), skip the whole event — no email
  *and* no publish. A consumer tracking status should not assume it sees every
  transition; `ticket_events` is the complete record.

### Stream (helpdesk-owned)

- Stream `HELPDESK_NOTIFICATIONS` (configurable: `nats.notify_stream`), subjects
  `helpdesk.*.events.>`, file storage, 7-day age limit, 2-minute `Duplicates`
  window. Each publish carries a `Nats-Msg-Id` header
  (`{event_type}:{occurrenceKey}`) so a republished event collapses inside that
  window. The MSP's automation owns the **consumer**; the helpdesk only
  publishes.
- Best-effort: if the creds lack publish/stream-management or the stream can't
  be ensured at boot, the helpdesk logs once and email keeps working — NATS
  publishes become silent no-ops.

## HTTP webhook

```
POST /api/helpdesk/inbound/{token}
Content-Type: application/json
```

`{token}` is the per-customer shared secret (`customers.webhook_token`).
Admin staff reveal or rotate it from the customer detail view (server
routes: `POST /api/helpdesk/customers/{id}/webhook-token`, add `?rotate=1`
to regenerate; both return `{"token": "..."}`, non-admins get `403`). Possession
of the token both authenticates the caller and selects the customer. Email
providers do **not** use this route — they have their own, below.

### Payload

```json
{
  "title": "printer on fire",            // required
  "body": "3rd floor copy room",         // optional
  "priority": "urgent",                  // optional: low|normal|high|urgent (else normal)
  "requester_email": "rita@acme.com",    // optional: links an existing portal account
  "dedupe_key": "alarm-1234",            // optional: idempotency key (per customer)
  "category": "hardware",                // optional: a ticket_categories key (unknown ignored)
  "thing": "printer-3f",                 // optional: free-text (thing_note)
  "thing_code": "HQ-PRN-3",              // optional: resolves to a things row (this customer)
  "location": "3rd floor copy room",     // optional: free-text (location_note)
  "location_code": "BLDG-C"              // optional: resolves to a locations row (this customer)
}
```

### Responses

- `201` `{"id": "...", "number": 17, "duplicate": false}` — ticket created
  (`source = webhook`).
- `200` `{"id": "...", "number": 17, "duplicate": true}` — a ticket of this
  customer with this `dedupe_key` already exists (including one a concurrent
  delivery created a moment earlier); its identifiers are returned.
- `400` — missing/invalid title or malformed JSON.
- `404` — unknown token (same shape for an inactive customer; the route is
  not an oracle).

`requester_email` is matched only against portal accounts belonging to the
token's customer — a stray email can never link a ticket across tenants.
Non-matching emails are silently ignored (the ticket is still created,
unlinked).

`thing_code` and `location_code` resolve to one of the token customer's `things`
/ `locations` rows (by `code`) and set the corresponding relation; an unresolved
code stays as free text in its note field (same behavior, and same customer
scoping, as the NATS intake).

The free-text thing field is spelled **`thing`**, matching the NATS contract —
it was `asset` before the `things` collection existed.

As on NATS, the ticket lands as `type = reactive` and the staff triage fields
are not accepted (unknown JSON fields are ignored). `dedupe_key` is scoped to the
token's customer and shares that customer's key space with NATS and email (see
above).

## HTTP inbound (email provider)

```
POST /api/helpdesk/inbound/email/{provider}   # {provider} = postmark
Authorization: Basic <base64(user:secret)>
Content-Type: application/json
```

A distinct intake for **email**: an email-parsing provider (Postmark to start)
receives forwarded mail, parses the MIME, and posts its own JSON here. Each
adapter registers its own literal path — today only `/inbound/email/postmark`
exists. The route exists only when `inbound.secret` is configured; the caller
authenticates with that secret as the Basic-auth **password** (the username is
ignored), optionally IP-pinned to `inbound.allowed_ips` (IPs or CIDRs).
Unlike the token webhook, the tenant is **not** in the URL — it is resolved from
the sender. The full design (forwarding, threading, resolution ladder,
provider-agnostic core) is in [`email-ingestion.md`](email-ingestion.md); the
wire contract:

- The provider's payload is provider-specific (a thin adapter maps it to an
  internal `NormalizedInbound`). For Postmark the fields read are `MessageID`,
  `FromFull` (falling back to `From`), `Subject`, `StrippedTextReply`/`TextBody`,
  and `Headers` (`Message-ID` as a fallback id, `X-Spam-Status`,
  `Authentication-Results`, `Auto-Submitted`, `Precedence`). Ingestion is
  text-only; attachments are ignored (a non-goal — see `email-ingestion.md`).
  DKIM is log-only: a `dkim=fail` verdict is logged, never enforced.
- **Threading:** a `[#N]` token in the subject routes a reply onto ticket N as a
  comment — public when the sender belongs to that ticket's customer (a
  registered user of it, reopening it if `resolved`, or an address at its
  `email_domain`), otherwise **internal**, held for staff. A `closed` ticket
  instead spawns a new one. No token, or no ticket N ⇒ a new ticket,
  `source = email`.
- **Tenant (new tickets):** the sender resolves to a customer by exact
  `users.email`, else by an active customer's `customers.email_domain` (never a
  shared provider like gmail.com). Unresolvable ⇒ the message is acked and
  dropped, not funneled to a catch-all. A threaded reply skips this step — the
  ticket picks the tenant.
- **Idempotency:** the email `Message-ID` dedupes both paths (`tickets.dedupe_key`,
  unique per customer, and the hidden `ticket_comments.source_message_id`, unique). A message
  with no Message-ID is not deduped.

### Responses

Every intentionally-handled or intentionally-dropped message returns **2xx**, so
the provider stops retrying:

- `200` `{"status": "created|commented|duplicate", "id": "...", "number": 17}` —
  ticket created, reply threaded, or a redelivery deduped.
- `200` `{"status": "ignored", "reason": "..."}` — deliberately dropped
  (unresolved tenant, spam, or an auto-reply/loop). `reason` is one of
  `unresolved customer`, `spam`, `empty from`, `system sender`,
  `auto-submitted`, `bulk precedence`.
- `403` — caller IP not allowed (checked first). `401` — missing/invalid
  Basic-auth secret.
- `400` — undecodable JSON body.
- `500` — genuine server fault (the provider should retry).
