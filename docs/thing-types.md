---
path: platform/thing-types
nav_order: 110
---
# Thing Types

Thing Types are the **contract layer** of Stone-Age.io. A Thing Type describes
what a kind of participant does on the bus, as data: what it publishes, what it
subscribes to and what it answers.

A single IP camera is a **Thing**. The description "an IP camera publishes
motion events, answers snapshot requests and accepts PTZ commands" is its
**Thing Type**.

Thing Types describe subjects. They do not describe payload shape. They also do
not set NATS permissions. Owners and Admins write those on the `nats_roles`
collection, which only they can read or write. The platform copies a role's
permission fields into the JWT it signs, so write access to `nats_roles` is the
same as granting NATS permissions. See [Authorization](./authorization.md).

---

## 1. The Contract / Instance Model

Every Thing has two parts:

- **The Thing** is one device, service, application or agent. It has a unique
  code, a location, credentials and metadata. It is in the `things`
  collection.
- **Its Thing Type** is the contract for that kind of thing. It is in the
  `thing_types` collection.

The Thing Type says "things of this kind publish motion events, answer snapshot
requests and accept PTZ commands." The Thing says "I am CA-9KD-4PX, in
warehouse-a, of type ip_camera." Together they give the exact subjects
CA-9KD-4PX uses on NATS.

Many Things share one contract. A Thing does not declare its own behavior. It
points to the contract.

---

## 2. The Two Collections

### `thing_types`

The contract record for a kind of participant.

