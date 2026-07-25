# Authorization & Roles

This page is the canonical description of who can do what in Stone-Age.io. Every other page defers to it.

Authorization is enforced **solely by the PocketBase API rules** declared in the platform's `schema.json`. There is no second enforcement layer: `pb-nats` and `pb-nebula` contain no tenancy logic at all — they never reference `organization`. The Stone Age Console's capability map (`can.*` in `ui/src/stores/auth.ts`) decides which menu items and buttons render; it is **navigation convenience, not a security boundary**. The same is true of the [`stone` CLI](./stone-cli.md) — it is a client of the same rules, not a privileged path around them.

> **The practical consequence:** if you want to know whether a role can do something, the answer is in the collection's API rules — not in what the UI happens to show. A hidden button is still a reachable endpoint for anyone with a token.

---

## 1. The Four Tenant Roles

Roles live on `memberships.role` — the record that binds a User to an Organization. A user who belongs to three organizations has three memberships and can hold a different role in each.

| Role | What it is |
| :--- | :--- |
| `owner` | Full tenant authority. Identical to `admin` in every API rule (see below). |
| `admin` | Full tenant authority. |
| `member` | Day-to-day operator of inventory: creates and edits Things and Locations, reads contracts, holds its own NATS credential. Cannot touch infrastructure collections. |
| `badge` | The most restricted role. Confined to the Badge view and a badge-only dashboard — for kiosk- or wallet-style identity surfaces. Still holds its own NATS credential. |

`invites.role` offers every role except `owner` — owners are not created by invitation.

> **`owner` and `admin` are deliberately identical.** They are the same allowlist in every API rule. Only two things distinguish them: an owner cannot leave their own organization (a console guard, not a rule), and `organizations.deleteRule` still admits the user recorded as the org's owner. **Do not read "admin" as a lesser grant** — handing someone `admin` hands them full tenant authority, including every credential-bearing collection.

> **Write allowlists, never deny-lists.** The rules name the roles that are permitted (`role ?= "owner" || role ?= "admin"`). An earlier deny-list form (`role ?!= "member"`) was satisfied by `badge` — the *most* restricted role — so badge holders passed every admin check. Copy the canonical snippet from a neighbouring rule rather than hand-writing a variant.

---

## 2. Capability Matrix

The authoritative summary. "—" means the API rules reject the operation, not that the UI hides it.

| Capability | Owner | Admin | Member | Badge | Operator¹ | SuperUser² |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| Read Things and Locations | ✅ | ✅ | ✅ | ✅³ | — | ✅ |
| Create / edit Things and Locations | ✅ | ✅ | ✅ | — | — | ✅ |
| Delete a Thing or Location | ✅ | ✅ | — | — | — | ✅ |
| Deactivate / reactivate a Thing or Leaf Node (§4.2) | ✅ | ✅ | — | — | — | ✅ |
| Reset a Thing's or Leaf Node's PocketBase password | ✅ | ✅ | — | — | — | ✅ |
| Attach a NATS user / Nebula host to a Thing | ✅ | ✅ | — | — | — | ✅ |
| Read Thing Types, Operations, Message Schemas | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| Manage Thing Types, Operations, Message Schemas | ✅ | ✅ | — | — | — | ✅ |
| **Read** NATS users, roles, imports, exports | ✅ | ✅ | — | — | — | ✅ |
| Manage NATS users, roles, imports, exports | ✅ | ✅ | — | — | — | ✅ |
| **Read** Nebula networks and hosts | ✅ | ✅ | — | — | — | ✅ |
| Manage Nebula networks and hosts | ✅ | ✅ | — | — | — | ✅ |
| Read the org's NATS Account and Nebula CA | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Edit the NATS Account or Nebula CA record directly | — | — | — | — | ✅ | ✅ |
| Manage the account's signing keys (§4.1)⁶ | ✅ | ✅ | — | — | ✅ | ✅ |
| Read own linked NATS identity | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| Rotate own NATS credential (§4) | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| Revoke someone else's NATS credential | ✅ | ✅ | — | — | — | ✅ |
| View the Leaf Nodes list | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| Create / edit / delete Leaf Nodes, reset their credentials | ✅ | ✅ | — | — | — | ✅ |
| Manage JetStream streams and KV buckets⁴ | ✅ | ✅ | — | — | — | — |
| Invite users, manage memberships | ✅ | ✅ | — | — | invites only | ✅ |
| Create / edit an Organization record | — | — | — | — | ✅ | ✅ |
| Delete an Organization | ✅⁵ | — | — | — | ✅ | ✅ |
| Read the audit log | — | — | — | — | ✅ | ✅ |
| Schema imports, Operator key custody | — | — | — | — | — | ✅ |

