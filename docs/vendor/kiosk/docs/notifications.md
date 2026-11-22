---
path: kiosk/notifications
nav_order: 90
---
# Notifications

This page covers the email notifications. It lists the event types and says
where templates and SMTP live. It shows how a managed kiosk node hands its
notifications to the controller, and how the scheduled digests compute. For
the config that selects managed
mode, see [Configuration Reference](configuration.md). For the subjects, see
[Wire Protocol](protocol.md).

---

## 1. Event Types

The **Notifications** tab of the admin SPA manages nine event types:

| Event type | Kind | What it sends |
| :--- | :--- | :--- |
| `receipt.transaction` | on commit | A transaction receipt. |
| `alert.lowstock` | on commit | A low-stock alert. |
| `alert.maintenance` | on commit | A maintenance alert: a serialized unit went into maintenance on return. |
| `digest.open_checkouts` | scheduled | The open checkouts. |
| `digest.daily_activity` | scheduled | The daily activity. |
| `digest.maintenance` | scheduled | "Items in maintenance": serialized units now parked in maintenance. |
| `digest.reconciliation` | scheduled | The custody-vs-location discrepancies. |
| `digest.timeclock` | scheduled | "Timeclock digest": the hours of every worker, in one admin email. |
| `digest.timeclock_self` | scheduled | "Timeclock summary (per worker)": each active worker's own timesheet, emailed to that worker. |

Each event type has:

- An editable subject and body, in Go `text/template` syntax.
- An editable recipients spec: `worker_email`, `all_admins` and `extras: []`.

The send log records one row per recipient, with `status` set to `sent`,
`failed` or `skipped`.

---

## 2. Standalone and Managed Kiosk Nodes

Where you write templates, where SMTP credentials live and where the audit
trail lands depend on whether the kiosk node is managed:

| | Standalone kiosk node | Managed kiosk node |
| :--- | :--- | :--- |
| Template authoring | `/admin/notifications` on this kiosk node | `/admin/notifications` on the **controller** |
| SMTP credentials | This node's PocketBase superuser UI (`/_/` → Settings → Mail) | The controller's PocketBase superuser UI |
| Send log | This node's `notification_send_log` | The controller's `notification_send_log` |
| Schedule rows | On the kiosk node | On the **controller**, with an optional per-kiosk scope |
| Cron timing and digest computation | Kiosk node | **Controller** |
| Render and SMTP dispatch | Kiosk node | Controller |

`recipients.all_admins` resolves against the `admins` collection of the app
that runs the notifier. On the controller that means controller admins. On a
standalone kiosk node it means that node's admins. Worker recipients work when
`users.email` has a value.

---

## 3. Commit Notifications in Managed Mode

A managed kiosk node still has its local `notification_templates` rows, because
the same migrations seed them. They are dormant. The commit hook publishes a
structured context over NATS instead of calling the local notifier. The
controller's aggregator subscribes to three subjects. Here `kiosk` is the
configurable `nats.subject_prefix`.

| Subject | Payload | Duplicate rule |
| :--- | :--- | :--- |
| `kiosk.{code}.evt.receipt.transaction` | `ReceiptContext`: kiosk, user, transaction, lines | The controller removes duplicates on `transaction_id` through `notification_dedupe`. A JetStream redelivery never sends twice. |
| `kiosk.{code}.evt.alert.lowstock` | `LowStockContext` | Scoped to the day, on purpose. It means "tell me once per item per day", not only a redelivery guard. |
| `kiosk.{code}.evt.alert.maintenance` | `MaintenanceContext` | One email per transaction. The controller removes duplicates on the transaction id (`Ref`), so a redelivery gives one send. |

The maintenance alert is batched. A cart that returns N serialized units
flagged for maintenance gives one email that lists all N. It goes to all
admins.

---

## 4. Scheduled Digests

The scheduled digests do not use NATS. In managed mode the controller owns all
of the work:

- The `scheduled_reports` rows.
- The cron.
- The digest computation.
- The SMTP send.

When `controller.enabled` is `true`, the kiosk node skips its scheduler. The
SPA on the kiosk node shows a banner that sends operators to the controller. A
standalone kiosk node keeps its local scheduler and local SMTP.

