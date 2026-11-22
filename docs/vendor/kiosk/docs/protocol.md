---
path: kiosk/protocol
nav_order: 30
---
# Wire Protocol

This page is the wire contract of the kiosk. It lists every NATS subject that
the kiosk node, the timeclock terminal and the controller publish or subscribe
to, with each payload and reply. It is the spec for an external system that
works with the kiosk, such as an access-control gate, a camera or occupancy
monitor, or a metrics consumer. The code that builds the subjects is
[`internal/events/subjects.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/events/subjects.go), and the command
handlers are in [`internal/commands/`](https://github.com/stone-age-io/kiosk/blob/main/internal/commands). This page is the
readable copy. The HTTP routes are in [API Reference](api.md).

---

## 1. The Whole Surface

Every subject follows the ecosystem's grammar, as ADR 0008 in `platform-docs`
gives it:

```text
{app}.{scope}.{channel}.{rest}
kiosk.{code}.evt.transaction.complete
```

- **`{app}`** is `nats.subject_prefix`. The default is `kiosk`. The kiosk node,
  the timeclock terminal and the controller must use the same value. This page
  writes `kiosk`. Read it as the configured prefix.
- **`{scope}`** is one token: the kiosk code, which is the node's Thing code.
  Every transaction carries it.
- **`{channel}`** is `evt`, `cmd`, `heartbeat` or `sighting`. The channel sets
  the transport. `sighting` is the kiosk's own channel for raw input, which ADR
  0008 allows because no stream captures it.
- **`{rest}`** names the message and ends with the verb.

| Subject | Direction | Transport | Stored | Payload |
| :--- | :--- | :--- | :--- | :--- |
| `kiosk.{code}.evt.transaction.complete` | node → controller | Publish | Yes, `KIOSK_EVENTS` | [§2](#evttransactioncomplete) |
| `kiosk.{code}.evt.item.{action}` | node → controller | Publish | Yes, `KIOSK_EVENTS` | [§2](#evtitemaction) |
| `kiosk.{code}.evt.inventory.adjust` | node → controller | Publish | Yes, `KIOSK_EVENTS` | [§2](#evtinventoryadjust) |
| `kiosk.{code}.evt.integrity.rebuild` | node → controller | Publish | Yes, `KIOSK_EVENTS` | [§2](#evtintegrityrebuild) |
| `kiosk.{code}.evt.checkout.admin_close` | node → controller | Publish | Yes, `KIOSK_EVENTS` | [§2](#evtcheckoutadmin_close) |
| `kiosk.{code}.evt.instance.lifecycle` | node → controller | Publish | Yes, `KIOSK_EVENTS` | [§2](#evtinstancelifecycle) |
| `kiosk.{code}.evt.timeclock.punch` | node, timeclock terminal → controller | Publish | Yes, `KIOSK_EVENTS` | [§2](#evttimeclockpunch) |
| `kiosk.{code}.evt.scan.rfid.observed` | node → stream | Publish | Yes, `KIOSK_EVENTS` | [§2](#evtscanrfidobserved) |
| `kiosk.{code}.evt.receipt.transaction` | node → controller | Publish | Yes, `KIOSK_EVENTS` | [§2](#evtreceipttransaction-managed-mode-only) |
| `kiosk.{code}.evt.alert.lowstock` | node → controller | Publish | Yes, `KIOSK_EVENTS` | [§2](#evtalertlowstock-managed-mode-only) |
| `kiosk.{code}.evt.alert.maintenance` | node → controller | Publish | Yes, `KIOSK_EVENTS` | [§2](#evtalertmaintenance-managed-mode-only) |
| `kiosk.{code}.cmd.inventory.adjust` | controller → node | Request and reply | No | [§3](#inventoryadjust) |
| `kiosk.{code}.cmd.inventory.set_threshold` | controller → node | Request and reply | No | [§3](#inventoryset_threshold) |
| `kiosk.{code}.cmd.inventory.snapshot` | controller → node | Request and reply | No | [§3](#inventorysnapshot) |
| `kiosk.{code}.cmd.checkout.close` | controller → node | Request and reply | No | [§3](#checkoutclose) |
| `kiosk.{code}.cmd.checkout.snapshot` | controller → node | Request and reply | No | [§3](#checkoutsnapshot) |
| `kiosk.{code}.cmd.instance.create` | controller → node | Request and reply | No | [§3](#instancecreate) |
| `kiosk.{code}.cmd.instance.edit` | controller → node | Request and reply | No | [§3](#instanceedit) |
| `kiosk.{code}.cmd.instance.set_status` | controller → node | Request and reply | No | [§3](#instanceset_status) |
| `kiosk.{code}.cmd.instance.snapshot` | controller → node | Request and reply | No | [§3](#instancesnapshot) |
| `kiosk.{code}.cmd.integrity.rebuild` | controller → node | Request and reply | No | [§3](#integrityrebuild) |
| `kiosk.{code}.cmd.ledger.republish` | controller → node | Request and reply | No | [§3](#ledgerrepublish) |
| `kiosk.{code}.cmd.timeclock.punch` | controller → node | Request and reply | No | [§3](#timeclockpunch) |
| `kiosk.{code}.cmd.timeclock.republish` | controller → node | Request and reply | No | [§3](#timeclockrepublish) |
| `kiosk.{code}.cmd.metrics.snapshot` | controller → node | Request and reply | No | [§3](#metricssnapshot) |
| `kiosk.{code}.cmd.config.snapshot` | controller → node | Request and reply | No | [§3](#configsnapshot) |
| `kiosk.{code}.cmd.cart.start` | external system → node | Request and reply | No | [§3](#cartstart) |
| `kiosk.{code}.cmd.read.trigger` | external system → node | Request and reply | No | [§3](#readtrigger) |
| `kiosk.{code}.heartbeat` | node, timeclock terminal → controller | Core publish | Never | [§4](#4-heartbeats) |
| `kiosk.{code}.sighting.raw` | gateway or managed node → node, controller | Core publish | No | [§5](#5-sightings) |

All payloads are JSON objects. Every event carries `ts`, an RFC 3339 time in
UTC, and every event publish carries a `Nats-Msg-Id` header
([§8](#8-duplicate-handling)).

::: note The stream captures events only
`KIOSK_EVENTS` binds to `kiosk.*.evt.>` and nothing else. Commands, heartbeats
and sightings are outside its filter because of their channel, not because of
an exclusion list.
:::

---

## 2. Events

All events go to `kiosk.{code}.evt.{rest}`. The node also writes every event to
its log as `slog.Info("kiosk.event", ...)`, whether NATS is on or not.

Every event follows ADR 0008 rule 3:

- **`ts`** is an RFC 3339 UTC time for when the thing happened. Each payload
  sets it from its own time, such as a transaction's `completed_at` or a
  punch's business time. A republished event therefore keeps its original
  `ts`. Domain fields such as `completed_at` stay beside it. If a payload has
  no `ts`, the publisher adds the publish time.
- **`Nats-Msg-Id`** is set on every publish. The id rules are in
  [§8](#8-duplicate-handling).

### `evt.transaction.complete`

The node publishes this event once for each cart commit, after the database
transaction.

```json
{
  "transaction_id": "...",
  "kiosk_code": "...",
  "location_code": "...",
  "user_id": "...",
  "user_code": "...",
  "user_group": "optional",
  "user_name": "optional",
  "started_at": "RFC3339",
  "completed_at": "RFC3339",
  "ts": "RFC3339 UTC, same instant as completed_at",
  "lines_count": 3,
  "checked_out": 2,
  "returned": 1,
  "consumed": 0,
  "terminal_id": "optional, only when set",
  "enclosure_id": "optional, enclosure_diff only, only when set"
}
```

### `evt.item.{action}`

The node publishes one event for each `transaction_lines` row of a cart commit.
`{action}` is `checkout`, `return` or `consume`. The payload shape is the same
for each action, and the `action` field tells them apart downstream.

```json
{
  "transaction_id": "...",
  "line_id": "...",
  "kiosk_code": "...",
  "location_code": "...",
  "user_id": "...",
  "user_code": "...",
  "user_group": "...",
  "item_id": "...",
  "item_code": "...",
  "item_name": "...",
  "action": "checkout",
  "qty": 1,
  "serial": "optional, serialized items only",
  "uncorrelated": false,
  "original_checkout_user_code": "optional, cross-user returns only",
  "item_instance_id": "optional",
  "completed_at": "RFC3339",
  "ts": "RFC3339 UTC"
}
```

### `evt.inventory.adjust`

The node publishes this event after every accepted stock adjustment. The source
can be the local HTTP endpoint or the `inventory.adjust` command. A lost or
damaged admin close of a quantity item also publishes it.

```json
{
  "adjustment_id": "...",
  "kiosk_code": "...",
  "location_code": "...",
  "item_id": "...",
  "item_code": "...",
  "item_name": "...",
  "mode": "delta" | "absolute",
  "value": 5,
  "delta": 5,
  "prev_quantity": 7,
  "new_quantity": 12,
  "reason": "free-form",
  "source": "local" | "controller",
  "admin_id": "optional, local source only",
  "controller_admin_id": "optional, controller source only",
  "command_id": "optional",
  "completed_at": "RFC3339",
  "ts": "RFC3339 UTC"
}
```

The controller uses `adjustment_id` as its idempotency anchor when it projects
the event into `inventory_audit`.

### `evt.integrity.rebuild`

The node publishes this event after a successful `open_checkouts` rebuild. The
rebuild can come from a local admin or from the command.

```json
{
  "kiosk_code": "...",
  "location_code": "...",
  "admin_id": "optional, local source only",
  "controller_admin_id": "optional, controller source only",
  "source": "local" | "controller",
  "command_id": "optional",
  "deleted": 4,
  "inserted": 4,
  "completed_at": "RFC3339",
  "ts": "RFC3339 UTC"
}
```

### `evt.checkout.admin_close`

The node publishes this event once for each row that `commit.AdminClose`
closes. It is separate from `evt.item.return`, so a report can tell "the worker
returned it" from "an admin closed it without a return" without a filter on a
field.

```json
{
  "transaction_id": "...",
  "line_id": "...",
  "kiosk_code": "...",
  "location_code": "...",
  "open_checkout_id": "...",
  "item_id": "...",
  "item_code": "...",
  "item_name": "...",
  "user_id": "worker whose row was closed",
  "user_code": "...",
  "user_group": "...",
  "item_instance_id": "optional",
  "serial": "optional",
  "qty": 1,
  "closure_reason": "lost" | "returned_offline" | "damaged" | "other",
  "notes": "optional",
  "source": "local" | "controller",
  "admin_id": "optional, local source only",
  "controller_admin_id": "optional, controller source only",
  "command_id": "optional",
  "completed_at": "RFC3339",
  "ts": "RFC3339 UTC"
}
```

An admin close publishes this subject only. It publishes no
`evt.transaction.complete` and no `evt.item.admin_close`. A `lost` or `damaged`
close also publishes the effect on the count: `evt.inventory.adjust` for a
quantity item, or `evt.instance.lifecycle` for a serialized unit.

### `evt.instance.lifecycle`

The node publishes this event on every `item_instances` status transition:

| `action` | Transition |
| :--- | :--- |
| `create` | a new unit |
| `to_maintenance` | in_service → maintenance |
| `return_to_service` | maintenance → in_service |
| `retire` | in_service or maintenance → retired |
| `unretire` | retired → in_service |

Cosmetic edits (code, serial, rfid_epc, notes) and updates that leave the
status unchanged do **not** publish.

```json
{
  "instance_id": "...",
  "instance_code": "WIDGET-001-A",
  "item_id": "...",
  "item_code": "WIDGET-001",
  "item_name": "Widget",
  "kiosk_code": "...",
  "location_code": "...",
  "action": "to_maintenance",
  "prev_status": "in_service",
  "new_status": "maintenance",
  "reason": "...",
  "source": "local" | "controller",
  "admin_id": "optional",
  "controller_admin_id": "optional",
  "command_id": "optional",
  "source_audit_id": "kiosk-side instance_audit.id",
  "completed_at": "RFC3339",
  "ts": "RFC3339 UTC",
  "rfid_epc": "current tag id, empty for an untagged unit"
}
```

- `prev_status` is empty on `create`.
- `source_audit_id` is the controller's idempotency anchor when it projects the
  event into `instance_lifecycle_audit`.
- `rfid_epc` keeps the controller's `instance_epc_index` current. That index is
  the map from EPC to owning unit that the sighting ingest resolves against
  (location/sightings L3). A cosmetic EPC change alone publishes no event, so
  the index refreshes on the next create or status transition.

### `evt.timeclock.punch`

The node or the timeclock terminal publishes this event once for each accepted
punch, from any source: `self`, `foreman`, `admin` or `controller_admin`. An
idempotent replay of a command punch does **not** publish again.

```json
{
  "punch_id": "kiosk-side time_punches.id (idempotency anchor)",
  "kiosk_code": "...",
  "location_code": "...",
  "user_id": "kiosk-local users.id",
  "user_code": "EMP-2",
  "user_name": "Bob",
  "direction": "in" | "out",
  "ts": "RFC 3339 UTC, the business time (an admin can backdate it)",
  "source": "self" | "foreman" | "admin" | "controller_admin",
  "recorded_by_user_code": "foreman's code (source=foreman)",
  "admin_id": "kiosk admins.id (source=admin)",
  "controller_admin_id": "controller admin id (source=controller_admin)",
  "reason": "...",
  "force": false,
  "command_id": "...",
  "job_code": "optional job or work-order tag, supplied on a clock-in",
  "note": "optional free-text note, either direction",
  "recorded_at": "RFC3339, when the row was written"
}
```

The controller projects the punch into its own `time_punches`, with
`source_punch_id` as the dedupe key. It then writes the worker's clocked-in
state to the `punch_state` bucket. With that bucket a worker can clock in at
one kiosk and clock out at another. The clock-out gate uses a sibling bucket,
`open_checkouts_state`. Both are in [§6](#6-streams-and-kv-buckets).

### `evt.scan.rfid.observed`

The node publishes this event after every completed LLRP inventory cycle, in
either RFID mode. It is low-cost observability. No projector consumes it today.
The stream keeps it for future drift detection and analytics.

```json
{
  "kiosk_code": "...",
  "location_code": "...",
  "cart_id": "...",
  "enclosure_id": "cabinet-a",   // enclosure_diff only
  "mode": "counter_scan" | "enclosure_diff",
  "observed_epcs": ["..."],
  "observed_at": "RFC3339",
  "ts": "RFC3339 UTC, the publish time"
}
```

### `evt.receipt.transaction` (managed mode only)

A managed node publishes this event beside `evt.transaction.complete`. It
carries the receipt context, and the controller's notifier fills in the
template and sends it. See [Notifications](notifications.md).

### `evt.alert.lowstock` (managed mode only)

A managed node publishes this event when an item's count crosses its
`reorder_threshold` downward. It carries the low-stock context for the
controller's notifier. See [Notifications](notifications.md).

### `evt.alert.maintenance` (managed mode only)

A managed node publishes this event when a cart commit sends one or more
returned serialized units to maintenance. The cause can be the SKU's
`requires_maintenance_on_return`, a per-line "needs maintenance" toggle, or
both.

- **One event per transaction.** A cart that returns N flagged units publishes
  one event that lists all N.
- It carries `MaintenanceContext` for the controller's notifier, which sends to
  all admins.
- It uses the same durable consumer as `alert.lowstock`.

```json
{
  "Kiosk": { "Code": "...", "LocationCode": "..." },
  "Units": [
    {
      "ItemCode": "WIDGET-001",
      "ItemName": "Widget",
      "InstanceCode": "WIDGET-001-A",
      "Serial": "SN-12345",
      "Reason": "free-form"
    }
  ],
  "Trigger": "return",
  "Ref": "transaction id",
  "ts": "RFC3339 UTC, the publish time"
}
```

The controller dedupes on `Ref` (the transaction id) through `SendIfFirst`. A
JetStream redelivery of the same batch therefore sends one email. A companion
`digest.maintenance` scheduled report ("Items in maintenance") lists the units
that are in maintenance now. See [Notifications](notifications.md).

---

## 3. Commands

A command is a core NATS request to `kiosk.{code}.cmd.{name}`. The node's
dispatcher ([`internal/commands/dispatcher.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/commands/dispatcher.go))
subscribes to `kiosk.{code}.cmd.>` and routes on `{name}`.

