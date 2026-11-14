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
| `member` | Manages inventory: creates and edits Things and Locations, reads contracts, has its own NATS credential. Cannot read or write the NATS and Nebula infrastructure collections, apart from reading the org's NATS Account and Nebula CA and its own linked NATS identity. |
| `viewer` | Read-only staff. Inventory screens and dashboards, no writes. Has its own NATS credential. |
| `dashboard` | A login for an unattended screen. The Visualizer at `/` and its own `/settings`, nothing else. No write capability. |

`invites.role` offers every role except `owner`. Invitations do not create
owners.

> **`viewer` and `dashboard` do not limit NATS.** What a login can do on the bus comes from its linked `nats_users` role, which is set separately. A `dashboard` screen can hold a NATS credential that publishes anywhere its role allows.

> **`owner` and `admin` are identical.** Every API rule allows both. The one difference is that an owner cannot leave their own organization (footnote 13). Neither can delete the organization, because that is Platform-Operator-only (§3). **`admin` is not a lesser grant.** It gives full tenant authority, including every collection that holds credentials.

---

## 2. Capability Matrix

"—" means the API rules reject the operation, not only that the console hides it.

| Capability | Owner | Admin | Member | Viewer | Dashboard | Platform Operator¹ | SuperUser² |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| Read Things and Locations | ✅ | ✅ | ✅ | ✅ | ✅³ | — | ✅ |
| Create / edit Things and Locations | ✅ | ✅ | ✅ | — | — | — | ✅ |
| Delete a Thing or Location | ✅ | ✅ | — | — | — | — | ✅ |
| Deactivate / reactivate a Thing (§4.2) | ✅ | ✅ | — | — | — | — | ✅ |
| Reset a Thing's PocketBase password¹⁰ | ✅ | ✅ | — | — | — | — | ✅ |
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
| Rotate own NATS credential (§4)⁸ | ✅ | ✅ | ✅ | ✅ | ✅ | — | —¹² |
| Revoke-and-replace, suspend or reactivate a NATS identity | ✅ | ✅ | — | — | — | — | ✅ |
| Manage JetStream streams and KV buckets⁴ | ✅ | ✅ | — | — | — | — | — |
| Use dashboards | ✅ | ✅ | ✅ | ✅ | ✅⁷ | — | ✅ |
| Invite users, manage memberships | ✅ | ✅ | — | — | — | invites only | ✅ |
| Leave the organization (delete own membership) | —¹³ | ✅ | ✅ | ✅ | ✅ | — | — |
| Create / edit an Organization record | — | — | — | — | — | ✅ | ✅ |
| Suspend / reactivate an Organization (§3.1)⁵ | — | — | — | — | — | ✅ | ✅ |
| Delete an Organization (§3)¹¹ | — | — | — | — | — | ✅ | ✅ |
| Read the org's activity feed (§5.2) | ✅ | ✅ | ✅ | ✅ | ✅⁹ | — | ✅ |
| Read the audit log (§5.1) | — | — | — | — | — | ✅ | ✅ |
| Schema imports, NATS Operator key custody | — | — | — | — | — | — | ✅ |

¹ **Platform Operator:** `users.is_operator = true`, a flag on the user account, separate from any Membership. See §3.

² The `_superusers` collection ignores API rules. See §3.

³ **Reads are scoped by organization, not by role.** The read rules on `things`, `locations`, `thing_types`, `location_types` and `thing_type_operations` require a non-blank active organization, `organization = current_organization`, and a membership in that organization. They have no role branch. So *every* role in an organization, `dashboard` included, can `curl` the whole inventory. Roles differ in writes and in which screens the console shows. The console limits `dashboard` to the Visualizer, and shows the Types screens only to owners and admins. **That is navigation, not a boundary.** To make a real read boundary, you would need a role branch in `schema.json` on every one of those collections, and relation expansions could then silently return nothing.

⁴ JetStream operations use the browser's own NATS connection, so the caller's **NATS** permissions limit them, not the API rules. The console shows these views to owners and admins. An *account's* total storage has a separate limit: `max_jetstream_disk_storage` and `max_jetstream_memory_storage` in `nats.default_limits`, applied when the account is provisioned. See [Configuration](./configuration.md#2-section-reference).

