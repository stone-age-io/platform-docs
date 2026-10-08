---
path: access-control/protocol
nav_order: 10
---
# Wire Protocol

This page is the wire contract between the central app (`accessd`) and the
edge controllers (`access-controller`). All of it runs over NATS, in two
planes:

- **Policy plane.** `accessd` mirrors the PocketBase policy graph into the
  NATS KV bucket `ACC_POLICY`, one key per record. Controllers watch it into
  memory.
- **Event and command plane.** Controllers decide locally and publish access
  events to the JetStream stream `ACC_EVENTS`. Operators send commands over
  core NATS.

Both binaries share the subjects, KV keys and message shapes below. Subject
construction and parsing live in one place,
[`internal/subjects`](https://github.com/stone-age-io/access-control/blob/main/internal/subjects/subjects.go). The KV value shapes
live in [`internal/policykv`](https://github.com/stone-age-io/access-control/blob/main/internal/policykv/wire.go) (policy, downward)
and [`internal/statuskv`](https://github.com/stone-age-io/access-control/blob/main/internal/statuskv/wire.go) (status, upward). Bucket
and stream names and the app token are in the
[Configuration Reference](configuration.md).

---

## 1. Subject Namespace

Every subject starts with the app token `acc`. The access app owns the `acc.>`
subtree. A **portal** (a controllable opening or logical access target) is a
Thing addressed under it as `acc.{location}.{type}.{thing}`, with the verb at
the end (`.tap`, `.cmd.*`, `.evt.*`).

The leading literal keeps `ACC_EVENTS`'s subjects disjoint from every sibling
app's stream on a shared NATS account. JetStream forbids overlapping stream
subjects, and a subject that led with a wildcard (e.g. `*.*.*.acc.evt.>`) would
overlap any stream rooted at a literal first token (`things.>`, `cameras.>`,
`kiosk.*.event.>`, …).

Set the token with `subjects.app` (or `SA_SUBJECTS_APP`). The default is `acc`.
Change it only to isolate a deployment on a shared NATS account. It must be a
single NATS token: no `.`, `*`, `>` or whitespace.

::: warning `accessd` and every controller must use the same app token
They publish and subscribe to each other's traffic, so a mismatch silently
cuts policy, commands and events.
:::

`{location}`, `{type}` and `{thing}` are each a single NATS token. They are
record **codes** (e.g. `hq`, `door`, `lobby-main`), never PocketBase ids. The
mirror rejects a location, portal, controller, aux input/output or area code
(or a portal type) that is not a single token or that matches a reserved
keyword (`acc`/`evt`/`cmd`/`tap`/`fire`). It logs the record and never mirrors
it.

---

## 2. Subjects

| Subject | Dir* | Transport | Body |
| :--- | :--- | :--- | :--- |
| `acc.{location}.{type}.{thing}.tap` | → ctrl | core NATS | `{"cred":"..."}` or a bare credential string |
| `acc.{location}.{type}.{thing}.cmd.posture` | → ctrl | core NATS | `{"posture":"…","actor":"…","reason":"…","until":"…"}` |
| `acc.{location}.{type}.{thing}.cmd.grant` | → ctrl | core NATS | `{"seconds":N,"actor":"…","reason":"…","source"?}` |
| `acc.{location}.auxout.{thing}.cmd.output` | → ctrl | core NATS | `{"action":"on"\|"off"\|"pulse","seconds":N,"actor":"…","reason":"…"}` |
| `acc.{location}.evt.fire` | ↔ | core NATS → JetStream | `{"active":bool,"ts"}` |
| `acc.{location}.{type}.{thing}.evt.tap` | ctrl → (accessd → for a denied badge unlock) | core NATS → JetStream | `{"cred","user","allow","reason","ts","source"?}` |
| `acc.{location}.{type}.{thing}.evt.state` | ctrl → | core NATS → JetStream | `{"posture","actor?","reason?","ts"}` |
| `acc.{location}.{type}.{thing}.evt.alarm` | ctrl → | core NATS → JetStream | `{"type","ts"}` |
| `acc.{location}.area.{code}.evt.alarm` | ctrl → | core NATS → JetStream | `{"type":"intrusion","point","ts"}` |
| `acc.{location}.area.{code}.evt.state` | accessd → | core NATS → JetStream | `{"arm","previous","controller","armSource","ts"}` |
| `acc.{location}.ctrl.{code}.evt.state` | accessd → | core NATS → JetStream | `{"status","lastSeen","ts"}` |
| `acc.{location}.ctrl.{code}.heartbeat` | ctrl → accessd | core NATS (**not** JetStream) | `{"code","location","ts"}` |

\* → ctrl: the controller subscribes. ctrl →: the controller publishes.
accessd →: accessd publishes. ↔: both (see fire under
[Command Details](#command-details)).

All bodies are JSON. `ts` is RFC 3339 UTC.

### Events accessd publishes

Two event subjects come from **accessd**, not the edge. Both are `evt.state`,
told apart by the `{type}` token. Both fit the existing `acc.*.*.*.evt.>`
stream subject, so neither needed a stream change.

**`area`: an arm/disarm transition.** All four ways an area changes arm-state
(an operator's arm route, entry-disarm, the one-shot release sweep, and a
scheduled auto-arm evaluated on each box) converge on the per-controller arm
shadow in `ACC_STATUS`. accessd's status projector emits the event from there.

- It is emitted **per participating controller**, matching the shadow: a
  3-box area reports three transitions, each naming its own controller.
- It is the only trace a scheduled auto-arm leaves anywhere in the system.
- `arm`/`previous` are `armed`/`disarmed`. `ts` is the shadow's own
  `updatedAt`.
- It fires only when an existing projection row's state changes. A key's first
  report is not a transition, so a cold boot produces no event per area.
- The shadow's provenance (`standing`/`scheduled`/`override`) travels as
  **`armSource`**, not `source`, because `source` is the audit projection's
  select over how an event arrived and rejects these values (see
  [Audit Projection](#11-audit-projection)).

**`ctrl`: a liveness transition.** Heartbeats stay off the stream, because
they would flood it. An online↔offline flip is one event per outage, and it is
audited. `ctrl` is the reserved controller token the heartbeat also uses. The
heartbeat sits outside `.evt` at 5 tokens so the stream cannot capture it; this
event sits inside at 6 so it can. `status` is `online`/`offline`. `lastSeen` is
the controller record's `last_seen` in PocketBase's datetime format
(`2006-01-02 15:04:05.000Z`), not RFC 3339.

### Subscriptions

The NATS reader subscribes to the **exact** `.tap` subject of each portal it
has armed (the portal's own location/type/code), not a location wildcard, so it
hears only portals this box drives.

Commands are subscribed per location with wildcards:
`acc.{location}.*.*.cmd.posture`, `acc.{location}.*.*.cmd.grant` and
`acc.{location}.*.*.cmd.output` (aux outputs). Every controller at a location
hears every command there and silently ignores those for portals and outputs
it does not drive.

### Stream capture

The audit surface is the `acc.*.…evt` subtree. `ACC_EVENTS` captures it, and
the audit consumer projects it into the `events` collection, through **two
stream subjects of different fixed arity**:

- `acc.*.evt.fire`: the 4-token location-scoped fire
  (`acc.{location}.evt.fire`)
- `acc.*.*.*.evt.>`: the 6+-token portal events
  (`acc.{location}.{type}.{thing}.evt.{kind}`)

JetStream forbids overlapping subjects, so the short one has no trailing `>`.
A 4-token subject can never match the 6+-token pattern, so the two are
disjoint. Both lead with the literal `acc`, so neither overlaps a sibling
stream rooted at another literal (`things.>`, `cameras.>`, `kiosk.*.event.>`,
…) on a shared account.

### Controller heartbeat

A **controller** is addressed under the reserved `acc.{location}.ctrl.{code}`
namespace (`ctrl` is not a portal type). Its heartbeat sits outside the `.evt`
subtree: a 5-token subject with no `evt`, so it matches neither audit pattern
and `ACC_EVENTS` never captures it.

accessd subscribes to `acc.*.ctrl.*.heartbeat` over core NATS and writes the
controller's `last_seen`/`status` directly on the `controllers` record, not as
an `events` row (which would flood the audit log). A controller publishes one
heartbeat on start, then every `controller.heartbeatInterval` (default 15s).
accessd marks a controller `offline` once it has been silent longer than
`accessd.controllerOfflineAfter` (default 45s).

### Command Details

- **posture** installs a runtime posture override for the portal. Valid
  values are `secure`, `free_access`, `unlocked`, `lockdown`, `disabled`, or
  `clear`. `clear` reverts to the *effective* posture from policy: the
  scheduled posture if its window is open, else the standing posture.
  Overrides are operational state on the controller and are **never written
  back to PocketBase**. `until` is parsed but **ignored**: timed reversion
  comes from an external scheduler publishing a follow-up command.
  `free_access` opens on any tap without consulting the credential (the strike
  pulses, the door stays closed). `unlocked` holds the strike open. Each set or
  clear emits one `evt.state` carrying the now-effective posture and the
  command's `actor`/`reason`. That is the **only** source of `evt.state` for a
  portal: a scheduled-posture window boundary or a standing-posture edit emits
  no event (the status shadow's `source` shows it instead).
- **grant** is a momentary strike pulse: the same physical effect as a
  credential grant, operator-initiated, and distinct from a standing posture
  change. `seconds <= 0` (or omitted) falls back to the portal's configured
  `pulseSeconds`. It emits an `evt.tap` with `allow=true`,
  `reason=allow_command_grant`, empty `cred`, and `user` set to the issuing
  actor, so the open is attributable in the audit trail. The optional `source`
  names the remote surface that sent it and is copied onto that event. The
  badge tier sends `badge`. Absent or empty (the operator route, and any older
  publisher) becomes `command`. The command's own `reason` is only logged.
- **output** drives a named auxiliary output relay (`auxout` type). `on`/`off`
  set the standing held state. `pulse` energizes momentarily (`seconds<=0`
  falls back to the aux output's configured `pulseSeconds`). Any other action
  is ignored. Aux outputs are first-class Things bound to a controller,
  addressed like portals, and their live state flows up the status channel
  (`auxout.{code}`). An output command emits **no** event and leaves no
  `events` row. For `on`/`off` the shadow's `energized` shows it; a `pulse` is
  momentary and not shown.
- **fire** toggles a location's fire-alarm-input state. While it is active,
  the controller **suppresses alarm emission** for that location if the
  location opts in with `faiSuppress` (forced and held-open events would be
  false alarms during evacuation). It never changes posture and never unlocks.
  It is location-scoped, not per-portal, and lives on the `evt` namespace, not
  `cmd`, because it is both a control input the controller subscribes to and an
  audited event the stream captures (`kind="fire"`). The subject
  `acc.{location}.evt.fire` goes both ways: a controller whose `aux_input` has
  `pointType: "fire"` publishes it on **both edges** (assert and clear), and
  every controller at that location, including the publisher (idempotently),
  subscribes and applies it. That is why the subject is location-scoped while
  the contact is bound to one box.

---

## 3. Door Monitoring & Alarms

The controller runs a per-portal door-state machine fed by two digital inputs:
a **door-position switch** (DPS, `dpsInput`) and an optional
**request-to-exit** (REX, `rexInput`). It emits `evt.alarm` events as
`{"type","ts"}`, where `type` is a stable string, like a reason code:

| `type` | Meaning |
| :--- | :--- |
| `forced` | The door opened with no recent grant or REX: a break-in |
| `held` | An authorized-open door stayed open past `heldOpenSeconds` (DOTL) |
| `held_clear` | A previously-held door closed |
| `no_entry` | A grant whose grace window expired with no door-open ("access granted, no entry") |
| `intrusion` | An armed area's `intrusion` aux point, or any `tamper_24h` point, went active; **or** a member portal was forced while its area is armed |

A grant (an `allow` tap or a `grant` command) and a REX press each open a short
window. During it a door-open reads as authorized (no `forced`) and arms the
held-open timer instead.

### `no_entry`

`no_entry` is the inverse of `forced`: the grant window closed and nobody came
through. It separates a real entry from a badge test, a stuck strike, or
someone who badged and walked away.

- It is **exception-only**. A used grant emits nothing, so the normal path adds
  no volume.
- It is evaluated on the existing hold-eval tick, not a per-grant timer, so it
  lands 10 to 20s after the grant.
- It is diagnostic, not urgent, so notification treats it as opt-in (see
  [Notifications & Webhook](#12-notifications-webhook)).
- It is emitted only where an open is **observable**, which takes two things:
  the portal's binding declares a `dpsInput`, *and* the controller has a
  door-input driver. Either alone is not enough. They agree on real hardware
  and differ under `driver: mock`, which has a lock and no inputs. So a box
  running the simulated reader (every demo and dev box) emits no `no_entry` at
  all, rather than one per granted tap.

### Fire suppression

While a location's **fire** input is active, alarm emission is suppressed
(forced, held and intrusion alarms during evacuation would be false), but only
if the location opts in with `faiSuppress`. **`held_clear` is always
emitted**: a clear cannot be a false alarm, and dropping it would leave an
active held-open on the console with no later event to resolve it. The DOTL
timer and the held-open threshold are hardware-local timing, not policy.

A location's fire input is an `aux_input` whose `pointType` is **`fire`**. It
is electrically an ordinary dry contact, so it needs no dedicated driver
interface. Its transport is under [Command Details](#command-details).
Software only suppresses alarm noise, records and notifies.

::: warning Hardware owns egress
The fire panel's relay drops maglock power directly. Nothing in this system
unlocks a door for fire.
:::

### Contact sense and lock type

Each input's **contact sense** is set per install (`dpsContact`/`rexContact`/
`aux_input.contact`, see [Policy KV](#8-policy-kv-acc_policy)). A
normally-open or normally-closed contact is folded onto the board's electrical
polarity, so "active" always means the monitored condition is asserted,
whatever the wiring. By default a REX press only shunts the forced alarm. With
`rexUnlock` the controller also pulses the strike (electric egress). The
strike's fail-safe behavior follows `lockType`: a fail-secure **strike**
de-energizes (re-locks) on shutdown or crash, while a fail-safe **maglock**
idles energized and releases on power loss.

---

## 4. Areas & Intrusion Arming

An **area** is a logical, single-location arm-state grouping that may span
several controllers. A **point** of an area is either an **aux input** (a bare
contact or DPS-only door) or a **portal** (a full reader/DPS/REX door).
Membership lives on each (`aux_input.area` + `point_type`, or `portal.area`).
The participant set (`peers`) and "which areas this box drives" union both
kinds.

For an **aux input**, `point_type` decides the trip:

- `monitor` (the default) is observe-only.
- `intrusion` raises an `intrusion` alarm **while its area is armed**.
- `tamper_24h` raises one **regardless** of arm-state.

Any active edge trips, because a bare contact has no notion of an authorized
open.

For a **portal**, the reader changes the rule. An authorized open (a grant or
REX) is normal passage and never an intrusion. A member portal trips intrusion
only on its **forced** condition (a DPS open with no grant/REX window, which
the door state machine already detects) **while the area is armed**. That
forced open still emits its door-level `forced` event; the area `intrusion` is
an extra armed-zone roll-up. A portal with no area, or whose area is disarmed,
escalates nothing.

Intrusion alarms are addressed as a Thing of type `area` and reuse the generic
alarm subject `acc.{location}.area.{areacode}.evt.alarm`, with body
`{"type":"intrusion","point":"<aux-or-portal-code>","ts"}`. The existing
6-token portal-event wildcard captures them with no new stream subject. They
go through the same fire-suppression gate as door alarms. Like `forced`, an
intrusion alarm is **edge-triggered**: one per active edge, so a
continuously-asserted point fires once. There is no controller-side latch and
no new timer. The events row stays unacknowledged until an operator acks it.

### Arm-state is durable

Unlike posture, a reboot must not silently disarm, so arming rides the policy
KV. An operator arm or disarm writes a durable `armOverride` field on the area
record (through accessd), the mirror propagates it, and every participating
controller converges.

The controller resolves the effective arm-state the same way it resolves
scheduled posture: `armOverride` → `autoArm` (while `autoSchedule`'s window is
open, holidays honored) → standing `arm`. The fail-safe direction is the
**inverse of access**: an unresolved or unknown area falls back to standing
(default disarmed) and never arms by mistake. Arm-state boundaries fire no
alarm themselves; they only change whether a future trip alarms.

::: note There is no `cmd.arm` subject
Arming is a durable record write, not a fire-and-forget command.
:::

### Entry-disarm

A portal flagged `disarmOnGrant` is an *entry* door: a valid credential grant
there durably disarms its area. Arm-state is durable and central, and an area
spans controllers, so this cannot be a local edge action. The edge emits the
`evt.tap` it already emits. accessd's **disarm sink** (`internal/disarm`)
observes the grant and writes the same durable `armOverride: disarmed` the
manual disarm route writes, and the mirror converges every peer controller.
The disarm sink is a third independent durable on `ACC_EVENTS`, beside the
audit and notify consumers:

| Property | Value |
| :--- | :--- |
| Durable | `acc-disarm` |
| Deliver policy | `DeliverNew` |
| Filter | `acc.*.*.*.evt.tap` |

- Only a **credential** grant disarms (`allow` with a `cred`). A deny is
  ignored. An operator remote `cmd.grant` carries no `cred`, so a remote
  door-pop cannot silently disarm a building.
- The write is idempotent and skips an area that is already disarmed or can
  never be armed, so a redelivery is a harmless no-op and needs no dedup.
- Each disarm writes its own `audit_logs` row attributed to the credential and
  portal.

### One-shot release

A disarm `armOverride` (manual *or* entry-disarm) on a *scheduled* area is
released automatically at the next scheduled arm. accessd's
`internal/armrelease` sweep clears `armOverride` once the area's base
arm-state (scheduled `autoArm` or standing `arm`, override excluded) is
disarmed. So scheduled auto-arm plus entry-disarm loops on its own: arm
overnight, the first badge disarms in the morning, re-arm at the next window,
with no operator action. An area with **no** `autoSchedule` has no scheduled
arm to revert to, so its disarm override stays until an operator clears it
(`arm-clear`).

---

## 5. Badge Actions

The badge tier adds **no wire surface**: no new subject, no new KV key, no
controller change.

### Remote unlock

A badge holder opening a door from their badge page
(`POST /api/badge/unlock/{portalId}`, `internal/badgeapi`) publishes the
**existing** `cmd.grant`. To the edge it is the same as an operator grant,
because the physical effect is the same one-shot strike pulse. Two checks on
the accessd side make it safe:

- **Authorization is `policy.Decide`**, run centrally over a live snapshot of
  `ACC_POLICY` (`internal/policysnapshot`, the same package the access
  simulator uses). A remote unlock can never exceed what that person's
  credential opens in person, and schedules, holidays, validity bounds and the
  posture gate all apply with no second implementation.
- **`portals.allow_remote_unlock`** (default false) is a per-door opt-in,
  checked before the graph is consulted. It is control-plane only and **not
  mirrored** to KV: the decision happens before publishing, so the edge never
  needs the flag.

The published body is:

```json
{"seconds":0,"actor":"badge:<cardholderId>","reason":"remote_unlock","source":"badge"}
```

`actor` names the person rather than an operator email. `source: badge` makes
the controller's resulting `evt.tap` say so (an operator grant's says
`command`). The grant carries no `cred`, so, like an operator door-pop, a badge
remote unlock **cannot** trigger entry-disarm.

A badge action never publishes to `.tap`. `Tap.Source` exists so a physical
read is distinguishable from a synthesized one. A phone-initiated open is a
command, and recording it as a credential presentation would put something
untrue in the audit trail.

### Arm, disarm and output

These use the same two checks, with one difference in shape:

- `POST /api/badge/areas/{id}/{arm|disarm}` is authorized by
  `policy.DecideArea` over the same snapshot and gated by
  `areas.allow_remote_arm`. It then writes `areas.arm_override`, a **durable
  record write** exactly as the operator route does, because arm-state must
  survive a reboot and there is no `cmd.arm` subject.
- `POST /api/badge/outputs/{id}/pulse` is authorized by `policy.DecideOutput`
  and gated by `aux_output.allow_remote`. It publishes the **existing**
  `cmd.output` with `action: "pulse"`, `seconds: 0` (the output's own
  configured duration), `actor: "badge:<cardholderId>"`, and
  `reason: "remote_output"`. The badge offers no `on`/`off`: a momentary act is
  self-limiting, and a relay energized from a phone and left is not.

A badge holder cannot clear an arm override. `arm-clear` is an operator's
"revert to the schedule", and `internal/armrelease` already releases a one-shot
disarm on a scheduled area, so a holder's disarm strands nothing.

### Reading a badge

`GET /api/badge/me`, `/api/badge/live` and the operator's
`GET /api/badge/preview/{id}` publish nothing and write nothing. They read a
`policysnapshot` of `ACC_POLICY` plus the PocketBase records its codes resolve
to.

The preview does not mint the holder a session for the operator to drive. A
badge action stamps the **cardholder** as its actor, so those commands would be
indistinguishable on the wire and in `events` from the holder's own. An
operator who needs a door opened publishes `cmd.grant` through the operator
route under their own `command` capability, where `actor` is their email
rather than `badge:<id>`.

---

## 6. Scheduled Posture & the Strike Hold

Of the postures, only `unlocked` (B) has a standing physical effect: the
strike is held energized so the door stands open. Every other posture is
enforced at the next tap, so physically the strike is just *not held*.

The controller keeps each driven portal's hold in step with its effective
posture three ways:

- immediately on a posture command, so a lockdown re-locks at once;
- immediately when a portal is armed;
- on a periodic **hold-eval reconcile** (default 10s) that re-evaluates each
  portal. This is the no-event fallback that flips scheduled posture at window
  boundaries.

The reconcile is a *sampling* loop. It reads "is the window open now" and never
computes boundaries, so the interval only sets latency and has no effect on
correctness. If an `autoSchedule` is set but not yet loaded (mid re-sync), the
reconcile keeps the previous hold rather than flapping the door.

A momentary `Pulse` composes with the hold: the strike is energized while
either is active, so a habitual tap during an auto-unlock window pulses
harmlessly. On controller shutdown or crash the strike de-energizes
(fail-secure: the door re-locks; egress stays hardware-owned).

---

## 7. Readers

`controller.reader` selects how taps arrive:

| Value | Behavior |
| :--- | :--- |
| `nats` (default) | Taps arrive by publishing to `acc.{location}.{type}.{thing}.tap`. The simulated and integration path, driven with `nats pub`. |
| `osdp` | A real OSDP reader polled on the model's RS485 bus. Clear-text in v1; OSDP Secure Channel is a planned fast-follow. |
| `both` | The NATS reader for **every** portal, plus the OSDP reader for the portals that have a physical reader. |

Under `both` a portal opts into OSDP with its `readerAddress`: `>= 0` is a
reader at that PD address, and `-1` is NATS-only. An absent value reads as 0,
so it means PD 0. `osdp` and `both` require `controller.model` (for its RS485
serial port). Each emitted `evt.tap` carries a `source` (`nats`/`osdp`), so a
physical read is distinguishable from a NATS-published tap.

The reader is independent of the lock and door driver. An `osdp` reader pairs
with any `controller.driver`; the strike and DPS/REX stay on GPIO/I2C. The
**lock and door inputs have real drivers**: `controller.driver: mock` (default,
no physical I/O and no door monitoring) or `gpio` (relays and DPS/REX on real
Linux edge hardware). Under `gpio` the `controller.model` profile selects the
transport: the native GPIO char device or an MCP23017 I2C expander.

An OSDP card read becomes a credential string as the **lowercase hex of the raw
card bytes** (`internal/drivers/osdp/wire`). This is lossless and
format-agnostic, so enrollment matches what the bench observes. Decimal and
Wiegand decoding depend on the reader's bit order and wait until confirmed
against physical hardware. See [Hardware & Readers](hardware.md).

---

## 8. Policy KV (`ACC_POLICY`)

One key per record, `<prefix><natural-key>`. Cross-references are stored as
stable **codes** (or credential value or cardholder id), never PocketBase ids,
so keys and values are human-readable and self-contained. `accessd`'s mirror is
the only writer; controllers are read-only watchers.

| Key | Value shape |
| :--- | :--- |
| `location.{code}` | `{"code","name","timezone","faiSuppress","holidayCalendars":["<calendar code>"]?}` |
| `sched.{code}` | `{"code","windows":[{"days":[1..7],"start":"HH:MM","end":"HH:MM"}],"observeHolidays"}` |
| `portal.{code}` | `{"code","type","location","posture","pulseSeconds",`<br>`"autoPosture"?,"autoSchedule"?,`<br>`"controller"?,"lockRelay"?,"dpsInput"?,"rexInput"?,"heldOpenSeconds"?,"readerAddress"?,`<br>`"dpsContact"?,"rexContact"?,"lockType"?,"rexUnlock"?,`<br>`"area"?,"disarmOnGrant"?}` |
| `controller.{code}` | `{"code","name","location","model"}` |
| `holiday.{pbid}` | `{"calendar":"<calendar code>","date":"YYYY-MM-DD","recurring"}` |
| `group.{code}` | `{"code","portals":["<portal code>"],"schedule":"<sched code>",`<br>`"areas":["<area code>"]?,"auxOutputs":["<output code>"]?,"areaRights":["arm"\|"disarm"]?}` |
| `role.{code}` | `{"code","groups":["<group code>"]}` |
| `user.{pbid}` | `{"id","status","roles":["<role code>"]}` |
| `cred.{value}` | `{"value","user":"<cardholder pbid>","status","validFrom"?,"validUntil"?}` |
| `auxin.{code}` | `{"code","location","controller"?,"inputIndex"?,"contact"?,"area"?,"pointType"?}` |
| `auxout.{code}` | `{"code","location","controller"?,"relayIndex"?,"pulseSeconds"?}` |
| `area.{code}` | `{"code","name"?,"location","arm"?,"armOverride"?,"autoArm"?,"autoSchedule"?}` |

Eventual consistency is fail-safe. An unknown credential, a reference to a
not-yet-synced role, group or schedule, a malformed value, or no policy at all
each result in **deny**. A `WatchAll` re-delivers every key on (re)subscribe,
so a reconnect performs a full re-sync.

### Access group targets

An access group grants **three independent kinds of target** under its one
schedule: portals, `areas` (arm/disarm) and `auxOutputs`. An absent or empty
list grants nothing of that kind, so a doors-only group is the common zero
case. `areaRights` names which arm actions `areas` is granted for. **An empty
or absent list grants neither**, because arming and disarming are separate
rights (disarming turns intrusion detection off). See `policy.DecideArea` and
`DecideOutput` in [Decision](#non-portal-targets), which are pure siblings of
`Decide` rather than part of it.

accessd consumes the three group fields **centrally**: it authorizes a badge
holder's arm/disarm and output actions with those deciders. They are mirrored
anyway rather than read from PocketBase, so there is one authorization
substrate, and so an OSDP keypad arming a partition at the reader (an edge
decision) needs no new wire.

### Fields that are not mirrored

These fields never reach `ACC_POLICY` or the edge, and the wire shapes above
omit them:

- **UI-only fields.** `locations.description`/`coordinates`/`floorplan`, and
  `floorplan_position` on `portals`, `aux_input` and `aux_output`, for the
  location map and floor-plan views. No floor-plan image data leaves accessd.
- **Badge-tier remote opt-ins.** `portals.allow_remote_unlock`,
  `areas.allow_remote_arm`, `aux_output.allow_remote` and
  `locations.badge_floorplan` gate accessd's own routes. The edge has no
  remote-actuation path to gate.
- **The holiday calendar record.** See [Holidays](#holidays).
- **The credential `type`.** See [Values and formats](#values-and-formats).
- **Controller liveness.** `controllers.last_seen`/`status` are written by
  accessd from heartbeats (see [Controller heartbeat](#controller-heartbeat)).

`policy.Decide`, arming and the door state machine are unaffected by any of
them.

### Values and formats

- `type` is the portal kind (`door`/`turnstile`/`elevator`/`gate`/`logical`)
  and the `{type}` subject segment.
- `timezone` is an IANA name, resolved once per location on the controller.
- `days` are ISO weekdays (1=Mon … 7=Sun). `start`/`end` are local wall-clock
  `HH:MM` (`24:00` allowed as end-of-day). `end <= start` means the window
  crosses midnight.
- `user.{pbid}` and `cred.{value}.user` are the only places a PocketBase id is
  a *reference*: the cardholder id is the credential→user join key.
  `holiday.{pbid}` is also keyed by id, since a holiday has no natural code,
  but nothing references it.
- A credential `value` is a KV key segment, so it must match
  `policykv.CredentialValuePattern`: the NATS KV key charset `-/_=.a-zA-Z0-9`,
  not ending in `.`. Unlike a code it may contain `.`, since it never appears
  in a subject. The same pattern guards the `credentials.value` field and the
  mirror, so an out-of-charset value is rejected at save rather than silently
  never mirrored.
- A missing `posture` mirrors as `secure`. A missing user or credential
  `status` mirrors as `active`.
- `validFrom`/`validUntil` are optional RFC 3339 credential bounds. The
  controller parses them once on apply. A present but unparseable bound drops
  the credential (fail closed).
- The credentials collection's `type` (`generic`/`wiegand`/`pin`/`mobile`) is
  a **control-plane label only**. It is absent from the `cred` value above,
  never crosses the wire, and `policy.Decide` ignores it.

### Holidays

`observeHolidays` (default true) closes every window of that schedule on a
holiday observed by the evaluated portal's location. It is stored inverted as
`schedules.ignore_holidays`, so the safe default holds for any record.

Holidays are grouped into **calendars**. A `holiday` belongs to one calendar,
and a location observes a set of them (`location.holidayCalendars`), so one
shared "Christmas" serves many sites. The controller unions a location's
observed calendars into its holiday set, so the same date can close schedules
at every site that observes the calendar. The `holiday_calendars` collection
is a grouping label only and is **not** mirrored to KV: holidays and locations
both carry the calendar `code`, so the edge never needs the calendar record. A
`holiday` is a local calendar `date`; `recurring` matches that month and day
every year.

### Scheduled posture and arm

`autoPosture` + `autoSchedule` are **scheduled posture**. While the schedule's
window is open, the controller adopts `autoPosture` (any posture, e.g.
`unlocked` for auto-unlock or `lockdown` for an overnight lock) instead of the
standing `posture`. A runtime command override still beats both. The two are
written together or not at all; the mirror drops a half-configured pair. Like
the hardware fields, they are resolved by the controller, never by the pure
`policy.Decide`.

An area's `autoArm` + `autoSchedule` follow the same both-or-neither rule.
`arm` (standing) and `armOverride` take `armed`/`disarmed`; empty means
disarmed and no override respectively.

### Hardware binding

A portal's hardware binding (the `?`-marked fields, omitted when unset) is
**central state**, carried in policy so a box is stateless and swappable:

- `controller` is the code of the edge box that drives the portal.
- `lockRelay`/`dpsInput`/`rexInput` are *logical* relay and input indices on
  that box.
- `heldOpenSeconds` is the held-open (DOTL) threshold.
- `readerAddress` is the reader's OSDP PD address on the box's RS485 bus (used
  when `controller.reader` is `osdp` or `both`). It is also the per-portal OSDP
  enable: `>= 0` is a reader at that PD address (0 is the single-reader case),
  and `-1` is NATS-only. The UI writes `-1` when a portal's OSDP reader is off.

The box maps the logical indices to physical lines through its `model`'s
hardware profile (`internal/drivers/hardware`). The indices and
`controller`/`model` are read only by the controller's PortalManager and
runtime, never by the pure `policy.Decide`.

### Wiring sense

The remaining hardware fields are **per-install wiring sense**, separate from
the board's electrical polarity (which lives in the model profile). The
controller folds them onto that polarity when it arms each line. Like the
indices, they are controller-only and never seen by `policy.Decide`.

- `dpsContact`/`rexContact` are the contact type, `"nc"` or `"no"`. Empty is
  the common default: a DPS is normally **closed** when the door is shut, and a
  REX is normally **open** (closed when pressed). The non-default value inverts
  how a contact edge is read.
- `lockType` is `"strike"` (empty or default; fail-secure, energize to unlock)
  or `"maglock"` (fail-safe, energize to lock, so the relay idles energized and
  releases on power loss). A maglock inverts the lock relay's drive sense.
- `rexUnlock` (default false) makes a REX press also pulse the strike for
  electric egress, not just shunt the forced alarm.
- `aux_input.contact` is the same `"nc"`/`"no"` sense (default normally-open).

---

## 9. Status KV (`ACC_STATUS`)

The upward "device shadow": the live state of each point the edge drives, and
the mirror image of `ACC_POLICY`. **Controllers write** one key per point
(value shapes in [`internal/statuskv`](https://github.com/stone-age-io/access-control/blob/main/internal/statuskv/wire.go)).
**accessd watches** and projects into the rebuildable `point_status`
collection, which the UI subscribes to for realtime. Each key is latest-wins
(KV history 1): this is what is true now, not history. The history of record
is `ACC_EVENTS`. accessd owns bucket creation; controllers bind it read-write.
A controller deletes its keys on disarm, and a reconnect re-publishes the whole
shadow.

accessd's projector ([`internal/status`](https://github.com/stone-age-io/access-control/blob/main/internal/status)) is the upward
twin of a controller's PolicyStore. It `WatchAll`s the bucket (a reconnect
re-delivers every key, a full re-sync). On the sync sentinel it **prunes**
`point_status` rows whose KV key is gone, so a deleted shadow key removes the
projection row.

| Key | Value shape |
| :--- | :--- |
| `portal.{code}` | `{"code","location","controller","door":"open"\|"closed"\|"unknown","posture","source":"standing"\|"scheduled"\|"override","held","updatedAt"}` |
| `auxin.{code}` | `{"code","location","controller","active","updatedAt"}` |
| `auxout.{code}` | `{"code","location","controller","energized","updatedAt"}` |
| `area.{controller}.{code}` | `{"code","location","controller","arm":"armed"\|"disarmed","source":"standing"\|"scheduled"\|"override","peers":["<controller code>"],"updatedAt"}` |

### Portal fields

- `door` is `unknown` on a controller with no DPS input wired (e.g. the mock
  driver) or before the first edge.
- `posture` is the current **effective** posture (command override, scheduled
  or standing). `source` is which of those three produced it, so the UI can
  flag a manual `override` (or an active `scheduled` posture) apart from the
  `standing` state. An empty `source` (a shadow from an older controller) reads
  as `standing`.
- `held` is the **door-held-open (DOTL) alarm flag**, true while a held-open
  alarm is active. It is **not** the strike's physical state; the strike hold
  follows `posture` (only `unlocked` holds it).
- `energized` is an aux output's standing held state. A `pulse` is momentary
  and not shown.

### Area shadows

The area key is **compound**: one shadow per participating controller for the
same area. `code`/`controller` come from the value, not the key.

`peers` is the full participant set (every controller with a member aux input
**or portal** in the area), so the console has a **denominator**:

- **armed** only when *every* peer reports armed;
- **partial/arming** if a peer disagrees or has not reported (e.g. it was
  offline at arm time and converges on reconnect);
- **disarmed** when all peers report disarmed.

The area shadow's `source` is the arm-state's provenance (`armOverride`,
scheduled `autoArm`, or standing `arm`), the same three words as posture. It
reaches the event stream as the arm-transition event's `armSource`.

---

## 10. Decision

`policy.Decide` is a pure function evaluated locally per tap. The order is the
contract, and **deny-overrides come first**:

1. Unknown portal → `deny_unknown_point`.
2. Posture gate: `disabled` → `deny_point_disabled`; `lockdown` →
   `deny_lockdown` (beats a valid credential); `unlocked` →
   `allow_posture_unlocked` (strike held, credential not consulted);
   `free_access` → `allow_posture_free_access` (any tap opens, credential not
   consulted); `secure` → continue. Any other (unknown or empty) posture fails
   closed as `deny_point_disabled`.
3. Credential/user: unknown credential → `deny_unknown_credential`; non-active
   credential → `deny_revoked`; before `validFrom` → `deny_not_yet_valid`;
   after `validUntil` → `deny_expired`; unknown or non-active user →
   `deny_revoked`.
4. Grant: walk the user's roles → access groups. A group that contains this
   portal **and** whose schedule window is open now (and the day is not a
   holiday the schedule observes) → `allow_grant`. If a group contained the
   portal but no window was open → `deny_schedule_closed`. If none contained it
   → `deny_no_access`.

The controller, not `Decide`, resolves the effective posture fed to step 2: a
runtime command override, else scheduled posture (`autoPosture` while
`autoSchedule` is open), else the standing `posture`.

| Concept | Values |
| :--- | :--- |
| Posture | `secure` · `free_access` · `unlocked` · `lockdown` · `disabled` |
| Status (user/cred) | `active` (anything else denies: `suspended`, `revoked`) |
| Reason codes | `allow_grant` · `allow_posture_unlocked` · `allow_posture_free_access` · `allow_command_grant` · `deny_unknown_credential` · `deny_revoked` · `deny_not_yet_valid` · `deny_expired` · `deny_no_access` · `deny_schedule_closed` · `deny_lockdown` · `deny_point_disabled` · `deny_unknown_point` |

::: warning Reason codes are a public contract
They flow verbatim into `tap` events and the `events` collection, and
downstream consumers and dashboards depend on them. The `*_point` codes keep
that spelling although the entity is called a portal.
:::

A **denied badge remote unlock** (see [Audit Projection](#11-audit-projection))
is the one tap event whose `reason` can fall outside this set. Besides any
`policy.Decide` code, accessd emits `remote_unlock_not_allowed` (the portal's
`allow_remote_unlock` is off, checked before the graph is consulted) and
`no_credential` (the holder has no credential to decide with).

### Non-portal targets

`policy.DecideArea` and `policy.DecideOutput` answer the same question for the
other two target kinds an access group can grant. They are **siblings** of
`Decide`, not branches inside it: `Decide`'s order is a contract on the per-tap
hot path, and an area has neither a posture gate nor a strike to pulse. Step 3
above, the credential/user ladder, is shared code (`subjectFor`), so a pass a
door refuses is refused here the same way.

`DecideArea(p, loc, cred, area, action, atUTC)`, where `action` is `arm` or
`disarm`:

1. Unknown area → `deny_unknown_area`.
2. Credential/user → the shared ladder (same codes as step 3 above).
3. Grant: a group containing this area, holding the right for this action,
   whose schedule window is open now → `allow_area_grant`. Otherwise, most
   specific first: a group had the area **and** the right but no window was
   open → `deny_schedule_closed`; a group had the area but not this right →
   `deny_no_area_right`; no group had it → `deny_no_access`.

`DecideOutput(p, loc, cred, output, atUTC)` is the same walk without the
arm/disarm split: `deny_unknown_output` → the ladder → `allow_output_grant` /
`deny_schedule_closed` / `deny_no_access`.

| Concept | Values |
| :--- | :--- |
| Arm actions | `arm` · `disarm`, **separate rights** (`group.areaRights`); an empty list grants neither |
| Added reason codes | `allow_area_grant` · `allow_output_grant` · `deny_unknown_area` · `deny_unknown_output` · `deny_no_area_right` |

`deny_no_area_right` is distinct from `deny_no_access`. It marks a group with
areas chosen and `areaRights` left empty: a misconfiguration an operator can
fix, not an access decision.

Neither function reads an area's **arm-state**. Authorizing a change is pure;
*resolving* the current state depends on time, schedule and override (like
posture), and is done by the controller's `AreaManager` or accessd's snapshot.
So a grant to disarm is a grant whether the area is armed or not, and disarming
an already-disarmed area is a no-op, not a denial.

---

## 11. Audit Projection

`ACC_EVENTS` is the system of record for events. The PocketBase `events`
collection is a rebuildable projection behind the UI timeline. The durable
consumer (`acc-audit`) delivers from the start of the stream and is
**at-least-once, made idempotent**: each row carries the message's JetStream
stream sequence (`stream_seq`, unique-indexed), and a redelivery whose row
already landed is acked and skipped.

A message that will not project is **not** retried forever. Each failure is
redelivered with a growing delay (`NakWithDelay`, 1s → 2min, about six minutes
in total), and after nine deliveries it is `Term`ed. The event stays in
JetStream and only its row is missing until a rebuild; an immediate-redelivery
loop would fill the log with one event. A subject that does not parse as an
event is acked and skipped. A body that is not JSON is kept as
`payload: {"raw": "<body>"}`.

Each event subject maps to a row:

| Column | Source |
| :--- | :--- |
| `location`, `type`, `portal`, `kind` | Parsed from the subject (`kind` ∈ `tap`/`state`/`alarm`/`fire`) |
| `credential`, `user`, `allow`, `reason`, `ts` | The matching body fields (`cred` → `credential`). `user` is the cardholder id for a credential decision, or the issuing actor for a command grant (an operator email or `badge:<cardholderId>`) |
| `user_name` | The cardholder's `name`, resolved from `user` **at projection time**. It is a snapshot, so a later rename or delete does not change who the event was about. Empty when `user` is not a cardholder id (no user, a command actor, legacy rows); the UI falls back to `user` |
| `source` | Tap body field: **what produced the tap**. `nats`/`osdp` (a reader) or `command`/`badge` (a remote act that never reached a reader). Empty on non-tap and legacy rows. See the warning below |
| `acknowledged`, `ack_by`, `ack_at` | Operator acknowledgement, set with `POST /api/events/{id}/ack` (the `command` capability) |
| `stream_seq` | The message's JetStream stream sequence (the idempotency key; 0 on rows projected before it existed) |
| `repage_count` | Reminders sent for an unacknowledged alarm ([`internal/repage`](https://github.com/stone-age-io/access-control/blob/main/internal/repage)). On the row so the cap survives a restart |
| `payload` | The full event body (JSON) |

::: warning `source` is a select field
An out-of-range value would fail the whole row, so the consumer writes a
value only if the collection's field accepts it; otherwise the value stays in
`payload` alone. Adding a value is a migration.
:::

The `(type, kind)` pair tells the event shapes apart; no new `kind` value
exists for any of the newer shapes:

| `type` | `kind` | Meaning |
| :--- | :--- | :--- |
| portal kind | `tap` | A decision (a card read, an operator grant, or a badge remote unlock; see `source`) |
| portal kind | `state` | A posture command (set or clear) |
| portal kind | `alarm` | `forced` / `held` / `held_clear` / `no_entry` |
| `area` | `alarm` | An intrusion trip |
| `area` | `state` | An arm/disarm transition |
| `ctrl` | `state` | A controller liveness transition |
| *(empty)* | `fire` | A location's fire input (4-token subject) |

- For `acc.{location}.evt.fire`, `portal` and `type` are empty and `kind` is
  `fire`.
- For an area intrusion alarm, `type` is `area`, `portal` is the area code,
  `kind` is `alarm`, and `payload.type` is `intrusion` (with `payload.point`
  naming the tripped input).
- The ack fields live on the projection row. The `stream_seq` dedupe means a
  redelivery or stream replay does not bring back an already-acknowledged row.
  Rows from before the field existed read `stream_seq` 0 and are exempt from
  the unique index.

A **denied badge remote unlock** is emitted by accessd as an ordinary `evt.tap`
with `allow: false` and `source: badge`, so a person denied at a door produces
an events row whether they tap a card or press the button. `cred` is empty: the
badge tier is identity-based, `user` carries `badge:<cardholderId>`, and it
keeps credential values out of one more place. The badge routes also write an
`audit_logs` row, which records the API call, a different question.

---

## 12. Notifications & Webhook

### Notification sink

A second, independent durable consumer (`acc-notify`,
[`internal/notify`](https://github.com/stone-age-io/access-control/blob/main/internal/notify)) on `ACC_EVENTS` emails on `alarm`/
`fire` and controller liveness transitions. Its filter is
`acc.*.*.*.evt.alarm`, `acc.*.evt.fire` and `acc.*.ctrl.*.evt.state`, not
portal or area `evt.state`.

- It runs parallel to `acc-audit`, not coupled to it. The audit consumer is an
  at-least-once projection, and alerting from there would double-send on
  redelivery.
- It uses **`DeliverNew`, not `DeliverAll`**. Alerting is not a backfillable
  projection, so the sink starts from now instead of emailing every
  historical alarm.
- Bounded redelivery (`MaxDeliver`) keeps a dead SMTP server from looping
  forever. The SMTP transport is PocketBase's own mail settings, configured in
  `/_`.
- It is **config-free and always started** (like the disarm sink), and stays
  inert unless two opt-ins line up: the alarm's source opts in
  (`portals`/`areas.notify_on_alarm`, `locations.notify_fire`) **and** at least
  one operator opts in (`users.notify`).
- The sink itself does not touch PocketBase. It parses the event and hands it
  to accessd, which resolves the source opt-in and the recipients.

Recipients are **scoped by location**. `users.notify_locations` is the set of
locations an operator is paged for. An alarm at location *L* mails only the
notify operators whose scope is empty (all locations, the default) or contains
*L*. This routes site-local alarms to site-local people without a per-source
to per-operator rules engine.

Recipients are also **scoped by severity**. `users.notify_types` selects which
kinds of event page an operator. An **empty selection means the default set**
(`forced`, `held`, `intrusion`, `fire`, `controller_offline`), not literally
everything. So an operator who never narrows keeps receiving future urgent
types, while `no_entry` stays off until chosen. `held_clear` is never emailed
(a clear, not a raise), and a controller coming back *online* is not paged. A
controller's source opt-in is `controllers.notify_offline`.

Each message carries a **deep link** to the exact event,
`{AppURL}/alarms?seq={stream_seq}`. It is keyed by the JetStream stream
sequence, not the row id, because the notify sink knows the sequence but is a
separate durable from the audit projection and may run *before* the row exists.
The console polls briefly for that race rather than reporting "not found". With
no console URL configured (PocketBase's `Settings().Meta.AppURL`), the link is
omitted.

### Unacknowledged-alarm reminders

[`internal/repage`](https://github.com/stone-age-io/access-control/blob/main/internal/repage) re-sends a notification for an alarm
still unacknowledged after 15 minutes, at most twice, and only for the urgent
types (never `held`/`no_entry`). It reuses the *same* SendFunc, so a reminder
can never reach anyone the original page could not. It is a projection reader,
not a durable: "still unacknowledged N minutes later" is a question about
accumulated state, not a message arriving.

### Webhook sink

A fourth durable (`acc-webhook`, [`internal/webhook`](https://github.com/stone-age-io/access-control/blob/main/internal/webhook))
POSTs each pageable event as JSON to `accessd.webhookURL`, so an install can
feed its own PagerDuty, Slack, ntfy or ITSM rather than relying on email. It
shares the notify sink's classification, so email and webhook never disagree
about what is worth forwarding. It **ignores the per-source and per-operator
email opt-ins**: those decide who gets mail, while a webhook has one configured
destination whose purpose is to receive the feed. Configuring the URL is the
opt-in. Payload:

```json
{"type":"forced","kind":"alarm","location":"hq","thing":"lobby-main",
 "thingType":"door","ts":"…","seq":42,"link":"https://…/alarms?seq=42","body":{…}}
```

`seq` is stable and unique, so a receiver can deduplicate redeliveries.
Delivery retries are JetStream's (`Nak`, bounded by `MaxDeliver`), not a
separate queue.

::: warning Redirects are never followed
The timeout is hard. accessd POSTs from inside the deployment's network, so
the destination is deploy-time config, not an operator-editable record.
:::

---

## 13. Where to Go Next

- Bucket, stream and subject config keys: [Configuration Reference](configuration.md)
- Who may send commands and acknowledge alarms: [Operators & Authorization](operators.md)
- Boards, drivers and OSDP readers: [Hardware & Readers](hardware.md)
- What the system is and how to run it: [Access Control](../README.md)
