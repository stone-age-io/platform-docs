---
path: kiosk
nav_order: 55
access: public
---
# Tool and Consumable Checkout Kiosk

The kiosk is a self-service checkout station for tool cribs and consumable
storerooms. It is an application on the [Stone-Age.io](https://stone-age.io)
platform. A worker scans a badge at a touchscreen, scans items, confirms the
cart and walks away. One transaction holds checkouts, returns and consumable
use together. Each binary embeds PocketBase and serves a Vue 3 SPA from the
same process, so there is no separate API server or database to run. To
deploy a kiosk node, copy one file: `scp kiosk-app pi@kiosk:/opt/kiosk/`.

---

## Three Binaries

The system is three programs. They share code, but at run time they talk
only over NATS.

| | `kiosk-app` | `kiosk-controller` | `kiosk-timeclock` |
| :--- | :--- | :--- | :--- |
| **Built from** | `cmd/kiosk` | `cmd/controller` | `cmd/timeclock` |
| **Runs** | Once per kiosk node, on a mini-PC beside the touchscreen | Optional. Once per fleet, centrally | Optional. Where workers can reach it from their phones |
| **Is** | The kiosk node: the checkout flow, the admin UI and the local custody ledger | The fleet hub: catalog distribution, the central ledger, fleet reports and central email | The timeclock terminal: a self-service punch page |
| **Who signs in** | Admins. Workers scan a badge and do not sign in | Admins | Every worker, with OAuth2 SSO or a password |
| **Config** | `kiosk.yaml` | `controller.yaml` | `timeclock.yaml` |
| **Data** | `pb_data/` | `pb_data_controller/` | `pb_data_timeclock/` |
| **Page** | [Overview](docs/overview.md) | [Central Controller](docs/controller.md) | [Configuration](docs/configuration.md) and [Operations](docs/operations.md) |

Each kiosk node is the only authority over its own custody ledger. The
controller aggregates and distributes, and it owns nothing authoritative. A
kiosk node never waits on it. [Wire Protocol](docs/protocol.md) is the whole NATS
contract between the binaries.

---

## What It Does

- **Edge first.** Each kiosk node works alone. It needs no central server, and
  no internet for normal operation. An optional NATS publisher sends its events to a central consumer
  when one is reachable. A kiosk node is one binary of about 40 MB: Go,
  embedded PocketBase and SQLite, and the built Vue SPA.
- **Two kinds of user.** Workers identify with a badge scan and never sign in.
  Admins sign in with email and password to manage items, workers, imports and
  reports.
- **Append-only ledger.** A transaction does not change after commit. The
  `open_checkouts` table is a materialized view that the kiosk node can
  rebuild from the ledger. The admin Reports view shows an integrity diff and
  has a one-click rebuild. See [Ledger](docs/ledger.md).
- **Stock with an audit trail.** Items carry `quantity_on_hand` and
  `reorder_threshold`, and a consume decrements the count. An admin changes the
  count of a quantity-tracked tool or consumable through the `/adjust`
  endpoint, which writes a `stock_adjustments` row in the same transaction. A
  Low Stock report shows the items at or below their threshold.
- **Serialized units.** One `items` row is the SKU. One `item_instances` row
  is a physical unit, with its own barcode, printed serial and RFID tag. A
  return closes the exact unit that was scanned. A serialized SKU's
  `quantity_on_hand` is derived from its non-retired units, so `/adjust`
  rejects it. See [Schema](docs/schema.md).
- **Maintenance for serialized units.** Each unit has a `status`:
  `in_service`, `maintenance` or `retired`. A returned unit goes to
  maintenance by SKU policy (`requires_maintenance_on_return`) or by a
  per-return toggle that any worker can set. There it counts as on hand, but
  nobody can check it out until an admin returns it to service. Units retire
  reversibly and are never deleted. Entry to maintenance sends one email alert
  per transaction, and a scheduled "items in maintenance" digest is available.
- **Optional RFID.** A networked LLRP reader (Impinj R700 or similar) runs in
  one of two modes. `counter_scan` acts as a bulk barcode gun: the operator
  taps "RFID scan" and every tag read goes into the cart. `enclosure_diff`
  serves a smart cabinet over NATS. The kiosk node compares what is still
  inside with what left, and proposes the cart for the worker to confirm. See
  [RFID](docs/rfid.md).
- **Optional asset location (advisory).** RFID and BLE gateways around the
  site publish sightings onto NATS. They are external publishers, configured
  and run outside the platform. Each tracked unit gets a coarse "last seen"
  zone or a GPS position, and a custody read counts as a sighting too.
  Location is lossy, last-write-wins and never gates a checkout. It feeds
  reconciliation, such as "checked out to Bob but last seen in Cabinet A". See
  [Location & Sightings](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md).
- **Optional timeclock with tool interlocks.** Workers clock in and out at the
  kiosk against an append-only `time_punches` ledger. `timeclock_only: true`
  makes a device a dedicated punch station. Two interlocks tie the clock to
  the tool ledger: `require_clock_in_for_checkout` (returns are always allowed)
  and `block_clock_out_with_open_checkouts`. In managed mode a worker can clock
  in at one kiosk node and out at another, and the open-tools block covers the
  whole fleet. The raw-punch CSV export is the payroll contract. See
  [Configuration](docs/configuration.md).
- **Timeclock terminal.** `kiosk-timeclock` serves a punch page that workers
  open on their phones, with no badge scanner. Each worker signs in, and the
  server reads the identity from the session, never from the request. The
  binary has only the authenticated `/api/self/timeclock/*` surface. See
  [Timeclock Terminal](#timeclock-terminal).
- **Several terminals on one kiosk node.** One process can drive several
  touchscreens on an isolated LAN, with one SQLite database and one inventory.
  Each terminal's browser adds `?terminal=` to the URL, and the commit stamps
  that value on `transactions.terminal_id`. The value is descriptive only and
  never an auth boundary. A kiosk node with more than one RFID reader also
  adds `?reader={reader_id}` per screen. One screen with one reader needs
  neither parameter.
- **Ready for a fleet.** Every transaction carries `kiosk_code` and
  `location_code`, and optionally `terminal_id` and `enclosure_id`. Every state
  change goes through `events.Publish`, which always logs through slog. When
  NATS is enabled, it also publishes to NATS, with no change for the caller.
- **Optional central controller.** `kiosk-controller` aggregates the
  transaction events of each kiosk node into its own ledger through a
  JetStream durable consumer. It pushes the catalog to managed kiosk nodes
  through JetStream KV, with membership deciding which items each node gets.
  It sends admin commands over core NATS request and reply, and tracks online
  status from 45 s heartbeats. It sends all email from one SMTP account, with
  one audit trail. See
  [Central Controller](docs/controller.md) and
  [Notifications](docs/notifications.md).
- **Fleet-wide reports.** The controller's Reports view has seven tabs:
  currently out, aging, low stock, group activity, recent transactions,
  adjustment audit and notification deliverability. A standalone kiosk node
  has the same view over its local data, without the controller-only tabs.
  Every tab has a server-side Export CSV that respects the filters on screen.

---

## Architecture

```text
┌─────────────────────────────────────────────────┐
│              Mini-PC / Touchscreen              │
│                                                 │
│   Chromium --kiosk  →  http://localhost:8090    │
│                       ↕                         │
│         kiosk-app (Go binary)                   │
│         ├── PocketBase (REST API, hooks, /_/)   │
│         ├── /api/kiosk/* custom routes          │
│         └── Vue SPA (embedded via //go:embed)   │
│                                                 │
│              ↑                                  │
│      USB Barcode Scanner (HID keyboard)         │
└─────────────────────────────────────────────────┘
```

The barcode scanner is a USB HID keyboard. A window-level listener in the
browser buffers the keystrokes and dispatches on Enter. The same path reads
badge QR codes and item barcodes. When a configured prefix matches, the prefix
decides the type. Otherwise the resolver tries these lookups in order:

1. Instance code
2. Item code
3. Instance RFID EPC
4. Instance BLE id
5. User code

EPCs and beacon ids belong to one tag each. So they live on `item_instances`
(`rfid_epc`, `ble_id`) and never on the SKU.

---

## Tech Stack

| Layer | Choice |
| :--- | :--- |
| Server | Go 1.27, one binary per program |
| Database | PocketBase 0.41 + SQLite (file at `pb_data/data.db`) |
| Migrations | Schema as code in Go (`migrations/*.go`), applied at startup |
| Config | YAML + `KIOSK_*` environment overrides |
| Frontend | Vue 3 (Composition API, `<script setup>`) + TypeScript |
| State | Pinia |
| Routing | Vue Router |
| Styling | Tailwind 4 |
| Headless components | Reka UI (accessibility primitives) |
| Maps | Leaflet + MapLibre GL |
| Build | Vite 8 → `internal/ui/dist/` → `//go:embed` into each binary |
| API client | PocketBase JS SDK 0.27 (admin CRUD), plain `fetch` (kiosk flow) |
| Messaging | NATS JetStream (optional): durable streams for event aggregation, KV buckets for catalog distribution |
| RFID | LLRP through `edgexfoundry/device-rfid-llrp-go` (optional) |

---

## Layout

```text
kiosk/
├── cmd/
│   ├── kiosk/              Kiosk node: PocketBase bootstrap, config, NATS, routes, watchers
│   ├── controller/         Controller: PocketBase bootstrap, JetStream consumer, KV publisher
│   └── timeclock/          Timeclock terminal: the authenticated self-service punch surface only
├── internal/
│   ├── cart/               In-memory cart store
│   ├── cartevents/         "This cart changed" broker for SSE subscribers
│   ├── catalog/            Catalog wire shape, kiosk-side KV watcher and projector
│   ├── commands/           Kiosk-side handlers for controller commands over NATS
│   ├── commit/             Cart-to-transaction orchestrator
│   ├── config/             YAML loader and env overrides, shared by every binary
│   ├── controller/         Aggregator, catalog publisher, membership, heartbeat registry, inventory commands
│   ├── csvimport/          Row validation and diff for the CSV imports, shared by kiosk and controller
│   ├── dberr/              Small shared helpers: IsNotFound, IsUniqueViolation
│   ├── demoseed/           The Northwind Traders demo estate
│   ├── events/             Publish(), the NATS publisher, JetStream and connection accessors
│   ├── exports/            CSV writers for items and transactions
│   ├── handlers/           HTTP handlers for /api/kiosk/* and /api/self/timeclock/*
│   ├── heartbeat/          Kiosk-side heartbeat goroutine
│   ├── instances/          item_instances hooks: audit rows and lifecycle events
│   ├── kioskctx/           Process-global kiosk identity
│   ├── ledger/             Ledger replay for integrity checks and rebuilds
│   ├── metrics/            Point-in-time operational snapshot of one kiosk node
│   ├── notifications/      Transactional email rendering and dispatch
│   ├── readiness/          GET /api/ready for each binary
│   ├── reconcile/          Custody-vs-location discrepancies
│   ├── rfid/               LLRP reader wrapper
│   ├── scan/               Scan resolver
│   ├── scheduler/          Scheduled reports on PocketBase's cron
│   ├── sightings/          Advisory "last observed" state for serialized units
│   ├── timeclock/          The punch funnel and derived clocked-in state
│   └── ui/                 //go:embed seam: dist/ holds the Vite output
├── migrations/             Schema as code, applied at startup
│   ├── controller/         Controller-only collections
│   └── timeclock/          Timeclock terminal only: worker auth on the users collection
├── contract/               Thing Types, operations and NATS roles for the platform
├── ui/                     Vue 3 SPA source (Vite project)
├── branding/               Optional on-disk branding overrides, next to the binary, not embedded
├── demo/                   Demo config
├── kiosk.yaml.example      Kiosk node config template
├── controller.yaml.example Controller config template
└── timeclock.yaml.example  Timeclock terminal config template
```

`pb_data/`, `pb_data_controller/`, `pb_data_timeclock/`, `internal/ui/dist/`
and the `*.yaml` config files are gitignored. Each binary creates its data
directory on first run.

---

## Build and Run

You must build the SPA before the Go binary. `//go:embed` fails on an empty
`internal/ui/dist/`.

```bash
go mod download
npm install --prefix ui
npm run build --prefix ui           # writes internal/ui/dist/
go build -o kiosk-app ./cmd/kiosk   # Windows: go build -o kiosk-app.exe ./cmd/kiosk
cp kiosk.yaml.example kiosk.yaml    # edit kiosk.code and location_code
./kiosk-app                         # Windows: .\kiosk-app.exe
```

On first boot the migration creates all collections and one bootstrap admin.
The binary prints the credentials to stdout **once**:

```text
================================================================
 BOOTSTRAP ADMIN CREDENTIALS — shown once, save them now
----------------------------------------------------------------
   email:    admin@kiosk.local
   password: <16-char base64 string>
----------------------------------------------------------------
 Sign in at /admin/login. Recovery: PB superuser UI at /_/.
================================================================
```

::: note Save the password
If you lose it, reset it in the PocketBase superuser UI at
`http://localhost:8090/_/`. The first visit asks you to create a superuser.
:::

Open `http://localhost:8090/`. It shows the checkout flow ("Scan your badge to
begin"). The small **Admin** link at the top right opens `/admin/login`.

The controller builds the same way, with `go build -o kiosk-controller
./cmd/controller`, and reads `controller.yaml`. See
[Central Controller](docs/controller.md). Dev loops, database reset and tests
are in [Development](docs/development.md).

### Timeclock Terminal

`kiosk-timeclock` shares the timeclock code of a kiosk node: the
`timeclock.PerformPunch` funnel, the `time_punches` ledger, the `punch`
replica and the payroll CSV. It uses the same SPA build. Then:

```bash
go build -o kiosk-timeclock ./cmd/timeclock   # Windows: kiosk-timeclock.exe
cp timeclock.yaml.example timeclock.yaml      # edit kiosk.code, auth, mode
KIOSK_CONFIG=timeclock.yaml ./kiosk-timeclock
```

It is a separate binary because the kiosk's `/api/kiosk/*` surface is
anonymous by design. Those handlers trust the `user_code` in the request body,
so auth in front of them secures nothing. The timeclock binary registers only
the authenticated `/api/self/timeclock/*` surface, identity and branding, and
an admin user import. The checkout, cart and inventory routes do not exist in
it, so a config error cannot expose them.

It supports the same three modes as a kiosk node: standalone, standalone with
NATS events, and controller-managed. In managed mode a worker who clocked in at
a kiosk node can clock out from a phone.

- [Configuration](docs/configuration.md): the `timeclock.yaml` keys and the
  three modes.
- [Operations](docs/operations.md): OAuth2 SSO, password reset through SMTP,
  worker provisioning, and hardening for a public host.

::: warning This is the binary you expose to the internet
Terminate TLS in front of it, restrict the superuser UI (`/_/`) and enable
PocketBase's auth rate limiter. Never expose `kiosk-app` this way.
:::

---

## Onboarding an Organization

[`contract/`](https://github.com/stone-age-io/kiosk/blob/main/contract) holds what an organization needs on the platform:
the Thing Types for kiosk nodes, timeclock terminals and the controller, their
operations, and a NATS role for each. As an owner or admin of the
organization, run:

```bash
stone apply --template contract/
```

You can run it again. A new run moves the organization to a newer contract.

---

## Releases

A pushed `v*` tag runs [the release workflow](https://github.com/stone-age-io/kiosk/blob/main/.github/workflows/release.yml).
goreleaser builds the SPA. Then it cross-compiles `kiosk-app`,
`kiosk-controller` and `kiosk-timeclock`, one archive per binary, for these
targets:

- Linux and macOS on amd64 and arm64
- Windows on amd64 (there is no Windows arm64 build)

The release body is the tag's section of [CHANGELOG.md](https://github.com/stone-age-io/kiosk/blob/main/CHANGELOG.md).
[`scripts/release-notes.sh`](https://github.com/stone-age-io/kiosk/blob/main/scripts/release-notes.sh) builds it and refuses an
empty section. So before you tag, change `## [Unreleased]` to
`## [X.Y.Z] - date`. A tag with a suffix (`v0.2.0-rc1`) reads `[Unreleased]`
and publishes as a prerelease.

---

## Documentation

- **[Overview](docs/overview.md)**: custody and location, the mental model, how
  the three binaries fit together and how a deployment grows. Start here.
- **[Configuration](docs/configuration.md)**: the YAML and environment
  variables, the timeclock, branding and custom CSS.
- **[Development](docs/development.md)**: dev loops, database reset and the
  test suite.
- **[API Reference](docs/api.md)**: custom endpoints and collection rules.
- **[Wire Protocol](docs/protocol.md)**: every NATS subject (events, commands,
  heartbeats, sightings) with its payload and reply shapes.
- **[Schema](docs/schema.md)**: collections, cardinality rules and the CSV
  import format.
- **[Ledger](docs/ledger.md)**: the append-only design and drift recovery.
- **[Operations](docs/operations.md)**: deployment, backups, ledger integrity,
  NATS failure modes, stock adjustments, instances, the timeclock terminal and
  password reset.
- **[Troubleshooting](docs/troubleshooting.md)**: common errors and their
  fixes.
- **[Central Controller](docs/controller.md)**: deployments with more than one
  kiosk node.
- **[Notifications](docs/notifications.md)**: receipts, low-stock alerts and
  scheduled digests.
- **[RFID](docs/rfid.md)**: the `counter_scan` and `enclosure_diff` modes, the
  LLRP reader and the SSE cart-events channel.
- **[Location & Sightings](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md)**: advisory asset
  location from external gateways, the `sighting` family, and reconciliation.
- **[Shipped & Roadmap](docs/roadmap.md)**: what is live and what is deferred.
