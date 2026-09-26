# Thing Types

Thing Types are the **contract layer** of the Stone-Age.io fabric. They describe what a participant on the fabric does — what it publishes, what it subscribes to, what it answers — as declarative data, independent of any specific instance.

If a **Thing** is an instance of something on the fabric, a **Thing Type** is the contract that defines how that kind of thing behaves. A single IP camera is a Thing. The description "an IP camera publishes motion events, answers snapshot requests, and accepts PTZ commands" is the Thing Type.

This page explains what's in a Thing Type, how it composes with operations, how consumers resolve its subject templates, and where the boundary lies between contract (what belongs here) and platform behavior (what doesn't).

> **Dropped in the 2026-09 cleanup.** A third collection, `message_schemas`, used to hold a JSON Schema per operation. Nothing validated against it — there is no JSON Schema validator anywhere in the platform — and its only reader was the Publisher widget's payload form. `thing_types.capabilities` (a hand-maintained union of its operations' capabilities) and `thing_types.nats_role` (a relation read by nothing) went with it. Operations, subject prefixes, and per-operation capabilities all stay.

Thing Types are purely declarative — they describe the message contract. NATS roles and their permissions are managed directly on the `nats_roles` collection, which is **Owner/Admin only** for reads as well as writes: a role's permission fields are copied verbatim into the JWT the platform signs, so write access to that collection is equivalent to granting NATS permissions. See [Authorization](./authorization.md).

---

## 1. The Contract / Instance Model

Every Thing on the fabric has two parts:

- **The Thing instance** — a specific device, service, application, or agent. It has a unique code, a location, credentials, and metadata. It lives in the `things` collection.
- **The Thing Type it points to** — the contract that describes what a thing of this kind does on the fabric. It lives in the `thing_types` collection.

A Thing Type says "things of this kind publish motion events, answer snapshot requests, and accept PTZ commands." A Thing says "I am CA-9KD-4PX, located in warehouse-a, of type ip_camera." Together, the platform and its consumers know exactly what subjects CA-9KD-4PX uses on NATS and what payloads it exchanges.

This separation is the key to the whole design. Contracts are shared across many instances. Instances don't re-declare their behavior — they reference the contract that already describes it.

---

## 2. The Two Collections

Thing Types compose from two collections that work together.

### `thing_types`

The contract record. Describes a kind of participant on the fabric.

Key fields:

