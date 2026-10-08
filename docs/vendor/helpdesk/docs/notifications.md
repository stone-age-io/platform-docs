---
path: helpdesk/notifications
nav_order: 40
---
# Notifications

Helpdesk sends notifications about ticket, comment and visit activity over two
independent channels: **email** and a **NATS publish**. This page covers the
events, who receives them, how they are suppressed, and how to edit the
templates. For the NATS envelope itself, see
[Wire Protocol](protocol.md). For inbound mail, see
[Email Ingestion](email-ingestion.md).

Templates live in the `notification_templates` collection. Admins edit them in
the staff SPA (**Notifications**, admin-only). The compiled-in defaults in
`internal/notifications/defaults.go` seed the rows on first run and back the
"Reset to defaults" button.

---

## 1. Delivery

Everything here is **best-effort and never blocks a write**:

- **Neither channel is required.** With no SMTP configured (PocketBase →
  Settings → Mail), the email channel is a clean no-op. With no NATS
  connection, or when the platform has not granted publish, the NATS channel
  is a clean no-op. The app runs fine with neither.
- **Sends follow the commit.** They are async goroutines fired from
  `OnRecordAfter*Success` hooks. A notification can never precede its own DB
  commit, and a delivery failure never fails the ticket, comment or visit
  save.
- **Every attempt is logged.** Each attempt on either channel, success or
  failure, is written to `notification_send_log` (visible in the SPA, with
  `channel` = `email` | `nats`), so you can answer "did that go out?". Email
  writes one row per recipient. `status` is `sent` | `failed` | `skipped`. An
  email whose recipients resolve to nobody, or a NATS publish with no customer
  code, is a `skipped` row. A NATS channel with no connection writes nothing,
  because nothing was attempted.

---

## 2. Channels

The same eight events drive both channels. Each template gates them
**independently**:

