# Thing Types

Thing Types are the **contract layer** of the Stone-Age.io fabric. They describe what a participant on the fabric does — what it publishes, what it subscribes to, what it answers — as declarative data, independent of any specific instance.

If a **Thing** is an instance of something on the fabric, a **Thing Type** is the contract that defines how that kind of thing behaves. A single IP camera is a Thing. The description "an IP camera publishes motion events, answers snapshot requests, and accepts PTZ commands" is the Thing Type.

This page explains what's in a Thing Type, how it composes with operations and message schemas, how consumers resolve its subject templates, and where the boundary lies between contract (what belongs here) and platform behavior (what doesn't).

Thing Types are purely declarative — they describe the message contract. NATS roles and their permissions are managed directly on the `nats_roles` collection.

---

## 1. The Contract / Instance Model

Every Thing on the fabric has two parts:

- **The Thing instance** — a specific device, service, application, or agent. It has a unique code, a location, credentials, and metadata. It lives in the `things` collection.
- **The Thing Type it points to** — the contract that describes what a thing of this kind does on the fabric. It lives in the `thing_types` collection.

A Thing Type says "things of this kind publish motion events, answer snapshot requests, and accept PTZ commands." A Thing says "I am cam-042, located in warehouse-a, of type ip_camera." Together, the platform and its consumers know exactly what subjects cam-042 uses on NATS and what payloads it exchanges.

This separation is the key to the whole design. Contracts are shared across many instances. Instances don't re-declare their behavior — they reference the contract that already describes it.

---

## 2. The Three Collections

Thing Types compose from three collections that work together.

### `thing_types`

The contract record. Describes a kind of participant on the fabric.

Key fields:

| Field | Purpose |
|---|---|
| `code` | URL-safe identifier, e.g. `ip_camera`. Used in subject templates and as a stable reference. |
| `name`, `description` | Human-readable labels. |
| `subject_prefix` | Template string like `{location}.camera.{thing}`. Stored literally. Empty values default to `{location}.{thing_type_code}.{thing}` when consumers resolve. |
| `capabilities` | Coarse-grained summary of what this Thing Type does. Values: `publish`, `subscribe`, `request`, `reply`. Typically maintained as the union of its operations' capabilities. |
| `operations` | Multi-relation to `thing_type_operations` — the verbs this Thing Type declares. |

### `thing_type_operations`

Shareable verbs. Each record describes one thing a Thing Type can do on the fabric.

Key fields:

| Field | Purpose |
|---|---|
| `name` | Operation identifier, lowercase snake_case, e.g. `motion`, `heartbeat`, `ptz`. |
| `capability` | One of `publish`, `subscribe`, `request`, `reply`. |
| `subject_suffix` | Appended to the Thing Type's `subject_prefix` to form the full subject. Stored literally. |
| `schema` | Relation to `message_schemas` describing the operation's payload. |
| `description` | Human-readable purpose. |

Operations are uniquely identified by `(organization, name, capability)`, which means the *same name* can exist for different capabilities — a `heartbeat` publish operation and a hypothetical `heartbeat` subscribe operation can coexist, since they describe genuinely different verbs.

**Operations are shareable across Thing Types.** A single `heartbeat` publish operation is typically linked from every Thing Type in the org that emits heartbeats — cameras, gateways, sensors, VMS servers. This is the feature, not a side effect (§4).

### `message_schemas`

The payload shapes referenced by operations. Each record is a JSON Schema document.

Key fields:

| Field | Purpose |
|---|---|
| `namespace` | Grouping identifier, e.g. `common` or `ip_camera`. |
| `name` | Schema identifier within its namespace, e.g. `heartbeat` or `motion`. |
| `version` | Semver, e.g. `1.0.0`. |
| `format` | `json_schema` in v1. |
| `schema` | The actual JSON Schema document. |

Schemas are uniquely identified by `(organization, namespace, name, version)`. A new version is a new record; old versions remain valid for existing operations. No auto-migration — if a schema's semantics change, publish a new version and update the operation(s) that should use it.

All three collections are org-scoped via the standard tenancy API rules.

---

## 3. Subject Templates and Resolution

Subject prefixes and suffixes are stored as **literal template strings**. The value `{location}.camera.{thing}` in a `subject_prefix` field is exactly the text stored — the curly braces are part of the value.

### Reserved variables

Consumers resolve templates against a Thing's context using these reserved variables:

| Variable | Source |
|---|---|
| `{org}` | `things.organization.code` |
| `{location}` | `things.location.code` |
| `{thing}` | `things.code` |
| `{thing_type_code}` | `things.type.code` |

