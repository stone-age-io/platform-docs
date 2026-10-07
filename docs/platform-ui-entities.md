---
path: platform/platform-ui-entities
nav_order: 60
---
# Platform Entities & UI

This page describes the main records you manage in the Stone Age Console and
how the console shows them.

These records are in the **Control Plane** (PocketBase). They are the source of
truth for identity, inventory and relationships. They decide what the **Data
Plane** carries: NATS subjects, KV buckets and Nebula certificates. See
[Architecture](./architecture.md).

---

## 1. Organizations & Memberships

Every record belongs to an Organization. A user can belong to several
Organizations.

### Organizations

- **Isolation:** each Organization has its own NATS Account and Nebula
  Certificate Authority.
- **Organization code:** a short slug such as `acme` or `northwind`. It is the
  **only globally unique identifier in the platform**. Every other code is
  unique only within its Organization.
  - If you do not supply one, the platform derives it from the name. A leading
    digit is valid (`816tech`).
  - The managed-org subject rewrite, sibling apps and external data joins all
    use it to name the tenant.
  - It is optional, but **you cannot change it once set**. Creation refuses a
    code that is already in use and does not invent `acme-2`, because the code
    goes into signed account JWTs and printed labels.
  - See [ADR 0002](./decisions/0002-organization-code-namespace.md).
