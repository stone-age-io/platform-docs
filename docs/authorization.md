# Authorization & Roles

This page is the canonical description of who can do what in Stone-Age.io. Every other page defers to it.

Permissions are enforced **solely by the PocketBase API rules** declared in the platform's `schema.json`. There is no second *permission* layer: `pb-nats` and `pb-nebula` contain no tenancy logic at all — they never reference `organization`.

There is exactly one server-side hook that enforces anything, and it enforces an **invariant**, not a permission: `hooks/relation_tenancy.go` refuses any relation that points into another organization's records. No rule can express that — a rule traverses a stored field, but a relation id in a request body is a raw string with nothing to traverse into — and without it an owner could name another tenant's `account_id` and have pb-nats sign them a credential inside that tenant's account. It is derived from the schema rather than listing the relations, binds the model hooks so it covers server-side saves as well as REST, and applies to SuperUsers too: a cross-tenant relation is corrupt data whoever writes it. It answers "may this record point there", never "may this caller act".

The Stone Age Console's capability map (`can.*` in `ui/src/stores/auth.ts`) decides which menu items and buttons render; it is **navigation convenience, not a security boundary**. The same is true of the [`stone` CLI](./stone-cli.md) — it is a client of the same rules, not a privileged path around them.

> **The practical consequence:** if you want to know whether a role can do something, the answer is in the collection's API rules — not in what the UI happens to show. A hidden button is still a reachable endpoint for anyone with a token.

---

## 1. The Five Tenant Roles

Roles live on `memberships.role` — the record that binds a User to an Organization. A user who belongs to three organizations has three memberships and can hold a different role in each.

| Role | What it is |
| :--- | :--- |
| `owner` | Full tenant authority. Identical to `admin` in every API rule (see below). |
| `admin` | Full tenant authority. |
| `member` | Day-to-day custodian of inventory: creates and edits Things and Locations, reads contracts, holds its own NATS credential. Cannot touch infrastructure collections. |
| `viewer` | Read-only staff. The inventory screens and dashboards, no write control anywhere. Still holds its own NATS credential. |
| `dashboard` | An appliance login for an unattended screen. The Visualizer at `/` and its own `/settings`, nothing else. Holds no write capability at all. |

`invites.role` offers every role except `owner` — owners are not created by invitation.

> **Neither `viewer` nor `dashboard` is a NATS restriction.** A console role's real capability on the bus is whatever its linked `nats_users` role permits, and that is set independently. An unattended screen logged in as `dashboard` can hold a NATS credential that publishes anywhere its role allows.

> **`owner` and `admin` are deliberately identical.** They are the same allowlist in every API rule. Only one thing distinguishes them: an owner cannot leave their own organization (a console guard, not a rule). Neither can delete the organization — that is Platform-Operator-only (§3). **Do not read "admin" as a lesser grant** — handing someone `admin` hands them full tenant authority, including every credential-bearing collection.

> **Write allowlists, never deny-lists.** The rules name the roles that are permitted (`role ?= "owner" || role ?= "admin"`). An earlier deny-list form (`role ?!= "member"`) was satisfied by `dashboard` — the *least* privileged role — so its holders passed every admin check. Copy the canonical snippet from a neighbouring rule rather than hand-writing a variant.
>
> The same bug returned in a second costume: a write branch that constrained *which fields* could be written while naming no role. A branch that restricts what may be written still has to say who may write it. Every write branch names its roles.

> **A read-only role costs one enum entry, and that is the point.** `viewer` was added with **zero changes to any rule text** — a role value that names itself in no write branch is denied everywhere by construction. That is the dividend of the allowlist discipline above, and it doubles as a test of it: if you ever find yourself editing a rule to keep a new read-only role *out*, that rule is a deny-list and it is the bug.

> **Two roles, two purposes — do not merge them.** `dashboard` is the zero-authority probe: it holds no capability at all, which is what makes it the only role that can prove an allowlist works. `viewer` holds read capability, so a denial it passes proves less. The authorization suite uses `dashboard` for exactly this reason.

