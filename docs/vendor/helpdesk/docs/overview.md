---
path: helpdesk/overview
nav_order: 10
---
# Overview — the ideas, and how to use them

Every other document here is a reference: the schema, the wire protocol, the
notification matrix. This one is the map. It explains the handful of ideas the
whole app hangs off, then walks through how each kind of person actually works
in it.

Read this first. Then use [data-model.md](data-model.md) when you need a field
and [protocol.md](protocol.md) when you need a payload.

---

## 1. What this is

`helpdesk` is the service desk the Stone-Age.io **operator** runs — the MSP that
operates the platform and supports the customer organizations on it. It does two
jobs that most tools separate:

- **Reactive support** — something broke, someone tells you, you fix it.
- **Proactive field work** — an installation, a rollout, a survey, a
  maintenance round. Nobody reported it; it was planned.

One app covers both because for an MSP they are the same work with the same
people, the same hours, and the same customer. Splitting them means logging time
in two places and never getting a straight answer about where the month went.

The name is historical. The scope has grown past a help desk, but `helpdesk`
stays as the technical identifier — most visibly the `helpdesk.>` NATS subject
contract, which is signed by the platform operator and can't be renamed on a
whim.

### Where it sits in Stone-Age.io

It is a **sibling app, not a platform feature** — its own binary, its own
database, its own logins, running beside kiosk and access-control and borrowing
their conventions. Four things follow from that, and they explain most of the
design decisions you'll meet later:

**The tenant is different.** On the platform, a tenant is a customer
organization. Here the tenant is the operator: one install per MSP, with
customers as records inside it. Those axes don't nest, which is the reason this
isn't a module bolted onto the platform.

**It holds no control-plane credentials, ever.** Staff here raise tickets and
log hours; they cannot reach into the platform. The only platform credential the
app carries is a NATS user scoped to `helpdesk.>` — enough to receive machine
tickets and publish its own events, and nothing else.

**It joins the platform by `code`, it does not sync.** Locations and things are a
local catalogue that lines up with the platform's by a shared `code`, curated
here and bulk-loaded from an operator-run export. There is no live feed and
there cannot be one: the platform publishes no event stream for them, and the
alternatives all require credentials this app must never hold. The catalogue is
also deliberately a **superset** — an MSP services gear the platform never
onboarded, so `code` is optional.

**Provenance arrives on the subject, not in the payload.** A thing publishes on
`helpdesk.>` inside its own organization's NATS account. The platform's
managed-org export rewrites that subject to carry the organization's **code**,
and the rewrite is signed by the operator's import — so the helpdesk reads the
tenant from the subject and ignores any org identifier in the message body.
That's what makes a self-reported ticket trustworthy.

That token used to be the platform's internal organization id, which meant the
ecosystem had two different names for a tenant depending on which direction you
were looking (ADR 0002 in `platform-docs`). It is now `customers.code` in both
directions — the same handle locations and things already joined on — so a consumer
can line helpdesk events up with platform data without a mapping table only this
database could produce.

---

## 2. The mental model

Eight ideas. Everything else is detail.

### A ticket is the unit of work

Everything attaches to a ticket: comments, attachments, on-site visits, logged
hours, the audit trail. If work happened, a ticket says so. Tickets get a
sequential `number` (the `#42` you say out loud) and never get merged or split.

### Work is reactive or planned

A ticket's `type` is `reactive` or `planned`. This isn't decoration — the app
behaves differently:

- **reactive** — a conversation. Staff can ask the customer a question and the
  portal will prompt them for an answer.
- **planned** — anticipated work. It doesn't nag the customer for replies,
  because its progress is tracked by visits and its project, not by an answer.
  Reports count it separately so you can see build-out versus break-fix.

`planned` covers far more than installs: replacements, decommissions, surveys,
PM rounds, a remote firmware campaign. If you scheduled it, it's planned.

### Recurring work schedules itself

A **maintenance plan** ("this door controller gets serviced every 90 days") sits
under **Maintenance**. It is not a second kind of work — when it comes due it
opens an ordinary `planned` ticket, and everything downstream behaves normally.
Two ways to repeat:

- **From the calendar** — quarterly stays quarterly however late the visit ran.
- **From last completion** — the clock restarts the day the work is resolved.
  The plan waits, showing "awaiting completion", while its ticket is open.

