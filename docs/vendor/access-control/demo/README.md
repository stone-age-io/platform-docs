---
path: access-control/demo
nav_order: 50
---
# Demo data

> **Start with `accessd demo-seed --confirm`.** The Northwind Traders seed is now
> built into the binary (`internal/demoseed`), covered by `go test ./...`, and it
> uses the same three site codes the Stone Age platform's own `demo-seed` writes —
> so the two demos describe one company. It needs no `pb` CLI, no superuser
> session, and no running server.
>
> ```bash
> ./accessd migrate up
> ./accessd demo-seed --confirm
> ```
>
> What you get: three sites (`KC-DC1`, `KC-OFFICE`, `SGF-XD2`), four controllers
> across both board models, ten portals including a maglock and a vehicle gate,
> four areas (two with scheduled overnight arming), eight aux inputs spanning the
> `monitor`/`intrusion`/`tamper_24h` point types (no `fire` input), four aux
> outputs, a holiday calendar, eight roles, six access groups (including the
> arm-only cleaning crew), fifteen cardholders — thirteen with badge logins, three
> of them visitors in three different pass states — and ~240 backdated events
> (`--events` to change) guaranteed to carry eight distinct decision reason codes,
> plus three unacknowledged alarms.
>
> The two files below still work and are kept for now. `seed.ps1` creates a
> **different** company (`dc`, `east-office`) so the two do not collide, but
> running both leaves you with two unrelated demos in one database — pick one.