- **`enabled`:** send email to the resolved recipient classes.
- **`publish_nats`:** publish a fixed JSON envelope to
  `helpdesk.{customerCode}.events.{event_type}` (see
  [Wire Protocol](protocol.md), *NATS notification events*). Token 2 is
  `customers.code`, the ecosystem's tenant handle. The *inbound* subject
  carries the same token, so both directions name a tenant the same way.
  - A customer with no code is **skipped, not published under a fallback**,
    and the reason lands on the send-log row.
  - No template text is involved. The envelope is a versioned, code-defined
    contract for machine consumers, so a template edit cannot produce
    malformed JSON.
  - Off by default (except `visit.completed`, see
    [§3](#3-events)). Opt in per event.

A failure on one channel never suppresses the other.

::: note Some suppression stops both channels
Author-side blanking is email-only: it narrows the recipient list, so the
NATS channel still publishes the comment event. The quiet header and
`Suppress` stop the hook before the event is dispatched at all, so a
silenced save is silent on **both** channels. For example, an auto-closed
ticket publishes no `ticket.status_changed`. See [§5](#5-suppression).
:::

---

## 3. Events

Eight event types, one template row each. "Fires when" is the exact
condition. Visit events fire on **transitions**, not raw saves.

| Event                    | Fires when                                                        | Default recipients      |
| ------------------------ | ----------------------------------------------------------------- | ----------------------- |
| `ticket.created`         | a ticket is created                                               | requester + all staff   |
| `ticket.assigned`        | `assignee` is newly set or changed on an **update** (a ticket created already assigned sends only `ticket.created`) | assignee |
| `ticket.commented`       | a **public** comment is created (internal notes never send)       | requester + assignee\*  |
| `ticket.status_changed`  | `status` changes                                                  | requester               |
| `visit.scheduled`        | a visit becomes `scheduled` (created scheduled, or requested→scheduled) | requester + assignee |
| `visit.rescheduled`      | `scheduled_at` moves while the visit stays `scheduled`            | requester + assignee    |
| `visit.canceled`         | a **scheduled** visit becomes `canceled`                          | requester + assignee    |
| `visit.completed`        | a visit becomes `completed` (or is back-dated straight to it)     | **none (NATS-only)**†   |

\* On comments the author's own side is blanked (see [§5](#5-suppression)). A
staff comment mails the requester. A requester comment mails the assignee.

† `visit.completed` ships with **email disabled and `publish_nats` enabled**
(seeded by migration `1817000000`). The ticket's status and comments already
tell people about completion, so an email would be noise. The wire event is a
"work done on site" signal for MSP-internal automation (billing, CMDB sync,
SLA close-out). An operator can still enable email and add recipients in the
editor, and the compiled-in template renders a sensible message.

Two changes send **no event at all**: canceling a bare `requested` visit
(nothing was announced yet), and swapping a visit's technician without
changing the time.

For visit events, the visit's **technician** (`assignee`) replaces the
ticket's assignee in the payload. Both `{{.Visit.AssigneeName}}` and the
`assignee` recipient class point at whoever is dispatched.

---

## 4. Recipient Classes

Each template's audience is a JSON spec on the row, editable in the SPA. An
empty column falls back to the event's compiled-in default.

| Class       | Resolves to                                                    |
| ----------- | -------------------------------------------------------------- |
| `requester` | the ticket's requester, **only if** the payload has one. Machine tickets (no requester) resolve to nothing. |
| `assignee`  | the ticket's (or visit's) assigned staff member, when present. |
| `all_staff` | every `staff` row with `active = true`.                        |
| `extras`    | free-form addresses, such as a shared ops mailbox.             |

All classes off with empty `extras` is a no-op skip, not an error.

---

## 5. Suppression

Four independent mechanisms keep a notification from being sent:

1. **Author-side blanking** (comments). The payload suppresses the side that
   wrote the comment, so nobody is emailed about their own comment.
2. **The `X-Helpdesk-Quiet: 1` header.** The staff UI sends it on a ticket
   update that should email nobody (triage cleanup, fixing a mis-set status,
   an internal reassignment). The request hook flags the record, and the
   after-success hook skips the send.
3. **`notifications.Suppress(record)`.** A server-initiated change whose news
   already went out another way, or should never be announced, marks itself
   silent. **Every** send hook honours it: ticket create and update, comment
   create, and visit create and update. It has three callers:
   - **Auto-reopen.** A requester's comment reopens a resolved ticket. The
     comment mail already alerted staff, so the status-change mail is
     skipped.
   - **Auto-close.** An administrative tidy-up, not a "we closed your ticket"
     message.
   - **`internal/demoseed`.** It marks every write, so seeding a showcase
     host cannot mail 150 fictional people.
4. **Day-keyed dedupe.** `SendIfFirst` writes `notification_dedupe`, which has
   a unique index on (event, ref, UTC day), and dispatches (both channels)
   only if its insert wins. A flapping source then cannot announce the same
   thing twice in a day. **No built-in hook calls it**: every event goes
   through plain `Send`. A machine publisher's retries are absorbed earlier,
   by `tickets.dedupe_key`, which stops the duplicate ticket (and so its
   `ticket.created`) from existing at all.

### Maintenance tickets are not suppressed

`internal/maintenance` opens tickets from a cron and does **not** call
`Suppress`. This is the opposite of auto-close, which runs fifteen minutes
earlier, at 03:30. Auto-close is tidying nobody needs to hear about. A new
preventive ticket is real news for whoever has to do the work, so it fires
`ticket.created` like any other ticket. A maintenance plan has no requester,
so the requester recipient resolves to nothing, as it does for a machine
ticket, and only staff are mailed. `internal/maintenance/notify_test.go` pins
this: adding a `Suppress` there fails the test.

---

## 6. Template Syntax

Templates use Go `text/template`. Fields come from `TicketContext`
(`internal/notifications/context.go`):

- `.Ticket.{Number,Title,Body,Status,Priority,Source,Type,URL,OldStatus}`
- `.Customer`, `.Requester.Name`, `.Assignee.Name`
- `.Comment.{AuthorName,Body}`
- `.Visit.{ScheduledAt,Location,Notes,AssigneeName,OldScheduledAt,CompletedAt}`

`OldStatus` is set only on `ticket.status_changed`, and `OldScheduledAt` only
on `visit.rescheduled`. `CompletedAt` is empty until the visit is completed.
`.Visit.Location` is the visit's free-text directions, not the ticket's
`location` record. A missing relation renders as a zero value (a machine
ticket with no requester renders nothing for that side), so guard optional
blocks with `{{if ...}}`.

The same small FuncMap serves subject and body:

- **`formatTime`:** a timestamp in the **server's local timezone**,
  `Jan 2, 2006 3:04 PM`. Empty for a blank value.
- **`statusLabel`:** `in_progress` → `in progress`.
- **`pluralize N "noun"`:** `1 visit`, `3 visits`.

`.Ticket.URL` is the role-neutral deep link `{AppURL}/t/{id}`. The SPA router
forwards `/t/{id}` to the staff or portal detail view, depending on who is
logged in. Set the **Application URL** in the PocketBase dashboard, or the
link is empty (the default templates tolerate that).

---

## 7. Editor API

Admin staff only, under `/api/helpdesk/notifications`:

- **`GET /api/helpdesk/notifications`:** list templates.
- **`PATCH /api/helpdesk/notifications/{event_type}`:** edit subject, body,
  recipients, `enabled` (email) and `publish_nats` (NATS channel). It
  parse-validates the templates before saving, so a bad `{{...}}` is rejected
  at edit time, not at send time.
- **`GET /api/helpdesk/notifications/{event_type}/defaults`:** the compiled-in
  subject, body and default recipients. Backs "Reset to defaults". Read-only:
  the admin still saves.
- **`GET /api/helpdesk/notifications/{event_type}/nats-sample`:** the subject
  pattern and a representative JSON envelope for the event's NATS channel. It
  is rendered from the publish code itself (`SampleEnvelope`), so it cannot
  drift. Backs the "see event format" drawer next to the NATS toggle.
- **`POST /api/helpdesk/notifications/{event_type}/test`:** render the draft
  (unsaved `subject`/`body` in the request body, else the stored row) against
  built-in sample data, and mail it to the calling admin with the subject
  prefixed `[TEST]`. Synchronous, email-only, and **not** written to the send
  log. An SMTP failure comes back in-band as `{sent: false, error}`.

---

## 8. Retention

`notification_send_log` and `notification_dedupe` are pruned daily at 03:15
local time, keeping 90 days (`sendLogRetentionDays` in
`cmd/helpdesk/main.go`). The cron is process-local. If the app is down when it
should fire, the next live tick clears the backlog.

---

## 9. Where to Go Next

- The NATS notification envelope and subjects: [Wire Protocol](protocol.md)
- SMTP, Application URL and NATS settings: [Configuration Reference](configuration.md)
- The notification collections and their rules: [Data Model & Access Rules](data-model.md)
- Mail coming in, and how replies thread: [Email Ingestion](email-ingestion.md)
- How the pieces fit together: [Overview](overview.md)
