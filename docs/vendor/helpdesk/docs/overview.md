---
path: helpdesk/overview
nav_order: 10
---
# Overview

This page is the map of the helpdesk. It explains the few ideas the whole app
is built on, then shows how each kind of person works in it, and ends with a
five-minute tour on demo data. The other pages are reference: use
[Data Model & Access Rules](data-model.md) when you need a field, and
[Wire Protocol](protocol.md) when you need a payload.

---

## 1. What This Is

`helpdesk` is the service desk that the Stone-Age.io **operator** runs: the MSP
that operates the platform and supports the customer organizations on it. It
does two jobs that most tools keep apart:

- **Reactive support.** Something broke, someone tells you, you fix it.
- **Proactive field work.** An installation, a rollout, a survey, a
  maintenance round. Nobody reported it; it was planned.

One app covers both because, for an MSP, they are the same work, done by the
same people, in the same hours, for the same customer. With two tools you log
time in two places and never get a straight answer about where the month went.

The scope is wider than a help desk, but `helpdesk` stays as the technical
identifier. The most visible place is the `helpdesk.>` NATS subject contract,
which the platform operator signs and which cannot be renamed casually.

### Where it sits in Stone-Age.io

It is a **sibling app, not a platform feature**: its own binary, its own
database and its own logins. It runs beside kiosk and access-control and uses
their conventions. Four things follow from that, and they explain most of the
design you will meet later.

**The tenant is different.** On the platform, a tenant is a customer
organization. Here the tenant is the operator: one install per MSP, with
customers as records inside it. Those axes do not nest, so the helpdesk is not
a platform module.

**It never holds control-plane credentials.** Staff here raise tickets and log
hours; they cannot reach into the platform. The only platform credential the
app carries is a NATS user scoped to `helpdesk.>`. That is enough to receive
machine tickets and publish its own events, and nothing else.

**It joins the platform by `code`; it does not sync.** Locations and things are
a local catalogue that lines up with the platform's by a shared `code`. They are
curated here and bulk-loaded from an operator-run export. There is no live
feed, and there cannot be one: the platform publishes no event stream for them,
and every alternative needs credentials this app must never hold. The catalogue
is also a **superset**. An MSP services gear the platform never onboarded, so
`code` is optional.

**Provenance arrives on the subject, not in the payload.** A thing publishes on
`helpdesk.>` inside its own organization's NATS account. The platform's
managed-org export rewrites that subject to carry the organization's **code**,
and the operator's import signs the rewrite. So the helpdesk reads the tenant
from the subject and ignores any org identifier in the message body. That is
what makes a self-reported ticket trustworthy.

That token is `customers.code` in both directions, the same handle that
locations and things join on (ADR 0002 in `platform-docs`). A consumer can line
helpdesk events up with platform data with no mapping table that only this
database could produce.

---

## 2. The Mental Model

Eight ideas. Everything else is detail.

### A ticket is the unit of work

Everything attaches to a ticket: comments, attachments, on-site visits, logged
hours and the audit trail. If work happened, a ticket says so. Tickets get a
sequential `number` (the `#42` you say out loud) and are never merged or split.

### Work is reactive or planned

A ticket's `type` is `reactive` or `planned`, and the app behaves differently
for each:

- **reactive** is a conversation. Staff can ask the customer a question, and
  the portal prompts them for an answer.
- **planned** is anticipated work. It does not ask the customer for replies,
  because visits and its project track its progress, not an answer. Reports
  count it separately, so you can see build-out against break-fix.

`planned` covers far more than installs: replacements, decommissions, surveys,
PM rounds, a remote firmware campaign. If you scheduled it, it is planned.

### Recurring work schedules itself

A **maintenance plan** ("this door controller gets serviced every 90 days")
lives under **Maintenance**. It is not a second kind of work. When it comes due,
it opens an ordinary `planned` ticket, and everything downstream behaves
normally. A plan repeats one of two ways:

- **From the calendar.** Quarterly stays quarterly, however late the visit ran.
- **From last completion.** The clock restarts the day the work is resolved.
  The plan waits, showing "awaiting completion", while its ticket is open.

