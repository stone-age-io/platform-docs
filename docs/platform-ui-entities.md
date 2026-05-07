# Platform Entities & UI

The Stone Age Console provides a unified interface for managing the logical and physical structures of your IoT environment or Event-Driven Architecture. This document explains the primary entities used to organize your data and how they interact with the user interface.

These entities live in the **Control Plane** (PocketBase) — they're the source of truth for identity, inventory, and relationships. At provisioning time and at runtime, they shape what flows through the **Data Plane** (NATS subjects, KV buckets, Nebula certificates). See [Architecture](./architecture.md) for the Control/Data Plane split in full.

---

## 1. Organizations & Memberships

Organizations are the top-level container for all data and infrastructure. Every resource in the platform belongs to an Organization and platform Users can belong to multiple Organizations.

### Organizations

- **Isolation:** Each Organization receives its own private NATS Account and Nebula Certificate Authority.
- **Ownership:** An organization is managed by an **Owner** (the creator) who has full control over billing and deletion.
- **Invites:** Owners and Admins can invite users to join their organization via email. Invites generate a secure token used for onboarding.

### Memberships

A Membership binds a PocketBase User to an Organization.

- **Roles (per-organization):**
    - `Owner`: Full access, including deletion of the Org.
    - `Admin`: Can manage users, locations, and infrastructure.
    - `Member`: Read-only or restricted access to dashboards and data.
    - `Badge`: Restricted to the Badge view and a badge-only dashboard — used for kiosk- or wallet-style identity surfaces where the user does not need general platform access.
- **Identity Linking:** A critical feature of the Membership is the **Linked NATS Identity**. This allows a human user to browse the NATS bus using specific credentials assigned to their membership for that specific Organization. Since users can be members of multiple Organizations, this NATS user relation is stored on the membership record itself.

### Cross-Organization Roles

Two roles exist *outside* the per-organization Membership model and apply to the user account itself:

- **Operator** (`users.is_operator = true`): Can create, edit, and delete Organizations and invite users into any Org. Operators are the day-to-day platform administrators and are the recommended identity for managing the system from the UI. The first Operator is created by the `bootstrap` command.
- **SuperUser** (`_superusers` collection): A backend service account with full database access regardless of API rules. Created via `./stone-age superuser upsert` and intended for infrastructure-level management — schema imports, NATS Operator/System Account seeding, and other platform-level concerns. SuperUsers are not members of any organization; they sign in at the embedded admin UI (`/_/`).

### Permissions Matrix

A coarse summary of what each role can do in the UI. Fine-grained authorization is enforced by PocketBase API rules on each collection; the UI hides actions a user cannot perform.

| Capability | Owner | Admin | Member | Badge | Operator¹ | SuperUser |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| View dashboards, Things, Locations | ✅ | ✅ | ✅ | dashboard only | ✅ | ✅ |
| Create / edit Things and Locations | ✅ | ✅ | — | — | ✅ | ✅ |
| Manage Thing Types, Operations, Schemas | ✅ | ✅ | — | — | ✅ | ✅ |
| Manage NATS users, roles, imports/exports | ✅ | ✅ | — | — | ✅ | ✅ |
| Manage JetStream streams and KV buckets | ✅ | ✅ | — | — | ✅ | ✅ |
| Manage Nebula networks and hosts | ✅ | ✅ | — | — | ✅ | ✅ |
| Invite / manage org members | ✅ | ✅ | — | — | ✅ | ✅ |
| Create / edit / delete Organizations | — | — | — | — | ✅ | ✅ |
| Schema imports, Operator key custody | — | — | — | — | — | ✅ |

¹ Operator is a flag on the user record (`is_operator`), independent of per-org Membership role. An Operator without a Membership in a given org still cannot read that org's data — Membership is what grants tenant-data access; the Operator flag grants org-management authority.

---

## 2. Locations 

Locations define the physical or logical hierarchy of your environment. They answer the question: *"Where is this thing?"*

### Concepts

- **Hierarchy:** Locations support parent/child relationships (e.g., `Global > North America > Chicago > Warehouse A > Row 4`).
- **Location Code:** A unique, URL-friendly identifier (e.g., `CHI-W-A`). This code is used to namespace the **Digital Twin** in the NATS Key-Value store.
- **Metadata:** A flexible JSON field for storing site-specific data like time zones, contact info, or local gateway IPs.

### Mapping & Visualization

The UI provides two distinct ways to see your locations:

