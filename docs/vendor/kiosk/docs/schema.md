---
path: kiosk/schema
nav_order: 50
---
# Schema

This page lists every collection in the kiosk, its fields and their meaning. It
also gives the cardinality rules for `open_checkouts` and the CSV import
format. The schema is Go code in three migration packages. The migrations are
the source of truth, and this page is the readable summary. For how the ledger
uses these collections, see [Ledger](ledger.md). For the HTTP routes, see
[API Reference](api.md). For the fleet side, see [Controller](controller.md).

---

## 1. The Whole Schema

Three migration packages build the schema:

| Package | Path | Imported by |
| :--- | :--- | :--- |
| `migrations` | `migrations/` | Every binary: the kiosk node, the controller and the timeclock terminal |
| `controllermigrations` | `migrations/controller/` | The controller only |
| `timeclockmigrations` | `migrations/timeclock/` | The timeclock terminal only |

`1779000000_init.go` creates the first six collections. It changes the default
`users` auth collection in place and creates `admins`, `items`,
`transactions`, `transaction_lines` and `open_checkouts`. Later migrations add
the per-instance and audit-log collections, the notification collections, the
timeclock ledger, and the controller-only collections. Each migration
registers itself in `init()`. The controller imports both the shared and the
controller packages, so the shared collections exist in its database too.

