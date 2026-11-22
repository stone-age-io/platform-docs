---
path: kiosk/overview
nav_order: 10
---
# Overview

This page explains what the kiosk is, the model behind it and how its three
binaries fit together. Read it first. The other pages in [the docs](https://github.com/stone-age-io/kiosk/blob/main/docs/README.md)
go deep on each part, and the repository's [README](../README.md) lists the
features.

---

## 1. What This Is

The kiosk is an **asset custody and location platform** for physical
inventory that moves between people and places. It is an application on the
Stone-Age.io platform. A worker identifies with a badge scan at a
touchscreen. Then the worker scans the tools or consumables to take or return,
confirms, and walks away. Behind that 30-second interaction is an append-only
ledger that always knows **who has what**. When location hardware is present,
a separate advisory signal shows **where each thing was last seen**.

We built it for construction and tool-rental operations. A rental yard or a
general contractor stocks tool cribs and consumable storerooms at job sites.
Subcontractors and crews check out drills, lasers and fasteners. The office
must know what is out, who has it and whether it will come back.

Nothing in the core is specific to construction. The same model applies
wherever people share a defined set of physical things across locations:

- a hospital equipment pool
- an IT device locker
- a film-gear cage
- a research instrument room

The rule is the same each time: **track custody first, add location on top,
and reconcile the two.**

The system is a small number of self-contained Go binaries. The kiosk node is
one executable of about 40 MB that embeds its web server, database and
touchscreen UI. Copy it to a mini-PC with `scp` and run it. It needs no
separate API server, no separate database and no cloud service for normal
operation.

---

## 2. Custody, Location and the Gap Between Them

The kiosk knows two independent facts about each tracked asset:

1. **Custody: who is responsible for it.** This fact is authoritative. It
   comes from an append-only ledger of checkout and return events, like a bank
   ledger. Nobody edits or deletes an entry. The system only appends. "What is
   out now" can always be derived from that history. Custody is the system of
   record.
2. **Location: where it was last seen.** This fact is advisory. RFID or BLE
   readers ("gateways") around a site observe tagged units and report a coarse
   zone, or GPS coordinates for a roaming reader. Location is lossy and best
   effort. A missed read only makes "last seen" stale. It **never** blocks a
   checkout or changes the ledger.

The value of the product is the **reconciliation of the two**:

- *"Checked out to Bob, but last seen still in Cabinet A."* Maybe nobody took
  it.
- *"In someone's custody, but not seen anywhere in three days."* Maybe it is
  lost.
- *"No custody record, but seen leaving the yard."* This is unaccounted
  movement, and a theft signal.

Custody tells you the paperwork. Location tells you the ground truth. **The
gap between them is the alert**, and the kiosk exists to show that gap.
Custody is mandatory and always on. Location is an optional layer that you
add when you install gateways.

---

## 3. The Mental Model

A small set of nouns carries the design. Most deployments use only the first
few. The others let one tool crib grow into a site with many buildings and
cabinets, with no change to the model.

| Concept | What it is |
| :--- | :--- |
| **Kiosk node** | A self-contained unit: one binary, one database, one shared inventory. It is the unit of trust and the only authority over its own custody ledger. Config and subjects call it a kiosk (`kiosk.code`). A kiosk node can be one screen on a wall, or the cabinets and screens of a whole building. |
| **Terminal** | A screen where a worker stands. One kiosk node can drive several, for example an inside and an outside screen, or two doors of a building. Each transaction records its terminal as descriptive attribution. A terminal is never a security boundary. |
| **Reader** | A physical RFID or BLE reader wired to a kiosk node. It reads tags at the point of checkout, for bulk scans or smart-cabinet reconciliation. |
| **Enclosure** | An access-controlled smart cabinet or locker. It is an inventory partition inside a kiosk node. A serialized unit can live in an enclosure, and a cabinet read compares what is still inside with what left. |
| **Gateway / Zone** | A location sensor around the site, operated outside the platform. It observes tags and reports sightings. A static gateway maps to a coarse **zone**, and a roaming one reports GPS. The kiosk only consumes these sightings. It never operates a location reader itself. |
| **Site** | A label that groups several kiosk nodes. It owns nothing. |

The inventory has its own nouns:

| Concept | What it is |
| :--- | :--- |
| **Item (SKU)** | A catalog entry, such as "1/2-inch impact driver" or "box of #8 screws". It carries quantity on hand and a reorder threshold. |
| **Instance (unit)** | One physical thing under a serialized SKU, tracked by itself: *this* impact driver, with its own barcode, printed serial and RFID tag. Three drivers under one SKU stay distinct, so a return closes the exact unit that was scanned. |
| **Tracking mode** | How a SKU is counted. **Consumable**: decrements on use (screws, blades). **Quantity-tracked tool**: a pool of N identical tools (a bin of tape measures). **Serialized**: each unit is an instance with its own lifecycle. |

Two kinds of people use the system, with different trust models:

- **Workers** identify with a badge scan and never sign in. On a kiosk node,
  the box itself, on a trusted local network, is the trust boundary.
- **Admins** sign in with email and password. They manage the catalog,
  workers, imports, reports and notifications.

---

## 4. The Three Binaries

The binaries share the same internal packages, but each exposes a different
surface.

```text
                         ┌───────────────────────────────┐
                         │     kiosk-controller          │   (optional, central)
                         │  • aggregates every node's    │
                         │    events into one ledger     │
                         │  • pushes catalog down to      │
                         │    each node it manages        │
                         │  • live online status, fleet   │
                         │    reports, central email       │
                         └───────────────────────────────┘
                              ▲            ▲            ▲
                    NATS      │            │            │   NATS
              (events up,     │            │            │
           catalog/commands   │            │            │
                  down)       │            │            │
              ┌───────────────┘            │            └───────────────┐
              │                            │                            │
   ┌──────────────────┐         ┌──────────────────┐         ┌────────────────────┐
   │   kiosk-app       │         │   kiosk-app       │         │  kiosk-timeclock   │
   │  (Building A)     │         │  (Building B)     │         │  (phone punch page)│
   │                   │         │                   │         │                    │
   │ touchscreen +     │         │ touchscreen +     │         │ authenticated      │
   │ badge + scanner   │         │ badge + scanner   │         │ self-service       │
   │ checkout/return   │         │ checkout/return   │         │ clock in/out       │
   └──────────────────┘         └──────────────────┘         └────────────────────┘
```

### 4.1 The Kiosk Node: `kiosk-app`

The kiosk node is the center of the system, and the only binary most
deployments need. One process serves the touchscreen checkout flow and the
admin web UI, and owns its database. It handles the full custody loop:

- checkout, return and consume
- serialized units and their maintenance
- stock levels
- the optional timeclock
- optional RFID reads

Every state change goes through one append-only ledger.

A kiosk node is **edge first and autonomous**. It needs no internet and no
central server to do its work. If the network or the controller goes down, it
continues to run and the ledger stays correct.

### 4.2 The Controller: `kiosk-controller`

The controller is optional. In a deployment with more than one kiosk node, it
is a central hub that does four things:

- **Aggregates** the transaction events of every kiosk node into its own
  ledger. The office then has one fleet-wide view of what is out.
- **Distributes the catalog** to each kiosk node. Membership decides which
  SKUs each location stocks, so a kiosk node receives only its own part.
- **Tracks online status** from heartbeats, and sends admin commands to a
  kiosk node: adjust stock, force-close a checkout, change a unit's status.
- **Sends all email** from one place through one mail server: receipts,
  low-stock alerts and scheduled digests.

The controller **owns nothing authoritative**. Each kiosk node stays the
source of truth for its own custody. The controller only aggregates and
distributes, and a kiosk node never waits on it. So a controller outage
degrades reporting and central email, but a worker can still check a tool out
or in.

### 4.3 The Timeclock Terminal: `kiosk-timeclock`

The timeclock terminal is optional. It is a public punch page where **each
worker signs in**, so crews can clock in and out **from their phones**. It
needs no badge scanner and no physical station.

Its trust model is the opposite of a kiosk node. The box is not trusted.
Each worker signs in with company SSO or a password, and the server reads the
identity from the session, never from the request. A worker can punch only
their own clock.

It runs the same timeclock code as a kiosk node, with the same ledger and the
same fleet-wide state. But it exposes *only* the authenticated punch surface.
The anonymous checkout endpoints do not exist in this binary, so a public
deployment cannot expose them by accident.

---

## 5. How a Deployment Grows

One rule guides the design: **"N=1 is invisible."** A single kiosk needs no
extra setup. Each capability for many nodes, many cabinets or central
management is opt-in by topology. You do not pay for complexity that you do
not use.

1. **One kiosk node, standalone.** A mini-PC, a touchscreen and a USB barcode
   scanner. One screen, one inventory, a local database, no network. For a
   single tool crib, this is the whole product.
2. **A kiosk node adds peripherals.** Add screens (terminals), RFID readers or
   smart cabinets (enclosures) to the same kiosk node. It stays one binary,
   one database and one shared inventory. A building becomes a site, but not
   a distributed system.
3. **A fleet joins a controller.** Point several kiosk nodes at one
   controller over NATS. The controller manages the catalog and pushes it
   down. The activity of every kiosk node rolls up into one ledger and one set
   of reports. Central email and remote admin commands start to work. Each
   kiosk node can still operate alone.

The same three steps are the operating **modes** that every binary supports:

| Mode | What it does |
| :--- | :--- |
| Standalone | No network. |
| Standalone with events | Publishes its activity on NATS for outside consumers, but manages itself. |
| Controller-managed | Full federation under a controller. |

---

## 6. What It Does

Each capability has its own page. This section gives one paragraph for each.

- **Checkout, return and consume in one flow.** A scan picks the natural
  action. A consumable is consumed. A tool already out *to you* is returned.
  Anything else is checked out. The worker can change the action before
  confirming. See [Ledger](ledger.md) and [API Reference](api.md).
- **Serialized units with a maintenance lifecycle.** Each physical unit has a
  status: *in service*, *in maintenance* or *retired*. A returned tool can go
  to maintenance by SKU policy or by a per-return toggle that any worker can
  set. There it counts as on hand, but nobody can check it out until an admin
  clears it. Units are never deleted. They retire, reversibly, so the ledger's
  history always points at a real unit. See [Schema](schema.md).
- **Stock levels with an audit trail.** Quantity-tracked items carry an
  on-hand count and a reorder threshold. An admin adjustment writes an audit
  row in the same database transaction as the change. A low-stock report shows
  what to reorder. Serialized counts are *derived* from the live unit count,
  so they cannot drift. See [Operations](operations.md).
- **Timeclock with tool interlocks.** Workers clock in and out against a
  second append-only ledger, with the same rule: never edit, only append. Two
  optional interlocks tie the clock to the tool ledger:
  - *No checkout unless clocked in.*
  - *No clock-out while holding tools.* The screen lists what to return and at
    which building, across the fleet.

  The raw punch export is the payroll contract. The kiosk does no rounding and
  no overtime math. See [Configuration](configuration.md).
- **RFID-assisted checkout.** A networked reader can act as a bulk barcode
  gun: tap "RFID scan" and every tag read goes into the cart. It can also run
  a **smart cabinet**. An access-control event opens a session, and a trigger
  reads the cabinet. The kiosk node compares what is still inside with what
  left, and proposes the cart for the worker to confirm. See [RFID](rfid.md).
- **Advisory asset location.** RFID and BLE gateways around the site, run
  *outside* the platform, publish sightings on NATS. Each tracked unit gets a
  coarse "last seen" zone or a GPS position. A custody read counts as a
  sighting too. Location feeds the reconciliation in
  [§2](#2-custody-location-and-the-gap-between-them), a Locations view and a
  reconciliation digest. See [Location & Sightings](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md).
- **Reports and notifications.** The reports are: what is out, aging
  checkouts, low stock, group activity, recent transactions, adjustment audits
  and notification deliverability. Each has a CSV export that respects the
  filters on screen. Receipts, low-stock alerts and scheduled digests go out
  by email. On a controller the reports cover the whole fleet. Standalone,
  they cover one kiosk node. See [Notifications](notifications.md).

---

## 7. Why It Is Built This Way

A few decisions explain most of the design.

- **One binary, no runtime dependencies.** Go, an embedded database and the
  compiled web UI go into one executable. To deploy, you copy a file. Nothing
  must be installed on the mini-PC, and nothing must run beside it.
- **The ledger is the system of record, and it is append-only.** Exactly one
  code path writes custody state, and it only appends. "What is out now" is a
  materialized view. The kiosk node can rebuild it from the ledger at any
  time, so it cannot drift for good. A correction is a new entry with a
  reason, never an edit. A financial ledger follows the same rule.
- **The kiosk node is the only authority. The controller only aggregates.**
  No central database must be up for a kiosk node to operate. This makes the
  system resilient at the edge and ready for federation, without a fragile
  central tier.
- **Location is advisory and never gates custody.** A wrong or missing
  sighting gives, at worst, a stale "last seen" cell. The checkout path never
  reads location. So the authoritative ledger stays clean, and nothing can
  block the workflow.
- **Each trust model matches its deployment.** A kiosk node on a trusted
  local network treats the box as the boundary and reads the worker's
  identity from a badge. The timeclock terminal faces the internet, so it does
  the opposite. Every worker signs in, and the identity comes from the
  session, never from the request. Each binary exposes only the surface its
  trust model can safely support.

---

## 8. Where to Go Next

- To run it: [Configuration](configuration.md) and
  [Operations](operations.md).
- The data model: [Schema](schema.md) and [Ledger](ledger.md).
- Integration over the wire: [Wire Protocol](protocol.md) and
  [API Reference](api.md).
- More than one site: [Central Controller](controller.md).
- The optional hardware and location layers: [RFID](rfid.md) and
  [Location & Sightings](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md).
- What is shipped and what is planned: [Shipped & Roadmap](roadmap.md).
- The feature list: the repository's [README](../README.md).
