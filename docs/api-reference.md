---
path: platform/api-reference
nav_order: 90
---
# API Reference

Most of the Stone-Age.io API is stock PocketBase REST on a collection, such as
`GET /api/collections/things/records` or
`PATCH /api/collections/locations/records/:id`. The API rules in `schema.json`
control it ([Authorization & Roles](./authorization.md)). The
[PocketBase API docs](https://pocketbase.io/docs/api-records/) describe it.

This page covers the **ten endpoints the platform adds**: nine under `/api/`,
and `/metrics`. Each application route exists because a PocketBase API rule
cannot express what it does.

---

## 1. The whole surface

| Route | Method | Who can call it | Does |
| :--- | :--- | :--- | :--- |
| [`/api/client-config`](#get-apiclient-config) | `GET` | any `users` session | Deployment settings the SPA cannot contain at build time |
| [`/api/me/leaf-config`](#get-apimeleaf-config) | `GET` | any `things` session | Ten fields an agent needs to run a NATS leaf server |
| [`/api/me/account-jwt`](#get-apimeaccount-jwt) | `GET` | any `things` session | The caller's account JWT, so a gateway can tell when its leaf config is out of date |
| [`/api/me/nats-creds/rotate`](#post-apimenats-credsrotate) | `POST` | any `users` or `things` session | Rotate the caller's own NATS credential |
| [`/api/org/invites/accept`](#post-apiorginvitesaccept) | `POST` | any `users` session | Redeem an invitation token |
| [`/api/org/things`](#post-apiorgthings) | `POST` | `member` and up for inventory, `owner`/`admin` for identities | Create a Thing and, optionally, its NATS and Nebula identities, in one transaction |
| [`/api/org/nats-account/keys`](#post-apiorgnats-accountkeys) | `POST` | `owner` / `admin` | Manage the organization's NATS account signing keys |
| [`/api/org/nebula-ca/rotate`](#post-apiorgnebula-carotate) | `POST` | `owner` / `admin` | Roll the organization's Nebula CA in three steps |
| [`/api/ready`](#get-apiready) | `GET` | unauthenticated | Readiness probe, `200` or `503` |
| [`/metrics`](#get-metrics) | `GET` | unauthenticated by default | Prometheus exposition |

Roles come from memberships and apply to the caller's **active** organization
(`users.current_organization`). See [Authorization §2](./authorization.md#2-capability-matrix).

Two more endpoints are not in the table, because they do not replace a rule:

- **`GET /branding/{path}`** serves unauthenticated static files for the
  operator's theme (`theme.css`, `logo.svg`, `branding.json`) from a host
  directory. See [Configuration §`branding`](./configuration.md#branding).
- **`POST /api/files/token`** is stock PocketBase, and you need it to fetch any
  uploaded file. Every file field on the platform is **protected**, so
  `/api/files/...` accepts only a short-lived *file* token (`?token=`) from this
  endpoint and checks it against the collection's view rule. **An auth token is
  not a file token.** A URL with an auth token returns `404`. See
  [The Console §7](./console.md#7-photos-and-file-fields).

---

## 2. Three rules that apply to all of them

**No route takes a record id.** Every `/api/me/*` route targets the caller's own
record. Every `/api/org/*` route targets the caller's active organization, with one
exception: `invites/accept` joins the organization the invitation names, and
the invitation must match the caller's email address. The target comes from
the session or from a server-side record, never from an id in the request, so
no route can target another tenant. The missing id parameter is the security property.

**A route that writes with `app.Save()` skips every API rule.** So each route
repeats the checks the rules would make. For example, `POST /api/org/things`
takes the organization from the caller's own record, and checks that a linked
`nats_user` or `nebula_host` belongs to that organization. Without the second
check, the route would let a caller steal another tenant's credential.

**Each route exists for one of three reasons.** A new route must also have one:

| Reason | Routes |
| :--- | :--- |
| A rule cannot allow only one field. The alternative is `:isset = false` on every other field, a deny-list that opens silently when someone adds a field. | `nats-creds/rotate`, `nats-account/keys`, `nebula-ca/rotate` |
| One operation needs two authority levels | `org/things` |
| The answer needs data the caller cannot compute or must not read whole | `leaf-config`, `account-jwt`, `client-config` |

Three routes are not in the table. `invites/accept` creates a membership for a
caller who has no role in the organization yet. `/api/ready` and `/metrics`
serve callers that have no session.

---

## 3. Identity routes (`/api/me/*`)

`GET /api/client-config` is not under `/api/me/`. It is in this section because
it also depends only on the caller's session.

### `GET /api/client-config`

Deployment settings that the console needs at runtime and cannot contain at
build time. Requires a `users` session.

```json
{ "natsWebsocketUrls": ["wss://bus.acme.io:9222"] }
```

The value is `nats.websocket_urls`, the address a browser dials, never derived
from `nats.server_url`
([Configuration §2.1](./configuration.md#21-serverurl-and-websocketurls-are-different-addresses)).
An empty list means "not configured", and the console uses its built-in
`ws://localhost:9222`. A device can override it in Settings.

### `GET /api/me/leaf-config`

Everything an [Agent](./agent.md) needs to run a NATS leaf server. It is bound
to the `things` collection, and the target is the caller's own record.

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

`domain` is the same string as `code`. The JetStream domain is computed from
the Thing's code and is not stored, so it cannot disagree with the code. The
agent writes it into `server_name` and `jetstream { domain }`.

`hub_leaf_url` and `hub_domain` are `nats.leaf_url` and
`nats.jetstream_domain`. If either is empty, the route answers `503` and names
the setting, rather than serve a config the agent would reject.

**The route checks only that the caller is an authenticated Thing.** Everything
it returns is public trust material or the caller's own credential. It does
**not** return account seeds, signing keys or any `$SYS` *user* credential.
[Leaf Nodes §3](./leaf-nodes.md#3-get-apimeleaf-config) describes each field
and gives the reasons for the missing check.

::: warning Do not add a device read branch to `nats_*` or `nebula_*`
Extend this route instead. The route keeps the edge's exposure to a fixed list
of named fields, not to rules that change for other reasons. See
[Leaf Nodes §3](./leaf-nodes.md#3-get-apimeleaf-config).
:::

The field names are a **contract with the agent repository**. The agent reads
them by name, so a rename breaks every deployed site.

### `GET /api/me/account-jwt`

The account JWT that `leaf-config` would serve, and nothing else. It is bound
to the `things` collection, and the target is the caller's own record.

```json
{
  "account_jwt": "eyJ0…",
  "account_pub": "AD3…"
}
```

A running gateway calls it every `platform.leaf_refresh_interval`. Revocations
are in the account JWT, so a new JWT means the site's leaf is out of date. The
agent then fetches `leaf-config` and reloads the leaf. When the JWT is the same,
it fetches nothing else. So the Thing's credential crosses the network only
when something changed. See [Leaf Nodes §5](./leaf-nodes.md#5-deploy-flow).

Both values are public trust material. The route makes the same lookup as
`leaf-config`, so it always names the same account. The two field names are the
same as in `leaf-config`.

### `POST /api/me/nats-creds/rotate`

Mint a new NATS credential for the caller. **Every role, including
`dashboard`**, can call it, from `users` and `things`.

```
POST /api/me/nats-creds/rotate
(no body)
```

```json
{ "rotated": true, "nats_user": "a1b2c3d4e5f6g7h" }
```

It writes one field, `regenerate`, on the caller's linked `nats_users` row.
pb-nats sees the field, mints a new JWT and `creds_file`, and clears the field.
**Read your own record again** to get the new credential.

For a `users` caller, the identity is the `nats_user` on the membership for the
active organization. For a `things` caller, it is the relation on the Thing.
Nothing comes from the request. Only an owner or admin can choose which
identity a membership links to. See
[Authorization §4](./authorization.md#4-the-row-scoped-credential-model).

| Response | When |
| :--- | :--- |
| `200` | New credential minted |
| `400` | A `users` caller with no active organization |
| `403` | The linked identity is **suspended** (`active = false`) |
| `404` | No membership in the active organization, or no linked identity |

::: note A suspended identity cannot rotate itself back to life
pb-nats treats `active = false` as "revoked, issue nothing". A new credential
would have a JWT issued *after* the account's revocation cutoff, and NATS would
accept it. Without the `403`, this route would end the suspension. Owners and
admins suspend and reactivate through the normal update rule on `nats_users`,
or by [deactivating the device](./authorization.md#42-taking-a-device-out-of-service)
that holds the identity.

Rotation does not retire a **leaked** file. `regenerate` signs again for the
same seed, so the leaked `.creds` keeps working. Use `revoke`, which moves to a
new key pair (owner/admin).
:::

---

## 4. Organization routes (`/api/org/*`)

### `POST /api/org/invites/accept`

Redeem an invitation token. Only a person can call it: a `users` session. A
Thing token gets `403`. The invitation must match the caller's email address,
ignoring case.

```json
{ "token": "8f3a…" }
```

```json
{ "message": "Successfully joined organization.", "organization": "9k2j…" }
```

| Response | When |
| :--- | :--- |
| `200` with `organization` | Membership created with the invitation's role |
| `200` with `"alreadyMember": true` | You were already a member. The invitation is deleted. This is usually a double-clicked link. |
| `400` | No token in the body |
| `403` | The invitation is for another email address |
| `404` | No invitation with that token |
| `410` | Expired. The invitation is deleted. |

One transaction creates the membership, sets `current_organization` if it was
blank, and deletes the invitation. `current_organization` changes **only when
blank**, so accepting a second invitation does not move you out of your current
organization.

Invitation links in email go to the console route `/accept-invite`, which posts
to this endpoint.

In the CLI, use `stone invite accept <token>`. The token is the `?token=` value
from the invitation link, **not** the invite record's id. Then run
`stone org switch`, which also writes the nats-cli context for the new
membership.

### `POST /api/org/things`

Create a Thing and, optionally, mint its NATS identity and Nebula host in **one
transaction**. Requires a `users` session with `member`, `admin` or `owner` in
the active organization.

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

Each identity block has a `mode`:

| Mode | Effect | Extra fields |
| :--- | :--- | :--- |
| `auto` | Mint a new identity | `nats.role_id` (optional, defaults to the organization's `is_default` role); `nebula.network_id`, `nebula.overlay_ip` |
| `link` | Attach an existing one, checked to belong to this organization | `nats.user_id`; `nebula.host_id` |
| `none` | Leave it unbound: an inventory record only | none |

- `name` is required (`400` without it).
- `code` is optional. If it is blank, the route generates one under the Thing
  Type's prefix (`CA-9KD-4PX`) before it saves anything, because the email and
  the NATS username come from the code. The response always includes the code.
- The route refuses a code that another Thing in the organization already has,
  ignoring case (`cam-1` and `CAM-1` conflict). See
  [Generated codes](./thing-types.md#generated-codes).
- A missing identity block means `none`. An unknown mode is rejected.
- `nats.mode: "auto"` needs an **active** NATS account. While the organization
  is [suspended](./authorization.md#31-suspending-an-organization), it returns
  `400` ("no active NATS account for this organization"). `link` and `none`
  still work.

```json
{
  "id": "7h8i9j0k1l2m3n4",
  "code": "cam-lobby",
  "email": "cam-lobby@acme.thing.local",
  "password": "…"
}
```

This route sets the email to `<thing code>@<organization code>.thing.local`. It uses the
organization's **code**, not its name, because a name is not unique and can
change.

**The password is returned only once, and only to an Owner or Admin.**
PocketBase stores only its hash, so record it from this response. When a
`member` creates the Thing, the response has no `password` field. An Owner or
Admin sets one later. Only they can (`things.manageRule`), and a password a
`member` sends to the record API is replaced.

**This is a route because one operation needs two authority levels.** A
`member` can create inventory but cannot attach an identity.
`things.createRule` freezes `nats_user` and `nebula_host` in the member branch,
but a create rule cannot describe an endpoint that mints those records. The
route checks the role for each part. A `member` who sends anything other than
`none` on both blocks gets `403`.

::: note Why the transaction is truly atomic
PocketBase runs `*AfterCreateSuccess` hooks only after the commit, and pb-nats
mints and publishes in that hook. After a rollback, pb-nats has signed and
published nothing. A failure means "nothing happened", never "NATS knows a user
that PocketBase does not".
:::

### `POST /api/org/nats-account/keys`

Manage the signing keys on the active organization's NATS account.
**Owner/admin only.**

```json
{ "action": "add_signing" }
```

| Action | Effect |
| :--- | :--- |
| `add_signing` | Routine rotation: adds a new signing key. Existing user JWTs stay valid. |
| `remove_signing` | Removes one key by `public_key` (required in the body). pb-nats refuses to remove the last key. |
| `rotate` | **Emergency replacement:** deletes every signing key and generates one. Every user JWT in the account stops validating and must be minted again. |

```json
{ "applied": "add_signing", "nats_account": "3c4d…" }
```

Use `add_signing` for routine rotation. Use `rotate` only if you suspect a key
is compromised.

The route's `switch` statement is the allowlist. Each action sets one field,
and an unknown action is rejected. `nats_accounts.updateRule` is
Platform-Operator-only, because the record also holds the account limits the
tenant bought and the signed account `jwt`. See
[Authorization §4.1](./authorization.md#41-account-signing-keys).

### `POST /api/org/nebula-ca/rotate`

Roll the active organization's Nebula CA. **Owner/admin only.** The console
shows it as a three-step panel on the CA detail view.

```json
{ "step": "prepare" }
```

| Step | What it does | Reversible |
| :--- | :--- | :--- |
| `prepare` | Publishes the new CA as *trusted*. Issuance does not change. | Yes, fully |
| `commit` | Moves issuance to the new CA and re-signs every active host. You can run it again to finish a partial sweep. | The old CA is still trusted |
| `finish` | Removes the old CA. **Refused** while any active host still has a certificate signed by it. The error names the host. | No |

```json
{ "applied": "prepare", "nebula_ca": "5e6f…" }
```

The route allows the three steps. pb-nebula checks each *transition*, and on a
`400` the route returns pb-nebula's message unchanged, because that message
tells you what to do.

**The wait between steps is the point.** `prepare` makes the new trust reach
every host before issuance moves.
[Authorization §4.3](./authorization.md#43-rolling-a-nebula-ca) explains why
the roll takes three steps and why the tenant controls it.

---

## 5. Observability

Both endpoints are served by the Control Plane with no session and no NATS
connection. The response body, the ten checks, the four states, every metric
and the alerts to set are in [Health & Metrics](./health-metrics.md).

### `GET /api/ready`

Unauthenticated and always on. `200` when ready, warnings included; `503`
when a check fails, and before the first background probe has run.

### `GET /metrics`

Prometheus exposition, on by default (`metrics.enabled`) and unauthenticated
by default. Protect it with `metrics.token` (Bearer or Basic) or a proxy.

---

## 6. What is deliberately not here

- **No resolver service.** A QR label holds a bare code, and nothing opens the
  decoded string as a destination. See
  [ADR 0002](./decisions/0002-organization-code-namespace.md#why-a-qr-payload-is-the-bare-code).
- **No route that grants Platform Operator status.** Only `bootstrap` and the
  admin panel can. `users.updateRule` and every branch of `users.createRule`
  refuse `is_operator`, so an operator cannot create an operator.
- **No server-side twin push.** Nothing in the platform applies a desired value
  to a device. See [Architecture §4.3](./architecture.md#43-nothing-applies-desired-values).
- **No HTTP API for JetStream and KV.** The browser creates streams and buckets
  over its own NATS connection. The caller's **NATS** permissions limit them,
  not API rules. The account's JetStream storage limits
  (`max_jetstream_disk_storage`, `max_jetstream_memory_storage`), set when the
  account is provisioned, limit the total.

---

## 7. Where to Go Next

- Who can call what: [Authorization & Roles](./authorization.md)
- The same operations from a terminal: [Stone CLI](./stone-cli.md)
- The edge identity model behind `leaf-config`: [Leaf Nodes](./leaf-nodes.md)
- Every check and metric: [Health & Metrics](./health-metrics.md)
- Config keys the routes read: [Configuration Reference](./configuration.md)
