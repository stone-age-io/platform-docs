---
path: helpdesk/nats-notifications-plan
nav_order: 90
---
# Plan: NATS publish channel for notifications

Status: **implemented** (build + `go test ./...` green; SPA rebuilt). This
document is the implementation plan for adding a second delivery channel to the
notification subsystem — publishing a fixed, typed JSON envelope to JetStream
alongside (and independent of) email.

Two things it says are now wrong. The subject below is
`helpdesk.{customerId}.events.{event_type}`; token 2 became **`customers.code`**
in migration `1828000000` (ADR 0002 in `platform-docs`), so both directions of
the boundary name a tenant the same way, and a customer without a code is
skipped rather than published under a fallback.

And it says "seven event types" throughout; there are now **eight**. Migration
`1817000000` added `visit.completed`, which is the one event that ships
email-disabled and NATS-enabled — completion is already visible to humans via
the ticket's status and comments, but "work done on site" is exactly the signal
MSP-internal automation wants. See [notifications.md](notifications.md) for the
current event / recipient / suppression matrix and
[protocol.md](protocol.md#nats-notification-events-outbound) for the envelope.

## Goal & shape

For each of the seven event types, an admin can opt in to publishing a
**fixed, typed JSON envelope** to JetStream, alongside email. Email is
unchanged; a NATS failure never affects email and vice versa.

### Locked decisions

- Reuse the existing hub connection (`nc.JS`); the platform widens the creds to
  allow publish. The helpdesk stays blind to the grant.
- JetStream, **helpdesk-owned outbound stream** `HELPDESK_NOTIFICATIONS`.
- Subject: `helpdesk.{customerId}.events.{event_type}` → e.g.
  `helpdesk.rec8f3x…events.ticket.created`. Stream filter `helpdesk.*.events.>`,
  **disjoint from the ingest filter `helpdesk.*.tickets.>` at token 3**
  (`events` ≠ `tickets`). The customer id is the always-present, token-safe
  tenant token; `platform_org_id` is *not* guaranteed (optional field, only set
  for platform-mapped customers) so it never touches the subject.
- The `event_type` string (`ticket.created`, `visit.scheduled`) already *is*
  `domain.verb`, so it drops straight into the last two subject tokens — no
  separate mapping table.
- Fixed typed envelope, versioned. `platform_org_id` rides the payload *when
  present*, never the subject.
- Per-template config is a single **`publish_nats` bool**. No editable subject
  (a hand-edited subject would break the stream filter, and the customer token
  is dynamic anyway).
- `Nats-Msg-Id` header for defensive dedupe. The consumer is MSP-internal ⇒ the
  envelope can be rich (assignee/technician names, etc.) — no portal-style
  redaction.

## Work items

1. **`internal/subjects`** — add `EventSubject(customerID, eventType)` and
   `EventStreamWildcards()` (`helpdesk.*.events.>`), plus a `VerbEventsToken`
   constant. Tests: `TestEventSubject` and `TestStreamsDisjoint` (token-3
   discriminator differs; an event subject can't be parsed by
   `ParseTicketEvent`, so it can never loop back through ingest).

2. **`internal/notifications`**
   - `context.go`: add `CustomerID` (set unconditionally off the ticket record)
     and `CustomerOrgID` (from the customer lookup) to `TicketContext`.
   - new `envelope.go`: `EventEnvelope` (schema `helpdesk.event`, version 1) +
     `CustomerWire`/`TicketWire`/`ChangeWire`/`CommentWire`/`VisitWire` and a
     `(TicketContext).toEnvelope(eventType, occurredAt)` builder. Decoupled from
     `TicketContext` so refactors can't silently break the wire contract.
   - `notifier.go`: a `Publisher` interface (keeps the package NATS-free and
     testable), `SetPublisher`, a `dispatch` that loads the template row once
     and drives both channels independently, `deliverEmail` (renamed from
     `deliver`), and `publish`. `writeLog` gains a `channel` param.

3. **`internal/natsx`** — a `Publisher` type wrapping `jetstream.JetStream`
   (`PublishMsg` with the `Nats-Msg-Id` header; satisfies
   `notifications.Publisher` structurally), and `EnsureNotifyStream` (its own
   config: `LimitsPolicy`, 7d `MaxAge`, `FileStorage`, 2m `Duplicates` window).

4. **`config/config.go`** — add `NotifyStream string` to `NATSConfig`, default
   `HELPDESK_NOTIFICATIONS`, read from `nats.notify_stream`.

5. **`cmd/helpdesk/main.go`** — after ingest stream/consumer come up, ensure the
   notify stream and `notifier.SetPublisher(natsx.NewPublisher(nc.JS))`. If the
   grant/stream is missing, log once and leave the publisher nil — email keeps
   working (same best-effort posture as ingest).

6. **Migration `1814000000_notifications_nats.go`** — add `publish_nats` (bool)
   to `notification_templates` and `channel` (select email|nats) to
   `notification_send_log`. Guarded/idempotent; runs on existing local DBs and
   fresh installs.

7. **`internal/notifications/routes.go`** — expose `publish_nats` in
   `templateDTO`/`toTemplateDTO` and accept it in `updateTemplate`.

8. **UI** — `NotificationTemplatesView.vue`: an "Also publish to NATS" checkbox
   + read-only derived-subject hint. Rebuild + re-commit `internal/webui/public`.

9. **Docs** — `docs/protocol.md` (outbound events contract), `docs/notifications.md`
   (channel concept), `docs/data-model.md` (new columns), `CLAUDE.md` (outbound
   email + events; owned outbound stream + grammar).

## Build order

subjects → config → natsx → notifications → migration → routes → main → UI → docs.

## Non-goals (v1)

Editable NATS subjects; a NATS-only event set (`visit.completed`, `time.logged`);
consumer-side stream/consumer (owned by the MSP automation); wiring `SendIfFirst`.