¹ `users.is_operator = true` — a flag on the user account, independent of any Membership. See §3.
² The `_superusers` collection bypasses API rules entirely. See §3.
³ The rules let any user in the organization read Things and Locations. The console confines `badge` to the badge routes, but that is a UI decision — see the note at the top of this page.
⁴ JetStream operations run over the browser's own NATS connection, so they are bounded by the caller's **NATS** permissions, not by PocketBase API rules. The console surfaces the views to owners and admins.
⁵ `organizations.deleteRule` keys on the `organizations.owner` **field** — the user recorded as the org's owner, normally the same person who holds the `owner` membership — rather than on the membership role itself. Creating and *editing* the record are operator-only; see §3.
⁶ Through `POST /api/org/nats-account/keys`, not by editing the record — `nats_accounts.updateRule` and `nebula_ca.updateRule` are both operator-only. `nebula_ca` has no rotation trigger at all, so rolling a CA is a platform-operator operation.

**Members and badge holders get an empty list, not a filtered one.** For `nats_users`, `nats_roles`, `nats_account_exports`, `nats_account_imports`, `nebula_networks`, and `nebula_hosts`, the `listRule` itself requires owner or admin. A member querying those collections receives zero records — with the single, deliberate exception in §4.

---

## 3. Cross-Organization Identities

Two identities exist *outside* the Membership model.

**Operator** (`users.is_operator = true`) is a regular user account with platform-administration authority. Operators create and edit Organization records and can invite users into any org. An Operator with no Membership in a given org still cannot read that org's tenant data — Membership is what grants tenant-data access; the flag grants org-management authority.

**SuperUser** (the `_superusers` collection) is a backend service account whose access bypasses API rules entirely. It exists for infrastructure-level work — schema imports, NATS Operator key custody, troubleshooting — and signs in at the embedded admin UI (`/_/`). SuperUsers are not members of any organization.