- **Ownership:** an Organization has an **Owner**, who has full tenant
  authority and cannot leave it. Only a **Platform Operator** can create, edit
  or delete the Organization record. The record holds the tenancy flags and
  drives NATS Account and Nebula CA provisioning. Deleting it does not cascade:
  it orphans the whole inventory. See [Authorization §3](./authorization.md#3-cross-organization-identities).
- **Suspension:** a Platform Operator can clear an Organization's **Active**
  flag. This withdraws its NATS account, and every device, agent and browser in
  the tenant disconnects. No credential is revoked, so everything reconnects
  when you set the flag again. Nebula is not affected, and the tenant can still
  sign in to the console and read its records. You cannot suspend the operator
  or system organizations. See [Authorization §3.1](./authorization.md#31-suspending-an-organization).
- **Invites:** Owners and Admins invite users by email. The invite contains a
  secure token for onboarding. An invite can offer any role except `owner`.

### Memberships

A Membership links a User to an Organization with one of five roles:

| Role | Can do |
| :--- | :--- |
| `owner` | Full tenant authority. **The same as `admin` in every API rule.** The one difference: an Owner cannot leave their own organization. |
| `admin` | Full tenant authority: members and invites, NATS and Nebula infrastructure, types and contracts, and the identity links on a Thing. |
| `member` | Creates and edits Things and Locations. Reads Thing Types and Operations. Cannot delete a Thing or Location, attach identities, or read the infrastructure collections. |
| `viewer` | Read-only staff. Browses inventory and uses dashboards. Writes nothing. |
| `dashboard` | A login for an unattended screen. Sees only the Visualizer and its own settings page. Writes nothing. |

Every role can read the one NATS identity linked to its own membership, which
is the identity the browser connects with. What a login can do on the bus comes
from that identity's `nats_users` role, which is set separately.

**Linked NATS identity.** A user can be a member of several Organizations, so
the NATS user relation is on the membership, not the user. Access to it is
**row-scoped**: a member, viewer or dashboard holder can read exactly that one
`nats_users` row. See [Authorization §4](./authorization.md#4-the-row-scoped-credential-model).
The read follows the link, so only an Owner or Admin can **choose** the linked
identity (on the member's detail page). Every role can clear its own link from
Settings, but cannot point it at another identity.

### Cross-Organization Roles

Two roles apply to the user account, outside any Membership:

- **Platform Operator** (`users.is_operator = true`) creates, edits, suspends
  and deletes Organizations, and invites users into any Org. No tenant role, not
  even Owner, can edit the Organization record. Only a Platform Operator can
  read the **audit log** (`audit_logs`). Use a Platform Operator for daily
  administration in the console. The `bootstrap` command creates the first one.
  `bootstrap` and the admin panel are the only ways to set the flag. The API
  refuses it, also from a Platform Operator.
- **SuperUser** (`_superusers` collection) is a service account with full
  database access that ignores API rules. Create it with
  `./stone-age superuser upsert`. Use it for infrastructure work such as schema
  imports and NATS Operator and System Account seeding. SuperUsers are not
  members of any organization. They sign in at the admin UI (`/_/`).

### Permissions

PocketBase API rules on each collection are the **only** permission layer. One
server-side hook also enforces an invariant: no relation may point into another
organization's records. See [Authorization](./authorization.md). The console's
capability map only decides which menu items and buttons appear. A hidden
button is still a reachable endpoint for anyone with a token.

[Authorization & Roles](./authorization.md) has the full capability matrix.
The points that most often surprise people:

- `owner` and `admin` are the same in every rule. Granting `admin` grants full
  tenant authority.
- `member` **can** create and edit Things and Locations. It cannot delete or
  deactivate them, and it cannot attach a NATS user or Nebula host to a Thing.
  A member who could point those relations at a privileged identity could then
  authenticate as the Thing and steal a credential. A member who could clear
  `active` could take any device off the network.
- `member`, `viewer` and `dashboard` cannot **read** the infrastructure
  collections (`nats_users`, `nats_roles`, `nats_account_exports`,
  `nats_account_imports`, `nebula_networks`, `nebula_hosts`). They get an empty
  list, except for their own linked NATS identity.
- Only Platform Operators can edit the Organization record and read the audit
  log.
- Every role, including `dashboard`, can rotate its own NATS credential,
  unless that identity is suspended.

### Self-Service Credential Rotation

Any authenticated identity with a linked NATS user (a `users` membership or a
`things` record) can rotate its own credential:

```
POST /api/me/nats-creds/rotate
```

It takes **no id**. It always targets the caller's own linked identity. After
the call, read your own record again to get the new `.creds`.

This is a route, not an update rule, because a PocketBase rule cannot allow
only one field. The field that must stay closed is
`nats_users.publish_permissions`, which the platform copies into the JWT it
signs. A **suspended** identity (`active = false`) gets `403`, because a new
credential would be issued after the revocation cutoff and end the suspension.

Suspending, reactivating and revoking are Owner/Admin actions. On a NATS user's
detail view, **Revoke** is for *leaked* credentials. It moves the identity to a
new key pair, returns a working replacement, and leaves the identity active. To
take an identity out of service, deactivate the Thing that holds it. See
[Authorization §4](./authorization.md#4-the-row-scoped-credential-model).

---

## 2. Locations

Locations are the physical or logical hierarchy of your sites. They answer
*"Where is this thing?"*

### Concepts

- **Hierarchy:** Locations have parents and children, for example
  `Global > North America > Chicago > Warehouse A > Row 4`.
- **Location code:** an identifier such as `CHI-W-A`, unique within the
  Organization (ignoring case).
  - It must match `^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$`: no dots, NATS wildcards
    or spaces ([why](./thing-types.md#what-a-code-may-contain)).
  - Use the name already on the door or drawing (`RM-204`). A Location saved
    with no code gets a [generated one](./thing-types.md#generated-codes) under
    its type's prefix.
  - It names the Location's **digital twin** keys in NATS KV. Sibling apps use it
    to find a ticket or work order. It is the payload of the site's
    [QR label](#codes-and-qr-labels).
  - **You cannot change it once set**, because every twin key, label and
    external record that uses it would be orphaned. The Location's **type** is
    also frozen once set.
- **Path:** the server computes it on every save. It is the Location's code and
  the code of each ancestor, from the root down, with `/` between them and at
  both ends: `/KC/BD-3/RM-204/`.
  - The end slashes stop `/BD-3/` from matching inside `/BD-30/`.
  - "Everything under BD-3" is one filter: `location.path ~ '/BD-3/'` on Things
    and `path ~ '/BD-3/'` on Locations.
    [Long-term dashboards](observability.md#5-where-things-are-joining-against-the-inventory)
    filter by site this way.
  - `~` is SQL `LIKE`, so `_` in a code matches any one character. Both slashes
    are required, so this rarely matters.
  - Moving a Location rewrites its path and every path below it in the same
    save. The server refuses a move under the Location itself or one of its
    descendants.
  - Deleting a parent makes each child a root, with its subtree.
  - The server ignores a path sent by a client. The Location page shows the
    path. See [ADR 0004](decisions/0004-long-term-data-and-location-path.md).
- **Metadata:** a JSON field for site data such as time zone, contacts or local
  gateway IPs.

### Mapping & Visualization

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

## 3. Things

A **Thing** is anything that produces or consumes data, or an asset you want to
record. A Thing is a PocketBase **auth record**. The same record is the
device's identity on the bus and the mesh. See
[Inventory-as-Identity](./architecture.md#31-inventory-as-identity).

The identity relations are optional. A Thing with neither is an asset-tracking
record and nothing more.

### Concepts

- **Identity:** Things are an auth collection, so a Thing can sign in to the
  PocketBase API to fetch its own configuration. If the password is lost, an
  Owner or Admin can set a new one in the **Authentication** card on the
  Thing's edit form. Type it and save. The platform shows a Thing password only
  once, when it generates one at creation.
- **Thing code:** the same character rules as the Location code. It is used in
  NATS subjects (for example `camera.CA-9KD-4PX`), as the join key for sibling
  apps, and as the payload of the device's [QR label](#codes-and-qr-labels).
  **You cannot change it once set.**
  - Leave it blank on the create form, and the server generates one under the
    Thing Type's prefix, such as `CA-9KD-4PX`.
  - To code a batch of devices, create the records, then print their labels
    from the list.
  - If a code is already stencilled on the hardware (`DOOR-1`), type that code.
  - See [Generated codes](./thing-types.md#generated-codes).
- **Type:** frozen once set. The code prefix and the default subject come from
  it. To fix a wrong type, delete and recreate the Thing, ideally before you
  provision it. See [A type is frozen once set](./thing-types.md#a-type-is-frozen-once-set).
- **Metadata:** device data that changes rarely, such as hardware revision,
  install date or calibration offsets.
- **Active:** an Owner/Admin switch that takes the device out of service and
  keeps its record and history. **Deactivation is a real decommission.** The
  device is signed out immediately and cannot sign in again. Its NATS identity
  is suspended. Every peer blocklists its Nebula certificate when its config is
  redeployed. The detail view shows a banner, and the list greys the row.
  Reactivating issues a *new* `.creds` file, and the old one stays revoked.
  - **Deactivate a Thing. Do not delete it.** A delete does not touch either
    identity, so its credential keeps working and its certificate stays trusted.
  - See [Authorization §4.2](./authorization.md#42-taking-a-device-out-of-service).

### Infrastructure Binding

Binding puts an inventory record on the bus. It is **optional and
reversible**. The create form has three modes for each identity: `auto` (mint
a new one), `link` (attach an existing one) and `none`.
`POST /api/org/things` creates the Thing and both identities in one
transaction, so a device is never half-provisioned.

A Thing usually links to:

- **A Thing Type:** the contract that declares which subjects the Thing uses.
  See [Thing Types](./thing-types.md).
- **A NATS user:** so the device can publish telemetry. Its publish and
  subscribe permissions come from the `nats_roles` record on that NATS user,
  plus any per-user overrides. An Owner or Admin writes these. They do not come
  from the Thing Type. See [Thing Types §5](./thing-types.md#5-relationship-to-nats-roles).
- **A Nebula host:** for encrypted access to the device, such as maintenance or
  SSH.

Only an Owner or Admin can set `nats_user` or `nebula_host`. Otherwise a member
could point a Thing at a privileged identity, authenticate as the Thing, and
read credentials that are not theirs. A Thing a member creates stays
unprovisioned until an Owner or Admin links its identities. See
[Authorization §2](./authorization.md#2-capability-matrix).

A Thing's subjects are the inputs to your Layer 1 rules, so choose clean codes
and subject patterns early. The Thing Type declares the pattern once, and every
Thing of that type follows it.

---

## 4. Types

Types classify your inventory and locations.

- **Location Types** categorize sites, for example `Campus`, `Building`, `Room`
  or `Cabinet`. They only classify.
- **Thing Types** are the platform's **contract layer**. A Thing Type declares
  a **subject prefix** (a template such as `camera.{thing}`, or blank for the
  default `{thing_type_code}.{thing}`) and a set of **operations**. See
  [Thing Types](./thing-types.md).
- **Thing Operations** are shared records, one per verb (publish, subscribe,
  request, reply), each with a subject suffix. One `heartbeat` operation is
  usually linked from every Thing Type that sends heartbeats.

Both kinds of type have an optional **code prefix** of 1 to 4 capital letters
(`CA`, `BLD`). The platform puts it at the start of every code it generates for
a record of that type. Thing prefixes and Location prefixes are separate sets
in an organization, so a generated Thing code never looks like a Location code.
A prefix change applies to future codes only.

All three are in the **Types** menu in the sidebar. **Only Owners and Admins
can create, edit and delete them**, and only they see the Types menu, because
the console has no read-only view of a type. Every role in the organization can
still *read* types through the API, because a member's Thing form and the
Publisher widget resolve subjects from them.

---

## 5. The User Interface Features

### The Dashboard

The Dashboard is a grid where you build your own views.

- **Widgets:** gauges, charts, switches, maps and more.
- **NATS-native:** most widgets subscribe to NATS subjects. The data goes from
  the device to NATS to your browser, and never through the database.
- **Variables:** dashboard variables (for example `{{building_id}}`) let one
  dashboard switch between sites or things.
- **Thing Type binding:** the Publisher widget can bind to a Thing and an
  operation. The subject then resolves from the Thing Type's templates and is
  read-only. The payload is free text. See [Thing Types](./thing-types.md).

### The Digital Twin

Every Location and Thing with a valid **code** has a **Live State** panel on its
detail view. It shows the keys under `thing.<code>` or `location.<code>` in the
organization's twin buckets. It is the same KV browser as for other buckets,
with tree and flat views, filters, revision history and a detail drawer.

It has two tabs, one for each [bucket](./architecture.md#41-two-buckets-one-writer-each):

- **Reported** (`twin`) is what the device says. It is **read-only**, because
  the edge overwrites it on the next sync.
- **Desired** (`twin_desired`) is what you want, and you can edit it. Put
  setpoints and configuration here. Send commands such as `reboot` as a message
  on `cmd.>` instead. Put thresholds and alarm ranges in
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

### JetStream Streams and KV Buckets

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

### Codes and QR Labels

Every Location or Thing with a **code** has a **Label** button on its detail
view. It makes a QR label to print and put on the equipment. A record with no
code has no button, because the payload is the code.

The Things and Locations **lists** also have a Label button. It prints **every
record that matches the current filter**, not only the current page. The button
shows the count. Records with no code are skipped and **listed** above the
preview.

- **The payload is the bare code**, for example `DOOR-1`. It is not a URL and
  not `org/kind/code`. Anyone can replace a sticker in a public corridor. With a
  URL payload, a forged label could send a person to any content. With a bare
  code, a forged label can at most open the wrong record in an app the person
  is already signed in to. A short code is also a smaller symbol: 21×21 at the
  highest error correction, where the URL form needs 41×41. On the same size
  sticker, that gives larger modules that survive scratches and grease.
- **You scan inside an app.** The [Scanner widget](./dashboards.md) reads these
  labels. Sibling apps read the *same* label with their own scanners and open
  their own view of the record, such as a work-order history. Nothing opens the
  decoded string as a destination, and there is no resolver service.
- **Sizes match real label stock:** 2″ × 1″ and 4″ × 2″ plain thermal labels,
  laid out in millimetres, so the print is the size of the stock.
- **Every label prints its code as text, sized to fit.** A scratched or dirty
  symbol, or a dark closet, can stop a scan. Then you read the code aloud or
  type it into the scanner's manual field. The font size is fitted to each
  label, so a short code prints large. A code that does not fit wraps at a
  hyphen.
- **The label shows only the Organization's own data.** The top line is the
  organization's **code** (or its name if it has no code), then the record's
  code and name. A Location label adds a **Site** marker. A Thing code is unique
  only within its organization, so `AHU-1` alone is ambiguous to a technician
  who services several customers. There is **no provider brand**, because that
  setting is per deployment and says nothing about who owns or services a
  device. There is no type, because the name already says what the thing is.

Codes are unique only within an Organization. A scanner looks up a code in all
organizations and, if there are several matches, asks you to pick one. See
[ADR 0002](./decisions/0002-organization-code-namespace.md).

### The Activity Feed

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

### Photos and File Fields

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

### CRUD & Management

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
not undo these deletes. For a Thing, deactivate instead (see **Active** in §3):
the Thing's NATS credential and Nebula certificate survive a delete.
