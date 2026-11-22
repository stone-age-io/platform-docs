---
path: kiosk/development
nav_order: 120
---
# Development

This page covers the prerequisites, the backend and frontend dev loops, the
database reset and the test suite. The first build and run are in the
repository's [README](../README.md#build-and-run). Common errors are in
[Troubleshooting](troubleshooting.md).

---

## 1. Prerequisites

- **Go 1.27 or later.** PocketBase 0.41 requires it. Import PocketBase from
  `ganigeorgiev.com/pocketbase`, never from the archived
  `github.com/pocketbase`.
- **Node 20.19+ or 22.12+, with npm.** Vite 8 requires one of these versions.
  The build is tested on Node 25.
- **A USB HID barcode scanner** in production. Any model that emulates a
  keyboard works: Honeywell, Zebra, a generic Chinese OEM. For development,
  your keyboard is sufficient.

---

## 2. Backend Dev Loop

After a Go change, build and run the kiosk node:

```bash
go build -o kiosk-app ./cmd/kiosk   # Windows: go build -o kiosk-app.exe ./cmd/kiosk
./kiosk-app                         # Windows: .\kiosk-app.exe
```

The optional binaries build the same way:

- `go build ./cmd/controller`: the controller.
- `go build ./cmd/timeclock`: the timeclock terminal.

Each binary has its own config and data directory, so all three can run from
one checkout at the same time:

| Binary | Config | Data directory |
| :--- | :--- | :--- |
| `cmd/kiosk` | `kiosk.yaml` | `pb_data/` |
| `cmd/controller` | `controller.yaml` | `pb_data_controller/` |
| `cmd/timeclock` | `timeclock.yaml` | `pb_data_timeclock/` |

The binary applies new migrations at startup. PocketBase records them in its
`_migrations` table, so a second start of the same binary changes nothing.

---

## 3. Frontend Dev Loop

For hot reload of SPA changes, run the Vite dev server next to the Go binary:

```bash
# Terminal 1
./kiosk-app

# Terminal 2
npm run dev --prefix ui             # opens http://localhost:5173
```

The Vite config proxies `/api` and `/_` to `http://127.0.0.1:8090`. So the dev
server sends every dynamic request to your local Go binary.

For a production SPA bundle, run the npm build and then `go build` again.
Vite writes to `internal/ui/dist/`. At compile time, `internal/ui/embed.go`
puts that directory into each binary with `//go:embed`:

```bash
npm run build --prefix ui           # writes internal/ui/dist/
go build -o kiosk-app ./cmd/kiosk   # embeds the dist/ bundle
```

---

## 4. Resetting the Database

::: warning This deletes all local data
`pb_data/` holds the whole state of the kiosk node.
:::

```bash
rm -rf pb_data                      # Windows: Remove-Item -Recurse -Force pb_data
./kiosk-app                         # runs the migrations again and seeds a new bootstrap admin
```

---

## 5. Testing

```bash
go test ./...
```

The frontend has no test suite. `vue-tsc` checks the SPA during
`npm run build`.

### 5.1 Tested Packages

- **`internal/scan`.** Table-driven tests of the resolver's dispatch order,
  with instance lookups before item lookups.
- **`internal/cart`.** The in-memory store: stacking rules, quantity and action
  updates, expiry and line removal.
- **`internal/commit`.** The center of the system. Each integration test
  starts a fresh PocketBase app with `pocketbase.NewWithConfig` and
  `core.NewMigrationsRunner`. Then it exercises the state machine:
  - checkout, with one row per unit for quantity N
  - return, correlated and uncorrelated
  - cross-user return
  - consume, with the `quantity_on_hand` decrement and negative values allowed
  - a mixed cart, and rollback on error
  - serialized constraints and per-instance return targeting
  - the policy flags: rejection of cross-user and uncorrelated returns
  - admin force-close: the lost or damaged quantity for quantity items, and
    the serialized variant (retire only, no `stock_adjustments` row, two
    events)
- **`internal/handlers`.** The stock-adjustment transaction:
  - delta and absolute modes, with the audit row written
  - an empty reason rejected, and an item not found
  - a controller source writes `controller_admin_id`
  - a replay with the same `command_id` returns the earlier result and does
    not apply it again
  - a serialized item rejected, with no row written and the quantity
    unchanged

  It also tests the self-service punch endpoints of the timeclock terminal:
  - anonymous → 401, a token not from `users` → 403, an inactive worker → 403
  - the trust rule: a punch lands on the signed-in worker, even when the body
    carries a different `user_code`
  - the worker-auth migration that only `cmd/timeclock` runs (`AuthRule` and
    OAuth2 enabled)
- **`internal/timeclock`.** The punch funnel:
  - per-source rules: self and foreman alternation with an active target, and
    admin backdate or force with a reason
  - the open-checkouts block, with the fleet-wide merge. A `CheckoutFleet` row
    at another kiosk node blocks. A replica row tagged with this kiosk node
    does not block twice. `force` and acknowledge bypass it. A nil fleet falls
    back to local only.
  - idempotent replay by `command_id`

  It also tests the `CurrentState` merge rule: the local ledger against the
  fleet `punch_state` replica, with the own-echo guard. And it tests `Pair`,
  the interval and day-total pairing for display only.
- **`internal/instances`.** The audit and lifecycle hooks, and the recompute of
  the derived `quantity_on_hand`:
  - create, to_maintenance, return_to_service, retire and unretire track the
    count of non-retired instances (in service plus maintenance, retired
    excluded)
  - non-serialized items are never touched
  - an idempotent command replay does not count twice
  - a cascade delete of the parent item is safe
- **`internal/events`.** `Publish()` calls the installed publisher, and a nil
  publisher does nothing. A manual smoke test covers the NATS path.
- **`internal/commands`.** The kiosk command dispatcher:
  - `inventory.adjust`: the normal path, every validation guard (missing
    fields, unknown item, bad mode, serialized item rejected) and idempotent
    replay
  - `inventory.snapshot`: all items, and a filter by codes
  - routing by subject suffix
- **`internal/catalog`.** The payload round trip, with assertions that banned
  fields are absent. The watcher's `upsertItem` and `upsertUser` against a real
  PocketBase database, which checks that the local `quantity_on_hand` of a
  kiosk node survives a catalog update. A soft delete sets `active=false`, and
  is idempotent for unknown codes.
- **`internal/controller`.**
  - Idempotent projection of transactions and lines under redelivery.
  - "Parent not here yet" causes a retry. An unknown user or item is skipped
    and acknowledged.
  - `TouchKiosk` registers a kiosk node at first sight, and advances
    `last_transaction_at` on each later `transaction.complete` event.
  - The membership helpers `KiosksForItem` and `ItemsForKiosk`, and cascade
    delete on `kiosk_items`.
  - The heartbeat registry: record and snapshot, the `IsLikelyOnline`
    thresholds, registration at the first beat (once) and tolerance of a
    malformed payload.