- The node subscribes in the queue group `kiosk-{code}`. If two processes run
  with one kiosk code by mistake, only one of them handles each command.
- A message with no reply inbox is logged and ignored. The node changes nothing
  for a caller that does not listen.
- An unknown `{name}` gets a reply with `success: false` and
  `"unknown command: {name}"`.

### Reply envelope

Every command reply has the same JSON shape:

```json
{
  "success": true,
  "error": "",
  "data": { /* command-specific */ }
}
```

- `success` is the only field that is always present.
- `error` is set when `success` is false. It is absent on success.
- `data` carries the result of the command. Each command below gives its shape.

::: warning Reply within 5 seconds
The controller waits **5 s** for a reply. It treats silence as "kiosk offline".
A handler must reply inside this window, also on a validation error.
:::

### `inventory.adjust`

Changes `items.quantity_on_hand` and writes a `stock_adjustments` audit row. The
business logic is the same as the local `POST /api/kiosk/items/{id}/adjust`
endpoint. That includes the rejection of **serialized** items, whose quantity
comes from the count of units that are not retired. A serialized item gets
`success=false`.

**Publisher.** controller

**Payload.**
```json
{
  "command_id": "uuid",
  "controller_admin_id": "admin record id",
  "item_code": "WIDGET-001",
  "mode": "delta" | "absolute",
  "value": 5,
  "reason": "free-form text"
}
```