⁵ `organizations.active`, copied onto the organization's NATS account. The operator and system organizations refuse the change. See §3.1.

⁶ Owners and admins use `POST /api/org/nats-account/keys`, which needs an owner or admin membership in the organization. A Platform Operator without one edits the `nats_accounts` record instead: `nats_accounts.updateRule` and `nebula_ca.updateRule` are both Platform-Operator-only. Rolling a Nebula CA is also a route, and owners and admins can use it: `POST /api/org/nebula-ca/rotate` (§4.3).

⁷ Dashboards are the only screen `dashboard` can open.

⁸ Refused with `403` while the identity is suspended (`active = false`). See §4.

⁹ The API rule allows every role. The console's `/activity` screen is not shown to `dashboard`.

¹⁰ By setting it directly. Password reset by email is refused for every Thing, because a member can choose a Thing's email when creating it, and a reset sent to that address would let the member sign in as the Thing.

¹¹ Only once the organization is suspended and holds no Things, Locations or Nebula hosts.

¹² `POST /api/me/nats-creds/rotate` accepts only a `users` or `things` session, and a SuperUser has no linked identity of its own. A SuperUser can still rotate any identity by setting `regenerate` on its `nats_users` record.

¹³ The `memberships` delete rule lets every user delete their own membership, except an `owner` membership. The console does not show **Leave Org** to an owner. The API does not fully stop an owner, because the owner and admin branch of the same rule allows the delete of any membership in the organization. A departing user keeps any `.creds` file they downloaded, so also deactivate or regenerate a NATS identity that only they used.

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
Operator cannot read that org's records through the record API. Membership
grants tenant-data access. The flag grants org management.

