---
path: helpdesk/notifications
nav_order: 40
---
# Outbound notifications

Helpdesk emits notifications from ticket, comment, and visit activity over two
independent channels: **email** and a **NATS publish**. Templates live in the
`notification_templates` collection and are edited from the staff SPA
(**Notifications**, admin-only); the compiled-in defaults in
`internal/notifications/defaults.go` back the "Reset to defaults" button and
seed the rows on first run.

Everything here is **best-effort and never blocks a write**:

- No SMTP configured (PocketBase → Settings → Mail) → the email channel is a
  clean no-op. No NATS connection (or the platform hasn't granted publish) →
  the NATS channel is a clean no-op. The app runs fine with neither.
- Sends are async goroutines fired from `OnRecordAfter*Success` hooks, so a
  notification can never precede its own DB commit, and a delivery failure
  never fails the ticket/comment/visit save.
- Every attempt (success or failure), on either channel, is written to
  `notification_send_log` (visible in the SPA, `channel` = `email` | `nats`)
  so you can answer "did that go out?". Email writes one row per recipient;
  `status` is `sent` | `failed` | `skipped` (an email whose recipients resolve
  to nobody, or a NATS publish with no customer code, is a `skipped` row). A
  NATS channel with no connection writes nothing — nothing was attempted.

## Channels

The same eight events drive both channels; each template gates them
**independently**:

- **`enabled`** — send email to the resolved recipient classes.
- **`publish_nats`** — publish a fixed JSON envelope to
  `helpdesk.{customerCode}.events.{event_type}` (see `docs/protocol.md` →
  *NATS notification events*). Token 2 is `customers.code` — the ecosystem's
  tenant handle, the same token the *inbound* subject carries, so both
  directions of the boundary name a tenant the same way. A customer with no
  code is **skipped, not published under a fallback**, and the reason lands on
  the send-log row. No template text is involved — the envelope is a
  versioned, code-defined contract for machine consumers, so a template edit
  can't produce malformed JSON. Off by default (except `visit.completed`,
  below); opt in per event.

A failure on one channel never suppresses the other. Of the suppression rules
below, **author-side blanking** is email-only — it narrows the recipient list,
so the NATS channel still publishes the comment event. The **quiet header** and
**`Suppress`** are not: they stop the hook before the event is dispatched at
all, so a silenced save is silent on **both** channels (an auto-closed ticket
publishes no `ticket.status_changed`, for instance).

## Events

Eight event types, each one template row. "Fires when" is the exact
condition; visit events fire on **transitions**, not raw saves.

| Event                    | Fires when                                                        | Default recipients      |
| ------------------------ | ----------------------------------------------------------------- | ----------------------- |
| `ticket.created`         | a ticket is created                                               | requester + all staff   |
| `ticket.assigned`        | `assignee` is newly set or changed on an **update** (a ticket created already assigned sends only `ticket.created`) | assignee |
| `ticket.commented`       | a **public** comment is created (internal notes never send)       | requester + assignee\*  |
| `ticket.status_changed`  | `status` changes                                                  | requester               |
| `visit.scheduled`        | a visit becomes `scheduled` (created scheduled, or requested→scheduled) | requester + assignee |
| `visit.rescheduled`      | `scheduled_at` moves while the visit stays `scheduled`            | requester + assignee    |
| `visit.canceled`         | a **scheduled** visit becomes `canceled`                          | requester + assignee    |
| `visit.completed`        | a visit becomes `completed` (or is back-dated straight to it)     | **none — NATS-only**†   |

\* On comments the author's own side is blanked (see Suppression). A staff
comment therefore mails the requester; a requester comment mails the
assignee.

† `visit.completed` ships **email-disabled and `publish_nats` enabled** (seeded
by migration `1817000000`). Completion is already communicated to humans by the
ticket's status/comments, so an inbox message would be noise — but the wire
event is a "work done on site" signal for MSP-internal automation (billing /
CMDB sync / SLA close-out). An operator can still enable email and add
recipients from the editor; the compiled-in template renders a sensible message
if they do.

**Deliberately silent** (no event at all): canceling a bare `requested` visit
(nothing was announced yet), and swapping a visit's technician without changing
the time.

For visit events the visit's **technician** (`assignee`) overrides the
ticket's assignee in the payload — both the `{{.Visit.AssigneeName}}` field
and the assignee recipient class point at whoever is dispatched.

## Recipient classes

Each template's audience is a JSON spec on the row (editable in the SPA); an
empty column falls back to the event's compiled-in default.

| Class       | Resolves to                                                    |
| ----------- | -------------------------------------------------------------- |
| `requester` | the ticket's requester — **only if** the payload has one. Machine tickets (no requester) resolve to nothing. |
| `assignee`  | the ticket's (or visit's) assigned staff member, when present. |
| `all_staff` | every `staff` row with `active = true`.                        |
| `extras`    | free-form addresses, e.g. a shared ops mailbox.                |

All classes off + empty `extras` = a no-op skip, not an error.

## Suppression — when a mail is deliberately not sent

Four independent mechanisms, all designed to prevent noise:

