---
path: platform/console
nav_order: 65
---
# The Console

The Stone Age Console is the Vue web UI inside the Control Plane binary. This
page covers what it shows and how it behaves. The records it edits are on
[Platform Entities](./platform-ui-entities.md), and what each role may do is in
[Authorization & Roles](./authorization.md).

The console is not the security boundary. It shows what the API rules already
permit, and a hidden button is still a reachable endpoint
([Platform Entities §1](./platform-ui-entities.md#permissions)).

---

## 1. The Dashboard

The Dashboard is a grid where you build your own views.

- **Widgets:** gauges, charts, switches, maps and more.
- **NATS-native:** most widgets subscribe to NATS subjects. The data goes from
  the device to NATS to your browser, and never through the database.
- **Variables:** dashboard variables (for example `{{building_id}}`) let one
  dashboard switch between sites or things.
- **Thing Type binding:** the Publisher widget can bind to a Thing and an
  operation. The subject then resolves from the Thing Type's templates and is
  read-only. The payload is free text. See [Thing Types](./thing-types.md).

The widgets are in [Dashboards](./dashboards.md).

---

## 2. Map and Floor Plans

The console shows Locations in two ways:

1. **Map:** a **Leaflet** map that plots Locations by latitude and longitude.
2. **Floor plans:** upload a JPG or PNG floor plan and drag **Things** onto it
   to show where they are in a room.

**The map draws one pin per site, not one per Location.** A Location gets a pin
only when no ancestor has coordinates. Everything below it goes into that pin,
and you open it from the pin's drawer. Without this, a campus, its buildings,
floors and rooms would all stack within a few metres. Use floor plans for
positions inside a building.

The pin goes to the outermost ancestor that has coordinates, not to the root,
because tenants put coordinates on different levels. Ancestors with no
coordinates are skipped, so a room under an unmapped floor goes into its
building's pin. Nearby sites that still overlap are **clustered**.

A search shows every matching Location on the map, the same as the list beside
it, so both show the same count.

---

## 3. The Digital Twin

Every Location and Thing with a valid **code** has a **Live State** panel on its
detail view. It shows the keys under `thing.<code>` or `location.<code>` in the
organization's twin buckets. It is the same KV browser as for other buckets,
with tree and flat views, filters, revision history and a detail drawer.

It has two tabs, one for each [bucket](./architecture.md#41-two-buckets-one-writer-each):

- **Reported** (`twin`) is what the device says. It is **read-only**, because
  the edge overwrites it on the next sync.
- **Desired** (`twin_desired`) is what you want, and you can edit it. Put
  setpoints and configuration here. Send commands such as `reboot` as a NATS
  message instead. Put thresholds and alarm ranges in
  [rules](./automation.md) over reported state.

Where the two differ, the row shows both values, for example
`"auto" → "manual"`, and the detail pane shows them in adjacent columns. The
console says **differs**, never "pending". Nothing in the platform pushes a
desired value into a device. `twin_desired` delivers the value to the edge's
local KV, and your firmware or rules act on it.

Only the keys in a desired value are compared, so extra reported fields are
ignored. With full equality, one new reported field would make every older
desired value "differ".

Layer 1 rules also read and write these buckets, for example for alarm
stacking. See [Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state)
and [Automation](./automation.md).

> **The Control Plane does not create these buckets.** It holds the NATS Operator key but cannot act inside an organization's own account. The console's **Initialize** button or the Agent at the edge creates them. Whichever runs first defines the bucket, so the two use the same retention settings.

---

## 4. JetStream Streams and KV Buckets

Owners and Admins can manage the org's JetStream resources in the console,
without the `nats` CLI. These views use the console's NATS WebSocket session,
so changes apply immediately.

- **Streams** (`/nats/streams`): create, edit, inspect and delete streams. The
  form has subjects, retention (`limits`, `interest`, `workqueue`), storage
  (`file`, `memory`), message, byte and age limits, replicas, discard policy
  and duplicate window.
- **KV Buckets** (`/nats/kv`): create, configure and inspect buckets. The form
  has history depth, bucket size, value size, TTL and replicas. The detail view
  has a **KV Dashboard** to browse keys and watch live updates.

These views appear only when the browser is connected to NATS, because they act
on the live cluster. Your NATS role's permissions limit what you can create.
The account's JetStream storage limits, set when the account is provisioned,
limit the total. Rules and stream processors use the same streams and buckets.

---

## 5. Printing QR Labels

Every Location or Thing with a **code** has a **Label** button on its detail
view. It makes a QR label to print and put on the equipment. A record with no
code has no button, because the payload is the code.

The Things and Locations **lists** also have a Label button. It prints **every
record that matches the current filter**, not only the current page. The button
shows the count. Records with no code are skipped and **listed** above the
preview.

- **Sizes match real label stock:** 2″ × 1″ and 4″ × 2″ plain thermal labels,
  laid out in millimetres, so the print is the size of the stock.
- **Every label prints its code as text, sized to fit.** A scratched or dirty
  symbol, or a dark closet, can stop a scan. Then you read the code aloud or
  type it into the scanner's manual field. The font size is fitted to each
  label, so a short code prints large. A code that does not fit wraps at a
  hyphen.

What a label holds, and why the payload is the bare code, is in
[Platform Entities §5](./platform-ui-entities.md#5-codes-and-qr-labels).

---

## 6. The Activity Feed

`/activity` shows who in the organization changed a record, and when. Every
role can read it through the API, `dashboard` included. The console shows it to
every role except `dashboard`, whose only screen is the Visualizer.

Each entry has the actor, the action, the record and the time. It stores no
record *values*. The audit log is separate: only Platform Operators can read
it, and it keeps old and new values for collections with no credentials (field
names only for the rest).
[Authorization §5](./authorization.md#5-two-histories-the-audit-log-and-the-activity-feed)
explains the boundary, and why the feed covers the five org-scoped inventory
collections but not memberships, invites or `nats_*` records.

- **The record label in a row is a snapshot.** If a Thing was renamed after the
  change, the row shows the old name. The row's detail dialog says so.
- **"This record's history"** in the row dialog filters the feed to one
  `resource_id`. This differs from a label search, which also finds other
  records with the same name. Thing and Location detail views, and the three
  type forms, show **Created / Last updated** stamps to compare with the feed.

---

## 7. Photos and File Fields

Things and Locations each have one **photo** of the installation, taken while
someone is at the device. It shows beside the fields on the detail view and
opens full size. The edit form shows it in the same place, beside Name and
Description.

With no photo yet, anyone who can edit inventory sees an **Add photo** plate in
that spot on the detail view. It uploads and saves the photo at once, without
the edit form. Viewers see nothing there. To replace or remove a photo, use the
edit form.

You add a Thing's photo **on edit only**. Creation goes through
`POST /api/org/things`, a JSON route that cannot carry a multipart body. Create
the Thing, then add the photo. On edit, the photo is sent in its own request.
The rest of the Thing update stays JSON, because the member branch of
`things.updateRule` requires `nats_user` and `nebula_host` to be unchanged, and
JSON can leave a field out. A multipart body cannot leave a field out, so a
member's normal edit would be refused. A Location's photo also works on create,
because Locations use the plain record API.

::: warning File URLs need a file token
`photo`, a Location's `floorplan`, an Organization's `logo` and a user's
`avatar` are **protected** file fields. Each request needs a short-lived file
token, and the server checks the collection's view rule. **An auth token is not
a file token.** An integration that uses a bare file URL must request a file
token first.
:::

---

## 8. Lists and Deletes

Lists are responsive:

- **Desktop:** dense tables for bulk work.
- **Mobile:** cards for status checks and urgent control on site.

**Delete is not on list rows.** Sort, search and paging move rows, so a row
button is easy to aim at the wrong record. Delete is in a **Danger Zone** at the
bottom of a record's detail view. For the three type collections, it is on the
edit form, which is their only detail view. Invitations keep a Delete on the
row, because revoking an invite is cheap and reversible.

**Six deletes ask you to type the record's identifier first.** Thing, Location,
Nebula host, NATS user and Organization ask for the code (or the name if there
is no code). A Nebula network asks for its name. Re-creating the record does
not undo these deletes. For a Thing, deactivate instead (see **Active** in [Platform Entities §3](./platform-ui-entities.md#3-things)):
the Thing's NATS credential and Nebula certificate survive a delete.
