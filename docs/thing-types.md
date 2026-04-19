# Thing Types

Thing Types are the **contract layer** of the Stone-Age.io fabric. They describe what a participant on the fabric does — what it publishes, what it subscribes to, what it answers — as declarative data, independent of any specific instance.

If a **Thing** is an instance of something on the fabric, a **Thing Type** is the contract that defines how that kind of thing behaves. A single IP camera is a Thing. The description "an IP camera publishes motion events, answers snapshot requests, and accepts PTZ commands" is the Thing Type.

This page explains what's in a Thing Type, how it composes with operations and message schemas, how the platform uses linked NATS roles to derive permissions, and where the boundary lies between contract (what belongs here) and platform behavior (what doesn't).

---

## 1. The Contract / Instance Model

Every Thing on the fabric has two parts:

- **The Thing instance** — a specific device, service, application, or agent. It has a unique code, a location, credentials, and metadata. It lives in the `things` collection.
- **The Thing Type it points to** — the contract that describes what a thing of this kind does on the fabric. It lives in the `thing_types` collection.

A Thing Type says "things of this kind publish motion events, answer snapshot requests, and accept PTZ commands." A Thing says "I am cam-042, located in warehouse-a, of type ip_camera." Together, the platform and its consumers know exactly what subjects cam-042 uses on NATS, what payloads it exchanges, and what permissions its NATS user needs.

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
| `nats_role` | Optional single relation to a `nats_roles` record. Linking a role turns this Thing Type's operations into permission content on that role (see §5). |

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

### The two platform resolvers

The platform ships reference resolvers so that consumers don't have to reinvent the logic:

- **Go resolver** — `internal/subjectresolver/`. Used by the NATS role sync hook (§5) to produce wildcard permission patterns (e.g., `*.camera.*.heartbeat`) rather than per-thing subjects.
- **TypeScript resolver** — `ui/src/utils/subjectResolver.ts`. Used by UI widgets to resolve against concrete Thing contexts.

Both implement the same resolution contract. Consumers are not required to use these resolvers — the platform stores templates as data, and any client can resolve however it wants. They exist because the role sync and the UI both need resolution and shouldn't duplicate the logic.

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

## 5. NATS Role Synchronization

A Thing Type's `nats_role` field is the connective tissue that turns the contract into runtime NATS permissions.

**The flow:**

1. You link a `nats_role` to a Thing Type.
2. A hook (`hooks/thing_type_role_sync.go`) fires on create/update of `thing_types` or `thing_type_operations`.
3. The hook walks the Thing Type's operations, resolves their subject patterns using the Go subject resolver, and writes them to the role's permission fields.
4. `pb-nats` continues to own the downstream chain — `nats_roles` → `nats_users` → JWTs and `.creds` files. The platform owns the *content* of the role; pb-nats owns the cryptographic identity.

**Capability-to-permission mapping:**

| Operation capability | Role permission field |
|---|---|
| `publish` | `publish_permissions` |
| `request` | `publish_permissions` (the request is published) |
| `subscribe` | `subscribe_permissions` |
| `reply` | `subscribe_permissions` (the reply subscribes to receive requests) |

Additionally, any `reply` operation on the Thing Type causes `allow_response = true` to be set on the role, so the NATS user can publish to the inbox subject when answering a request.

**Wildcarding for role permissions:**

Role permissions are per-role, not per-thing. A role grants permissions to *all* things that link it, so subjects are wildcarded:

- `{thing}` → `*`
- `{location}` → `*` unless the role scopes it to a specific location
- Other variables resolve to concrete values from the role's context

For example, a camera Thing Type with operation `motion` (suffix `motion`) and prefix `{location}.camera.{thing}` produces the wildcard pattern `*.camera.*.motion` on its linked role. Every camera using that role can publish to its own `warehouse-a.camera.cam-042.motion` subject; none can publish to another camera's subject because their individual permission paths don't include other cameras — the pattern is scoped by the role, but NATS enforces per-user resolution at connection time.

**Re-sync on operation changes:**

Editing a shared operation re-syncs every Thing Type that links it. A schema change, a suffix change, or a capability change propagates to all roles at once.

**Thing Types without a linked role:**

Thing Types with no `nats_role` produce no permissions. This is the correct default for existing records and for Thing Types used purely as documentation or inventory categorization without live NATS traffic.

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
nats_role:         → camera_role
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

### Resolved role permissions (camera_role)

With `camera_role` linked to the `ip_camera` Thing Type:

| Permission Field | Patterns |
|---|---|
| `publish_permissions` | `*.camera.*.heartbeat`, `*.camera.*.status`, `*.camera.*.motion` |
| `subscribe_permissions` | `*.camera.*.snapshot`, `*.camera.*.cmd.ptz` |
| `allow_response` | `true` (because `snapshot_reply` is a reply operation) |

---

## 7. Using Thing Types in the UI

Admin views live under the **Types** menu group in the sidebar, alongside Location Types:

- **Thing Types** — list and edit Thing Types. The form includes subject prefix, operations multi-select, NATS role picker, and capability summary.
- **Thing Operations** — list and edit the shareable operation records.
- **Message Schemas** — list and edit JSON Schema documents.

### Publisher widget integration

The dashboard `publisher` widget can bind to a **Thing + Operation** pair in its configuration. When bound:

- **Subject auto-resolves** from the Thing's context (org, location, thing, thing_type_code) against the Thing Type's prefix and the operation's suffix. The resolved subject renders read-only in the widget.
- **Payload input is schema-driven** if the operation has a linked message schema. Top-level primitive properties render as form fields via `JsonSchemaForm.vue`; nested objects and arrays fall back to JSON input.
- **On send**, the form model serializes to JSON and publishes.

Without a binding, the Publisher widget retains its legacy free-text subject and payload inputs.

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

## 9. Migration and Existing Data

Existing Thing Types without `subject_prefix`, `operations`, or `nats_role` values continue working exactly as before. The new fields are optional and additive:

- A Thing Type with no operations emits no subjects and grants no NATS permissions via role sync. It's a pure inventory/categorization record.
- A Thing Type with operations but no linked `nats_role` describes contracts but doesn't automatically generate NATS permissions. Consumers (CLI tools, UI widgets) can still use it for resolution and schema awareness.
- A Thing Type with operations and a linked role participates fully in the role sync.

The `capabilities` field values were widened from `pub`/`sub`/`req-reply` to `publish`/`subscribe`/`request`/`reply` as part of this feature. Existing records using the old values require a one-time data migration.

---

## 10. Where to Go Next

- **[Architecture](./architecture.md)** — how the Control Plane and Data Plane relate; where Thing Types sit in the Digital Twin model.
- **[Platform UI and Entities](./platform-ui-entities.md)** — the full inventory of entities the UI manages, including how Thing Types fit alongside Things and Locations.
- **[Connectivity](./connectivity.md)** — the NATS substrate that resolved subjects land on; subject namespacing conventions.
- **[Automation](./automation.md)** — rules that consume the subjects Thing Types declare.