The flag still gives two cross-tenant reads. A Platform Operator can list every
user. It can also read the audit log, which holds old and new values of tenant
records from every organization ([§5.1](#51-audit_logs-is-platform-operator-only)).

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
orphans. The membership clause in §2 stops a tenant from reading a record with
a blank organization, but an orphan is still data that no tenant owns, and only
a SuperUser can remove it. To take a tenant off the bus without deleting
anything, suspend it (§3.1).

**So a delete needs the organization suspended and empty first.** The platform
refuses the delete while the organization's NATS account is still active, and
while the organization still has Things, Locations or Nebula hosts. Suspending
withdraws the account, and it stays withdrawn after the delete blanks it.
Nebula hosts must go first because suspension does not touch Nebula, and a host
certificate keeps working until it expires. The System and operator
organizations cannot be deleted.

### 3.1 Suspending an organization

Only a Platform Operator can change `organizations.active`. It does one thing:
**it withdraws the organization's NATS account.**

`hooks/org_active_flag.go` copies the flag onto the account record's own
`active` field, which is pb-nats's account-level suspend. Clearing it deletes
the account claim from the resolver. Every device, edge agent and browser in the
tenant disconnects from the hub at once, and the account stays withdrawn across
restarts. A site's leaf node keeps its own copy of the account, so devices on it
keep working locally
([Leaf Nodes §8.1](./leaf-nodes.md#81-what-reaches-a-site-and-when)).

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

It is a route because an API rule cannot allow one field and forbid the rest.
That matters here: the platform copies `nats_users.publish_permissions` into
the JWT it signs, so write access to that collection is owner/admin only.

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
| `active = false` on the linked `nats_users` row | The signed NATS credential. pb-nats revokes the public key on the account and issues nothing new. The hub disconnects the device at once. A site's leaf node applies the revocation at its next refresh ([Leaf Nodes §8.1](./leaf-nodes.md#81-what-reaches-a-site-and-when)). |
| `active = false` on the linked `nebula_hosts` row | The mesh certificate. pb-nebula adds its fingerprint to the `pki.blocklist` of every host under the same CA. Nebula has no CRL, so this applies as each peer's config is redeployed. |

All four are necessary:

> **An `authRule` runs only at the authentication endpoint.** It does not run on a request that carries a token issued earlier. Thing tokens last **7 days**. With only `active = false`, a decommissioned device would keep a working API session for up to a week. The new `tokenKey` closes that gap, which is why deactivation is a server-side hook and not only a rule.

A device's real capability is its credentials, not its PocketBase session. If
you block API access but not the NATS identity, the device still publishes. If
you block NATS but not Nebula, it stays on the mesh. A device can hold either
identity, both or neither, so each cascade runs on its own.

**A deactivation that cannot revoke is refused** (from v0.19.0). The identities are revoked before the Thing is saved. If either one
fails, the save answers `400` and the Thing stays active, so the console never
shows a device as cut off while its credential still works. An identity revoked
before the failure stays revoked; deactivate again once the cause is fixed. The
same holds for any later save of an inactive Thing: an identity linked to it
then is revoked by that save. In v0.18.1 and earlier the cascade was
best-effort and ran only when the flag changed: a failed revoke was only
logged, and an identity linked to an already-inactive Thing stayed live.

**Deactivation sets `active`, never `revoke`.** In pb-nats, `revoke` is for
leaked credentials. It generates a **new** key pair, puts the old public key on
the account's revocation list, and returns a *working* replacement. The identity
stays active. `active = false` is the suspend: revoke, and issue nothing.

**Deactivate, then delete.** A Thing delete does not cascade to either
identity, so it cannot revoke anything. The server refuses to delete a Thing
while its linked NATS user or Nebula host is still active, with a `400` that
names the identity. Deactivate the Thing first. Its identity rows stay, inactive,
so the certificate stays on every blocklist.

**Reactivating issues a *new* NATS credential.** The revocation cutoff in the
account JWT is permanent, so the old `.creds` file stays rejected. The device's
platform token ended with the `tokenKey`, so its Agent must sign in again before
it can fetch anything. See [Agent §2.1](./agent.md#21-removing-the-password)
for a device whose password was removed.

For a device, use `things.active`, which moves the NATS identity, the Nebula
host and the session together. The NATS user's detail view also has **Revoke**
(replace leaked credentials, stay active), which the Thing's page has too, and
**Re-enable** (reactivate a suspended identity with a new `.creds`). On the
NATS user, `active` is a real control: true to false revokes and issues
nothing, and false to true mints a credential issued after the cutoff.

**A deactivated Thing's identities stay down until the Thing is reactivated.**
While the Thing is deactivated, the server refuses to make its NATS user or
Nebula host active. It also refuses `regenerate`, `revoke` and `renew` on them,
because each of those issues a working credential even for an inactive
identity. The response is a `400` that names the Thing. Re-enable and the Nebula
host's Active toggle are therefore for identities that no Thing holds.

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

**A site gateway is a Thing**, with no gateway flag
([Leaf Nodes §1](./leaf-nodes.md#1-there-is-no-gateway-flag)). Like any Thing,
it reads only its own record, its linked NATS identity and its linked Nebula
host: no inventory, and nothing else in `nats_*` or `nebula_*`. What a leaf
node needs beyond that (account, operator and `$SYS` JWTs) comes from
`GET /api/me/leaf-config`, which returns named fields and never a record
([Leaf Nodes §3](./leaf-nodes.md#3-get-apimeleaf-config)).

**Do not add a device read branch** to `nats_users` or `nats_accounts` for an
edge feature. Extend the route, so the edge's exposure stays a fixed list of
fields. To take a gateway out of service, clear `active` on its Thing (§4.2).

---

## 7. Changing the Rules

Contributors changing an API rule follow
[`AUTHORIZATION.md`](https://github.com/stone-age-io/platform/blob/main/AUTHORIZATION.md)
in the platform repository. In short: write allowlists that name every role a
write branch allows; ship the change in a new `migrations/schema_update_*.go`
(an edit to `schema.json` alone reaches new databases only), with a backfill
for any new column a rule reads; and add a paired "can" and "cannot" check to
`./scripts/test-authz.sh`, using `dashboard` as the denial probe.

---

## 8. Where to Go Next

- The records these rules protect: [Platform Entities](./platform-ui-entities.md)
- Every route on this page: [API Reference](./api-reference.md)
- The same rules from the terminal: [Stone CLI](./stone-cli.md)
- The edge identity model: [Leaf Nodes](./leaf-nodes.md)
- NATS roles and permissions: [Connectivity](./connectivity.md)
- Creating the first Platform Operator and SuperUser: [Getting Started](./getting-started.md)
- Audit retention: [Configuration Reference](./configuration.md)
