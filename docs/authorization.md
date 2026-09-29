---
path: platform/authorization
nav_order: 80
---
# Authorization & Roles

This page is the reference for who can do what in Stone-Age.io. Other pages
link here.

**The PocketBase API rules** in the platform's `schema.json` are the only
permission layer. `pb-nats` and `pb-nebula` have no tenancy logic. They never
reference `organization`.

One server-side hook enforces an **invariant**, not a permission.
`hooks/relation_tenancy.go` refuses any relation that points into another
organization's records.

- No rule can express this. A rule follows a stored field, but a relation id in
  a request body is a plain string with nothing to follow.
- Without the hook, an owner could name another tenant's `account_id`, and
  pb-nats would sign a credential inside that tenant's account.
- The hook reads the relations from the schema. It runs on model saves, so it
  covers server-side saves and REST. It also applies to SuperUsers, because a
  cross-tenant relation is corrupt data whoever writes it.
- It answers "may this record point there", never "may this caller act".

The console's capability map (`can.*` in `ui/src/stores/auth.ts`) only decides
which menu items and buttons appear. It is **not a security boundary**. The
[`stone` CLI](./stone-cli.md) is also only a client of the same rules.

> To know whether a role can do something, read the collection's API rules, not the console. A hidden button is still a reachable endpoint for anyone with a token.

---

## 1. The Five Tenant Roles

Roles are on `memberships.role`, the record that links a User to an
Organization. A user in three organizations has three memberships and can have
a different role in each.

| Role | What it is |
| :--- | :--- |
| `owner` | Full tenant authority. The same as `admin` in every API rule. |
| `admin` | Full tenant authority. |
| `member` | Manages inventory: creates and edits Things and Locations, reads contracts, has its own NATS credential. Cannot read or write infrastructure collections. |
| `viewer` | Read-only staff. Inventory screens and dashboards, no writes. Has its own NATS credential. |
| `dashboard` | A login for an unattended screen. The Visualizer at `/` and its own `/settings`, nothing else. No write capability. |

`invites.role` offers every role except `owner`. Invitations do not create
owners.

> **`viewer` and `dashboard` do not limit NATS.** What a login can do on the bus comes from its linked `nats_users` role, which is set separately. A `dashboard` screen can hold a NATS credential that publishes anywhere its role allows.

> **`owner` and `admin` are identical.** Every API rule allows both. The one difference is that an owner cannot leave their own organization, which is a console check, not a rule. Neither can delete the organization, because that is Platform-Operator-only (§3). **`admin` is not a lesser grant.** It gives full tenant authority, including every collection that holds credentials.

> **Write allowlists, never deny-lists.** Rules name the roles that are allowed (`role ?= "owner" || role ?= "admin"`). A deny-list such as `role ?!= "member"` also lets `dashboard` through, which is the least privileged role. Copy the standard snippet from a nearby rule.
>
> A write branch that limits *which fields* can be written must also name *which roles* can write. Every write branch names its roles.

> **A new read-only role needs no rule change.** A role that no write branch names is denied every write. If you must edit a rule to keep a new read-only role *out*, that rule is a deny-list, and the rule is the bug.

> **Keep `viewer` and `dashboard` separate.** `dashboard` has no capability, so it is the only role that can prove an allowlist works. `viewer` can read, so a denial it gets proves less. The authorization test suite uses `dashboard` for this.

---

## 2. Capability Matrix

"—" means the API rules reject the operation, not only that the console hides it.