---

## 2. Capability Matrix

The authoritative summary. "—" means the API rules reject the operation, not that the UI hides it.

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

¹ **Platform Operator.** `users.is_operator = true` — a flag on the user account, independent of any Membership. See §3.
² The `_superusers` collection bypasses API rules entirely. See §3.
³ **Reads are org-scoped, not role-scoped, and that is deliberate.** The read rules on `things`, `locations`, `thing_types`, `location_types`, `thing_type_operations` all require a non-blank active organization, `organization = current_organization`, and a membership in that organization — with no role branch. So *every* role in an organization — `dashboard` included — can `curl` the whole inventory. What differs between roles is writes, plus which screens the console navigates to: it confines `dashboard` to the Visualizer and shows no inventory screens at all, and the Types screens (Thing Types, Operations, Location Types) are reachable only by owners and admins, whose capability they sit behind. **That is navigation, not a boundary** — do not read a hidden screen as a denied read. Making one of these an actual boundary means a role branch in `schema.json`, across every one of those collections, with a new failure mode where a relation expansion silently returns nothing.
⁴ JetStream operations run over the browser's own NATS connection, so they are bounded by the caller's **NATS** permissions, not by PocketBase API rules. The console surfaces the views to owners and admins. What an *account* may store in total is a separate, account-level fence — `max_jetstream_disk_storage` and `max_jetstream_memory_storage` in `nats.default_limits`, applied when the account is provisioned — see [Configuration](./configuration.md#2-section-reference).
⁵ `organizations.active`, mirrored onto the organization's NATS account. The infrastructure organizations (operator and system) refuse the change. See §3.1.
⁶ Through `POST /api/org/nats-account/keys`, not by editing the record — `nats_accounts.updateRule` and `nebula_ca.updateRule` are both Platform-Operator-only. Rolling a Nebula CA is likewise a route rather than a record edit, but an **owner/admin** one: `POST /api/org/nebula-ca/rotate` (§4.3).
⁷ Dashboards are the only screen `dashboard` reaches. That is the role's entire purpose: a login for an unattended display.
⁸ Refused with `403` while the identity is suspended (`active = false`) — see §4.
⁹ The API rule admits every role; the console's `/activity` screen does not include `dashboard`, which reaches only the Visualizer.

**The lower roles get an empty list, not a filtered one.** For `nats_users`, `nats_roles`, `nats_account_exports`, `nats_account_imports`, `nebula_networks`, and `nebula_hosts`, the `listRule` itself requires owner or admin. A member, viewer or dashboard holder querying those collections receives zero records — with the single, deliberate exception in §4.

> **A membership is what keeps a read alive — by construction.** Every org-scoped read rule requires both a non-blank `users.current_organization` **and** a membership in that organization. The membership clause is the load-bearing half. `current_organization` alone was not enough: both sides of `organization = current_organization` are text defaulting to `''`, and in PocketBase `'' = ''` is true, so a record whose organization had been blanked was readable by any caller whose own context was blank. `memberships.organization` is required and cascades, so it can never be blank, which kills that match without relying on a comparison someone might later tidy away. Deleting a membership therefore ends the reads immediately; `hooks/membership_lifecycle.go` also clears `current_organization` on the way out, as a second safeguard. **The review question for any rule is "what does this do when both sides are the zero value"**, not only "does it name the right roles".

---

## 3. Cross-Organization Identities

Two identities exist *outside* the Membership model.

**Platform Operator** (`users.is_operator = true`) is a regular user account with platform-administration authority. A Platform Operator creates and edits Organization records and can invite users into any org. A Platform Operator with no Membership in a given org still cannot read that org's tenant data — Membership is what grants tenant-data access; the flag grants org-management authority.

**SuperUser** (the `_superusers` collection) is a backend service account whose access bypasses API rules entirely. It exists for infrastructure-level work — schema imports, NATS Operator key custody, troubleshooting — and signs in at the embedded admin UI (`/_/`). SuperUsers are not members of any organization.

> **Platform Operator status cannot be granted through the API.** The only two paths are the `bootstrap` command and the embedded admin panel, both of which bypass API rules. `users.updateRule` refuses `is_operator` on your own record, and both branches of `users.createRule` refuse it on a new one — including the branch that lets a Platform Operator onboard users, so an operator cannot mint another operator over REST either. That last clause is recent: until it landed, the operator branch was a bare `is_operator = true` check. See [Getting Started §2](./getting-started.md#2-initialize-the-control-plane).

### The organization record is Platform Operator territory

`organizations.updateRule` is `@request.auth.is_operator = true`, plus a freeze on `code` that binds operators too (see [ADR 0002](./decisions/0002-organization-code-namespace.md); a typo is a SuperUser fix, deliberately). **No tenant role, not even `owner`, can edit the organization record.** That record carries the tenancy flags (`managed`, `is_operator_org`, `is_system_org`) and drives NATS Account and Nebula CA provisioning, so editing it is a Platform Operator action rather than a tenant one. `organizations.createRule` is likewise Platform-Operator-only.

**Deletion is Platform-Operator-only too**, and it used to be the exception. Most relations into `organizations` are non-cascade and non-required, so deleting one does not remove the tenant's inventory — PocketBase **blanks** the `organization` field on every Thing, Location, NATS account and Nebula CA that pointed at it, leaving orphans. Combined with the blank-matches-blank read described in §2 that was a cross-tenant read, reachable by any owner deleting their own organization. Deleting a tenant is a support action, not a self-service one; to take a tenant off the bus without destroying anything, suspend it (§3.1).

### 3.1 Suspending an organization

`organizations.active` is Platform-Operator-only and means exactly one thing: **the organization's NATS account is withdrawn.** `hooks/org_active_flag.go` mirrors the flag onto the account record's own `active` field, which is pb-nats's account-level suspend: clearing it deletes the account claim from the resolver, so every device, edge agent and browser in the tenant disconnects at once, and it stays withdrawn across restarts.

- **Reversible, unlike deactivating a device.** It deletes the *account* claim; it adds no revocation, touches no `nats_users` row and re-mints nothing. Every `.creds` file stays valid and simply has nothing to connect to until the flag is set again. Contrast §4.2, where a device's revocation cutoff is permanent and coming back needs a new credential.
- **Deliberately narrow.** It does **not** touch Nebula — a blocklist lands only on redeploy and undoing it rewrites every peer config, the wrong shape for something reversible. It does **not** lock the console: a suspended tenant still signs in and reads what it owns. And it does not kill any Thing's auth tokens. Any screen that shows the state should say both halves.
- **While suspended, minting a NATS identity fails.** `POST /api/org/things` with `nats.mode: "auto"` answers `400` ("no active NATS account for this organization"), since there is no active account to sign under.
- **The operator and system organizations refuse the change.** Withdrawing the operator organization's account would cut off the hub every managed tenant imports through.

The mirror is level-triggered rather than edge-triggered, so a failed withdrawal can be retried by saving the organization again.

---

## 4. The Row-Scoped Credential Model

`nats_users.creds_file` embeds the user seed, and `nebula_hosts.config_yaml` embeds the host key. Both stay **readable**, because the identity that owns them needs them: the browser opens its NATS connection with them, and the console's download button hands a console user a `.creds` file. What the rules restrict is **which rows a caller sees**. (Edge boxes read only the rows linked to themselves, and get everything else they need from the route in §6.)

So there is exactly one exception to the owner/admin-only rule on `nats_users`: **a user of any role, including `dashboard`, can read the single `nats_users` row linked to their own membership in the active organization.** That is the credential their browser authenticates with. A Thing likewise sees only the NATS user and Nebula host assigned to it.

**Which identity a membership links to is therefore an owner/admin decision.** The read follows the link, so whoever can set the link can read the credential it names. On their own membership, every role may keep the link or clear it, and nothing else: re-pointing it at a different identity is refused unless the caller is an owner or admin of the organization. That clause is recent. Before it, the self branch of `memberships.updateRule` let any role choose freely, and since every `nats_users` id in the organization is readable off `things.nats_user`, a `dashboard` login could link itself to a gateway's identity — or the owner's — and read that seed. `relation_tenancy` did not catch it because the target was in the *same* organization. In the console, the Settings picker offers a member only the identity already linked to them, so nothing visible changed.

> **This is row scoping, not field hiding.** Marking `creds_file` or `config_yaml` hidden would break the browser's NATS connection and the console download button — and buy nothing, since the read rules already confine each caller to their own row.

### Self-service rotation

```
POST /api/me/nats-creds/rotate
```

Available to **every role, including `dashboard`**, for callers in the `users` and `things` collections. It takes **no id parameter** — it only ever targets the caller's own linked identity, so there is no other identity it could be aimed at. It responds with the identity's id; re-read that record to pick up the new credential.

It exists as a route rather than a rule branch because **an API rule cannot express a single-field allowlist**. Permitting self-rotation through the update rule would mean asserting `:isset = false` on every *other* writable field — a deny-list that opens up silently the moment someone adds a field. And the field that must stay closed is consequential: `nats_users.publish_permissions` is copied **verbatim** into the JWT the platform signs, so write access to that collection is equivalent to granting NATS permissions. That is why it is owner/admin only.

**A suspended identity cannot rotate — the route answers `403`.** A regenerate mints a JWT issued *after* the account's revocation cutoff, which NATS accepts, so rotating a suspended identity would silently un-suspend it. Until the route checked `active`, the self-service rotate button was also a self-service reactivate. Suspending and reactivating stay owner/admin actions through the normal update rule — or a consequence of deactivating the device that holds the identity (§4.2).

### 4.1 Account signing keys

The organization's NATS Account record has the same problem one level up, and the same answer. `nats_accounts.updateRule` is **Platform-Operator-only**, because the record mixes fields a tenant may legitimately trigger with fields it must not touch — the account limits it was sold, and the signed account `jwt`. An owner or admin manages its signing keys through:

```
POST /api/org/nats-account/keys      { "action": "rotate" | "add_signing" | "remove_signing" }
```

| Action | Effect |
| :--- | :--- |
| `add_signing` | Graceful rotation: appends a new signing key. Existing user JWTs stay valid. |
| `remove_signing` | Removes one key by `public_key`. The last remaining key cannot be removed. |
| `rotate` | **Emergency replacement:** purges every signing key and generates one. Every user JWT in the account stops validating and must be re-minted. |

Like the credential route it takes no record id — the account is derived from the caller's active organization, so it cannot be aimed at another tenant — and each action writes exactly one field. Reach for `add_signing` for routine rotation; `rotate` is for suspected key compromise.

`nebula_ca.updateRule` is Platform-Operator-only for the same reason — the record holds the trust anchor for the organization's whole overlay. Rolling one is a route, and an **owner/admin** one: see §4.3.

### 4.2 Taking a device out of service

`things.active` is an Owner/Admin-only boolean. Clearing one is a **decommission**, not a label change — four things happen in the same operation:

| | What it stops |
| :--- | :--- |
| The collection's `authRule` (`active = true`) | New sign-ins. The device cannot obtain another token. |
| A refreshed `tokenKey` | Every token the device **already holds**, immediately. |
| `active = false` on the linked `nats_users` row | The signed NATS credential. pb-nats revokes the public key on the account and deliberately issues nothing back — the device stops publishing. |
| `active = false` on the linked `nebula_hosts` row | The overlay certificate. pb-nebula adds its fingerprint to the `pki.blocklist` of every host under the same CA — effective as each peer's config is redeployed, since Nebula has no CRL. |

All four are needed, and the reason is worth internalizing before you rely on any similar flag:

> **An `authRule` is evaluated at the authentication endpoint only** — never on a request that arrives carrying an already-issued token. Thing tokens live **7 days**. So `active = false` on its own would leave a decommissioned device with a working API session for up to a week. Refreshing `tokenKey` is what closes that window, and it is why deactivation is a server-side hook rather than a rule alone.

And the second half: **a device's real capability is its credentials, not its PocketBase session.** Blocking API access without reaching the NATS identity leaves the device publishing to the bus; reaching NATS without reaching Nebula leaves it on the mesh. The two cascades are independent — a device may hold either identity, both or neither — so neither is allowed to short-circuit the other.

**Deactivation sets `active`, never `revoke`.** The names mislead. In pb-nats, `revoke` is the "these credentials leaked" button: it generates a **new** key pair, puts the old public key on the account's revocation list, and hands back a *working* replacement — the identity stays active. Using it to decommission a device would re-credential the thing you just disabled. `active = false` is the suspend: revoke, and reissue nothing.

**Deactivate, do not delete.** Deleting a Thing cascades to neither identity — its NATS credential keeps working and its Nebula certificate stays trusted, with nothing left pointing at them — and a deleted certificate can no longer be fingerprinted onto a blocklist at all.

**Reactivating issues a *fresh* NATS credential.** The revocation cutoff embedded in the account JWT is permanent, so the old `.creds` file stays rejected forever — the device needs the new one. The device's platform token died with the `tokenKey`, so its Agent has to sign in again before it can fetch anything; see [Agent §2.2](./agent.md#22-removing-the-password) for the case where its password was removed.

> **A flag with nothing enforcing it is worse than no flag**, because someone will trust it during an incident. `nats_users.active` used to be exactly that — read into pb-nats's model and consulted by nothing, while the console showed it as an editable checkbox beside a red/green badge, so an admin could "deactivate" a device that kept publishing. Since pb-nats v0.2.1 it **is** the control: true→false revokes and reissues nothing, false→true mints a credential issued after the cutoff. For a device the lever is still `things.active`, which moves the NATS identity, the Nebula host and the session together; the NATS user's detail view offers **Revoke** (leaked credentials: replace them, stay active) and **Re-enable** (reactivate a suspended identity with a fresh `.creds`).

### 4.3 Rolling a Nebula CA

```
POST /api/org/nebula-ca/rotate       { "step": "prepare" | "commit" | "finish" }
```

**Owner/Admin of the CA's own organization**, and the console presents it as a three-step panel on the Nebula CA detail view. Like the routes above it takes no record id — the CA is resolved from the caller's active organization, so it cannot be aimed at another tenant — and the route allowlists the three verbs while `pb-nebula` validates the *transition*.

**The tenant owns this lever deliberately.** The dangerous part of rotating a CA is not the cryptography, it is the **wait** in the middle, and the wait belongs to whoever operates the devices. A Platform Operator cannot judge when a fleet has caught up.

| Step | What it does | Reversible |
| :--- | :--- | :--- |
| `prepare` | Publishes the new CA as *trusted* without moving issuance. | Yes — fully. |
| `commit` | Swaps issuance to the new CA and re-signs every active host. | The outgoing CA is still trusted. |
| `finish` | Drops the outgoing CA. **Refused** while any active host still holds a certificate signed by it. | No. |

**Three steps and not one, because Nebula verification is mutual and config distribution is pull-based.** A single write carrying both the new trust bundle and the new certificate splits the mesh for as long as propagation takes: a host that has fetched presents a new-CA certificate to one that has not, and the handshake fails in *both* directions. `prepare` exists to make the trust half land first, everywhere, before any issuance moves.

!!! note "Why a route and not an owner branch on the update rule"
    A rule branch permitting rotation would have to deny-list every other field on `nebula_ca` — and would silently re-open each one added afterwards. That is the same deny-list shape this repo has been bitten by twice, here on the record holding the trust anchor for a tenant's entire mesh. See §7.

---

## 5. Two Histories: The Audit Log and the Activity Feed

There are **two** records of who changed what, and they are not variants of each other. They differ in who may read them and in what they contain.

| | `audit_logs` | `activity` |
| :--- | :--- | :--- |
| Who can read it | Platform Operator / SuperUser only | **every role** in the organization |
| Scope | the whole deployment, no `organization` column | one organization |
| What it records | the names of the fields that changed on every write; before/after **values** only for an allowlist of collections that hold no credential | actor, action, record, timestamp, and a label snapshot — **no values at all** |
| Console route | `/audit` | `/activity` |
| Purpose | the forensic trail | "who on my team changed this device, and when" |

### 5.1 `audit_logs` is Platform-Operator-only

`audit_logs` list and view are `@request.auth.is_operator = true`. **No tenant role — including `owner` — can read the audit log**, and the console's `/audit` route is gated on the same flag to match. Creates, updates, and deletes are closed to everyone; the log is written by the platform. Retention is configured in `audit.retention` — see [Configuration §2](./configuration.md#2-section-reference).

**Values are opt-in per collection.** Every event records `changed_fields` — the *names* of the fields that moved. Before/after values are kept only for the collections in `auditSnapshotCollections` (`main.go`): organizations, memberships, users, the five inventory collections, `nats_roles`, `nebula_networks` and email templates. Everything else — `nats_users`, `nebula_hosts`, `nats_accounts`, `nebula_ca`, `invites`, and the account exports and imports — records field names only. The reason is the credential model in §4: `creds_file` and `config_yaml` are protected by **row scoping**, and a flat log holding copies of records has no rows to scope. When every collection was snapshotted, creating one NATS identity wrote its full `.creds` file, seed included, into the log. The list is an allowlist, and a test fails if a listed collection carries an unhidden credential-bearing field. So the review question for anything new is not "is this field hidden" but **"does anything copy this record somewhere the row rules do not reach."**

The flat-collection problem is also why the log cannot simply be opened up. A read on `audit_logs` inherits the exposure of every collection it snapshots at once — `nats_roles` values, for one, are publish/subscribe permission sets. Org-scoping the collection would not fix that; the snapshots would still be there.

### 5.2 `activity` is tenant-facing, and carries no values

`activity` answers the question tenants actually ask, without any of that exposure: it names the actor, the action and the record, and stores **no record values**. Every role in the organization can read it through the API, `dashboard` included; the console's `/activity` screen is offered to every role except `dashboard`, which reaches only the Visualizer.

**The invariant to preserve: an entry is visible to exactly those who could read the record it describes.** A flat collection mirroring other collections inherits none of their scoping. So the feed covers only the five tenant collections whose own reads are org-scoped with no role branch — `things`, `locations`, `thing_types`, `location_types`, `thing_type_operations` — and deliberately **not** memberships, invites, `nats_roles` or `nebula_networks`, whose reads stop at owner/admin. Adding a collection to the feed is therefore an authorization change, not a configuration one, and the platform has a test that says so.

It is **append-only by construction**: all three write rules are nil, so no one — tenant or operator — can forge or rewrite an entry through the API. `actor` is plain text rather than a relation, so deleting a user does not quietly strip attribution from every line that mentions them; the flip side is that the stored label is a **snapshot**, not a live join, and a record renamed since will show its old name.

From the CLI this is `stone activity ls` (see [stone CLI](./stone-cli.md)); `--filter 'resource_id="<id>"'` is the one to know, because it answers "who touched this device".

**The MSP consequence, restated:** a tenant admin still cannot self-serve an *audit* export, and a request for before/after values (where the log keeps them) goes through a Platform Operator. But "who changed this record, and when" no longer does.

---

## 6. Gateways and the Edge

**A site gateway is a Thing.** There is no `leaf_nodes` collection any more and no gateway flag anywhere — not on `things` and not on [`thing_types`](./thing-types.md) either. Nothing branches on one, so a marker would only be a field to get wrong (see [Leaf Nodes §1](./leaf-nodes.md#1-there-is-no-gateway-flag)). So a gateway's read surface is exactly a Thing's read surface: its own record, the one NATS identity linked to it, and the one Nebula host linked to it. **No inventory collection** — every other Thing, Location and type is readable only by a `users` session — and nothing in `nats_*` or `nebula_*` beyond those two rows.

The values an edge box cannot derive locally — the org's account JWT and public key, the NATS Operator JWT, and the `$SYS` account JWT and public key — come from a dedicated route:

```
GET /api/me/leaf-config
```

It is bound to `things` and takes **no record id**: the target is the caller's own authenticated record, exactly like `POST /api/me/nats-creds/rotate`. It returns ten named fields: `code`, `domain`, `creds`, `account_jwt`, `account_pub`, `operator_jwt`, `sys_account_jwt`, `sys_account_pub`, `hub_leaf_url`, `hub_domain`. The server reads the secret-bearing collections with its own privileges and serves named fields, never whole records — so **secret-bearing collections are never exposed to a device identity**, and the blast radius of a leaked edge credential is those ten values regardless of how the collection rules later evolve.

**The route gates on nothing, and that is the interesting part.** Everything it serves is either public trust material — the Operator, account and `$SYS` account JWTs, which every server in the network validates anyway — or the caller's own credential, which it must already hold in order to connect at all. A Thing that will never run a leaf node can call it and learns nothing it could not already read. Adding a permission here would be a gate over data that is not secret, and it would have required inventing the marker field that §1 of [Leaf Nodes](./leaf-nodes.md) explains the absence of.

!!! note "Why the `$SYS` **account** JWT is safe to serve"
    The NATS Operator JWT names a system account, and the leaf's `resolver: MEMORY` has nowhere to fetch it — so without the `$SYS` account JWT preloaded, `nats-server` dies with `error resolving system account` before JetStream starts. Preloading it grants nothing. Connecting **as** `$SYS` needs a `$SYS` **user** credential, which the platform never serves to anything. Those are different objects.

Account **seeds** and signing keys are never served on this path, and `nats_system_operator` stays superuser-only.

**Don't re-add a device read branch** to `nats_users` or `nats_accounts` to make some edge feature work — extend the route instead. The point of the route is that the edge's blast radius is a fixed list of named fields rather than a consequence of rules that change for unrelated reasons.

Taking a site out of service is `active` on its Thing (§4.2), like any other device.

---

## 7. Changing the Rules

Two operational facts matter every time an API rule changes.

- **A schema or rule change reaches existing deployments only via a new `migrations/schema_update_*.go` file.** Editing `schema.json` alone affects **freshly-created databases only** — an upgraded production deployment keeps its old rules. This is the single most common way a security fix fails to ship.
- **A new column that a rule reads needs a backfill in the same migration.** PocketBase booleans have no schema-level default, so a new `active` field lands as `false` on every existing row. Importing `authRule: "active = true"` without an accompanying `UPDATE` would lock every already-provisioned device out of the API the moment the deployment restarts. Test the upgrade path against a database that has rows in it, not only a fresh one.
- **Run `./scripts/test-authz.sh` after any rule change, and add a check.** It builds the binary, creates a throwaway database, and asserts every authorization behaviour it covers against a live server. The count lives in `EXPECTED_CHECKS` at the top of the script, where it guards against a suite that exits early — it is deliberately not repeated in prose here. The rules are the only permission enforcement in the platform, and nothing else type-checks them. Pair every "cannot" with a "can" on the same record — otherwise a blanket deny passes the suite. Note that PocketBase answers **404**, not 403, when an update rule rejects.

Keep the console's capability map (`ui/src/stores/auth.ts`) and the router's `meta.requiresCapability` guards in step with the matrix in §2 — not because they enforce anything, but because a menu that offers an action the rules reject is a bug report waiting to happen.

---

## 8. Where to Go Next

- **The entities these rules protect:** [Platform Entities & UI](./platform-ui-entities.md).
- **Every route named on this page, in one table:** [API Reference](./api-reference.md).
- **The same rules from the terminal:** [Stone CLI](./stone-cli.md).
- **The edge identity model in context:** [Leaf Nodes](./leaf-nodes.md).
- **NATS roles and permission fields:** [Connectivity](./connectivity.md).
- **First-time Platform Operator and SuperUser creation:** [Getting Started](./getting-started.md).
- **Audit retention keys:** [Configuration Reference](./configuration.md).