**Reply data.**
```json
{
  "adjustment_id": "audit row id",
  "item_id": "items record id",
  "item_code": "WIDGET-001",
  "delta": 5,
  "new_quantity": 12,
  "prev_quantity": 7
}
```

**Idempotency.** `command_id` has a unique index on `stock_adjustments`. A retry
returns the earlier result and does not apply the change again.

**Errors.** A missing required field, an item that is not found, an unknown
mode.

### `inventory.set_threshold`

Sets one SKU's `reorder_threshold` at this node. That is the level at or below
which the available stock raises a low-stock alert.

`reorder_threshold` is **kiosk-local** on purpose. It does not travel in the
catalog. A busy main crib and a quiet cross-dock that stock the same SKU need
different levels, and the alert fires against each node's own available count.
So on a managed node this command is the only way to set a threshold. It is
therefore the only way low-stock alerting can fire in a managed fleet.

Unlike `inventory.adjust`, this command **accepts serialized SKUs**. Their
`quantity_on_hand` is derived, so it cannot be adjusted. A threshold is an
alert level against that derived count, so it still has a meaning.

**Publisher.** controller

**Payload.**
```json
{
  "controller_admin_id": "admin record id",
  "item_code": "WIDGET-001",
  "value": 4
}
```

**Reply data.**
```json
{
  "item_id": "items record id",
  "item_code": "WIDGET-001",
  "reorder_threshold": 4,
  "prev_threshold": 0
}
```