1. **Author-side blanking** (comments) — the payload suppresses the side that
   authored the comment, so nobody is emailed about their own comment.
2. **`X-Helpdesk-Quiet: 1` header** — the staff UI sends this on a ticket
   update that shouldn't email anyone (triage cleanup, mis-set-status fix,
   an internal reassignment). The request hook flags the record; the
   after-success hook skips the send.
3. **`notifications.Suppress(record)`** — a server-initiated change whose news
   already went out another way (or should never be announced at all) marks
   itself silent. Honoured by **every** send hook: ticket create/update,
   comment create, and visit create/update. Three callers today: auto-reopen (a
   requester's comment reopens a resolved ticket, but the comment mail already
   alerted staff, so the status-change mail is skipped); auto-close (an
   administrative tidy-up, not a "we closed your ticket" message); and
   `internal/demoseed`, which marks every write so seeding a showcase host can't
   mail 150 fictional people. It originally guarded only the ticket-update hook,
   which made it a trap — the name promises more than one event.
4. **Day-keyed dedupe** — `SendIfFirst` writes `notification_dedupe` with a
   unique index on (event, ref, UTC-day) and dispatches (both channels) only
   if its insert wins, so a flapping source can't announce the same thing twice
   in a day. It is plumbing, not yet policy: **no built-in hook calls it today**
   — every event goes through plain `Send`. A machine publisher's retries are
   absorbed earlier, by `tickets.dedupe_key`, which stops the duplicate ticket
   (and so its `ticket.created`) from existing at all.

### The deliberate non-suppression

`internal/maintenance` opens tickets from a cron and pointedly does **not**
call `Suppress` — the opposite call from auto-close, which runs fifteen
minutes earlier (03:30) in the same 03:xx window. Auto-close is administrative
tidying nobody needs to hear about; a newly opened preventive ticket is real
news for whoever has to do the work. It fires `ticket.created` like any other ticket, and because
a maintenance plan has no requester, that event's requester recipient resolves
to nothing exactly as it does for a machine ticket — so only staff are mailed.
`internal/maintenance/notify_test.go` pins this, so adding a `Suppress` here
(which looks like tidiness) fails loudly rather than silently going quiet.

## Template syntax

Go `text/template`. Fields come from `TicketContext`
(`internal/notifications/context.go`): `.Ticket.{Number,Title,Body,Status,
Priority,Source,Type,URL,OldStatus}`, `.Customer`, `.Requester.Name`,
`.Assignee.Name`, `.Comment.{AuthorName,Body}`, `.Visit.{ScheduledAt,
Location,Notes,AssigneeName,OldScheduledAt,CompletedAt}`. `OldStatus` is set
only on `ticket.status_changed` and `OldScheduledAt` only on
`visit.rescheduled`; `CompletedAt` is empty until the visit is completed.
`.Visit.Location` is the visit's free-text directions, not the ticket's
`location` record. A missing relation renders as a
zero value (a machine ticket with no requester simply renders nothing for
that side), so guard optional blocks with `{{if ...}}`.

Small FuncMap: `formatTime` (a timestamp in the **server's local timezone**,
`Jan 2, 2006 3:04 PM`; empty for a blank value), `statusLabel` (`in_progress`
→ `in progress`), and `pluralize N "noun"` (`1 visit`, `3 visits`). The same
map serves subject and body.

`.Ticket.URL` is the role-neutral deep link `{AppURL}/t/{id}` — the SPA
router forwards `/t/{id}` to the staff or portal detail view by who is logged
in. Set the **Application URL** in the PocketBase dashboard or the link is
empty (the default templates tolerate that).

## Editor API

Admin staff only, under `/api/helpdesk/notifications`:

- `GET  /api/helpdesk/notifications` — list templates.
- `PATCH /api/helpdesk/notifications/{event_type}` — edit subject, body,
  recipients, `enabled` (email), `publish_nats` (NATS channel). Parse-validates
  the templates before saving, so a bad `{{...}}` is rejected at edit time
  rather than at send time.
- `GET  /api/helpdesk/notifications/{event_type}/defaults` — the compiled-in
  subject, body and default recipients (backs "Reset to defaults"; read-only —
  the admin still saves).
- `GET  /api/helpdesk/notifications/{event_type}/nats-sample` — the subject
  pattern + a representative JSON envelope for the event's NATS channel,
  rendered from the publish code itself (`SampleEnvelope`) so it can't drift.
  Backs the "see event format" reference drawer next to the NATS toggle.
- `POST /api/helpdesk/notifications/{event_type}/test` — render the draft
  (unsaved `subject`/`body` in the request body, else the stored row) against
  built-in sample data and mail it to the calling admin, subject prefixed
  `[TEST]`. Synchronous, email-only, and **not** written to the send log; an
  SMTP failure comes back in-band as `{sent: false, error}`.

## Retention

`notification_send_log` and `notification_dedupe` are pruned daily at 03:15
local, keeping 90 days (`sendLogRetentionDays` in `cmd/helpdesk/main.go`).
The cron is process-local; if the app is down at fire time, the next live
tick clears the backlog.
