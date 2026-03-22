# Platform Entities & UI

The Stone Age Console provides a unified interface for managing the logical and physical structures of your IoT environment or Event Driven Architecture. This document explains the primary entities used to organize your data and how they interact with the user interface.

---

## 1. Organizations & Memberships

Organizations are the top-level container for all data and infrastructure. Every resource in the platform belongs to an Organization and platform Users can belong to multiple Organizations.

### Organizations

- **Isolation:** Each Organization receives its own private NATS Account and Nebula Certificate Authority.
- **Ownership:** An organization is managed by an **Owner** (the creator) who has full control over billing and deletion.
- **Invites:** Owners and Admins can invite users to join their organization via email. Invites generate a secure token used for onboarding.

### Memberships

A Membership binds a PocketBase User to an Organization.

- **Roles:** 
    - `Owner`: Full access, including deletion of the Org.
    - `Admin`: Can manage users, locations, and infrastructure.
    - `Member`: Read-only or restricted access to dashboards and data.
- **Identity Linking:** A critical feature of the Membership is the **Linked NATS Identity**. This allows a human user to browse the NATS bus using specific credentials assigned to their membership for that specific Organization. Since users can be members of multiple Organizations, this NATS user relation is stored on the membership record itself.

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

A **Thing** is any entity that produces/consumes data (or even just an entry for inventory purposes/asset tracking). In Stone-Age, a Thing is a first-class **Auth Record**.

### Concepts

- **Identity:** Because Things are an authentication collection, they can log in to the PocketBase API directly to fetch their own configuration.
- **Thing Code:** Similar to the Location code, this is used for NATS namespacing (e.g., `thing.LOC_01.SENSOR_01`).
- **Metadata:** Used to store device-specific state that doesn't change often, such as hardware revision, install date, or calibration offsets.

### Infrastructure Binding

A Thing is typically linked to:

- **A NATS User:** To allow the device to publish telemetry.
- **A Nebula Host:** To allow secure, encrypted access to the device for maintenance or SSH.

---

## 4. Types 

Types provide a way to categorize your inventory and locations. They act as blueprints for classification and filtering.

- **Location Types:** Categorize your sites (e.g., `Campus`, `Building`, `Room`, `Cabinet`).
- **Thing Types:** Define the "Capabilities" of a device. For example, a `Smart Meter` type might define capabilities like `publish` and `request-reply`, informing the UI what widgets are appropriate for that device.

---

## 5. The User Interface Features

The UI is designed to be reactive and low-latency, connecting the Control Plane and Data Plane into a Single Pane of Glass.

### The Dashboard 

The Dashboard is a flexible grid system where you can build custom views:

- **Widgets:** Add Gauges, Charts, Switches, and Maps.
- **NATS-Native:** Most widgets subscribe directly to NATS subjects. Data never touches the database; it flows from the device to NATS to your browser.
-  **Variables:** Define dashboard variables (e.g., `{{building_id}}`) to create a single dashboard that can be "switched" to show data for different sites/things/etc.

### The Digital Twin 

Every Location and Thing with a valid **Code** has a dedicated Digital Twin view. 

- This component shows the live state stored in the NATS KV bucket. 
- You can edit values directly in the UI (e.g., changing a `set_point`), and the update is published to NATS instantly for the device to receive.

### CRUD & Management

The platform provides a standard management interface for all entities. It uses a **Responsive List** pattern:

- **Desktop:** High-density tables for bulk management.
-  **Mobile:** Card-based layouts for on-the-go status checks and emergency control.