| Collection | Where | Purpose |
| :--- | :--- | :--- |
| [`users`](#users) | All | Workers (badge holders). |
| [`admins`](#admins) | All | Foremen and admins who sign in to the admin SPA. |
| [`groups`](#groups) | All | Sub-contractors and trades. |
| [`items`](#items) | All | Tools and consumables: the SKU. |
| [`item_instances`](#item_instances) | All | One physical unit of a serialized SKU. |
| [`instance_audit`](#instance_audit) | All | Append-only log of instance lifecycle changes. |
| [`stock_adjustments`](#stock_adjustments) | All | Append-only log of quantity changes to quantity-tracked items. |
| [`transactions`](#transactions) | All | The append-only ledger, one row per committed cart. |
| [`transaction_lines`](#transaction_lines) | All | One row per item action in a transaction. |
| [`open_checkouts`](#open_checkouts) | All | What is out right now. |
| [`time_punches`](#time_punches) | All | Append-only timeclock ledger. |
| [`notification_templates`](#notification_templates) | All | One editable template per event type. |
| [`notification_send_log`](#notification_send_log) | All | One row per attempted recipient. |
| [`notification_dedupe`](#notification_dedupe) | All | The once-per-day gate for `SendIfFirst`. |
| [`scheduled_reports`](#scheduled_reports) | All | Admin-edited digest schedules. |
| [`kiosks`](#kiosks) | Controller | Registry of every kiosk node in the fleet. |
| [`kiosk_items`](#kiosk_items) | Controller | Which kiosk node stocks which SKU. |
| [`inventory_audit`](#inventory_audit) | Controller | Fleet-wide projection of stock adjustments. |
| [`instance_lifecycle_audit`](#instance_lifecycle_audit) | Controller | Fleet-wide projection of instance lifecycle events. |
| [`instance_location`](#instance_location) | Controller | The latest advisory sighting per serialized unit. |
| [`instance_epc_index`](#instance_epc_index) | Controller | EPC to owning unit map. |

### Reading the tables

- The tables leave out PocketBase's `id`, the auth system fields, and the
  `created` and `updated` autodate fields, except where the app reads them.
- "→ `items`" is a relation to that collection. A relation holds a PocketBase
  id, so it is valid only inside one database.
- "Unique when set" is a partial unique index that skips empty values.

### Access rules

- Every API rule is `@request.auth.collectionName = 'admins'`. Workers and
  anonymous callers read nothing through the record API.
- The append-only collections (`transactions`, `transaction_lines`,
  `open_checkouts`, `instance_audit`, `stock_adjustments`, `time_punches`, the
  notification log and dedupe tables, and the controller's audit and location
  projections) have no create, update or delete rule. Only in-process code
  writes them.
- `notification_templates` has no create or delete rule. Migrations seed the
  rows, and admins edit them.
- On the controller, `kiosks` has no delete rule.

---

## 2. People

### `users`

Workers (badge holders). This is the default PocketBase auth collection,
changed in place. It keeps real emails, for notifications such as receipts.
Workers do not sign in, except on the timeclock terminal
([§7](#7-timeclock-terminal-only-schema)).

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `email` | email, required | The worker's real email. |
| `name` | text | Display name. |
| `code` | text, required, unique | The worker's badge code. A scan resolves to it, and CSV import matches on it. |
| `role` | select, required | `worker` or `foreman`. |
| `active` | bool | |
| `group` | → `groups`, optional | The worker's trade. Deleting the group sets this to null. |
| `phone` | text | Optional direct line to this worker. `groups.contact_phone` covers the crew. |
| `avatar` | file | The PocketBase default. |

### `admins`

Foremen and admins. A separate PocketBase auth collection. Admins sign in
with email and password.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `email` | email, required | Sign-in email. |
| `name` | text, required | Display name. |
| `active` | bool | Notifications to "all admins" go to active rows only. |

### `groups`

Sub-contractors and trades. Optional on workers.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `code` | text, required, unique | The stable join key, for CSV import and cross-fleet sync. |
| `name` | text, required | Display name. |
| `contact_email` | email | Admin-managed. Later features, such as email receipts, use it. |
| `contact_phone` | text | Admin-managed. |
| `notes` | text | Admin-managed. |
| `active` | bool | Indexed. |

Deleting a group sets `users.group` to null on the affected workers.

---

## 3. Catalog

### `items`

Tools and consumables: the SKU.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `code` | text, required, unique | The SKU code. CSV import matches on it. |
| `name` | text, required | Display name. |
| `type` | select, required | `tool` or `consumable`. |
| `unit` | text | For example `each` or `box of 100`. |
| `tracking_mode` | select, required | `quantity` or `serialized`. |
| `category` | text | Indexed. |
| `active` | bool | |
| `notes` | text | |
| `quantity_on_hand` | number (int) | See below. |
| `reorder_threshold` | number (int) | The low-stock alert level. `0` disables the alert. |
| `requires_maintenance_on_return` | bool | Serialized SKUs only. When set, a returned unit goes into maintenance automatically. |

**`quantity_on_hand`** means two things, by tracking mode:

- **`quantity` tools and consumables.** A stored value that admins can adjust.
  For a `quantity` tool it is the fleet count. For a consumable it is the
  current stock.
- **`serialized` SKUs.** A **derived** materialized count of the
  **non-retired** `item_instances` (`in_service` and `maintenance`, not
  `retired`). The instances recompute hook keeps it in sync, and nobody can
  edit it directly.

### `item_instances`

One physical unit of a serialized SKU.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `item` | → `items`, required, cascade delete | The parent SKU. |
| `code` | text, required, unique when set | The scannable code. |
| `serial` | text | The printed serial. |
| `rfid_epc` | text, unique when set | The optional RFID tag. Stored as trimmed, lower-case hex ([RFID](rfid.md)). |
| `status` | select, required | `in_service`, `maintenance` or `retired`. See below. |
| `notes` | text | |
| `enclosure_id` | text, indexed | The access-controlled cabinet this unit lives in. It is the `enclosure_diff` partition key. |
| `ble_id` | text, indexed | A BLE beacon id, parallel to `rfid_epc`. |
| `last_observed_at` | date, indexed | Advisory last-observed time. |
| `last_observed_zone` | text | Advisory last-observed zone. |
| `last_observed_gateway` | text | Advisory last-observed gateway. |
| `last_observed_lat` | number | Advisory last-observed latitude. |
| `last_observed_lon` | number | Advisory last-observed longitude. |

**`status`** is the lifecycle:

- `in_service` is checkout-eligible.
- `maintenance` is physically present but parked. It counts toward on-hand
  and is not available.
- `retired` replaces the old "decommissioned" state and the removed hard
  delete. Units are never deleted, because the ledger keeps their relations
  alive.

"Checked out" is **not** a status. It stays derived from `open_checkouts`.

**The `last_observed_*` fields are advisory, lossy and last-write-wins.** RFID
and BLE gateway sightings and custody reads write them. They stay on the
kiosk node and are never synced with the catalog. They **never** gate custody.

### `instance_audit`

Append-only log of `item_instances` lifecycle changes. It has the same role as
`stock_adjustments` for quantity.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `item_instance` | → `item_instances`, required | The unit. |
| `item` | → `items`, required | Its SKU. |
| `action` | select, required | `create`, `to_maintenance`, `return_to_service`, `retire` or `unretire`. Derived from the (previous → target) transition. |
| `prev_status` | select | The status before the change. |
| `new_status` | select | The status after the change. |
| `reason` | text | |
| `admin` | → `admins` | The responsible admin, for `source=local`. |
| `controller_admin_id` | text | The controller's admin id, for `source=controller`. |
| `source` | select, required | `local` or `controller`. |
| `command_id` | text, unique when set | Idempotency anchor for remote commands. |

Two writers add rows: PocketBase record hooks (the REST path) and
`instances.SetStatusInTx` (the commit and command-bus path). There is one row
per lifecycle action. Cosmetic edits (code, serial, notes) do not write a row,
on purpose. `commit.AdminClose` also writes a `retire` row when
`closure_reason` is `lost` or `damaged` and so retires a serialized instance.

### `stock_adjustments`

Append-only log of changes to a **quantity-tracked** item's
`quantity_on_hand`. Two paths write it: `/api/kiosk/items/{id}/adjust` (local)
and the controller's `inventory.adjust` command bus (remote). Both paths reject
serialized items, because their quantity is derived.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `item` | → `items`, required | The adjusted item. |
| `delta` | number (int), required | The change. |
| `new_quantity` | number (int), required | A snapshot of the quantity after the change. |
| `reason` | text, required | |
| `admin` | → `admins` | The responsible admin, for `source=local`. |
| `source` | select, required | `local` or `controller`. |
| `controller_admin_id` | text | The controller's admin id, for `source=controller`. |
| `command_id` | text, unique when set | A UUID, for idempotent replay of remote commands. |

---

## 4. Ledger

### `transactions`

The append-only ledger. One row per committed cart.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `kiosk_code` | text, required | The kiosk node that committed it. |
| `location_code` | text, required | Its location. |
| `user` | → `users`, required | The cart user. |
| `started_at` | date | |
| `completed_at` | date | |
| `status` | select, required | `open`, `completed` or `voided`. |
| `void_reason` | text | |
| `lines_count` | number (int) | The number of lines, set once by the commit hook, so lists need no count per row. |
| `user_group` | text | A snapshot of the worker's group code at commit, so reports stay correct after a worker changes group. |
| `terminal_id` | text, indexed | Optional attribution tag. The screen that accepted the cart, from the `?terminal=` URL param on commit. |
| `enclosure_id` | text, indexed | Optional attribution tag. The cabinet an RFID `enclosure_diff` cart drew from (`cart.EnclosureID`, set by `StartByExternal`). |
| `closed_by_admin` | → `admins` | Set when an admin force-close created the row. |
| `command_id` | text, unique when set | Idempotency anchor for closes the controller forwards. |

`terminal_id` and `enclosure_id` are empty on a single-kiosk install. They are
attribution only and never gate auth or correlation.

### `transaction_lines`

One row per item action in a transaction.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `transaction` | → `transactions`, required, cascade delete | The parent transaction. |
| `item` | → `items`, required | The SKU. |
| `action` | select, required | `checkout`, `return`, `consume` or `admin_close`. |
| `qty` | number (int), required | Always `1` on a serialized line. |
| `serial` | text | |
| `item_instance` | → `item_instances` | The unit, on a serialized line. |
| `original_checkout_user` | → `users` | The worker whose open checkout this line closed. Set on `return` rows from the foreman-return endpoint and on every `admin_close` row. |
| `uncorrelated` | bool | A return that matched fewer open rows than its `qty` ([§4 cardinality](#cardinality-rules-for-open_checkouts)). |
| `closure_reason` | select | `admin_close` only: `lost`, `returned_offline`, `damaged` or `other`. |
| `closed_by_admin` | → `admins` | `admin_close` only, for `source=local`. |
| `notes` | text | Also carried on `admin_close` rows. |

### `open_checkouts`

A materialized view of what is out right now. One row per unit out.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `item` | → `items`, required | The SKU. |
| `item_instance` | → `item_instances` | The unit, for a serialized unit. |
| `serial` | text, unique when set | |
| `user` | → `users`, required | Who has it. |
| `checked_out_at` | date, required | |
| `transaction_line` | → `transaction_lines`, required | The checkout line that opened the row. |

The commit hook maintains this table **on the kiosk node**. The controller does
not maintain it. The controller derives "currently out" on demand by replaying
`transaction_lines` (`ledger.ReplayOpenRows`).

### Cardinality rules for `open_checkouts`

- A `checkout` line with `qty=N` for a non-serialized tool creates **N rows**.
- A `return` line with `qty=N` deletes up to **N rows**. If fewer matched, the
  line is marked `uncorrelated=true`.
- A serialized line always has `qty=1` and carries an `item_instance`
  relation. At most one open row exists per instance at any time. A return
  targets that exact instance, and sibling units of the same SKU stay as they
  are.
- Consumables create no `open_checkouts` rows. The commit hook decrements
  `items.quantity_on_hand` by `qty` in the same transaction instead.

::: note Consumable stock can go negative
The ledger is authoritative. A worker who takes more than was recorded must
not be blocked at the kiosk.
:::

---

## 5. Timeclock

### `time_punches`

The append-only timeclock ledger, one row per clock-in or clock-out punch. It
is **API-readonly**: admins can list and view, and create, update and delete
are forbidden. Only the in-process punch funnel `timeclock.PerformPunch`
writes it.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `user` | → `users`, required | The worker. |
| `user_code` | text, required | The worker's code. |
| `direction` | select, required | `in` or `out`. |
| `occurred_at` | date, required | Business time. Admin punches can backdate. The server stamps live punches. |
| `source` | select, required | `self`, `foreman`, `admin` or `controller_admin`. |
| `recorded_by_admin` | → `admins` | The actor for an `admin` punch. |
| `recorded_by_user` | → `users` | The actor for a `foreman` punch. |
| `controller_admin_id` | text | The actor for a `controller_admin` punch. |
| `reason` | text | Required only for admin and corrective punches. |
| `force` | bool | An admin override, or a self or foreman "clock out anyway" past the open-tools block. `source` tells them apart. |
| `job_code` | text | An optional job or work-order tag on a clock-in. Never validated. The display pairing carries it from the "in" punch onto the interval. |
| `note` | text | An optional annotation on any punch, also self and foreman. Separate from `reason`. Never validated. |
| `kiosk_code` | text, required | Where the punch happened. |
| `location_code` | text | |
| `command_id` | text, unique when set | Idempotency anchor. |
| `created` | autodate | Breaks ties on `occurred_at`. |

A non-self punch sets exactly one actor field (`recorded_by_admin`,
`recorded_by_user` or `controller_admin_id`).

"Is this user clocked in" is **derived**. It is the latest punch by
`occurred_at` (with `created` as the tiebreaker), merged with the fleet
`punch_state` replica. There is no materialized open-shifts table, on purpose.
The migration is shared, so the controller's database has the collection too,
and the aggregator projects fleet punches into it.

---

## 6. Notifications

The schema is in every binary. On a managed kiosk node the local template rows
are dormant, because sends fire from the controller's rows. See
[Notifications](notifications.md).

### `notification_templates`

One row per event type. The event types are `receipt.transaction`,
`alert.lowstock`, `alert.maintenance`, `digest.open_checkouts`,
`digest.daily_activity`, `digest.maintenance`, `digest.reconciliation`,
`digest.timeclock` and `digest.timeclock_self`.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `event_type` | text, required, unique | The key. Code finds a template by event, not by id. |
| `name` | text, required | Display name. |
| `enabled` | bool | Per-event gate. Turning it off stops sends and keeps the content. |
| `subject` | text | A Go template. |
| `body` | text | A Go template. |
| `recipients` | json | `{worker_email, all_admins, extras}`. |
| `updated_by` | → `admins` | The last admin to edit the row. |

Migrations seed the rows from compiled-in defaults. Admins can edit a row but
cannot delete it. `digest.timeclock_self` is the per-worker timesheet. The
scheduler sends one email per worker from a single schedule row, so its
recipients are implicit and the scheduler ignores the row's `recipients`.

### `notification_send_log`

One row per attempted recipient.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `event_type` | text, required | |
| `template` | → `notification_templates` | |
| `recipient` | text | |
| `status` | select, required | `sent`, `failed` or `skipped`. |
| `error` | text | |
| `payload_summary` | text | |

A daily prune removes rows older than 90 days. In managed mode the
controller's table holds the fleet-wide audit. A standalone kiosk node logs to
its own.

### `notification_dedupe`

The race-free deduplication gate for `SendIfFirst`.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `event_type` | text, required | |
| `ref` | text, required | Receipts use the transaction id. Low-stock uses the item id. |
| `day` | text, required | |

The three fields are unique together: `(event_type, ref, day)`. Scheduled
digests skip this table on purpose, because the repeat is the feature.

### `scheduled_reports`

Admin-edited schedule rows.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `report_key` | select, required | `open_checkouts`, `daily_activity`, `maintenance`, `timeclock`, `timeclock_self` or `reconciliation`. |
| `cadence` | select, required | `daily`, `weekly` or `monthly`. |
| `hour` | number (int), required | |
| `weekday` | number (int) | For `weekly`. |
| `day_of_month` | number (int) | For `monthly`. |
| `enabled` | bool | Indexed. |
| `recipients` | json | Overrides the template's stored recipients for this row. |
| `subject_override` | text | |
| `last_run_at` | date | |
| `last_status` | text | |
| `last_error` | text | |
| `kiosk_code` | text | Scopes a controller row to one kiosk node. Empty means fleet-wide. |

In a standalone deployment the kiosk node runs the scheduler against its local
data. In a managed deployment the controller owns the schedule, the
computation and SMTP, and the kiosk node's scheduler stays off.

---

## 7. Timeclock-Terminal-Only Schema

The virtual timeclock terminal (`cmd/timeclock`) applies one extra migration
that no other binary imports: `migrations/timeclock/` (Go package
`timeclockmigrations`), with the same isolation as `migrations/controller/`.

It turns `users` into a real worker sign-in surface, in that binary's
database only. It sets `AuthRule = "active = true"` and
`OAuth2.Enabled = true`, so active workers can sign in with SSO, a password,
or both. The row-level list, view, create and update rules stay admins-only.
The migration turns on authentication, not data access. Kiosk nodes and the
controller never import the package, so worker sign-in stays off there.

---

## 8. Controller-Only Schema

The controller-only migrations are in the package `migrations/controller/`.
The kiosk binary does not import it, so a kiosk node's database never has
these collections or fields.

### Extra fields on shared collections

| Collection | Field | Type | Meaning |
| :--- | :--- | :--- | :--- |
| `transactions` | `source_kiosk_code` | text | With `source_transaction_id`, the redelivery idempotency key. The pair is unique when both are set. |
| `transactions` | `source_transaction_id` | text | The originating kiosk node's transaction id. |
| `transaction_lines` | `source_line_id` | text, unique when set | Idempotency anchor for redelivery. |
| `transaction_lines` | `source_item_instance_id` | text | The kiosk-local instance id, so the open-checkouts replay can pair a serialized checkout with its return. |
| `open_checkouts` | `kiosk_code` | text, indexed | The kiosk node the unit is out from. |
| `open_checkouts` | `source_item_instance_id` | text | The kiosk-local instance id. |
| `time_punches` | `source_punch_id` | text, unique when set | The originating kiosk node's `time_punches.id`. The projection's idempotency anchor. |
| `time_punches` | `source_actor` | text | The actor, for a kiosk-admin actor whose relation cannot resolve in the controller's database. |

### `kiosks`

Registry of every kiosk node in the fleet. It gives fleet visibility. It is also the join
target for "which kiosk node did this aggregated transaction come from?". A row appears in
one of three ways:

- An admin pre-registers the kiosk node with the "New kiosk" button on
  `AdminKiosksView`.
- The aggregator creates it with `status=unknown` the first time it sees a
  `transaction.complete` from a new `kiosk_code`.
- The first heartbeat creates it.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `kiosk_code` | text, required, unique | The kiosk node's code. |
| `location_code` | text | |
| `status` | select, required | `unknown`, `active` or `disabled`. |
| `notes` | text | |
| `last_transaction_at` | date | Advances on `transaction.complete` only. The heartbeat, not this table, gives general liveness. |

### `kiosk_items`

Membership rows. One row is one (kiosk node, item) pair: "this kiosk node
stocks that SKU".

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `kiosk` | → `kiosks`, required, cascade delete | |
| `item` | → `items`, required, cascade delete | |

The pair is unique. A delete on either side removes the row. The rows drive
per-kiosk catalog publishing. A kiosk node never receives an item over
JetStream KV unless a row ties it to that item.

### `inventory_audit`

Fleet-wide, append-only projection of every `inventory.adjust` event the
aggregator sees. One row per adjustment, denormalized. It feeds the
Reports → Adjustment audit tab on the controller.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `kiosk_code` | text, required | |
| `item_code` | text, required | |
| `item_name` | text | |
| `mode` | text | The adjust mode, `delta` or `absolute`. |
| `delta` | number (int) | |
| `prev_quantity` | number (int) | |
| `new_quantity` | number (int) | |
| `reason` | text | |
| `source` | select | `local` or `controller`. |
| `admin_id` | text | |
| `command_id` | text | |
| `occurred_at` | date | |
| `source_adjustment_id` | text, unique when set | The originating kiosk node's `stock_adjustments.id`. JetStream redelivery never duplicates a row. |

### `instance_lifecycle_audit`

Fleet-wide, append-only projection of every `instance.lifecycle` event the
aggregator sees. One row per lifecycle event, denormalized. It feeds the
Reports → Instance lifecycle tab on the controller. A standalone kiosk node's
Reports tab reads its local `instance_audit` for the same view.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `kiosk_code` | text, required | |
| `item_code` | text | |
| `item_name` | text | |
| `instance_id` | text, required, indexed | |
| `instance_code` | text | |
| `action` | select, required | The same values as `instance_audit.action`. |
| `prev_status` | select | |
| `new_status` | select | |
| `reason` | text | |
| `source` | select | `local` or `controller`. |
| `admin_id` | text | |
| `command_id` | text | |
| `occurred_at` | date | |
| `source_audit_id` | text, unique when set | The originating kiosk node's `instance_audit.id`. JetStream redelivery never duplicates a row. |

### `instance_location`

The fleet-wide advisory location view (location and sightings, L3): the latest
sighting per serialized unit. It holds the latest value only and is never a
sighting log.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `kiosk_code` | text, required | Unique with `instance_code`. |
| `instance_code` | text, required | Unique with `kiosk_code`. |
| `instance_id` | text, indexed | |
| `item_code` | text | |
| `last_observed_at` | date, indexed | Mirrors the kiosk node's `last_observed_*` columns. |
| `last_observed_zone` | text | |
| `last_observed_gateway` | text | |
| `last_observed_lat` | number | |
| `last_observed_lon` | number | |

The `SightingIngest` upserts it **monotonically** on `observed_at`. It is a
plain core-NATS subscriber on the lossy `sighting` channel, **not** the durable
consumer. The L4 reconciliation report joins this table against the replayed
ledger.

### `instance_epc_index`

The EPC to owning unit map. The aggregator fills it from the `rfid_epc` it
threads onto the `instance.lifecycle` projection. It lets the `SightingIngest`
resolve a raw gateway sighting, which carries only a tag id, to its owning
kiosk node. It is bounded: one row per tagged unit.

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `rfid_epc` | text, required, unique when set | The tag. |
| `instance_id` | text | |
| `instance_code` | text | |
| `kiosk_code` | text, required | The owning kiosk node. |
| `item_code` | text | Lets the fleet location report name what the unit is. |
| `item_name` | text | |

### Controller migrations

| Migration | What it adds or changes |
| :--- | :--- |
| `2000000000_controller_collections.go` | `kiosks`, `source_kiosk_code` and `source_transaction_id` on `transactions`, and `source_line_id` on `transaction_lines` |
| `2000100000_add_kiosk_items.go` | `kiosk_items` |
| `2000200000_kiosks_last_transaction_at.go` | `kiosks.last_transaction_at` |
| `2000300000_inventory_audit.go` | `inventory_audit` |
| `2000400000_instance_lifecycle_audit.go` | `instance_lifecycle_audit` |
| `2000500000_open_checkouts_kiosk_code.go` | `kiosk_code` and `source_item_instance_id` on `open_checkouts` |
| `2000600000_applied_oc_closes.go`, `2000800000_drop_applied_oc_closes.go` | Create, then drop, `applied_oc_closes`. It was the idempotency guard for the old materialized open-checkouts projection. The controller now replays the ledger. |
| `2000700000_tx_lines_source_instance.go` | `source_item_instance_id` on `transaction_lines` |
| `2000900000_instance_lifecycle_audit_status.go` | Moves `instance_lifecycle_audit` to the `status` vocabulary (`prev_status`, `new_status`) |
| `2001000000_drop_kiosks_last_seen.go` | Drops the old `kiosks.last_seen` |
| `2001100000_time_punches_source.go` | `source_punch_id` and `source_actor` on `time_punches` |
| `2001200000_transactions_door_id.go`, `2001300000_rename_door_to_terminal.go` | `terminal_id` and `enclosure_id` on the controller's projected `transactions` |
| `2001400000_instance_location.go` | `instance_location` |
| `2001500000_instance_epc_index.go` | `instance_epc_index` |
| `2001600000_epc_index_item.go` | `item_code` and `item_name` on `instance_epc_index` |

The kiosk-side location and sightings fields (`item_instances.last_observed_*`
and `ble_id`) come from the shared migrations
`1803000000_instance_last_observed.go` and `1804000000_instance_ble_id.go`.

---

## 9. CSV Import Format

There are three importers, with the same response shape (per-row outcomes, see
[API Reference](api.md)). All three are on **both binaries**: the kiosk node's
Admin → Import view and the controller's same view. A managed kiosk node shows
a read-only banner that points to the controller. Each endpoint has a matching
`/template` route. It streams a starter CSV with a header and example rows that
the importer reads back cleanly.

Common rules:

- An empty cell is null. `active` accepts `true|false|1|0|yes|no|y|n`.
- Rows match existing records by `code` (upsert). The importer leaves records
  that are not in the CSV alone. It never deletes.
- Validation is per row. A bad row records an error and the rest of the batch
  continues.
- A dry run (`dry_run=true`) is read-only: one snapshot read and no writes. The
  response classifies every row as `insert` or `update`, from the diff against
  the current database.

### Items: `POST /api/kiosk/items/import`

```text
code,name,type,unit,tracking_mode,category,active,notes,quantity_on_hand,reorder_threshold
DR-IMPACT-042,Impact Driver,tool,each,serialized,Power Tools,true,,,0
SCREW-DECK-3IN,Deck Screws 3in,consumable,box of 100,quantity,Fasteners,true,,25,5
```

`quantity_on_hand` and `reorder_threshold` are optional. If you leave them
out, existing rows keep their values and new rows default to zero.

- For a **serialized** row the importer ignores `quantity_on_hand`, because
  the count is derived from non-retired instances. `reorder_threshold` still
  applies.
- Per-unit serials and RFID EPCs live on `item_instances`, not on the SKU row.
  A serialized SKU created by CSV still needs its instances, added in the admin
  UI's instances panel. They drive its derived quantity.

### Workers: `POST /api/kiosk/users/import`

```text
code,name,email,role,group,active
WORKER-1,Alice,alice@example.com,worker,electrical,true
FOREMAN-1,Sam,sam@example.com,foreman,electrical,true
```

- `role` defaults to `worker`.
- `group` is the group's **code**, not its id.
- On a real run, the importer creates an unknown group code with
  `code=name=value` and `active=true`. Admins add the contact details later in
  the Groups admin view.
- A dry run does *not* create groups. The side effect happens only on a real
  import.

### Groups: `POST /api/kiosk/groups/import`

```text
code,name,contact_email,contact_phone,notes,active
electrical,Electrical Crew,lead@example.com,+1-555-0100,Morning shift,true
```

Use it to fill in contact details on groups that a workers import created.

---

## 10. Where to Go Next

- How commit, returns and admin closes write these tables: [Ledger](ledger.md)
- Routes, including the CSV importers: [API Reference](api.md)
- RFID and the `rfid_epc` and `enclosure_id` fields: [RFID](rfid.md)
- Templates, recipients and the send log: [Notifications](notifications.md)
- The fleet side and its projections: [Controller](controller.md)
- The system overview: [Overview](overview.md)