### Default prefix

When a Thing Type's `subject_prefix` is empty, consumers use `{location}.{thing_type_code}.{thing}` as the default. This covers the common case and removes boilerplate for Thing Types that don't need a bespoke layout.

### The platform resolver

The platform ships a reference TypeScript resolver at `ui/src/utils/subjectResolver.ts`. It's used by UI widgets (the Publisher widget in particular) to resolve templates against concrete Thing contexts. Consumers are not required to use it — the platform stores templates as data, and any client can resolve them however it wants. It exists so the UI doesn't have to reinvent the substitution logic.

### Resolution example

Given:

```
thing_type.subject_prefix:  {location}.camera.{thing}
operation.subject_suffix:   motion
thing.code:                 cam-042
thing.location.code:        warehouse-a
```

A consumer resolves the subject to `warehouse-a.camera.cam-042.motion`. A wildcard subscription `warehouse-a.camera.*.motion` gives every camera's motion events at that site. The prefix/suffix split is what makes wildcard discovery natural.

---

## 4. Why Operations Are Shareable

Operations are designed to be linked from many Thing Types, not owned by one.

Consider `heartbeat`. Nearly every kind of participant on the fabric emits one — cameras, gateways, sensors, VMS servers, AI agents, badge readers. The heartbeat contract is the same in all cases: the subject suffix is `heartbeat`, the payload is a liveness message, the capability is `publish`.

With shareable operations, there's exactly one `heartbeat` operation record in the organization, linked from every Thing Type that emits one. The benefits are direct:

- **One canonical definition** across the deployment. No drift between Thing Types.
- **Schema updates propagate.** Bumping the heartbeat schema to a new version and updating the operation updates every Thing Type that uses it.
- **Rules generalize.** A rule that reacts to "anything emitting a heartbeat" can do so cleanly because the operation is the same record everywhere.
- **Thing Types stay compositional.** A new Thing Type is primarily a list of existing operations plus any novel ones it introduces.

The tradeoff: a shared operation's `subject_suffix` and `schema` must be Thing-Type-agnostic. A shared `heartbeat` has suffix `heartbeat` everywhere. When that's not what you want — for example, a specialized operation with a schema that only makes sense for one Thing Type — create a Thing-Type-specific operation with a distinct name.

Deleting a Thing Type does not delete its operations. The operations persist and may still be linked from other Thing Types. If an operation becomes fully unlinked, it remains as a harmless orphan until someone cleans it up.

---

## 5. Relationship to NATS Roles

Thing Types describe what a participant does on the fabric. NATS roles control what a NATS user is allowed to publish to or subscribe from. These are **independent concerns** — Thing Types do not derive role permissions.

Operators author NATS role permissions directly on the `nats_roles` record. A Thing Type's subject templates are a useful reference when authoring those permissions — the patterns a role needs to grant look like the resolved wildcard forms of the Thing Type's operations — but the translation is manual and deliberate.

---

## 6. A Complete Example

### Shared operations

Records in `thing_type_operations`:

```
name:              heartbeat
capability:        publish
subject_suffix:    heartbeat
schema:            → common/heartbeat@1.0.0
description:       Generic liveness heartbeat.

name:              status
capability:        publish
subject_suffix:    status
schema:            → common/status@1.0.0
description:       Online/offline + status message.
```

### Camera-specific operations

```
name:              motion
capability:        publish
subject_suffix:    motion
schema:            → ip_camera/motion@1.0.0

name:              snapshot_request
capability:        request
subject_suffix:    snapshot
schema:            → ip_camera/snapshot_request@1.0.0

name:              snapshot_reply
capability:        reply
subject_suffix:    snapshot
schema:            → ip_camera/snapshot_reply@1.0.0

name:              ptz
capability:        subscribe
subject_suffix:    cmd.ptz
schema:            → ip_camera/ptz_command@1.0.0
```

Note that `snapshot_request` and `snapshot_reply` are two separate operations that share a subject suffix. A Thing Type that *offers* snapshots links `snapshot_reply`; a Thing Type that *asks for* them links `snapshot_request`.

### The Thing Type record

```
code:              ip_camera
name:              IP Camera
description:       Network camera with motion detection and PTZ
subject_prefix:    {location}.camera.{thing}
capabilities:      [publish, subscribe, reply]
operations:        [heartbeat, status, motion, snapshot_reply, ptz]
```

### A referenced schema

