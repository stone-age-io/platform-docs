---
path: kiosk/controller
nav_order: 20
---
# Central Controller (kiosk-controller)

`kiosk-controller` is the central service of a kiosk fleet. It holds the
catalog, sends it down to each kiosk node, and turns the events that the kiosk
nodes publish into one fleet ledger. This page says what the controller owns,
how to run it and how each flow works. The subjects and payloads are in the
[Wire Reference](protocol.md). The ledger model is in [Ledger](ledger.md). Every
config key is in [Configuration](configuration.md).

---

## 1. What It Is

The controller is optional. A stand-alone kiosk node works without it. Run a
controller when you have more than one kiosk node. It gives you one source of truth
for the catalog and one transaction ledger for the fleet.

`kiosk-controller` ([`cmd/controller`](https://github.com/stone-age-io/kiosk/blob/main/cmd/controller/main.go)) is a
PocketBase application. It embeds PocketBase as its database and serves the
same admin SPA as a kiosk node. Its NATS consumer and subscribers run inside
the same process.

The controller **never writes a kiosk node's ledger**. Each kiosk node records
its own checkouts, returns and punches, and its local ledger stays
authoritative. The controller reads what the kiosk nodes publish. To change
something on a kiosk node, it sends a command, and the kiosk node makes the
change in its own database.

### Who owns what

| Concern | `kiosk-controller` | Kiosk node |
| :--- | :--- | :--- |
| Catalog (`items`, `users`, `groups`) | Owns it. Publishes it to the catalog KV bucket | Watches its slice of the `items` family and all of `users` into its local tables. Hides catalog edits in its admin SPA |
| Stocking (`kiosk_items` membership) | Owns it | Receives only the items it stocks |
| Local state (`quantity_on_hand`, `reorder_threshold`, `item_instances`) | Never syncs it. Changes it only through commands | Owns it. Catalog updates leave it alone |
| Ledger (`transactions`, `transaction_lines`) | Projects a fleet copy from events | Writes it through the single write path. Authoritative |
| `open_checkouts` | Does not store it. Asks the kiosk node, or replays the projected lines | Keeps it current in the commit path |
| Time punches | Projects `time_punches`. Writes the `punch` family | The only punch writer |
| Commands | Sends them over core NATS request and reply | Answers them |
| Heartbeats | Subscribes. Keeps online status in memory | Publishes one every 45 s |
| Email | Sends receipts, alerts and scheduled digests for the fleet | Publishes notification events. Its scheduler stays off |

---

## 2. Running It

### On the platform

Each controller is a **Thing** in the organization it serves, like every
application process (Building an Application in `platform-docs`). Its Thing
Type and its NATS role come from the repository's
[`contract/`](../contract/README.md) folder.

1. **Apply the contract** to the organization, as an owner or admin of it:

   ```bash
   stone org switch acme
   stone apply --template contract/ --dry-run
   stone apply --template contract/
   ```

   It creates the Thing Type `kiosk-controller` and the NATS role
   `kiosk-controller`, with the ones for kiosk nodes and timeclock terminals.
   A second run changes nothing that already matches. It never deletes.
2. **Create a Thing** of Thing Type `kiosk-controller`. Give its NATS user the
   `kiosk-controller` role.
3. **Give it the Thing's creds file.** Either set `platform.url` and
   `platform.identity`, and the controller writes and rotates
   `nats.credentials_file` itself as the Thing
   ([Configuration §5.1](configuration.md#51-credentials-from-the-platform)),
   or export the file from the platform and set `nats.credentials_file` to
   its path.
4. **Set `nats.code` to the Thing's code.** The controller registers on NATS
   service discovery as `kiosk-controller` and puts this value in the metadata
   as `code`. With `nats.code` empty, it skips the registration.

The connection reconnects forever and keeps trying through auth errors.
nats.go reads the creds file again on each reconnect. So a file that
the platform rewrites after a Revoke reaches the controller without a restart.
A creds file copied by hand is fine for development, and a Revoke then means
copying the new one.

The controller needs NATS. With `nats.enabled: false`, `serve` stops with an
error. JetStream must be on for the account. On a NATS server you run
yourself, start it with `nats-server -js`.

::: note The role names the default resources
The `kiosk-controller` role grants the `kiosk` prefix, `KIOSK_EVENTS` and the
default bucket names. If you change one of these names
([NATS resources](#nats-resources)), change the role to match.
:::

### Build and first run

```bash
# Build
go build -o kiosk-controller ./cmd/controller

# Config
cp controller.yaml.example controller.yaml      # set nats.url and the creds

# First run: applies migrations, prints the bootstrap admin credentials once.
./kiosk-controller

# Or seed the catalog from CSV once, before you serve:
./kiosk-controller seed-catalog --items=items.csv --users=users.csv --groups=groups.csv
```

The controller reads `controller.yaml`, or the path in `KIOSK_CONFIG`.
[Seeding from CSV](#seeding-from-csv) describes `seed-catalog`.

### Migrations and data directory

The controller uses the same `migrations/` package as the kiosk node, plus
the controller-only package `migrations/controller/`. That package holds 17
migrations. They add the `kiosks` registry, `kiosk_items` membership, the two
audit projections, `instance_location`, `instance_epc_index` and the source
fields that the projections use as idempotency keys.

Each migration registers itself through `init()`, and
`cmd/controller/main.go` blank-imports both packages. The kiosk node binary
does not import `migrations/controller`, so its database never gets the
controller-only collections.

The controller's data directory is `pb_data_controller/`. So a kiosk node and
a controller can run from one working directory during development.

### NATS resources

The controller creates these on `serve`, and updates them if they exist.
`kiosk` is the configurable subject prefix (`nats.subject_prefix`).

| Resource | Default name | Settings | Used for |
| :--- | :--- | :--- | :--- |
| Stream | `KIOSK_EVENTS` (`nats.stream_name`) | Subjects `kiosk.*.evt.>`, limits retention, `MaxAge` 168 h, file storage, 1 replica | Every event the kiosk nodes publish |
| Durable consumer | `controller-aggregator` | `AckExplicitPolicy`, starts from the start of the stream | The projection (§4) |
| KV bucket | `KIOSK_CATALOG` (`controller.catalog_bucket`) | History 1 | The catalog: `items.{kiosk_code}.{item_code}`, `users.{user_code}` for the whole organization, `groups.{group_code}` |
| KV bucket | `KIOSK_STATE` | History 1 | Fleet state: `punch.{user_code}` (clocked in), `open.{user_code}` (fleet-wide open checkouts), `seen.{kiosk_code}.{instance_id}` (last sighting per unit) |

Each key's first token is its family ([Wire Protocol](protocol.md#kv-buckets)).
They were six buckets, one per family, until the controller's NATS role grew
too large for nats-server's default `max_control_line`. A failure to create
`KIOSK_STATE` is logged, and the controller continues without fleet state. To provision the main resources by hand, or to keep a record of them:

```bash
nats stream add KIOSK_EVENTS --subjects 'kiosk.*.evt.>' --retention limits --max-age 168h
nats kv add KIOSK_CATALOG --history 1
nats kv add KIOSK_STATE --history 1
```

The stream captures only the `evt` channel. Commands (`kiosk.*.cmd.>`) and
heartbeats (`kiosk.*.heartbeat`) use core NATS. They are outside the stream's
filter by construction, so the request and reply path never waits on a
JetStream PubAck. A new durable subject goes under `evt`, and the stream
captures it with no change. A subject for request and reply, or for
fire-and-forget publish, goes under `cmd` or a channel of its own.

The durable consumer acknowledges each event it processes. That ack moves the
cursor that survives a restart, apart from the stream-level PubAck.

The names above are defaults. On a shared NATS where `kiosk.>` or
`KIOSK_EVENTS` is already in use, set `nats.subject_prefix`,
`nats.stream_name` and the `controller.catalog_*_bucket` keys. The kiosk nodes
and the controller must use the same subject prefix. Only the controller reads
the stream name. Put your names into the commands above.

::: warning Run exactly one controller per stream
The durable consumer is named `controller-aggregator`, a constant in
[`internal/controller/consumer.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/controller/consumer.go). Two
`kiosk-controller` processes on the same `nats.stream_name` share that cursor,
and the projection writes become unpredictable. For redundancy, run the
controller under a supervisor that restarts it. A restart resumes from the
last acknowledged sequence and loses no events. For separate fleets, give each
one its own `nats.stream_name` and a matching `nats.subject_prefix`.
:::

A JetStream durable consumer has one owner by design. We do not want high
availability through duplicate controllers.

### Admin console

The controller serves its admin UI at the same paths as a kiosk node: `/_/`
for the PocketBase superuser and `/admin/login` for the kiosk admin. The
Kiosks list (`/admin/kiosks`) shows the fleet with online badges. Click a row
to open the detail page at `/admin/kiosks/{code}`. It has these tabs:

- **Overview.** Location, status and notes, which you can edit. The live
  online indicator and the last-transaction time. The maintenance buttons
  (§5).
- **Items.** The "Stocked items" membership panel (§3).
- **Inventory.** A live snapshot from the kiosk node through the
  `inventory.snapshot` command: on-hand, out, available, reorder threshold and
  a low-stock highlight. It shows the same detail as the kiosk node's own Items
  view.
- **Instances.** The serialized-unit roster from `instance.snapshot`, with a
  status per unit and an out-status column.
- **Readers.** The kiosk node's reader configuration, from `config.snapshot`.
- **Metrics.** The kiosk node's metrics, from `metrics.snapshot`.
- **Timeclock.** Shown when `timeclock.enabled` is true. It records a punch at
  the kiosk node through `timeclock.punch`.

On the Inventory tab, on-hand and the threshold come from the kiosk node. The
controller derives "out" from the projected ledger (`ReplayOpenRows`). The SPA
computes available and low-stock from those values with the shared
`ui/src/lib/inventory.ts` helper. Click the "Reorder ≤" value to set the
threshold. Each quantity-tracked row has an Adjust button that sends
`inventory.adjust`. A serialized row shows a "serialized" marker instead,
because its count is derived and you manage it on the Instances tab.

On the Instances tab, the out-status ("currently out" or "available") comes
from the same ledger replay. Create and edit map to their own commands.
Every lifecycle change goes through `instance.set_status` and needs a reason,
which goes into the audit log.

Use the Items view to add and edit items for the whole fleet. A user edit goes
to every managed kiosk node. An item edit goes only to the kiosk nodes that
stock the item, so assign SKUs first (§3). Each item's edit dialog shows a
"Stocked at" chip list, which is the inverse view of membership.

---

## 3. Catalog Down to Kiosk Nodes

The controller is the source of truth for `items` and `users`. The controller
**does not broadcast items**. Explicit `kiosk_items` membership rows on the
controller decide what each kiosk node stocks:

- A row exists: that kiosk node receives that item.
- No row: it does not.
- A new SKU goes nowhere until an admin adds it. Use the kiosk's "Stocked
  items" panel or the bulk-add-by-category action.

The `items` family of `KIOSK_CATALOG` uses keys `items.{kiosk_code}.{item_code}`.
Each kiosk node watches only its own prefix (`items.KIOSK01.>`), so the wire
never carries an item that the kiosk node must not see. Users stay
organization-wide in the `users` family.

### What crosses the wire

The payload follows one rule: **per-SKU policy syncs, per-site physical state
does not**. "What kind of thing is this, and how do we handle it" has the same
answer at every kiosk node. "How many are on this shelf" does not. So `type`,
`tracking_mode`, `category` and `requires_maintenance_on_return` cross the
wire. The quantities do not.

`reorder_threshold` reads like policy, but the alert fires against each kiosk
node's *own* available count. A busy main crib and a quiet cross-dock that
stock the same SKU want different levels. So the threshold stays local to the
kiosk node, and it has its own route in: the `inventory.set_threshold`
command. You reach it from
`POST /api/controller/kiosks/{code}/inventory/threshold`, or from the "Reorder
≤" value on the detail page's Inventory tab. It is the only way a managed
kiosk node receives a threshold. Without it, low-stock alerts cannot fire
anywhere in a managed fleet.

::: note Older KV entries lack `requires_maintenance_on_return`
Entries written by a build before this field was carried do not have it. The
publisher rewrites a key only when its item record is saved. Run **catalog
reconcile** once (`POST /api/kiosk/catalog/reconcile`, or the button in the
admin UI). It pushes every expected key again, not only the missing ones, so
the whole fleet gets the field in one pass. Until then, a managed kiosk node
reads the missing field as `false`, which is how it behaved before.
:::

### Assigning items to kiosk nodes

When the controller has items and kiosk records, decide which SKUs each kiosk
node stocks. The admin UI has two paths:

1. **The New kiosk button** on the Kiosks list pre-registers a kiosk record by
   `kiosk_code` and `location_code`, before the kiosk node connects. You need
   this to assign items on the first day of a deployment. After it creates the
   record, the SPA opens the new kiosk's detail page.
2. **The Items tab** on the detail page (`/admin/kiosks/{code}`):
   - **Add item.** Search the catalog and click an item to add it.
   - **Bulk add by category.** Pick a category, review the matching SKUs and
     confirm. The result is rows in `kiosk_items` and nothing more. There is
     no stored "category rule", so an item added to the catalog later does not
     reach this kiosk node. Click the button again to add new items.
   - **Remove.** This deletes the membership row. The kiosk node receives a KV
     delete on its key and deactivates the item locally. Its `item_instances`
     and its transaction history stay.

The **Stocked at** chip list on each item's edit dialog (controller only)
shows which kiosk nodes stock that SKU. It is read-only. Membership per kiosk
node is the source of truth.

### Seeding from CSV

`seed-catalog` reads up to three optional CSV files (`--items`, `--users`,
`--groups`). It shares its row validation with the HTTP importer at
`POST /api/kiosk/{kind}/import`. The column shapes, the automatic group
creation and the per-row errors are the same. The CLI writes one summary line
per kind and a log line for each bad row. The HTTP path returns JSON with an
outcome per row.

For daily catalog edits, use the SPA's **Admin → Import** view, which the
controller also serves. Use the CLI for a one-time bulk seed before the SPA is
reachable, or for scripted re-imports.

The full column schemas are in
[Schema → CSV import format](schema.md#9-csv-import-format). The CLI seeds
groups first, so a user row that names a group code finds the imported group
and does not create a minimal one.

On shared sites with more than one trade, set each worker's group. A foreman
can then return tools for other users **only within their own group**. A
foreman with no group cannot act for anyone. The full rules are in
[Returns policy](configuration.md#returns-policy).

`--no-publish` skips the KV publish. Use it for a first seed before the broker
is reachable. A later admin edit to a record publishes that record.

### Opting a kiosk node in

On each kiosk node that the controller manages:

```yaml
nats:
  enabled: true
  url: "nats://controller-host:4222"
  # ... matching creds

controller:
  enabled: true
  # catalog_bucket defaults to KIOSK_CATALOG; set it only if your
  # operator provisioned a different name
```

Restart the kiosk node. It then does these things:

1. It connects to NATS and watches its slice of the items bucket
   (`items.{kiosk_code}.>`) and the whole `users` family. It
   writes the snapshot into its local `items` and `users`, matched by `code`.
   An item without a membership row never arrives.
2. It publishes its transaction events as before. The controller's consumer
   receives them, and the kiosk node appears in the controller's `kiosks`
   registry if no one pre-registered it.
3. Its admin SPA hides the catalog edit controls. Every admin page shows the
   banner "Catalog managed by controller".

If `controller.enabled` is true but NATS is unreachable, the kiosk node still
starts. It serves checkouts from the catalog it has. The watcher logs a
warning and continues without sync until the broker returns. The local ledger
is always authoritative.

::: warning Upgrading from flat catalog keys
Earlier builds used flat keys (`{item_code}`) in `catalog_items` and sent
every SKU to every kiosk node. Membership publishing changes the shape and the
meaning of the keys. To upgrade, delete each kiosk node's `pb_data/`, then
assign items in the "Stocked items" panel. The controller now publishes into
`KIOSK_CATALOG`, so the old buckets are unused; remove them with
`nats kv rm`. The app is not in production yet, so there is no compatibility layer.
:::

### Reconciling catalog drift

The controller's PocketBase record hooks `Put` to the catalog buckets after
each save. If the broker is unreachable during a save, the database row
commits but the `Put` fails. The controller logs the failure at warn level and
continues. Over time, KV can drift from the controller's database. Two other
cases cause the same drift:

- A controller restored from an older backup is behind newer KV state.
- A new controller that points at an existing bucket gets whatever the bucket
  holds.

Two admin endpoints help.

**`GET /api/kiosk/catalog/integrity`** returns a read-only diff:

```json
{
  "items": {
    "bucket": "KIOSK_CATALOG.items",
    "expected_keys": 24,
    "actual_keys": 25,
    "missing_in_kv": [],
    "extra_in_kv": ["KIOSK-OLD.OBSOLETE-SKU"]
  },
  "users": { ... }
}
```

`missing_in_kv` lists database rows whose KV entries never arrived, so they
need a push. `extra_in_kv` lists KV keys with no database record behind them,
from a rollback or from an existing bucket.

**`POST /api/kiosk/catalog/reconcile`** pushes the database state to KV:

- Body `{"delete_orphans": false}`, the default, puts every expected key
  again. You can run it at any time. KV history is 1, so it is an idempotent
  overwrite.
- Body `{"delete_orphans": true}` also removes the `extra_in_kv` keys. Use it
  after a confirmed rollback, or when you adopt an existing bucket.

```bash
# Inspect first (read-only):
curl -H "Authorization: Bearer <admin-token>" \
  http://controller:8091/api/kiosk/catalog/integrity

# Push DB → KV without touching orphans (safe default):
curl -X POST -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" -d '{}' \
  http://controller:8091/api/kiosk/catalog/reconcile

# Push DB → KV and delete orphans (destructive, explicit):
curl -X POST -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"delete_orphans": true}' \
  http://controller:8091/api/kiosk/catalog/reconcile
```

The controller's database is always the source of truth. Reconcile goes in
one direction only, from the database to KV. There is no mode where KV
teaches the database. That mode would let an operator's `nats kv put`
override the controller's state, and we do not want that.

The controller **does not run reconcile at start**. An operator who uses
`nats kv put` to debug or to override must not lose the edit at the next
restart. After a rollback or a bucket adoption, run `reconcile` with
`delete_orphans: true`.

---

## 4. Events Up to the Controller

When NATS is on, every kiosk node publishes `kiosk.{code}.evt.transaction.complete`
and `kiosk.{code}.evt.item.{action}`. The `controller-aggregator` consumer reads
the `KIOSK_EVENTS` stream and projects each event into the controller's own
collections. [Ledger](ledger.md) explains the projection and its idempotency
keys in full.

### The ledger projection

The aggregator writes each event into `transactions` and `transaction_lines`.
The idempotency keys are `source_kiosk_code` with `source_transaction_id` on
transactions, and `source_line_id` on lines. So a redelivery is safe.

An admin close publishes only `evt.checkout.admin_close`, never
`transaction.complete` or `item.*`. So the aggregator projects it on its own.
`ProjectAdminCloseToLedger` writes the same rows that the kiosk node records:
one completed `transactions` row and one `admin_close` line. It is idempotent
on `source_transaction_id` and `source_line_id`. The controller computes
"what is out" by replaying `transaction_lines`, so the projected line removes
the holder's row. There is no separate `open_checkouts` change.

### Timeclock punches

When a managed kiosk node records a punch, it publishes
`kiosk.{code}.evt.timeclock.punch`. The aggregator then does two things:

1. It projects the punch into the controller's `time_punches`, idempotent on
   `source_punch_id`.
2. It writes the worker's merged state to the `punch` family, keyed by
   `user_code`. The write is monotonic on `occurred_at`.

Every kiosk node watches that family into an in-memory replica, so clocked-in
state covers the fleet. A worker can clock in at one kiosk node and clock out
at another.

The **timeclock terminal** (`cmd/timeclock`) is one more managed kiosk node
on this path. It authenticates workers, writes punches to its own ledger, and
uses the same projection and replica. So a phone punch appears across the
fleet, and the reverse is also true. Kiosk nodes are the only punch writers.
A punch by a controller admin is recorded *at* the target kiosk node, through
the `timeclock.punch` command.

### The fleet-wide clock-out gate

A second replica per user uses the same path. After the aggregator projects a
checkout, return or admin-close line, it computes that worker's open checkouts
across the fleet (`ReplayOpenRowsForUser`). It writes them to the
**`open`** family of `KIOSK_STATE`, keyed by `user_code`.

Managed kiosk nodes and the phone terminal watch this family. So a clock-out
at any kiosk node can stop for tools the worker has out at *other* kiosk
nodes, and name the building. The gate is advisory and **fails open**. A stale
or unreachable replica allows the clock-out, so the worker is never stuck. The
worker can also choose "clock out anyway" to acknowledge and continue. This
family is what gives the gate meaning on the phone terminal, which holds no
local checkouts.

### The kiosks registry

A kiosk node gets a row in the controller's `kiosks` collection in one of three
ways:

1. **Pre-registered.** An admin uses the "New kiosk" button on the Kiosks list.
   You need this to assign items before the kiosk node connects.
2. **Self-registered.** The aggregator sees a `transaction.complete` event from
   a `kiosk_code` it does not know.
3. **Registered by heartbeat.** The first heartbeat from a new kiosk node also
   creates the row. So a kiosk node with no transactions yet still appears.

All three give the same row, with `status=unknown`. Only `transaction.complete`
moves `last_transaction_at`. Live online status comes from the heartbeat map in
memory, not from the stored time.

### Heartbeats and online status

Each managed kiosk node publishes a small JSON beacon on
`kiosk.{kiosk_code}.heartbeat` every 45 s. It uses core NATS, not JetStream,
because a missed beat is the signal. The controller subscribes, keeps a
`map[code]time.Time` behind a mutex in memory, and serves it at
`GET /api/controller/kiosks/heartbeats`.

The SPA polls that route every 10 s and shows one of three badges:

| Badge | Last beat |
| :--- | :--- |
| **online** | Less than 90 s ago |
| **stale** | 90 s to 5 min ago |
| **offline** | More than 5 min ago |

For about 90 s after a controller restart, the SPA shows "unknown". This
stops it from painting the fleet red while the beats arrive.

### Audit projections

- **Inventory adjustments.** The aggregator projects every `inventory.adjust`
  event into `inventory_audit`, with copied fields: `kiosk_code`,
  `item_code`, `item_name`, `delta`, `prev_quantity`, `new_quantity`,
  `reason`, `source` and `admin_id`. A unique-when-non-empty
  `source_adjustment_id` index makes a JetStream redelivery a no-op. The
  Reports → Adjustment audit tab reads it. Operators can then see every stock
  change at every kiosk node, who made it and when, from one page.
- **Instance lifecycle.** The aggregator projects every `instance.lifecycle`
  event into `instance_lifecycle_audit`, with copied fields: `kiosk_code`,
  `item_code`, `instance_id`, `instance_code`, `action`, `prev_status`,
  `new_status`, `reason`, `source` and `admin_id`. A unique-when-non-empty
  `source_audit_id` index holds the kiosk-side `instance_audit.id` of the row
  that made the event. The Reports → Instance lifecycle tab reads it. A
  stand-alone kiosk node shows the same tab from its local `instance_audit`,
  so managed and unmanaged deployments have the same feature.

### Notifications

Managed kiosk nodes publish three notification subjects on the same stream:

| Subject | When |
| :--- | :--- |
| `receipt.transaction` | One per commit |
| `alert.lowstock` | One each time an item crosses its threshold |
| `alert.maintenance` | One per transaction that sends returned serialized units to maintenance, batched |

The aggregator gives each one to the controller's `notifications.Notifier`. It
renders with the controller's `notification_templates` rows for the fleet,
sends through the controller's PocketBase SMTP, and writes to the controller's
`notification_send_log`.

Scheduled digests do not use NATS in managed mode. The controller owns the
`scheduled_reports` rows and the scheduler. The kiosk node's scheduler stays
off.

- **Items in maintenance** (`digest.maintenance`) sends `instance.snapshot` to
  every online kiosk node, filtered to `status=maintenance`. It lists offline
  kiosk nodes as excluded.
- **Timeclock digests** need no fan-out, because the controller projects the
  whole punch ledger. `digest.timeclock` (one admin email) and
  `digest.timeclock_self` (one private email per active worker) read only the
  controller's `time_punches`. A worker's hours then include every kiosk node.

The CRUD endpoints (`/api/controller/notifications`) match the kiosk node's.
The SPA detects its role at start and points the Templates tab at the right
base URL. [Notifications](notifications.md) has the full picture.

### Sightings and reconciliation

The controller also runs a **plain** core NATS subscriber, `SightingIngest`,
apart from the durable consumer. Like the heartbeat registry, it reads a lossy
family: the `sighting` channel that external gateways publish to. For each
raw sighting, it does these things:

1. It resolves the sighting through `instance_epc_index`. The `rfid_epc` field
   on the `instance.lifecycle` projection feeds that index.
2. It upserts the fleet view `instance_location`.
3. It writes each unit's last sighting back to its kiosk node through the
   `seen` family of `KIOSK_STATE`, sliced per kiosk node like `items`.

A movement-not-reads filter drops a sighting that changes nothing before any
write. The result is the **custody-vs-location reconciliation** report
(`GET /api/controller/reconciliation` and the Reconciliation view). It joins
the replayed ledger with `instance_location` and flags `not_taken`, `stale`
and `unaccounted`. It is advisory only and never gates custody. See
[Location & Sightings](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md).

---

## 5. Commands to Kiosk Nodes

The controller sends an admin's action to the target kiosk node over core NATS
request and reply, on `kiosk.{kiosk_code}.cmd.{name}`. The kiosk node runs the
same business logic as its local HTTP path. It then publishes the same event as
a local action, and the aggregator projects it as usual. The payloads are in
[Wire Reference](protocol.md).

| Route on the controller | Command |
| :--- | :--- |
| `GET /api/controller/kiosks/{code}/inventory` | `inventory.snapshot` |
| `POST /api/controller/kiosks/{code}/inventory/adjust` | `inventory.adjust` |
| `POST /api/controller/kiosks/{code}/inventory/threshold` | `inventory.set_threshold` |
| `GET /api/controller/kiosks/{code}/instances` | `instance.snapshot` |
| `POST /api/controller/kiosks/{code}/instances` | `instance.create` |
| `PATCH /api/controller/kiosks/{code}/instances/{instance_code}` | `instance.edit` |
| `POST /api/controller/kiosks/{code}/instances/{instance_code}/status` | `instance.set_status` |
| `POST /api/controller/kiosks/{code}/checkouts/{source_line_id}/close` | `checkout.close` |
| `POST /api/controller/kiosks/{code}/integrity/rebuild` | `integrity.rebuild` |
| `POST /api/controller/kiosks/{code}/ledger/republish` | `ledger.republish` |
| `POST /api/controller/kiosks/{code}/timeclock/punch` | `timeclock.punch` |
| `POST /api/controller/kiosks/{code}/timeclock/republish` | `timeclock.republish` |
| `GET /api/controller/kiosks/{code}/config` | `config.snapshot` |
| `GET /api/controller/kiosks/{code}/metrics` | `metrics.snapshot` |

**Idempotency is on the server.** For a change, the controller generates a
UUID `command_id`. The kiosk node keeps it in a unique column, so a retried
command returns the earlier result and does not apply twice.

**An offline kiosk node fails fast.** When the kiosk node's heartbeat is
stale, the endpoint returns **503 `{error: "kiosk_offline", kiosk_code,
command_id}`** at once. The SPA then shows "offline" without a 5 s wait for a
NATS timeout.

### Inventory

`inventory.adjust` runs the kiosk node's `PerformStockAdjustment`, the same
function as the local HTTP path. It rejects serialized items, because their
quantity is the count of their non-retired instances. Manage those on the
Instances tab. The idempotency key is the unique `command_id` column on
`stock_adjustments`.

### Instances

The instance commands match the inventory family for serialized units:

- `instance.snapshot` reads the roster.
- `instance.create` adds a unit.
- `instance.edit` changes cosmetic fields only. It writes no audit row and no
  lifecycle event.
- `instance.set_status` handles every lifecycle change: send to maintenance,
  return to service, retire and un-retire. The target `status` (`in_service`,
  `maintenance` or `retired`) travels as data. The kiosk node derives the
  audit verb from the change. The body is `{status, reason}`.

A change writes to the kiosk node's `item_instances` and `instance_audit`. It
emits the same `instance.lifecycle` event as the local PocketBase-hook path.
The controller's `instance_lifecycle_audit` projection can tell where a change
started only from the `source` field (`local` or `controller`). The
idempotency key is the unique-when-non-empty `command_id` index on
`instance_audit`. The Instances tab on the detail page drives all four.

### Maintenance

Two operator tools repair or refill state on a remote kiosk node:

- **`integrity.rebuild`** deletes the kiosk node's `open_checkouts` and
  replays it from the ledger. Use it when you suspect drift.
- **`ledger.republish`** takes an optional `{from, to}` RFC 3339 window. It
  sends `transaction.complete` and `item.{action}` events again. The
  controller's projection has a unique index on `source_line_id`, so a
  duplicate changes nothing. Use it when events were lost, for example during
  a NATS outage while the kiosk node started.

Both use the same kiosk-side logic as the local
`/api/kiosk/integrity/rebuild` and `/api/kiosk/ledger/republish` endpoints.
So they behave the same as a kiosk admin who runs them at the touchscreen.
The buttons are on the Overview tab of the detail page.

### Admin force-close

`checkout.close` sends a force-close to a remote kiosk node. The kiosk-side
handler calls `commit.AdminClose`, so the close behaves the same as a local
one:

- It makes the same ledger writes.
- A `lost` or `damaged` close has the same quantity effect.
- It emits the same `instance.lifecycle` event (action `retire`) when a `lost`
  or `damaged` close retires a serialized unit.

The controller generates the `command_id`, so a retry is idempotent from end
to end. The kiosk node's unique-when-non-empty `transactions.command_id`
index catches a duplicate. §4 describes how the controller projects the
resulting `checkout.admin_close` event.

---

## 6. Reports

The controller's Reports view has these tabs:

| Tab | Source | Notes |
| :--- | :--- | :--- |
| Currently out | `GET /api/kiosk/reports/open-checkouts` | Online kiosk nodes answer from their own `open_checkouts` through `checkout.snapshot`. For an offline kiosk node, the controller replays the projected `transaction_lines`. Honors `?kiosk_code=`. Highlights rows held longer than a number of days you set. That threshold is a display hint, not a filter. A "Close…" control on each row uses the admin force-close route |
| Low stock | `GET /api/controller/reports/low-stock` (snapshot fan-out) | Lists offline kiosk nodes under `errors`, so a partial result is visible |
| Group activity | `transactions`, `transaction_lines` and `groups` through pb-sdk, rolled up in the SPA | Date range filter |
| Adjustment audit | `inventory_audit` through pb-sdk, paginated | Filters: from, to, source (local or controller). The kiosk filter comes from the page header |
| Instance lifecycle | `instance_lifecycle_audit` through pb-sdk, paginated | Filters: from, to, action (create, to_maintenance, return_to_service, retire, unretire), source. The kiosk filter comes from the page header. The same tab works on a stand-alone kiosk node from its local `instance_audit` |
| Notifications | `notification_send_log` through pb-sdk, rolled up in the SPA | Success rate per event and a recent-failures panel. The same tab works on a stand-alone kiosk node from its own send log |
| On the clock | `GET /api/controller/timeclock/now` | Shown when `timeclock.enabled` is true |
| Timesheets | `GET /api/controller/timeclock/history` | Shown when `timeclock.enabled` is true |

Recent transactions have their own Transactions view (`/admin/transactions`).
Click a transaction there to see its lines.

The controller **does not store an `open_checkouts` table**. Where it needs
the open set from its own data, it replays `transaction_lines` with
`ledger.ReplayOpenRows`. So its view converges with each kiosk node's by
construction.

Each tab has an **Export CSV** button that uses the filters on screen. The
server endpoints are `/api/kiosk/reports/{name}.csv`, or
`/api/controller/reports/{name}.csv` for the controller-only fleet reports.
[API reference](api.md) lists them all with their query parameters.

### The fleet low-stock report

`GET /api/controller/reports/low-stock` sends `inventory.snapshot` to every
online managed kiosk node in parallel. It joins each reply with `out` counts
from a replay of the projected `transaction_lines` (`ledger.ReplayOpenRows`).
It returns the rows where `available ≤ reorder_threshold`.

Offline kiosk nodes appear under `errors`. The SPA can then show "partial
result: N kiosks excluded" and does not hide the limit. The report honors
`?kiosk_code=`, so the kiosk filter on the page sends the fan-out to one
kiosk node only.

---

## 7. What It Does Not Do

These are out of scope in v1, on purpose:

- **Drift detection.** There is no state-hash compare between the controller
  and a kiosk node.
- **A stored `quantity_on_hand` per kiosk node.** The snapshot fan-out for the
  low-stock report runs live on each request. A stored `kiosk_inventory`
  rollup is on the roadmap, for when the fan-out round trip becomes the
  bottleneck. It would consume `inventory.adjust` deltas plus the quantity
  deltas of `item.checkout` and `item.consume`.
- **Moving serialized items between kiosk nodes.**
- **Stricter PocketBase collection rules on managed kiosk nodes.** The
  projector uses the DAO, so the rules do not apply to it. The UI controls
  what an admin sees.
- **More remote commands than §5 lists.** The dispatcher's `HandleFunc`
  registry makes a new command a change to one handler.

---

## 8. Where to Go Next

- The ledger model and the projection's idempotency keys: [Ledger](ledger.md)
- Every subject, command and payload: [Wire Reference](protocol.md)
- Every config key and default: [Configuration](configuration.md)
- Every HTTP route: [API reference](api.md)
- Templates, recipients and digests: [Notifications](notifications.md)
- Collections and the CSV formats: [Schema](schema.md)
- The Thing Types and NATS roles: [`contract/`](../contract/README.md)
