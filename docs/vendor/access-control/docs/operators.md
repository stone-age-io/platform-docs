---
path: access-control/operators
nav_order: 30
---
# stone-access operators & control-plane access

Who may sign into the management UI, what each operator is allowed to do, and how
every control-plane change is recorded. This is the **control plane's** access
model — distinct from the **data plane** access *decision* (`policy.Decide`, the
credential-at-a-door call documented in [`protocol.md`](protocol.md)). The two
never mix: `policy.Decide`, the KV mirror, and the controller never see operator
permissions, and a controller never sees an operator.

## Contents

- [Sign-in](#sign-in) — the `users` auth collection, superuser break-glass
- [Capabilities](#capabilities) — the five orthogonal abilities
- [What each capability gates](#what-each-capability-gates) — collection rules + custom routes
- [Presets](#presets) — the UI's named capability sets
- [Non-operator auth tiers](#non-operator-auth-tiers) — why the read floor names `users`
- [Privilege-escalation guard](#privilege-escalation-guard)
- [Control-plane audit log](#control-plane-audit-log-audit_logs) — `audit_logs`, what is recorded, retention

## Sign-in

The management UI authenticates against PocketBase's built-in **`users` auth
collection**, *not* the all-powerful `_superusers` admin. Open signup is disabled —
operator accounts are created by another operator who holds the `operators`
capability (or by a superuser). Seed the first one with the guarded dev fixture
(`pbmigrations/1750000010`) or create it directly in the PocketBase admin (`/_`).

A **superuser** remains the break-glass account: it bypasses every collection rule
and every capability check, and it still signs into the PocketBase admin UI at
`/_`. Create one with `./accessd superuser upsert <email> <pass>`. Superuser logins
are deliberately **not** written to the operator audit log (they go through
`_superusers`, a separate auth collection).

## Capabilities

An operator's ability is the multi-select **`users.permissions`** field — an
*orthogonal set of capabilities*, not a rank. (It replaced an earlier
`admin`/`operator`/`viewer` ladder, which couldn't express real roles like
"enrollment only" or "door ops but not hardware" — each a non-linear subset.)
**Read is a universal floor**: any authenticated operator can read every
operational collection. "Operator" here means a record in the **`users`**
collection specifically — the floor is scoped to that collection, not to "any
authenticated request", so a second auth tier does not inherit it (see
[Non-operator auth tiers](#non-operator-auth-tiers)). Only **writes and commands**
are gated, each by one capability:

| Capability | Grants |
|---|---|
| `enroll` | write **people** — cardholders, credentials |
| `policy` | write **access logic** — roles, access_groups, schedules, holidays, holiday_calendars |
| `topology` | write **hardware** — locations, controllers, portals, aux_input, aux_output, areas |
| `command` | issue **commands** — grant, posture, aux-output drive, area arm/disarm, alarm ack |
| `operators` | manage **operator accounts**, read the **audit log**, and **hard-delete** structural records |

The five names are constants in [`internal/authz`](https://github.com/stone-age-io/access-control/blob/main/internal/authz/authz.go)
(`CapEnroll`/`CapPolicy`/`CapTopology`/`CapCommand`/`CapOperators`). They are the
operator's whole authorization surface — there is no role field to drift out of
sync with the permissions.

> **`policy` also decides who may disarm.** An access group grants **areas** and **aux
> outputs** alongside portals (migration
> [`1750000037`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000037_group_targets.go)), so editing a group can hand
> a badge holder the ability to disarm an area or drive a relay. That stays under `policy`
> rather than moving to `command`: choosing *who may* disarm the warehouse on their shift
> is the same kind of decision as choosing who may open its door, where `command` is
> "disarm it, now, myself". Note the asymmetry that follows — a `policy` holder with no
> `command` cannot arm anything themselves, but can decide who can.

### Access groups grant three kinds of thing

A group is `{portals, areas, aux_outputs}` under **one schedule**, plus `area_rights`. The
three relations are independent, so an area-only group is simply one with no portals.

**Arm and disarm are separate rights.** `area_rights` is a two-value multi-select, and an
**empty list grants neither** — closing staff who lock up can hold `arm` alone, and
disarming (which turns intrusion detection off) is the one worth withholding. The form
pre-selects both the moment you add an area, because an operator who ticks an area plainly
means to grant something; narrowing it is then a deliberate click. If rights are left empty
anyway, the decision reports `deny_no_area_right` — distinct from `deny_no_access`
precisely so this misconfiguration is diagnosable in the reason code the action returns and
in the `audit_logs` row it writes, rather than looking like a person with no access. (The
access simulator is portal-only for now, so it will not reproduce this one.)

A holder acting on any of it also needs the per-record remote opt-in (see the route table
below); at a keypad or reader, the group grant is the whole story.

### Cardholder photos (PII)

`cardholders.photo` (migration
[`1750000029`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000029_cardholder_photo.go)) is the first real
PII in the schema, and it follows the read floor above: **every operator can see
every photo**, with no capability gate. That is deliberate — a guard verifying a
face at a desk needs it, and gating it would make the badge and alarm views
inconsistent per-operator. Two consequences worth knowing:

- The field is a **protected** file, so its URL carries no implicit authorization:
  PocketBase requires a short-lived file token (`pb.files.getToken()`, wrapped by
  the UI's `useFileUrl`). Unlike an ordinary PocketBase file URL, a pasted link does
  not work for someone without a session.
- Photos live in `pb_data/storage`, so **backups grow** with the cardholder
  population, and dropping the field does not delete the stored files.

The photo is never mirrored to NATS KV — `policykv.User` carries only status and
roles — so it never reaches a leaf node.

## What each capability gates

Two enforcement points share `users.permissions`:

**1. Collection CRUD** — PocketBase collection rules (the real boundary), set by
migration [`1750000016`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000016_operator_permissions.go) (and, for the
collections they add, [`1750000018`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000018_holiday_calendars.go)
`holiday_calendars` and [`1750000019`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000019_areas_and_points.go) `areas`).
List/View are open to any authenticated operator
(`@request.auth.collectionName = "users"`, set by migration
[`1750000027`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000027_operator_read_floor.go)) except where
noted; the table shows the **write** rules:

| Collection(s) | Create / Update | Delete |
|---|---|---|
| `cardholders`, `credentials` | `enroll` | `operators` |
| `schedules`, `access_groups`, `roles` | `policy` | `operators` |
| `holidays`, `holiday_calendars` | `policy` | `policy` |
| `locations`, `controllers`, `portals`, `aux_input`, `aux_output`, `areas` | `topology` | `operators` |
| `users` | `operators` (create) · self-or-`operators` (update) | `operators` |
| `audit_logs` | — (superuser-only; hook-written) | — |
| `events`, `point_status` | — (machine-written; accessd's `app.Save` bypasses rules) | — |

`users` List/View is **self or `operators`** (an operator without `operators` sees
only their own account), and `audit_logs` List/View needs `operators`. Two auth
collections also carry a **ManageRule** — the right to change another record's auth
fields (password, email) without the proof PocketBase otherwise demands: `users` →
`operators`, and `cardholders` →
`@request.auth.collectionName = "users" && @request.auth.permissions ~ "enroll"` (which is
what lets the cardholder form reset a locked-out holder's password).

**Hard-delete is a trusted action.** Removing a person or a structural
topology/policy record requires `operators` — for everyday revocation, *deactivate*
via the existing status / `valid_from` / `valid_until` fields instead of deleting.
`holidays` and `holiday_calendars` are the exception (their delete stays at `policy`,
being low-value access logic).

> The rule expression is `@request.auth.permissions ~ "x"` (JSON LIKE), **not**
> `?=`. A multi-select referenced through `@request.auth` is bound as its
> serialized array (not `json_each`-expanded), so the "any-equals" `?=` silently
> matches nothing; `~` (contains) matches, and is exact here only because the five
> capability names are pairwise non-substring. This is load-bearing and is the
> security boundary `TestPermissionRuleEnforcement` locks down — don't rename a
> capability to a substring of another, and don't switch the operator.

**2. Custom HTTP routes** — accessd's bespoke routes don't go through a collection,
so they call `authz.RequireCapability` per handler:

| Route | Requires | Effect |
|---|---|---|
| `POST /api/portals/{id}/grant` | `command` | momentary strike pulse → `cmd.grant` |
| `POST /api/portals/{id}/posture` | `command` | posture override / clear → `cmd.posture` |
| `POST /api/aux-outputs/{id}/output` | `command` | drive an aux output → `cmd.output` |
| `POST /api/events/{id}/ack` | `command` | acknowledge an alarm/fire (sets ack fields; also stops [`internal/repage`](https://github.com/stone-age-io/access-control/blob/main/internal/repage)'s reminder emails) |
| `POST /api/areas/{id}/arm` · `/disarm` · `/arm-clear` | `command` | set/clear an area's durable `arm_override` |
| `GET /api/models` | any operator | hardware-model catalogue (relay/input counts and labels per controller model) for the I/O map and index pickers |
| `POST /api/simulate` | any operator | access simulator — a decision oracle; operator-only |
| `POST /api/badge/visitors` | `enroll` | mint a visitor: cardholder + time-bound credential, in one transaction |
| `POST /api/badge/visitors/{id}/revoke` | `enroll` | end a visit: revoke the pass, keep the person |
| `POST /api/badge/invite/{id}` | `enroll` | email a badge holder where to sign in (never the password) |
| `GET /api/badge/preview/{id}` | `enroll` | **read** what that cardholder's own badge shows them |

There is deliberately **no** route for "give this cardholder a badge login": it is a
field on the cardholder (`badge_login`), so it is an ordinary record update the
collection rules already govern.

#### Seeing a holder's badge (`/api/badge/preview`)

"My pass doesn't work" is the support call, and almost every cause of it is invisible from
the operator side without cross-referencing four collections: no credential issued at all, a
window that has not opened, a suspended person, a group that grants nothing, a door that
grants in person but not remotely, a `badge_login` that was never ticked. The badge already
reduces all of that to one sentence and one list, so this route returns **the holder's own
`/me` and `/live` payloads** — the same Go builders serve both — plus the three
operator-only facts a badge cannot show about itself (`badgeLogin`, `passwordSet`,
`status`). The console opens it from **View their badge** on the cardholder page (shown to
`enroll` holders) and renders it with the badge's own Vue components — down to the same
bottom navigation bar — so if the preview looks wrong, it *is* wrong.

**It is a read, and mints nothing.** PocketBase can issue a session for another record
(`NewStaticAuthToken`), which would have let an operator press the holder's buttons. That
was rejected: a badge action stamps the **cardholder** as `actor_id`, because that is who
the audit trail is about — so an operator driving a borrowed badge session would write rows
indistinguishable from the holder's own, and "did this visitor open the loading bay, or
someone checking on them?" would stop being answerable from the log. It is exactly the sort
of question only asked after something has gone wrong.

The trade, stated plainly: this cannot prove a holder's unlock button works end-to-end. It
proves what the server would decide, which is where essentially every "my badge is broken"
actually lives. An operator who needs the door opened uses `POST /api/portals/{id}/grant`
with their own `command` capability. Reading a badge means reading someone's photo, QR
payload, and every door they hold, so **every preview writes an `audit_logs` row** —
looks at people are what an access-control system should be able to account for afterwards.

The badge tier has routes of its own, gated by the **`cardholders`** collection rather than
by capability — see [Non-operator auth tiers](#non-operator-auth-tiers):

| Route | Who | Purpose |
|---|---|---|
| `GET /api/badge/me` | a badge holder **or an operator** | their own badge: photo, QR, and what it grants |
| `POST /api/badge/unlock/{id}` | a badge holder | remote unlock, authorized by `policy.Decide` |
| `POST /api/badge/areas/{id}/arm` · `/disarm` | a badge holder | arm/disarm, authorized by `policy.DecideArea` |
| `POST /api/badge/outputs/{id}/pulse` | a badge holder | pulse an aux relay, authorized by `policy.DecideOutput` |
| `GET /api/badge/live` | a badge holder | their own doors/controls placed on a site's floor plan |
| `POST /api/badge/password` | a badge holder | set or change their own password |

All of these except the operator-only preview are rate-limited by default (migrations
`1750000032`/`1750000039`/`1750000041`), as are the `cardholders` sign-in endpoints; the
numbers are in [`configuration.md`](configuration.md#rate-limits-and-trustedproxy-accessd).

`/api/badge/me` is the **only** one an operator token may call, resolving through
`cardholders.operator` (migration `1750000040`) so one human who holds accounts in both
tiers can see their own badge from the console's profile menu without a second sign-in.
Everything that *actuates* names `cardholders` alone: an operator opening a door uses
`POST /api/portals/{id}/grant` with their `command` capability, where it is audited as an
operator action, rather than through a second path that would leave the audit trail
ambiguous about which authority they used.

The badge presents these as **one bottom navigation bar** — Badge (the face: photo and
QR), then Plan, Portals, Areas, Controls, On site — that is **adaptive**: the face is always
there, and every other screen appears only if that badge has something in it, so the common
badge is Badge + Plan or Badge + Portals (one that grants nothing gets a single Access
screen saying so). It is deliberately not a copy of the operator's Live View: that has
fixed segments because a site has hundreds of points and an operator is hunting through
them, whereas a holder typically has a handful of doors and no areas or controls. Nor
does it show live hardware state — an area's chip is the policy *intent* the server resolved, and
door open/closed never appears. Watching a building is the console's job; a badge is what
you use to get into one.

Each badge action also has a **per-record opt-in**, all default false, all control-plane
only (never mirrored to KV): `portals.allow_remote_unlock`, `areas.allow_remote_arm`,
`aux_output.allow_remote`, and `locations.badge_floorplan`. None of them widens anything —
the pure decider still has to grant the action — they only separate "may act here" from
"may act from anywhere, with nobody present", and in the floor plan's case "may open a door
here" from "may see the layout of the building".

Most of these bridge the UI to the **NATS command plane**; the wire subjects and
bodies they publish are documented in [`protocol.md`](protocol.md#command-details).
The **ack** and **arm/disarm** routes are the exception: they write a PocketBase
record (the ack fields; the area `arm_override`) rather than publishing a
fire-and-forget command, because arm-state must be *durable* (a reboot must not
silently disarm). Each therefore writes its own `audit_logs` row (a custom-route
`app.Save` doesn't trip the changelog `*Request` hooks).

> **`command` now covers arming.** Adding arm/disarm and alarm-ack under `command`
> widens that capability's meaning: an operator you trust to buzz a door open can
> now also arm/disarm the intrusion system and acknowledge alarms. That is a
> deliberate v1 choice (no separate `arm` capability yet) — keep it in mind when
> granting `command`. Area *configuration* (membership, schedules) stays at
> `topology`; only the operational arm/disarm is `command`.

> **Entry-disarm is credential-driven, not capability-gated.** A valid credential
> grant at a portal flagged `disarm_on_grant` durably disarms that portal's area —
> this is a *cardholder* action (badging in), not an operator API call, so no
> operator capability is involved. accessd's disarm sink (`internal/disarm`) writes
> the `arm_override` and an `audit_logs` row attributed to the **credential + portal**
> (`actor_email: entry-disarm`), not to an operator. An operator remote `cmd.grant`
> carries no credential and therefore never disarms.

## Presets

The operator-management UI offers **named presets** that tick capability boxes —
they are a UI convenience only; *nothing about a preset is stored*, keeping
`permissions` the single source of truth (an operator whose set matches no preset
shows as "Custom"):

| Preset | Capabilities |
|---|---|
| Read-only | *(none)* |
| Enrollment | `enroll` |
| Command Ops | `command`, `policy` |
| Facilities | `topology` |
| Admin | all five |

## Non-operator auth tiers

stone-access has more than one auth collection. `users` is the **operator** tier this
document describes; `_superusers` is the break-glass admin; and **`cardholders`** —
the collection holding the people the PACS is about — is itself the **badge tier**.
A cardholder with `badge_login` set can sign in to view their own badge and, where
permitted, remotely unlock a door. A cardholder is *not* an operator: the record holds no
`permissions` field and must never read the policy graph.

That the badge tier and a policy-graph node are the **same collection** is what makes the
rules below load-bearing rather than merely tidy. One row is simultaneously the thing a
holder authenticates as and the entry point to the access graph
(cardholder → roles → groups → portals), so a rule that admits a badge token to the wrong
verb is a self-service grant of doors.

> **Why one collection and not two.** The badge tier began as a separate `badge_users`
> collection with a 1:1 relation back to `cardholders`. Every complicated part of it was
> the relation: a unique index so one person could not hold two logins, a cascade delete
> so a deleted person left no orphan login that authenticates and resolves nobody, a
> field guard so a holder could not repoint the relation at someone else and inherit
> their doors, and a delete hook so a visitor's two halves died together. None of those
> describe a rule about badges — they describe the join. Collapsing the records deleted
> all four. See [`internal/badgeapi`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi/badgeapi.go)'s package doc for
> what it cost.

Keeping the two tiers apart takes three deliberate choices, all easy to get wrong:

1. **Collection read rules name the collection, not "any auth."** The floor is
   `@request.auth.collectionName = "users"`, not `@request.auth.id != ""`. The
   latter is auth-collection-*agnostic*: every badge holder would satisfy it and
   inherit operator read on the whole graph — including `credentials`, whose
   `value` field is the credential secret in plaintext. `TestReadFloorExcludesNonOperatorAuth`
   is the regression test, and it deliberately uses a *throwaway* auth collection so
   the guarantee holds for tiers added later.
2. **Custom routes use `authz.RequireOperatorAuth()`, not bare `apis.RequireAuth()`.**
   Bare `RequireAuth()` admits any auth collection. `POST /api/simulate` is the
   sharp case: it is a **decision oracle** over the entire policy graph, so exposing
   it to the badge tier would be worse than exposing the collections. Note that
   `apis.RequireAuth("users")` *alone* is also wrong — PocketBase's check is plain
   collection-name membership with no superuser exemption, so it would lock out the
   break-glass account. `RequireOperatorAuth` names both.
3. **Reads are self-scoped; writes exclude the badge tier entirely.** `cardholders` is
   read by `id = @request.auth.id || @request.auth.collectionName = "users"` — an operator
   sees everyone, a holder sees exactly their own row — while create/update/delete are a
   bare capability check (`@request.auth.permissions ~ "enroll"`, delete `"operators"`)
   that a cardholder, having no `permissions` field, can never satisfy, with **no self
   clause at all**.

   That asymmetry is the whole boundary, and it is why there is no field-level guard on
   this collection. A PocketBase rule selects which **records** may be written and says
   nothing about which **fields**, so a self-write clause here would mean "may edit every
   non-system field on my own row", including `roles` (a grant at the reader), `status`
   (un-suspending yourself), and `kind` (whether the QR carries a working credential).
   Rather than guard each one, the tier simply cannot write its own record;
   `POST /api/badge/password` is how a holder changes the one thing they may, and it is an
   `app.Save` that bypasses collection rules by design.

   The **self-read** clause is not cosmetic. PocketBase checks a **protected file**
   download against the record's own `ViewRule`, and `cardholders.photo` is protected — so
   without it a holder's own badge renders with no face on it. It also means the operator
   UI can show the badge-login field to *any* operator and gate only the editing, instead
   of hiding it behind `enroll` as a blank space that cannot say "not allowed to look".

Nothing in a cardholder row is secret to an operator (the password hash and token key are
system fields the API never serialises), so `enroll` gates *changing* a login, never
seeing one.

Badge-tier routes live in `internal/badgeapi` and are authorized by
`policy.Decide` (what that person's own credential opens, right now) rather than by
capability — so a remote unlock can never exceed the holder's physical access.
Every badge action, allowed or denied, writes an `audit_logs` row. A **denied** remote
unlock also emits an ordinary `evt.tap` with `allow: false` and `source: badge`, so it
lands in `events` beside a denial at a reader; an allowed one is the existing `cmd.grant`
(actor `badge:<cardholderId>`), recorded by the controller's own tap event.

### Issuing a badge login

The two kinds of badge are created by different flows, because they start from
different places:

| | **Visitor** | **Staff holder** |
|---|---|---|
| Where | **Cardholders → Visitor Pass** | **Cardholder form → Badge login** (a checkbox) |
| Route | `POST /api/badge/visitors` | none — it is a field update |
| Creates | the person + a time-bound credential, in one transaction | nothing; the person already exists |
| Access from | a curated `visitor_preset` role, chosen at mint | the roles already on that cardholder |
| QR encodes | the credential value (works at a scanner) | the cardholder id (opens nothing) |
| Usual sign-in | emailed one-time code | password |
| Extending it | **Reissue** — a new pass, the old code revoked | issue or extend a credential |
| Ending it | **Revoke** (pass dies, person kept) or **Delete** (both) | untick the checkbox — the credential is untouched |

**One page, one filter.** Only the *minting* is a separate flow; after that a visitor is an
ordinary row on **Cardholders**, found under its **Visitors** filter (server-side on `kind`,
remembered per browser, defaulting to **Permanent** so a lobby of guests does not bury the
roster). Their page is the cardholder page, which grows the pass state, its window, and the
visit actions when `kind = "visitor"`. There were two pages over this one collection until
the merge, and searching the roster for someone who happened to be a visitor returned nothing
with no hint the other page existed — so search now spans every kind whatever the filter
shows, and says how many matches it is hiding. The pass-state chips are the one thing scoped
to the Visitors filter: a state is derived from the newest of a person's credentials, a row in
another collection, so it narrows the loaded page rather than the query — sound on 50
newest-first visits, misleading on a name-sorted roster of thousands.

**Reissue, not extend.** A visitor's QR carries the credential *value* — a working key, on a
screen, for hours — so it gets photographed, screenshotted and forwarded as a matter of
course. Pushing that same value's `valid_until` out would silently re-arm every copy of it,
so extending a visit goes through `POST /api/badge/visitors` again: the route recognises the
returning visitor by email and refreshes them in place (`reused: true`), minting a new value
from the server's CSPRNG and revoking the previous one, all in one transaction. It costs the
visitor one refresh of their badge.

**With no mail server, set an initial password.** A visitor's default route in is an emailed
one-time code, and password reset is also an email, so an install with no SMTP would mint
passes nobody could open. Both flows therefore accept an optional initial password
(`password` on the mint request; the Badge login section of the cardholder form for staff) —
handed over at the desk and **never** emailed, since mail is stored indefinitely, forwarded,
and synced to devices, so a door-opening password sent that way would outlive every control
around it. The mint success screen also shows the badge link and a QR of it; both are safe to
display, because the link carries no code and no token.

A staff badge login is deliberately *not* granted by enrollment: most cardholders never
need one, and giving everybody a login would put a phone-openable surface on people who
only ever tap a card. It is one checkbox on the person's own form, because it is one
**field** on that person — `badge_login`, which backs the collection's auth rule — rather
than a related entity with a lifecycle of its own.

Every cardholder is an auth record, including the majority who never sign in. Being an
auth record is not being an account: a record without `badge_login` fails the collection's
auth rule, and carries a random password nobody has ever seen (PocketBase requires a
non-blank one; [`badgeapi.RegisterGuards`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi/guards.go) fills it). A
cardholder with **no email** — a contractor, a hourly worker, a "Loading Dock Spare" card —
cannot sign in by any method at all, since email is the sole identity field and the only
route an emailed code can arrive by; so `bindLoginRequiresEmail` refuses to save
`badge_login` on a record with no email (on create and on update, so clearing the address
later is refused too).

**For a staff holder, a badge login is not access.** It controls who may *see* a badge
and use remote unlock. Their credentials work at every door they are entitled to whether
or not a login exists, and removing a login revokes nothing. To actually revoke access,
set `credentials.status = revoked` (or suspend the cardholder) — that is what propagates
through the mirror to the edge. Giving a login and taking it back are the same act, so
both are `enroll`.

**Ending a visit is Revoke, not Delete.** Revoke kills the pass and keeps the person, so
the visit stays on the record and a returning visitor is recognised rather than
duplicated. Delete removes the person *and their credentials* — `credentials.user`
cascades ([`1750000036`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000036_credential_cascade.go)), because a
credential outliving its holder is a key that opens doors and resolves to nobody. The
cascade runs through the ordinary delete path, so the KV mirror prunes those
`cred.{value}` keys; it cannot leave a working key at the edge.

> Two bugs the collapse removed. While the login was a separate record, deleting a
> visitor login left the credential `active` **and** removed it from
> [`internal/badgesweep`](https://github.com/stone-age-io/access-control/blob/main/internal/badgesweep)'s view, since the sweep finds expired
> passes by enumerating visitors — the one action an operator would take to end a visit
> both failed to end it and disabled the job that eventually would. Separately, deleting
> a *cardholder* always failed outright: `credentials.user` is a required relation and
> PocketBase refuses to delete its target, so the delete button did not work for anyone
> who had ever been issued a card.

**A login with no credential** signs in and honestly reports that no pass has been
issued. Roles and effective access are not enough on their own; the cardholder page says
so where the fix is one click away.

### Sign-in methods

All three are enabled on `cardholders`
([`1750000000`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000000_collections.go)):

| Method | For | Needs SMTP |
|---|---|---|
| **Password** (email + password) | staff holders, who sign in for years | no |
| **One-time code** (emailed) | visitors; anyone who has not set a password | **yes** |
| **OAuth2** | staff with an existing identity; providers are configured in the PocketBase admin | no |

> **Without SMTP, a password is the only way in.** OTP and the forgot-password link are
> both emails. On an install with no mail server, set an initial password and hand it over
> in person — otherwise the badge tier is inert. There is a field for it on **both** issuing
> paths: the cardholder form for a staff holder, and **Initial password** on the visitor
> mint form. The visitor path needs it most, because a visitor's only other route in is an
> emailed code: without a password, minting on an SMTP-less install produces a pass its
> holder can never see.

Both tiers share **one sign-in page** at `/login`, with an explicit two-way selector
(*My badge* / *Operator*) that is deep-linkable as `?as=badge` — what the invite mail
links to — and remembered per browser, so a lobby tablet and an operator's laptop each
land on the right form. The choice is explicit rather than guessed from the address
because one person can legitimately hold an account in **both** tiers: the security guard
who badges in and also runs the console. Guessing would sign them into the wrong
privilege domain, split their failed attempts across two rate-limit buckets, and leak
which tier an address belongs to. It is two entries and not three — a visitor and a staff
cardholder are the same collection, so a visitor never has to know they are a "visitor".

> **A subtlety worth knowing about, since PocketBase does it silently.** On a *first*
> successful one-time code, PocketBase marks the record verified and — unless MFA is on —
> **randomises its password**, as a defence against account pre-hijacking on an open-signup
> collection. That defence does not apply here (only an `enroll` operator can create a
> cardholder, so there is no attacker-authored record to disarm) and it destroyed exactly
> the operator-set password the SMTP-less install depends on. `bindOTPPasswordPreservation`
> in [`internal/badgeapi`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi/guards.go) marks such a record verified
> before that branch runs, which skips it.

An initial password is **optional and never emailed**: mail is stored indefinitely,
forwarded, and synced to devices, so a door-opening password sent by mail would outlive
every other control around it. The invite mail says only *where* to sign in.

A holder sets or changes their own password from the badge page, under the account menu in
its header. The `password_set`
flag records whether they have one, which decides whether the current password must be
supplied to change it: a holder who signed in by one-time code is setting a *first*
password and has nothing to prove, while one who already has a password must supply it
so that a stolen session cannot silently lock them out of their own badge. Setting a
password from the cardholder form replaces the existing one — the operator's path for
someone who is locked out and has no working mail. Note that **changing a password signs out every
device**, including the one making the change (PocketBase rotates the record's token
key); the badge UI re-authenticates silently, so this is only visible on a holder's
other phones.

## Privilege-escalation guard

Changing a user's `permissions` is itself gated beyond the `users` update rule: a
hook in [`internal/changelog`](https://github.com/stone-age-io/access-control/blob/main/internal/changelog/changelog.go) rejects any
update that alters `permissions` unless the actor is a superuser or holds the
`operators` capability — so an operator who can edit their own profile (self-update
is allowed) still cannot grant themselves new capabilities. `permissions` is the only
guarded field: the rest of an operator's own row — notably the notification opt-ins
`notify`/`notify_locations`/`notify_types` (see
[`configuration.md`](configuration.md#notifications-accessd-only)) — stays self-editable.

## Control-plane audit log (`audit_logs`)

Every operator edit to a policy record is recorded in the **`audit_logs`**
collection by [`internal/changelog`](https://github.com/stone-age-io/access-control/blob/main/internal/changelog/changelog.go). This is
the operator-edit counterpart to [`internal/audit`](https://github.com/stone-age-io/access-control/blob/main/internal/audit) (which
records *door* activity from JetStream into `events`) — the two are complementary
and disjoint.

**What's recorded.** API-driven create / update / delete on the audited collections —
`cardholders`, `credentials`, `holidays`, `holiday_calendars`, `locations`, `schedules`,
`controllers`, `portals`, `access_groups`, `roles`, `aux_input`, `aux_output`, `areas`,
`users` — plus operator **logins** (auth events on `users`; superusers excluded, and
badge-tier sign-ins on `cardholders` are not recorded). `TestAuditedCoversControlPlane`
fails if a control-plane collection is added and left off this list.

**What's excluded by construction.** The hooks are PocketBase `*Request` hooks,
which fire only for **API-driven** operations. accessd's own programmatic
`app.Save()` writes — controller heartbeats, the `events`/`point_status`
projections, the KV mirror — never trigger them, so machine churn is excluded
without an allowlist dance. `events`, `point_status`, and `audit_logs` itself are
also excluded. (`controllers` is safely audited *because* heartbeat updates take
the programmatic path, not the API.)

**Rows written outside the hooks.** The flip side of "programmatic writes are
invisible" is that accessd's custom routes, and the entry-disarm sink, write their own
rows — all `event_type` `update` (the visitor mint is `create`), with the route in
`request_url`:

| Source | `collection_name` | Notes |
|---|---|---|
| alarm ack, area arm/disarm/arm-clear (`internal/commandapi`) | `events`, `areas` | `after` is the fields written |
| badge unlock / arm / disarm / pulse | `portals`, `areas`, `aux_output` | **every attempt, denials included**; `record_id` is the target's *code*, `after.action` names it |
| visitor mint · revoke, invite, badge preview, holder password change | `cardholders` | `after.action`; never the credential value or a password |
| entry-disarm (`internal/disarm`) | `areas` | no request: `actor_email: entry-disarm`, attributed to the credential + portal |

Each row carries:

| Field | Source |
|---|---|
| `event_type` | `create` · `update` · `delete` · `auth` |
| `collection_name`, `record_id` | the affected record |
| `actor_id`, `actor_email`, `actor_collection` | the authenticated operator (or superuser) |
| `request_ip`, `request_method`, `request_url` | the request origin |
| `timestamp` | when the row was written |
| `before`, `after` | full field snapshots (JSON) — **`password` and `tokenKey` are stripped** |

**Fail-safe & non-blocking.** The audited operation has already committed before
the row is written, so an audit-write failure is logged and swallowed, never
propagated to the operator.

**Retention.** When `accessd.auditRetentionDays` is positive, a daily 03:00 cron
deletes rows older than that many days — at most 1000 per run, which is ample for a
change log (unlike the high-volume `events` prune, it does not drain a backlog). The
default is **365** (`0` normalizes to 365 in config); set a **negative** value to
disable pruning and keep audit history forever. See [`configuration.md`](configuration.md#accessd).
