---
path: kiosk/operations
nav_order: 80
---
# Operations

This page covers the day-to-day work of running a kiosk fleet: deploy, back
up, check and repair the ledger, and recover from a NATS outage. It also
covers stock, serialized units and the timeclock terminal. Every config key
named here is in [Configuration Reference](configuration.md). The subjects and
commands are in [Wire Protocol](protocol.md).

---

## 1. Deploy a Kiosk Node

The minimum deploy, on a Linux host:

```bash
mkdir -p /opt/kiosk
cp kiosk-app /opt/kiosk/
cp kiosk.yaml /opt/kiosk/                 # set kiosk.code and kiosk.location_code
cd /opt/kiosk && ./kiosk-app
```

On the first run, the binary creates `pb_data/` next to itself and applies the
migrations. It prints the bootstrap admin credentials. Save them. Then point
Chromium, or any browser, at `http://localhost:8090/`. Use the browser's kiosk
mode if it fits the site.

To start the binary at boot, run it under the supervisor your host uses:
systemd, runit, OpenRC or a Windows service. The binary needs:

- A working directory that contains `kiosk.yaml`, or
  `KIOSK_CONFIG=/path/to/yaml`.
- Write access to that directory, for `pb_data/`.
- A reachable port. The default is `8090`, bound to `127.0.0.1`.

---

## 2. Make Backups

The SQLite file at `pb_data/data.db` holds the whole state of a kiosk node.

A hot copy is safe enough for a system with this few writes:

```bash
cp /opt/kiosk/pb_data/data.db /backups/data-$(date +%Y%m%d-%H).db
```

For more safety, use the SQLite online backup:

```bash
sqlite3 /opt/kiosk/pb_data/data.db ".backup /backups/data-$(date +%Y%m%d-%H).db"
```

Schedule it with your host's scheduler. Hourly is enough for a tool crib,
because people make every write.

---

## 3. Check Ledger Integrity

After a suspected fault, such as a power loss, a manual database edit or a hook
bug, an admin can call `GET /api/kiosk/integrity`. It uses the PocketBase SDK
auth of the admin UI. A clean ledger returns:

```json
{
  "checked_lines": 247,
  "expected_open": 18,
  "actual_open": 18,
  "missing_in_table": [],
  "extra_in_table": []
}
```

When `missing_in_table` or `extra_in_table` is not empty, the
`transaction_lines` ledger is authoritative. You can rebuild the
`open_checkouts` table from it:

1. In the admin SPA, open **Reports → Currently out**.
2. Click **Rebuild from ledger** at the bottom of the list.
3. Confirm. The modal warns that this wipes and repopulates `open_checkouts`
   in a single transaction.

You can also call `POST /api/kiosk/integrity/rebuild` with an admin token. The
response reports `{ deleted, inserted }` counts.

Each rebuilt row takes the `completed_at` of its source checkout line as
`checked_out_at`. It also keeps a foreign key to the originating
`transaction_line`. Aging and audit reports stay correct after a rebuild.

---

## 4. Resync a Kiosk Node's Ledger to the Controller

The controller's projected ledger can drift from the local ledger of a kiosk
node. The usual cause is a short NATS outage, followed by a restart of the
kiosk node that loses a buffered event. The kiosk node can then publish its
history again:

```bash
# Publish every completed transaction in the ledger again:
curl -X POST \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{}' \
  http://localhost:8090/api/kiosk/ledger/republish

# Or limit it to a date window (suspected drift in the last 24h):
curl -X POST \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"from": "2026-05-21T00:00:00Z"}' \
  http://localhost:8090/api/kiosk/ledger/republish
```

The controller can start the same work on a remote kiosk node with
`POST /api/controller/kiosks/{code}/ledger/republish`.

The endpoint walks the completed transactions in `completed_at` order. For
each transaction, it publishes one `transaction.complete` event, plus one
`item.{action}` event per line. For example, the first goes to
`kiosk.{code}.evt.transaction.complete`, where `kiosk` is the configurable
`nats.subject_prefix`. The endpoint rebuilds each payload from the stored
records. It uses the `kiosk_code` and `location_code` stamped at the original
commit.