A plan can also open its ticket a few days early, so the work is on the board
before it's late. Generation runs nightly; `./helpdesk maintenance-run` does it
on demand, which is how you catch up after downtime (and how you watch a plan
work without waiting for 3:45am).

Tickets carry a **due date** — the date somebody agreed to. It's a date, not a
timer: nothing escalates off it. The queue can filter on it and the dashboard
counts what's overdue.

### Status is a two-stage ending

`open → in_progress → waiting → resolved → closed`

- `waiting` means *you* are blocked on a third party. It's not the same as
  waiting on the customer, which is a separate flag.
- `resolved` is a **grace window**, not an ending. If the customer replies to a
  resolved ticket, it reopens itself automatically — because a reply means it
  wasn't resolved.
- `closed` is final. Customers can't comment on a closed ticket; the portal
  offers them a new one instead.

A nightly job promotes tickets left `resolved` past the configured window to
`closed`, so nobody has to sweep up.

### The ledger: ticket → visit → time

- A **visit** is a trip to site. Creating one is how a ticket becomes on-site
  work — there's no "needs a visit" checkbox, because a visit existing *is* the
  fact. Lifecycle: `requested → scheduled → completed | canceled`.
- A **time entry** is minutes of labour, optionally attributed to a visit.

The ticket is the canonical ledger. Every hour lives on a ticket even when it
was logged from a visit or a running timer, so "what did this cost" always has
one answer. Each entry is billable unless flagged `non_billable` — billability
belongs to the *labour*, not the ticket, because one ticket routinely mixes
billable work with rework or goodwill.

**No money anywhere.** Minutes only. Rates and invoices live in accounting, on
purpose.

### Five axes to slice by

Every ticket can name:

| Axis | Answers |
|---|---|
| **customer** | whose work is this |
| **location** | where is it |
| **thing** | what is it on |
| **category** | what is it about |
| **project** | what larger effort is it part of |

Location and thing are real records, not free text — that's what makes
"everything that ever happened to this door reader" and "which things burn the
most hours" answerable at all. Both keep a free-text fallback for gear that
isn't in the catalogue yet.

`category` and `type` look alike and are not. Category is a label you can add to
whenever you like. Type changes how the app behaves, so it's a fixed pair. The
rule, if you're extending: **enums for what the code branches on, collections
for what only humans read.**

### A code is the same name everywhere

Locations and things carry an optional `code` (`DOOR-1`, `AP-HS-GYM`). It is the
one name the whole ecosystem agrees on: a machine intake resolves it, the
platform knows the same record by it, and — printed as a QR label from the
record's detail view — it is what a tech scans in the hallway to land on that
record's history.

The label payload is the **bare code**: no web address, no customer, no
"thing-or-location" marker. That is a security property, not a shortcut. A sticker
on a wall is something a stranger can replace, and a payload containing a URL
would let a forged sticker send a person to arbitrary content. A bare in-system
identifier means the worst a forged label achieves is opening the wrong record
inside an app you were already signed in to — which is also why scanning happens
**inside the app** (`/staff/scan`) and never through a plain camera.

Two consequences you'll see in the UI. Codes are resolved **globally, then
disambiguated** — staff have no customer of their own, and `DOOR-1` is the code
every customer independently invents, so a match list with a picker is the
honest answer where a silent guess would be a different tenant's door. And every
label prints its code in readable text next to the symbol, because the sticker
will eventually be scratched, greasy, or in a closet too dark to focus in;
typing the code into the scanner is a first-class path, not a fallback.

A record with no code gets no label button. The payload *is* the code.

### Work arrives five ways

| Source | How |
|---|---|
| `portal` | the customer files it |
| `agent` | staff raise it |
| `email` | the customer emails; a parsing provider posts it in |
| `nats` / `webhook` | a machine reports itself |
| `maintenance` | a schedule comes due and opens it (see below) |

The machine paths are the signature feature: a thing on the Stone-Age.io
platform can open its own ticket, and the customer it belongs to is derived from
the **message subject**, which is operator-signed and therefore unforgeable.

Replies work too — answer a notification email and it lands as a public comment
on the right ticket, matched by the `[#42]` token in the subject. A reply from
someone outside that ticket's customer is held as an internal note for staff
instead, since anyone can type `[#42]`.