> **Operator status cannot be granted through the API.** The only two paths are the `bootstrap` command and the embedded admin panel. No API rule permits writing `is_operator`, so no tenant role — and no Operator — can mint another Operator over REST. See [Getting Started §2](./getting-started.md#2-initialize-the-control-plane).

### The organization record is operator territory

`organizations.updateRule` is `@request.auth.is_operator = true` and nothing else. **No tenant role, not even `owner`, can edit the organization record.** That record carries the tenancy flags (`managed`, `is_operator_org`, `is_system_org`) and drives NATS Account and Nebula CA provisioning, so editing it is a platform-operator action rather than a tenant one. `organizations.createRule` is likewise operator-only.

The one exception is deletion: `organizations.deleteRule` admits the organization's own `owner` as well as any Operator.

---

## 4. The Row-Scoped Credential Model

`nats_users.creds_file` embeds the user seed, and `nebula_hosts.config_yaml` embeds the host key. Both stay **readable**, because the identity that owns them needs them: the browser opens its NATS connection with them, and the console's download button hands an operator a `.creds` file. What the rules restrict is **which rows a caller sees**. (Edge boxes are the exception that proves the rule — they read no row at all, and get their credential from the route in §6.)

So there is exactly one exception to the owner/admin-only rule on `nats_users`: **a user of any role, including `badge`, can read the single `nats_users` row linked to their own membership in the active organization.** That is the credential their browser authenticates with. A Thing likewise sees only the NATS user and Nebula host assigned to it.

> **This is row scoping, not field hiding.** Marking `creds_file` or `config_yaml` hidden would break the browser's NATS connection and the console download button — and buy nothing, since the read rules already confine each caller to their own row.

### Self-service rotation

```
POST /api/me/nats-creds/rotate
```

Available to **every role, including `badge`**, for callers in the `users`, `things`, and `leaf_nodes` collections. It takes **no id parameter** — it only ever targets the caller's own linked identity, so there is no other identity it could be aimed at. It responds with the identity's id; re-read that record to pick up the new credential.

It exists as a route rather than a rule branch because **an API rule cannot express a single-field allowlist**. Permitting self-rotation through the update rule would mean asserting `:isset = false` on every *other* writable field — a deny-list that opens up silently the moment someone adds a field. And the field that must stay closed is consequential: `nats_users.publish_permissions` is copied **verbatim** into the JWT the platform signs, so write access to that collection is equivalent to granting NATS permissions. That is why it is owner/admin only.

Revocation is **not** part of the route. Setting the regenerate flag on a revoked user would re-enable it, so revocation stays an owner/admin action through the normal update rule — or a consequence of deactivating the device that holds the identity (§4.2).

### 4.1 Account signing keys

The organization's NATS Account record has the same problem one level up, and the same answer. `nats_accounts.updateRule` is **operator-only**, because the record mixes fields a tenant may legitimately trigger with fields it must not touch — the account limits it was sold, and the signed account `jwt`. An owner or admin manages its signing keys through:

```
POST /api/org/nats-account/keys      { "action": "rotate" | "add_signing" | "remove_signing" }
```

| Action | Effect |
| :--- | :--- |
| `add_signing` | Graceful rotation: appends a new signing key. Existing user JWTs stay valid. |
| `remove_signing` | Removes one key by `public_key`. The last remaining key cannot be removed. |
| `rotate` | **Emergency replacement:** purges every signing key and generates one. Every user JWT in the account stops validating and must be re-minted. |

Like the credential route it takes no record id — the account is derived from the caller's active organization, so it cannot be aimed at another tenant — and each action writes exactly one field. Reach for `add_signing` for routine rotation; `rotate` is for suspected key compromise.

`nebula_ca.updateRule` is operator-only for the same reason and has no tenant route, because the collection has no rotation trigger. Rolling a CA is an operator operation.

### 4.2 Taking a device out of service

`things.active` and `leaf_nodes.active` are Owner/Admin-only booleans. Clearing one is a **decommission**, not a label change — three things happen in the same operation:

| | What it stops |
| :--- | :--- |
| The collection's `authRule` (`active = true`) | New sign-ins. The device cannot obtain another token. |
| A refreshed `tokenKey` | Every token the device **already holds**, immediately. |
| `revoke` on the linked `nats_users` row | The signed NATS credential — the device stops publishing. |

All three are needed, and the reason is worth internalizing before you rely on any similar flag:

> **An `authRule` is evaluated at the authentication endpoint only** — never on a request that arrives carrying an already-issued token. Thing and Leaf Node tokens live **7 days**. So `active = false` on its own would leave a decommissioned device with a working API session for up to a week. Refreshing `tokenKey` is what closes that window, and it is why deactivation is a server-side hook rather than a rule alone.

And the second half: **a device's real capability is its NATS credential, not its PocketBase session.** Blocking API access without revoking the credential leaves the device publishing to the bus. Deactivation does both.

**Reactivating issues a *fresh* NATS credential.** The revocation cutoff embedded in the account JWT is permanent, so the old `.creds` file stays rejected forever — the device needs the new one. For a Thing running the Agent that happens on the next sync; for a Leaf Node, re-run `leaf-sync config`.

> **A flag with nothing enforcing it is worse than no flag**, because someone will trust it during an incident. `nats_users.active` is the cautionary case: `pb-nats` reads it into its model and then consults it nowhere in JWT generation — only `revoke` disconnects anyone. The console therefore no longer exposes it as an editable control; **Revoke** and **Re-enable** on the NATS user's detail view are the real operations.

---

## 5. The Audit Log Is Operator-Only

`audit_logs` list and view are `@request.auth.is_operator = true`. **No tenant role — including `owner` — can read the audit log**, and the console's `/audit` route is operator-gated to match. Creates, updates, and deletes are closed to everyone; the log is written by the platform.

The practical consequence for MSP deployments: **a tenant admin cannot self-serve an audit export.** Requests for "who changed this record" go through a platform operator. Retention is configured in `audit.retention` — see [Configuration §2](./configuration.md#2-section-reference).

---

## 6. Leaf Nodes and the Edge

A Leaf Node authenticates as a record in the `leaf_nodes` collection — "a special Thing" with one NATS identity. Its read surface is deliberately narrow.

A leaf-node identity **can** read:

- its own `leaf_nodes` record, and
- the allowlisted collections it mirrors, within its own organization: `things`, `locations`, `thing_types`, `location_types`, `thing_type_operations`, `message_schemas`.

A leaf-node identity reads **nothing** in any `nats_*` or `nebula_*` collection. The four values an edge box cannot derive locally — its own creds, the org's account JWT and public key, and the operator JWT — come from a dedicated, leaf-node-authenticated route:

```
GET /api/leaf/bootstrap
```

It returns six named fields (`domain`, `code`, `creds`, `account_jwt`, `account_pub`, `operator_jwt`). The server reads the secret-bearing collections with its own privileges and serves named fields, never whole records — so **secret-bearing collections are never exposed to a leaf-node identity**, and the blast radius of a leaked edge credential is those six values regardless of how the collection rules later evolve. `GET /api/leaf/operator-jwt` still exists for older agents but is superseded by `/api/leaf/bootstrap`.

Managing Leaf Node records — creating, editing, deleting, and resetting their credentials via the collection's `manageRule` — is an owner/admin action. Any role in the org can view the list. See [Leaf Nodes](./leaf-nodes.md).

---

## 7. Changing the Rules

Two operational facts matter every time an API rule changes.

- **A schema or rule change reaches existing deployments only via a new `migrations/schema_update_*.go` file.** Editing `schema.json` alone affects **freshly-created databases only** — an upgraded production deployment keeps its old rules. This is the single most common way a security fix fails to ship.
- **A new column that a rule reads needs a backfill in the same migration.** PocketBase booleans have no schema-level default, so a new `active` field lands as `false` on every existing row. Importing `authRule: "active = true"` without an accompanying `UPDATE` would lock every already-provisioned device out of the API the moment the deployment restarts. Test the upgrade path against a database that has rows in it, not only a fresh one.
- **Run `./scripts/test-authz.sh` after any rule change, and add a check.** It builds the binary, stands up a throwaway database, and asserts 97 authorization behaviours against a live server. The rules are the only tenancy enforcement in the platform, and nothing else type-checks them. Pair every "cannot" with a "can" on the same record — otherwise a blanket deny passes the suite. Note that PocketBase answers **404**, not 403, when an update rule rejects.

Keep the console's capability map (`ui/src/stores/auth.ts`) and the router's `meta.requiresCapability` guards in step with the matrix in §2 — not because they enforce anything, but because a menu that offers an action the rules reject is a bug report waiting to happen.

---

## 8. Where to Go Next

- **The entities these rules protect:** [Platform Entities & UI](./platform-ui-entities.md).
- **The same rules from the terminal:** [Stone CLI](./stone-cli.md).
- **The edge identity model in context:** [Leaf Nodes](./leaf-nodes.md).
- **NATS roles and permission fields:** [Connectivity](./connectivity.md).
- **First-time operator and SuperUser creation:** [Getting Started](./getting-started.md).
- **Audit retention keys:** [Configuration Reference](./configuration.md).
