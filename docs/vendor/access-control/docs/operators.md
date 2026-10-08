---
path: access-control/operators
nav_order: 50
---
# Operators & Authorization

This page covers who may sign in to the management UI, what each operator may
do, the badge tier that cardholders and visitors sign in to, and how every
control-plane change is recorded. It is the access model of the **control
plane**. The **data plane** decision (`policy.Decide`, the credential-at-a-door
call) is in [Wire Protocol](protocol.md). The two never mix: `policy.Decide`,
the KV mirror and the controller never see operator permissions, and a
controller never sees an operator.

---

## 1. Sign-in

The management UI authenticates against PocketBase's built-in **`users` auth
collection**, not the all-powerful `_superusers` admin. Open signup is
disabled. An operator account is created by another operator who holds the
`operators` capability, or by a superuser. Seed the first one with the guarded
dev fixture (`pbmigrations/1750000010`), or create it directly in the
PocketBase admin (`/_`).

A **superuser** is the break-glass account. It bypasses every collection rule
and every capability check, and it signs in to the PocketBase admin UI at `/_`.
Create one with `./accessd superuser upsert <email> <pass>`. Superuser logins
are **not** written to the operator audit log, because they go through
`_superusers`, a separate auth collection.

---

## 2. Capabilities

An operator's ability is the multi-select **`users.permissions`** field: a set
of orthogonal capabilities, not a rank. A rank cannot express real roles such
as "enrollment only" or "door ops but not hardware", which are non-linear
subsets.