```
namespace:   common
name:        heartbeat
version:     1.0.0
format:      json_schema
description: Generic liveness + identity heartbeat used by any Thing.
schema:
  {
    "type": "object",
    "required": ["timestamp", "uptime_seconds"],
    "properties": {
      "timestamp":        { "type": "string", "format": "date-time" },
      "uptime_seconds":   { "type": "integer", "minimum": 0 },
      "firmware_version": { "type": "string" }
    }
  }
```

### Resolved subjects for an IP camera instance

Thing: `code = cam-042`, `type = ip_camera`, located at `warehouse-a`.

| Operation | Capability | Resolved Subject |
|---|---|---|
| `heartbeat` | publish | `warehouse-a.camera.cam-042.heartbeat` |
| `status` | publish | `warehouse-a.camera.cam-042.status` |
| `motion` | publish | `warehouse-a.camera.cam-042.motion` |
| `snapshot_reply` | reply | `warehouse-a.camera.cam-042.snapshot` |
| `ptz` | subscribe | `warehouse-a.camera.cam-042.cmd.ptz` |

---

## 7. Using Thing Types in the UI

Admin views live under the **Types** menu group in the sidebar, alongside Location Types:

- **Thing Types** — list and edit Thing Types. The form includes identity fields (name, description, code), subject prefix, capabilities multi-select, and an operations multi-select with a quick-add modal for creating new operations inline.
- **Thing Operations** — list and edit the shareable operation records. The form enforces the `^[a-z0-9_]+$` name pattern, requires a `capability`, requires a `subject_suffix`, and offers an optional schema relation with a quick-add modal.
- **Message Schemas** — list and edit JSON Schema documents. The form enforces the namespace/name pattern and a semver `version`. A built-in **"Infer from sample"** helper accepts a JSON sample and generates a starting schema, which you can then refine in either the visual schema builder or the raw JSON editor.

### Publisher widget integration

The dashboard `publisher` widget can bind to a **Thing + Operation** pair in its configuration. When bound:

- **Subject auto-resolves** from the Thing's context (org, location, thing, thing_type_code) against the Thing Type's prefix and the operation's suffix. The resolved subject renders read-only in the widget.
- **Payload input is schema-driven** if the operation has a linked message schema. Top-level primitive properties render as form fields via `JsonSchemaForm.vue`; nested objects and arrays fall back to JSON input.
- **On send**, the form model serializes to JSON and publishes.

Without a binding, the Publisher widget falls back to free-text subject and payload inputs.

This integration is a direct consumer of the Thing Type primitive — the widget knows the subject because it resolved the template, and it knows the payload shape because it read the schema. Other widgets (Gauge, Chart, Console) will gain similar bindings as they evolve; the primitive is already in place.

---

## 8. What Thing Types Don't Describe

Thing Types describe the **message contract** between a Thing and the fabric. They do not describe platform behavior, runtime configuration, or business logic.

Not in a Thing Type or its operations:

- **State machines or lifecycles.** Alarm status, presence, session tracking — belong in NATS KV and rule-router rules.
- **Rate limits, priorities, throttles.** Belong in NATS account limits, the NATS role, or rule-router rules.
- **Enabled / disabled flags.** Belong on the Thing instance as runtime state.
- **Ownership, cost center, environment tags.** Belong on the Thing instance's metadata.
- **Alert thresholds, notification routing.** Belong in rules.
- **Historical retention, TSDB export config.** Belong in observability config.
- **Inheritance or composition of Thing Types.** Flat types only. Shared behavior via shared operations.

The test for any proposed new field: *does it describe the message contract between a Thing and the fabric, or does it describe platform behavior around that contract?* Contract fields (like `content_type` or `qos`) are in scope. Everything else has a better home and that home already exists.

---

## 9. Optional Fields

`subject_prefix` and `operations` are both optional:

- A Thing Type with no operations is a pure inventory/categorization record — it emits no subjects and defines no contract.
- A Thing Type with operations describes contracts that consumers (UI widgets, CLI tools, rules) can use for subject resolution and schema awareness.

The `capabilities` field accepts `publish`, `subscribe`, `request`, and `reply`.

---

## 10. Where to Go Next

- **[Architecture](./architecture.md)** — how the Control Plane and Data Plane relate; where Thing Types sit in the Digital Twin model.
- **[Platform UI and Entities](./platform-ui-entities.md)** — the full inventory of entities the UI manages, including how Thing Types fit alongside Things and Locations.
- **[Connectivity](./connectivity.md)** — the NATS substrate that resolved subjects land on; subject namespacing conventions.
- **[Automation](./automation.md)** — rules that consume the subjects Thing Types declare.