**Idempotency.** There is no `command_id`, on purpose. The operation is
absolute ("set it to 4"), so a replay ends at the same value. An idempotency
key would protect nothing. `inventory.adjust` is different: it can carry a
delta, so it must dedupe.

**No audit row and no event.** `stock_adjustments` is a ledger of physical
count changes, and a threshold changes no count. The controller does not
project item state either. Its Inventory panel reads a live
`inventory.snapshot`, which already carries `reorder_threshold`. The new value
shows on the next refresh, with nothing more on the wire.

**Errors.** A missing required field, a negative value, an item that is not
found.

### `inventory.snapshot`

Read-only. Returns the node's current on-hand quantities. The controller SPA
uses it to fill the Inventory tab before and after an adjust.

**Publisher.** controller

**Payload.**
```json
{
  "item_codes": ["A", "B"]   // optional, empty or missing = all active items
}
```

**Reply data.**
```json
{
  "items": [
    {
      "item_code": "WIDGET-001",
      "item_name": "Widget",
      "quantity_on_hand": 12,
      "reorder_threshold": 5,
      "tracking_mode": "quantity" | "serialized" | "consumable",
      "active": true,
      "maintenance": 0,
      "out": 3
    }
  ]
}
```

`maintenance` is the count of the SKU's serialized units in maintenance (0 for
other items). `out` is the count of units checked out now, from the node's
`open_checkouts`. `quantity_on_hand` includes the units in maintenance, so
available = `quantity_on_hand` − `maintenance` − `out`.

**Idempotency.** Read-only, so a replay is safe.

### `checkout.close`

Force-closes one `open_checkouts` row. In one database transaction it writes a
`transactions` row and one `transaction_lines` row (`action="admin_close"`), and
deletes the open row. The business logic is the same as
`POST /api/kiosk/checkouts/by-line/{id}/close`.

**Publisher.** controller

**Payload.**
```json
{
  "command_id": "uuid",
  "controller_admin_id": "admin record id",
  "transaction_line_id": "the original checkout line id",
  "reason": "lost" | "returned_offline" | "damaged" | "other",
  "notes": "optional free-form"
}
```

**Reply data.**
```json
{
  "transaction_id": "new admin_close transaction id",
  "line_id": "new transaction_lines row id",
  "open_checkout_id": "deleted row id",
  "item_id": "...",
  "item_code": "...",
  "user_id": "...",
  "user_code": "...",
  "closure_reason": "lost"
}
```

For a non-serialized row with qty=N, one call closes one row. Call it N times
to close all of them. A serialized line closes exactly once.

