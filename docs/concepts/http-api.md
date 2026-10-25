---
path: concepts/http-api
nav_order: 40
---
# HTTP API

The Control Plane is built on **PocketBase**, a Go framework that puts a
database, a REST API, authentication and an admin panel in one binary. Most of
the Stone-Age.io HTTP API is stock PocketBase. This page explains collections,
records, tokens, API rules and the SQLite database under them. For the full
detail, see the [PocketBase documentation](https://pocketbase.io/docs/).

---

## 1. Collections and records

A **collection** is like a database table. A **record** is one row in it.
PocketBase has three types of collection:

| Type | What it is | Platform examples |
| :--- | :--- | :--- |
| **Base** | Normal records. | `locations`, `thing_types`, `memberships` |
| **Auth** | Records that can sign in. Each has a password and gets tokens. | `users` for people, `things` for devices |
| **View** | A read-only collection built from a SQL query. | None. The platform uses no view collections. |

A **relation** field holds the id of a record in another collection. For
example, `things.location` holds the id of a `locations` record. A rule can
also follow a relation backwards. `memberships_via_user` means "the
`memberships` records whose `user` field points to this record".

**A Thing is an auth record.** A device signs in to the API as its own Thing
record, and reads its own configuration. See
[Architecture §3.1](../architecture.md#31-inventory-as-identity).

---

## 2. The REST API

Each collection gets the same routes:

| Route | Method | Does |
| :--- | :--- | :--- |
| `/api/collections/{collection}/records` | `GET` | List records, with filter, sort, expand and pages |
| `/api/collections/{collection}/records/{id}` | `GET` | Read one record |
| `/api/collections/{collection}/records` | `POST` | Create a record |
| `/api/collections/{collection}/records/{id}` | `PATCH` | Change a record |
| `/api/collections/{collection}/records/{id}` | `DELETE` | Delete a record |
| `/api/collections/{collection}/auth-with-password` | `POST` | Sign in to an auth collection, and get a token |
| `/api/collections/{collection}/auth-refresh` | `POST` | Get a new token before the current one expires |

Sign in as a user:

```bash
curl -s -X POST http://localhost:8090/api/collections/users/auth-with-password \
  -H 'Content-Type: application/json' \
  -d '{"identity": "admin@example.com", "password": "change-me-8-chars-min"}'
```

The response holds a `token` and the `record`. Send the token in the
`Authorization` header of each request. This request lists one Thing by its
code, with its location expanded:

```bash
curl -s -G http://localhost:8090/api/collections/things/records \
  -H "Authorization: $TOKEN" \
  --data-urlencode 'filter=code = "TP-4KD-7PX"' \
  --data-urlencode 'expand=location'
```

A list response has pages:

```json
{
  "page": 1,
  "perPage": 30,
  "totalItems": 1,
  "totalPages": 1,
  "items": [ { "id": "…", "code": "TP-4KD-7PX", "expand": { "location": { … } } } ]
}
```

Query parameters on a list:

| Parameter | What it does | Example |
| :--- | :--- | :--- |
| `filter` | Keeps only the records that match | `code = "TP-4KD-7PX" && active = true` |
| `sort` | Sorts the records. `-` means descending. | `-created` |
| `expand` | Adds related records under `expand` | `location` |
| `fields` | Returns only these fields | `id,code,name` |
| `page`, `perPage` | Selects a page | `page=2&perPage=100` |

Stone-Age.io adds ten routes for the jobs that a collection cannot do. See
[API Reference](../api-reference.md). The `stone` CLI is a client of the same
API ([Stone CLI](../stone-cli.md)).

---

## 3. Tokens

A sign-in returns a **token**. It is a JWT, as in
[NATS Security §2](./nats-security.md#2-jwts), but the server signs it with its
own secret. So only the server can check it.

- **Each auth collection sets a token lifetime.** In Stone-Age.io, a Thing's
  token lasts 7 days. The Agent gets a new one on each sync. See
  [The Agent §2.2](../agent.md#22-removing-the-password).
- **Each auth record has a `tokenKey`.** A change to the `tokenKey` makes every
  token of that record invalid at once. Stone-Age.io changes it when you
  deactivate a Thing.
- **A token is not a file token.** To download a protected file, get a
  short-lived file token from `POST /api/files/token`. See
  [Platform Entities §5](../platform-ui-entities.md#photos-and-file-fields).

---

## 4. API rules

Each collection has five **API rules**: `listRule`, `viewRule`, `createRule`,
`updateRule` and `deleteRule`. An auth collection also has an `authRule`, which
decides who can sign in. A rule has one of three kinds of value:

| Value | Who passes |
| :--- | :--- |
| `null` (locked) | Superusers only |
| `""` (empty string) | **Everyone, including a caller with no token** |
| A filter expression | Each caller and record that match the expression |

::: warning An empty rule is open to everyone
An empty string does not mean "nobody". It means that any caller passes,
including a caller with no token. To allow only superusers, the rule must be
`null`. This is the opposite of a NATS allow list in Stone-Age.io, where empty
means nothing ([NATS Security §5](./nats-security.md#5-permissions)).
:::

### Reading a rule

A rule expression uses these names:

| Name | What it refers to |
| :--- | :--- |
| A field name, such as `organization` | The field of the record that the caller acts on |
| `@request.auth.*` | The record of the caller, such as `@request.auth.id` |
| `@request.body.*` | The data that the caller sends in a create or update |
| `@collection.<name>.*` | Records in another collection |
| `:isset`, `:changed` | Whether the request sends a field, or changes it |
| `?=` | "Any of": true if at least one of many values matches |

This is a shortened form of the list rule on `things`:

```
@request.auth.collectionName = "users" &&
organization = @request.auth.current_organization &&
@request.auth.memberships_via_user.organization ?= @request.auth.current_organization
```

It reads: the caller is a person, the Thing is in the caller's active
organization, and the caller has a membership in that organization.

### What a failed rule returns

- **List:** the response leaves out each record that fails. It is a `200` with
  fewer records, not an error.
- **View, update and delete:** a `404`, not a `403`. A caller cannot tell a
  record it cannot see from a record that does not exist.

### What skips the rules

- **Superusers** pass every rule. They use the admin panel at `/_/`.
- **Server-side code** skips the rules. A route that saves a record with
  `app.Save()` must make the same checks itself. See
  [API Reference §2](../api-reference.md#2-three-rules-that-apply-to-all-of-them).

In Stone-Age.io, the API rules are the **only** permission layer. The console
only hides buttons. A rule also cannot allow only one field, so the platform
uses a route for each of those jobs. See [Authorization](../authorization.md).

---

## 5. SQLite

PocketBase keeps all its data in **SQLite**, a database in a file. There is no
separate database server. The files are in the `pb_data` directory.

- **One writer at a time.** SQLite lets many readers work at once, but writes
  wait for each other. This suits inventory, which changes slowly. Fast values,
  such as a temperature, belong in [KV](./persistence.md#3-kv-buckets).
- **Back up with PocketBase, not with a file copy.** A copy of a live database
  file can be inconsistent. Use PocketBase backups or a filesystem snapshot.
  See [Operations §3](../operations.md#3-backups).
- **`pb_data` holds secrets.** It holds the NATS Operator key, each
  organization's Nebula CA key and each issued credential. Protect each backup
  as you protect the live database. See
  [Operations §1](../operations.md#1-what-youre-protecting).

::: warning Do not edit the database with SQL
A write in SQL skips the API rules and every server-side hook. The hooks sign
NATS credentials, issue Nebula certificates and keep tenants apart. A row
changed in SQL can leave a credential that no longer matches its record. Use
the API, the console or the admin panel.
:::

---

## 6. Where to Go Next

- The routes the platform adds: [API Reference](../api-reference.md)
- Who can read and write each collection: [Authorization](../authorization.md)
- The records and the console: [Platform Entities & UI](../platform-ui-entities.md)
- Live state, which is not in SQLite: [Persistence §3](./persistence.md#3-kv-buckets)
- Backups and restores: [Operations](../operations.md)
