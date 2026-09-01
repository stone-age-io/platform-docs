# Platform Entities & UI

The Stone Age Console provides a unified interface for managing the logical and physical structures of your IoT environment or Event-Driven Architecture. This document explains the primary entities used to organize your data and how they interact with the user interface.

These entities live in the **Control Plane** (PocketBase) — they're the source of truth for identity, inventory, and relationships. At provisioning time and at runtime, they shape what flows through the **Data Plane** (NATS subjects, KV buckets, Nebula certificates). See [Architecture](./architecture.md) for the Control/Data Plane split in full.

---

## 1. Organizations & Memberships

Organizations are the top-level container for all data and infrastructure. Every resource in the platform belongs to an Organization and platform Users can belong to multiple Organizations.

### Organizations

- **Isolation:** Each Organization receives its own private NATS Account and Nebula Certificate Authority.
- **Organization Code:** A short slug (`acme`, `northwind`) that is the **one globally unique identifier in the ecosystem** — every other code on the platform is unique only *within* an Organization. It is derived from the name when you don't supply one, and it roots the public namespace: the managed-org subject rewrite carries it, sibling apps name a tenant by it, and it is the handle that lets a consumer join their data to the platform's without a mapping table. **Optional, but immutable once set** — creation refuses a colliding code rather than inventing `acme-2`, because a wrong code would be baked into signed account JWTs and printed on labels long before anyone noticed. `system` and `operator` are reserved. See [ADR 0002](./decisions/0002-organization-code-namespace.md).
- **Ownership:** An organization has an **Owner** — the identity that may delete it. Creating and *editing* the organization record are **Platform Operator** actions: the record carries the tenancy flags and drives NATS Account and Nebula CA provisioning, so no tenant role has an update path to it. See [Authorization §3](./authorization.md#3-cross-organization-identities).
- **Invites:** Owners and Admins can invite users to join their organization via email. Invites generate a secure token used for onboarding. Invitations can offer any role except `owner`.

### Memberships

A Membership binds a PocketBase User to an Organization.

- **Roles (per-organization):**
    - `Owner`: Full tenant authority. **Identical to `Admin` in every API rule** — the only differences are that an Owner cannot leave their own organization and may delete it.
    - `Admin`: Full tenant authority — members and invitations, NATS and Nebula infrastructure, Thing/Location types and contracts, Leaf Nodes, and the identity links on a Thing.
    - `Member`: Creates and edits Things and Locations, and reads the contract collections (Thing Types, Operations, Message Schemas). Cannot delete a Thing or Location, cannot attach identities to one, and cannot read the infrastructure collections at all.
    - `Viewer`: Read-only staff. Browses the inventory screens and uses dashboards, and writes nothing anywhere. Adding it needed no rule change at all — a role that names itself in no write branch is denied by construction.
    - `Dashboard`: An appliance login for an unattended screen — the Visualizer and its own settings page, nothing else. It holds no write capability, which is exactly why the authorization suite uses it as the probe that proves an allowlist works.
    - Both, like every role, can still read the one NATS identity linked to their own membership, which is what the browser connects with. Neither restriction is a NATS restriction: what a login can do on the bus is whatever its linked `nats_users` role permits, set independently.
- **Identity Linking:** A critical feature of the Membership is the **Linked NATS Identity**. This allows a human user to browse the NATS bus using specific credentials assigned to their membership for that specific Organization. Since users can be members of multiple Organizations, this NATS user relation is stored on the membership record itself. Access to it is **row-scoped**, not field-hidden: a member, viewer or dashboard holder sees exactly that one `nats_users` row and no other — see [Authorization §4](./authorization.md#4-the-row-scoped-credential-model).

### Cross-Organization Roles

Two roles exist *outside* the per-organization Membership model and apply to the user account itself:

- **Platform Operator** (`users.is_operator = true`): Can create, edit, and delete Organizations and invite users into any Org. Editing the organization record is **exclusively** a Platform Operator action — no tenant role, not even Owner, has an update path to it. A Platform Operator is also the only identity that can read the **audit log** (`audit_logs`); no tenant role can. Platform Operators are the day-to-day platform administrators and the recommended identity for managing the system from the UI. The first one is created by the `bootstrap` command, which — along with the embedded admin panel — is the only way to grant Platform Operator status. The API cannot.
- **SuperUser** (`_superusers` collection): A backend service account with full database access regardless of API rules. Created via `./stone-age superuser upsert` and intended for infrastructure-level management — schema imports, NATS Operator/System Account seeding, and other platform-level concerns. SuperUsers are not members of any organization; they sign in at the embedded admin UI (`/_/`).

### Permissions

Authorization is enforced **solely** by PocketBase API rules on each collection. The UI's capability map decides which menu items and buttons render — it is navigation convenience, **not** the security boundary, and a hidden button is still a reachable endpoint for anyone holding a token.

**The authoritative capability matrix lives on one page: [Authorization & Roles](./authorization.md).** Rather than duplicate it here, the highlights that most often surprise people:

- `Owner` and `Admin` are the same allowlist in every rule. Granting `admin` grants full tenant authority.
- `Member` **does** create and edit Things and Locations. It cannot delete them, deactivate them, or attach a NATS user or Nebula host to a Thing — a member who could re-point those relations at a privileged identity and then authenticate as the Thing would have a credential-theft path, and one who could clear `active` could take any device in the org off the network. Members create and edit inventory; **decommissioning it is a management action.**
- `Member`, `Viewer` and `Dashboard` cannot **read** the infrastructure collections at all (`nats_users`, `nats_roles`, `nats_account_exports`, `nats_account_imports`, `nebula_networks`, `nebula_hosts`). They receive an empty list, not a filtered one — with the single exception of their own linked NATS identity.
- Editing the Organization record, and reading the audit log, are Platform-Operator-only.
- Every role, including `Dashboard`, can rotate its own NATS credential (`POST /api/me/nats-creds/rotate`).

### Self-Service Credential Rotation

Any authenticated identity with a linked NATS user — a `users` membership, a `things` record, or a `leaf_nodes` record — can rotate its own credential:

```
POST /api/me/nats-creds/rotate
```

It takes **no id parameter**: it only ever targets the caller's own linked identity, so there is no other identity it could be aimed at. Available to every role, including `dashboard`. Afterwards, re-read your own record to pick up the new `.creds`.

The reason this is a route rather than a permissive update rule is that a PocketBase rule cannot express a single-field allowlist, and the field that must stay closed is consequential — `nats_users.publish_permissions` is copied verbatim into the JWT the platform signs. **Revocation** is not part of the route; it stays an Owner/Admin action. See [Authorization §4](./authorization.md#4-the-row-scoped-credential-model).

---

## 2. Locations 

Locations define the physical or logical hierarchy of your environment. They answer the question: *"Where is this thing?"*

### Concepts

- **Hierarchy:** Locations support parent/child relationships (e.g., `Global > North America > Chicago > Warehouse A > Row 4`).
- **Location Code:** A unique, URL-friendly identifier (e.g., `CHI-W-A`), unique within the Organization. It namespaces the **Digital Twin** in the NATS Key-Value store, it is the join key a sibling app resolves a ticket or work order against, and it is the payload of the site's [QR label](#codes-and-qr-labels). **Immutable once set:** changing it orphans every twin key, label and external history pointing at it.
- **Metadata:** A flexible JSON field for storing site-specific data like time zones, contact info, or local gateway IPs.

### Mapping & Visualization

The UI provides two distinct ways to see your locations:

1.  **Geospatial Map:** A global view using **Leaflet** to plot locations based on Latitude and Longitude.
2.  **Floor Plans:** An image-overlay system. You can upload a JPG/PNG of a floor plan and "drag and drop" **Things** onto the map to represent their physical position in a room.

---

## 3. Things 

A **Thing** is any entity that produces or consumes data — or just an asset you want a record of. In Stone-Age.io, a Thing is a first-class **Auth Record**, and that one record doubles as the device's identity on the messaging fabric and the mesh. See [Architecture §3.1 — Inventory-as-Identity](./architecture.md#31-inventory-as-identity) for why the platform collapses those two registries into one.

**Pure inventory is a supported use.** The identity relations below are optional; a Thing with neither is an asset-tracking row and nothing more. Nothing on this page obliges you to put a device on the bus.

### Concepts

- **Identity:** Because Things are an authentication collection, they can log in to the PocketBase API directly to fetch their own configuration. An Owner or Admin can reset that password from the detail view if it is lost — it is shown once, and the old one stops working immediately.
- **Thing Code:** Similar to the Location code, this is used for NATS namespacing (e.g., `thing.LOC_01.SENSOR_01`), and it is likewise the join key for sibling apps and the payload of the device's [QR label](#codes-and-qr-labels). **Immutable once set**, for the same reasons.
- **Metadata:** Used to store device-specific state that doesn't change often, such as hardware revision, install date, or calibration offsets.
- **Active:** An Owner/Admin switch for taking the device out of service without deleting its record and history. **Deactivating is a real decommission** — the device is signed out immediately, cannot sign in again, and its NATS credential is revoked. The detail view banners the state, and the list greys the row. Reactivating issues a *new* `.creds` file; the old one stays revoked. See [Authorization §4.2](./authorization.md#42-taking-a-device-out-of-service).

### Infrastructure Binding

Binding is what turns an inventory row into a participant on the fabric. It is **optional and reversible** — the console's create form offers three modes per identity (`auto` to mint a new one, `link` to attach an existing one, `none` to leave it unbound), and `POST /api/org/things` performs the Thing and both identities in a single transaction so you never end up with a half-provisioned device.

A Thing is typically linked to:

- **A Thing Type:** The contract that declares what subjects the Thing uses and what message shapes it exchanges. See [Thing Types](./thing-types.md).
- **A NATS User:** To allow the device to publish telemetry. What it may publish or subscribe to comes from the `nats_roles` record assigned to that NATS user (plus any per-user overrides) — authored directly by an Owner or Admin, not derived from the Thing Type. See [Thing Types §5](./thing-types.md#5-relationship-to-nats-roles).
- **A Nebula Host:** To allow secure, encrypted access to the device for maintenance or SSH.

Both relations are **Owner/Admin only**. A `member` may create and edit a Thing but cannot set or change its `nats_user` or `nebula_host` — otherwise a member could re-point a Thing at a privileged identity, authenticate as the Thing, and read credentials that were never theirs. In practice this means a member-created Thing sits un-provisioned until an Owner or Admin links its identities. See [Authorization §2](./authorization.md#2-capability-matrix).

The subjects a Thing publishes to become the inputs to your Layer 1 rules — picking a clean Thing Code and subject namespace pattern is the first step in building automation that's easy to reason about later. The Thing Type makes that pattern declarative rather than implicit: rather than hoping every camera publishes on a sensible subject, the camera Thing Type declares the contract once and every camera of that type follows it.

---

## 4. Types 

Types provide a way to categorize your inventory and locations. They act as blueprints for classification and filtering. Location Types are purely for organization; Thing Types have grown into the platform's primary **contract layer** for describing what a participant does on the fabric.

- **Location Types:** Categorize your sites (e.g., `Campus`, `Building`, `Room`, `Cabinet`).
- **Thing Types:** The contract for a kind of participant on the fabric. A Thing Type declares a **subject prefix** (template like `camera.{location}.{thing}`), a set of **operations** (shareable verbs — publish, subscribe, request, reply — each with a message schema), and an optional **NATS role** that turns those operations into runtime permissions. See [Thing Types](./thing-types.md) for the full model.

Thing Types compose from two other collections that the UI also manages directly:

- **Thing Operations:** Shareable records describing individual verbs on the fabric. A single `heartbeat` operation record is typically linked from every Thing Type that emits heartbeats.
- **Message Schemas:** JSON Schema documents describing operation payloads, versioned via `(namespace, name, version)`.

All three (Thing Types, Thing Operations, Message Schemas) live under the **Types** menu group in the sidebar alongside Location Types. **Reading them is open to every role in the organization** — a member needs the contract to resolve subjects and validate payloads. **Creating, editing, and deleting them is Owner/Admin only.**

---

## 5. The User Interface Features

The UI is designed to be reactive and low-latency, connecting the Control Plane and Data Plane into a Single Pane of Glass.

### The Dashboard 

The Dashboard is a flexible grid system where you can build custom views:

- **Widgets:** Add Gauges, Charts, Switches, and Maps.
- **NATS-Native:** Most widgets subscribe directly to NATS subjects. Data never touches the database; it flows from the device to NATS to your browser.
- **Variables:** Define dashboard variables (e.g., `{{building_id}}`) to create a single dashboard that can be "switched" to show data for different sites/things/etc.
- **Thing Type-aware binding:** The Publisher widget can bind to a `Thing + Operation` pair. When bound, the subject auto-resolves from the Thing's context against the Thing Type's templates, and payload input renders as a schema-driven form when the operation has a linked message schema. See [Thing Types](./thing-types.md) for the contract model that powers this.

### The Digital Twin

Every Location and Thing with a valid **Code** gets a **Live State** panel on its detail view, showing the keys under `thing.<code>` or `location.<code>` in the organization's twin buckets. It is the same KV browser used for every other bucket, with a second bucket attached — so tree and flat views, filtering, revision history and the detail drawer all behave identically.

It has two tabs, because there are [two buckets](./architecture.md#41-two-buckets-one-writer-each):

- **Reported** (`twin`) is what the device says. It is **read-only** — the edge overwrites it, so an edit button here would be a lie: the value returns on the next sync.
- **Desired** (`twin_desired`) is what you want. This is the writable half, and it is a console user's actual control. Setpoints and configuration belong here; commands like `reboot` do not (send those as a message on `cmd.>` — a durable "reboot now" is a bug), and neither do thresholds or alarm ranges (those are [rules](./automation.md) over reported state).

Where the two disagree, the row shows the values themselves — `"auto" → "manual"` — rather than a status word, and the detail pane pairs them in adjacent columns. It says **differs**, never "pending": nothing in the platform pushes a desired value into a device, so a word implying a control loop in progress would be describing something that does not exist. `twin_desired` delivers the value to the edge's local KV; what acts on it is your firmware or your rules.

Only the keys present in a desired value are compared, so extra fields a device reports are ignored. That is deliberate — full equality would flip every assertion you ever set to "differs" the day a device starts reporting one new field.

The same KV buckets are what Layer 1 rules read and write for stateful operations like alarm stacking. See [Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state) for the full model, and [Automation](./automation.md) for the KV-state patterns.

> **Neither the console nor the platform server creates these buckets on its own.** The Control Plane holds the NATS Operator key but has no reach into an organization's own account, so it cannot provision them. Creation is the console's **Initialize** button, or `leaf-sync` at the edge — whichever gets there first defines the bucket, which is why the two retention configurations are kept in step deliberately.

### JetStream Streams and KV Buckets

Owners and Admins can manage the org's JetStream resources directly from the UI without dropping to the `nats` CLI. These views connect over the same NATS WebSocket session the rest of the UI uses, so changes take effect immediately.

- **Streams** (`/nats/streams`): create, edit, inspect, and delete JetStream streams. The form covers the common operational knobs — captured subjects, retention policy (`limits` / `interest` / `workqueue`), storage backend (`file` / `memory`), max-messages / max-bytes / max-age limits, replicas, discard policy, and duplicate window.
- **KV Buckets** (`/nats/kv`): create, configure, and inspect Key-Value buckets. The form covers history depth, max bucket size, max value size, TTL, and replicas. The detail view embeds a **KV Dashboard** that lets you browse keys, view current values, and watch live updates as keys change.

Both views appear in the sidebar only when the browser is connected to NATS — the operations execute against the live cluster, not against PocketBase. Layer 1 rules and stream processors consume the same streams and buckets you create here; the UI is a convenience surface, not a separate runtime.

### Codes and QR Labels

Any Location or Thing with a **Code** gets a **Label** button on its detail view, producing a provider-branded QR label to print and stick on the equipment. A record with no code gets no button — the payload *is* the code.

- **The payload is the bare code.** Not a web address, not `org/kind/code` — just `DOOR-1`. A sticker on a wall in a public corridor is something a stranger can replace, and a payload containing a URL would let a forged label send a person to arbitrary content. A bare in-system identifier means the worst a forged label achieves is opening the wrong record inside an app you were already signed in to. It also buys error correction: a short code at the highest correction level is a 21×21 symbol where the URL form of the same identifier needs 41×41 — four times the modules on an identically sized sticker, all of it spent on surviving scratches and grease rather than on repeating a hostname.
- **Scanning happens inside an app.** The [Scanner widget](./dashboards.md) reads these labels here; sibling apps read the *same* label with their own scanners and land on their own view of the record — a work-order history rather than a live state panel. Nothing ever fetches the decoded string as a destination, and there is deliberately no resolver service to look one up.
- **Sized to real stock.** 2″ × 1″ and 4″ × 2″, in millimetres rather than pixels, and both reserve a clear band down the centre for an RFID inlay's chip so one layout prints correctly on plain *or* RFID media. The **RFID stock** toggle reveals that reserved band so you can check it against your inlay's datasheet; it does not change the layout. Inlay geometry varies by vendor — treat the default as conservative, and print one before committing to a roll.
- **Every label prints its code in readable text.** That is not decoration. The symbol will eventually be scratched, greasy, or in a closet too dark to focus in, and reading the code aloud or typing it into a scanner's manual field is a designed path, not a fallback.
- **The Organization name is deliberately not printed.** A tenant name beside a device naming convention is free reconnaissance for anyone walking past. The provider's brand *is* printed — whoever finds broken equipment needs to know who services it.

Because codes are unique only within an Organization, a scanner resolves a code **globally and then disambiguates** rather than assuming a tenant: `DOOR-1` is exactly the code every organization independently invents, so a match list with a picker is honest where a silent guess would be somebody else's door. See [ADR 0002](./decisions/0002-organization-code-namespace.md).

### CRUD & Management

The platform provides a standard management interface for all entities. It uses a **Responsive List** pattern:

- **Desktop:** High-density tables for bulk management.
-  **Mobile:** Card-based layouts for on-the-go status checks and emergency control.