---

## 3. Who does what

### Requesters — the customer portal (`/portal`)

Customers see **only their own company's** tickets, and never internal notes or
technician names. That last one is deliberate: the MSP's roster is not the
customer's business.

They can: file a ticket (naming the location and thing if they know them), follow
the conversation, see what's scheduled, and read a service summary. Hours appear
only if you've opted that customer in.

They also get both catalog axes as browsable surfaces — **Locations** and
**Things**, each with a read-only detail view. A location shows what's installed
there, who's coming out, and its recent tickets; a thing answers "is this one a
repeat offender" with open/total counts and its own history. Both show the
record's type-defined `metadata` in full — serial, firmware, square footage are
facts about their own property — and withhold what is ours rather than theirs:
the access notes our technicians write for each other, our service notes on a
thing, and — as everywhere in the portal — the name of whoever is coming.

Their filters live in the URL too (tickets, visits, projects, things and the
summary), so a filtered list or a quarter's summary is a link they can send.

### Agents — the staff desk (`/staff`)

The working day:

1. **Dashboard** — where `/staff` lands you: counts by status and the urgent
   and unassigned piles across the top, your own active tickets in the main
   column, and a rail beside them with how much of the backlog is going stale,
   what's due, and inflow over the last eight weeks. Every tile, age and due
   count is a link into the queue that produced it, so it's a set of doors
   rather than a scoreboard.
2. **Queue** — filter by status, priority, assignee, customer, category,
   location, thing, type, due date, and backlog age. Save the filters you use
   daily as views. Filters live in the URL on the queue, Reports and Dispatch,
   so a filtered board is a link you can send someone — and opening a ticket
   and pressing Back returns you to the filters you had, not a reset list.
3. **Triage** — set category, type, project, and an effort estimate. If a change
   shouldn't email anyone, the UI can send it quietly.
4. **Work it** — comment publicly (tick *Request a reply* when you genuinely
   need the customer, which is what drives their prompt) or leave an internal
   note nobody outside sees.
5. **Log time** — type the minutes, or run the start/stop timer and let it
   round.
6. **Dispatch** — schedule a visit from the ticket or the Dispatch board. A
   scheduled visit must have both a time and a technician; that's the one rule
   the server enforces.

### Field techs — the mobile shell

Techs get a different shell on the same login (the `field` role steers the UI;
it is *not* a permission boundary — field techs are still staff). Same
`/staff/*` URLs, different chrome, so every link keeps working.

The core loop is today's visits, then per visit: **Arrive → timer runs →
Complete**. Completing stamps the visit and can close out the timer into a time
entry in one action.

The phone bar is `Today · Schedule · Tickets · Time · More`. Five thumb targets
is the most a phone takes and there are more destinations than that, so the
fifth slot is a door rather than a place: **More** holds Scan, Locations and
Things under "Look up", and Projects and Maintenance under "Work" (read
*between* jobs rather than during one). On a desktop the sidebar lists all of
it flat.

Locations and Things offer a **My scheduled locations** toggle that narrows the roster
to the customers this tech has scheduled visits at. It only appears if they have
any — a dispatcher or admin never meets a control that would filter their roster
to nothing.

### Admins — setting up a new install

Order matters, because each step is the previous one's vocabulary:

1. **Customers** first — everything hangs off them. Give a customer its `code`
   here if it exists on the platform: that one field is what the NATS subject
   carries in both directions, so machine intake and outbound events both stay
   dark without it (an event for a code-less customer is skipped, with the
   reason on the send-log row).
2. **Location types** and **thing types**, then **locations** and **things**.
   Types are per-customer; give them a `code` matching the platform if the
   customer is on it. Codes are also what QR labels carry, so a record you
   intend to put a sticker on needs one.
3. **Requesters** — portal logins, each tied to one customer.
4. **Categories** — start from the seeded set and prune.
5. **Notification templates** — check who gets what before real mail goes out.
6. **Intake**, if wanted: reveal a customer's webhook token, or set their email
   domain. NATS intake needs nothing beyond the `code` from step 1 —
   `platform_org_id` is no longer the routing key, it only records that this
   customer *is* a platform organization.