**Read is a universal floor.** Any authenticated operator can read every
operational collection. "Operator" means a record in the **`users`**
collection specifically, not any authenticated request, so a second auth tier
does not inherit the floor (see [§6](#6-the-badge-tier)). Only **writes and
commands** are gated, each by one capability:

| Capability | Grants |
|---|---|
| `enroll` | write **people**: cardholders, credentials |
| `policy` | write **access logic**: roles, access_groups, schedules, holidays, holiday_calendars |
| `topology` | write **hardware**: locations, controllers, portals, aux_input, aux_output, areas |
| `command` | issue **commands**: grant, posture, aux-output drive, area arm/disarm, alarm ack |
| `operators` | manage **operator accounts**, read the **audit log**, and **hard-delete** structural records |

The five names are constants in [`internal/authz`](https://github.com/stone-age-io/access-control/blob/main/internal/authz/authz.go)
(`CapEnroll`/`CapPolicy`/`CapTopology`/`CapCommand`/`CapOperators`). They are
the operator's whole authorization surface. There is no role field to drift
out of sync with the permissions.

`policy` also decides who may disarm. An access group grants **areas** and
**aux outputs** alongside portals (migration
[`1750000037`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000037_group_targets.go)), so editing a group
can let a badge holder disarm an area or drive a relay. That stays under
`policy`, not `command`: choosing *who may* disarm the warehouse on their shift
is the same kind of decision as choosing who may open its door, while `command`
is "disarm it, now, myself". So a `policy` holder with no `command` cannot arm
anything themselves, but can decide who can.

### Access groups grant three kinds of target

A group is `{portals, areas, aux_outputs}` under **one schedule**, plus
`area_rights`. The three relations are independent, so an area-only group is
one with no portals.

**Arm and disarm are separate rights**, because disarming turns intrusion
detection off. `area_rights` is a two-value multi-select, and an **empty list
grants neither**. Closing staff who lock up can hold `arm` alone. The form
pre-selects both rights when you add an area; narrowing them is then a
deliberate click. If the rights are left empty anyway, the decision reports
`deny_no_area_right`, distinct from `deny_no_access`, so the misconfiguration
shows in the reason code the action returns and in the `audit_logs` row it
writes. The access simulator is portal-only for now, so it does not reproduce
this case.

A holder acting on any of it remotely also needs the per-record remote opt-in
(see [§6](#6-the-badge-tier)). At a keypad or reader, the group grant is the
whole story.

### Cardholder photos

`cardholders.photo` (migration
[`1750000029`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000029_cardholder_photo.go)) holds PII, and it
follows the read floor: **every operator can see every photo**, with no
capability gate. A guard verifying a face at a desk needs it, and gating it
would make the badge and alarm views differ per operator.

- The field is a **protected** file, so its URL carries no implicit
  authorization. PocketBase requires a short-lived file token
  (`pb.files.getToken()`, wrapped by the UI's `useFileUrl`). A pasted link does
  not work for someone without a session.
- Photos live in `pb_data/storage`, so **backups grow** with the cardholder
  population. Dropping the field does not delete the stored files.

The photo is never mirrored to NATS KV (`policykv.User` carries only status and
roles), so it never reaches a leaf node.

---

## 3. Collection Rules

Two enforcement points share `users.permissions`: collection rules (this
section) and custom HTTP routes ([§4](#4-operator-routes)).

PocketBase collection rules are the real boundary. They are set by migration
[`1750000016`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000016_operator_permissions.go), and for the
collections they add, by
[`1750000018`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000018_holiday_calendars.go)
(`holiday_calendars`) and
[`1750000019`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000019_areas_and_points.go) (`areas`).
List/View are open to any authenticated operator
(`@request.auth.collectionName = "users"`, set by migration
[`1750000027`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000027_operator_read_floor.go)) except where
noted. The table shows the **write** rules:

| Collection(s) | Create / Update | Delete |
|---|---|---|
| `cardholders`, `credentials` | `enroll` | `operators` |
| `schedules`, `access_groups`, `roles` | `policy` | `operators` |
| `holidays`, `holiday_calendars` | `policy` | `policy` |
| `locations`, `controllers`, `portals`, `aux_input`, `aux_output`, `areas` | `topology` | `operators` |
| `users` | `operators` (create); self or `operators` (update) | `operators` |
| `audit_logs` | none (superuser only; hook-written) | none |
| `events`, `point_status` | none (machine-written; accessd's `app.Save` bypasses rules) | none |

`users` List/View is **self or `operators`**: an operator without `operators`
sees only their own account. `audit_logs` List/View needs `operators`.

Two auth collections also carry a **ManageRule**, the right to change another
record's auth fields (password, email) without the proof PocketBase otherwise
demands:

- `users`: `operators`
- `cardholders`: `@request.auth.collectionName = "users" && @request.auth.permissions ~ "enroll"`.
  This is what lets the cardholder form reset a locked-out holder's password.

**Hard-delete is a trusted action.** Removing a person or a structural
topology/policy record requires `operators`. For everyday revocation,
*deactivate* through the status, `valid_from` or `valid_until` fields instead
of deleting. `holidays` and `holiday_calendars` are the exception: their delete
stays at `policy`, since they are low-value access logic.

::: warning The rule operator is `~`, not `?=`
The rule expression is `@request.auth.permissions ~ "x"` (JSON LIKE). A
multi-select referenced through `@request.auth` is bound as its serialized
array (not `json_each`-expanded), so the "any-equals" `?=` silently matches
nothing. `~` (contains) matches, and is exact here only because the five
capability names are pairwise non-substring. This is the security boundary
`TestPermissionRuleEnforcement` locks down. Do not rename a capability to a
substring of another, and do not switch the operator.
:::

---

## 4. Operator Routes

accessd's own routes do not go through a collection, so each handler calls
`authz.RequireCapability`:

| Route | Requires | Effect |
|---|---|---|
| `POST /api/portals/{id}/grant` | `command` | momentary strike pulse → `cmd.grant` |
| `POST /api/portals/{id}/posture` | `command` | posture override / clear → `cmd.posture` |
| `POST /api/aux-outputs/{id}/output` | `command` | drive an aux output → `cmd.output` |
| `POST /api/events/{id}/ack` | `command` | acknowledge an alarm/fire (sets ack fields; also stops [`internal/repage`](https://github.com/stone-age-io/access-control/blob/main/internal/repage)'s reminder emails) |
| `POST /api/areas/{id}/arm` · `/disarm` · `/arm-clear` | `command` | set/clear an area's durable `arm_override` |
| `GET /api/models` | any operator | hardware-model catalogue (relay/input counts and labels per controller model) for the I/O map and index pickers |
| `POST /api/simulate` | any operator | access simulator; a decision oracle, so operator-only |
| `POST /api/badge/visitors` | `enroll` | mint a visitor: cardholder + time-bound credential, in one transaction |
| `POST /api/badge/visitors/{id}/revoke` | `enroll` | end a visit: revoke the pass, keep the person |
| `POST /api/badge/invite/{id}` | `enroll` | email a badge holder where to sign in (never the password) |
| `GET /api/badge/preview/{id}` | `enroll` | **read** what that cardholder's own badge shows them |

There is **no** route for "give this cardholder a badge login". It is a field
on the cardholder (`badge_login`), so it is an ordinary record update the
collection rules already govern.

Most of these routes bridge the UI to the **NATS command plane**. The subjects
and bodies they publish are in
[Wire Protocol](protocol.md#command-details). The **ack** and **arm/disarm**
routes are the exception. They write a PocketBase record (the ack fields; the
area `arm_override`) rather than publish a fire-and-forget command, because
arm-state must be durable: a reboot must not silently disarm. Each therefore
writes its own `audit_logs` row, since a custom-route `app.Save` does not trip
the changelog `*Request` hooks.

::: warning `command` covers arming and alarm ack
An operator you trust to buzz a door open can also arm/disarm the intrusion
system and acknowledge alarms. There is no separate `arm` capability in v1,
so keep this in mind when granting `command`. Area *configuration*
(membership, schedules) stays at `topology`; only the operational
arm/disarm is `command`.
:::

::: note Entry-disarm needs no capability
A valid credential grant at a portal flagged `disarm_on_grant` durably
disarms that portal's area. It is a *cardholder* action (badging in), not an
operator API call. accessd's disarm sink (`internal/disarm`) writes the
`arm_override` and an `audit_logs` row attributed to the **credential +
portal** (`actor_email: entry-disarm`), not to an operator. An operator
remote `cmd.grant` carries no credential, so it never disarms.
:::

### Seeing a holder's badge (`/api/badge/preview`)

"My pass doesn't work" is the support call, and most of its causes are
invisible from the operator side without cross-referencing four collections:
no credential issued, a window that has not opened, a suspended person, a group
that grants nothing, a door that grants in person but not remotely, a
`badge_login` that was never ticked. The badge already reduces all of that to
one sentence and one list.

So this route returns **the holder's own `/me` and `/live` payloads** (the same
Go builders serve both), plus the three operator-only facts a badge cannot show
about itself: `badgeLogin`, `passwordSet` and `status`. The console opens it
from **View their badge** on the cardholder page (shown to `enroll` holders)
and renders it with the badge's own Vue components, down to the same bottom
navigation bar. If the preview looks wrong, the holder's badge is wrong.

**It is a read, and mints nothing.** PocketBase can issue a session for another
record (`NewStaticAuthToken`), but a badge action stamps the **cardholder** as
`actor_id`. An operator driving a borrowed session would write rows that look
like the holder's own, and "did this visitor open the loading bay, or someone
checking on them?" would no longer be answerable from the log.

The preview therefore cannot prove a holder's unlock button works end to end.
It proves what the server would decide, which is where almost every "my badge
is broken" lives. An operator who needs the door opened uses
`POST /api/portals/{id}/grant` with their own `command` capability. Reading a
badge means reading someone's photo, QR payload and every door they hold, so
**every preview writes an `audit_logs` row**.

---

## 5. Presets

The operator-management UI offers **named presets** that tick capability boxes.
They are a UI convenience only: nothing about a preset is stored, so
`permissions` stays the single source of truth. An operator whose set matches
no preset shows as "Custom".

| Preset | Capabilities |
|---|---|
| Read-only | *(none)* |
| Enrollment | `enroll` |
| Command Ops | `command`, `policy` |
| Facilities | `topology` |
| Admin | all five |

---

## 6. The Badge Tier

stone-access has more than one auth collection:

- `users` is the **operator** tier this page describes.
- `_superusers` is the break-glass admin.
- **`cardholders`**, the people the PACS is about, is itself the **badge
  tier**. A cardholder with `badge_login` set can sign in to view their own
  badge and, where permitted, act remotely (unlock a door, arm an area, pulse
  an output).

A cardholder is not an operator. The record holds no `permissions` field and
must never read the policy graph. One row is both the thing a holder
authenticates as and the entry point to the access graph
(cardholder → roles → groups → portals), so a rule that admits a badge token to
the wrong verb is a self-service grant of doors. The badge tier is one
collection, not a separate login record, because a 1:1 login needed a unique
index, a cascade delete, a field guard and a delete hook just to keep the join
coherent. See [`internal/badgeapi`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi/badgeapi.go)'s package
doc.

### Keeping the tiers apart

Three rules keep the badge tier out of the operator tier:

1. **Collection read rules name the collection, not "any auth".** The floor is
   `@request.auth.collectionName = "users"`, not `@request.auth.id != ""`. The
   latter is auth-collection-agnostic: every badge holder would satisfy it and
   read the whole graph, including `credentials`, whose `value` field is the
   credential secret in plaintext. `TestReadFloorExcludesNonOperatorAuth` is
   the regression test. It uses a throwaway auth collection, so the guarantee
   holds for tiers added later.
2. **Custom routes use `authz.RequireOperatorAuth()`, not bare
   `apis.RequireAuth()`.** Bare `RequireAuth()` admits any auth collection.
   `POST /api/simulate` is a **decision oracle** over the entire policy graph,
   so exposing it to the badge tier would be worse than exposing the
   collections. `apis.RequireAuth("users")` alone is also wrong: PocketBase's
   check is plain collection-name membership with no superuser exemption, so it
   would lock out the break-glass account. `RequireOperatorAuth` names both.
3. **Reads are self-scoped; writes exclude the badge tier entirely.**
   `cardholders` is read by
   `id = @request.auth.id || @request.auth.collectionName = "users"`: an
   operator sees everyone, a holder sees exactly their own row.
   Create/update/delete are a bare capability check
   (`@request.auth.permissions ~ "enroll"`, delete `"operators"`) that a
   cardholder, having no `permissions` field, can never satisfy. There is **no
   self clause**.

That asymmetry is the whole boundary, so the collection has no field-level
guard. A PocketBase rule selects which **records** may be written, not which
**fields**. A self-write clause would mean "may edit every non-system field on
my own row", including `roles` (a grant at the reader), `status` (un-suspending
yourself) and `kind` (whether the QR carries a working credential). The tier
cannot write its own record at all. `POST /api/badge/password` is how a holder
changes the one thing they may, and it is an `app.Save` that bypasses
collection rules.

The **self-read** clause is required. PocketBase checks a **protected file**
download against the record's own `ViewRule`, and `cardholders.photo` is
protected, so without it a holder's own badge renders with no face. It also
lets the operator UI show the badge-login field to *any* operator and gate only
the editing.

Nothing in a cardholder row is secret to an operator (the password hash and
token key are system fields the API never serializes), so `enroll` gates
*changing* a login, never seeing one.

### Badge routes

Badge-tier routes live in `internal/badgeapi`. They are gated by the
**`cardholders`** collection, not by capability, and each action is authorized
by the pure decider for what that person's own credential opens right now. A
remote action can never exceed the holder's physical access.

| Route | Who | Purpose |
|---|---|---|
| `GET /api/badge/me` | a badge holder **or an operator** | their own badge: photo, QR, and what it grants |
| `POST /api/badge/unlock/{id}` | a badge holder | remote unlock, authorized by `policy.Decide` |
| `POST /api/badge/areas/{id}/arm` · `/disarm` | a badge holder | arm/disarm, authorized by `policy.DecideArea` |
| `POST /api/badge/outputs/{id}/pulse` | a badge holder | pulse an aux relay, authorized by `policy.DecideOutput` |
| `GET /api/badge/live` | a badge holder | their own doors/controls placed on a site's floor plan |
| `POST /api/badge/password` | a badge holder | set or change their own password |

All of these, and the `cardholders` sign-in endpoints, are rate-limited by
default (migrations `1750000032`/`1750000039`/`1750000041`). The operator-only
preview is not. The numbers are in
[Configuration Reference](configuration.md#9-rate-limits).

`/api/badge/me` is the **only** one an operator token may call. It resolves
through `cardholders.operator` (migration `1750000040`), so one person with
accounts in both tiers can see their own badge from the console's profile menu
without a second sign-in. Everything that *actuates* names `cardholders` alone.
An operator opening a door uses `POST /api/portals/{id}/grant` with their
`command` capability, where it is audited as an operator action, so the audit
trail is never ambiguous about which authority they used.

Every badge action, allowed or denied, writes an `audit_logs` row. A **denied**
remote unlock also emits an ordinary `evt.tap` with `allow: false` and
`source: badge`, so it lands in `events` beside a denial at a reader. An
allowed one is the existing `cmd.grant` (actor `badge:<cardholderId>`),
recorded by the controller's own tap event.

Each badge action also has a **per-record opt-in**, all default false and all
control-plane only (never mirrored to KV): `portals.allow_remote_unlock`,
`areas.allow_remote_arm`, `aux_output.allow_remote` and
`locations.badge_floorplan`. None of them widens anything, since the pure
decider still has to grant the action. They separate "may act here" from "may
act from anywhere, with nobody present", and for the floor plan, "may open a
door here" from "may see the layout of the building".

The badge shows these as **one bottom navigation bar**: Badge (the face: photo
and QR), then Plan, Portals, Areas, Controls, On site. It is **adaptive**. The
face is always there, and every other screen appears only if that badge has
something in it, so the common badge is Badge + Plan or Badge + Portals. A badge
that grants nothing gets a single Access screen saying so. It is not a copy of
the operator's Live View, which has fixed segments because an operator hunts
through hundreds of points, while a holder typically has a handful of doors and
no areas or controls. It shows no live hardware state: an area's chip is the
policy *intent* the server resolved, and door open/closed never appears.
Watching a building is the console's job.

### Issuing a badge login

The two kinds of badge come from different flows:

| | **Visitor** | **Staff holder** |
|---|---|---|
| Where | **Cardholders → Visitor Pass** | **Cardholder form → Badge login** (a checkbox) |
| Route | `POST /api/badge/visitors` | none; it is a field update |
| Creates | the person + a time-bound credential, in one transaction | nothing; the person already exists |
| Access from | a curated `visitor_preset` role, chosen at mint | the roles already on that cardholder |
| QR encodes | the credential value (works at a scanner) | the cardholder id (opens nothing) |
| Usual sign-in | emailed one-time code | password |
| Extending it | **Reissue**: a new pass, the old code revoked | issue or extend a credential |
| Ending it | **Revoke** (pass dies, person kept) or **Delete** (both) | untick the checkbox; the credential is untouched |

**One page, one filter.** Only minting is a separate flow. After that a
visitor is an ordinary row on **Cardholders**, under its **Visitors** filter
(server-side on `kind`, remembered per browser, defaulting to **Permanent** so a
lobby of guests does not bury the roster). Their page is the cardholder page,
which adds the pass state, its window and the visit actions when
`kind = "visitor"`. Search spans every kind whatever the filter shows, and says
how many matches it is hiding. The pass-state chips are the one thing scoped to
the Visitors filter: a state comes from the newest of a person's credentials, a
row in another collection, so it narrows the loaded page rather than the query.
That is sound on 50 newest-first visits and misleading on a name-sorted roster
of thousands.

**Reissue, not extend.** A visitor's QR carries the credential *value*, a
working key on a screen for hours, so it gets photographed and forwarded.
Pushing that value's `valid_until` out would silently re-arm every copy.
Extending a visit goes through `POST /api/badge/visitors` again: the route
recognizes the returning visitor by email and refreshes them in place
(`reused: true`), minting a new value from the server's CSPRNG and revoking the
previous one, in one transaction. It costs the visitor one refresh of their
badge.

**With no mail server, set an initial password.** A visitor's default way in is
an emailed one-time code, and password reset is also an email, so without SMTP
a minted pass cannot be opened. Both flows accept an optional initial password
(`password` on the mint request; the Badge login section of the cardholder form
for staff). It is handed over at the desk and **never** emailed. The mint
success screen also shows the badge link and a QR of it; both are safe to show,
because the link carries no code and no token.

Enrollment does **not** grant a staff badge login. Most cardholders never need
one, and a login on everyone would put a phone-openable surface on people who
only ever tap a card. It is one checkbox on the person's own form, because it
is one **field** on that person: `badge_login`, which backs the collection's
auth rule.

Every cardholder is an auth record, including the majority who never sign in.
An auth record is not an account. A record without `badge_login` fails the
collection's auth rule, and carries a random password nobody has seen
(PocketBase requires a non-blank one;
[`badgeapi.RegisterGuards`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi/guards.go) fills it). A
cardholder with **no email** (a contractor, an hourly worker, a "Loading Dock
Spare" card) cannot sign in by any method, since email is the only identity
field and the only way an emailed code can arrive. So `bindLoginRequiresEmail`
refuses to save `badge_login` on a record with no email, on create and on
update, so clearing the address later is refused too.

**For a staff holder, a badge login is not access.** It controls who may *see*
a badge and use remote actions. Their credentials work at every door they are
entitled to whether or not a login exists, and removing a login revokes
nothing. To revoke access, set `credentials.status = revoked` or suspend the
cardholder; that is what propagates through the mirror to the edge. Giving a
login and taking it back are the same act, so both are `enroll`.

**End a visit with Revoke, not Delete.** Revoke kills the pass and keeps the
person, so the visit stays on the record and a returning visitor is recognized
rather than duplicated. Delete removes the person *and their credentials*:
`credentials.user` cascades
([`1750000036`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000036_credential_cascade.go)), because a
credential outliving its holder is a key that opens doors and resolves to
nobody. The cascade runs through the ordinary delete path, so the KV mirror
prunes those `cred.{value}` keys and cannot leave a working key at the edge.
[`internal/badgesweep`](https://github.com/stone-age-io/access-control/blob/main/internal/badgesweep) finds expired visitor passes by
querying `cardholders` where `kind = 'visitor'`.

**A login with no credential** signs in and reports that no pass has been
issued. Roles and effective access are not enough on their own. The cardholder
page says so where the fix is one click away.

### Sign-in methods

All three are enabled on `cardholders`
([`1750000000`](https://github.com/stone-age-io/access-control/blob/main/pbmigrations/1750000000_collections.go)):

| Method | For | Needs SMTP |
|---|---|---|
| **Password** (email + password) | staff holders, who sign in for years | no |
| **One-time code** (emailed) | visitors; anyone who has not set a password | **yes** |
| **OAuth2** | staff with an existing identity; providers are configured in the PocketBase admin | no |

::: warning Without SMTP, a password is the only way in
OTP and the forgot-password link are both emails. On an install with no mail
server, set an initial password and hand it over in person, or the badge tier
is inert. Both issuing paths have a field for it: the cardholder form for a
staff holder, and **Initial password** on the visitor mint form. The visitor
path needs it most, because a visitor's only other way in is an emailed code.
:::

Both tiers share **one sign-in page** at `/login`, with an explicit two-way
selector (*My badge* / *Operator*). It is deep-linkable as `?as=badge` (what
the invite mail links to) and remembered per browser, so a lobby tablet and an
operator's laptop each land on the right form. The choice is explicit, not
guessed from the address, because one person can hold an account in **both**
tiers: the guard who badges in and also runs the console. Guessing would sign
them in to the wrong privilege domain, split their failed attempts across two
rate-limit buckets, and leak which tier an address belongs to. There are two
entries, not three: a visitor and a staff cardholder are the same collection,
so a visitor never has to know they are a "visitor".

::: note A first OTP does not wipe the password
On a *first* successful one-time code, PocketBase marks the record verified
and, unless MFA is on, **randomizes its password** to defend against account
pre-hijacking on an open-signup collection. That defence does not apply here
(only an `enroll` operator can create a cardholder, so there is no
attacker-authored record to disarm), and it would destroy the operator-set
password an SMTP-less install depends on. `bindOTPPasswordPreservation` in
[`internal/badgeapi`](https://github.com/stone-age-io/access-control/blob/main/internal/badgeapi/guards.go) marks such a record
verified before that branch runs, which skips it.
:::

An initial password is **optional and never emailed**: mail is stored
indefinitely, forwarded and synced to devices, so a door-opening password sent
by mail would outlive every other control around it. The invite mail says only
*where* to sign in.

A holder sets or changes their own password from the badge page, under the
account menu in its header. The `password_set` flag records whether they have
one, which decides whether the current password must be supplied:

- A holder who signed in by one-time code is setting a *first* password and has
  nothing to prove.
- A holder who already has a password must supply it, so a stolen session
  cannot silently lock them out of their own badge.

Setting a password from the cardholder form replaces the existing one. That is
the operator's path for someone who is locked out and has no working mail.
**Changing a password signs out every device**, including the one making the
change, because PocketBase rotates the record's token key. The badge UI
re-authenticates silently, so this is visible only on a holder's other phones.

---

## 7. Privilege-Escalation Guard

Changing a user's `permissions` is gated beyond the `users` update rule. A hook
in [`internal/changelog`](https://github.com/stone-age-io/access-control/blob/main/internal/changelog/changelog.go) rejects any update
that alters `permissions` unless the actor is a superuser or holds the
`operators` capability. An operator who can edit their own profile (self-update
is allowed) still cannot grant themselves new capabilities. `permissions` is
the only guarded field. The rest of an operator's own row, including the
notification opt-ins `notify`/`notify_locations`/`notify_types` (see
[Configuration Reference](configuration.md#8-notifications)), stays
self-editable.

---

## 8. Control-Plane Audit Log (`audit_logs`)

[`internal/changelog`](https://github.com/stone-age-io/access-control/blob/main/internal/changelog/changelog.go) records every
operator edit to a policy record in the **`audit_logs`** collection. It is the
operator-edit counterpart to [`internal/audit`](https://github.com/stone-age-io/access-control/blob/main/internal/audit), which
records *door* activity from JetStream into `events`. The two are complementary
and disjoint.

**What is recorded.** API-driven create, update and delete on the audited
collections: `cardholders`, `credentials`, `holidays`, `holiday_calendars`,
`locations`, `schedules`, `controllers`, `portals`, `access_groups`, `roles`,
`aux_input`, `aux_output`, `areas`, `users`. Plus operator **logins** (auth
events on `users`). Superuser logins and badge-tier sign-ins on `cardholders`
are not recorded. `TestAuditedCoversControlPlane` fails if a control-plane
collection is added and left off this list.

**What is excluded.** The hooks are PocketBase `*Request` hooks, which fire
only for **API-driven** operations. accessd's own programmatic `app.Save()`
writes (controller heartbeats, the `events`/`point_status` projections, the KV
mirror) never trigger them, so machine churn is excluded without an allowlist.
`events`, `point_status` and `audit_logs` itself are also excluded.
`controllers` is safe to audit because heartbeat updates take the programmatic
path, not the API.

**Rows written outside the hooks.** Because programmatic writes are invisible
to the hooks, accessd's custom routes and the entry-disarm sink write their own
rows. All have `event_type` `update` (the visitor mint is `create`), with the
route in `request_url`:

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
| `before`, `after` | full field snapshots (JSON); **`password` and `tokenKey` are stripped** |

**Fail-safe and non-blocking.** The audited operation has already committed
before the row is written, so an audit-write failure is logged and swallowed,
never returned to the operator.

**Retention.** When `accessd.auditRetentionDays` is positive, a daily 03:00
cron deletes rows older than that many days, at most 1000 per run. That is
ample for a change log; unlike the high-volume `events` prune, it does not
drain a backlog. Leaving the key out gives **365**. Set it to `0` or a negative
value to disable pruning and keep audit history forever. See
[Configuration Reference](configuration.md#7-accessd).

---

## 9. Where to Go Next

- What the central service runs and owns: [Central Service (accessd)](accessd.md)
- The data-plane decision, subjects and command bodies: [Wire Protocol](protocol.md)
- Rate limits, notifications and retention settings: [Configuration Reference](configuration.md)
- Controllers, readers and wiring: [Hardware & Readers](hardware.md)
- What the system is and how to run it: [Access Control](../README.md)