**Idempotency.** `command_id` has a unique index on the new `transactions` row.
A retry returns the earlier result.

**Errors.** A missing field, an `open_checkouts` row that is not found.

### `checkout.snapshot`

Read-only. Returns the node's open checkouts from the `open_checkouts` table. It
hydrates them through the same `ledger.Hydrate` path as the local report. So
the DTO shape and the id scheme match the node's own `/reports/open-checkouts`
exactly. The admin-close flow keys on the `transaction_line` id it returns.

The controller's reconciliation gather uses it to prefer a live snapshot from
an online node. For an offline node, the controller replays its projected
ledger instead.

**Publisher.** controller

**Payload.** None.

**Reply data.** `{open_checkouts: [<ledger.OpenCheckoutDTO>]}`. The row shape is
the same as `GET /api/kiosk/reports/open-checkouts`.

**Idempotency.** Read-only.

### `instance.create`

Creates one `item_instances` row and an `instance_audit` row, and publishes an
`instance.lifecycle` event.

**Publisher.** controller

**Payload.**
```json
{
  "command_id": "uuid",
  "controller_admin_id": "admin record id",
  "item_code": "WIDGET-001",
  "code": "WIDGET-001-A",
  "serial": "SN-12345",            // optional
  "rfid_epc": "abc123...",         // optional
  "notes": "optional",
  "enclosure_id": "cabinet-a"      // optional
}
```

**Reply data.** The instance result:

```json
{
  "instance_id": "...",
  "instance_code": "WIDGET-001-A",
  "item_id": "...",
  "item_code": "WIDGET-001",
  "status": "in_service",
  "enclosure_id": ""
}
```

**Idempotency.** `command_id` has a unique index on `instance_audit`.

### `instance.edit`

Updates cosmetic fields only: code, serial, rfid_epc, notes and enclosure_id.
It writes no audit row and publishes no `instance.lifecycle` event, because
these fields do not change inventory. A retry writes the same values again.

The node stores `rfid_epc` as trimmed lower-case hex, whatever case the caller
sends. A model hook on `item_instances` does this, so it matches the reader's
lower-case observations.

**Publisher.** controller

**Payload.**
```json
{
  "instance_code": "WIDGET-001-A",
  "code": "new code",        // any subset, null or missing = no change
  "serial": "new serial",
  "rfid_epc": "new EPC",
  "notes": "new notes",
  "enclosure_id": "cabinet-b"
}
```

At least one field besides `instance_code` is required.

**Reply data.** The instance result, in the same shape as `instance.create`.

**Idempotency.** Safe to replay, because a replay writes the same content.
There is no `command_id`, because there is no audit row to anchor it.

### `instance.set_status`

Sets `item_instances.status` to a target state. It writes an audit row and
publishes an `instance.lifecycle` event. One command covers every lifecycle
transition, because the target status is data, not a separate verb:

- send a unit to maintenance,
- return it to service,
- retire it,
- un-retire it.

**Publisher.** controller

**Payload.**
```json
{
  "command_id": "uuid",
  "controller_admin_id": "admin record id",
  "instance_code": "WIDGET-001-A",
  "status": "in_service" | "maintenance" | "retired",
  "reason": "free-form, required"
}
```

**Reply data.** The instance result, in the same shape as `instance.create`,
with the new `status`.

**Idempotency.** `command_id` has a unique index on `instance_audit`.

The node derives the audit `action` from the transition. The caller does not
send it:

| prev → target | action |
| :--- | :--- |
| in_service → maintenance | `to_maintenance` |
| maintenance → in_service | `return_to_service` |
| in_service or maintenance → retired | `retire` |
| retired → in_service | `unretire` |

### `instance.snapshot`

Read-only. Lists instances, with an optional filter on `item_code`.

**Publisher.** controller

**Payload.**
```json
{
  "item_code": "WIDGET-001"   // optional, empty = all instances
}
```

**Reply data.**
```json
{
  "instances": [
    {
      "instance_id": "...",
      "instance_code": "WIDGET-001-A",
      "item_id": "...",
      "item_code": "WIDGET-001",
      "item_name": "Widget",
      "serial": "SN-12345",
      "rfid_epc": "...",
      "status": "in_service" | "maintenance" | "retired",
      "notes": "",
      "enclosure_id": "",
      "created": "RFC3339",
      "updated": "RFC3339",
      "last_observed_at": "RFC3339 or empty",
      "last_observed_zone": "",
      "last_observed_gateway": "",
      "last_observed_lat": 0,
      "last_observed_lon": 0,
      "out": false
    }
  ]
}
```

The `last_observed_*` fields are the advisory location columns. They stay empty
until something observes the unit. In managed mode the L3 mirror watcher keeps
them current. The command handler derives `out` from `open_checkouts`, so the
controller does not replay its ledger to find what is out.

**Idempotency.** Read-only.

### `integrity.rebuild`

Clears `open_checkouts` and rebuilds it from the node's own ledger. After
success it publishes `evt.integrity.rebuild`.

**Publisher.** controller

**Payload.** All fields are optional. An empty body is valid.
```json
{
  "command_id": "uuid",
  "controller_admin_id": "admin record id"
}
```

**Reply data.** Rebuild counts, `{deleted, inserted}`.

**Idempotency.** A replay gives the same state, because the rebuild follows
from the ledger.

### `ledger.republish`

Publishes the events again for every completed transaction in the optional
window. The controller uses it to fill its projection after a NATS outage.