| Field | Purpose |
|---|---|
| `code` | Identifier, for example `ip_camera`. Used in subject templates and as a stable reference. Must match `^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$` (see [What a code may contain](#what-a-code-may-contain)). **Frozen once set:** the update rule refuses any change. |
| `name`, `description` | Labels for people. |
| `prefix` | Optional, 1 to 4 capital letters (`^[A-Z]{1,4}$`), for example `CA`. The platform puts it at the start of every code it generates for a Thing of this type (`CA-9KD-4PX`). See [Generated codes](#generated-codes). Unique in the organization, and never the same as a Location Type's prefix. You can change it, and the change applies to future codes only. |
| `subject_prefix` | A template such as `camera.{thing}`, stored as typed. If empty, consumers use `{thing_type_code}.{thing}`. |
| `operations` | Relations to `thing_type_operations`: the verbs this type declares. |
| `metadata_schema` | A JSON Schema for the inventory fields in a Thing's `metadata`. The Thing form renders it (§7). It is not a message contract, and nothing validates a payload against it. |

### `thing_type_operations`

Shared verbs. Each record is one thing a Thing Type can do on the bus.

| Field | Purpose |
|---|---|
| `name` | Operation identifier, lowercase snake_case, for example `motion`, `heartbeat`, `ptz`. |
| `capability` | One of `publish`, `subscribe`, `request`, `reply`. |
| `subject_suffix` | Added after the Thing Type's `subject_prefix` to make the full subject. Stored as typed. It can use the same variables as the prefix (§3). |
| `description` | What the operation is for. |

An operation is unique by `(organization, name, capability)`. So one name can
exist for two capabilities. For example, a `heartbeat` publish operation and a
`heartbeat` subscribe operation are different verbs.

**Operations are shared across Thing Types.** One `heartbeat` publish operation
is usually linked from every Thing Type in the org that sends heartbeats:
cameras, gateways, sensors, VMS servers (§4).

The standard tenancy API rules scope both collections to the organization.

---

## 3. Subject Templates and Resolution

Prefixes and suffixes are stored as **literal template strings**. A
`subject_prefix` of `camera.{thing}` is stored with the braces.

### Reserved variables

A consumer joins the prefix and the operation's suffix, then resolves the whole
string for one Thing. So a variable works in either half. A suffix of
`cmd.{thing}.ack` resolves the same way as a prefix.

| Variable | Source |
|---|---|
| `{org}` | `things.organization.code` |
| `{location}` | `things.location.code` |
| `{thing}` | `things.code` |
| `{thing_type_code}` | `things.type.code` |

A variable with no value stays as literal text in the subject, so you can see
it is unresolved. An empty value would make an empty token: a subject that
looks valid and matches nothing.

- **Every Thing and Location has a code.** A record saved without one gets a
  [generated code](#generated-codes). If an older record still has a blank
  code, the Publisher widget uses the record id for `{thing}`. That is a valid
  token but not a stable one.
- **An organization with no code leaves `{org}` literal.** The platform does
  not use the name, which can contain spaces and dots. Every new organization
  gets a code ([ADR 0002](./decisions/0002-organization-code-namespace.md)).
- **A Thing with no location leaves `{location}` literal.** This is another
  reason not to put `{location}` in a prefix for things that move or are not
  placed yet.

### Default prefix

When `subject_prefix` is empty, consumers use `{thing_type_code}.{thing}`
([ADR 0003](./decisions/0003-human-friendly-codes-and-default-subject.md)):

- **The type comes first**, so one JetStream stream can capture every Thing of
  one kind (for example a `SENSOR` stream on `sensor.>`). The stream filter has
  no leading wildcard, so you never write `*.sensor.>`, and streams do not
  overlap by accident.
- **There is no location.** Things move, and a subject built from the current
  location would move with them (see the constraints below). A Thing code is
  unique in its organization, and the organization is the NATS account, so the
  subject is unique without the location.

To put the location in a type's subjects, set an explicit prefix, such as
`freezer.{location}.{thing}` for equipment fixed to a building.

### Subject layout past the default is guidance

The platform enforces two things about subjects: what an empty prefix resolves
to, and the [character rules](#what-a-code-may-contain) for codes. The account
owner designs the rest. A prefix can have as many literal tokens as you need.
The demo's access-control hardware uses `acc.{location}.door.{thing}`, and its
kiosks use `kiosk.{thing}`, because those are the subject hierarchies of the
apps that drive them. `acc.>` and `kiosk.>` then capture everything each app
does.

A suggested starting layout:

> Token 0 is a **kind**: a Thing Type code, `agents`, or an application's namespace. Token 1 is the **code** of the thing or instance. The kind owns everything after that, usually built from operation suffixes.

An application can use a bare `{app-identifier}.…`, the same shape as a Thing
Type, or put every application under one root such as `app.{app}.…`. The demo
uses the second form: `app.wms.{thing}`, `app.kiosk.{thing}`. That keeps its
kiosk controller out of `kiosk.>`, which belongs to the kiosk nodes. Thing Type
codes and application namespaces share token 0, and the same organization admin
controls both, so the platform does not check for a clash.

### What a code may contain

`^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$`: letters, digits, `-` and `_`, starting
with a letter or digit, up to 63 characters. This applies to `things.code`,
`locations.code`, `thing_types.code` and `location_types.code`.

Mixed case is allowed on purpose. These codes are the text stencilled on the
hardware (`DOOR-1`, `KC-DC1`, `GW-KC-01`), so lowercasing them would make the
label and the record disagree. An Organization code is different: the platform
makes it from a name and nobody types it on site, so it is lowercase only.

**A code is stored as typed, but uniqueness ignores case.** `cam-1` and
`CAM-1` cannot both exist in one organization. Subjects, permissions and twin
keys use the stored spelling exactly, because NATS is case-sensitive. Two
spellings would be two identities with two subject namespaces that sound the
same when read aloud, and each would work, so nothing would report an error.
For the same reason, a lookup that a person makes can safely ignore case, such
as a code typed into a scanner (`code:lower = "{value:lower}"` in the
[Scanner widget](./dashboards.md)).

Each excluded character has a reason:

- **`.`** splits one subject token into two. The subject a publisher builds
  and the subject a subscriber expects stop matching, and messages stop
  arriving with no error.
- **`*` and `>`** are NATS wildcards. A code with one widens every permission
  pattern built from it, from one identity to every identity of that kind.
  This is the security case, because NATS permissions go into a signed JWT
  exactly as written.
- **A space** breaks the JetStream domain that an edge site's code becomes.
- **63 characters** is the RFC 1123 label limit, the strictest place a code is
  used.

A record with an older code that breaks these rules still works and can be
read, but cannot be saved until the code is fixed. `code` is frozen in the API
rules, so only a superuser can fix it, in the admin panel (`/_/`). Nothing
rewrites codes in bulk, because codes are on printed labels and in signed
subjects.

### Generated codes

A Thing or Location saved without a code gets one from the server
([ADR 0003](./decisions/0003-human-friendly-codes-and-default-subject.md)):

- **Shape:** `PFX-XXX-XXX` under the type's `prefix` (`CA-9KD-4PX`), or
  `XXX-XXX` when the type has no prefix or the record has no type.
- **Alphabet:** A to Z and 0 to 9, without `0 O 1 I 2 Z`, which people misread.
  Each three-character chunk has at least one letter and one digit, so a chunk
  never spells a word.
- **Random, not sequential.** A mistyped code then almost never matches
  anything, and a scanner says "not found". With sequential codes, a typo of
  `CAM-042` is `CAM-043`, a real device, and the tech opens the wrong record
  with no warning.
- **Unique across both collections.** A generated code never matches any Thing
  or Location code in the organization, with or without a prefix. For the same
  reason, Thing Type and Location Type prefixes are separate sets.

If the hardware already has a code, use it: `DOOR-1` on the door stays
`DOOR-1`. For a Location, use the name on the door or drawing (`RM-204`),
because people read location codes in subjects and paths. Generation is the
fallback.

### A type is frozen once set

You can set `things.type` and `locations.type` once and never change them. A
generated code has its type's prefix, and the default subject starts with the
type's code. A type change would make the code wrong and move every subject the
device publishes on.

To fix a wrong type, delete and recreate the record. Do this before you
provision the device, because afterwards you must also reissue its NATS user,
Nebula host and printed label. Give the new record a new code, not the old
one's, or it takes over the old record's subjects and history.

### Two constraints worth knowing before you design a prefix

**Put `{location}` in a prefix only for things that do not move.** The subject
comes from the Thing's *current* location. If you move a trailer, a spare camera
or a loaner tablet, every subject it publishes on changes. Its history stays
under the old site, a subscriber that filters on the new site misses it, and its
NATS permissions still point at the old site. The default leaves the location
out for this reason. A device that knows its position reports it in its
payload. For everything else, long-term storage adds the location from
inventory at query time ([ADR 0004](./decisions/0004-long-term-data-and-location-path.md)).

Without the location in the subject, you lose site-scoped patterns such as
`camera.chi-w-a.>` for "every camera in Chicago" in one subscription, stream
filter or **NATS permission**. Subscriptions and streams can filter on data
instead. Permissions cannot, because NATS authorizes on subjects and never
reads payloads. If you need an identity limited to one site's devices, put
`{location}` in those types' prefixes.

**You cannot wildcard part of a code.** A NATS `*` matches exactly one *whole*
token. If you put the site inside the code (`WHA-CAM-042`), then
`camera.WHA-*.>` is literal text, not a pattern. To subscribe per site, the
site must be its own token. There is also no negation: no subject pattern can
say "every camera except this one".

### The platform resolver

The resolver is `ui/src/utils/subjectResolver.ts`, the only implementation in
the platform. UI widgets, the Publisher widget in particular, use it to resolve
templates for a Thing. Other consumers do not have to use it. Templates are
data, and any client can resolve them its own way.

### Resolution example

Given:

```
thing_type.code:            camera
thing_type.subject_prefix:  (empty, so the default {thing_type_code}.{thing})
operation.subject_suffix:   motion
thing.code:                 CA-9KD-4PX
```

The subject is `camera.CA-9KD-4PX.motion`. `camera.*.motion` gives every
camera's motion events. `camera.>` gives every camera event and is the filter
for a `CAMERA` JetStream stream.

With a prefix of `camera.{location}.{thing}` and the location `warehouse-a`,
the same camera resolves to `camera.warehouse-a.CA-9KD-4PX.motion`, and
`camera.warehouse-a.*.motion` selects one site.

---

## 4. Why Operations Are Shared

Many Thing Types link the same operation. No Thing Type owns it.

Almost every kind of participant sends a `heartbeat`: cameras, gateways,
sensors, VMS servers, AI agents, badge readers. The contract is the same each
time: the suffix is `heartbeat`, the payload is a liveness message, and the
capability is `publish`. So the organization has one `heartbeat` operation
record, linked from every Thing Type that sends one.

- **One definition** for the whole deployment, with no drift between types.
- **Rules can be general.** A rule for "anything that sends a heartbeat" works
  because the operation is the same record everywhere.
- **Thing Types are built from parts.** A new Thing Type is mostly a list of
  existing operations, plus any new ones.

A shared operation's `subject_suffix` must suit every type that links it. A
shared `heartbeat` has the suffix `heartbeat` everywhere. If a type needs
something different, create a separate operation with its own name.

Deleting a Thing Type does not delete its operations. They may still be linked
from other types. An operation with no links stays until someone deletes it.

---

## 5. Relationship to NATS Roles

Thing Types describe what a participant does. NATS roles control what a NATS
user may publish or subscribe to. They are **separate**. Thing Types do not
produce role permissions.

An organization's Owners and Admins write NATS role permissions on the
`nats_roles` record. This is a tenant action. `nats_roles` has no Platform
Operator branch in its API rules, and no role below admin can read it. A Thing
Type's templates help when you write permissions, because a role usually needs
the wildcard forms of the type's resolved subjects. You write the permissions
by hand.

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

`snapshot_request` and `snapshot_reply` are two operations with the same
suffix. A Thing Type that *offers* snapshots links `snapshot_reply`. A Thing
Type that *asks for* them links `snapshot_request`.

### The Thing Type record

```
code:              ip_camera
name:              IP Camera
description:       Network camera with motion detection and PTZ
prefix:            CA
subject_prefix:    camera.{thing}
operations:        [heartbeat, status, motion, snapshot_reply, ptz]
```

### Resolved subjects for one camera

The Thing was saved without a code, so it got `CA-9KD-4PX`. Its type is
`ip_camera`.

| Operation | Capability | Resolved Subject |
|---|---|---|
| `heartbeat` | publish | `camera.CA-9KD-4PX.heartbeat` |
| `status` | publish | `camera.CA-9KD-4PX.status` |
| `motion` | publish | `camera.CA-9KD-4PX.motion` |
| `snapshot_reply` | reply | `camera.CA-9KD-4PX.snapshot` |
| `ptz` | subscribe | `camera.CA-9KD-4PX.cmd.ptz` |

If you move this camera to another building, none of these subjects change.

---

## 7. Using Thing Types in the UI

Both collections are in the **Types** menu in the sidebar, with Location Types.
**Every role in the organization can read them through the API**, because a
member's widgets need them to resolve subjects. In the console, only Owners and
Admins see the Types menu and its forms ([Authorization](./authorization.md)).
Members and viewers use Thing Types through the Thing form and the Publisher
widget.

- **Thing Types:** list and edit Thing Types. The form has name, description,
  code, code prefix (uppercased as you type), subject prefix, an operations
  multi-select with a quick-add dialog for new operations, and the inventory
  schema (`metadata_schema`). **"Infer from sample"** takes one example record
  and makes a typed field from each key, for you to review.
- **Thing Operations:** list and edit the shared operations. The form enforces
  the `^[a-z0-9_]+$` name pattern and requires `capability` and
  `subject_suffix`.

### Publisher widget integration

The dashboard `publisher` widget can bind to a **Thing and an operation**. When
bound:

- **The subject resolves** from the Thing (org, location, thing,
  thing_type_code), the Thing Type's prefix and the operation's suffix. It is
  shown read-only.
- **The payload is free text.**

With no binding, the widget has free-text subject and payload inputs.

The Publisher widget is the direct consumer of Thing Types. You do not need to
type `camera.CA-9KD-4PX.motion` by hand.

---

## 8. What Thing Types Don't Describe

Thing Types describe the **subject contract** between a Thing and the bus.
They do not describe platform behavior, runtime configuration or business
logic.

These do not belong in a Thing Type or its operations:

- **State machines or lifecycles** (alarm status, presence, sessions): use NATS
  KV and rule-router rules.
- **Rate limits, priorities, throttles:** use NATS account limits, the NATS
  role, or a rule's `throttle`. Account limits are a **Platform Operator**
  setting. Owners and Admins can read the account record and rotate keys, but
  cannot change its limits.
- **Enabled / disabled flags:** put them on the Thing as runtime state.
- **Ownership, cost center, environment tags:** put them in the Thing's
  metadata.
- **Alert thresholds, notification routing:** use rules.
- **Retention and TSDB export:** use the observability config.
- **Inheritance or composition of types:** types are flat. Share behavior
  through shared operations.

For a proposed new field, ask: *does it describe the contract between a Thing
and the bus, or platform behavior around it?* Contract fields such as
`content_type` or `qos` belong here. Everything else already has a place.

### Operations stay a collection, not a JSON field

**A fixed shape belongs in columns. A freeform document belongs in JSON.** An
operation always has the same four keys, so it is a collection. A
`metadata_schema` is a document you write with no fixed shape, so it is a JSON
field. A JSON array of operations would cost three things:

1. **PocketBase does not validate a JSON field.** A typo such as `subject_sufix`
   would save, show nothing in the Publisher picker, and raise no error.
2. **You would own every migration.** A new field on a collection is a column
   that PocketBase adds. In a JSON array it is a data migration over every
   `thing_types` record, or mixed shapes forever.
3. **The admin panel could not help.** Today you can fix a bad operation at
   `/_/` in seconds. In JSON you would edit text in a textarea.

---

## 9. Optional Fields

`subject_prefix` and `operations` are both optional:

- A Thing Type with no operations only categorizes. It emits no subjects and
  defines no contract.
- A Thing Type with operations gives consumers (widgets, CLI tools, rules) the
  data to resolve subjects.

An operation's `capability` is `publish`, `subscribe`, `request` or `reply`. It
belongs to the operation, not the type. It tells a `request` from a `reply` on
the same suffix (§6).

---

## 10. Where to Go Next

- [Architecture](./architecture.md): the Control Plane, the Data Plane and the digital twin
- [Platform UI and Entities](./platform-ui-entities.md): the records the console manages
- [Authorization & Roles](./authorization.md): who can read and change a contract
- [Connectivity](./connectivity.md): NATS, where the resolved subjects go
- [Automation](./automation.md): rules that use the subjects Thing Types declare