| Capability | Owner | Admin | Member | Viewer | Dashboard | Platform Operator¹ | SuperUser² |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| Read Things and Locations | ✅ | ✅ | ✅ | ✅ | ✅³ | — | ✅ |
| Create / edit Things and Locations | ✅ | ✅ | ✅ | — | — | — | ✅ |
| Delete a Thing or Location | ✅ | ✅ | — | — | — | — | ✅ |
| Deactivate / reactivate a Thing (§4.2) | ✅ | ✅ | — | — | — | — | ✅ |
| Reset a Thing's PocketBase password | ✅ | ✅ | — | — | — | — | ✅ |
| Attach a NATS user / Nebula host to a Thing | ✅ | ✅ | — | — | — | — | ✅ |
| Read Thing Types, Operations | ✅ | ✅ | ✅ | ✅ | ✅³ | — | ✅ |
| Manage Thing Types, Operations | ✅ | ✅ | — | — | — | — | ✅ |
| **Read** NATS users, roles, imports, exports | ✅ | ✅ | — | — | — | — | ✅ |
| Manage NATS users, roles, imports, exports | ✅ | ✅ | — | — | — | — | ✅ |
| **Read** Nebula networks and hosts | ✅ | ✅ | — | — | — | — | ✅ |
| Manage Nebula networks and hosts | ✅ | ✅ | — | — | — | — | ✅ |
| Read the org's NATS Account and Nebula CA | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Edit the NATS Account or Nebula CA record directly | — | — | — | — | — | ✅ | ✅ |
| Manage the account's signing keys (§4.1)⁶ | ✅ | ✅ | — | — | — | ✅ | ✅ |
| Read own linked NATS identity | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| Clear own membership's NATS identity link | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| Choose which NATS identity a membership links to (§4) | ✅ | ✅ | — | — | — | — | ✅ |
| Rotate own NATS credential (§4)⁸ | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| Revoke-and-replace, suspend or reactivate a NATS identity | ✅ | ✅ | — | — | — | — | ✅ |
| Manage JetStream streams and KV buckets⁴ | ✅ | ✅ | — | — | — | — | — |
| Use dashboards | ✅ | ✅ | ✅ | ✅ | ✅⁷ | — | ✅ |
| Invite users, manage memberships | ✅ | ✅ | — | — | — | invites only | ✅ |
| Create / edit an Organization record | — | — | — | — | — | ✅ | ✅ |
| Suspend / reactivate an Organization (§3.1)⁵ | — | — | — | — | — | ✅ | ✅ |
| Delete an Organization | — | — | — | — | — | ✅ | ✅ |
| Read the org's activity feed (§5.2) | ✅ | ✅ | ✅ | ✅ | ✅⁹ | — | ✅ |
| Read the audit log (§5.1) | — | — | — | — | — | ✅ | ✅ |
| Schema imports, NATS Operator key custody | — | — | — | — | — | — | ✅ |

¹ **Platform Operator:** `users.is_operator = true`, a flag on the user account, separate from any Membership. See §3.

² The `_superusers` collection ignores API rules. See §3.

³ **Reads are scoped by organization, not by role.** The read rules on `things`, `locations`, `thing_types`, `location_types` and `thing_type_operations` require a non-blank active organization, `organization = current_organization`, and a membership in that organization. They have no role branch. So *every* role in an organization, `dashboard` included, can `curl` the whole inventory. Roles differ in writes and in which screens the console shows. The console limits `dashboard` to the Visualizer, and shows the Types screens only to owners and admins. **That is navigation, not a boundary.** To make a real read boundary, you would need a role branch in `schema.json` on every one of those collections, and relation expansions could then silently return nothing.

⁴ JetStream operations use the browser's own NATS connection, so the caller's **NATS** permissions limit them, not the API rules. The console shows these views to owners and admins. An *account's* total storage has a separate limit: `max_jetstream_disk_storage` and `max_jetstream_memory_storage` in `nats.default_limits`, applied when the account is provisioned. See [Configuration](./configuration.md#2-section-reference).

⁵ `organizations.active`, copied onto the organization's NATS account. The operator and system organizations refuse the change. See §3.1.

⁶ Through `POST /api/org/nats-account/keys`, not a record edit. `nats_accounts.updateRule` and `nebula_ca.updateRule` are both Platform-Operator-only. Rolling a Nebula CA is also a route, and owners and admins can use it: `POST /api/org/nebula-ca/rotate` (§4.3).