- An ordinary transaction gets `evt.transaction.complete` and one
  `evt.item.{action}` per line.
- An admin-close transaction gets one `evt.checkout.admin_close`, the same
  shape as the live close.

**Publisher.** controller

**Payload.** All fields are optional.
```json
{
  "command_id": "uuid",
  "controller_admin_id": "admin record id",
  "from": "RFC3339 timestamp",
  "to": "RFC3339 timestamp"
}
```

**Reply data.** `{transactions_published, lines_published, skipped,
admin_closes_published?, from?, to?}`. The fields marked `?` are left out when
they are zero or empty.

**Idempotency.** The controller's aggregator dedupes on
`source_kiosk_code + source_transaction_id` (transactions), on
`source_line_id` (lines) and on the admin-close line id. Repeated publishes are
therefore safe.

### `timeclock.punch`

Records a clock-in or clock-out punch **at** the node for a controller admin.
The node is the only punch writer. The controller's ledger learns about the
punch from the resulting `evt.timeclock.punch`, as for every other punch.

- Backdating (`occurred_at`) and `force` (bypass the open-checkouts block on
  clock-out) follow the node's admin punch rules.
- `reason` is always required.
- The node replies with an error when timeclock is not enabled on it.

**Publisher.** controller

**Payload.**
```json
{
  "command_id": "uuid",
  "controller_admin_id": "admin record id",
  "user_code": "EMP-2",
  "direction": "in" | "out",
  "reason": "forgot to clock out",
  "occurred_at": "RFC3339 (optional, empty = now)",
  "force": false,
  "job_code": "optional job or work-order tag",
  "note": "optional free-text note"
}
```

**Reply data.** The punch result: `{punch_id, user_id, user_code, user_name,
direction, occurred_at, recorded_at, source, clocked_in, replayed?}`.
`clocked_in` is the worker's merged state **after** the punch. A backdated
correction can leave it unchanged.

**Idempotency.** `command_id` is unique when it is not empty on
`time_punches`. A replayed command returns the earlier result with
`replayed: true`, and publishes no second event.

### `timeclock.republish`

Publishes `evt.timeclock.punch` again for every punch in the optional window.
It is the sibling of `ledger.republish` for the punch ledger.

**Publisher.** controller

**Payload.** All fields are optional.
```json
{
  "from": "RFC3339 timestamp",
  "to": "RFC3339 timestamp"
}
```

**Reply data.** `{published, from?, to?}`.

**Idempotency.** The controller's projection dedupes on `source_punch_id`. Its
`punch_state` write moves only forward on `occurred_at`. Repeated publishes are
therefore safe, and an old punch cannot move fleet state backwards.

### `metrics.snapshot`

Read-only. Returns the node's point-in-time operational and activity snapshot.
The controller's `GET /api/controller/kiosks/{code}/metrics` forwards it. The
shape is the same as the local `GET /api/kiosk/metrics` endpoint, because both
come from `internal/metrics`.

**Publisher.** controller

**Payload.** None.

**Reply data.**
```json
{
  "kiosk_code": "...",
  "generated_at": "RFC3339, UTC",
  "operational": {
    "uptime_seconds": 0,
    "nats_connected": true,
    "rfid_enabled": false,
    "rfid_mode": "counter_scan",
    "rfid_connected": false,
    "active_carts": 0
  },
  "ledger": {
    "items_out": 0,
    "users_with_items_out": 0,
    "low_stock_skus": 0,
    "transactions_today": 0,
    "transactions_week": 0
  }
}
```

**Idempotency.** Read-only, so a replay is safe.

### `config.snapshot`

Read-only. Returns the node's RFID reader and enclosure layout, with the live
connection status of each reader. It drives the controller's per-node Readers
tab, through `GET /api/controller/kiosks/{code}/config`. You edit the config in
the node's local YAML. This command is observability only.

It reaches process state through `Dispatcher.KioskHandlers`. If that is not set
(a test dispatcher, or the window before wiring), it still replies with an
error. It does not hang, so the controller's 5 s request never times out into a
false "offline".

**Publisher.** controller

**Payload.** None.

**Reply data.**
```json
{
  "enabled": true,
  "read_window_ms": 2000,
  "readers": [
    {
      "reader_id": "counter",
      "mode": "counter_scan" | "enclosure_diff",
      "host": "10.0.0.20",
      "port": 5084,
      "enclosure_id": "cabinet-a",   // enclosure_diff only
      "antennas": 2,
      "connected": true
    }
  ]
}
```

**Idempotency.** Read-only.

### `cart.start`

**RFID `enclosure_diff` mode only.** Starts a cart keyed on
`(user_code, enclosure_id)`, or uses the existing one, so the next
`read.trigger` has a cart to write into. An access-control system usually sends
it when a worker badges into the enclosure door.

**Publisher.** external system (access control)

**Payload.**
```json
{
  "user_code": "W-042",
  "enclosure_id": "cabinet-a",
  "command_id": "uuid"   // optional, for tracing on the caller's side
}
```

**Reply data.**
```json
{
  "cart_id": "...",
  "user_code": "W-042",
  "enclosure_id": "cabinet-a",
  "reused": false   // true if an earlier cart matched the (user, enclosure) key
}
```

**Idempotency.** The cart store has a secondary index on
`(user_code, enclosure_id)`. A second request within the cart's idle window
returns the same `cart_id` with `reused: true`. After a commit or an idle
expiry, the next `cart.start` for the same key creates a new cart.

**Errors.** User not found, user inactive, missing fields.

### `read.trigger`

