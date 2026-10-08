---
path: access-control/protocol
nav_order: 10
---
# stone-access protocol reference

The wire contract between the central app (`accessd`) and the edge controllers
(`access-controller`), carried entirely over NATS. There are two planes:

- **Policy plane** — `accessd` mirrors the PocketBase policy graph into a NATS KV
  bucket (`ACC_POLICY`), one key per record; controllers watch it into memory.
- **Event/command plane** — controllers decide locally and publish access events
  to JetStream (`ACC_EVENTS`); operators issue commands over core NATS.

Subjects, KV keys, and message shapes below are the source of truth shared by
both binaries. Subject construction and parsing live in one place,
[`internal/subjects`](https://github.com/stone-age-io/access-control/blob/main/internal/subjects/subjects.go); the KV value shapes live
in [`internal/policykv`](https://github.com/stone-age-io/access-control/blob/main/internal/policykv/wire.go) (policy, downward) and
[`internal/statuskv`](https://github.com/stone-age-io/access-control/blob/main/internal/statuskv/wire.go) (status, upward). Config keys
(bucket/stream names, the app token) have their own reference in
[`configuration.md`](configuration.md).

## Contents

- [Subject namespace](#subject-namespace) — the `acc.>` token layout and why it leads
- [Subjects](#subjects) — every subject, command bodies, door alarms, scheduled posture
- [Policy KV (`ACC_POLICY`)](#policy-kv-bucket-acc_policy) — downward policy mirror, one key per record
- [Status KV (`ACC_STATUS`)](#status-kv-bucket-acc_status) — upward device shadow
- [Decision](#decision) — the pure `policy.Decide` order and reason codes
- [Audit projection](#audit-projection-events-collection) — JetStream → PocketBase `events` rows

## Subject namespace

Every subject **leads with the app token `acc`**: the access app owns the
`acc.>` subtree, and a **portal** (a controllable opening or logical access
target) is a Thing addressed underneath it as `acc.{location}.{type}.{thing}`,
with the verb trailing (`.tap`, `.cmd.*`, `.evt.*`). Leading with a literal app
token is what keeps `ACC_EVENTS`'s subjects disjoint from every sibling app's
stream on a shared NATS account — JetStream forbids overlapping stream subjects,
and a subject that *led with a wildcard* (e.g. `*.*.*.acc.evt.>`) would intersect
any stream rooted at a literal first token (`things.>`, `cameras.>`,
`kiosk.*.event.>`, …). The `acc` token is set by `subjects.app` in config (or
`SA_SUBJECTS_APP`), default `acc`. `accessd` and all controllers **must use the
same app token** — they publish and subscribe to each other's traffic, so a
mismatch silently severs policy/commands/events. Change it only to isolate a
deployment on a shared NATS account; it must be a single NATS token (no `.`, `*`,
`>`, or whitespace).

`{location}`, `{type}`, and `{thing}` are each a single NATS token and the record
**codes** (e.g. `hq`, `door`, `lobby-main`), never PocketBase ids. The mirror
rejects a location, portal, controller, aux input/output, or area code (or a portal
type) that is not a single token or that collides with a reserved keyword
(`acc`/`evt`/`cmd`/`tap`/`fire`); the record is logged and simply never mirrored.

## Subjects

| Subject | Dir* | Transport | Body |
|---|---|---|---|
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

\* → ctrl = controller subscribes; ctrl → = controller publishes; accessd → =
accessd publishes; ↔ = both (see fire, below).

Two event subjects are published by **accessd**, not the edge, and both are
`evt.state` distinguished by their `{type}` token:

- **`area` — an arm/disarm transition.** All four ways an area changes arm-state
  (an operator's arm route, entry-disarm, the one-shot release sweep, and a
  scheduled auto-arm evaluated on each box) converge on the per-controller arm
  shadow in `ACC_STATUS`, so accessd's status projector emits from there. It is
  emitted **per participating controller** — a 3-box area reports three
  transitions, each naming its own controller — matching the shadow's granularity.
  Scheduled auto-arm has no other trace anywhere in the system. `arm`/`previous` are
  `armed`/`disarmed`; `ts` is the shadow's own `updatedAt`. It fires only when an
  existing projection row's state *changes* — a key's first report is not a
  transition, so a cold boot manufactures no event per area. The shadow's provenance
  (`standing`/`scheduled`/`override`) travels as **`armSource`, not `source`**:
  `source` is the audit projection's select over how an event *arrived*
  (`nats`/`osdp`/`command`/`badge`), and shipping arm provenance under that key put a
  value the select rejects into every arm event (see [Audit
  projection](#audit-projection-events-collection)).
- **`ctrl` — a liveness transition.** Heartbeats stay off the stream (they are a
  flood); an online↔offline flip is one event per outage and is audited. `ctrl` is
  the reserved controller token, the same one the heartbeat uses — the heartbeat
  sits outside `.evt` at 5 tokens so the stream cannot capture it, while this sits
  inside at 6 so it can. `status` is `online`/`offline`; `lastSeen` is the
  controller record's `last_seen` in PocketBase's datetime format
  (`2006-01-02 15:04:05.000Z`), not RFC 3339.

Both fit the existing `acc.*.*.*.evt.>` stream subject; **no stream subject
changed** for either.

`acc.{location}.evt.fire` is bidirectional. A controller whose `aux_input` has
`pointType: "fire"` publishes it on **both edges** (assert and clear), and every
controller at that location — including the publisher, harmlessly and
idempotently — subscribes and applies it. That is why it is location-scoped while
the contact is bound to one box.

The NATS reader subscribes to the **exact** `.tap` subject of each portal it has
armed (the portal's own location/type/code), not a location wildcard, so it hears
only portals this box drives. Commands are subscribed per location with wildcards —
`acc.{location}.*.*.cmd.posture`, `acc.{location}.*.*.cmd.grant`, and
`acc.{location}.*.*.cmd.output` (aux outputs) — so every controller at a location
hears every command there and silently ignores those for portals/outputs it does not
drive.
The audit surface is the `acc.*.…evt` subtree,
captured by `ACC_EVENTS` and projected into the `events` collection via **two
stream subjects of different fixed arity** (JetStream forbids overlapping subjects,
so the short one must not use a trailing `>`):

- `acc.*.evt.fire` — the 4-token location-scoped fire (`acc.{location}.evt.fire`)
- `acc.*.*.*.evt.>` — the 6+-token portal events (`acc.{location}.{type}.{thing}.evt.{kind}`)

A 4-token subject can never match the ≥6-token portal pattern, so the two are
disjoint with each other; both lead with the literal `acc`, so the set overlaps
no sibling stream rooted at another literal (`things.>`, `cameras.>`,
`kiosk.*.event.>`, …) on a shared account. All bodies are JSON; `ts` is RFC 3339
UTC.

A **controller** is addressed under the reserved `acc.{location}.ctrl.{code}`
namespace (`ctrl` is not a portal type). Its **heartbeat** sits deliberately
*outside* the `.evt` subtree — a 5-token subject with no `evt`, so it matches
neither audit pattern and is **never captured by `ACC_EVENTS`**. accessd
subscribes to `acc.*.ctrl.*.heartbeat` over core NATS and writes the controller's
`last_seen`/`status` directly on the `controllers` record (not an `events` row,
which would flood the audit log). A controller publishes one heartbeat on start
and then every `controller.heartbeatInterval` (default 15s); accessd marks a
controller `offline` once it has been silent longer than
`accessd.controllerOfflineAfter` (default 45s).

### Command details

- **posture** — installs a runtime posture override for the portal. Valid values:
  `secure`, `free_access`, `unlocked`, `lockdown`, `disabled`, or `clear` (reverts
  to the *effective* posture from policy — scheduled posture if its window is open,
  else the standing posture). Overrides are operational state on the controller and
  are **never written back to PocketBase**. `until` is parsed but **deliberately
  ignored** — timed reversion must come from an external scheduler publishing a
  follow-up command. `free_access` opens on any tap without consulting the
  credential (strike pulses, door stays closed); `unlocked` holds the strike open.
  Each set or clear emits one `evt.state` carrying the now-effective posture and the
  command's `actor`/`reason`. That is the **only** source of `evt.state` for a
  portal: a scheduled-posture window boundary or a standing-posture edit emits no
  event (the status shadow's `source` reflects it instead).
- **grant** — a momentary strike pulse (the same physical effect as a credential
  grant, operator-initiated), distinct from a standing posture change.
  `seconds <= 0` (or omitted) falls back to the portal's configured `pulseSeconds`.
  Emits an `evt.tap` with `allow=true`, `reason=allow_command_grant`, empty `cred`,
  and `user` set to the issuing actor, so the open is attributable in the audit
  trail. The optional `source` names the remote surface that sent it and is copied
  onto that event: the badge tier sends `badge`; absent/empty (the operator route,
  and any older publisher) becomes `command`. The command's own `reason` is only
  logged.
- **output** — drives a named auxiliary output relay (`auxout` type). `on`/`off`
  set the standing held state; `pulse` energizes momentarily (`seconds<=0` falls
  back to the aux output's configured `pulseSeconds`); any other action is ignored.
  Aux outputs are first-class Things bound to a controller, addressed like portals;
  their live state flows up the status channel (`auxout.{code}`). It emits **no**
  event — an output command leaves no `events` row (for `on`/`off`, the shadow's
  `energized` reflects it; a `pulse` is momentary and not reflected).
- **fire** — toggles a location's fire-alarm-input state. While active, the
  controller **suppresses alarm emission** for that location if it opts in via
  `faiSuppress` (forced/held-open
  events would be false alarms during evacuation). It never changes posture and
  never unlocks — hardware owns egress. It is location-scoped (not per-portal) and
  lives on the `evt` namespace, not `cmd`: it is both a control input the
  controller subscribes to *and* an audited event the stream captures
  (`kind="fire"`).

### Door monitoring & alarms

The controller runs a per-portal door-state machine fed by two digital inputs —
a **door-position switch** (DPS, `dpsInput`) and an optional **request-to-exit**
(REX, `rexInput`). It emits `evt.alarm` events whose `type` is a stable string
(like a reason code), carried as `{"type","ts"}`:

| `type` | Meaning |
|---|---|
| `forced` | door opened with no recent grant or REX — a break-in |
| `held` | an authorized-open door stayed open past `heldOpenSeconds` (DOTL) |
| `held_clear` | a previously-held door closed |
| `no_entry` | a grant whose grace window expired with no door-open — "access granted, no entry" |
| `intrusion` | an armed area's `intrusion` aux point — or any `tamper_24h` point — went active, **or** a member portal was forced while its area is armed |

A grant (an `allow` tap or a `grant` command) and a REX press each open a short
window during which a door-open reads as *authorized* (no `forced`), arming the
held-open timer instead.

`no_entry` is the inverse of `forced`: the grant window closed and nobody came
through, which separates a real entry from a badge test, a stuck strike, or someone
who badged and walked away. It is **exception-only** (a used grant emits nothing, so
the happy path adds no volume) and is evaluated on the existing hold-eval tick rather
than a per-grant timer, so it lands 10–20s after the grant. It is diagnostic rather
than urgent, so notification treats it as opt-in (see below).

It is emitted only where an open is genuinely **observable**, which takes two
independent things: the portal's binding declares a `dpsInput`, *and* the
controller has a door-input driver. Either alone is not enough. They agree on real
hardware and diverge under `driver: mock`, which has a lock and no inputs — so a
box running the simulated reader (every demo and dev box) emits no `no_entry` at
all, rather than one per granted tap.

While a location's **fire** input is active, alarm emission is suppressed
(forced/held/intrusion during evacuation would be false alarms) — but only if the
location opts in via `faiSuppress`, and **`held_clear` is always emitted**: a clear
can never be a false alarm, and dropping it would strand an active held-open on the
console with no later event to resolve it. The DOTL timer and the held-open threshold
are hardware-local timing, not policy.

A location's fire input is an `aux_input` whose `pointType` is **`fire`**. It is
electrically an ordinary dry contact, so it needs no dedicated driver interface: the
controller that owns it publishes `acc.{location}.evt.fire` on both edges, and every
controller at the location applies it. Software's role stays narrow — suppress alarm
noise, record, notify. **Hardware owns egress**: the fire panel's relay drops maglock
power directly, and nothing here unlocks a door.

### Areas & intrusion-lite arming

An **area** is a logical, single-location arm-state grouping that may span several
controllers. A **point** of an area is either an **aux input** (a bare contact /
DPS-only door) or a **portal** (a full reader/DPS/REX door) — membership lives on
each (`aux_input.area` + `point_type`, or `portal.area`). The participant set
(`peers`) and "which areas this box drives" union both kinds.

For an **aux input**, `point_type` decides the trip: a `monitor` point is
observe-only (the default), an `intrusion` point raises an `intrusion` alarm
**while its area is armed**, and a `tamper_24h` point raises one **regardless** of
arm-state — any active edge trips, because a bare contact has no notion of an
"authorized" open.

For a **portal**, the reader changes the rule: an authorized open (a grant/REX) is
normal passage and never an intrusion, so a member portal trips intrusion only on
its **forced** condition (a DPS open with no grant/REX window — exactly what the
door state machine already detects) **while the area is armed**. That forced open
still emits its door-level `forced` event; the area `intrusion` is an additional
armed-zone roll-up. A portal with no area, or whose area is disarmed, escalates
nothing.

Intrusion alarms are addressed as a Thing of type `area` and reuse the generic
alarm subject — `acc.{location}.area.{areacode}.evt.alarm`, body
`{"type":"intrusion","point":"<aux-or-portal-code>","ts"}` — captured by the
existing 6-token portal-event wildcard with no new stream subject. They go through
the same fire-suppression gate as door alarms. Like `forced`, an intrusion alarm is
**edge-triggered** (one per active edge; a continuously-asserted point fires once) —
there is no controller-side latch and no new timer; the events row stays
unacknowledged until an operator acks it.

**Arm-state is durable, not a RAM override.** Unlike posture, a reboot must not
silently disarm, so arming rides the policy KV: an operator arm/disarm writes a
durable `armOverride` field on the area record (via accessd), the mirror propagates
it, and every participating controller converges. The controller resolves the
effective arm-state exactly as it resolves scheduled posture —
`armOverride` → `autoArm` (while `autoSchedule`'s window is open, holidays honored)
→ standing `arm` — and the fail-safe direction is the **inverse of access**: an
unresolved or unknown area falls back to standing (default disarmed) and never
spuriously arms. Arm-state boundaries themselves fire no alarm; they only change
whether a future trip alarms. There is **no `cmd.arm` subject** — arming is a record
write, not a fire-and-forget command.

**Entry-disarm (a valid grant disarms the area).** A portal flagged
`disarmOnGrant` is an *entry* door: a valid credential grant there durably disarms
its area. Because arm-state is durable and central (and an area spans controllers),
this can't be a local edge action — so the edge just emits the `evt.tap` it already
emits, and accessd's **disarm sink** (`internal/disarm`, a third independent durable, `acc-disarm`,
on ACC_EVENTS alongside the audit and notify consumers, `DeliverNew`, filter
`acc.*.*.*.evt.tap`) observes the grant and writes the same durable `armOverride:
disarmed` the manual disarm route writes; the mirror then converges every peer
controller. Only a **credential** grant disarms (`allow` with a `cred`): a deny is
ignored, and an operator remote `cmd.grant` carries no `cred`, so a remote door-pop
can't silently disarm a building. The write is idempotent and skips an area that is
already disarmed / can never be armed, so a redelivery is a harmless no-op (no dedup
needed). Each disarm writes its own `audit_logs` row attributed to the credential +
portal. **One-shot release:** a disarm `armOverride` (manual *or* entry-disarm) on a
*scheduled* area is released automatically at the next scheduled arm — accessd's
`internal/armrelease` sweep clears `armOverride` once the area's base arm-state
(scheduled `autoArm` / standing `arm`, override excluded) is disarmed. So scheduled
auto-arm + entry-disarm loops on its own — arm overnight, first badge disarms in the
morning, re-arms the next window — with no operator action. An area with **no**
`autoSchedule` has no scheduled arm to revert to, so its disarm override stays until an
operator clears it (`arm-clear`).

**Badge remote unlock adds no wire surface.** A badge holder opening a door from
their badge page (`POST /api/badge/unlock/{portalId}`, `internal/badgeapi`) publishes
the **existing** `cmd.grant` — no new subject, no new KV key, no controller change.
From the edge's point of view it is indistinguishable from an operator grant, which
is exactly right: the physical effect is the same one-shot strike pulse. Two things
make it safe on the accessd side rather than the edge side:

- **Authorization is `policy.Decide`**, run centrally over a live snapshot of
  `ACC_POLICY` (`internal/policysnapshot`, the same package the access simulator
  uses). So a remote unlock can never exceed what that person's credential opens in
  person, and schedules, holidays, validity bounds and the posture gate all apply
  with no second implementation to drift.
- **`portals.allow_remote_unlock`** (default false) is a per-door opt-in, checked
  before the graph is consulted. It is control-plane only and deliberately **not
  mirrored** to KV — the decision happens before publishing, so the edge never needs
  to know the flag exists.

The published body is `{"seconds":0,"actor":"badge:<cardholderId>","reason":"remote_unlock","source":"badge"}`:
`actor` names the person rather than an operator email, and `source: badge` makes the
controller's resulting `evt.tap` say so (an operator grant's says `command`). Note the
grant carries no `cred`, so — like an operator door-pop — a badge remote unlock
**cannot** trigger entry-disarm.

A badge action never publishes to `.tap`. `Tap.Source` exists so a physical read is
distinguishable from a synthesized one; a phone-initiated open is a command, and
recording it as a credential presentation would make the audit trail assert something
untrue.

**Badge arm/disarm and output add no wire surface either**, for the same two reasons plus
one shape difference. `POST /api/badge/areas/{id}/{arm|disarm}` is authorized by
`policy.DecideArea` over the same snapshot and gated by `areas.allow_remote_arm`, then
writes `areas.arm_override` — a **durable record write**, exactly as the operator route
does, because arm-state must survive a reboot and there is deliberately no `cmd.arm`
subject. `POST /api/badge/outputs/{id}/pulse` is authorized by `policy.DecideOutput`,
gated by `aux_output.allow_remote`, and publishes the **existing** `cmd.output` with
`action: "pulse"`, `seconds: 0` (the output's own configured duration),
`actor: "badge:<cardholderId>"`, and `reason: "remote_output"`. The badge
surface offers no `on`/`off`: a momentary act is self-limiting, where energizing a relay
from a phone and walking away is not.

A badge holder cannot clear an arm override — `arm-clear` is an operator's "revert to the
schedule", and `internal/armrelease` already releases a one-shot disarm on a scheduled
area, so a holder's disarm strands nothing.

**Reading a badge adds no wire surface at all.** `GET /api/badge/me`, `/api/badge/live`, and
the operator's `GET /api/badge/preview/{id}` publish nothing and write nothing — they read a
`policysnapshot` of `ACC_POLICY` plus the PocketBase records the codes in it resolve to.
Worth stating for the preview in particular, because "let an operator see a holder's badge"
has an obvious wire-level implementation that was rejected: minting that holder a session
and letting the operator drive it. A badge action stamps the **cardholder** as its actor, so
those commands would be indistinguishable on the wire and in `events` from the holder's own.
An operator who needs a door opened publishes `cmd.grant` through the operator route under
their own `command` capability, where `actor` is their email rather than `badge:<id>`.

Each input's **contact sense** is configurable per install (`dpsContact`/
`rexContact`/`aux_input.contact`, see Policy KV below): a normally-open vs
normally-closed contact is folded onto the board's electrical polarity so "active"
always means the monitored condition is asserted, regardless of wiring. By default
a REX press only shunts the forced alarm; with `rexUnlock` the controller also
pulses the strike (electric egress). The strike's fail-safe behavior follows
`lockType`: a fail-secure **strike** de-energizes (re-locks) on shutdown/crash,
while a fail-safe **maglock** idles energized and releases on power loss by design.

### Scheduled posture & the strike hold

Of the postures, only `unlocked` (B) has a standing physical effect: the strike is
held energized so the door stands open. Every other posture is enforced lazily at
the next tap, so physically the strike is just *not held*. The controller keeps each
driven portal's hold in step with its effective posture three ways: immediately on
a posture command (so a lockdown re-locks at once), immediately when a portal is
armed, and on a periodic **hold-eval reconcile** (default 10s) that re-evaluates
each portal and is the no-event fallback that flips scheduled posture at window
boundaries. The reconcile is a
*sampling* loop (it reads "is the window open now", never computes boundaries), so
the interval is a pure latency knob with no correctness coupling; if an
`autoSchedule` is set but not yet loaded (mid re-sync) the reconcile keeps the
previous hold rather than flapping the door. A momentary `Pulse` composes with the
hold: the strike is energized while either is active, so a habitual tap during an
auto-unlock window pulses harmlessly. On controller shutdown/crash the strike
de-energizes (fail-secure: the door re-locks; egress stays hardware-owned).

> **Reader options** (`controller.reader`): `nats` (default) — taps arrive by
> publishing to `acc.{location}.{type}.{thing}.tap`, the simulated/integration path,
> driven with `nats pub`; `osdp` — a real OSDP reader polled on the model's RS485
> bus (clear-text in v1; OSDP Secure Channel is a planned fast-follow); or `both` —
> the NATS reader for **every** portal plus the OSDP reader for the portals that
> have a physical reader. In `both` a portal opts into OSDP via its `readerAddress`:
> `>= 0` means a reader at that PD address, `-1` (or absent → 0 is treated as PD 0)
> means NATS-only. `osdp` and `both` require `controller.model` (its RS485 serial
> port). Each emitted `evt.tap` carries a `source` (`nats`/`osdp`) so a physical read
> is distinguishable from a NATS-published tap. The reader is
> independent of the lock/door driver: an `osdp` reader pairs with any
> `controller.driver` (the strike and DPS/REX stay on GPIO/I2C). The **lock and door
> inputs have real drivers**: `controller.driver: mock` (default — no physical I/O,
> no door monitoring) or `gpio` (relays + DPS/REX on real hardware, the
> `controller.model` profile selecting the transport — native GPIO char device or an
> MCP23017 I2C expander; Linux edge hardware).
>
> An OSDP card read becomes a credential string via the **lowercase hex of the raw
> card bytes** (`internal/drivers/osdp/wire`): lossless and format-agnostic, so
> enrollment mirrors what the bench observes. Decimal/Wiegand decoding depends on the
> reader's bit order and is deferred until confirmed against physical hardware.

## Policy KV (bucket `ACC_POLICY`)

One key per record, `<prefix><natural-key>`. Cross-references are stored as
stable **codes** (or credential value / cardholder id), never PocketBase ids, so
keys and values are human-readable and self-contained. `accessd`'s mirror is the
sole writer; controllers are read-only watchers.

| Key | Value shape |
|---|---|
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

An access group grants **three independent kinds of target** under its one schedule:
portals, `areas` (arm/disarm), and `auxOutputs`. An absent or empty list grants nothing
of that kind, so a doors-only group is the common zero case. `areaRights` names which arm
actions `areas` is granted for — **an empty or absent list grants NEITHER**, because
arming and disarming are separate rights (disarming turns intrusion detection off). See
`policy.DecideArea` / `DecideOutput`, which are pure siblings of `Decide` rather than part
of it.

The three group fields are consumed **centrally** today: accessd authorizes a badge
holder's arm/disarm and output actions with those deciders. They are mirrored anyway
rather than read from PocketBase, so there is one authorization substrate rather than two
— and so an OSDP keypad arming a partition at the reader, which is an edge decision, needs
no new wire.

**UI-only fields are deliberately excluded.** The management UI adds
`locations.description`/`coordinates`/`floorplan` and `floorplan_position` on
`portals`, `aux_input`, and `aux_output` for the location map and floor-plan views.
The badge tier's per-record remote opt-ins are excluded for the same reason:
`portals.allow_remote_unlock`, `areas.allow_remote_arm`, `aux_output.allow_remote`, and
`locations.badge_floorplan` gate accessd's own routes, and the edge has no
remote-actuation path to gate. These are visualization and control-plane metadata only —
the mirror's wire shape above omits them, so they never reach `ACC_POLICY` or the
edge. `policy.Decide`, arming, and the door state machine are unaffected, and no
floor-plan image data ever leaves accessd.

`type` is the portal kind (`door`/`turnstile`/`elevator`/`gate`/`logical`) and the
`{type}` subject segment. `timezone` is an IANA name resolved once per location on
the controller. `days` are ISO weekdays (1=Mon … 7=Sun); `start`/`end` are local
wall-clock `HH:MM` (`24:00` allowed as end-of-day); `end <= start` means the
window crosses midnight. `user.{pbid}` and `cred.{value}.user` are the only places
a PocketBase id is a *reference* — the cardholder id is the credential→user join key.
(`holiday.{pbid}` is also keyed by id, since a holiday has no natural code, but
nothing references it.) A credential `value` is a KV key segment, so it must match
`policykv.CredentialValuePattern` — the NATS KV key charset `-/_=.a-zA-Z0-9`, not
ending in `.`; unlike a code it may contain `.`, since it never appears in a
subject. The same pattern guards the `credentials.value` field and the mirror, so
an out-of-charset value is rejected at save rather than silently never mirrored.
A missing `posture` mirrors as `secure`, and a missing user/credential `status` as
`active`.

`observeHolidays` (default true; stored inverted as `schedules.ignore_holidays` so
the safe default holds for any record) closes every window of that schedule on a
holiday observed by the evaluated portal's location. Holidays are grouped into
**calendars**: a `holiday` belongs to one calendar, and a location observes a set
of them (`location.holidayCalendars`), so one shared "Christmas" serves many sites
instead of being duplicated per location. The controller unions a location's
observed calendars into its holiday set, so the same date can close schedules at
every site that observes the calendar. The `holiday_calendars` collection is a pure
grouping label and is **not** mirrored to KV — both holidays and locations carry
the calendar `code`, so the edge never needs the calendar record itself. A
`holiday` is a local calendar `date`; `recurring` matches that month/day every
year. `validFrom`/`validUntil` are
optional RFC 3339 credential bounds (the controller parses them once on apply; a
present-but-unparseable bound drops the credential — fail closed). The credentials
collection's `type` (`generic`/`wiegand`/`pin`/`mobile`) is a **control-plane label
only** — it is deliberately absent from the `cred` value above, never crosses the
wire, and `policy.Decide` ignores it. `autoPosture` +
`autoSchedule` are **scheduled posture**: while the schedule's window is open the
controller adopts `autoPosture` (any posture, e.g. `unlocked` for auto-unlock or
`lockdown` for an overnight lock) instead of the standing `posture`; a runtime
command override still beats both. The two are written together or not at all
(the mirror drops a half-configured pair). Like the hardware fields, `autoPosture`/
`autoSchedule` are resolved by the controller, never by the pure `policy.Decide`.
An area's `autoArm` + `autoSchedule` follow the same both-or-neither rule; `arm`
(standing) and `armOverride` take `armed`/`disarmed`, empty meaning disarmed and
no override respectively.

A portal's hardware binding (the `?`-marked fields, omitted when unset) is **central
state**, carried in policy so a box is stateless and swappable: `controller` is the
code of the edge box that drives the portal; `lockRelay`/`dpsInput`/`rexInput` are
*logical* relay/input indices on that box; `heldOpenSeconds` is the held-open (DOTL)
threshold; `readerAddress` is the reader's OSDP PD address on the box's RS485 bus
(used when `controller.reader` is `osdp` or `both`). It doubles as the per-portal
OSDP enable: `>= 0` is a reader at that PD address (0 = the single-reader case),
`-1` is NATS-only (no OSDP). The UI writes `-1` when a portal's OSDP reader is off. The
box maps the logical indices to physical lines via its `model`'s
hardware profile (`internal/drivers/hardware`); the indices and `controller`/`model`
are consumed only by the controller's PortalManager/runtime, never by the pure
`policy.Decide`.

The remaining hardware fields are **per-install wiring sense**, distinct from the
board's electrical polarity (which lives in the model profile) — the controller
folds them onto that polarity when it arms each line. `dpsContact`/`rexContact` are
the contact type, `"nc"` or `"no"` (empty = the common default: a DPS is normally
**closed** when the door is shut, a REX is normally **open**, closed when pressed);
the non-default value inverts how a contact edge is read. `lockType` is `"strike"`
(empty/default, fail-secure — energize to unlock) or `"maglock"` (fail-safe —
energize to lock, so the relay idles energized and releases on power loss); a
maglock inverts the lock relay's drive sense. `rexUnlock` (default false) makes a
REX press also pulse the strike for electric egress, not just shunt the forced
alarm. Like the indices, these are controller-only and never seen by `policy.Decide`.
`aux_input.contact` is the same `"nc"`/`"no"` sense (default normally-open). `controllers.last_seen`/`status` are **not** mirrored — accessd
writes them from heartbeats (see above), so they are absent from the KV value.

Eventual consistency is fail-safe: an unknown credential, a reference to a
not-yet-synced role/group/schedule, a malformed value, or no policy at all all
result in **deny**. A `WatchAll` re-delivers every key on (re)subscribe, so a
reconnect performs a full re-sync.

## Status KV (bucket `ACC_STATUS`)

The upward "device shadow" — the live state of each point the edge drives, the
mirror image of `ACC_POLICY`: **controllers write** (one key per point, value
shapes in [`internal/statuskv`](https://github.com/stone-age-io/access-control/blob/main/internal/statuskv/wire.go)); **accessd watches**
and projects into the rebuildable `point_status` collection (the UI subscribes for
realtime). Latest-wins per key (KV history 1): this is "what is true now," not
history — the history of record is `ACC_EVENTS`. accessd owns bucket creation;
controllers bind it read-write. A controller deletes its keys on disarm; a
reconnect re-publishes the whole shadow.

accessd's projector ([`internal/status`](https://github.com/stone-age-io/access-control/blob/main/internal/status)) is the upward twin
of a controller's PolicyStore: it `WatchAll`s the bucket (a reconnect re-delivers
every key = full re-sync), and on the sync sentinel it **prunes** `point_status`
rows whose KV key is gone — so a deleted shadow key removes the projection row.

| Key | Value shape |
|---|---|
| `portal.{code}` | `{"code","location","controller","door":"open"\|"closed"\|"unknown","posture","source":"standing"\|"scheduled"\|"override","held","updatedAt"}` |
| `auxin.{code}` | `{"code","location","controller","active","updatedAt"}` |
| `auxout.{code}` | `{"code","location","controller","energized","updatedAt"}` |
| `area.{controller}.{code}` | `{"code","location","controller","arm":"armed"\|"disarmed","source":"standing"\|"scheduled"\|"override","peers":["<controller code>"],"updatedAt"}` |

The area key is **compound** (one shadow per participating controller for the same
area) — `code`/`controller` come from the value, not the key. `peers` is the full
participant set (every controller with a member aux input **or portal** in the area), so the console
has a **denominator**: the area is "armed" only when *every* peer reports armed,
"partial/arming" if a peer disagrees or hasn't reported (e.g. it was offline at arm
time and converges on reconnect), and "disarmed" when all peers report disarmed.
The area shadow's `source` is the arm-state's provenance (`armOverride` / scheduled
`autoArm` / standing `arm`), the same three words as posture; it reaches the event
stream as the arm-transition event's `armSource`.

`door` is `unknown` on a controller without a DPS input wired (e.g. the mock
driver) or before the first edge. `posture` is the current **effective** posture
(command override / scheduled / standing) and `source` is which of those three
produced it — so the UI can flag a manual `override` (or an active `scheduled`
posture) distinctly from the `standing` state. An empty `source` (a shadow from an
older controller) reads as `standing`. `held` is the **door-held-open (DOTL)
alarm flag** — true while a held-open alarm is active — **not** the strike's
physical state; the strike hold follows `posture` (only `unlocked` holds it).
`energized` is an aux output's standing held state (a `pulse` is momentary and
not reflected).

## Decision

`policy.Decide` is a pure function evaluated locally per tap. Order is the
contract — **deny-overrides come first**:

1. Unknown portal → `deny_unknown_point`
2. Posture gate: `disabled` → `deny_point_disabled`; `lockdown` → `deny_lockdown`
   (beats a valid credential); `unlocked` → `allow_posture_unlocked` (strike held,
   credential not consulted); `free_access` → `allow_posture_free_access` (any tap
   opens, credential not consulted); `secure` → continue; any other (unknown or
   empty) posture fails closed as `deny_point_disabled`
3. Credential/user: unknown credential → `deny_unknown_credential`; non-active
   credential → `deny_revoked`; before `validFrom` → `deny_not_yet_valid`; after
   `validUntil` → `deny_expired`; unknown/non-active user → `deny_revoked`
4. Grant: walk the user's roles → access groups; a group that contains this portal
   **and** whose schedule window is open now (and the day is not a holiday the
   schedule observes) → `allow_grant`. If a group contained the portal but no
   window was open → `deny_schedule_closed`; if none contained it → `deny_no_access`.

The effective posture fed to step 2 is resolved by the controller, not `Decide`:
a runtime command override, else scheduled posture (`autoPosture` while
`autoSchedule` is open), else the standing `posture`.

| Concept | Values |
|---|---|
| Posture | `secure` · `free_access` · `unlocked` · `lockdown` · `disabled` |
| Status (user/cred) | `active` (anything else denies: `suspended`, `revoked`) |
| Reason codes | `allow_grant` · `allow_posture_unlocked` · `allow_posture_free_access` · `allow_command_grant` · `deny_unknown_credential` · `deny_revoked` · `deny_not_yet_valid` · `deny_expired` · `deny_no_access` · `deny_schedule_closed` · `deny_lockdown` · `deny_point_disabled` · `deny_unknown_point` |

Reason codes are **stable strings** — they flow verbatim into `tap` events and
the `events` collection, so downstream consumers and dashboards depend on them.
(The `*_point` reason codes keep their historical spelling even though the entity
is now called a portal.)

A **denied badge remote unlock** (below) is the one tap event whose `reason` can
fall outside this set: besides any `policy.Decide` code, accessd emits
`remote_unlock_not_allowed` (the portal's `allow_remote_unlock` is off — checked
before the graph is consulted) and `no_credential` (the holder has no credential to
decide with).

### Non-portal targets

`policy.DecideArea` and `policy.DecideOutput` answer the same question for the other two
target kinds an access group can grant. They are **siblings** of `Decide`, not branches
inside it: `Decide`'s order is a contract on the per-tap hot path, and an area has neither
a posture gate nor a strike to pulse. Step 3 above — the credential/user ladder — is
literally shared code (`subjectFor`), so a pass that a door refuses is refused here
identically.

`DecideArea(p, loc, cred, area, action, atUTC)`, where `action` is `arm` or `disarm`:

1. Unknown area → `deny_unknown_area`
2. Credential/user → the shared ladder (same codes as step 3 above)
3. Grant: a group containing this area, holding the right for this action, whose schedule
   window is open now → `allow_area_grant`. Otherwise, most specific first: a group had the
   area **and** the right but no window was open → `deny_schedule_closed`; a group had the
   area but not this right → `deny_no_area_right`; no group had it → `deny_no_access`.

`DecideOutput(p, loc, cred, output, atUTC)` is the same walk without the arm/disarm split:
`deny_unknown_output` → the ladder → `allow_output_grant` / `deny_schedule_closed` /
`deny_no_access`.

| Concept | Values |
|---|---|
| Arm actions | `arm` · `disarm` — **separate rights** (`group.areaRights`); an empty list grants neither |
| Added reason codes | `allow_area_grant` · `allow_output_grant` · `deny_unknown_area` · `deny_unknown_output` · `deny_no_area_right` |

`deny_no_area_right` is distinct from `deny_no_access` on purpose: it is the signature of a
group with areas chosen and `areaRights` left empty — a misconfiguration an operator can
fix, not an access decision.

Neither function reads an area's **arm-state**. Authorizing a change is pure; *resolving*
the current state is time-, schedule- and override-dependent operational state (like
posture), resolved by the controller's `AreaManager` or accessd's snapshot. So a grant to
disarm is a grant whether the area is armed or not, and disarming an already-disarmed area
is a no-op rather than a denial.

## Audit projection (`events` collection)

`ACC_EVENTS` is the system of record for events; the PocketBase `events`
collection is a rebuildable projection behind the UI timeline. The durable
consumer (`acc-audit`) delivers from the start of the stream and is
**at-least-once, made idempotent**: each row carries the message's JetStream
stream sequence (`stream_seq`, unique-indexed), and a redelivery whose row
already landed is acked and skipped. A message that will not project is
**not** retried forever: each failure is redelivered with a growing delay
(`NakWithDelay`, 1s → 2min, about six minutes in total) and after nine deliveries
it is `Term`ed — the event stays in JetStream and only its row is missing until a
rebuild, where an immediate-redelivery loop would fill the log with one event. A
subject that does not parse as an event is acked and skipped; a body that is not
JSON is kept as `payload: {"raw": "<body>"}`. Each event subject maps to a row:

| Column | Source |
|---|---|
| `location`, `type`, `portal`, `kind` | parsed from the subject (`kind` ∈ `tap`/`state`/`alarm`/`fire`) |
| `credential`, `user`, `allow`, `reason`, `ts` | corresponding body fields (`cred` → `credential`). `user` is the cardholder id for a credential decision, the issuing actor for a command grant (an operator email or `badge:<cardholderId>`) |
| `user_name` | the cardholder's `name`, resolved from `user` **at projection time** — a snapshot, so a later rename or delete does not rewrite who the event was about. Empty when `user` is not a cardholder id (no user, a command actor, legacy rows); the UI falls back to `user` |
| `source` | tap body field — **what produced the tap**: `nats`/`osdp` (a reader) or `command`/`badge` (a remote act that never reached a reader). Empty on non-tap and legacy rows. `source` is a select: the consumer writes a value only if the collection's field accepts it, otherwise it stays in `payload` alone — an out-of-range value would fail the whole row. Adding a value is a migration |
| `acknowledged`, `ack_by`, `ack_at` | operator acknowledgement (set via `POST /api/events/{id}/ack`, the `command` capability) |
| `stream_seq` | the message's JetStream stream sequence (idempotency key; 0 on rows projected before it existed) |
| `repage_count` | reminders sent for an unacknowledged alarm ([`internal/repage`](https://github.com/stone-age-io/access-control/blob/main/internal/repage)); on the row so the cap survives a restart |
| `payload` | the full event body (JSON) |

The `(type, kind)` pair is what distinguishes the newer event shapes; **no new
`kind` value was added** for any of them:

| `type` | `kind` | Meaning |
|---|---|---|
| portal kind | `tap` | a decision (a card read, an operator grant, or a badge remote unlock — see `source`) |
| portal kind | `state` | a posture command (set or clear) |
| portal kind | `alarm` | `forced` / `held` / `held_clear` / `no_entry` |
| `area` | `alarm` | an intrusion trip |
| `area` | `state` | an arm/disarm transition |
| `ctrl` | `state` | a controller liveness transition |
| *(empty)* | `fire` | a location's fire input (4-token subject) |

A **denied badge remote unlock** is emitted by accessd as an ordinary `evt.tap`
with `allow: false` and `source: badge`. Without it, the same person denied at the
same door would produce an events row when they tap a card and nothing at all when
they press the button. `cred` is deliberately empty: the badge tier is
identity-based, `user` carries `badge:<cardholderId>`, and it keeps credential
values out of one more place. The `audit_logs` row the badge routes also write stays
— that records an API call, which is a different question.

For `acc.{location}.evt.fire`, `portal` and `type` are empty and `kind` is `fire`.
For an area intrusion alarm, `type` is `area`, `portal` is the area code, `kind` is
`alarm`, and `payload.type` is `intrusion` (with `payload.point` naming the tripped
input). The ack fields live on the projection row; the `stream_seq` dedupe means
a redelivery or stream replay no longer resurrects an already-acknowledged row
(rows from before the field existed read `stream_seq` 0 and stay exempt from the
unique index).

**Notification sink.** A *second, independent* durable consumer (`acc-notify`,
[`internal/notify`](https://github.com/stone-age-io/access-control/blob/main/internal/notify)) on `ACC_EVENTS` emails on `alarm`/`fire`
and controller liveness transitions (filter `acc.*.*.*.evt.alarm`, `acc.*.evt.fire`,
`acc.*.ctrl.*.evt.state` — not portal/area `evt.state`).
It is parallel to `acc-audit`, not coupled to it (the audit consumer is an
at-least-once projection; coupling alerting there would double-send on redelivery).
It diverges in one way: **`DeliverNew`, not `DeliverAll`** — alerting is not a
backfillable projection, so the sink starts from "now" instead of emailing every
historical alarm. Bounded redelivery (`MaxDeliver`) keeps a dead SMTP server from
looping forever; the SMTP transport is PocketBase's own mail settings, configured
in `/_`. It is **config-free and always started** (like the disarm sink) and stays
inert unless two opt-ins line up: the alarm's source opts in
(`portals`/`areas.notify_on_alarm`, `locations.notify_fire`) **and** at least one
operator opts in (`users.notify`). Recipients are then **scoped by location**:
`users.notify_locations` is the set of locations an operator is paged for, so an
alarm at location *L* mails only the notify operators whose scope is empty (= all
locations, the default) or contains *L* — routing site-local alarms to site-local
people without a per-source→per-operator rules engine. The sink itself stays
PocketBase-free — it parses the event and hands it to accessd, which resolves the
source opt-in and the location-scoped recipients.

Recipients are also **scoped by severity**: `users.notify_types` selects which kinds
of event page an operator. An **empty selection means the DEFAULT set** — `forced`,
`held`, `intrusion`, `fire`, `controller_offline` — not literally everything, so an
operator who never narrows keeps receiving future urgent types, while `no_entry`
stays off until explicitly chosen. `held_clear` is never emailed at all (a clear, not
a raise), and a controller coming back *online* is not paged (good news is not a
page). A controller's source opt-in is `controllers.notify_offline`.

Each message carries a **deep link** to the exact event —
`{AppURL}/alarms?seq={stream_seq}` — keyed by the JetStream stream sequence rather
than the row id, because the notify sink knows the sequence but is an independent
durable from the audit projection and may run *before* the row exists. The console
polls briefly for that race rather than reporting "not found". No console URL
configured (PocketBase's `Settings().Meta.AppURL`) simply omits the link.

**Unacknowledged-alarm reminders.** [`internal/repage`](https://github.com/stone-age-io/access-control/blob/main/internal/repage) re-sends
a notification for an alarm still unacknowledged after 15 minutes, at most twice, and
only for the urgent types (never `held`/`no_entry`). It reuses the *same* SendFunc, so
a reminder can never reach anyone the original page could not. It is a projection
reader, not a durable — "still unacknowledged N minutes later" is a question about
accumulated state, not a message arriving.

**Webhook sink.** A *fourth* durable (`acc-webhook`,
[`internal/webhook`](https://github.com/stone-age-io/access-control/blob/main/internal/webhook)) POSTs each pageable event as JSON to
`accessd.webhookURL`, so an install can feed its own PagerDuty/Slack/ntfy/ITSM rather
than relying on email. It shares the sink's classification (so email and webhook never
disagree about what is worth forwarding) but deliberately **ignores the per-source and
per-operator email opt-ins** — those decide who gets *mail*; a webhook has one
configured destination whose purpose is to receive the feed. Configuring the URL is
the opt-in. Payload:

```json
{"type":"forced","kind":"alarm","location":"hq","thing":"lobby-main",
 "thingType":"door","ts":"…","seq":42,"link":"https://…/alarms?seq=42","body":{…}}
```

`seq` is stable and unique, so a receiver can deduplicate redeliveries. Delivery
retries are JetStream's (`Nak`, bounded by `MaxDeliver`) rather than a bespoke queue.
**Redirects are never followed** and the timeout is hard: accessd POSTs from inside
the deployment's network, so the destination is deploy-time config, not an
operator-editable record.
