---
path: platform/automation
nav_order: 150
---
# Automation

The **rule engine** is Layer 1 of Stone-Age.io: declarative event logic on top
of NATS, with no state between messages.

This page covers how the engine fits the platform, the patterns that use NATS
KV for state, the patterns that combine the engine with the platform's other
parts, and when to use something else. How the engine itself works (rule
syntax, variables, functions, `forEach`, payload modes, the gateway, the
scheduler, throttle) is in the
[rule-router documentation](./vendor/rule-router/README.md), for the version in
[Operations §6.1](./operations.md#61-the-versions-these-docs-describe). See
[Platform Layers](./platform-layers.md) for the layer model.

---

## 1. The Rule Engine in This Platform

The rule engine (`rule-router`) is a **separate binary**, not part of the
Control Plane. It connects to NATS as a client with a user credential from the
tenant's account, so it sees exactly what that user's NATS role allows. Run
it:

- **centrally**, beside your main NATS cluster, which is the usual case;
- **at the edge**, beside a site's leaf node, so local rules keep running
  during a WAN outage;
- **or both**: central rules for cross-site alerts, edge rules for site-local
  reactions.

One binary has three features, which share the YAML rule syntax and the KV
buckets:

| Feature | Trigger | Actions |
|---|---|---|
| **Router** (default) | A NATS subject | Publish to NATS, or call HTTP |
| **Gateway** | An HTTP request, or a NATS subject for outbound calls | Publish to NATS, or call HTTP with retry |
| **Scheduler** | A cron expression | Publish to NATS, or call HTTP with retry |

Each rule is a **trigger, conditions and one action**. The engine keeps no
state between messages: durable state is in NATS KV (§2), and the only thing it
holds in memory is throttle windows.

**A NATS trigger is a JetStream consumer by default, so a stream must already
cover its subject**, or the engine rejects the rule at load ("no stream found
for trigger subject"). Actions publish to JetStream and wait for an ack by
default too. For subjects you do not stream, such as heartbeats or high-rate
telemetry, set `mode: core` on the trigger or the action. Creating streams:
[The Console §4](./console.md#4-jetstream-streams-and-kv-buckets).

**Put signature verification on every gateway endpoint the internet can
reach.** Without it, anyone who learns the path can publish into your bus. See
[Verifying webhook signatures](./vendor/rule-router/docs/02-gateway.md#verifying-webhook-signatures-hmac).

---

## 2. Stateful Patterns via KV

The engine keeps no state between messages, but rules can read and write NATS
KV. This gives you stateful behavior with no separate state store.

### Stateful Alarms (KV Stacking)

A sensor that flickers around a threshold can send 100 alerts. To prevent this,
keep the alarm state in a KV bucket:

1. **Threshold hit:** a rule fires on the reading only if no alarm is active:
   an `or` group of `{@kv.alarms.device_01.high_temp}` with `not_exists` (no
   alarm yet) and `{@kv.alarms.device_01.high_temp:state}` `eq` `cleared`.
   Only `not_exists` matches a missing key. `neq` `active` is `false` on a
   missing key, so it would never raise the first alarm.
2. **Write state:** the rule's action writes the alarm state. A write is a
   normal publish to the bucket's subject, `$KV.alarms.device_01.high_temp`,
   with the value as the body.
3. **Notify:** a rule has one action, so a second rule sends the notification.
   It triggers on the write (`$KV.alarms.>`) or on the same threshold
   condition.
4. **Deduplication:** once the key holds an active alarm, neither condition
   passes. The administrator was already notified, and the rules do nothing.
5. **Auto-clear:** when the temperature is normal again, another rule
   overwrites the key with a cleared state. A recovery notification can trigger
   on that write in the same way.

**The rules keep no state. The KV bucket holds it.**

### Other KV-Backed Patterns

- **Presence tracking with a TTL.** Each relevant event refreshes a KV key with a
  short TTL. When the key expires, that is the "gone" event. Use it for
  occupancy or heartbeat monitoring.
- **Deduplication.** A KV key per event ID stops duplicates across restarts or
  replays.

### Detecting silence

A rule runs when a message arrives, so on its own it cannot notice that
messages have *stopped*. A TTL key catches a sender that goes quiet, but not one
that never reports at all, because a key that was never written never expires.

For liveness across a fleet, run the [Watchdog](./vendor/services/docs/watchdog.md).
It is a small service in the tenant's account that watches the subjects you
name in a KV bucket, and writes each target's `pending`, `up` or `down` state
to another KV bucket. A rule on `$KV.watchdog_state.>` then sends the
notification, the same way the alarm pattern above triggers on `$KV.alarms.>`.
§3 builds escalation, silences and inactivity timers on top of it.

### Throttle and debounce are built in

Rate limiting and debounce use a rule's `throttle` block, not KV. Put it on
the **action**, not the trigger, so a normal reading cannot use up the window
before an alarming one arrives. Its windows live in each instance's memory and
reset on restart; if suppression must survive a restart, gate the rule on a KV
key with a TTL instead. See
[Throttle](./vendor/rule-router/docs/01-core-concepts.md#4-throttle).

---

## 3. Patterns Built From Existing Parts

Some needs look like they call for a new service, but the parts you already run
cover them. Each pattern below combines the rule engine with one other part:
the [Watchdog](./vendor/services/docs/watchdog.md), the
[Helpdesk](./vendor/helpdesk/README.md), a KV bucket, or NATS message
scheduling. Reach for a new service only when none of them fits.

| Need | Built from |
| :--- | :--- |
| Escalation and acknowledgement | Watchdog or alarm → rule → Helpdesk ticket |
| Silencing alerts during maintenance | A KV key per check, with a TTL, read by the alert rule |
| "Do this after N minutes of inactivity" | A Watchdog check, plus a rule on its state |
| "Do this at a time the message names" | NATS message scheduling, set by a rule |

### Escalation and Acknowledgement

A notification is easy to miss. A **ticket** has an owner, a status and a
history, and stays open until someone resolves it. The Helpdesk already takes
machine-generated tickets over NATS, so a rule can turn a Watchdog `down`, or
any alarm, into one:

```yaml
- trigger:
    nats:
      subject: "$KV.watchdog_state.>"
  conditions:
    operator: and
    items:
      - field: "{state}"
        operator: eq
        value: "down"
  action:
    nats:
      subject: "helpdesk.tickets.create"
      mode: core
      payload: |
        {
          "title": "{target} stopped reporting ({check})",
          "body": "Down since {since}. Last message: {last_seen}.",
          "priority": "high",
          "dedupe_key": "watchdog-{check}-{target}",
          "thing": "{target}"
        }
```

- **`dedupe_key` stops ticket storms.** While a ticket with the same key is
  open, a repeat only increases that ticket's repeat count. Once the ticket is
  resolved, the next `down` opens a new one. A flapping target is one ticket,
  and a failure that returns after the fix is a new ticket.
- **`mode: core` is required.** The stream that stores tickets is in the
  operator's hub account, reached through the platform's export and import. No
  stream in the tenant's account covers the subject, so a JetStream action
  would wait for an ack that never comes and log an ack timeout on every fire.
- **The ticket does not close itself.** Helpdesk takes only the `create` verb
  today, so a target that comes back `up` does not resolve its ticket. Whoever
  works the ticket resolves it. A second rule can still send an `up`
  notification.
- **`thing` is free text. `thing_code` links the ticket to inventory.** The
  Helpdesk stores `thing` as a note and resolves nothing from it. If your
  targets are Thing codes, also add `"thing_code": "{target}"`, and the ticket
  is joined to the Thing for reporting. See the Helpdesk [wire protocol](./vendor/helpdesk/docs/protocol.md#2-nats-ticket-events).

Escalation then happens where people work: the ticket's priority, assignee and
the Helpdesk's own notifications. The rule's only job is to open it once.

### Silencing Alerts During Maintenance

Planned work makes devices go quiet on purpose. Put a key in a `silences`
bucket for each check being worked on, and have the alert rule skip any check
that has one:

```bash
# Once: a bucket that allows a TTL on each key
nats kv add silences
nats kv edit silences --marker-ttl 1m

# Silence the "gateways" check for two hours
nats kv create silences gateways '{"reason": "firmware upgrade, ticket #42"}' --ttl 2h
```

```yaml
  conditions:
    operator: and
    items:
      - field: "{state}"
        operator: eq
        value: "down"
      - field: "{@kv.silences.{check}}"
        operator: not_exists
```

- **The silence ends by itself.** The key's TTL removes it, so nobody has to
  remember to turn alerts back on. To end it early, `nats kv del silences gateways`.
- **The TTL is fixed when the key is created.** `put` and `update` remove it, so
  to extend a silence, delete the key and create it again.
- **Only alerts are silenced, not detection.** The Watchdog still records every
  state change while the silence is on, so the state is correct the moment it
  ends.
- **The value says why,** so the next person who looks knows. The rule only
  checks that the key exists.

### Inactivity Timers

"Turn the lights off after 10 minutes with no motion" is the Watchdog's job
under another name: a target that stops sending messages. Point a check at the
motion subject, and turn the `down` state into a command:

```bash
nats kv put watchdog_checks rooms '{
  "subject": "room.*.motion",
  "target_token": 1,
  "timeout": "10m"
}'
```

```yaml
- trigger:
    nats:
      subject: "$KV.watchdog_state.rooms.*"
  conditions:
    operator: and
    items:
      - field: "{state}"
        operator: eq
        value: "down"
  action:
    nats:
      subject: "room.{target}.lights"
      mode: core
      payload: '{"on": false}'
```

- **The action uses `mode: core`**, because a command subject usually has no
  stream. A JetStream publish to it waits for an ack that never arrives.
- **Turn the lights on from the motion itself,** with an ordinary rule on
  `room.*.motion`. The Watchdog only marks the room `up` on the next
  evaluation, and only writes when the state changes.
- **The timer is coarse.** A room goes `down` up to one evaluation interval
  (10s by default) after the timeout. The shortest timeout is three evaluation
  intervals, 30s by default. For a door held open for 15 seconds, use
  something that runs at the door, such as the Access Control controller.
- **A room is learned from its first motion.** A room that never reports isn't
  tracked unless it's listed in `expected`.

### Actions at a Time the Message Names

Sometimes the time to act is in the message: a booking ends at 17:00, a
temporary credential expires at midnight. NATS message scheduling (nats-server
2.12 and later) holds a message in a stream and publishes it at that time. A
rule sets the schedule with two headers:

```yaml
- trigger:
    nats:
      subject: "bookings.*.created"
  action:
    nats:
      subject: "schedules.booking.{@subject.1}"
      headers:
        Nats-Schedule: "@at {ends_at}"
        Nats-Schedule-Target: "bookings.{@subject.1}.ended"
      payload: '{"booking": "{@subject.1}"}'
```

At `ends_at`, the stream publishes the payload to `bookings.{id}.ended`, where
another rule acts on it.

- **The stream needs scheduling turned on.** Create a stream with
  `allow_msg_schedules: true` whose subjects cover both the schedule subjects
  (`schedules.>`) and the targets (`bookings.*.ended`). Scheduling can't be
  turned off on a stream once it's on.
- **Each schedule has its own subject.** Publishing again to the same schedule
  subject replaces the earlier schedule, which is how a rule extends a booking.
- **To cancel,** publish any message to another subject in the stream with the
  headers `Nats-Schedule-Next: purge` and `Nats-Scheduler: schedules.booking.{id}`.
  The schedule is removed only if that publish succeeds.
- **The time must be in the message, in RFC 3339.** Templates have no arithmetic,
  so a rule can't compute "now plus 10 minutes". For a delay relative to the
  last message, use an [inactivity timer](#inactivity-timers). For a fixed time
  of day, use the [scheduler](./vendor/rule-router/docs/03-scheduler.md). Otherwise,
  have the publisher put the time in the payload.
- **A time in the past fires immediately,** for example after a long outage.

---

## 4. Rule-Writing Best Practices

- **Use specific subjects.** Do not trigger on `>`. Use narrow subjects such as
  `telemetry.*.temp`.
- **Keep JSON flat.** The engine reads nested fields (`{user.profile.email}`),
  but flat structures are easier to read and faster to evaluate.
- **Use KV for context.** Do not repeat static data such as "unit location" in
  every message. Store it in KV and add it with a `{@kv.lookup}`.
- **Keep state in KV, not in rules.** If a rule must remember something across
  messages, use a KV key. The one built-in exception is `throttle`.
- **Name subjects consistently.** Rules, stream processors and Telegraf all use
  the same subjects. Choose a hierarchy and keep it.

---

## 5. When to Use Something Else

Anything with a **time window**, a **join** of two streams, **retractable**
results, **SQL** over streams or **complex event processing** belongs in a
stream processor that runs beside your rules on the same bus. Logic specific to
your domain (a physics model, ML inference, your own libraries) belongs in a
small service that reads from and publishes to NATS. The
[services repository](./vendor/services/README.md) holds the ones useful to
every tenant, such as the Watchdog. [Stream Processing](./stream-processing.md)
covers both and says when each fits.

