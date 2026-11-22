---
path: platform/decisions/0008-application-namespace
nav_order: 80
---
# ADR 0008: One Namespace, Event Shape and Identity for Applications

**Status:** Accepted — partly implemented. The helpdesk and access control follow its subjects and event shape; kiosk does not yet. The helpdesk (`nats.code`), accessd (`accessd.code`) and each access controller (`controller.code`) register their Thing codes. See [What changes in each application](#what-changes-in-each-application).
**Date:** 2026-11-21

> This ADR is ecosystem-scoped, like [ADR 0002](./0002-organization-code-namespace.md). It decides how the applications built on the platform (helpdesk, access control, kiosk and the services) name their subjects, shape their events, connect, and refer to inventory. It changes nothing in the platform itself.
>
> It builds on ADR 0002 (ids for storage, codes for addressing), [ADR 0003](./0003-human-friendly-codes-and-default-subject.md) rule 6 (token 0 is the kind, token 1 is the code) and [ADR 0007](../vendor/services/docs/decisions/0007-creds-keeper.md) (a companion program keeps a Thing's creds file current). It does not revisit them.
>
> Numbers 0005 to 0007 belong to the services repository, so this is 0008.

---

## Context

Four applications now run on the platform, and none is in production. They
follow the platform's conventions in outline and differ in the details:

| | Shape | Event token | Request | Liveness | Time field |
|---|---|---|---|---|---|
| Agent | `agents.{code}.{channel}.…` | `telemetry` | `agents.{code}.cmd.health` | `agents.{code}.heartbeat` | `ts` |
| kiosk | `kiosk.{code}.event.{domain}.{verb}` | `event` | none | `kiosk.{code}.heartbeat` | `occurred_at` |
| access control | `acc.{location}.{type}.{thing}.evt.{kind}`, and `acc.{location}.evt.fire` | `evt` | `acc.{location}.ctrl.{code}.health` | `acc.{location}.ctrl.{code}.heartbeat` | `ts` |
| helpdesk | `helpdesk.tickets.create`, at the hub `helpdesk.{org}.tickets.create`; out `helpdesk.{org}.events.{type}` | `events` | none | none | `occurred_at` |

**The disjointness token never got an owner.** ADR 0002 found that an app's
inbound and outbound streams must differ at one token, and said the rule
"needs an owner before a third app picks a token". Two more apps picked one
since then, each a different word: `evt`, `event`, `events`, `tickets`.

**A scope of uneven length costs a filter.** Access control's fire alarm has a
one-token scope and every other event has three, so its events stream needs
two filters of different arity.

**Only the helpdesk sets `Nats-Msg-Id`.** The other streams keep every
duplicate a producer sends, and two of the four apps name the time field
something other than the `ts` that [Message Design](../concepts/message-design.md)
asks for.

**No application process is a platform Thing.** Each one reads a creds file
that an operator copied by hand, so Regenerate, Revoke and deactivation in the
console don't reach it, and the console's Services page can't connect a
running process to inventory. ADR 0007 solved this for services with
creds-keeper. The applications haven't adopted it.

**Inventory is typed twice.** The helpdesk keeps its own `things`, `locations`
and type collections, access control its own `locations`, and kiosk a `kiosks`
collection with a `location_code`. They join to the platform by code.

Nothing is in production. Every change below is a rename in a demo, a test and
a protocol document. This is the cheapest it will ever be.

---

## Decision

Five rules.

### 1. One subject grammar

```
{app}.{scope}.{channel}.{rest}         inside a tenant account (relative)
{app}.{org}.{scope}.{channel}.{rest}   at the hub, after a managed-org import
```

- **`{app}`** is the literal application token, as ADR 0002 and
  [Message Design §2](../concepts/message-design.md#2-identity-in-the-subject-facts-in-the-payload)
  already require.
- **`{scope}` is a fixed number of tokens for each application, and each one
  is a code.** It is the instance's Thing code for kiosk and the Agent, and
  the location code for access control, because a door controller's
  permissions are scoped to a site. Each is one token. The portal type and
  code come after the channel, in `{rest}`.
  The helpdesk has no scope inside a tenant account, and at the hub the
  organization code is its scope. An application states its count once, in
  its protocol document.
- **`{channel}`** is the kind of message, from the list in rule 2.
- **`{rest}`** belongs to the application, as ADR 0003 rule 6 says of
  everything after the code.

Fixing the length of the scope is what lets one filter capture a whole
channel. A location in the scope is still allowed for fixed equipment and for
site-scoped permissions, as ADR 0003 decided.

### 2. A short, fixed list of channels

| Channel | Kind of message ([Message Design §1](../concepts/message-design.md#1-choose-the-kind-of-message-first)) | Transport | Stored |
|---|---|---|---|
| `evt` | Event: something happened | Publish | Yes, in the application's stream |
| `cmd` | Command or request | Core publish, or request and reply | No |
| `heartbeat` | Liveness | Core publish | Never |
| `telemetry` | Measurement | Publish | Yes |

- **An application may add a channel of its own** for raw input, such as
  access control's `tap`, if no stream filter captures it.
- **ADR 0002's disjointness rule follows from the channel.** A stream captures
  `{app}.{*…}.evt.>`, with one `*` per scope token, and an intake stream
  captures `cmd`. Two channels never overlap, so no application chooses a
  disjointness token again. This ADR is that rule's owner.

### 3. One event shape

- **`ts`, an RFC 3339 string in UTC, in every payload.** No `occurred_at`.
- **`Nats-Msg-Id` on every publish to a stream**, set to a stable id the
  producer chooses. A consumer that also removes duplicates itself keeps doing
  so, because the stream's duplicate window is finite.
- **No envelope.** Metadata travels in headers and the facts in the body, so a
  stored event makes sense on its own. A contract name and version in the body
  ([Message Design §5](../concepts/message-design.md#5-version-the-contract))
  stay where an application has them.

### 4. Every application process is a Thing

accessd, each access controller, each kiosk node and the kiosk controller, the
helpdesk, and every service instance get a Thing of their own, with a type
that names the program. Each one:

- **gets its creds file from the platform through creds-keeper**, as
  [ADR 0007](../vendor/services/docs/decisions/0007-creds-keeper.md) decided:
  a companion program, not a platform client built into the application;
- **reconnects after a Revoke**, which in nats.go means
  `IgnoreAuthErrorAbort()` beside `UserCredentials(path)`, so the next
  connect reads the file creds-keeper wrote (ADR 0007 §4);
- **registers a NATS micro service with `metadata.code` set to its Thing's
  code**, which is how the console joins a running service to a Thing.

A creds file copied by hand stays possible for development.

### 5. Inventory is joined by code

The platform remains the owner of Things and Locations. An application that
needs them keeps a copy loaded by an operator's export then seed, joined to
the platform by `(organization, code)`, with its own fields in its own
collections. There is no live sync.

The Control Plane stays an admin-only NATS client, so the platform does not
publish inventory on NATS ([Architecture §2](../architecture.md)).

---

## What changes in each application

| Application | Change |
|---|---|
| **helpdesk** | `helpdesk.tickets.create` → `helpdesk.cmd.tickets.create` (`helpdesk.{org}.cmd.tickets.create` at the hub). `helpdesk.{org}.events.{type}` → `helpdesk.{org}.evt.{type}`. `occurred_at` → `ts`. The managed-org export maps the whole of `helpdesk.>`, so the platform doesn't change. |
| **access control** | The scope becomes the location alone, and the portal type and code move after the channel. Every subject changes: see the table below. The events stream then needs one filter, `acc.*.evt.>`. `Nats-Msg-Id` on every event. |
| **kiosk** | `kiosk.{code}.event.…` → `kiosk.{code}.evt.…`. `occurred_at` → `ts`. `Nats-Msg-Id` on every event. |
| **Agent** | None. It already fits rules 1 to 3. |
| **All of them** | Rule 4: a Thing per process, creds-keeper, reconnect after a Revoke, `metadata.code`. |

Access control's subjects, before and after:

| Message | Today | After |
|---|---|---|
| Card read | `acc.{location}.{type}.{thing}.tap` | `acc.{location}.tap.{type}.{thing}` |
| Posture override | `acc.{location}.{type}.{thing}.cmd.posture` | `acc.{location}.cmd.{type}.{thing}.posture` |
| Door pop | `acc.{location}.{type}.{thing}.cmd.grant` | `acc.{location}.cmd.{type}.{thing}.grant` |
| Aux output | `acc.{location}.auxout.{thing}.cmd.output` | `acc.{location}.cmd.auxout.{thing}.output` |
| Decision, posture change, alarm | `acc.{location}.{type}.{thing}.evt.{tap,state,alarm}` | `acc.{location}.evt.{type}.{thing}.{tap,state,alarm}` |
| Fire alarm | `acc.{location}.evt.fire` | unchanged |
| Controller liveness change | `acc.{location}.ctrl.{code}.evt.state` | `acc.{location}.evt.ctrl.{code}.state` |
| Controller heartbeat | `acc.{location}.ctrl.{code}.heartbeat` | `acc.{location}.heartbeat.ctrl.{code}` |
| Controller health | `acc.{location}.ctrl.{code}.health` | `acc.{location}.cmd.ctrl.{code}.health` |

A reader can still be limited to its own door with a literal subject, such as
`acc.hq.tap.door.lobby-main`, and a site's controller to `acc.hq.>`.

---

## Consequences

### Good

- One filter per channel, in every application. `*.evt.>`-shaped filters are
  the whole list of what any stream stores.
- No application has to work out its own disjointness token.
- Duplicates stop at the stream for every application, not only the helpdesk.
- Regenerate, Revoke and deactivation in the console reach every process in an
  account, and every process shows up on its Thing.
- A reader who knows one application's subjects can read the others'.

### Costs we are accepting

- **Every application renames subjects.** Each one changes its protocol
  document, its demo rules and its tests, once.
- **One more process per application instance**: creds-keeper runs beside it,
  as a sidecar container or a second systemd unit (ADR 0007 §8).
- **Every access control subject changes,** not only the two that differed
  from the others. After the channel, the rest of a subject varies in length
  (`evt.fire` against `evt.door.lobby-main.tap`), so a consumer that parses
  it checks the token count.
- **Inventory is still typed twice.** Rule 5 keeps today's code join.

---

## What would make us revisit this

- **An application needs inventory that is live, not seeded.** The likely
  answer is a purpose-built route for a Thing, as `GET /api/me/leaf-config` is
  for a gateway. That route is an authorization change, so it would need its
  own decision.
- **A fifth kind of message needs a channel** that none of the four describes.
  Add it to rule 2 here, not in one application.
- **Site-scoped permissions turn out to need more than one scope length** in
  one application.

---

## Rejected alternatives

- **A platform client built into each application.** ADR 0007 rejected it for
  services, and the reasons hold here: every application would gain an HTTP
  client, a sync loop and credential swapping, and the platform's credential
  lifecycle would have several implementations.
- **An envelope around every payload** (`{"meta": …, "data": …}`). Every
  consumer would have to unwrap it, rule-router included, and NATS headers
  already carry metadata.
- **The platform publishes inventory changes on NATS.** That makes the
  credential issuer a participant on every tenant's bus, which
  [Architecture §2](../architecture.md) rules out.
- **An application signs in to the platform as a `viewer` member to read
  inventory.** It works without a platform change, but it gives a machine a
  person's login, where the platform's model is that a Thing is the login.
- **A three-token scope for access control, `{location}.{type}.{thing}`.**
  It changes fewer subjects, but the fire alarm belongs to a location and has
  no type or thing, so it would need padding such as
  `acc.hq.site.hq.evt.fire`. A location-only scope says what access control
  actually scopes by.
- **The fire alarm keyed by its aux input** (`acc.{location}.evt.auxin.{code}.fire`).
  The protocol defines fire as a location's state, which every controller at
  that location applies. Keyed by contact, each subscriber would have to
  combine the states of however many fire contacts the location has.
- **Leaving the scope variable and listing filters per application.** It works
  today, and it is how each application ended up with its own token.
