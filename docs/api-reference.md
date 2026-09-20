# API Reference

Almost everything in Stone-Age.io is stock PocketBase REST against a collection —
`GET /api/collections/things/records`, `PATCH /api/collections/locations/records/:id`,
and so on — governed entirely by the API rules in `schema.json`
([Authorization & Roles](./authorization.md)). The
[PocketBase API docs](https://pocketbase.io/docs/api-records/) cover that surface,
and this page does not repeat it.

This page covers the **ten endpoints the platform adds on top of that**: nine
under `/api/`, plus `/metrics`. Each of the application routes exists because a
PocketBase API rule could not express what it needed to.

---

## 1. The whole surface

| Route | Method | Who may call it | Does |
| :--- | :--- | :--- | :--- |
| [`/api/client-config`](#get-apiclient-config) | `GET` | any `users` session | Deployment facts the SPA cannot be compiled with |
| [`/api/me/leaf-config`](#get-apimeleaf-config) | `GET` | any `things` session | Ten fields an agent needs to stand up a NATS leaf server |
| [`/api/me/nats-creds/rotate`](#post-apimenats-credsrotate) | `POST` | any `users` or `things` session | Rotate the caller's own NATS credential |
| [`/api/org/invites/accept`](#post-apiorginvitesaccept) | `POST` | any authenticated caller | Redeem an invitation token |
| [`/api/org/things`](#post-apiorgthings) | `POST` | `member`+ for inventory, `owner`/`admin` for identities | Create a Thing and, optionally, its NATS and Nebula identities, in one transaction |
| [`/api/org/nats-account/keys`](#post-apiorgnats-accountkeys) | `POST` | `owner` / `admin` | Manage the organization's NATS account signing keys |
| [`/api/org/nebula-ca/rotate`](#post-apiorgnebula-carotate) | `POST` | `owner` / `admin` | Roll the organization's Nebula CA, in three steps |
| [`/api/org/nebula/cert-audit`](#get-apiorgnebulacert-audit) | `GET` | `owner` / `admin` | Hosts whose certificate no longer matches their network |
| [`/api/ready`](#get-apiready) | `GET` | unauthenticated | Readiness probe, `200` or `503` |
| [`/metrics`](#get-metrics) | `GET` | unauthenticated by default | Prometheus exposition |

Roles are per-organization memberships and resolve against the caller's **active**
organization (`users.current_organization`). See
[Authorization §2](./authorization.md#2-capability-matrix).

---

## 2. Three rules that apply to all of them

**No route takes a record id.** Every `/api/me/*` route targets the caller's own
authenticated record; every `/api/org/*` route targets the caller's active
organization. The target is derived from the session, never named in the request,
so none of these can be aimed at another tenant. When you are reading a route here
and looking for the id parameter, its absence is the security property.

**A route that writes with `app.Save()` bypasses every API rule.** So each check
the rules would have made is restated inside the route. `POST /api/org/things` is
the worked example: the organization comes from the caller's own record, and a
linked `nats_user` or `nebula_host` is verified to belong to that organization —
without that second check the route would be a cross-tenant credential-theft path.
Rules protect the CRUD endpoints, not these.

**Each one exists for one of three reasons**, and it is worth knowing which,
because it tells you what a proposed new route has to justify:

| Reason | Routes |
| :--- | :--- |
| A rule cannot express a single-field allowlist (the alternative is `:isset = false` on every other field, a deny-list that opens up silently when a field is added) | `nats-creds/rotate`, `nats-account/keys`, `nebula-ca/rotate` |
| One operation needs two authority levels | `org/things` |
| The answer needs something the caller cannot compute or must not read whole | `leaf-config`, `nebula/cert-audit`, `client-config` |

---

## 3. Identity routes (`/api/me/*`)

### `GET /api/client-config`

Deployment facts the single-page console needs at runtime but cannot be compiled
with. Requires a `users` session.

```json
{ "natsWebsocketUrls": ["wss://bus.acme.io:9222"] }
```

The value is `nats.websocket_urls` from `config.yaml`. It is **not** derived from
`nats.server_url`: the first is a TCP address *this process* dials to publish
account claims, the second is a WebSocket listener a *browser* dials, on a
different port and often a different hostname. An empty list is a valid answer and
means "not configured" — the console then falls back to its compiled-in
`ws://localhost:9222`.

The response is deployment-wide rather than per-organization, and that follows
from the NATS hierarchy: every organization is an account under one operator, so
they all live on the same cluster. The axis that genuinely varies is *location* —
hub versus a specific leaf — which is a property of the box the browser runs on,
so it is a device-level override in `localStorage` rather than anything the server
knows. See [Configuration §`nats`](./configuration.md#2-section-reference).

!!! note "Why it requires auth when the value is not a secret"
    Nothing needs it before login — the console will not dial the bus without a
    session and a linked NATS identity anyway. Since there is no pre-login need,
    there is no reason to hand an unauthenticated scanner the address of the bus.

### `GET /api/me/leaf-config`

Everything an [Agent](./agent.md) needs to stand up a NATS leaf server. Bound to
the `things` collection; the target is the caller's own record.

```json
{
  "code": "s01",
  "domain": "s01",
  "creds": "-----BEGIN NATS USER JWT-----\n…",
  "account_jwt": "eyJ0…",
  "account_pub": "AD3…",
  "operator_jwt": "eyJ0…",
  "sys_account_jwt": "eyJ0…",
  "sys_account_pub": "ACY…",
  "hub_leaf_url": "nats-leaf://hub.acme.io:7422",
  "hub_domain": "hub"
}
```

`domain` is the same string as `code` — the JetStream domain is computed from the
Thing's code and never stored, because a stored column could disagree with the
code it was derived from, and when it did the symptom was a site that silently
stopped appearing. The agent writes it into both `server_name` and
`jetstream { domain }`.

**The route gates on nothing beyond being an authenticated Thing, and that is
deliberate.** Everything it serves is either public trust material — the operator,
account and `$SYS` account JWTs, which every server in the network validates
anyway — or the caller's own credential, which it must already hold to connect at
all. A Thing that will never run a leaf node can call it and learns nothing it
could not already read.

What is **not** served: account seeds, signing keys, and any `$SYS` *user*
credential. `nats_system_operator` stays superuser-only. The server reads the
secret-bearing collections with its own privileges and returns ten named fields,
never whole records — so the blast radius of a leaked edge credential is those ten
values regardless of how those collections' rules later evolve.

!!! warning "Do not add a device read branch to `nats_*` or `nebula_*`"
    Extend this route instead. The point of it is that the edge's blast radius is
    a fixed list of named fields rather than a consequence of rules that change
    for unrelated reasons. See [Leaf Nodes §3](./leaf-nodes.md#3-get-apimeleaf-config).

The field names are a **cross-repo contract** — the agent decodes them by name, in
a different module — so a rename here is a breaking change for every deployed
site.

### `POST /api/me/nats-creds/rotate`

Re-mint the caller's own NATS credential. Available to **every role, including
`dashboard`**, for callers in both `users` and `things`.

```
POST /api/me/nats-creds/rotate
(no body)
```

```json
{ "rotated": true, "nats_user": "a1b2c3d4e5f6g7h" }
```

It writes exactly one field, `regenerate`, on the caller's linked `nats_users`
row. pb-nats watches that field, re-mints the JWT and `creds_file`, then clears
it — so **re-read your own record afterwards** to pick up the new credential.

For a `users` caller the identity is the `nats_user` on the membership for the
active organization; for a `things` caller it is the relation on the Thing itself.
Either way nothing is read from the request.

!!! note "Revocation is deliberately not part of this route"
    Setting `regenerate` on a revoked user would re-enable it. Revocation stays an
    owner/admin action through the normal update rule on `nats_users`, or a
    consequence of [deactivating the device](./authorization.md#42-taking-a-device-out-of-service)
    that holds the identity.

---

## 4. Organization routes (`/api/org/*`)

### `POST /api/org/invites/accept`

Redeem an invitation token. Any authenticated caller; the invitation is matched to
the caller by email address, case-insensitively.

```json
{ "token": "8f3a…" }
```

```json
{ "message": "Successfully joined organization.", "organization": "9k2j…" }
```

| Response | When |
| :--- | :--- |
| `200` with `organization` | Membership created with the role the invitation carried |
| `200` with `"alreadyMember": true` | You were already in; the invitation is deleted as cleanup. Usually a double-clicked link |
| `400` | No token in the body |
| `403` | The invitation was issued to a different email address |
| `404` | No invitation with that token |
| `410` | Expired. The invitation is deleted on the way out |

Creating the membership, setting `current_organization` when it was blank, and
deleting the invitation all happen in one transaction. `current_organization` is
set **only when blank** — accepting an invitation to a second organization should
not move you out of the one you are working in.

!!! warning "Renamed in 0.6.0"
    This was `POST /api/tenancy/accept-invite` until pb-tenancy was absorbed into
    the platform. The old path named a library that no longer exists. Invitation
    **links** already in delivered mail are unaffected — they point at the console
    route `/accept-invite`, which posts here, not at the API directly. Anything
    driving invitations outside the console needs updating.

From the CLI this is `stone invite accept <token>`, where the token is the
`?token=` value from the invitation link and **not** the invite record's id.
Redeeming sets `current_organization` only when it was blank, so follow it with
`stone org switch` — which is also what writes the nats-cli context the new
membership has no creds for yet.

### `POST /api/org/things`

Create a Thing and, optionally, mint its NATS identity and Nebula host in **one
transaction**. Requires a `users` session with `member`, `admin` or `owner` in the
active organization.

```json
{
  "name": "Lobby Camera",
  "code": "cam-lobby",
  "description": "",
  "type": "<thing_types id>",
  "location": "<locations id>",
  "metadata": {},
  "nats":   { "mode": "auto", "role_id": "<nats_roles id>" },
  "nebula": { "mode": "none" }
}
```

Each identity block takes a `mode`:

| Mode | Effect | Extra fields |
| :--- | :--- | :--- |
| `auto` | Mint a new identity | `nats.role_id`; `nebula.network_id`, `nebula.overlay_ip` |
| `link` | Attach an existing one, verified to belong to this organization | `nats.user_id`; `nebula.host_id` |
| `none` | Leave it unbound — a pure inventory row | — |

An absent block is `none`, and an unrecognised mode is rejected rather than
treated as `none`.

```json
{
  "id": "7h8i9j0k1l2m3n4",
  "code": "cam-lobby",
  "email": "cam-lobby@things.acme.io",
  "password": "…"
}
```

**The password is returned exactly once** — PocketBase stores only its hash, so
this response is the only chance to record it.

**Two authority levels in one operation, which is why this is a route.** Creating
inventory is a `member` action; attaching an identity is not. `things.createRule`
approximates the split by freezing `nats_user` / `nebula_host` in the member
branch, but a *provisioning* endpoint that mints those records cannot be expressed
as a create rule at all. Here it is a role check per section: a `member` calling
with anything other than `none` on both blocks gets `403`.

!!! note "Why one transaction, and why the atomicity is real"
    This replaced three unguarded client calls whose partial failure orphaned a
    signed NATS credential and an allocated overlay IP, and which never sent
    `active`, so every Thing the console created was locked out by
    `things.authRule`. PocketBase defers `*AfterCreateSuccess` hooks to commit, and
    pb-nats mints and publishes on that hook — so a rollback means pb-nats never
    signed anything and never published. The failure mode is "nothing happened",
    not "NATS knows about a user PocketBase forgot".

### `POST /api/org/nats-account/keys`

Manage the signing keys on the active organization's NATS account. **Owner/admin
only.**

```json
{ "action": "add_signing" }
```

| Action | Effect |
| :--- | :--- |
| `add_signing` | Graceful rotation: appends a new signing key. Existing user JWTs stay valid |
| `remove_signing` | Removes one key by `public_key` (required in the body). pb-nats refuses to remove the last remaining key |
| `rotate` | **Emergency replacement:** purges every signing key and generates one. Every user JWT in the account stops validating and must be re-minted |

```json
{ "applied": "add_signing", "nats_account": "3c4d…" }
```

Reach for `add_signing` for routine rotation; `rotate` is for suspected key
compromise.

The `switch` **is** the allowlist — each action sets exactly one field, and an
unrecognised action is rejected rather than ignored. `nats_accounts.updateRule` is
Platform-Operator-only, because the record mixes fields a tenant may legitimately
trigger with the account limits it was sold and the signed account `jwt`. See
[Authorization §4.1](./authorization.md#41-account-signing-keys).

### `POST /api/org/nebula-ca/rotate`

Roll the active organization's Nebula CA. **Owner/admin only**, and the console
presents it as a three-step panel on the CA detail view.

```json
{ "step": "prepare" }
```

| Step | What it does | Reversible |
| :--- | :--- | :--- |
| `prepare` | Publishes the new CA as *trusted* without moving issuance | Yes — fully |
| `commit` | Swaps issuance to the new CA and re-signs every active host. Idempotent, so re-running recovers a partial sweep | The outgoing CA is still trusted |
| `finish` | Drops the outgoing CA. **Refused** while any active host still holds a certificate signed by it, and the error names the host | No |

```json
{ "applied": "prepare", "nebula_ca": "5e6f…" }
```

The route allowlists the three verbs; pb-nebula validates the *transition* and its
message is surfaced verbatim on a `400`, because that message is the whole reason
the interlock is usable.

**Three steps because the wait between them is the feature.** Nebula verification
is mutual and config distribution is pull-based, so a single write carrying both
new trust and new certificates splits the mesh: a host that has fetched presents a
new-CA certificate to one that has not, and the handshake fails in *both*
directions. `prepare` exists to land the trust half first, everywhere.

**The tenant owns this lever deliberately** — a Platform Operator cannot judge when
a fleet has caught up. Requires pb-nebula v0.3.2. See
[Authorization §4.3](./authorization.md#43-rolling-a-nebula-ca).

### `GET /api/org/nebula/cert-audit`

Which of the organization's Nebula hosts hold a certificate whose network no
longer matches the network the host belongs to. **Owner/admin only.**

```json
{ "stale": ["4f5g6h7i8j9k0l1", "2m3n4o5p6q7r8s9"] }
```

`stale` is never `null` — an empty array means "no host needs attention", where a
null would read as "the audit did not run".

It exists because pb-nebula signed host certificates at `/32` until v0.3.0. Nebula
puts a certificate's network straight onto the tun device and installs a link
route for it, so the mask **is** the host's route to the overlay: a `/32` verifies,
renders, handshakes — and moves no packet. Nothing errors anywhere.

**A route because answering it means parsing a Nebula certificate**, which no
browser can do.

!!! warning "Read-only, and nothing is re-signed automatically"
    Re-signing moves a certificate's fingerprint, and a fingerprint is what
    `pki.blocklist` revokes — so a sweep would rewrite every peer config in the
    mesh on the strength of a dependency bump. The audit names the hosts; the fix
    is `renew` on one host at a time, then redeploy that host's config.

    **Inactive hosts are excluded**, and not as an optimization: an inactive host
    is revoked, so re-signing it would publish a new fingerprint while the old
    certificate stayed valid and un-blocklisted — silently un-revoking it. A host
    whose certificate or network cannot be read is omitted rather than reported.

---

## 5. Observability

Both are served by the Control Plane itself and need no session and no NATS
connection. Full detail, including every check and metric, is on
[Health & Metrics](./health-metrics.md).

### `GET /api/ready`

Unauthenticated, and **always served** — a probe endpoint that can be disabled is
one some deployment will disable and then be unable to explain.

```json
{
  "ready": true,
  "state": "warn",
  "version": "0.8.0",
  "uptime": "4h12m",
  "took": "3ms",
  "checked": "2026-09-18T09:14:02Z",
  "checks": [
    { "name": "nats_reachable", "state": "ok", "took": "2ms" },
    { "name": "nebula_cert_expiry", "state": "warn",
      "detail": "1 Nebula host certificate expiring within 30 days (soonest 2026-10-11)",
      "fix": "Re-issue before the date above. Nebula certificates fail all at once and silently." }
  ]
}
```

Ten checks: `database`, `schema`, `schema_version`, `bootstrap`, `nats_operator`,
`nats_reachable`, `nats_trust`, `nebula_cert_expiry`, `nats_websocket_urls`,
`encryption_at_rest`.

**Four states, and only `fail` is unready** — so the endpoint answers `503` only
when something is genuinely broken, and `200` for warnings. That is what makes it
safe in front of a load balancer.

| State | Means |
| :--- | :--- |
| `ok` | Checked and healthy |
| `warn` | Running, but misconfigured. Still `200` |
| `skipped` | The check could not look. Ranks **below** `ok` |
| `fail` | Unready. `503` |

Every non-OK check carries remediation guidance in `fix` — a command where there
is one, prose where the fix is a judgement. Probing runs in the
background on `readiness.interval`, off the startup path — so during startup the
endpoint correctly answers "503, not probed yet" rather than blocking the listener
on a NATS dial timeout.

### `GET /metrics`

Prometheus exposition. On by default (`metrics.enabled`), **unauthenticated by
default**, and closed with `metrics.token` (Bearer or Basic) or a proxy.

Two constraints worth knowing before you add a series:

- **No per-organization labels.** `/metrics` is open by default, and a tenant name
  beside a certificate inventory is free reconnaissance.
- **`stone_age_records{collection="things"}` counts devices CONFIGURED, not
  online.** An alert on it can never fire. Anything mistakable for a health signal
  says so in its HELP text.

Alert on certificate expiry relative to now, so the horizon lives in the alert:

```
stone_age_certificate_expiry_seconds - time() < 30 * 86400
```

Give the CA a wider horizon than a host — 90 days, not 30. A host certificate is
reissued in a moment; a CA can only be rotated, which is a staged procedure with a
wait in the middle of it.

---

## 6. What is deliberately not here

- **No resolver service.** A QR label carries a bare code and nothing fetches the
  decoded string as a destination. See [ADR 0002](./decisions/0002-organization-code-namespace.md#why-a-qr-payload-is-the-bare-code).
- **No bulk certificate re-issue.** See `cert-audit` above.
- **No route granting Platform Operator status.** `bootstrap` and the embedded
  admin panel are the only two paths; no API rule permits writing `is_operator`.
- **No server-side twin push.** `twin_desired` is a delivery mechanism — nothing in
  the platform applies a desired value to a device. See
  [Architecture §4.3](./architecture.md#43-the-console-says-differs-never-pending).
- **JetStream and KV management is not an HTTP API.** Streams and buckets are
  created over the browser's own NATS connection, so they are bounded by the
  caller's **NATS** permissions rather than by PocketBase API rules.

---

## 7. Where to Go Next

- **Who may call what, and the rules behind it:** [Authorization & Roles](./authorization.md).
- **The same operations from a terminal:** [Stone CLI](./stone-cli.md).
- **The edge identity model `leaf-config` serves:** [Leaf Nodes](./leaf-nodes.md).
- **Every check and metric in full:** [Health & Metrics](./health-metrics.md).
- **Config keys the routes read:** [Configuration Reference](./configuration.md).
