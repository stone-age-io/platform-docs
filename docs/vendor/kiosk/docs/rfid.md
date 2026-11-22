---
path: kiosk/rfid
nav_order: 100
---
# RFID

This page covers how the kiosk node reads RFID tags. It describes the two input surfaces,
the two reader modes, the LLRP reader setup, the NATS commands and the SSE
channel. It assumes you know the collections in
[Schema](schema.md) and the architecture overview in the repo's `CLAUDE.md`.
For every subject and payload on the wire, see [Wire Protocol](protocol.md). For
the rest of `kiosk.yaml`, see [Configuration](configuration.md).

---

## 1. Two Input Surfaces

RFID at the kiosk is **serialized-only by construction**. A tag carries a
unique identity. If every unit has a tag, every unit is distinguishable, and
that is what serialized means. One tag is one `item_instances` row, matched on
the `rfid_epc` field. Consumables and quantity-tracked tools never take part
in RFID flows.

EPC matching **ignores case in effect**:

- The model hooks in [`internal/instances/hooks.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/instances/hooks.go)
  store `item_instances.rfid_epc` as trimmed, lower-case hex on every write.
  They cover the admin SPA's PocketBase writes and the controller command bus.
- [`migrations/1792000000_lowercase_rfid_epc.go`](https://github.com/stone-age-io/kiosk/blob/main/migrations/1792000000_lowercase_rfid_epc.go)
  backfills older rows.
- The LLRP reader emits lower-case hex.
- Both match paths (`scanInstanceByRFID` in `internal/handlers/scan.go`, and
  `expectedInstanceStates`) also fold case.

So a tag registered in any case resolves against an observed read.

There are two RFID input surfaces. We keep them separate on purpose:

| Surface | How it reaches the kiosk node | Role |
| :--- | :--- | :--- |
| **USB HID badge reader** | A card scan emits keyboard events, like a barcode gun. The SPA's window-level scan composable receives them, and `scan.Resolver` resolves them against a user `code` or an instance `rfid_epc`. | The cart-start input. Nothing new at this layer: buy the right reader and register the card's internal ID in PocketBase. |
| **Networked Impinj R700** (or another LLRP reader) | The kiosk node owns the reader and talks to it directly over LLRP. | The inventory input, for either mode in [§2](#2-modes). |

The rest of this page is about the second surface.

RFID adds **no new collections**. It uses `item_instances.rfid_epc` and
`item_instances.enclosure_id` (migration `1802000000_instance_enclosure_id.go`).
The diff runs against the existing PocketBase tables. The cart stays in
memory. The in-memory cart store has a secondary lookup key for
`(user_code, enclosure_id)` in `enclosure_diff` mode, and nothing else about
cart persistence changes.

---

## 2. Modes

Both modes use the same in-process LLRP connection and the same resolver. They
differ in who starts the read and what the read means.

### 2.1 `counter_scan`: an operator-driven scan window

A countertop reader points its antenna at a small work surface.

1. The operator badges in at the touchscreen.
2. The operator presses the "RFID scan" button on the cart screen.
3. The kiosk node runs one inventory cycle of 3 to 5 s against the reader.
4. `scan.Resolver` resolves each observed EPC. Each matched instance becomes a
   cart line through the same write path that `POST /api/kiosk/cart/add` uses.
   The [`defaultActionFor`](https://github.com/stone-age-io/kiosk/blob/main/internal/handlers/cart.go) logic picks checkout
   or return for each line.
5. The worker confirms the cart on the touchscreen, and the normal commit path
   runs.

The endpoint is `POST /api/kiosk/cart/rfid-scan?cart_id=…`. It returns the new
lines, the observed EPCs and the EPCs it could not resolve. The button shows a
short "Reading… 3s" toast, styled like the cart-complete countdown.

In this mode the barcode gun is in effect an RFID antenna. The cart-write side
does not know that the input came in bulk over LLRP and not one keypress at a
time.

### 2.2 `enclosure_diff`: a system-driven diff against expected state

A reader sits inside an RF-isolated enclosure (a smart cabinet or a tool
locker). The worker stands outside, and the reader inside sees what is
present. NATS events drive the flow:

1. **Cart start.** An access-control event (a badge scan at the enclosure door,
   handled by an external system) publishes a `cart.start` command on
   `kiosk.{code}.cmd.cart.start` with `user_code` and `enclosure_id`. The
   kiosk node's command dispatcher creates or reuses a cart keyed by
   `(user_code, enclosure_id)`. The cart is empty at this point.
2. **The worker uses the enclosure.** The worker takes things out and puts
   things back. The kiosk node takes no part. The camera or occupancy system
   handles this step outside the binary.
3. **Read trigger.** When occupancy ends (the worker has stepped out), the
   external system publishes a `read.trigger` command on
   `kiosk.{code}.cmd.read.trigger`. It carries the active cart's
   `(user_code, enclosure_id)`, or its `cart_id` if known. The kiosk node runs one
   LLRP inventory cycle.
4. **In-process diff.** A pure function compares the observed EPCs with the
   expected set ([§2.3](#23-the-diff)) and populates the cart.
5. **Confirm.** The worker confirms on a screen outside the enclosure (the same
   `CheckoutView`, no new view), and the normal commit runs.

`kiosk` is the configurable `nats.subject_prefix`, and `{code}` is the kiosk
node's code.

**`cart.start` is idempotent.** The cart store has a secondary index keyed by
`(user_code, enclosure_id)`. A re-fire inside the cart's active window
(`session.idle_timeout`) returns the same `cart_id` and does not create a new
cart. After a commit or an idle expiry, the next `cart.start` for the same key
creates a new cart.

**`read.trigger` needs an active cart.** It looks up the active cart for the key
and replies with an error if there is none. We do not start an anonymous cart
on a read trigger. That path would hide wiring mistakes, such as a lost
access-control event or a race with the cart timeout. A loud failure shows the
problem.

::: note The kiosk node never auto-commits
A worker always confirms an `enclosure_diff` cart. A read result that nobody
confirms expires through the normal session idle timeout, like any other
abandoned cart.
:::

The outside-enclosure screen has a manual "Re-read enclosure" button. It calls
the same read-trigger logic over HTTP
(`POST /api/kiosk/cart/read-trigger?cart_id=…`), for parity with the NATS path.
Use it to run the read again after the operator steps in (took an extra thing,
put something back) before confirming.

### 2.3 The diff

The diff is a pure function in `internal/rfid/diff.go`, over the observed EPCs
and the expected set.

**Expected-present** is the non-retired serialized instances (`in_service` and
`maintenance`) on this kiosk node whose `id` is **not** in `open_checkouts`.

- **Several cabinets on one node.** When the node hosts more than one cabinet
  (`enclosureCount() > 1`), the set is also scoped to instances whose
  `item_instances.enclosure_id` matches the cabinet being read. A read of
  cabinet A then never treats cabinet B's tools as missing.
- **One cabinet.** A single-cabinet node, and any unassigned instance, keeps
  the whole-inventory set.
- **Assigning a unit.** Set a unit's cabinet in the instance admin UI (the
  "Enclosure" field, local or controller), by CSV, or in the PocketBase
  superuser UI.

The diff gives one result per EPC:

| Observed | Expected | Result |
| :--- | :--- | :--- |
| Yes | Present | No-op. The unit is still there. |
| Yes | Absent (in `open_checkouts`) | A return line. |
| No | Present | A checkout line. |
| Yes, but the EPC does not resolve | | Logged at warn level and dropped. A stray tag never touches the cart. |

Two cases are skipped and counted, never synthesized:

- **Maintenance units.** A `maintenance` unit is expected-present, because it
  is physically in the enclosure. It is **not** checkout-eligible. If it leaves
  the enclosure, the diff records it in a `SkippedIneligible` bucket, and the
  reply surfaces it to the operator as `skipped_maintenance_count`. Commit
  would reject a checkout of a unit that is not `in_service` anyway.
- **Cross-user returns.** A returned tag whose `open_checkouts` row belongs to
  a worker other than the cart user is skipped. The reply counts it in
  `skipped_cross_user_count`. The commit-time foreman and same-group gate would
  reject such a line, so a synthesized line would only make a cart the worker
  cannot commit. The count appears in the SPA toast ("3 cart lines from 5
  observed (1 skipped, held by another worker)"), so the operator sees that the
  read was not a black hole. If real demand for cross-user enclosure returns
  appears, the right pattern is probably a foreman-only mode toggle, parallel to
  the `CartForemanReturn` dialog. Silent acceptance is not.

---

## 3. Configuration

The `rfid:` block goes in `kiosk.yaml`. RFID is off by default. When it is
off, the kiosk node behaves exactly as it does without RFID hardware.

```yaml
rfid:
  enabled: false
  read_window: "3s"         # one inventory cycle, shared across readers
  # readers maps a reader_id to one physical reader. A node can host several:
  # a counter plus one or more enclosure cabinets, each with its own mode.
  # A single-reader kiosk declares exactly one entry (selection is implicit).
  readers:
    front-counter:
      mode: "counter_scan"  # "counter_scan" | "enclosure_diff"
      host: "10.0.0.50"     # reader IP / hostname
      port: 5084            # standard LLRP port
      # antennas (optional): active reader ports and the TX power each runs
      # at. Empty or omitted leaves the reader's own baseline alone. When set,
      # only the listed ports are inventoried, each at the given dBm (resolved
      # to the reader's nearest available power index at Connect time).
      # antennas:
      #   - id: 1
      #     tx_power_dbm: 25.0
      # zone (optional): a coarse location label. When set, a read here also
      # stamps each observed unit's advisory "last seen" at this zone, which
      # gives location data from custody activity. See
      # docs/location-sightings-plan.md.
      # zone: "Main Crib"
    cabinet-a:
      mode: "enclosure_diff"
      host: "10.0.0.51"
      port: 5084
      enclosure_id: "cabinet-a"  # required when mode=enclosure_diff
```

| Key | Type | Default | Purpose |
| :--- | :--- | :--- | :--- |
| `rfid.enabled` | bool | `false` | Turns RFID on. |
| `rfid.read_window` | duration | `3s` | One inventory cycle, shared by every reader. |
| `rfid.readers.{reader_id}.mode` | string | | `counter_scan` or `enclosure_diff`. Required. |
| `rfid.readers.{reader_id}.host` | string | | Reader IP or hostname. Required. |
| `rfid.readers.{reader_id}.port` | int | | LLRP port, usually `5084`. Required. |
| `rfid.readers.{reader_id}.enclosure_id` | string | | The cabinet this reader covers. Required when `mode` is `enclosure_diff`. |
| `rfid.readers.{reader_id}.zone` | string | `""` | Optional location label. Empty means no location stamping. |
| `rfid.readers.{reader_id}.antennas` | list | `[]` | Optional `id` and `tx_power_dbm` per active port. |

### Validation at startup

- When `rfid.enabled` is `true`, `rfid.readers` must have at least one entry.
- Each reader needs `mode` (`counter_scan` or `enclosure_diff`), `host` and
  `port`.
- An `enclosure_diff` reader needs `enclosure_id`.
- When any reader is `enclosure_diff`, the shared `rfid.read_window` must be
  3.5 s or less (`config.MaxEnclosureReadWindow`). The read runs synchronously
  inside the controller's command-reply window of about 5 s, so a longer window
  would push the reply past it. `counter_scan` is HTTP-driven and has no cap.
- A listed antenna needs `id >= 1`, a unique `id` and `tx_power_dbm > 0`. The
  reader's real ceiling (FCC about 33 dBm, ETSI about 31.5 dBm at the port) is
  enforced at Connect against the reader's power table, not statically (see
  [§4](#4-reader-lifecycle)).

::: note A reader that is offline does not stop the kiosk node
A failed reader connection at startup logs a warning, and the kiosk node
continues, as it does when NATS is unreachable. A background goroutine
supervises the LLRP session and retries with exponential backoff. A kiosk node that
boots before its reader is online recovers by itself when the reader appears.
During any gap, RFID endpoints return `ErrNotConnected` (`503` to the SPA), and
they recover when the session is back.
:::

### Environment overrides

Environment variables cover the top-level keys only: `KIOSK_RFID_ENABLED` and
`KIOSK_RFID_READ_WINDOW`. Per-reader fields live in the `rfid.readers` map and
are YAML-only. There is no flat environment path into a map entry.

### What the SPA sees

The identity payload served to the SPA carries `rfid_enabled` and `rfid_mode`,
so the frontend shows only the controls that apply:

- `counter_scan` shows an "RFID scan" button on `CheckoutView`.
- `enclosure_diff` shows a "Re-read enclosure" button, as a manual fallback
  beside the NATS-driven `read.trigger`.
- Both use the same 3-second countdown style.
- With RFID off, the button does not appear.

It also carries `rfid_enclosure_ids`, the cabinets this node's
`enclosure_diff` readers cover. The admin SPA offers them as suggestions when
you set `item_instances.enclosure_id`.

### Reader selection on a multi-reader node

`rfid_mode` in the identity payload is the mode of the **sole** reader. It
means something only when the node has exactly one reader.

- **One reader.** Selection is implicit, and no URL parameter is needed.
- **More than one reader** (for example two crib windows). Give each
  touchscreen a `?reader={reader_id}` URL parameter, beside the existing
  `?terminal=` attribution parameter. The "RFID scan" button then posts
  `POST /api/kiosk/cart/rfid-scan?cart_id=…&reader={reader_id}`, and the kiosk node
  fires exactly that reader (`Handlers.ReaderByID`).
- **When the scan button shows.** It shows when the sole reader is
  `counter_scan` **or** a `?reader=` is present. The server checks that the
  named reader is `counter_scan`, and answers `404` to a misconfigured screen.
- **The "Re-read" button needs no `?reader=`.** It finds the reader from the
  cart's `enclosure_id` through `ReaderForEnclosure`. It shows when the
  **active cart** carries an `enclosure_id` (a server-started `enclosure_diff`
  cart), not when the sole reader's `rfid_mode` matches. So it works at a node
  that mixes `counter_scan` and `enclosure_diff` readers, where `rfid_mode` is
  blank.

---

## 4. Reader Lifecycle

The kiosk node keeps one long-running LLRP TCP session per configured reader. It
does not connect once per read. Each entry in `rfid.readers` is its own
`impinjReader` (`internal/rfid/reader.go`). `Connect` starts a supervisor
goroutine that owns the session, and `Close` cancels it. The read lock
(`readMu`) is per reader, so two enclosures on one node can read at the same
time.

### The supervisor loop

On each iteration the supervisor:

1. Dials the reader (5 s timeout per attempt).
2. Starts the EdgeX `*llrp.Client` on the TCP connection.
3. If the operator configured antennas, sends `GET_READER_CAPABILITIES` (5 s
   timeout). It resolves each requested `tx_power_dbm` against the reader's
   `TransmitPowerLevelTable` to an LLRP power index. The hopping or
   fixed-frequency region information comes from the same response.
4. Publishes the live `*llrp.Client` and the resolved per-antenna `txConfig`
   under the reader's mutex. `ReadFor` takes a snapshot of both and continues.
5. Waits on the connection's exit channel until the connection drops (retry)
   or the supervisor's context is cancelled (`Close`).

The power resolver picks the highest entry **at or below** the request, so it
never exceeds the request. If every entry is above the request (a request
below the reader's minimum), it uses the lowest entry and logs a line.

On a dial or capabilities failure, the supervisor logs and retries with
exponential backoff: 1 s, 2 s, 4 s and up to a 30 s ceiling. A successful
connect resets the backoff to 1 s, so a short drop during reconnect does not
penalize the next attempt.

**Why a supervisor and not retry on demand.** The reader is long-lived shared
state. A kiosk node that boots before its reader is ready, or whose reader
power-cycles mid-shift, must not need a manual restart. A retry inside the HTTP
handler would also add the dial latency to every cart-screen visit.

### One inventory cycle

`ReadFor` runs one cycle:

1. Sends `ADD_ROSPEC` and `ENABLE_ROSPEC`.
2. Collects `RO_ACCESS_REPORT` messages for the read window.
3. Decodes the EPCs from each `TagReportData`.
4. Sends `DISABLE_ROSPEC` and `DELETE_ROSPEC`.

### Antenna power travels in every ROSpec

The operator could store antenna power in the reader's NVRAM (web UI or IoT
REST), or push it once per session with LLRP `SET_READER_CONFIG`. Instead, the
kiosk puts an `AntennaConfiguration` block inside the `InventoryParameterSpec`
of every ROSpec. This gives three results:

- **A reader reboot changes nothing.** The next `ReadFor` applies the tuning
  again. The supervisor needs no logic to push baseline state on reconnect.
- **`kiosk.yaml` is the source of truth, not the box.** A replacement reader
  (RMA, hardware refresh) needs no provisioning. The same YAML configures it.
- **Variable installs are a config problem, not a code problem.** A room may
  have 1 to 4 antennas, and each gets its own dBm. Overhead and side-mount
  antennas in the same cabinet often run at different power to avoid bleed.

The cost is one extra parameter block per ROSpec on the wire. That is
negligible at our read rate (operator-driven, low frequency).

**When `antennas:` is empty**, the ROSpec uses `AntennaIDs: [0]` ("all
antennas, the reader's own baseline") and sends no per-antenna override. The
supervisor also skips the capabilities round trip, because there is nothing to
resolve.

---

## 5. NATS Subjects

Both families follow the subject grammar `kiosk.{code}.{channel}.{rest}`, with
the same channel meanings as the rest of the kiosk ([Wire Protocol](protocol.md)).
The subject builders are in `internal/events/subjects.go`.

### Commands

`enclosure_diff` only. Request and reply, with a timeout of 5 s or less.

| Subject | Payload | Reply |
| :--- | :--- | :--- |
| `kiosk.{code}.cmd.cart.start` | `{user_code, enclosure_id, command_id}` | `{success, error, data: {cart_id, user_code, enclosure_id, reused}}` |
| `kiosk.{code}.cmd.read.trigger` | `{cart_id}` **or** `{user_code, enclosure_id}`, with an optional `command_id` | `{success, error, data: {cart, added_lines, observed_epcs, unresolved_epcs, skipped_cross_user_count, skipped_maintenance_count}}` |

`reused` tells the caller that its retry joined the existing cart. `command_id`
is for the caller's tracing. The kiosk node does not use it for deduplication: the
`(user_code, enclosure_id)` key in the cart store does that.

::: note Both commands reply inside 5 s, also on error
A silent command shows "kiosk offline" to the caller. To keep that rule for
`read.trigger` with a slow or half-open reader, the handler gives the LLRP read
a 4.5 s deadline (`commands.ReadTriggerBudget`, below the 5 s window). Past the
deadline the read stops, releases the reader's serialization lock, and the
handler replies with an error. The 3.5 s `read_window` cap keeps a normal read
inside that budget.
:::

A `cart.start` from access control is dispatched the same way as a
`cart.start` from the controller binary: the same handler, the same
idempotency, the same dispatcher.

### Events

Publish only, captured by the JetStream stream.

| Subject | When | Payload |
| :--- | :--- | :--- |
| `kiosk.{code}.evt.scan.rfid.observed` | After every completed read in either mode, also when it saw no tags | `{kiosk_code, location_code, cart_id, enclosure_id, mode, observed_epcs, observed_at}` |

This event is low-cost observability. It gives the controller, or any other
consumer, a stream of which tags were seen where, at no in-process cost. No
projector consumes it today. It stays in the JetStream stream for future drift
detection or analytics.

---

## 6. SSE Channel

In `enclosure_diff` mode, NATS commands start carts and run reads without the
SPA's knowledge. So the SPA cannot assume that it starts every cart change. A
small Server-Sent Events channel covers that:

| Endpoint | Purpose |
| :--- | :--- |
| `GET /api/kiosk/cart/events?cart_id=…` | Streams `cart.updated` and `cart.gone` tickles as plain `text/event-stream`. An SSE comment heartbeat every 15 s keeps idle proxies from closing the connection. |
| `GET /api/kiosk/cart?cart_id=…` | The refetch endpoint the SPA calls on every tickle. |

The server side:

- The broker is `internal/cartevents`: `Subscribe(cartID)` returns
  `(chan, unsub)`, plus `Tickle(cartID)` and `Close(cartID)`. Each subscriber
  has a small buffer that drops on full, so a slow client never blocks a busy
  write path.
- Every cart write path fires `Tickle`: `CartAdd`, `CartUpdateLine`,
  `CartDeleteLine`, `CartForemanReturn`, `PerformRFIDScan` and
  `PerformReadTrigger`. It fires exactly once per HTTP or NATS call, not once
  per cart line. `CartCommit` and `CartCancel` fire `Close`.
- `counter_scan` also fires the tickle, although the button press is local.
  This keeps the broker uniform and supports a future spectator client (for
  example a controller-side view of one kiosk).

The SPA side:

- `CheckoutView` opens the `EventSource` when its `cart_id` becomes non-null.
  It refetches through the GET endpoint on every tickle. It drops the
  subscription on unmount or on `cart.gone`. It uses plain `EventSource`, with
  no library.
- The browser reconnects by itself only after a network-level drop. On a
  non-2xx response (a short `503` during a restart, or a `404` for an unknown
  `cart_id`), it sets `readyState` to `CLOSED` and stops.
- So the composable (`useCartEvents.ts`) detects `CLOSED` and reconnects with
  capped exponential backoff (1.5 s to 30 s). On recovery it refetches once, to
  catch writes it missed while the stream was down. `cart.gone` is the one
  terminal case where it stops.

The cart stays in memory. If the cart were a PocketBase record, PocketBase
realtime would deliver the changes. That would cost the in-memory rule: it
adds concurrency, schema, cleanup, and the pull to build more features on a
"persistent" cart. SSE with tickles keeps the rule.

---

## 7. Trust Boundary

The kiosk binary still binds HTTP to `127.0.0.1` and treats the box as the
trust boundary. The external systems of `enclosure_diff` (access control,
camera or occupancy) never reach the kiosk node over HTTP. They publish NATS
commands, and the same per-subject permissions that gate controller-to-kiosk
traffic gate them.

The LLRP TCP connection goes out from the kiosk node to the reader on the LAN. The
kiosk node starts it. The reader does not need to reach the kiosk node on any new port.

---

## 8. Code Layout

```text
internal/rfid/                  domain wrapper, public to other internal packages
  reader.go                     Reader interface + impinjReader impl + EPC type
  diff.go                       enclosure_diff pure function
  diff_test.go                  pure-function unit tests, no I/O
  reader_test.go                wrapper tests; LLRP integration gated on RFID_SIM=1

internal/cartevents/            small SSE-driven pub/sub broker
  broker.go                     Subscribe / Tickle / Close
  broker_test.go

internal/handlers/
  rfid_scan.go                  counter_scan endpoint + PerformRFIDScan core
  rfid_read_trigger.go          enclosure_diff PerformReadTrigger core + ReadTrigger HTTP wrapper
  rfid_readers.go               ReaderByID, ReaderForEnclosure, enclosureCount
  rfid_sighting.go              zone stamping of observed units
  cart_events.go                SSE endpoint (GET /api/kiosk/cart/events)
  cart.go                       CartGet (GET /api/kiosk/cart) for the SSE refetch

internal/commands/
  rfid_enclosure.go             cart.start + read.trigger handlers (one file, two methods)
  dispatcher.go                 KioskHandlers field, so those handlers can reach the cart store

internal/cart/
  store.go                      StartByExternal + GetByUserEnclosure + secondary byUserEnclosure index

internal/config/
  config.go                     RFIDConfig block + KIOSK_RFID_* env overrides + cross-field validation

internal/events/
  subjects.go                   ScanRFIDObservedSubject, CartStartCommandSubject, ReadTriggerCommandSubject

cmd/kiosk/main.go               wires rfid.Reader, the cart-events broker, enclosure command deps

ui/src/composables/
  useCart.ts                    refresh(), rfidScan(), readTrigger()
  useCartEvents.ts              EventSource wrapper

ui/src/views/CheckoutView.vue   "RFID scan" (counter_scan), "Re-read enclosure" (enclosure_diff),
                                SSE subscription via useCartEvents
ui/src/types.ts                 KioskIdentity.rfid_enabled / .rfid_mode, RFIDScanResult, ReadTriggerResult
```

The `Reader` interface in `internal/rfid` stays small: `Connect`,
`ReadFor(ctx, d) ([]EPC, error)`, `Close`, and `Connected` (a point-in-time
status for metrics). Handler and command tests can mock it without an LLRP
simulator. The EdgeX `llrp.Client` is an implementation detail of
`impinjReader`, and `internal/rfid` does not export it again.

---

## 9. LLRP Library

The kiosk node uses the LLRP implementation from EdgeX Foundry's
`device-rfid-llrp-go` repository. The package is
`github.com/edgexfoundry/device-rfid-llrp-go/pkg/llrp`, a stable public API. We
**import it directly**, pinned in `go.mod`:

```bash
go get github.com/edgexfoundry/device-rfid-llrp-go/pkg/llrp@main
```

The pin is the `@main` pseudo-version, not a semver tag. EdgeX's `v4.x` tags
exist, but Go's module system cannot reach them. Their `go.mod` declares
`module github.com/edgexfoundry/device-rfid-llrp-go` without the `/v4` suffix
that a semver major version needs. The proxy serves only the older `v1` tags,
which are from before the package moved from `internal/llrp` to `pkg/llrp`.
`@main` resolves to a `v1.0.1-0.{timestamp}-{sha}` pseudo-version that Go
accepts. If EdgeX ships a release with a correct module path, move to that
tag.

We chose the EdgeX implementation over the standalone Go LLRP libraries
because:

- It is actively maintained as part of a Linux Foundation project.
- It is tested against Impinj hardware, including the R700.
- Its Apache-2.0 license causes no friction for our use.
- The package's production code imports only the Go standard library. EdgeX's
  large device-service dependency tree (MongoDB, OpenTelemetry, Zitadel and
  more) belongs to the driver code, not to the LLRP package. Importing it adds
  nothing extra to our `go.mod`.

We import it and do not vendor it. Vendoring (a copy in our own
`internal/llrp/`) made sense only while the code was under EdgeX's `internal/`
directory. In `pkg/llrp`, an import is simpler and more idiomatic. The version
pin in `go.mod` covers the risk of an upstream break that vendoring would have
covered: we move to a new version on our schedule, not theirs.

We do **not** write our own LLRP. The spec is large, binary and unforgiving,
and a new implementation gives no benefit.

---

## 10. Testing

The EdgeX `pkg/llrp` package has good upstream tests. The integration risk is
in our wrapper and in the diff, and you can test both without hardware:

- **`internal/rfid/diff.go`.** Pure functions over slices, with exhaustive unit
  tests for every observed and expected combination and no I/O. This is where
  the real correctness risk is, much more than in the LLRP traffic.
- **The `internal/rfid.Reader` wrapper.** The interface is small enough to mock
  in handler tests. Tests cover construction from an `RFIDConfig` value.
  `ReadFor` integration tests run against the EdgeX LLRP simulator, gated on an
  opt-in `RFID_SIM=1` environment variable for CI. This follows the pattern the
  PocketBase tests use for slower paths.
- **Config validation.** Enabled and disabled, the mode rules, the
  `enclosure_id` rule for `enclosure_diff`, and the environment overrides.
- **Handler and command tests.** They use real PocketBase apps, as in
  `commit_test.go`, and mock the `Reader` interface so results are repeatable.
  They include an end-to-end scan, resolve and cart-add test, an idempotency
  test for `cart.start`, and an anonymous-read rejection test for
  `read.trigger`.
- **The SSE endpoint.** An end-to-end `httptest` test opens a subscription,
  changes the cart and checks that the tickle arrives.

The frontend has no test suite (see `CLAUDE.md`). SPA correctness depends on
`vue-tsc` and integration checks.

---

## 11. Out of Scope

- Drift detection, cross-fleet instance movement and a controller-side quantity
  projection. These are separate roadmap items.
- Camera and access-control integrations. These external systems publish to
  the NATS command subjects in [§5](#5-nats-subjects). We define the command
  shape. We do not build the camera side.
- Antenna placement, cabling, regulatory region selection and EPC filter
  prefixes. The physical design and the reader's own provisioning tools (web
  UI, IoT REST) handle them. TX power per antenna is in the binary (see
  [§4](#4-reader-lifecycle)).
- LLRP over MQTT or any other reader transport. We chose direct LLRP and we
  keep it.
- Persisting carts to PocketBase. The cart stays in memory.
- Auto-commit of `enclosure_diff` carts. A worker always confirms.

---

## 12. Where to Go Next

- Collections, including `item_instances.rfid_epc` and `enclosure_id`: [Schema](schema.md)
- Every subject and payload on the wire: [Wire Protocol](protocol.md)
- The rest of `kiosk.yaml`: [Configuration](configuration.md)
- Zone stamping and fleet location: [Location Sightings Plan](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md)
- The system overview: [Overview](overview.md)
