---
path: helpdesk/protocol
nav_order: 30
---
# Wire Protocol

This page is the wire contract for everything that crosses the helpdesk's
boundary outside the SPA. Tickets arrive as NATS machine events, through a
per-customer HTTP webhook, or from an email-parsing provider. The helpdesk also
publishes its own notification events back onto NATS. For the config keys these
channels read, see [Configuration Reference](configuration.md).

---

## 1. The Whole Surface

| Channel | Subject or route | Direction | Authenticated by |
| :--- | :--- | :--- | :--- |
| [NATS ticket events](#2-nats-ticket-events) | `helpdesk.{orgCode}.tickets.create` | in | the operator-signed subject rewrite |
| [NATS notification events](#3-nats-notification-events-outbound) | `helpdesk.{customerCode}.events.{event_type}` | out | the helpdesk's hub-account creds |
| [HTTP webhook](#4-http-webhook) | `POST /api/helpdesk/inbound/{token}` | in | the per-customer token |
| [Email provider webhook](#5-email-provider-webhook) | `POST /api/helpdesk/inbound/email/{provider}` | in | Basic auth with `inbound.secret` |

---

## 2. NATS Ticket Events

### Subjects

Customer-side apps (things, rule-router) publish inside their own
organization's NATS account:

```
helpdesk.tickets.create
```

The platform's managed-org export/import delivers those into the operator hub
account, with the organization code (`customers.code`) injected as token 2:

```
helpdesk.{orgCode}.tickets.create
```

::: note The tenant comes from the subject, never the payload
The operator import signs the subject rewrite, so a customer cannot spoof
another organization's code. Ingestion reads the tenant **from the subject
only**. An org id in the payload is ignored.
:::

Only the `create` verb is consumed. The `{verb}` token leaves room for
`comment` and `resolve` later without a subject migration.

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

### Behavior

- **Unknown organization.** When no customer row has that `code`, the event is
  logged (`ingest: no customer mapped for organization code`) and acked. Map
  the customer in the SPA and later events flow. The missed event is not
  replayed.
- **`dedupe_key`.** If a ticket with the same key exists, the event is acked
  and no second ticket is created. Publishers should stamp a stable key for
  retry loops and flapping sources. The key is unique **per customer**
  (`(customer, dedupe_key)`, migration `1830000000`), so publishers in
  different tenants cannot collide. Within one customer, the key space is
  shared with that customer's webhook calls and email `Message-ID`s.
- **`thing` and `location`** are free text, stored as `thing_note` and
  `location_note`.
- **`thing_code` and `location_code`** are the platform join keys. Each
  resolves against this customer's `things` or `locations` rows (matched on
  `code`) and sets the matching relation, which is what reports query on. An
  unresolved code is logged. When the payload's matching free-text field is
  empty, the code is kept as a breadcrumb in the note field (supplied `thing`
  or `location` text wins over the code). No row is auto-created, so you can
  add the missing row and later events resolve.
- **The two codes resolve independently.** A resolved `thing` does **not**
  backfill the ticket's `location`, even though the thing record has one. One
  payload field maps to one ticket field. Inference belongs in the UI, not the
  projection.
- **Both codes are `(customer, code)`-scoped**, so a code never resolves
  across tenants.
- **`category`** is matched against a `ticket_categories` `key`. An unknown or
  inactive key is ignored, and the ticket is still created, unclassified (the
  same as an unmapped org).
- **Provenance.** The full hub-side subject is recorded on the ticket as
  `origin_subject`, and `source` is `nats`. The ticket lands as
  `type = reactive`, status `open`.
- **Staff fields are not accepted.** The triage fields (`type`, `project`,
  `due_at`, `estimated_minutes`, assignee) are not part of this contract.
  Unknown payload fields are ignored.
- **Errors.** Malformed payloads (including a missing or blank `title`) and
  unsupported verbs are logged and acked, because redelivery cannot fix them. A
  transient database failure is the only case that NAKs for redelivery.

::: warning The platform does not freeze `things.code` or `locations.code`
Rename one upstream and later events stop resolving. They fall back to free
text until you update the helpdesk row to match.
:::

### Stream and consumer

The helpdesk creates and owns its inbox stream in the hub account:

| Resource | Default name | Config key | Details |
| :--- | :--- | :--- | :--- |
| Stream | `HELPDESK_EVENTS` | `nats.stream` | Subjects `helpdesk.*.tickets.>`, file storage, 7-day age limit. |
| Durable consumer | `helpdesk-ingest` | `nats.durable` | Explicit ack. A restart resumes from the last-acked sequence. |

The helpdesk's NATS identity is a hub-account `nats_user` minted by the
platform. It is scoped to `sub helpdesk.>`, plus `pub helpdesk.>` once outbound
notifications are enabled (§3), and delivered as a `.creds` file
(`nats.creds_file`). See [NATS credentials](configuration.md#nats-credentials).

---

## 3. NATS Notification Events (Outbound)

This is the mirror of ingestion. When a notification template has
`publish_nats` enabled, the helpdesk publishes a fixed JSON envelope for that
event onto the hub account. The consumers are MSP-internal (Slack or Teams
bridges, on-call paging, metrics), **never** customers. It is a second delivery
channel beside email, and each template turns the two on separately.

### Subjects

```
helpdesk.{customerCode}.events.{event_type}
```

- **`{customerCode}` is `customers.code`**, the ecosystem's tenant token. It is
  the same handle token 2 carries on the way **in**, and the same one the
  platform stamps on its operator-signed subject rewrite (ADR 0002 in
  `platform-docs`). Both directions name a tenant the same way, so a consumer
  can join helpdesk events to platform data without a mapping table.
- **`platform_org_id` is not in the subject.** It is optional, so it would
  leave a hole. It rides the payload instead, when known.
- **`{event_type}`** is the notification event (`ticket.created`,
  `ticket.status_changed`, `visit.scheduled`, ...). Its embedded dot supplies
  the trailing `domain.verb` tokens.
- **Token 3 is the literal `events`**, which keeps this stream disjoint from the
  ingest stream (`helpdesk.*.tickets.>`). Because `events` is not `tickets`,
  JetStream accepts both streams, and an outbound event can never be
  re-ingested as a ticket.

::: warning A customer with no code is not published for
The event is skipped and the reason is recorded on its
`notification_send_log` row. There is no fallback to the customer's record
id: a token that is sometimes a shared code and sometimes one app's own
primary key is not a token, because a consumer cannot tell which it holds.
Set `customers.code` to turn the channel on for that tenant.
:::

### Envelope

The envelope is `schema: helpdesk.event`, `version: 1`:

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

The full event set is the eight notification types:

| Event | Optional block | Notes |
| :--- | :--- | :--- |
| `ticket.created` | none | |
| `ticket.assigned` | none | |
| `ticket.commented` | `comment` (`author_name`, `body`, `by_staff`) | Internal (staff-only) comments emit no `ticket.commented`. |
| `ticket.status_changed` | `change` | |
| `visit.scheduled` | `visit` | |
| `visit.rescheduled` | `visit`, plus `old_scheduled_at` | |
| `visit.canceled` | `visit` | |
| `visit.completed` | `visit`, plus `completed_at` | **NATS-only.** Email-disabled by default. |

- **Optional blocks are omitted, never `null`.** Likewise `ticket.type`,
  `ticket.url` (empty when the PocketBase application URL is not set) and
  `ticket.assignee` drop out when empty.
- **`customer.platform_org_id`** is omitted when the customer is not mapped.
  `customer.id` is the helpdesk record id. The tenant code is in the subject,
  not the payload.
- **The `visit` block** carries `scheduled_at`, `assignee_name`, `location` and
  `notes` as available, plus `old_scheduled_at` (only on `visit.rescheduled`)
  and `completed_at` (only on `visit.completed`). Empty fields are omitted.
- **On `visit.*` events, `ticket.assignee` is the visit's technician**, not the
  ticket's assignee (when the visit has one).
- **`visit.completed`** is the machine signal that on-site work finished. It
  publishes on this channel but does not email by default (see
  [Notifications](notifications.md)). The other visit events also email.
- **Staff identity is included.** The consumer is MSP-internal, so the
  assignee is in the envelope. The portal's roster-hiding does not apply here.

::: note A silenced save publishes nothing
The per-recipient email rules (do not mail a comment's author) do not touch
this channel, but a silenced save does. A ticket update sent with
`X-Helpdesk-Quiet: 1`, and server-side changes marked with
`notifications.Suppress` (the requester-reply auto-reopen, the
`auto_close_resolved` cron, demo seeding), skip the whole event: no email
*and* no publish. A consumer tracking status should not assume it sees every
transition. `ticket_events` is the complete record.
:::

### Stream

- **Stream `HELPDESK_NOTIFICATIONS`** (config `nats.notify_stream`), subjects
  `helpdesk.*.events.>`, file storage, 7-day age limit, 2-minute `Duplicates`
  window.
- **Each publish carries a `Nats-Msg-Id` header**
  (`{event_type}:{occurrenceKey}`), so a republished event collapses inside
  that window.
- **The MSP's automation owns the consumer.** The helpdesk only publishes.
- **Best-effort.** If the creds lack publish or stream-management permission,
  or the stream cannot be ensured at boot, the helpdesk logs once and email
  keeps working. NATS publishes become silent no-ops.

---

## 4. HTTP Webhook

```
POST /api/helpdesk/inbound/{token}
Content-Type: application/json
```

`{token}` is the per-customer shared secret (`customers.webhook_token`).
Holding the token both authenticates the caller and selects the customer. Email
providers do **not** use this route; they have their own (§5).

Admin staff reveal or rotate the token from the customer detail view, which
calls these server routes:

| Route | Does |
| :--- | :--- |
| `POST /api/helpdesk/customers/{id}/webhook-token` | Returns the token as `{"token": "..."}`. |
| `POST /api/helpdesk/customers/{id}/webhook-token?rotate=1` | Regenerates the token and returns it in the same shape. |

Non-admins get `403` from both.

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

- **`requester_email`** is matched only against portal accounts that belong to
  the token's customer, so a stray email can never link a ticket across
  tenants. A non-matching email is silently ignored, and the ticket is still
  created, unlinked.
- **`thing_code` and `location_code`** resolve to one of the token customer's
  `things` or `locations` rows (by `code`) and set the matching relation. An
  unresolved code stays as free text in its note field. Behavior and customer
  scoping are the same as the NATS intake (§2).
- **The free-text thing field is spelled `thing`**, matching the NATS contract.
- **The ticket lands as `type = reactive`**, as on NATS. The staff triage
  fields are not accepted, and unknown JSON fields are ignored.
- **`dedupe_key`** is scoped to the token's customer, and shares that
  customer's key space with NATS and email (§2).

### Responses

| Code | Body | When |
| :--- | :--- | :--- |
| `201` | `{"id": "...", "number": 17, "duplicate": false}` | Ticket created (`source = webhook`). |
| `200` | `{"id": "...", "number": 17, "duplicate": true}` | A ticket of this customer with this `dedupe_key` already exists, including one a concurrent delivery created a moment earlier. Its identifiers are returned. |
| `400` | | Missing or invalid title, or malformed JSON. |
| `404` | | Unknown token. An inactive customer gets the same response, so the route is not an oracle. |

---

## 5. Email Provider Webhook

```
POST /api/helpdesk/inbound/email/{provider}   # {provider} = postmark
Authorization: Basic <base64(user:secret)>
Content-Type: application/json
```

A separate intake for **email**. An email-parsing provider (Postmark to start)
receives forwarded mail, parses the MIME, and posts its own JSON here. Each
adapter registers its own literal path. Only `/inbound/email/postmark` exists
today.

The route exists only when `inbound.secret` is set. The caller authenticates
with that secret as the Basic-auth **password** (the username is ignored),
optionally IP-pinned to `inbound.allowed_ips` (IPs or CIDRs). Unlike the token
webhook, the tenant is **not** in the URL; it is resolved from the sender. The
full design (forwarding, threading, resolution ladder, provider-agnostic core)
is in [Email Ingestion](email-ingestion.md).

### Request

The provider's payload is provider-specific. A thin adapter maps it to an
internal `NormalizedInbound`. For Postmark the fields read are:

- `MessageID`
- `FromFull` (falling back to `From`)
- `Subject`
- `StrippedTextReply` / `TextBody`
- `Headers`: `Message-ID` (a fallback id), `X-Spam-Status`,
  `Authentication-Results`, `Auto-Submitted`, `Precedence`

Ingestion is text-only. Attachments are ignored (a non-goal, see
[Email Ingestion](email-ingestion.md)). DKIM is log-only: a `dkim=fail` verdict
is logged, never enforced.

### Handling

- **Threading.** A `[#N]` token in the subject routes a reply onto ticket N as
  a comment. The comment is public when the sender belongs to that ticket's
  customer: a registered user of it (whose reply also reopens a `resolved`
  ticket), or an address at its `email_domain`. Otherwise it is **internal**,
  held for staff. A `closed` ticket instead spawns a new one. No token, or no
  ticket N, gives a new ticket with `source = email`.
- **Tenant (new tickets).** The sender resolves to a customer by exact
  `users.email`, else by an active customer's `customers.email_domain` (never a
  shared provider like gmail.com). An unresolvable sender's message is acked
  and dropped, not funneled to a catch-all. A threaded reply skips this step,
  because the ticket picks the tenant.
- **Idempotency.** The email `Message-ID` dedupes both paths:
  `tickets.dedupe_key` (unique per customer) and the hidden
  `ticket_comments.source_message_id` (unique). A message with no Message-ID is
  not deduped.

### Responses

Every message that is handled or dropped on purpose returns **2xx**, so the
provider stops retrying:

- `200` `{"status": "created|commented|duplicate", "id": "...", "number": 17}`:
  ticket created, reply threaded, or a redelivery deduped.
- `200` `{"status": "ignored", "reason": "..."}`: dropped on purpose
  (unresolved tenant, spam, or an auto-reply or loop). `reason` is one of
  `unresolved customer`, `spam`, `empty from`, `system sender`,
  `auto-submitted`, `bulk precedence`.
- `403`: caller IP not allowed (checked first).
- `401`: missing or invalid Basic-auth secret.
- `400`: undecodable JSON body.
- `500`: a real server fault. The provider should retry.

---

## 6. Where to Go Next

- Config keys these channels read: [Configuration Reference](configuration.md)
- Which events notify whom, and template settings: [Notifications](notifications.md)
- Forwarding, threading and sender resolution: [Email Ingestion](email-ingestion.md)
- The collections tickets land in: [Data Model & Access Rules](data-model.md)
- How the pieces fit together: [Overview](overview.md)