It is safe to run again. The controller's aggregator removes duplicates:

- For transactions, on `(source_kiosk_code, source_transaction_id)`.
- For lines, on `source_line_id`.

Publishing the whole history is the brute-force recovery. A `{from, to}`
window is better for routine work. The response is
`{ transactions_published, lines_published, skipped }`.

---

## 5. NATS Failure Modes

NATS is best-effort on a kiosk node and required on the controller. This table
shows what survives each failure and what is lost, so you can decide what to
monitor.

| Scenario | Kiosk node | Controller |
| :--- | :--- | :--- |
| Broker unreachable when the kiosk node starts | Boots normally. `events.Connect` returns a buffering connection that dials in the background. The local ledger is authoritative, and checkouts work without NATS. Catalog sync, if enabled, logs a warning and waits for the broker. | Not applicable. |
| Broker unreachable when the controller starts | Not applicable. | Does not start, because it requires NATS. Start the broker first. |
| Broker stops during a publish, kiosk node to controller | The NATS client keeps the event in its in-memory buffer. If the buffer overflows, or the kiosk node restarts before it reconnects, the controller **loses** the event. The local ledger still has the transaction. Publish the history again as in [§4](#4-resync-a-kiosk-nodes-ledger-to-the-controller), with an optional `{from, to}` window. The controller's projection is idempotent, admin force-closes included. | Misses the event, and its projected ledger drifts from the kiosk node's without a warning. Find it by comparing aggregate counts on both sides. |
| Broker stops during a publish, controller to catalog KV | No loss. A kiosk node that was offline syncs again from the bucket's current value when it reconnects. `Watch` replays the latest value of each key. | The `Put` call fails, and the controller logs a warning. The database record is already saved, so the controller's state is correct. Only the KV update failed. Save the record again (any edit) to retry, or restart the controller to publish again. |
| Broker recovers after an outage | Buffered events flush. KV watchers attach again and project each key that changed during the outage. | The durable consumer continues from the last acknowledged sequence, with no replay storm. |
| Controller restarts | Not applicable. | The durable consumer `controller-aggregator` continues from the last acknowledged sequence. KV `CreateOrUpdateKeyValue` is idempotent. Hooks bind again on the next save. No event is lost: events that arrived during the outage are still in the JetStream stream (7 days of retention by default). |
| Kiosk node restarts | The in-memory cart is lost. The NATS publisher reconnects. A managed node's watcher projects the current KV snapshot again. The local ledger is intact on disk. | Not applicable. |
| JetStream retention expires | Not applicable. | Events older than `MaxAge` (7 days by default) leave the stream. Running the consumer again does not replay them. For long-term archive, use the local ledger of the kiosk node or the projected ledger of the controller. Both are persistent SQLite. |

Two rules follow:

1. **Local ledgers are authoritative.** The kiosk node's `pb_data/data.db` and
   the controller's `pb_data_controller/data.db` are the source of truth for
   their own views. NATS is a transport, not a database.
2. **The controller's projected ledger can drift when events are lost in
   flight.** Today an operator finds drift by hand, by checking aggregate
   counts. A drift-detection job, which compares `transactions.count` per
   kiosk node on both sides, is on the [roadmap](roadmap.md#2-deferred).

---

## 6. Adjust Stock

For quantity-tracked tools and consumables, change `items.quantity_on_hand`
through the **Adjust…** button in the admin UI. Do not edit the value
directly. The button is next to the read-only quantity in the item dialog.

- The Adjust dialog takes a signed delta, or an absolute "set to N" value.
- Both need a free-form reason.
- Each submission writes a `stock_adjustments` row in the same transaction as
  the item update. The row records who, what and why.
- The **View adjustment history** link below the threshold field shows the
  past adjustments for the item.

Serialized items have **no** Adjust button. Their `quantity_on_hand` is the
count of instances that are not retired, which is in service plus maintenance.
The item dialog shows it read-only as "Units in service". To change it, add
instances or move them through their lifecycle ([§8](#8-manage-serialized-units)).
The `/adjust` endpoint and the controller's `inventory.adjust` command both
reject serialized items.

The **Low Stock** tab on Reports shows every active item whose available
quantity is at or below its `reorder_threshold`. "Available" means:

| Item type | Available |
| :--- | :--- |
| Serialized | active instance count − instances currently out |
| Quantity-tracked | `quantity_on_hand` − `count(open_checkouts)` |
| Consumable | `quantity_on_hand` |

---

## 7. Adjust Stock from the Controller

A controller admin can adjust the stock of a kiosk node without walking to it:

1. Open **Kiosks → {kiosk} → Inventory** on the controller. The SPA gets a live
   snapshot over NATS (`inventory.snapshot`).
2. Click **Adjust** on a row. The same delta, absolute and reason dialog
   opens.
3. Submit. The controller sends the `inventory.adjust` command to the kiosk
   node.

The kiosk node runs the same `PerformStockAdjustment` logic as the local
endpoint. It writes a `stock_adjustments` row with `source='controller'` and
the controller admin's id in `controller_admin_id`. It then publishes the usual
`inventory.adjust` event back through JetStream. The audit log on the
controller sees one event shape, wherever the change started.

Failure modes:

- **Kiosk node offline.** When the node's last heartbeat is older than 90 s,
  the controller endpoint returns **503
  `{error: "kiosk_offline", kiosk_code, command_id}`** at once. It publishes
  nothing. The SPA shows "kiosk offline" in about 1 s, and does not wait for
  a NATS timeout. The same body comes back when the NATS request times out
  (5 s) or hits `nats.ErrNoResponders`.
- **Retry or duplicate submission.** The SPA can time out while the kiosk node
  still processes the command. A retry with the same `command_id` is then
  safe. The kiosk node checks `stock_adjustments.command_id` and returns the
  earlier result instead of applying it again. Today the controller makes one
  UUID per click of submit. The future "reconcile" tool will accept an external
  `command_id` for an explicit replay.

---

## 8. Manage Serialized Units

In the admin SPA, open a serialized item, or create and save one. An
**Instances** panel shows below the form. Each row is one physical unit:

- **Code.** The barcode on the unit, for example `DR-042-A`. Workers scan it.
  It wins over the SKU code on a collision.
- **Serial.** The printed serial label, for information only.
- **RFID EPC.** An optional tag. It resolves through the same scan dispatcher.
- **Status.** The lifecycle state:
  - `in_service`: can be checked out.
  - `maintenance`: at the bench. Still owned and on hand, but not available.
  - `retired`: out of service. You can reverse it.

Each row offers only the changes that are valid for its current status:
**Send to maintenance**, **Return to service**, **Retire** and **Un-retire**.

The SPA **never hard-deletes** a unit. Retire it instead, which keeps the
ledger history. Two settings send a returned unit straight into maintenance:

- The `requires_maintenance_on_return` flag on the SKU.
- The per-return "needs maintenance" toggle, which any worker can set.

On serialized rows, the Items list shows an `N inst` badge next to the
tracking mode. An amber `N maint` badge shows when units are in maintenance.
An admin sees at a glance how many physical units each SKU has.

Each lifecycle change recomputes the SKU's `quantity_on_hand`. The changes are
create, to_maintenance, return_to_service, retire and unretire. The new value
is the count of **non-retired** instances, in service plus maintenance. This is
the only way the quantity of a serialized SKU changes, and you cannot adjust it
by hand. An admin close of a serialized unit as `lost` or `damaged` retires its
instance in the same way. The derived quantity drops by one, and no
`stock_adjustments` row is written.

---

## 9. Timeclock Terminal

The timeclock terminal, `kiosk-timeclock`, is the one binary you may expose to
the public internet. It serves a self-service punch page with per-user
authentication, so workers clock in and out from their phones. It uses the
timeclock stack of the kiosk node. It registers **only**:

- The authenticated `/api/self/timeclock/*` routes.
- Identity and branding.
- An admin user import.

None of the anonymous `/api/kiosk/*` checkout routes exist in it.

```bash
# Build. Build the SPA first, because the binary embeds it, as the kiosk node does.
go build -o kiosk-timeclock ./cmd/timeclock
cp timeclock.yaml.example timeclock.yaml      # edit kiosk.code, server.bind and the mode
KIOSK_CONFIG=timeclock.yaml ./kiosk-timeclock # creates pb_data_timeclock/ on first run
```

Choose an operating mode with the `nats` and `controller` blocks in
`timeclock.yaml`. See
[Configuration Reference](configuration.md#timeclock-terminal-timeclockyaml).
**Managed mode** is the right choice for a public terminal in front of a
fleet. Workers, with their email addresses, sync from the controller, and
clocked-in state merges across the fleet.

### What workers see

The punch panel shows each worker a live **today** and **this week** total.
The week starts on Monday. It also shows the in and out intervals of the day,
so workers can check their own hours.

- On the timeclock terminal, the panel shows the full view. It comes from
  `/api/self/timeclock/history`.
- On a physical kiosk node, the time-clock panel shows a compact "X today"
  line.

To send the same data on a schedule, schedule the **per-worker timeclock
summary** (Notifications → Scheduled reports, `digest.timeclock_self`). It
emails each active worker their own timesheet. See
[Notifications](notifications.md).

### Provision workers

- **Managed mode.** Workers come from the controller's catalog. You do nothing
  on the terminal.
- **Standalone modes.** Provision workers locally. Use the embedded admin SPA
  (`/admin/login` → Users), the superuser UI (`/_/`), or the CSV importer
  (`POST /api/kiosk/users/import`, which this binary registers). Give each
  worker an **email** address. SSO matching and password reset both need it.

### Configure authentication

- **OAuth2 SSO (recommended).** In the superuser UI, open `/_/` → Collections →
  `users` → Options → OAuth2. Enable a provider and paste its client id and
  secret. They are deployment secrets and are not in any migration. The match
  is by email. A runtime guard rejects an IdP account that has no
  pre-provisioned worker. This is **match-only**, with no self-enrollment.
- **Password.** Workers sign in by email. Provisioning sets a random password
  that nobody knows, so each worker sets one with **"Forgot password"**. That
  needs SMTP (superuser UI → Settings → Mail). The controller uses the same
  SMTP for notifications.

### Harden a public host

- **TLS.** Terminate it in front of the binary, with a reverse proxy or a
  Cloudflare Tunnel. Or use the PocketBase autocert (`serve --https`).
- **Firewall the superuser UI** (`/_/`). Restrict `/admin` and the PocketBase
  collections API to an admin network if you can. They require credentials,
  but a smaller reachable surface on a public host is good defense in depth.
- **Rate-limit** the auth endpoints, to slow credential stuffing. In the
  superuser UI, open Settings and enable the rate limiter.
- **Bind beyond localhost** (`server.bind: "0.0.0.0"`) only behind that TLS or
  proxy layer.

::: warning Never expose `kiosk-app` this way
The API of a kiosk node is anonymous by design. Its trust boundary is the box
and its `127.0.0.1` bind. Only the timeclock terminal authenticates each user.
:::

---

## 10. Reset the Bootstrap Admin Password

The bootstrap admin email is `admin@kiosk.local`. If you lost the password:

1. Open `http://localhost:8090/_/` and sign in as the PocketBase superuser.
2. Open the `admins` collection and click the `admin@kiosk.local` record.
3. Set a new password and save.

The superuser at `/_/` is separate from the `admins` collection of the kiosk
node. You create the superuser on your first visit to `/_/`. It manages
PocketBase itself: collections, settings and system tables.

---

## 11. Where to Go Next

- Every config key and default: [Configuration Reference](configuration.md)
- Subjects, commands and payloads: [Wire Protocol](protocol.md)
- The ledger, its projection and drift recovery: [Ledger](ledger.md)
- The central controller and managed mode: [Central Controller](controller.md)
- Templates, recipients and digests: [Notifications](notifications.md)
- Known problems and their fixes: [Troubleshooting](troubleshooting.md)