A plan can also open its ticket a few days early, so the work is on the board
before it is late. Generation runs nightly. `./helpdesk maintenance-run` runs it
on demand, which is how you catch up after downtime (and how you watch a plan
work without waiting for 3:45am).

Tickets carry a **due date**: the date somebody agreed to. It is a date, not a
timer, and nothing escalates off it. The queue can filter on it, and the
dashboard counts what is overdue.

### Status is a two-stage ending

`open → in_progress → waiting → resolved → closed`

- `waiting` means *you* are blocked on a third party. Waiting on the customer
  is a separate flag.
- `resolved` is a **grace window**, not an ending. If the customer replies to a
  resolved ticket, it reopens itself, because a reply means it was not
  resolved.
- `closed` is final. Customers cannot comment on a closed ticket; the portal
  offers them a new one instead.

A nightly job promotes tickets left `resolved` past the configured window to
`closed`, so nobody has to sweep up.

### The ledger: ticket → visit → time

- A **visit** is a trip to site. Creating one is how a ticket becomes on-site
  work. There is no "needs a visit" checkbox, because a visit existing *is* the
  fact. Lifecycle: `requested → scheduled → completed | canceled`.
- A **time entry** is minutes of labour, optionally attributed to a visit.

The ticket is the canonical ledger. Every hour lives on a ticket, even when it
was logged from a visit or a running timer, so "what did this cost" always has
one answer. Each entry is billable unless flagged `non_billable`. Billability
belongs to the *labour*, not the ticket, because one ticket often mixes billable
work with rework or goodwill.

**No money anywhere.** Minutes only. Rates and invoices live in accounting.

### Five axes to slice by

Every ticket can name:

| Axis | Answers |
|---|---|
| **customer** | whose work is this |
| **location** | where is it |
| **thing** | what is it on |
| **category** | what is it about |
| **project** | what larger effort is it part of |

Location and thing are real records, not free text. That is what makes
"everything that ever happened to this door reader" and "which things burn the
most hours" answerable. Both keep a free-text fallback for gear that is not in
the catalogue yet.

`category` and `type` look alike and are not. Category is a label you can add
to whenever you like. Type changes how the app behaves, so it is a fixed pair.
The rule if you extend the app: **enums for what the code branches on,
collections for what only humans read.**

### A code is the same name everywhere

Locations and things carry an optional `code` (`DOOR-1`, `AP-HS-GYM`). It is
the one name the whole ecosystem agrees on. A machine intake resolves it, the
platform knows the same record by it, and, printed as a QR label from the
record's detail view, it is what a tech scans in the hallway to open that
record's history.

The label payload is the **bare code**: no web address, no customer, no
"thing-or-location" marker. This is a security property. A stranger can replace
a sticker on a wall, and a payload containing a URL would let a forged sticker
send a person to arbitrary content. With a bare in-system identifier, the worst
a forged label can do is open the wrong record inside an app you were already
signed in to. That is also why scanning happens **inside the app**
(`/staff/scan`) and never through a plain camera.

You will see two consequences in the UI:

- **Codes resolve globally, then disambiguate.** Staff have no customer of their
  own, and `DOOR-1` is a code every customer invents independently. So the app
  shows a match list with a picker, where a silent guess could open a different
  tenant's door.
- **Every label prints its code as readable text** next to the symbol, because
  the sticker will end up scratched, greasy, or in a closet too dark to focus
  in. Typing the code into the scanner is a first-class path, not a fallback.

A record with no code gets no label button. The payload *is* the code.

### Work arrives five ways