⁷ Dashboards are the only screen `dashboard` can open.

⁸ Refused with `403` while the identity is suspended (`active = false`). See §4.

⁹ The API rule allows every role. The console's `/activity` screen is not shown to `dashboard`.

**Lower roles get an empty list, not a filtered one.** For `nats_users`,
`nats_roles`, `nats_account_exports`, `nats_account_imports`,
`nebula_networks` and `nebula_hosts`, the `listRule` requires owner or admin. A
member, viewer or dashboard holder gets zero records, except for the one row in
§4.

> **The membership clause is what keeps reads safe.** Every org-scoped read rule requires a non-blank `users.current_organization` **and** a membership in that organization.
>
> `current_organization` alone is not enough. Both sides of `organization = current_organization` are text that defaults to `''`, and in PocketBase `'' = ''` is true. A record with a blank organization would then be readable by any caller with a blank context. `memberships.organization` is required and cascades, so it is never blank.
>
> When a membership is deleted, the reads stop at once. `hooks/membership_lifecycle.go` also clears `current_organization` as a second safeguard.
>
> **For every rule, ask "what does this do when both sides are the zero value?"**, not only "does it name the right roles?".

---

## 3. Cross-Organization Identities

Two identities are outside the Membership model.

**Platform Operator** (`users.is_operator = true`) is a user account with
platform-administration authority. It creates and edits Organization records
and can invite users into any org. Without a Membership in an org, a Platform
Operator cannot read that org's tenant data. Membership grants tenant-data
access. The flag grants org management.

**SuperUser** (the `_superusers` collection) is a service account that ignores
API rules. Use it for infrastructure work: schema imports, NATS Operator key
custody and troubleshooting. It signs in at the admin UI (`/_/`). SuperUsers are
not members of any organization.

