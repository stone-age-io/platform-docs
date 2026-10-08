---
path: access-control/plan-events
nav_order: 60
---
# Plan: events, notifications, and the fire input

> **Status: Phases 0–5 are implemented.** Phase 6 (opt-in door state) remains
> deferred, as designed — it is the one phase gated on someone asking for it.
> The durable reference for what shipped is [`protocol.md`](protocol.md) (wire),
> [`configuration.md`](configuration.md) (keys and opt-ins), and `CLAUDE.md`
> (rationale); this file is the record of *why the work was scoped this way* and
> can be deleted once that is no longer interesting.
>
> One deviation from the plan as written: the webhook destination is a **config
> key** (`accessd.webhookURL`), not an operator-editable record. Deploy-time
> config removes the SSRF-shaped API surface entirely rather than guarding it, and
> matches how the other outbound transport (SMTP) is administered.
>
> Three smaller deviations. An **empty** `users.notify_types` means the *default
> set* — every urgent type, but not `no_entry` — rather than literally all (2.2),
> so a future urgent type still reaches everyone who never narrowed. The
> arm-transition event carries its standing/scheduled/override provenance as
> `armSource`, not `source` (1.2): `events.source` is a select of how an event
> *arrived*, and an out-of-range value there stalled the audit consumer. Bulk
> notify (2.3) is a selection action on the portal list rather than a per-location
> button. One loose end from 1.4: the badge-tier deny tap that
> [`internal/badgeapi`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi) publishes is not counted by
> `IncEventPublished` — that package has no metrics handle.

A work plan, not a reference — delete it when the phases land. It covers three
related gaps found reviewing the event/notification path:

1. The **fire input** is a two-thirds feature (nothing produces the signal), and
   `locations.fai_suppress` is a control that does nothing.
2. Several kinds of building history are recorded in the **wrong plane** — or in
   no plane at all.
3. Alarm email is **all-or-nothing and unactionable**, which is how notification
   systems get switched off.

It is deliberately phased so each phase ships and stops. Phases 0–1 are the whole
correctness story and cost roughly 80 lines across five existing files, with no
migrations, no new packages, and no new timers. That ratio is the thing to protect.

## Contents