1.  **Geospatial Map:** A global view using **Leaflet** to plot locations based on Latitude and Longitude.
2.  **Floor Plans:** An image-overlay system. You can upload a JPG/PNG of a floor plan and "drag and drop" **Things** onto the map to represent their physical position in a room.

---

## 3. Things 

A **Thing** is any entity that produces/consumes data (or even just an entry for inventory purposes / asset tracking). In Stone-Age.io, a Thing is a first-class **Auth Record**.

### Concepts

- **Identity:** Because Things are an authentication collection, they can log in to the PocketBase API directly to fetch their own configuration.
- **Thing Code:** Similar to the Location code, this is used for NATS namespacing (e.g., `thing.LOC_01.SENSOR_01`).
- **Metadata:** Used to store device-specific state that doesn't change often, such as hardware revision, install date, or calibration offsets.

### Infrastructure Binding

A Thing is typically linked to:

- **A Thing Type:** The contract that declares what subjects the Thing uses and what message shapes it exchanges. See [Thing Types](./thing-types.md).
- **A NATS User:** To allow the device to publish telemetry. Permissions can be derived from the Thing Type's linked `nats_role`.
- **A Nebula Host:** To allow secure, encrypted access to the device for maintenance or SSH.

The subjects a Thing publishes to become the inputs to your Layer 1 rules — picking a clean Thing Code and subject namespace pattern is the first step in building automation that's easy to reason about later. The Thing Type makes that pattern declarative rather than implicit: rather than hoping every camera publishes on a sensible subject, the camera Thing Type declares the contract once and every camera of that type follows it.

---

## 4. Types 

Types provide a way to categorize your inventory and locations. They act as blueprints for classification and filtering. Location Types are purely for organization; Thing Types have grown into the platform's primary **contract layer** for describing what a participant does on the fabric.

- **Location Types:** Categorize your sites (e.g., `Campus`, `Building`, `Room`, `Cabinet`).
- **Thing Types:** The contract for a kind of participant on the fabric. A Thing Type declares a **subject prefix** (template like `{location}.camera.{thing}`), a set of **operations** (shareable verbs — publish, subscribe, request, reply — each with a message schema), and an optional **NATS role** that turns those operations into runtime permissions. See [Thing Types](./thing-types.md) for the full model.

Thing Types compose from two other collections that the UI also manages directly:

- **Thing Operations:** Shareable records describing individual verbs on the fabric. A single `heartbeat` operation record is typically linked from every Thing Type that emits heartbeats.
- **Message Schemas:** JSON Schema documents describing operation payloads, versioned via `(namespace, name, version)`.

All three (Thing Types, Thing Operations, Message Schemas) live under the **Types** menu group in the sidebar alongside Location Types.

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

Every Location and Thing with a valid **Code** has a dedicated Digital Twin view. 

- This component shows the live state stored in the NATS KV bucket. 
- You can edit values directly in the UI (e.g., changing a `set_point`), and the update is published to NATS instantly for the device to receive.

The same KV buckets that back the Digital Twin UI are what Layer 1 rules read and write for stateful operations like alarm stacking. See [Architecture](./architecture.md) for the full Digital Twin concept, and [Automation](./automation.md) for the KV-state patterns.

### JetStream Streams and KV Buckets

Owners and Admins can manage the org's JetStream resources directly from the UI without dropping to the `nats` CLI. These views connect over the same NATS WebSocket session the rest of the UI uses, so changes take effect immediately.

- **Streams** (`/nats/streams`): create, edit, inspect, and delete JetStream streams. The form covers the common operational knobs — captured subjects, retention policy (`limits` / `interest` / `workqueue`), storage backend (`file` / `memory`), max-messages / max-bytes / max-age limits, replicas, discard policy, and duplicate window.
- **KV Buckets** (`/nats/kv`): create, configure, and inspect Key-Value buckets. The form covers history depth, max bucket size, max value size, TTL, and replicas. The detail view embeds a **KV Dashboard** that lets you browse keys, view current values, and watch live updates as keys change.

Both views appear in the sidebar only when the browser is connected to NATS — the operations execute against the live cluster, not against PocketBase. Layer 1 rules and stream processors consume the same streams and buckets you create here; the UI is a convenience surface, not a separate runtime.

### CRUD & Management

The platform provides a standard management interface for all entities. It uses a **Responsive List** pattern:

- **Desktop:** High-density tables for bulk management.
-  **Mobile:** Card-based layouts for on-the-go status checks and emergency control.