**RFID `enclosure_diff` mode only.** Runs one LLRP inventory cycle, compares the
observed EPCs with the expected-present state, and writes the resulting cart
lines. A camera or occupancy system usually sends it when the worker steps out
of the enclosure.

**Publisher.** external system (camera or occupancy)

**Payload.** One of two shapes:
```json
{ "cart_id": "...", "command_id": "uuid" }
```
or
```json
{ "user_code": "W-042", "enclosure_id": "cabinet-a", "command_id": "uuid" }
```

**Reply data.**
```json
{
  "cart": { /* full cart object */ },
  "added_lines": [ /* cart.Line[] */ ],
  "observed_epcs": ["..."],
  "unresolved_epcs": ["..."],
  "skipped_cross_user_count": 0,
  "skipped_maintenance_count": 0
}
```

**Idempotency.** A second request gives the same diff against the same expected
state. Lines that an earlier trigger already put in the cart change nothing,
because the cart store rejects a duplicate instance write. The manual
"Re-read enclosure" button in the SPA runs the same logic over HTTP, with the
same result.

**Errors.**

- No active cart for the key. The node **rejects** a read with no cart on
  purpose: a loud failure shows an access-control event that is wired wrong.
- The reader is not reachable.
- A field is missing.
- The read passed its deadline, from a slow or half-open reader.

**Deadline.** The handler limits the LLRP read to 4.5 s
(`commands.ReadTriggerBudget`), which is below the 5 s reply window. A stuck
reader therefore cannot hold the reader's lock past the window. After the
deadline the read stops and the node replies with an error, so the caller does
not time out. For the same reason, config rejects `rfid.read_window > 3.5 s` in
`enclosure_diff` mode: the read runs inside this reply window.

---

## 4. Heartbeats

```text
kiosk.{code}.heartbeat
```

A kiosk node and a timeclock terminal publish a heartbeat with a core publish,
not to a stream. The controller's `HeartbeatRegistry` keeps the most recent
beat of each node in memory, and serves it at
`GET /api/controller/kiosks/heartbeats`. Nothing stores a heartbeat, by design.
A stored beat would hide the signal that matters: a missed beat.

**Cadence.** 45 s.

**Payload.**
```json
{
  "code": "...",
  "location": "...",
  "ts": "RFC3339"
}
```

The field names match the access-control application's heartbeat shape
(`{code, location, ts}`), so fleet tooling can read both. The controller still
accepts the old `kiosk_code` and `location_code` names from older node builds.

The first beat from an unknown node also registers a `kiosks` row on the
controller. This runs in parallel with the aggregator's `touchKiosk` path.

---

## 5. Sightings

```text
kiosk.{code}.sighting.raw
```

A sighting is a core publish, not stored. The `sighting` channel carries lossy
data for advisory asset location (see
[location-sightings](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md)).

- **Publishers.** A gateway is usually an external publisher, off the platform:
  RFID over MQTT straight into the MQTT interface of NATS, or an HTTP to NATS
  bridge. In managed mode a node also publishes its custody reads on its own
  subject.
- **The payload is always raw.** It carries `tag_id`, never a resolved instance
  code. The subscriber resolves it.
- **Subscribers.** A standalone node subscribes to its own subject and resolves
  the tag through the scan resolver. The controller subscribes fleet-wide
  (`kiosk.*.sighting.raw`) and resolves the tag through an EPC index.
- **Lossy.** The next read replaces a dropped sighting. A sighting is never
  authoritative and never gates custody.

**Payload.**
```json
{
  "tag_id": "e2801168200082c0a3b400a1",
  "gateway_id": "yard-gw-1",
  "zone": "Yard",
  "lat": 47.6062,
  "lon": -122.3321,
  "observed_at": "RFC3339",
  "rssi": -52
}
```

`zone`, `lat`, `lon` and `rssi` are optional. A roaming gateway sends GPS and
no zone. A static gateway sends a zone and no GPS. If `observed_at` is missing,
the subscriber uses the time of ingest.

---

## 6. Streams and KV Buckets

### Stream

The controller creates the stream at start with CreateOrUpdate. A node publishes
to subjects and never names the stream.

| Property | Value |
| :--- | :--- |
| Name | `KIOSK_EVENTS` (`nats.stream_name`) |
| Subjects | `kiosk.*.evt.>` |
| Retention | Limits, 7 days |
| Storage | File, 1 replica |
| Duplicate window | Not set, so the server default applies |

The controller reads the stream with one durable consumer:

| Property | Value |
| :--- | :--- |
| Durable | `controller-aggregator` |
| Deliver policy | All |
| Ack | Explicit, `AckWait` 120 s, `MaxAckPending` 256 |
| Filters | `transaction.complete`, `item.*`, `inventory.adjust`, `integrity.rebuild`, `checkout.admin_close`, `instance.lifecycle`, `receipt.transaction`, `alert.lowstock`, `alert.maintenance`, `timeclock.punch`, each under `kiosk.*.evt.` |

`evt.scan.rfid.observed` is in the stream, but no consumer filter selects it.

### KV buckets

The controller creates each bucket with CreateOrUpdate and `History: 1`, and is
the only writer. Each key holds the latest value.