Each schedule row has an optional `kiosk_code` column. Empty means fleet-wide:
one digest that covers every kiosk node. A value scopes the digest to one
kiosk node. On the controller, the dialog shows a "Scope" dropdown filled from
the `kiosks` collection. On a standalone kiosk node, the field stays empty and
out of the UI.

### Where each digest gets its data

| Digest | Standalone kiosk node | Controller |
| :--- | :--- | :--- |
| `open_checkouts` | A replay of the local ledger (`ledger.ReplayOpenRows`) | Live first, with a last-known fallback. See below. |
| `daily_activity` | The local transactions | The projected ledger |
| `maintenance` | Local `item_instances` with `status=maintenance` | Live first, with a last-known fallback. See below. |
| `reconciliation` | The node's own `item_instances.last_observed_*` columns | The fleet `instance_location` projection |
| `timeclock`, `timeclock_self` | The local punch ledger | The projected punch ledger |

The controller does not keep an `open_checkouts` table. The `open_checkouts`
and `maintenance` digests on the controller ask the kiosk nodes first:

- **An online kiosk node answers live.** For `open_checkouts`, it answers the
  `checkout.snapshot` command from its own `open_checkouts`. For
  `maintenance`, it answers `instance.snapshot`, filtered to
  `status=maintenance`.
- **An offline kiosk node gets its last-known state.** For `open_checkouts`,
  the controller replays the node's `transaction_lines` in its projected ledger
  (`ledger.ReplayOpenRows`). This is the path the integrity check of the kiosk
  node uses. For `maintenance`, the controller rebuilds each unit's status from
  its projected `instance_lifecycle_audit`. Those rows have no serial.
- **A node that should be online but does not answer** is listed as
  unavailable. The controller does not replay it.

The digest names each node as live, last-known or unavailable, so the operator
knows when the result is partial.

The `reconciliation` digest (`ReconciliationDigestContext`) emails the
`not_taken`, `stale` and `unaccounted` rows of the reconciliation report. It
reads only the database, on both binaries. See
[Location & Sightings](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md).

### Timeclock digests

The two timeclock digests pair raw punches into display totals. The raw-punch
CSV stays the payroll contract.

- **`digest.timeclock`** ("Timeclock digest", `TimeclockDigestContext`) is one
  admin email. It lists the day totals of every worker for the window.
- **`digest.timeclock_self`** ("Timeclock summary (per worker)",
  `TimeclockSelfDigestContext`) is a **fan-out**. One schedule row expands into
  one private email for each active worker with punches in the window. Each
  email covers only that worker and goes only to that worker.

The fan-out is the scheduler's one-row-to-many delivery shape
(`fanOutRunners`). The default shape is one-row-to-one (`reportRunners`). For
a fan-out row:

- The runner makes its own send to each recipient.
- The scheduler ignores the row's recipients column, and the SPA hides the
  recipients editor.
- A bounce for one worker is logged, and the rest of the schedule still runs.

Both timeclock digests read only the database, on either binary. They need no
live snapshot, because the timeclock ledger is fully projected. A fleet-wide
row on the controller gives each worker their complete hours across every
kiosk node.

---

## 5. Operator Visibility

Two SPA surfaces show the send log:

- **Notifications → Recent sends** (`/admin/notifications/log`). Every
  attempted recipient in time order, filtered by event type and status. Open a
  row to read it in detail.
- **Reports → Notifications.** A tally over a window you choose: 24h, 7d, 30d
  or 90d. A "Recent failures" panel shows the last 10 failed sends with their
  error strings. The success rate of each event type has a color, so a drop is
  easy to see.

Both work on a standalone kiosk node against its local `notification_send_log`.
On the controller they use the fleet-wide log.

---

## 6. Where to Go Next

- Managed mode and the `controller.*` keys: [Configuration Reference](configuration.md)
- Subjects and payloads: [Wire Protocol](protocol.md)
- The central controller and its reports: [Central Controller](controller.md)
- Punch-ledger setup and the timeclock terminal: [Operations](operations.md#9-timeclock-terminal)