| File | What it is |
|---|---|
| [`rules/`](https://github.com/stone-age-io/access-control/blob/main/demo/rules) | **Start here for live activity.** rule-router scheduler rules for the `demo-seed` estate. Publishes to the *reader* subject, so running `access-controller` processes make the decisions — nothing about a reason code is fabricated. Needs four controllers up; see [`rules/README.md`](https://github.com/stone-age-io/access-control/blob/main/demo/rules/README.md). |
| [`telegraf/`](https://github.com/stone-age-io/access-control/blob/main/demo/telegraf) | A Telegraf config that subscribes to the `acc.>` event subtree while `rules/` drives the estate and writes each event to VictoriaMetrics as a time series — "which door, which site, which box" as long-term, queryable history. Storage only; it decides nothing. |
| [`seed.ps1`](https://github.com/stone-age-io/access-control/blob/main/demo/seed.ps1) | Superseded by `accessd demo-seed`. Idempotent PowerShell seed driving the REST API — sites, controllers, portals, an armed area, roles, people, credentials, badge logins, visitor passes, and a backfill of recent events plus unacknowledged alarms. |
| [`access-demo.yaml`](https://github.com/stone-age-io/access-control/blob/main/demo/access-demo.yaml) | The older simulator, for `seed.ps1`'s company and for a deployment with **no controller running**: it injects finished `evt.tap` events into the audit subtree. Still the right tool when you want a moving event feed and nothing else. |

> Point `rule-router --rules` at `demo/rules`, not at `demo/` — the latter loads
> `access-demo.yaml` too, and the two target different companies.

Everything in this directory is **dev/demo tooling**, not part of either
binary. Nothing here ships to a customer install, and the passwords below are
deliberately weak and well-known.

## Seeding

Needs the `pb` CLI authenticated as a superuser against the target instance:

```bash
pb context select <your-context> && pb auth status
```

Then, from the repo root:

```bash
pwsh demo/seed.ps1
```

It builds on top of the base fixture (`pbmigrations/1750000001_fixture.go`), so run it
against a database where migration `1750000001` seeded `location hq` — a fresh `accessd`
data directory. It reports `+` created, `=` already present, `!` failed, and a re-run
should report `created=0 failed=0`.

> **Re-running is safe; running against production is not.** Every record is looked up by
> its natural key first, so repeating a partial run is harmless. But this creates people
> with working credentials — check `pb context list` before you run it.

### What you get

| | |
|---|---|
| Sites | `hq` (from the fixture), `dc` Distribution Center, `east-office` East Coast Office |
| Intrusion | area `dc-warehouse`, armed, with a motion point and a 24h glassbreak point |
| Automation | `east-lobby` auto-unlocks during office hours; `dc-main-entrance` is `disarm_on_grant` |
| People | 13 employees + contractors across 7 roles, one suspended |
| No-inbox cards | "Loading Dock Spare Card" and "Fire Dept Lockbox" — cardholders with no email, which cannot sign in by any method |
| Visitors | three passes, one live, one expired, one revoked |
| Area rights | `ag-warehouse` grants arm **and** disarm on `dc-warehouse`; `ag-cleaning` grants **arm only** |
| Aux output on a badge | `ag-relays` grants the East gate strike (Facilities and Security hold it) |
| Remote opt-ins | unlock on `east-lobby` + `hq-east-stair`; arm/disarm on `dc-warehouse`; the gate strike; floor plan on `east-office` |
| Operator's own badge | `admin@local.dev` is linked to Sarah Chen's cardholder, so "My badge" in the profile menu works |
| Troubleshooting a badge | the expired and revoked visitors are the ones to open — find them on **Cardholders** under the **Visitors** filter, then **View their badge** shows what that person's own screen says, which is how you tell "expired" from "never issued" from "no login" without cross-referencing four collections |
| History | 9 taps and 3 unacknowledged alarms, backdated minutes to hours |

The arm-rights asymmetry is the part worth looking at: the cleaning crew can arm the
warehouse when they finish and **cannot** disarm it. That is why arm and disarm are
separate rights rather than one checkbox, and it is what `deny_no_area_right` reports when
a group has areas but no rights at all.

The floor plan on badges needs an image: `east-office` is opted in, but nothing renders
until you upload a floorplan to that location and place a portal or two on it.

### Signing in

The seed prints these when it finishes:

| Tier | Identity | Secret |
|---|---|---|
| Operator console (`/login`) | `admin@local.dev` | `changeme123` (from fixture `1750000010`) |
| Badge — staff (`/login?as=badge`) | `sarah.chen@stoneage.example`, `marcus.johnson@…`, `priya.patel@…`, `emily.rodriguez@…` | `badge-demo-1234` |
| Badge — fixture cardholder | `alice@example.com` | `changeme123` |
| Badge — visitor | `dana.whitfield@acme.example` | `badge-demo-1234` |

A real visitor normally signs in with an **emailed one-time code**, so their pass would need
SMTP. The seed gives the demo visitors the staff password instead — partly so the demo works
with no mail server, and partly because that operator-set initial password is a real feature
rather than a demo shortcut: it is the field on the visitor mint form that makes the badge
tier usable on an install with no mail at all. It is never emailed; an operator hands it over
at the desk, along with the badge link and QR the mint screen shows.

The other nine employees have **no** badge login, which is the realistic default: most
people in a PACS only ever tap a card. `david.kim@stoneage.example` is the one to try if
you want to watch the auth rule refuse a correct password.

## Live event feed

`access-demo.yaml` publishes straight to the audit subtree, so **no controller needs to be
running** — `accessd`'s always-on audit consumer projects the messages into `events` by
exactly the path a real controller's events take.

```bash
rule-router --config config/rule-scheduler.yaml   # features.scheduler: true
```

Its NATS connection must point at the same server and account as `accessd`, and be allowed
to publish `acc.>`. Copy the file into rule-router's rules directory (e.g.
`rules/scheduler/access-demo.yaml`).

Every location code, portal code, and credential value in it is one `seed.ps1` creates, so
**seed first** or the events will reference records that do not exist. They still project —
the `events` collection is a denormalized snapshot of text — but the UI will link nowhere.

> Alarms project as **unacknowledged and accumulate** until someone acks them in the Alarm
> Console. That is the point during a demo, and a nuisance if you leave the scheduler
> running for a week: widen the alarm crons, or ack them.

## Keeping these in step with the schema

`seed.ps1` writes through the REST API, so it is subject to the same rules and validators
as the UI. Two things about the current schema bite hardest, and both are commented in the
script where they matter:

- **`cardholders` is an auth collection.** Every create must carry `password` +
  `passwordConfirm`; PocketBase's record-create request form requires them on any new auth
  record, before any server hook can fill them in. `New-Cardholder` handles it.
- **Being an auth record is not being an account.** The collection's auth rule requires
  `badge_login`, so the people seeded without it cannot sign in whatever is stored.

If a migration adds a required field or a validator, this script is the thing most likely
to break silently — it prints `!` and a message per failed record, so check the summary
line rather than assuming a clean run.