| Bucket | Key | Value | Watched by |
| :--- | :--- | :--- | :--- |
| `catalog_items` (`controller.catalog_items_bucket`) | `{code}.{item_code}` | `{code, name, type, unit?, tracking_mode, category?, active, notes?, requires_maintenance_on_return}` | Managed nodes and timeclock terminals, each on its own slice (`{code}.>`) |
| `catalog_users` (`controller.catalog_users_bucket`) | `{user_code}` | `{code, name, email?, phone?, role, group_code?, active}` | Managed nodes and timeclock terminals |
| `catalog_groups` (`controller.catalog_groups_bucket`) | `{group_code}` | `{code, name, contact_email?, contact_phone?, notes?, active}` | Managed nodes and timeclock terminals |
| `punch_state` | `{user_code}` | `{user_code, clocked_in, occurred_at, source_punch_id}` | Managed nodes and timeclock terminals |
| `open_checkouts_state` | `{user_code}` | `{user_code, rows: [{item_code, item_name, serial?, kiosk_code}]}` | Managed nodes and timeclock terminals |
| `last_observed_state` | `{code}.{instance_id}` | `{zone?, gateway?, lat?, lon?, observed_at}` | Managed nodes, each on its own slice (`{code}.>`) |

- **`punch_state`.** The controller writes it after it projects each
  `evt.timeclock.punch`, and moves it only forward on `occurred_at`. A managed
  node watches it into an in-memory replica. Every clocked-in decision uses the
  fresher of the local ledger and the replica. That is what lets a worker clock
  in at one kiosk and out at another.
- **`open_checkouts_state`** is the **clock-out gate**. After each checkout,
  return or admin-close line, the controller recomputes the worker's fleet-wide
  open checkouts and writes them here. A managed node and a managed timeclock
  terminal watch it into a `CheckoutFleet`. The punch path merges it with the node's
  local `open_checkouts` (split by `kiosk_code`), and blocks a clock-out while
  tools are out anywhere.
    - It fails open when the replica is absent.
    - A worker can bypass it with "clock out anyway" (`acknowledge:true`, which
      becomes `force` on the punch).
- **The catalog buckets** are described in [Controller](controller.md).

---

## 7. Service Discovery

Each binary registers as a NATS micro service, so `nats micro ls` (or any
`$SRV` client) lists every running process with its version.

| Service | Binary | Metadata |
| :--- | :--- | :--- |
| `kiosk` | `kiosk-app` | `code`, `host` |
| `kiosk-timeclock` | `kiosk-timeclock` | `code`, `host` |
| `kiosk-controller` | `kiosk-controller` | `code`, `host` |

- **`code`** is the process's Thing code (ADR 0008 rule 4). It is `nats.code`,
  or `kiosk.code` on a node or timeclock terminal when `nats.code` is empty.
  The controller has no kiosk code, so set `nats.code` there. With no code, the
  controller skips the registration.
- **`host`** is the hostname. It is left out if the hostname cannot be read.
- **Identity only.** The services have no endpoints. Nothing can be read or
  controlled through them.
- **Never fatal.** With NATS off, with no code, or on any failure, the process
  logs a warning and runs on.

---

## 8. Duplicate Handling

**Events.** The node sets `Nats-Msg-Id` on every event publish. For an event
with a record id the value is stable, `{kind}:{id}`, where `{kind}` is the
subject after `evt.`:

| Event | `Nats-Msg-Id` |
| :--- | :--- |
| `transaction.complete` | `transaction.complete:{transaction_id}` |
| `item.{action}` | `item.{action}:{line_id}` |
| `checkout.admin_close` | `checkout.admin_close:{line_id}` |
| `inventory.adjust` | `inventory.adjust:{adjustment_id}` |
| `timeclock.punch` | `timeclock.punch:{punch_id}` |
| `instance.lifecycle` | `instance.lifecycle:{source_audit_id}` |

A `ledger.republish` or `timeclock.republish` inside the stream's duplicate
window is therefore stored once. Alerts, receipts, RFID reads and rebuilds get
a new unique id on each publish.

**Projections.** The duplicate window is finite, so the controller also dedupes
when it writes. Each projection looks up a key the node set before it inserts:

| Event | Controller dedupe key |
| :--- | :--- |
| `transaction.complete` | `source_kiosk_code` + `source_transaction_id` |
| `item.{action}` | `source_line_id` |
| `checkout.admin_close` | the admin-close line id |
| `inventory.adjust` | `adjustment_id` (into `inventory_audit`) |
| `instance.lifecycle` | `source_audit_id` (into `instance_lifecycle_audit`) |
| `timeclock.punch` | `source_punch_id` |
| `alert.maintenance` | `Ref`, through `SendIfFirst` |

**Commands.** A mutating command carries `command_id`, with a unique index on
the row it writes. A retry returns the earlier result. An absolute or
read-only command needs no key. Each command in [§3](#3-commands) states its
rule.

**Heartbeats and sightings** carry no id. Nothing stores them, so a duplicate
changes nothing.

---

## 9. Inspecting Traffic

Watch every event:
```bash
nats sub "kiosk.*.evt.>"
```

Watch one node:
```bash
nats sub "kiosk.KC-MAIN-01.>"
```

Watch the commands to one node, which shows retries and external publishers:
```bash
nats sub "kiosk.KC-MAIN-01.cmd.>"
```

Watch heartbeats:
```bash
nats sub "kiosk.*.heartbeat"
```

---

## 10. Where to Go Next

- The HTTP routes, and which binary serves each one: [API Reference](api.md)
- The controller, its catalog and its NATS provisioning: [Controller](controller.md)
- Which events notify whom: [Notifications](notifications.md)
- RFID modes and readers: [RFID](rfid.md)
- Config keys such as `nats.subject_prefix` and `nats.stream_name`: [Configuration](configuration.md)
- The rules every application on the platform follows: Building an Application in `platform-docs`
