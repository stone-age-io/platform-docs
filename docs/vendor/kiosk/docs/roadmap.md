---
path: kiosk/roadmap
nav_order: 130
---
# Shipped & Roadmap

This page is the status of the kiosk. It lists what has shipped since v1, and
what we deferred on purpose, each with its reason. The [CHANGELOG](https://github.com/stone-age-io/kiosk/blob/main/CHANGELOG.md)
has the history of each release. For how the pieces fit together, see
[Overview](overview.md).

---

## 1. Shipped

Each item below started as a deferred roadmap item and is now in the binary.

### Ledger and stock

- **Stock tracking with an audit log.** `items.quantity_on_hand` and
  `reorder_threshold`, an automatic decrement on `consume`, a low-stock report,
  and the `/items/{id}/adjust` endpoint with the `stock_adjustments` audit
  table.
- **Returns policy.** The commit hook honors `allow_cross_user` and
  `allow_uncorrelated`, and rolls back the transaction when a flag is `false`.
- **Ledger rebuild.** An admin button and the `/integrity/rebuild` endpoint
  repopulate `open_checkouts` from the ledger.
- **Admin force-close.** An admin closes a stale `open_checkouts` row as lost,
  damaged or returned offline, without bypassing the ledger
  (`action="admin_close"`, `closure_reason`). `lost` and `damaged` reduce the
  inventory in the same transaction. The local endpoint and the controller's
  `checkout.close` command both run `commit.AdminClose`.
- **Worker self-service.** The `/api/kiosk/scan` response includes the
  scanned worker's open checkouts. `CheckoutView` shows them in a "What you have
  out" panel.
- **Explicit foreman returns.** A scan of another worker's tool defaults to
  checkout. A foreman uses the "Return on behalf of…" dialog for a cross-user
  return. The commit-time foreman and same-group check stays the trust
  boundary.

### Serialized units

- **Per-instance tracking.** The `item_instances` collection, scan-resolver
  precedence, per-instance returns and the admin Instances panel.
- **Maintenance workflow.** A 3-state `status` (`in_service`, `maintenance`,
  `retired`) replaced `item_instances.active`. Nothing hard-deletes a unit. A
  return can route a unit into maintenance in three ways: the SKU flag, a
  per-line toggle, or an admin action. The single `instance.set_status`
  command and endpoint cover every change.
- **Lifecycle audit.** Each kiosk node writes `instance_audit` from record
  hooks and publishes `instance.lifecycle` events. The controller projects them
  into `instance_lifecycle_audit`, idempotent on `source_audit_id`.

### Controller and fleet

- **Central controller.** The `cmd/controller` binary aggregates each kiosk
  node's transactions into a central ledger through a JetStream durable
  consumer. It publishes item and worker catalog changes to managed nodes
  through JetStream KV. See [Central Controller](controller.md).
- **Per-kiosk catalog membership.** The `kiosk_items` collection, KV keys of
  the form `{kiosk_code}.{item_code}`, and a prefix-filtered watch on each kiosk
  node. An admin can register a kiosk node before it first connects.
- **NATS publishing.** `events.Publish` also publishes to NATS when
  `nats.enabled` is `true`. It supports all `nats.go` auth modes. An
  unreachable server does not stop a kiosk node from booting.
- **Command bus.** Core NATS request and reply on
  `kiosk.{code}.cmd.{name}`, where `kiosk` is the configurable prefix. It
  started with `inventory.adjust` and `inventory.snapshot`. It now also carries
  `checkout.close`, the `instance.*` family, `integrity.rebuild`,
  `ledger.republish`, and the RFID `cart.start` and `read.trigger` pair. See
  [Wire Protocol](protocol.md).
- **Heartbeat and online status.** Each kiosk node publishes a heartbeat every
  45 s on `kiosk.{code}.heartbeat`. The controller serves
  `GET /api/controller/kiosks/heartbeats`, and its SPA polls it every 10 s. A
  controller endpoint returns `503` at once when a node's heartbeat is stale.
- **Kiosk detail page.** `/admin/kiosks/{code}` on the controller groups the
  per-kiosk work in tabs, behind one deep link.
- **`kiosks.last_transaction_at`.** It records when the kiosk node last made a
  transaction. Only `transaction.complete` events update it. Liveness comes
  from the heartbeat.
- **Fleet-wide low-stock report.** `GET /api/controller/reports/low-stock`
  sends `inventory.snapshot` to every online managed node in parallel. Offline
  nodes show in an `errors` block, so the SPA can mark a partial result.
- **Inventory adjustment audit.** The controller projects every
  `inventory.adjust` event into `inventory_audit`, idempotent on
  `source_adjustment_id`. A Reports tab shows the history for the whole fleet.

### Notifications

- **Notification system.** Admin-edited templates
  (`notification_templates`), recipients specs, a daily duplicate gate
  (`notification_dedupe`), and a send log with one row per recipient
  (`notification_send_log`), pruned at 90 days. `scheduled_reports` rows drive
  the digest cron. See [Notifications](notifications.md).
- **Central notifications in managed mode.** A managed kiosk node publishes
  structured contexts. The controller renders and sends them with fleet-wide
  templates and its own SMTP. One set of SMTP credentials, one audit trail.
- **Scheduled reports on the controller.** In managed mode the controller runs
  the cron, the computation and the SMTP send. A `kiosk_code` on each row
  scopes a report to one kiosk node, and empty means fleet-wide.
- **Deliverability tab.** A Reports tab on both binaries summarizes the local
  `notification_send_log`: totals, success rate per event type, and recent
  failures.

### RFID and location

- **RFID (Impinj R700, LLRP).** Two modes share one LLRP client in
  `internal/rfid`. `counter_scan` runs an operator-driven inventory cycle of
  3 to 5 s. `enclosure_diff` is driven by NATS `cart.start` and `read.trigger`.
  Every read publishes `evt.scan.rfid.observed`. An SSE channel tells the SPA
  to refetch after each cart write. See [RFID](rfid.md).
- **Asset-tracker foundation.** Merged to `main`. It splits
  `transactions.door_id` into `terminal_id` and `enclosure_id`. It adds a
  per-node reader map with a mode per reader, and `enclosure_diff` reads
  partitioned per cabinet. It also adds the read-only `config.snapshot`
  command and `counter_scan` reader selection by `?reader=`. All of it is
  additive, and a single-reader node does not see it. Its north star is the
  on-site **smart cache** container. See the
  [asset-tracker plan](https://github.com/stone-age-io/kiosk/blob/main/docs/asset-tracker-plan.md).
- **Location and sightings (L1 to L4).** Merged to `main`. External RFID and
  BLE gateways publish raw sightings on the lossy `sighting` channel, outside
  the durable stream. Custody reads also count as sightings. The payoff is the
  custody-vs-location reconciliation (`not_taken`, `stale`, `unaccounted`), as
  an endpoint, an admin view and the `digest.reconciliation` email. See the
  [location & sightings plan](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md).

### Timeclock

- **Timeclock with tool interlocks.** An append-only `time_punches` ledger,
  written only through `timeclock.PerformPunch`. Two config-gated interlocks
  tie it to the tool ledger. In managed mode, the `punch_state` KV bucket lets
  a worker clock in at one kiosk node and out at another. The raw-punch CSV is
  the payroll contract, with no rounding or overtime anywhere.
  `timeclock_only` makes a device a dedicated punch station.
- **Timeclock digests.** `digest.timeclock` emails the daily totals to admins.
  `digest.timeclock_self` sends each active worker a private timesheet.
- **Timeclock terminal.** The `cmd/timeclock` binary serves a public punch page
  with per-user authentication (OAuth2 SSO, password, or both). It registers
  only `/api/self/timeclock/*`, and OAuth2 is match-only. It supports the same
  three modes as a kiosk node. The punch panel shows each worker today's and
  this week's totals. See
  [Configuration Reference](configuration.md#timeclock-terminal-timeclockyaml)
  and [Operations](operations.md#9-timeclock-terminal).
- **Fleet-wide clock-out block.** In managed mode,
  `block_clock_out_with_open_checkouts` sees tools out anywhere in the fleet.
  The controller writes a per-user replica (`open_checkouts_state` KV) from
  `ledger.ReplayOpenRowsForUser`. The punch path reads the broadcast replica,
  so it has no synchronous WAN dependency. It is fail-open, and a worker can
  "clock out anyway".

---

## 2. Deferred

The schema and the subjects are in place, so each item below can be added
without a rewrite. We evaluate each one on demand. None of them gets built
until a concrete user asks for it.

- **Controller-side quantity projection.** A `kiosk_inventory` rollup would
  make the low-stock report O(1) and cover offline nodes. Deferred because the
  live fan-out is fine into the dozens of kiosk nodes, until its round trips
  hurt.
- **More remote commands**, such as a forced catalog resync, or locking a
  kiosk node to a holding screen. The command bus is in place, and each one is
  a kiosk handler plus a controller endpoint. Deferred until a user needs one.
- **Drift detection.** A periodic state-hash compare between the controller
  and each kiosk node, shown in the controller admin UI. Deferred because an
  operator can compare aggregate counts by hand today
  ([Operations §5](operations.md#5-nats-failure-modes)).
- **Cross-fleet movement of serialized units.** Move one `item_instances` row
  from kiosk node A to node B, with the controller as the arbiter. One serial
  belongs to one kiosk node at a time. Deferred until a user asks for it.
- **Locked collection rules in managed mode.** Deferred because UI gating is
  the v1 answer. Locked rules would also stop an admin who edits PocketBase
  directly.
- **Cross-building returns.** Return a serialized unit at a building other
  than the one where it was checked out. Deferred because the instance row
  would have to move between databases, which is a separate, harder problem.
- **Controller-side fleet BLE.** Deferred because standalone BLE already
  works. See the [location & sightings plan](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md).
- **The GPS-polygon theft flag.** Deferred because it needs site-polygon
  config. See the [location & sightings plan](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md).