| Field | Purpose |
|---|---|
| `code` | Identifier, e.g. `ip_camera`. Used in subject templates and as a stable reference. Must match `^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$` — see [What a code may contain](#what-a-code-may-contain). **Frozen once set:** the update rule refuses any change to it. |
| `name`, `description` | Human-readable labels. |
| `prefix` | Optional, 1–4 capital letters (`^[A-Z]{1,4}$`), e.g. `CA`. Copied into every code the platform generates for a Thing of this type (`CA-9KD-4PX`); see [Generated codes](#generated-codes). Unique within the organization, and never the same as a Location Type's prefix. Editable: changing it affects future codes only. |
| `subject_prefix` | Template string like `camera.{thing}`. Stored literally. Empty values default to `{thing_type_code}.{thing}` when consumers resolve. |
| `operations` | Multi-relation to `thing_type_operations` — the verbs this Thing Type declares. |
| `metadata_schema` | A JSON Schema describing the inventory fields a Thing of this type carries in its `metadata` — what the Thing form renders (§7). Not a message contract; nothing validates a payload against it. |

### `thing_type_operations`

Shareable verbs. Each record describes one thing a Thing Type can do on the fabric.

Key fields:

| Field | Purpose |
|---|---|
| `name` | Operation identifier, lowercase snake_case, e.g. `motion`, `heartbeat`, `ptz`. |
| `capability` | One of `publish`, `subscribe`, `request`, `reply`. |
| `subject_suffix` | Appended to the Thing Type's `subject_prefix` to form the full subject. Stored literally, and may use the same variables as the prefix (§3). |
| `description` | Human-readable purpose. |

Operations are uniquely identified by `(organization, name, capability)`, which means the *same name* can exist for different capabilities — a `heartbeat` publish operation and a hypothetical `heartbeat` subscribe operation can coexist, since they describe genuinely different verbs.

**Operations are shareable across Thing Types.** A single `heartbeat` publish operation is typically linked from every Thing Type in the org that emits heartbeats — cameras, gateways, sensors, VMS servers. This is the feature, not a side effect (§4).

Both collections are org-scoped via the standard tenancy API rules.

---

## 3. Subject Templates and Resolution

Subject prefixes and suffixes are stored as **literal template strings**. The value `camera.{thing}` in a `subject_prefix` field is exactly the text stored — the curly braces are part of the value.

### Reserved variables

Consumers join the prefix and the operation's suffix first, then resolve the whole string against a Thing's context. A variable therefore works in either half: a suffix of `cmd.{thing}.ack` resolves the same way a prefix does. These are the reserved variables:

| Variable | Source |
|---|---|
| `{org}` | `things.organization.code` |
| `{location}` | `things.location.code` |
| `{thing}` | `things.code` |
| `{thing_type_code}` | `things.type.code` |

A variable with nothing to resolve to is left literal in the subject, visibly unresolved. That is deliberate: a blank would produce an empty token, a subject that looks valid and matches nothing. In practice:

- **Every Thing and Location now has a code.** One saved without a code gets a generated one ([Generated codes](#generated-codes)), so `{thing}` and `{location}` always have something to resolve to. A record created before that rule can still have a blank code; the Publisher widget then fills `{thing}` with the record id, which is a valid token but not a stable handle.
- **An organization without a code leaves `{org}` literal**, rather than substituting its name, which can contain spaces and dots. Every organization created today gets a code ([ADR 0002](./decisions/0002-organization-code-namespace.md): ids for storage, codes for addressing).
- **A Thing with no location leaves `{location}` literal**, which is one more reason not to put it in a prefix for anything that moves or is not yet placed.

### Default prefix

When a Thing Type's `subject_prefix` is empty, consumers use `{thing_type_code}.{thing}` as the default ([ADR 0003](./decisions/0003-human-friendly-codes-and-default-subject.md)):

- **Family-first**, so a single JetStream stream can capture everything for one kind of Thing (e.g. a `SENSOR` stream binding `sensor.>`). Putting the fixed dimension at position 0 makes stream filters concrete instead of wildcarded. You never have to write `*.sensor.>` to capture "all sensors", and streams stop overlapping by accident.
- **No location.** Things move, and a subject resolved from a Thing's current location would move with it (see the first constraint below). Uniqueness never needed the location: a Thing code is unique within its organization, and the organization is the NATS account.

Before ADR 0003 the default was `{thing_type_code}.{location}.{thing}`. A Thing Type that wants the location in its subjects now says so with an explicit prefix, such as `freezer.{location}.{thing}` for equipment bolted to a building.

### Subject layout past the default is guidance

The platform enforces two things about subjects: what an empty prefix resolves to, and the [character rules](#what-a-code-may-contain) that make a code a safe token. Everything else is the account owner's to design, and a prefix can carry as many literal tokens as the layout needs. The demo's access-control hardware uses `acc.{location}.door.{thing}`, and its kiosks use `kiosk.{thing}`, because those are the real subject hierarchies of the apps that drive them. `acc.>` and `kiosk.>` then capture everything each app does.

The layout we suggest as a starting point:

> Token 0 is a **kind**: a Thing Type code, `agents`, or an application's namespace. Token 1 is the **code** of the thing or instance. Everything after that belongs to the kind, and is usually built from operation suffixes.

An application can use a bare `{app-identifier}.…`, the same shape as a Thing Type, or group every application under one root such as `app.{app}.…`. The demo does the second: `app.wms.{thing}`, `app.kiosk.{thing}`. That keeps its kiosk controller out of `kiosk.>`, which belongs to the kiosk nodes. Token 0 is shared between Thing Type codes and application namespaces, and the same organization admin controls both, so the platform does not police a clash.

### What a code may contain

`^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$` — letters, digits, `-` and `_`, starting with a letter or digit, 63 characters maximum. Enforced on `things.code`, `locations.code`, `thing_types.code` and `location_types.code`.

Mixed case is deliberate. These codes are the string stencilled on the hardware — `DOOR-1`, `KC-DC1` and `GW-KC-01` are what a tech reads out loud — so folding them to lowercase would make the label and the record disagree. An Organization code is the exception: it is slugified from a name and never typed by an installer, so it stays lowercase-only.

**A code is stored as typed, but uniqueness ignores case.** `cam-1` and `CAM-1` cannot both exist in one organization. Subjects, permissions and twin keys use the stored spelling exactly, because NATS is case-sensitive. That is also why two spellings must not coexist: they would be two identities with two subject namespaces that nobody can tell apart when reading the code aloud, and each would work on its own, so nothing would ever error. Lookups a person makes, such as a code typed into a scanner, can ignore case safely for the same reason (`code:lower = "{value:lower}"` in the [Scanner widget](./dashboards.md)).

Each excluded character is excluded for a concrete reason:

- **`.`** would split one subject token into two. The subject a publisher computes and the subject a subscriber's filter expects stop being the same string, and nothing errors — messages simply stop arriving.
- **`*` and `>`** are the NATS wildcards. A code containing one widens any permission pattern built from it, from a single identity to every identity of that kind. This is the security-relevant case, because NATS permissions are copied verbatim into a signed JWT.
- **A space** breaks the JetStream domain that an edge site's code becomes.
- **63 characters** is the RFC 1123 label limit, the tightest of the places a code lands.

A code that predates the validator keeps working and stays readable. It simply cannot be saved again until someone corrects it — and because `code` is frozen in the API rules, "someone" means a superuser in the PocketBase admin panel (`/_/`). Nothing rewrites codes in bulk, because a code is printed on a label and baked into a signed subject.

### Generated codes

A Thing or Location saved without a code gets one from the server ([ADR 0003](./decisions/0003-human-friendly-codes-and-default-subject.md)):

- **Shape:** `PFX-XXX-XXX` under the type's `prefix` (`CA-9KD-4PX`), or `XXX-XXX` when the type has no prefix or the record has no type.
- **Alphabet:** A–Z and 0–9 without `0 O 1 I 2 Z`, which are the characters people misread. Each three-character chunk holds at least one letter and one digit, so a chunk never spells a word.
- **Random, not sequential.** A mistyped code then almost always matches nothing and a scanner says "not found". With sequential codes, a typo of `CAM-042` is `CAM-043`, a real device, and the tech opens the wrong record with nothing looking wrong.
- **Unique across both collections.** A generated code never matches any Thing or Location code in the organization, with or without a prefix. Thing Type and Location Type prefixes are separate sets for the same reason.

An installer's code is still the right choice when the hardware already has one: `DOOR-1` stencilled on the door stays `DOOR-1`. For a Location, prefer the name on the door or drawing (`RM-204`), since a location code is read in subjects and paths. Generation is the fallback that makes sure nothing is left without a code.

### A type is frozen once set

`things.type` and `locations.type` can be set once and never changed. A generated code carries its type's prefix, and the default subject starts with the type's code, so a changed type would leave the code wrong and move every subject the device publishes on. A wrong type is fixed by deleting and recreating the record. Do that before the device is provisioned: after that, recreating also means reissuing its NATS user, its Nebula host and its printed label. The recreated record should get a new code, not the deleted one's, or it inherits the old record's subjects and history.

### Two constraints worth knowing before you design a prefix

**Put `{location}` in a prefix only for things that do not move.** The subject is computed from the Thing's *current* location, so relocating a trailer, a spare camera or a loaner tablet changes every subject it publishes under. Its history stays filed under the old site, a subscriber filtering on the new one misses it, and its NATS permissions still point at the old site. The default leaves the location out for this reason. A device that knows its own position reports it in its payload; for everything else, long-term storage joins the location in from inventory at query time ([ADR 0004](./decisions/0004-long-term-data-and-location-path.md)).

The cost of leaving it out is site-scoped patterns. `camera.chi-w-a.>` used to mean "every camera at Chicago" in one subscription, stream filter or **NATS permission**. Subscriptions and streams can filter on data instead; permissions cannot, because NATS authorizes on subjects and never looks at payloads. If you need a site-local identity limited to one site's devices, opt those types into `{location}`.

**You cannot wildcard part of a code.** A NATS `*` matches exactly one *whole* token, so folding the site into the code (`WHA-CAM-042`) does not buy you `camera.WHA-*.>` — that is a literal string, not a pattern. Subscribing per site requires the site to be its own token, which is the tradeoff the paragraph above describes. There is no negation either: no subject pattern can express "every camera except this one."

### The platform resolver

The platform ships the resolver at `ui/src/utils/subjectResolver.ts` — the only implementation there is, despite a header comment that long claimed it mirrored a Go package nobody ever wrote. It's used by UI widgets (the Publisher widget in particular) to resolve templates against concrete Thing contexts. Consumers are not required to use it — the platform stores templates as data, and any client can resolve them however it wants. It exists so the UI doesn't have to reinvent the substitution logic.

### Resolution example

Given:

```
thing_type.code:            camera
thing_type.subject_prefix:  (empty, so the default {thing_type_code}.{thing})
operation.subject_suffix:   motion
thing.code:                 CA-9KD-4PX
```

A consumer resolves the subject to `camera.CA-9KD-4PX.motion`. A wildcard subscription `camera.*.motion` gives every camera's motion events; `camera.>` gives every camera event and is the natural filter for a `CAMERA` JetStream stream. The prefix/suffix split is what makes wildcard discovery natural, and family-first is what keeps stream subject filters concrete.

The same camera under an opt-in prefix of `camera.{location}.{thing}`, located at `warehouse-a`, resolves to `camera.warehouse-a.CA-9KD-4PX.motion`, and `camera.warehouse-a.*.motion` then selects one site.

---

## 4. Why Operations Are Shareable

Operations are designed to be linked from many Thing Types, not owned by one.

Consider `heartbeat`. Nearly every kind of participant on the fabric emits one — cameras, gateways, sensors, VMS servers, AI agents, badge readers. The heartbeat contract is the same in all cases: the subject suffix is `heartbeat`, the payload is a liveness message, the capability is `publish`.

With shareable operations, there's exactly one `heartbeat` operation record in the organization, linked from every Thing Type that emits one. The benefits are direct:

- **One canonical definition** across the deployment. No drift between Thing Types.
- **Rules generalize.** A rule that reacts to "anything emitting a heartbeat" can do so cleanly because the operation is the same record everywhere.
- **Thing Types stay compositional.** A new Thing Type is primarily a list of existing operations plus any novel ones it introduces.

The tradeoff: a shared operation's `subject_suffix` must be Thing-Type-agnostic. A shared `heartbeat` has suffix `heartbeat` everywhere. When that's not what you want, create a Thing-Type-specific operation with a distinct name.

Deleting a Thing Type does not delete its operations. The operations persist and may still be linked from other Thing Types. If an operation becomes fully unlinked, it remains as a harmless orphan until someone cleans it up.

---

## 5. Relationship to NATS Roles

Thing Types describe what a participant does on the fabric. NATS roles control what a NATS user is allowed to publish to or subscribe from. These are **independent concerns** — Thing Types do not derive role permissions.

An organization's Owners and Admins author NATS role permissions directly on the `nats_roles` record — this is a tenant action, not a Platform Operator one. `nats_roles` has no Platform Operator branch in its API rules. No role below admin can read the collection at all. A Thing Type's subject templates are a useful reference when authoring those permissions — the patterns a role needs to grant look like the resolved wildcard forms of the Thing Type's operations — but the translation is manual and deliberate.

---

## 6. A Complete Example

### Shared operations

Records in `thing_type_operations`:

```
name:              heartbeat
capability:        publish
subject_suffix:    heartbeat
description:       Generic liveness heartbeat.

name:              status
capability:        publish
subject_suffix:    status
description:       Online/offline + status message.
```

### Camera-specific operations

```
name:              motion
capability:        publish
subject_suffix:    motion

name:              snapshot_request
capability:        request
subject_suffix:    snapshot

name:              snapshot_reply
capability:        reply
subject_suffix:    snapshot

name:              ptz
capability:        subscribe
subject_suffix:    cmd.ptz
```

Note that `snapshot_request` and `snapshot_reply` are two separate operations that share a subject suffix. A Thing Type that *offers* snapshots links `snapshot_reply`; a Thing Type that *asks for* them links `snapshot_request`.

### The Thing Type record

```
code:              ip_camera
name:              IP Camera
description:       Network camera with motion detection and PTZ
prefix:            CA
subject_prefix:    camera.{thing}
operations:        [heartbeat, status, motion, snapshot_reply, ptz]
```

### Resolved subjects for an IP camera instance

Thing: saved without a code, so it was generated as `CA-9KD-4PX`; `type = ip_camera`.

| Operation | Capability | Resolved Subject |
|---|---|---|
| `heartbeat` | publish | `camera.CA-9KD-4PX.heartbeat` |
| `status` | publish | `camera.CA-9KD-4PX.status` |
| `motion` | publish | `camera.CA-9KD-4PX.motion` |
| `snapshot_reply` | reply | `camera.CA-9KD-4PX.snapshot` |
| `ptz` | subscribe | `camera.CA-9KD-4PX.cmd.ptz` |

Moving this camera to another building changes none of these subjects.

---

## 7. Using Thing Types in the UI

Both collections live under the **Types** menu group in the sidebar, alongside Location Types. **Every role in the organization can read them through the API** — a member's widgets need the contract to resolve subjects — but in the console the whole Types menu, lists included, is **Owner/Admin only**, as are the create/edit/delete forms ([Authorization](./authorization.md)). A member or viewer consumes Thing Types through the screens that use them (the Thing form, the Publisher widget), not by browsing them:

- **Thing Types** — list and edit Thing Types. The form includes identity fields (name, description, code, and the code prefix, which it uppercases as you type), subject prefix, an operations multi-select with a quick-add modal for creating new operations inline, and the type's inventory-field schema (`metadata_schema`), which has an **"Infer from sample"** helper: paste one example record and every key becomes a typed field to review.
- **Thing Operations** — list and edit the shareable operation records. The form enforces the `^[a-z0-9_]+$` name pattern, requires a `capability`, and requires a `subject_suffix`.

### Publisher widget integration

The dashboard `publisher` widget can bind to a **Thing + Operation** pair in its configuration. When bound:

- **Subject auto-resolves** from the Thing's context (org, location, thing, thing_type_code) against the Thing Type's prefix and the operation's suffix. The resolved subject renders read-only in the widget.
- **Payload stays free text.** A bound operation used to render a typed form from its linked message schema; that went with `message_schemas`.

Without a binding, the Publisher widget falls back to free-text subject and payload inputs.

This is the one direct consumer of the Thing Type primitive: the widget knows the subject because it resolved the template. Subject resolution is what the contract is *for* — typing `camera.CA-9KD-4PX.motion` by hand is exactly the error-prone chore a control plane should absorb.

---

## 8. What Thing Types Don't Describe

Thing Types describe the **message contract** between a Thing and the fabric. They do not describe platform behavior, runtime configuration, or business logic.

Not in a Thing Type or its operations:

- **State machines or lifecycles.** Alarm status, presence, session tracking — belong in NATS KV and rule-router rules.
- **Rate limits, priorities, throttles.** Belong in NATS account limits, the NATS role, or a rule-router rule's `throttle`. (Account limits are a **Platform Operator** setting — an org's Owners and Admins can read the account record and trigger key rotation, but not change its limits.)
- **Enabled / disabled flags.** Belong on the Thing instance as runtime state.
- **Ownership, cost center, environment tags.** Belong on the Thing instance's metadata.
- **Alert thresholds, notification routing.** Belong in rules.
- **Historical retention, TSDB export config.** Belong in observability config.
- **Inheritance or composition of Thing Types.** Flat types only. Shared behavior via shared operations.

The test for any proposed new field: *does it describe the message contract between a Thing and the fabric, or does it describe platform behavior around that contract?* Contract fields (like `content_type` or `qos`) are in scope. Everything else has a better home and that home already exists.

### Operations stay a collection, not a JSON field

Folding `thing_type_operations` into a JSON array on `thing_types` was considered during the 2026-09 cleanup and rejected. The rule that settled it: **a fixed shape belongs in columns; a freeform document belongs in JSON.**

An operation is four keys, the same four every time. A `metadata_schema` is a user-authored document with no shape to migrate — which is why THAT one is correctly a JSON field on the same record. Three costs decided it:

1. **Nothing validates a PocketBase JSON field.** A typo’d `subject_sufix` would save clean, render nothing in the Publisher picker, and raise no error anywhere. That is the exact failure mode `message_schemas` was dropped for; trading a validated relation for an unvalidated blob to save two screens is cutting the wrong thing.
2. **Migrations move from PocketBase to you, permanently.** Adding `content_type` to a relation is a column PocketBase applies. In a blob it is a data migration walking every `thing_types` record — or, more likely, heterogeneous shapes tolerated forever with no error.
3. **The admin panel stops helping.** A bad operation is fixable at `/_/` in seconds today; in a blob it is hand-editing JSON in a textarea.

What the cleanup actually removed was the *third* collection and the framing that called two-thirds of it a contract layer — not the operations table.

---

## 9. Optional Fields

`subject_prefix` and `operations` are both optional:

- A Thing Type with no operations is a pure inventory/categorization record — it emits no subjects and defines no contract.
- A Thing Type with operations describes contracts that consumers (UI widgets, CLI tools, rules) can use for subject resolution.

Each operation's `capability` accepts `publish`, `subscribe`, `request`, and `reply`. It is a property of the OPERATION, not of the type: it is what tells a `request` apart from a `reply` on the same subject suffix (see §6). `thing_types.capabilities` used to carry the union of them as well, hand-maintained and read by nothing, and was dropped.

---

## 10. Where to Go Next

- **[Architecture](./architecture.md)** — how the Control Plane and Data Plane relate; where Thing Types sit in the Digital Twin model.
- **[Platform UI and Entities](./platform-ui-entities.md)** — the full inventory of entities the UI manages, including how Thing Types fit alongside Things and Locations.
- **[Authorization & Roles](./authorization.md)** — who can read a contract and who can change it.
- **[Connectivity](./connectivity.md)** — the NATS substrate that resolved subjects land on; subject namespacing conventions.
- **[Automation](./automation.md)** — rules that consume the subjects Thing Types declare.