| Source | How |
|---|---|
| `portal` | the customer files it |
| `agent` | staff raise it |
| `email` | the customer emails; a parsing provider posts it in |
| `nats` / `webhook` | a machine reports itself |
| `maintenance` | a schedule comes due and opens it (see [Recurring work schedules itself](#recurring-work-schedules-itself)) |

The machine paths are the signature feature. A thing on the Stone-Age.io
platform can open its own ticket, and the customer it belongs to comes from the
**message subject**, which the operator signs and so cannot be forged.

Replies work too. Answer a notification email and it lands as a public comment
on the right ticket, matched by the `[#42]` token in the subject. A reply from
someone outside that ticket's customer is held as an internal note for staff
instead, since anyone can type `[#42]`.

---

## 3. Who Does What

### Requesters: the customer portal (`/portal`)

Customers see **only their own company's** tickets, and never internal notes or
technician names. The MSP's roster is not the customer's business.

They can file a ticket (naming the location and thing if they know them),
follow the conversation, see what is scheduled, and read a service summary.
Hours appear only if you have opted that customer in.

They also get both catalogue axes as pages: **Locations** and **Things**, each
with a read-only detail view. A location shows what is installed there, who is
coming out, and its recent tickets. A thing answers "is this one a repeat
offender" with open and total counts and its own history. Both show the record's
type-defined `metadata` in full, because serial, firmware and square footage are
facts about the customer's own property. Both withhold what is ours: the access
notes our technicians write for each other, our service notes on a thing, and,
as everywhere in the portal, the name of whoever is coming.

Their filters live in the URL too (tickets, visits, projects, things and the
summary), so a filtered list or a quarter's summary is a link they can send.

### Agents: the staff desk (`/staff`)

The working day:

1. **Dashboard.** `/staff` lands here: counts by status, and the urgent and
   unassigned piles, across the top; your own active tickets in the main
   column; and a rail beside them with how much of the backlog is going stale,
   what is due, and inflow over the last eight weeks. Every tile, age and due
   count links to the queue that produced it.
2. **Queue.** Filter by status, priority, assignee, customer, category,
   location, thing, type, due date and backlog age. Save the filters you use
   daily as views. Filters live in the URL on the queue, Reports and Dispatch,
   so a filtered board is a link you can send. Opening a ticket and pressing
   Back returns you to the filters you had, not a reset list.
3. **Triage.** Set category, type, project and an effort estimate. If a change
   should not email anyone, the UI can send it quietly.
4. **Work it.** Comment publicly, or leave an internal note nobody outside
   sees. Tick *Request a reply* when you need the customer; that is what drives
   their prompt.
5. **Log time.** Type the minutes, or run the start/stop timer and let it
   round.
6. **Dispatch.** Schedule a visit from the ticket or the Dispatch board. A
   scheduled visit must have both a time and a technician. That is the one rule
   the server enforces.

### Field techs: the mobile shell

Techs get a different shell on the same login. The `field` role steers the UI;
it is *not* a permission boundary, and field techs are still staff. The
`/staff/*` URLs are the same with different chrome, so every link keeps working.

The core loop is today's visits, then, per visit: **Arrive → timer runs →
Complete**. Completing stamps the visit and can close out the timer into a time
entry in one action.

The phone bar is `Today · Schedule · Tickets · Time · More`. A phone takes at
most five thumb targets and there are more destinations than that, so the fifth
slot opens a menu. **More** holds Scan, Locations and Things under "Look up",
and Projects and Maintenance under "Work" (read *between* jobs, not during one).
On a desktop the sidebar lists everything flat.

Locations and Things offer a **My scheduled locations** toggle that narrows the
roster to the customers this tech has scheduled visits at. It appears only if
they have any, so a dispatcher or admin never sees a control that would filter
their roster to nothing.

### Admins: setting up a new install

Order matters, because each step supplies the vocabulary for the next:

1. **Customers** first; everything hangs off them. Give a customer its `code`
   here if it exists on the platform. The NATS subject carries that one field
   in both directions, so machine intake and outbound events both stay dark
   without it. An event for a customer with no code is skipped, with the reason
   on the send-log row.
2. **Location types** and **thing types**, then **locations** and **things**.
   Types are per customer. Give them a `code` matching the platform if the
   customer is on it. QR labels also carry codes, so a record you intend to put
   a sticker on needs one.
3. **Requesters**: portal logins, each tied to one customer.
4. **Categories**: start from the seeded set and prune.
5. **Notification templates**: check who gets what before real mail goes out.
6. **Intake**, if wanted: reveal a customer's webhook token, or set their email
   domain. NATS intake needs nothing beyond the `code` from step 1.
   `platform_org_id` is not the routing key; it only records that this customer
   *is* a platform organization.
7. **Branding**, if wanted: point `branding.dir` at a directory holding a logo,
   a theme and an app name, and the install shows the operator's identity with
   no rebuild. Nothing in the app hardcodes an operator, which is why nothing in
   these docs names one either.

Also per customer: `show_time_to_requester` decides whether their portal shows
hours. It is off by default, because exposing hours is a billing-model choice
and awkward to walk back.

---

## 4. Try It in Five Minutes

```bash
go build ./cmd/helpdesk && ./helpdesk seed-demo --confirm --tickets 60
```

That fills a throwaway instance with eight customers, a staff roster, locations
and things with real type schemas, and a backdated history of tickets,
comments, visits and logged hours. It is idempotent, so re-run it as often as
you like.

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

1. **Dashboard**, the landing screen. Click *Over 7 days* under Backlog age to
   open the queue filtered to exactly those tickets. The count and the queue
   agree, because both cut the backlog at the same boundary.
2. **Reports** → *Thing type*: which classes of thing cost the most hours.
3. **Reports** → *Customer*, then flip to *Staff*. The totals above stay put;
   they are the denominator each table is read against.
4. Open a ticket with a location and a thing, and follow its links out to the
   filtered history for each.
5. **Dispatch**: the needs-scheduling bucket and the day-grouped board.
6. **Maintenance**: five seeded plans, one paused. Two are due, so quit the
   server and run `./helpdesk maintenance-run`. It opens a `planned` ticket for
   each and steps both plans forward. Run it again and nothing happens: an
   occurrence can generate only once. Now open *Clinic HVAC filter change*. It
   repeats from last completion but is not due for nine days, so **Edit** its
   next due date to today and run the command once more. The roster now reads
   "awaiting completion", and the plan's page names the open ticket. Resolve
   that ticket and the plan's next date lands 60 days out.
   Back on the **Dashboard**, the *Due* card counts what you just made, and each
   number opens the queue filtered to exactly those tickets.
7. **Things** → open one with a code → **Label**. Switch between 2″ × 1″ and
   4″ × 2″, and tick *RFID stock* to reveal the inlay keep-out the artwork
   straddles. Then **Scan** → type that code in the manual field: one match goes
   straight to the record. The demo codes are all distinct, so to see the
   picker, give a thing at another customer the same code and scan again.
8. Sign in as Sam and the shell changes shape: today's visits, and **More** →
   Locations / Things with the *My scheduled locations* toggle narrowing to
   Sam's customers.
9. Sign in as Regina and compare: the same tickets, no internal notes, no
   technician names, and a service summary with billable hours because
   Northwind is opted in. Sign in as `anita.rao@harborview.example` and the
   hours are absent, because Harborview is not.

---

## 5. What Is Not Built

So you do not go looking:

- No SLA timers or escalation. A ticket's `due_at` is a date somebody agreed
  to, with no clock behind it.
- No knowledge base, canned responses or CSAT.
- No ticket merge or split.
- No calendar sync.
- No money anywhere.
- No live sync of locations and things from the platform. This one is ruled
  out, not just unbuilt, for the reasons in
  [Where it sits in Stone-Age.io](#where-it-sits-in-stone-ageio).

---

## 6. Where to Go Next

- Collections, fields and access rules: [Data Model & Access Rules](data-model.md)
- Machine intake and event payloads: [Wire Protocol](protocol.md)
- Who gets emailed, and when: [Notifications](notifications.md)
- Inbound email setup: [Email Ingestion](email-ingestion.md)
- Config files and env vars: [Configuration Reference](configuration.md)
- Build, run and the design records: [Helpdesk](../README.md)
- Why things are the way they are: `CLAUDE.md` in the repo root
