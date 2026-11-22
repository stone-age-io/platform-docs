---
path: kiosk/ledger
nav_order: 60
---
# Ledger

This page describes how a kiosk node records state changes and why we model
them as a ledger, not as direct changes to inventory rows. It also shows how
the same model extends to the controller's fleet view. Read
[Schema](schema.md) first. The controller itself is in
[Central Controller](controller.md), and the architecture overview is in
[CLAUDE.md](https://github.com/stone-age-io/kiosk/blob/main/CLAUDE.md).

---

## 1. What the Ledger Is

The ledger is two collections and one derived view:

| Collection | Role |
| :--- | :--- |
| `transactions` | One row per committed cart. Header facts: who, where, when, status. Append-only after commit. |
| `transaction_lines` | One row per item action in a transaction. The action is `checkout`, `return`, `consume` or `admin_close`. It carries `item_instance` for serialized lines, and `original_checkout_user` for cross-user returns and every admin close. Append-only after commit. |
| `open_checkouts` | "What is out now." One row per unit that is checked out. The commit path keeps it current. You can rebuild it from the two collections above. |

The first two are the ledger proper: a sequence of facts that never changes.
The third is a cache of the current state, derived from those facts. The
kiosk node stores it so its UI can answer "what is out?" with one SELECT. It
does not replay history on each page load.

Two other collections in the same database are supporting audit logs. They
follow the same append-only rule:

- `stock_adjustments` records every admin adjustment to the
  `quantity_on_hand` of a quantity-tracked item.
- `instance_audit` records every lifecycle change on a serialized unit. That
  change also moves the derived `quantity_on_hand` of a serialized SKU.

These logs are not part of the checkout state machine. They share its design
property: every change leaves a permanent row.

`time_punches` is a **second append-only ledger** with the same rules:

- It holds one row per clock-in or clock-out punch.
- Only the funnel `timeclock.PerformPunch` writes it.
- Nothing edits or deletes a punch. A correction is a new punch with a reason.

`open_checkouts` derives "what is out". In the same way, the clocked-in state
comes from the latest punch per worker. Nothing stores it, and there is no
open-shifts table. The raw-punch CSV export is the payroll contract. No
rounding, overtime or pay-period logic exists anywhere in this codebase, the
same position as for billing.

---

## 2. The Single Write Path

Every change a worker can make goes through one function,
[`commit.Commit`](https://github.com/stone-age-io/kiosk/blob/main/internal/commit/commit.go). That covers checkout,
return, consume and any mix of them in one cart. An admin force-close uses a
sibling entry point, [`commit.AdminClose`](https://github.com/stone-age-io/kiosk/blob/main/internal/commit/admin_close.go),
which writes rows of the same shape.

`commit.Commit` does these steps:

1. It opens one PocketBase database transaction (`app.RunInTransaction`).
2. It writes one `transactions` row.
3. For each cart line, it does three things:
   - It checks that the action is legal for the item type. For example,
     `consume` applies only to consumables, and a serialized item must have
     qty=1 and an instance FK.
   - It writes one `transaction_lines` row.
   - It applies the side effect of the action:
     - `checkout` inserts N rows into `open_checkouts`.
     - `return` deletes up to N rows. If fewer rows match, it marks the line
       `uncorrelated=true`. For a serialized item, `item_instance` identifies
       the row. For a non-serialized item, only rows of the
       `original_checkout_user` are eligible, or of the cart user if that
       field is empty. The resolver never takes rows from another user.
     - `consume` decrements `items.quantity_on_hand`. It writes nothing to
       `open_checkouts`.
4. It commits the database transaction.
5. **After** the commit succeeds, it publishes one `transaction.complete`
   event and one `item.{action}` event per line through `events.Publish`.
   That always writes a slog line, and it publishes to NATS when NATS is
   configured.

### The three invariants

- **`transactions` and `transaction_lines` are append-only.** PocketBase
  collection rules forbid writes through the REST API. The commit path is the
  only writer. By design, the SPA has no control to edit a transaction or to
  delete a line.
- **`open_checkouts` is a function of the ledger.** Each row in
  `open_checkouts` has a `transaction_line` FK behind it. If you delete the
  table and replay the ledger, you get the same content. `commit.Commit` is the
  only writer of the table, and the `open_checkouts` collection rules are
  closed too.
- **Events fire only after the database commit succeeds.** If the database
  transaction rolls back, nothing is published. No event can announce
  something that did not happen.

### Two consequences

A `checkout` of `qty=N` for a non-serialized tool creates **N rows** in
`open_checkouts`, one per physical unit. A serialized checkout creates exactly
one row, keyed by the `item_instance` FK. So a return of "DR-IMPACT-042 unit
A" closes *that exact unit* and leaves units B and C of the same SKU alone.

Consumables and consumable returns never touch `open_checkouts`.
`items.quantity_on_hand` holds the whole state of a consumable. The ledger
holds the audit trail of the decrements.

---

## 3. What the Design Buys and Costs

The ledger is not the only way to track a kiosk node's state. A simpler design
would change `items.quantity_on_hand` directly on each checkout and return, and
keep no audit table per line. The ledger does a little more work at write time.
In return, it gives properties that the simpler design cannot:

- **Reconstruction.** You can rebuild `open_checkouts` from
  `transaction_lines` at any time. The integrity tools
  (`GET /api/kiosk/integrity` and `POST /api/kiosk/integrity/rebuild`) exist
  because we treat the derived view as less trusted than the ledger. A buggy
  hook, a manual database edit or a power loss during a write can all damage
  the view. A replay gives the right answer in each case.
  [`expectedOpenCheckouts`](https://github.com/stone-age-io/kiosk/blob/main/internal/handlers/integrity.go) has the replay
  rules.
- **Audit.** Every action records four facts:
  - Who: the user FK.
  - Where: `kiosk_code` and `location_code`, from the process identity.
  - When: `started_at` and `completed_at`.
  - Why: the action, and a reason for admin closes.

  The API has no delete. A retraction is a new row, not the removal of an old one.
- **No double-spend race.** A checkout or return and its `open_checkouts`
  insert or delete happen in one database transaction. So the ledger and the
  view never disagree about whether a unit is out. A crash between steps
  cannot leave a partial change. SQLite commits all of it or rolls all of it
  back.
- **Ready for a fleet by construction.** Each transaction gets `kiosk_code`
  and `location_code` at write time, from the process identity set at start
  ([`internal/kioskctx`](https://github.com/stone-age-io/kiosk/blob/main/internal/kioskctx)). Clients do not supply these
  fields. Two kiosk nodes at different sites can write transactions for the
  same SKU with no coordination. A consumer downstream tells them apart from
  the rows themselves.
- **Events are a fan-out of ledger writes, not a separate protocol.** The
  `evt.transaction.complete` and `evt.item.{action}` subjects carry the same
  facts as the ledger rows, in the same shape. There is no second commit hook
  to tell the outside world. The publish step reads the records it just wrote.

The design has costs:

- **Two tables to read, not one.** Reports join `transactions` and
  `transaction_lines`, and often `open_checkouts`. They do not read one row.
  List views paginate first to keep this small. The commit stores
  `transactions.lines_count`, so a list page needs no `COUNT(*)` per row.
- **Storage only grows.** A kiosk node with 200 transactions a day at 3 lines
  each adds about 220k rows per year to the lines table. That is well inside
  what SQLite handles, and it is not a near-term concern. A 10-year-old kiosk
  node will still have a large database file. There is no retention policy in
  v1. We keep the whole ledger on purpose.
- **Hot-path validation is in the commit code, not in the schema.** Rules such
  as "a serialized line must carry an instance" or "consume applies only to
  consumables" live in Go, not in collection rules. The same code path runs
  interactive commits and ledger replays, and a replay does not validate
  again.

---

## 4. `open_checkouts` as a Derived View

`open_checkouts` is where the rule "the ledger is the source of truth" becomes
something you can check.

### Replay rules

These come from
[`expectedOpenCheckouts`](https://github.com/stone-age-io/kiosk/blob/main/internal/handlers/integrity.go):

- For each completed transaction, walk its lines in order.
- `checkout`: add `qty` to the bucket keyed by `(item, item_instance, user)`.
- `return`: subtract `qty` from the bucket keyed by
  `(item, item_instance, original_checkout_user OR transaction.user)`.
- `admin_close`: subtract, the same as `return`. The line always carries
  `original_checkout_user`, the holder whose row the admin closed.
- `consume`: skip it. Consumables do not open rows.

Both the integrity *check*
([`expectedOpenCheckouts`](https://github.com/stone-age-io/kiosk/blob/main/internal/handlers/integrity.go)) and the
*rebuild* ([`ledger.ReplayOpenRows`](https://github.com/stone-age-io/kiosk/blob/main/internal/ledger/replay.go)) subtract
on `admin_close`. So an admin force-close shows no false drift, and the
rebuild does not restore the closed row.

Returns and admin closes reduce the holder's rows **only**. When a return
subtracts more than the holder has, the replay takes nothing from another
user. The other users' rows stay, and the line is stamped `uncorrelated`. The
replay matches `commit.candidateOpenRows` exactly on this point.

### The integrity check

The check compares the replay with the current `open_checkouts` table:

- `missing_in_table`: the replay expects a row and the table has none. Cause:
  a hook bug or an interrupted write.
- `extra_in_table`: the table has a row the replay does not expect. Cause: a
  manual database edit or a stale row.

A healthy result has both arrays empty and `expected_open == actual_open`.

### Rebuild

`POST /api/kiosk/integrity/rebuild` deletes the table and inserts it again
from the replay, inside one database transaction. Each rebuilt row gets the
source line's `completed_at` as `checked_out_at`, and an FK to the
`transaction_line` it came from. So aging and audit reports stay correct
after a rebuild.

---

## 5. Events: Ledger Writes, Broadcast

Every ledger write produces events on NATS. Subjects follow
`{prefix}.{kiosk_code}.{channel}.{rest}`, where `{prefix}` is
`nats.subject_prefix` and defaults to `kiosk`. The ledger publishes on the
`evt` channel:

- `kiosk.{code}.evt.transaction.complete`: one per commit.
- `kiosk.{code}.evt.item.{action}`: one per line. `{action}` is `checkout`,
  `return`, `consume` or `admin_close`.

Two more event subjects travel beside them but start outside the commit path:

- `kiosk.{code}.evt.inventory.adjust` comes from admin stock adjustments
  ([`stock_adjust.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/handlers/stock_adjust.go)). It is also the
  quantity side effect of a `lost` or `damaged` admin close of a
  **quantity-tracked** item. A serialized close does not emit it. The unit's
  removal travels on `evt.instance.lifecycle`, and the derived quantity
  follows the count of active instances.
- `kiosk.{code}.evt.instance.lifecycle` comes from the `item_instances`
  PocketBase record hooks, and from `commit.AdminClose` when it retires a
  serialized unit.

The controller's JetStream stream binds `kiosk.*.evt.>`. Commands (`cmd`) and
heartbeats (`heartbeat`) use core NATS. They stay outside the stream by
construction, not because someone keeps a filter list. To add a new event
subject:

1. Add a builder and a filter helper in
   [`internal/events/subjects.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/events/subjects.go).
2. Add it to the consumer's `FilterSubjects` and its dispatch switch.

The stream captures the new subject with no change.

When NATS is off or unreachable, `events.Publish` still writes a slog line
(`kiosk.event`). The ledger and the slog stream both stay authoritative. The
NATS broadcast is best-effort transport for consumers downstream.

---

## 6. The Controller's Projected Ledger

The controller binary embeds the same migrations as the kiosk node, plus a
small set of controller-only collections. Its `transactions` and
`transaction_lines` collections each get extra fields, used as idempotency
keys:

| Field | On | Purpose |
| :--- | :--- | :--- |
| `source_kiosk_code` + `source_transaction_id` | `transactions` (unique pair index) | One row per originating kiosk node and transaction. A redelivery is a no-op. |
| `source_line_id` | `transaction_lines` (unique-when-non-empty) | The same idea, for lines. |

A JetStream durable consumer named `controller-aggregator`
([`internal/controller/consumer.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/controller/consumer.go))
binds the `evt` channel and projects each event:

| Event | Projection |
| :--- | :--- |
| `evt.transaction.complete` | One `transactions` row. |
| `evt.item.{action}` | One `transaction_lines` row. Then the aggregator recomputes the worker's open set for the fleet and writes it to the `open` family of `KIOSK_STATE` (see below). |
| `evt.inventory.adjust` | One `inventory_audit` row, idempotent on `source_adjustment_id`. |
| `evt.instance.lifecycle` | One `instance_lifecycle_audit` row, idempotent on `source_audit_id`. |
| `evt.checkout.admin_close` | One `transactions` row and one `admin_close` line (`ProjectAdminCloseToLedger`), the same writes as `commit.AdminClose` makes locally. |
| `evt.integrity.rebuild` | Acknowledged and logged, as an audit hook for a future operations view. The controller stores no `open_checkouts`, so it has nothing to rebuild. |

### Open checkouts on the controller

The controller **does not store an `open_checkouts` table**. When it needs
the open set from its own data, it replays the projected lines
(`ledger.ReplayOpenRows`). The result converges with each kiosk node's view by
construction, so it cannot drift. The Currently out report asks online kiosk
nodes first and replays only for an offline one
([Central Controller §6](controller.md#6-reports)).

After each line projection, the aggregator also recomputes the affected
worker's open set across the fleet with `ledger.ReplayOpenRowsForUser`. That
replay is bounded to one user. It reads the worker's own transactions, and
every transaction whose return or close names the worker as
`original_checkout_user`. So a foreman's cross-user return still closes the
holder's row. The aggregator writes the result to the `open` family of the
`KIOSK_STATE` bucket, which feeds the fleet-wide clock-out gate.

### Admin closes

An admin close publishes **only** `evt.checkout.admin_close`, never
`transaction.complete` or `item.*`. So this event is the controller's only
view of the close. The projected `admin_close` line is what makes the replay
drop the holder's row.

### One direction for each kind of record

The projection only adds rows. The controller never writes back to a kiosk
node's ledger. Ledger data flows one way, from the kiosk node to the
controller.

`users` and `items` flow the other way, from the controller to the kiosk node
over JetStream KV. Those are catalog records, not ledger records. We split
them on purpose. The controller manages the catalog and distributes it. The
kiosk nodes generate the ledger at the edge, and the controller collects it.

---

## 7. Idempotency

Every write the controller makes for an event is idempotent, because the
storage layer enforces a unique, stable key:

| Surface | Key | Effect of a duplicate |
| :--- | :--- | :--- |
| `transactions` projection | unique(`source_kiosk_code`, `source_transaction_id`) | Lookup first, insert on a miss. A unique violation from a race is caught and treated as already projected. |
| `transaction_lines` projection | unique-when-non-empty `source_line_id` | The same pattern. |
| `inventory_audit` | unique-when-non-empty `source_adjustment_id` | The same. |
| `instance_lifecycle_audit` | unique-when-non-empty `source_audit_id` | The same. |
| `checkout.admin_close` projection | unique(`source_kiosk_code`, `source_transaction_id`) + `source_line_id` | Projected as a `transactions` row and an `admin_close` line, with the same keys as the rows above. A redelivery is a no-op. The controller stores no `open_checkouts`, so there are no guarded deletes. The replay drops the holder's row because of the projected line. |
| Remote `inventory.adjust` command | unique-when-non-empty `command_id` on `stock_adjustments` | On the kiosk node: a retried command finds the earlier row and replies with the earlier result. It does not apply twice. |
| Remote `checkout.close` command | unique-when-non-empty `command_id` on `transactions` | The same pattern, at transaction scope. |
| Remote `instance.{create,set_status}` | unique-when-non-empty `command_id` on `instance_audit` | The same. |

JetStream delivers at least once, so the consumer can see one event twice.
The unique indexes make the second delivery a no-op, not a second write.

---

## 8. Drift Recovery

The controller's projected ledger is a copy kept over an unreliable transport:
NATS, with `MaxAge=7d` retention in v1. Three things can make it drift from a
kiosk node's local ledger:

1. **NATS was unreachable when the kiosk node published an event.** The
   client holds the publish in its memory buffer. If the buffer overflows, or
   the kiosk node restarts before it reconnects, the controller never sees the
   event. The kiosk node's local ledger still has the transaction.
2. **The controller was down for longer than the JetStream retention window**
   (7 days by default). Events older than `MaxAge` leave the stream, and the
   consumer cannot replay them.
3. **A bug or a manual edit on either side.** PocketBase collection rules block
   manual edits through the normal API. A PocketBase superuser can still change
   rows through `/_/`.

Two operator tools close the gap:

- **`POST /api/kiosk/ledger/republish`** walks each completed transaction in
  an optional `{from, to}` RFC 3339 window. It sends again the events that the
  live commit path sent:
  - `transaction.complete` and `item.{action}` for an ordinary transaction.
  - One `checkout.admin_close` for an admin force-close transaction, the same
    shape as `commit.AdminClose` sends live.

  It rebuilds the payloads from the stored rows, with the original timestamps
  and the `kiosk_code` and `location_code` stamped at commit time. You can run
  it again safely, because the controller's projection is idempotent.
- **`POST /api/controller/kiosks/{code}/ledger/republish`** does the same
  thing from the controller, over NATS request and reply. The operator needs
  no shell access to the kiosk node.

For the opposite case, where a kiosk node's `open_checkouts` has drifted from
its own ledger, use the integrity rebuild in §4.

::: note No automatic drift detection
v1 does not detect drift by itself. If you suspect drift, compare the counts
by hand: `transactions.count` per `kiosk_code` on the controller against the
count on the kiosk node.
:::

---

## 9. Stand-alone and Managed: One Ledger Model

A **stand-alone** kiosk node has the full ledger (`transactions`,
`transaction_lines` and `open_checkouts`) and writes through `commit.Commit`.
Events fire and go to slog. If NATS is not configured, they stop there.
Reports read the local ledger.

A **managed** kiosk node has the same ledger, the same commit path and the
same events. NATS is configured, and the events also reach the controller's
durable consumer, which projects them. Catalog records come in from the
controller's KV buckets. The kiosk node's local ledger stays authoritative for
what happened at that kiosk node. If the controller is unreachable, the kiosk
node continues to work: checkouts work and events wait in the buffer. The
controller's projection receives the backlog on reconnect, or through a
republish if it cannot.

The controller is not a database upgrade for the kiosk node. It is a
projection target that uses the same row shapes for the ledger. It also has
its own audit collections for the event families outside the ledger.

You can delete the controller's `pb_data_controller/` and rebuild it with a
`ledger.republish` on every kiosk node. That gives back the transaction and
line data, and so the open-checkouts view that the controller derives from it.
The exception is events older than the JetStream retention window. The next
manual export pass would have to cover those.

A republish reproduces admin force-closes exactly. It detects an admin-close
transaction by its single `admin_close` line, and sends the same
`checkout.admin_close` event as the live path. It does *not* send the
`transaction.complete` and `item.{action}` pair of the regular walk. The
controller projects that event into the same ledger rows that the kiosk node
holds: a completed transaction and one `admin_close` line. So a replay drops
the holder's open row. Both projections are idempotent on
`source_transaction_id` and `source_line_id`, so a second republish changes
nothing.

---

## 10. Where to Go Next

- The write path: [`internal/commit/commit.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/commit/commit.go)
- Admin force-close: [`internal/commit/admin_close.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/commit/admin_close.go)
- Integrity check and replay: [`internal/handlers/integrity.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/handlers/integrity.go)
- Republish: [`internal/handlers/ledger_republish.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/handlers/ledger_republish.go)
- The controller's aggregator: [`internal/controller/consumer.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/controller/consumer.go)
- Event subjects: [`internal/events/subjects.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/events/subjects.go)
- Collection shapes: [`migrations/1779000000_init.go`](https://github.com/stone-age-io/kiosk/blob/main/migrations/1779000000_init.go) and the files beside it
- The controller that consumes the ledger: [Central Controller](controller.md)