7. **Branding**, if wanted: point `branding.dir` at a directory holding a logo,
   a theme, and an app name, and the install wears the operator's identity
   without a rebuild. Nothing in the app hardcodes an operator — that's the
   point, and it's why nothing in these docs names one either.

Also per customer: `show_time_to_requester` decides whether their portal shows
hours. Off by default — exposing hours is a billing-model choice and awkward to
walk back.

---

## 4. Try it in five minutes

```bash
go build ./cmd/helpdesk && ./helpdesk seed-demo --confirm --tickets 60
```

That fills a throwaway instance with eight customers, a staff roster, locations and
things with real type schemas, and a backdated history of tickets, comments,
visits and logged hours. It's idempotent — re-run it as often as you like.

```bash
./helpdesk serve
```

Every demo login uses the password `demo12345`:

| Who | Login | See |
|---|---|---|
| Admin | `maya@msp.example` | everything, including admin screens |
| Agent | `diego@msp.example` | the desk: queue, dispatch, reports |
| Field tech | `sam@msp.example` | the mobile visit shell |
| Requester | `regina.holt@northwind.example` | the portal (Northwind has hours on) |

A good first lap, as Maya:

1. **Dashboard** — the landing screen. Click *Over 7 days* under Backlog age
   and land in the queue filtered to exactly those tickets; the count and the
   queue agree because both cut the backlog at the same boundary.
2. **Reports** → *Thing type* — which classes of thing cost the most hours.
3. **Reports** → *Customer*, then flip to *Staff* — the totals above stay put;
   they're the denominator each table is read against.
4. Open a ticket with a location and a thing, and follow its links out into the
   filtered history for each.
5. **Dispatch** — the needs-scheduling bucket, and the day-grouped board.
6. **Maintenance** — five seeded plans, one paused. Two are due, so quit the
   server and run `./helpdesk maintenance-run`; it opens a `planned` ticket for
   each and steps both plans forward. Run it again and nothing happens — an
   occurrence can only generate once. Now open *Clinic HVAC filter change*: it
   repeats from last completion but isn't due for nine days, so **Edit** its
   next due to today and run the command once more. The roster now reads
   "awaiting completion" and the plan's page names the open ticket. Resolve
   that ticket and the plan's next date lands 60 days out.
   Back on the **Dashboard**, the *Due* card counts what you just made, and each
   number opens the queue filtered to exactly those tickets.
7. **Things** → open one with a code → **Label**. Switch between 2″ × 1″ and
   4″ × 2″ and tick *RFID stock* to reveal the inlay keep-out the artwork
   straddles. Then **Scan** → type that code in the manual field: one match goes
   straight to the record. The demo codes are all distinct, so to see the
   picker, give a thing at another customer that same code and scan again.
8. Sign in as Sam and the shell changes shape: today's visits, and **More** →
   Locations / Things with the *My scheduled locations* toggle narrowing to just Sam's
   customers.
9. Sign in as Regina and compare: same tickets, no internal notes, no
   technician names, and a service summary with billable hours because
   Northwind is opted in. Sign in as `anita.rao@harborview.example` and the
   hours are simply absent — Harborview isn't.

---

## 5. Deliberately not built

Worth knowing so you don't go looking: no SLA timers or escalation (a ticket's
`due_at` is a date somebody agreed to, with no clock behind it), no knowledge
base, no canned responses, no CSAT, no ticket merge or split, no calendar sync,
no money anywhere, and no live sync of locations and things from the platform —
that last one closed rather than merely unbuilt, for the reasons in
[Where it sits in Stone-Age.io](#where-it-sits-in-stone-ageio).

---

## Where next

| You want | Read |
|---|---|
| Collections, fields, access rules | [data-model.md](data-model.md) |
| Machine intake and event payloads | [protocol.md](protocol.md) |
| Who gets emailed, and when | [notifications.md](notifications.md) |
| Inbound email setup | [email-ingestion.md](email-ingestion.md) |
| Config files and env vars | [configuration.md](configuration.md) |
| Why things are the way they are | `CLAUDE.md` in the repo root |

`plan.md`, `service-delivery-plan.md` and `nats-notifications-plan.md` are
historical design documents, kept for their reasoning. Each carries a banner
saying where reality has moved past it — don't read them as descriptions of the
app.