- [The three record planes](#the-three-record-planes) — the framing the whole plan rests on
- [Decisions taken up front](#decisions-taken-up-front) — settled; don't re-litigate mid-build
- [Phase 0 — stop lying](#phase-0-stop-lying)
- [Phase 1 — move the misfiled planes](#phase-1-move-the-misfiled-planes)
- [Phase 2 — make notifications worth keeping on](#phase-2-make-notifications-worth-keeping-on)
- [Phase 3 — webhook sink](#phase-3-webhook-sink)
- [Phase 4 — a real fire-input source](#phase-4-a-real-fire-input-source) (independent)
- [Phase 5 — `no_entry`](#phase-5-no_entry)
- [Phase 6 — door state](#phase-6-door-state-opt-in-only-if-asked) (opt-in, only if asked)
- [Not building](#not-building) — the explicit no-list
- [Sizing](#sizing)

## The three record planes

The system already records in three places, and the split is good:

| plane | answers | mechanism |
|---|---|---|
| event stream | what happened at the building | `ACC_EVENTS` → [`internal/audit`](https://github.com/stone-age-io/access-control/blob/main/internal/audit) → `events` |
| `audit_logs` | who changed the config | PocketBase `*Request` hooks → [`internal/changelog`](https://github.com/stone-age-io/access-control/blob/main/internal/changelog) |
| status shadow | what is true *right now* | `ACC_STATUS` → [`internal/status`](https://github.com/stone-age-io/access-control/blob/main/internal/status) → `point_status` |

Every gap in Phase 1 is **building history filed in the wrong plane**:

| today | is really | plane it's in | plane it belongs in |
|---|---|---|---|
| arm/disarm (manual, entry-disarm, release) | building history | `audit_logs` | event stream |
| arm/disarm (scheduled auto-arm) | building history | **nowhere** | event stream |
| controller online↔offline | building history | status shadow only | event stream |
| badge deny | building history | `audit_logs` | event stream |
| door open/close, aux input transitions | building history | status shadow only | event stream (opt-in) |

Control-plane edits staying in `audit_logs` is **correct** and stays that way. The
planes are not being merged; three things are being refiled.

## Decisions taken up front

### The projector emits arm events

All four arm paths — manual ([`internal/commandapi`](https://github.com/stone-age-io/access-control/blob/main/internal/commandapi)),
entry-disarm ([`internal/disarm`](https://github.com/stone-age-io/access-control/blob/main/internal/disarm)), one-shot release
([`internal/armrelease`](https://github.com/stone-age-io/access-control/blob/main/internal/armrelease)), and scheduled auto-arm (edge,
[`internal/controller/areamanager.go`](https://github.com/stone-age-io/access-control/blob/main/internal/controller/areamanager.go)) —
converge on exactly one observable: the per-controller arm shadow in `ACC_STATUS`.

[`status.Projector.apply()`](https://github.com/stone-age-io/access-control/blob/main/internal/status/projector.go) already loads the
existing row before saving it, so detecting a transition is comparing two strings
already in hand:

```go
// in apply(), after rowFor() and the find-or-create:
old := rec.GetString("state")           // "" for a newly created row
// ... existing Set() calls, Save() ...
if r.kind == statuskv.KindArea && old != "" && old != r.state {
    // emit acc.{location}.area.{code}.evt.state
}
```

**One code path covers four features** with no new queries, no new timers, and no
migrations. Scheduled auto-arm — which today leaves no trace anywhere in the
system — comes along for free.

**The tension, stated honestly:** this makes `accessd` an event *emitter*, where
the architecture otherwise says the edge emits and accessd projects. The judgment
is that it's fine — the projector already turns edge-reported state into a central
record, and emitting an event is the same act, not a claim of ownership. The
rejected alternative (the edge `AreaManager` emits on its own resolved-state
change) keeps the direction pure but puts emission logic on the edge and produces
N events for an N-controller area with nowhere central to dedupe them.

**Per-controller, not aggregated.** The shadow is keyed `area.{controller}.{code}`,
so a 3-box area yields 3 events. Emit per-controller and carry the controller code:
honest ("`ctrl-hq-1` now considers `zone1` armed"), zero extra queries, and exactly
one event for the common single-box area. Aggregate later only if someone complains.

### Zero new event kinds

`events.kind` is a **SelectField** (`tap`/`state`/`alarm`/`fire`) — widening it
costs a migration plus UI filter changes. `events.type` is a plain **TextField** —
free. The pair `(type, kind)` already carries everything being added:

| new event | subject | type | kind | migration |
|---|---|---|---|---|
| arm/disarm | `acc.{loc}.area.{code}.evt.state` | `area` | `state` | none |
| controller liveness | `acc.{loc}.ctrl.{code}.evt.state` | `ctrl` | `state` | none |
| badge deny | `acc.{loc}.{type}.{portal}.evt.tap` | portal kind | `tap` | none |
| `no_entry` | `acc.{loc}.{type}.{portal}.evt.alarm` | portal kind | `alarm` | none |
| door state (Ph. 6) | `acc.{loc}.{type}.{portal}.evt.state` | portal kind | `state` | none |

`acc.{loc}.ctrl.{code}.evt.state` is 6 tokens, so the existing `acc.*.*.*.evt.>`
stream subject captures it — the same trick area alarms used. **No stream subject
changes anywhere in this plan.**

Two notes. `no_entry` under `alarm` means the notify sink sees it; that is wrong by
default (it's diagnostic, not urgent) and is solved by `notify_types` in Phase 2 —
filing it under `state` instead would start turning `state` into a junk drawer. And
`(door, state)` will serve both posture and door-position after Phase 6; that is the
only genuine ambiguity in the table, and it can be settled when Phase 6 is actually
wanted.

### No new timers

The "no new timers" rule is an **edge discipline**, not a global one.
[`internal/controller`](https://github.com/stone-age-io/access-control/blob/main/internal/controller) has exactly three by design (the
per-door DOTL `AfterFunc`, the heartbeat, and the hold-eval tick). `accessd` already
runs a health sweep ticker, the `armrelease` sweep, `badgesweep`, two crons, and the
KV watcher — it is not under that constraint.

Nothing in this plan adds a timer to the controller. The two candidates that looked
like they would, don't:

- **Controller liveness** is accessd work, and
  [`health.Monitor.sweepLoop`](https://github.com/stone-age-io/access-control/blob/main/internal/health/monitor.go) already ticks at
  `offlineAfter/3`, with `sweep()` already being the exact transition branch.
- **`no_entry`** is edge work, but `reconcileHolds` already ticks every 10s and
  already iterates every driven portal. (It snapshots the portal set under the
  read lock and acts without holding it; the `grantPending` read-and-clear takes
  the write lock the same way `handleDPS` does — decide under the lock, emit after
  releasing it.)

Phase 2's re-page sweep is the one genuinely new background job, and it is on
accessd, modeled on `armrelease`.

### A webhook instead of email templates

Editable email templates were considered and rejected: they buy a template
language, a preview UI, an escaping story, a "my template broke and nobody got
paged" failure mode, and a migration path per new field. What people actually want
is the data somewhere else. Phase 3 ships a webhook; the email body stays fixed and
plain text, with a deep link (Phase 2) doing the work a template would have been
asked to do.

## Phase 0 — stop lying

Small, independent, ship first. Fixes things that are actively misleading.

| # | change | where |
|---|---|---|
| 0.1 | Honor `locations.fai_suppress` at the two suppression sites | [`controller/runtime.go`](https://github.com/stone-age-io/access-control/blob/main/internal/controller/runtime.go) `EmitAlarm`, `emitIntrusionAlarm` |
| 0.2 | Let `held_clear` escape fire suppression | same, `EmitAlarm` |
| 0.3 | Delete the stale "v1 has no alarm source yet" comment | same, above `EmitAlarm` |

**0.1** — `FAISuppress` is on the wire ([`policykv.Location`](https://github.com/stone-age-io/access-control/blob/main/internal/policykv/wire.go))
and written by [`mirror`](https://github.com/stone-age-io/access-control/blob/main/internal/mirror/mirror.go), and **nothing reads it**.
Suppression is unconditional today, so an operator toggling "FAI Suppress" off in
the UI changes nothing. It needs one condition in each of the two suppression
sites, reading the location from the store. Default stays suppress-on.

**0.2** — a clearing event cannot be a false alarm. Today, fire going active while
a door is held-open means the `held_clear` never emits and the alarm console keeps
a stuck badge that no later event resolves. `point_status` recovers; the event row
never does.

## Phase 1 — move the misfiled planes

No migrations. No new timers. No new packages.

### 1.1 Controller online↔offline

[`health.sweep()`](https://github.com/stone-age-io/access-control/blob/main/internal/health/monitor.go) queries only `status = 'online'`
and writes only on the flip — it is already the transition branch. Emitting is one
call inside it.

The online direction needs one comparison: `markOnline` currently sets status
unconditionally, so it doesn't know it transitioned. Guard on
`rec.GetString("status") != statusOnline` before the `Set`.

Body carries `{"status":"online"|"offline","lastSeen":...,"ts":...}`. This is the
event that makes "a site just went to cached policy / default-deny" pageable, which
is arguably the most operationally urgent thing the system can notice.

`health.Monitor` needs a NATS publish handle; it already holds `*nats.Conn`.

### 1.2 Arm/disarm

Per the decision above: [`status.Projector.apply()`](https://github.com/stone-age-io/access-control/blob/main/internal/status/projector.go),
comparing `old` to `r.state` on the already-loaded record, emitting per-controller.

Body carries `{"arm":"armed"|"disarmed","controller":...,"source":...,"ts":...}` —
`source` (standing/scheduled/override) already rides the area shadow payload, so an
operator can tell a scheduled arm from an override.

Once this lands, the `audit_logs` row that [`writeDisarmAudit`](https://github.com/stone-age-io/access-control/blob/main/cmd/accessd/main.go)
writes for entry-disarm stays as the *config-write* record; the building-history
answer now comes from the event stream. Don't delete it — they're different questions.

### 1.3 Badge denies

A physical deny writes an `events` row; a badge remote-unlock deny writes only
`audit_logs`, because the deny never reaches a controller. Same person, same door,
different record type depending on surface — so "who's been probing doors" needs a
union across two collections.

accessd emits the `evt.tap` with `allow:false` directly from
[`internal/badgeapi`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi). Downstream is safe by construction: the
disarm sink already filters `allow && cred != ""`, and notify only handles
`alarm`/`fire`.

Set `source` on the emitted event (`badge`) — and while in there, the command-grant
emit in [`runtime.Grant`](https://github.com/stone-age-io/access-control/blob/main/internal/controller/runtime.go) doesn't set `Source`
either, so an operator door-pop and an OSDP read are distinguishable only by
string-prefixing `user`. Fix both.

### 1.4 Metrics

Add the new emissions to `IncEventPublished`. Trivial, easy to forget.

## Phase 2 — make notifications worth keeping on

Highest felt value for an operator. This is where schema and UI work starts.

### 2.1 Deep link

The single most valuable change in the plan. Today an operator gets
`[stone-access] forced alarm: hq/door/lobby-main` at 2am and then has to go find it.

[`notify.process`](https://github.com/stone-age-io/access-control/blob/main/internal/notify/consumer.go) can read
`msg.Metadata().Sequence.Stream`, and the audit consumer already writes
`stream_seq` **unique-indexed** (migration `1750000025`) — so the email links to the
*exact row*, not a filter. Thread the sequence into `process` as a parameter (keeps
it testable, no `jetstream.Msg` in the signature).

Console URL comes from `Settings().Meta.AppURL`, which PocketBase already uses for
its own mail. **No new config key.**

**The race is real and must be handled:** notify is `DeliverNew` on its own durable,
audit is a separate durable, so the email can beat the row into existence. The
console route needs a "not projected yet, retrying" state rather than a 404. Neither
`AlarmConsoleView` nor `EventListView` reads query params today, so this is a small
UI addition regardless of which link shape is chosen.

### 2.2 `users.notify_types`

Multi-select (`forced`/`held`/`intrusion`/`fire`/…), **empty = all** so existing
operators keep current behavior. One field, one filter line in `notifyRecipients`.

`held` is by far the highest-volume alarm (a propped door in July) and the least
urgent; bundling it with `intrusion` is why people switch notifications off. This is
also what keeps `no_entry` (Phase 5) out of inboxes by default.

### 2.3 Bulk enable

`portals.notify_on_alarm` is a per-portal toggle on the portal form only. 400 doors
is 400 checkboxes, and a newly created door defaults to **off** — so the failure mode
is silence, which nobody notices.

A "enable notify on all portals at this location" action in the portal list. Less
schema and less thinking than tri-state inheritance; revisit only if it isn't enough.

### 2.4 Unacked re-page

The one new background job. Modeled on [`internal/armrelease`](https://github.com/stone-age-io/access-control/blob/main/internal/armrelease):
a sweep that re-pages a `forced`/`intrusion` still unacknowledged after N minutes,
using the `acknowledged`/`ack_by`/`ack_at` fields already built in migration
`1750000020`.

Those fields and the notify sink currently don't talk to each other at all. This is
what turns alarm email from a firehose into a duty-of-care mechanism. Bound the
re-page count (2–3) so a permanently unacked alarm doesn't page forever.

## Phase 3 — webhook sink

A **fourth durable** beside audit/notify/disarm — not a second `SendFunc` — so it can
subscribe to more than alarms. With Phase 1 done, that includes controller-offline
and arm/disarm, which is exactly what a NOC wants. JetStream `Nak` gives retry for
free, which is the whole argument for sink-over-hook.

Payload is the structured [`notify.Event`](https://github.com/stone-age-io/access-control/blob/main/internal/notify/consumer.go) shape, not
rendered text — the point is that the receiver renders it.

**This closes the template question.** "We want it to look different" becomes "point
it at your ntfy / Slack / PagerDuty / ITSM," all of which render better than anything
written here.

**It is an SSRF surface.** Non-negotiable: no redirect following, a hard timeout, and
the URL setting gated behind `operators` / superuser.

## Phase 4 — a real fire-input source

**Independent of Phases 1–3; can slot in anywhere after Phase 0.**

Three layers exist today and the bottom one is empty. Consumption is complete and
tested (`SetFire` → `r.fire[location]` → gates both alarm emitters; `TestIntrusionFireSuppressed`).
Transport is complete (`acc.{loc}.evt.fire`, subscribed on core NATS *and* captured
by `ACC_EVENTS` — a genuinely good bit of design). But **nothing produces the signal**:
[`drivers.FAIInput`](https://github.com/stone-age-io/access-control/blob/main/internal/drivers/drivers.go) has zero implementations, no board
profile carries an FAI line, and the only way to assert fire is a hand-published NATS
message (which is what [`demo/access-demo.yaml`](https://github.com/stone-age-io/access-control/blob/main/demo/access-demo.yaml) tells you to do).

**Make FAI an aux input point type and delete `drivers.FAIInput`.**

Add `fire` to `aux_input.point_type` (migration; the enum is
`monitor`/`intrusion`/`tamper_24h` today). Then it inherits the wiring UI (aux inputs
already have controller, index, contact sense, floorplan position), the driver path
(`InputAux` already flows through GPIO and I2C polling), and the status shadow. The
controller publishes `evt.fire` on the transition and hears its own message back —
idempotent, and that is exactly how the *other* boxes at the location learn about it,
which is why the subject is location-scoped in the first place.

This turns the FAI from code (an interface plus per-controller config that doesn't
exist) into data (a row an integrator creates like any other point). It deletes an
interface and a config concept instead of adding them.

**The trap:** `setAuxInput` only calls `maybeIntrusionAlarm` on the **rising** edge.
Fire needs both edges, so the `fire` case hangs off `setAuxInput` *above* that guard,
not inside the intrusion switch.

Software's role stays exactly what the existing doc comments say: suppress alarm
noise, record it, notify. **Hardware owns egress** — the FACP relay cuts maglock power
directly, and software is never in that path.

## Phase 5 — `no_entry`

The classic *access granted, no entry* case: it separates a real entry from a badge
test, a stuck strike, and someone who badged and walked away. Every commercial PACS
logs it; today it's unanswerable because `handleDPS` writes only to the shadow.

Exception-only, so **zero happy-path volume**. Folds into the existing hold-eval tick:

- add `grantPending bool` to `doorMonitor`
- set it in `noteGrant` (covers both credential and command grants)
- clear it in `handleDPS` on an authorized open
- in the loop `reconcileHolds` already runs: if `grantPending && now > grantUntil`,
  emit and clear

**Guard on `Binding.DpsInput != 0`** so a door with no contact never emits — otherwise
it fires on every single grant at those doors.

Grace is 10s and the tick is 10s, so it fires 10–20s after the grant. That sampling
imprecision is irrelevant for "nobody walked through," and it is the same tradeoff
scheduled-posture holds already accept.

## Phase 6 — door state (opt-in, only if asked)

`portals.log_door_state`, default false, control-plane only — same shape as
`allow_remote_unlock`. Mantraps and high-security doors turn it on; the lobby stays
quiet. The same flag should cover `monitor` aux inputs, whose history is equally
invisible today ("when did the freezer door open" is currently unanswerable).

Two things to decide **at that time**, not now:

- How to disambiguate `(door, state)` between posture and door-position. A body
  discriminator is cheapest; a new `kind` filters more cleanly in the UI but costs a
  migration.
- `events` retention. `eventRetentionDays` defaults to **keep forever**, which is fine
  for everything in Phases 0–5 and becomes a real footgun the day this ships.

This is also the prerequisite for anti-passback, if that ever comes up.

## Not building

Named explicitly so they don't creep back in:

- **A rules engine** (severity × time × location × group). The classic PACS trap, and
  the opposite of the pure-function discipline the rest of the codebase holds.
- **An email template engine.** Superseded by Phase 3. See the decision above.
- **HTML email.** Plain text is correct for pager mail.
- **Notification schedules** ("page me only outside business hours"). Real request,
  but it needs a KV snapshot like `policysnapshot` to evaluate a schedule from
  accessd, so it isn't free. Wait until asked.
- **Merging the three record planes.** Config edits stay in `audit_logs`.
- **Anti-passback, duress codes.** Real PACS features, out of scope.

## Sizing

| phase | new packages | migrations | new timers | rough size |
|---|---|---|---|---|
| 0 — stop lying | — | — | — | ~15 lines |
| 1 — misfiled planes | — | — | — | ~65 lines |
| 2 — notifications | — | 1 (`notify_types`) | 1 (re-page, accessd) | schema + UI |
| 3 — webhook | 1 | 1 (settings) | — | new sink |
| 4 — fire source | −1 (deletes `FAIInput`) | 1 (`point_type`) | — | ~30 lines |
| 5 — `no_entry` | — | — | — | ~15 lines |
| 6 — door state | — | 1 | — | opt-in |

**If you want the smallest thing that makes the system honest: Phase 0 and Phase 1,
then use it for a week before starting Phase 2.**