> **The API cannot grant Platform Operator status.** Only the `bootstrap` command and the admin panel can, and both ignore API rules. `users.updateRule` refuses `is_operator` on your own record. Both branches of `users.createRule` refuse it on a new record, including the branch that lets a Platform Operator onboard users. So an operator cannot create another operator over REST. See [Getting Started §2](./getting-started.md#2-initialize-the-control-plane).

### The organization record is Platform Operator territory

`organizations.updateRule` is `@request.auth.is_operator = true`, with a freeze
on `code` that also applies to operators (see
[ADR 0002](./decisions/0002-organization-code-namespace.md)). Only a SuperUser
can fix a code typo. **No tenant role, not even `owner`, can edit the
organization record.** The record holds the tenancy flags (`managed`,
`is_operator_org`, `is_system_org`) and drives NATS Account and Nebula CA
provisioning. `organizations.createRule` is also Platform-Operator-only.

**Only a Platform Operator can delete an organization.** Most relations into
`organizations` are not cascade and not required. When an organization is
deleted, PocketBase **blanks** the `organization` field on every Thing,
Location, NATS account and Nebula CA that pointed at it. Those records become
orphans, and with the blank-matches-blank read in §2 they would be readable
across tenants. To take a tenant off the bus without deleting anything, suspend
it (§3.1).

### 3.1 Suspending an organization

Only a Platform Operator can change `organizations.active`. It does one thing:
**it withdraws the organization's NATS account.**

`hooks/org_active_flag.go` copies the flag onto the account record's own
`active` field, which is pb-nats's account-level suspend. Clearing it deletes
the account claim from the resolver. Every device, edge agent and browser in the
tenant disconnects at once, and the account stays withdrawn across restarts.

- **It is reversible.** It deletes the *account* claim only. It adds no
  revocation, changes no `nats_users` row and re-mints nothing. Every `.creds`
  file stays valid and reconnects when the flag is set again. Compare §4.2,
  where a device's revocation is permanent and it needs a new credential.
- **It is narrow.** It does **not** change Nebula, because a blocklist applies
  only on redeploy, and removing it rewrites every peer config. It does **not**
  lock the console: a suspended tenant still signs in and reads its records. It
  does not end any Thing's auth tokens. A screen that shows the state should say
  both of these.
- **While suspended, you cannot mint a NATS identity.** `POST /api/org/things`
  with `nats.mode: "auto"` returns `400` ("no active NATS account for this
  organization").
- **The operator and system organizations refuse the change.** Withdrawing the
  operator organization's account would disconnect the hub that every managed
  tenant imports through.

The hook applies the current flag value on every save, so to retry a failed
withdrawal, save the organization again.

---

## 4. The Row-Scoped Credential Model

`nats_users.creds_file` holds the user seed, and `nebula_hosts.config_yaml`
holds the host key. Both stay **readable**, because their owner needs them. The
browser opens its NATS connection with them, and the console's download button
gives a user a `.creds` file. The rules limit **which rows a caller sees**.
Edge boxes read only the rows linked to themselves, and get everything else
from the route in §6.

So `nats_users` has one exception to the owner/admin-only rule: **a user of any
role, including `dashboard`, can read the one `nats_users` row linked to their
own membership in the active organization.** Their browser authenticates with
that credential. A Thing can read only the NATS user and Nebula host assigned
to it.

**Only an owner or admin can choose which identity a membership links to.**
The read follows the link, so whoever sets the link can read the credential. On
their own membership, every role can keep the link or clear it. A change to a
different identity is refused unless the caller is an owner or admin.

Every `nats_users` id in the organization is visible in `things.nats_user`. If
any role could choose freely, a `dashboard` login could link itself to a
gateway's identity, or the owner's, and read that seed. `relation_tenancy` does
not catch this, because the target is in the *same* organization. In Settings,
the console offers a member only the identity already linked to them.

> **This is row scoping, not field hiding.** Hiding `creds_file` or `config_yaml` would break the browser's NATS connection and the download button. The read rules already limit each caller to their own row.

### Self-service rotation

```
POST /api/me/nats-creds/rotate
```

**Every role, including `dashboard`**, can call it, from the `users` and
`things` collections. It takes **no id**. It always targets the caller's own
linked identity. It returns the identity's id. Read that record again to get
the new credential.

It is a route, not a rule branch, because **an API rule cannot allow only one
field**. To allow self-rotation in the update rule, you would have to assert
`:isset = false` on every *other* writable field. That is a deny-list, and it
opens silently when someone adds a field. The field that must stay closed is
important: the platform copies `nats_users.publish_permissions` **exactly**
into the JWT it signs. Write access to that collection is the same as granting
NATS permissions, so it is owner/admin only.

**A suspended identity cannot rotate. The route returns `403`.** A new
credential would have a JWT issued *after* the account's revocation cutoff, and
NATS would accept it, so the rotation would end the suspension. Owners and
admins suspend and reactivate through the normal update rule. Deactivating the
device that holds the identity also suspends it (§4.2).

### 4.1 Account signing keys

`nats_accounts.updateRule` is **Platform-Operator-only**. The record has some
fields a tenant may change and some it must not, such as the account limits it
bought and the signed account `jwt`. An owner or admin manages signing keys
through a route:

```
POST /api/org/nats-account/keys      { "action": "rotate" | "add_signing" | "remove_signing" }
```

| Action | Effect |
| :--- | :--- |
| `add_signing` | Routine rotation: adds a new signing key. Existing user JWTs stay valid. |
| `remove_signing` | Removes one key by `public_key`. You cannot remove the last key. |
| `rotate` | **Emergency replacement:** deletes every signing key and generates one. Every user JWT in the account stops validating and must be minted again. |

It takes no record id. The account comes from the caller's active
organization, so it cannot target another tenant. Each action writes one
field. Use `add_signing` for routine rotation. Use `rotate` only if you suspect
a key is compromised.

`nebula_ca.updateRule` is also Platform-Operator-only, because the record holds
the trust anchor for the organization's whole mesh. Owners and admins roll a
CA through a route (§4.3).

### 4.2 Taking a device out of service

Only an Owner or Admin can change `things.active`. Clearing it **decommissions**
the device. Four things happen in the same operation:

| | What it stops |
| :--- | :--- |
| The collection's `authRule` (`active = true`) | New sign-ins. The device cannot get another token. |
| A new `tokenKey` | Every token the device **already holds**, immediately. |
| `active = false` on the linked `nats_users` row | The signed NATS credential. pb-nats revokes the public key on the account and issues nothing new, so the device stops publishing. |
| `active = false` on the linked `nebula_hosts` row | The mesh certificate. pb-nebula adds its fingerprint to the `pki.blocklist` of every host under the same CA. Nebula has no CRL, so this applies as each peer's config is redeployed. |

All four are necessary:

> **An `authRule` runs only at the authentication endpoint.** It does not run on a request that carries a token issued earlier. Thing tokens last **7 days**. With only `active = false`, a decommissioned device would keep a working API session for up to a week. The new `tokenKey` closes that gap, which is why deactivation is a server-side hook and not only a rule.

A device's real capability is its credentials, not its PocketBase session. If
you block API access but not the NATS identity, the device still publishes. If
you block NATS but not Nebula, it stays on the mesh. A device can hold either
identity, both or neither, so each cascade runs on its own.

**Deactivation sets `active`, never `revoke`.** In pb-nats, `revoke` is for
leaked credentials. It generates a **new** key pair, puts the old public key on
the account's revocation list, and returns a *working* replacement. The identity
stays active. `active = false` is the suspend: revoke, and issue nothing.

**Deactivate, do not delete.** A Thing delete does not cascade to either
identity. Its NATS credential keeps working and its Nebula certificate stays
trusted. After a delete, the certificate can no longer be added to a blocklist.

**Reactivating issues a *new* NATS credential.** The revocation cutoff in the
account JWT is permanent, so the old `.creds` file stays rejected. The device's
platform token ended with the `tokenKey`, so its Agent must sign in again before
it can fetch anything. See [Agent §2.2](./agent.md#22-removing-the-password)
for a device whose password was removed.

For a device, use `things.active`, which moves the NATS identity, the Nebula
host and the session together. The NATS user's detail view also has **Revoke**
(replace leaked credentials, stay active) and **Re-enable** (reactivate a
suspended identity with a new `.creds`). On the NATS user, `active` is a real
control: true to false revokes and issues nothing, and false to true mints a
credential issued after the cutoff.

### 4.3 Rolling a Nebula CA

```
POST /api/org/nebula-ca/rotate       { "step": "prepare" | "commit" | "finish" }
```

An **Owner or Admin of the CA's own organization** can call it. The console
shows it as a three-step panel on the Nebula CA detail view. It takes no record
id: the CA comes from the caller's active organization. The route allows the
three steps, and `pb-nebula` checks each *transition*.

The tenant controls this, because the risky part of a CA roll is the **wait**
between steps. Only whoever operates the devices knows when the fleet has
caught up.

| Step | What it does | Reversible |
| :--- | :--- | :--- |
| `prepare` | Publishes the new CA as *trusted*. Issuance does not change. | Yes, fully. |
| `commit` | Moves issuance to the new CA and re-signs every active host. | The old CA is still trusted. |
| `finish` | Removes the old CA. **Refused** while any active host still has a certificate signed by it. | No. |

**It takes three steps because Nebula checks certificates in both directions and
hosts pull their config.** If one write changed the trust bundle and the
certificate together, the mesh would split until every host fetched it. A host
with the new certificate would meet a host that still trusts only the old CA,
and the handshake would fail both ways. `prepare` makes the new trust reach
every host before issuance moves.

::: note Why a route and not an owner branch on the update rule
A rule branch that allowed rotation would have to deny every other field on
`nebula_ca`, and it would silently allow each field added later. That is a
deny-list, on the record that holds the trust anchor for a tenant's whole mesh.
See §7.
:::

---

## 5. Two Histories: The Audit Log and the Activity Feed

There are **two** records of who changed what. They differ in who can read them
and what they contain.

| | `audit_logs` | `activity` |
| :--- | :--- | :--- |
| Who can read it | Platform Operator / SuperUser only | **every role** in the organization |
| Scope | the whole deployment, no `organization` column | one organization |
| What it records | the names of the fields each write changed. Old and new **values** only for an allowlist of collections that hold no credential. | actor, action, record, time and a label snapshot. **No values.** |
| Console route | `/audit` | `/activity` |
| Purpose | the forensic record | "who on my team changed this device, and when" |

### 5.1 `audit_logs` is Platform-Operator-only

`audit_logs` list and view are `@request.auth.is_operator = true`. **No tenant
role, `owner` included, can read the audit log.** The console's `/audit` route
uses the same check. Nobody can create, update or delete entries. The platform
writes them. Set retention with `audit.retention`. See
[Configuration §2](./configuration.md#2-section-reference).

**Values are kept only for listed collections.** Every event records
`changed_fields`, the *names* of the changed fields. Old and new values are kept
only for the collections in `auditSnapshotCollections` (`main.go`):
organizations, memberships, users, the five inventory collections,
`nats_roles`, `nebula_networks` and email templates. The others (`nats_users`,
`nebula_hosts`, `nats_accounts`, `nebula_ca`, `invites`, and account exports
and imports) record field names only.

The reason is the credential model in §4. **Row scoping** protects
`creds_file` and `config_yaml`, and a flat log with copies of records has no
rows to scope. A test fails if a listed collection has a credential field that
is not hidden. For anything new, ask **"does anything copy this record to a
place the row rules do not reach?"**, not only "is this field hidden?".

For the same reason, you cannot simply open the log to tenants. A read on
`audit_logs` exposes every snapshot collection at once. For example,
`nats_roles` values are publish and subscribe permission sets. Scoping the log
by organization would not help, because the snapshots are still there.

### 5.2 `activity` is tenant-facing, and carries no values

`activity` names the actor, the action and the record, and stores **no record
values**. Every role in the organization can read it through the API,
`dashboard` included. The console's `/activity` screen is shown to every role
except `dashboard`.

**Rule: an entry is visible only to those who could read the record it
describes.** A flat collection that copies other collections does not inherit
their scoping. So the feed covers only the five tenant collections whose reads
are org-scoped with no role branch: `things`, `locations`, `thing_types`,
`location_types` and `thing_type_operations`. It does **not** cover
memberships, invites, `nats_roles` or `nebula_networks`, which only owners and
admins can read. Adding a collection to the feed is an authorization change,
and a test enforces this.

It is **append-only**. All three write rules are nil, so nobody, tenant or
operator, can forge or change an entry through the API. `actor` is plain text,
not a relation, so a user delete does not remove attribution. As a result, the
stored label is a **snapshot**. A record renamed later shows its old name.

In the CLI, use `stone activity ls` (see [stone CLI](./stone-cli.md)).
`--filter 'resource_id="<id>"'` shows who changed one device.

A tenant admin cannot export the *audit* log, and a request for old and new
values goes through a Platform Operator. A tenant can see who changed a record,
and when, without one.

---

## 6. Gateways and the Edge

**A site gateway is a Thing.** There is no gateway flag, on `things` or on
[`thing_types`](./thing-types.md), because nothing would read one (see
[Leaf Nodes §1](./leaf-nodes.md#1-there-is-no-gateway-flag)). A gateway can
read what any Thing can read: its own record, its one linked NATS identity and
its one linked Nebula host. It can read **no inventory collection**, because
only `users` sessions can read other Things, Locations and types. It can read
nothing else in `nats_*` or `nebula_*`.

An edge box cannot compute some values locally: the org's account JWT and
public key, the NATS Operator JWT, and the `$SYS` account JWT and public key. A
dedicated route supplies them:

```
GET /api/me/leaf-config
```

It is bound to `things` and takes **no record id**. It targets the caller's own
record, like `POST /api/me/nats-creds/rotate`. It returns ten named fields:
`code`, `domain`, `creds`, `account_jwt`, `account_pub`, `operator_jwt`,
`sys_account_jwt`, `sys_account_pub`, `hub_leaf_url` and `hub_domain`.

The server reads the secret collections with its own privileges and returns
named fields, never whole records. So **a device identity never gets access to
the secret collections**. A leaked edge credential exposes those ten values,
whatever the collection rules become later.

**The route has no permission check, on purpose.** Everything it returns is
public trust material or the caller's own credential. Every server in the
network already validates the Operator, account and `$SYS` account JWTs. The
caller must already hold its credential to connect at all. A Thing that never
runs a leaf node learns nothing new from it. A permission check here would guard
data that is not secret, and it would need the gateway flag that
[Leaf Nodes §1](./leaf-nodes.md) explains is absent.

::: note Why the `$SYS` **account** JWT is safe to serve
The NATS Operator JWT names a system account. The leaf's `resolver: MEMORY`
cannot fetch it, so without the `$SYS` account JWT preloaded, `nats-server`
stops with `error resolving system account` before JetStream starts. Preloading
it grants nothing. To connect **as** `$SYS` you need a `$SYS` **user**
credential, and the platform never serves one.
:::

This path never serves account **seeds** or signing keys, and only superusers
can read `nats_system_operator`.

**Do not add a device read branch** to `nats_users` or `nats_accounts` for an
edge feature. Extend the route. The route keeps the edge's exposure to a fixed
list of named fields, not to rules that change for other reasons.

To take a site out of service, clear `active` on its Thing (§4.2), like any
other device.

---

## 7. Changing the Rules

Check these every time an API rule changes.

- **Existing deployments get a schema or rule change only from a new
  `migrations/schema_update_*.go` file.** An edit to `schema.json` alone
  affects **new databases only**. An upgraded production deployment keeps its
  old rules. This is the most common way a security fix fails to ship.
- **A new column that a rule reads needs a backfill in the same migration.**
  PocketBase booleans have no schema default, so a new `active` field is
  `false` on every existing row. An `authRule: "active = true"` without an
  `UPDATE` would lock every provisioned device out of the API at the next
  restart. Test the upgrade on a database with rows, not only on a new one.
- **Run `./scripts/test-authz.sh` after any rule change, and add a check.** It
  builds the binary, creates a throwaway database, and tests every
  authorization behaviour it covers against a live server.
  - `EXPECTED_CHECKS` at the top of the script holds the check count, so a suite
    that stops early fails.
  - The rules are the platform's only permission enforcement, and nothing else
    checks them.
  - Pair every "cannot" with a "can" on the same record. Otherwise a blanket
    deny passes the suite.
  - PocketBase returns **404**, not 403, when an update rule rejects.

Keep the console's capability map (`ui/src/stores/auth.ts`) and the router's
`meta.requiresCapability` guards the same as the matrix in §2. They enforce
nothing, but a menu that offers an action the rules reject is a bug.

---

## 8. Where to Go Next

- The records these rules protect: [Platform Entities & UI](./platform-ui-entities.md)
- Every route on this page: [API Reference](./api-reference.md)
- The same rules from the terminal: [Stone CLI](./stone-cli.md)
- The edge identity model: [Leaf Nodes](./leaf-nodes.md)
- NATS roles and permissions: [Connectivity](./connectivity.md)
- Creating the first Platform Operator and SuperUser: [Getting Started](./getting-started.md)
- Audit retention: [Configuration Reference](./configuration.md)
