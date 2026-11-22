---
path: kiosk/api
nav_order: 40
---
# API Reference

This page lists the HTTP routes of the kiosk node (`kiosk-app`), the controller
(`kiosk-controller`) and the timeclock terminal (`kiosk-timeclock`), with the
auth each route needs. Most controller routes send a NATS command to a node.
The subjects, payloads and replies behind them are in
[Wire Protocol](protocol.md).

---

## 1. The Whole Surface

Each binary adds custom routes under `/api/kiosk/*`, `/api/controller/*` or
`/api/self/*`. PocketBase's own `/api/collections/*` serves the PocketBase CRUD.

| Binary | Serves |
| :--- | :--- |
| `kiosk-app` | [Checkout flow](#2-checkout-flow), [timeclock](#3-timeclock), [admin operations](#4-admin-operations), [imports, exports and reports](#5-imports-exports-and-reports), [process endpoints](#8-process-endpoints) |
| `kiosk-controller` | [Controller routes](#6-controller-routes), part of [imports, exports and reports](#5-imports-exports-and-reports), `/api/kiosk/identity`, `/branding/*`, [process endpoints](#8-process-endpoints) |
| `kiosk-timeclock` | [Virtual timeclock terminal](#7-virtual-timeclock-terminal), [process endpoints](#8-process-endpoints) |

The **Auth** column in each table uses three values:

- **none**: an anonymous route.
- **admin**: a token from the `admins` auth collection in the `Authorization`
  header. The PocketBase SDK sends it after login.
- **worker**: a token from the `users` auth collection, on the timeclock
  terminal only ([§7](#7-virtual-timeclock-terminal)).

The checkout routes are anonymous. They assume that the kiosk node is
physically secured and bound to `127.0.0.1`. The application identifies the
worker by a badge scan: the scanned `code` resolves to a `users` record.

---

## 2. Checkout Flow

These routes are on the kiosk node.

| Route | Auth | Purpose |
| :--- | :--- | :--- |
| `GET /api/kiosk/identity` | none | The node's identity and feature flags (see below). Also on the controller and the timeclock terminal. |
| `GET /branding/logo` | none | The configured logo file. `404` when none is set. |
| `GET /branding/custom.css` | none | The configured custom stylesheet, as `text/css`. `404` when none is set. |
| `POST /api/kiosk/scan` | none | Resolves a raw scan to `user`, `item` or `unknown`. |
| `GET /api/kiosk/items` | none | Active items for the in-cart browse picker. Query: `?q=` (matches code, name, category or notes), `?type=` (`tool` \| `consumable`). |
| `POST /api/kiosk/cart/start` | none | Returns the existing cart for a user code, or a new one. |
| `POST /api/kiosk/cart/add` | none | Adds a line or stacks it on a line, and sets the default action (see below). |
| `GET /api/kiosk/cart/foreman-return/options` | none | The picker for the "Return on behalf of…" dialog. Query: `?cart_id=…`. |
| `POST /api/kiosk/cart/foreman-return` | none | Adds a return line for another worker (see below). |
| `PATCH /api/kiosk/cart/lines/{id}` | none | Changes the qty and/or the action of a line (see below). |
| `DELETE /api/kiosk/cart/lines/{id}` | none | Removes a line. |
| `GET /api/kiosk/cart` | none | Gets the cart again, by `?cart_id=`. |
| `GET /api/kiosk/cart/events` | none | Server-Sent Events for one cart. Query: `?cart_id=…`. |
| `POST /api/kiosk/cart/cancel` | none | Discards a cart in progress. |
| `POST /api/kiosk/cart/commit` | none | Turns the cart into a transaction, with its side effects and events. |
| `POST /api/kiosk/cart/rfid-scan` | none | **RFID `counter_scan` mode only.** Reads tags into the cart. Query: `?cart_id=…`. |
| `POST /api/kiosk/cart/read-trigger` | none | **RFID `enclosure_diff` mode only.** Reads the enclosure and reconciles the cart. Query: `?cart_id=…`. |

**`identity`** returns `{role, kiosk_code, location_code, branding, max_qty,
managed, rfid_enabled, rfid_mode, rfid_enclosure_ids?, timeclock_enabled,
timeclock_require_clock_in, timeclock_block_clock_out, timeclock_only,
timeclock_virtual}`.

- `managed` is true when the node is opted into central control.
- `rfid_enabled` and `rfid_mode` control the SPA's "RFID scan" and "Re-read
  enclosure" buttons.
- The `timeclock_*` flags control the splash "Time clock" button and the
  interlock text. `timeclock_only` and `timeclock_virtual` switch the SPA to the
  punch-station or the signed-in self-service view.
- On the controller, `role` is `controller`.

**`cart/add`** picks the default action:

- a consumable → `consume`,
- a tool that is already out to the cart's user → `return`,
- anything else → `checkout`.

It never sets `original_checkout_user_id`. A cross-user return goes through
`cart/foreman-return`.

**`cart/foreman-return/options`** returns the workers in the cart user's group
who have at least one open checkout, with their open rows. The cart user must be
a `foreman` with a group.

**`cart/foreman-return`** takes `{cart_id, item_code, target_user_code?}`.

- `target_user_code` is optional only when `item_code` resolves to a
  **serialized** instance. The server then finds the holder from the instance's
  `open_checkouts` row.
- It checks that the cart user is a `foreman` with a group, and that the target
  is in the same group. The commit gate checks the same things again.
- It is the only **cart-write API** route that sets
  `original_checkout_user_id`. Commit also resolves it on the server for
  serialized returns (see the next item). The server always resolves it. The
  client never sends it.

**`PATCH cart/lines/{id}`.** A change of a **serialized** line to `return`
does not set `original_checkout_user_id`. But if the scanned instance's
open-checkout holder is another worker, commit finds the holder on the server.
It then applies the same foreman and same-group gate and the
`returns.allow_cross_user` policy. A cross-user serialized return is therefore
gated here too, not only through `cart/foreman-return`.

**`cart` and `cart/events`.** The events stream sends `cart.updated` on every
cart write and `cart.gone` on commit or cancel. An SSE comment every 15 s keeps
proxies from closing an idle connection. The SPA gets the cart again through
`GET /api/kiosk/cart` on every signal: the server pushes a signal, and the SPA
pulls the payload.

**`cart/rfid-scan`** runs one LLRP inventory cycle. It resolves each observed
EPC through the same scan path as `cart/add`, and adds the matched instances to
the cart.

- A failure on one EPC is logged and skipped, so one bad tag does not fail the
  batch. The failures are: already in the cart, an ineligible instance (status
  ≠ `in_service`), an unknown tag.
- It returns `{cart, added_lines, observed_epcs, unresolved_epcs}`.
- It returns `503` when the reader connection is down.
- It publishes `evt.scan.rfid.observed` for every outcome.

**`cart/read-trigger`** runs one LLRP inventory cycle and reconciles the
observed EPCs with the expected-present state through `rfid.Diff`.

- It adds checkout lines (expected, not observed) and self-return lines (held
  by the cart user, observed).
- It skips and counts a cross-user return.
- It returns `{cart, added_lines, observed_epcs, unresolved_epcs,
  skipped_cross_user_count, skipped_maintenance_count}`.
- The NATS `read.trigger` command runs the same read. This HTTP form is the
  manual retry on the outside-enclosure screen.

---

## 3. Timeclock

These routes are on the kiosk node. The four admin routes are also on the
timeclock terminal.

| Route | Auth | Purpose |
| :--- | :--- | :--- |
| `GET /api/kiosk/timeclock/status` | none | One worker's merged clocked-in state, and the context the punch screen shows. Query: `?user_code=…`. |
| `POST /api/kiosk/timeclock/punch` | none | A live punch: the worker's own, or a foreman's punch for a crew member (see below). |
| `GET /api/kiosk/timeclock/foreman/options` | none | The picker for "punch a crew member": the ACTIVE workers in the foreman's group, each with merged clocked-in state. Query: `?user_code=…`. The user must be a `foreman` with a group. |
| `POST /api/kiosk/timeclock/admin-punch` | admin | A manual or corrective punch (see below). |
| `GET /api/kiosk/timeclock/now` | admin | Everyone who is clocked in now, by the merge rule. A managed node includes fleet state. |
| `GET /api/kiosk/timeclock/history` | admin | Raw punches, and paired intervals and day totals, for a date range. Query: `?from=&to=` (YYYY-MM-DD), `?user_code=`. |
| `POST /api/kiosk/timeclock/republish` | admin | Publishes the `timeclock.punch` events again for an optional `{from, to}` RFC3339 window. It is for a controller backfill after a NATS outage, and is idempotent on `source_punch_id`. |
| `GET /api/kiosk/reports/timeclock.csv` | admin | The raw-punch CSV (see below). Query: `?from=&to=`, `?user_code=`. |

**`timeclock/status`** returns `{user_id, user_code, user_name, user_role,
clocked_in, since, origin, open_checkouts, block_clock_out, today_seconds}`.

- `origin` is `local`, `fleet` or `""`.
- `open_checkouts` is the **fleet-merged** list in managed mode. Each row has
  its `kiosk_code`.
- `today_seconds` is the worker's time in CLOSED intervals for the local day
  at THIS node. The panel adds the open session to it for its "X today" text.

**`timeclock/punch`** takes `{user_code, direction: "in"|"out",
target_user_code?, acknowledge?, job_code?, note?}`.

- A `target_user_code` that differs from `user_code` makes it a foreman punch
  for a crew member.
- `job_code` is an optional job or work-order tag, used on a clock-in. `note`
  is an optional free-text note, on either direction.
- It does NOT accept backdating or an admin force. `acknowledge:true` is the
  worker's or foreman's "clock out anyway" past the open-tools block. The punch
  records it.
- It goes through `timeclock.PerformPunch`. The foreman and same-group gate
  runs again inside the transaction.
- It returns **409** `{error: "already_clocked_in"|"not_clocked_in"|"open_checkouts", …}`
  for an expected conflict. The `open_checkouts` body carries the blocking
  rows. In managed mode they are **fleet-wide**, each with the `kiosk_code` to
  return it to.

**`timeclock/admin-punch`** takes `{user_code, direction, reason, occurred_at?,
force?, job_code?, note?}`. `reason` is required. Backdating (`occurred_at`,
RFC3339) and a `force` clock-out past the open-tools block are admin-only.

**`reports/timeclock.csv`** is the **payroll contract**. It has no rounding, no
overtime and no pay-period logic. Its last columns are `job_code` and `note`,
for cost-by-job pivots and context on each punch.

---

## 4. Admin Operations

These routes are on the kiosk node.

| Route | Auth | Purpose |
| :--- | :--- | :--- |
| `GET /api/kiosk/integrity` | admin | Compares the expected and the actual `open_checkouts`. |
| `POST /api/kiosk/integrity/rebuild` | admin | Clears `open_checkouts` and rebuilds it from the ledger. |
| `POST /api/kiosk/ledger/republish` | admin | Publishes the `transaction.complete` and `item.{action}` events again for the completed transactions in an optional `{from, to}` ISO8601 window. The aggregator is idempotent, so you can run it again safely. |
| `POST /api/kiosk/items/{id}/adjust` | admin | Changes `quantity_on_hand` and writes a `stock_adjustments` audit row, in one transaction (see below). |
| `POST /api/kiosk/checkouts/by-line/{transaction_line_id}/close` | admin | Force-closes one `open_checkouts` row (see below). |
| `GET /api/kiosk/reconciliation` | admin | Node-local reconciliation of custody against location (see below). **Observability only.** |
| `GET /api/kiosk/locations` | admin | Node-local advisory location report (see below). **Observability only.** |
| `GET /api/kiosk/metrics` | admin | An operational and activity snapshot: uptime, NATS status, transaction counts for today and 7 days, and more. The controller forwards the same `metrics.Compute` payload for each node. |
| `GET /api/kiosk/notifications` | admin | Lists the notification templates. Also on the timeclock terminal. |
| `PATCH /api/kiosk/notifications/{event_type}` | admin | Updates a template. Also on the timeclock terminal. |
| `GET /api/kiosk/notifications/{event_type}/defaults` | admin | The compiled-in defaults of a template. Also on the timeclock terminal. |

**`items/{id}/adjust`** returns **400** for a serialized item. Its quantity
comes from the count of units that are not retired. Change it by adding or
retiring instances, or by moving them through maintenance.

**`checkouts/by-line/{transaction_line_id}/close`** takes
`{reason: "lost"|"returned_offline"|"damaged"|"other", notes?}`. In one
database transaction it writes one `transactions` row and one
`transaction_lines` row (`action="admin_close"`), and deletes the open row.
`lost` and `damaged` also lower the item's count:

- A quantity item: the node lowers `quantity_on_hand` and writes a
  `stock_adjustments` row.
- A serialized item: the node sets `item_instances.status="retired"` and writes
  an `instance_audit` `retire` row. The derived `quantity_on_hand` follows the
  count of units that are not retired. There is no `stock_adjustments` row.

**`reconciliation`** (location/sightings L4) joins the node's `open_checkouts`
with its `item_instances.last_observed_*`. It returns
`{discrepancies: [{kind, kiosk_code, instance_code, item_name, holder?, zone?,
observed_at?}], generated_at, stale_after_hrs}`. `kind` is `not_taken`,
`stale` or `unaccounted`. It never enforces anything.

**`locations`** is the inverse of reconciliation. It lists every serialized unit
with a `last_observed_at`, newest first.

- Row shape: `{kiosk_code, instance_code, item_code, item_name, zone, gateway,
  lat, lon, observed_at, status, holder?}`. `holder` is set when the unit is
  out now.
- It drives the Locations admin page, as a list and an optional map.
- It is empty until a gateway or a zoned custody reader reports.

---

## 5. Imports, Exports and Reports

The **Binaries** column says where each route runs: the node, the controller
(ctrl) or the timeclock terminal (tc).

| Route | Auth | Binaries | Purpose |
| :--- | :--- | :--- | :--- |
| `POST /api/kiosk/items/import` | admin | node, ctrl | Multipart CSV upload, upsert by `code` (see below). |
| `GET /api/kiosk/items/import/template` | admin | node, ctrl | A CSV template with the columns the importer accepts and example rows. |
| `POST /api/kiosk/users/import` | admin | node, ctrl, tc | The workers CSV importer. Same response shape as items. On a real run (not a dry run) it creates an unknown `group` code. |
| `GET /api/kiosk/users/import/template` | admin | node, ctrl, tc | The workers CSV template. |
| `POST /api/kiosk/groups/import` | admin | node, ctrl | The groups CSV importer. Same response shape. |
| `GET /api/kiosk/groups/import/template` | admin | node, ctrl | The groups CSV template. |
| `GET /api/kiosk/transactions.csv` | admin | node, ctrl | Completed transactions as CSV. Optional `from=` and `to=` ISO8601 query parameters. |
| `GET /api/kiosk/items.csv` | admin | node, ctrl | The items catalog, in the same columns the items importer accepts. |
| `GET /api/kiosk/reports/open-checkouts` | admin | node, ctrl | The open checkouts. Optional `?kiosk_code=`. On the controller it prefers a live `checkout.snapshot` from an online node. |
| `GET /api/kiosk/reports/open-checkouts.csv` | admin | node, ctrl | The CSV form of `reports/open-checkouts`. Optional `?kiosk_code=`. |
| `GET /api/kiosk/reports/low-stock.csv` | admin | node | The node's low-stock CSV: active items at or below `reorder_threshold`. The controller has a fleet form at `/api/controller/reports/low-stock.csv`. |
| `GET /api/kiosk/reports/group-activity.csv` | admin | node, ctrl | Transactions per group, as CSV. Query: `?from=` and `?to=` (YYYY-MM-DD), optional `?kiosk_code=`. |
| `GET /api/kiosk/reports/instance-lifecycle.csv` | admin | node, ctrl | The instance lifecycle audit as CSV. The node reads its `instance_audit`. The controller reads `instance_lifecycle_audit`. Filters: `?from`, `?to` (YYYY-MM-DD), `?action`, `?source`, and `?kiosk_code` on the controller only. |
| `GET /api/kiosk/reports/notifications.csv` | admin | node, ctrl | `notification_send_log` rows for the `?lookback_days` window (default 7, max 90). |

**`items/import`** takes `file` (the CSV) and `dry_run` (`true` or `false`). It
returns `{dry_run, rows_total, rows_inserted, rows_updated, rows_errored,
rows: [{row, code, name, action: "insert"|"update"|"error", errors?: [{code,
message}]}]}`.

- There is one entry for each input row.
- The importer classifies each row by a diff against a snapshot of the existing
  records.
- A dry run is read-only. Its `insert` or `update` is the action that *would*
  happen.

---

## 6. Controller Routes

These routes are on the controller only. A route marked "503 on offline"
returns `503 {error: "kiosk_offline", kiosk_code}` when the node's heartbeat is
stale or the NATS request times out.

**Catalog and fleet:**

| Route | Auth | Purpose |
| :--- | :--- | :--- |
| `GET /api/kiosk/catalog/integrity` | admin | Compares the catalog database with JetStream KV. Returns `missing_in_kv` and `extra_in_kv` for each bucket. |
| `POST /api/kiosk/catalog/reconcile` | admin | Pushes the database to KV, always. Deletes orphan KV keys when the body is `{delete_orphans: true}`. |
| `GET /api/controller/kiosks/heartbeats` | admin | Returns `{controller_started_at, kiosks: {code: lastSeenISO}}`. The SPA polls it every 10 s to show the online, stale and offline badges. |

**Commands to one node.** Each route sends one NATS command
([Wire Protocol §3](protocol.md#3-commands)) to the node `{code}`. Each one is 503
on offline.

| Route | Auth | Command | Notes |
| :--- | :--- | :--- | :--- |
| `GET /api/controller/kiosks/{code}/inventory` | admin | `inventory.snapshot` | The node's live on-hand count for every stocked item. |
| `POST /api/controller/kiosks/{code}/inventory/adjust` | admin | `inventory.adjust` | Body: `{item_code, mode, value, reason}`. See below. |
| `POST /api/controller/kiosks/{code}/inventory/threshold` | admin | `inventory.set_threshold` | Body: `{item_code, value}`. `value: 0` turns the alert off. See below. |
| `POST /api/controller/kiosks/{code}/checkouts/{source_line_id}/close` | admin | `checkout.close` | Body: `{reason, notes?}`. See below. |
| `GET /api/controller/kiosks/{code}/instances` | admin | `instance.snapshot` | Optional `?item_code=` filter. See below. |
| `POST /api/controller/kiosks/{code}/instances` | admin | `instance.create` | Body: `{item_code, code, serial?, rfid_epc?, notes?}`. A new unit starts as `status="in_service"`. |
| `PATCH /api/controller/kiosks/{code}/instances/{instance_code}` | admin | `instance.edit` | Body: any subset of `{code, serial, rfid_epc, notes}`. Cosmetic only: no audit row, no lifecycle event. |
| `POST /api/controller/kiosks/{code}/instances/{instance_code}/status` | admin | `instance.set_status` | Body: `{status, reason}`. See below. |
| `GET /api/controller/kiosks/{code}/metrics` | admin | `metrics.snapshot` | The node's live metrics, in the same shape as the node's `GET /api/kiosk/metrics`. |
| `GET /api/controller/kiosks/{code}/config` | admin | `config.snapshot` | The node's RFID readers: mode, host and port, enclosure, antenna count and live connection status. Drives the Readers tab. Observability only: you edit the config in the node's YAML. |
| `POST /api/controller/kiosks/{code}/integrity/rebuild` | admin | `integrity.rebuild` | Clears the node's `open_checkouts` and rebuilds it from its ledger. Empty body. Idempotent on its own, because a replay gives the same state. |
| `POST /api/controller/kiosks/{code}/ledger/republish` | admin | `ledger.republish` | Publishes `transaction.complete` and `item.{action}` again for the optional `{from, to}` window. The projection dedupes on `source_line_id`, so a duplicate changes nothing. |
| `POST /api/controller/kiosks/{code}/timeclock/punch` | admin | `timeclock.punch` | Body: `{user_code, direction, reason, occurred_at?, force?, job_code?, note?}`. See below. |
| `POST /api/controller/kiosks/{code}/timeclock/republish` | admin | `timeclock.republish` | Publishes `timeclock.punch` again for the optional `{from, to}` window. Idempotent on `source_punch_id`. |

- **A server-generated `command_id`.** For `inventory/adjust`,
  `checkouts/…/close`, `instances` (create), `instances/…/status` and
  `timeclock/punch`, the controller makes the `command_id`. A replay is
  therefore idempotent.
- **`inventory/adjust`** gets `success=false` for a serialized item, because its
  quantity is derived. Manage it through the Instances tab.
- **`inventory/threshold`** has no `command_id`. The operation is absolute, so a
  replay ends at the same value. It **accepts serialized SKUs**, unlike adjust.
  `reorder_threshold` is kiosk-local and never travels in the catalog. So this
  route is the only way a managed node gets a threshold, and the only way
  low-stock alerting fires in a managed fleet.
- **`checkouts/{source_line_id}/close`.** `source_line_id` is the node's
  `transaction_lines.id` from the projected ledger. The node runs
  `commit.AdminClose`, so the result is the same as a local close.
- **`instances` (GET)** returns `{instances: [{instance_id, instance_code,
  item_code, item_name, serial, rfid_epc, status, notes, enclosure_id, created,
  updated, last_observed_at, last_observed_zone, last_observed_gateway,
  last_observed_lat, last_observed_lon}]}`. The controller adds a derived `out`
  flag to each row. The `last_observed_*` fields fill the panel's "Last seen"
  column. In managed mode the node's mirror watcher keeps them current.
- **`instances/{instance_code}/status`** is the single lifecycle-transition
  route. `status` is `in_service`, `maintenance` or `retired`, and `reason` is
  required. It writes an audit row and publishes `instance.lifecycle`. The node
  derives the audit verb from the transition: `to_maintenance`,
  `return_to_service`, `retire` or `unretire`.
- **`timeclock/punch`** records a controller-admin punch **at** the node. The
  nodes are the only punch writers.

**Fleet timeclock, reports and location:**

| Route | Auth | Purpose |
| :--- | :--- | :--- |
| `GET /api/controller/timeclock/now` | admin | Everyone who is clocked in now, fleet-wide, from the controller's projected `time_punches`. |
| `GET /api/controller/timeclock/history` | admin | Fleet punches and the paired view. Query: `?from=&to=`, `?user_code=`, `?kiosk_code=`. |
| `GET /api/controller/reports/timeclock.csv` | admin | Raw fleet punches as CSV (the payroll contract). It has `kiosk_code`, so a downstream system can split by site, and `job_code` and `note` columns. |
| `GET /api/controller/reports/low-stock` | admin | The fleet low-stock report (see below). Optional `?kiosk_code=` limits it to one node. |
| `GET /api/controller/reports/low-stock.csv` | admin | The CSV form of the fleet low-stock report. It uses the same fan-out. The CSV holds data only: it leaves out the errors for offline nodes. Use the JSON route for status. |
| `GET /api/controller/reports/adjustment-audit.csv` | admin | The `inventory_audit` collection as CSV. Filters: `?from` and `?to` (YYYY-MM-DD), `?kiosk_code`, `?source` (`local` \| `controller`). |
| `GET /api/controller/reconciliation` | admin | Fleet-wide reconciliation of custody against location (see below). **Observability only.** |
| `GET /api/controller/locations` | admin | The fleet-wide advisory location report (see below). **Observability only.** |

**`reports/low-stock`** sends `inventory.snapshot` to every online managed node
in parallel. It joins each snapshot with `out` counts from the controller's
projected ledger, and returns the rows whose `available ≤ reorder_threshold`.
The response is `{rows: [...], errors: [{kiosk_code, error}]}`. An offline node
shows in `errors`, so a partial result is explicit.

**`reconciliation`** (location/sightings L4) joins each node's replayed ledger
with the site-wide `instance_location` view. The response shape is the same as
`/api/kiosk/reconciliation`. The `not_taken` flag needs
`location.custody_zones` in the controller config, because the controller has
no reader zones to use as a default. `stale` and `unaccounted` work without it.

**`locations`** has the same row shape as `/api/kiosk/locations`. The location
comes from the `instance_location` view, the holder from a replay of each
node's projected ledger, and the item identity from `instance_epc_index`.

**Notification templates:**

| Route | Auth | Purpose |
| :--- | :--- | :--- |
| `GET /api/controller/notifications` | admin | Lists the notification templates. Same DTO as the node's `/api/kiosk/notifications`. |
| `PATCH /api/controller/notifications/{event_type}` | admin | Updates the subject, body, enabled flag or recipients of a template. |
| `GET /api/controller/notifications/{event_type}/defaults` | admin | The compiled-in defaults, for "Reset to defaults". |

---

## 7. Virtual Timeclock Terminal

The `kiosk-timeclock` binary serves a public self-service punch surface, with a
login for each worker. It does **not** register the anonymous checkout, cart or
inventory routes. Those routes do not exist in that process, so the public box
cannot expose them. It registers these routes:

- `/api/kiosk/identity` and `/branding/*`,
- the three `/api/self/timeclock/*` routes below,
- the timeclock admin routes `timeclock/now`, `timeclock/history`,
  `timeclock/admin-punch` and `reports/timeclock.csv`
  ([§3](#3-timeclock)),
- the notification template routes ([§4](#4-admin-operations)),
- the admin workers import and its template, for standalone provisioning
  ([§5](#5-imports-exports-and-reports)).

| Route | Auth | Purpose |
| :--- | :--- | :--- |
| `GET /api/self/timeclock/status` | worker | The signed-in worker's own merged clocked-in state (see below). |
| `POST /api/self/timeclock/punch` | worker | The signed-in worker's own live punch (see below). |
| `GET /api/self/timeclock/history` | worker | The signed-in worker's own punches and paired view for a `?from=&to=` range. The server forces it to the session's worker. The terminal's today and week summary card comes from this route. |

**`self/timeclock/status`** has the shape of `/api/kiosk/timeclock/status`
without `today_seconds`. The terminal shows its own today and week summary from
`/history` instead. The identity comes from `re.Auth`. There is no `user_code`
query parameter to spoof.

**`self/timeclock/punch`** takes `{direction, acknowledge?, job_code?, note?}`.

- The target is always the session's worker, with `source=self` forced. There
  is no backdating and no foreman power.
- `job_code` is optional and used on a clock-in. `note` is optional free text
  on either direction.
- `acknowledge:true` is the worker's "clock out anyway" past the fleet-wide
  open-tools block.
- A 409 conflict body matches the node's punch route. Its `open_checkouts`
  lists the tools that are out anywhere in the fleet, each with its building.

**Auth model.** `worker` means a valid token for the `users` auth collection,
with `active=true`. `requireWorker` checks it. It is the `users` form of
`requireAdmin`.

- The server resolves the punched identity **from the session, never from the
  request body**. This is the same trust rule as `original_checkout_user_id`.
- A migration that only `cmd/timeclock` runs makes the `users` collection a
  real auth surface (`AuthRule = "active = true"`, OAuth2 on).
- Workers sign in through OAuth2 SSO, or with a password, or both. SSO matches
  an existing worker by email, and does not enroll new ones. Provisioning sets a
  random password, so a password login starts with a reset by email.
- The base `/api/kiosk/timeclock/*` routes stay anonymous on the kiosk node.
  The timeclock terminal does not serve the anonymous ones.

::: warning Gate PocketBase's own routes
The timeclock terminal is reachable from the public network. PocketBase still
serves its own `/api/collections/*` auth routes and the `/_/` superuser UI on
it. Gate those at the reverse proxy or firewall.
:::

---

## 8. Process Endpoints

All three binaries serve these routes.

| Route | Auth | Purpose |
| :--- | :--- | :--- |
| `GET /health` | none | Returns `{status: "ok"}`, for liveness probes. |
| `GET /api/ready` | none | The platform's readiness contract (Health & Metrics in `platform-docs`). |

`/api/ready` checks the database, the binary's collections, the schema version
and NATS every 15 s. It returns `503` only when a check fails. The NATS check
warns on a node or a timeclock terminal, which keep working without NATS. It
fails on the controller.

---

## 9. PocketBase Collection Rules

| Collection | List/View | Create/Update/Delete |
| :--- | :--- | :--- |
| `users` (workers) | admin | admin |
| `admins` | self only | superuser only (through `/_/`) |
| `items` | admin | admin |
| `item_instances` | admin | admin |
| `transactions` | admin | forbidden through the API. Only the commit hook writes it. |
| `transaction_lines` | admin | forbidden through the API |
| `open_checkouts` | admin | forbidden through the API |
| `time_punches` | admin | forbidden through the API. Append-only. Only the punch path (`timeclock.PerformPunch`) writes it. |
| `stock_adjustments` | admin | forbidden through the API. Only `/items/{id}/adjust` writes it. |
| `instance_audit` | admin | forbidden through the API. The `item_instances` record hooks write it, and `commit.AdminClose` writes it for a serialized retire on close. |
| `inventory_audit` | admin | **Controller only.** Forbidden through the API. The aggregator writes it from `inventory.adjust` events. |
| `instance_lifecycle_audit` | admin | **Controller only.** Forbidden through the API. The aggregator writes it from `instance.lifecycle` events. |

The checkout flow never uses PocketBase's REST API. Every operation goes
through a custom `/api/kiosk/*` route. The route runs in the process and does
not go through the collection rules.

There is one exception, on the **timeclock terminal**. A migration that only
that binary runs sets the `users` collection's `AuthRule` to `active = true`
and turns on OAuth2. Active workers can then sign in through PocketBase's
built-in `/api/collections/users/auth-with-*` routes. The row rules for list,
view, create and update stay admin-only. A worker can sign in, but cannot read
or change the collection. The kiosk node and the controller never run that
migration, so worker login is off there.

---

## 10. Events, Commands and Heartbeats

The commit hook calls `internal/events.Publish(subject, payload)` for every
state change.

- It always writes a structured `slog.Info` line.
- When `nats.enabled=true`, it also publishes the JSON payload to the same
  subject, through a NATS connection that buffers while disconnected.
- It logs a NATS publish error at warn level. A publish error never blocks or
  fails a commit.

[Wire Protocol](protocol.md) has every event, command and heartbeat, with its
payload and reply. In short:

- **Events:** `kiosk.{code}.evt.{rest}`. The node publishes them, and the
  `KIOSK_EVENTS` stream stores them. The stream binds to `kiosk.*.evt.>` and
  nothing else.
- **Commands:** `kiosk.{code}.cmd.{name}`. Core NATS request and reply, with a
  5 s reply timeout. The reply envelope is `{success, error, data}`.
- **Heartbeats:** `kiosk.{code}.heartbeat`. A core publish every 45 s. Only the
  latest beat counts.

`kiosk` is the default of `nats.subject_prefix`. The kiosk node, the timeclock
terminal and the controller must use the same value. Change it only to prevent
a collision on a shared NATS cluster, where another application already owns
the `kiosk.>` subjects.

---

## 11. Where to Go Next

- Subjects, payloads and replies: [Wire Protocol](protocol.md)
- The controller and its catalog: [Controller](controller.md)
- Config keys: [Configuration](configuration.md)
- Collections and fields: [Schema](schema.md)
- Notification templates and recipients: [Notifications](notifications.md)
